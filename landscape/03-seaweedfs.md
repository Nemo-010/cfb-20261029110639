# SeaweedFS — deep review

## Verdict

Yes — but in a narrow slot, and with two configuration changes you must not skip: **write an `s3.json`** (auth is off by default, so a bare tunnel ingress publishes an unauthenticated read-write store) and **put Postgres or Redis behind the filer** (the default LevelDB filer is an unshareable single point of failure). Put SeaweedFS in the R2 replacement slot for **CI artifacts, container-image layers, and build caches**, running as a 3-node cluster with the S3 gateway co-located, exposed to the world only through one `cloudflared` ingress on port 8333. Do not put it in the slot of "multi-tenant object store other teams self-serve," and do not lean on its erasure coding for durability in the open-source build. The reason it earns the slot at all is one thing: it is the only OSS S3 clone I read whose `If-None-Match: *` / `If-Match` conditional writes are genuinely atomic across multiple gateways — implemented by routing every write for an object to one consistent-hash-owner filer and serialising there on a plain in-process mutex (`weed/s3api/s3api_object_routed_write.go:29-37`, `weed/server/filer_grpc_server.go:327-376`, `weed/server/filer_server.go:204,267`, `weed/util/lock_table.go:13-18`), not by requiring compare-and-swap from the metadata store. That is exactly the property that usually disqualifies MinIO-alikes from being a lock backend, and it is the property a CI system needs. Against that: ~978k lines of Go, 20 commits/day, 54% of them from one person, OSS erasure coding hardcoded at 10+4 with *manual* repair, the filer metadata tier as a hard single point of failure, and S3 authentication **off by default** (`weed/s3api/auth_credentials.go:419-437`). Ship it if you will own it. Do not ship it as an appliance you forget about.

## What it actually is

The README still sells a 2014 story ("a simple and highly scalable distributed file system… store billions of files"). What the code is in 2026 is a **three-tier object store with a POSIX-shaped metadata tree bolted to the front**:

1. **Master** — Raft-replicated topology and volume-assignment service. It does not store data or metadata. It assigns volumes to volume servers, tracks free slots, and — this is the part that matters for this design — maintains and broadcasts the **consistent-hash ring of filers** that decides who owns each object's writes (`weed/server/master_grpc_server.go:526-527,644-661`).
2. **Volume servers** — append-only `.dat` files plus a `.idx` needle map. This is where bytes live. Each "volume" is a ~30 GiB (default) file; a file is chunked at `filer.maxMB` (default 4 MiB in `weed server`, `weed/command/server.go:128`) and each chunk is one needle, one disk read.
3. **Filer** — a hierarchical namespace (`/buckets/<bucket>/<key...>`) held in an *external* store: LevelDB/RocksDB/SQLite locally, or Postgres/MySQL/Redis/etcd/Cassandra/TiKV/MongoDB/HBase/YDB/Tarantool/Elasticsearch/ArangoDB remotely (`weed/command/imports.go:21-44` — 20 backends blank-imported unconditionally; RocksDB and FoundationDB are build-tagged at `weed/filer/rocksdb/rocksdb_store.go:1` and `weed/filer/foundationdb/foundationdb_store.go:1`).
4. **S3 gateway** — a stateless HTTP front end (`weed/s3api/s3api_server.go:1-120`) that translates S3 into filer gRPC calls plus direct HTTP chunk fetches from volume servers.

The S3 layer is now the product, not the filesystem. `weed/s3api` is 218 non-test Go files / 88,320 lines, with 361 test files. Beyond S3 proper it carries S3 Tables, S3 Vectors, an Iceberg REST catalog (default port 8181), and a Lance namespace server (9101) (`weed/command/server.go:180-181`).

Where the README oversells:

- **"O(1) disk reads."** True per chunk — one needle read. But a GET of a 4 GiB object is ~1,024 chunk fetches plus a metadata lookup each, unless chunks have been folded into a manifest (`weed/filer/filechunk_manifest.go`, batch of 10,000 chunks at `weed/filer/manifest_batch.go:10`). The O(1) claim describes the unit, not the operation.
- **"The most complete S3 API"** (README:205-212) — 73 bucket/object operations. Genuinely broad, and I found no missing core verb. But breadth ≠ semantics: `ListObjectsV2` is a **directory walk** with a page limit per directory (`weed/s3api/s3api_object_handlers_list.go:1225-1233` sends `ListEntriesRequest{Directory, Prefix, Limit}`), so listing a prefix with millions of keys costs proportional to entries in that directory, not a flat-keyspace scan like R2. That is the deepest structural difference from R2 and it is not a bug you can patch.
- **Object storage "over the same data" as POSIX and Iceberg** — true, and it is why the metadata tier is a tree. It is also why small-object workloads hit the filer store, not the disks. The Enterprise feature "Sealed Directories" exists precisely to fix this (`18–58× less filer metadata for cold data`) and is paid.

