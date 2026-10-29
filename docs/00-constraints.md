# 00 — What is being replaced, and the numbers that decide it

Every figure here was fetched from the primary source on **2026-10-29**. Prices and limits
on the Cloudflare platform change without much notice; re-verify before committing money.

---

## The workload

Two shapes, and they have opposite requirements:

1. **Heavy CI.** Bursty, CPU-bound, minutes-to-hours, needs a Docker daemon, needs a large
   image with toolchains, needs to survive a 40-minute compile, needs artifacts to land
   somewhere durable.
2. **Long-running containers.** Persistent, low-CPU, stateful, must not be killed because
   nothing talked to it for a while.

Neither is request-shaped. Both are being run today on products designed for request-shaped
work, which is the actual problem.

---

## R2

| | |
|---|---|
| Standard storage | $0.015 / GB-month |
| Infrequent Access | $0.01 / GB-month |
| Class A ops | $4.50 / million (IA $9.00) |
| Class B ops | $0.36 / million (IA $0.90) |
| Egress | **free** |
| Free tier | 10 GB-month, 1M Class A, 10M Class B |

Source: <https://developers.cloudflare.com/r2/pricing/> —
*"Egress (data transfer to Internet) | Free"*.

Limits: 5 TiB object (4.995 TiB exactly), 1,000,000 buckets per account, unlimited stored
data. Source: <https://developers.cloudflare.com/r2/platform/limits/>.

Two things matter more than the headline rate:

- **Usage rounds up to the billing unit.** *"If you have used 1.1 GB-month, you will be
  billed for 2 GB-month."* For many small buckets or churny artifact storage this, not the
  rate, sets the bill.
