# microVM primitives (Firecracker / microsandbox / Kata) — deep review

## Verdict

**microsandbox is the wrong choice for the production slot, and Firecracker is the right primitive — but neither is a platform, and that gap is where this decision actually lives.** microsandbox is not a microVM primitive at all: it is a 484,726-line, single-host, batteries-included sandbox *product* built on a fork of **libkrun, not Firecracker** (`Cargo.toml:99` pins `msb_krun = "=0.1.42"`; `crates/runtime/lib/runner/vm.rs:3-6` hands control to `Vm::enter()` from `msb_krun`). It gives you OCI→ext4 image building, a userspace TCP/IP stack, secrets substitution, and live snapshot/fork — genuinely impressive, and the single best reference implementation of "what you still have to build" that I read for this study. But it has **no seccomp, no namespaces, and no cgroups around the VMM** (zero grep hits across 484k lines), it runs the VMM as whatever uid launched it (`docs/security/isolation.mdx:21`), and its containerd/CRI seam — the only clean way into a non-Cloudflare orchestrator — is **PR #1167, still open since 2026-07-11**. Put **Firecracker + jailer** under your own scheduler if you are building the control plane yourself; put **Kata** there instead if your orchestrator already speaks CRI. Use microsandbox as a dev-loop tool and a design reference, not as the isolation boundary under untrusted CI. See "Rejected / not for this" for the one condition that would flip this.

## What it actually is

**microsandbox** — a single-host sandbox runtime with an unusually complete feature set and an unusually thin trust boundary. 0.7.11, Apache-2.0, created 2024-10-03, 8,860 stars, 497 forks, 148 open issues+PRs, 26 watchers. README self-describes as **beta** with "breaking changes, missing features, and rough edges" (`README.md:119`). 14 crates under `crates/` totalling 270,906 lines, 484,726 lines of Rust repo-wide. 863 packages in `Cargo.lock`, 103 direct workspace dependencies.

What the README claims vs what it is:

| README claim | Reality |
|---|---|
| "microVMs" (`README.md:38`) | True, but the VMM is **libkrun** (their fork, `msb_krun`), not Firecracker. Different device model, different security posture, different snapshot semantics. |
| "Instant Startup … under 100 milliseconds" (`README.md:43`) | Footnote says **"Boot time refers to guest boot on an M1 machine"** (`README.md:486`). That is guest kernel boot only — not image pull, not ext4 format, not layer extraction, not sandbox-ready. No benchmark suite exists in the repo to check the end-to-end number. |
| "No setup server. No long-running daemon." (`README.md:44`) | Literally true — there is no local control-plane daemon. There is, however, **one full VMM process per sandbox** (`msb machine`), plus a shared SQLite catalog. |
| "Secrets That Can't Leak" (`README.md:45`) | True only for HTTP(S) through a TLS-MITM proxy. Non-HTTP protocols and cert-pinned clients get a placeholder, not a credential. |
| "OCI Compatible" (`README.md:41`) | True and substantial — they wrote their own ext4 and EROFS formatters. |

**Firecracker** — the actual primitive. Apache-2.0, AWS-backed, 37,695 stars, created 2017-10-19, pushed 2026-10-29. A VMM and a jailer binary. Nothing else. No image management, no networking, no scheduler, no snapshot packaging.

**Kata Containers** — a containerd **shimv2** runtime that turns microVMs into Kubernetes pods. Apache-2.0, OpenInfra Foundation, 9,044 stars, 1,247 open issues. One shim per pod, several containers per VM, VMM backends QEMU / Cloud Hypervisor / Firecracker / Dragonball (`docs/hypervisors.md`). It is a *seam*, not a primitive.

## Architecture (with file paths)

### microsandbox process model — one VMM process per sandbox, no supervisor

```
msb CLI (50.32 MiB)  ──spawn──>  msb machine (VMM in-process via libkrun)
        │                              │
        │                              ├── virtio-console ──> agentd (PID 1, 2.47 MiB)
        │                              ├── virtio-net ──────> smoltcp userspace stack (1 OS thread)
        │                              ├── virtio-fs ───────> host dirs (passthrough)
        │                              └── virtio-blk ──────> ext4 root
        └── ~/.microsandbox/msb.db (SQLite, WAL)  <── every host-side process writes here
```

