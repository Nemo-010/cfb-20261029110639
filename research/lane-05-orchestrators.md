# Lane 05 — Non-Cloudflare orchestrators: the substrate for long-running containers and heavy CI on owned metal

Research date: **2026-10-29**. All versions, star counts and release dates below were read from
GitHub's REST API through the study proxy or from the projects' own documentation on that date.

## Verdict

No single tool in this list is a "remote-provisioning substrate". Provisioning and scheduling are
two different jobs, and the best answer is a two-layer stack: **Incus or Proxmox VE as the machine
layer** (create VMs/system containers over a REST API, cloud-init them, then hand them to the
workload layer) and **Nomad as the workload layer** (bin-packing, batch scheduling, rescheduling,
mTLS, ACLs) for long-running containers and CI runners. Nomad is the only scheduler here whose model
matches "long-running services *and* one-shot batch jobs" without dragging in Kubernetes, and it
survives the Cloudflare constraint cleanly because its control plane is a plain HTTP API on 4646
that you reach from the Workers dashboard through a `vpc_networks` binding to Cloudflare Mesh —
nothing has to be publicly exposed. The single most important caveat: **Nomad creates zero
machines**. It has no API to boot a host; "provisioning" is still Incus's or Proxmox's API plus
cloud-init, and the moment you need per-job pod isolation for GitHub Actions or GitLab CI you are
back to wanting k3s, because ARC and the GitLab Kubernetes executor are the only mature
pod-per-job executors and both require Kubernetes. Second caveat: Nomad is BUSL-1.1 and its licence
forbids embedding it in a paid product that overlaps Nomad Enterprise — if this platform is a
product you sell, read the licence before you build on it.

## Findings

### The Cloudflare network boundary decides half the answer, and it is the half people get wrong

Every orchestrator in this lane needs a peer-to-peer data plane that carries UDP. Cloudflare Tunnel
cannot carry it. Cloudflare's own comparison table is unambiguous:

- Cloudflare **Mesh**: protocols `TCP, UDP, ICMP`
- Cloudflare **Tunnel**: protocols `HTTP/S, TCP, SSH, RDP, SMB (proxied over WebSocket)`

Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/concepts/
— "| **Protocols** | TCP, UDP, ICMP | HTTP/S, TCP, SSH, RDP, SMB (proxied over WebSocket) |".

The consequence is concrete and kills a lot of designs:

| orchestrator | UDP requirement | source |
|---|---|---|
| k3s (default Flannel VXLAN) | UDP 8472 between **all** nodes | https://docs.k3s.io/installation/requirements |
| Docker Swarm | UDP 4789 (VXLAN), TCP/UDP 7946, TCP 2377 | https://docs.docker.com/engine/swarm/swarm-tutorial/ |
| Nomad | TCP **and UDP** 4648 (Serf WAN) between servers | https://developer.hashicorp.com/nomad/docs/deploy/production/requirements |
| Proxmox VE cluster | UDP 5405–5412 (corosync) | https://pve.proxmox.com/wiki/Cluster_Manager |

So: **the cluster runs on Mesh, not on Tunnel.** Tunnel's only job here is publishing one HTTP
endpoint (e.g. a single Nomad server's 4646 or a Proxmox 8006) — and even that you do not need,
because a Worker can reach Mesh directly. Workers VPC: "With this single binding, your Worker can
reach any service across all Cloudflare Tunnels, Mesh nodes, and Cloudflare WAN on-ramps in your
account" (https://developers.cloudflare.com/workers-vpc/examples/connect-to-cloudflare-mesh/).

Two operational traps in the Mesh docs that will bite a cluster build:

- "This will conflict with DNS services running on the same machine (for example, Active Directory
  DNS, Pi-hole, Unbound, BIND, or dnsmasq)" — so you cannot put a Mesh node on a host that is also a
  resolver. Proxmox hosts commonly run `dnsmasq`. Plan the gateway host accordingly.
  (https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/best-practices/)
- "Split Tunnels is the only supported method of running both connectors on the same machine. The
  Mesh node's kernel-level integration overrides manual routing configurations (`ip route add`,
  `iptables`)." Same page. A Mesh node that owns the routing table is a direct conflict risk with a
  CNI that also writes routes (flannel/calico). **BELIEVED, not verified**: the docs only name
  other VPN clients, not CNIs. Settle it by running a k3s node with a Mesh node on the same host and
  watching `ip route` after a flannel restart.

