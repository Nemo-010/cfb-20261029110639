# 12 — Operations: backup, restore, access, capacity, upgrades

This document exists because revision 1 of this spec did not have it, and an adversarial
review correctly called that a blocker: the word "backup" appeared twice in the whole set,
both times inside a cost table. A design without a restore procedure is a design for launch
day, not for the two years after.

---

## 1. What state exists, and where the second copy is

Enumerate every piece of state and answer one question: **if this host dies right now, where
is the other copy?**

| State | Lives in | Second copy | RPO | RTO |
|---|---|---|---|---|
| Node inventory, jobs, audit | D1 | Cloudflare's own replication + `wrangler d1 export` nightly to R2 | 24 h | 1 h |
| Job definitions | D1 | same | 24 h | 1 h |
| Object data (images, cache, artifacts) | SeaweedFS | **off-site replica node**, different rack or site | 1 h | 4 h |
| celld fleet bucket | SeaweedFS bucket | **its own off-site replica** — it is the fleet's state | 1 h | 4 h |
| Nomad Raft | 3 servers, BoltDB on disk | Raft itself (quorum) + nightly snapshot to object storage | 24 h | 2 h |
| Incus database | Raft across cluster members | Raft quorum + `incus admin sql global .dump` nightly | 24 h | 2 h |
| headscale | SQLite on one host | nightly `sqlite3 .backup` to object storage | 24 h | 1 h |
| Cloudflare Worker code | Cloudflare | `wrangler versions` + this repo | 0 | 15 min |
| Secrets | Worker secrets + DO | **offline password manager**, break-glass | — | 1 h |

The rule: **any state with a single copy is a bug.** Three things above start with one copy
and need one added on day one — the headscale database, the Nomad snapshots, and the Incus
dump. None of them is hard; all of them are forgotten.

---

## 2. Backup

| What | How | Where | How often | Retention |
|---|---|---|---|---|
| D1 | `wrangler d1 export` | R2 bucket `cfb-backups` | nightly | 90 days |
| Nomad | `nomad operator snapshot save` | object storage, off-site | 6-hourly | 30 days |
| Incus | `incus admin sql global .dump` per member | object storage | nightly | 30 days |
| headscale | `sqlite3 headscale.db ".backup"` | object storage | nightly | 30 days |
| SeaweedFS objects | volume replication to an off-site node | second site | continuous | — |
| Config | this repo | git | per change | forever |

Everything except the object data is small. A full Nomad snapshot is tens of megabytes; the
Incus dump is similar; the headscale database is kilobytes. Put them all in one bucket, and
run the jobs as Nomad `sysbatch` so there is one scheduler to check rather than five cron
entries.

**The backup job is itself monitored.** A backup that has not run in 36 hours is a page, not
a warning — the failure mode where backups silently stop for a year is the one that ends
companies.

---

## 3. Restore — written, and rehearsed

Untested backups are not backups. Rehearse quarterly, on a scratch host, and write down the
time it took.

### Restore D1

```bash
wrangler d1 create cfb-restore
wrangler d1 import cfb-restore --file=cfb-2026-10-29.sql
# repoint the Worker binding, deploy, verify node count
```

### Restore Nomad

```bash
systemctl stop nomad        # all three servers
nomad operator snapshot restore nomad-2026-10-29.snap
systemctl start nomad       # one server first, confirm leader, then the others
nomad server members        # expect one leader, two followers
nomad node status           # expect all clients
```

Restoring Raft is the operation most likely to be done wrong under pressure. Practise it
once with a deliberately broken cluster.

### Restore Incus

```bash
incus admin sql global .dump > dump.sql     # the backup
incus admin sql global < dump.sql           # the restore, on a fresh member
```

The instances themselves live on the storage pool; the database is the inventory. Restoring
the database without the pool gives you a list of machines that do not exist, which is worse
than no list.

### Restore celld

celld's state **is** the bucket. Restore the bucket and the fleet reconstitutes:

1. Stop every celld node.
2. Restore the bucket to the last good state.
3. Start one node. Confirm it takes ownership of the cells you expect.
4. Start the rest.

**Never** start a node against a partially restored bucket. Half a fleet bucket is two owners
for one cell, which is silent corruption.

### The rehearsal log

Keep a file in the repo, `ops/restore-log.md`, with one line per rehearsal: date, what was
restored, how long it took, what went wrong. The first rehearsal always finds something.

---

## 4. Out-of-band access

Revision 1 said "if an action needs SSH it is out of scope" and then wrote ten runbooks that
all need a shell. That was wrong. The design has no *inbound* path by default, which is
correct, but it needs a *deliberate* one for the operator.

Three layers, in order of preference:

### Layer 1 — the overlay (normal path)

`ssh` to the node's overlay address. This is the everyday path and it is already encrypted and
already authenticated. It is not out-of-band: if headscale is down, it does not work.

### Layer 2 — `cloudflared access ssh` (when the overlay is broken)

```bash
cloudflared access ssh --hostname ssh-node-01.cfb.example.com
```

An SSH hostname route on the tunnel, gated by Cloudflare Access with a short-lived service
token. This works when the overlay does not, because it uses a different path — which is the
whole point of out-of-band.

Add exactly one of these per site, on the gateway host. Not one per node.

### Layer 3 — the physical/console path (when Cloudflare is down)

