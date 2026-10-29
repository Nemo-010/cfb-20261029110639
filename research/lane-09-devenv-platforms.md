# Lane 09 — cloud dev-environment platforms: Daytona, Coder, DevPod, Gitpod/Envbuilder, Eclipse Che, Okteto, amika

Research date: **2026-10-29**. All repo metadata read through the GitHub proxy on that date. Docs fetched as Markdown the same day. Nothing was deployed or benchmarked; every statement below is from a fetched page, a repo file, or the GitHub API, and is labelled VERIFIED or BELIEVED.

## Verdict

Of the seven comparators, **only Coder is a viable self-hosted control plane** for this study's shape (orchestration off Cloudflare, machines reached over Tunnel/Mesh, SPA on Workers). It is AGPL-3.0 end to end, single Go binary plus PostgreSQL, Terraform-defined workspaces that can target Kubernetes, Docker, cloud VMs or bare machines, and a workspace agent that dials *out* to the control plane. Everything else fails on a hard axis: **Daytona's OSS repo was archived and gutted in June 2026** when the company moved to a private codebase; **Gitpod Classic is sunset and gitpod.io now redirects to Ona**, a closed SaaS; **DevPod is client-only by design** ("No need to install a server backend") and has had no release since June 2025; **Okteto's platform is licence-key-gated proprietary**; **Eclipse Che is Kubernetes/OpenShift-only**; **amika has no self-host path at all**. The single most important caveat about Coder is that it is a *dev-environment* platform, not CI: its one headless job API, `Coder Tasks`, **was deprecated in v2.34 and removed** — the Tasks API now returns errors — and the two features that matter for a fleet (external provisioners, prebuilt workspaces) are Premium-licensed. Coder also requires its control plane to be directly reachable with **no NAT** between workspaces and control plane, which is a real design constraint against the "dashboard on Workers, orchestrator elsewhere" split.

## Findings

### Daytona — the OSS project is dead; only a tag and a fork remain

This is the largest single fact in the lane and it changes the shortlist. `daytonaio/daytona` returns `"archived": true` from the GitHub API, with `"pushed_at": "2026-07-24T07:12:07Z"` and no `license` field at all — because the licence file was deleted from `main`. The repo's `main` branch tree now contains **five entries** (`README.md`, `assets/`, two PNGs, one nested tree). The source is gone from the default branch.

