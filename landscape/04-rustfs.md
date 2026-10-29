# RustFS — deep review

## Verdict

**Yes — put it in the R2 slot, but as a tier-2 store, not the system of record, and only for objects you can write in ≤100 MB chunks.** RustFS is the only serious Apache-2.0 answer to a question that got much louder this year: MinIO's repo was archived on 2026-04-25 and has not shipped since 2025-10-15, so the "MinIO-shaped hedge" is no longer a hedge, it is a vacancy. RustFS fills it with a real Reed–Solomon erasure-coded engine, ~78 S3 trait methods, and genuinely exceptional operator documentation. But it went 1.0 on 2026-09-16 — six weeks ago — and the data path still has open P1 bugs (scanner OOM on a single disk, heal failures, multipart 5xx) plus a silent-data-corruption fix sitting in `Unreleased`. The conditional-write story is the decisive one for celld: `If-None-Match: *` and `If-Match: *` work, **etag-specific conditional writes return 501 NotImplemented**, so RustFS can back create-if-absent leases but cannot back read-modify-write CAS. And your hard constraint — Cloudflare Tunnel — is the exact topology where RustFS's own docs tell you to turn the proxy off.

## What it actually is

A Rust reimplementation of MinIO's architecture, and the code says so itself in several places (see Licence). Not a from-scratch object store: a port of MinIO's Go codebase to Rust, shipping MinIO's on-disk format (`xl.meta`, `rs-vandermonde`, HighwayHash256S bitrot) with the metadata bucket renamed from `.minio.sys` to `.rustfs.sys`.

Scale: 53 workspace crates, 1,622 `.rs` files, **1,344,269 lines of Rust** under `crates/`, 22,182 `#[test]`/`#[tokio::test]` functions, 61 GitHub workflow files. `Cargo.lock` pins **1,020 unique crates**; the main binary crate declares 118 direct dependencies. The released musl binary is **276,241,344 bytes (276 MB), static-pie, stripped** — the zip is 97.2 MB.

The README claims "broad S3 API compatibility", "no telemetry", and "avoiding the restrictions of AGPL". All three need asterisks, addressed below. What the README understates is the documentation: `docs/architecture/erasure-coding.md` is a normative spec with invariant checklists and a change procedure, and `docs/operations/reverse-proxy.md` documents its own Cloudflare failure modes by issue number. That is not the behaviour of a hobby project.

## Architecture (with file paths)

**S3 front end is not theirs.** The protocol layer is the `s3s` crate, pinned to a **git revision** of `s3s-project/s3s`, not crates.io (`Cargo.toml:327-328`, rev `5761ddfe4c509fcac87e3b99fd5bd9e176b442c0`, `features = ["minio"]`). So S3 conformance is bounded by `s3s` plus RustFS's overrides. The handler is `impl S3 for FS` at `rustfs/src/storage/ecfs.rs:540` with **78 `async fn` methods** — near-complete, but each is a thin delegate into `rustfs/src/app/`.

**Layering** (from `ARCHITECTURE.md`, which is honest enough to mark its own violated invariants with ⚠️):
`server/` → `admin/` + `app/` → `storage/ecfs.rs` → `crates/ecstore` → `crates/rio` → `crates/io-core`. Object ops live in `rustfs/src/app/object/{put,get,copy,delete,head}.rs`; the shared precondition logic is `rustfs/src/app/object/shared.rs`.

**Erasure coding is real.** `crates/ecstore/src/erasure/coding/erasure.rs` — Reed–Solomon, MDS, GF(2⁸) via `rustfs-erasure-codec` 9.0.0 (a fork of `reed-solomon-erasure` v8, `Cargo.toml:318`), with a legacy GF(2¹⁶) path on `reed-solomon-simd` 3.1.0 purely to read RustFS's own older format. 1 MiB blocks, HighwayHash-256S interleaved bitrot. Geometry: `SET_SIZES = 2..=16` drives per set; single-drive is a separate `N=1, parity=0` path (`is_single_drive_layout`). Default parity, `crates/ecstore/src/config/storageclass.rs:24-32`:

```rust
1 => 0,  2|3 => 1,  4|5 => 2,  6|7 => 3,  _ => 4
```

So 8 drives → EC:4 (4 data + 4 parity, 50% overhead); 4 drives → EC:2 (50% overhead). `parity ≤ N/2` is enforced, but the doc admits `validate_parity_inner` only applies that bound for `N > 2`, so `EC:2` on `N=2` yields `data_blocks = 0`.

