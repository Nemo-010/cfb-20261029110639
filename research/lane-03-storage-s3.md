# Lane 03 — S3-compatible object storage to replace R2

Researched 2026-10-29. All prices, versions, licences and star counts below were fetched on that date.

## Verdict

MinIO is no longer a candidate and that is the single most important finding in this lane: the
`minio/minio` repository is **archived**, its README says "THIS REPOSITORY IS NO LONGER
MAINTAINED", and community builds are source-only with no binaries since October 2025. The
replacement, AIStor Free, is a **proprietary** licence that grants use "solely in standalone mode
(single-node deployments without distributed clustering or high availability)" — so the only legal
path to a multi-node MinIO is a paid Enterprise Lite subscription, which is exactly the thing the
study is trying to avoid.

Of the genuinely open options, **SeaweedFS** is the best default for this project: Apache-2.0, the
broadest S3 surface of any OSS candidate (73 bucket/object operations plus IAM and STS on one
endpoint), single binary, actively released (4.51 on 2026-10-25). Its cost is operational: master +
volume servers + filer + a separate filer metadata database + stateless S3 gateways, and erasure
coding runs **asynchronously on warm data**, so you must actually run the EC and repair jobs or you
are silently paying 3x for replication.

**RustFS** is the closest drop-in for MinIO's shape and licence (Apache-2.0, 1.0.4 on 2026-10-25)
and is the obvious hedge, but it reached GA only in September 2026 after open-sourcing in July 2025
— there is no multi-year production track record. **Garage** is by far the easiest to operate and
the right answer for a small number of nodes, but it deliberately has no erasure coding, no bucket
versioning and no ACLs/policies. **Ceph RGW** is the only candidate with a decade of production
proof and near-complete S3 coverage, and it is also the only one whose own docs say a single-host
cluster is "generally not suitable for production". **VersityGW** is a translation gateway, not a
store — it adds no redundancy of its own. **Zenko CloudServer** positions itself as a CI S3
emulator. **JuiceFS** is a POSIX filesystem that *consumes* an object store, not a replacement for
one.

The caveat that matters more than any feature table: none of this reproduces R2's actual advantage,
which is zero egress fees and zero operators. Self-hosting S3 buys you capacity economics and data
residency, and costs you a durability engineer.

## Findings

### MinIO: archived, source-only, and the community console was gutted first

