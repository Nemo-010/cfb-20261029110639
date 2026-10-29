# celld — deep review

*Reviewed at `denoland/celld` v0.6.3, commit `8702f6d186c77698dbfb30cf29e3b1922a88f008` (2026-10-21). 116,568 lines of Rust across 132 files.*

## Verdict

**Put celld in the edge-runtime + stateful-coordination slot. Do not put it in the compute slot.** workerd (Apache-2.0, 9,093 stars) is the open-source single-node runtime Cloudflare itself uses, but it ships no durable storage, no clustering and no deploy path. celld is the only serious project that fills that gap, and the engineering underneath it (a pure-decision core, epoch-fenced ownership via object-store CAS, per-cell SQLite with an LTX write-ahead replication stream) is real, not a demo. But it is a beta with a hard, non-negotiable dependency on an object store that implements S3 conditional writes with read-after-write consistency (`docs/guarantees.md:25-40`) — which is exactly the component this study is *also* replacing. MinIO community edition passes the startup probe but is explicitly "not qualified for production" (`docs/guarantees.md:37-41`); Garage, SeaweedFS and Ceph-RGW are not mentioned at all and their `If-Match`/`If-None-Match` behaviour on PUT is unverified. If the store ignores a conditional header, celld's correctness story collapses into "two nodes can own one cell" (`docs/guarantees.md:32-34`), which is silent data corruption, not an outage. Its Containers feature is explicitly **Experimental** (`docs/cloudflare-compat.md:21`), binds a container to the lifetime of a Durable Object's ownership on one node, gives it ephemeral disk, and ships images to nodes as tarballs through the bucket (`docs/services/containers.md:5-6`, `crates/celld/container.rs:20-24`). That is not a CI runner and it will not run your long-lived containers. Adopt celld as the runtime for the stateful half of the dashboard's backend; keep CI and long-running containers on something with a real scheduler.

## What it actually is

The README calls it "self-hosted, distributed Durable Objects" (`README.md:3`). That undersells it and oversells it at the same time.

**What it genuinely is:** a single 66 MB Rust binary that embeds V8 and runs a Wrangler bundle — Workers, Durable Objects, KV, Queues, D1, R2, Workflows, Cron Triggers, static assets, Worker Loaders, and (experimentally) Containers. It is a *complete reimplementation of the Cloudflare serverless platform's programming model*, deployed from `wrangler.jsonc`, with the durable state pushed into an S3/GCS/Azure bucket instead of Cloudflare's internal storage. The API surface is broad enough that the project maintains a differential-conformance test suite against workerd as the oracle (`docs/testing.md:14-22`).

**What it is not:** it is not a scheduler, not an orchestrator, not a container platform, and not multi-tenant. `docs/limitations.md:9` — "A fleet runs one application. celld has no account service, multi-tenant scheduler, or managed ingress." `crates/celld/protocol.rs:13` — "one fleet has one current application." `docs/security.md:3-4` — "It is not safe for hostile multi-tenant use. Only the latest release receives security fixes."

**The honest architectural read of "no consensus service":** the README says the fleet "needs no membership protocol, failure detector, or consensus service" (`README.md:22-25`). True, and slightly misleading. celld has not eliminated consensus — it has *outsourced it to the object store*. Every ownership decision is a conditional PUT against S3/R2/GCS/Azure (`crates/celld/bucket.rs:5-20`), and the durability of every acknowledged write is proved either by that store or by a write-all-ack-all fsync to 1-2 peer nodes (`crates/celld/node_log.rs:5-12`). You have replaced a Raft cluster with an object-store bill and a strong-consistency requirement. That is a good trade — S3's conditional writes are a well-tested primitive and you already own the bucket — but it means **the bucket is the single point of correctness**. `docs/security.md:149-153`: "The fleet bucket is the root of authority... A holder of the bucket credentials controls the fleet."

## Architecture (with file paths)

**Three crates, one deliberate split** (`Cargo.toml:5`, `members = ["crates/*"]`):