## Architecture (with file paths)

### The three data paths

**Write.** S3 gateway → chunks written directly to volume servers over HTTP (`weed/s3api/s3api_object_handlers_put.go:544` `putToFiler`) → entry written to filer via gRPC `CreateEntry` or a routed `ObjectTransaction`. The volume write is fsynced, but batched: 1 MiB / 128 requests / 500 µs (`weed/storage/volume_write.go:679-683`, `DefaultSyncBatchOption`). Durability is real; write throughput is bounded by fsync batching, not by the network.

**Read.** The gateway looks up the file id, then fetches the chunk itself over HTTP from the volume server (`weed/s3api/s3api_object_handlers.go:2265` `RetriedFetchChunkData`, `:2278-2310` `readChunkRange`). **There is no HTTP redirect anywhere in `weed/s3api`** (grep for `http.Redirect` / `StatusTemporaryRedirect` returns nothing in non-test code). This is a large, under-appreciated deployment win: clients only ever need the S3 port.

**Conditional write.** This is the mechanism the blog describes and the code implements:

- The gateway hashes `"/buckets/<bucket>/<key>"` onto a consistent-hash ring of live filers to name the owner (`weed/s3api/s3api_object_routed_write.go:29-37` `objectRouteKey`, `:39-48` `routableWriteOwner`; ring built with 50 vnodes, `weed/cluster/lock_manager/hash_ring.go:11`).
- The condition is reduced to a list of primitive clauses — `IF_NOT_EXISTS`, `IF_EXISTS`, `IF_ETAG_MATCH`, `IF_ETAG_NOT_MATCH`, `IF_UNMODIFIED_SINCE`, `IF_MODIFIED_SINCE`, `IF_EXTENDED_NOT_EQUAL`, `IF_EXTENDED_TIME_ELAPSED`, `IF_CHUNKS_EQUAL`, `IF_ENTRY_EQUAL` — defined in `weed/pb/filer.proto:267-315`. The filer never learns S3 semantics; it compares (`weed/server/filer_grpc_server_condition.go:22-100`).
- The transaction carries a `route_key`; a non-owner filer forwards exactly one hop and sets `is_moved` so it cannot loop (`weed/server/filer_grpc_server.go:337-372`).
- The owner takes `entryLockTable.AcquireLock(..., ExclusiveLock)` (`weed/server/filer_grpc_server.go:374-376`) and evaluates the condition under it. `entryLockTable` is `util.NewLockTable[util.FullPath]()` (`weed/server/filer_server.go:267`) — a `map` plus a `sync.Mutex` (`weed/util/lock_table.go:13-18`). **In-process, per filer, lost on restart.**
- The gateway falls back to a distributed lock (`withObjectWriteLock`, `weed/s3api/s3api_object_handlers_put.go:442-478`) whenever the route is unavailable, and has a deliberately narrow recovery path for ambiguous routed writes (`createAfterAmbiguousRoute`, `:1205-1296`).

The honesty in this code is unusual. `objectTxnOnFiler` documents that the transaction "is not replayable: it fails over only over a channel that never came up, never past a possibly-committed attempt — a lost response is ambiguous and re-sending could re-apply mutations over a write that landed in between" (`weed/s3api/s3api_object_routed_write.go:157-175`). That is the correct call, and it is the kind of comment you write after being burned.

### Erasure coding

`weed/storage/erasure_coding/` — 14 shards from a volume, 10 data + 4 parity, 1.4× overhead, tolerates 4 shard losses. But in the open-source build the ratio is **hardcoded**:

```
weed/storage/erasure_coding/ec_encoder.go:21-24
    DataShardsCount   = 10
    ParityShardsCount = 4
```

and the code says so in as many words: *"Open-source SeaweedFS always uses the fixed 10+4 layout"* (`weed/storage/erasure_coding/ec_shards_info.go:129-142`). `MinTotalDisks = 14/4 + 1 = 4` (`ec_encoder.go:25`), so four disks is the floor, not fourteen.