- **The S3 API is partial.** `PutBucketPolicy`, `PutBucketAcl`, `PutBucketVersioning`,
  `PutObjectLockConfiguration`, `PutBucketReplication`, `PutBucketLogging`,
  `PutBucketNotificationConfiguration` and `PutBucketWebsite` are unimplemented
  (<https://developers.cloudflare.com/r2/api/s3/api/>). No ACLs, no bucket policies, no
  replication, no notifications, no static hosting.

  **But R2 does have retention.** It is not exposed through the S3 Object Lock API; it is a
  separate first-class feature called Bucket Locks: *"Bucket locks prevent the deletion and
  overwriting of objects in an R2 bucket for a specified period — or indefinitely"*
  (<https://developers.cloudflare.com/r2/buckets/bucket-locks/>). So "R2 has no WORM" is
  wrong. What it lacks is the *S3-compatible* object-lock API that third-party tools expect,
  which matters only if your tooling drives it through the S3 API rather than R2's own.

**Verdict:** R2 is the one Cloudflare product in this list that is genuinely hard to beat.
Free egress is worth more than any self-hosted saving unless you own transit. Replace it only
if you are moving more than ~80 TB, or if you need object lock / bucket policies that R2
does not implement.

---

## Containers (and Sandbox)

| | |
|---|---|
| Largest instance | standard-4: 4 vCPU / 12 GiB / 20 GB |
| Memory:vCPU floor | 3 GiB per vCPU |
| Account concurrency | 6 TiB memory, 1,500 vCPU, 30 TB disk |
| **Total image storage per account** | **50 GB** |
| CPU | $0.000020 / vCPU-second |
| Memory | $0.0000025 / GiB-second |
| Disk | $0.00000007 / GB-second |

Sources: <https://developers.cloudflare.com/containers/platform/limits/> and
<https://developers.cloudflare.com/containers/platform/pricing/>.

The lifetime behaviour is the constraint people get wrong in both directions, so state it
precisely. From <https://developers.cloudflare.com/sandbox/concepts/lifetime/>, verbatim:

> **Code that runs inside the instance does not count as activity.** If no requests arrive,
> the instance stops when the inactivity timeout ends, even while a build, a test suite, or
> an agent task still runs inside it.

But from the Containers FAQ (<https://developers.cloudflare.com/containers/faq/>):

> Cloudflare does not stop a container instance after a fixed maximum runtime. With the
> Durable Object Container API, call `setInactivityTimeout()` to stop an inactive container.
> The `Container` class sets `sleepAfter` to 10 minutes by default.

So the accurate picture is:

- There is **no fixed maximum runtime.** "6 hours" is the largest *inactivity timeout* you can
  set, not a runtime cap.
- The default `Container` class sleeps after **10 minutes** of no activity, and its
  `onActivityExpired()` hook can be overridden.
- A Durable Object alarm that fires more often than the timeout is the documented way to keep
  an instance alive through a long build.

What you cannot override on the standard plan: 4 vCPU / 12 GiB / 20 GB per instance, 50 GB of
image storage per account, ephemeral disk (a snapshot saves the root filesystem only, not
memory or processes, and expires 30 days after creation or last restore), and the fact that
*"Cloudflare does not guarantee that any container instance will run for a set period"* —
host events can stop it.

**Verdict:** workable for a long job, with a keep-alive you must own and an interruption
model you must design around. The blockers are the instance ceiling and the image budget, not
a runtime limit. That is a narrower objection than it first appears, and it matters because
the cost argument is close to neutral — see [`09-cost.md`](09-cost.md).

---

## Workers (and Workers Builds, the "CI" product)

| | Free | Paid |
|---|---|---|
| CPU per request | 10 ms | 5 min max (default 30 s) |
| Memory | 128 MB | 128 MB |
| Subrequests | 50 | 10,000 |
| Simultaneous outbound connections | 6 | 6 |
| Worker size (uncompressed) | 64 MiB | 64 MiB |
| Floor price | — | $5/month minimum |

Source: <https://developers.cloudflare.com/workers/platform/limits/>.

Workers Builds, from
<https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/>:

| | Free | Paid |
|---|---|---|
| Build minutes | 3,000/month | 6,000/month, then $0.005/min |
| Concurrent builds | 1 | 6 |
| **Build timeout** | **20 minutes** | **20 minutes** |
| vCPU / RAM / disk | 2 / 8 GB / 20 GB | 4 / 8 GB / 20 GB |

20 minutes and 6 concurrent builds. The build image is fixed and no Docker daemon is
documented. This is a "build my Worker and deploy it" service, not CI.

**Verdict:** Workers is a *correct* choice for the dashboard and a wrong one for anything
else. The 128 MB isolate is the number that decides it.

---

## Durable Objects

| | |
|---|---|
| Requests | 1M/month included, then $0.15/M |
| Duration | 400,000 GB-s/month included, then $12.50/M GB-s |
| Duration billing | flat 128 MB allocation regardless of actual use |
| SQLite rows written | 50M/month included, then **$1.00/M** |
| SQLite storage | 5 GB-month included, then $0.20/GB-month |
| Per-DO storage cap | 10 GB (paid), 1 GB (free) |

Source: <https://developers.cloudflare.com/durable-objects/platform/pricing/>.

DOs are an excellent primitive and a bad database. The trap is rows written: a scheduler
that writes a row per state transition, per heartbeat and per lease renewal will spend more
on rows than on compute. 1M jobs × 30 heartbeats = 30M rows = $30/month before a single read.

**Verdict:** keep DOs for the dashboard's per-machine coordination state, where the write
volume is human-scale. Do not build a job queue on them.

---

## Connectivity

| | |
|---|---|
| `cloudflared` tunnels per account | 1,000 |
| Tunnels beyond that | $4.50/tunnel/month |
| Routes (CIDR + hostname) per account | 50,000 (shared with Mesh) |
| Active replicas per tunnel | 25 |
| **Mesh nodes per account** | **50** |

Sources: <https://developers.cloudflare.com/cloudflare-one/account-limits/>,
<https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/>.

Tunnel public hostnames support HTTP, HTTPS, UNIX, TCP, SSH, RDP, SMB — all over WebSocket.
**No UDP.** For UDP you need Spectrum, a separate product. Private-network routes (the
WARP/Mesh path) do carry TCP and UDP, but see the 50-node cap.

Workers VPC (<https://developers.cloudflare.com/workers-vpc/>) is the piece that makes the
dashboard work: *"Workers VPC is currently in beta. Features and APIs may change before
general availability. While in beta, Workers VPC is available for free to all Workers plans."*
It offers `vpc_services` (bind a specific host:port) and `vpc_networks` (bind a whole tunnel,
Mesh network, or WAN on-ramp), with HTTP via `fetch()` and raw TCP via `connect()`.

**Verdict:** one tunnel per site, Workers VPC for the control path, and something else
entirely for machine-to-machine.

---

## The summary that drives everything

| Product | Cost problem? | Capability problem? | Keep or replace |
|---|---|---|---|
| R2 | only above ~80 TB | object lock, bucket policies missing | **keep** unless you are large |
| Containers / Sandbox | yes | **fatal** — instance dies mid-build | replace |
| Workers (dashboard) | no | no | **keep** |
| Workers Builds | yes | **fatal** — 20 min, 6 concurrent | replace |
| Durable Objects | at volume | 10 GB per object | keep for coordination, not queues |
| Tunnel / VPC | at scale | 50-node Mesh cap | keep for control, replace for data |

The design in this repo replaces the two rows marked "fatal", keeps the rows marked "keep",
and is explicit that the R2 row is a judgement call rather than an obvious win.
