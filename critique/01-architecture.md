# Architecture critique — cfb, revision 1

## Verdict

The design is salvageable, but its two load-bearing claims are both wrong: the cost model
that justifies the whole exercise is off by a factor of twelve, and the "orchestration is not
Cloudflare" premise is false in the only sense that matters, because the Worker holds
cluster-root credentials for every substrate inside a third-party account. Strip the
dogma — the six-system stack is four systems too many, and the three-plane rule delivers two
of its three stated benefits while costing you an entire extra distributed system — and what
remains (Nomad + cloudflared + an object store, with the scheduler off Cloudflare) is sound
and worth building.

---

## Findings

### [BLOCKER] The cost model is off by 12× — an annual labour figure is used as a monthly one

**Where:** `docs/09-cost.md:37`

**Claim under attack:** `labour     0.5 FTE × $128,869 loaded / 54.6 nodes    = $1,180`

**Why it fails:** $128,869 is the loaded cost of *one* FTE per *year*
(`docs/09-cost.md:143`: "Loaded labour | $128,869/yr"). Half of it, divided by 54.6 nodes,
is **$1,180 per node-year**, i.e. **$98.34 per node-month**. The document uses $1,180 as a
node-month. Labour is therefore overstated 12×, and labour is the term the document itself
calls "the single dominant term" and reports as 48% of node-month.

Every downstream number moves:

| | document | corrected |
|---|---|---|
| node-month | $2,443 | $1,361 |
| cost per container-month | $114.50 | $63.80 |
| break-even duty cycle | 39.1% | **21.8%** |
| Cloudflare at the doc's own 24% duty | $70.26 | $70.26 |
| cheaper at 24% duty | Cloudflare by 38% | **owned metal by 9%** |

So `docs/09-cost.md:54` — *"A CI fleet at 8 hours × 22 weekdays is 24% duty. At 24% the
Cloudflare equivalent is $70/month against $114.50 owned — Cloudflare is 38% cheaper"* — is
false on the document's own inputs, and inverts the headline of the README
(`README.md:108-109`: *"self-hosting only beats Cloudflare above roughly a 40% sustained duty
cycle, and the break-even is set by labour, not by electricity"* — it is set by labour, and
the labour arithmetic is the part that is wrong). The
document also contradicts itself internally: the fleet table at `docs/09-cost.md:119` charges
labour correctly at ~$5,400/month for 11 nodes (~$491/node-month), a third figure that agrees
with neither.

This is not a defensible choice I disagree with. It is arithmetic.

**What to do instead:** recompute with `0.5 × 128,869 / 54.6 / 12 = $98.34`. Then decide
which story you are telling, because the corrected break-even (~22%) *strengthens* the case
for self-hosting and destroys the "this is a capability purchase, not a cost play" framing
that the entire document leans on to excuse its complexity. If you still want the
capability framing, argue it on the 4 vCPU ceiling and the Sandbox lifetime — both real —
and stop claiming self-hosting loses on price at CI duty cycles.

---

### [BLOCKER] "Orchestration is not Cloudflare" is false: the Worker is the cluster root

**Where:** `README.md:25-26`, `docs/07-control-plane.md:3`, `docs/07-control-plane.md:132`

**Claim under attack:** *"Orchestration is not Cloudflare. Cloudflare may carry the control
connection. It must never be the scheduler, the consensus layer, or the data path between
machines."*

**Why it fails:** read the list carefully. It excludes scheduler, consensus, and data path.
It does not exclude *authorisation*. And `docs/07-control-plane.md:132` then puts the Nomad
ACL token, the Incus client certificate, the SeaweedFS admin key and the celld token in one
Worker — `docs/07-control-plane.md:3`: *"holds the only credentials in the system."*

Concretely: an attacker who obtains the Cloudflare account — a stolen API token from a
laptop, a support-engineering insider, a lawful request to Cloudflare, or simply an account
suspension — gets a Worker that can `POST /v1/jobs` with an arbitrary job spec, i.e. run
arbitrary code on every Nomad client in the fleet, and can reach every substrate API
through the VPC binding. The substrate ACLs do not help: the Worker is the one principal they
were written for. The design has moved the scheduler off Cloudflare and left the *authority
to command the scheduler* on Cloudflare, which is the same dependency with a thinner
euphemism.

`docs/08-threat-model.md` enumerates ten attacks and not one of them is "the Cloudflare
account". Attack 5 is an XSS in the SPA exfiltrating secrets — that is a *path to* the
compromise, not the compromise. There is no consideration anywhere in the corpus of account
takeover, insider access, or legal process against the control plane; `jurisdiction`,
`subpoena` and `insider` appear zero times across `README.md` and `docs/`.

**What to do instead:** decide which of two things you mean and write it down.
(a) If Cloudflare must not be able to command the fleet, the Worker must hold *no* substrate
credential that can execute work — it should hold a token that can only *enqueue intent*
(e.g. a Nomad ACL policy scoped to `submit-job` on one namespace, plus a per-job
unseal/approval step that requires a signature the Worker does not possess). (b) If it is
acceptable for Cloudflare to command the fleet, delete the constraint from the README and
price the risk explicitly, because it is the single largest risk in the design and it is
currently unlisted. Option (a) is implementable — Nomad ACL policies are per-namespace and
per-capability — and it is the only version of the premise that is true.