The README states the reason verbatim (VERIFIED, https://github.com/daytonaio/daytona/blob/main/README.md):

> **This repository is no longer maintained.**
>
> As of June 2026, Daytona's core development has moved to a private codebase. This repository will receive no further updates, fixes, or releases.

The company's own announcement post, dated `JUN 11 2026`, is explicit about the motive (VERIFIED, https://www.daytona.io/dotfiles/updates/daytona-is-going-closed-source):

> Today we are moving Daytona's production codebase to closed source.

and about what survives:

> The existing open source repository is not going anywhere. It will stay public so anyone who wants to keep using it, fork it, or build on it can continue to do so. We will no longer maintain or update it, but it remains available as is.

**The code is still obtainable at the tag, not on `main`.** `git/trees/v0.190.0?recursive=1` returns 6,703 entries / 5,770 blobs / ~79 MB, with top-level `libs` (3,306), `apps` (2,587), `examples`, `guides`, `charts`, `docker`. The last release is `v0.190.0` published 2026-06-23T13:25:53Z. The last two commits on `main` are `b40f732a38` "daytona maintenance notice" (2026-06-23) and `ec4c21b2d5` "Fix license link in README" (2026-06-25) — i.e. the repo's final activity was writing its own obituary.

**Licence at the tag is AGPL-3.0**, verified by fetching `https://raw.githubusercontent.com/daytonaio/daytona/v0.190.0/LICENSE` → "GNU AFFERO GENERAL PUBLIC LICENSE / Version 3, 19 November 2007". This matters: AGPL-3.0 means a fork is legally protected, which is exactly what one community project did.

**The fork: `nightona-co/nightona`** (VERIFIED, https://forge.web.pkgforge.dev/github/repos/nightona-co/nightona) — AGPL-3.0, created 2026-07-02, pushed 2026-09-28, **24 stars**. Its README says:

> Community fork of the last AGPL-3.0 release (v0.190.0).

and, critically:

> **Status:** Nightona is in its bootstrap phase. The codebase is functionally identical to Daytona v0.190.0.

So "self-host Daytona" in 2026-10 means "run an unmaintained AGPL snapshot, or a 24-star one-person bootstrap fork of it". Neither is a foundation for a paid service.

**What Daytona's design still teaches, from the live docs (which now document the closed product).** Snapshot semantics are the best in this lane and worth copying conceptually (VERIFIED, https://www.daytona.io/docs/snapshots/):

> container sandboxes capture filesystem state only (**cold snapshots**), VM sandboxes capture filesystem and memory state (**hot snapshots**)

That hot/cold split — filesystem-only for containers, memory+filesystem for VMs — is the correct honesty about what a container snapshot can be. The default snapshot table also shows a first-class GPU class: `daytona-gpu` at 1 vCPU / 1 GiB / 1 GiB / **1 GPU** (VERIFIED, same page), alongside `daytona-small/medium/large` (container), `daytona-vm-*` (Linux VM) and `windows-*`. GPU sandboxes are metered separately (VERIFIED, https://www.daytona.io/docs/limits/):

> **GPU sandboxes** use a separate GPU quota under the [earth region]. Their vCPU, memory, and disk do not count against the tier compute pool.

Pricing is per-second, publicly listed (VERIFIED, https://www.daytona.io/pricing/): vCPU `$0.0504/h`, memory `$0.0162/GiB/h`, storage `$0.000108/GiB/h`, Windows `$0.0858/vCPU/h`, and preemptible GPUs from `Nvidia RTX 4090, $0.57/h` to `Nvidia B300, $4.08/h`. "BYOC" exists but only via sales.

### Coder — the one real candidate, and what it actually is

Coder is the only project here that is simultaneously (a) actively developed, (b) genuinely self-hostable with no licence key for the core, and (c) able to provision onto infrastructure you already own.

Health (VERIFIED, https://forge.web.pkgforge.dev/github/repos/coder/coder): `AGPL-3.0`, **17,220 stars**, 1,641 forks, 1,173 open issues, created 2021-12-22, `"pushed_at": "2026-10-29T11:11:56Z"` — i.e. it was pushed **minutes before this lane was written**. Releases are frequent and patch-level: `v2.38.4` (2026-10-28T21:07:52Z), `v2.37.8` and `v2.36.11` the same day — three supported branches patched simultaneously, which is a real maintenance signal.

**Licence is AGPL-3.0 for the whole repo, including `enterprise/`.** `https://raw.githubusercontent.com/coder/coder/main/LICENSE` is the AGPL-3.0 text, and `enterprise/` contains no separate licence file (contents listing shows only Go packages: `coderd`, `provisionerd`, `wsproxy`, `tailnet`, `audit`, `aiseats`, …). BELIEVED implication: premium features are gated at runtime by a licence key, not by a different licence grant — so the code is readable and forkable, but the commercial features are not free to use. That is a legal posture to confirm with counsel, not something I verified.

**The model, verbatim** (VERIFIED, https://github.com/coder/coder/blob/main/README.md):

> Workspaces are defined with Terraform, connected through a secure Wireguard® tunnel, and automatically shut down when not used.

This is the key architectural difference from every other candidate: a Coder "workspace" is whatever a Terraform module creates — an EC2 instance, a Kubernetes Pod, a Docker container, a Proxmox VM, or a bare machine joined by the agent. Coder is not a container runtime; it is a **Terraform execution engine with an agent-based connectivity layer and a lifecycle database**. That is exactly the right shape for "machines reached over Cloudflare Tunnel": the machine just needs to run `coder agent` and reach the control plane.

**Self-hosting weight is genuinely low**: one Go binary (`coder server`) plus PostgreSQL, no message broker, no object store, no Redis. VERIFIED, https://coder.com/docs/install/server/kubernetes:

> Coder does not manage a database server for you. This is required for storing data about your Coder deployment and resources.

Kubernetes install requires only "Kubernetes cluster running K8s 1.19+" and "Helm 3.5+". A single-binary + Postgres deployment is a two-container compose file.

### Coder's networking model is a hard constraint against the Cloudflare split

This is the caveat that matters most for this study and it is easy to miss. VERIFIED, https://coder.com/docs/admin/networking/:

> The control plane must have an inbound address reachable by users and workspaces, but otherwise, all topologies *just work* with Coder.

> Workspaces connect to the control plane via its external address, set by [`ACCESS_URL`]. There must not be a NAT between workspaces and the control plane.

So Coder expects a **publicly reachable control plane** (`CODER_ACCESS_URL`) that both users and agents dial. It does not run behind an outbound-only tunnel on the agent side. Consequences for the architecture:

- If the Coder control plane lives off-Cloudflare (as the brief wants), it needs its own public ingress/DNS/TLS — fine, but it is a second public surface next to the Workers dashboard.
- The Workers-hosted SPA cannot talk to `coder server` directly unless you put Workers VPC / a Tunnel in front of it, because Coder's API and its WebSocket-based agent transport both need to be proxied.
- Agents need outbound HTTP/HTTPS + WebSocket to the control plane, and UDP to STUN servers for direct connections: "All outbound UDP traffic must be allowed for both the client and the agent on **all ports**". Direct connections fall back to relay through the control plane when NAT traversal fails, so UDP is an optimisation, not a requirement.
- Networking is Tailscale-derived: "Tailscale's open source backs our websocket/HTTPS networking logic." That is a well-understood dependency, not a bespoke protocol.

There is a partial escape hatch: workspace proxies (Premium) can be deployed in other regions, but they still front the same control plane. BELIEVED: a "Coder control plane behind Cloudflare Tunnel, agents dialling the tunnel hostname" topology would work, since cloudflared terminates TLS and forwards WebSockets — but I did not test it, and Coder's docs explicitly warn "Any reverse proxy or ingress between the Coder control plane and clients/agents must support WebSockets."

### Coder's CI story: the headless job API was removed

This is the blunt finding. Coder is not a CI system and its one attempt at one is gone. VERIFIED, https://coder.com/docs/ai-coder/agents/tasks-to-chats-migration/:

> Coder Tasks was deprecated in Coder v2.34 and has been removed, including the Tasks API (`/api/v2/tasks`).

> Migrate now. Coder Tasks has been removed, so requests to the Tasks API fail.

What replaced it is not a job runner. "Coder Agents" runs an **LLM agent loop in the control plane**, with the Chats API (`/api/v2/chats`) — a conversational AI product, not a `POST /jobs {image, cmd}` primitive. The docs are clear that "The two systems are not interchangeable."

What Coder *does* give a CI system: a durable, addressable machine with `coder ssh <workspace> -- <command>`, `coder exec`, port forwarding, and a REST API. So the realistic pattern is **Coder as the executor, an external scheduler as the brain** — exactly the same conclusion lane 07 reached about amika. Coder has no queue, no matrix, no artifact store, no cache, no test-result model. Do not mistake "runs a long-lived container" for "runs CI".

Two features that would help a fleet are **Premium**:

- External provisioners (VERIFIED, https://coder.com/docs/install/operate/provisioners, marked "Premium"): "Each provisioner runs a single concurrent workspace build. For example, running 30 provisioner containers will allow 30 users to start workspaces at the same time." This is the scaling unit and the answer to "how many concurrent builds" — one build per provisioner process.
- Prebuilt workspaces (VERIFIED, https://coder.com/docs/admin/templates/extending-templates/prebuilt-workspaces, marked "Premium"): a warm pool claimed on demand — the closest thing to a warm CI runner pool, and paywalled.

Community/OSS pricing is $0 (VERIFIED, https://coder.com/pricing/ — "Community / Free"), but the page shows **no price** for Premium, only "Annually per user" and "Get a demo". BELIEVED: Coder does not publish per-seat pricing; you must talk to sales.

### Coder persistence and snapshots: Terraform lifecycle, not snapshots

Coder has **no snapshot feature**. Persistence is expressed as Terraform resource lifecycle. VERIFIED, https://coder.com/docs/admin/templates/extending-templates/:

> The resources you define in a template may be *ephemeral* or *persistent*. Persistent resources stay provisioned when workspaces are stopped, where as ephemeral resources are destroyed and recreated on restart.

The documented idiom is "persistent home directory, ephemeral everything else": a PVC or EBS volume that survives stop, with the container/VM rebuilt each start. VERIFIED, https://coder.com/docs/user-guides/workspace-lifecycle/: three states (Running / Stopped / Deleted), and deletion "runs `terraform destroy`, destroying both persistent and ephemeral resources. This action can not be reverted."

Practical consequence: **resume-from-snapshot is not a Coder primitive**. If you want a warm, pre-baked machine you either keep it running (cost) or rebuild it (time), or buy Premium prebuilds. There is no memory snapshot, no filesystem snapshot, no image-from-workspace. Compare Daytona's hot/cold snapshots — Daytona is architecturally better here and unusable for other reasons.

### Eclipse Che — the only fully-open Kubernetes-native option

Che is the most "enterprise open source" of the set: EPL-2.0, Eclipse Foundation governance, upstream of Red Hat OpenShift Dev Spaces. Health (VERIFIED, https://forge.web.pkgforge.dev/github/repos/eclipse-che/che): **7,169 stars**, 1,212 forks, created 2015-03-26, `"pushed_at": "2026-10-28T14:42:19Z"`, latest release `7.124.0` (2026-10-21T13:00:33Z). Release cadence is roughly fortnightly, sustained for a decade.

**Hard constraint: Kubernetes or OpenShift only.** VERIFIED, https://eclipse.dev/che/docs/stable/discover/what-is-che/:

> Che workspaces are Kubernetes or OpenShift Pods that replicate application runtimes used in production and provide a development layer on top: intelligent code completion, debugging, and IDE tools.

There is no Docker or bare-metal provisioner. If your machines are not Kubernetes nodes, Che does not apply. That single sentence disqualifies Che for a fleet of individually-tunnelled machines, unless you run K8s on each.

**Persistence is good and configurable** (VERIFIED, https://eclipse.dev/che/docs/stable/administration-guide/configuring-the-storage-strategy/): three strategies —

> `per-user`: Use a single PVC for all workspaces created by a user.
> `per-workspace`: Each workspace is given its own PVC.
> `ephemeral`: Non-persistent storage; any local changes will be lost when the workspace is stopped.

Default is `per-user`, and `persistUserHome` defaults to `{"enabled": true}` (VERIFIED, CheCluster CR reference). Also from that reference: `secondsOfInactivityBeforeIdling` defaults to **1800** and `secondsOfRunBeforeIdling` defaults to **-1** ("To disable workspace run timeout, set this value to -1"), `startTimeoutSeconds` 300, and `maxNumberOfRunningWorkspacesPerCluster` / `...PerUser` caps. **`secondsOfRunBeforeIdling: -1` is the important number for this study** — Che can be configured to never time a workspace out, which Cloudflare Containers and the Sandbox SDK structurally cannot do.

But: no snapshots. Che 7 removed workspace snapshots and there is no memory/filesystem capture — persistence is PVC-only. GPU is not a Che feature; the docs mention GPU once, in a sizing sentence ("accurately calculate the resource requirements for each CDE, including memory and CPU or GPU needs", https://eclipse.dev/che/docs/stable/install/running-at-scale/), and the devfile schema I fetched (`devfile/api` `schemas/latest/dev-workspace.json`, 291 KB) contains **no `gpu` key at all** — so GPU arrives only through cluster node pools plus whatever pod-override attributes you hand-write. BELIEVED: workable, undocumented, unsupported.

Self-hosting weight is the heaviest of the set: a `CheCluster` CR, the DevWorkspace Operator, a routing/ingress layer, a PostgreSQL, and (per the storage docs) a CSI driver that supports RWX for `per-user`. The docs are candid that generic NFS breaks it: "Kubernetes Persistent Volume Claims (PVCs) cannot reliably enforce storage quotas on a generic NFS volume."

### Okteto — proprietary platform, licence key required

Okteto's CLI is open (`okteto/okteto`, Apache-2.0 — verified from `LICENSE`, "Apache License / Version 2.0, January 2004"; 3,554 stars; release `3.24.1` 2026-10-21; pushed 2026-10-29). The **platform is not**. VERIFIED, https://www.okteto.com/docs/self-hosted/manage/okteto-license.md:

> Okteto requires a license key to use any of our paid products: [BYOC and Self-Hosted].

and VERIFIED, https://www.okteto.com/docs/admin/billing.md:

> Okteto bills per seat on an annual contract.

There is a real free tier — "Start with our Free Tier (5 seats, 1 year)" (https://www.okteto.com/docs/) — which is enough to evaluate but not to build a product on. Pricing for Scale/Enterprise is "Contact us for pricing" on https://www.okteto.com/pricing/; **no number is published**, so this option cannot be costed without a sales call. That alone is disqualifying for a build-vs-buy study.

Technically Okteto is a Kubernetes developer-experience layer: Helm chart containing NGINX Ingress, API, Buildkit, Frontend, Registry, a validating webhook (VERIFIED, https://www.okteto.com/docs/self-hosted/). Its distinguishing feature for this lane is **Volume Snapshots** (VERIFIED, https://www.okteto.com/docs/self-hosted/install/volume-snapshots.md): "Volume Snapshots allow you to initialize persistent volume claims with the contents of a preexisting Volume Snapshot", requiring a CSI driver + `VolumeSnapshotClass`. That is PVC-init-from-snapshot, not sandbox snapshot, and it is cluster-scoped. Okteto also has the closest thing to CI in this lane — "Okteto Test" runs unit/integration/e2e tests *inside* dev environments, and Preview Environments per PR — but both are inside a proprietary product.

### DevPod — client-only by design, and dormant

DevPod cannot be a control plane, and it says so on the tin. VERIFIED, https://github.com/loft-sh/devpod/blob/main/README.md:

> DevPod is a client-only tool to create reproducible developer environments based on a [devcontainer.json] on any backend.

> **Client-only**: No need to install a server backend, DevPod runs only on your computer.

The website repeats it: "Client Only / No server side setup needed." (https://devpod.sh/). There is no server, no multi-user model, no API to schedule against, no fleet state. Each developer runs their own CLI/desktop app that SSHes to a backend.

Health is poor (VERIFIED, https://forge.web.pkgforge.dev/github/repos/loft-sh/devpod): MPL-2.0, **15,297 stars**, `"pushed_at": "2025-11-14T06:33:38Z"` — nearly a year stale at research date. The last commits are `5a0efcbff` "Clarify SSH session requirement for port forwarding" (2025-11-14), then `7b3860792` (2025-07-24), `f9ad03312` (2025-06-23). Latest release is `v0.7.0-alpha.34`, published **2025-06-23T10:54:41Z**, and it is marked prerelease. So: no stable release in over 16 months, last real feature work in June 2025, no 0.7.0 final. Treat as dormant.

Its one durable contribution is the provider interface — "Through DevPod providers, these environments can be created on any backend, such as the local computer, a Kubernetes cluster, any reachable remote machine, or in a VM in the cloud" — which is the same adapter pattern lane 07 found in `@amika/sandbox`. Copy the pattern; do not depend on the project.

### Gitpod — Classic is sunset; the company is now Ona

Gitpod is not an option and the evidence is unusually clean. VERIFIED, https://github.com/gitpod-io/gitpod/blob/main/README.md:

> **[Gitpod has been renamed to Ona]** - mission control for software projects and software engineering agents. We no longer recommend this version of Gitpod

> **Important: [Gitpod Classic pay-as-you-go did sunset on October 15th]** 2025.

`https://www.gitpod.io/` now serves the Ona homepage (`final_url: "https://ona.com/"`, title "Run background agents") — the domain was repurposed. The self-hosted docs path `https://www.gitpod.io/docs/self-hosted/latest/self-hosted` returns **404**, and `gitpod-io/self-hosted` is archived since 2021-10-05. Self-hosted Gitpod was formally ended years before the rename (secondary sources: devclass 2024-11-06 "Gitpod discontinues 'journey of experiments, failures and dead ends with Kubernetes'", and the 2022 HN thread "Ending support for Gitpod Self Hosted").

Confusingly, the repo is **not** dead — it receives security patches (`beff6f390` "Update images digests" 2026-10-26, `0b2ad2f43` "Fix critical Brotli vulnerability" 2026-10-26, `823df85e9` "Fix critical Go runtime, HTTP/2, and CI tooling vulnerabilities" 2026-10-20). That is CVE maintenance of a sunset product, not development. Releases stopped at `2022.11.3` (2023-06-05). The installer still exists at `install/installer` but its own README calls it "an internal tool and as such not expected to be used by those external to Gitpod".

Gitpod's genuinely reusable artifact is **envbuilder**, and it moved to Coder. `coder/envbuilder` (VERIFIED, https://forge.web.pkgforge.dev/github/repos/coder/envbuilder): Apache-2.0, **305 stars**, pushed 2026-10-26. `gitpod-io/envbuilder` does not exist (404) — it lives under `coder/`. It builds a devcontainer into an image *at workspace start* with no Docker daemon. And Coder's own docs have already written it off (VERIFIED, https://github.com/coder/coder/blob/main/docs/admin/templates/managing-templates/envbuilder.md):

> Envbuilder is in **maintenance mode** with no new features planned.

The recommended replacement is Coder's built-in Dev Containers integration. So envbuilder is a useful *technique* (rootless devcontainer materialisation), not a live dependency.

### amika — comparator only, no self-host path

Already deep-read in lane 07 and not re-derived here. Summary with its sources: Apache-2.0, 295 stars, and `docs/self-hosting.md` states "There is currently no supported local CLI path. Rig commands use the hosted Amika control plane." Control plane, UI, relay and gateway are closed source; the `--local` Docker mode was removed. Architecturally it is the closest precedent for this study — orchestration off-Cloudflare, one Cloudflare Durable Object per host as a WebSocket relay — but the relay itself is not in the repo. See `research/lane-07-amika.md`.

### Cross-cutting: which of these can run "heavy CI plus long-running containers"

Taking the two workloads separately, because no single product covers both:

**Long-running containers.** Coder is the answer, with a caveat. A Coder workspace can be a Docker container or a Kubernetes Pod that never idles out (autostop is a schedule you configure, not an enforced ceiling), with a persistent home volume, reachable by `coder ssh` and port-forward, and driven from a REST API. Che can also do this on Kubernetes (`secondsOfRunBeforeIdling: -1`) but only on Kubernetes. Nothing here imposes a runtime ceiling the way Cloudflare Containers (inactivity stop) or Workers Builds (20-minute timeout) do — that is the whole reason to leave Cloudflare for compute.

**Heavy CI.** Nothing in this lane is a CI system. Ranked by distance from being one:
1. **Okteto** — has test execution and PR preview environments, but proprietary and unpriced.
2. **Coder** — has the executor (durable machine + exec API) and Premium prebuilds for warm pools, but the headless Tasks API was removed and there is no queue/matrix/artifacts/cache. Use as an executor behind an external scheduler.
3. **Eclipse Che** — pods that can run anything, but no scheduling model above the pod.
4. **Daytona (forked)** — has sandbox-per-job semantics and snapshots, but no job model and an unmaintained codebase.
5. **DevPod / Gitpod / amika / envbuilder** — not candidates.

The honest conclusion: pick the *executor*, and keep the CI scheduler in your own control plane (which is what the study's architecture already implies). Coder is the executor with the least lock-in because its abstraction is Terraform, so the machine can be anything.

### GPU support, ranked honestly

- **Daytona**: first-class. `daytona-gpu` default snapshot (1 vCPU / 1 GiB / 1 GiB / 1 GPU), separate GPU quota, published preemptible GPU price list. VERIFIED. Irrelevant, because archived.
- **Coder**: no GPU feature. `grep -i gpu` across the entire Coder docs corpus (`llms-full.txt`, 5.4 MB) returns only a parameter-naming example (`data "coder_parameter" "enable_gpu"` used to demo a checkbox form field) and prose about attaching "existing on-premises GPU servers for ML development". The `coder/coder` git tree contains **zero** paths matching `gpu`, and the community module registry (`registry.coder.com/api/modules`, 94 modules) contains **zero** GPU modules. GPU works only because your Terraform template can request a GPU instance type or a K8s node with a device plugin. VERIFIED by absence; the mechanism is BELIEVED (it is just Terraform).
- **Eclipse Che**: no GPU field in the devfile schema; sizing docs mention GPU needs. Effectively "bring a GPU node and hand-write overrides".
- **Okteto**: not documented as a feature; BELIEVED to inherit whatever the cluster offers.
- **DevPod / Gitpod / amika / envbuilder**: irrelevant (client-only / dead / closed / a builder).

If GPU is a requirement, none of the *viable* options gives it to you; you get it from your infrastructure and surface it through Terraform (Coder) or pod overrides (Che).

### Cloudflare fit: what each one forces you to expose

| platform | what must be publicly reachable | fits "SPA on Workers, orchestration off CF"? |
|---|---|---|
| Coder | `CODER_ACCESS_URL` — one HTTPS+WebSocket endpoint for users *and* agents; "There must not be a NAT between workspaces and the control plane" | Yes, with work: put the control plane behind its own ingress or a Cloudflare Tunnel, proxy the API from the Worker via Workers VPC. Agents dial outbound. |
| Eclipse Che | Che gateway + `*.<domain>` wildcard for every workspace port; requires wildcard DNS and TLS | Poorly. Wildcard-per-workspace hostnames are the opposite of a single tunnelled ingress. |
| Okteto | Ingress + wildcard DNS + its own registry + BuildKit | Poorly, and it is proprietary. |
| Daytona (fork) | API + proxy with per-sandbox hostnames `{port}-{sandboxId}.{proxy-domain}` | Poorly; also unmaintained. |
| DevPod | nothing (client-only) | N/A — no server to host. |
| Gitpod Classic | full K8s install incl. its own ws-proxy and wildcard | Dead. |

Coder is the only one whose connectivity model (agent dials out, single control-plane endpoint) is compatible with "machines reached over Cloudflare Tunnel / Mesh" without inventing wildcard DNS per workspace. Che and Daytona both assume a per-workspace hostname, which is exactly what a single Tunnel hostname cannot give you cheaply.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| Daytona (OSS) | https://github.com/daytonaio/daytona | AGPL-3.0 at `v0.190.0`; **no licence on `main`** | archived; `v0.190.0` 2026-06-23; `main` gutted to 5 entries | Best snapshot model in the lane (hot VM / cold container), first-class GPU class, per-second pricing design | **Archived and closed-sourced 2026-06-11**; `main` has no source; unmaintained |
| nightona (Daytona fork) | https://github.com/nightona-co/nightona | AGPL-3.0 | pushed 2026-09-28; created 2026-07-02; 24 stars | Self-hosted-first continuation of v0.190.0, full 2,700-commit history | "bootstrap phase"; packages/images not published; one-maintainer risk |
| **Coder** | https://github.com/coder/coder | AGPL-3.0 (whole repo incl. `enterprise/`) | `v2.38.4` 2026-10-28; pushed 2026-10-29; 17,220 stars | Terraform-defined workspaces on K8s/Docker/VMs/bare metal; outbound agent; single binary + Postgres; `coder ssh`/`exec`; REST API | Not CI (Tasks API removed in v2.34); no snapshots; no GPU feature; external provisioners + prebuilds are Premium; control plane must be reachable with no NAT |
| Coder `envbuilder` | https://github.com/coder/envbuilder | Apache-2.0 | pushed 2026-10-26; 305 stars | Builds a devcontainer into an image at start, no Docker daemon | **"maintenance mode with no new features planned"**; superseded by Coder's Dev Containers integration |
| DevPod | https://github.com/loft-sh/devpod | MPL-2.0 | last commit 2025-11-14 (docs); last release `v0.7.0-alpha.34` 2025-06-23 | devcontainer-on-any-backend with a clean provider interface | **Client-only by design** — no server, no API, no multi-user; dormant, no stable release in 16 months |
| Gitpod / Ona | https://github.com/gitpod-io/gitpod → https://ona.com | AGPL-3.0 (Classic repo) | releases stopped at `2022.11.3` (2023-06-05); repo only gets CVE patches (2026-10-26) | Historical `.gitpod.yml` prebuild model; openvscode-server | **Classic sunset 2025-10-15**; self-hosted docs 404; company is now closed SaaS |
| Eclipse Che | https://github.com/eclipse-che/che | EPL-2.0 | `7.124.0` 2026-10-21; pushed 2026-10-28; 7,169 stars | Kubernetes-native CDE, DevWorkspace operator, `per-user`/`per-workspace`/`ephemeral` PVCs, unlimited run time (`secondsOfRunBeforeIdling: -1`) | **K8s/OpenShift only**; no snapshots; no GPU field in devfile; heaviest install (operator + CR + RWX CSI) |
| Okteto | https://github.com/okteto/okteto (CLI) / https://www.okteto.com | CLI Apache-2.0; **platform proprietary** | CLI `3.24.1` 2026-10-21; platform v1.49 | K8s dev envs, Okteto Test, PR previews, Volume Snapshots (CSI) | **Licence key required**; per-seat annual; **no published price**; K8s only; wildcard ingress |
| amika | https://github.com/gofixpoint/amika | Apache-2.0 | pushed 2026-10-28; 295 stars | Best Cloudflare precedent (DO-per-host relay), tunnel protocol, hostd node agent | No self-host path; control plane/UI/relay closed (see lane 07) |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| Daytona repo archived | `true` | https://forge.web.pkgforge.dev/github/repos/daytonaio/daytona | `"archived": true`, `"pushed_at": "2026-07-24T07:12:07Z"` |
| Daytona stars | 71,443 | https://forge.web.pkgforge.dev/github/repos/daytonaio/daytona | `"stargazers_count": 71443` |
| Daytona `main` tree size | 5 entries (README + assets only) | https://forge.web.pkgforge.dev/github/repos/daytonaio/daytona/git/trees/main?recursive=1 | `entries 5` — `blob README.md`, `tree assets`, 2 PNGs |
| Daytona `v0.190.0` tree | 6,703 entries / 5,770 blobs / ~79 MB | https://forge.web.pkgforge.dev/github/repos/daytonaio/daytona/git/trees/v0.190.0?recursive=1 | `entries 6703`, `blobs 5770`, `total bytes 78997296` |
| Daytona last release | `v0.190.0`, 2026-06-23 | https://forge.web.pkgforge.dev/github/repos/daytonaio/daytona/releases?per_page=3 | `v0.190.0 2026-06-23T13:25:53Z` |
| Daytona licence at tag | AGPL-3.0 | https://raw.githubusercontent.com/daytonaio/daytona/v0.190.0/LICENSE | "GNU AFFERO GENERAL PUBLIC LICENSE / Version 3, 19 November 2007" |
| Daytona unmaintained | as of June 2026 | https://github.com/daytonaio/daytona/blob/main/README.md | "As of June 2026, Daytona's core development has moved to a private codebase. This repository will receive no further updates, fixes, or releases." |
| Daytona closed-source date | 2026-06-11 | https://www.daytona.io/dotfiles/updates/daytona-is-going-closed-source | "JUN 11 2026"; "Today we are moving Daytona's production codebase to closed source." |
| Daytona snapshot semantics | container=cold (fs only), VM=hot (fs+memory) | https://www.daytona.io/docs/snapshots/ | "container sandboxes capture filesystem state only (**cold snapshots**), VM sandboxes capture filesystem and memory state (**hot snapshots**)" |
| Daytona GPU snapshot | `daytona-gpu`, 1 vCPU / 1 GiB / 1 GiB / 1 GPU | https://www.daytona.io/docs/snapshots/ | "**`daytona-gpu`** \| 1 \| 1GiB \| 1GiB \| 1 \| GPU" |
| Daytona GPU quota | separate pool, earth region | https://www.daytona.io/docs/limits/ | "**GPU sandboxes** use a separate GPU quota under the [earth region]" |
| Daytona compute price | $0.0504/vCPU-h, $0.0162/GiB-h, $0.000108/GiB-h | https://www.daytona.io/pricing/ | "Compute, vCPU, $0.0504/h, Memory, GiB, $0.0162/h, Storage, GiB, $0.000108/h" |
| Daytona GPU price, H100 | $2.27/h preemptible | https://www.daytona.io/pricing/ | "Nvidia H100, $2.27/h" |
| nightona fork licence + age | AGPL-3.0, 24 stars, pushed 2026-09-28 | https://forge.web.pkgforge.dev/github/repos/nightona-co/nightona | `"stargazers_count": 24`, `"license": {"spdx_id": "AGPL-3.0"}`, `"pushed_at": "2026-09-28T22:16:11Z"` |
| nightona maturity | bootstrap phase | https://github.com/nightona-co/nightona/blob/main/README.md | "**Status:** Nightona is in its bootstrap phase. The codebase is functionally identical to Daytona v0.190.0." |
| Coder licence | AGPL-3.0 | https://forge.web.pkgforge.dev/github/repos/coder/coder | `"license": {"spdx_id": "AGPL-3.0"}`; LICENSE file body: "GNU AFFERO GENERAL PUBLIC LICENSE / Version 3" |
| Coder stars / issues | 17,220 / 1,173 | https://forge.web.pkgforge.dev/github/repos/coder/coder | `"stargazers_count": 17220`, `"open_issues_count": 1173` |
| Coder last push | 2026-10-29T11:11:56Z | https://forge.web.pkgforge.dev/github/repos/coder/coder | `"pushed_at": "2026-10-29T11:11:56Z"` |
| Coder latest release | `v2.38.4`, 2026-10-28 | https://forge.web.pkgforge.dev/github/repos/coder/coder/releases?per_page=3 | `v2.38.4 2026-10-28T21:07:52Z` (plus `v2.37.8`, `v2.36.11` same day) |
| Coder workspace model | Terraform + WireGuard tunnel | https://github.com/coder/coder/blob/main/README.md | "Workspaces are defined with Terraform, connected through a secure Wireguard® tunnel, and automatically shut down when not used." |
| Coder needs Postgres | yes, unmanaged | https://coder.com/docs/install/server/kubernetes | "Coder does not manage a database server for you. This is required for storing data about your Coder deployment and resources." |
| Coder K8s install floor | K8s 1.19+, Helm 3.5+ | https://coder.com/docs/install/server/kubernetes | "Kubernetes cluster running K8s 1.19+", "Helm 3.5+ installed on your local machine" |
| Coder no-NAT requirement | control plane must be inbound-reachable | https://coder.com/docs/admin/networking/ | "The control plane must have an inbound address reachable by users and workspaces"; "There must not be a NAT between workspaces and the control plane." |
| Coder ingress must support WebSockets | yes | https://coder.com/docs/admin/networking/ | "Any reverse proxy or ingress between the Coder control plane and clients/agents must support WebSockets." |
| Coder networking basis | Tailscale OSS | https://coder.com/docs/admin/networking/ | "Tailscale's open source backs our websocket/HTTPS networking logic." |
| Coder Tasks removed | v2.34, Tasks API fails | https://coder.com/docs/ai-coder/agents/tasks-to-chats-migration/ | "Coder Tasks was deprecated in Coder v2.34 and has been removed, including the Tasks API (`/api/v2/tasks`)." |
| Coder provisioner concurrency | 1 build per provisioner; Premium | https://coder.com/docs/install/operate/provisioners | "Each provisioner runs a single concurrent workspace build. For example, running 30 provisioner containers will allow 30 users to start workspaces at the same time." |
| Coder prebuilds | Premium | https://coder.com/docs/admin/templates/extending-templates/prebuilt-workspaces | "Prebuilt workspaces (prebuilds) reduce workspace creation time with an automatically-maintained pool of ready-to-use workspaces" (page badge: "Premium") |
| Coder persistence model | Terraform ephemeral/persistent | https://coder.com/docs/admin/templates/extending-templates/ | "Persistent resources stay provisioned when workspaces are stopped, where as ephemeral resources are destroyed and recreated on restart." |
| Coder delete is destructive | terraform destroy, irreversible | https://coder.com/docs/user-guides/workspace-lifecycle/ | "A delete workspace build runs `terraform destroy`, destroying both persistent and ephemeral resources. This action can not be reverted." |
| Coder Community price | $0 | https://coder.com/pricing/ | "Community / Free"; Premium shows only "Annually per user" with no figure |
| Coder GPU coverage | zero GPU paths in repo, zero GPU modules in registry, no GPU doc page | https://registry.coder.com/api/modules + https://forge.web.pkgforge.dev/github/repos/coder/coder/git/trees/main?recursive=1 | 94 modules returned, none matching `gpu`; git tree has no path containing `gpu` |
| DevPod licence | MPL-2.0 | https://raw.githubusercontent.com/loft-sh/devpod/main/LICENSE | "Mozilla Public License Version 2.0" |
| DevPod stars / staleness | 15,297; pushed 2025-11-14 | https://forge.web.pkgforge.dev/github/repos/loft-sh/devpod | `"stargazers_count": 15297`, `"pushed_at": "2025-11-14T06:33:38Z"` |
| DevPod last release | `v0.7.0-alpha.34`, 2025-06-23, prerelease | https://forge.web.pkgforge.dev/github/repos/loft-sh/devpod/releases?per_page=3 | `v0.7.0-alpha.34 2025-06-23T10:54:41Z True` |
| DevPod is client-only | yes, by design | https://github.com/loft-sh/devpod/blob/main/README.md | "**Client-only**: No need to install a server backend, DevPod runs only on your computer." |
| Gitpod renamed | to Ona; Classic sunset 2025-10-15 | https://github.com/gitpod-io/gitpod/blob/main/README.md | "**Gitpod has been renamed to Ona**"; "Gitpod Classic pay-as-you-go did sunset on October 15th" 2025 |
| Gitpod self-hosted docs gone | HTTP 404 | https://www.gitpod.io/docs/self-hosted/latest/self-hosted | 404 at research time; `gitpod-io/self-hosted` archived 2021-10-05 |
| Gitpod last release | `2022.11.3`, 2023-06-05 | https://forge.web.pkgforge.dev/github/repos/gitpod-io/gitpod/releases?per_page=3 | `2022.11.3 2023-06-05T12:24:19Z False` |
| Gitpod repo activity | CVE patches only, 2026-10-26 | https://forge.web.pkgforge.dev/github/repos/gitpod-io/gitpod/commits?per_page=8 | "Fix critical Brotli vulnerability (#21642)" 2026-10-26; "Fix critical Go runtime, HTTP/2, and CI tooling vulnerabilities" 2026-10-20 |
| envbuilder location + licence | `coder/envbuilder`, Apache-2.0, 305 stars | https://forge.web.pkgforge.dev/github/repos/coder/envbuilder | `"full_name": "coder/envbuilder"`, `"stargazers_count": 305`; `gitpod-io/envbuilder` → 404 |
| envbuilder status | maintenance mode | https://github.com/coder/coder/blob/main/docs/admin/templates/managing-templates/envbuilder.md | "Envbuilder is in **maintenance mode** with no new features planned." |
| Che licence | EPL-2.0 | https://raw.githubusercontent.com/eclipse-che/che/main/LICENSE | "Eclipse Public License - v 2.0" |
| Che stars / release | 7,169; `7.124.0` 2026-10-21 | https://forge.web.pkgforge.dev/github/repos/eclipse-che/che | `"stargazers_count": 7169`; release `7.124.0 2026-10-21T13:00:33Z` |
| Che platform requirement | K8s or OpenShift pods only | https://eclipse.dev/che/docs/stable/discover/what-is-che/ | "Che workspaces are Kubernetes or OpenShift Pods" |
| Che storage strategies | per-user (default) / per-workspace / ephemeral | https://eclipse.dev/che/docs/stable/administration-guide/configuring-the-storage-strategy/ | "`per-user`: Use a single PVC for all workspaces created by a user." / "`ephemeral`: Non-persistent storage; any local changes will be lost when the workspace is stopped." |
| Che idle / run timeouts | idle 1800 s; run `-1` (unlimited) | https://eclipse.dev/che/docs/stable/administration-guide/checluster-custom-resource-fields-reference/ | `secondsOfInactivityBeforeIdling` default `1800`; `secondsOfRunBeforeIdling` default `-1` — "To disable workspace run timeout, set this value to -1." |
| Che persistent home default | enabled | same CR reference | `persistUserHome` … `{ "enabled": true}` |
| Che start timeout | 300 s | same CR reference | `startTimeoutSeconds` … `300` |
| Che devfile has no GPU field | no `gpu` key in schema | https://raw.githubusercontent.com/devfile/api/main/schemas/latest/dev-workspace.json | 291,300-byte schema; `grep -io "gpu[A-Za-z]*"` → no matches |
| Okteto CLI licence | Apache-2.0 | https://raw.githubusercontent.com/okteto/okteto/master/LICENSE | "Apache License / Version 2.0, January 2004" |
| Okteto CLI release / stars | `3.24.1` 2026-10-21; 3,554 | https://forge.web.pkgforge.dev/github/repos/okteto/okteto | `3.24.1 2026-10-21T17:04:44Z`; `"stargazers_count": 3554` |
| Okteto platform needs a licence key | yes | https://www.okteto.com/docs/self-hosted/manage/okteto-license.md | "Okteto requires a license key to use any of our paid products: [BYOC and Self-Hosted]." |
| Okteto billing model | per seat, annual | https://www.okteto.com/docs/admin/billing.md | "Okteto bills per seat on an annual contract." |
| Okteto free tier | 5 seats, 1 year | https://www.okteto.com/docs/ | "Start with our Free Tier (5 seats, 1 year)" |
| Okteto published price | none | https://www.okteto.com/pricing/ | Scale: "Contact us for pricing"; Enterprise: "Contact us for pricing" |
| Okteto snapshots | PVC init from VolumeSnapshot, CSI required | https://www.okteto.com/docs/self-hosted/install/volume-snapshots.md | "Volume Snapshots allow you to initialize persistent volume claims with the contents of a preexisting Volume Snapshot." |
| amika self-host | unsupported | https://github.com/gofixpoint/amika/blob/main/docs/self-hosting.md | "There is currently no supported local CLI path. Rig commands use the hosted Amika control plane." |

## Rejected options

| option | why rejected |
|---|---|
| Daytona OSS as the platform | Repo archived; `main` reduced to a README and two images; "This repository will receive no further updates, fixes, or releases." No source on the default branch. |
| Daytona `v0.190.0` tag as a frozen base | Code is retrievable (5,770 blobs) and AGPL-3.0, but it is a dead snapshot of a product that has since diverged. You would own all security work on an isolation layer — the exact thing Daytona said it could not keep safe in the open. |
| nightona as a Daytona substitute | 24 stars, created 2026-07-02, self-described "bootstrap phase", images and packages unpublished. One-maintainer dependency for a security boundary. |
| Coder as a CI system | `Coder Tasks` "was deprecated in Coder v2.34 and has been removed"; the Tasks API returns errors. No queue, matrix, artifacts, cache, or test-result model. Use it as an executor behind your own scheduler. |
| Coder Tasks / Chats API as a generic job primitive | The Chats API is an LLM agent loop (`/api/v2/chats`), not `POST /jobs`. Docs: "The two systems are not interchangeable." |
| Coder without the Premium licence | External provisioners and prebuilt workspaces — the two features that make it a fleet — are Premium. Community edition gives you workspaces, templates, autostart/autostop and the API. |
| Coder as a snapshot/resume engine | No snapshot feature exists. Persistence is Terraform lifecycle (`persistent` vs `ephemeral`); delete runs `terraform destroy` irreversibly. |
| Coder behind a NAT / outbound-only control plane | Docs: "There must not be a NAT between workspaces and the control plane." The control plane needs its own inbound HTTPS+WebSocket endpoint. |
| DevPod as the control plane | It is client-only by construction — "No need to install a server backend". There is no server to host, no multi-user model, no scheduling API. |
| DevPod as a maintained dependency | Last release `v0.7.0-alpha.34` (2025-06-23, prerelease); last commit 2025-11-14 and it was a docs clarification. |
| Gitpod Classic (hosted or self-hosted) | "Gitpod has been renamed to Ona"; Classic PAYG sunset 2025-10-15; self-hosted docs 404; self-hosted support ended years earlier; releases stopped 2023-06-05. |
| Gitpod Flex / Ona as a self-hosted platform | Ona is a closed SaaS ("Contact sales"); `gitpod.io` redirects to `ona.com`. Nothing to self-host. |
| envbuilder as a runtime component | "maintenance mode with no new features planned"; Coder replaced it with its built-in Dev Containers integration. |
| Eclipse Che for non-Kubernetes machines | "Che workspaces are Kubernetes or OpenShift Pods". No Docker or bare-metal path. |
| Eclipse Che as a snapshot solution | No snapshot capability; persistence is PVC strategy only (`per-user`/`per-workspace`/`ephemeral`). |
| Eclipse Che for GPU workloads | No GPU field in the devfile schema; GPU appears only as a cluster-sizing remark. Would need hand-written pod overrides and GPU nodes. |
| Okteto as a costed option | Platform requires a licence key; "Okteto bills per seat on an annual contract"; Scale and Enterprise are "Contact us for pricing" — no number exists to model. |
| Okteto as a self-hosted OSS platform | Only the CLI is Apache-2.0; the platform is proprietary and licence-gated. |
| amika as any part of the compute plane | No self-host path; control plane, UI, relay and gateway closed source (lane 07). |

## Open questions

- **Does Coder's AGPL-3.0 licence actually permit production use of `enterprise/` code without a Premium licence?** The code is in the AGPL repo with no separate licence file, but features are runtime-gated. Settle by reading `coder/coder`'s `enterprise/` headers and any `LICENSE.enterprise`/CLA, and by asking Coder legal directly — this is a counsel question, not a docs question.
- **What does Coder Premium cost per seat?** https://coder.com/pricing/ shows only "Annually per user". Settle with a sales quote for a named seat count; until then Coder cannot be cost-compared against Cloudflare Containers in lane 10.
- **Can Coder's control plane run behind a Cloudflare Tunnel?** Docs require an inbound WebSocket-capable endpoint and say there must be no NAT. A tunnel technically satisfies both, but I did not test agent registration, `coder ping`, or STUN/direct-connection behaviour through `cloudflared`. Settle with a two-machine test: `coder server` behind a named tunnel, one workspace agent, measure `coder ssh` latency and whether it degrades to relay-only.
- **How many concurrent workspaces can one Coder control plane hold, and what does the provisioner ceiling mean in practice?** Docs give "one concurrent workspace build" per provisioner process, which is a hard concurrency cap on *builds* (not on running workspaces). No published number for max running workspaces or agent fan-out per `coderd`. Settle with Coder's scale-testing docs (`/docs/install/validate/scale-testing/`) plus an actual 100-workspace soak.
- **Is Coder's Terraform-on-every-build acceptable latency for CI?** Each start runs a Terraform apply. No published timing. Settle by timing `coder create` → agent ready for a Docker template and a Kubernetes template on real hardware.
- **Does Eclipse Che actually support GPU via devfile pod overrides in a documented way?** The devfile schema has no `gpu` key and Che's docs never show an example. Settle by reading the DevWorkspace operator's `pod-overrides` attribute docs and testing an `nvidia.com/gpu` limit on a GPU node.
- **Is `nightona` a serious project or a placeholder?** 24 stars, one apparent maintainer, "bootstrap phase". Settle by watching commit cadence and whether Nightona-named images ever publish; treat as unusable until then.
- **What happened to Gitpod's self-hosted installer support, exactly, and when?** The repo retains `install/installer` and calls it "an internal tool", the docs 404, and `gitpod-io/self-hosted` is archived since 2021. The formal end-of-support announcement date is only attested by secondary sources (devclass, HN). Settle by finding the original gitpod.io blog post in the Wayback Machine.
- **Does Daytona's hosted product offer real self-hosting/BYOC on terms a self-hoster could use?** Pricing page lists "BYOC" under Enterprise, "Contact Sales". Settle by asking Daytona sales whether BYOC ships the control plane into your cluster and at what price — likely irrelevant given the closed-source posture, but it is the only remaining Daytona path.
- **Is the Coder module registry's absence of GPU modules an ecosystem gap or a deliberate stance?** 94 modules, zero GPU. Settle by searching Coder's GitHub discussions for GPU templates and counting maintained examples.