- `crates/cli/lib/machine_cmd.rs:1-6` — "This command **never returns** — the VMM calls `_exit()` on guest shutdown." Same in `crates/runtime/lib/runner/vm.rs:1-6`. The VMM is a *library* linked into the sandbox process, not a separate binary. **There is no `firecracker`-style separation between a launcher and a VMM, and therefore no natural place to put a jailer.**
- Config is passed over inherited fd 96 (`crates/runtime/lib/client/launch.rs:32`, `CONFIG_FD`), not argv, so secrets stay out of `ps`/`/proc/<pid>/cmdline` (issue #997 referenced at `launch.rs:6-7`). This is a thoughtful, real security control.
- Device model is exactly five virtio devices (`docs/security/isolation.mdx:34-38`): console, net, fs, blk, rng. No PCI passthrough, no host sockets, no shared memory beyond those.
- Guest control channel is `virtio-console`, host-driven, **explicitly unauthenticated by design** (`docs/security/isolation.mdx:44-49`): "The channel has no cryptographic authentication, and doesn't need one. It is a virtio device wired to exactly one VM." Correct reasoning — but it means the whole guest-side control plane trusts the hypervisor's device isolation, which is the thing you are trying to bound.
- `agentd` is PID 1 as root, and **workload commands run as root by default** (`docs/security/isolation.mdx:60-62`). `--security restricted` opts into `no_new_privs` + `CAP_SYS_ADMIN` drop, and is documented as incompatible with `sudo` and Docker-in-Docker.

### Networking — userspace netstack, no TAP, no root

This is microsandbox's biggest genuine architectural differentiator and its biggest throughput risk.

- `crates/network/lib/engine/netstack/backend.rs:37` — `SmoltcpBackend` "bridges libkrun's NetWorker to smoltcp via lock-free queues."
- `crates/network/lib/engine/netstack/poll.rs:1-5` — "the core networking event loop that runs on a **dedicated OS thread**." One thread per sandbox. MTU 1500 (`poll.rs:1546` et al.).
- `crates/network/lib/engine/network.rs:53-79` — `SmoltcpNetwork` holds guest/gateway MAC and IPv4/IPv6, MTU, TLS state, secrets handle.
- Consequence: **no `/dev/net/tun`, no bridge, no `CAP_NET_ADMIN`, no root.** Zero grep hits for `TUNSETIFF` or `/dev/net/tun` in `crates/`. This is a real operational win over Firecracker.
- Cost: every byte is copied through one poll thread with no visible GRO/TSO. `docs/networking/overview.mdx:455` confirms published ports are "one host socket per port" — so a 1,025-port range is 1,025 host sockets.
- Historical evidence of how young this path is: `docs/changelog/2026-06-05.mdx:99` — "Non-loopback published-port throughput is **no longer throttled to roughly 30 to 120 KB/s**." That is a 100× bug in the exact path a CI runner would use.

### Images — they wrote a filesystem

This is the part I would flag hardest to a reviewer who only read the README.

- `crates/image/lib/ext4/` — **7,965 lines** implementing ext4 from scratch: superblock, group descriptors, extents, block/inode bitmaps, `metadata_csum`, `resize_inode`, and a **JBD2 journal** (`formatter.rs` imports `JBD2_MAGIC`, `JBD2_SUPERBLOCK_V2` at lines 16-17). Plus a resizer (`resizer.rs`, 2,811 lines).
- `crates/image/lib/erofs/` — **3,857 lines** of EROFS writer/reader.
- OCI pull, layer stacking, and CoW layering in `crates/image/lib/{pull,registry,layer,stitch,cache}`.
- Two root layouts: **layered** (default, shared read-only layers + writable layer, supports snapshots/patches) and **flat** (private ext4 clone per sandbox, faster, **no snapshots**) — `docs/sandboxes/optimization.mdx:38-52`.

A hand-rolled ext4 with a journal is the single highest-consequence component here. A bug does not crash; it silently corrupts a CI workspace after a `fsync`.

### Snapshots — the strongest thing in the repo

`crates/runtime/lib/checkpoint/` is **14,329 lines** (`coordinator.rs` 128 KB, `disk.rs` 100 KB, `local_memory.rs` 45 KB, `restore.rs` 38 KB). Capabilities, all verified in `docs/sandboxes/snapshots.mdx`:

- **Disk** and **Full** (disk + memory + running processes). No memory-only type (`snapshots.mdx:15-19`).
- **CoW memory sharing** across restores (`cowMemory` / `--cow-mem`), so N forks share unchanged pages.
- **Fork** a live sandbox directly, including `forkMany` for batches.
- **Snapshot groups** with ancestry-tracked heads, immutable members since v0.7, layer **compaction**, opt-in **integrity hashing**, and `.msb` archives with `--since` base-diff export.
- **Nested VM snapshots** (a VM inside the VM, resumed together) — genuinely unusual, and something Firecracker cannot do (no nested virt).

Constraints that matter operationally: capture timeout 30 minutes (`snapshots.mdx:21`); full restore requires **matching CPU and memory settings and a compatible runtime + guest kernel** (`snapshots.mdx:299`); **"Cross-host migration … not guaranteed"** (`snapshots.mdx:40`); host-side connections are not captured, so every client must reconnect.

### Shared state — one SQLite file, every process

`crates/db/lib/pool.rs:1-5`: "Both the host CLI and the in-VM runtime open the same SQLite file and must apply identical PRAGMAs (**WAL, busy timeout, foreign keys, synchronous=NORMAL**)." Home dir is `~/.microsandbox` (`crates/utils/lib/lib.rs:19`). Every sandbox's `msb machine` process writes to it. This is the coordination point, the contention point, and the corruption blast radius — and it is **per host**, so N hosts means N independent catalogs with no shared view.

### Firecracker's model, for contrast

- One process = one microVM. Threads: API, VMM, one vCPU per core (`docs/design.md:59`).
- **Jailer** (`docs/jailer.md`) does the work microsandbox does not: `chroot` + `pivot_root`, new mount namespace, optional `--new-pid-ns`, cgroup creation, `setrlimit` (`no-file` default 2048, `fsize`), `mknod /dev/kvm` and `/dev/net/tun` inside the jail, then drops to `--uid`/`--gid`.
- **seccomp filters installed by Firecracker itself, per-thread, before guest code runs** (`docs/design.md:104-110`).
- Devices: virtio-net, virtio-block, virtio-vsock, serial, i8042, MMDS. **No virtio-fs. No virtio-console.** (`docs/design.md:77`)
- Networking is **TAP-backed** and unfiltered: "Firecracker does not perform any network traffic filtering. All egress traffic from a guest is therefore considered untrusted, and should be filtered at the host-level." (`docs/design.md:51,67`)
- Density: "5 microVMs per host core per second … 180 microVMs per second on a host with 36 physical cores" at 1 vCPU / 128 MiB (`docs/design.md:28`).
- Snapshots: full + diff (diff "still in developer preview", `snapshot-support.md:73`), `MAP_PRIVATE` CoW memory, integrity is **a 64-bit CRC only** (`snapshot-support.md:65`), and — critically — **"provides no functionality to package or manage them on the host"** (`snapshot-support.md:59`).

### Kata's model

- `containerd-shim-kata-v2` implements shimv2; one shim per pod, several containers per VM (`docs/design/architecture/README.md:39-55`).
- Rootfs via virtio-fs; guest agent over **ttRPC on vsock** (`README.md:202`).
- Requires a container manager (containerd or CRI-O). It has no standalone story.
- VMM backends: QEMU, Cloud Hypervisor, Firecracker, Dragonball (`docs/hypervisors.md:48-60`).

## The seam into this design

Your design: dashboard on Workers, machines reached over Tunnel/Mesh/VPC, orchestration deliberately not Cloudflare, heavy CI and long-running containers. So the microVM layer sits **on the box, under your scheduler, behind a Tunnel egress**. The question is what your scheduler talks to.

**Where microsandbox would plug in:** your node agent shells out to `msb` (or embeds the Rust SDK) to create a sandbox per CI job, then `exec`s into it. That works today. It gets you OCI images, fast boot, no root, and — uniquely — **fork from a warm snapshot**, which is the single most valuable property for CI (checkout + install + build cache in a pre-baked full snapshot, fork per job).

**Where it will not plug in:**
1. **No scheduler.** `CpuPlacement` (`packages/microsandbox-types/rust/lib/domain.rs:1077-1092`) is per-VM vCPU thread affinity — `Inherit | Auto | Spread | Compact`. That is *not* bin-packing, placement, or cluster scheduling. There is no membership, no lease, no node registry, no health endpoint. You write all of it.
2. **The real seam is unmerged.** PR #1167, "Feat/microsandbox oci runtime", open since 2026-07-11, adds `runmsb` so "Docker and the stock containerd-shim-runc-v2 can run one container per Microsandbox microVM." That is precisely the interface that would let an existing orchestrator drive it. It is a PR, not a release. Until it lands, integration means a bespoke supervisor around a CLI whose own docs say the command never returns.
3. **No stable network identity.** Published ports are host sockets, one per port. Behind Cloudflare Tunnel that is survivable, but there is no service discovery, no per-sandbox DNS name, no address that survives a restore.
4. **Snapshot portability is host-local.** Restore requires matching CPU/memory and a compatible runtime+kernel, and cross-host migration is explicitly not guaranteed. Your scheduler cannot treat snapshots as portable artifacts across a fleet.
5. **No GPU.** Issue #291, open since 2025-07-07, 22 comments. If any CI workload is GPU, this is disqualifying.
6. **Their own cloud doesn't run full snapshots.** `docs/cloud/overview.mdx` lists snapshots as "Limited on cloud — live capture, full checkpoints, forking, groups … remain local-only." The vendor has not made the flagship feature work multi-host.

**Where Firecracker plugs in:** a REST API over a per-VM unix socket. Your scheduler creates a VM, configures drives and NICs, boots it. You own: TAP/bridge setup or a CNI plugin, image→block-device pipeline, snapshot storage and packaging, health, and the API socket's auth (there is none beyond filesystem permissions — the jailer's chroot is the control).