EC is applied **to volumes, not objects**, and only on demand or by a worker: `ec.encode` (default `-fullPercent 95 -quietFor 1h`), `ec.decode`, `ec.balance`, `ec.check.replication`, `ec.scrub`, `ec.rebuild` (`weed/shell/command_ec_*.go`). Repair is manual and dry-run by default:

```
weed/shell/command_ec_rebuild.go:34-40
    ec.rebuild [-c EACH_COLLECTION|<collection_name>] [-apply] ...
    -apply: actually perform the rebuild operations (default is dry-run mode)
```

There is no automatic EC rebuild task in the OSS worker registry (the worker only registers `balance`, `erasure_coding` = encode, `ec_balance`, `vacuum`, `s3_lifecycle` — `weed/worker/tasks/`). Automatic shard repair, EC vacuum and bitrot scrub are Enterprise-only, per the vendor's own table.

### Filer metadata backends

20 backends blank-imported unconditionally (`weed/command/imports.go:21-44`), plus RocksDB and FoundationDB behind build tags. This is the pluggability that makes the conditional-write design interesting — the blog's whole argument is that atomicity lives in routing, not in the store, so "LevelDB through Cassandra" behave identically. That argument holds up in the code. What it does *not* buy you is HA: the default is `leveldb2` in a local directory (`weed/server/filer_server.go:282-283`), which cannot be shared. **Multiple filers require an external store.** Three filers each with their own LevelDB would silently diverge.

### What a "minimal 3-node" actually needs

The repo's own 3-node reference is `docker/compose/local-cluster-compose.yml`: **8 containers** — 3 masters, 3 volume servers, 1 filer, 1 S3 gateway — across ports 9333/9334/9335, 19333/19334/19335, 8080/8082/8083, 18080/18082/18083, 8888, 18888, 8111, 8333. Every gRPC port is `HTTP + 10000` (`weed/command/master.go:212`, `filer.go:379`, `volume.go:417`, `s3.go:367`).

The honest minimum for HA:

| Role | Count | Why |
|---|---|---|
| master | 3 | Raft quorum; 1 is a SPOF, 2 is worse than 1 |
| volume server | 3 | replication `001` (one copy on another rack/server) or EC spread |
| filer | 1 or 3 | 1 = metadata SPOF; 3 requires Postgres/MySQL/Redis/etcd |
| s3 gateway | 1–2 | stateless; needs the same ring view as the filers |

So the real floor is 8–10 processes and **one extra database** if you want the filer to survive a node loss. You can collapse master+filer+volume+s3 into one process with `weed server` (`weed/command/server.go:440-535` starts all of them as goroutines), but three of those do **not** give you three filers — they give you three independent LevelDBs.

## The seam into this design

### Where it plugs in cleanly

**The S3 endpoint behind the tunnel.** One `cloudflared` ingress to `:8333` on the S3 gateway host. Because the gateway proxies every byte and never redirects, **volume servers, filers and masters never need to be reachable from Cloudflare at all** — they stay on a private L2/L3 segment. That is exactly the shape this design wants.

**Workers → S3.** Two paths, and you want both:
- *Presigned URLs minted by the dashboard Worker.* SeaweedFS verifies SigV4 query-string presigning (`weed/s3api/auth_signature_v4.go:245-260,319-333,701`). The Worker holds one scoped access key, signs a PUT/GET for a specific key, and the browser or CI runner uploads **directly to the tunnel** — bypassing the Worker entirely.
- *Worker → `fetch()` → tunnel hostname* for control-plane calls (HEAD, small JSON state objects, `ListObjectsV2` on a bounded prefix).

This split matters because of the Workers request-body cap: 100 MB on Free/Pro, 200 MB Business, up to 5 GB Enterprise (self-serve). A CI artifact pipeline that proxies through a Worker will break at 100 MB. Presigned direct upload does not.

**Conditional writes as the CI coordination primitive.** `PUT` with `If-None-Match: *` gives exactly-once "claim this artifact name"; `If-Match: "<etag>"` gives optimistic concurrency on a job-state object. Both are atomic across all gateways and across all filers, which is the thing you would otherwise build a separate database for. R2 has the same guarantee (`developers.cloudflare.com/r2/api/s3/api/` — "evaluated atomically against the committed bucket state"), so this is parity, not a regression, which is the bar.

