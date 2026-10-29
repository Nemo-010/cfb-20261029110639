# 05 — Storage: replacing R2, and the conditional-write problem

R2 is the hardest product in this list to beat, because free egress is not a feature you can
reimplement — it is a business decision. This document is about the cases where you should
replace it anyway, and the one technical property that decides which replacement works.

---

## The decision

| Situation | Do this |
|---|---|
| Under ~80 TB stored, egress under a few TB/month | **Keep R2.** You will not beat it. |
| Egress is the bill (media, artifacts, package mirrors) | Replace it. Transit is 16–270× cheaper. |
| You need object lock, bucket policies, replication, notifications | Replace it. R2 does not implement them. |
| You are running celld, which needs a CAS store | Either keep a small R2 bucket for celld, or use SeaweedFS. |

The last row is the interesting one and it is the reason this document exists at all.

---

## The property that matters: conditional writes

A distributed system that stores its state in object storage needs a compare-and-swap.
Without it, two writers both think they own a cell, and the failure mode is not an outage —
it is **silent data corruption**.

celld states the requirement plainly (`docs/guarantees.md`):

> The store must provide conditional writes, exact ranged reads, and read-after-write
> consistency. Amazon S3, Cloudflare R2, Google Cloud Storage, Tigris, and Azure Blob
> Storage qualify; Backblaze B2, Hetzner, and DigitalOcean Spaces do not.

That single sentence eliminates most of the cheap storage market. It also means the naive
plan — "replace R2 with a MinIO clone" — is wrong, because most MinIO clones do not implement
`If-None-Match` atomically.

### The matrix

| Store | `If-None-Match: *` (create) | `If-Match: <etag>` (CAS) | Verdict |
|---|---|---|---|
| AWS S3 | yes | yes | qualifies |
| Cloudflare R2 | yes | yes | qualifies |
| Google Cloud Storage | yes | yes | qualifies |
| Azure Blob | yes | yes | qualifies |
| Tigris | yes | yes | qualifies |
| **SeaweedFS** | yes | yes | **qualifies** — owner-filer serialisation |
| **RustFS** | yes | **501 NotImplemented** | create-if-absent only |
| MinIO (community) | yes | yes | passes the probe, "not qualified for production" |
| **Garage** | **no** | **no** | **structurally impossible** |
| Backblaze B2 | no | no | fails |
| Hetzner | no | no | fails |
| DigitalOcean Spaces | no | no | fails |
| Ceph RGW | unverified | unverified | unknown |

### Why Garage cannot be fixed

From Garage's own known-issues page, verbatim:

> This is structurally impossible to implement in Garage due to the lack of a consensus
> algorithm, which is one of Garage's core design choices which we cannot reconsider.

Garage is otherwise the nicest thing to operate in this list — one binary, no metadata
database, trivial geo-distribution. If you are not running celld, it is a fine choice. If
you are, it will corrupt your state.

### Why SeaweedFS works

SeaweedFS does not require CAS from its metadata backend. It routes every write for an
object to one consistent-hash-owner filer and serialises there on an in-process mutex. From
their engineering write-up:

> Instead of demanding compare-and-swap from each of SeaweedFS's many metadata backends, or
> taking a distributed lock on every write, SeaweedFS routes each object's writes to one
> owner filer that serializes them locally.

That is a legitimate design — atomicity from routing plus a local lock, not from the store —
and it means conditional writes work on LevelDB, Cassandra, Postgres and Redis alike. It is
also exactly the property a CI system needs for "only one runner claims this job".

---

## SeaweedFS: the tier-1 choice

**Topology:** 3 nodes, each running master + volume + filer + S3 gateway, with the filer's
metadata in **Postgres**, not LevelDB, and **replication, not erasure coding**.