---

### [BLOCKER] Untrusted microVMs are required to reach the overlay, which Phase 5 forbids

**Where:** `docs/01-architecture.md:120` vs `docs/11-roadmap.md:101`

**Claim under attack:** `F->>S: pull image layers / push artifacts (overlay, plane 3)` —
against the Phase 5 acceptance criterion *"an untrusted build runs with no route to the
node's overlay address or the Nomad client API."*

**Why it fails:** SeaweedFS's S3 gateway is an overlay service. `docs/01-architecture.md:16`
puts `seaweedfs` on every storage node with `8333` as the S3 gateway, and
`docs/05-storage.md:94` says the gateway is *"reached over the overlay only"*. So a microVM
that pulls image layers and pushes artifacts over the overlay **has a route to the overlay**.
The two statements cannot both hold. Either:

- the microVM has an overlay address (via the tap device and a tailnet identity), in which
  case Phase 5's "done when" is unsatisfiable and the isolation claim in
  `docs/04-compute.md:18` — *"anything you did not write runs in a microVM"* — is guarding a
  host that is reachable from inside the microVM; or
- it does not, in which case it cannot pull its own image and the Flow 2 diagram is fiction.

This matters because the whole point of the microVM is `docs/08-threat-model.md:56` — a CI job
that *"escapes its container, and reaches the node's overlay address, the Nomad client API,
or another job's build cache."* The design hands the untrusted workload the overlay on
purpose and then asserts it has no route to it.

**What to do instead:** the supervisor pulls the image and pushes the artifacts; the microVM
never speaks to SeaweedFS. Give the microVM a per-job tap with exactly one egress rule to a
per-job local cache proxy on the host (or a loopback vsock to the supervisor), and make the
Phase 5 test explicit: *from inside the microVM, `curl` to 100.64.0.0/10 and to the Nomad
client port both fail.* Write that test down as the acceptance criterion, because right now
the criterion and the sequence diagram contradict each other and a reviewer will believe
whichever they read first.

---

### [MAJOR] headscale's default relay path routes Raft through Tailscale Inc — the exact failure the design forbids

**Where:** `docs/02-connectivity.md:135-137`, against `docs/03-orchestration.md:155-159`

**Claim under attack:** *"It depends on Tailscale Inc's DERP fleet out of the box for relay
when direct NAT traversal fails. Run your own DERP if you care; DERP forwards WireGuard
ciphertext it cannot read, so a third-party relay is a privacy question, not a
confidentiality one."*

**Why it fails:** the framing is wrong, and the wrongness is fatal to the scheduler. The
document elsewhere states the rule this violates, at `docs/03-orchestration.md:155-159`:

> *"If Nomad's Raft peers reach each other over Cloudflare … a Cloudflare incident can cost
> you quorum; your scheduler's availability is the product of your availability and
> Cloudflare's."*

