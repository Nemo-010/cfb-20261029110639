# Survey

Every candidate evaluated, with the mechanism worth taking and the reason for the verdict.
Licences verified against the repository on 2026-10-29.

Verdicts: **adopt** (in the stack) · **borrow** (take the mechanism) · **reference** (read it,
copy nothing) · **reject**.

---

## Agents, tunnels, brokers

| Project | Licence | Verdict | Mechanism worth taking | Why not adopted |
|---|---|---|---|---|
| **talaria0101/cfrs** | 0BSD | borrow | Unprivileged socket interposition: every `AF_INET` sockaddr rewritten to the `AF_UNIX` abstract name `\0cfrsnet/<family>/<ip>/<port>` (`shim/cfrsnet.c:to_abstract`), so an unmodified binary binds real addresses with no root, no netns, no `CAP_NET_ADMIN`. Multiplexed over one control stream, `u8 op \| u16 len \| payload`. | Tunnel side is primitives only — registration is unimplemented, `cfrs tunnel` serves nothing. |
| **rivet-gg/rivet** | Apache-2.0 | borrow | Multiplexed HTTP/WS-over-WS tunnel with `(GatewayId, RequestId)` streams and credit-based flow control (`pegboard-gateway3/src/http_stream/handler.rs`). Connection-ownership fencing: a reconnecting envoy atomically evicts its predecessor via a monotonic `EnvoyConnIdKey`. | Not a runtime: no workerd, no Workers API. Requires rewriting apps to its actor API. "One binary and a bucket" still needs UniversalDB and local NVMe. |
| **ZingerLittleBee/ServerBee** | AGPL-3.0 | reference | `msg_id`-correlated request/reply over one agent-dialed WebSocket (`server/src/service/agent_manager.rs:573`), with waiters dropped on disconnect so callers get `Disconnected` instead of hanging. Capability bitmask owned by the **agent**, mirrored read-only by the server. Trial-window self-upgrade with automatic rollback. | AGPL — copy nothing. Also no inbound data plane: everything is JSON RPC, 1 MiB frame cap, which rules it out as a proxy. |
| **timhartmann7/omnyssh** | MIT | reference | `TunnelManager::start` → `run_tunnel` → `serve` + `bind_all`: listeners are bound before the first dial and held across reconnects, with stability-gated backoff. | Client-side SSH fleet manager with no agent or control plane. |
| **metalbear-co/mirrord** | MIT | reference | `protocol-io`'s per-queue fair-queued multiplexer (`Connection::from_stream`, `io_task`, `SharedState::{try_push,poll_next}`). | LD_PRELOAD + iptables interception is Kubernetes-coupled and far heavier than needed. |
| **Pouzor/homelable** | MIT | reference | Field-level state merge with precedence (`ieee > ip > mac`) and "an absent field is silence, not a reset" (`device_merge.py`, `inventory_sync.py`). | Homelab visualisation app; no tunnel, broker, dispatch or supervision. |
| **crocofied/CoreObs** | — | reject | — | 225-line auth scaffold, single commit, README describes an unbuilt product. |
| **gofixpoint/amika** | Apache-2.0 | reference | Tunnel multiplexer codec (`js/tunnel-protocol`, 479 lines) and service-token signing (`js/service-auth`, 269 lines) — both Worker-safe. | Control plane, UI and relay are closed source; `--local` was removed; every command talks to `app.amika.dev`. No scheduler, KVM-only, one VM per rig. |
| **coder/coder** | AGPL-3.0 | reject | Outbound-only agent plus a same-listener DERP relay — the most tunnel-compatible ingress model surveyed. | Not a CI executor: no pipeline engine, no artifact store, no SCM trigger. External provisioners and prebuilds are Premium. |
| **hashicorp/nomad** | BUSL-1.1 | reject | Batch jobs with parameterized dispatch map onto CI exactly; servers proxy `/v1/client/fs/logs` so only 4646 needs exposing. | Creates no machines, quotas are a no-op in CE (`plan_apply_ce.go`), and its Raft must not cross Cloudflare — a second control plane for scheduling the agent can do. MPL until v1.6.10; BUSL from 1.7.0. |
| **lxc/incus** | Apache-2.0 | reject | One REST API for VMs and system containers, projects with real quota limits. | A second API and auth model for a job the agent does with the runtime already on the host. mTLS is unusable through `cloudflared`; no `X-Forwarded-For` anywhere in the tree. |
| **daytonaio/daytona** | — | reject | — | Repository archived 2026-07-24, `main` gutted to a README after the 2026-06-11 closed-source move. |

---

## Workers runtimes

| Project | Licence | Verdict | Notes |
|---|---|---|---|
| **cloudflare/workerd** | Apache-2.0 | adopt | The actual runtime, 9,093 stars, daily releases, 236 contributors. Runs a Worker from a `config.capnp`; single-tenant; `ctx.container` is a Docker shim for dev only. Cluster mode landed on `main` 2026-10-29 in PR #7994 — **in no released binary**, `--experimental`, no alarms. |
| **denoland/celld** | Apache-2.0 | adopt (conditional) | 6,169 stars, v0.6.3, 2 contributors, 14 commits, no published tests. Runs Workers, DO, KV, Queues, D1, R2, Workflows, Cron from an unmodified `wrangler.json`. **One application per fleet.** Requires an object store with conditional writes, exact ranged reads and read-after-write consistency. |
| **cloudflare/miniflare** | MIT | reference | A simulator. Useful for tests, not for serving. |
| **wasmCloud** | Apache-2.0 | reject | Component model, not the Workers model. Different programming surface, so it fails the portability requirement by construction. |