- `crates/logic/` — 13,360 lines. The decision core. Sans-I/O. `crates/logic/lib.rs:1-9` states the invariant: "`on_event` is the only way behavioral state advances... No adapter may mutate `State` directly." `State` is at `crates/logic/lib.rs:643`. Every coordination decision — ownership, restore, drain, rebalance, pressure, alarms, queues, the log tier — is a module here (`crates/logic/lib.rs:11-38`). This is what makes the protocol testable by simulation, and it is the single most credible thing in the repo.
- `crates/celld/` — 91,797 lines. The effect executor. V8 embedding, HTTP, bucket I/O, Docker, deploy. Explicitly "only an effect executor and adapter host" (`Cargo.toml:1-3`).
- `crates/ltx/` — 11,411 lines. The SQLite replication format. Seeded 2026-08-03 from a read-only snapshot of `mikenomitch/rustyriver`, itself a Rust reimplementation of Litestream v0.5, which implements the `superfly/ltx` file format (`crates/ltx/README.md:14-30`). Byte-level format spec at `crates/ltx/reference/ltx-format.md`. It does **not** track upstream — "celld owns and evolves this snapshot as first-class celld source" (`crates/ltx/README.md:16-17`).

**SQLite-per-cell.** `crates/celld/storage.rs:8-14`: "Each cell is its OWN db file (its own replicated, epoch-fenced bucket prefix), so the JS thread holds a `scope -> Connection` map: `open` on activate, `close` on evict." The `OpenCell` struct (`crates/celld/storage.rs:82-96`) binds the `Connection` to the `epoch` that authorised activation, deliberately, "to prevent asynchronous object-store work from recovering an epoch through a later ownership lookup after a takeover." Cell scope is a *security* fence because it becomes both a path component and a bucket key: `valid_cell_scope` at `crates/logic/cell.rs:43-50` admits only ASCII alphanumerics plus `_ - . : $`, max 255 bytes, and rejects `.` and `..` (`crates/logic/cell.rs:1-42`). That is a well-reasoned check, not an afterthought.

**The ownership lease protocol.** This is the core of the system and it is simple enough to audit:

- One record per cell: `cells/<cell>/own.json`, holding `{"node": "<id>", "epoch": <u64>}` (`crates/celld/ownership_store.rs:21-31`, `docs/guarantees.md:90-95`).
- Acquire = conditional create if absent, compare-and-swap on the etag if present. `cas_owner` at `crates/celld/ownership_store.rs:949-967`; release writes `{"node":"","epoch":E}` only after verifying the record still names this node at this epoch (`release_owner`, `crates/celld/ownership_store.rs:934-948`).
- Every activation advances the epoch. The epoch is stamped into the *storage key* — `cells/<cell>/ltx/e<epoch>/` — so a fenced node that keeps writing writes only into a superseded prefix that no restore will read (`docs/guarantees.md:139-148`). This is the clever bit: fencing is enforced by key layout, not by trusting the loser to stop.
- Node liveness is a separate lease: `nodes/<node>.json` with an expiry, renewed at one third of `CELLD_TTL_MS` (default 10,000 ms). `cas_node_lease` at `crates/celld/ownership_store.rs:970-1040`. On expiry the node **self-fences**: stops every active cell, fails every incomplete request, logs `SELF-FENCE:` and exits with code 3 (`docs/guarantees.md:276-300`). The fenced state is terminal — only a supervisor restart recovers it.
- Acknowledgement (RPO=0): after a bucket proof, the node re-reads the ownership record once and acks only if it still names this node at this epoch. `docs/guarantees.md:150-160`: "The check reads the record instead of a clock, so a paused process or a skewed clock cannot pass it." That is the right call, and it is why there is no clock-skew dependency in the safety argument.

**Replication (LTX).** Committed WAL frames are captured as L0 LTX segments (`crates/ltx/README.md:5-9`). Two durability postures, selected by `CELLD_DURABILITY`:

- `bucket` — ack after the segment lands in the object store. One round trip per write.
- `fleet` (default) — the owner ships each segment to a follower ensemble of 1-2 other nodes over signed peer HTTP; ack when every member has fsync'd, **or** when the bucket upload wins, whichever is first (`crates/celld/node_log.rs:5-12`). Write-all, ack-all. "A node never counts itself as a follower... a fleet needs two running celld nodes before any node can complete a fleet proof" (`docs/guarantees.md:166-186`).

The fleet posture is materially faster: README reports ~90 ms per write to a region-local store, ~600 ms against a non-local store, and ~25 ms once a second node holds the write (`README.md:178-182`). The cost is that you now need node→node connectivity and a follower's disk is holding acknowledged writes that the bucket does not yet have — which is why takeover has a "recovery gate" that must collect a dead node's retained segments before a successor may restore (`docs/guarantees.md:193-205`).