**Workers VPC / service binding.** SeaweedFS speaks plain HTTP S3; a VPC service binding to `:8333` works without a tunnel at all, if you prefer to keep the dashboard's data path off the public internet.

### Where it will not plug in

**gRPC is unreachable from Workers.** The filer's `ObjectTransaction`, `DistributedLock`, `SubscribeMetadata`, the admin API and the volume gRPC surface all live on `port+10000`. Workers cannot speak gRPC. So the dashboard can use the S3 HTTP surface **only**. Anything the design wants to express as "atomically mutate this metadata record with a TTL and a server-side callback" has to be rebuilt on top of S3 conditional PUT + GET, with no TTL primitive and no server-side compute. That is the Durable-Objects-shaped hole, and SeaweedFS does not fill it.

**L3 adjacency is assumed, not optional.** Every PUT is at minimum: one filer gRPC for the condition+entry, N volume-server HTTP writes for chunks, one more filer round trip to commit. Every GET is one filer lookup plus one volume fetch. Stretching filers and volume servers across a Cloudflare Mesh with 20–60 ms RTT multiplies all of that. **Do not run one cluster across sites.** Run it on one host or one rack, and let the tunnel be the only WAN hop.

**No bucket notifications, no bucket replication, no inventory/analytics/metrics configs.** All are explicit stubs: `GetBucketNotificationConfigurationHandler` returns an empty config and the comment says "SeaweedFS has no bucket event notifications" (`weed/s3api/s3api_bucket_handlers_misc.go:137-148`); `GetBucketReplicationHandler` returns `ErrReplicationConfigurationNotFound` (`:152-160`); analytics/inventory/intelligent-tiering/metrics return `ErrNoSuchConfiguration` (`weed/s3api/s3api_bucket_config_stubs.go:1-10`); the `Notification` and `Replication` fields are commented out of `BucketMetadata` (`weed/s3api/s3api_bucket_config.go:221-222`). If the design expects "on upload, fire an event into the orchestrator," that event source does not exist here — you would poll `ListObjectsV2` or run a `filer.sync` sidecar.

## Limits and failure modes

**Size and dependency weight.** 3,369 `.go` files, 978,104 lines. `go.sum` is 1,761 lines; `go.mod` has 126 direct + 368 indirect requirements. Release `4.51` linux_amd64 tarball is 47.5 MB; the `_full` variant is 70.2 MB. It is one static binary, which is the redeeming half of this.

**Moving parts.** 8 processes minimum for the reference 3-node, 16+ listening ports, plus a database if you want filer HA. Compare with R2: zero processes.

**What breaks on restart.**
- *Master*: Raft log + snapshot in `-mdir`. `-resumeState` defaults to **true** (`weed/command/master.go:129`), so topology survives. With `-resumeState=false` it wipes `log/`, `conf/`, `snapshot/` and `state/` (`weed/server/raft_server.go:168-180`) and rebuilds from volume heartbeats — which means volume IDs and assignments are re-derived, and any in-flight assignment is lost.
- *Volume server*: rescans `.dat`/`.idx` and rebuilds the in-memory needle map. For a multi-TB server this is minutes of degraded I/O, and `-volume.index=memory` (the default, `weed/command/server.go:150`) means RAM proportional to needle count.
- *Filer*: reopens LevelDB. The per-path lock table and the `ObjectTransaction` replay cache are gone — correctly, they are transient — but that means a filer restart during a conditional-write storm turns in-flight writes into the ambiguous case the code refuses to replay (`weed/s3api/s3api_object_routed_write.go:157-175`). Clients get errors and must retry with a fresh read.
- *S3 gateway*: genuinely stateless. Restart is free.

**The filer is a hard dependency for every operation.** No filer, no S3 — including GETs, because the chunk id comes from the metadata. One filer + LevelDB is a single point of failure for the whole bucket namespace. This is the single biggest architectural risk for a 3-node deployment and the reason I would insist on Postgres or Redis behind it.

**S3 authentication is OFF by default.** With no `-config` file and no identities, `isAuthEnabled = false` and the log line is literally *"S3 authentication disabled - no credentials configured (allowing all access)"* (`weed/s3api/auth_credentials.go:419-437`). `Auth` then short-circuits: `if !iam.isEnabled() { f(w, r); return }` (`:1678-1684`). Point a `cloudflared` ingress at `:8333` without an `s3.json` and you have published an unauthenticated read-write object store. To their credit, the logic is defensive in the other direction — a config file that parses to zero identities **denies everyone** rather than falling open — but the no-file case is a live grenade for exactly this deployment.

