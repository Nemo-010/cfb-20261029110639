# Lane 01 — Cloudflare product baseline: R2, Workers, Durable Objects, Containers, Sandbox, Queues, D1, Tunnel, Mesh, Access

Research date: **2026-10-29**. All prices in USD, all figures taken from `developers.cloudflare.com` and `cloudflare.com` on that date. Cloudflare changes prices and limits without much notice; re-verify before committing to a design.

## Verdict

Cloudflare's developer platform is priced for *request-shaped* workloads, not for *machine-shaped* ones. R2 is genuinely excellent and cheap (egress free, $0.015/GB-month, 5 TiB objects) and is the one product in this list that beats a self-hosted replacement on both cost and operational burden for most teams. Workers and Durable Objects are cheap and fast but hard-capped at 128 MB memory / 5 min CPU per invocation and 10 GB per Durable Object — fine for a control plane, useless for compute. Containers (GA 2026-04-13) are the only real compute option and they are small: **max 4 vCPU, 12 GiB RAM, 20 GB disk per instance, and 50 GB of total image storage per account** — one decent CI image with toolchains can eat the whole account's image budget. The single most important caveat is that a Container is stopped when its Durable Object goes inactive even if a build is still running inside it: Cloudflare's own docs say "Code that runs inside the instance does not count as activity… the instance stops when the inactivity timeout ends, even while a build, a test suite, or an agent task still runs inside it", and the inactivity timeout is capped at 6 hours. That makes Containers/Sandbox structurally wrong as the primary executor for heavy or long CI, regardless of price. Secondary hard blockers: no inbound TCP/UDP to containers, no persistent disk (snapshots only, 20 GB, 30-day TTL), 50 Mesh nodes per account, and Workers Builds' 20-minute hard build timeout.

## Findings

### R2 — the one product worth adopting as-is

