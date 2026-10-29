# 01 — The portability contract

The requirement is that application source runs on Cloudflare and on self-hosted hardware with
minimal change. That is only achievable if the portability surface is **defined and enforced**,
not hoped for.

---

## The subset

`PWS` — Portable Workers Subset. Code inside PWS runs on both runtimes from one source file.

| API | Cloudflare | workerd+celld | Source portable |
|---|---|---|---|
| ESM `fetch` handler, `env`, `ctx` | yes | yes | **yes** |
| `vars` | yes | yes | **yes** |
| KV | yes | yes | yes — consistency differs, semantics do not |
| R2 / S3 | yes | yes | yes, unless presigned or public URL |
| D1 | yes | yes | yes, single-statement only |
| Queues (produce + consume) | yes | yes | yes, no pull consumers |
| Durable Objects + SQLite | yes | yes | yes, no `jurisdiction` |
| DO alarms | yes | yes | **yes** |
| WebSockets + hibernation | yes | yes | yes, with reconnect on cell move |
| Service bindings | yes | yes | yes, no stub passing |
| Workflows | yes | yes | yes, without `schedules` |
| Cron Triggers | yes | yes | yes, plain expressions |
| HTMLRewriter | yes | yes | **yes** |
| WebAssembly | yes | yes | **yes** |
| Static assets | yes | yes | yes, no `.assetsignore` |
| `ctx.waitUntil` | yes | yes | **yes** |

Source: celld `docs/cloudflare-compat.md` and the per-service docs; Cloudflare
`developers.cloudflare.com/workers/runtime-apis/`. Verified 2026-10-29.

---

## The forks

Thirteen things force a source change. They are listed here so that the adapter, and only the
adapter, knows about them.

| # | Fork | Why | Adapter surface |
|---|---|---|---|
| 1 | Service-worker syntax | celld runs module Workers only | — (rewrite once) |
| 2 | Cache API | always-miss on celld | `port.cache` |
| 3 | `node:crypto` ciphers, DH, RSA-PSS, DSA | partial on celld | `port.crypto` |
| 4 | Web Crypto P-384/P-521, RSA-PSS, secret JWK export | partial on celld | `port.crypto` |
| 5 | `request.cf` geo/colo/TLS | absent on celld | `port.geo` |
| 6 | `performance.now()` as a monotonic clock | frozen clock on celld | `port.clock` |
| 7 | R2 presigned URLs, public URL, S3 endpoint, `ssecKey` | absent on celld | `port.storage` |
| 8 | D1 `dump()`, read replicas, `BEGIN`/`ATTACH`, multi-statement | absent on celld | `port.sql` |
| 9 | Queues pull consumers, HTTP API, R2 notifications | absent on celld | `port.queue` |
| 10 | Workflow `schedules`, rollback, stream step results | absent on celld | `port.workflow` |
| 11 | Cron with descending ranges or `*` in a list | rejected by celld | — (rewrite once) |
| 12 | DO `jurisdiction`, class rename migrations | rejected by celld | — (rewrite once) |
| 13 | Workers AI, Vectorize, Hyperdrive, Browser Rendering | absent | — (no equivalent) |

Items 1, 11 and 12 are one-time rewrites with no adapter: do them before the first deploy.
Item 13 has no self-hosted equivalent; a workload that needs it is Cloudflare-only, and saying
so is cheaper than pretending.

---

## The adapter

One package, `@cfb/port`, and it is the only place a runtime check exists.

```ts
// @cfb/port/src/index.ts
export interface Port {
  storage: StoragePort;
  sql: SqlPort;
  cache: CachePort;
  crypto: CryptoPort;
  clock: ClockPort;
  geo: GeoPort;
  queue: QueuePort;
}

export function port(env: Env, runtime: "cf" | "self"): Port {
  return runtime === "cf" ? cfAdapter(env) : selfAdapter(env);
}
```

Applications call `port(env, env.RUNTIME).storage.get(key)`. They never call
`env.BUCKET.get(key)` directly, and they never branch.

### `storage`

| | Cloudflare | self-hosted |
|---|---|---|
| get/put/delete/list | R2 binding | S3 SDK against `STORAGE_URL` |
| presigned PUT/GET | Worker-signed URL to R2 | agent-proxied URL |
| public URL | `r2.dev` or custom domain | gateway route |

Presigning is the one place the two diverge in behaviour, not just in implementation:
Cloudflare signs with its own key, self-hosted signs through the agent. Both return a URL the
browser can PUT to, which is all the application sees.

### `sql`

| | Cloudflare | self-hosted |
|---|---|---|
| query | D1 `prepare().bind().all()` | same API over SQLite |
| transaction | `batch()` | `batch()` |
| migrations | `wrangler d1 migrations` | `cfbd sql migrate` |

Single-statement only on both. If a workload needs `BEGIN`, it needs a different data store,
and that is a design decision rather than an adapter concern.

### `cache`

Cloudflare's Cache API is a CDN cache. celld's is always-miss. The adapter therefore treats
cache as **an optimisation with no correctness value** on both runtimes: `port.cache.get()`
may return `undefined` anywhere, and the application must work when it does. That is the
correct contract on Cloudflare too — a cache hit is never guaranteed.

### `clock`

`performance.now()` is frozen during JS execution on celld and monotonic on Cloudflare.
`port.clock.now()` returns `Date.now()` on both. Any code that needs a monotonic clock for
timeouts uses a timer, not a clock read.

---

## Enforcement

A contract nobody checks is a comment.

1. **Lint.** A custom rule bans `caches.default`, `request.cf`, `env.BUCKET` and
   `presigned` outside `packages/port/`. One regex, one CI job.
2. **Dual test.** CI builds the app twice — once for Cloudflare, once for `workerd` — and runs
   the same test suite against both. A test that only passes on one is a portability bug.
3. **Runtime assertion.** `env.RUNTIME` is set by the platform, not by the app, and the
   adapter throws if it is missing.
4. **Fork register.** Every item in the table above has a test named `portability/fork-NN` that
   fails if the adapter stops covering it.

---

## What portability does not buy

- **Identical performance.** Cloudflare runs in 300+ locations; your node runs in one.
- **Identical consistency.** KV on Cloudflare is eventually consistent; on celld it is strong.
  Code that depends on either is not portable, and the adapter does not fix it.
- **Identical secrets handling.** celld has no secret store; values land in `vars` and are
  plaintext in the deployment. Use the adapter's `port.secret()` and keep the real value out of
  the bundle.
- **Identical networking.** Cloudflare terminates TLS and gives you a global anycast address.
  Self-hosted gives you whatever the gateway provides.

The contract is about **source**, not about behaviour. State that plainly, because the first
person who assumes otherwise will be the one who ships a bug that only appears on one side.