**Where Kata plugs in:** CRI. If your orchestrator is Kubernetes, this is a `RuntimeClass` plus a shim install. That is the only one of the three that is a *drop-in*.

**Capability matrix — what you get vs what you build:**

| Capability | Firecracker | microsandbox | Kata |
|---|---|---|---|
| Isolation primitive | VMM + seccomp + jailer | libkrun VMM, **no seccomp/jail** | VMM + shim + agent |
| Host networking | **build** (TAP, CNI) | userspace stack, no root | via CNI |
| Image build | **build** (you need ext4/OCI→disk) | **included** (own ext4+EROFS) | via CRI images |
| Snapshot mgmt | **build** (no packaging) | **included** (best in class) | via CRI, weaker |
| Scheduling | **build** | **build** | **included** (K8s) |
| Multi-host | **build** | **build** (host-local only) | **included** |
| Root required | yes (jailer, TAP) | **no** | yes |
| GPU | no | no | yes (VFIO) |

## Limits and failure modes

**Quantified footprint (microsandbox, v0.7.11 linux-x86_64):**

| Artifact | Size |
|---|---|
| `msb` binary | **50.32 MiB** |
| `libkrunfw-linux-x86_64.so` (guest kernel blob) | **20.63 MiB** |
| `agentd-x86_64` (in-guest PID 1) | **2.47 MiB** |
| `libmicrosandbox_go_ffi-linux-amd64.so` | 35.65 MiB |
| `msb-metrics-linux-x86_64` | 8.20 MiB |

