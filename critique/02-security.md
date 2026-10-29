# 02 — Security critique: the threat model protects the wrong things

## Verdict

The threat model is a competent enumeration of *component defaults* (SeaweedFS auth, E2B's open
gRPC port, celld's plaintext peers, cloudflared's auto-update) and a near-total blank on the
*architecture's own* trust boundaries. It contains no attack on the enrolment token, none on
`vpc_networks`, none on the Cloudflare account, and none on the Worker itself — the four things
that actually hold the system together. The design is salvageable, but not as written: the
credential placement defeats the stated reason for keeping orchestration off Cloudflare, and
"single-tenant by construction" is contradicted by the document's own compute chapter and its
own build order.

---

## Findings

### [BLOCKER] The enrolment token does not appear in the threat model at all

**Where:** `docs/01-architecture.md:91-92`; `docs/08-threat-model.md` (entire file — zero
occurrences of "enrolment token", "preauth", or "install.sh")

**Claim under attack:** "The enrolment token is single-use, expires in 15 minutes, and is bound
to the `node_id`. It is the only credential that is ever typed by a human."

**Why it fails:** The threat model's asset list (`08:10-17`) ranks the fleet bucket, substrate
credentials, the build path, object data and the audit log. It omits the one credential whose
compromise grants access to all five. The flow at `01:80` is:

```
curl -fsSL https://cfb.example/install.sh | sh -s -- --token <token>
```

The token is in `argv`. On Linux that means it is world-readable in `/proc/<pid>/cmdline` for
the life of the install, it is in the operator's `~/.bash_history`, it is in whatever terminal
recorder or screen-share the operator is using, and — because this is the flow an operator runs
while debugging a new box — it will be pasted into the same ticket or chat thread as the error
message. "Single use, 15 minutes" is a replay control, not a confidentiality control, and the
attack here is not replay: it is *first use*. Whoever redeems the token first becomes
`node_id` X. The legitimate installer then fails with "token already used", the operator sees a
node go `ready` in the dashboard, and the attacker is inside the overlay.

The token is also not merely an identity token. Per `01:82-85` the same 15-minute bearer value
buys a headscale preauth key, a Nomad join stanza, and Incus registration — and per `01:83`,
"installs cloudflared with a tunnel token (only on the site's gateway host)". So a token minted
with `roles: ["gateway"]` (the enum at `spec/openapi.yaml:61-63` lets the caller pick any role,
including `server` and `gateway`) hands an attacker a *connector slot on the site tunnel* or a
*Raft seat*. That is a 15-minute bearer string, typed on a command line, convertible into the
plane-2 chokepoint or the scheduler. Nothing in the threat model prices that.

**What to do instead:** Make enrolment proof-of-possession, not bearer. The machine generates a
keypair, prints its public key/fingerprint, and the operator confirms that fingerprint in the
SPA — the token authorises "this key may enrol as node X", and the key never transits a shell.
Pass the token on stdin or via a file descriptor (`--token-fd 3`), never `argv`. Split the
grant: an enrolment token may enrol *as a node*, and nothing else. Tunnel tokens and Nomad
server credentials are minted by a separate, per-role, operator-confirmed flow, never by the
installer acting on a bearer string. Log every redemption with source IP and fingerprint, and
add a "this node enrolled from an address you have not seen before" alert.

---

### [BLOCKER] `vpc_networks` is an unrestricted L3 pivot into plane 3, and the destination is a runtime string

**Where:** `docs/02-connectivity.md:80-83`, `docs/02-connectivity.md:60-62`;
`docs/08-threat-model.md` (no SSRF attack anywhere)

**Claim under attack:** "Use `vpc_networks`, not `vpc_services`, unless you need to pin a
host:port." (`02:82-83`)

**Why it fails:** Cloudflare's own documentation for VPC Networks states, verbatim
(<https://developers.cloudflare.com/workers-vpc/configuration/vpc-networks/>, fetched
2026-10-29>): *"At runtime, the URL you pass to `fetch()` or the address you pass to `connect()`
determines the destination — any hostname or IP address reachable through the bound Cloudflare
Tunnel or through Cloudflare Mesh."* The page's own example is
`env.MY_VPC.fetch("http://10.0.5.42:5432")`.

So the Worker has, by construction, an unmediated L3 path to every host and port on the overlay,
including the Nomad servers (`4646` with a management token in a header), the Incus API, the
SeaweedFS admin port, and celld's internal listener on `9876`. The only control between an
attacker and that path is *the correctness of every line of Worker code that builds a URL*. This
document's own API has four such inputs: `key` (`spec/openapi.yaml:300`), `repo` and `ref`
(`spec/openapi.yaml:136-137`), `bundle_key` (`spec/openapi.yaml:335`), and `name`
(`spec/openapi.yaml:275`). One template string — ``env.SITE.fetch(`http://${host}/...`)`` — and
the whole private network is reachable from the internet through your dashboard.

The threat model has no SSRF section, and `08:66` treats "reach" as something only a *tenant*
does. It never asks what the *manager* can reach.