Swap "Cloudflare" for "Tailscale" and the sentence still holds — and this is the *default*
configuration. headscale's shipped `config-example.yaml` sets `derp.server.enabled: false`
and `derp.urls: [https://controlplane.tailscale.com/derpmap/default]`
(<https://raw.githubusercontent.com/juanfont/headscale/main/config-example.yaml>, verified
2026-10-29). Tailscale's own documentation confirms DERP is the fallback *"when a direct
connection isn't possible"* and that a DERP server *"blindly forwards already-encrypted
traffic"*
(<https://tailscale.com/kb/1232/derp-servers>, verified).

Now apply the design's own premise: `docs/01-architecture.md:95` promises the installer works
*"behind CGNAT and on a residential connection"*, and `docs/02-connectivity.md:127` justifies
headscale over plain WireGuard precisely because *"you will have nodes behind CGNAT."* CGNAT
is the case where direct NAT traversal fails. So the design's stated deployment target is
exactly the case where Nomad Raft and SeaweedFS replication fall back to a relay operated by
a company the design never mentions in its threat model. `docs/03-orchestration.md:161`
insists *"Put the three servers on the overlay, in one site or in sites joined by a real
network path. Never across the tunnel."* — but the overlay **is** a third party's relay in
the default configuration. The three-plane rule's "blast radius" pillar is not implemented;
it is delegated, silently, to Tailscale.

It is also a latency problem, not just an availability one: a DERP relay is an HTTPS/TCP hop
with a region chosen by *nearest to the client*, so three Nomad servers in three cities can
all relay through one DERP region, adding a WAN round trip to every Raft append — the exact
cost `docs/02-connectivity.md:102` cites as the reason Raft must not cross Cloudflare.

**What to do instead:** enable `derp.server` on the gateway hosts (headscale supports an
embedded DERP server — `config-example.yaml`, `derp.server.enabled`) and set `derp.urls` to
your own map, or accept DERP only for plane-2 control traffic and hard-deny it for the Nomad
ports via ACLs. Then say so in `docs/00-constraints.md` next to the Mesh 50-node row, because
"the overlay is a third party" belongs in the same table as "Cloudflare Mesh caps at 50
nodes." As written, a reader believes plane 3 is peer-to-peer; by default it is not.

---

### [MAJOR] "One cloudflared per site" breaks the plane-2 topology at every site count above one, and the fix was rejected on a misapplied limit

**Where:** `docs/02-connectivity.md:147-153`, `README.md:35`

**Claim under attack:** *"**One `cloudflared` per site, not per machine.** … `vpc_networks`
binds the *network*, so new machines behind the same gateway need no Cloudflare-side change
at all."*

**Why it fails:** `vpc_networks` does not bind "the network". It binds *one* of three
concrete things, and the doc's own wrangler snippet gets the field name wrong
(`docs/02-connectivity.md:61`: `"network_id": "<mesh-or-tunnel-id>"` — a tunnel is bound by
`tunnel_id`; `network_id` accepts the Mesh sentinel `cf1:network`). See
<https://developers.cloudflare.com/workers-vpc/configuration/vpc-networks/> (verified).

That distinction is the whole finding:

- **Bind by `tunnel_id`** → one binding per tunnel, i.e. per site. The document admits the
  consequence at `docs/02-connectivity.md:82-84` — *"Adding a new site means a Worker
  redeploy"* — and then does not draw the obvious conclusion.
- **Bind by `network_id: "cf1:network"`** → one static binding that reaches *"private services
  across multiple Cloudflare Tunnels"*, no redeploy ever, and automatic use of whichever
  tunnel can reach the target.

So here is what actually breaks, concretely:

- **2 sites.** Two bindings, two config entries, two redeploys over the project's life. Fine.
  But note the failure mode that already exists: if both connectors at site A die, the
  `SITE_A` binding fails, and the Worker *cannot* retry through `SITE_B` — even though site
  B's gateway is on the same headscale tailnet and can route to site A's `10.96.0.11`
  perfectly well. Nothing in the design does that retry. You have built two independent
  control paths and wired them as two independent single points of failure.
- **5 sites.** Five bindings hard-coded in `wrangler.jsonc`. Every site addition is a
  **global** Worker redeploy — the same artefact that serves all five sites. Adding site five
  is a change whose blast radius is sites one through four, during an operation (bringing up
  a site) when you least want one.
- **20 sites.** Twenty bindings, forty connectors, twenty tunnels, and `docs/10-failure-modes.md:200`
  (*"Tunnel connector count — expect 2 per site; alert at 1"*) becomes twenty separate alerts
  with no aggregation, against a dashboard that is itself reached through one of them.

And the stated justification does not survive arithmetic. `docs/02-connectivity.md:149`:
*"Tunnels cost $4.50/month past 1,000, and 1,000 sounds like a lot until every CI worker wants
its own."* One tunnel per machine at 200 machines is 200 tunnels: **$0**. The free tier is
1,000 tunnels per account
(<https://developers.cloudflare.com/cloudflare-one/account-limits/>, verified: "cloudflared
tunnels per account | 1,000"). The cost argument is dead at every scale this document
contemplates; the real argument (*"one process to monitor, one config to rotate"*,
`docs/02-connectivity.md:151`) is a different and much weaker one.

**What to do instead:** two changes. (1) Bind **once**, to `cf1:network`, and run Cloudflare
Mesh *only on the gateway hosts* — the 50-node cap is on Mesh nodes, which are hosts running
the Cloudflare One Client
(<https://developers.cloudflare.com/cloudflare-one/account-limits/>: "Mesh nodes per account
| 50"; <https://developers.cloudflare.com/mesh/>: "Mesh nodes run the Cloudflare One Client in
headless mode on Linux"). Two gateways × 20 sites = 40, under the cap, and the fleet's 200
workload nodes never touch Mesh at all. `README.md:36` rejects Mesh with *"Cloudflare Mesh
caps at 50 nodes"* — true of the *fleet*, irrelevant to the *gateways*, and the conflation
costs you a static, self-healing plane 2. (2) Whether or not you take (1), make the Worker
iterate over its bindings on failure and treat them as interchangeable paths to one overlay,
because that is what they are. Then a site's tunnel outage is a latency blip, not a blind
spot.

Note also that "site" is never defined anywhere in the corpus. Is a developer's home CI box
behind CGNAT a site? If yes, the "one gateway host, redundant, boring" model collapses the
first time someone wants a runner at home. Define the unit before you parameterise the
topology on it.

---

### [MAJOR] The three-plane rule buys two of its three stated benefits; the third is dogma that costs you headscale

**Where:** `README.md:80-86`

**Claim under attack:** *"This plane never touches Cloudflare, for three reasons: latency,
blast radius, and the fact that Cloudflare Tunnel carries no UDP."*

**Why it fails:** the UDP reason is real and decisive — verified, Workers VPC requires QUIC
on the tunnel and Tunnel public hostnames carry no UDP
(<https://developers.cloudflare.com/workers-vpc/configuration/tunnel/>). The latency reason
is real. The **blast radius** reason is not delivered by anything in the design, and that is
the one the document uses to justify the overlay.

Blast radius requires a boundary. The design has none. `docs/02-connectivity.md:155-157`
puts `cloudflared` and the relays on the gateway host and says it *"is a choke point by
design."* A choke point that is also a full tailnet member with unrestricted reach to every
other node is not a choke point, it is a door. `docs/08-threat-model.md:150-155` concedes
this outright: *"If the gateway host is compromised, the attacker has a route into the private
network that looks like legitimate Cloudflare traffic."* And the ACL that would fix it is
specified, in the roadmap, as the opposite: `docs/11-roadmap.md:46` — *"ACLs: nodes can reach
the substrate APIs **and each other**, nothing else."* "And each other" is the negation of
plane separation.

So the rule as written costs you headscale — a second NAT-traversal system, a second
credential store, a second upgrade cadence, a second failure domain, one maintainer, and (per
the previous finding) a default path through a third party — and in exchange delivers latency
and UDP, both of which you could have had by simply not putting Raft through the tunnel. The
blast-radius benefit, the one that makes the rule sound like architecture rather than
etiquette, is not implemented.

**What to do instead:** keep the rule, but implement it as a *trust* boundary rather than a
*transport* taxonomy, and make the ACL the deliverable. Tag the gateway hosts separately in
headscale and give them reach only to the relay ports and the three substrate APIs; give
workload nodes no route to each other except the specific peer ports (4647/4648 to the three
servers, 19333 to the volume servers). Write that ACL into `docs/02-connectivity.md` as
normative, with the `tailscale`/headscale policy file inline, and change the Phase 2
acceptance test from "two machines can talk to each other" to "a gateway host cannot reach
a SeaweedFS volume server's replication port, and a CI node cannot reach another CI node's
supervisor." Then the rule is a fact rather than a claim, and it is worth the overlay.

---

### [MAJOR] The DO-per-node model is keyed on the wrong object — 200 DOs is fine, the lease isn't

**Where:** `docs/07-control-plane.md:82`, `docs/01-architecture.md:116`

**Claim under attack:** *"One DO per node. It is the node's live state and its command
channel."* and, in Flow 2, `W->>D: allocate attempt (idempotency key)`.

**Why it fails:** on the question the brief asks — does this work at 200 nodes — the answer is
yes, and the document is right about why (see "What the document gets right"). 200 Durable
Objects is nothing, and an alarm-driven heartbeat every 30 s hibernates between firings, so
duration billing is a rounding error. The model fails for a different reason: **the unit of
design is the node and the unit of work is the job, and they do not line up.**

Flow 2 has the Worker allocate the attempt against a *node* DO at
`docs/01-architecture.md:116`, *before* it submits to Nomad at line 117 and before Nomad has
chosen a node at line 118. At the moment of allocation there is no node. The diagram is not
implementable as drawn. The idempotency record has to be global (keyed on the client's
`Idempotency-Key`, which `spec/openapi.yaml` already requires on `POST /jobs`), so it belongs
in D1 or in a job DO, not in a node DO.

The consequences compound at scale, and this is where 200 nodes actually hurts:

1. **Reschedule orphans the lease.** `docs/04-compute.md` sets `reschedule { attempts = 2 }`
   and `docs/10-failure-modes.md:127` says *"Nomad will reschedule the job onto another node,
   which is the correct behaviour."* When that happens, the lease lives in node A's DO
   (`leases: Map<string, {jobId, expiresAt}>`, `docs/07-control-plane.md:91`) and node B's DO
   never learns it holds the job. The lease either expires and the job is *"reported stale"*
   (`docs/04-compute.md:173`) while it is actually running, or it never existed and nothing
   renews it. At 5 nodes with a handful of retries you can paper over this by hand; at 200
   nodes with constant preemption you cannot.
2. **The fleet view is N DO calls per page.** `GET /api/v1/nodes` has to fan out to every DO
   to build a health list. At 200 nodes that is 200 RPC sessions per refresh, each a billed
   request (`docs/00-constraints.md` already counts requests at $0.15/M; at a 5 s poll this
   is ~3.5M/day). Not fatal, but the design claims the DO is the *cheap* choice and never
   does this multiplication.
3. **`sockets: WebSocket[]` is in-memory and "rebuilt on wake"** (`docs/07-control-plane.md:94`).
   Eviction drops every operator's log stream, and the reconnect path is a cursor resync
   against a job whose lease may have moved. The failure is silent from the operator's side.

**What to do instead:** split the key space. One DO **per job** (or a sharded lease DO keyed
by `hash(job_id)`) owns the lease, the idempotency record, and the log cursor — because those
are properties of the job, not the machine. Keep a per-node DO only for the thing that is
genuinely per-node: liveness, load, and drain state, where the worst case of a lost message is
a stale health dot. Then make the submit path `POST /jobs → job DO (idempotency + lease) →
Nomad → job DO observes the allocation`, and fix the sequence diagram at
`docs/01-architecture.md:115-125`, which currently allocates against an object that does not
yet exist.

---

### [MAJOR] Six systems where two would do — and the document's own evidence removes one of them

**Where:** `README.md:115`, `docs/05-storage.md:16`, `docs/05-storage.md:40-50`

**Claim under attack:** *"The full stack is six systems. Most people need one."*

**Why it fails:** it is not that six is too many in the abstract. It is that five of the six
are either conditional in the document's own text or justified by evidence the document
itself refutes, and the sixth (Nomad) is the only one doing work no other component can do.

- **SeaweedFS** exists because celld needs a CAS store. But the document's own matrix at
  `docs/05-storage.md:40-50` lists **Cloudflare R2 as qualifying** ("`If-None-Match: *` yes,
  `If-Match: <etag>` yes, qualifies"), and `docs/05-storage.md:16` concedes it: *"Either keep
  a small R2 bucket for celld, or use SeaweedFS."* So the one requirement that motivated the
  entire storage document is satisfied by the product the document is trying to replace. The
  real driver for SeaweedFS is egress and object-lock, both of which `docs/05-storage.md:13-15`
  says are conditional ("Egress is the bill", "You need object lock") — not the celld path.
  That is a legitimate reason to offer SeaweedFS as an *option*; it is not a reason to make it
  one of the six pillars.
- **Incus** exists to create VMs from the dashboard (`docs/07-control-plane.md:54-58`). Neither
  target workload — "heavy CI" and "long-running containers" (`docs/00-constraints.md:10-17`)
  — requires creating machines on demand. `docs/03-orchestration.md:3` states the boundary
  correctly ("Nomad creates zero machines") and then treats provisioning as a first-class
  layer anyway. `docs/11-roadmap.md:155` even lists Incus as the second thing to cut, which
  is the document admitting it is optional.
- **Firecracker** is a 4–6 week build (`docs/04-compute.md:59`) whose only justification is
  that `postinstall` scripts are untrusted. gVisor (`runsc`) under Nomad's existing `docker`
  driver gets you a separate user-space kernel for untrusted code in an afternoon, with a
  weaker but real boundary, and `docs/04-compute.md:20` already concedes the rule is a
  judgement call ("anything you did not write"). Firecracker is the right answer for
  *multi-tenant*; the document declares multi-tenancy out of scope at
  `docs/08-threat-model.md:176`.
- **headscale** is required only above 50 nodes or across more than one site —
  `docs/11-roadmap.md:156` says so: *"only if you have fewer than 50 machines and one site,
  where Cloudflare Mesh is genuinely adequate."*
- **celld** is explicitly optional and last (`docs/06-edge-runtime.md:138`).

**What to do instead:** state the minimal correct architecture and make the tiers derive from
it rather than from a feature checklist:

> **Nomad (1 or 3 servers) + `cloudflared` + R2.** Nomad runs the batch and service jobs;
> R2 holds artifacts, caches, logs and — if you want celld — the fleet bucket, because it
> qualifies for CAS. Add gVisor if some jobs are untrusted. Add headscale only when you
> exceed one site or 50 nodes. Add SeaweedFS only when egress or object-lock actually bills.
> Add Incus only when "create a VM from the UI" becomes a real request.

That is **three systems**, one of which you already pay for, and it covers both stated
workloads. Everything above it is an option with a named trigger, not a pillar. The document
already believes this — Tier 0 at `README.md:118-128` is exactly this architecture — and then
builds a Tier 2 that treats the optional extras as the "full" design, which is how a
three-system project becomes a ten-to-fourteen-week one (`docs/11-roadmap.md:142`).

---

### [MAJOR] The audit log has a hard 10 GB ceiling, no retention rule, and is the only copy

**Where:** `docs/07-control-plane.md:65`, `docs/01-architecture.md:254`

**Claim under attack:** `GET /api/v1/audit  D1, append-only`

**Why it fails:** D1's maximum database size is **10 GB and it cannot be raised** —
*"Maximum database size | 10 GB (Workers Paid) … Note that the 10 GB limit of a D1 database
cannot be further increased"*
(<https://developers.cloudflare.com/d1/platform/limits/>, verified 2026-10-29). D1's own
guidance is to shard across many small databases, which the document never contemplates.

An append-only table in a fixed 10 GB database is a table with a scheduled outage. There is no
retention rule for it anywhere: `docs/05-storage.md:193-198` gives careful retention for
*buckets* (14 days cache, 90 days artifacts) and gives D1 nothing. There is no export path,
no archival to R2, and no second copy. When the table fills, writes fail — and because the
same database holds node inventory and job history, "the audit table filled up" takes out the
whole control plane, not just the audit trail.

Worse, "append-only" is a comment, not a control. The Worker holds the D1 binding and can
`UPDATE` and `DELETE`; `docs/08-threat-model.md:17` ranks *"The audit log. Integrity matters
more than confidentiality"* and then the design stores it in the one place the trusted
component can rewrite at will. The substrate cannot corroborate it either: every substrate
sees exactly one principal, the Worker (`docs/07-control-plane.md:132`), so Nomad's and
Incus's own logs say "the Worker did it" for every action ever taken.

**What to do instead:** three things. (1) Make the audit log append-only *by construction*:
write each entry to R2 as an immutable object with a monotonically increasing key (or a hash
chain, `prev_hash` in each record), and keep only an index in D1 — R2 has no 10 GB database
limit and object lock is available
(`docs/05-storage.md:165`: *"Object lock / WORM | no | yes (SeaweedFS)"* — R2 itself does not
do WORM, so a hash chain is the cheap substitute). (2) Give the table a retention rule and a
nightly export, and put the retention next to the bucket table in `docs/05-storage.md` so it
is not the one table in the document without one. (3) Propagate the operator's identity to
the substrate — Nomad ACL tokens are per-principal, so mint one token per operator rather than
one for the Worker — or stop claiming the substrate has an audit trail at all.

---

### [MAJOR] "Replace CI" is false: no GPU, no arm64, no macOS, no Windows

**Where:** `docs/04-compute.md:10-16`, `docs/03-orchestration.md:43`

**Claim under attack:** the isolation table offers three levels — *"Process / Container /
microVM"* — and the document's stated target is *"Heavy CI … needs a Docker daemon, needs a
large image with toolchains"* (`docs/00-constraints.md:11-13`).

**Why it fails:** `grep -ri "gpu\|arm64\|windows\|macos"` across `README.md` and `docs/`
returns **nothing**. Firecracker's machine model is VirtIO net and block plus a serial console and an
I8042 controller, with no PCI device model at all
(<https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/docs/design.md>,
verified), so there is no path to a GPU; and the sizing table at
`docs/03-orchestration.md:169-175` has columns for Role, vCPU, RAM and Disk and
nothing else. A CI product that
cannot run a CUDA build, an `aarch64` container build, or a single iOS job is not a
replacement for the CI product it is replacing — it is a replacement for the subset of that
product that happens to be x86 Linux CPU work. The document is scrupulous about the limits it
does discuss and silent about the ones that will stop adoption in week one.

This also undercuts the 2026 framing: `docs/04-compute.md:16` mentions *"agent workloads"* as
a use case for microVMs. Agent workloads increasingly want accelerators, and the compute
chapter never mentions one.

**What to do instead:** add a "What this cannot run" section to `docs/04-compute.md` listing
GPU, arm64, macOS, Windows, and nested virtualisation, with the workaround for each (GPU: bare
metal node with the NVIDIA container runtime under Nomad's `docker` driver, outside the
microVM path; arm64: a second Nomad node class with a constraint; macOS: not solvable, buy a
hosted service). Then update `README.md:143-158` so the "does not solve" list is honest about
scope, not just about cost. A spec that lists four honest non-goals is stronger than one that
silently assumes x86.

---

### [MAJOR] Cache and artifact prefixes are not a security boundary, and the threat model treats them as one

**Where:** `docs/08-threat-model.md:66`, `docs/05-storage.md:180-184`

**Claim under attack:** *"Build caches are per-job-prefix and read-only where possible."*

**Why it fails:** "prefix" and "where possible" are doing all the work. There is one S3
credential per node (or per job, from the Worker's presigner) and the buckets are flat. The
Worker mints presigned URLs for *any* key on request (`POST /buckets/{name}/presign`,
`spec/openapi.yaml`, with `key` as a free-form string and no scoping to the caller's job). A CI
job that runs `postinstall` from a stranger's pull request — which `docs/04-compute.md:20`
explicitly names as in scope — can request a presigned PUT for `cache/cargo/<other-repo>/`
and poison the build cache of a repository it does not own. The next build of that repository
executes attacker-controlled bytes *outside* the microVM, on the host, because the cache is
mounted into the job as a build input. That is Attack 6 ("the supply chain",
`docs/08-threat-model.md:105-116`) executed through a hole the design left open, and it
bypasses Firecracker entirely: the poisoned artifact is consumed by a *trusted* build.

The same applies to `cfb-artifacts`: a job can overwrite another job's artifact key, and
`docs/05-storage.md:184`'s "NEVER shared" note is scoped only to the celld bucket.

**What to do instead:** make the presigner the authorisation point. The Worker knows which job
is calling (it minted the job's token); it should sign only keys under `cache/<toolchain>/`
for the *requesting repository* and `artifacts/<job_id>/`, and it should refuse a `key`
containing `..` or a prefix it did not derive. Add a per-repo cache namespace to the bucket
layout in `docs/05-storage.md:180-184`, and change the mitigation at
`docs/08-threat-model.md:66` from a hope ("where possible") to a rule ("the presigner refuses
any key outside the caller's namespace; the cache is content-addressed so a poisoned entry
misses rather than hits"). Content addressing is the real fix here and the document already
uses it for images at `docs/05-storage.md:181`.

---

### [MAJOR] The "too small" premise rests on limits Cloudflare says are defaults

**Where:** `README.md:98`, `docs/00-constraints.md:178`

**Claim under attack:** *"A large compile does not fit."* and *"The honest reading: Cloudflare's
compute products are not too expensive for this workload. They are **too small**."*

**Why it fails:** the limits page the document cites opens with: *"All instance size maximums
and account limits on this page are defaults and can be increased. To request higher limits,
contact your account team or Cloudflare Support"*
(<https://developers.cloudflare.com/containers/platform/limits/>, verified 2026-10-29 — the
note is the first paragraph, above the instance table). The 4 vCPU / 12 GiB ceiling and the
50 GB image-storage figure are both on that page. So the "fatal, structural" verdict is one
support ticket away from being wrong, and the document presents it as physics.

I am not arguing the Sandbox lifetime problem away — that one is structural and verified
verbatim (see "What the document gets right"). But the document's own summary table
(`docs/00-constraints.md:178`) marks Containers as *"Capability problem? **fatal**"* on the
strength of a *size* limit that is explicitly negotiable, while the genuinely fatal limit
(lifetime) is listed separately and is not the one the table cites.

**What to do instead:** split the row. "Instance size: soft, negotiable, ask support — do not
architect around it until you have asked." "Instance lifetime: hard, structural, 6 h, cannot
be raised." The second is the real argument and it is strong enough on its own; leading with
the first invites a reader who has a Cloudflare account manager to dismiss the whole document.

---

### [MINOR] The binding example uses a field that does not exist for tunnels

**Where:** `docs/02-connectivity.md:61`

**Claim under attack:** `{ "binding": "SITE", "network_id": "<mesh-or-tunnel-id>", "remote": true }`

**Why it fails:** a tunnel is bound with `tunnel_id`; `network_id` is the Mesh form and the
only documented value is the sentinel `cf1:network`
(<https://developers.cloudflare.com/workers-vpc/configuration/vpc-networks/>, verified). A
reader who copies this snippet gets a config error, and — more importantly — the placeholder
`<mesh-or-tunnel-id>` is the exact conceptual muddle that produces the "one binding per site"
problem above.

**What to do instead:** show both forms side by side, name the trade-off in one sentence, and
say which one the design uses and why.

---

### [MINOR] The plane-2 diagram delivers the tunnel to loopback, contradicting the gateway host's charter

**Where:** `docs/02-connectivity.md:46` vs `docs/02-connectivity.md:155-157`

**Claim under attack:** `T->>S: http://127.0.0.1:4646/v1/jobs` — against *"The gateway host
runs `cloudflared` plus the relay services … and nothing else."*

**Why it fails:** if Nomad is on `127.0.0.1:4646`, it is on the gateway host, which the
document forbids two paragraphs later. If it is not, the origin must be the overlay address
(`10.96.0.11:4646`), and the document never says how a VPC binding resolves an overlay
address — which is the one thing a reader deploying this actually needs to know, because
headscale's `100.64.0.0/10` range is not a subnet route that Cloudflare knows about; the
gateway must route it, and nothing in the document establishes that.

**What to do instead:** pick one and draw it. If the tunnel's origin is the overlay address,
say so explicitly and add the `cloudflared` ingress stanza that reaches `10.96.0.11:4646`
through the gateway's tailnet interface, plus the ACL that permits it.

---

### [MINOR] "TLS end-to-end from the Worker is not available" is false for `fetch()`

**Where:** `docs/02-connectivity.md:76-80`

**Claim under attack:** *"`connect()` is plaintext TCP. No TLS termination inside the binding.
… TLS end-to-end from the Worker is not available."*

**Why it fails:** true of `connect()`, false of `fetch()`. VPC Services support an `https`
scheme with SNI taken from the requested hostname, trust both public CAs and Cloudflare Origin
CA, and expose a `--cert-verification-mode` of `verify_full` / `verify_ca` / `disabled`
(<https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/>, verified). So
you *can* have TLS from the Worker to the origin, and you can even run a self-signed origin.

This matters because the document uses the "no TLS" premise to justify putting the Incus
relay on the gateway and writing "a few hundred lines of Go" (`docs/07-control-plane.md:152-155`).
The *client-certificate* half of that argument is correct — mTLS really does not survive
`cloudflared`, which is why Incus needs OIDC — but the blanket TLS claim is not, and a reader
who checks it will distrust the rest.

**What to do instead:** narrow the sentence to client certificates and `connect()`, and note
that `fetch()` with `https` gives you server-authenticated TLS to the origin.

---

### [MINOR] The log path is a long-lived Worker request, which the document forbids two pages earlier

**Where:** `docs/07-control-plane.md:51` vs `docs/01-architecture.md:130-132`

**Claim under attack:** *"No long-lived Worker request. The Worker submits and returns."*

**Why it fails:** the SSE endpoint `GET /api/v1/jobs/{id}/logs` is a Worker request that stays
open for the length of a build, fed by polling Nomad through the VPC binding. That is the
definition of a long-lived Worker request. It is *permitted* — "There is no hard limit on
duration for HTTP-triggered Workers"
(<https://developers.cloudflare.com/workers/platform/limits/>, verified) — but it is bounded
by the subrequest budget: 10,000 per invocation by default, raisable to 10M via the `limits`
config. A 40-minute build polled at 10 Hz is 24,000 subrequests and blows the default in
about 17 minutes, mid-build, with the log stream simply stopping. The document mentions
neither the limit nor the knob.

**What to do instead:** either say "no long-lived *substrate* request" and keep the SSE
stream (with the subrequest limit configured and documented), or take the cheaper path the
design already has: have the supervisor write log chunks to R2/SeaweedFS and have the browser
read them with presigned ranged GETs, which needs no Worker involvement at all and survives a
Worker redeploy. The second is more consistent with `docs/07-control-plane.md:202-212`.

---

### [MINOR] No clock discipline anywhere, and the design is built on TTLs

**Where:** `docs/04-compute.md:171-174`, `docs/07-control-plane.md:91`

**Claim under attack:** *"Long jobs get a lease, not a keep-alive alarm. The Worker records a
lease with an expiry in the DO; the supervisor renews it every 30 s over the tunnel."*

**Why it fails:** `NTP` appears zero times in the corpus, and `skew` zero times. Every
liveness decision in the design is a wall-clock comparison across three administrative
domains: the DO's `expiresAt` (Cloudflare's clock), the supervisor's renewal timer (your
node's clock), the preauth key's 15-minute expiry (`docs/01-architecture.md:91`), the Access
JWT's expiry, and Nomad's own lease timers. A node whose clock is five minutes fast renews
"early" forever and never trips; one five minutes slow is reported stale on every renewal and
the operator learns to ignore the stale signal — which is the same signal that means "the
machine is actually gone" (`docs/10-failure-modes.md:60-75`).

**What to do instead:** make `chrony` part of `install.sh` with a hard failure if it cannot
reach a configured source, carry the DO's clock in the heartbeat response and have the
supervisor compute the skew and log it, and add "clock offset > 30 s on any node" to the
five monitored signals at `docs/10-failure-modes.md:196-204`.

---

### [NIT] "It is beta and free-for-now" understates what changes at GA

**Where:** `docs/02-connectivity.md:84-86`

**Claim under attack:** *"It is beta and free-for-now. Design as if it will be priced."*

**Why it fails:** the risk is not only price. The document's entire plane-2 design — one
binding per site, `vpc_networks` rather than `vpc_services`, TCP via `connect()`, the QUIC
requirement — is a beta API surface that the document itself says *"Features and APIs may
change before general availability."* A GA that changes the binding shape or drops raw
`connect()` rewrites the control plane. The fallback named (public hostname + Access service
token) is described but never scoped: it needs a hostname per site, a DNS record per site, and
an Access application per site — i.e. the per-site work the design was trying to avoid.

**What to do instead:** say which specific beta behaviours you depend on (tunnel-bound
`vpc_networks`, `connect()`, QUIC-only) and make the fallback a Phase 1 deliverable with its
own acceptance test, not "behind a feature flag."

---

## What the document gets right

- **The DO billing analysis at 200 nodes.** I expected the 30 s heartbeat loop to be a
  duration-billing disaster and it is not. Cloudflare bills duration only *"while the Durable
  Object is actively running or is idle in memory but unable to hibernate"*, and an alarm is
  not a `setTimeout`, so an alarm-driven DO hibernates between firings
  (<https://developers.cloudflare.com/durable-objects/platform/pricing/> and
  <https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/>,
  verified). The document's cost instinct here is correct and my prior was wrong.
- **The Sandbox lifetime claim is verbatim and stronger than stated.** *"Code that runs inside
  the instance does not count as activity"* is on the page word for word, the 6 h cap is real,
  and the same page adds something the document did not use: *"Cloudflare does not guarantee
  that an instance runs for a set time"*
  (<https://developers.cloudflare.com/sandbox/concepts/lifetime/>, verified). This is the one
  argument in the corpus that is unanswerable.
- **The two "gotcha" defaults are real, not folklore.** Nomad CE really does stub out quotas —
  `evaluatePlanQuota` returns `false, nil` in `nomad/plan_apply_ce.go` (verified at
  `main`) — and SeaweedFS really does start with S3 auth off: `isAuthEnabled = identityCount >
  0 || startConfigFile != ""`, with the source comment *"For 'weed mini' without any S3
  config, default to allowing all access"* (verified in `weed/s3api/auth_credentials.go`).
  Both were claims I expected to be repeated second-hand and both check out in the source.

---

## Unanswered questions

- **Where does the Worker execute relative to the tunnel, and what is the RTT budget?** There
  is no discussion of colo, region, or placement anywhere. An operator in Sydney hitting a
  Worker in SYD that opens a VPC connection to a tunnel in Frankfurt is the normal case for
  this design, and no latency figure appears in any document.
- **What is the disaster-recovery plan for D1 and DO state?** `backup` appears once in the
  corpus, as a line item in a cost table. There is no export, no point-in-time restore, no
  restore test, and no statement of what is lost if the D1 database is destroyed — even though
  `docs/01-architecture.md:218` says D1 holds *intent* and a reconciler repairs it from
  reality. Intent cannot be reconciled from reality: job history and the audit trail have no
  substrate counterpart.
- **How does an operator act during a total Cloudflare outage?** `docs/10-failure-modes.md`
  says the fleet keeps running, which is true, and that the dashboard is gone, which is also
  true. The break-glass path is a Cloudflare service token — i.e. another Cloudflare object.
  Combined with `docs/02-connectivity.md:170` (*"Never join the private network. No WARP, no
  client install."*), there is no out-of-band path to the fleet at all. Is that intended?
- **What is a "site"?** The entire topology is parameterised on a term that is never defined.
  Does a single CI box at a developer's house count? Does a rack in a colo? The answer changes
  the gateway count, the tunnel count, the binding count, and the cost model.
- **Who patches six distributed systems, on what cadence, and who is on call?** The labour
  line assumes 0.5 FTE for 54.6 nodes. Three of the six components are single-maintainer
  projects (`docs/05-storage.md:107` for SeaweedFS, `docs/02-connectivity.md:133` for
  headscale, `docs/06-edge-runtime.md:125` for celld). 0.5 FTE across three bus-factor-one
  dependencies, one of which has zero published tests, is not a staffing plan.
- **What happens at the next ceiling?** 51 Mesh nodes, 1,001 tunnels, a 10 GB D1 database,
  10,000 subrequests, 50,000 routes. Each is named as a constraint that killed some other
  design; none has a "and then we do X" attached to it.
- **Does "single-tenant" survive contact with CI?** `docs/08-threat-model.md:176` puts
  multi-tenancy out of scope, but `docs/04-compute.md:20` puts *"a pull request from a
  stranger"* in scope. Those are the same threat model with different words. Which one is
  binding?
- **Who can read the build logs?** They land in R2 (`docs/01-architecture.md:214`) and are
  served through the Worker. Build logs routinely contain secrets echoed by a failing script.
  There is no retention rule for `cfb-logs`, no redaction, and no statement of who besides the
  operator can read them — including Cloudflare.
- **What is the SLO for the control plane, and what is the operator's response when it is
  missed?** The document specifies failure *behaviour* in detail and never states a target.