~73 MiB of host tooling before a single VM boots, plus one full guest kernel image resident per running VM. Compare Firecracker's single static binary (order 1–2 MiB, BELIEVED — I did not build it and will not invent a number).

**Dependency surface:** 863 crates in `Cargo.lock`, 103 direct workspace deps. **Four maintained forks** that Super Rad Company must keep rebased:
1. `superradcompany/libkrun` → published as `msb_krun` (Apache-2.0, 7 stars on the fork)
2. `superradcompany/smoltcp` → `msb_smoltcp`, pinned `=0.14.0`, with a comment at `Cargo.toml:155` that it is a "Temporary scheduling fix for smoltcp-rs/smoltcp#1214"
3. `superradcompany/imago` → `msb-imago` (qcow2)
4. `superradcompany/libkrunfw` → the kernel blob, branch `krunfw` (`.gitmodules`)

Every one is a divergence that grows. The smoltcp one is explicitly temporary and pinned by exact version.

**The jailer gap — the finding I would lead with in a security review.** `grep -rn "seccomp" --include=*.rs .` returns **zero hits repo-wide**, and there is **no `seccomp` or `landlock` crate in `Cargo.lock` at all** — the project does not even depend on a library that could install a filter. `grep -rn "unshare|CLONE_NEW|setuid|setgid" crates/` returns hits only inside `agentd` (guest-side, for the workload process: `PR_SET_NO_NEW_PRIVS` at `session.rs:1503`, `PR_CAPBSET_DROP CAP_SYS_ADMIN` at `session.rs:1545`, `setuid/setgid` at `session.rs:1812-1815`) and inside `filesystem` (setuid-bit stripping). **There is no host-side namespace, no cgroup, no seccomp, no privilege drop around the VMM.**

