# 04 — Storage is a URL

The agent does not ship a storage engine. It holds a `STORAGE_URL` and speaks S3 to it. That
makes storage a deployment decision rather than a component of the platform.

```
STORAGE_URL=s3://cfb-artifacts?endpoint=https://acct.r2.cloudflarestorage.com&region=auto
STORAGE_URL=s3://cfb-artifacts?endpoint=http://10.96.0.7:8333&region=us-east-1
```

Both work. The application code does not change. This is the portability contract applied to
storage.

---

## Choosing an endpoint

| Option | Fit | Caveat |
|---|---|---|
| **R2** | best default under ~80 TB | no presigned URL support in celld's binding; free egress |
| **SeaweedFS** | large, self-hosted, conditional writes | ~978k LOC, 59% one author, S3 auth **off** by default |
| **RustFS** | MinIO-shaped, Apache-2.0 | 1.0 shipped 2026-09; `If-Match` etag CAS returns 501 |
| **Garage** | simplest to operate | **no conditional writes, structurally** — disqualified for celld |
| **MinIO** | — | repository archived; AIStor Free is single-node only |
| **Backblaze B2 / Hetzner / DO Spaces** | cheap | no conditional writes; celld will split-brain |

The conditional-write requirement only matters if you run celld. It is the property celld uses
in place of consensus: a cell is owned by whoever wins a compare-and-swap on a small record.

| Store | `If-None-Match: *` | `If-Match: <etag>` |
|---|---|---|
| S3, R2, GCS, Azure, Tigris | yes | yes |
| SeaweedFS | yes | yes (owner-filer serialisation) |
| RustFS | yes | **501** |
| Garage | no | no — "structurally impossible … lack of a consensus algorithm" |
| B2, Hetzner, DO Spaces | no | no |

If you are not running celld, ignore this table and pick on cost.

---

## Layout

```
bucket: images       content-addressed OCI layers and rootfs, immutable, forever
bucket: cache        build caches, prefix per toolchain, 14-day lifecycle
bucket: artifacts    test output, binaries, reports, 90-day lifecycle
bucket: celld-<app>  one per celld fleet, never shared
bucket: logs         small; R2 is fine even if everything else is self-hosted
```

`logs` staying on R2 is deliberate: it is the one dataset you want readable when your site is
down, and it is small enough that the bill is noise.

The `celld-<app>` bucket is special — **the bucket controls the fleet**. Credentials for it
must be scoped to that one bucket, because a credential that can write ownership records can
take over every cell.

---

## Uploads never transit the control plane

A Worker has 128 MB of memory and a 100 MB request body limit. Proxying an artifact through it
is not an option, so every upload is presigned:

```
runner ──▶ agent ──presign──▶ S3 endpoint
runner ──PUT────────────────▶ S3 endpoint
```

The agent signs because it holds the storage credential; the control plane only ever sees the
object key. This is also why the storage endpoint must be reachable from the node — a
self-hosted store behind the same gateway is the normal case.

---

## Durability, stated honestly

R2 is designed for eleven nines because Cloudflare replicates across its own infrastructure. A
three-node self-hosted cluster is not that, and saying otherwise is how people lose data.

| Cluster | Correct mechanism |
|---|---|
| 1 node | none. Say it is a single point of failure. |
| 3 nodes | **replication**, not erasure coding |
| 5+ nodes, 2+ racks | EC 10+4 is viable |

Erasure coding on three nodes is a data-loss bug: EC 10+4 needs 14 shards and no node may hold
more than 4, so losing one node loses ~4.7 shards against 4 parity shards. If you want EC, you
need five nodes and two racks.

EC repair is manual in the open-source build. Without a scheduled repair job a failed volume is
simply under-replicated and nobody is told.

**If the data matters, replicate off-site and rehearse a restore.** An untested backup is a
hope, not a backup.

---

## Retention

| Bucket | Retention | Why |
|---|---|---|
| `images` | forever | content-addressed, deduplicated |
| `cache` | 14 days since last read | this is where the bill comes from |
| `artifacts` | 90 days, or per project | policy, not storage |
| `celld-*` | forever | it is the fleet's state |

A lifecycle rule on `cache` is not optional. It is the difference between a storage bill and a
storage incident.