The repository state is not ambiguous. `minio/minio` returns `"archived": true`, 61,301 stars,
`pushed_at` 2026-04-24, 78 open issues
(https://forge.web.pkgforge.dev/github/repos/minio/minio). The last actual commit is
2026-02-12T05:53:17Z, "update README.md format and clarify state of the project"
(https://forge.web.pkgforge.dev/github/repos/minio/minio/commits?per_page=5).

The README opens with, verbatim:

> **THIS REPOSITORY IS NO LONGER MAINTAINED.**
> **Alternatives:**
> - **[AIStor Free](https://min.io/download)** — Full-featured, standalone edition for community use (free license)
> - **[AIStor Enterprise](https://min.io/pricing)** — Distributed edition with commercial support

and further down:

> **Important:** The MinIO community edition is now distributed as source code only. We will no
> longer provide pre-compiled binary releases for the community version.

(https://github.com/minio/minio — read via
https://forge.web.pkgforge.dev/github/repos/minio/minio/readme)

The release history confirms the cutover. `RELEASE.2025-10-15T17-29-55Z` is the newest tag and it
has **zero assets**; the last release carrying binaries is `RELEASE.2025-09-07T16-13-09Z`
(linux-amd64 110,989,496 bytes, plus deb/rpm/apk/darwin/windows)
(https://forge.web.pkgforge.dev/github/repos/minio/minio/releases?per_page=2). Anything from
`dl.min.io` is a frozen artefact — the README calls them "Legacy Binary Releases … These legacy
binaries will not receive updates."

The console was degraded before that. `RELEASE.2025-05-24T17-08-30Z` release notes contain the line:

> Embedded UI Console is now deprecated and moved to [object-browser](https://github.com/minio/object-browser)

(https://forge.web.pkgforge.dev/github/repos/minio/minio/releases?per_page=40). Note that
`https://github.com/minio/object-browser` returns **404** as of 2026-10-29 — the announced
replacement UI is not publicly available. This corroborates the community complaints from April–May
2025 that admin/IAM/config features vanished from the free console (secondary:
https://www.reddit.com/r/selfhosted/comments/1lcgq86/minio_removed_admin_features_from_the_web_ui_in/,
https://github.com/community-scripts/ProxmoxVE/issues/4787).

Practical consequence: a MinIO deployment today means either (a) pinning a 2025-09-07 binary that
will never get a CVE fix, (b) building from an archived AGPLv3 tree forever, or (c) buying AIStor.

### MinIO AIStor Free is proprietary and single-node by licence, not by configuration

This is the part that disqualifies MinIO for a multi-machine study, and it is a licensing limit
rather than a technical one. The AIStor Free Tier License Agreement (last updated 2026-01-30,
https://www.min.io/legal/aistor-free-agreement) grants:

> a limited, non-exclusive, non-transferable, royalty-free license to install and use the Software
> solely in **standalone mode** (single-node deployments without distributed clustering or high
> availability)

and:

> **Ownership:** The Software is proprietary to MinIO and protected by copyright and other
> intellectual property laws.

with restrictions including "You may not modify, reverse engineer, decompile, disassemble, or create
derivative works of the Software."

The pricing page matches: the Free tier lists "Single-node deployment architecture" and "Free of
charge", while Enterprise Lite is "Full-featured, horizontally scalable multi-node architecture …
capacity requirements below 400 TiB" (https://www.min.io/pricing). No public price is listed for
Enterprise Lite or Enterprise — both are "Request … Pricing".

So "free MinIO" in 2026 = one node, no HA, no clustering, no source modification, and a licence
MinIO can change at will ("MinIO has the sole discretion, at any time, to change, substitute, or
modify the Software"). If the plan is a multi-node storage tier reached over Tunnel/Mesh, MinIO is
a dead end. If the plan is a single fat box, AIStor Free is legal and free but proprietary — and
you are betting the storage layer on a vendor that just demonstrated it will relicense.

### MinIO erasure coding, for the record

Worth recording because the competitors are measured against it. Erasure sets default to 2–16
drives, up to 32 via `MINIO_ERASURE_SET_DRIVE_COUNT` on `RELEASE.2026-02-02T23-40-11Z` or later;
parity can be 0 to 1/2 the set; and:

> **Production deployments must use a parity of `EC:3` or higher.** Lower parity values — including
> the automatic defaults selected for erasure sets of five or fewer drives — do not provide
> sufficient failure tolerance for production workloads and are suitable for development and
> testing environments only.

(https://docs.min.io/aistor/operations/core-concepts/erasure-coding/)

Note the redirect: `docs.min.io/community/minio-object-store/...` now resolves to
`docs.min.io/aistor/...` (visible as `final_url` in the fetch metadata). The community documentation
has been folded into the AIStor documentation — another sign the AGPLv3 branch is being left behind.

### Garage: the simplest thing that works, and it means it

Repo moved: `dxflrs/garage` now 404s; the live repo is `deuxfleurs-org/garage`, AGPL-3.0, 4,784
stars, pushed 2026-10-24, tag v2.5.0
(https://forge.web.pkgforge.dev/github/repos/deuxfleurs-org/garage). Any bookmark or Helm chart
still pointing at `dxflrs` is stale.

Garage's design goals page is refreshingly explicit about what it refuses to build:

> **Storage optimizations**: erasure coding or any other coding technique both increase the
> difficulty of placing data and synchronizing; we limit ourselves to duplication.

(https://garagehq.deuxfleurs.fr/documentation/design/goals/)

That is the whole trade: Garage is 3x raw capacity for 3 replicas, forever, with no EC tier. In
exchange you get a genuinely simple system — no Raft in the request path, self-contained binary,
automatic rebalancing, static website hosting (which MinIO and Ceph do not do properly), and a
cluster admin REST API.

The S3 gaps are real and documented by the project itself
(https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/):

- **No bucket versioning.** "Garage does not (yet) support object versioning." `GetBucketVersioning`
  is a stub that always answers "not enabled"; `PutBucketVersioning` and `ListObjectVersions` are
  missing outright.
- **No ACLs and no bucket policies.** "Garage implements none of them, and has its own system
  instead, built around a per-access-key-per-bucket logic." `PutBucketAcl`, `GetObjectAcl`,
  `PutObjectAcl`, `Put/Put/GetBucketPolicy` are all missing.
- **No SigV2**, no bucket replication, no `ExpiredObjectDeleteMarker` in lifecycle, and
  `RedirectAllRequestsTo` unimplemented.
- Missing endpoints return `501 Not Implemented`.

For a CI/container platform this matters concretely: anything that relies on bucket policies to
scope per-job credentials, or on versioning to survive a bad `rm -rf`, does not work on Garage. You
would have to put credential scoping in your own control plane.

Also: single-node Garage is explicitly not production. The quick-start says "Note that this kind of
deployment should not be used in production, as it provides no redundancy for your data!"
(https://garagehq.deuxfleurs.fr/documentation/quick-start/)

### SeaweedFS: the broadest S3 surface, and the most moving parts

35,799 stars, Apache-2.0, pushed 2026-10-29, release 4.51 on 2026-10-25
(https://forge.web.pkgforge.dev/github/repos/seaweedfs/seaweedfs). One `weed` binary, but at
production scale it is four roles: master (Raft, tracks volumes not files), volume servers (the
actual disks), filer (directory metadata, backed by an **external** database), and stateless S3
gateways in front of the filer. The README's own list of supported filer stores is long — LevelDB,
RocksDB, SQLite, MySQL, PostgreSQL, Cassandra, HBase, MongoDB, Redis, Elasticsearch, etcd, TiKV,
FoundationDB, YDB, ArangoDB, Tarantool, TiDB, CockroachDB — which is another way of saying **you
must run and back up a metadata database as well**. That is a second stateful system to operate,
and it is the part most likely to bite you: lose the filer store and the objects are intact but
unreachable.

The S3 surface is the strongest of the OSS candidates: the README claims 73 bucket/object
operations, 36 S3 Tables operations, 39 IAM and 5 STS on one endpoint, and the wiki enumerates them
against AWS operation names. What is *missing* is documented just as clearly
(https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API):

- `GetBucketNotificationConfiguration` / `PutBucketNotificationConfiguration`: **No** — no S3 event
  notifications. This is a genuine functional hole if anything downstream reacts to object creation
  (CI artefact triggers, cache invalidation).
- `GetBucketWebsite` / `PutBucketWebsite`: **No** — no S3 static-site endpoint (though SeaweedFS
  has its own filer-level web serving).
- `GetBucketReplication` / `PutBucketReplication`: **No**.
- `SelectObjectContent`: **No**. `RestoreObject`: **No**.
- Lifecycle: "Transition rules not supported". Several config APIs are stubs that return
  `NoSuchConfiguration` or an empty list — honest, but they will not do anything.
- `MFA Delete for versioning`: **No**.

The erasure coding model is the important operational difference: "Hot data is replicated; erasure
coding is applied to warm data in the background, so writes never pay the encoding cost"
(https://github.com/seaweedfs/seaweedfs/blob/master/README.md). Nothing automatically guarantees the
EC job runs — "Balancing, vacuum, erasure coding, and repair run on demand from `weed shell` or the
maintenance worker" (same README). If you do not schedule the maintenance worker, a cluster that
looks like it has EC is actually running at replication factor and you will find out during a disk
failure.

SeaweedFS is also the only candidate here that ships its own claim about MinIO's death:

> Please note, as Apr 25, 2026 MinIO ceased development. It's strongly discouraged to use that
> unmaintained software with multiple security bugs.

(https://github.com/seaweedfs/seaweedfs/blob/master/README.md) — a competitor's claim, so treat the
"multiple security bugs" as secondary; the cessation itself is independently verified above.

### RustFS: Apache-2.0, MinIO-shaped, and about one year old in public

35,524 stars, Apache-2.0, pushed 2026-10-29, release 1.0.4 on 2026-10-25; repo created 2023-11-23
(https://forge.web.pkgforge.dev/github/repos/rustfs/rustfs). The vendor's own timeline: first line
of code February 2024, **open-sourced July 2025**, Beta April 2026, RC August 2026, GA September
2026 (https://rustfs.com/blog/announcing-rustfs-1-0-0-ga/). So the entire public life of this
project is roughly fifteen months and the GA is one month old.

Its value proposition is deliberate: MinIO's storage model and API, Apache-2.0 instead of AGPL, with
byte-compatible on-disk format as a migration path — though "MinIO On-Disk Compatibility" is marked
🧪 **Preview**, not Available, in the README feature matrix.

Deployment modes are documented with unusual honesty
(https://docs.rustfs.com/en/installation/linux):

- SNSD (single node, single disk): "with no redundancy — a disk failure means data loss, so rely on
  backups."
- SNMD (single node, multiple disks): "Erasure coding shards data across the disks, so the node
  tolerates a limited number of disk failures, but a whole-server failure still means data loss."
- MNMD (four or more servers): "Erasure coding spans servers, providing disk- and node-level fault
  tolerance plus horizontal scalability. This is the mode for production workloads."

The S3 compatibility matrix is candid about scope: "RustFS provides broad S3 API compatibility for
supported features. It does not claim complete coverage of every standard or vendor-specific S3
behavior" (https://github.com/rustfs/rustfs/blob/main/docs/architecture/s3-compatibility-matrix.md).
One concrete migration gotcha from the same document: "MinIO SSE objects (SSE-S3, SSE-KMS, SSE-C)
are not readable in default builds" — so a MinIO→RustFS move with encryption enabled requires an
`rio-v2` migration build.

The honest summary is in a third-party GA review: run it "for a real workload you can measure, not
just a hello-world bucket" and "watch p99 latency under your own traffic before you trust it with
the primary copy of anything" (secondary: https://dev.to/ethan-carter/rustfs-10-is-ga-after-25-years-whats-actually-production-ready-and-what-isnt-15go).

### VersityGW: a translation gateway, not a store

3,079 stars, Apache-2.0, v1.10.0 released 2026-10-22
(https://forge.web.pkgforge.dev/github/repos/versity/versitygw). It is explicitly "a
high-performance, Apache-2.0-licensed translation service that exposes an S3-compatible API over
POSIX filesystems, ScoutFS, Azure Blob Storage, other S3 services, and custom backends"
(https://github.com/versity/versitygw/wiki).

That sentence is the whole story: **VersityGW implements no replication and no erasure coding of
its own.** Durability is whatever the filesystem underneath gives you. With the POSIX backend, "The
POSIX backend maps S3 buckets, objects, and multipart uploads directly onto directories and files in
a local or mounted filesystem" and "The first positional argument after the POSIX options … becomes
the gateway root" (https://github.com/versity/versitygw/wiki/POSIX-Backend) — i.e. one process over
one mount. Multi-node durability requires ScoutFS or a clustered filesystem underneath, at which
point VersityGW is the least interesting component in the stack.

It also requires xattrs unless you pass `--sidecar` or `--nometa`, which rules out some object
stores and network filesystems as backends.

Documented incompatibilities (https://github.com/versity/versitygw/wiki/Incompatibilities-With-AWS-S3):

- **No object ACLs.** "versitygw currently does **not** support **object ACLs** … Object ACL headers
  are ignored for incoming requests."
- **No SigV2.** SigV4 only.
- Standalone IAM "is a single-account system in which every ARN is scoped to the account id
  `000000000000`", inline policies only, no managed policies, no groups, no permissions boundaries,
  and only `AssumeRoleWithWebIdentity` + `GetCallerIdentity` on STS.
- The POSIX backend invents error codes with no S3 analogue (`ExistingObjectIsDirectory`,
  `ObjectParentIsFile`, `DirectoryObjectContainsData`, `QuotaExceeded`, …), which clients that
  branch on error codes must special-case.

VersityGW is a reasonable choice *if* the org already runs ScoutFS or a clustered POSIX layer and
wants an S3 door onto it. It is not a storage system to adopt standalone.

### Ceph RGW: the only one with a decade of proof, and the heaviest

17,178 stars, `pushed_at` 2026-10-29, licence reported by GitHub as `NOASSERTION` (Ceph is
LGPL-2.1-or-later with a pile of other licences in-tree, hence the detection failure — not a
proprietary licence) (https://forge.web.pkgforge.dev/github/repos/ceph/ceph). Active release lines:
umbrella 21.2.0 (2026-10-28), tentacle 20.2.4, squid 19.2.7
(https://docs.ceph.com/en/latest/releases/).

S3 coverage is the most complete of any candidate, and the gaps are almost embarrassingly small. The
feature table marks List/Create/Delete Bucket, Lifecycle, Policy, Website, ACLs, Versioning, Object
Tagging, Storage Class, Logging, Object Ownership, PublicAccessBlock and multipart all **Supported**.
The only non-Supported entries are:

- **Bucket Replication — "Partial — Permitted only across zones"**
- and a single unsupported header, "**x-amz-id-2** | Response"

(https://docs.ceph.com/en/latest/radosgw/s3/)

The cost is the cluster. RGW is a front end onto RADOS; you are running mons, mgrs and OSDs whether
or not you want them. Ceph's own documentation sets a floor: "We recommend running a production Ceph
Storage Cluster with at least three Ceph Monitors"
(https://docs.ceph.com/en/latest/rados/configuration/mon-config-ref/), and per daemon: `ceph-mon`
"2 cores minimum", ">= 5 GB per daemon", "100 GB per daemon, SSD strongly urged"; `ceph-osd` ">= 4
GiB per OSD" (https://docs.ceph.com/en/latest/start/minimum-hardware/).

And on single-node, the docs are blunt: the `--single-host-defaults` flag exists, but "Such clusters
are generally not suitable for production"
(https://docs.ceph.com/en/latest/cephadm/install/).

So Ceph is the right answer only if the org already has or wants a Ceph cluster for block/file too.
Standing up Ceph purely to get an S3 endpoint for CI artefacts is a large amount of operational
surface for the return.

### Zenko CloudServer: a CI S3 emulator that grew up

`zenko/cloudserver` 404s; the live repo is `scality/cloudserver`, Apache-2.0, 1,955 stars, release
9.5.2 on 2026-10-27, actively committed (2026-10-27)
(https://forge.web.pkgforge.dev/github/repos/scality/cloudserver). It is not abandoned.

But read what it says it is for:

> CloudServer … provides a single AWS S3 API interface to access multiple backend data storage both
> on-premise or public in the cloud.
>
> CloudServer is useful for Developers, either to run as part of a continous integration test
> environment to emulate the AWS S3 service locally or as an abstraction layer to develop object
> storage enabled application on the go.

(https://github.com/scality/cloudserver)

That is a self-description as a **development/CI S3 emulator and multi-cloud abstraction layer**, not
as a durable object store. Its file backend writes to `localData`/`localMetadata` directories on the
local disk of one node; there is no erasure coding and no replication layer in CloudServer itself
(BELIEVED — derived from the README's backend description and the absence of any redundancy feature
in the docs; I did not find an explicit statement either way).

Note also that the README is stale in a way that matters for anyone following it: it says "Building
and running the Zenko CloudServer requires node.js 10.x and yarn v1.17.x", but `package.json` on the
`development/9.5` branch declares `"engines": {"node": ">=24"}`. Node 10 has been EOL since 2021 —
if you follow the README you will build something that cannot be patched.

### JuiceFS: a filesystem that consumes an object store

14,586 stars, Apache-2.0, v1.4.2 on 2026-10-22
(https://forge.web.pkgforge.dev/github/repos/juicedata/juicefs). It is architecturally the opposite of
what this lane needs: it splits file data into blocks in an object store and keeps metadata in a
separate engine — "JuiceFS supports a variety of common databases as the metadata engine, like Redis,
TiKV, MySQL/MariaDB, PostgreSQL, and SQLite" (https://juicefs.com/docs/community/architecture/).

Its S3 gateway is not an object store either, and it is built on code MinIO deleted:

> JuiceFS S3 Gateway implements its functionality through [MinIO S3 Gateway] … Leveraging MinIO's
> `object` interface, we integrate the JuiceFS file system as the backend storage for MinIO servers.

(https://juicefs.com/docs/community/guide/gateway/)

MinIO removed gateway mode years ago (BELIEVED — widely reported, I did not fetch the removal commit),
so JuiceFS is maintaining a fork of a dead code path pinned to a specific upstream commit. That is a
maintenance risk, not a feature.

JuiceFS is worth considering as a *shared POSIX workspace* for CI jobs (with a real object store like
SeaweedFS underneath). It is not a candidate for the R2 replacement itself.

### Erasure coding economics decide the shortlist

The single number that separates these systems is raw-to-usable ratio:

- **Replication only (Garage)**: 3x raw for 3 replicas, permanently. Garage says so: "we limit
  ourselves to duplication."
- **Full-time EC (MinIO, RustFS MNMD, Ceph)**: typically 1.3–1.5x at EC:4..6, at the cost of
  read amplification and repair traffic. MinIO's floor is EC:3 for production.
- **Async EC on warm data (SeaweedFS)**: 1x during ingest (replication), then compressed by a
  background job. Cheapest writes, but only if the maintenance worker actually runs.

For a CI platform the write pattern is large sequential blobs (build caches, container layers,
artefacts) that are read rarely and then expire. That is close to the ideal case for EC and a
terrible case for 3x replication — which argues against Garage on cost and in favour of SeaweedFS or
RustFS, provided the EC/repair job is scheduled and monitored.

### Single-node and small-cluster behaviour

Nobody's single-node mode is durable, and each project says so differently:

- Garage: "this kind of deployment should not be used in production, as it provides no redundancy
  for your data!"
- RustFS SNSD: "no redundancy — a disk failure means data loss, so rely on backups."
- Ceph single host: "generally not suitable for production."
- MinIO SNSD is single-drive, zero-parity (BELIEVED — MinIO's erasure coding needs a drive set; the
  SNSD path has no parity. I could not fetch a current primary page because the community docs now
  redirect to AIStor).
- SeaweedFS single node works and is the least painful of the group, but with `-replication=000`
  you have no copies.

The practical minimum for a genuinely durable small cluster is **3 nodes** (Garage, replication
factor 3) or **4 nodes** (RustFS MNMD; Ceph wants 3 mons plus OSDs). Anything below that is a
backup-and-restore story, not a durability story.

### What self-hosting does not fix

Blunt list, because the study's premise is "replace R2":

1. **Egress.** R2's differentiator is not storage price, it is that egress is free. Self-hosted S3
   reached over Cloudflare Tunnel still consumes Tunnel/Mesh capacity and your own uplink. There is
   no egress saving to be had here, only a transfer of who pays for the wire.
2. **Durability.** R2 gives you object durability as a service. Every candidate above makes
   durability *your* job — EC/repair scheduling, scrub cycles, filer-store backups (SeaweedFS),
   monitor quorum (Ceph), or accepting 3x replication (Garage).
3. **Small-object performance.** SeaweedFS is the only candidate designed for many small files
   (packed append-only volumes, O(1) reads). MinIO-family and Ceph both suffer on millions of tiny
   objects; SeaweedFS's own README attacks MinIO/RustFS on exactly this: "There is no optimization
   for lots of small files … it only amplifies the LOSF problem."
4. **The management UI.** If the dashboard/SPA is going to manage buckets, you are writing that
   against the S3/admin API yourself. MinIO's console is gone, RustFS has one, SeaweedFS has a basic
   filer UI, Garage has an admin REST API and a third-party UI. Do not pick a store for its UI.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| MinIO (community) | https://github.com/minio/minio | AGPL-3.0 | archived; last commit 2026-02-12; last release with binaries RELEASE.2025-09-07T16-13-09Z | Mature S3, Reed-Solomon EC (2–16 drive sets, EC:3+ for prod), the de-facto compatibility baseline | **Archived, "NO LONGER MAINTAINED", source-only since 2025-10**; no security updates; console deprecated 2025-05-24 and the named replacement repo 404s |
| MinIO AIStor Free | https://www.min.io/legal/aistor-free-agreement | proprietary, free of charge | EULA 2026-01-30 | Full feature set, supported | **Licence restricted to "standalone mode (single-node deployments without distributed clustering or high availability)"**; no modification, no redistribution; vendor may change terms |
| Garage | https://github.com/deuxfleurs-org/garage (moved from dxflrs/garage) | AGPL-3.0 | v2.5.0, 2026-10-23 | Simplest ops of any candidate; no Raft in request path; geo replication; static website hosting; admin REST API; auto-rebalance | **No erasure coding ("we limit ourselves to duplication")** → 3x raw; **no bucket versioning**; **no ACLs/policies**; no SigV2; no bucket replication |
| SeaweedFS | https://github.com/seaweedfs/seaweedfs | Apache-2.0 | 4.51, 2026-10-25 | Broadest S3 surface (73 ops + IAM + STS); one binary; O(1) small-file reads; hot-replication + async EC on warm data; S3 Tables/Iceberg | Needs master + volume servers + filer + **external metadata DB** + gateways; **no S3 event notifications, no bucket website, no SelectObjectContent, no bucket replication**; EC only runs if you schedule it |
| RustFS | https://github.com/rustfs/rustfs | Apache-2.0 | 1.0.4, 2026-10-25 | MinIO-shaped, Apache-2.0, distributed EC from 4 nodes, broad API incl. bucket policies, versioning, object lock, IAM/OIDC, console | GA only 2026-09; open-sourced 2025-07 → no production track record; MinIO on-disk compat is Preview; MinIO SSE objects unreadable by default |
| VersityGW | https://github.com/versity/versitygw | Apache-2.0 | v1.10.0, 2026-10-22 | Fast S3 front end for existing POSIX/ScoutFS/Azure/S3; static websites; WebGUI; RDMA | **A gateway, not a store — no replication or EC of its own**; POSIX backend is one process over one mount; **no object ACLs**; single-account IAM (`000000000000`); needs xattrs |
| Ceph RGW | https://github.com/ceph/ceph | LGPL-2.1 + others (GitHub: NOASSERTION) | umbrella 21.2.0, 2026-10-28 | Most complete S3 (only gap: cross-zone-only bucket replication); a decade of production proof; EC and replication both | Full Ceph cluster required (mons/mgrs/OSDs); **single-host "generally not suitable for production"**; ≥3 mons, 5 GB+100 GB SSD per mon, 4 GiB per OSD; heavy ops |
| Zenko CloudServer | https://github.com/scality/cloudserver | Apache-2.0 | 9.5.2, 2026-10-27 | S3 API over local dirs or cloud backends; genuinely active | Self-described as a **CI emulator / dev abstraction layer**; single-node file backend; no EC/replication of its own; README says Node 10 while package.json needs Node ≥24 |
| JuiceFS | https://github.com/juicedata/juicefs | Apache-2.0 | v1.4.2, 2026-10-22 | POSIX filesystem over an object store; shared workspace for CI; strong metadata options | **Not an object store** — consumes one, plus a separate metadata DB; S3 gateway is a fork of MinIO's removed gateway code |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| minio/minio archived | true | https://forge.web.pkgforge.dev/github/repos/minio/minio | `"archived": true` (API field) |
| minio/minio stars | 61,301 | https://forge.web.pkgforge.dev/github/repos/minio/minio | `"stargazers_count": 61301` |
| minio/minio last commit | 2026-02-12T05:53:17Z | https://forge.web.pkgforge.dev/github/repos/minio/minio/commits?per_page=5 | "update README.md format and clarify state of the project" |
| MinIO no longer maintained | — | https://github.com/minio/minio | "**THIS REPOSITORY IS NO LONGER MAINTAINED.**" |
| MinIO community is source-only | — | https://github.com/minio/minio | "The MinIO community edition is now distributed as source code only. We will no longer provide pre-compiled binary releases for the community version." |
| MinIO last release has no binaries | RELEASE.2025-10-15T17-29-55Z, assets `[]` | https://forge.web.pkgforge.dev/github/repos/minio/minio/releases?per_page=2 | `"tag_name": "RELEASE.2025-10-15T17-29-55Z"`, `"assets": []` |
| MinIO last binary release | RELEASE.2025-09-07T16-13-09Z, linux-amd64 110,989,496 B | https://forge.web.pkgforge.dev/github/repos/minio/minio/releases?per_page=2 | `minio.linux-amd64.RELEASE.2025-09-07T16-13-09Z 110989496` |
| MinIO console deprecated | release 2025-05-24 | https://forge.web.pkgforge.dev/github/repos/minio/minio/releases?per_page=40 | "Embedded UI Console is now deprecated and moved to object-browser" |
| AIStor Free is single-node only, by licence | — | https://www.min.io/legal/aistor-free-agreement | "solely in **standalone mode** (single-node deployments without distributed clustering or high availability)" |
| AIStor Free is proprietary | — | https://www.min.io/legal/aistor-free-agreement | "The Software is proprietary to MinIO and protected by copyright and other intellectual property laws." |
| AIStor Free tier = single node | — | https://www.min.io/pricing | "Single-node deployment architecture" / "Free of charge" |
| AIStor Enterprise Lite capacity ceiling | 400 TiB | https://www.min.io/pricing | "capacity requirements below 400 TiB" |
| MinIO EC set size | 2–16 drives default, up to 32 | https://docs.min.io/aistor/operations/core-concepts/erasure-coding/ | "By default, each erasure set can contain 2 to 16 drives." |
| MinIO production parity floor | EC:3 | https://docs.min.io/aistor/operations/core-concepts/erasure-coding/ | "**Production deployments must use a parity of `EC:3` or higher.**" |
| Garage stars / licence | 4,784 / AGPL-3.0 | https://forge.web.pkgforge.dev/github/repos/deuxfleurs-org/garage | `"stargazers_count": 4784`, `"spdx_id": "AGPL-3.0"` |
| Garage repo moved | dxflrs/garage → 404 | https://forge.web.pkgforge.dev/github/repos/dxflrs/garage | HTTP 404 |
| Garage has no erasure coding | — | https://garagehq.deuxfleurs.fr/documentation/design/goals/ | "erasure coding or any other coding technique both increase the difficulty of placing data and synchronizing; we limit ourselves to duplication." |
| Garage has no versioning | — | https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/ | "Garage does not (yet) support object versioning." |
| Garage has no ACLs/policies | — | https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/ | "Garage implements none of them, and has its own system instead, built around a per-access-key-per-bucket logic." |
| SeaweedFS stars / release | 35,799 / 4.51 (2026-10-25) | https://forge.web.pkgforge.dev/github/repos/seaweedfs/seaweedfs | `"stargazers_count": 35799`, `"pushed_at": "2026-10-29T10:32:07Z"` |
| SeaweedFS S3 op counts | 73 / 36 / 39 / 5 | https://github.com/seaweedfs/seaweedfs/blob/master/README.md | "S3 bucket and object: 73"; "S3 Tables: 36"; "IAM: 39"; "STS: 5" (table cells, pipes replaced with colons) |
| SeaweedFS has no S3 event notifications | — | https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API | "GetBucketNotificationConfiguration | No" / "PutBucketNotificationConfiguration | No" |
| SeaweedFS EC is async on warm data | — | https://github.com/seaweedfs/seaweedfs/blob/master/README.md | "Hot data is replicated; erasure coding is applied to warm data in the background, so writes never pay the encoding cost." |
| SeaweedFS EC runs only on demand | — | https://github.com/seaweedfs/seaweedfs/blob/master/README.md | "Balancing, vacuum, erasure coding, and repair run on demand from `weed shell` or the maintenance worker." |
| RustFS stars / release | 35,524 / 1.0.4 (2026-10-25) | https://forge.web.pkgforge.dev/github/repos/rustfs/rustfs | `"stargazers_count": 35524`, `"pushed_at": "2026-10-29T10:28:34Z"` |
| RustFS GA date / age | GA Sept 2026, open-sourced July 2025 | https://rustfs.com/blog/announcing-rustfs-1-0-0-ga/ | "July 2025 — Open-sourced"; "September 2026 — GA release" (milestone table, pipe replaced with dash) |
| RustFS production mode needs 4+ servers | — | https://docs.rustfs.com/en/installation/linux | "Four or more servers, each with one or more disks. … This is the mode for production workloads." |
| RustFS SNSD has no redundancy | — | https://docs.rustfs.com/en/installation/linux | "The simplest mode, with no redundancy — a disk failure means data loss, so rely on backups." |
| RustFS does not claim full S3 coverage | — | https://github.com/rustfs/rustfs/blob/main/docs/architecture/s3-compatibility-matrix.md | "It does not claim complete coverage of every standard or vendor-specific S3 behavior." |
| RustFS cannot read MinIO SSE objects | — | https://github.com/rustfs/rustfs/blob/main/docs/architecture/s3-compatibility-matrix.md | "MinIO SSE objects (SSE-S3, SSE-KMS, SSE-C) are not readable in default builds" |
| VersityGW stars / release | 3,079 / v1.10.0 (2026-10-22) | https://forge.web.pkgforge.dev/github/repos/versity/versitygw | `"stargazers_count": 3079` |
| VersityGW is a translation service | — | https://github.com/versity/versitygw/wiki | "a high-performance, Apache-2.0-licensed translation service that exposes an S3-compatible API over POSIX filesystems, ScoutFS, Azure Blob Storage, other S3 services, and custom backends." |
| VersityGW has no object ACLs | — | https://github.com/versity/versitygw/wiki/Incompatibilities-With-AWS-S3 | "versitygw currently does **not** support **object ACLs**." |
| VersityGW IAM single account | 000000000000 | https://github.com/versity/versitygw/wiki/Incompatibilities-With-AWS-S3 | "a single-account system in which every ARN is scoped to the account id **`000000000000`**" |
| Ceph latest releases | umbrella 21.2.0 (2026-10-28) | https://docs.ceph.com/en/latest/releases/ | "umbrella (latest 21.2.0): done, 2026-10-28" |
| Ceph S3 bucket replication gap | partial, cross-zone only | https://docs.ceph.com/en/latest/radosgw/s3/ | "**Bucket Replication** — Partial — Permitted only across zones" (table cells, pipes replaced with dashes) |
| Ceph only unsupported S3 header | x-amz-id-2 | https://docs.ceph.com/en/latest/radosgw/s3/ | "**x-amz-id-2** — Response" (table cells, pipe replaced with dash) |
| Ceph single host not for production | — | https://docs.ceph.com/en/latest/cephadm/install/ | "Such clusters are generally not suitable for production." |
| Ceph monitor floor | 3 monitors, 2 cores, ≥5 GB, 100 GB SSD each | https://docs.ceph.com/en/latest/start/minimum-hardware/ | "`ceph-mon` … 2 cores minimum … >= 5 GB per daemon … 100 GB per daemon, SSD strongly urged" |
| Ceph OSD RAM floor | ≥4 GiB per OSD | https://docs.ceph.com/en/latest/start/minimum-hardware/ | ">= 4 GiB per OSD" |
| Zenko CloudServer stars / release | 1,955 / 9.5.2 (2026-10-27) | https://forge.web.pkgforge.dev/github/repos/scality/cloudserver | `"stargazers_count": 1955` |
| Zenko CloudServer positioning | CI emulator | https://github.com/scality/cloudserver | "useful for Developers, either to run as part of a continous integration test environment to emulate the AWS S3 service locally" |
| Zenko node engine mismatch | README says 10.x, package.json says >=24 | https://github.com/scality/cloudserver | `"engines": {"node": ">=24"}` vs README "requires node.js 10.x" |
| JuiceFS stars / release | 14,586 / v1.4.2 (2026-10-22) | https://forge.web.pkgforge.dev/github/repos/juicedata/juicefs | `"stargazers_count": 14586` |
| JuiceFS needs a metadata engine | — | https://juicefs.com/docs/community/architecture/ | "JuiceFS supports a variety of common databases as the metadata engine, like Redis, TiKV, MySQL/MariaDB, PostgreSQL, and SQLite" |
| JuiceFS S3 gateway is MinIO-gateway-derived | — | https://juicefs.com/docs/community/guide/gateway/ | "JuiceFS S3 Gateway implements its functionality through [MinIO S3 Gateway]" |
| MinIO publishes no S3 compatibility list | — | https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/ | "Minio is missing because they do not provide a public S3 compatibility list." |
| MinIO ACLs are accepted but not enforced (secondary) | — | https://github.com/seaweedfs/seaweedfs/wiki/Supported-APIs-vs-MinIO | "ACLs — ✅ Full — ⚠️ Dummy — MinIO accepts but does not enforce bucket and object ACL requests" (table cells, pipes replaced with dashes) |

## Rejected options

| option | why rejected |
|---|---|
| MinIO community edition (current) | Repo archived 2026-02, README says "NO LONGER MAINTAINED", source-only since 2025-10, last binary 2025-09-07 will never be patched. Running it is running unpatched storage. |
| MinIO AIStor Free | Proprietary licence limited to "standalone mode (single-node deployments without distributed clustering or high availability)"; no modification; terms changeable at vendor discretion. Cannot serve a multi-node cluster. |
| MinIO AIStor Enterprise / Lite | Paid subscription, price on request. Defeats the purpose of the exercise and is the exact vendor dependency the study is trying to escape. |
| Garage as the primary store | Rejected *as primary*, kept as the small-cluster option. No erasure coding (3x raw forever), no bucket versioning, no ACLs/policies. Fine for 3–5 nodes of non-critical data; wrong for a CI artefact store that wants cheap capacity. |
| Zenko CloudServer | Self-described CI/dev S3 emulator; single-node file backend; no redundancy layer of its own; stale README (Node 10 vs Node ≥24). |
| JuiceFS as the S3 layer | Category error: it is a POSIX filesystem over an object store, plus a separate metadata database, and its S3 gateway is a fork of MinIO's deleted gateway code. Good as a CI shared workspace, not as the store. |
| VersityGW standalone | No replication and no erasure coding of its own; POSIX backend is one process over one mount. Only sensible on top of ScoutFS or an existing clustered FS. |
| Ceph RGW for this project | Not rejected on capability — rejected on footprint. Full mon/mgr/OSD cluster, 3 mons minimum, 5 GB + 100 GB SSD per mon, and the project's own docs say single-host is "generally not suitable for production". Right answer only if a Ceph cluster already exists. |
| MinIO gateway mode (as a compatibility shim) | Removed from MinIO years ago; the only surviving copies are forks (JuiceFS). Not a supported path. |
| Object-store-on-object-store (Zenko multi-cloud, VersityGW S3 backend) | Adds a hop and a second failure domain without adding durability you control. No benefit over picking one real store. |

## Open questions

- **SeaweedFS filer-store durability.** I could not find a doc stating what happens to object
  *reachability* if the filer metadata DB (Postgres/Redis/etc.) is lost while volumes are intact.
  Settle by reading `weed filer` backup/restore docs and, better, by killing the metadata DB in a
  test cluster and attempting a read by known object key.
- **SeaweedFS EC job guarantee.** Does anything alarm when EC has not run for N days? The README says
  it "run[s] on demand". Settle by checking the maintenance-worker docs for a Prometheus metric
  like `ec_shards_unencoded` and confirming an alert can be built on it.
- **RustFS at scale.** No public production case studies with node counts and object counts. Settle
  by asking the project for reference deployments, or by a 30-day burn-in with the org's real
  workload before trusting a primary copy.
- **RustFS MinIO on-disk migration.** "MinIO On-Disk Compatibility" is 🧪 Preview. Whether an actual
  MinIO 2025-09 dataset mounts read-write is unverified. Settle by taking a real MinIO volume and
  attempting a mount in a lab.
- **AIStor Free enforcement.** Whether the single-node restriction is technically enforced (licence
  key check / node-count check) or purely contractual. Not stated in the EULA text I read. Settle by
  reading `docs.min.io/aistor/operations/licenses/`.
- **Garage object-count and bucket-count limits.** Garage's docs describe layout/rebalance but I did
  not find a stated ceiling on objects or buckets. Settle by reading the layout/administration docs
  and the project's own benchmarks page.
- **Ceph RGW single-node for real.** Docs say "generally not suitable for production" but do not
  quantify. Whether a 1-node, 3-OSD Ceph is acceptable for a non-critical CI cache is untested here.
  Settle with a lab cluster and a `--single-host-defaults` bootstrap plus failure injection.
- **R2 comparison numbers.** This lane deliberately did not re-derive R2 pricing/egress; that belongs
  to the Cloudflare baseline and cost-model lanes. The verdict here assumes R2's zero-egress
  advantage, not a verified figure.
- **Whether MinIO's archived AGPLv3 tree is being forked by anyone credible.** No fork surfaced in
  searches (e.g. an "OpenMinIO"/community continuation with real release cadence). Settle by
  watching for a maintained fork with binaries and a CVE process over the next 6 months.