Pricing (VERIFIED, https://developers.cloudflare.com/r2/pricing/): Standard $0.015/GB-month, Infrequent Access $0.01/GB-month; Class A $4.50/million (IA $9.00), Class B $0.36/million (IA $0.90); IA data retrieval $0.01/GB; **egress free for both classes**. Free tier is Standard-only: 10 GB-month, 1M Class A, 10M Class B per month.

Egress footnote, verbatim: *"Egressing directly from R2, including via the Workers API, S3 API, and `r2.dev` domains does not incur data transfer (egress) charges and is free."*

Limits (VERIFIED, https://developers.cloudflare.com/r2/platform/limits/): object size 5 TiB ("The object size limit is 5 GiB less than 5 TiB, so 4.995 TiB"); single-part upload 5 GiB; multipart up to 4.995 TiB with 10,000 parts; unlimited objects and data per bucket; 1,000,000 buckets/account; 100 custom domains per bucket; 50 bucket-management ops/s per bucket; 1 concurrent write per second to the same key.

Billing gotcha (VERIFIED, same page): **Cloudflare rounds usage up to the next billing unit** — "If you have used 1.1 GB-month, you will be billed for 2 GB-month." For many small buckets or bursty artifact churn this rounding, not the headline rate, sets the bill.

What R2 does **not** do (VERIFIED, https://developers.cloudflare.com/r2/api/s3/api/): the S3 API is partial. Bucket-level operations marked unimplemented include `PutBucketAcl`/`GetBucketAcl`, `PutBucketPolicy`/`GetBucketPolicy`, `PutBucketVersioning`/`GetBucketVersioning`, `PutObjectLockConfiguration`/`GetObjectLockConfiguration`, `PutBucketReplication`, `PutBucketLogging`, `PutBucketNotificationConfiguration`, `PutBucketWebsite`, `PutPublicAccessBlock`. Practically: no ACLs, no bucket policies (auth is via API tokens), no object lock / WORM, no replication, no bucket notifications, no static website hosting. If a self-hosted tool assumes any of those, R2 will fail at the first `PutBucketPolicy`.

`r2.dev` managed public access is explicitly not for production: "not intended for production usage and has a variable rate limit applied to it… requests to your `r2.dev` endpoint will be temporarily throttled and you will receive a `429 Too Many Requests` response."

The Cloudflare REST API is rate limited to 1,200 requests per five minutes across all R2 operations on the account — for a control plane that enumerates objects per machine, use the S3 API, not the REST API.

### Workers — cheap, and deliberately small

Paid plan (VERIFIED, https://developers.cloudflare.com/workers/platform/pricing/): **"a minimum charge of $5 USD per month for an account"**; 10M requests/month included then $0.30/M; 30M CPU-ms/month included then $0.02/M CPU-ms; no charge or limit on duration; no egress charges.

Hard limits (VERIFIED, https://developers.cloudflare.com/workers/platform/limits/): **memory 128 MB per isolate, both plans**; CPU 10 ms (Free) / 5 min max (Paid, default 30 s); subrequests 50 (Free) / 10,000 (Paid, "up to 10M"); 6 simultaneous outgoing connections per request; Worker size 64 MiB; startup 1 s; 500 Workers (Paid, raisable).

The 128 MB isolate ceiling is the number that matters. Anything that buffers a build log, a tarball, or a large JSON response in memory dies here. The 6-concurrent-outbound-connections limit is easy to hit when fanning out health checks across machines.

Request body limits are set by the *zone* plan, not the Workers plan: Free/Pro 100 MB, Business 200 MB, Enterprise up to 5 GB (VERIFIED, limits page). A dashboard upload path inherits this.

### Workers Builds (the "Workers CI" product) — 20-minute ceiling

VERIFIED, https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/ (page last updated 2026-10-28):

| Metric | Free | Paid |
|---|---|---|
| Build minutes | 3,000/month | 6,000/month, then **+$0.005/minute** |
| Concurrent builds | 1 | **6** |
| **Build timeout** | **20 minutes** | **20 minutes** |
| CPU | 2 vCPU | 4 vCPU |
| Memory | 8 GB | 8 GB |
| Disk | 20 GB | 20 GB |
| Retention | 90 days | 90 days |

This is not a CI product in the GitHub-Actions sense. 6 concurrent builds and a 20-minute hard timeout means it cannot run a large test matrix or a long compile. It is a "build my Worker and deploy it" service. The build image is a fixed image with pinned toolchains (Go 1.27.3, Node 24.22.1, Python 3.14.8, Ruby 3.4.11, Bun 1.4.4, npm 10.9.2, pnpm 10.11.1, yarn 4.18.1 — VERIFIED, https://developers.cloudflare.com/workers/ci-cd/builds/build-image/); packages are installed with `apt` and no Docker daemon is documented, so image-building CI is out of scope.

### Durable Objects — a good lock/queue primitive, a bad database

Compute (VERIFIED, https://developers.cloudflare.com/durable-objects/platform/pricing/): Paid 1M requests/month included + $0.15/M; **400,000 GB-s/month included + $12.50/million GB-s**. Duration is wall-clock while active or idle-but-not-hibernatable, and **is billed on a flat 128 MB allocation regardless of actual use**: *"Duration billing charges for the 128 MB of memory your Durable Object is allocated, regardless of actual usage."* WebSocket hibernation avoids duration charges; `accept()`ed WebSockets bill for the whole connection.

SQLite storage billing (VERIFIED, same page): rows read — first 25 billion/month included + $0.001/M; rows written — first 50 million/month included + **$1.00/M**; stored data 5 GB-month included + $0.20/GB-month. Note the note: *"Storage billing for SQLite-backed Durable Objects will be enabled in January 2026, with a target date of January 7, 2026 (no earlier)."*

Limits (VERIFIED, https://developers.cloudflare.com/durable-objects/platform/limits/): **10 GB storage per Durable Object** (Paid; 1 GB Free); 128 MB memory; key+value ≤ 2 MB; WebSocket message ≤ 32 MiB; 500 DO classes/account (Paid); CPU 30 s default / 5 min max per request; 6 simultaneous outgoing connections.

The $1.00 per million rows written is the trap for a coordination layer. A scheduler that writes a row per job-state transition, per heartbeat, and per lease renewal will hit this hard — 10M transitions/month is $10, but 1M jobs × 30 heartbeats is 30M rows = $30, before reads.

### Containers — the only compute, and it is small

GA since 2026-04-13 (VERIFIED, https://developers.cloudflare.com/changelog/post/2026-04-13-containers-sandbox-ga/: *"Cloudflare Containers and Sandboxes are now generally available."*).

Pricing (VERIFIED, https://developers.cloudflare.com/containers/platform/pricing/), billed per 10 ms of active running, on the $5 Workers Paid plan:

| | Included/month | Overage |
|---|---|---|
| Memory | 25 GiB-hours | +$0.0000025 per GiB-second |
| CPU | **375 vCPU-minutes** | +$0.000020 per vCPU-second |
| Disk | 200 GB-hours | +$0.00000007 per GB-second |

Memory and disk bill on **provisioned** resources; CPU bills on **active usage** only. Egress: North America & Europe $0.025/GB with 1 TB/month included; Oceania/Korea/Taiwan $0.05/GB with 500 GB; everywhere else $0.04/GB with 500 GB.

Instance types (VERIFIED, https://developers.cloudflare.com/containers/platform/limits/): lite 1/16 vCPU / 256 MiB / 2 GB; basic 1/4 / 1 GiB / 4 GB; standard-1 1/2 / 4 GiB / 8 GB; standard-2 1 / 6 GiB / 12 GB; standard-3 2 / 8 GiB / 16 GB; **standard-4 4 / 12 GiB / 20 GB**. Custom types are capped at min 1 vCPU, max 4 vCPU, 12 GiB memory, 20 GB disk, and a minimum 3 GiB memory per vCPU.

Account limits (VERIFIED, same page): concurrent memory **6 TiB**, concurrent vCPU **1,500**, concurrent disk **30 TB**, **total image storage per account 50 GB**, image size ≤ instance disk.

Worked cost, standard-4 at full tilt for one hour (my arithmetic from the published rates): memory 12 GiB × 3600 s = 43,200 GiB-s × $0.0000025 = $0.108; CPU 4 × 3600 = 14,400 vCPU-s × $0.000020 = $0.288; disk 20 GB × 3600 = 72,000 GB-s × $0.00000007 = $0.005 — **≈ $0.40/hour**, so ≈$9.63 for 24 hours. The 375 vCPU-minutes/month included allotment is 6.25 vCPU-hours; for CI it is rounding error.

The vCPU concurrency cap of 1,500 means **at most 375 standard-4 instances** (1,500 ÷ 4) run concurrently across the whole account. That is the ceiling on fleet parallelism, and it is the number to design against.

Things that do not work (all VERIFIED):

- **No inbound TCP or UDP.** https://developers.cloudflare.com/containers/concepts/architecture/ — *"Because all Container requests are passed through a Worker, end-users cannot make non-HTTP TCP or UDP requests to a Container instance."* SSH exists only as `wrangler containers ssh`, which "does not expose a publicly accessible port on the Container" (https://developers.cloudflare.com/containers/guides/ssh/).
- **No persistent disk.** https://developers.cloudflare.com/containers/faq/ — *"All disk is ephemeral by default. When a Container instance goes to sleep, the next time it starts, it uses a fresh disk from the container image."* Snapshots are the only point-in-time mechanism, max 20 GB, **retained 30 days**, and are "in public beta". FUSE-mounted R2 is the alternative, but the docs warn "you should not expect native SSD-like performance while using FUSE."
- **No fixed maximum runtime, but no guarantee either.** FAQ: *"Cloudflare does not stop a container instance after a fixed maximum runtime"* — but also *"Cloudflare does not guarantee that any container instance will run for a set period"*, and a host restart sends SIGTERM, waits up to 15 minutes, then SIGKILL.
- **No autoscaling for stateless apps.** FAQ: *"Not today, though Cloudflare plans to add built-in autoscaling in a future release."*
- **No GPU** on the public product. The instance-type table lists no GPU option and no containers page mentions one. (BELIEVED — absence of evidence in the docs I fetched. The 2024 blog "Our container platform is in production. It has GPUs" describes Cloudflare's *internal* platform used for Workers AI, not the customer-facing Containers product.)
- **No iptables.** FAQ: *"Cloudflare Containers do not support iptables manipulation."* Docker-in-Docker works only with `--iptables=false --ip6tables=false --ip-forward=false` and `--network=host`.
- **No swap.** FAQ: *"Containers do not use swap memory."* OOM restarts the instance.

### Sandbox SDK — Containers with a friendlier API, same ceiling

Two generations exist. The current one is `@cloudflare/sandbox` **1.0.3**, released **2026-10-22** (VERIFIED, https://forge.web.pkgforge.dev/github/repos/cloudflare/sandbox-sdk/releases); repo `cloudflare/sandbox-sdk`, 1,156 stars, Apache-2.0 per the LICENSE file (GitHub's API reports the SPDX id as `NOASSERTION`, but the license body is Apache 2.0). The docs still carry a 0.x tree at `/sandbox/sdk/` for existing apps.

A sandbox is a Durable Object plus the Container it starts. The SDK adds `Files`, `S3Mount` (credentials stay in the Worker) and `DirectoryBackup` (directory → R2, restorable into a container on a newer image). Pricing is exactly Containers pricing — no separate meter (VERIFIED, https://developers.cloudflare.com/sandbox/sdk/platform/pricing/).

**The killer constraint**, VERIFIED at https://developers.cloudflare.com/sandbox/concepts/lifetime/: *"Code that runs inside the instance does not count as activity. If no requests arrive, the instance stops when the inactivity timeout ends, even while a build, a test suite, or an agent task still runs inside it."* The documented workaround is a Durable Object alarm that fires more often than the timeout and "checks the work". The timeout itself is capped: `setInactivityTimeout()` must be "greater than 0 and at most 6 hours (21600000)" (https://developers.cloudflare.com/containers/api/durable-object-container/). And *"The timeout does not survive a restart"* — a DO restart (deploy, alarm boundary) drops it.

Also: *"Cloudflare does not wake the Durable Object when its instance stops"*, so a stopped sandbox is not resumable without an external trigger.

### Queues — usable for dispatch, not for payloads

VERIFIED, https://developers.cloudflare.com/queues/platform/pricing/ and .../limits/: 1M operations/month included + $0.40/M on Paid (10,000/day Free); an operation is per 64 KB per message per write/read/delete, so a normal message costs 3 operations. Retention 4 days default, configurable to 14 (Free is fixed at 24 hours). Limits: 10,000 queues/account; **128 KB max message**; 100 retries; batch ≤ 100 messages / 256 KB; **5,000 messages/second per queue**; 25 GB backlog per queue; **250 concurrent consumer invocations**; **15-minute consumer wall-clock duration**; 5-minute max consumer CPU.

The 15-minute consumer duration and 250 concurrency are the relevant numbers for a job dispatcher: long jobs must be *dispatched*, not *executed*, in a consumer.

### D1 — a control-plane DB, not a data warehouse

VERIFIED, https://developers.cloudflare.com/d1/platform/pricing/ and .../limits/: Paid includes 25 billion rows read/month + $0.001/M, 50 million rows written/month + $1.00/M, 5 GB storage + $0.75/GB-month. **Maximum database size 10 GB** (Paid; 500 MB Free); 1 TB storage/account; 50,000 databases/account; 30 s max query duration; 100 KB max SQL statement; 2 MB max row; 30 days Time Travel.

The 10 GB per-database cap is the binding constraint for anything that stores per-job logs or per-machine telemetry.

### Cloudflare Tunnel — free, and the right machine on-ramp

VERIFIED, https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/: *"Every account includes 1,000 tunnels at no cost."* Beyond that, *"Tunnels for Platforms costs $4.50 per additional tunnel per month."* Note: *"Every tunnel that exists in your account counts toward your limit. This includes tunnels that are inactive or have no connected `cloudflared` replicas."* — an orchestrator that creates a tunnel per job and forgets to delete it will silently consume the quota.

Limits (VERIFIED, https://developers.cloudflare.com/cloudflare-one/account-limits/): 1,000 `cloudflared` tunnels per account; **50,000 routes (CIDR + hostname) per account, shared with Cloudflare Mesh**; 25 active `cloudflared` replicas per tunnel; published applications per tunnel bounded by the 1 MB config size; 1,000 virtual networks per account.

Tunnel is outbound-only: `cloudflared` dials out, no inbound listener, no public IP. This is exactly the shape wanted for reaching machines behind NAT. It carries HTTP, SSH, RDP and arbitrary TCP.

### Cloudflare Mesh — 50 nodes per account is a hard stop

VERIFIED, https://developers.cloudflare.com/cloudflare-one/account-limits/: **"Mesh nodes per account | 50"**. Routes are shared with Tunnel (50,000). Mesh gives every participant a private IP in `100.96.0.0/12` and L3/L4 connectivity over TCP, UDP or ICMP, with long-lived connection preservation — the right tool for database replication or RDP. Mesh nodes are Linux servers running the Cloudflare One Client (`warp-cli`) headless; WireGuard-mode device profiles lose capabilities, MASQUE is required.

The 50-node cap is decisive. If the design is "one Mesh node per managed machine", it works for a lab and fails at 51 machines. Tunnel's 1,000 (extendable at $4.50 each) is the only path to fleet scale on Cloudflare.

### Zero Trust Access — free to 50 users, then per-seat

VERIFIED from the pricing JSON embedded in https://www.cloudflare.com/plans/ (the rendered page is client-side; the payload reads: Free tier description *"Teams under 50 users or enterprise proof-of-concept tests."*, price `$0`, `billing: "forever"`; Pay-as-you-go price `$7`, billing `"/user/month"`, description *"Teams over 50 solving narrow SSE use cases without enterprise support."*; feature row `"User Limit"` → free `"50 users"`, paygo `"No limit"`).

Access is deny-by-default with Allow/Block/Bypass/Service Auth actions and Include/Require/Exclude rule types (VERIFIED, https://developers.cloudflare.com/cloudflare-one/policies/access/). For machine-to-machine, **service tokens** are the mechanism: a Client ID + Client Secret pair, secret shown once, sent as request headers (VERIFIED, https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/). Limits: **50 service tokens per account**, 50 identity providers, 500 applications, 50 custom applications (Free/Paygo) (VERIFIED, account-limits page).

Warning from the docs worth repeating: Bypass "does not enforce any Access security controls and requests are not logged."

For a dashboard hosted on Workers that must reach machines, Access service tokens + Tunnel is the natural auth story — but 50 service tokens per account is a low ceiling if you mint one per machine. Use one token per orchestrator role, not per machine.

### Workers VPC — the bridge from the dashboard to private machines

VERIFIED, https://developers.cloudflare.com/workers-vpc/: "Available on Free and Paid plans". **VPC Services** bind a Worker to a specific host:port reachable through a Tunnel (HTTP, plus TCP via Hyperdrive). **VPC Networks** bind to an entire Tunnel, a **Mesh network**, or a Cloudflare WAN on-ramp without pre-registering hosts, and support HTTP via `fetch()` and raw TCP via `connect()` "for non-HTTP services like Redis, MQTT, and custom protocols."

This is the piece that makes the architecture coherent: dashboard on Workers → Workers VPC binding → Tunnel/Mesh → machine. No public ingress, no VPN client on the user's laptop.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| Cloudflare R2 | https://developers.cloudflare.com/r2/ | proprietary service | docs updated 2026-10-26 | $0.015/GB-mo, free egress, 5 TiB objects, S3 API | Partial S3: no ACLs, bucket policies, object lock, versioning, replication, notifications. Billable-unit rounding. `r2.dev` not for prod |
| Cloudflare Workers (Paid) | https://developers.cloudflare.com/workers/ | proprietary service | docs 2026-10-02 | $5/mo, 10M req, 30M CPU-ms, global anycast, zero egress | 128 MB memory, 5 min CPU max, 64 MiB bundle, 6 concurrent outbound conns — dashboard/API only |
| Workers Builds | https://developers.cloudflare.com/workers/ci-cd/builds/ | proprietary service | docs 2026-10-28 | 6,000 build-min/mo, 4 vCPU/8 GB, $0.005/min overage | **20-minute hard timeout**, 6 concurrent, fixed build image, no Docker daemon — not real CI |
| Cloudflare Containers | https://developers.cloudflare.com/containers/ | proprietary service | GA 2026-04-13; docs 2026-10-21 | microVM per instance, custom images, Docker Hub, SSH via wrangler | Max 4 vCPU/12 GiB/20 GB disk; 50 GB image storage/account; 1,500 concurrent vCPU; no inbound TCP/UDP; ephemeral disk; no autoscaling |
| Sandbox SDK | https://github.com/cloudflare/sandbox-sdk | Apache-2.0 (LICENSE body; GitHub API reports NOASSERTION) | `@cloudflare/sandbox@1.0.3`, 2026-10-22; repo pushed 2026-10-29; 1,156 stars | Files / S3Mount / DirectoryBackup over Containers; ergonomic DO wrapper | Inherits every Containers limit **plus**: instance stops mid-task if the DO goes inactive; timeout ≤ 6 h and does not survive DO restart |
| Cloudflare Queues | https://developers.cloudflare.com/queues/ | proprietary service | docs 2026-04-21 | $0.40/M ops, 5,000 msg/s per queue, 14-day retention, DLQ | 128 KB message cap; 250 concurrent consumers; 15 min consumer wall clock |
| Cloudflare D1 | https://developers.cloudflare.com/d1/ | proprietary service | docs 2026-10-24 (limits) | SQLite, scale-to-zero, 30-day Time Travel | **10 GB max per database**, 1 TB/account, 30 s query cap |
| Cloudflare Durable Objects | https://developers.cloudflare.com/durable-objects/ | proprietary service | docs 2026-10-18 | Per-key serializable single-threaded actors, alarms, WebSocket hibernation, SQLite | 10 GB per DO, 128 MB memory, billed 128 MB flat, $1.00/M rows written |
| Cloudflare Tunnel | https://developers.cloudflare.com/tunnel/ | proprietary service (client `cloudflared` is Apache-2.0 — BELIEVED) | docs 2026-10-16 (Tunnels for Platforms) | Free, 1,000 tunnels/account, outbound-only, HTTP/SSH/RDP/TCP | 25 replicas/tunnel; 50,000 routes shared with Mesh; unused tunnels still consume quota |
| Cloudflare Mesh | https://developers.cloudflare.com/mesh/ | proprietary service | docs 2026-09-16 | L3/L4 private IP mesh, TCP/UDP/ICMP, long-lived connections | **50 nodes per account** — blocks one-node-per-machine fleets |
| Zero Trust Access | https://developers.cloudflare.com/cloudflare-one/ | proprietary service | docs 2026-10-01 (policies) | IdP-backed SSO, service tokens, deny-by-default, per-app policies | 50 users free then $7/user/mo; 50 service tokens/account; Bypass is unlogged and unenforced |
| Workers VPC | https://developers.cloudflare.com/workers-vpc/ | proprietary service | docs 2026-10-12 | Worker → Tunnel/Mesh/WAN bindings, HTTP + raw TCP | Ties the dashboard's reachability to Cloudflare's own control plane |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| R2 Standard storage | $0.015 / GB-month | https://developers.cloudflare.com/r2/pricing/ | `| Storage | $0.015 / GB-month | $0.01 / GB-month |` |
| R2 Class A ops | $4.50 / million | https://developers.cloudflare.com/r2/pricing/ | `| Class A Operations | $4.50 / million requests | $9.00 / million requests |` |
| R2 Class B ops | $0.36 / million | https://developers.cloudflare.com/r2/pricing/ | `| Class B Operations | $0.36 / million requests | $0.90 / million requests |` |
| R2 egress | free | https://developers.cloudflare.com/r2/pricing/ | "Egressing directly from R2, including via the Workers API, S3 API, and `r2.dev` domains does not incur data transfer (egress) charges and is free." |
| R2 free tier | 10 GB-mo, 1M Class A, 10M Class B | https://developers.cloudflare.com/r2/pricing/ | "The free tier only applies to Standard storage, and does not apply to Infrequent Access storage." |
| R2 max object size | 5 TiB | https://developers.cloudflare.com/r2/platform/limits/ | "The object size limit is 5 GiB less than 5 TiB, so 4.995 TiB." |
| R2 billing rounding | round up to next unit | https://developers.cloudflare.com/r2/pricing/ | "If you have used 1.1 GB-month, you will be billed for 2 GB-month." |
| R2 REST API rate limit | 1,200 req / 5 min | https://developers.cloudflare.com/r2/platform/limits/ | "is rate limited to 1,200 requests per five minutes across all R2 REST API operations on your account" |
| Workers Paid minimum | $5 USD / month | https://developers.cloudflare.com/workers/platform/pricing/ | "for a minimum charge of $5 USD per month for an account" |
| Workers included requests | 10M/mo, +$0.30/M | https://developers.cloudflare.com/workers/platform/pricing/ | "10 million included per month <br> +$0.30 per additional million" |
| Workers included CPU | 30M CPU-ms, +$0.02/M | https://developers.cloudflare.com/workers/platform/pricing/ | "30 million CPU milliseconds included per month<br> +$0.02 per additional million CPU milliseconds" |
| Workers memory | 128 MB per isolate (both plans) | https://developers.cloudflare.com/workers/platform/limits/ | `| Memory | 128 MB | 128 MB |` |
| Workers CPU max (Paid) | 5 min (default 30 s) | https://developers.cloudflare.com/workers/platform/limits/ | "CPU time per HTTP request | 10 ms | 5 min (default: 30 seconds)" |
| Workers subrequests (Paid) | 10,000 per invocation | https://developers.cloudflare.com/workers/platform/limits/ | `| Subrequests per invocation | 50 | 10,000 (up to 10M) |` |
| Workers concurrent outbound conns | 6 | https://developers.cloudflare.com/workers/platform/limits/ | "Each Worker invocation can have up to six connections simultaneously waiting for response headers." |
| Workers Builds minutes | 6,000/mo then $0.005/min (Paid) | https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/ | `| **Build minutes** | 3,000 per month | 6,000 per month (then, +$0.005 per minute) |` |
| Workers Builds timeout | 20 minutes (both plans) | https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/ | `| **Build timeout** | 20 minutes | 20 minutes |` |
| Workers Builds concurrency | 1 Free / 6 Paid | https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/ | `| **Concurrent builds** | 1 | 6 |` |
| DO requests (Paid) | 1M/mo + $0.15/M | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "1 million / month, + $0.15/million" |
| DO duration (Paid) | 400,000 GB-s/mo + $12.50/M GB-s | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "400,000 GB-s / month, + $12.50/million GB-s" |
| DO memory billing | flat 128 MB | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "Duration billing charges for the 128 MB of memory your Durable Object is allocated, regardless of actual usage." |
| DO rows written (SQLite) | 50M/mo + $1.00/M | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "First 50 million / month included + $1.00 / million rows" |
| DO storage per object | 10 GB | https://developers.cloudflare.com/durable-objects/platform/limits/ | `| Storage per Durable Object | 10 GB |` |
| Containers memory | 25 GiB-h/mo + $0.0000025/GiB-s | https://developers.cloudflare.com/containers/platform/pricing/ | "25 GiB-hours/month included <br> +$0.0000025 per additional GiB-second" |
| Containers CPU | 375 vCPU-min/mo + $0.000020/vCPU-s | https://developers.cloudflare.com/containers/platform/pricing/ | "375 vCPU-minutes/month <br>+ $0.000020 per additional vCPU-second" |
| Containers disk | 200 GB-h/mo + $0.00000007/GB-s | https://developers.cloudflare.com/containers/platform/pricing/ | "200 GB-hours/month <br> +$0.00000007 per additional GB-second" |
| Containers max instance | 4 vCPU / 12 GiB / 20 GB | https://developers.cloudflare.com/containers/platform/limits/ | `| standard-4 | 4 | 12 GiB | 20 GB |` |
| Containers image storage per account | 50 GB | https://developers.cloudflare.com/containers/platform/limits/ | `| Total image storage per account | 50 GB |` |
| Containers account concurrency | 1,500 vCPU / 6 TiB / 30 TB | https://developers.cloudflare.com/containers/platform/limits/ | `| Concurrent vCPU | 1,500 |` |
| Containers egress NA/EU | $0.025/GB, 1 TB included | https://developers.cloudflare.com/containers/platform/pricing/ | `| North America & Europe | $0.025 | 1 TB |` |
| Containers no inbound TCP/UDP | not supported | https://developers.cloudflare.com/containers/concepts/architecture/ | "Because all Container requests are passed through a Worker, end-users cannot make non-HTTP TCP or UDP requests to a Container instance." |
| Containers disk ephemeral | yes | https://developers.cloudflare.com/containers/faq/ | "All disk is ephemeral by default. When a Container instance goes to sleep, the next time it starts, it uses a fresh disk from the container image." |
| Containers no autoscaling | not available | https://developers.cloudflare.com/containers/faq/ | "Not today, though Cloudflare plans to add built-in autoscaling in a future release." |
| Containers no iptables | not supported | https://developers.cloudflare.com/containers/faq/ | "Cloudflare Containers do not support iptables manipulation." |
| Containers no swap | confirmed | https://developers.cloudflare.com/containers/faq/ | "Containers do not use swap memory." |
| Container snapshot cap | 20 GB, 30-day TTL | https://developers.cloudflare.com/containers/platform/limits/ | `| Maximum snapshot size | 20 GB |` / `| Snapshot retention | 30 days from creation or the most recent restore |` |
| Sandbox inactivity timeout cap | 6 hours | https://developers.cloudflare.com/containers/api/durable-object-container/ | "The value must be greater than `0` and at most 6 hours ( `21600000`)." |
| Sandbox stops mid-work | confirmed | https://developers.cloudflare.com/sandbox/concepts/lifetime/ | "Code that runs inside the instance does not count as activity. If no requests arrive, the instance stops when the inactivity timeout ends, even while a build, a test suite, or an agent task still runs inside it." |
| Sandbox SDK version | 1.0.3, 2026-10-22 | https://forge.web.pkgforge.dev/github/repos/cloudflare/sandbox-sdk/releases | `@cloudflare/sandbox@1.0.3 2026-10-22T15:46:14Z` |
| Sandbox SDK stars | 1,156 | https://forge.web.pkgforge.dev/github/repos/cloudflare/sandbox-sdk | `"stargazers_count": 1156` |
| Containers + Sandbox GA date | 2026-04-13 | https://developers.cloudflare.com/changelog/post/2026-04-13-containers-sandbox-ga/ | "Cloudflare Containers and Sandboxes are now generally available." |
| Queues ops (Paid) | 1M/mo + $0.40/M | https://developers.cloudflare.com/queues/platform/pricing/ | "1,000,000 operations/month included + $0.40/million operations" |
| Queues message size | 128 KB | https://developers.cloudflare.com/queues/platform/limits/ | `| Message size | 128 KB |` |
| Queues throughput | 5,000 msg/s per queue | https://developers.cloudflare.com/queues/platform/limits/ | `| Per-queue message throughput | 5,000 messages per second |` |
| Queues consumer duration | 15 minutes | https://developers.cloudflare.com/queues/platform/limits/ | `| Consumer duration (wall clock time) | 15 minutes |` |
| Queues concurrent consumers | 250 | https://developers.cloudflare.com/queues/platform/limits/ | `| Concurrent consumer invocations | 250 |` |
| D1 max database size | 10 GB (Paid) | https://developers.cloudflare.com/d1/platform/limits/ | `| Maximum database size | 10 GB (Workers Paid) / 500 MB (Free) |` |
| D1 storage price | $0.75/GB-mo | https://developers.cloudflare.com/d1/platform/pricing/ | "First 5 GB included + $0.75 / GB-mo" |
| D1 rows written | 50M/mo + $1.00/M | https://developers.cloudflare.com/d1/platform/pricing/ | "First 50 million / month included + $1.00 / million rows" |
| Tunnel free allotment | 1,000 per account | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ | "Every account includes 1,000 tunnels at no cost." |
| Tunnel overage price | $4.50 / tunnel / month | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ | "Tunnels for Platforms costs $4.50 per additional tunnel per month." |
| Tunnel quota counts idle tunnels | yes | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ | "Every tunnel that exists in your account counts toward your limit. This includes tunnels that are inactive or have no connected `cloudflared` replicas." |
| Tunnel replicas per tunnel | 25 | https://developers.cloudflare.com/cloudflare-one/account-limits/ | `| Active `cloudflared` replicas per tunnel | 25 |` |
| Routes per account (Tunnel+Mesh) | 50,000 shared | https://developers.cloudflare.com/cloudflare-one/account-limits/ | `| Routes (CIDR routes + Hostname routes) per account | 50,000 (shared with Cloudflare Tunnel) |` |
| Mesh nodes per account | 50 | https://developers.cloudflare.com/cloudflare-one/account-limits/ | `| Mesh nodes per account | 50 |` |
| Zero Trust Free | $0, 50 users | https://www.cloudflare.com/plans/ | rendered text: "Teams under 50 users or enterprise proof-of-concept tests." and, in the `User Limit` feature row, "50 users" |
| Zero Trust Pay-as-you-go | $7 /user/month | https://www.cloudflare.com/plans/ | rendered text: "$7" followed by "/user/month"; description "Teams over 50 solving narrow SSE use cases without enterprise support."; `User Limit` row "No limit" |
| Access service tokens per account | 50 | https://developers.cloudflare.com/cloudflare-one/account-limits/ | `| Service tokens | 50 |` |
| Workers VPC availability | Free and Paid | https://developers.cloudflare.com/workers-vpc/ | "Available on Free and Paid plans" |

## Rejected options

| option | why rejected |
|---|---|
| Cloudflare Containers as the primary CI executor | Max 4 vCPU / 12 GiB / 20 GB disk per instance, 1,500 concurrent vCPU per account, no persistent disk, no inbound TCP/UDP, no autoscaling, 50 GB total image storage per account. Cannot host a real build fleet. |
| Sandbox SDK as a long-job runner | Instance stops mid-build when its Durable Object goes inactive ("Code that runs inside the instance does not count as activity"), timeout capped at 6 h, and the timeout does not survive a DO restart. Needs an external heartbeat/alarm hack to survive even a 20-minute test suite. |
| Workers Builds as the CI system | 20-minute hard build timeout, 6 concurrent builds, fixed build image with no Docker daemon. Fine for `wrangler deploy`, nothing else. |
| Workers (plain) as the orchestration compute | 128 MB memory and 5 min CPU per invocation, 6 simultaneous outbound connections. Cannot hold fleet state or fan out health checks. |
| Durable Objects as the job/state database | 10 GB per object, 128 MB memory, and $1.00 per million rows written — heartbeat-heavy schemas get expensive fast. Use as a lock/lease primitive, not as the system of record. |
| D1 as the job-history store | 10 GB per database cap; 30 s query cap. Will not hold per-job logs or telemetry. |
| Queues as the job execution path | 15-minute consumer wall clock and 250 concurrent consumers. Dispatch only. |
| Cloudflare Mesh as the per-machine network fabric | 50 nodes per account. Cannot express "one node per managed machine" beyond a lab. |
| R2 for anything needing S3 ACLs / bucket policy / object lock / versioning / replication | Those S3 operations are explicitly unimplemented in R2's S3 API. |
| `r2.dev` public buckets for production artifact serving | Docs: "not intended for production usage", variable rate limit, 429s. Requires a custom domain. |
| Zero Trust Access Bypass policies for machine traffic | Bypass "does not enforce any Access security controls and requests are not logged." Use service tokens. |

## Open questions

- **Is `cloudflared` itself Apache-2.0?** BELIEVED, not verified in this lane. Settle with `curl https://forge.web.pkgforge.dev/github/repos/cloudflare/cloudflared/license`.
- **Does the public Containers product expose GPUs?** The docs list no GPU instance type and never mention GPU, but the 2024 blog says the internal platform has them. Settle by asking Cloudflare support / checking the Containers changelog for a GPU instance type, or by attempting `instance_type` values outside the documented six.
- **What is the real-world cold-start distribution for a large CI image?** Docs say "often in the 1-3 second range, but this is dependent on image size". No benchmark for a multi-GB image. Settle by measuring `ctx.container.start()` → port-ready on a realistic 3-5 GB image across regions.
- **How fast is image distribution on deploy?** Docs say Cloudflare "distributes that image across its network and prepares capacity for new instances" but give no timing. Settle by deploying a 5 GB image and timing first-start per region.
- **Does the 50 GB image-storage limit include every tagged version, or only the deployed one?** The footnote only says to delete images with `wrangler containers delete` to free space. Settle by pushing 12 tagged variants of a 5 GB image and observing when uploads fail.
- **What is the actual enforced concurrency when 1,500 vCPU is requested?** Whether that is a soft (support-raisable) or hard ceiling is unclear — the limits page says "All instance size maximums and account limits on this page are defaults and can be increased." Settle by asking support for a quota increase and recording what they grant.
- **Do Durable Object alarms reliably keep a Container alive for multi-hour jobs?** The docs propose this workaround but give no guarantee that the alarm cadence survives DO eviction. Settle with a 6-hour soak test: one alarm per minute plus a long-running process, measuring whether the instance survives.
- **Is Mesh's 50-node limit raisable?** Not stated on the limits page (which says limits "may be increased on Enterprise accounts"). Settle by asking an account team for the Enterprise Mesh node cap.
- **Does the Workers Paid $5 minimum stack with Containers, or is Containers metered on top?** Docs say Containers usage is "with included monthly usage as part of the $5 USD per month Workers Paid plan", so it is on top with an allotment, but the interaction with an account already paying $5 for Workers is untested here. Settle with a one-month bill for a known workload.
- **Zero Trust per-seat pricing for machine identities.** Service tokens appear not to consume seats, but this is not stated. Settle by creating 60 service tokens on a 50-user Free org and observing whether the account is prompted to upgrade.