libkrun's own security model doc (`libkrun/docs/security-model.md`) is explicit that this is required and not provided:

> "The VM boundary alone does not restrict the host resources exposed through those devices."
> "**Host Namespace Isolation**: … On Linux, the primary mechanism is namespaces (user, mount, network, PID, IPC)."
> "**UID / GID Constraints**: … ensure the VMM runs with dedicated, unprivileged UID/GID mappings."
> "**virtio-fs**: Do not treat the virtio-fs export path as a sandbox for the VMM process."

microsandbox ships virtio-fs **on by default** (the heartbeat file reaches the host through it), exposes user bind mounts through passthroughfs, and runs the VMM as the invoking user. A guest kernel compromise reaches the host as that uid, through a virtio-fs path that libkrun itself says is not a sandbox. Against `docs/security/isolation.mdx:21` — "runs as the same user that launched it" — that is a weaker story than Firecracker's chroot + seccomp + namespace + cgroup stack, and the project's own docs do not claim otherwise. They say the hypervisor *is* the boundary (`isolation.mdx`, closing note).

**Restart and durability:**
- Attached sandboxes **stop when their creator process exits** (`docs/changelog/2026-06-05.mdx` — "Attached sandboxes stop on creator exit"). Detached mode is the only way to survive client exit.
- **Host reboot loses everything running.** State persists only as disk or full snapshots; a full snapshot taken pre-reboot restores, but nothing auto-restarts. There is no supervisor to reconcile desired state.
- The SQLite catalog is a single writer at a time under WAL with `busy_timeout`; a crashed `msb machine` mid-write is a catalog-integrity event, and `msb snap reindex` exists precisely because the local index can desync.
- `msb modify --compact` warns: "If compaction fails, a running VM may stay paused. Restart to recover from disk journals; do not assume rollback or blindly retry." (`docs/sandboxes/snapshots.mdx`)

**Code-shape risk:** `crates/runtime/lib/runner/relay.rs` is **11,764 lines in one file**; `vm.rs` is **4,991 lines**. `checkpoint/coordinator.rs` is 128 KB. These are the files a bug in "heavy CI, long-running container" behaviour will land in, and they are effectively unreviewable.

**No benchmarks.** No `criterion`, no `benches/`, no perf CI visible in `crates/`. Every performance number in this project is a claim, including the headline one.

**Firecracker's failure modes** are the mirror image: no image pipeline (you build ext4 or use virtiofsd), no snapshot packaging, no network filtering, no API authentication, no virtio-fs (so no host-dir sharing without adding virtiofsd — a separate process with its own attack surface), no nested virt (BELIEVED — widely documented limitation, not confirmed in the docs I fetched), and a hard requirement for `CAP_NET_ADMIN`-class host networking. Every one of those is work you own forever.

**Kata's failure mode** is weight and churn: 1,247 open issues, three moving parts per pod (shim, virtiofsd, hypervisor), and a hard dependency on a container manager.

## Licence and governance

**microsandbox itself: Apache-2.0.** `LICENSE` is Apache 2.0; `Cargo.toml:56` `license = "Apache-2.0"`. Clean, permissive, forkable.

