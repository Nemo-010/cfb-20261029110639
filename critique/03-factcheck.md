# Fact-check: cfb — an offload architecture for Cloudflare-shaped workloads

Checked 2026-10-29 against primary sources (Cloudflare docs, vendor repos, GitHub REST).
Every "VERIFIED" row below is something I fetched and read myself. "BELIEVED" means I could
not reach the primary source and am relying on secondary evidence. Nothing is asserted from
memory.

---

## Verdict

The Cloudflare half of this document is unusually well sourced and almost entirely correct:
I went in expecting to catch the usual set of stale Cloudflare numbers and caught only one
(the 3 MiB free-tier Worker size). The cost document, which carries the headline
"self-hosting only wins above ~40% duty", is arithmetically broken — its dominant line item
mixes dollars-per-year into a dollars-per-month sum, and the break-even is really ~22%, not
39%. The storage chapter's recommendation survives, but two of the three justifications for
replacing R2 are false (R2 has object lock) and the SeaweedFS port/firewall table would
break a cluster if followed. Salvageable: the architecture is sound, but docs/09 and
docs/05 need rework before anyone budgets from them.

---

## Findings

### Claim ledger — everything I re-verified

| Claim | Where | Verified? | Actual value | Source |
|---|---|---|---|---|
| R2 Standard $0.015/GB-mo, IA $0.01 | 00:20-21 | YES | identical | https://developers.cloudflare.com/r2/pricing/ |
| R2 Class A $4.50/M (IA $9.00), Class B $0.36/M (IA $0.90) | 00:22-23 | YES | identical | same |
| R2 egress free; free tier 10 GB-mo / 1M A / 10M B | 00:24-26 | YES | identical | same |
| "1.1 GB-month → billed 2 GB-month" | 00:38 | YES | verbatim | same |
| R2 object 5 TiB (4.995 TiB), 1,000,000 buckets/account | 00:30 | YES | identical | https://developers.cloudflare.com/r2/platform/limits/ |
| R2 unimplemented: PutBucketPolicy/Acl/Versioning/ObjectLockConfiguration/Replication/Logging/NotificationConfiguration/Website | 00:44-49 | YES | all eight marked ❌ | https://developers.cloudflare.com/r2/api/s3/api/ |
| R2 durability "eleven nines" | 05:159 | YES | 99.999999999% | https://developers.cloudflare.com/r2/reference/durability/ |
| Containers standard-4 = 4 vCPU / 12 GiB / 20 GB | 00:62 | YES | identical | https://developers.cloudflare.com/containers/platform/limits/ |
| Memory:vCPU floor 3 GiB/vCPU | 00:63 | YES | identical | same |
| Account: 6 TiB mem / 1,500 vCPU / 30 TB disk | 00:64 | YES | identical | same |
| Image storage 50 GB/account | 00:65 | YES | identical | same |
| Containers $0.000020/vCPU-s, $0.0000025/GiB-s, $0.00000007/GB-s | 00:66-68 | YES | identical | https://developers.cloudflare.com/containers/platform/pricing/ |
| Sandbox: "Code that runs inside the instance does not count as activity" | 00:75-78 | YES | verbatim | https://developers.cloudflare.com/sandbox/concepts/lifetime/ |
| Inactivity timeout capped at 6 h | 00:80 | YES | "up to 6 hours" | same |
| Snapshot = root fs only, expires 30 days | 00:84-85 | YES | identical | same |
| Workers 10 ms / 5 min CPU; 128 MB; 50/10,000 subrequests; 6 connections; $5/mo | 00:95-101 | YES | identical | https://developers.cloudflare.com/workers/platform/limits/ |
| Workers Builds 3,000/6,000 min, $0.005/min, 1/6 concurrent, 20 min timeout, 2/4 vCPU, 8 GB, 20 GB | 00:107-116 | YES | identical | https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/ |
| DO: 1M req + $0.15/M; 400k GB-s + $12.50/M; 50M rows + $1.00/M; 5 GB-mo + $0.20 | 00:126-131 | YES | identical | https://developers.cloudflare.com/durable-objects/platform/pricing/ |
| DO flat 128 MB duration billing | 00:128, 07:141 | YES | verbatim footnote | same |
| Per-DO storage 10 GB paid / 1 GB free | 00:132 | YES | identical | https://developers.cloudflare.com/durable-objects/platform/limits/ |
| 1,000 tunnels/account; $4.50 per extra tunnel/mo | 00:138-139 | YES | identical | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ |
| 50,000 routes (shared with Mesh); 25 replicas/tunnel; Mesh 50 nodes | 00:140-142 | YES | identical | https://developers.cloudflare.com/cloudflare-one/account-limits/ |
| Workers VPC beta, free while beta | 00:151-153 | YES | verbatim | https://developers.cloudflare.com/workers-vpc/ |
| VPC requires QUIC + outbound UDP 7844; http2 breaks DNS resolution | 02:74-78, 10:57 | YES | "requires … QUIC … using `auto` or `quic`" | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ |
| `vpc_services` vs `vpc_networks` semantics | 00:154 | YES | correct | https://developers.cloudflare.com/workers-vpc/configuration/vpc-networks/ |
| Static Assets requests free and unlimited | 07:33 | YES | "free and unlimited" | https://developers.cloudflare.com/workers/platform/pricing/ |
| 125 s Proxy Read Timeout | 03:45, 02:74 | YES | "default 125 seconds" | https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/ |
| Tunnel TCP/SSH/RDP/SMB streamed over WebSocket; no UDP | 00:146, 02:20 | YES | "Streams TCP over a WebSocket connection" | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/protocols/ |
| Nomad BUSL-1.1, internal use granted, hosted-competitor not | 03:38-40 | YES | verbatim grant text | https://raw.githubusercontent.com/hashicorp/nomad/main/LICENSE |
| Nomad quotas are a no-op in CE (`nomad/plan_apply_ce.go`) | 03:41, README:157 | YES | `evaluatePlanQuota` returns `false, nil` | https://raw.githubusercontent.com/hashicorp/nomad/main/nomad/plan_apply_ce.go |
| Parameterized dispatch payload 16 KiB | 03:25 | YES | "maximum size of a payload is 16 KiB" | https://developer.hashicorp.com/nomad/docs/job-specification/parameterized |
| Incus Apache-2.0; 7.0 LTS to June 2031 | 03:57 | YES | identical | https://linuxcontainers.org/incus/news/2026_05_05_16_29.html |
| Firecracker boot <125 ms, <5 MiB overhead, "does not perform any network traffic filtering" | 04:30-34 | YES | verbatim (README uses `<125ms`) | https://firecracker-microvm.github.io/ ; https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/docs/design.md |
| E2B Embed Apache-2.0; single machine; "When one node is not enough" → private cloud/BYOC/Cloud | 04:80-90 | YES | verbatim | https://raw.githubusercontent.com/e2b-dev/runtime/main/embed/README.md |
| E2B port 5008 unauthenticated, creates/kills sandboxes | 04:95, 08:62 | YES | "**unauthenticated** gRPC control API" | https://raw.githubusercontent.com/e2b-dev/runtime/main/embed/docs/REFERENCE.md |
| E2B 13 host ports; 5010/5016/5017/5018 egress proxies | 04:95, 08:66 | YES | identical | same |
| E2B 12 GiB RAM / 20 GiB disk; 8 at full memory or ~20 idle; HUGEPAGES; "Failed to place sandbox: this node cannot map 512 MiB" | 04:97-102 | YES | verbatim | https://raw.githubusercontent.com/e2b-dev/runtime/main/embed/compose/README.md |
| E2B 7,922-line OpenAPI spec | 04:92 | YES | `spec/openapi.yml` = 7,922 lines | https://raw.githubusercontent.com/e2b-dev/runtime/main/spec/openapi.yml |
| E2B belt is private (404) | 04:88 | YES | 404 | https://forge.web.pkgforge.dev/github/repos/e2b-dev/belt |
| celld Apache-2.0, 6,169 stars, v0.6.3 | 06:6 | YES | 6,169; Apache-2.0; latest tag v0.6.3 | https://forge.web.pkgforge.dev/github/repos/denoland/celld |
| celld: 2 contributors, 14 commits at v0.6.3, PRs disabled | 06:126 | YES | ry:9 + bartlomieju:5 = 14; "Pull requests are disabled" | contributors API; https://raw.githubusercontent.com/denoland/celld/main/README.md |
| celld 419 crates | 06:126 | YES | 419 packages in Cargo.lock | https://raw.githubusercontent.com/denoland/celld/main/Cargo.lock |
| celld one app per fleet; plaintext peer HTTP; no TLS termination | 06:82-96 | YES | verbatim in limitations.md | https://raw.githubusercontent.com/denoland/celld/main/docs/limitations.md |
| celld `POST /reload`, `/state`, 30 s deploy poll | 06:112, 06:137 | YES | `CELLD_DEPLOY_POLL_S` default 30 | https://raw.githubusercontent.com/denoland/celld/main/docs/README.md |
| celld: "An external system starts and stops the nodes, and celld hands the cells off." | 06:144 | YES | verbatim | same |
| workerd cluster mode merged 2026-10-29, `--experimental`, alarms unsupported, in no release | 06:22-32 | YES | commit aa494794, 03:11Z; release v1.20261029.1 tagged 00:53Z | https://forge.web.pkgforge.dev/github/repos/cloudflare/workerd/commits/aa494794 |
| SeaweedFS S3 auth off by default | 05:105, 08:44 | YES | `isAuthEnabled = identityCount > 0 \|\| startConfigFile != ""` | https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/weed/s3api/auth_credentials.go |
| SeaweedFS EC 10+4 hardcoded in OSS | 05:108 | YES | `DataShardsCount = 10`, `ParityShardsCount = 4` | https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/weed/storage/erasure_coding/ec_encoder.go |
| SeaweedFS ports 9333 / 8080 / 8888 / 8333 | 05:90-93 | YES | identical defaults | weed/command/{master,volume,filer}.go |
| SeaweedFS does implement If-Match / If-None-Match with 412 | 05:45 | YES | `validateConditionalHeaders`, `ErrPreconditionFailed` | https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/weed/s3api/s3api_object_handlers_put.go |
| Garage "structurally impossible … lack of a consensus algorithm" | 05:76-78 | YES | verbatim | https://garagehq.deuxfleurs.fr/documentation/reference-manual/known-issues/ |
| MinIO archived; AIStor Free "standalone mode (single-node deployments without distributed clustering…)" | 05:146-150 | YES | verbatim | https://forge.web.pkgforge.dev/github/repos/minio/minio ; https://www.min.io/legal/aistor-free-agreement |
| RustFS 1.0 shipped 2026-09-16 | 05:137 | YES | 1.0.0 published 2026-09-16 | https://forge.web.pkgforge.dev/github/repos/rustfs/rustfs/releases |
| AWS Fargate $0.000011244/vCPU-s, $0.000001235/GB-s; Cloudflare 1.8× / 2.0× | 09:159-160 | YES | ratios compute to 1.78× and 2.02× | https://aws.amazon.com/fargate/pricing/ |
| Cost arithmetic: $292.76 container-month, 21.33 containers/node, $114.50/container-month, 2.6× at 100% duty, 5.6% power+transit, 48/35/4.5/3.6/2.0/6.9 shares | 09:20-60 | YES | all reproduce | own arithmetic |
| microsandbox ~484,726 lines | 04:109 | BELIEVED | 17.5 MB of Rust ≈ 485k lines | https://forge.web.pkgforge.dev/github/repos/superradcompany/microsandbox/languages |
| SeaweedFS ~978k lines Go, ~20 commits/day | 05:107 | BELIEVED | 29.6 MB Go ≈ 990k lines; 1,280 commits in 90 days ≈ 14/day | languages API; commits API |
| workerd ~434k lines C++/Rust | 06:14 | BELIEVED | 12.8 MB C++ ≈ 430k lines (+4.1 MB Rust) | https://forge.web.pkgforge.dev/github/repos/cloudflare/workerd/languages |
| celld 63 MiB binary | 06:126 | BELIEVED | gz artifact 25,157,496 B ⇒ ~62 MiB uncompressed | releases API |
| cloudflared self-updates every 24 h from update.argotunnel.com | 08:135 | BELIEVED | `DefaultCheckUpdateFreq` is 24 h; current docs no longer state it | cloudflared `updater` package |