Whatever the provider gives you: IPMI, a serial console, a KVM-over-IP, or a person with a
laptop. Document the credential location and **test it once a year**. This is the layer
everybody forgets and everybody needs exactly once.

### The rule

| Failure | Path |
|---|---|
| A node is unhealthy | overlay SSH |
| The overlay is broken | `cloudflared access ssh` |
| Cloudflare is down | console / physical |
| The gateway host is down | console, then rebuild the gateway |

---

## 5. Capacity

Three numbers per resource: current, growth per month, headroom in months. A written trigger,
not a vibe.

| Resource | Measure | Add capacity at | Lead time |
|---|---|---|---|
| Storage bytes | bytes stored, per bucket | **70% of usable** | 6 weeks |
| Storage IOPS | p95 latency on the volume tier | p95 > 20 ms | 6 weeks |
| CI capacity | queued jobs, oldest job age | oldest > 10 min sustained | 2 weeks |
| Overlay nodes | node count | 200 (peer-map rebuild cost) | 1 week |
| Nomad nodes | node count per server | 200 per server | 1 week |

**Measure bytes per build and per artifact on day one of Phase 3** and write the number down.
It turns the first capacity decision into arithmetic instead of panic. For a typical Go or
Node project expect 200 MB–2 GB per build in cache and artifacts; a monorepo can be 20× that.

### The storage arithmetic that matters

`usable = raw × (1 - EC overhead) × (1 - 0.2 reserve)`

With replication rather than EC on a 3-node cluster (see below), usable is **one third of
raw**. Twelve 20 TB drives per node is 240 TB raw, 80 TB usable. That is the number to put in
front of anyone who asks why the storage bill looks like that.

---

## 6. Erasure coding: the correction

Revision 1 recommended EC 10+4 on a 3-node cluster. That is wrong and would have caused data
loss.

**EC 10+4 needs at least 14 shards, and to survive one node's failure no node may hold more
than 4 of them.** 14 ÷ 4 = 3.5, so a 3-node cluster cannot satisfy it: losing one node loses
~4.7 shards, more than the 4 parity shards, and the object is unreadable.

| Cluster size | Correct durability mechanism |
|---|---|
| 1 node | none. It is a single point of failure; say so. |
| 2 nodes | replication across the two; still no quorum for the master |
| 3 nodes | **replication**, not EC. One copy plus one on a different rack. |
| 5+ nodes, 2+ racks | EC 10+4 is viable |
| 5+ nodes, one rack | EC protects against disk loss, not node loss. Say which one you bought. |

And EC repair is **manual** in the OSS build (`ec.rebuild -apply`). Without a scheduled repair
job a failed volume is simply under-replicated and nobody is told. Schedule it, and monitor
the backlog.

---

## 7. Upgrades

Six stateful systems, each with its own upgrade story. The order matters because of
dependencies.

| Order | Component | Method | Rollback |
|---|---|---|---|
| 1 | headscale | stop, replace binary, start | keep the previous binary and the pre-upgrade DB copy |
| 2 | SeaweedFS | one node at a time, never during a rebuild | pin the previous image tag |
| 3 | Nomad | servers one at a time, wait for leader | Raft snapshot restore |
| 4 | Incus | one member at a time | `snap`/`apt` downgrade, DB dump |
| 5 | celld | one node at a time; cells hand off | redeploy the previous bundle |
| 6 | Firecracker | drain the node, replace, undrain | pin the kernel and FC version together |

**Rules that are not negotiable:**

- Never upgrade two components in one window.
- Never upgrade storage while an EC rebuild is running.
- Never upgrade Nomad and its clients in the same window — upgrade servers, wait a day, then
  clients.
- Pin every version in the repo. A floating tag is an unplanned upgrade.

### The version file

One file, `ops/versions.env`, with the exact version of every component. It is the thing you
read when rebuilding a node from scratch, and the thing you diff when something changes
behaviour for no reason.

---

## 8. Staffing, stated honestly

Revision 1 priced 0.5 FTE across 27 nodes, which is 54.6 nodes per person. That is not a
defensible number for a fleet with six stateful systems, two of them beta, one of them
single-maintainer upstream.

The honest minimum is **one full-time person who owns this**, with a second who can cover
holidays and on-call. Below that, you are one illness away from an unmaintained fleet.

What that person does, week to week:

- patch and upgrade the six components, in order, without breaking quorum
- watch the CAS probe, the EC backlog, and the storage headroom
- handle the two or three real incidents a quarter
- answer "why is this build slow" — which is almost always the cache
- keep the restore rehearsal on the calendar

That is a job. Price it as one. If you cannot, the correct answer is to keep paying
Cloudflare, because an unowned fleet is more expensive than a managed one — just in a way that
arrives all at once.

---

## 9. Day two, in one table

| Question | Answer |
|---|---|
| Who is on call? | named, with a rota, before the first node is enrolled |
| Where are the credentials? | offline manager, with a break-glass path |
| How do I know it is broken? | five signals, listed in `10-failure-modes.md` |
| How do I get in? | overlay → tunnel SSH → console |
| How do I restore? | section 3, rehearsed quarterly |
| How do I know it is full? | section 5, with a written trigger |
| How do I upgrade? | section 7, one component at a time |
| Who owns it? | one named person, and their cover |

If any row is blank, the design is not finished — regardless of how good the architecture
diagram looks.
