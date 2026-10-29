# Ops critique — the 3am view, two years out

## Verdict

The architecture is salvageable; the operations half of the document is not there yet.
The three-plane rule, the dashboard-on-Workers decision and the refusal to put orchestration
on Cloudflare are sound and better argued than most specs of this kind. But strip the
diagrams and what remains is a build plan with no backup, no restore, no out-of-band access,
no pager, no upgrade policy, no capacity model and no staffing number that survives its own
arithmetic — and those are precisely the things that decide whether this is running in
2028. As written, this is a design for the day it goes live, not for the two years after.

A note on method: I have marked each outside-world claim VERIFIED (I fetched the primary
source) or BELIEVED. Several things I expected to be invented turned out to be correct, and
I say so in the last section rather than padding the findings with them.

---

## Findings

### [BLOCKER] There is no backup and no restore, anywhere, for any of the six stateful systems

**Where:** `docs/09-cost.md:38` — `monitoring backups, spares = $169`; `docs/10-failure-modes.md:89` — `2. Restore the bucket.`; `docs/05-storage.md:174` — `If the data matters, replicate off-site, and test a restore.`

**Claim under attack:** the word "backup" occurs exactly twice in the entire 3,034-line
document set, both times inside a cost table row. There is no backup section, no restore
procedure, no RPO, no RTO, and no roadmap phase that produces either.

**Why it fails:** enumerate the state and ask where the second copy is.

| State | Owner (per `docs/01-architecture.md:207-215`) | Copy |
|---|---|---|
| Fleet bucket — "it is the fleet's state", retention `forever` (`05-storage.md:200`) | SeaweedFS | none |
| Filer metadata in Postgres (`05-storage.md:85`) | Postgres | none specified |
| Object data, 720 TB raw across three nodes | SeaweedFS | none |
| D1 inventory, jobs, audit | Cloudflare D1 | not mentioned |
| R2 build logs | Cloudflare R2 | not mentioned |
| headscale membership, Nomad Raft, Incus DB, celld bucket | five different systems | none specified |

Now pick any of these at 03:10. A `DELETE` with a wrong prefix against `cfb-artifacts`, or a
misapplied lifecycle rule, or `ec.rebuild` pointed at the wrong collection. There is nothing
to restore from. `docs/10-failure-modes.md:89` says "Restore the bucket" as step 2 of four,
in a document that elsewhere claims to be written for people who cannot read architecture
docs at 3am — and the restore has no source, no command, no target, no expected duration and
no verification step. Worse, the one component that would let you rebuild the namespace —
the Postgres filer — has no backup story at all, so a Postgres loss leaves 720 TB of
volumes on disk that nothing can name.