### Claims I could NOT verify

- **celld "176 environment variables"** (06:126). The docs table lists 51 rows / 57 unique
  `CELLD_*` names and says the full list is only in `celld -h`. I could not run the binary.
  The number may be right but is uncheckable from the published docs.
- **E2B "ships a Next.js 16 SSR app"** (04:90). The dashboard is a separate, private-ish
  release (`e2b-dev/dashboard`, image `dashboard:v0.4.0`). No public manifest confirms Next 16.
- **E2B "`s3://` storage seam with `endpoint=` and `s3ForcePathStyle=true`"** (04:91). I found
  no such option in `embed/compose/compose.yaml` or `embed/docs/REFERENCE.md`; the compose
  file sets `TEMPLATE_STORAGE_URL: file:///var/lib/e2b/storage/templates`. The option may
  exist in the non-Embed path, but the claim as written does not describe Embed.
- **"SeaweedFS is 54% one person"** (README:159). `chrislusf` has 10,801 commits out of ~399
  contributors, but I did not obtain the total commit count, so 54% is unconfirmed (it is
  plausible).
- **"headscale is effectively one maintainer"** (README:159). Believed, not measured.
- **RustFS "`If-Match: <etag>` returns 501 NotImplemented (`app/object/shared.rs`)"** (05:132).
  The cited path returns 404 — `app/` no longer exists in the repo root. The *behaviour* may
  be right, but the citation is dead, so the tier-2 hedge rests on an unverifiable claim.
