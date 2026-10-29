# Lane 04 — microVM and sandbox compute (Firecracker, Cloud Hypervisor, Kata, gVisor, microsandbox, E2B, bwrap/nsjail)

Researched 2026-10-29. All repo metadata (stars, licenses, push dates) fetched that day via
`https://forge.web.pkgforge.dev/github/repos/...`.

## Verdict

Only one stack in this lane actually reproduces Cloudflare Containers *semantics* on your own
hardware rather than merely supplying a hypervisor: **E2B Runtime / E2B Embed** (Apache-2.0), which
ships a control-plane API, per-node Firecracker orchestrator, template builder, snapshot-resume data
plane and a dashboard. **Firecracker** is the correct *primitive* — 125 ms to guest userspace, ≤5 MiB
VMM overhead, snapshot/restore with lazy page faulting — but it is a VMM with a per-VM HTTP socket,
not an orchestrator: no image management, no networking policy, no multi-tenant API, no lifecycle.
**Kata Containers** is the right answer only if you are already running Kubernetes and want a
CRI-compatible `RuntimeClass`; it is a shim, not a product. **gVisor** is the density play that does
not need `/dev/kvm` at all, but it is a syscall-interception sandbox and is the weakest fit for heavy
CI. The single most important caveat: **every serious option here (except gVisor on `systrap`) needs
bare-metal KVM**, and E2B Embed is explicitly *one machine by design* — so none of them gives you
Cloudflare's fleet, and you are trading Cloudflare's scale-to-zero economics for owning the scheduler.
A second caveat that cuts the other way: Cloudflare Containers only accepts HTTP ingress, so a
self-hosted replacement that terminates raw TCP/UDP is *more* capable than the thing it replaces.

## Findings

### What "Cloudflare Containers semantics" actually is (the spec to match)

This is the bar, taken from Cloudflare's own docs on 2026-10-29:

- **On-demand start from code, not an API call chain.** "Container instances are spun up on-demand and
  controlled by code you write in your Worker." — https://developers.cloudflare.com/containers/
- **HTTP-only ingress.** "Because all Container requests are passed through a Worker, end-users cannot
  make non-HTTP TCP or UDP requests to a Container instance." —
  https://developers.cloudflare.com/containers/concepts/architecture/
- **Cold start 1–3 s.** "Container cold starts can often be in the 1-3 second range, but this is
  dependent on image size and code execution time, among other factors." —
  https://developers.cloudflare.com/containers/faq/
- **Scale to zero via inactivity timeout**, not a max runtime. "Cloudflare does not stop a container
  instance after a fixed maximum runtime." Same FAQ. `sleepAfter` defaults to 10 minutes on the
  `Container` class.
- **Ephemeral disk; filesystem-only snapshots.** "All disk is ephemeral by default." and "Snapshots
  capture the Container's complete filesystem state, but not its memory or running processes." —
  https://developers.cloudflare.com/containers/guides/snapshots/
- **Instance caps**: 4 vCPU / 12 GiB / 20 GB disk max for a custom type; 6 TiB / 1,500 vCPU / 30 TB
  concurrent per account — https://developers.cloudflare.com/containers/platform/limits/
- **15-minute SIGTERM grace** on host drain: "Sends `SIGTERM`... Waits up to 15 minutes... Sends
  `SIGKILL`" — https://developers.cloudflare.com/containers/faq/
- **Identity/state coupling**: each container is bound to a Durable Object. This is the part nobody
  in the open-source lane gives you, because the DO equivalent (lane 03) is a separate product.

Any candidate must be scored against this list, not against "can it run a container".

### Firecracker — the primitive, not the product

Hard numbers, all from the project's own enforced spec
(https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/SPECIFICATION.md):

- "The Firecracker virtual machine manager starts (up to API socket availability) within `8 CPU ms`"
  with wall clock "spanning `6 ms to 60 ms`, with typical durations around `12 ms`."
- "It takes `<= 125 ms` to go from receiving the Firecracker InstanceStart API call to the start of
  the Linux guest user-space `/sbin/init` process." (serial console disabled, minimal kernel + rootfs)
- "Firecracker's virtual machine manager threads have a memory overhead `<= 5 MiB`."
- Compute-only guest CPU "is `> 95%` of the equivalent bare-metal performance."
- Network: "the guest achieves up to `14.5 Gbps`... by using `<= 80%` of the host CPU core", and
  "the virtualization layer adds on average `0.06ms` of latency."

Density claim from https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md:
"Firecracker supports a steady mutation rate of 5 microVMs per host core per second (e.g., one can
create 180 microVMs per second on a host with 36 physical cores)." Also "any combination of vCPU (up
to 32)".