**The licensing trap is one level down, in the artifact you actually run.** `libkrunfw` ships exactly two licence files and no `LICENSE`:

- `LICENSE-GPL-2.0-only`
- `LICENSE-LGPL-2.1-only`

(`libkrun/libkrunfw` root listing; GitHub reports the repo licence as `NOASSERTION`, which is why a casual scan misses it.) The 20.63 MiB `.so` that microsandbox downloads on install is **a GPL-2.0-**only** Linux kernel**. microsandbox redistributes it from its own GitHub releases (`crates/utils/lib/lib.rs:209` constructs `.../releases/download/v{version}/libkrunfw-{os}-{arch}.{ext}`), from a fork (`superradcompany/libkrunfw`, branch `krunfw`, per `.gitmodules`).

Practical consequences for this study:
- The Apache-2.0 badge on the microsandbox repo **does not cover the kernel blob**. If you redistribute an appliance image, you are redistributing GPL-2.0-only code and owe a source offer for that kernel.
- `GPL-2.0-only` is **incompatible with GPLv3** and awkward to combine with Apache-2.0 in a single derived work. Keeping the kernel as a separate, dlopen'd blob is the standard mitigation and it is what they do — but it is a legal posture you should have counsel confirm before shipping a firmware image, not something to discover at diligence.
- Firecracker is Apache-2.0 with no such layer. Kata is Apache-2.0.

**Governance and bus factor — the blunt part.** 74 contributors total. The top two accounts are **`appcypher` (532 commits)** and **`toksdotdev` (392)**. The third-largest *human* is 13 commits; everything after that is single digits. Recent 30 commits: 9 from `toksdotdev`, 3 from `appcypher`, the rest bots or drive-by. That is a **two-person project inside one company** (Super Rad Company, `Cargo.toml:53`). 8,860 stars is attention, not users, and definitely not maintainers.

Commercial pressure is visible: `docs/cloud/` (private beta, API keys, billing), `docs/enterprise/` (sales@, managed configuration, device policy), and a feature matrix where a meaningful set of capabilities is badged **"Local-only"** or **"Cloud-only"**. Nothing here is hostile — Apache-2.0 means you can fork — but you would be forking 484k lines of two-person Rust. The realistic read is: **you are adopting a vendor's roadmap, not a community standard.**

By contrast Firecracker has had AWS funding and a stable API since 2018; Kata is foundation-governed.

## Verified facts