- **"There is no stream resumption. A QUIC idle timeout kills every in-flight socket"** and
  the heading **"The five-second problem"** (02:88-91). Nothing in the Workers VPC docs,
  reference, or troubleshooting page documents a 5-second (or any) idle timeout or the
  absence of stream resumption. The troubleshooting page lists 18 error codes; none is an
  idle timeout. I believe this number is invented.
- **"~100 contributors" for workerd** (06:14). This one is *verifiably wrong*: 236
  (non-anonymous) or 247 (with anonymous) — see below.
- **RustFS "P1 bugs … scanner OOM … silent-data-corruption fix in `Unreleased`"** (05:139-141).
  Not checked; no URL given in the document.

### Claims that are WRONG

- **09:37 labour arithmetic** — unit error, see BLOCKER 1.
- **00:73 / 09:77-82 "Containers cannot run this at any price; inactivity ceiling 6 hours"** — see MAJOR 2.
- **00:49 / 00:53 / 05:165 "R2 does not implement object lock"** — see MAJOR 3.
- **02:61 `"network_id": "<mesh-or-tunnel-id>"`** — see MAJOR 4.
- **05:94 "replication | 19333"** — see MAJOR 5.
- **05:110 "silently at 3× replication cost"** — see MAJOR 6.
- **00:100 "Worker size | 3 MiB | 64 MiB"** — Workers Free is 64 MiB uncompressed, same as
  Paid. https://developers.cloudflare.com/workers/platform/limits/ ("Worker size (uncompressed) | 64 MiB | 64 MiB").