**Erasure coding is not self-healing in OSS.** Fixed 10+4, and `ec.rebuild` is a manual dry-run-then-`-apply` shell command. Automatic EC repair, EC vacuum, and EC bitrot scrub are Enterprise. If you lose a shard at 3 a.m. in the OSS build, you are running a command from memory. For an R2 replacement — where the whole value proposition is "durable without me" — this is the sharpest gap.

**Listing scales with directory fanout, not keyspace size.** `ListObjectsV2` streams from the filer per-directory with `Limit: maxKeys+2` (`weed/s3api/s3api_object_handlers_list.go:1225-1233`). Worse, the per-directory cap is inconsistent between launch modes: `-filer.dirListLimit` defaults to **1000** under `weed server` (`weed/command/server.go:129`) but **100000** under `weed filer` (`weed/command/filer.go:136`). A bucket with 50k keys under one prefix will silently truncate on a `weed server` deployment.

**Telemetry is on by default.** `-telemetry=true`, posting to `https://telemetry.seaweedfs.com/api/collect` every 24 h (`weed/command/master.go:134-135`, `weed/server/master_server.go:222-231`). Payload is version, GOOS/GOARCH, volume-server count, total disk bytes, volume count, filer count, broker count, timestamp, topology id (`weed/telemetry/collector.go:114-140`). It is gated behind 10 GiB stored (`telemetry/proto/floor.go:7`), so a small cluster never reports — but this is a self-hosted stack and the default should be off.

**Open reliability issues that are not cosmetic.** #6121 "Freed volumes are lost after restart and recurrent inconsistent state of volume services (LookupFileId)" — open since 2024-10-14, 32 comments, on a 15-node 200 TB-per-node deployment. #8908 "S3 API: Docker Registry blob finalization fails silently, resulting in corrupted/missing blobs" — open since 2026-04-03, 32 comments. Both are exactly the failure classes that matter for a CI artifact store. The tracker carries 638 open issues plus 72 open PRs.

**Churn.** 500 commits between 2026-10-04 and 2026-10-29 — 20/day. The S3 lifecycle subsystem was redesigned wholesale during 2026 (`S3_LIFECYCLE_REDESIGN.md` at repo root still describes the old broken state; the new `weed/s3api/s3lifecycle/{engine,scheduler,dispatcher,shard,dailyrun}` packages have since landed). Behaviour moves. Pin a release, read the diff before bumping, and expect to re-test your conditional-write assumptions on each upgrade.

## Licence and governance

**Apache-2.0**, confirmed from both `LICENSE` in the tree and the GitHub API (`"spdx_id": "Apache-2.0"`). No licence trap: no BSL, no SSPL, no field-of-use restriction, no CLA or DCO file in the tree, no `CONTRIBUTING.md`. You can fork it and you can sell a service on it.

The trap is **open-core, not licence**. The Enterprise comparison page gates, among others: Data Recovery, Point-in-Time Recovery, Self-Healing Storage Format, **Customizable EC Ratio**, **Automatic EC Shard Repair**, **Automatic EC Volume Vacuum**, **EC Bitrot Scrub**, Admin UI OIDC, Admin Audit Log, zstd compression, Sealed Directories, S3-over-RDMA. The boundary is drawn straight through the durability and operability features. Every one of those is something an R2 replacement is expected to have for free.

Pricing is genuinely cheap: **$2/TB/month or $20/TB/year**, free for dev/test under 25 TB. At 25 TB that is $50/month — less than R2's $375/month at $0.015/GB-month for the same bytes. So the enterprise tier is not a pricing trap; it is a "you will eventually want to pay" path. Budget for it if you intend to rely on EC.

The vendor states that on licence expiry SeaweedFS "will automatically fall back to the open source implementation. Your data remains accessible, but the self-healing features will be disabled." Read that as: the durability posture is licence-coupled.

