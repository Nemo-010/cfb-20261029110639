# 01 — The portability contract

Requirement: application source runs on Cloudflare, on self-hosted hardware, or on a hosted
backend, with as little change as possible.

That is only achievable if the portability surface is **defined, enumerated and enforced**.
This document defines it.

---

## Two levels, and only one of them is a runtime swap

The requirement is usually read as "swap the whole platform". That is not achievable and
pretending otherwise is how these projects fail. There are two distinct levels:

| Level | What changes | Who does it |
|---|---|---|
| **Application runtime** | the platform the app process runs on | you, once |
| **Capability** | storage, sandbox, queue, actor backend behind an interface | the adapter |

The application runtime has exactly **two** real targets: Cloudflare Workers, and
`workerd` (optionally with celld for Durable Objects). Nothing else runs Workers code — not
Rivet, not E2B, not Kubernetes. Those are *capability* backends, not runtime substitutes, and
conflating them is the mistake to avoid.

So: **the runtime swap is a one-time decision; the capability swaps are per-deployment and
free.**

---

## Level 1 — the Portable Workers Subset

Code inside `PWS` runs on both runtimes from one source file.

| API | Cloudflare | workerd + celld | Portable |
|---|---|---|---|
| ESM `fetch` handler, `env`, `ctx` | yes | yes | **yes** |
| `vars` | yes | yes | **yes** |
| KV | yes | yes | yes — consistency differs, semantics do not |
| R2 / S3 | yes | yes | yes, unless presigned or public URL |
| D1 | yes | yes | yes, single-statement only |
| Queues (produce + consume) | yes | yes | yes, no pull consumers |
| Durable Objects + SQLite | yes | yes | yes, no `jurisdiction` |
| DO alarms | yes | yes | **yes** |
| WebSockets + hibernation | yes | yes | yes, reconnect on cell move |
| Service bindings | yes | yes | yes, no stub passing |
| Workflows | yes | yes | yes, without `schedules` |
| Cron Triggers | yes | yes | yes, plain expressions |
| HTMLRewriter | yes | yes | **yes** |
| WebAssembly | yes | yes | **yes** |
| Static assets | yes | yes | yes, no `.assetsignore` |
| `ctx.waitUntil` | yes | yes | **yes** |

Verified 2026-10-29 against celld's compatibility document and Cloudflare's runtime API
reference.

### The 13 forks

| # | Fork | Adapter surface |
|---|---|---|
| 1 | Service-worker syntax | rewrite once |
| 2 | Cache API (always-miss on celld) | `cache` |
| 3 | `node:crypto` ciphers, DH, RSA-PSS, DSA | `crypto` |
| 4 | Web Crypto P-384/P-521, RSA-PSS, secret JWK export | `crypto` |
| 5 | `request.cf` geo/colo/TLS | `geo` |
| 6 | `performance.now()` as a monotonic clock | `clock` |
| 7 | R2 presigned URLs, public URL, `ssecKey` | `storage` |
| 8 | D1 `dump()`, read replicas, `BEGIN`/`ATTACH` | `sql` |
| 9 | Queues pull consumers, HTTP API | `queue` |
| 10 | Workflow `schedules`, rollback, stream results | `workflow` |
| 11 | Cron descending ranges, `*` inside a list | rewrite once |
| 12 | DO `jurisdiction`, class rename migrations | rewrite once |
| 13 | Workers AI, Vectorize, Hyperdrive, Browser Rendering | no equivalent |

Items 1, 11 and 12 are one-time rewrites with no adapter. Item 13 has no self-hosted
equivalent: a workload that needs it is Cloudflare-only, and saying so is cheaper than
pretending.

---

## Level 2 — capability adapters

Each capability is an interface with N implementations. The application calls the interface.

| Capability | Cloudflare | Self-hosted | Hosted third party |
|---|---|---|---|
| `storage` | R2 binding | S3 (R2, SeaweedFS, RustFS, Garage, MinIO) | Backblaze B2, Tigris |
| `sql` | D1 | SQLite via celld, or Postgres | Neon, Turso |
| `queue` | Queues | celld Queues | — |
| `sandbox` | Sandbox SDK | Firecracker via the agent | **E2B Cloud** |
| `actors` | Durable Objects | celld DOs | **Rivet Cloud** |
| `cache` | Cache API | no-op | — |
| `secrets` | Worker secrets | celld `vars` + external store | — |

The third column is the point of this revision. **E2B and Rivet are capability backends, not
runtime substitutes:**

- **E2B** gives you sandboxed execution. It does not run Workers code. Use it as the `sandbox`
  adapter when you want microVMs without operating Firecracker — one machine per install, and
  multi-node is commercial.
- **Rivet** gives you actors. It does not run Workers code either: its API is its own, so an
  app written for `DurableObject` needs rewriting to use it. It is a legitimate `actors`
  adapter for *new* code, not a swap for existing code.

Being explicit about this is what stops the design from promising a portability it cannot
deliver.

---

## What actually changes when you swap

| Swap | Source change | Config change |
|---|---|---|
| Cloudflare → workerd (PWS-only app) | **0 lines** | `wrangler.jsonc` bindings |
| Cloudflare → workerd (uses 2 forks) | adapter only, ~40 lines, written once | bindings |
| R2 → SeaweedFS | **0 lines** | `STORAGE_URL` |
| Cloudflare Sandbox → E2B Cloud | `sandbox` adapter implementation | API key, endpoint |
| Durable Objects → Rivet | **rewrite the actor code** | SDK, config |
| Any → any, for an app outside PWS | rewrite that feature | — |

The last two rows are the honest limits. Everything above them is a config change.

---

## The adapter

One package, `@cfb/port`. It is the only place a backend check exists.

```
port
├── storage   get/put/delete/list/presign
├── sql       query/batch/migrate
├── cache     get/put (may always miss)
├── queue     send/consume
├── sandbox   run(code, limits) -> exit, logs
├── actors    namespace(id) -> object
├── crypto    hash, hmac, sign, encrypt
├── clock     now, monotonic
├── geo       country, colo, tls
└── secrets   get(name)
```

Backends are registered, not branched:

```
backend = env.CFB_BACKEND        # "cloudflare" | "selfhosted" | "hybrid"
adapters = registry[backend]
```

`hybrid` is a real configuration and probably the common one: Cloudflare runtime, E2B for
sandboxes, SeaweedFS for storage. The registry exists so that combination is a config file
rather than a code change.

---

## Enforcement

A contract nobody checks is a comment.

1. **Lint.** A rule bans `caches.default`, `request.cf`, `env.BUCKET`, `presigned` and direct
   `new DurableObject` outside `packages/port/`.
2. **Dual build.** CI builds the app twice — Cloudflare and `workerd` — and runs the same test
   suite against both. A test that passes on one is a portability bug.
3. **Fork tests.** Each of the 13 forks has a test named `portability/fork-NN` that fails if the
   adapter stops covering it.
4. **Runtime assertion.** `env.CFB_BACKEND` is set by the platform, not the app; the adapter
   throws if it is missing or unknown.

---

## What portability does not buy

| Not portable | Why |
|---|---|
| Performance | Cloudflare runs in 300+ locations; your node runs in one |
| Consistency | KV is eventually consistent on Cloudflare, strong on celld; code that depends on either is not portable |
| Secrets handling | celld has no secret store; values land in `vars` and are plaintext in the deployment |
| Networking | Cloudflare terminates TLS globally; self-hosted gives you what the gateway gives you |
| Workers AI | no equivalent anywhere |

The contract is about **source**, not behaviour. State that plainly, because the first person
who assumes otherwise ships a bug that appears on one side only.