**The peer transport.** Plaintext HTTP with an HMAC over each control request. `crates/celld/peer_auth.rs:16-33`: HMAC-SHA256, domain-separated, 30-second clock window, 2× replay retention, 1M-entry replay cache, protocol version 5. Cell fetch and RPC traffic travels inside an upgraded `/peer/tunnel` stream and is **not signed after establishment** — `crates/celld/main/peer_tunnel.rs:1-19`, `docs/security.md:40-46`. The comment at `crates/celld/main/peer_tunnel.rs:15-19` explains the design constraint well: `x-cells-*` headers are overwritten by the sender and stripped by the receiver so an application cannot smuggle them.

**The wrangler compatibility surface** is a hard allowlist, not a parser that tolerates extras. `SUPPORTED_KEYS` at `crates/celld/deploy.rs:42-64` names exactly 21 top-level keys: `$schema, name, main, compatibility_date, compatibility_flags, durable_objects, migrations, assets, services, triggers, vars, d1_databases, kv_namespaces, queues, workflows, r2_buckets, worker_loaders, containers, no_bundle, define, rules`. Anything else — including `routes` — fails the deploy at `crates/celld/deploy.rs:1296-1306` with "celld deploy does not support these config keys: ... Deploy this project with Wrangler instead, or remove them." `wrangler.toml` is refused outright (`crates/celld/deploy.rs:1279`). This is the correct failure mode: refuse at deploy, not at first request. The full difference list is `docs/cloudflare-compat.md`, and it is unusually honest about gaps (Cache is always-miss, `BroadcastChannel` throws, `cf` has no geolocation, RPC stubs cannot cross isolates).

## The seam into this design

**Where it fits, exactly:**

1. **Dashboard → celld over Workers VPC.** The dashboard stays on Workers; a Worker binding reaches celld's public listener over a VPC Network backed by Cloudflare Tunnel or Mesh (verified: Workers VPC supports HTTP `fetch()` and raw TCP `connect()` to a bound tunnel or Mesh network — https://developers.cloudflare.com/workers-vpc/). celld does not terminate TLS (`docs/limitations.md:20-21`), so the tunnel edge does it, which is the correct division. This seam is clean and needs no celld changes.
2. **celld's internal listener over Cloudflare Mesh / WireGuard.** celld requires exactly this: "Put every advertised address on a trusted private network or an encrypted overlay such as WireGuard or Tailscale, and do not publish the internal port" (`README.md:231-234`). Your Mesh network *is* that overlay. This is the one place where your stated constraint and celld's stated requirement coincide perfectly.
3. **The stateful-coordination slot.** Anything you were going to build with Durable Objects — a per-tenant config object, a job-state machine, a lock, a WebSocket fan-out room, an alarm-driven scheduler, a Workflow — celld gives you with `wrangler.jsonc` unchanged. Workflows and Queues are each a cell, so they inherit the same lease and the same failover (`README.md:39-43`).

**Where it will not fit, exactly:**

1. **Containers as CI runners.** `docs/services/containers.md` is a list of reasons not to. The container is bound to the cell's ownership on one node (`crates/celld/container.rs:9-16`); a move, a node restart, a reset, or a node stop **destroys** it (`docs/services/containers.md:154-157`). Disk is ephemeral (`docs/services/containers.md:5-6`). Disk size is not enforced (`docs/services/containers.md:138`). Placement follows the cell, so there is no scheduler — "celld places a container on the node that owns the cell. Cloudflare can place a container away from its object." (`docs/services/containers.md:135-136`). Images travel as tarballs at `deploy/images/<content-key>.tar` through the fleet bucket (`crates/celld/container.rs:20-24, 66-71`); the sandbox example's base image is "about 225 MB" and "each node loads it the first time one of its sandboxes starts" (`examples/sandbox/README.md:8-9`). A 2 GB CI image would be uploaded once and re-downloaded by every node. And a container-heavy node "reports no headroom and sheds cells" (`docs/services/containers.md:120-122`).
2. **Long-running containers.** Default inactivity timeout is 10 minutes (`docs/services/containers.md:107-108`), `start()` checks `hardTimeout` and then ignores it (`docs/services/containers.md:142-144`), and `monitor()` / `exec()` do not keep the object active after the handler answers (`docs/services/containers.md:147-148`). The model is "a Durable Object supervises a short-lived sidecar", not "run this container until it exits".
3. **Multi-app in one fleet.** One fleet = one application (`docs/limitations.md:9`). One process binds to one `--bucket` (one prefix). So N applications means N fleets means N node groups — you cannot amortise a node pool across apps. If the dashboard's backend is one app this is fine; if you were imagining a shared celld cluster serving several, that does not exist.
4. **Workers as a general compute target.** The handler budget defaults to 300 s of wall clock (`crates/celld/engine_api.rs:874-880`), the per-isolate V8 heap is 128 MB shared across up to 32 cells (`crates/celld/runtime.rs:456`, `const MAX_CELLS_PER_ISOLATE: usize = 32`), and 64 concurrent fetches per cell is the admission cap (`docs/README.md:619-620`). This is a request/response and actor runtime, not a batch runtime.