| claim | value | source |
|---|---|---|
| microsandbox version | 0.7.11 | `Cargo.toml:55` (clone) |
| microsandbox licence | Apache-2.0 | `LICENSE`, `Cargo.toml:56` |
| microsandbox stars / forks / open | 8,860 / 497 / 148 | https://forge.web.pkgforge.dev/github/repos/microsandbox/microsandbox |
| microsandbox created | 2024-10-03 | same |
| VMM is libkrun fork, not Firecracker | `msb_krun = "=0.1.42"` | `Cargo.toml:99`; `crates/runtime/lib/runner/vm.rs:3-6` |
| `msb_krun` published from | github.com/superradcompany/libkrun (Apache-2.0, fork, 7 stars) | https://crates.io/api/v1/crates/msb_krun |
| Rust LOC, `crates/` only | 270,906 | `find crates -name '*.rs' \| xargs cat \| wc -l` |
| Rust LOC, whole repo | 484,726 | same over `.` |
| `Cargo.lock` packages | 863 | `grep -c '^\[\[package\]\]' Cargo.lock` |
| Direct workspace deps | 103 | `Cargo.toml` `[workspace.dependencies]` |
| `msb` binary size (linux x86_64) | 50.32 MiB | https://forge.web.pkgforge.dev/github/repos/microsandbox/microsandbox/releases (v0.7.11) |
| guest kernel blob size | 20.63 MiB | same, `libkrunfw-linux-x86_64.so` |
| `agentd` size | 2.47 MiB | same, `agentd-x86_64` |
| seccomp in host code | 0 occurrences | `grep -rn seccomp --include=*.rs .` |
| host namespaces / privilege drop | 0 occurrences (only in-guest `agentd`) | `grep -rn "unshare\|CLONE_NEW" crates/` |
| host process privilege model | "same user that launched it", `/dev/kvm` via `kvm` group, no setuid | `docs/security/isolation.mdx:21-27` |
| device model | virtio-console/net/fs/blk/rng only | `docs/security/isolation.mdx:34-38` |
| control channel auth | none, by design | `docs/security/isolation.mdx:44-49` |
| guest root by default | agentd PID 1 root; workload root | `docs/security/isolation.mdx:60-62` |
| hand-written ext4 | 7,965 lines incl. JBD2 | `wc -l crates/image/lib/ext4/*.rs`; `formatter.rs:16-17` |
| hand-written EROFS | 3,857 lines | `wc -l crates/image/lib/erofs/*.rs` |
| checkpoint engine | 14,329 lines | `wc -l crates/runtime/lib/checkpoint/*.rs` |
| snapshot types | disk + full; no memory-only | `docs/sandboxes/snapshots.mdx:15-19` |
| capture timeout | 30 min | `docs/sandboxes/snapshots.mdx:21` |
| cross-host migration | "not guaranteed" | `docs/sandboxes/snapshots.mdx:40` |
| full restore constraint | CPU + memory must match capture | `docs/sandboxes/snapshots.mdx:299` |
| netstack threading | one dedicated OS thread per sandbox | `crates/network/lib/engine/netstack/poll.rs:1-5` |
| netstack MTU | 1500 | `crates/network/lib/engine/netstack/poll.rs:1546` |
| published ports | one host socket per port | `docs/networking/overview.mdx:455` |
| past port-throughput bug | throttled to 30–120 KB/s | `docs/changelog/2026-06-05.mdx:99` |
| shared state | one SQLite file, WAL, all host processes | `crates/db/lib/pool.rs:1-5`; `crates/utils/lib/lib.rs:19` |
| CPU placement semantics | per-VM affinity, not scheduling | `packages/microsandbox-types/rust/lib/domain.rs:1077-1092` |
| containerd/OCI runtime | PR #1167, **open** since 2026-07-11 | https://forge.web.pkgforge.dev/github/repos/microsandbox/microsandbox/issues/1167 |
| GPU support | issue #291, open since 2025-07-07 | repo issues list |
| contributors | 74; top 2 = 532 + 392 commits | https://forge.web.pkgforge.dev/github/repos/microsandbox/microsandbox/contributors |
| beta status | "still beta software … breaking changes" | `README.md:119` |
| boot-time claim scope | "guest boot on an M1 machine" | `README.md:486` |
| libkrunfw licences | GPL-2.0-only + LGPL-2.1-only, no LICENSE file | https://forge.web.pkgforge.dev/github/repos/libkrun/libkrunfw/contents/ |
| libkrunfw GitHub licence field | `NOASSERTION` | https://forge.web.pkgforge.dev/github/repos/libkrun/libkrunfw |
| libkrun security model requires host namespaces | quoted | `libkrun/docs/security-model.md` |
| Firecracker stars / created | 37,695 / 2017-10-19 | https://forge.web.pkgforge.dev/github/repos/firecracker-microvm/firecracker |
| Firecracker licence | Apache-2.0 | same |
| Firecracker density | 5 microVMs/core/s; 180/s on 36 cores | `docs/design.md:28` |
| Firecracker process model | 1 process = 1 microVM; API/VMM/vCPU threads | `docs/design.md:59` |
| Firecracker seccomp | per-thread, installed by Firecracker | `docs/design.md:104-112` |
| Firecracker jailer steps | chroot, pivot_root, mount ns, cgroups, setrlimit, mknod kvm/tun, drop uid/gid | `docs/jailer.md` |
| Firecracker devices | virtio-net/block/vsock, serial, i8042, MMDS — no virtio-fs | `docs/design.md:77` |
| Firecracker networking | TAP-backed, no filtering | `docs/design.md:51,67` |
| Firecracker snapshot packaging | "provides no functionality to package or manage them on the host" | `docs/snapshotting/snapshot-support.md:59` |
| Firecracker snapshot integrity | 64-bit CRC only | `docs/snapshotting/snapshot-support.md:65` |
| Firecracker diff snapshots | "still in developer preview" | `docs/snapshotting/snapshot-support.md:73` |
| Kata stars / licence | 9,044 / Apache-2.0 | https://forge.web.pkgforge.dev/github/repos/kata-containers/kata-containers |
| Kata open issues | 1,247 | same |
| Kata architecture | shimv2, one shim per pod, multi-container VM, ttRPC over vsock | `docs/design/architecture/README.md:39-55,202` |
| Kata VMM backends | QEMU, Cloud Hypervisor, Firecracker, Dragonball | `docs/hypervisors.md:48-60` |
| Firecracker launch latency | <125 ms full launch, <7 ms VM creation | https://www.infoq.com/news/2022/02/firecracker-microvm-containers/ (secondary source, VERIFIED as published, not independently measured) |