---

## Object storage

| Project | Licence | Verdict | Notes |
|---|---|---|---|
| **R2** | proprietary | adopt | $0.015/GB-mo, free egress, 5 TiB objects. No ACLs, bucket policies or S3 object-lock API — but it does have **Bucket Locks** (retention, indefinite). Rounding to the billing unit sets the bill on churny data. |
| **seaweedfs/seaweedfs** | Apache-2.0 | adopt (large deployments) | 35,799 stars, ~978k LOC, 59% of the last 100 commits from one author. Only OSS S3 clone whose `If-None-Match`/`If-Match` writes are atomic across gateways — owner-filer routing plus a per-path mutex, not backend CAS. **S3 auth is off by default.** |
| **rustfs/rustfs** | Apache-2.0 | adopt (tier 2) | 35,525 stars, 1.0 shipped 2026-09-16. Real Reed–Solomon EC. `If-None-Match: *` works; **`If-Match` etag CAS returns 501**, so create-if-absent only. Ported from MinIO's Go code; CLA permits relicensing. |
| **deuxfleurs-org/garage** | AGPL-3.0 | reject (for celld) | Simplest to operate of the lot, but conditional writes are *"structurally impossible … due to the lack of a consensus algorithm"*. Fine for artifacts, disqualifying for a celld fleet bucket. |
| **minio/minio** | AGPL-3.0 | reject | Repository archived — *"THIS REPOSITORY IS NO LONGER MAINTAINED"*. AIStor Free is single-node only, redistribution prohibited. |
| **Ceph RGW** | LGPL-2.1 | reject | Most complete S3 surface, heaviest to operate. Conditional-write behaviour unverified. |
| **VersityGW / JuiceFS / Zenko** | Apache-2.0 / Apache-2.0 / Apache-2.0 | reject | A gateway, a filesystem, and a CI emulator respectively. None is a store. |

---

## Compute and isolation

| Project | Licence | Verdict | Notes |
|---|---|---|---|
| **firecracker** | Apache-2.0 | adopt (optional) | ≤125 ms to `/sbin/init`, ≤5 MiB overhead. A VMM, not a product: no images, no networking policy, no snapshot management. The jailer is mandatory. |
| **e2b-dev/E2B** | Apache-2.0 | borrow | `e2b-dev/runtime` is the real orchestration layer (Go, Apache-2.0). Embed runs the whole stack on one machine — *"one machine, by design"*; multi-node, BYOC and the `belt` volume API are not in the public repo. 21 services, 12 images, 13 host ports, port 5008 unauthenticated. |
| **microsandbox** | Apache-2.0 | reject | Not a Firecracker wrapper — pins `msb_krun`, a libkrun fork. 484k LOC, no seccomp, no namespaces, no cgroups around the VMM. Containerd shim still an open PR. |
| **kata-containers** | Apache-2.0 | reference | The right answer if the orchestrator already speaks CRI. It is a CRI shim, not a sandbox API. |
| **gVisor** | Apache-2.0 | reference | No KVM needed, worst case for syscall- and fork-heavy CI. |

---

## Connectivity

| Project | Licence | Verdict | Notes |
|---|---|---|---|
| **cloudflare/cloudflared** | Apache-2.0 | adopt | Outbound-only QUIC/HTTP2 connector. Public hostnames carry HTTP/HTTPS/UNIX/TCP/SSH/RDP/SMB over WebSocket — **no UDP**. 1,000 tunnels/account, 50,000 routes, 25 replicas/tunnel. Auto-updates and restarts daily by default. |
| **Cloudflare Workers VPC** | proprietary | adopt (beta) | `vpc_services` (host:port) and `vpc_networks` (whole tunnel, Mesh, or WAN). HTTP via `fetch()`, raw TCP via `connect()`. Beta, free while beta; requires QUIC with outbound UDP 7844. |
| **Cloudflare Mesh** | proprietary | adopt (small fleets) | **50 nodes per account.** IP routing only from Workers. |
| **juanfont/headscale** | BSD-3 | adopt (optional) | Self-hostable coordination server; no hardcoded node cap. Needed because celld's peer traffic is plaintext HTTP. Effectively single-maintainer; depends on Tailscale's DERP fleet by default. |
| **NetBird / Nebula** | BSD-3 / MIT | reference | Viable overlays; neither offers anything headscale does not for this shape. |

---

## Cloudflare open source

| Project | Licence | Usable on your metal |
|---|---|---|
| `workerd` | Apache-2.0 | **yes** — the runtime |
| `cloudflared` | Apache-2.0 | **yes** — the connector |
| `pingora`, `quiche` | Apache-2.0 | yes — libraries, not products |
| `miniflare` | MIT | yes — as a simulator |
| `workers-sdk` / `wrangler` | MIT/Apache-2.0 | yes — build tooling |
| `containers`, `sandbox-sdk`, `agents` | — | no — clients for hosted products |
| `amika`'s relay pattern | Apache-2.0 | partially — the two JS files above |

---

## The short version

Take **workerd** for the runtime, **cfrs**'s address-space trick if you need unprivileged
networking, **rivet**'s tunnel framing and connection fencing, **ServerBee**'s capability
model (reimplemented), and **R2 or SeaweedFS** for storage. Everything else on this list is
either a client for a hosted product, a second control plane you do not need, or archived.