That last point corrects revision 1 of this document, which recommended EC 10+4 on a 3-node
cluster. That would have caused data loss: EC 10+4 needs 14 shards, and to survive a node
failure no node may hold more than 4 of them — 14 ÷ 4 = 3.5, so three nodes cannot satisfy it.
Losing one node loses ~4.7 shards against 4 parity shards, and the object is unreadable. EC is
a five-node-and-two-rack feature. On three nodes, replicate. See
[`12-operations.md`](12-operations.md#6-erasure-coding-the-correction).

| Component | HTTP | gRPC | Notes |
|---|---|---|---|
| master | 9333 | 19333 | Raft-replicated; 3 is the minimum |
| volume | 8080 | 18080 | actual block storage; **volume-to-volume replication rides the volume HTTP port** |
| filer | 8888 | 18888 | metadata |
| **S3 gateway** | **8333** | — | the only port that faces the tunnel |

Replication between volume servers uses the volume HTTP port (8080), not 19333 — 19333 is the
master's gRPC port. Firewalling 19333 as "the replication port" is a common mistake that
breaks the cluster in a way that looks like a network problem.

### Two configuration changes you must not skip

1. **Write an `s3.json`.** S3 authentication is **off by default** in SeaweedFS
   (`weed/s3api/auth_credentials.go`). A bare tunnel ingress therefore publishes an
   unauthenticated read-write object store to anything that can reach the hostname. This is
   the single most dangerous default in the entire stack.
2. **Put Postgres or Redis behind the filer.** The default LevelDB filer is an unshareable
   single point of failure — it cannot be replicated and it cannot be failed over.

### The costs

- ~978k lines of Go, 20 commits/day, 54% from one person. You are adopting a large, fast-moving
  codebase with a bus factor of roughly one.
- OSS erasure coding is hardcoded at 10+4 and repair is **manual** (`ec.rebuild -apply`).
  Without a scheduled repair job, a failed volume is simply under-replicated, and you will not
  be told.
- No bucket notifications, no replication policies.
- Workers cannot reach its gRPC, and the 100 MB Worker body cap means uploads must be
  presigned and go direct from the browser or the runner.

### The honest assessment

SeaweedFS is the right answer because it is the only one that satisfies the conditional-write
requirement *and* is actively maintained *and* is Apache-2.0. It is also the component most
likely to page you at 3am. Ship it if you will own it; do not install it and forget it.

---

## RustFS: the tier-2 hedge

RustFS exists because MinIO's repository was archived. It fills that vacancy with a real
Reed–Solomon engine (GF(2⁸), 1 MiB blocks), ~78 S3 trait methods, and genuinely excellent
operator documentation.

Use it for **artifact and cache buckets** — objects you can write in ≤100 MB chunks, where a
create-if-absent is enough and you never need read-modify-write CAS.

Do not use it for celld's fleet bucket: `If-Match: <etag>` returns **501 NotImplemented**
(reported at `app/object/shared.rs` in the reviewer's clone; verify the path against your pinned tag, it has moved), so create-if-absent works but CAS does not.

Other caveats:

- 1.0 shipped 2026-09-16. Six weeks old at the time of writing.
- Open P1 bugs on the data path, including a scanner OOM on a single disk and a
  silent-data-corruption fix sitting in `Unreleased`.
- The repo states it was *"ported from MinIO's Go code"*, and MinIO is AGPL-3.0. The licence
  is cleanly Apache-2.0 and the CLA permits relicensing, but the provenance is worth knowing.
- Its own documentation tells you to turn off the reverse proxy in exactly the topology this
  design uses (a single ingress in front of the S3 gateway). Read that section before you
  deploy.

---

## MinIO: dead

`minio/minio` is archived — *"THIS REPOSITORY IS NO LONGER MAINTAINED"* — and the successor,
AIStor Free, is a proprietary licence limited to *"standalone mode (single-node deployments
without distributed clustering or high availability)"*, with redistribution prohibited.

Multi-node MinIO now means a paid subscription. Any tutorial that tells you to deploy a
MinIO cluster is out of date.

---

## What you lose by leaving R2

| Property | R2 | Self-hosted |
|---|---|---|
| Durability | eleven nines | whatever your replication actually achieves |
| Egress | free | your transit bill |
| Object lock / WORM | yes, but as R2 Bucket Locks, not the S3 API | yes (SeaweedFS, S3 API) |
| Bucket policies | no | yes (SeaweedFS) |
| Notifications | no | no |
| Ops burden | zero | real |
| Cost at 10 TB, 5 TB egress/mo | ~$150/mo | ~$0 + hardware amortisation |

The durability row deserves emphasis. R2 is designed for eleven nines because Cloudflare
replicates across its own infrastructure. Your 3-node SeaweedFS with EC 10+4 on one rack is
not that, and pretending otherwise is how people lose data. If the data matters, replicate
off-site, and test a restore.

---

## Layout

```
bucket: cfb-images       content-addressed OCI layers, immutable
bucket: cfb-cache        build caches, prefix per toolchain, evictable
bucket: cfb-artifacts    test output, binaries, reports
bucket: cfb-celld-<app>  celld fleet bucket, one per application, NEVER shared
```

The celld bucket is special: **the bucket controls the fleet**. Give its credentials access
to one fleet only, because a credential that can write the ownership records can take over
every cell in that fleet.

---

## Retention, because nobody does this until it costs money

| Bucket | Retention | Mechanism |
|---|---|---|
| `cfb-images` | forever, deduplicated by digest | content addressing |
| `cfb-cache` | 14 days since last read | lifecycle rule |
| `cfb-artifacts` | 90 days, or per-project | lifecycle rule |
| `cfb-celld-*` | forever | it is the fleet's state |

The cache bucket is where storage bills come from. A lifecycle rule is not optional.
