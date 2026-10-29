# Review — revision 4

What was wrong with revision 2, and what changed. Revisions 1 and 2 were reviewed by five
hostile reviewers (architecture, security, fact-checking, operations, economics); their
findings drove revision 2. This revision is a response to the design itself being the wrong
shape.

---

## The three structural criticisms

### 1. Portability was an afterthought

**The requirement:** application code must run on Cloudflare or self-hosted with minimal
change.

Revision 2 chose components and never defined what "portable" meant, so the answer would have
been "rewrite your app per target". That is the opposite of the requirement.

**Fixed:** `docs/01-portability.md` defines the **Portable Workers Subset** — the 16 APIs that
run unchanged on both — and enumerates the 13 things that force a source fork, each mapped to
one adapter surface. The adapter (`@cfb/port`) is the only place a runtime check is allowed,
and a lint rule enforces it. The contract is testable: the same test suite runs against both
runtimes in CI.

### 2. Six daemons to run one job

Revision 2 installed `cloudflared`, Nomad, Incus, celld, SeaweedFS and `tailscaled` per node.
Five credential stores, five upgrade paths, five failure modes, and five routes through the
tunnel — to move a job onto a box.

**Fixed:** one binary, `cfbd`, which is the tunnel connector, the broker and the supervisor.
It dials out, holds one connection, multiplexes streams over it, and supervises child
processes (`workerd`, containers, microVMs) using the runtime already on the host. Nomad and
Incus are gone; placement is a filter-and-sort in the control plane.

The mechanisms are borrowed, not invented: the multiplexed tunnel and connection fencing from
rivet, the `msg_id` RPC and agent-owned capability model from ServerBee (reimplemented — AGPL),
the reconnect lifecycle from omnyssh.

### 3. The documents were fat, and carried narrative sections

Revision 2 was 40 files and 165,000 words, including a narrative section about a video game.

**Fixed:** 9 documents, one survey, one review, ~13,000 words. The 23 research lanes and 12
deep reviews are consolidated into `SURVEY.md` — one row per project, the mechanism worth
taking, the reason for the verdict. That was the load-bearing part; the prose was not.

Revision 4 also removed the `reference/` and `spec/` directories: this is a design document,
and a skeleton implementation plus a machine-readable schema were duplication of what the
prose already states. The protocol detail lives in `docs/02-agent.md`.

---

## Corrections carried forward from the revision-2 review

| Was | Is |
|---|---|
| Break-even 39.1% | **21.8%** vs Cloudflare, **40.6%** vs Fargate — the labour line mixed $/year into a $/month sum |
| "Cloudflare cannot run this at any price" | No fixed max runtime; `Container` sleeps after 10 min by default, `setInactivityTimeout()` reaches 6 h. The blockers are the 4 vCPU / 12 GiB ceiling, the 50 GB image budget, and interruptible hosts. |
| "R2 has no object lock" | R2 has **Bucket Locks**; what it lacks is the *S3 object-lock API* |
| EC 10+4 on 3 nodes | **Data loss.** 14 shards, no node may hold more than 4. EC is a 5-node, 2-rack feature. |
| No backup, restore, or out-of-band access | `docs/07-operations.md` |
| microVMs reach the overlay to pull images | Node-local pull-through proxy; the VM's only route is one port |
| `vpc_networks` destination from user input | Static allowlist; lint rule; one call site |
| "Single-tenant by construction" | Single-tenant per organisation, **not** per job — CI runs untrusted code |
| Worker holds all credentials | Stated as residual risk, with blast-radius controls |

---

## Revision 4: the contract was too narrow

Revision 3's adapter had two targets — Cloudflare and self-hosted — which silently assumed
that "swap to another hosted backend" meant "swap the whole platform". It does not, and the
distinction matters:

- **The application runtime** has exactly two real targets. Nothing but `workerd` runs Workers
  code. Rivet and E2B do not, and a design that implies otherwise is promising a portability
  it cannot deliver.
- **Capabilities** — storage, sql, queue, sandbox, actors — are swappable per deployment and
  cost config, not code.

`docs/01-portability.md` now separates the two levels, gives the capability matrix across
Cloudflare / self-hosted / hosted third parties, and quantifies the change for each swap:
0 lines for an app inside the subset, an adapter implementation for the 13 forks, a rewrite for
anything outside it.

## What revision 3 gives up

Honest accounting of what the simplification costs:

| Lost | Consequence |
|---|---|
| Nomad's scheduler | no gang scheduling, no preemption, no affinity beyond labels. Fine below ~200 nodes. |
| Incus's VM API | creating a VM is now "run the installer in a VM you made some other way". Provisioning is out of scope. |
| Nomad's ACL and mTLS | the agent's capability policy and node credential replace it; weaker, simpler |
| SeaweedFS as a component | storage is an S3 URL; you still have to run the store somewhere |
| A second control plane | no HA for the scheduler — the control plane is D1 and a Worker, which is Cloudflare's HA, not yours |

If any of those become requirements, add the component back. They are not requirements for
running CI and long-lived containers, which is what this is for.