**The gating dependency you must resolve first.** celld needs a store providing conditional create, conditional overwrite, read-after-write consistency, and ranged reads (`docs/guarantees.md:5-12`). The qualified list is Amazon S3, Cloudflare R2, Tigris, GCS, Azure Blob (`docs/guarantees.md:25-27`). **Backblaze B2, Hetzner Object Storage and DigitalOcean Spaces fail it** and produce two-writers-per-cell (`docs/guarantees.md:32-34`). **MinIO community edition passes the probe but is explicitly "not qualified for production"** (`docs/guarantees.md:37-41`). Since this study is replacing R2 with self-hosted object storage, celld's viability is downstream of a decision made in a different review. If the self-hosted store is MinIO, you are running a beta coordination protocol on a store its authors declined to qualify. Run `celld diagnose` against your store *before* anything else — it performs the four conditional-write probes and refuses to serve if the store lies (`docs/guarantees.md:46-64`).

## Limits and failure modes

**Quantified moving parts, per node:** one process; two TCP listeners (`--listen`, `--internal-listen`, `docs/security.md:23-27`); 66,345,400 bytes of binary (63.3 MiB, stripped, dynamically linked against glibc); 419 packages in `Cargo.lock`; 176 distinct `CELLD_*` environment variables; 10 reserved bucket prefixes (`probe/ cells/ nodes/ node-cells/ fleet/ deploy/ deploy-blobs/ log/ wake/ telemetry/`, `docs/guarantees.md:69-71`). Plus, outside the process: a supervisor, an ingress that terminates TLS, a private overlay, `esbuild` on `PATH` for deploys, and — for container classes — a Docker or Podman daemon on every node plus a privileged one-shot `celld-fence` container to install nftables rules on the container bridges (`docs/services/containers.md:80-86`).

**What breaks on restart:**

- Every resident cell re-runs its constructor; a cell keeps no memory across activation (`docs/README.md:34-37`).
- All containers on the node are destroyed (`docs/services/containers.md:154-157`).
- Outbound/non-hibernatable WebSockets close; hibernatable ones are closed with code 1012 and clients must reconnect (`docs/README.md:411-412`).
- A cut handoff leaves the node log for the replacement to recover, and "Recovery of a large dead node can take minutes" (`docs/guarantees.md:230`).
- The supervisor is mandatory and must be configured correctly: "The supervisor must restart without an attempt limit and wait at least one lease lifetime between attempts" (`docs/guarantees.md:84-88`). Without it, a self-fenced node is gone permanently and its capacity with it.

**Failure modes worth naming:**