**What to do instead:** Use `vpc_services`, one binding per substrate host:port, so the
destination set is fixed at deploy time and enumerated in `wrangler.jsonc`. Where a whole
network binding is genuinely needed, put a single `cfbVpcFetch(path, init)` chokepoint in the
Worker that takes a symbolic name (not a URL), resolves it from a frozen table, and rejects
anything else; make it the only place in the codebase that touches `env.SITE`. Consider routing
Worker egress through Cloudflare Gateway with an explicit allowlist, which Cloudflare documents
as the supported mechanism for this (<https://developers.cloudflare.com/workers-vpc/>).

---

### [BLOCKER] "The Worker is the policy point" — but no policy is specified, and the result is a one-call fleet takeover

**Where:** `docs/02-connectivity.md:176`; `spec/openapi.yaml:15-16`, `spec/openapi.yaml:280-312`;
`docs/07-control-plane.md:129`

**Claim under attack:** "The Worker is the policy point. That is its whole job, and it is a job
an isolate is good at."

**Why it fails:** The policy point has no policy. `spec/openapi.yaml:15-16` applies a single
security scheme globally, and `spec/openapi.yaml:388-392` describes that one scheme as
*"Cloudflare Access JWT for operators; API token for CI systems"* — one scheme for two
identities with wildly different privilege. `07:129` says the CI token's scope is "submit jobs,
read own jobs", but no endpoint implements "own": `GET /jobs` has no repo or actor filter,
`GET /jobs/{id}` has no ownership check, and nothing stops a CI token calling
`DELETE /machines/{id}`, `POST /buckets`, `POST /apps/{app}/deploy` or `POST /nodes/enroll`.

That is not a scoping nuisance, because of `/buckets/{name}/presign`
(`spec/openapi.yaml:280-312`). It takes a free-form bucket `name` and a free-form `key` and
returns a presigned URL, signed with the Worker's S3 credential. `05:187-188` states the
consequence in the document's own words: *"the bucket controls the fleet. Give its credentials
access to one fleet only, because a credential that can write the ownership records can take
over every cell in that fleet."* So: a leaked CI token → `POST /buckets/cfb-celld-myapp/presign`
with `{key: "<ownership record prefix>/...", method: "PUT"}` → attacker writes celld ownership
records → attacker owns every cell in the fleet. `08:10-11` calls that "the highest-value target
in the system", and the API hands it out through an endpoint whose only validation is a string.

**What to do instead:** Write the policy down as a table — (actor class × endpoint × resource) →
allow/deny — and implement it in one middleware, not per handler. Specifically: `presign` must
resolve `name` against the `purpose` recorded at bucket creation (`spec/openapi.yaml:276`), must
pin `key` to a caller-derived prefix, and must never sign with a credential that can reach the
`celld` purpose. Issue a *separate* S3 user per purpose so the presign signer physically cannot
write the fleet bucket. Scope CI tokens to a repo list and filter `/jobs` by it. Require
re-authentication (not just a valid session) for `revoke`, `DELETE /machines/{id}` and
`/nodes/enroll`.

---

### [BLOCKER] Cloudflare account compromise is not an attack, and its blast radius is the entire fleet

**Where:** `docs/08-threat-model.md:91-101` (the nearest thing, Attack 5); `docs/07-control-plane.md:132-133`;
`docs/02-connectivity.md:161`; `README.md` ("orchestration deliberately off Cloudflare")

**Claim under attack:** "The Worker holds the substrate credentials (Nomad ACL token, Incus
client cert, SeaweedFS admin key, celld token). The browser never sees them. This is the reason
the Worker exists." (`07:132-133`)

**Why it fails:** Everything the design does to keep orchestration off Cloudflare is about
*availability* — "if Cloudflare has an incident, your scheduler should keep scheduling"
(`02:110`). It buys nothing for *integrity or confidentiality*, because all four cluster-wide
substrate credentials sit in a Cloudflare account. `08:12-13` correctly labels them "each
cluster-wide". An attacker who takes over the Cloudflare account gets, in order of effort:

1. `wrangler secret list` / deploy a one-line Worker that reads `env` and POSTs it out. Four
   cluster-wide credentials, gone. Nomad management token = arbitrary job submission =
   `raw_exec`/`docker` on every client. Incus cert = create/destroy every VM. SeaweedFS admin
   key = every bucket, including every `cfb-celld-*` fleet bucket. The three-plane rule does not
   slow this down by one hop.
2. Re-issue the tunnel token and run a second connector. `02:161` establishes the premise —
   *"`cloudflared` supports up to 25 replicas per tunnel"* — so the same token legitimately
   serves many connectors. A connector terminates the tunnel and dials the origin in plaintext
   (`02:46` shows `http://10.96.0.5:4646/v1/jobs`), so a rogue connector sees the
   `X-Nomad-Token` header and every other credential the Worker forwards, on every request
   Cloudflare load-balances to it.
3. Edit the Access application's policy. Access is a control *in* the account, not a control
   *over* it. There is no second factor that survives account takeover.
4. Rewrite `install.sh` at `https://cfb.example/install.sh`. Every future enrolment is now a
   rootkit on a machine you own, delivered by a `curl | sh` your own docs told the operator to
   run (`01:80`).

`08:182-183` declares "no key management story" out of scope. That is not a compliance
footnote; it is the finding. The document chose a single policy point on Cloudflare and never
asked what happens when that point is taken.

