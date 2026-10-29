# Nomad — deep review

## Verdict

**Yes — Nomad is the right orchestrator for this stack, and it should be the only control plane in it.** It is the one component in the replacement set that is genuinely *simpler* than what it replaces: one static Go binary per host, no etcd/Consul/ZooKeeper, Raft and a BoltDB client store baked in (`nomad/server.go:1373` `setupRaft`, `client/client.go:1346` `restoreState`). For "heavy CI + long-running containers" it maps almost 1:1 onto `batch` jobs with parameterized dispatch and `service` jobs, and the whole thing is drivable over one HTTPS port (4646) — which is exactly the shape a Workers dashboard behind a Tunnel wants. **Caveats that are not negotiable:** it will not give you multi-tenant safety (resource quotas are a no-op in the free build — `nomad/plan_apply_ce.go:27-30`), it is not a sandbox (cgroups + chroot, not a microVM), and the licence is BUSL-1.1 whose "competitive offering" clause is the single largest legal risk in this whole study. Put it in the **compute/orchestration slot**, keep the Workers dashboard as a thin API client, and do not let Raft traffic anywhere near Cloudflare.

## What it actually is

A single-binary, Raft-backed workload scheduler: `server` agents (odd number, quorum) hold all state in Raft + an in-memory memdb index; `client` agents run tasks and keep their own BoltDB of allocation state. Servers and clients are the *same* binary with different config blocks (`command/agent/config.go:1888` onwards). There is no external database, no external service registry required, and no external queue.

The README claims ("Simple & Reliable", "no external services for storage or coordination", "federation out-of-the-box", "10K+ nodes") are mostly true, with one lie by omission: **multi-region *jobs* are Enterprise-only** — `nomad/structs/structs_ce.go:41-47` returns `"Multiregion jobs are unlicensed."` Federation lets you *read* across regions from the free build; it does not let you deploy across them. Same for quotas, Sentinel, audit logging and Autopilot's redundancy zones.

Scale of the thing: 2,186 Go files / 705,897 lines excluding `ui/`; 336 `require` lines in `go.mod`, 131 direct. Published container image `hashicorp/nomad:2.1.0` is **65.6 MB compressed** (Docker Hub API, tag `2.1.0`, `full_size` 65,605,186). The bundled UI is an Ember app (`ui/package.json`) — you will not use it, and you should ship with `ui { enabled = false }`.

## Architecture (with file paths)

**Job types** — five, defined at `nomad/structs/structs.go:4265-4271`:

| type | scheduler | semantics |
|---|---|---|
| `service` | `scheduler/generic_sched.go:53` `GenericScheduler` | long-lived; rescheduled forever; rolling deploys |
| `batch` | same `GenericScheduler`, `batch=true` | runs to completion, job goes `dead`; reschedule attempts 1/24h (`structs.go:6219-6224`) |
| `system` | `scheduler/scheduler_system.go` | exactly one alloc per eligible node, forever |
| `sysbatch` | `scheduler/scheduler_sysbatch.go:25` | one alloc per node, run once, exit |
| `_core` | internal | reserved (`structs.go:4265-4267`) |

Defaults that bite: batch restart policy is 3 attempts / 24 h (`structs.go:6200-6206`), service is 2 attempts / 30 min (`structs.go:6193-6199`). Batch allocs are **not** rescheduled after a node dies — one attempt (`structs.go:6219`). For CI that is usually what you want (fail fast, re-dispatch) but it means node drains during a build kill the build.

**Parameterized dispatch** — the CI primitive. `ParameterizedJobConfig` at `nomad/structs/structs.go:6067-6076`: `Payload` (`optional`/`required`/`forbidden`), `MetaRequired`, `MetaOptional`. Only legal on `batch`/`sysbatch` (`structs.go:4861-4863`). Dispatch RPC at `nomad/job_endpoint.go:1988`; each dispatch **registers a brand-new child job** into Raft, so dispatched jobs are real, listable, GC-able jobs with their own IDs. Three details that matter enormously for a build system:

- **Payload cap is 16 KiB uncompressed** — `DispatchPayloadSizeLimit = 16 * 1024` at `nomad/job_endpoint.go:32-34`, enforced at `:2146`. You cannot pass a git checkout through it; pass a signed URL and a commit SHA in `Meta`.
- **Idempotency token** — `nomad/job_endpoint.go:2046-2055` short-circuits duplicate dispatches by looking for an existing child job with the same token. Wired through `WriteRequest.IdempotencyToken` (`structs.go:449-450`) and emitted as the `idempotency_token` query param (`api/api.go:757-758`). A Worker retry after a timeout will not double-start a build. This is the single best feature in the API for your use case.
- **`IdPrefixTemplate`** — `structs.go:932`; lets the child job ID be templated from meta, so builds get deterministic, greppable IDs.

Retention problem: dispatched jobs are GC'd after `JobGCThreshold`, default **4 hours** (`nomad/config.go:653`), swept every 5 min (`nomad/config.go:651`). Batch evals live 24 h (`nomad/config.go:651`). If you want build history, raise `job_gc_threshold` and store the authoritative record in your own store — Nomad is not a CI history database.

**The two fork/exec drivers.** `drivers/rawexec/driver.go` is `fork/exec` with **no isolation**: `FSIsolation: fsisolation.None` at `:107-115`, and it is **disabled by default** — `"enabled"` defaults to the literal `"false"` at `:83-86`, and `StartTask` returns `errDisabledDriver` at `:391-394`. It runs as the same user as the Nomad process, i.e. root. `drivers/exec/driver.go` is the isolated one: `FSIsolation: fsisolation.Chroot` at `:104-113`, PID/IPC namespace modes default to `private` (docs), and it runs the task through **libcontainer from runc v1.5.2** (`go.mod:122`; `drivers/shared/executor/executor_linux_cgo.go:41-44`) — i.e. Nomad's exec driver *is* runc-as-a-library.

The trap: **the `exec` driver only exists in cgo builds.** `helper/pluginutils/catalog/register_cgo.go:18` registers it; `helper/pluginutils/catalog/register.go` (build tag `!cgo`) does not. Build with `CGO_ENABLED=0` and you silently lose the only isolated driver, leaving `raw_exec`, `docker`, `java`, `qemu`. Also `drivers/shared/executor/executor_linux.go` (`linux && !cgo`) quietly falls back to the universal executor "to prevent compilation issues".