The only real backup in the system is unmentioned: D1 Time Travel gives point-in-time
restore to any minute in the last 30 days (VERIFIED,
<https://developers.cloudflare.com/d1/reference/time-travel/>). That is a genuine safety
net for the inventory, and it is 30 days, which is not the two-year audit retention the
"append-only audit" table implies.

The `$169` line is also not a backup budget. It is 6.9% of a node-month and has to cover
monitoring, spares and backup for a node holding 15 TB of SAS. It cannot fund an off-site
copy of anything at this scale, and no second site exists anywhere in the architecture.

**What to do instead:** add a data-class table with an RPO and RTO per row, and a mechanism
per row: `pg_dump` + WAL archiving for the filer, S3 object-lock or versioning on
`cfb-images`/`cfb-artifacts`, a nightly `weed backup` of the filer metadata to a host in a
different building, `wrangler d1 export` to R2 on a schedule, and an explicit statement that
the celld fleet bucket is restored *only* by restoring SeaweedFS consistently with its
filer. Then add a Phase 8 to the roadmap whose acceptance criterion is "restore the whole
stack into a scratch site and time it". Until that drill has been run once, every RTO in the
document is fiction.

---

### [BLOCKER] There is no out-of-band access path, and every runbook step needs a shell

**Where:** `docs/01-architecture.md:256` — `If an action needs SSH, it is not in scope of this design and should be called out as such rather than quietly requiring a shell.` against `docs/10-failure-modes.md:33` (`cloudflared tunnel info <name>`), `:87` (`nomad job stop celld`), `:122` (`nomad alloc status <id>`), `:151` (`ec.rebuild -apply`).

**Claim under attack:** "If an action needs SSH, it is not in scope." Then the failure
document is almost entirely out of scope: nine of its ten failures are resolved by running a
command on a host.

**Why it fails:** the architecture deliberately has no inbound path. Enrolment is
"outbound-only" (`01-architecture.md:94`), the gateway is "reached over the tunnel", and the
SPA is the only management surface. So consider the exact scenario Failure 1 is written for:

> `docs/10-failure-modes.md:37` — `3. If Cloudflare is having an incident, do nothing. The fleet runs. Wait.`

To "wait" competently you first have to run step 1, `cloudflared tunnel info <name>`, which
calls the Cloudflare API — during a Cloudflare incident — from a shell on the gateway host,
which you reach through the tunnel, which is down. In the one failure the design admits it
cannot prevent, the operator has no path to any machine in the fleet. Not a slow path: none.
Same for Access misconfiguration (Failure 10), same for a bad `wrangler deploy` that breaks
the SPA, same for `s3.json` corruption, same for a `cloudflared` version that no longer
starts.

I searched the whole document set for `out-of-band`, `IPMI`, `BMC`, `serial console`, `jump
host`, `bastion` — zero hits. The word "break-glass" appears once (`10-failure-modes.md:172`)
and refers to a Cloudflare Access service token, which is itself only reachable through
Cloudflare.

**What to do instead:** name the OOB path and budget for it. Cheapest is a management VLAN
plus a WireGuard endpoint on a second ISP at the site, or an SSH jump host in the colo with
a cross-connect, or BMC on a separate carrier. Then make it the first page of the runbook:
"how to get a shell when the tunnel is down", tested quarterly. If the answer is "drive to
the datacentre", write that down with the drive time, because it is now part of your RTO.

---

### [BLOCKER] EC 10+4 across three nodes has zero node-failure tolerance, and the doc recommends EC to solve disk pressure

**Where:** `docs/05-storage.md:85` — `**Topology:** 3 nodes, each running master + volume + filer + S3 gateway`; `docs/10-failure-modes.md:151-153` — `Check EC repair backlog ... Add a volume, or expire the cache bucket.`

**Claim under attack:** the storage design is a 3-node cluster and the disk-full remedy is
to erasure-code. Those two statements are incompatible.

**Why it fails:** SeaweedFS's own `ec.encode` help text states the constraint plainly:

> "The erasure coding is 10.4. So ideally you have more than 14 volume servers, and you can
> afford to lose 4 volume servers." — VERIFIED,
> <https://github.com/seaweedfs/seaweedfs/blob/master/weed/shell/command_ec_encode.go>

Fourteen shards across three volume servers means at least one server holds five or more.
Losing that server loses five shards against a four-shard budget, and the volume is
unrecoverable. In other words: on the topology the document actually specifies, EC converts
"one node down" from a degraded state into permanent data loss for some fraction of
volumes — while the same topology with 3× replication survives two node losses and costs 3×
the disk. The document acknowledges the rack-level weakness in prose (`05-storage.md:172`,
"Your 3-node SeaweedFS with EC 10+4 on one rack is not that") but never does the arithmetic,
and then tells the operator at 3am to encode.

Separately, the topology table specifies **no replication level at all**. Whatever
SeaweedFS's default is, the operator reading this document cannot tell what durability they
have bought for `cfb-images`, and the document does not say. (BELIEVED: the SeaweedFS master
default is no replication, i.e. `000`; the document should not leave this to folklore.)

**What to do instead:** state the durability target per bucket and the topology that
achieves it. With three nodes: replication `001` and accept 3× overhead, and delete the EC
advice. With EC: go to at least five volume servers (and preferably more than fourteen, per
upstream) before encoding anything, and put the shard-placement arithmetic in the document
so the next person can check it. Either way, add "replication level" and "EC or not" to the
Phase 4 checklist, which currently lists neither (`11-roadmap.md:79-84`).

---

### [MAJOR] The integrity probe cannot detect the integrity failure it exists for

**Where:** `docs/10-failure-modes.md:107` — `Run the CAS probe before every storage upgrade — a script that does two concurrent If-None-Match: * PUTs to the same key and asserts exactly one succeeds.` and `:112` — `the probe runs as a Nomad sysbatch job hourly, and a failure pages.`

**Claim under attack:** an hourly two-PUT test from one client, run *before* an upgrade, is
the control that guards against silent dual ownership.

**Why it fails:** SeaweedFS's own description of how conditional writes work names two
windows where the guarantee is weakened, and the probe cannot see either:

> "a forwarded transaction is applied where it lands rather than forwarded again, so two
> filers that briefly disagree during a ring change can't loop." — VERIFIED,
> <https://seaweedfs.com/blog/conditional-writes/>

and

> "The owner going down doesn't block writes. If the resolved owner filer is unreachable, a
> routed write fails over rather than hanging." — same source, VERIFIED.

So the failure mode is: a filer restarts (a node reboots, a `weed` upgrade, a network blip),
the consistent-hash ring is in flux, two conditional writes to the same key land on
different filers, and both are applied — "applied where it lands" is the mechanism, and it
is exactly the mechanism celld's safety depends on not happening. The doc's probe runs
hourly, from one client, against one gateway, and runs *before* the upgrade rather than
during the membership change the upgrade itself causes. It is structurally blind to the
event it is meant to guard.

Second-order problem: the probe tests `If-None-Match: *` (create-if-absent) only. The
capability matrix at `05-storage.md:40-52` says the thing that distinguishes SeaweedFS from
RustFS is `If-Match: <etag>` — the CAS that celld actually uses to renew leases. The probe
does not exercise the operation whose failure causes the corruption.

**What to do instead:** three changes. (1) Probe continuously — every 5–10s — from at least
two clients through different S3 gateways, against the same key, so a ring disagreement is
actually sampled. (2) Add an `If-Match` CAS case: two clients racing to update one key from
the same etag, assert exactly one 200 and one 412. (3) Make the probe part of the upgrade
procedure rather than a pre-flight check: keep it running *through* the filer restart and
watch for a 412 that should have happened and did not. And add the missing operational
control: celld should refuse to serve a cell whose ownership record it cannot re-read, so a
CAS failure is a refusal rather than corruption.

---

### [MAJOR] Three of the five signals stop working when Nomad stops working — including the integrity signal

**Where:** `docs/10-failure-modes.md:198` — `Five signals, no more:` and `:201-204`.

**Claim under attack:** `2. **CAS probe result** — alert on failure; this is the integrity
signal.` `3. **Nomad node count vs enrolled node count** — divergence means drift.`
`5. **Job queue depth and oldest queued job age** — the capacity signal.`

**Why it fails:** to answer the assignment's question directly — the count is not the
problem, the composition is. Five is a defensible number; these five are all drawn from the
control plane's point of view, and three of them are computed *by* the system they watch.

Concrete: at 02:00 the Nomad servers lose quorum (two of three rebooted after a kernel
update and the third is waiting on a slow disk). The `sysbatch` CAS probe never runs,
because Nomad is what runs it. Signal 3 cannot compare counts, because there is no Nomad to
ask. Signal 5 cannot read queue depth, for the same reason. Three of five signals are
silent — and "silent" is indistinguishable from "healthy" in every alerting system that does
not have a dead-man's switch. The two survivors, tunnel connector count and storage free
space, will both read normal. You find out when a developer asks why their build is queued,
which is the failure this whole document exists to prevent.

The same structural problem appears one level up: the dashboard is the only place the
document puts operational state (`:163`, "Put all three in the dashboard with a countdown"),
and the dashboard is on Cloudflare, reached over the tunnel. So the health of the fleet is
only visible through the path whose health you are trying to observe.

**What to do instead:** (1) Move the probe out of Nomad — run it as a systemd timer on the
gateway host and a second one on a node, so two independent schedulers have to fail before
the signal goes quiet. (2) Add a dead-man's switch: a Cloudflare Worker cron that pages if
the probe has not checked in within three intervals. This is the single highest-value
monitoring change available and it costs about thirty lines. (3) Add a plane-3 reachability
check (node A can reach node B on the overlay, and replication lag is under N seconds),
because nothing in the current five observes the plane that carries the data.

---

### [MAJOR] "Five signals" omits storage *availability*, so a Postgres restart will be treated as corruption

**Where:** `docs/10-failure-modes.md:203` — `4. **Storage free space and EC repair backlog**.`

**Claim under attack:** the storage signal is capacity plus repair backlog. Nothing watches
whether the filer, the S3 gateway or Postgres answers.

**Why it fails:** the document introduces Postgres behind the filer specifically because the
LevelDB default "is an unshareable single point of failure" (`05-storage.md:102`) — and then
never specifies how Postgres is made highly available, never gives it a failure mode in
document 10, and never gives it a signal. So the most likely 3am event in the whole stack,
Postgres being Postgres, produces this sequence:

1. Postgres restarts or its connection pool is exhausted.
2. S3 gateway returns 500s; celld nodes cannot renew ownership.
3. The CAS probe PUT fails.
4. Signal 2 pages, labelled "integrity".
5. The operator reads Failure 5 and follows it: `10-failure-modes.md:87-89` — "Stop the
   celld nodes ... Restore the bucket."
6. The operator starts restoring a bucket that is perfectly healthy, and takes the
   application down for an hour, when the actual fix was `systemctl restart postgresql`.

That is the doc's own stated nightmare — "the good outcome and the bad outcome look
identical from outside" (`:102`) — arrived at by following its own runbook.

**What to do instead:** split the signal into "storage unavailable" (filer 5xx rate, Postgres
reachability and replication lag, S3 gateway p99) and "storage lying" (CAS probe). Give
Failure 4 a decision tree that starts with "is the bucket unreadable or is it *wrong*",
because those have different reflexes and the current text conflates them. And specify the
Postgres deployment: which HA mechanism, where the second copy lives, what the failover time
is, and what the operator sees when it happens.

---

### [MAJOR] The 10–14 week estimate is contradicted by the document's own phase arithmetic, and excludes every ops deliverable

**Where:** `docs/11-roadmap.md:142` — `Roughly 10–14 weeks for one engineer, with Phase 5 being the uncertain one.`

**Claim under attack:** the total.

**Why it fails:** add up the phases as written. Phase 0 (1) + Phase 1 (1) + Phase 2 (1) +
Phase 3 (2–3) + Phase 4 (2) + Phase 5 (2–4) + Phase 6 (1) + Phase 7 (2–4) = **12–17 weeks**.
Drop celld (Phase 7 is "optional") and you get 10–13: the stated upper bound of 14 has no
source in any phase, and the stated lower bound of 10 is only reachable if Phase 5 lands at
its optimistic two weeks *and* celld is cut. The E2B variant is further out: replacing
Phase 5 with "a week" (`:105`) yields 9–10 weeks, not the stated "6–8".

Then the internal contradiction that matters most. The roadmap budgets Phase 5 at 2–4 weeks.
Document 04 says of the same work:

> `docs/04-compute.md:59` — `This is four to six weeks of work for someone who has done it before, and three months for someone who has not.`

The roadmap's own correction for the inexperienced reader is "double Phase 3 and Phase 4"
(`:146`) — it does not double the phase with the largest documented variance, which is the
one that is already understated by 50–300%.

And the estimate contains no line item for anything an operator does: backup, restore drill,
pager and escalation, runbooks, capacity model, certificate rotation, the security posture
panel the threat model demands (`08-threat-model.md:192-193`), or the staging environment
you need to test any of it. Every one of those is a deliverable with an owner and a
completion criterion, and none of them appears in any phase. A plan that schedules the
building of six stateful systems and zero of the procedures for running them will deliver
six stateful systems and no procedures — which is exactly what the document currently
contains.

**What to do instead:** restate as 16–22 weeks for a competent generalist who has not built a
Firecracker platform (12–17 from the phases, plus the ops work the phases omit), and add
Phase 8, "operate it", with concrete acceptance criteria: a restore drill with a measured
duration, an alert that reaches a phone, a runbook a second person has executed unaided, and
a node rebuilt from bare metal by script. If Phase 8 is not in the plan, it will not happen.

---

### [MAJOR] Six stateful systems, no upgrade policy, against ~48 SeaweedFS releases a year

**Where:** `docs/10-failure-modes.md:107` — `Run the CAS probe before every storage upgrade` — is the document's entire upgrade guidance. `docs/11-roadmap.md:28` pins a version for `cloudflared` and for nothing else.

**Claim under attack:** that "upgrade" is a single sentence about a probe.

**Why it fails:** measure the upstream cadence (VERIFIED, GitHub releases API,
<https://api.github.com/repos/seaweedfs/seaweedfs/releases>): **48 releases between
2025-10-29 and 2026-10-29**, 29 of them since 2026-04-29, and two on the same day
(4.50 and 4.51, both 2026-10-25). celld is on a similar treadmill — v0.6.0 (2026-09-26) to
v0.6.3 (2026-10-21) is four releases in 25 days (VERIFIED,
<https://api.github.com/repos/denoland/celld/releases>).

Now put a 0.5 FTE operator in front of that. Six stateful systems (SeaweedFS, Postgres,
Nomad, Incus, headscale, celld) plus Firecracker, the host kernel and `cloudflared`. At
roughly ten hours a week, you have under two hours per system per month, which is not enough
to read a changelog for a project shipping weekly, let alone stage and test it. The document
does not say what to pin, whether to run N-1, whether to upgrade storage before or after
celld, what the compatibility constraint between them is, or how to roll back. `:108` says
"roll back the storage version immediately" as if that were an action rather than a project
— SeaweedFS publishes no downgrade guarantee, and the filer's metadata schema is the thing
most likely to have moved.

The dependency ordering is the part that will actually bite. celld's correctness rests on
SeaweedFS's conditional-write implementation, and that implementation is itself new — the
owner-filer routing is described in a July 2026 engineering post (VERIFIED,
<https://seaweedfs.com/blog/conditional-writes/>), which is to say the property celld
depends on is younger than most of the code it protects. So the upgrade order is not
"storage then celld"; it is "storage, then re-run the CAS probe against the *celld*
workload, then celld". Nothing in the document says this.

**What to do instead:** write an upgrade policy as a table — component, pinned version,
upgrade cadence, dependency order, rollback method, and what evidence justifies the upgrade.
Pin everything, not just `cloudflared`. Run one canary node ahead of the fleet for storage
and celld. Add an explicit "do not upgrade during a freeze" window around any period you
cannot afford a rebuild. And accept in writing that you will run several months behind
upstream, with the security trade-off that implies.

---

### [MAJOR] The roadmap ships untrusted code in containers, on the storage host, for 2–4 weeks — against its own threat model

**Where:** `docs/11-roadmap.md:71` — `**Start with containers, not microVMs.** Get the whole path working with the docker driver on trusted code` and `:57` (Phase 3, CI live) versus `:93` (Phase 5, isolation) versus `docs/04-compute.md:18` — `The rule: **anything you did not write runs in a microVM.**`

**Claim under attack:** "on trusted code" is doing a great deal of work in one sentence, and
nothing enforces it.

**Why it fails:** Phase 3's acceptance criterion is "a real build runs end to end, triggered
from the SPA" (`:68`). A real CI system's first useful act is to build a pull request, and
the threat model says so explicitly: "**The build path.** CI runs arbitrary code from
repositories. It is the intended entry point for an attacker." (`08-threat-model.md:14`).
Between Phase 3 and Phase 5 there is a window of two to four weeks, plus however long the
Firecracker work actually takes, in which a stranger's `postinstall` script runs in a
container — namespaces and cgroups, no seccomp, no separate kernel — on a node that, in the
same document's architecture, is a Nomad client holding a token and sitting on the overlay
next to the storage cluster. `08-threat-model.md:69` says the opposite: "do not run untrusted
code on a host that also holds your fleet bucket credentials."

**What to do instead:** make it a gate rather than an aspiration. Either Phase 3 runs only
on repositories you control and the SPA refuses to accept a job from a fork until Phase 5 is
done (a five-line check, and a visible one), or move isolation before CI goes live. Say which
in the roadmap. "Get the whole path working with the docker driver on trusted code" reads as
advice; it needs to read as an enforced precondition, because at 3am in week three nobody
remembers the sentence.

---

### [MAJOR] Nobody is on call, and the only staffing number in the document is off by 12×

**Where:** `docs/09-cost.md:37` — `labour     0.5 FTE × $128,869 loaded / 54.6 nodes    = $1,180`

**Claim under attack:** the labour line, which is the document's entire answer to "how many
people does this take".

**Why it fails:** every other line in that block is per node per **month** — hardware is
`$40,520 / 48 months`, power is `730 h`, colo is per kW-month. The labour line divides an
annual figure by a node count, which yields **$1,180 per node-year**, then places it in a
monthly column. Corrected, it is $98/node-month, the node-month total is $1,360 rather than
$2,443, the owned cost per container-month is $63.76 rather than $114.50, and the headline
break-even moves from 39.1% to **21.8%** — which inverts the document's own conclusion at
its own worked example ("a CI fleet at 8 hours × 22 weekdays is 24% duty", `09-cost.md:55`).
Take the other reading, that $1,180/node-month is right, and 0.5 FTE supports 4.5 nodes, not
54.6, and the design is uneconomic by an order of magnitude. Either way the number that
drives the whole cost argument is wrong, and the reader cannot tell whether this needs half
a person or six.

Underneath the arithmetic is the question the document never asks: **who gets woken up?**
`10-failure-modes.md:18` says integrity failures "are the only ones that justify waking
someone", which implies a rota. There is no rota, no pager, no escalation, no secondary, no
policy for "the one person is on a plane", and no SLA. The whole premise is replacing a
managed service with an uptime commitment and a status page with something a single person
runs from a phone. That may be a defensible trade; it is not stated as one, and it is not
priced.

**What to do instead:** state the staffing model in people, not FTE fractions — "one
engineer at 40% plus a second who can execute the runbook under supervision" — and fix the
labour arithmetic so the number is auditable. Then write the on-call policy: who, how they
are reached, what the response time is for an integrity page versus a capacity page, and
what the documented behaviour is when nobody answers. If the answer is "there is no
escalation, it is one person", say that, because it changes what the reader is buying.

---

### [MAJOR] When the builder leaves there is no configuration source of truth to inherit

**Where:** `docs/11-roadmap.md:111` — `- [ ] Incus cluster on the provisioning hosts`; `docs/03-orchestration.md:53-72` (HCL that exists only as a snippet in a markdown file); `docs/01-architecture.md:80-90` (`install.sh`).

**Claim under attack:** the document is the handover.

**Why it fails:** I grepped the entire set for `Terraform`, `Ansible`, `Pulumi`,
`infrastructure as code` and `config management` — zero hits. What the successor inherits is:
six stateful systems configured by hand from prose; roughly 1,500 lines of bespoke Go
(`04-compute.md:204` — supervisor, network allocator, GC, plus the relay at
`07-control-plane.md:158` "a few hundred lines of Go" that is also "the component most likely
to become a security hole"); an `install.sh` with no tests; and a roadmap with **zero** test,
staging or drill line items — I checked, the only occurrence of "test" in the whole roadmap
is "test with an `http2` tunnel once, deliberately" (`11-roadmap.md:37`). For a project whose
purpose is CI, there is no CI.

The bus-factor paragraph in the README (`README.md:156`) is honest about the upstream
projects and then stops. It never asks the question that follows: the person who understands
the interaction between SeaweedFS's hash ring, celld's lease expiry and Nomad's rescheduling
is also the person who wrote all of it, and the document is the only artefact.

**What to do instead:** every config in git, and one command that rebuilds a node from bare
metal — `make node` or equivalent, idempotent, exercised by deleting a node quarterly. A
staging instance of the whole stack (it can be one box, Tier 0) where upgrades are tried
first. A written handover test: a competent engineer who has never seen the system is given
the repo, a broken staging cluster and a day, and the measure is whether they fix it. If
that test fails, the document is not finished, regardless of how good the diagrams are.

---

### [MAJOR] Rotation is a countdown in a dashboard, the API endpoint it points at does not exist, and half the credentials are unlisted

**Where:** `docs/10-failure-modes.md:162-163` — `Put all three in the dashboard with a countdown, and rotate on a schedule rather than on expiry.`; `docs/08-threat-model.md:101` — `the rotation path is an API endpoint, not a runbook`; `docs/01-architecture.md:253` — `| Rotate a token | API + DO, revoke on the substrate |`

**Claim under attack:** that rotation is designed.

**Why it fails:** `spec/openapi.yaml` has fifteen paths and none of them rotates anything —
`/nodes`, `/nodes/enroll`, `/nodes/{id}/drain`, `/nodes/{id}/revoke`, `/jobs`, `/jobs/{id}`,
`/jobs/{id}/logs`, `/jobs/{id}/cancel`, `/machines`, `/machines/{id}`, `/buckets`,
`/buckets/{name}/presign`, `/apps/{app}/deploy`, `/apps/{app}/state`, `/audit`. So the
architecture document promises a capability, the threat model relies on it, and the spec
does not have it. The gap will be discovered by whoever implements the SPA, who will
improvise.

The list of clocks is also short. `:161-162` names three: the Access session, the Nomad ACL
token, the overlay node keys. Missing: the `cloudflared` tunnel credentials themselves (the
thing that actually expires and takes the entire management plane with it), the four Worker
secrets at `07-control-plane.md:192-195`, the SeaweedFS admin key, the Incus client
certificate the relay holds, the celld fleet token, and the Postgres credentials. `:172` says
the break-glass service token has "a documented rotation" — it is not documented anywhere in
the set.

And the countdown is not an alert. A countdown you have to look at is a countdown you will
look at after it expires. Signal 5 in the monitoring section is "job queue depth"; there is
no signal for "a credential expires in 14 days".

**What to do instead:** one table of every credential: owner, lifetime, where it lives, how
it is rotated, blast radius if it leaks, and the command. Add `/v1/credentials` with
`GET` (expiry inventory) and `POST /{id}/rotate` to the spec, or delete the claim from
documents 01 and 08. Make expiry an alert at T-14 and T-2, not a number on a screen. And
document the actual order of operations for rotating the tunnel credential without an
outage, because that one takes the dashboard down while you do it.

---

### [MAJOR] No capacity model and no growth forecast; the one capacity signal has no procedure attached to it

**Where:** `docs/10-failure-modes.md:204` — `5. **Job queue depth and oldest queued job age** — the capacity signal.`

**Claim under attack:** that capacity is covered by a queue-depth metric.

**Why it fails:** a queue-depth alert tells you that you are out of capacity. It does not
tell you what to buy, when, or how to add it. The document contains no concurrency model (a
128-core node with 8–16 vCPU builds is 8–16 concurrent jobs, not the 21.33 container
equivalents at `09-cost.md:42`, which is a memory-bound figure and the wrong unit for CPU-bound
work), no per-job storage growth figure, no threshold at which you add a node, and no
forecast horizon. The only sizing table (`03-orchestration.md:167-175`) is a starting point,
not a model.

Storage is where this actually hurts, because storage expansion is the one thing you cannot
do at 3am in an afternoon. Three nodes × 12 × 20 TB is 720 TB raw. At 3× replication that is
240 TB usable. `cfb-images` is "forever" (`05-storage.md:197`), `cfb-celld-*` is "forever"
(`:200`), and `cfb-artifacts` is 90 days. Nothing in the document estimates how much a
40-minute build produces, how fast an image library grows, or how many months 240 TB buys
you. When it runs out you are adding a fourth node to a cluster whose EC arithmetic already
does not work (see the BLOCKER above), and rebalancing it by hand.

**What to do instead:** a capacity section with three numbers per resource (current, growth
per month, headroom in months) and a written trigger ("add a storage node at 70% of usable
capacity, lead time six weeks"). For storage specifically: measure bytes per build and per
artifact on day one of Phase 3, and put the number in the document so the first capacity
decision is arithmetic rather than panic. Note that `05-storage.md:202` is right that "a
lifecycle rule is not optional" — but see the next finding, because the rule may not do what
the document thinks it does.

---

### [MAJOR] The observability stack sits behind the same tunnel it is supposed to observe

**Where:** `docs/07-control-plane.md:174` — `Do not build a metrics dashboard. Point Grafana at the substrate and link to it.`

**Claim under attack:** that linking to Grafana from the SPA is an observability strategy.

**Why it fails:** there are exactly two ways to implement that sentence, and both are bad.
If Grafana is published on a Cloudflare hostname, it is a new public attack surface that
reads every metric in the fleet, protected by an Access policy — which is the same policy
that, per Failure 10, can lock you out. If it is on the overlay, it is reachable only through
the tunnel — so it is unavailable in precisely the incidents you need it for: Cloudflare
outage, tunnel down, VPC degraded. The document's own failure table
(`02-connectivity.md:180-186`) lists "Cloudflare outage → dashboard gone" and treats that as
acceptable because "the entire fleet keeps running"; but "keeps running" is only reassuring
if you can still see it, and you cannot.

**What to do instead:** decide, explicitly, and write it down. The cheap correct answer is a
Grafana/Prometheus instance on the site's management network, reachable over the OOB path
from the previous finding, with alerting that leaves the site independently (a webhook to a
paging provider over a different provider's network). Link to it from the SPA as a
convenience, not as the only door.

---

### [MINOR] The disk-full remedy does not work: lifecycle expiry does not reclaim space, and "add a volume" is not a thing on a full EC cluster

**Where:** `docs/10-failure-modes.md:153` — `2. Add a volume, or expire the cache bucket.`; `docs/05-storage.md:202` — `The cache bucket is where storage bills come from. A lifecycle rule is not optional.`

**Claim under attack:** that expiring `cfb-cache` frees disk.

**Why it fails:** there is an open SeaweedFS issue titled "Disk space is not reclaimed when
using S3 lifecycle policy" — objects disappear from the listing while the volume server
still reports the space consumed, because the volume has not been vacuumed (VERIFIED,
<https://github.com/seaweedfs/seaweedfs/issues/8757>, opened 2026-03-24, still open as of
2026-06-06). If that is the behaviour you hit, "expire the cache bucket" removes the objects
and frees nothing, which is the worst possible outcome during a disk-full incident: you
believe you have acted. Relatedly, "advanced policies for data tiering and expiration" is
listed as a *future* Enterprise feature on SeaweedFS's own comparison page (VERIFIED,
<https://seaweedfs.com/docs/comparison/>), so OSS lifecycle is the basic path and should not
be relied on for the one control that keeps the cluster from filling.

"Add a volume" is also misleading: a volume is a unit inside a volume server. What you add
is a server (or a disk to one), and then you rebalance — which is the six-week-lead-time
operation from the capacity finding, not a 3am action.

**What to do instead:** replace the step with something that works at 3am: identify the
collection and volume filling, `volume.vacuum` to reclaim deleted bytes, throttle or pause
writes to the offending bucket via the S3 quota, and only then plan the expansion. And add
an alert on volume-server used-space per disk rather than only cluster free space.

---

### [MINOR] The 45-minute ceiling is a comment, not a configuration, so Failure 6 has no timeout to fire

**Where:** `docs/04-compute.md:142` — `# 45 minute ceiling; the supervisor kills the microVM, not Nomad`; `docs/10-failure-modes.md:123-124` — `If the microVM is alive but the build is stuck, the supervisor's timeout should have fired.`

**Claim under attack:** "the supervisor's timeout should have fired."

**Why it fails:** the job spec above that comment sets `kill_timeout = "10s"` and nothing
else. There is no `NOMAD_META` deadline, no supervisor flag, no `timeout` stanza. So Failure
6's diagnostic — "if it did not fire, that is a supervisor bug" — points the operator at a
timeout that was never configured, in a document that also says the supervisor should be
kept dumb. The operator will spend the incident looking for a bug in code that was never
asked to do the thing.

**What to do instead:** put the deadline in the job spec as a real parameter passed to
`cfb-run-sandbox` (`--max-duration 45m`), make the supervisor enforce it with SIGKILL on the
Firecracker process, and have it exit with a distinct code that Nomad records. Then Failure 6
can say "check the allocation's exit code" instead of "check that a thing happened".

---

### [MINOR] Phase 3's acceptance criterion depends on Phase 4's storage

**Where:** `docs/11-roadmap.md:66` — `- [ ] Artifacts to SeaweedFS with presigned PUT` (Phase 3) and `:68` — `**Done when:** ... the artifact lands in a bucket`; against `:77` — `## Phase 4 — storage (2 weeks)`.

**Claim under attack:** the phase ordering.

**Why it fails:** Phase 3 cannot be "done" before Phase 4 exists, unless you mean R2 — but
Phase 4's own checklist says "Move artifacts off R2" (`:84`), which implies Phase 3 used R2.
That is fine as an intent, but the roadmap does not say it, so the reader is left with an
acceptance criterion that cannot be met and a dependency that is invisible until week six.
The same ambiguity applies to the CAS probe: Phase 3 says the whole path is live; Phase 4
says the probe is the thing that makes storage trustworthy.

**What to do instead:** say "artifacts to R2 in Phase 3, moved to SeaweedFS in Phase 4", and
put the dependency explicitly at the top of Phase 3.

---

### [MINOR] There is no power-loss or boot-order runbook for the most likely total outage

**Where:** `docs/10-failure-modes.md` (all ten failures); `docs/09-cost.md:35` — `colo       0.55 kW × $200/kW-month`.

**Claim under attack:** the failure taxonomy is complete.

**Why it fails:** for owned metal in one rack, the single most likely total outage is the
rack losing power — a colo transfer switch test, a PSU, a breaker. Nothing in the document
covers it: no UPS or dual-feed in the cost model, no graceful-shutdown ordering, and no
startup ordering. That last one matters enormously, because the components have real
ordering constraints: Postgres before filers; SeaweedFS masters before volume servers before
filers before the S3 gateways; Nomad servers before clients (clients will retry, but the
servers need quorum and a stale Raft member that comes back late is a known source of
confusion); headscale before the nodes that need to re-key; `cloudflared` last. Get it wrong
and you will spend an hour on a cluster that is "up" but serving 500s.

**What to do instead:** a one-page boot order with the commands, a shutdown order with
timeouts, and a UPS in the bill of materials with the runtime stated. Test it once by pulling
power deliberately, because the alternative is testing it for the first time at 3am.

---

### [MINOR] Guest-kernel patching has no cadence, and every rebuild invalidates the snapshot cache that makes the platform fast

**Where:** `docs/08-threat-model.md:69` — `kernel. Patch them, and do not run untrusted code on a host that also holds your fleet bucket credentials.`; `docs/11-roadmap.md:98` — `- [ ] Snapshot and resume for the template cache`.

**Claim under attack:** "Patch them" is the whole patching plan.

**Why it fails:** this is the dominant recurring task of a microVM platform and it appears
once, in a threat model, as two words. The work is not patching a host — that is routine. It
is that every guest kernel CVE requires rebuilding every rootfs in the image pipeline, which
invalidates every cached template snapshot, which turns a "patch Tuesday" into a full
image-pipeline run plus a cache cold-start for every recipe. The pipeline is a Phase 5
deliverable with no stated rebuild cadence, no automated trigger, and no way to know which
recipes use which kernel. Two years in, you will be running a kernel with a known local
privilege escalation because rebuilding 30 images by hand is a weekend.

**What to do instead:** treat the image pipeline as a service with an owner and an SLA —
"every base image rebuilt within 7 days of a kernel CVE, automatically, on a schedule" — and
build the rebuild trigger in Phase 5 rather than discovering the need later. Track kernel
version as a first-class attribute of every image so you can answer "which recipes are still
on the vulnerable one" in one query.

---

### [MINOR] "Append-only audit" with a 30-day restore window and no export is not a two-year audit log

**Where:** `docs/01-architecture.md:210` — `| Job definition and history | D1 |`; `docs/07-control-plane.md` — `/api/v1/audit` reads D1; `docs/01-architecture.md:254` — `| Read the audit trail | D1 |`.

**Claim under attack:** that D1 is an adequate home for the audit log over the document's own
two-year horizon.

**Why it fails:** D1's only recovery mechanism is Time Travel, 30 days (VERIFIED,
<https://developers.cloudflare.com/d1/reference/time-travel/>). Nothing in the document
exports the audit table anywhere, so a bad migration, an accidental `DELETE`, or a D1
incident longer than the window loses the audit trail permanently. And `01-architecture.md:210`
puts job history in D1 too, so the same window applies to the record of what ran. The
document asks "who deleted that VM" (`07-control-plane.md:172`) — over two years, D1 alone
cannot answer it.

**What to do instead:** ship the audit table to R2 as append-only objects (or to SeaweedFS
with object lock) on a schedule, with a documented retention, and state the retention the
design actually supports. Add `wrangler d1 export` to the backup procedure.

---

### [NIT] "Alert at 1 connector" pages you during your own documented maintenance

**Where:** `docs/10-failure-modes.md:200` — `1. **Tunnel connector count** — expect 2 per site; alert at 1.` against `docs/08-threat-model.md:172` — `Update deliberately, during a maintenance window, one connector at a time.`

**Claim under attack:** the threshold.

**Why it fails:** the recommended `cloudflared` upgrade procedure is to take one connector
down at a time, which trips the alert every time, by design. And 2→1 and 1→0 are the same
signal, when they are not the same event: one connector down is degraded, zero is "the
management plane is gone". The document's own fear — "Alert fatigue kills the integrity
alert, which is the only one that matters" (`:206`) — is realised by its first signal.

**What to do instead:** alert on 0 immediately and on 1 after ten minutes (or suppress
during a declared maintenance window), and make the two states distinct pages with distinct
runbooks.

---

### [NIT] The SeaweedFS bus factor is worse than the document admits

**Where:** `README.md:156` — `SeaweedFS is 54% one person.`

**Claim under attack:** the 54% figure.

**Why it fails:** measured from the contributors API, `chrislusf` holds 10,801 of 14,537
commits across the top 100 contributors — **74.3%**, or **83.9%** excluding the 1,664
dependabot commits (VERIFIED, <https://api.github.com/repos/seaweedfs/seaweedfs/contributors>).
The document understates its own central risk by about twenty points. This matters because
the number is doing argumentative work: at 54% the reader thinks "large project, one dominant
maintainer, normal for Go"; at 84% the reader should think "this is a one-person project with
a large community attached", which is a different risk decision.

**What to do instead:** use the measured figure and say how it was measured. Then say what
you would actually do if `chrislusf` stopped: who forks, who patches, what the exit to RustFS
or a commercial SeaweedFS licence costs. A bus-factor number without a contingency plan is
decoration.

---

## What the document gets right

- **Workers VPC genuinely requires QUIC and outbound UDP 7844, and an `http2` tunnel silently
  breaks VPC DNS resolution.** I expected this to be folklore. It is in Cloudflare's own
  troubleshooting reference, in almost the document's words (VERIFIED,
  <https://developers.cloudflare.com/workers-vpc/reference/troubleshooting/> and
  <https://developers.cloudflare.com/workers-vpc/configuration/tunnel/>). The failure mode
  and the "this will cost you an afternoon" warning are correct.
- **"OSS erasure coding is hardcoded at 10+4 and repair is manual."** I expected the document
  to have assumed configurable shards. Upstream's `ec.encode` help says "The erasure coding
  is 10.4", and customisable ratios are an Enterprise feature (VERIFIED,
  <https://seaweedfs.com/docs/comparison/>). The claim is right — the *topology* built on it
  is what is wrong, which is the BLOCKER above.
- **The refusal to sell the cost story.** I expected a flattering comparison. Instead the
  document says self-hosting loses below ~40% duty cycle, that the argument is capability and
  not price, and that labour is the dominant term. The Cloudflare container arithmetic
  ($292.76/container-month) checks out line by line, as does the observation that CPU bills
  on active use only so the figure is a ceiling. The labour line is wrong, but the *instinct*
  — that this is a capability purchase and not a discount — is the correct and unusual one.

---

## Unanswered questions

- What is the RPO and RTO for each data class, and how long does restoring 720 TB raw
  actually take over the transit you bought?
- After a full-site power loss, in what order do the nine daemons start, and who has that
  written down?
- Who is on call, how are they reached, and what happens when they do not answer?
- How many people does this need — the document implies 0.5 FTE in one place and, if its own
  arithmetic is taken literally, 6 FTE in another.
- How is Postgres behind the filer made highly available, and what does the operator see
  during a failover?
- What happens to a celld fleet bucket when SeaweedFS must be restored from an older
  snapshot — does celld tolerate its ownership records going backwards in time?
- What is the upgrade order between SeaweedFS and celld when a storage release changes
  conditional-write semantics?
- What is the retention requirement for the audit log, and where does it live for two years?
- How do you patch the Firecracker host kernel and the guest kernels without a maintenance
  window, and what happens to running microVMs?
- What is the exit plan if celld is abandoned, or if SeaweedFS's maintainer stops — how many
  weeks to migrate off, and to what?
- Which single person holds the break-glass Access service token, and what is the procedure
  if they are unavailable?
- Is there a second site in any scenario, and if not, what is the stated availability number
  this design is claiming?