- **03:40 "The last MPL release was v1.6.3"** — v1.6.4 through **v1.6.10** exist and predate
  the BUSL cut-over, which the LICENSE scopes to "Nomad Version 1.7.0 or later". Anyone who
  pins 1.6.3 for licence reasons is choosing to miss seven patch releases of security fixes.
  https://forge.web.pkgforge.dev/github/repos/hashicorp/nomad/tags
- **09:142 "36 months raises owned cost ~22%"** — by the document's own numbers, hardware
  amortisation goes $844 → $1,126, i.e. +$282 on a $2,443 node-month = **+11.5%**. 22% is
  not derivable.
- **09:144 "Nodes per ops person | 54.6 | halve it and owned cost per unit doubles"** — labour
  is 48% of node-month, so doubling it gives 1.48×, not 2×. The sensitivity statement is
  only true if labour were ~100% of cost.
- **09:101 "a container pushing 10 TB/month out of Cloudflare costs $250 in egress alone"** —
  Containers egress includes 1 TB/month in NA/EU, so 9 TB billable = **$225**.
  https://developers.cloudflare.com/containers/platform/pricing/
- **01:15 "celld … 9876 (worker)"** — 9876 is the `celld dev` loopback default. Production
  nodes are started with `--listen 0.0.0.0:8080`; the internal/peer listener is `:8081`.
  https://raw.githubusercontent.com/denoland/celld/main/README.md
- **04:208 "29 containers/services … a privileged orchestrator process launched through `nsenter`"** —
  `embed/compose/compose.yaml` defines **21** services and 12 images. `nsenter` is used by the
  `preflight` and `host-setup` one-shot containers; the orchestrator is `privileged: true`
  with `pid: host` / `cgroup: host`, not launched via `nsenter`.
- **06:14 "~100 contributors" (workerd)** — 236.
- **06:30 "two synchronous round trips to the S3 bucket"** — the merge commit says "an object
  acknowledges a write only once it is fully synced to the bucket". "Two round trips" is
  not in the source.
- **05:132 "(`app/object/shared.rs`)"** — path does not exist in rustfs main.

---

### [BLOCKER] The cost model mixes $/year into a $/month sum, so the 39.1% break-even is wrong

**Where:** docs/09-cost.md:37 (and the resulting 09:47, 09:55, README:108, README:147)

**Claim under attack:**
> `labour     0.5 FTE × $128,869 loaded / 54.6 nodes    = $1,180`

summed with `hardware $40,520 / 48 months = $844`, `power … = $89`, `colo … = $110`,
`transit … = $50` to produce `node-month = $2,443`, then
`$114.50 / $292.76 = 39.1% duty cycle`.

**Why it fails:** every other line is dollars per month. `$128,869 × 0.5 ÷ 54.6` is
**dollars per node per year** ($1,180.1/yr = $98.3/month). The correct monthly figure is
`0.5 × 128,869 / 54.6 / 12 = $98`. Substituting it:

```
node-month = 844 + 89 + 110 + 50 + 98 + 169 = $1,360
container-month = 1,360 / 21.33 = $63.76
break-even = 63.76 / 292.76 = 21.8%
```

So the headline "self-hosting only beats Cloudflare above roughly a 40% sustained duty
cycle" (README:108) is really **~22%**, and the sentence "At 24% the Cloudflare equivalent is
$70/month against $114.50 owned — Cloudflare is 38% cheaper" (09:57) reverses: at 24% owned
metal ($63.76) is *cheaper* than Cloudflare ($70.26). The document's central economic
conclusion inverts.

The inconsistency is visible inside the same file: 09:119 books "Labour (0.5 FTE) ~$5,400"
for an 11-node fleet — a third value, implying $491/node-month, neither $1,180 nor $98.

**What to do instead:** pick one labour model and state its units in the table header
(`$/node-month`). If the intent is "one ops person covers 54.6 nodes", the line is $98/month
and the break-even is 22% — rewrite the conclusion and the README accordingly. If the intent
is "0.5 FTE per node", the break-even is over 100% and the whole "capability, not cost"
framing needs restating. Either way, reconcile 09:37 with 09:119.

---

### [MAJOR] "Containers cannot run the target workload at any price" is false; the 6-hour cap is a Sandbox/DO-API limit

**Where:** docs/09-cost.md:77-82 and docs/00-constraints.md:73-82

**Claim under attack:**
> "Because the comparison above is partly fictional. Cloudflare Containers **cannot run the
> target workload at any price**: - a container stops when its Durable Object goes inactive,
> even mid-build; - the inactivity ceiling is 6 hours;"

and 00:73: *"The decisive constraint is not size, it is lifetime. From
<…/sandbox/concepts/lifetime/>, verbatim:"*