**What it does not do — this is the load-bearing part.** The entire device model is, verbatim:
"Firecracker provides guests with storage and network access via emulated VirtIO Net and VirtIO Block
devices. It also exposes a serial console and partial keyboard controller". There is no VFIO, no GPU
passthrough, no PCI bus worth the name (virtio-PCI hotplug is marked "Developer Preview" in the
README). For "heavy CI" this matters: no GPU runners, no nesting.
And from design.md: "Firecracker does not perform any network traffic filtering. All egress traffic"
— you must build the firewall yourself. Security depends entirely on host config: "The overall
security of Firecracker microVMs... depends on a well configured Linux host operating system"
(README). In production it must run under `jailer`, as root, on a prepared host
(`docs/prod-host-setup.md`). So Firecracker gives you a VMM; you still owe: image/template
distribution, per-VM netns + TAP + NAT + egress policy, cgroup limits, a vsock/agent protocol, a
metadata API, a scheduler, a lifecycle state machine, and an auth layer.

Snapshot/restore is real and is the thing that makes sub-second sandbox creation possible
(https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/docs/snapshotting/snapshot-support.md):
- Restore is lazy: "Firecracker creates a MAP_PRIVATE mapping of the memory file, resulting in
  runtime on-demand loading of memory pages... This has the advantage of very fast snapshot loading
  times". No latency number is published — the docs only promise "very fast".
- "Diff snapshots are still in developer preview".
- Known breakage: "High snapshot restoration latency when cgroups V1 are in use"; "Guest network
  connectivity is not guaranteed to be preserved after resume"; "vsock connections that are open when
  the snapshot is taken are closed"; "Resuming from a snapshot that was taken during early stages of
  the guest kernel boot might lead to crashes".
- "Firecracker... provides no functionality to package or manage them on the host" and "only verifies
  integrity using a 64-bit CRC value" — snapshot storage, encryption and distribution are yours.

### Cloud Hypervisor — the Firecracker alternative when you need real devices

v54.0 released 2026-10-14 (https://github.com/cloud-hypervisor/cloud-hypervisor/releases). Rust, built
on rust-vmm. Objectives from the README: "Minimal emulation", "Low latency", "Machine to machine
migration", "CPU, memory, PCI hotplug". It supports **VFIO passthrough** (build-configurable, runtime
configurable — https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/device_model.md),
which Firecracker does not. That is the single reason to pick CH over FC for CI with accelerators.

It has snapshot/restore (`ch-remote pause` then `snapshot file:///...`, restoring "in a paused state")
— https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/snapshot_restore.md — and live
migration, which Firecracker lacks entirely.

**Gap:** it publishes no boot-time guarantee. Its `performance_metrics.md` documents a `boot_time_ms`
metric with a 2 s timeout and 10 iterations, but no expected value; I found no first-party number to
cite. Operationally it is also a bigger device model than FC, so per-VM memory overhead is higher and
boot is slower (BELIEVED, unmeasured). And like FC it is a VMM only — same list of missing pieces.
License: the GitHub API returns `null`, but the repo carries `LICENSES/Apache-2.0.txt` and
`LICENSES/BSD-3-Clause.txt` (REUSE layout), i.e. dual-licensed Apache-2.0 / BSD-3-Clause — VERIFIED
from the directory listing, not from a prose statement.

### Kata Containers — the Kubernetes-shaped path