- **Silent split-brain on a lying object store.** The worst one. "A store that accepts the conditional headers but ignores the condition fails late and silently" (`docs/guarantees.md:33-35`). The startup probe exists precisely for this, but a store that *starts* honouring `If-Match` and later stops is undetectable in flight.
- **Unbounded storage growth.** "Each activation can add a new epoch prefix to the bucket. celld deletes the older prefixes only when `CELLD_LTX_RETENTION_SECS` enables epoch GC, so without it the bytes of a cell increase with each activation" (`docs/README.md:38-41`). Default is unset = no deletion (`--help`, `CELLD_LTX_RETENTION_SECS`). A cell that activates once a minute for a month leaves ~43,000 epoch prefixes. Turn this on.
- **Lost ownership record = unservable cell.** If a lifecycle rule deletes `cells/<cell>/own.json`, celld refuses to acquire the cell forever and requires a hand-written repair record at the newest epoch (`docs/guarantees.md:96-138`). The repair procedure is documented, delicate, and explicitly warns that getting it wrong loses acknowledged writes.
- **Single-node latency cliff.** A one-node fleet cannot do a fleet proof, so every write waits for the bucket: ~90 ms region-local, ~600 ms otherwise (`README.md:178-182`). Two nodes is the minimum for the good path. Do not evaluate celld on a one-node fleet and conclude it is slow.
- **Recovery can stall.** Four documented limits on the recovery gate including "A follower's HTTP error does not prove its data is absent... persistent errors can block recovery and startup" (`docs/guarantees.md:211-222`). A stuck peer can wedge a takeover.
- **The operator API is unauthenticated.** `docs/security.md:40-48`: "Most operator routes have no request authentication" — `/state`, `/cell/<SCOPE>`, `/evict/<SCOPE>`, `/do/<ID>`, `POST /shutdown`. It is alpha and "A release can change its paths or response formats." Network isolation is the only control.
- **No TLS anywhere, and peer traffic is unsigned after tunnel establishment** (`docs/security.md:45-47`). Cloudflare Mesh or WireGuard is not optional here; it is a correctness boundary for confidentiality.
- **Upgrade cadence is aggressive and some upgrades are stop-the-world.** `docs/README.md:518-560` lists seven upgrade notes; three of them (v0.1→v0.2, v0.3→v0.4, v0.5.1→v0.6.0) require stopping the entire fleet. "Mixed versions cannot share a serving fleet" (`README.md:226`). At ~1.2 releases per week you will be doing this often.
- **Hot-path inefficiency in the v0 log tier.** "entries travel as base64 JSON" (`crates/celld/node_log.rs:23-25`). That is a 33% wire overhead plus JSON parse on every replicated segment, on the path that gates every acknowledged write. The comment calls it a deliberate v0 limit. Take them at their word, but it bounds write throughput per node more than the hardware does.

## Licence and governance

**Apache-2.0**, verified from `LICENSE` and `Cargo.toml:5` (`license = "Apache-2.0"`), matching the GitHub API's `spdx_id: Apache-2.0`.