**Two ports, not four.** `crates/config/src/constants/app.rs:279,287`: 9000 = S3 API **and** admin API **and** inter-node gRPC (`TONIC_RPC_PREFIX = "/node_service.NodeService"`, `crates/ecstore/src/cluster/rpc/http_auth.rs:99`, multiplexed on the same listener); 9001 = web console. That is a genuinely small moving-part count.

## The seam into this design

**Where it plugs in:** a single `rustfs server /data` process on each storage machine, S3 on `:9000`, reachable from Workers over Workers VPC / Mesh as plain HTTP, and from CI runners over a `cloudflared` tunnel. No database, no etcd, no external coordinator — state is the disk. That is the right shape for your design, and it is why it beats Ceph or SeaweedFS here.

**Where it will not plug in — two hard seams.**

1. **The 100 MB body cap is unavoidable on a Tunnel.** Cloudflare's request body limit is plan-based: Free 100 MB, Pro 100 MB, Business 200 MB, Enterprise up to 5 GB (`https://developers.cloudflare.com/workers/platform/limits/`). With a *tunnel* you cannot fall back to grey-cloud DNS — the community answer is explicit that "when using a tunnel, it's not possible to use DNS-only mode, which results in a 100MB limit." RustFS's own mitigation, in `docs/operations/reverse-proxy.md:104`, is: *"For large object writes prefer DNS-only (grey cloud) for the S3 endpoint, or a plan/tunnel configuration that does not buffer or re-chunk the body."* **That advice is unavailable to you by construction.** Consequence: every single-shot `PutObject` >100 MB returns 413. CI artifacts, container image layers and long-run logs must go through multipart with parts ≤100 MB. RustFS supports that (`upload_part` at `ecfs.rs:2103`), but it is a client-side contract you must enforce, and it means no `mc cp` of a 2 GB tarball will "just work".

2. **`Accept-Encoding` rewriting breaks SigV4.** `docs/operations/reverse-proxy.md:127` lists it as a known signature: *"SigV4 `SignatureDoesNotMatch` on Cloudflare tunnel — `Accept-Encoding` header rewritten — #1492"*. Issue #1492 (closed 2026-01-24) shows Cloudflare rewriting a client's `Accept-Encoding: identity` into `gzip, br`; because rclone signs that header, every request 403s. Cloudflare Request Header Transform rules and Compression Rules both failed to fix it in the reporter's testing. The resolution was **client-side**: `s3s` maintainer Nugine in `s3s-project/s3s#458` — *"rclone signs `Accept-Encoding` which is always rewritten by Cloudflare Tunnel. `--s3-sign-accept-encoding false` works."* AWS SDKs do not sign it by default, so this is survivable, but it is a documented landmine for exactly your topology. Also #934: the console fails behind a Tunnel because chunked re-encoding drops `Content-Length`.

## Limits and failure modes

**Conditional writes — the answer for celld.** `rustfs/src/app/object/shared.rs:1137-1153`:

```rust
pub(crate) fn reject_non_wildcard_write_if_none_match(
    if_none_match: Option<&s3s::dto::ETagCondition>, headers: &HeaderMap,
) -> S3Result<()> {
    if matches!(if_none_match, Some(s3s::dto::ETagCondition::ETag(_))) || /* header not exactly "*" */ {
        return Err(S3Error::new(S3ErrorCode::NotImplemented));
    }
    Ok(())
}
```

So on PUT: `If-None-Match: *` → works (412 if present, 200 if absent). `If-Match: *` → works. **`If-None-Match: "<etag>"` and `If-Match: "<etag>"` → 501 NotImplemented.** The project then *patched the upstream conformance suite* to accept this: `scripts/s3-tests/patches/0006-conditional-write-wildcard-contract.patch` rewrites `test_put_object_if_match` and friends to assert `(501, 'NotImplemented')` where ceph s3-tests asserts `412 PreconditionFailed` / `200`. That is transparent, but it is a real capability gap.

**Verdict for celld: it can use RustFS as its bucket for create-if-absent (acquire-if-absent lease objects, `If-None-Match: *`), but not for read-modify-write CAS on an existing key.** If celld's lease/leader protocol needs "update this object only if it is still at version X", RustFS cannot do it and you must not paper over it — a 501 must be handled as "no CAS available", not retried. Note `DeleteObjects` *does* support per-object ETag conditions (`docs/architecture/s3-compatibility-matrix.md`, "Conditional Bulk Deletion"), which is inconsistent and will confuse you.