**Bus factor is the real governance risk.** Of the last 500 commits, 271 (54.2%) are `chrislusf`; `dependabot[bot]` 48 (9.6%), `github-actions[bot]` 29 (5.8%). Excluding bots, roughly **64% of human commits are one person**. Total contributors is 650 (last page of the contributors API), but the tail is very thin — the next human is at 5.0%, then 3.8%, then a long flat line. 35,799 stars, 3,096 forks, created 2014-07-14, actively pushed today. This is a healthy, alive, single-maintainer-led project — not an abandoned one — but it is one person's project, and the commit rate means the codebase is not being reviewed at the depth its complexity implies.

**Security support policy** is latest-release-only: "Security fixes land in the latest release… issues that only reproduce on old, unsupported versions are not eligible for a fix or an advisory" (`SECURITY.md:1-7`). No LTS. You must track releases. Given 20 commits/day and this policy, "pin and forget" is not available.

## Verified facts

| claim | value | source |
|---|---|---|
| Licence | Apache-2.0 | `LICENSE` in tree; GitHub API `license.spdx_id` = `Apache-2.0` — VERIFIED |
| Latest release | `4.51`, published 2026-10-25 | `forge.web.pkgforge.dev/github/repos/seaweedfs/seaweedfs/releases/latest` — VERIFIED |
| Binary size (linux/amd64) | 47.5 MB tar.gz; `_full` 70.2 MB | same release asset list — VERIFIED |
| Stars / forks / open issues | 35,799 / 3,096 / 710 (638 issues + 72 PRs) | GitHub repo API + GitHub search API — VERIFIED |
| Contributors | 650 (last page of paginated contributors API) | GitHub contributors API `Link: rel="last"` — VERIFIED |
| Commit concentration | 271/500 (54.2%) by `chrislusf`, 2026-10-04→2026-10-29 | GitHub commits API, 5 pages × 100 — VERIFIED |
| Commit velocity | 500 commits / 25 days ≈ 20/day | same sample — VERIFIED |
| Go source size | 3,369 files, 978,104 lines | `find`/`wc` on clone — VERIFIED |
| S3 layer size | 218 non-test files, 88,320 lines, 361 test files | `find`/`wc` on `weed/s3api` — VERIFIED |
| Dependency count | 126 direct + 368 indirect; `go.sum` 1,761 lines | `go.mod` / `go.sum` — VERIFIED |
| Go toolchain | `go 1.26.6` | `go.mod:3` — VERIFIED |
| EC ratio in OSS | fixed 10+4; "Open-source SeaweedFS always uses the fixed 10+4 layout" | `weed/storage/erasure_coding/ec_encoder.go:21-24`, `ec_shards_info.go:129-142` — VERIFIED |
| EC rebuild is manual | `-apply` required; "default is dry-run mode" | `weed/shell/command_ec_rebuild.go:34-40` — VERIFIED |
| Default filer store | `leveldb2` in a local dir | `weed/server/filer_server.go:282-283` — VERIFIED |
| Filer store backends compiled in | 20 blank-imported + RocksDB/FoundationDB behind build tags | `weed/command/imports.go:21-44`; `weed/filer/rocksdb/rocksdb_store.go:1`; `weed/filer/foundationdb/foundationdb_store.go:1` — VERIFIED |
| Default ports | master 9333, filer 8888, volume 8080, s3 8333, iceberg 8181, lance 9101 | `weed/command/server.go:98,121,146,177,180,181` — VERIFIED |
| gRPC port rule | HTTP port + 10000 | `weed/command/master.go:212`, `filer.go:379`, `volume.go:417`, `s3.go:367` — VERIFIED |
| Default volume size limit | 30 GiB | `weed/util/volume_size.go:7` — VERIFIED |
| Default chunk size | 4 MiB (`filer.maxMB`); S3 defaults to 8 MiB if filer reports none | `weed/command/server.go:128`; `weed/s3api/s3api_object_handlers_put.go:500-514` — VERIFIED |
| Write durability | fsync batched at 1 MiB / 128 reqs / 500 µs | `weed/storage/volume_write.go:679-683` — VERIFIED |
| Telemetry | ON by default, `telemetry.seaweedfs.com`, 24 h, 10 GiB floor | `weed/command/master.go:134-135`; `weed/telemetry/proto/floor.go:7` — VERIFIED |
| S3 auth default | disabled (allow-all) when no config file and no identities | `weed/s3api/auth_credentials.go:419-437,1678-1684` — VERIFIED |
| List cap inconsistency | 1000 (`weed server`) vs 100000 (`weed filer`) | `weed/command/server.go:129`; `weed/command/filer.go:136` — VERIFIED |
| No bucket notifications | handler returns empty config; "SeaweedFS has no bucket event notifications" | `weed/s3api/s3api_bucket_handlers_misc.go:137-148` — VERIFIED |
| No bucket replication config | returns `ErrReplicationConfigurationNotFound` | `weed/s3api/s3api_bucket_handlers_misc.go:152-160` — VERIFIED |
| S3 ops count | 73 bucket/object, 36 S3 Tables | `README.md:205-212` — VERIFIED (vendor claim) |
| Enterprise price | $2/TB/month, $20/TB/year; free dev/test under 25 TB | `seaweedfs.com/pricing/` — VERIFIED |
| Enterprise-gated features | data recovery, PITR, self-healing format, custom EC ratio, auto EC repair, EC vacuum, EC bitrot scrub, admin OIDC, audit log, zstd, sealed dirs, S3-over-RDMA | `seaweedfs.com/docs/comparison/` — VERIFIED |
| R2 pricing (comparison) | $0.015/GB-month standard; $4.50/M Class A; $0.36/M Class B; egress free; 10 GB free tier | `developers.cloudflare.com/r2/pricing/` — VERIFIED |
| R2 conditional writes | evaluated atomically against committed state; at most one `If-None-Match: *` wins, others 412 | `developers.cloudflare.com/r2/api/s3/api/` — VERIFIED |
| Workers request body cap | 100 MB Free/Pro, 200 MB Business, up to 5 GB Enterprise self-serve | `developers.cloudflare.com/workers/platform/limits/` — VERIFIED |
| MinIO ceased development | "as Apr 25, 2026 MinIO ceased development" | `README.md` "Compared to MinIO, RustFS" — VERIFIED as a vendor claim; NOT independently checked |
| Security support | latest release only, no LTS | `SECURITY.md:1-7` — VERIFIED |