**Why it fails:** the 6-hour ceiling is `setInactivityTimeout()` on the **Durable Object
Container API**, i.e. the Sandbox path. Containers using the **`default` scheduling policy**
(the `Container` class) are governed by `sleepAfter`, which the docs describe as
"`string | number`, default: `"10m"` — how long to keep the container alive without activity
… Accepts a number of seconds or a duration string such as `"30s"`, `"5m"`, or `"1h"`", with
no documented maximum, plus an overridable `onActivityExpired()` hook that can decline to
stop. The scaling page states flatly: "Each instance will run until its `sleepAfter` time has
elapsed, or until it is manually stopped."
(https://developers.cloudflare.com/containers/api/container-class/ ,
https://developers.cloudflare.com/containers/configuration/scaling-and-routing/ )

Concretely: `sleepAfter = "8h"` plus `renewActivityTimeout()` runs an 8-hour build on
Containers today. The document's "decisive constraint" is a category error — it quotes the
Sandbox page as evidence about Containers.

The conclusion ("replace Cloudflare compute for heavy CI") still survives on the *other*
grounds the document gives — 4 vCPU / 12 GiB / 20 GB max instance and 50 GB image storage per
account, both verified — but the argument it calls decisive does not hold.

**What to do instead:** drop "at any price" and the lifetime bullet from the Containers
argument, or re-scope it explicitly to "Sandbox SDK and the `durable_object` scheduling
policy". Keep the size and image-storage arguments, which are correct and sufficient. Fix
00:73 to say the 6-hour cap applies to `setInactivityTimeout()`, not to Containers.

---

### [MAJOR] R2 does implement object lock, and the document uses its absence as a reason to replace R2

**Where:** docs/00-constraints.md:49 and 00:53; docs/05-storage.md:165

**Claim under attack:**
> "No ACLs, no bucket policies, no object lock, no replication, no notifications, no static
> hosting." … "Replace it only if you are moving more than ~80 TB, or if you need object lock
> / bucket policies that R2 does not implement."

and 05:165: `| Object lock / WORM | no | yes (SeaweedFS) |`

**Why it fails:** R2 has shipped **bucket locks** — prefix-scoped retention rules that
"prevent the deletion and overwriting of objects in an R2 bucket for a specified period — or
indefinitely". Configured via dashboard, `wrangler r2 bucket lock add|set`, or
`PUT /accounts/{id}/r2/buckets/{bucket}/lock`. Cloudflare's own durability page points at it
as the anti-deletion control. The document's inference is valid only for the *S3 API surface*
(`PutObjectLockConfiguration` is indeed ❌); it does not follow that the capability is absent.
(https://developers.cloudflare.com/r2/buckets/bucket-locks/ ;
https://developers.cloudflare.com/r2/reference/durability/ — "Use bucket locks … to limit access to data")

This matters because "you need object lock" is one of exactly two stated triggers for leaving
R2. Half of the replacement case is built on a capability that exists. It also corrupts the
05:159 comparison table, which claims self-hosted wins on WORM.

**What to do instead:** delete "no object lock" from 00:49 and 05:165, and change the verdict
at 00:53 to "bucket policies and replication", which are genuinely unimplemented. If the real
objection is that R2's bucket locks are not S3-API-compatible (so tooling cannot use them),
say that instead — it is a narrower and defensible claim.

---

### [MAJOR] The `vpc_networks` example is not valid Wrangler configuration

**Where:** docs/02-connectivity.md:61

**Claim under attack:**
> `{ "binding": "SITE", "network_id": "<mesh-or-tunnel-id>", "remote": true }`

**Why it fails:** there are two distinct keys and they are not interchangeable. Binding to a
**tunnel** uses `tunnel_id` with the tunnel's UUID; `network_id` is only ever the literal
`"cf1:network"` for Cloudflare Mesh. Pasting `network_id: "<mesh-or-tunnel-id>"` produces a
binding that resolves nothing, and the failure surfaces at request time as
`destination_not_found`/`dns_error`, which the document's own troubleshooting table
(02:74) will mislead the reader into blaming on QUIC. The README mermaid diagram (README:76)
correctly shows `cf1:network`, so the two files contradict each other.
(https://developers.cloudflare.com/workers-vpc/configuration/vpc-networks/ — "Reference a
specific Cloudflare Tunnel directly by its UUID: `"tunnel_id": "550e8400-…"`"; "Bind to
Cloudflare Mesh using `network_id: "cf1:network"`")

**What to do instead:** show both forms explicitly —
`{"binding":"SITE","tunnel_id":"<uuid>","remote":true}` for a per-site tunnel, and
`{"binding":"SITE","network_id":"cf1:network","remote":true}` for Mesh — and state that the
document's recommendation (one tunnel per site) means `tunnel_id`. Note also that binding
directly to a tunnel requires the **Connectivity Directory Admin** role, which the doc never
mentions.

---

### [MAJOR] The SeaweedFS port table mislabels master-gRPC as replication; following it breaks the cluster

**Where:** docs/05-storage.md:94 (and docs/01-architecture.md:16)

**Claim under attack:**
> `| replication | 19333 | overlay only |`

**Why it fails:** 19333 is the **master server's gRPC port**, not replication. SeaweedFS
defaults every gRPC listener to `port + 10000`, so master 9333→19333, volume 8080→**18080**,
filer 8888→18888, S3 8333→18333 (`-port.grpc` defaults to `0` in
`weed/command/{master,volume,filer}.go`). Volume-to-volume replication — the actual bulk data
plane the document is trying to keep off Cloudflare — runs over the volume servers'
8080/18080, not 19333.

An operator who builds the firewall from this table gets two failures at once: they allow
19333 on the overlay (harmless, it is master gRPC) and they leave 18080/8080 unreachable
between volume servers, so replication and EC repair silently stall. That is precisely the
failure mode doc 10 Failure 8 and the EC-repair warnings are written to prevent.

**What to do instead:** replace the row with `replication (volume↔volume) | 8080 + 18080 |
overlay only`, and add `master gRPC | 19333` as a separate overlay-only row if you want
completeness. Same correction in 01:16.

---

### [MAJOR] "You are silently at 3× replication cost" — the shipped default is no replication at all

**Where:** docs/05-storage.md:110

**Claim under attack:**
> "OSS erasure coding is hardcoded at 10+4 and repair is **manual** (`ec.rebuild -apply`).
> If you never schedule it, you are silently at 3× replication cost."

**Why it fails:** SeaweedFS's `-master.defaultReplication` default is the empty string
(`weed/command/server.go:107`), which the volume allocator treats as `000` — **one copy, zero
redundancy**. So the operator who "never schedules it" is not paying 3× for safety; they are
paying 1× and holding a single copy of every shard on one disk. EC 10+4 is 1.4× overhead,
which is *cheaper* than the 3× the sentence warns about, so the sentence also inverts the
cost direction. (Flag default:
https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/weed/command/server.go ; the
`defaultReplication = 000` semantics are visible in
https://github.com/seaweedfs/seaweedfs/issues/8460 )

This is the single most dangerous sentence in the storage chapter: it tells the reader their
unconfigured cluster is expensively redundant when it is actually undefended, in a document
whose whole thesis is "do not lose data".

**What to do instead:** say what is true — "the default replication setting is `000`: one
copy. Set `-master.defaultReplication=001` (or 002) *and* run `ec.rebuild -apply` on a
schedule, or you have no redundancy at all." That makes the point the paragraph is trying to
make, and it is checkable.

---

### [MAJOR] Two block quotes are presented as verbatim but are not the source text

**Where:** docs/05-storage.md:30-32 (celld) and docs/05-storage.md:73-75 (SeaweedFS)

**Claim under attack:**
> "celld states the requirement plainly (`docs/guarantees.md`): > The store must provide
> conditional writes, exact ranged reads, and read-after-write consistency. Amazon S3,
> Cloudflare R2, Google Cloud Storage, Tigris, and Azure Blob Storage qualify; Backblaze B2,
> Hetzner, and DigitalOcean Spaces do not."

and

> "From their engineering write-up: > Instead of demanding compare-and-swap from each of
> SeaweedFS's many metadata backends, or taking a distributed lock on every write, SeaweedFS
> routes each object's writes to one owner filer that serializes them locally."

**Why it fails:** the celld text does not exist in `docs/guarantees.md`. The actual wording is
two separate paragraphs — "Both promises require a bucket with working conditional writes and
ranged reads…" and "The qualified stores are Amazon S3, Cloudflare R2, Tigris, Google Cloud
Storage, and Azure Blob Storage." and "Backblaze B2, Hetzner Object Storage, and DigitalOcean
Spaces do not implement the required conditional writes". The substance matches; the
quotation marks are fabricated, and the ordering of the store list differs. I could not find
the SeaweedFS sentence anywhere in the repository or the project site, and no URL is given.
The mechanism it describes is also not how the code works: SeaweedFS sends a filer-side
`WriteCondition` (`IF_ENTRY_EQUAL` / `IF_NOT_EXISTS`) to the owner filer under the object's
path lock (`weed/s3api/s3api_object_handlers_put.go`, `routedPut`/`createUnderLock`), not an
"in-process mutex".

**Why this is more than a nit:** the document's credibility rests on "every figure here was
fetched from the primary source" (00:3). Two of its most load-bearing citations are
paraphrases dressed as quotes, one with no source at all. A reader who checks will stop
trusting the rest — which is a shame, because the rest mostly holds up.

**What to do instead:** either quote exactly and link the file/line, or drop the quotation
marks and write "celld's guarantees document requires…". For SeaweedFS, replace the invented
quote with a pointer to `s3api_object_handlers_put.go` and describe the write-condition
mechanism accurately.

---

### [MINOR] Workers Free worker size is 64 MiB, not 3 MiB

**Where:** docs/00-constraints.md:100

**Claim under attack:** `| Worker size | 3 MiB | 64 MiB |`

**Why it fails:** the current limits table reads `Worker size (uncompressed) | 64 MiB | 64 MiB`.
3 MiB was the compressed limit in an older plan. Nothing in the design depends on it, but it
sits in a table introduced as "the numbers that killed the obvious approaches", so a reader
who knows the current number discounts the whole table.
(https://developers.cloudflare.com/workers/platform/limits/)

**What to do instead:** change to `64 MiB | 64 MiB`, or drop the row — it is not load-bearing.

---

### [MINOR] "The last MPL release was v1.6.3" — it is v1.6.10

**Where:** docs/03-orchestration.md:40

**Claim under attack:** "The last MPL release was v1.6.3."

**Why it fails:** the Nomad LICENSE scopes BUSL to "Nomad Version 1.7.0 or later", and the
tag list contains v1.6.4 through v1.6.10. v1.6.10 is the last MPL-2.0 release. The practical
harm is that a reader who wants a permissively licensed Nomad pins 1.6.3 and forfeits seven
patch releases of fixes — in a document that elsewhere insists you patch KVM and pin
versions for security.
(https://forge.web.pkgforge.dev/github/repos/hashicorp/nomad/tags ;
https://raw.githubusercontent.com/hashicorp/nomad/main/LICENSE)

**What to do instead:** "The last MPL-2.0 release was v1.6.10; 1.7.0 and later are BUSL-1.1."

---

### [MINOR] The sensitivity table's numbers do not follow from the model

**Where:** docs/09-cost.md:142 and 09:144

**Claim under attack:**
> `| Hardware life | 48 months | 36 months raises owned cost ~22% |`
> `| Nodes per ops person | 54.6 | halve it and owned cost per unit doubles |`

**Why it fails:** with the document's own line items, 36 months moves hardware from $844 to
$1,126 (+$282 on $2,443) = **+11.5%**, not 22%. And because labour is 48% of node-month,
doubling it yields 1.48×, not 2×. Both rows overstate sensitivity, which makes the model look
more assumption-driven than it is — the opposite of the intended effect of a sensitivity table.

**What to do instead:** recompute both from the stated formula and put the actual deltas in
the table (+11.5%, ×1.48). If you want a "doubles" row, apply it to the labour line only.

---

### [MINOR] The "five-second problem" has no source and no such documented limit

**Where:** docs/02-connectivity.md:88-91

**Claim under attack:**
> "### The five-second problem
> There is no stream resumption. A QUIC idle timeout kills every in-flight socket."

**Why it fails:** the Workers VPC documentation, the reference page, and the troubleshooting
page enumerate failure modes in detail (18 `fetch()` error codes, tunnel errors, permission
errors) and none of them describes an idle timeout or the absence of stream resumption. A
5-second timeout would make the recommended `GET /v1/jobs` path unusable too, which
contradicts the sentence immediately following ("That is fine for `GET /v1/jobs`"). The
recommendation it produces — idempotency keys, cursor-based reconnect — is good practice
regardless, so nothing downstream breaks, but the number appears invented.
(https://developers.cloudflare.com/workers-vpc/reference/troubleshooting/)

**What to do instead:** either cite the doc that states the timeout, or rewrite as "treat VPC
connections as liable to drop without resumption; assume the worst and require idempotency
keys" without inventing a duration.

---

### [MINOR] celld's port is the dev-server default, presented as the production listener

**Where:** docs/01-architecture.md:15 and docs/06-edge-runtime.md:104-108

**Claim under attack:** `| celld | Tier 2 only | runs Workers applications | 9876 (worker), internal |`

**Why it fails:** 9876 is `celld dev`'s loopback Worker listener. A real node is started with
`--listen 0.0.0.0:8080` and `--internal-listen <private>:8081`, and the README's deployment
examples all use 8080/8081. The doc 06 diagram labels the ingress targets `:9876`, so an
operator wiring Caddy to 9876 against a production node gets connection refused.
(https://raw.githubusercontent.com/denoland/celld/main/README.md)

**What to do instead:** `8080` (worker listener, `--listen`) and `8081` (peer/operator
listener, `--internal-listen`), noting 9876 is dev-only.

---

### [MINOR] E2B service count and the `nsenter` characterisation are wrong

**Where:** docs/04-compute.md:208-209

**Claim under attack:**
> "- 29 containers/services, 13 host ports, 8 one-shot initialisers, and a privileged
> orchestrator process launched through `nsenter`"

**Why it fails:** `embed/compose/compose.yaml` defines **21** services across 12 images (and
10 with `restart: "no"`, not 8). 13 host ports is correct. `nsenter` appears in the
`preflight` and `host-setup` one-shots (`nsenter -t 1 -m -u -i -n -p -- …`); the orchestrator
is `privileged: true` with `pid: host`, `cgroup: host`, `network_mode: host` — it is not
launched through `nsenter`. The argument ("E2B is someone else's complexity") is unaffected;
the enumeration is just wrong.
(https://raw.githubusercontent.com/e2b-dev/runtime/main/embed/compose/compose.yaml)

**What to do instead:** "21 services across 12 images, 13 host ports, 10 one-shot
initialisers, and a privileged orchestrator with `pid: host` and `cgroup: host`."

---

### [MINOR] workerd contributor count and the "two round trips" detail

**Where:** docs/06-edge-runtime.md:14 and 06:30

**Claim under attack:** "~100 contributors" and "every write is acknowledged only after two
synchronous round trips to the S3 bucket".

**Why it fails:** the contributors API paginates to **236** (247 including anonymous
commits). And the merge commit says "an object acknowledges a write only once it is fully
synced to the bucket" — the number of round trips is not stated and is an implementation
detail that may change. Both are small, but the second is presented as a reason the feature
is too slow to use.
(https://forge.web.pkgforge.dev/github/repos/cloudflare/workerd/contributors ;
https://forge.web.pkgforge.dev/github/repos/cloudflare/workerd/commits/aa494794)

**What to do instead:** "~240 contributors"; "acknowledges a write only once it is fully
synced to the bucket (no peer replication, so latency is a bucket round trip)".

---

### [NIT] "All over WebSocket" is true only of the non-HTTP service types

**Where:** docs/00-constraints.md:146 (and README:44)

**Claim under attack:** "Tunnel public hostnames support HTTP, HTTPS, UNIX, TCP, SSH, RDP,
SMB — all over WebSocket."

**Why it fails:** Cloudflare's protocol table marks TCP, SSH, RDP and SMB as "Streams … over a
WebSocket connection"; HTTP, HTTPS and UNIX are ordinary proxied requests, not WebSocket.
The load-bearing half — no UDP — is correct.
(https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/protocols/)

**What to do instead:** "HTTP/HTTPS/UNIX proxied; TCP, SSH, RDP, SMB tunnelled over WebSocket;
no UDP."

---

### [NIT] "100 MB Worker body cap" is a zone-plan limit, not a Worker limit

**Where:** docs/05-storage.md:113 and docs/07-control-plane.md (presign rationale)

**Claim under attack:** "the 100 MB Worker body cap means uploads must be presigned".

**Why it fails:** the 100 MB figure is the *account plan's* maximum request body size (Free
and Pro 100 MB, Business 200 MB, Enterprise up to 5 GB) — "Request body size limits depend on
your Cloudflare account plan, not your Workers plan". The presign conclusion is right; the
attribution is not.
(https://developers.cloudflare.com/workers/platform/limits/)

**What to do instead:** "the 100 MB request-body limit on Free/Pro zones".

---

### [NIT] Firecracker boots in *less than* 125 ms, not "≤125 ms"

**Where:** docs/04-compute.md:31

**Claim under attack:** "boot to `/sbin/init` in ≤125 ms".

**Why it fails:** the project states "<125ms" and "< 5 MiB memory footprint". Trivial, but
this document is explicitly a citation exercise.
(https://firecracker-microvm.github.io/)

**What to do instead:** "<125 ms".

---

## What the document gets right

- **The 125 s Proxy Read Timeout.** I expected the usual 100-second folk figure and it is
  wrong: Cloudflare's 524 page says "the default 125 seconds Proxy Read Timeout", and the
  Nomad `wait=60s` advice that follows from it is correct.
- **The Workers VPC QUIC/UDP-7844 requirement.** I expected this to be forum folklore. It is
  documented verbatim on the VPC tunnel page and again in the troubleshooting page, including
  the specific failure signature (http2 breaks DNS resolution while the tunnel looks healthy).
- **SeaweedFS actually implements atomic conditional writes.** I expected the CAS claim to be
  aspirational. `s3api_object_handlers_put.go` implements `If-Match`/`If-None-Match` with
  filer-side `WriteCondition` under a path lock, returning 412 — the celld requirement is
  genuinely met. (celld's own governance numbers — 6,169 stars, 2 contributors, 14 commits,
  PRs disabled — also check out exactly.)

---

## Unanswered questions

- **What is the labour model, in units?** docs/09 gives three mutually incompatible labour
  figures ($1,180/node-month, $98/node-month, $491/node-month for the 11-node fleet). Until
  one is chosen, no reader can reproduce or challenge the break-even.
- **What happens to one-DO-per-node at fleet scale?** At 10,000 nodes the design has 10,000
  Durable Objects each writing rows; the doc argues DOs are fine because "the write volume is
  human-scale" but never states the node ceiling it is designing for.
- **How does the Worker hold a SeaweedFS *admin* credential?** 07:194 lists
  `SEAWEEDFS_ADMIN_KEY` as a Worker secret, but 01:251 promises "presigned admin calls" for
  bucket creation and policy. Presigned URLs cannot create buckets or write `s3.json`; the
  admin path is unaddressed.
- **What is the backup and restore story?** There is no mention of backing up D1, the Durable
  Object state, or the celld fleet bucket — yet 10:82 makes bucket loss an "integrity event"
  with a stop-all-writes runbook and no recovery procedure beyond "restore the bucket".
- **What is the RPO/RTO target?** The document says "replicate off-site, and test a restore"
  (05:174) and never states a number, in a document that states numbers everywhere else.
- **Does the threat model cover the S3 gateway's own CVE history?** 08:22-32 covers the
  auth-off default but not the gateway's track record (a cross-bucket path traversal has been
  published as CVE-2026-54917 — BELIEVED, from
  https://kitploit.com/en/tools/github/biitts/cve-2026-54917-seaweedfs-cross-bucket-traversal ;
  I did not reach a primary advisory). For a component the doc says is "the most likely to
  page you at 3am", patch cadence deserves a paragraph.
- **What does the enrolment path do when the Worker is down?** Flow 1 (01:72-92) requires the
  Worker to mint the preauth key and the enrolment token; a Cloudflare outage therefore blocks
  all node replacement, which contradicts the "worst case is I cannot see my fleet" claim at
  02:190.
- **How are Nomad ACL tokens bootstrapped and rotated?** 10:162 lists "Nomad ACL token" as one
  of three expiry clocks to display, but no flow creates or rotates it.
- **Where does the CAS probe run when SeaweedFS is the thing that is broken?** 10:112 makes
  the probe a Nomad `sysbatch` job — but the fleet bucket *is* SeaweedFS, so the probe's own
  scheduler dependency is unexamined.
