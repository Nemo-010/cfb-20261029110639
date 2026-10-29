# 09 — Build order

Each phase is usable on its own. Do not parallelise; each changes what "normal" looks like.

---

## Phase 0 — the manager (1 week)

- [ ] Worker + Hono + Static Assets
- [ ] D1 schema (nodes, workloads, jobs, audit)
- [ ] Cloudflare Access in front
- [ ] `NodeDO` with connection fencing
- [ ] A fake agent that connects and reports, so the UI is real before the fleet is

**Done when:** you can log in and see one fake node.

---

## Phase 1 — the agent (2 weeks)

- [ ] `cfbd` binary: config, dial, reconnect with backoff
- [ ] Control RPC: `msg_id` correlation, `disconnected` on drop
- [ ] Streams: open/data/window/close with credit flow control
- [ ] `exec` capability, streaming stdout/stderr
- [ ] `metrics` capability
- [ ] Local unix-socket API: `status`, `ps`, `logs`, `doctor`
- [ ] Enrolment: token exchange, credential at `0600`

**Done when:** a real node connects, reports, and `cfbd doctor` answers offline.

**This is the phase to get right.** Everything else is a capability on top of it, and the
protocol is the part you cannot change later without a fleet-wide upgrade.

---

## Phase 2 — workloads (2 weeks)

- [ ] Container runtime detection: containerd → Docker → systemd units
- [ ] `container.start/stop/rm` with cgroup limits
- [ ] Restart policy with crash-loop budget
- [ ] Log ring buffer + shipping
- [ ] Desired-state reconcile: generation diff, idempotent apply
- [ ] Control-plane placement (filter + sort)

**Done when:** a CI job runs from the dashboard, with a live log and a stored artifact.

---

## Phase 3 — storage (1 week)

- [ ] `STORAGE_URL` parsing, S3 client in the agent
- [ ] Presign locally; upload never transits the Worker
- [ ] Bucket layout and lifecycle rules
- [ ] Move artifacts off R2; keep logs on R2

**Done when:** artifacts flow without touching Cloudflare.

---

## Phase 4 — portability (2 weeks)

- [ ] `@cfb/port` adapter with the seven surfaces
- [ ] Lint rule: runtime checks only in `packages/port/`
- [ ] Dual-build CI: same test suite against Cloudflare and `workerd`
- [ ] Fork tests `portability/fork-NN`
- [ ] Migrate one real app through the contract

**Done when:** one app builds twice from one source and passes the same tests.

This phase is the product. Without it the self-hosted side is a separate codebase, which is
what the whole design exists to avoid.

---

## Phase 5 — Workers runtime (1 week, optional)

- [ ] `workerd` as a supervised child process
- [ ] Bundle upload + `config.capnp` generation
- [ ] Swap on deploy
- [ ] Only if needed: celld for DOs, one fleet per app, dedicated bucket

**Done when:** an app you already run on Cloudflare runs on your metal, and rolling back is a
DNS change.

---

## Phase 6 — isolation (2 weeks, optional)

- [ ] Firecracker rootfs pipeline (OCI → ext4, content-addressed)
- [ ] Slot allocator: tap device, /30 from a /16, nftables per slot
- [ ] Jailer: seccomp, cgroups, chroot, uid
- [ ] Node-local pull-through proxy (the VM's only route)
- [ ] Rootfs GC

**Done when:** an untrusted build has no route anywhere except one port on its own node.

---

## Total

6–9 weeks for one engineer to Phase 4. Phases 5 and 6 are optional and can wait until a
specific workload demands them.

---

## What to cut

In order:

1. **Phase 6** — until a workload runs code you did not write.
2. **Phase 5** — Workers apps keep working on Cloudflare for $5/month.
3. **Phase 3** — R2 is a fine storage backend; the agent already speaks S3 to it.

Do not cut: the agent, the manager, portability. Those three are the project.

---

## The number to watch

Time from push to artifact. If it has not improved within a month of Phase 2, stop and
reconsider — you are building infrastructure for its own sake, which is the failure mode this
design is trying to avoid.