**S3 coverage, quantified.** `scripts/s3-tests/` against ceph s3-tests: **460 implemented, 274 excluded, 21 unimplemented**. The 274 exclusions are not all junk: 106 are bucket logging, 42 ACL, 35 other, 22 delete, 17 lifecycle, 11 multipart, 9 policy, 6 cors. Explicitly not implemented (`unimplemented_tests.txt`): **bucket access logging** (handlers exist at `ecfs.rs:1446,1465` but do not pass), **POST Object form-upload checksums**, **bucket ownership controls** (no handler). Stubs: `get_object_torrent` returns `NoSuchKey` rather than 501 (`ecfs.rs:1308-1314`); `put_bucket_accelerate_configuration` and `put_object_acl` XML-grant bodies return `NotImplemented` (`ecfs.rs:1405`, `ecfs.rs:1633`). **ACL authorization is intentionally unsupported** — canned ACLs only, XML grants refused. Any client that depends on ACLs (rather than bucket policy/IAM) breaks.

**Current open defects (all open as of 2026-10-29, labels `S-confirming`/`S-reproducing`):**
- **#8961 — scanner OOMs on a single disk.** Single node, one disk, ~2M small objects, 4 GiB container limit → OOM-killed hundreds of times. Reporter traced it to `scanner_folder.rs` skipping root compaction until 250k folders. Baseline RSS without the scanner: **~250 MiB**; with it, 0.28 → 1.85 → 2.61 GiB and climbing. This is precisely a small self-hosted deployment.
- **#8992** — the 1.0.x image moved to non-root uid `10001`; every write to a pre-existing root-owned volume fails after upgrade.
- **#8957** — EC:4 pool stays unavailable after 4 of 8 offline drives return.
- **#8843** — large GETs fail with `internode body stalled for 5s`.
- **#8822** — Create/AbortMultipartUpload return 5xx.
- **#8771** — multipart with a bad ETag returns 500 instead of 400.
- **#8742** — DELETE on an object with a delete marker errors.
- **#8645** — "Heal erasure set failed".