**Third-party encumbrance is disclosed and low.** `NOTICE` lists `lol_html` (BSD-3-Clause, Cloudflare's HTMLRewriter) and its Servo dependencies `cssparser`, `cssparser-macros`, `dtoa-short`, `selectors` under **MPL-2.0**, shipped unmodified in the binary. MPL-2.0 is file-level copyleft: static linking is fine, but you must be able to supply the source of those MPL-covered files. The NOTICE points at crates.io for each, which discharges the obligation as long as those published versions remain available — a real, if small, supply-chain dependency on crates.io not deleting them. `crates/ltx/LICENSE` is Apache-2.0 and `crates/ltx/LICENSE.pierrec-lz4` is BSD-3-Clause (the exact lz4 block bytes are preserved for format compatibility, `crates/ltx/README.md:26-30`). `crates/celld/tokio_select.rs:6` carries an MIT header for Tokio-derived code. No GPL crate names appear in `Cargo.lock`.

**One inconsistency:** `crates/celld/main/peer_tunnel.rs:1` reads "Copyright 2026 Deno Land Inc. **All rights reserved**" while the other 105 source files say "Apache-2.0 license". Two source files carry "All rights reserved" (`crates/celld/js/node_util.js`, `crates/celld/main/peer_tunnel.rs`); the third hit is the BSD-3 lz4 licence, where that phrasing is normal boilerplate. Almost certainly a copied header, and the repo-level LICENSE governs — but if you are doing legal diligence, flag it and get it fixed upstream rather than relying on the reading.

**Governance is the real risk, and it is worse than "single maintainer".**

- **Two contributors, total.** GitHub contributors API: `ry` (9 commits), `bartlomieju` (5 commits). Both Deno Land employees.
- **14 commits on `main`, every one of them a release squash** — `v0.0.1` through `v0.6.3`. There is no incremental development history to review. You cannot see how a change was made or why; you can only diff releases.
- **Zero tests in the public tree.** `grep -c '#\[test\]'` across `crates/celld`, `crates/logic`, `crates/ltx` returns **0**. No `#[cfg(test)] mod tests`, no `proptest!`. The Dockerfile runs `cargo test` in its build stage, and `Cargo.toml:116` declares `proptest`, so tests exist upstream — they are simply not published. `docs/testing.md` describes an impressive suite: differential execution against workerd, TLA+ model checking that "found four bugs and a split-brain that lost an acknowledged write" (`docs/testing.md:28-34`), and deterministic simulation with a fault-injecting object store. Open issue #284 ("Internal test suite availability?") asks for it and has no maintainer reply. **You are asked to trust a beta distributed-consistency protocol on the strength of a prose description of tests you cannot run.** That is the single biggest thing standing between this and a production recommendation.
- **Pull requests are disabled.** `README.md:384-390`: "Coding agents make it too easy to send a large, low-context change that costs maintainers more time than it saves." Contributions go by `git format-patch` to a personal email, under a CLA that assigns all rights to Deno Land Inc. (`README.md:391-397`). You cannot upstream a fix without emailing a patch and hoping. For a component in your critical path, that is a support-model decision, not a style preference.
- **Commercial interest is real and aligned for now.** Deno Land Inc. funds it, celld.dev is a polished docs site with no pricing page (no hosted offering yet), and releases land weekly. The project is not abandoned and shows no signs of it. But "only the latest release receives security fixes" (`docs/security.md:4`) means no LTS, no backports, and a CVE in v0.6.2 forces you onto v0.6.3's stop-the-world upgrade path on the vendor's schedule.

## Verified facts

| claim | value | source |
| --- | --- | --- |
| Licence | Apache-2.0 | `LICENSE`; `Cargo.toml:5`; GitHub API `license.spdx_id` |
| Version reviewed | 0.6.3, commit `8702f6d`, 2026-10-21 | `git log -1`; `celld --version` on the released binary |
| Binary size, x86-64 Linux, uncompressed | 66,345,400 bytes (63.3 MiB), stripped ELF, dynamically linked | downloaded `celld-x86_64-unknown-linux-gnu.gz`, `gunzip`, `file` |
| Binary size, gzipped release asset | 25,157,496 bytes | GitHub releases API, asset `celld-x86_64-unknown-linux-gnu.gz` |
| Rust source size | 116,568 lines across 132 `.rs` files | `wc -l` over `crates/**/*.rs` |
| Transitive dependency count | 419 packages | `grep -c '^\[\[package\]\]' Cargo.lock` |
| Direct `CELLD_*` env vars | 176 distinct | `grep -o 'CELLD_[A-Z0-9_]*' -r crates/ \| sort -u \| wc -l` |
| Stars / forks / open issues | 6,169 / 423 / 78 | GitHub API `/repos/denoland/celld` |
| Contributors | 2 (`ry` 9, `bartlomieju` 5) | GitHub API `/contributors` |
| Commits on `main` | 14, all release squashes | GitHub API `/commits` |
| Releases | 14, `v0.0.1` (2026-08-02) → `v0.6.3` (2026-10-21) | GitHub releases API |
| Tests in the public tree | 0 | `grep -rn '#\[test\]\|#\[cfg(test)\]\|mod tests'` over `crates/` |
| Max cells sharing one V8 isolate | 32 | `crates/celld/runtime.rs:456` |
| Default V8 heap per isolate | 128 MB, shared by up to 32 cells | `README.md:366-368`; `--help` (`CELLD_V8_HEAP_LIMIT_MB`) |
| Default node lease TTL | 10,000 ms, renewed at 1/3 | `docs/guarantees.md:277-279`; `--help` |
| Default handler budget | 300 s | `crates/celld/engine_api.rs:874-880` |
| Max concurrent fetches per cell | 64 | `docs/README.md:619-620` |
| Accepted `wrangler.json` top-level keys | 21, hard allowlist; `routes` rejected | `crates/celld/deploy.rs:42-64`, `:1296-1306` |
| Reserved bucket prefixes | 10 | `docs/guarantees.md:69-71` |
| Qualified object stores | S3, R2, Tigris, GCS, Azure Blob | `docs/guarantees.md:25-27` |
| Stores that fail the probe | Backblaze B2, Hetzner Object Storage, DigitalOcean Spaces | `docs/guarantees.md:32-34` |
| MinIO status | passes probe, "not qualified for production" | `docs/guarantees.md:37-41` |
| Containers status | Experimental | `docs/cloudflare-compat.md:21`; `docs/services/containers.md:6` |
| Cloudflare DO duration price | $12.50 per million GB-s; 400,000 GB-s/month included | https://developers.cloudflare.com/durable-objects/platform/pricing/ |
| Cloudflare DO request price | $0.15 per million; 1M/month included | same |
| Cloudflare DO SQLite storage | $0.20 / GB-month; 5 GB-month included | same |
| R2 Class A / Class B ops | $4.50 / million, $0.36 / million | https://developers.cloudflare.com/r2/pricing/ |
| R2 storage | $0.015 / GB-month | same |
| Workers VPC reach | HTTP `fetch()` + raw TCP `connect()` to Cloudflare Tunnel / Mesh / WAN bound networks | https://developers.cloudflare.com/workers-vpc/ |
| workerd (the alternative) | Apache-2.0, 9,093 stars — single-node runtime only, no storage or clustering | GitHub API `/repos/cloudflare/workerd` |

## Rejected / not for this

- **celld Containers as the CI executor — rejected.** Ephemeral disk, destroyed on cell move and node restart, no scheduler, images shipped as bucket tarballs, disk size unenforced, 10-minute default inactivity timeout. Five independent disqualifiers (`docs/services/containers.md:5-6, 107-108, 135-136, 138, 154-157`).
- **celld as the long-running-container host — rejected.** The container's life is a Durable Object's residency on one node. That is the opposite of what a long-running service needs.
- **celld as a multi-tenant platform — rejected by the authors.** `docs/security.md:3` and `docs/limitations.md:9`. Application code is trusted; it can consume shared node resources; one fleet is one application.
- **celld as an edge/CDN — rejected.** `docs/cloudflare-compat.md` — Cache is always-miss, `cf` carries no geolocation/colo/TLS metadata, `passThroughOnException()` is a no-op, `routes` are not supported. There is no edge. There is one region you chose.
- **celld with a non-qualified object store — rejected.** Split-brain, silently. See `docs/guarantees.md:32-35`.
- **celld on Windows — does not exist.** Linux x86-64, Linux ARM64, Apple Silicon only (`docs/limitations.md:45-47`). There is also an open bug where the aarch64 Linux release aborts on 16 KiB-page kernels such as Raspberry Pi 5 (issue #298), so "ARM64 Linux" is narrower than it sounds.

## Open questions

1. **What object store is the other review choosing, and does it pass `celld diagnose`?** This single answer decides whether celld is adoptable at all. Everything else in this review is secondary. Run the four conditional-write probes against the real store, from two machines, before committing.
2. **Will the internal test suite be published?** Issue #284 is unanswered. Without it you are accepting a beta RPO=0 protocol on documentation alone. If Deno Land will not publish, ask for a support contract that transfers that assurance contractually.
3. **What is the operational cost of the "one fleet per application" rule for your topology?** If the dashboard needs one celld app and CI needs another, that is two node pools, two bucket prefixes, two upgrade schedules, and two sets of reserved-prefix lifecycle-rule exclusions.
4. **How do you front celld's public listener without exposing the internal one?** Workers VPC to the public port is straightforward. But `--advertise` must resolve to the internal listener, and celld "cannot verify a hostname or a translated port" (`docs/security.md:31-34`) — so Mesh routing has to be exact, and a mistake here silently publishes an unauthenticated operator API.
5. **Does the peer ensemble survive a Mesh partition the way you need?** `fleet` durability needs 1-2 reachable followers. A Cloudflare Mesh outage degrades every node to bucket-proof acks (~90 ms/write) rather than failing — correct, but the latency and the bucket op cost both jump, and R2 Class A is $4.50/million.
6. **Is the 128 MB heap shared across 32 cells acceptable for the dashboard's objects?** One noisy cell can OOM its 31 neighbours in the same isolate. `README.md:366-368` presents 128 MB as matching Cloudflare's per-DO limit, but the sharing is celld-specific and issue #278 requests a configurable cap. Model your worst-case cell before assuming per-object isolation.
7. **Who patches this when it breaks at 03:00?** Two maintainers, PRs disabled, patches by email, latest-release-only security support. Decide now whether that is acceptable for the coordination layer of the product, or whether the honest answer is "run it in the slot, but keep a documented exit back to Cloudflare DO for the stateful tier."