Workers VPC is also still beta and inherits Workers limits: "Standard Workers limits apply for
request size, timeout, and subrequests" and "Workers VPC is currently in beta"
(https://developers.cloudflare.com/workers-vpc/platform/limits/). A dashboard that proxies a
40-minute CI log stream through a Worker `fetch()` is not what this binding was built for; stream
from the runner to R2 and have the Worker only hand out signed URLs.

### Nomad

Nomad is the strongest fit and also the most misrepresented option in this lane.

What it actually gives you:
- Four schedulers in one binary: "Nomad provides the `service`, `system`, `batch`, and `sysbatch`
  schedulers" (https://developer.hashicorp.com/nomad/docs/job-specification/job). `batch` is the CI
  primitive; parameterized jobs can be dispatched on demand (`parameterized` → "can be dispatched
  against", same page), which is exactly the "start one job now, with these parameters" call a CI
  trigger needs.
- In 2.1.0 (released **2026-10-28**, i.e. yesterday) it grew an actual queue: "An new
  (experimental) batch job queue can be configured on node pools with different queuing options:
  FIFO ensures batch jobs are placed in the order received, and Dynamic Priority can prioritize
  batch jobs by age and 'fairness' of resources requested and/or placed"
  (https://github.com/hashicorp/nomad/releases/tag/v2.1.0). That is the first thing in this lane
  that resembles a real CI queue with fairness, and it is *experimental*.
- 2.0.3 added `max_run_duration` for batch/system-batch groups — a hard wall-clock cap per
  allocation, which is what you want for runaway builds
  (https://developer.hashicorp.com/nomad/docs/release-notes/v2-0-x).

What it does not give you:
- **No machine provisioning.** Nomad schedules onto agents you already installed. There is no
  "create node" API. Every "autoscaling" story is an external controller calling a cloud API.
- **No CI executor.** GitLab Runner's executor list is Docker, Docker Autoscaler, Instance,
  Kubernetes, SSH, Shell, VirtualBox, Parallels, Custom — there is no Nomad executor
  (https://docs.gitlab.com/runner/executors/). The working pattern is to run *runner managers* as
  Nomad services and let each manager spawn job containers via the Docker executor; Nomad then
  bin-packs the managers and reschedules them, but the per-job containers are invisible to Nomad.
- **Control plane is not cheap.** "We suggest having between 4-8+ cores, 16-32 GB+ of memory, 40-80
  GB+ of fast disk" per server, and "Nomad servers are expected to have sub 10 millisecond network
  latencies between each other"
  (https://developer.hashicorp.com/nomad/docs/deploy/production/requirements). Three servers for
  quorum means ~48–96 GB of RAM doing nothing but scheduling. That sub-10 ms rule also means you do
  not stretch a Nomad region across sites over Mesh.
- **Licence.** BUSL-1.1, licensor IBM: "Licensed Work: Nomad Version 1.7.0 or later" and "You may
  make production use of the Licensed Work, provided Your use does not include offering the Licensed
  Work to third parties on a hosted or embedded basis in order to compete with IBM Corp's paid
  version(s) of the Licensed Work" (https://github.com/hashicorp/nomad/blob/main/LICENSE). Internal
  self-hosting is fine. Shipping it inside a paid platform is not, if the platform overlaps Nomad
  Enterprise. Also note the support clock: 1.11.x support ends **2026-10-31**; 2.0.x runs to
  2028-04-30 (https://developer.hashicorp.com/nomad/docs/release-notes).

### k3s

k3s is the correct answer to a different question: "I need per-job pod isolation for GitHub Actions
or GitLab CI." It is the only path in this lane to that.

- "Lightweight Kubernetes. Production ready, easy to install, half the memory, all in a binary less
  than 100 MB." and, notably, "Great for: Edge / IoT / **CI**"
  (https://github.com/k3s-io/k3s — README).
- HA needs three servers with embedded etcd
  (https://docs.k3s.io/architecture). Server floor is 2 cores / 2 GB, agent 1 core / 512 MB
  (https://docs.k3s.io/installation/requirements) — an order of magnitude cheaper than Nomad's
  recommended control plane.
- Latest release **v1.37.1+k3s1**, 2026-09-30, Apache-2.0, 34,274 stars.

The CI story is the reason to pick it: "The executor calls the Kubernetes cluster API and creates a
new Pod (with a build container and services containers) for each GitLab CI/CD job"
(https://docs.gitlab.com/runner/executors/), and ARC "applies these resources onto a Kubernetes
cluster. Once applied, it creates a set of Pods that contain your self-hosted runners' containers"
(https://docs.github.com/en/actions/concepts/runners/actions-runner-controller). Ephemeral,
per-job, no shared Docker socket, no runner-manager pets.

Cost: you now own etcd, a CNI, a CSI, ingress, and an upgrade treadmill — and the CNI wants UDP 8472
between every node, so the whole cluster must sit on Mesh (or one LAN), never behind Tunnel.

### Docker Swarm

Do not build on this in 2026. It works, and it is being kept alive, but it is not being developed.

- It does have real job semantics: `--mode replicated-job` / `global-job`, plus `--max-concurrent`
  ("Number of job tasks to run concurrently")
  (https://docs.docker.com/reference/cli/docker/service/create/). "Jobs are a special kind of
  service designed to run an operation to completion and then stop." That is a legitimate CI
  primitive and it is the cheapest one in this lane to operate.
- But the repository activity is dependency hygiene, not features: the last five commits on
  `moby/swarmkit` (2026-10-16) are "remove uses of deprecated grpc.WithInsecure", "remove dead
  code", "bump cst", "remove unused printLogMessages test-utility". Latest release v2.1.2
  (2026-04-23) is "fix lint and go mods", "update go to 1.21", "update to go 1.24"
  (https://github.com/moby/swarmkit/commits, https://github.com/moby/swarmkit/releases).
- Docker's own docs describe Swarm mode neutrally and never claim active development
  (https://docs.docker.com/engine/swarm/). The only forward-looking commitment is a vendor one:
  Mirantis extended Swarm support through 2030 (secondary source:
  https://www.efficientlyconnected.com/mirantis-doubles-down-on-simple-container-orchestration/,
  2025-07-08 — **secondary, mark as such**; the primary is a Mirantis press release).
- Hard gaps for this study: no autoscaling, no CRDs/operators, no CSI, no per-job scheduling
  constraints beyond placement preferences, and the routing mesh needs UDP 4789 across nodes.

### Proxmox VE

The best mature *machine* layer, with one 2026 surprise and one hard network constraint.

- **9.2, released 2026-05-21**, AGPL-3.0 ("Proxmox VE 2.x and higher versions are licensed under the
  GNU Affero General Public License, version 3", https://pve.proxmox.com/wiki/Open_Source).
  9.2 added a real guest placement scheduler: "the cluster resource scheduler (CRS) incorporates
  real-time node and guest resource utilization into every placement decision … can automatically
  migrate guests managed by the High Availability (HA) stack"
  (https://www.proxmox.com/en/about/company-details/press-releases/proxmox-virtual-environment-9-2).
  It also added "Native support for WireGuard and BGP … integrated into the SDN stack", which is a
  pleasant fit with a Mesh/WireGuard-based private network.
- Surprise: PVE now runs OCI images. "With the introduction of OCI … Proxmox VE now also integrates
  'Application Containers' as a technology preview. When creating a container from an OCI image, the
  image is automatically converted to the LXC stack"
  (https://pve.proxmox.com/wiki/Linux_Container). **Technology preview** — this is not a production
  container runtime and there is no rolling update, health check, service discovery or rescheduling
  for those containers. The same page still says "nesting containers inside a Proxmox QEMU VM
  remains a recommended practice", which tells you what the maintainers think.
- Hard constraint: "All nodes must be able to connect to each other via UDP ports 5405-5412 for
  corosync to work" and corosync "needs consistent low latency but not a lot of bandwidth"
  (https://pve.proxmox.com/wiki/Cluster_Manager). **Do not build a PVE cluster across sites over
  Cloudflare Mesh.** One PVE cluster per site; federate at the Nomad layer instead.
- Provisioning API: the REST API is good, and the Terraform provider is genuinely active —
  `bpg/terraform-provider-proxmox`, MPL-2.0, 2,289 stars, v0.119.0 released 2026-10-29 (today).

### Incus

Incus is the better *machine* layer if you are building a product: Apache-2.0, one API, and it can
hand you either a VM or a container from the same call.

- v7.0.2 (2026-10-16), Apache-2.0, 6,524 stars. "It provides a unified experience for running and
  managing full Linux systems inside containers or virtual machines … built around a very powerful,
  yet pretty simple, REST API. Incus scales from one instance on a single machine to a cluster in a
  full data center rack" (https://linuxcontainers.org/incus/docs/main/).
- It speaks OCI: "Incus can consume application container images from any OCI-compatible image
  registry (e.g., the Docker Hub)" (https://linuxcontainers.org/incus/docs/main/explanation/instances/).
- Clustering transport is HTTPS on 8443 — "`incus config set core.https_address=[IP_OR_DNS]:8443`"
  (https://linuxcontainers.org/incus/docs/main/howto/cluster_form/). **BELIEVED**: dqlite/raft over
  TCP tolerates WAN RTT better than corosync's timing-sensitive UDP, so an Incus cluster spanning
  Mesh sites is more plausible than a PVE one. Unconfirmed — no published latency budget.
- Where it fails as an orchestrator: OCI app containers are LXC-wrapped single-process containers.
  There is no bin-packing scheduler for them across the cluster, no health-based rescheduling, no
  rolling deploy, no service discovery, no job/batch concept. You would be scripting all of it
  through the API. Treat Incus as `terraform + cloud-init` with a better API, not as Nomad.

### Harvester and Cozystack

Both are "a cloud in a box", and both are the wrong shape for this study.

- **Harvester** v1.9.0 (2026-09-16), Apache-2.0, 5,227 stars. Production floor is brutal: "A
  three-node cluster is required to fully realize the multi-node features"; production is "16 cores
  minimum", "64 GB minimum", "500 GB minimum, 1 TB or more recommended", "10 Gbps Ethernet minimum",
  "5,000+ random IOPS per disk (SSD/NVMe)"
  (https://docs.harvesterhci.io/v1.9/install/requirements/). It gives you VMs (KubeVirt) and
  Longhorn storage. You still need a container orchestrator on top. You have paid a very high price
  for the privilege of running VMs.
- **Cozystack** v1.6.5 (2026-10-16), Apache-2.0, 2,375 stars. "With Cozystack, you can transform your
  bunch of servers into an intelligent system with a simple REST API for spawning Kubernetes
  clusters, Database-as-a-Service, virtual machines, load balancers, HTTP caching services"
  (https://cozystack.io/docs/). Installation is a three-stage Talos → Kubernetes → Cozystack
  pipeline (https://cozystack.io/docs/install/). It is a well-built platform, but you are adopting
  someone else's opinions about storage, networking, tenancy and upgrades across the whole stack.
  For a team replacing Cloudflare primitives one by one, that is a rewrite, not a component.

### The PaaS layer: Kamal, Dokploy, Coolify, CapRover, Dokku

These are app deployers, not substrates, with one exception worth knowing about.

- **Kamal** (MIT, v2.12.0, 2026-06-18): "Kamal uses kamal-proxy to seamlessly switch requests
  between containers. Works seamlessly across multiple servers, using SSHKit to execute commands"
  (https://github.com/basecamp/kamal). No scheduler, no bin-packing, no queue, no rescheduling
  policy, no multi-tenant model. It deploys a *declared* set of containers to a *declared* set of
  hosts. Excellent for the dashboard's own API process; useless as the substrate.
- **Dokploy** (v0.30.10, 2026-10-22): multi-server means "Remote Servers are independent machines
  that Dokploy manages over SSH. Each remote server runs its own standalone Docker and its own
  Traefik instance" (https://docs.dokploy.com/docs/core/deployment-options). That is a fan-out of
  independent Docker hosts, not a cluster — no placement decision is made for you. Licence is split:
  Apache-2.0 except `/proprietary`, which is the "Dokploy Source Available license (DSAL) version
  1.0" requiring "a valid commercial agreement from Dokploy" for production use
  (https://github.com/Dokploy/dokploy/blob/canary/LICENSE_PROPRIETARY.md). "Open source" is not an
  accurate description of the whole product.
- **Coolify** (Apache-2.0, v4.5.3, 2026-10-28, 65,235 stars — the most-starred thing in this lane):
  "Coolify uses SSH to manage the servers connected to it"
  (https://coolify.io/docs/knowledge-base/server/openssh). Same shape as Dokploy: N independent
  Docker hosts, a control UI, no scheduler. Good product, wrong layer.
- **CapRover** (Apache-2.0 with an appendix, v1.15.5, 2026-10-23): Docker Swarm under the hood and
  it does document multi-node ("In a multi-node cluster, allow the following ports only between
  trusted Swarm nodes: 2377/tcp … 7946/tcp and 7946/udp … 4789/udp",
  https://caprover.com/docs/firewall.html). So it inherits every Swarm limitation above, plus its
  licence appendix restricts modification of paid features.
- **Dokku** (MIT, v0.38.32, 2026-10-25): nominally "a Platform as a Service that runs on a single
  server of your choice" (https://dokku.com/docs/getting-started/installation/). **But** since 0.33
  it ships a k3s scheduler that actually provisions remote nodes over SSH:
  `scheduler-k3s:cluster:add <ssh://user@host:port>` — "This will ssh onto the specified server,
  install k3s, and join it to the current cluster"
  (https://dokku.com/docs/deployment/schedulers/k3s/,
  https://dokku.com/tutorials/other/deploying-to-k3s/). It also wires in KEDA autoscaling, Helm chart
  overrides, node profiles and per-node sysctls. That is the only PaaS in this lane that does
  remote provisioning honestly. It is still an app deployer — it deploys `git push` apps, not
  arbitrary CI jobs — but if the requirement were "deploy my services to my metal with as little
  bespoke code as possible", Dokku is the surprise winner and nobody lists it.

### Heavy CI specifically

Ranking by fitness for heavy CI, with the reason each one fails:

1. **k3s + ARC or GitLab Kubernetes executor** — pod per job, real ephemerality, autoscaling.
   Cost: you run Kubernetes.
2. **Nomad + runner managers as services** — Nomad places and reschedules the runners; the job
   containers are spawned by the runner outside Nomad's view. Cheaper to operate than k3s, worse
   isolation. The 2.1 batch queue (experimental) is the only fairness-aware queue in this lane.
3. **Swarm `replicated-job`** — genuinely simple, `--max-concurrent` is a real concurrency cap, but
   you are building on a project whose last five commits are lint fixes.
4. **Incus / Proxmox as "CI machines"** — you get pets. Snapshot/restore is fast and the API is
   clean, but nothing scales, nothing drains, nothing reschedules.
5. **Harvester / Cozystack** — VM-level only; a CI job that needs a 4-core box waits for a VM to
   boot and for Longhorn to attach a volume.

Two things that do not work no matter which substrate you pick, and are worth writing down before
anyone promises otherwise:

- **You cannot stream a heavy CI job's live log through the Workers dashboard.** Workers VPC
  inherits "standard Workers limits … for request size, timeout, and subrequests". Push logs to R2
  from the runner, read them in the Worker.
- **You cannot put the CI cache on the orchestrator's overlay network and expect it to be fast.**
  All of the overlay options here (VXLAN 8472/4789) tunnel through Mesh; a `ccache`/`cargo` cache
  pull becomes a WAN round trip. Cache has to be node-local or on R2.

### Putting it together — the topology this lane recommends

```
Workers dashboard (dashboard.example.com)
   │  vpc_networks binding, network_id "cf1:network"
   ▼
Cloudflare Mesh ── one Mesh node per site (gateway host, not a cluster node)
   │  private IPs, TCP/UDP/ICMP
   ▼
Site A: Incus (3 members) ──> Nomad servers ×3 (mTLS, 4646) ──> Nomad clients on Incus VMs
Site B: Incus (3 members) ──> Nomad clients, joined to the same region
```

Rules that fall out of the findings above:
- Nomad servers per site, federated, not one region across sites (sub-10 ms rule).
- Never expose 4646, 8006 or 8443 publicly; the Worker reaches them over Mesh only.
- The Mesh gateway host must not be a DNS server and must not be a cluster node with a CNI.
- Machine creation is Incus API + cloud-init, driven by the Worker (or by a small controller);
  Nomad only ever sees a node after it has joined.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| Nomad | https://github.com/hashicorp/nomad | BUSL-1.1 (IBM) | v2.1.0, 2026-10-28 | service/system/batch/sysbatch schedulers, parameterized dispatch, mTLS, ACL, 17,057★ | provisions no machines; no CI executor; 16–32 GB/server recommended; BUSL blocks embedding in a paid product |
| k3s | https://github.com/k3s-io/k3s | Apache-2.0 | v1.37.1+k3s1, 2026-09-30 | full conformant k8s in <100 MB binary, 34,274★; the only route to pod-per-job CI | needs UDP 8472 between all nodes; you own etcd/CNI/CSI/upgrades |
| Docker Swarm | https://github.com/moby/swarmkit | Apache-2.0 | v2.1.2, 2026-04-23; last commit 2026-10-16 | `replicated-job`/`global-job`, `--max-concurrent`; zero extra moving parts | maintenance-only commits; no autoscaling, CSI, or operators; UDP 4789 overlay |
| Proxmox VE | https://www.proxmox.com / https://github.com/proxmox/pve-manager | AGPL-3.0 | 9.2, 2026-05-21 | mature REST API, HA, CRS dynamic load balancer, SDN with WireGuard/BGP, bpg Terraform provider | VM/LXC placement only; corosync UDP 5405–5412 needs low latency → single site; OCI app containers are "technology preview" |
| Incus | https://github.com/lxc/incus | Apache-2.0 | v7.0.2, 2026-10-16 | one REST API for VMs + system containers + OCI images, projects, 6,524★ | no scheduler for app containers, no rolling deploy, no batch concept |
| Harvester | https://github.com/harvester/harvester | Apache-2.0 | v1.9.0, 2026-09-16 | HCI: KubeVirt VMs + Longhorn storage on bare metal | 3 nodes × 16 cores / 64 GB / 500 GB SSD / 10 Gbps for production; VMs only |
| Cozystack | https://github.com/cozystack/cozystack | Apache-2.0 | v1.6.5, 2026-10-16 | turnkey private cloud: managed k8s, DBaaS, VMs, storage, tenancy | requires Talos + k8s; you adopt the whole opinionated stack |
| Kamal | https://github.com/basecamp/kamal | MIT | v2.12.0, 2026-06-18 | dead-simple zero-downtime container deploys over SSH, kamal-proxy, 14,697★ | no scheduler, no queue, no bin-packing — not a substrate |
| Dokploy | https://github.com/Dokploy/dokploy | Apache-2.0 + DSAL for `/proprietary` | v0.30.10, 2026-10-22 | polished UI, remote servers over SSH, 38,107★ | remote servers are independent Docker hosts, no placement; part of it is source-available, not open source |
| Coolify | https://github.com/coollabsio/coolify | Apache-2.0 | v4.5.3, 2026-10-28 | huge community, 65,235★, SSH-managed servers | no scheduler, no HA, no CI job model |
| CapRover | https://github.com/caprover/caprover | Apache-2.0 + appendix | v1.15.5, 2026-10-23 | Swarm-backed PaaS with a manager UI, 15,195★ | inherits Swarm's decline; control plane sits on one manager node; appendix restricts paid-feature modification |
| Dokku | https://github.com/dokku/dokku | MIT | v0.38.32, 2026-10-25 | 32,208★; since 0.33 a k3s scheduler that SSH-provisions nodes (`cluster:add ssh://…`), KEDA autoscaling | deploys `git push` apps, not arbitrary CI jobs; still an app platform |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| Nomad licence | BUSL-1.1, IBM, 1.7.0+ | https://github.com/hashicorp/nomad/blob/main/LICENSE | "Licensor: International Business Machines Corporation (IBM) / Licensed Work: Nomad Version 1.7.0 or later." |
| Nomad BUSL restriction | no competing hosted/embedded use | same | "provided Your use does not include offering the Licensed Work to third parties on a hosted or embedded basis in order to compete with IBM Corp's paid version(s)" |
| Nomad latest release | v2.1.0, 2026-10-28 | https://github.com/hashicorp/nomad/releases/tag/v2.1.0 | "v2.1.0 2026-10-28T18:00:35Z" |
| Nomad 2.1 batch queue | experimental, FIFO + dynamic priority | same | "An new (experimental) batch job queue can be configured on node pools with different queuing options" |
| Nomad 1.11 support end | 2026-10-31 | https://developer.hashicorp.com/nomad/docs/release-notes | "| 1.11.x | October 31, 2026 | October 31, 2026 | October 31, 2026 |" |
| Nomad server sizing | 4–8+ cores, 16–32 GB+, 40–80 GB disk | https://developer.hashicorp.com/nomad/docs/deploy/production/requirements | "We suggest having between 4-8+ cores, 16-32 GB+ of memory, 40-80 GB+ of fast disk" |
| Nomad server latency | sub-10 ms between servers | same | "Nomad servers are expected to have sub 10 millisecond network latencies between each other" |
| Nomad gossip port | 4648 TCP and UDP | same | "Serf WAN (Default 4648). This is used by servers to gossip both over the LAN and WAN to other servers. … TCP and UDP." |
| Nomad schedulers | service, system, batch, sysbatch | https://developer.hashicorp.com/nomad/docs/job-specification/job | "Nomad provides the `service`, `system`, `batch`, and `sysbatch` schedulers" |
| k3s latest release | v1.37.1+k3s1, 2026-09-30 | https://github.com/k3s-io/k3s/releases/latest | "v1.37.1+k3s1 \| 2026-09-30T16:10:38Z" |
| k3s binary size | "less than 100 MB" | https://github.com/k3s-io/k3s | "half the memory, all in a binary less than 100 MB" |
| k3s server floor | 2 cores / 2 GB | https://docs.k3s.io/installation/requirements | "| Server | 2 cores | 2 GB |" |
| k3s VXLAN port | UDP 8472, all nodes | same | "The nodes need to be able to reach other nodes over UDP port 8472 when using the Flannel VXLAN backend" |
| Swarm ports | 2377 TCP, 7946 TCP/UDP, 4789 UDP | https://docs.docker.com/engine/swarm/swarm-tutorial/ | "Port `4789` UDP (configurable) for overlay network traffic" |
| Swarm job modes | replicated-job, global-job | https://docs.docker.com/reference/cli/docker/service/create/ | "Jobs are a special kind of service designed to run an operation to completion and then stop" |
| swarmkit release | v2.1.2, 2026-04-23 | https://github.com/moby/swarmkit/releases | "v2.1.2 \| 2026-04-23T18:21:25Z" — changelog: "fix lint and go mods", "update go to 1.21" |
| Proxmox VE version | 9.2, 2026-05-21 | https://www.proxmox.com/en/about/company-details/press-releases/proxmox-virtual-environment-9-2 | "May 21, 2026 … announced the immediate availability of Proxmox Virtual Environment 9.2" |
| Proxmox licence | AGPL-3.0 for 2.x+ | https://pve.proxmox.com/wiki/Open_Source | "Proxmox VE 2.x and higher versions are licensed under the GNU Affero General Public License, version 3" |
| Proxmox corosync ports | UDP 5405–5412 | https://pve.proxmox.com/wiki/Cluster_Manager | "All nodes must be able to connect to each other via UDP ports 5405-5412 for corosync to work." |
| Proxmox OCI support | technology preview | https://pve.proxmox.com/wiki/Linux_Container | "Proxmox VE now also integrates "Application Containers" as a technology preview" |
| Incus release | v7.0.2, 2026-10-16 | https://github.com/lxc/incus/releases/latest | "v7.0.2 \| 2026-10-16T15:25:36Z" |
| Incus OCI images | any OCI registry | https://linuxcontainers.org/incus/docs/main/explanation/instances/ | "Incus can consume application container images from any OCI-compatible image registry (e.g., the Docker Hub)" |
| Incus API port | 8443 | https://linuxcontainers.org/incus/docs/main/howto/cluster_form/ | "`incus config set core.https_address=[IP_OR_DNS]:8443`" |
| Harvester production floor | 16 cores, 64 GB, 500 GB, 10 Gbps | https://docs.harvesterhci.io/v1.9/install/requirements/ | "16 cores minimum" / "64 GB minimum" / "10 Gbps Ethernet minimum" |
| Harvester node count | 3 nodes | same | "A three-node cluster is required to fully realize the multi-node features of Harvester." |
| Mesh vs Tunnel protocols | Mesh: TCP/UDP/ICMP; Tunnel: HTTP/S, TCP, SSH, RDP, SMB | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/concepts/ | "| **Protocols** | TCP, UDP, ICMP | HTTP/S, TCP, SSH, RDP, SMB (proxied over WebSocket) |" |
| Workers→Mesh binding | single binding reaches all tunnels/mesh | https://developers.cloudflare.com/workers-vpc/examples/connect-to-cloudflare-mesh/ | "With this single binding, your Worker can reach any service across all Cloudflare Tunnels, Mesh nodes, and Cloudflare WAN on-ramps in your account." |
| Workers VPC status | beta; standard Workers limits | https://developers.cloudflare.com/workers-vpc/platform/limits/ | "Workers VPC is currently in beta." / "Standard Workers limits apply for request size, timeout, and subrequests." |
| Mesh + DNS conflict | cannot run on a DNS host | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/best-practices/ | "This will conflict with DNS services running on the same machine (for example, Active Directory DNS, Pi-hole, Unbound, BIND, or dnsmasq)." |
| Mesh + cloudflared | Split Tunnels only | same | "Split Tunnels is the only supported method of running both connectors on the same machine." |
| GitLab executors | no Nomad executor | https://docs.gitlab.com/runner/executors/ | "| Executor | Docker | Docker Autoscaler | Instance | Kubernetes | SSH | Shell | VirtualBox | Parallels | Custom |" |
| ARC needs Kubernetes | operator on a cluster | https://docs.github.com/en/actions/concepts/runners/actions-runner-controller | "An ARC deployment applies these resources onto a Kubernetes cluster." |
| Dokku k3s provisioning | SSH-add nodes | https://dokku.com/docs/deployment/schedulers/k3s/ | "scheduler-k3s:cluster:add [--profile PROFILE] [--role ROLE] … <ssh://user@host:port> # Adds a server node to a Dokku-managed cluster" |
| Dokploy multi-server shape | independent Docker hosts | https://docs.dokploy.com/docs/core/deployment-options | "Remote Servers are independent machines that Dokploy manages over SSH. Each remote server runs its own standalone Docker and its own Traefik instance" |
| Coolify server model | SSH-managed | https://coolify.io/docs/knowledge-base/server/openssh | "Coolify uses SSH to manage the servers connected to it." |
| Star counts (2026-10-29) | nomad 17,057; k3s 34,274; swarmkit 3,652; incus 6,524; harvester 5,227; cozystack 2,375; kamal 14,697; dokploy 38,107; coolify 65,235; caprover 15,195; dokku 32,208; bpg/proxmox 2,289 | https://api.github.com/repos/<owner>/<repo> (via proxy) | `"stargazers_count"` field, read 2026-10-29 |

## Rejected options

| option | why rejected |
|---|---|
| Docker Swarm as the substrate | swarmkit's recent commits are lint/dependency churn only; no autoscaling, CSI, or operator ecosystem; the only long-term support commitment comes from a single vendor (Mirantis, through 2030) |
| Harvester | production floor of 3 × 16 cores / 64 GB / 500 GB SSD / 10 Gbps to get VMs, and VMs are not containers — you still need an orchestrator on top |
| Cozystack | requires Talos + Kubernetes + its own storage/network/tenancy opinions; adopting it is a platform migration, not a component choice |
| Kamal | a deploy tool: no scheduler, no queue, no bin-packing; cannot be the thing that decides where a CI job runs |
| Dokploy | "remote servers" are independent Docker hosts each with their own Traefik; no placement; `/proprietary` is under a source-available licence requiring a commercial agreement |
| Coolify | SSH-managed independent Docker hosts, no scheduler, no HA; great UI, wrong layer |
| CapRover | Swarm-backed PaaS whose control plane lives on one manager node; inherits every Swarm limitation plus a licence appendix restricting paid-feature modification |
| Proxmox VE OCI "Application Containers" as the production runtime | explicitly a "technology preview"; no rolling update, health checking or rescheduling |
| Running any cluster's peer traffic through Cloudflare Tunnel | Tunnel's protocol list is "HTTP/S, TCP, SSH, RDP, SMB (proxied over WebSocket)" — no UDP; k3s 8472, Swarm 4789/7946, Nomad 4648 and corosync 5405–5412 all need UDP |
| One Nomad region spanning sites over Mesh | Nomad servers want sub-10 ms RTT; run one region per site and federate |
| One Proxmox VE cluster spanning sites over Mesh | corosync needs UDP 5405–5412 with "consistent low latency"; corosync over WAN is a known way to lose quorum |
| Streaming CI logs through a Worker `fetch()` to the orchestrator | Workers VPC inherits standard Workers request-size and timeout limits; logs belong in R2 |

## Open questions

- **Does a Cloudflare Mesh node conflict with flannel/calico route management on the same host?**
  The docs only name other VPN clients. Settle by installing a Mesh node on a k3s node, restarting
  flannel, and diffing `ip route` / `iptables-save`. Until then, keep Mesh nodes on dedicated
  gateway hosts with CIDR routes.
- **Can Incus OCI application containers run in a clustered Incus?** The docs describe OCI support
  without stating a cluster restriction, and I could not find a definitive statement either way.
  Settle by creating a 3-member cluster and running `incus launch docker:nginx c1 --target member2`.
- **What is the actual RTT budget for an Incus (dqlite) cluster across Cloudflare Mesh sites?**
  Transport is TCP/8443, which is more WAN-friendly than corosync, but no published latency figure.
  Settle by measuring `incus cluster list` stability under a 30–60 ms injected delay.
- **Is Nomad 2.1's batch job queue good enough to replace an external CI queue?** It is flagged
  experimental in the release notes. Settle by running a few thousand dispatched jobs against a
  3-server cluster and measuring fairness and starvation.
- **Does the BUSL "competitive offering" clause cover this platform?** It turns on whether the
  product is "offered to third parties on a paid basis" and "significantly overlaps with the
  capabilities of IBM Corp's paid version(s)". That is a legal question, not an engineering one.
  Settle with counsel before shipping Nomad inside a paid product; the safe alternative is k3s
  (Apache-2.0).
- **Dokku's k3s scheduler maturity.** It provisions nodes over SSH and wires in KEDA and Helm, which
  is genuinely unusual for a PaaS, but it is new (0.33, and the repo's own issues include k3s init
  failures on small machines). Settle by building a 3-node cluster from a clean Ubuntu image and
  running it for a month.
- **Whether Cloudflare Mesh has a per-node throughput or connection cap that matters for a busy
  CI cache.** No published number found. Settle with a `iperf3` run between two Mesh nodes.