**What to do instead:** Move the credentials out of the Worker. Put a credential broker on the
gateway host that holds the Nomad/Incus/S3 secrets and mints short-lived, per-action,
per-resource scoped tokens on request; the Worker then holds only a broker credential that can
be revoked in seconds and cannot, by itself, submit a job or write a bucket. Split the Cloudflare
estate: the Access application and DNS in one account, the Worker in another, so taking the
Worker does not take the front door. Pin `install.sh` by published digest and verify it in the
pipe (`curl -fsSL ... -o install.sh && sha256sum -c`) rather than piping to `sh`. And add a
"Cloudflare account compromise" row to the asset table with the honest answer: total.

---

### [BLOCKER] "Single-tenant by construction" is false, and the build order ships the version where it is false

**Where:** `docs/08-threat-model.md:178`; `docs/04-compute.md:18-20`; `docs/11-roadmap.md:71`,
`docs/11-roadmap.md:158`

**Claim under attack:** "**Multi-tenant isolation.** This design is single-tenant by
construction." (`08:178`)

**Why it fails:** The document contradicts itself three pages earlier. `04:18-20`: *"The rule:
**anything you did not write runs in a microVM.** A build that executes `postinstall` scripts
from a dependency tree is untrusted code. … So is a pull request from a stranger."* And the
job submission API is `POST /jobs {repo, ref, recipe}` (`spec/openapi.yaml:136-138`) — a job
*from a repository*. A repository you do not control is a tenant. The design is single-*operator*
and multi-*tenant-by-content*: every PR is a tenant, and the only boundary between tenants is
the one that Phase 5 builds.

Then `11:71`: *"**Start with containers, not microVMs.** Get the whole path working with the
`docker` driver on trusted code, then swap the isolation layer in Phase 5."* Phase 3 is the
third phase in a strictly sequential plan, and Phase 5 does not start until Phase 4 (storage)
is done; `11:142` calls Phase 5 "the uncertain one". And `11:158`
puts microVM isolation on the cut list: *"**MicroVM isolation** — only if every job runs your own
code."* So the document's own sequence runs PR builds in shared-kernel containers, with the
fleet bucket credential and the Nomad client on the same host, for the entire period when the
platform is new and most likely to be handed a stranger's PR. `08:60`'s mitigation — "Untrusted
code runs in a microVM" — is not in the build order until Phase 5.

**What to do instead:** Make the isolation level a property of the *job*, not of the phase.
Every job carries `isolation: container | microvm`; until Phase 5 lands, the Worker refuses to
submit a job whose `repo` is not on an operator-managed allowlist, and returns a specific error
code rather than silently downgrading. Strike `11:158`'s fourth cut entirely, or rewrite it as
"you may cut microVM isolation only if job submission is repo-allowlisted". And change `08:178`
to the true statement: single-operator, multi-tenant by content, with per-job isolation required
before the first external PR.

---

### [MAJOR] Attack 5 conflates two unrelated attacks and its mitigation fits neither

**Where:** `docs/08-threat-model.md:93-101`

**Claim under attack:** "an XSS in the SPA, or a malicious dependency in the build, exfiltrates
the Worker's secrets."

**Why it fails:** An XSS in a static SPA cannot exfiltrate Worker secrets. The SPA is Static
Assets; it has no `env`, no bindings, no isolate. What an XSS gets is the *operator's* Access
session, i.e. the ability to call the API as the operator — which, given the missing policy
above, means "delete every VM, revoke every node, presign the fleet bucket". That is a different
attack with a different fix (step-up auth, confirmation on destructive actions), and the listed
mitigation ("CSP with no `unsafe-inline`") does not touch it.