## Rejected / not for this

**Rejected: microsandbox as the production isolation boundary for multi-tenant CI.** Four independent reasons, any one sufficient: (1) no host-side seccomp/namespace/cgroup confinement around a VMM that its own upstream says requires exactly that; (2) the orchestration seam is an unmerged PR; (3) hand-written ext4 with a JBD2 journal is the wrong place to accept unquantified risk on a write-heavy CI workload; (4) two-person maintenance of 484k lines with a `!`-breaking-change cadence.

**Rejected: Firecracker as "the platform".** It is a VMM. You would be signing up to build a TAP/CNI networking layer, an OCI→block-device pipeline, a snapshot store with packaging and integrity (their own is a 64-bit CRC), and an authenticated control plane around a socket that has none. That is a real product, not an integration.

**Rejected: Kata for a non-Kubernetes orchestrator.** Kata's entire value is the CRI/shimv2 seam. Without a container manager it is a pile of parts with worse ergonomics than either alternative.

**Rejected: microsandbox's secret substitution as a CI credential control.** It is a TLS-MITM proxy: it terminates TLS, inspects the request, and substitutes at the boundary (`docs/security/secrets.mdx`). It cannot help non-HTTP protocols, breaks on certificate pinning, and requires the host to hold plaintext credentials for every tenant. As a convenience for a single-tenant box, fine. As a multi-tenant credential boundary, it moves the secret from "in the guest" to "in a proxy process with no seccomp" — which is not obviously better.

**The one condition that flips the verdict:** if this CI is **single-tenant** (your own repos, your own commits, no arbitrary fork PRs) and you want the fastest path to *snapshot-fork-per-job*, microsandbox is defensible as the runner on a dedicated host, behind a Tunnel, with the box treated as cattle. Fork-from-warm-snapshot is a genuinely strong CI primitive and nobody else in this comparison ships it as a one-liner. In that world you accept the trust boundary because the code is yours.

## Open questions

1. **Does your orchestrator speak CRI?** If yes, Kata is a two-line change and this whole document collapses to "install the shim." If no, Firecracker-plus-your-own-supervisor is the honest scope.
2. **Single-tenant or multi-tenant CI?** Own repos vs customer PRs changes the security requirement by an order of magnitude and is the only thing that makes microsandbox viable.
3. **Do you need GPU runners?** Neither microsandbox (issue #291, open since 2025-07-07) nor Firecracker do GPU. Kata via VFIO is the only answer here, which forces the Kubernetes question.
4. **Is fork-from-snapshot a requirement or a nice-to-have?** If a requirement, microsandbox is the only one that ships it and the calculus shifts. If nice-to-have, Firecracker + a warm-image cache gets you most of the boot-time win.
5. **How many hosts?** microsandbox's state is `~/.microsandbox/msb.db` per host. At N hosts you have N catalogs and no shared truth — is that acceptable, or do you need the fleet to see one pool?
6. **What is your per-host density target?** microsandbox spawns a 50 MiB binary plus a 20 MiB kernel blob per VM; Firecracker's footprint is far smaller per VM but needs a supervisor process. Neither number is published by either project as a density figure — worth measuring before committing.
7. **Has anyone run microsandbox's full-snapshot restore across a reboot at scale?** The docs are candid that cross-host migration is not guaranteed, but there is no published durability or MTBF data, and the changelog shows capture/restore correctness fixes shipping as recently as v0.7.9–0.7.11.
8. **Who is the second maintainer?** If the answer is "nobody," budget for the fork now rather than at incident time.
