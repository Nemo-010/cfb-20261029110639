# 11 — Build order

Sequenced so that each phase delivers something usable, and so that the least mature
components come last. Do not parallelise phases; each one changes what "normal" looks like
and you want to learn its failure modes in isolation.

---

## Phase 0 — the manager exists (1 week)

Nothing to manage yet, but you need the surface.

- [ ] Worker + Hono + Static Assets skeleton
- [ ] D1 schema: nodes, jobs, audit
- [ ] Cloudflare Access in front
- [ ] One `NodeDO`
- [ ] A fake node that heartbeats, so the UI is real before the fleet is

**Done when:** you can log in, see one fake node, and read its health.

**Why first:** because a dashboard built after the fleet is a dashboard shaped by the fleet's
accidents. Build the contract first and make the substrate fit it.

---

## Phase 1 — connectivity (1 week)

- [ ] One `cloudflared` on the gateway host, QUIC, pinned version, auto-update off
- [ ] `vpc_networks` binding in the Worker
- [ ] A relay that answers `/health` and nothing else
- [ ] Second connector on a second host
- [ ] Access service token as the fallback path, behind a flag

**Done when:** the Worker can call the relay's `/health` over VPC, and the fallback works when
you force it.

**Trap:** test with an `http2` tunnel once, deliberately, so you recognise the failure. It
looks like a DNS problem and it is not.

---

## Phase 2 — the overlay (1 week)

- [ ] headscale on one small host
- [ ] Every machine enrolled, with preauth keys minted by the API
- [ ] ACLs: nodes can reach the substrate APIs and each other, nothing else
- [ ] A DERP relay if you do not want to depend on Tailscale's

**Done when:** two machines can talk to each other by overlay address and cannot talk on the
flat LAN.

**Why before Nomad:** because Nomad's Raft must never touch the tunnel, and you want the
overlay proven before you build on it.

---

## Phase 3 — CI on Nomad (2–3 weeks)

The phase that pays for the project.

- [ ] Nomad servers ×3, advertised on overlay addresses
- [ ] Nomad clients on the CI nodes
- [ ] `batch` job with parameterized dispatch
- [ ] A supervisor that runs one job and streams its log
- [ ] Worker: submit, poll, cancel, stream logs via SSE
- [ ] Artifacts to SeaweedFS with presigned PUT

**Done when:** a real build runs end to end, triggered from the SPA, with a live log, and the
artifact lands in a bucket.

**Start with containers, not microVMs.** Get the whole path working with the `docker` driver
on trusted code, then swap the isolation layer in Phase 5. If you start with Firecracker you
will debug the image pipeline and the job pipeline at the same time.

---

## Phase 4 — storage (2 weeks)

- [ ] SeaweedFS 3 nodes, Postgres filer backend
- [ ] `s3.json` with explicit users — **before** the gateway is reachable
- [ ] Gateway on 8333, reached over the overlay only
- [ ] Lifecycle rules on the cache bucket
- [ ] CAS probe as an hourly `sysbatch` job
- [ ] Move artifacts off R2; keep logs on R2

**Done when:** the CAS probe passes hourly and artifacts flow without touching Cloudflare.

**Trap:** the probe is the whole point. If you skip it you will discover a storage regression
as data corruption.

---

## Phase 5 — isolation (2–4 weeks)

- [ ] Firecracker image pipeline: OCI → ext4, content-addressed
- [ ] Per-job tap device, /16 slot allocator, nftables egress policy
- [ ] Jailer: seccomp, cgroups, chroot, dedicated uid
- [ ] Snapshot and resume for the template cache
- [ ] GC job for orphaned snapshots

**Done when:** an untrusted build runs with no route to the node's overlay address or the
Nomad client API — its only reachable destination is the node-local pull-through proxy on one
port, which holds the storage credentials the VM never sees.

**Alternative:** E2B Embed instead, in which case this phase is "deploy and harden" and takes
a week — but you get one node and no volumes, and you must bind 5008 to loopback.

---

## Phase 6 — machines (1 week)

- [ ] Incus cluster on the provisioning hosts
- [ ] OIDC relay, because mTLS does not survive the tunnel
- [ ] Profiles for the standard shapes
- [ ] Create/delete from the SPA
- [ ] cloud-init that enrols the new VM automatically

**Done when:** you can create a VM from the dashboard and it appears as an enrolled node
without a shell.

---

## Phase 7 — celld (optional, 2–4 weeks)

Only if you actually need self-hosted Workers/DO.

- [ ] One fleet, one application, one dedicated bucket
- [ ] Nodes as Nomad `service` jobs
- [ ] Ingress proxy terminating TLS
- [ ] Peer listener on the overlay only
- [ ] Deploy from the SPA

**Done when:** an application you already run on Cloudflare runs on your metal, and you can
roll back by pointing DNS at Cloudflare again.

**Keep the rollback path for a month.** celld is beta, and the honest expectation is that you
will find something.

---

## Total

Roughly 10–14 weeks for one engineer, with Phase 5 being the uncertain one. If you use E2B
Embed it is 6–8 weeks.

That estimate assumes you have run a scheduler and a storage cluster before. If you have not,
double Phase 3 and Phase 4.

---

## What to cut if you are short on time

In order, cut:

1. **celld** — Workers apps keep working on Cloudflare for $5/month.
2. **Incus** — create VMs by hand until it hurts; the pain will tell you what the API needs.
3. **The overlay** — only if you have fewer than 50 machines and one site, where Cloudflare
   Mesh is genuinely adequate. You will need it later; do not pretend otherwise.
4. **MicroVM isolation** — only if every job runs your own code. The moment a dependency's
   `postinstall` script runs, this becomes untrue.

Do not cut: the manager, the tunnel, Nomad, storage. Those four are the project.

---

## The first thing to measure

Time from "push" to "artifact available". If that number does not improve over your current
setup within a month of Phase 3, stop and reconsider — you are building infrastructure for
its own sake, which is the failure mode this whole document is trying to avoid.