**Networking / ports.** Defaults at `command/agent/config.go:1809-1813`: HTTP `4646` (TCP), RPC `4647` (TCP), Serf `4648` (**TCP *and* UDP** — confirmed by the production requirements doc; `4648` is memberlist's `BindPort`, bound at `command/agent/agent.go:406-407`). Task dynamic ports come from `20000-32000` (`config.go:1843-1844`, ~12,001 ports); reserved allocation ports `14000-14512` (`config.go:1841-1842`). Container networking beyond host mode needs CNI plugins on disk (`client/allocrunner/network_manager_linux.go:171-203`) — another set of moving parts.

**Server proxies the client endpoints.** This is the fact that makes the whole design work. `/v1/client/fs/logs/...` and `/v1/client/allocation/<id>/exec` look like client endpoints, but the API client tries the node directly and **falls back to the server** on any network error (`api/fs.go:206-238`, `api/allocations_exec.go:76-120`), and the server forwards over its existing RPC stream (`nomad/client_fs_endpoint.go:33-36` registers `FileSystem.Logs` / `FileSystem.Stream` as streaming RPCs). So **you never need to expose a single compute node to the internet.**

## The seam into this design

**The one that fits cleanly: `fetch()` from a Worker to the Nomad servers over a Tunnel / Workers VPC.**

Topology: 3 Nomad servers + N clients inside one private network; one `cloudflared` connector; a Workers VPC Service bound to `<server>:4646`; the dashboard Worker calls it. Raft (4647) and Serf (4648/TCP+UDP) **must stay on the private network** — never put Raft over a Tunnel. A Tunnel adds a hop and connection churn; Raft is latency-sensitive and will spend its life electing.

Endpoints the dashboard actually needs, all JSON, all present in `command/agent/http.go:443-600`:

- `POST /v1/job/<id>/dispatch` (`http.go:447` → `JobSpecificRequest`) — start a build. Body `{Payload, Meta, IdPrefixTemplate, Priority}` (`nomad/structs/structs.go:927-934`). Auth: `X-Nomad-Token` header (`command/agent/http.go:1098`). Returns eval ID + dispatched job ID.
- `GET /v1/job/<id>/allocations`, `GET /v1/allocation/<id>` — build status.
- `GET /v1/nodes`, `GET /v1/node/<id>`, `PUT /v1/node/<id>/drain`, `PUT /v1/node/<id>/eligibility` — fleet view; API at `api/nodes.go:42-490`.
- `GET /v1/client/fs/logs/<alloc>?follow=true&type=stdout&origin=start&offset=0` — log tail, via server proxy.
- `GET /v1/event/stream` (`http.go:582`) — NDJSON event firehose for the dashboard's live view.
- `GET /v1/operator/snapshot` (`http.go:574`) — backups you can pull from a Cron Trigger.

**ACL.** Off by default — `command/agent/config.go:1888-1889` sets `ACL.Enabled = false`. Turn it on and bootstrap with `POST /v1/acl/bootstrap` (`http.go:484`), which returns the one management token exactly once. Then **do not store that token in the Worker.** Nomad has OIDC SSO built in and free: `POST /v1/acl/oidc/auth-url` and `POST /v1/acl/login` (`http.go:504-505`), plus `POST /v1/acl/token/onetime` + `/onetime/exchange` (`http.go:482-483`) for one-shot tokens. The right shape is: dashboard authenticates the human, exchanges for a short-TTL Nomad token scoped to their namespace, passes it per-request. The capability vocabulary is fine-grained enough to express "can dispatch and read logs, cannot touch nodes" — `dispatch-job`, `read-job`, `read-logs`, `alloc-exec` (`acl/policy.go:33-80`); note the shorthand `write` policy bundles `dispatch-job` + `alloc-exec` + `read-fs` together (`acl/policy.go:340-355`), which is too much for a build runner.

**The seams that will not work as-is:**

1. **Blocking queries vs the 125 s Proxy Read Timeout.** Nomad's default blocking-query wait is **300 s** (`nomad/structs/structs.go:210-214`, `MaxBlockingRPCQueryTime` and `DefaultBlockingRPCQueryTime` both 300 s). Cloudflare's Proxy Read Timeout is **125 s** and returns 524 (`developers.cloudflare.com/fundamentals/reference/connection-limits/`, verified). Every long-poll must be re-issued with `?wait=30s` or less, or replaced with the event stream. This is a hard, documented mismatch, not a tuning preference.
2. **`follow=true` log streaming on a quiet task.** The Tunnel kills an origin that sends nothing for 125 s (Proxy Read Timeout) and the proxy idle timeout is 900 s. A CI step that thinks for three minutes will drop the log socket. Buffer logs into your object store and serve from there; treat the live tail as best-effort.
3. **CORS.** Only a handful of routes get CORS headers — `wrapCORS` is applied to `/v1/client/fs/`, `/v1/client/stats`, `/v1/client/allocation/`, `/v1/vars`, `/v1/var/` and nowhere else (`command/agent/http.go:1251-1261`, applied at `:515-527`), and it is `AllowedOrigins: ["*"]` with `AllowCredentials: true` (`http.go:82-88`), which browsers reject for credentialed requests anyway. A browser SPA **cannot** call Nomad directly. Everything must go through the Worker. Good news: that is your design already.
4. **`nomad alloc exec`.** It is a WebSocket, and because browsers can't set headers the token is read from the **first message** after upgrade (`command/agent/http.go:794-798`). Workers can proxy the upgrade, but you're building a shell, and `alloc-exec` on a root-run `raw_exec` task is root on the host. I would not expose this from a dashboard at all.

## Limits and failure modes

- **No quotas.** `nomad/plan_apply_ce.go:27-30` — `evaluatePlanQuota` returns `false, nil`. Nothing stops one runaway CI job from consuming the fleet. Your only levers are node pools (`api/node_pools.go`) and client-side `reserved` resources. Per-namespace quota is Enterprise.
- **No sandbox.** cgroups + chroot + namespaces, all requiring **root on the client**. The `exec` driver's docs state plainly it "can only be run when on Linux and running Nomad as root". If the threat model is untrusted third-party code, Nomad is the wrong primitive — you'd need gVisor/Firecracker inside the alloc, and neither is an in-tree driver here.
- **Docker is the only real container runtime**, and it needs a Docker daemon socket (`drivers/docker/config.go:160-170`). No containerd/CRI driver in-tree. Podman is an out-of-tree plugin. That's a daemon you now have to patch and secure on every host.
- **What survives a restart.** Tasks are supervised by a separate go-plugin executor process; the client reattaches by `ReattachConfig` after restart (`drivers/rawexec/driver.go:314-345`, `drivers/exec/driver.go:403-440`). So: **Nomad client process dies → builds keep running.** Machine reboots → builds die. Server quorum lost → no scheduling and no API, but running allocs keep running. Wiped `data_dir` on a client → orphaned processes.
- **Failure blast radius is honest**: lose 1 of 3 servers, nothing happens; lose 2, you lose writes but not running workloads. That's a better story than most of this stack.
- **Port surface**: 3 ports per agent (one of which is TCP+UDP), plus 12,001 dynamic ports for task networking. Firewalling this for a CI fleet is real work.
- **Heartbeat scaling**: node TTL auto-scales to hold `MaxHeartbeatsPerSecond` at 50/s (`nomad/config.go:677`, `nomad/heartbeat.go:107`, `helper/cluster.go:28-38`). Past ~500 nodes the leader deliberately slows heartbeats. It works, but "10K+ nodes" means multi-second detection latency, not magic.
- **Plan apply pipeline defaults to 1** (`command/agent/config.go:1873`, `nomad/leader.go:403`) — single-threaded plan application. Tune it before blaming the scheduler.
- **No log shipping.** Logs are files in the alloc dir on the client. There is no sink. You ship them yourself.

## Licence and governance

**BUSL-1.1, and this is the sharpest edge in the study.** `LICENSE` in-tree: Licensor **International Business Machines Corporation (IBM)**, Licensed Work "Nomad Version 1.7.0 or later", Change Date "Four years from the date the Licensed Work is published", Change License **MPL 2.0**.

Where it actually bites — read the Additional Use Grant carefully, it is narrower than "don't sell Nomad":

> "You may make production use of the Licensed Work, provided Your use does not include offering the Licensed Work to third parties on a hosted or embedded basis in order to compete with IBM Corp's paid version(s) of the Licensed Work."

and then, crucially:

> "Hosting or using the Licensed Work(s) for **internal purposes within an organization** is not considered a competitive offering."

So: **running your own CI on Nomad is fine.** Running Nomad to schedule *your customers'* workloads is the grey zone — it is "hosted … to third parties", and whether it is *competitive* turns on whether your product "significantly overlaps with the capabilities of IBM Corp's paid version(s)". If you sell CI, it does not overlap with Nomad Enterprise. If you sell "a compute platform", a lawyer will want a say. Also note the ratchet is one-way: "If Your Product is not a competitive offering when You first make it generally available, it will not become a competitive offering later due to IBM Corp releasing a new version" — that grandfather clause is genuinely protective and worth relying on, deliberately, in writing.

**Escape hatches, in order of preference:**
1. Pin to **v1.6.3**, the last MPL-2.0 release — verified by fetching `raw.githubusercontent.com/hashicorp/nomad/v1.6.3/LICENSE` ("Mozilla Public License, version 2.0") vs `v1.6.4` (BUSL, "Nomad Version 1.6.4 or later"). v1.6.3 shipped 2023-10-30, so you'd be forking a three-year-old orchestrator. Not recommended.
2. Wait for the **Change Date on v1.6.4: published 2023-12-07, so it converts to MPL-2.0 on ~2027-12-07**. That is 14 months away and gives you a permanently free fork of a 2023-era Nomad.
3. Buy Enterprise. Note the docs' warning: **an Enterprise cluster cannot be downgraded** — OSS servers *panic* when joined to an Enterprise cluster. Do not mix.

**Good news for the dashboard:** the `api/` and `plugins/` Go modules are **MPL-2.0**, not BUSL — all 84 `api/*.go` files carry `SPDX-License-Identifier: MPL-2.0`, and `api/LICENSE` / `plugins/LICENSE` are MPL 2.0. Only 92 of the tree's Go files are MPL; 1,942 are BUSL-1.1. So you may vendor the API client freely. (Irrelevant for a TypeScript Worker, but it means a Go sidecar is unencumbered.)

**Governance.** IBM completed the HashiCorp acquisition on 2025-02-27. The licence file's licensor line and every source header changed from "HashiCorp, Inc." to "IBM Corp." The docs now state that from April 2026 Nomad follows **IBM's V.M.F versioning** (April = new lifecycle, October = features, monthly = fixes), and publish support windows: 2.0.x base support ends **2028-04-30**, extended 2029-04-30, ongoing extended 2032-04-30; 1.11.x base support ended **2026-10-31**. That is a real, enforced upgrade cadence you must staff for.

**Bus factor: low.** 14 distinct authors across the last 100 commits (2026-09-23 → 2026-10-28), led by `tgross` (29), `mismithhisler` (25), `jrasell` (14). 17,057 stars, 2,152 forks, 1,626 open issues, `archived: false`, last push 2026-10-28. This is a healthy, staffed project — the opposite of the abandonment risk you'd carry with a hobbyist alternative.

## Verified facts

| claim | value | source |
|---|---|---|
| Current tree | commit `7399e1f13154e5a643c1c24432819092006ceb14`, 2026-10-28, `Version = "2.1.1"`, `VersionPrerelease = "dev"` | local clone; `version/version.go:22-25` |
| Latest release | v2.1.0, published 2026-10-28T18:00:35Z | GitHub REST `/repos/hashicorp/nomad/releases` |
| Licence (current) | BUSL-1.1; Licensor **IBM**; Change Date 4 years; Change License MPL 2.0 | `LICENSE:1-40` in clone |
| Licence (v1.6.3) | MPL-2.0 ("Copyright (c) 2015 HashiCorp, Inc.") | `raw.githubusercontent.com/hashicorp/nomad/v1.6.3/LICENSE` |
| Licence (v1.6.4) | BUSL-1.1, "Nomad Version 1.6.4 or later" | `raw.githubusercontent.com/hashicorp/nomad/v1.6.4/LICENSE` |
| v1.6.4 publication | 2023-12-07 → Change Date ≈ 2027-12-07 | GitHub REST `/releases/tags/v1.6.4` |
| `api/` + `plugins/` licence | MPL-2.0, 84/84 `api/*.go` carry the SPDX header | `grep -h SPDX api/*.go`; `api/LICENSE` |
| Image size | `hashicorp/nomad:2.1.0` = 65,605,186 bytes compressed | Docker Hub `/v2/repositories/hashicorp/nomad/tags` |
| Code size | 2,186 Go files, 705,897 lines (excl. `ui/`) | local `find`/`wc` |
| Dependency count | 336 `require` entries, 131 direct | `go.mod` |
| Ports | HTTP 4646 TCP, RPC 4647 TCP, Serf 4648 **TCP+UDP** | `command/agent/config.go:1809-1813`; developer.hashicorp.com/nomad/docs/deploy/production/requirements |
| Dynamic port range | 20000–32000 (~12,001 ports) | `command/agent/config.go:1843-1844` |
| Dispatch payload cap | 16 KiB uncompressed | `nomad/job_endpoint.go:32-34`, `:2146` |
| Blocking query cap | 300 s default and max | `nomad/structs/structs.go:210-214` |
| Cloudflare Proxy Read Timeout | 125 s → HTTP 524; Proxy Write 30 s (not adjustable); idle 900 s | developers.cloudflare.com/fundamentals/reference/connection-limits/ |
| Worker duration | HTTP request: **no wall-clock limit**; CPU 30 s default, 5 min max (paid) | developers.cloudflare.com/workers/platform/limits/ |
| Quotas in free build | no-op (`evaluatePlanQuota` returns `false, nil`) | `nomad/plan_apply_ce.go:27-30` |
| Multi-region jobs | Enterprise only | `nomad/structs/structs_ce.go:41-47` |
| `exec` driver requires cgo | registered only in `register_cgo.go` | `helper/pluginutils/catalog/register.go` vs `register_cgo.go:18` |
| `raw_exec` default | disabled (`"enabled"` literal `"false"`), `FSIsolation: None` | `drivers/rawexec/driver.go:83-86`, `:107-115` |
| Container runtime lib | `opencontainers/runc v1.5.2` (libcontainer) | `go.mod:122`; `drivers/shared/executor/executor_linux_cgo.go:41-44` |
| ACL default | disabled | `command/agent/config.go:1888-1889` |
| Job GC threshold | 4 h (job), 24 h (batch eval) | `nomad/config.go:650-655` |
| Enterprise support windows | 2.0.x base 2028-04-30 / ext 2029-04-30 / ongoing 2032-04-30; 1.11.x base ended 2026-10-31 | developer.hashicorp.com/nomad/docs/enterprise |
| IBM acquisition closed | 2025-02-27 | newsroom.ibm.com, 2025-02-27 |
| Commit authorship | 14 distinct authors / last 100 commits | GitHub REST `/commits?per_page=100` |

## Rejected / not for this

- **The bundled Ember UI.** 7.2 MB of `ui/`, an Ember SPA (`ui/package.json`). You are building a Workers dashboard; disable it (`ui { enabled = false }`) and remove an attack surface.
- **Nomad Enterprise, at least initially.** You would be paying for quotas, Sentinel, audit log, multi-region and Autopilot. Buy it only when you can name the specific thing you need — most likely **quotas**, the moment you have more than one team's CI on the cluster.
- **`raw_exec` for CI jobs.** It is the tempting answer for "run this shell script", and it is root-on-host with no isolation and no filesystem boundary. Use it only for trusted, operator-owned system jobs. `exec` (cgo build) or `docker` for anything a developer can influence.
- **Nomad as the artifact/log store.** Not its job. Pair it with the object-storage layer from the rest of this study; Nomad's only storage primitives are host volumes and CSI (`/v1/volume/host/`, `/v1/volume/csi/`, `http.go:472-477`).
- **Nomad as a Cloudflare Containers/Sandbox replacement for untrusted code.** It schedules; it does not sandbox. If the workload is hostile, the sandboxing has to come from somewhere else and Nomad just becomes the placement layer.
- **Putting Raft or Serf through the Tunnel.** Non-negotiable. 4647 and 4648/TCP+UDP stay private.
- **The `nomad` CLI inside the Worker.** There isn't one. Drive the HTTP API directly; the Go `api` module is MPL and irrelevant to a TS Worker anyway.

## Open questions

1. **Does "we run customer CI" count as a competitive offering?** Everything about the licence analysis is fine for internal use; the moment third parties' jobs land on the cluster, this needs a written opinion. Get the grandfather clause documented at GA.
2. **What is the actual Cloudflare path for the Tunnel — Workers VPC Service bound to `host:4646`, or a public hostname behind Access?** VPC Service is cleaner and verified to exist (bind a specific host+port; HTTP and TCP). Confirm the Tunnel's own origin timeouts, which the connection-limits page defers to a separate "origin parameters" doc I did not read.
3. **How do builds get their workspace?** Nomad has no cache primitive. Host volumes (`/v1/volume/host/`) or CSI, or just have the job pull from object storage at start. This decision drives most of the latency budget.
4. **Do you accept a Docker daemon on every host, or build a cgo binary and lean on `exec`?** The former is operationally familiar and gives you image handling for free; the latter removes a daemon but makes you own the root filesystem for each task.
5. **Is `job_gc_threshold = 4h` acceptable, or do you need Nomad to hold build records?** If the dashboard treats Nomad as the source of truth for "what happened to build 1234", 4 hours is far too short.
6. **Quotas or node pools?** If team A's CI can starve team B's long-running services, the free build gives you only node pools and `reserved` resources as a defence. Decide before onboarding the second team, not after.
7. **What happens on the 2.x upgrade treadmill?** IBM's V.M.F model with 2.0.x support ending 2028-04-30 means a forced major-version migration roughly every two years. Who owns that?
