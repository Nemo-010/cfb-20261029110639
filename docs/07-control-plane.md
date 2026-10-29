# 07 — The control plane: a SPA on Workers

The manager is a single Worker that serves a static SPA and an API, and holds the only
credentials in the system.

---

## Shape

```
cfb-manager (one Worker)
├── Static Assets          dist/ — SPA, no SSR, no Node runtime
├── /api/*                 Hono router
├── NodeDO                 one Durable Object per enrolled node
├── D1                     inventory, jobs, audit
├── R2 (LOGS)              build logs, artifact index
├── Queues                 job dispatch, outbox
└── vpc_networks           SITE — reaches the private network
```

One Worker, not several. A second Worker means a second deploy, a second set of secrets and a
service binding you have to keep in sync, in exchange for nothing.

### Why a SPA and not SSR

- Workers Static Assets are **free and unlimited** for requests
  (<https://developers.cloudflare.com/workers/platform/pricing/>).
- No SSR framework means no Node compatibility layer, no bundle-size fight against the 64 MiB
  Worker limit, and no framework upgrade treadmill.
- The dashboard is a control surface for an authenticated operator. It does not need SEO,
  streaming SSR, or edge rendering.

Vite + React (or Svelte) + TanStack Query. The API is the contract; the SPA is a client of it.

---

## The API

Full sketch in [`../spec/openapi.yaml`](../spec/openapi.yaml). The shape:

```
GET    /api/v1/nodes                     list, with health
POST   /api/v1/nodes/enroll              mint a one-time enrolment token
POST   /api/v1/nodes/{id}/drain          Nomad node eligibility → ineligible
POST   /api/v1/nodes/{id}/revoke         revoke tokens, leave overlay
GET    /api/v1/nodes/{id}/health         DO-backed, cached 5 s

GET    /api/v1/jobs                      list, filter by state
POST   /api/v1/jobs                      submit (idempotency key required)
GET    /api/v1/jobs/{id}                 status + attempt list
GET    /api/v1/jobs/{id}/logs            SSE stream, cursor-based
POST   /api/v1/jobs/{id}/cancel          Nomad deregister

GET    /api/v1/machines                  Incus instances, cached view
POST   /api/v1/machines                  create VM/container from a profile
DELETE /api/v1/machines/{id}             delete

GET    /api/v1/buckets                   SeaweedFS buckets
POST   /api/v1/buckets                   create
POST   /api/v1/buckets/{name}/presign    presigned PUT/GET

POST   /api/v1/apps/{app}/deploy         celld deploy from an uploaded bundle
GET    /api/v1/apps/{app}/state          celld /state per node

GET    /api/v1/audit                     D1, append-only
```

### Three rules the API must follow

1. **No request waits for a substrate operation.** Submit, return 202, let the DO poll. A
   Worker has 5 minutes of CPU and a client has less patience. Every long operation is a
   resource with a state, not a hanging request.
2. **Every mutating call takes an idempotency key.** The VPC path has no stream resumption,
   so retries are normal, not exceptional.
3. **Errors carry a machine-readable code and a retryable boolean.** `503 vpc_degraded
   {retryable: true}` is actionable. A 500 with a stack trace is not.

---

## The Durable Object model

One DO per node. It is the node's live state and its command channel.

```ts
export class NodeDO {
  // persisted
  nodeId: string
  site: string
  roles: string[]
  lastSeen: number
  leases: Map<string, { jobId: string, expiresAt: number }>

  // in-memory, rebuilt on wake
  sockets: WebSocket[]

  async heartbeat(addr: string, load: Load) { ... }   // alarm-driven, 30 s
  async streamLog(jobId: string, cursor: string) { ... } // SSE fanout
  async renewLease(jobId: string, ttl: number) { ... }
  async expireLeases() { ... }                        // alarm
}
```

**What the DO is for:** the live view — which nodes are up, which leases are held, which log
streams are open, and the fanout to connected browsers.

**What the DO is not for:** the job ledger. That is D1, updated on transition only.

The reason is billing. DO duration bills a flat 128 MB allocation regardless of use, and
SQLite rows written cost $1.00/million. A heartbeat that writes a row every 30 seconds is
2,880 rows per node per day — trivial. A log line per row is not: a 40-minute build emitting
50 lines/second is 120,000 rows, $0.12, for one job. Keep rows out of the log path; stream
through memory and persist only the summary.

### Hibernation

Use `accept()`ed WebSockets for the live dashboard, and hibernate. A DO that holds an
accepted WebSocket bills duration for the whole connection; one that hibernates does not.
The reconnect cost is a cursor-based resync, which the API already requires.

---

## Auth

Three distinct identities, three distinct mechanisms:

| Who | Mechanism | Scope |
|---|---|---|
| Operator (browser) | Cloudflare Access, in front of the Worker | whole dashboard |
| CI system | API token, `Authorization: Bearer`, hashed in D1 | submit jobs, read own jobs |
| Node agent | enrolment token (one-time) → long-lived node token in the DO | heartbeat, lease renew, log push |

The Worker holds the substrate credentials (Nomad ACL token, Incus client cert, SeaweedFS
admin key, celld token). The browser never sees them. This is the reason the Worker exists.

**Do not** put a Nomad ACL token in the SPA bundle. It will end up in a browser cache, a
screen share, and a support ticket.

---

## The relay problem, and the one place it is unavoidable

Two components cannot be driven directly by a Worker:

- **Incus** — mTLS does not survive `cloudflared` (no client-certificate origin option), and
  Incus reads `r.RemoteAddr` only, with no `X-Forwarded-For` support anywhere in its tree.
- **celld** — its internal listener must stay on the private network, and its worker listener
  expects a real client connection.

So the gateway host runs a small relay per component:

```
Worker ──VPC──▶ relay :8080 ──unix socket──▶ Incus
Worker ──VPC──▶ relay :8081 ──HTTP──▶ celld worker listener
```

The relay does four things: terminates OIDC, holds the client certificate, maps the Worker's
authorisation decision onto the substrate's model, and translates the substrate's operation
objects into something pollable. It is a few hundred lines of Go. It is also the component
most likely to become a security hole, so keep it stateless and log every decision.

---

## What the SPA shows

A control surface, not a monitoring product. Four screens:

1. **Fleet** — nodes, roles, health, last seen, current jobs. One row per node.
2. **Jobs** — a list with state, and a detail view with a live log tail.
3. **Machines** — Incus instances, with create/delete from a profile.
4. **Storage** — buckets, usage, presigned upload links.

Plus an audit log, because "who deleted that VM" is a question you will be asked.

Do not build a metrics dashboard. Point Grafana at the substrate and link to it.

---

## Deployment

```bash
npm run build            # SPA → dist/
wrangler deploy          # Worker + Static Assets + bindings
wrangler d1 migrations apply cfb --remote
```

One command, one artefact, no container build. The manager deploys faster than any component
it manages, which is the correct relationship.

### Secrets

```bash
wrangler secret put NOMAD_TOKEN
wrangler secret put INCUS_RELAY_TOKEN
wrangler secret put SEAWEEDFS_ADMIN_KEY
wrangler secret put CELLD_TOKEN
```

Stored encrypted at the edge, never in `wrangler.jsonc`, never in the repo.

---

## The 128 MB budget

The isolate has 128 MB and 5 minutes of CPU. The rules that follow:

- Never `await response.json()` on a large payload. Stream and transform.
- Never proxy a file through the Worker. Presign and redirect.
- Never buffer a build log. Stream it, or read it from R2 in ranges.
- Keep the SPA bundle under the Static Assets limits by not importing a UI framework twice.

If a feature needs to hold more than a few megabytes, it does not belong in the Worker.
That constraint is a feature: it keeps the control plane honest about being a control plane.
