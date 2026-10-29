# Adversarial review — what broke, and what changed

Revision 1 of this specification was reviewed by five hostile reviewers: architecture,
security, fact-checking, operations and economics. This file records what they found and what
was done about it, because a spec that does not show its own corrections is indistinguishable
from a spec that never had any.

The reviews themselves are in this directory, unedited.

---

## Summary

| Reviewer | Blockers | Major | Outcome |
|---|---|---|---|
| [01-architecture](01-architecture.md) | 3 | 9 | 2 accepted and fixed, 1 accepted in part |
| [02-security](02-security.md) | 5 | 12 | 4 accepted and fixed, 1 accepted as a stated residual risk |
| [03-factcheck](03-factcheck.md) | 1 | 6 | all fixed |
| [04-ops](04-ops.md) | 3 | 11 | all fixed |
| [05-economics](05-economics.md) | 2 | 6 | both fixed; the conclusion changed |

Revision 1 was wrong in ways that mattered. The most serious was arithmetic.

---

## The blocker that changed the conclusion

**The cost model divided an annual labour figure into a monthly sum.** The line

```
labour  0.5 FTE × $128,869 loaded / 54.6 nodes = $1,180
```

is dollars per node per *year*. The correct monthly figure is $98. Substituting it moves the
node-month from $2,443 to $1,360, the cost per container-month from $114.50 to $63.76, and the
break-even duty cycle from **39.1% to 21.8%**.

That inverts the headline. Revision 1 said Cloudflare wins below 40% duty and a CI fleet runs
at 24%, so Cloudflare wins. Revision 2 says the two are close to neutral at that duty cycle,
and that the real competitor — Fargate, which can actually run the job — wins outright at 24%.

Recomputed independently, twice, in `python3`. The critique's numbers reproduce exactly.

**What changed:** `docs/09-cost.md` rewritten around a labour-sensitivity table; the README's
claim corrected; a Fargate comparison added, because benchmarking against a product the
document calls unusable was circular.

---

## Blockers, and their disposition

### 1. "Orchestration is not Cloudflare" is false — the Worker is cluster root

**Accepted.** The Worker holds every substrate credential. The claim was true about scheduling
and false about authority.

**Fixed:** `docs/02-connectivity.md` now states the distinction explicitly and adds a *Trust
concentration* section: scoped tokens per substrate, no storage-delete capability in the
Worker, hardware-key MFA on the Cloudflare account, an offline break-glass identity, and the
residual risk written down rather than argued away.

### 2. Untrusted microVMs must reach the overlay, which Phase 5 forbids

**Accepted — this was a real contradiction.** The sequence diagram had the job pulling images
over the overlay while the acceptance criterion forbade any route to it.

**Fixed:** `docs/04-compute.md` adds a node-local pull-through proxy. The microVM's only route
is one port on its own node; the proxy holds the storage credentials and enforces the job's
prefix. Strictly better than overlay access, because the credential never enters the sandbox.

### 3. The enrolment token is absent from the threat model

**Accepted.** The one credential a human types, and it was not in the document.

**Fixed:** new *Attack 1b* in `docs/08-threat-model.md`: 15-minute single-use tokens bound to a
pre-created node id, exchanged once for a long-lived credential, with a default-deny overlay
group so a stolen token enrols a machine that can reach nothing.

### 4. `vpc_networks` is an SSRF primitive with a route into the private network

**Accepted.** The destination is a runtime string, and the document recommended
`vpc_networks` over `vpc_services` on convenience grounds.

**Fixed:** a `vpcFetch()` helper with a static allowlist in `docs/02-connectivity.md`, a lint
rule ("`env.SITE.fetch` may appear exactly once"), and *Attack 11* in the threat model.

### 5. No backup, no restore, no RPO, no RTO

**Accepted.** The word "backup" appeared twice, both in a cost table.

**Fixed:** new `docs/12-operations.md` — a state inventory with a second copy and RPO/RTO for
every item, backup procedures, restore procedures per component, a quarterly rehearsal, and a
rehearsal log.

### 6. No out-of-band access, while every runbook needs a shell

**Accepted.** The architecture has no inbound path by design, then wrote ten runbooks that
need one.