## Rejected / not for this

- **Not a Durable Objects replacement.** No single-threaded actor, no WebSocket hibernation, no server-side compute, no per-object TTL. The conditional-write mechanism is a *coordination primitive*, not a runtime. The dashboard can use it for CAS on state objects; it cannot host logic there.
- **Not for a multi-tenant, self-serve object store.** One filer namespace, one bucket tree, quotas per bucket but no per-tenant rate limits or hard isolation. Bucket policies and ACLs exist and are real, but the operational model is "one team's cluster," not "a platform."
- **Not for millions of small objects.** The metadata store becomes the bottleneck before the disks do. The paid fix is Sealed Directories. If the CI workload is 40-byte pointer files at 10M scale, this is the wrong product.
- **Rejected: "three `weed server` processes = 3-node HA."** Each would carry its own LevelDB filer and the namespaces would diverge silently. If you want HA you need an external metadata store; if you do not, accept one filer as a SPOF and say so out loud.
- **Rejected: EC as the durability story in OSS.** Fixed 10+4 with manual repair is not a substitute for replication you can forget about. Either use `replication=001` and pay 2×, or budget for Enterprise and get automatic repair.
- **Rejected: stretching a cluster across the Cloudflare mesh.** The metadata path is 2+ RPCs per write; WAN RTT makes it unusable. One site, one tunnel.

## Open questions

1. **Do you already run Postgres or Redis?** This single answer decides whether the filer can be HA at zero marginal cost or whether the "3-node" cluster has a hard metadata SPOF.
2. **What is the object-size distribution?** Large blobs (image layers, checkpoints) suit SeaweedFS well. A long tail of sub-100 KB artifacts pushes on the filer and argues for a different product.
3. **How much data, and for how long?** Crossing 25 TB moves you from "free enterprise for dev" to a paid licence — and the paid tier is where EC repair and vacuum live, which is where the durability story actually is.
4. **Who owns patching?** Latest-release-only support plus 20 commits/day means someone has to read release notes monthly. If the answer is "nobody," the correct choice is to keep paying R2.
5. **Does the CI system actually need cross-object atomicity, or only `If-None-Match: *`?** The former is where SeaweedFS's `ObjectTransaction` shines and where every alternative falls over; the latter is table stakes. If you only need the latter, the field widens considerably and you should re-run this comparison.
6. **Will the dashboard ever need bucket events?** There is no notification surface. If "on upload, tell the orchestrator" is a requirement, it has to be built as a poller or a `filer.sync` consumer, and that is a component this review has not scoped.