Plus, in `CHANGELOG.md` under `[Unreleased]`: **"Restore of encrypted or compressed multipart objects (silent data corruption)"** — restore reported success while writing misaligned slices, and *"this release does not detect or repair them retroactively"*; and per-pool parity resolving to zero data shards, *"panicking Reed-Solomon construction on write"* (#4801). Two GHSAs (`GHSA-xm99-m3gq-83g8`, `GHSA-g8w9-qw9q-fghr`) were unsigned-`x-amz-*`-header privilege escalations. The bugs are being found and fixed fast — that is the good news — but they are still being found in the write path at 1.0.4.

**Operational limits you must plan for:**
- **No network filesystems.** `rustfs/src/startup_fs_guard.rs:57-66` rejects `nfs, cifs, smb2, fuse, fuseblk, overlayfs, 9p, v9fs, ceph, glusterfs, gfs, gfs2`. Default policy is `warn` (`RUSTFS_UNSUPPORTED_FS_POLICY`), so it will *start* on a bad FS and misbehave later. This kills NFS-backed PVs, rclone-mounts, s3fs, JuiceFS, and writing into a container's overlay layer.
- **512 file descriptors per disk.** `FD_CACHE_CAPACITY: u64 = 512` (`crates/ecstore/src/disk/local.rs:4595`). I hit this immediately on a real run: `"std fd cache disabled: RLIMIT_NOFILE soft limit too low for 512 fds/disk; using open-per-read"` — it degrades gracefully but silently costs read performance. Raise `LimitNOFILE` to ≥4096 for any multi-drive node.
- **Layout is frozen at first start.** `crates/ecstore/src/error/mod.rs:249`: a single-node-single-drive deployment *cannot be expanded in place* — "restart with the original single local path, or create a new multi-drive deployment and migrate data through S3". Endpoint order, set width and disk UUID positions are persisted; `format.json` must not be deleted to escape `PoolTopologyMismatch`.
- **Only the latest patch is supported.** `SECURITY.md`: supported versions = `Latest`; `< 1.0` = ✗. No LTS, no backports. With 4 patch releases in 5 weeks you are on a treadmill.
- **Maintainability:** `crates/ecstore/src/core/pools.rs` is **41,995 lines**; `crates/ecstore/src/disk/local.rs` 32,406; `crates/ecstore/src/set_disk/ops/object.rs` 28,154. That is not a codebase you patch yourself.
- **Supply chain:** 4 git dependencies pinned by rev — `s3s` ×2 (`Cargo.toml:327-328`), `openidconnect`, `oauth2` (`Cargo.toml:428-433`), plus a local `zstd` patch. A force-push or repo deletion upstream breaks your build.

## Licence and governance

**Outbound: Apache-2.0, clean.** Plain Apache text, `Copyright 2024-2026 RustFS, Inc.`, no added terms, no field-of-use restriction, no BSL clock. `rustfs.com/pricing` states "Self-host RustFS under Apache 2.0 with no license fee" and sells only optional support, with no published prices or SLAs. That is the real thing, and it is the entire reason to prefer it over AGPL MinIO.

**The entitlement gate exists but is off.** `rustfs/src/license.rs` and `crates/license/src/lib.rs` implement a `SERVER_ENTITLEMENT = "rustfs.server"` check behind a cargo feature `license` (`rustfs/Cargo.toml` `[features]`, `license = []`). In a default build `cfg!(feature = "license")` is false, `OpenSourceLicenseProvider` accepts a missing licence (test `open_source_provider_accepts_missing_license`, `rustfs/src/license.rs:~396`), and a real 1.0.4 binary logs `"license_status":"uninitialized"` at startup. So **today the OSS binary is not gated** — but the mechanism for gating it, and an OEM path for third parties to own entitlement decisions, is already in-tree. Treat that as a documented future option, not a present trap.

**Inbound: a CLA that permits relicensing.** `CLA.md` §2 grants RustFS, Inc. a licence to distribute your contribution *"under any license, including proprietary or commercial licenses … at RustFS's sole discretion."* This is the standard open-core ratchet. Apache-2.0 on already-published releases is irrevocable, so a future rug-pull can only affect *new* versions — meaning you should **mirror and pin a specific release tarball + checksum**, not track `latest`.

**The MinIO problem — this is the one to flag loudly.** The README says Apache-2.0 means "no 'poison pill' clauses" and "clear IP rights … no intellectual property ambiguity". The repository's own words contradict that:
- `scripts/s3-tests/S3_COMPAT_WORKFLOW.md:54`: *"This is critical because **RustFS was ported from MinIO's Go code to Rust**."*
- `crates/ecstore/src/erasure/coding/bitrot.rs:606`: *"This is a **byte-for-byte port** of MinIO's `bitrotShardFileSize`…"*
- `crates/checksums/src/lib.rs:48`: *"The **MinIO-port** client's `ChecksumMode`"*
- Dozens of `reason = "MinIO-parity surface … in this port (backlog#1823)"` annotations, e.g. `crates/ecstore/src/bucket/lifecycle/bucket_lifecycle_ops.rs:132`.
- 2,597 occurrences of "minio" in `.rs` files; `docs/` cites MinIO Go source line-by-line at pinned commit `7aac2a2`.

MinIO is **AGPL-3.0** (verified: GitHub licence API, `spdx_id: AGPL-3.0`). A line-by-line translation of AGPL Go into Rust is, on the ordinary understanding, a derivative work, and AGPL-3.0 does not permit relicensing the result as Apache-2.0. RustFS, Inc. asserts Apache-2.0 anyway. **I am not a lawyer and this is not legal advice**, but the risk is asymmetric: it lands on whoever deploys the code, and it is precisely the risk the README claims to have solved. If this ever matters to you commercially, get counsel before it is load-bearing. For a lab/internal deployment, it is a footnote.

**Telemetry: the claim is technically true and rhetorically misleading.** `rustfs/src/connect/` contains `telemetry.rs`, `heartbeat.rs`, `registration.rs`, `inventory.rs`, `report_upload.rs`, `license_relay.rs` — a complete device-enrolment, heartbeat and remote-diagnostics uplink. It is **default-off**: `connect/mod.rs` states *"An unconfigured server starts no Connect task, generates no key, and holds no Connect identity"*, and `HeartbeatConfig::from_env()` returns `Option`. So "No Telemetry" holds for a default install. But the machinery is compiled into every 276 MB binary you ship, and the README's "No Telemetry / Full Compliance … GDPR, CCPA, APPI" row is marketing, not architecture.

## Verified facts

| claim | value | source |
|---|---|---|
| Licence (outbound) | Apache-2.0, plain text, `Copyright 2024-2026 RustFS, Inc.` | `/workspace/.clones/rustfs/LICENSE`; https://github.com/rustfs/rustfs/blob/main/LICENSE |
| GitHub licence metadata | `spdx_id: Apache-2.0` | https://api.github.com/repos/rustfs/rustfs |
| Stars / forks | 35,525 / 1,630 | https://api.github.com/repos/rustfs/rustfs |
| `open_issues_count` | 66 (issues **+ PRs**); direct enumeration found 26 open non-PR issues + 14 open PRs | https://api.github.com/repos/rustfs/rustfs , `/issues?state=open`, `/pulls?state=open` |
| Repo created / last push | 2023-11-23 / 2026-10-29 | https://api.github.com/repos/rustfs/rustfs |
| Total releases | 125 since `1.0.0-alpha.1` (2025-07-02) | https://api.github.com/repos/rustfs/rustfs/releases |
| Stable releases | 5: 1.0.0 (2026-09-16), 1.0.1 (2026-10-03), 1.0.2 (2026-10-16), 1.0.3 (2026-10-17), 1.0.4 (2026-10-25) | same |
| Workspace crates | 53 | `Cargo.toml` `[workspace] members` |
| Rust LOC under `crates/` | 1,344,269 across 1,622 files | `find crates -name '*.rs'` |
| Test functions | 22,182 `#[test]` + `#[tokio::test]` | `grep -rn` over repo |
| CI workflows | 61 files in `.github/workflows/` | directory listing |
| Unique crates in `Cargo.lock` | 1,020 | `Cargo.lock` parse |
| Direct deps, main crate | 118 | `rustfs/Cargo.toml` `[dependencies]` |
| Release binary size | 276,241,344 B (276 MB) musl static-pie stripped; zip 97.2 MB | release asset + `file` on downloaded binary |
| S3 trait methods implemented | 78 `async fn` in `impl S3 for FS` | `rustfs/src/storage/ecfs.rs:540` |
| Conditional writes | etag-based `If-None-Match`/`If-Match` on PUT → **501 NotImplemented**; only `*` works | `rustfs/src/app/object/shared.rs:1137-1153`; `scripts/s3-tests/patches/0006-conditional-write-wildcard-contract.patch` |
| Conditional DELETE | per-object ETag supported (`*` and specific ETag) | `docs/architecture/s3-compatibility-matrix.md` |
| ceph s3-tests coverage | 460 implemented / 274 excluded / 21 unimplemented | `scripts/s3-tests/{implemented,excluded,unimplemented}_tests.txt` |
| Unimplemented standard S3 | bucket access logging, POST-object checksum, bucket ownership controls | `scripts/s3-tests/unimplemented_tests.txt` |
| ACL support | canned ACLs only; XML grant bodies → NotImplemented | `docs/architecture/minio-rustfs-router-compatibility.md:29`; `ecfs.rs:1633` |
| Erasure coding | Reed–Solomon MDS, GF(2⁸), `rs-vandermonde`, 1 MiB blocks, HighwayHash256S | `crates/ecstore/src/erasure/coding/erasure.rs`; `docs/architecture/erasure-coding.md` |
| Default parity by drive count | 1→0, 2-3→1, 4-5→2, 6-7→3, ≥8→4 | `crates/ecstore/src/config/storageclass.rs:24-32` |
| Max drives per erasure set | 16 (`SET_SIZES = 2..=16`) | `docs/architecture/erasure-coding.md` §2.1 |
| SNSD in-place expansion | unsupported | `crates/ecstore/src/error/mod.rs:249` |
| Ports | 9000 = S3 + admin + internode gRPC; 9001 = console | `crates/config/src/constants/app.rs:279,287`; `crates/ecstore/src/cluster/rpc/http_auth.rs:99` |
| FDs per disk (cache) | 512, degrades to open-per-read under low `RLIMIT_NOFILE` | `crates/ecstore/src/disk/local.rs:4595`; observed at runtime |
| Unsupported filesystems | nfs, cifs, smb2, fuse, fuseblk, overlayfs, 9p, v9fs, ceph, glusterfs, gfs, gfs2 (default `warn`) | `rustfs/src/startup_fs_guard.rs:57-66` |
| Licence feature gate | opt-in cargo feature `license`, **off by default**; OSS provider accepts no licence | `rustfs/src/license.rs`; `rustfs/Cargo.toml [features]` |
| CLA relicense right | yes — "any license, including proprietary or commercial" | `CLA.md` §2 |
| Self-declared MinIO port | "RustFS was ported from MinIO's Go code to Rust" | `scripts/s3-tests/S3_COMPAT_WORKFLOW.md:54` |
| Self-declared byte-for-byte port | "byte-for-byte port of MinIO's `bitrotShardFileSize`" | `crates/ecstore/src/erasure/coding/bitrot.rs:606` |
| MinIO licence | AGPL-3.0 | https://api.github.com/repos/minio/minio |
| MinIO status | **archived**, last push 2026-04-24, last release 2025-10-15 | https://api.github.com/repos/minio/minio ; https://github.com/minio/minio |
| MinIO archive date | 2026-04-25 | https://tuxcare.com/endless-lifecycle-support/minio-eol-support/ ; https://github.com/minio/minio ("archived by the owner on Apr 25, 2026") |
| Cloudflare request body limit | Free 100 MB, Pro 100 MB, Business 200 MB, Enterprise ≤5 GB | https://developers.cloudflare.com/workers/platform/limits/ |
| Tunnel cannot use grey-cloud | yes — "when using a tunnel, it's not possible to use DNS-only mode" | https://community.cloudflare.com/t/100mb-tunnel-limit/901339 |
| SigV4 vs Cloudflare Tunnel | `Accept-Encoding` rewritten → `SignatureDoesNotMatch`; fix is client `--s3-sign-accept-encoding false` | https://github.com/rustfs/rustfs/issues/1492 ; https://github.com/s3s-project/s3s/issues/458 |
| Pricing model | Apache-2.0 free; paid support only; no published prices/SLAs | https://rustfs.com/pricing |
| Supported versions | "Latest" only; `< 1.0` unsupported | `SECURITY.md` |

## Rejected / not for this

- **As a system of record for anything irreplaceable.** 1.0 is six weeks old, there is an unreleased silent-data-corruption fix in the tier-restore path, and #8961 (scanner OOM on a single disk) is a live memory-growth bug on exactly the small deployment you would start with. Keep a second copy.
- **As a CAS primitive for celld.** Etag conditional writes return 501. If celld's design assumes S3 conditional writes for fencing, either redesign around `If-None-Match: *` create-if-absent, or keep Durable Objects / a real coordinator for that one job.
- **As a large-object ingress behind Cloudflare Tunnel.** >100 MB single PUT is impossible; you must force multipart with ≤100 MB parts, or route bulk writes over Workers VPC/Tailscale instead of the Tunnel.
- **As an NFS/SMB/FUSE-backed volume.** Hard-refused by `startup_fs_guard.rs`, and warn-only by default so you will not notice until writes corrupt.
- **As something you fork and maintain.** 42k-line `pools.rs`, 4 git-pinned dependencies, 1,020 transitive crates. Consume releases, do not patch.
- **For ACL-based multi-tenancy.** Canned ACLs only; XML grants are 501.
- **Bucket access logging.** Handlers exist, tests do not pass. If you need server access logs, you need a different mechanism.
- **Not evaluated / out of scope:** S3 Tables (Iceberg REST, `🧪 Preview`), Swift/SFTP/FTPS protocols, site replication, KMS backends (Vault/AWS), Connect. None of these are needed for the R2 slot.

## Open questions

1. **Does the MinIO port create a derivative-work problem?** The project says Apache-2.0 and simultaneously says it was ported from AGPL Go. Which is it, and has anyone with standing asked? This is the single question that could invalidate the whole choice, and it is unanswerable from source alone.
2. **Will `license` ever be turned on in a published build?** The gate is in-tree and off. What is the commitment — a written statement that `rustfs/rustfs` releases stay ungated, or nothing?
3. **How does the scanner behave at 1–2 M objects on a single disk after #8961?** The reporter measured ~250 MiB idle / 2.6 GiB+ with scanner on. Is there a config that bounds it (`scanner.cycle_max_directories`), and does the fix hold at 10 M objects?
4. **What is the real fix for the 100 MB Tunnel cap?** Is there any path where RustFS accepts a chunked/streamed PUT that Cloudflare will forward without re-framing, or is multipart the only answer? `docs/operations/reverse-proxy.md` implies the latter.
5. **Upgrade treadmill cost.** Four patch releases in five weeks with a breaking uid change (#8992) and no LTS. What is the actual cadence for a self-hoster, and does `1.0.x` accept in-place upgrades across every patch? `CHANGELOG.md` carries only `[Unreleased]`, so there is no per-version upgrade note to read.
6. **Bus factor.** Top three contributors hold 5,095 of 7,353 commits (69%) across the top 100. `overtrue` alone has 2,731. What happens if the company pivots to the paid tier, as MinIO did?