4.3.1 released 2026-10-21. Apache-2.0. The 4.0 architecture doc
(https://github.com/kata-containers/kata-containers/blob/main/docs/design/architecture_4.0/architecture.md)
describes a Rust `runtime-rs` with `containerd-shim-kata-v2` and a built-in VMM (Dragonball) or an
external one ("QEMU / Cloud-Hypervisor / Firecracker"). The release blog confirms the Go runtime "will
remain available but in a deprecated state" —
https://katacontainers.io/blog/kata-containers-4-0-0-release-overview/.

**What it gives:** OCI-compatible pods where each pod gets its own kernel, driven through containerd.
That is genuinely the cheapest route to "VM isolation with container UX" *if* you already run K8s.

**Why it fails as a Cloudflare-Containers replacement:** it is a CRI shim, not a control plane. You
get no "start this sandbox for this user, right now, with this snapshot" API; you get a Kubernetes pod.
Cold start is dominated by the guest kernel boot plus shim plus agent. Boot-time numbers are only
available second-hand and they conflict: a Kuasar benchmark post claims "The boot time of Kata is about
850~950 ms" (https://kuasar.io/blog/benchmark-test-report/ — secondary), while a Northflank blog claims
"150 to 300ms" (secondary). I could not find a first-party figure. Either way it is well above the
125 ms Firecracker floor and above the sub-100 ms snapshot-resume path that E2B uses. It also inherits
all of Kubernetes' scheduling latency, which is exactly the layer this study is trying to replace.

### gVisor — the option that does not need KVM

`runsc` is a user-space kernel (the Sentry). Apache-2.0, 19.8k stars, releases weekly
(`release-20261026.0`, 2026-10-28).

The important operational fact: **`systrap` is the default platform since mid-2023 and needs no
`/dev/kvm`.** From https://gvisor.dev/docs/architecture_guide/platforms/: "`systrap` replaced `ptrace`
as the default gVisor platform in mid-2023", and "The `systrap` platform is a better choice when
running inside a VM, or on a machine without virtualization support." It works via
`SECCOMP_RET_TRAP`/`SIGSYS`. This means gVisor can be layered *inside* an ordinary VM — relevant if
your "machines" are themselves cloud VMs reached over Cloudflare Mesh.

The project is blunt about its own cost model
(https://gvisor.dev/docs/architecture_guide/performance/): "gVisor imposes runtime costs over native
containers", split into **structural costs** (the Sentry layer) and **implementation costs** ("the
network stack... does not support all the advanced recovery mechanisms offered by other stacks and is
less CPU efficient"). CPU execution itself is free — "gVisor does not perform emulation or otherwise
interfere with the raw execution of CPU instructions".

**Blunt failure modes:**
- Compatibility is explicitly not guaranteed: "there are (and always will be) unimplemented features
  and bugs. The only real way to know if it will work is to try."
  (https://gvisor.dev/docs/user_guide/compatibility/). Notably "gVisor does not fully support
  `io_uring`-related syscalls".
- Syscall-heavy workloads are the worst case. The docs single out `redis` as a scenario that "is
  likely to remain a challenging performance scenario". A compiler/linker-heavy CI job is a
  syscall-and-`fork`-heavy workload, i.e. the wrong shape for gVisor.
- Checkpoint/restore exists but has sharp edges: "Checkpoint/restore functionality is currently
  available via raw `runsc` commands"; "Two checkpoints cannot be saved to the same directory";
  restore verifies CPU features and "verifies that the target host machine possesses all the CPU
  features enabled on the machine where the checkpoint snapshot was created" — so a snapshot is not
  freely movable across a heterogeneous fleet. With `--network=host`, "Sockets that were connected at
  checkpoint time return `ECONNRESET`".
- No published performance numbers in text form — every figure on the performance page is an image,
  so I cannot cite a syscall-overhead multiplier.

### microsandbox — good sandbox library, not a service

Apache-2.0, 8.9k stars, v0.7.11 (2026-10-24), very active. Repo moved to
`superradcompany/microsandbox`. Built on **libkrun** (the README credits "libkrun and smoltcp"), so it
is a library that links a VMM into your process rather than a daemon.

What it genuinely has: OCI images, per-sandbox VM, `msb fork` (live fork), `msb snap create/restore`
with `--cow-mem` for shared unchanged memory, SDKs in TypeScript/Rust/Python/Go/Ruby, resource limits
(cpus/memory), named long-running sandboxes.

**The headline number is not what it looks like.** "Average boot times[^boot-time] under 100
milliseconds" carries the footnote "Boot time refers to guest boot on an M1 machine." That is Apple
Silicon / Hypervisor.framework, not Linux/KVM. Do not carry <100 ms into a Linux fleet plan.

**Why it fails as the compute layer for this study:** it is explicitly not a service. "The SDK starts
the sandbox process directly. No daemon, remote service, or infrastructure setup."
(https://docs.microsandbox.dev/). A dashboard/SPA cannot talk to it; there is no self-hostable REST
server. The REST API in the docs (`/v1/sandboxes`, `/v1/snapshots`) is **microsandbox cloud**, keyed
by an API key — hosted only. You would have to write the entire control plane, auth, and multi-tenant
scheduling yourself, at which point you have written E2B.

### E2B Runtime / E2B Embed — the only turnkey match

This is the most important finding in the lane, and it is recent. `e2b-dev/infra` has become
`e2b-dev/runtime` (1,781 stars, Apache-2.0, pushed 2026-10-29) and it now ships **E2B Embed**, a
self-hostable, single-machine distribution of the whole stack.

Architecture, verbatim from the README
(https://github.com/e2b-dev/runtime):
- "A sandbox is a resumed snapshot. Templates are pre-booted VMs (memory, disk, and machine state)
  stored in object storage. 'Creating' a sandbox means restoring one, not booting a kernel. Memory
  pages are served lazily on page fault through `userfaultfd`, and the root filesystem is a
  copy-on-write overlay over a read-only image".
- "Control plane and data plane never mix. The API decides *where* a sandbox runs... The orchestrator
  on each node owns *how* it runs: the Firecracker process, the network namespace, the block device,
  the cgroup."
- "One Firecracker microVM per sandbox, in its own cgroup and network namespace, with a per-sandbox
  nftables egress firewall and SNI/Host-inspecting domain allow and deny lists."

That is a 1:1 match for the Cloudflare Containers feature set *plus* memory snapshots, which
Cloudflare does not have ("Snapshots capture the Container's complete filesystem state, but not its
memory"). E2B: "A paused sandbox is kept indefinitely with no time-to-live".

Deployment options, from
https://github.com/e2b-dev/runtime/blob/main/embed/README.md: Docker Compose on "a Linux host you
own", Terraform modules for GCP/AWS/Azure, or `kubectl apply -k` on one cluster node. "Same SDK, same
API as E2B Cloud." "No E2B account and no license key needed."

**Why it fails — read this before planning around it:**
1. **Single node, by design.** "Embed is one machine, by design. When you need more, E2B runs three
   other ways" — and all three others are commercial (Private cloud "in development", BYOC, E2B
   Cloud). Multi-node is not open source. This is the hard ceiling.
2. **Needs hardware virtualization.** "Embed needs a Linux machine with hardware virtualization."
   No KVM, no E2B. So: bare metal or a nested-virt VM.
3. **Plain HTTP, no TLS.** "Embed answers over HTTP at the machine's own address, with no TLS of its
   own, which is why it belongs inside your network." You must front it — which is actually fine
   given the Cloudflare Tunnel/Mesh constraint, but it means E2B is not internet-facing as shipped.
4. **13 ports on the host network.** From
   https://github.com/e2b-dev/runtime/blob/main/embed/docs/REFERENCE.md, "13 ports listen on every
   interface of the machine", including port 5008 which "creates and kills sandboxes". Exposing this
   through a Tunnel needs care — you cannot naively publish all 13.
5. **Ships its own dashboard.** Embed includes "The dashboard. Your sandboxes, templates and logs in
   the browser, with a terminal and a file browser for every sandbox." That collides with the study's
   hard constraint that the management SPA is hosted on Cloudflare Workers. You would either run
   Embed's dashboard as an internal ops tool and build your own Worker-hosted UI against the E2B API,
   or fork it.
6. **Binaries come from E2B's registry, not from source.** `embed/compose/.env` pins
   `E2B_API_IMAGE=us-docker.pkg.dev/e2b-artifacts/api/api:v0.14...`,
   `E2B_FIRECRACKER_VERSION=v1.14-0.2.0`, `E2B_KERNEL_VERSION=vmlinux-6.1.177_5008931`. The *code* is
   Apache-2.0 but what you run is vendor-built images and a vendored Firecracker fork. Reproducible
   builds are not the default path.
7. **Continuous runtime is capped by plan in the cloud** (Hobby 1 h, Pro 24 h —
   https://docs.e2b.dev/faq/sandbox-lifetime). Whether Embed enforces an equivalent cap is unconfirmed
   (see Open Questions); the docs present it as a *plan* limit, and Embed has no plan.

### bubblewrap / nsjail — rejected as a compute layer

Both are shared-kernel namespace tools. They are excellent at what they do and completely wrong here.

- **bubblewrap** (LGPL-2.1 per `COPYING`, v0.13.1 2026-10-14) says so itself: "bubblewrap is not a
  complete, ready-made sandbox with a specific security policy... the level of protection between the
  sandboxed processes and the host system is entirely determined by the arguments passed to
  bubblewrap." It also removed setuid mode: "Historically, bubblewrap also supported a setuid mode...
  However, this has been removed."
- **nsjail** (Apache-2.0, 3.6, 2026-03-18) is "Linux process isolation tool using namespaces, resource
  limits, and seccomp-bpf syscall filters."

Neither is a security boundary against a kernel LPE, which is the entire threat model for running
untrusted CI from arbitrary users. They are the right tool for sandboxing *your own* build steps
inside an already-isolated VM — i.e. layer 2, not layer 1. Also: neither gives you snapshots,
boot semantics, or any API. Reject as the compute layer; consider as a defence-in-depth wrapper
inside a microVM.

### Flintlock — the missing Firecracker control plane (worth knowing)

Firecracker's own README names it: "Firecracker has also been integrated in container runtimes, for
example Kata Containers and Flintlock." `liquidmetal-dev/flintlock`, MPL-2.0, 1.5k stars, v0.16.0
(2026-10-03), active.

It is "a service for creating and managing the lifecycle of microVMs on a host machine", supporting
both Firecracker and Cloud Hypervisor, over gRPC or HTTP: create/get/list/delete microVMs, OCI images
for "volumes, kernel and initrd", TAP/bridge/macvtap networking with DHCP or static IPs, cloud-init,
vsock guest agent, Prometheus metrics.

**Gaps:** the feature list contains **no snapshot, pause, resume, or restore** — so it cannot do the
sub-second create-from-snapshot trick that Cloudflare-like semantics need. It is per-host with no
cluster scheduler, no multi-tenancy, and no auth story in the README. Its stated purpose is making
microVMs that act as Kubernetes nodes, which is a different product. Useful as a reference
implementation of the Firecracker lifecycle API; not usable as-is.

### Boot time and snapshot/restore, summarised

The ladder, worst to best, for "time to a usable sandbox":

| Path | Time | Source quality |
|---|---|---|
| Cloudflare Containers, cold | 1–3 s | VERIFIED, first-party FAQ |
| Kata pod, cold boot | ~0.85–0.95 s (conflicting: 150–300 ms) | secondary only, no first-party number |
| Firecracker, cold boot to `/sbin/init` | ≤125 ms | VERIFIED, enforced by CI |
| Firecracker, resume from snapshot | "very fast", no published ms | VERIFIED that it is lazy/on-demand, number unpublished |
| microsandbox, boot | <100 ms **on M1** | VERIFIED claim, but Apple Silicon |

The lesson: **the cold-boot number is not the number that matters**; the snapshot-resume path is. That
is why E2B's design ("creating a sandbox means restoring one, not booting a kernel") beats a naive
Firecracker-per-job orchestrator, and why Cloudflare's own 1–3 s is dominated by image pull and
entrypoint, not by virtualisation.

### The Cloudflare edge constraint

Nothing in this lane speaks Cloudflare Tunnel or Mesh natively. All of them are host-local HTTP (or
gRPC/vsock) services. The integration shape is therefore uniform: run `cloudflared` on each compute
host, expose one internal HTTP port per host, and let the Worker-hosted dashboard talk to it. E2B Embed
is the awkward case because it wants 13 ports on every interface and has no TLS — you would expose
only `3000` (SDK/API) and `3002` (sandbox traffic) through the Tunnel and firewall the rest, per
`embed/docs/REFERENCE.md`. gVisor and Kata both need an outer VM or host per tenant-group, which is
the natural unit to put behind a Mesh connector anyway.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| Firecracker | https://github.com/firecracker-microvm/firecracker | Apache-2.0 | v1.17.0 (2026-09-10); pushed 2026-10-29; 37,693 stars | ≤125 ms boot to `/sbin/init`, ≤5 MiB VMM overhead, 5 microVMs/core/s, snapshot+restore with `userfaultfd`-style lazy paging | VMM only: no orchestrator, no images, no networking policy, no egress filtering, no API for many VMs; no VFIO/GPU; must run as root under `jailer` on a hardened host |
| Cloud Hypervisor | https://github.com/cloud-hypervisor/cloud-hypervisor | Apache-2.0 + BSD-3-Clause (dual, per `LICENSES/`) | v54.0 (2026-10-14); pushed 2026-10-29; 6,440 stars | VFIO passthrough, CPU/mem/PCI hotplug, snapshot/restore, live migration, virtiofs, Windows guests | Same "VMM not a product" gap; no published boot-time number; heavier device model than FC |
| Kata Containers | https://github.com/kata-containers/kata-containers | Apache-2.0 | 4.3.1 (2026-10-21); pushed 2026-10-29; 9,044 stars | OCI/CRI pods with a real kernel each; Rust `runtime-rs` + Dragonball, or QEMU/CH/FC backends | It is a containerd shim: you get Kubernetes pods, not a sandbox API; cold start ~0.9 s (secondary); inherits K8s scheduling, which is the layer being replaced |
| gVisor | https://github.com/google/gvisor | Apache-2.0 | release-20261026.0 (2026-10-28); 19,818 stars | User-space kernel; `systrap` default needs **no KVM**; checkpoint/restore; strong syscall-level isolation; zero CPU emulation cost | Syscall-heavy and `fork`-heavy workloads are its worst case; "always will be" unimplemented features; snapshots are CPU-feature-pinned; no published perf numbers |
| microsandbox | https://github.com/superradcompany/microsandbox | Apache-2.0 | v0.7.11 (2026-10-24); 8,858 stars | libkrun-based per-sandbox microVM, live fork, snapshots with `--cow-mem`, 5 language SDKs, OCI images | Library, not a service: "No daemon, remote service"; the REST API is cloud-only; <100 ms boot is an M1 measurement; no multi-node |
| E2B Runtime / Embed | https://github.com/e2b-dev/runtime | Apache-2.0 | pushed 2026-10-29; 1,781 stars; SDK repo `e2b-dev/E2B` 14,606 stars | Full control plane + Firecracker orchestrator + template builder + memory snapshot/pause/resume + dashboard; Docker Compose / Terraform / K8s single-node install | **One machine by design**; multi-node is commercial only; needs KVM; plain HTTP with no TLS; 13 host ports; ships its own dashboard (conflicts with Worker-hosted SPA constraint); runs vendor-built images |
| Flintlock | https://github.com/liquidmetal-dev/flintlock | MPL-2.0 | v0.16.0 (2026-10-03); pushed 2026-10-27; 1,519 stars | gRPC/HTTP microVM lifecycle API over Firecracker *and* Cloud Hypervisor, OCI kernel/initrd/volumes, TAP/bridge/macvtap, Prometheus | No snapshot/pause/resume at all; per-host only, no scheduler, no multi-tenancy, no auth |
| bubblewrap | https://github.com/containers/bubblewrap | LGPL-2.1 | v0.13.1 (2026-10-14); 9,271 stars | Unprivileged namespace sandbox construction | Shared kernel; "not a complete, ready-made sandbox with a specific security policy"; no VM boundary, no snapshots, no API |
| nsjail | https://github.com/google/nsjail | Apache-2.0 | 3.6 (2026-03-18); pushed 2026-10-28; 4,178 stars | namespaces + seccomp-bpf + cgroups + resource limits, inetd-style listener mode | Shared kernel; not a defence against kernel LPE; no snapshots, no orchestration |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| Cloudflare Containers cold start | 1–3 s | https://developers.cloudflare.com/containers/faq/ | "Container cold starts can often be in the 1-3 second range, but this is dependent on image size and code execution time, among other factors." |
| CF Containers max custom instance | 4 vCPU / 12 GiB / 20 GB | https://developers.cloudflare.com/containers/platform/limits/ | "Maximum vCPU | 4 ... Maximum Memory | 12 GiB ... Maximum Disk | 20 GB" |
| CF Containers account concurrency | 6 TiB mem / 1,500 vCPU / 30 TB disk | https://developers.cloudflare.com/containers/platform/limits/ | "Concurrent memory | 6 TiB ... Concurrent vCPU | 1,500 ... Concurrent disk | 30 TB" |
| CF Containers snapshot cap | 20 GB, 30-day retention | https://developers.cloudflare.com/containers/platform/limits/ | "Maximum snapshot size | 20 GB ... Snapshot retention | 30 days from creation or the most recent restore" |
| CF Containers image storage | 50 GB per account | https://developers.cloudflare.com/containers/platform/limits/ | "Total image storage per account | 50 GB" |
| CF Containers vCPU price | $0.000020 per vCPU-second | https://developers.cloudflare.com/containers/platform/pricing/ | "375 vCPU-minutes/month + $0.000020 per additional vCPU-second" |
| CF Containers memory price | $0.0000025 per GiB-second | https://developers.cloudflare.com/containers/platform/pricing/ | "25 GiB-hours/month included +$0.0000025 per additional GiB-second" |
| CF Containers disk price | $0.00000007 per GB-second | https://developers.cloudflare.com/containers/platform/pricing/ | "200 GB-hours/month +$0.00000007 per additional GB-second" |
| CF Containers egress (NA/EU) | $0.025/GB, 1 TB included | https://developers.cloudflare.com/containers/platform/pricing/ | "North America & Europe | $0.025 | 1 TB" |
| CF Containers SIGTERM grace | 15 minutes | https://developers.cloudflare.com/containers/faq/ | "Waits up to 15 minutes for that process to exit." |
| CF Containers snapshot scope | filesystem only, not memory | https://developers.cloudflare.com/containers/guides/snapshots/ | "Snapshots capture the Container's complete filesystem state, but not its memory or running processes." |
| Firecracker boot to `/sbin/init` | ≤125 ms | https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/SPECIFICATION.md | "It takes `<= 125 ms` to go from receiving the Firecracker InstanceStart API call to the start of the Linux guest user-space `/sbin/init` process." |
| Firecracker VMM memory overhead | ≤5 MiB | same SPECIFICATION.md | "Firecracker's virtual machine manager threads have a memory overhead `<= 5 MiB`." |
| Firecracker API socket readiness | 8 CPU ms (6–60 ms wall) | same SPECIFICATION.md | "starts (up to API socket availability) within `8 CPU ms` ... spanning `6 ms to 60 ms`, with typical durations around `12 ms`." |
| Firecracker VM creation rate | 5 microVMs/core/s | https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md | "Firecracker supports a steady mutation rate of 5 microVMs per host core per second (e.g., one can create 180 microVMs per second on a host with 36 physical cores)." |
| Firecracker max vCPU | 32 | same design.md | "Customers can create microVMs with any combination of vCPU (up to 32)" |
| Firecracker network throughput | 14.5 Gbps at ≤80% of one core | same SPECIFICATION.md | "the guest achieves up to `14.5 Gbps` network throughput by using `<= 80%` of the host CPU core for emulation" |
| Firecracker net latency added | 0.06 ms avg | same SPECIFICATION.md | "the virtualization layer adds on average `0.06ms` of latency." |
| Firecracker diff snapshots | developer preview | https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md | "Diff snapshots are still in developer preview" |
| microsandbox boot time | <100 ms **on M1 only** | https://github.com/superradcompany/microsandbox (README) | "Average boot times[^boot-time] under 100 milliseconds." / "[^boot-time]: Boot time refers to guest boot on an M1 machine." |
| E2B Embed scope | single machine | https://github.com/e2b-dev/runtime/blob/main/embed/README.md | "Embed is one machine, by design. When you need more, E2B runs three other ways" |
| E2B Embed TLS | none | same embed README | "Embed answers over HTTP at the machine's own address, with no TLS of its own, which is why it belongs inside your network." |
| E2B Embed exposed ports | 13 on every interface | https://github.com/e2b-dev/runtime/blob/main/embed/docs/REFERENCE.md | "13 ports listen on every interface of the machine." |
| E2B paused sandbox retention | indefinite | https://docs.e2b.dev/faq/sandbox-lifetime | "A paused sandbox is kept indefinitely with no time-to-live" |
| E2B continuous runtime cap (cloud plans) | 1 h Hobby / 24 h Pro | https://docs.e2b.dev/faq/sandbox-lifetime | "| Hobby | 1 hour | ... | Pro | 24 hours | ... | Enterprise | Custom |" |
| gVisor default platform | systrap, no KVM needed | https://gvisor.dev/docs/architecture_guide/platforms/ | "`systrap` replaced `ptrace` as the default gVisor platform in mid-2023." |
| gVisor io_uring | not fully supported | https://gvisor.dev/docs/user_guide/compatibility/ | "gVisor does not fully support `io_uring`-related syscalls" |
| bubblewrap security posture | not a sandbox policy | https://github.com/containers/bubblewrap (README) | "bubblewrap is not a complete, ready-made sandbox with a specific security policy." |
| bubblewrap setuid mode | removed | same README | "Historically, bubblewrap also supported a setuid mode... However, this has been removed." |
| Kata boot time (secondary) | ~850–950 ms | https://kuasar.io/blog/benchmark-test-report/ | "The boot time of Kata is about 850~950 ms while Kuasar is only 300~360 ms" |
| Firecracker repo activity | 37,693 stars, pushed 2026-10-29 | https://forge.web.pkgforge.dev/github/repos/firecracker-microvm/firecracker | API `"stargazers_count": 37693`, `"pushed_at": "2026-10-29T10:49:20Z"` |

## Rejected options

| option | why rejected |
|---|---|
| bubblewrap as the isolation layer | Shared kernel. It states outright it is "not a complete, ready-made sandbox with a specific security policy" and that protection "is entirely determined by the arguments passed to bubblewrap." No defence against a host kernel LPE, which is the actual threat model for untrusted CI. Keep it only as an inner wrapper inside a microVM. |
| nsjail as the isolation layer | Same problem: namespaces + seccomp-bpf on the host kernel. It is a fuzzing/process-isolation tool, not a VM boundary. No snapshots, no API, no orchestration. |
| microsandbox as the platform | It is a library with "No daemon, remote service, or infrastructure setup." There is no self-hostable REST server to point a Worker-hosted dashboard at; the REST API is microsandbox cloud. The <100 ms figure is an Apple M1 measurement, not a Linux fleet number. |
| Kata Containers as the platform | You get Kubernetes pods, not a "create sandbox for this user now" API. Cold start ~0.9 s. It requires you to already own the orchestration layer this study is trying to build, so it is a poor fit as the *product* and only sensible as a CRI runtime if K8s is already the substrate. |
| Flintlock as the control plane | Its own feature list has no snapshot, pause, resume or restore — so it cannot deliver create-from-snapshot, which is the only way to get Cloudflare-like cold starts. Per-host, no scheduler, no multi-tenancy, no auth. |
| Cloud Hypervisor as the default VMM | Only if you need VFIO/GPU passthrough or live migration. Otherwise Firecracker has a smaller device model, a *published and CI-enforced* boot-time budget, and vastly more production evidence. CH publishes no boot-time number at all. |
| Firecracker alone, "just wire it up" | You would be writing image distribution, per-VM netns/TAP/NAT, egress firewall (FC does none: "Firecracker does not perform any network traffic filtering"), cgroups, a vsock agent protocol, a metadata service, snapshot storage/encryption (FC "provides no functionality to package or manage them"), a scheduler and auth. That is a multi-month project whose output already exists as E2B. |
| E2B Embed as the whole answer | Rejected as a *fleet*: "Embed is one machine, by design" and every multi-node path is commercial. Also collides with the Worker-hosted-dashboard constraint (it ships its own dashboard) and needs a TLS-terminating front (Tunnel handles this) plus careful port exposure (13 ports). |
| gVisor as the default for heavy CI | Worst-case workload shape. Syscall- and `fork`-heavy builds hit exactly the structural cost gVisor documents, and the project names `redis`-class syscall-heavy work as "likely to remain a challenging performance scenario". Good as a second, cheap tier for small untrusted snippets; bad as the CI engine. |

## Open questions

- **What is Firecracker's actual snapshot-resume latency?** The docs promise "very fast" and explain
  the `MAP_PRIVATE`/on-demand mechanism but publish no millisecond figure, and the CI runs snapshot
  tests without quoting a target. *Would be settled by:* running `test_snapshot_perf` from
  `firecracker/tests/integration_tests/performance/` on target hardware, or finding an AWS-published
  p50/p99 restore number.
- **Does E2B Embed enforce a continuous-runtime cap?** The 1 h / 24 h figures are documented as *plan*
  limits against E2B Cloud, and Embed has no plan or license key. *Would be settled by:* reading the
  `teams/{teamID}/metrics/max` handling in the orchestrator/api source, or starting a sandbox on Embed
  and leaving it up past 24 h.
- **How many concurrent sandboxes fit on one E2B Embed node?** The reference documents ports and
  metrics but no density figure, and there is no published per-node ceiling. *Would be settled by:* a
  load test on a known host (cores/RAM), or the private-cloud docs.
- **Kata Containers' real cold-start on 4.3.1 with `runtime-rs` + Dragonball.** Only secondary,
  mutually contradictory figures exist (850–950 ms vs 150–300 ms). *Would be settled by:* running
  `kata-runtime check` plus a timed pod-create on fixed hardware, or a first-party benchmark from the
  Kata project.
- **Cloud Hypervisor's boot time.** The repo defines a `boot_time_ms` metric and runs it, but no
  result is published in-tree. *Would be settled by:* running
  `./scripts/dev_cli.sh tests --metrics -- -- --test-filter boot_time` and reading `metrics.json`.
- **Whether E2B Embed can be pointed at your own object storage** (it stores templates/snapshots on
  the node's disk per the README: "Templates, sandbox logs and data live on its disk"). For a
  multi-host future this matters — a node's snapshots would otherwise be stranded. *Would be settled
  by:* reading the orchestrator's storage config in `e2b-dev/runtime`.
- **Licence status of Cloud Hypervisor.** The GitHub API reports `null`; the repo has
  `LICENSES/Apache-2.0.txt` and `LICENSES/BSD-3-Clause.txt`. Dual Apache-2.0/BSD-3-Clause is the
  strong inference but no prose statement confirms it. *Would be settled by:* `REUSE.toml`/`.reuse`
  config or a maintainer statement.
- **Whether any of these can be made to satisfy the "dashboard on Workers" constraint without
  forking.** E2B Embed ships a full dashboard; the plan would be to use its API from a
  Worker-hosted SPA and run Embed's UI as an internal ops tool. *Would be settled by:* checking the
  API surface in `embed/docs/REFERENCE.md` covers sandboxes, templates, logs and terminal/exec
  without the bundled UI — the docs imply yes, but I did not enumerate every endpoint.
- **Nested-virtualisation penalty on the actual "machines".** If machines are cloud VMs reached over
  Cloudflare Mesh, KVM-in-VM is required for Firecracker/CH/Kata. gVisor's own docs warn
  "nested virtualization will have poor performance and is historically a cause of security issues...
  It is not recommended for production." *Would be settled by:* benchmark on the real host type.