**Fixed:** `docs/12-operations.md` §4 — three layers (overlay SSH, `cloudflared access ssh`,
console), with a table of which failure each layer covers.

### 7. Erasure coding on three nodes cannot tolerate a node failure

**Accepted — this would have caused data loss.** EC 10+4 needs 14 shards and no node may hold
more than 4; 14 ÷ 4 = 3.5, so three nodes cannot satisfy it.

**Fixed:** `docs/05-storage.md` now recommends replication on three nodes and states that EC
is a five-node, two-rack feature. `docs/12-operations.md` §6 carries the correction table.

### 8. "Single-tenant by construction" is contradicted by the CI path

**Accepted.** CI runs arbitrary code from arbitrary repositories. The design is single-tenant
at the *organisation* level and not at the job level.

**Fixed:** restated in `docs/08-threat-model.md`, with the isolation mechanism named (microVM
plus per-job network policy) rather than implied.

---

## The factual corrections

All verified against primary sources and all applied:

| Claim in rev 1 | Correct |
|---|---|
| R2 has no object lock / WORM | R2 has **Bucket Locks** — retention for a period or indefinitely. It lacks the *S3 object-lock API*, not retention. |
| Containers die mid-build; 6 h ceiling; "cannot run at any price" | No fixed max runtime. `Container` class defaults `sleepAfter` to 10 min; `setInactivityTimeout()` goes to 6 h; the hook is overridable. The real blockers are 4 vCPU / 12 GiB / 50 GB images and interruptible hosts. |
| Workers Free size 3 MiB | 64 MiB, same as Paid. |
| Nomad last MPL release v1.6.3 | v1.6.4–v1.6.10 predate the BUSL cut-over, which is scoped to "1.7.0 or later". Pin 1.6.10. |
| SeaweedFS replication port 19333 | 19333 is the *master gRPC* port; volume replication rides the volume HTTP port 8080. Firewalling 19333 breaks the cluster. |
| "silently at 3× replication cost" | Without a scheduled repair a failed volume is simply under-replicated and you are not told. |
| celld worker listener 9876 | 9876 is the `celld dev` loopback default; production is `--listen 0.0.0.0:8080`, internal `:8081`. |
| `"network_id": "<mesh-or-tunnel-id>"` | A tunnel binds with `tunnel_id`; Mesh binds with `network_id: "cf1:network"`. Different fields. |
| E2B Embed: 29 services, orchestrator via `nsenter` | 21 services, 12 images; the orchestrator is `privileged` with `pid: host`, and `nsenter` is used by the preflight/host-setup one-shots. |
| workerd "~100 contributors" | 236. |
| 36-month hardware life raises cost ~22% | +11.5% (hardware $844 → $1,126 on a $1,360 node-month). |
| "halve nodes per person and cost doubles" | 1.48×, not 2× — labour is 7% at the reference ratio. |
| 10 TB egress costs $250 | $225 — the first 1 TB is included. |

---

## What was not fixed, and why

- **"The 54.6 nodes per ops person constant is back-solved."** True. It is kept, but only as
  the *optimistic* column of a sensitivity table, with the honest minimum staffing stated as
  one full-time person in `docs/12-operations.md` §8. Deleting the number would hide the
  assumption; publishing it alone would launder it.
- **Cloudflare account compromise.** Not fixable by architecture. Stated as a residual risk
  with mitigations that reduce blast radius rather than eliminate it.
- **The bus factor of SeaweedFS, celld and headscale.** Not fixable. Stated in the README, in
  each landscape review, and in the staffing section. The honest advice is that this stack is
  a commitment to own it.

---

## The reviewers' verdicts, verbatim in spirit

> salvageable — the core instinct is right, but the cost model is off 12× and "orchestration is
> not Cloudflare" is false because the Worker holds cluster root

> the Cloudflare half is unusually well sourced; the cost document is arithmetically broken

> the operations half of the document does not exist — no backup, no restore, no out-of-band
> access, no pager, no upgrade policy, no capacity model

> the arithmetic reproduces exactly but the model is incoherent — the break-even is measured
> against a product the doc calls unusable, while the competitor that can run the job is never
> costed

All four are now addressed. The design did not change shape; the claims about it did.