The second half — "a malicious dependency in the build" — is a real secret-theft path, but only
if "the build" means the Worker bundle, and CSP does nothing for it. Meanwhile the listed
mitigation *"Secrets are Worker secrets, not bindings"* is factually wrong: Cloudflare's docs say
*"Secrets are a type of binding that allow you to attach encrypted text values to your Worker"*
(<https://developers.cloudflare.com/workers/configuration/secrets/>, fetched 2026-10-29>). And
"read at call time" is wrong in the way that matters: `wrangler secret put` *"creates a new
version of the Worker and deploys it immediately"* (same page). A secret is not fetched from a
vault per call; it is materialised into the deployed version's `env`. That is why `07:192-195`
gives four `wrangler secret put` commands — which directly contradicts `08:101`'s "the rotation
path is an API endpoint, not a runbook". One of the two documents is describing a system that
does not exist.

**What to do instead:** Split the attack in two. (a) *Stored XSS in the dashboard* → steals an
operator session; mitigate with CSP, output encoding of attacker-controlled content (see the log
finding below), and step-up re-auth on destructive endpoints. (b) *Compromised dependency in the
Worker bundle* → steals substrate credentials; mitigate by not putting cluster-wide credentials
in the isolate at all (the broker above), by pinning and vendoring the Worker's dependency set
with a lockfile hash checked at deploy, and by an egress allowlist so a malicious dependency has
nowhere to send the secret. Then delete the sentence about bindings and write down what rotation
actually is: a deploy, with a version pin and a rollback.

---

### [MAJOR] Cloudflare is inside plane 3, which is the exact thing the architecture says it prevents

**Where:** `README.md` ("Cloudflare may carry the *control* connection. It must never be the
scheduler, the consensus layer, or the data path between machines."); `docs/08-threat-model.md:155-157`

**Claim under attack:** "Egress policy on the gateway host: it may reach the overlay and the
substrate APIs, and nothing else." (`08:156-157`)

**Why it fails:** That sentence describes a router. The gateway host's permitted destination set
is *the entire overlay* — every Nomad server, every Incus host, every SeaweedFS node, every
celld listener — and the *source* of that traffic is a Cloudflare edge isolate, whose destination
is chosen by a runtime string (see the `vpc_networks` finding). So Cloudflare-the-operator,
every Cloudflare employee with the right internal access, and any bug in Cloudflare's edge
routing has a TCP path into plane 3, at a source address the overlay ACLs will happily admit
because it arrives from the gateway. The document's stated invariant — Cloudflare is never in
the data path between machines — holds only for *machine-to-machine* traffic, and only as long
as nothing pivots. The gateway is the pivot, and it is by design the one host that can reach
everything.

**What to do instead:** Say it out loud in the asset ranking: the Cloudflare account is inside
the trust boundary. Then reduce the surface: the gateway should be a set of `vpc_services`
(one host:port each) rather than a network router, so the destination set is finite and
reviewable. On the overlay, tag the gateway's node and give it an ACL that permits exactly those
host:port pairs, not "the substrate APIs". And put an authenticating proxy in front of each
substrate so that arriving from the gateway is not itself an authorisation.

---

### [MAJOR] The relay is placed on the host the threat model assumes is compromised, and it cannot know the caller

**Where:** `docs/08-threat-model.md:121-122`, `docs/08-threat-model.md:127`,
`docs/08-threat-model.md:155`

**Claim under attack:** "the Incus/celld relay is the one component that holds substrate
credentials *and* faces the Worker. An authorisation bug there is a full cluster compromise."

**Why it fails:** Attack 9 (`08:147-159`) assumes the gateway host is compromised and calls that
"a route into the private network". Attack 7 puts the relay on that same host (`08:155`:
"The gateway host runs `cloudflared` and the relays, nothing else"). The two mitigations are
mutually destructive: the moment the gateway is compromised, the attacker has the relay's Incus
client certificate — `08:12-13` ranks that certificate as a cluster-wide credential — and has
network position to talk to the relay. "Stateless. No session, no cache, no queue" (`08:126`)
does not help; statelessness protects against persistence, not against a caller who is already
inside.

Worse, the relay is reachable *by design* from the Worker over VPC, which means it is reachable
from anything that can make the Worker issue a request — including the SSRF path above and
including a compromised Cloudflare account. Its only gate is "the relay's own token"
(`08:129`), a static shared secret. And `08:127`'s "log every decision with the caller identity"
is unachievable as written: the relay's peer is the Worker. The human's identity can only arrive
as a header the Worker sets, which is forgeable by anyone who can reach the relay and which the
relay has no way to verify. The audit trail (`08:17`, "integrity matters more than
confidentiality") would therefore record whatever the caller claims.

**What to do instead:** Move the relay off the gateway host onto a host that runs no connector,
so compromising the ingress path does not hand over the substrate certificate. Give the relay
its own verifiable identity check: it validates the Cloudflare Access JWT itself (`aud` and
`iss` against the team JWKS — Cloudflare documents this requirement at
<https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/>),
so the actor is proven, not asserted. Bind the relay to the overlay only and give it an ACL that
admits the gateway's address on one port. And log the *JWT subject*, not a header.

---

### [MAJOR] The node agent's ingress path must bypass Cloudflare Access, and nobody has specified it

**Where:** `docs/01-architecture.md:87`; `docs/07-control-plane.md:128-130`;
`spec/openapi.yaml:15-16`

**Claim under attack:** "| Operator (browser) | Cloudflare Access, in front of the Worker |
whole dashboard |" (`07:128`)

**Why it fails:** `01:87` has the node "POSTs a heartbeat to the Worker over the tunnel". That is
inbound to the Worker from a machine with no human and no Access session. Two possibilities, both
bad. Either heartbeats carry an Access *service token* — which, per Cloudflare's API reference,
defaults to one year and accepts the literal value `forever`
(<https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/service_tokens/methods/list/>,
fetched 2026-10-29) — so every enrolled node carries a year-long, unattributable Access
credential; or the agent routes are an Access *bypass*, i.e. an internet-facing, unauthenticated
surface whose only control is the node bearer token. `07:130` says the node token lives in the
DO, but `spec/openapi.yaml` has no agent endpoints and no node authentication scheme at all — the
contract that the whole "three distinct identities" table describes is not in the spec. And
`08:133-142` (DoS) is the only attack that mentions the manager's own endpoints, so the
internet-facing-agent surface is not analysed anywhere.

**What to do instead:** Specify the agent API as a first-class, separately-mounted surface
(`/agent/*`) with its own mTLS or signed-request scheme, not a bearer token in a header; publish
the agent contract in `openapi.yaml` as a second `securityScheme`. If Access is used at all on
that path, use per-node service tokens with a 24-hour duration and rotate them on the node's
heartbeat response. Add the agent surface to the threat model with an explicit note that it is
internet-reachable and Access does not cover it.

---

### [MAJOR] The reconciler turns any substrate compromise into persistent inventory

**Where:** `docs/01-architecture.md:218-219`; `docs/10-failure-modes.md` (Failure 5)

**Claim under attack:** "D1 holds *intent*. The substrate holds *reality*. When they disagree,
reality wins and D1 is corrected by a reconciler — not the other way round."

**Why it fails:** This is a persistence primitive. An attacker who can create a Nomad job or an
Incus instance — via a leaked substrate credential, via the E2B host below, or via the presign
bug — does not need to touch D1: the reconciler will adopt their artifact into the inventory as
"reality" and the dashboard will show it as legitimate. `01:182` goes further: a new VM "enrols
itself using a token the API embedded in its cloud-init user-data", so an attacker who can read
user-data from the Incus API (or from inside a VM they compromised during provisioning) gets an
enrolment token, and the reconciler gives them a row in the inventory.

The same gap applies to the fleet bucket. `10:Failure 5` defines the CAS probe as "two concurrent
`If-None-Match: *` PUTs … asserts exactly one succeeds". That tests whether the *store* honours
CAS. It says nothing about whether the ownership records are *legitimate*. `08:10-11` says
whoever can write them owns the fleet, and there is no control, log or alert that fires when
somebody does.

**What to do instead:** Reconciler adoption must be an authenticated, attributed event: any
substrate object not created through the Worker's own audit-logged path is quarantined and
alerted, not adopted. Give the Worker-created resources a provenance label (Nomad job meta,
Incus config key) and reconcile only labelled objects. On the bucket side, maintain a signed
manifest of expected ownership records in D1 and alert on any record that does not verify —
that is the integrity signal you actually want, and the CAS probe is not it.

---

### [MAJOR] E2B Embed violates the document's own residual-risk rule

**Where:** `docs/08-threat-model.md:68-70`; `docs/04-compute.md:208-209`, `docs/04-compute.md:78`

**Claim under attack:** "do not run untrusted code on a host that also holds your fleet bucket
credentials." (`08:69-70`)

**Why it fails:** `04:208-209` describes Embed as "29 containers/services, 13 host ports, 8
one-shot initialisers, and a **privileged orchestrator process launched through `nsenter`**" on
a *single machine* (`04:78` points its `s3://` seam at SeaweedFS). That is a host running
untrusted sandboxed code, with a privileged process whose entire job is to enter namespaces, and
with S3 credentials in its environment. `08:Attack 2`'s mitigation is "bind 5008 to loopback",
which addresses a different problem (an unauthenticated gRPC port reachable from the tunnel) and
does nothing about privilege concentration on the sandbox host. A single escape from an E2B
sandbox reaches a `nsenter`-capable process, and from there the S3 credential and the node's
overlay identity. The document already wrote the rule; the recommended option breaks it.

**What to do instead:** If Embed is used, put it on a dedicated host that holds *no* fleet
credential: give it its own S3 user scoped to `cfb-images` and `cfb-cache` only, keep it off the
`cfb-celld-*` buckets entirely, and do not run a Nomad client or celld node on it. Or say
plainly that Embed and the residual-risk rule are incompatible and pick one.

---

### [MAJOR] Build-cache poisoning crosses the microVM boundary, and the boundary is a prefix

**Where:** `docs/08-threat-model.md:66`; `docs/04-compute.md:181-192`; `spec/openapi.yaml:136-137`

**Claim under attack:** "Build caches are per-job-prefix and read-only where possible." (`08:66`)

**Why it fails:** "Where possible" is doing all the work. A prefix is not an isolation boundary
when the writer chooses the prefix. `POST /jobs` takes `repo` and `ref` as free strings
(`spec/openapi.yaml:136-137`), so the cache key is caller-controlled; and even with a fixed
per-repo prefix, a PR from a fork of *your* repo writes the same prefix as `main`. The attack is
the standard one and it is immune to Firecracker: an untrusted PR populates
`cache/<toolchain>/…` with a poisoned compiler cache, artifact or `node_modules` tree; the next
trusted build on `main` restores it and executes attacker code *with the trusted build's
artifact-write credentials*. The microVM was per-job and it worked perfectly — the state that
crossed jobs was the cache.

`04:191` also notes the local SSD `host_volume` "for the hot cache", which is shared across
all jobs on the node, with no mention of per-job scoping at all.

**What to do instead:** Cache entries must be content-addressed and verified: key on
`hash(repo, ref, lockfile, toolchain)`, write to an immutable object, and have the consuming
build verify a manifest hash before use. Never let an untrusted job write a key an untrusted
job will later read without verification. On the node-local tier, give each job a fresh
`host_volume` mount or make the hot cache read-only to jobs and writable only by a supervisor
that validates on insert.

---

### [MAJOR] Browser presigned uploads are unreachable unless you re-open the SeaweedFS exposure the document calls its most dangerous default

**Where:** `docs/05-storage.md:112-113`; `docs/02-connectivity.md:170-174`;
`docs/08-threat-model.md:32-33`; `docs/07-control-plane.md:170`

**Claim under attack:** "the 100 MB Worker body cap means uploads must be presigned and go direct
from the browser or the runner." (`05:112-113`)

**Why it fails:** The browser "Never join[s] the private network" and "Never talk[s] to a private
address directly. It cannot" (`02:170-174`). The S3 gateway is "behind `vpc_networks` … reach it
only from the Worker and from runners over the overlay" (`08:32-33`). Yet `07:170` advertises
"presigned upload links" in the Storage screen. A presigned URL is a URL; the browser must be
able to resolve and connect to it. It cannot. So either browser uploads do not work, or the S3
gateway gets a public hostname — which is precisely the configuration `08:23-25` attacks, and
which `05:99-101` calls "the single most dangerous default in the entire stack". The document has no third
option and does not notice the contradiction. There is a second-order problem too: a presigned
URL minted against an overlay-only endpoint will contain the *internal* hostname, leaking
private topology into the browser.

**What to do instead:** Pick one and write it down. Either (a) drop browser-direct upload and
route all artifact ingress through runners and CI, or (b) publish a *separate*, write-only S3
gateway hostname with its own credentials that can only `PUT` to `cfb-artifacts/` with a
server-minted key, and document it as the one deliberately-public surface. Do not leave it
implied that a browser can reach an overlay-only endpoint.

---

### [MAJOR] The audit log's integrity is asserted, not engineered — and it is written by the component it audits

**Where:** `docs/08-threat-model.md:17`, `docs/08-threat-model.md:182-183`;
`spec/openapi.yaml` (`GET /audit`, "Append-only audit log")

**Claim under attack:** "The audit log. Integrity matters more than confidentiality." (`08:17`)

**Why it fails:** The audit log lives in D1 (`01:34`, `07:15`), written by the Worker, which is
the same component that performs every action being audited. D1 has no append-only enforcement —
it is SQLite, and the Worker holds the binding. So anyone who compromises the Worker (an
injected dependency, a bad deploy) or the Cloudflare account can `UPDATE`/`DELETE` audit rows
before exfiltrating anything. `08:182-183` then declares "No audit-grade immutability" out of
scope while `08:17` ranks audit integrity fifth-highest — the document states the requirement
and waives the mechanism in the same file. There is also no D1 backup or restore path anywhere:
`02`'s failure table says only "D1 unavailable → dashboard read-only", and `10` has no
"we lost D1" scenario, so the audit log's RPO is "whatever Cloudflare's retention happens to be".

**What to do instead:** Ship audit entries off the manager's trust domain as they are written: a
hash chain (`prev_hash`) stored in D1 *and* appended to an object-lock-protected SeaweedFS bucket
that the Worker can only append to. `05:165` already notes SeaweedFS has object lock — use it for
this and only this. Add a daily anchor (chain head) to R2. Then "append-only" is a property of
the storage, not a claim in a comment. And add D1 restore to `10-failure-modes.md`.

---

### [MAJOR] The break-glass Access service token is an unexpiring, unattributable master key, described in one sentence

**Where:** `docs/10-failure-modes.md:172-173`

**Claim under attack:** "Cloudflare Access has a break-glass path via service token. Keep one,
stored offline, with a documented rotation. This is the one credential that must not live only in
the dashboard."

**Why it fails:** Cloudflare's own API reference gives service tokens a duration field that
"Must be in the format `300ms` or `2h45m`, or the special value `forever` for non-expiring
tokens. The default is 1 year in hours (8760h)"
(<https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/service_tokens/methods/list/>,
fetched 2026-10-29). So the default break-glass credential is valid for a year, and can be made
permanent. It bypasses Access, therefore it bypasses your IdP and any MFA policy attached to it.
It is not a human identity, so every audit entry it produces says "a token", not a person — which
directly defeats `08:17`'s stated priority. It is stored "offline", i.e. outside every rotation
mechanism and every alert the system has. One sentence is not a treatment for the weakest front
door in the design.

**What to do instead:** Make break-glass a *human* identity with a hardware key, not a service
token: a dedicated Access policy restricted to one IdP group with a WebAuthn-only rule, plus a
paging alert on any use. If a service token is unavoidable, set a duration of hours (not `forever`,
not the 1-year default), scope it to a single Access application that only exposes a
`/recover` route, alert on every use, and rotate it after every use.

---

### [MAJOR] The Worker's Nomad token is root on every node, and the document never says which capabilities it holds

**Where:** `docs/08-threat-model.md:12-13`, `docs/08-threat-model.md:64-65`;
`docs/01-architecture.md:144-145`

**Claim under attack:** "The Nomad ACL token, the Incus client certificate, the SeaweedFS admin
key. Each is cluster-wide." (`08:12-13`)

**Why it fails:** "Cluster-wide" undersells it. Nomad's ACL documentation lists the capabilities
implied by `policy = "write"` as `list-jobs parse-job read-job submit-job dispatch-job read-logs
read-fs alloc-exec alloc-lifecycle …`
(<https://developer.hashicorp.com/nomad/docs/other-specifications/acl-policy>, fetched
2026-10-29>). So a token that can do what the Worker needs — submit a job, read a log, stop a job
— also carries `alloc-exec` ("connect and run commands in running allocations") and `read-fs`
("the filesystem of allocations … viewed"). `01:144-145` sells the fact that "the servers proxy
`/v1/client/fs/logs` and `/v1/client/allocation/<id>/exec`" as a *feature* — "you do not need to
expose 4647 or 4648". It is also a design statement that the Worker's credential can exec into
every allocation on the fleet. Add job submission itself: an arbitrary Nomad job spec is
arbitrary code on the node, and the document's `allow_privileged = false` (`03:74`) closes one
door while leaving `raw_exec` and host-volume mounts open.

**What to do instead:** Do not use `policy = "write"`. Use an explicit capabilities list —
`["list-jobs","parse-job","read-job","submit-job","read-logs","alloc-lifecycle"]` — and never
grant `alloc-exec`, `alloc-node-exec` or `read-fs` to the manager. Run the Worker's jobs in a
dedicated namespace with a quota, and disable `raw_exec` and `host_volume` writes for that
namespace. Then state the residual plainly: the manager's Nomad credential is RCE-on-the-fleet,
and treat it accordingly.

---

### [MAJOR] Unbounded `timeout_s` and `expires_s`

**Where:** `spec/openapi.yaml:139`, `spec/openapi.yaml:302`

**Claim under attack:** "timeout_s: { type: integer, default: 2700 }" and
"expires_s: { type: integer, default: 900 }"

**Why it fails:** Neither has a `maximum`, and the same file bounds `limit` at 200
(`spec/openapi.yaml:111`) — so this is an oversight, not a philosophy. `04:142` promises a "45
minute ceiling" enforced by the supervisor; the API lets the caller ask for `timeout_s:
100000000`. A CI token can therefore pin every CI node indefinitely — a capacity denial of
service against the scheduler, from the credential with the weakest supposed scope. `expires_s`
is worse in kind: a presigned URL minted with a decade-long expiry outlives any revocation of
the caller's token, so the "revoke on the substrate" path (`01:253`) cannot take it back.

**What to do instead:** `timeout_s: maximum: 3600` (and reject rather than clamp, so the caller
learns). `expires_s: maximum: 3600`, plus a per-actor rate limit on presign. And state that
revocation does not revoke outstanding presigned URLs, so their TTL is the real revocation
latency.

---

### [MINOR] The DO is not a trust boundary in either direction

**Where:** `docs/07-control-plane.md:130`, `docs/08-threat-model.md:142-143`

**Claim under attack:** "The DO per node means one noisy node degrades one object, not the
fleet." (`08:143`)

**Why it fails:** The DO separates *billing and blast radius for load*, not *authority*. Every
DO in the Worker is reachable by the same Worker code via `idFromName`, so a bug in the id
derivation is a cross-node authorisation bypass, and there is no per-DO authorisation at all.
More concretely, `07:130` stores the node's "long-lived node token in the DO" — so the DO is a
credential store, and it inherits the Worker's and the account's compromise surface. A DO's
SQLite is encrypted at rest under Cloudflare-managed keys, which means account compromise reads
every node token; that is the same finding as the account blast radius, one layer down.

There is also an internal contradiction worth flagging under this heading: `08:141` says
"Heartbeats are alarm-driven at a fixed interval, not client-driven", but `04:186-188` says "the
supervisor renews it every 30 s over the tunnel" — that is client-driven. `07:96` marks
`heartbeat()` "alarm-driven, 30 s" while `07:98` has `renewLease` called by the client. The DoS
mitigation as stated does not describe the system.

**What to do instead:** Say what the DO is: a live-state cache with no authority. Store node
tokens in a dedicated secret store keyed per node (or, better, don't store long-lived node
tokens at all — use short-lived signed assertions derived from the node's keypair). Make the
heartbeat/lease direction explicit and fix whichever sentence is wrong.

---

### [MINOR] Build logs are attacker-controlled content rendered in an authenticated operator's browser

**Where:** `docs/07-control-plane.md:97`, `docs/01-architecture.md:213`;
`docs/08-threat-model.md:93`

**Claim under attack:** "async streamLog(jobId: string, cursor: string) { ... } // SSE fanout"

**Why it fails:** A PR can print `<img src=x onerror=…>`, ANSI escapes, or a markdown link into
its build log. Those bytes are fanned out by the DO and rendered in the "live log tail"
(`07:168`). `08`'s only XSS mention is framed as a defect in the SPA's own source; it never
considers that the *content* is attacker-supplied. CSP is the only line of defence, and it is
one config typo deep. The logs also land in R2 (`01:214`), which per `00` has no bucket policies
and no ACLs — so log confidentiality rests entirely on R2 API-token hygiene, with no per-repo
scoping.

**What to do instead:** Render logs as text nodes only, never as HTML or markdown; disable ANSI
interpretation or use a parser that emits spans with a fixed class set. Add a test that pushes a
log line containing `<script>` and asserts it appears literally. Put per-repo prefixes on the R2
log keys and scope read paths accordingly.

---

### [MINOR] `Idempotency-Key` has no actor scope

**Where:** `spec/openapi.yaml:124-127`, `spec/openapi.yaml:213`, `spec/openapi.yaml:323`

**Claim under attack:** "Every mutating call takes an idempotency key." (`07:73-74`)

**Why it fails:** The key is a bare header with no stated uniqueness domain. If the Worker stores
it globally, actor A submitting `Idempotency-Key: 1` and actor B submitting `Idempotency-Key: 1`
collide, and the second caller receives the first caller's `Job` object — which contains `repo`,
`ref`, `artifacts[].key` and `sha256` (`spec/openapi.yaml:431-436`). That is a cross-tenant read
through a retry, and it is the kind of thing that only shows up when a CI system retries under
load, i.e. exactly when nobody is watching.

**What to do instead:** Key idempotency on `(actor_id, endpoint, key)`, document it in the
description, and return `409` on a body mismatch rather than replaying the stored response.

---

### [MINOR] `install.sh` is fetched and executed with no integrity check

**Where:** `docs/01-architecture.md:80`

**Claim under attack:** "curl -fsSL https://cfb.example/install.sh | sh -s -- --token <token>"

**Why it fails:** This is a root-privileged installer piped directly from the same origin the
Cloudflare account controls. There is no digest, no signature, no version pin. The supply-chain
attack at `08:105-115` covers container images, npm packages and rootfs builds; it does not cover
the single script that every node runs as root. A one-line change to that file — reachable by
anyone who can deploy the Worker — is a fleet-wide rootkit delivered by your own documented
procedure, and TLS does not help because the server is the attacker.

**What to do instead:** Serve a versioned installer with a published SHA-256, verify before
execution, and sign it. Better: make the installer a package (deb/rpm/`apt` repo with signed
metadata) so the trust root is a signing key you control, not an HTTPS endpoint.

---

### [MINOR] `heartbeat(addr)` stores a node-supplied address that is echoed to the dashboard

**Where:** `docs/07-control-plane.md:96`; `spec/openapi.yaml` (`Node.overlay_addr`)

**Claim under attack:** "async heartbeat(addr: string, load: Load) { ... }"

**Why it fails:** The node supplies its own address and the Worker persists it as
`Node.overlay_addr`, which the SPA renders and links. A rogue or compromised node can set it to
anything — a `javascript:` URL, or an internal host it does not own. If any later code path (a
"open Grafana for this node" link, a health poll) dials it, that is stored SSRF. It is not a
current exploit because nothing in the spec dials it, but it is a loaded gun.

**What to do instead:** Derive the address server-side from the node's enrolled key, or validate
it against the expected overlay CIDR on write and reject anything else.

---

### [NIT] The plane-2 sequence diagram puts Nomad on the gateway host

**Where:** `docs/02-connectivity.md:47`

**Claim under attack:** "T->>S: http://127.0.0.1:4646/v1/jobs"

**Why it fails:** The gateway host is meant to run "cloudflared and the relays, nothing else"
(`02:155`, `08:155`). `127.0.0.1:4646` is only reachable if Nomad is co-located. The text two
lines above uses `10.96.0.5:4646`, an overlay address, which is the actual model. The diagram
matters because it is the one a reader will copy into a config, and copying it puts a Nomad
server on the most exposed host in the design.

**What to do instead:** Fix the diagram to the overlay address.

---

### [NIT] The headscale preauth-key lifetime is unstated — and the defaults happen to be right

**Where:** `docs/11-roadmap.md:45`

**Claim under attack:** "Every machine enrolled, with preauth keys minted by the API"

**Why it fails:** Not a defect today: headscale's default is safe — "By default, the key is
valid for one hour and can only be used once"
(<https://headscale.net/stable/usage/getting-started/>, fetched 2026-10-29>). But the document
never says so, and an operator who has to re-enrol a node that lost its state will reach for
`--reusable`, at which point every key minted by the API is a permanent fleet-wide skeleton key.
`08:190` argues that "every serious risk in this design is a default" and then fails to write
down the two defaults that protect the overlay.

**What to do instead:** One sentence: preauth keys are single-use, one hour, tagged per node,
and `--reusable` is forbidden in the API's minting code.

---

## What the document gets right

- **`cloudflared`'s auto-update restart.** I expected Attack 10 to be folklore. Cloudflare's own
  docs confirm it: *"Updates will cause `cloudflared` to restart which will impact traffic
  currently being served."* (<https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/update-cloudflared/>,
  fetched 2026-10-29). The mitigation — pin and disable auto-update on the gateway — is correct.
- **SeaweedFS S3 authentication being off by default.** I expected this to be an exaggeration
  that only applied to old versions. The `weed/s3api` package documentation states that
  authorisation "Returns `s3err.ErrNone` when allowed **or when auth is disabled**"
  (<https://pkg.go.dev/github.com/seaweedfs/seaweedfs/weed/s3api>, fetched 2026-10-29>) — auth
  disabled is a reachable, silent code path, exactly as Attack 1 describes.
- **The three-plane rule buys what it claims for availability.** I expected "your fleet keeps
  running during a Cloudflare outage" to be untrue once the manager is the only writer of state,
  but `02:180-190` is right: the substrates own reality, D1 owns intent, and the reconciler
  corrects in the safe direction. The claim is sound for outages. It is the *compromise* case
  that the rule does not cover.

---

## Unanswered questions

- What Nomad ACL **capabilities** does the Worker's token actually hold? `08:12-13` says
  "cluster-wide" and stops. If it is `policy = "write"`, it includes `alloc-exec`.
- Who may call `POST /nodes/enroll`, is there a cap, and is there any second-person approval for
  a token whose `roles` can include `server` or `gateway`?
- Where does the tunnel token live on the gateway host, with what file mode, and is it in the
  systemd unit's `ExecStart` (i.e. world-readable in `/proc`)?
- Is D1 backed up? What is the audit log's RPO, and what is the restore procedure after an
  accidental `DELETE` or an account compromise?
- Does the dashboard render build logs as HTML or markdown anywhere, and with what escaping?
- Is the relay reachable from the tunnel ingress by path (i.e. can a compromised Worker
  `fetch("http://gateway:8080/1.0/instances")` directly), and what authenticates that call?
- Does `install.sh` verify a digest, and is the path that serves it writable by the same deploy
  that serves the SPA?
- Does the Worker hold one SeaweedFS admin key for all purposes, or one scoped user per bucket
  purpose? `07:194` names a single `SEAWEEDFS_ADMIN_KEY`.
- What is the retention and access policy for build logs, which routinely contain repository
  contents, environment dumps and sometimes credentials?
- What happens to a node's long-lived token and its overlay identity when the machine is
  re-imaged, and is there a bulk-revoke path?
