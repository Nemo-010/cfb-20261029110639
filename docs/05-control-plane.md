# 05 — Control plane

One Worker: static SPA, JSON API, D1 for desired state, R2 for logs. It holds every credential
and is the only thing that talks to agents.

---

## Shape

```
cfb-manager (one Worker)
├── Static Assets     dist/ — SPA, no SSR
├── /api/*            Hono
├── NodeDO            one per node: live connection, streams, leases
├── D1                desired state, job history, audit
├── R2 (LOGS)         build logs
└── vpc_networks      SITE — reaches agents without a public hostname
```

### Why the manager stays on Cloudflare

It is the one component whose traffic profile matches the platform exactly: small requests,
global, low CPU, and it must be up when the fleet is not. A manager that lives on the hardware
it manages is useless precisely when you need it.

The cost is a hard dependency on Cloudflare for the control plane. That is the trade, and it
is better than the alternative.

### Why a SPA and not SSR

Static Asset requests are free and unlimited. No SSR means no Node compatibility layer, no
fight with the 64 MiB Worker limit, and no framework upgrade treadmill. The dashboard is an
authenticated operator console; it needs none of what SSR provides.

---

## Desired state

D1 holds **intent**. The node holds **reality**. They are reconciled, never merged.

```sql
CREATE TABLE nodes (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  capabilities TEXT NOT NULL,      -- JSON array
  labels       TEXT NOT NULL,      -- JSON object
  state        TEXT NOT NULL,      -- pending|ready|stale|draining|revoked
  last_seen    INTEGER,
  conn_id      INTEGER
);

CREATE TABLE workloads (
  id           TEXT PRIMARY KEY,
  node_id      TEXT,
  spec         TEXT NOT NULL,      -- JSON: image, cpu, memory, mounts, env, restart
  state        TEXT NOT NULL,      -- pending|starting|running|succeeded|failed|stopped
  generation   INTEGER NOT NULL,   -- bumped on every spec change
  updated_at   INTEGER
);

CREATE TABLE jobs (
  id            TEXT PRIMARY KEY,
  workload_id   TEXT,
  idempotency   TEXT UNIQUE,       -- submit key
  exit_code     INTEGER,
  started_at    INTEGER,
  finished_at   INTEGER
);

CREATE TABLE audit (
  at      INTEGER,
  actor   TEXT,
  action  TEXT,
  target  TEXT,
  outcome TEXT
);
```

`generation` is the important column. An agent reports the generation it is running; if it is
lower than D1's, the agent is behind and the control plane pushes the spec again. That single
integer removes most reconciliation bugs.

---

## The reconcile loop

```
every 15 s, per connected node:
  desired = SELECT * FROM workloads WHERE node_id = ?
  agent   = last reported state
  diff    = desired − agent
  if diff: push
```

Push, do not pull. The agent has a live connection, so there is no reason to make it poll.
The 15 s interval only exists to catch a missed push.

On reconnect, the agent sends a full state report and the control plane diffs from scratch.
That is the recovery path, and it must be idempotent — starting a workload that is already
running must be a no-op, not a second copy.

---

## Placement

```ts
function place(w: Workload, nodes: Node[]): Node | null {
  const candidates = nodes.filter(n =>
    n.state === "ready" &&
    n.capabilities.includes(w.requiredCapability) &&
    n.freeMemoryMiB >= w.memoryMiB &&
    n.labels.includes(w.labels)
  );
  return candidates.sort((a, b) => b.freeMemoryMiB - a.freeMemoryMiB)[0] ?? null;
}
```

That is the entire scheduler. Filter, sort, pick. It is correct for CI and services below a
few hundred nodes, and it is one query instead of a second control plane.

---

## The API

`spec/api.yaml`. Shape:

```
GET    /api/v1/nodes                     list with health
POST   /api/v1/nodes/enroll              mint a one-time token
POST   /api/v1/nodes/{id}/drain          stop accepting new workloads
POST   /api/v1/nodes/{id}/revoke         revoke credential

GET    /api/v1/workloads                 list
PUT    /api/v1/workloads/{id}            upsert spec (idempotent, bumps generation)
DELETE /api/v1/workloads/{id}            stop and remove

POST   /api/v1/jobs                      submit one-shot (Idempotency-Key required)
GET    /api/v1/jobs/{id}                 status
GET    /api/v1/jobs/{id}/logs            SSE, cursor-based
POST   /api/v1/jobs/{id}/cancel          cancel

POST   /api/v1/storage/presign           presigned PUT/GET
GET    /api/v1/audit                     append-only
```

Three rules:

1. **No request waits for a workload operation.** Submit, return 202, let the DO poll.
2. **Every mutation takes an idempotency key.** The VPC path has no stream resumption, so
   retries are normal.
3. **Errors carry `code` and `retryable`.** `503 vpc_degraded {retryable:true}` is actionable;
   a 500 is not.

---

## The DO

One per node. Holds the live connection state, the open streams, and the log fanout.

```ts
export class NodeDO {
  connId: number
  sockets: WebSocket[]
  streams: Map<number, { kind: string, buffer: Ring }>
  leases: Map<string, number>

  async onConnect(connId: number)   // fence the predecessor
  async onStateReport(s: Report)    // diff and correct
  async streamLog(jobId: string, cursor: string)
}
```

**Not** the job ledger — that is D1, written on transition only. The reason is billing: DO
duration bills a flat 128 MB allocation, and SQLite rows written cost $1.00/million. A log
line per row is 120,000 rows for a 40-minute build.

Hibernate the DO between requests; use `accept()`ed WebSockets only while a dashboard is
actually streaming.

---

## Connectivity

`vpc_networks` binding, one per site. The Worker reaches agents over the tunnel with no public
hostname:

```jsonc
"vpc_networks": [{ "binding": "SITE", "tunnel_id": "<uuid>", "remote": true }]
```

Two caveats that cost a day each:

- The tunnel must run **QUIC** with outbound UDP 7844 open. An `http2` tunnel silently breaks
  VPC resolution while looking healthy.
- Workers VPC is **public beta and free while beta**. Keep the fallback (public hostname plus
  an Access service token) implementable behind a flag.

**Every VPC call goes through one allowlist function.** The destination is a runtime string; a
route that builds it from user input is an SSRF primitive with a route into your network.

```ts
const ALLOWED = { node: { host: "10.96.0.5", ports: [7844] } };
function vpcFetch(t: keyof typeof ALLOWED, path: string) { /* host and port pinned */ }
```

A lint rule enforces that `env.SITE.fetch` appears exactly once.

---

## Auth

| Identity | Mechanism | Scope |
|---|---|---|
| Operator | Cloudflare Access JWT | dashboard |
| CI | API token, hashed in D1 | submit jobs, read own jobs |
| Agent | node credential, issued at enrolment | its own node only |

The Worker holds the storage credential and the agent credential. The browser holds neither.

---

## Degradation

| Substrate | Dashboard |
|---|---|
| Agent disconnected | last-known state, actions disabled |
| VPC degraded | banner, actions 503 with `retryable` |
| D1 unavailable | read-only from cache |
| Cloudflare outage | dashboard gone; **fleet keeps running** |

The last row is the whole point of keeping the data plane off Cloudflare. The worst case is
"I cannot see my fleet", never "my fleet stopped".
