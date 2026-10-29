# Lane 08 — Control plane on Workers: SPA + API, D1/DO/KV/R2/Queues, Hono/Chanfana/itty-router, Drizzle, Access/OIDC, and reaching a machine behind a tunnel

Research date: **2026-10-29**. All Cloudflare facts fetched from `developers.cloudflare.com` on that date; all repo facts from the GitHub API via `forge.web.pkgforge.dev` on that date. Version numbers from `registry.npmjs.org`.

## Verdict

A Cloudflare-hosted control plane for remote machines is buildable today and the shape is not controversial: one Worker serving a React SPA from Static Assets plus a Hono API on the same origin, D1 + Drizzle for inventory and job history, one Durable Object per machine for the state machine and for live sockets, Cloudflare Workflows for anything that has to outlive a request, R2 for artifacts and logs, Queues only for fan-out dispatch, and Cloudflare Access in front of the whole thing. The one genuinely hard problem — a Worker calling an agent on a machine that has no public IP — now has a real answer: **Workers VPC**, a `vpc_networks` binding to `cf1:network` that lets the Worker `fetch()` or `connect()` any destination reachable through your Tunnel or Mesh. The single most important caveat is that **Workers VPC has been in beta since 2025-11-05 and still is (docs last revised 2026-10-12), is free only "during the open beta period", has no published GA date or price, and its `connect()` path is "plaintext TCP only" with WebSocket-over-VPC undocumented** — so the only GA, contractually-safe path from a Worker to a tunneled machine remains a public tunnel hostname plus an Access service token, which is exactly what you were trying to avoid. Second caveat, and it bites every implementation: **`ctx.access` is undefined in your API Worker when you use Static Assets**, because "the router does not pass `ctx.access` to the user Worker" — so every API route must validate the `Cf-Access-Jwt-Assertion` JWT itself.

## Findings

### SPA + API on one Worker is the correct topology, and it is one deployable

Workers Static Assets deploys the SPA bundle and the Worker script as a single unit (VERIFIED, https://developers.cloudflare.com/workers/static-assets/: *"Cloudflare deploys both your Worker code and your static assets in a single operation. This deployment operates as a tightly integrated 'unit'"*). SPA routing is a config flag: `"assets": { "directory": "./dist/", "not_found_handling": "single-page-application" }` (VERIFIED, https://developers.cloudflare.com/workers/static-assets/routing/single-page-application/).

The behaviour you must design around: with a compatibility date of `2025-04-01` or later, **navigation requests do not invoke your Worker script** (VERIFIED, same page: *"navigation requests will not invoke the Worker script"*). The docs are explicit that this produces a surprising result — `fetch("/api/date")` from the SPA hits the Worker, but typing `/api/date` into the address bar serves `index.html`. This is fine for a dashboard and is a billable-invocation saving, but it breaks any "paste this URL into the browser" API affordance. Set `assets.run_worker_first` if you want the Worker to run ahead of assets, e.g. to enforce auth before serving the SPA shell.

Static Assets limits (VERIFIED, https://developers.cloudflare.com/workers/platform/limits/#static-assets): **20,000 files per Worker version on Free, 100,000 on Paid; 25 MiB per individual file.** A Vite-built SPA is nowhere near this. Static asset requests are free and unlimited; only Worker invocations bill (VERIFIED, https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/).

### Routing/framework layer: Hono wins, Chanfana only if you need OpenAPI, itty-router only if you are counting bytes

Versions on 2026-10-29 (VERIFIED, `registry.npmjs.org`):

| package | latest | next | license | repo stars |
|---|---|---|---|---|
| `hono` | **4.13.14** (2026-10-25) | `5.0.0-rc.1` | MIT | 32,740 |
| `chanfana` | **3.4.2** (2026-10-27) | — | MIT | 773 |
| `itty-router` | **5.0.24** (2026-06-08) | `5.0.12-next.0` | MIT | 2,051 |
| `@hono/cloudflare-access` | **0.4.0** (2026-04-13) | — | (in `honojs/middleware`) | — |
| `jose` | **6.2.14** (2026-10-29) | — | — | — |

Hono's practical advantage here is not routing speed, it is that the middleware you need for a control plane already exists and is typed: `bearer-auth`, `jwt`, `cors`, `logger`, `request-id`, `secure-headers`, plus third-party `@hono/cloudflare-access` and `@hono/oidc-auth` (VERIFIED, https://hono.dev/docs/middleware/third-party). Hono 5 is still an RC — **pin to 4.x for this build.**

`@hono/cloudflare-access` does the JWT work you would otherwise hand-roll: it takes team name + AUD tag and verifies the token, exposing `c.get('accessPayload')` (VERIFIED, https://github.com/honojs/middleware/tree/main/packages/cloudflare-access). It accepts an array of AUDs, which you need the moment you have both a production and a preview Access application. Its error table returns 401 for bad/expired/wrong-audience tokens — but note it returns **500** for `"The Access Organization 'my-team-name' does not exist"`, so a typo in the team name looks like an outage, not a config error.

Chanfana (Cloudflare's own, formerly `itty-router-openapi`) is a class-based OpenAPI 3/3.1 generator that *extends* an existing Hono or itty-router app without taking it over (VERIFIED, https://github.com/cloudflare/chanfana). Take it only if you actually want a machine-readable spec — it adds Zod v4, `@asteasolutions/zod-to-openapi`, `js-yaml`, `yargs-parser` and an opinionated endpoint class model. For a dashboard API with ~40 routes, Hono + `zod` directly is less machinery.

itty-router is 2 KB and has no dependencies (`dependencies: {}` for `5.0.24`, VERIFIED from the registry), but no middleware ecosystem and no OpenAPI. It is the wrong choice once you need auth middleware, request IDs and validation.

### D1 + Drizzle: fine for inventory and job history, and it will not do two things you will want

Drizzle's own D1 guide now tells you to install **`drizzle-orm@rc` / `drizzle-kit@rc`** (VERIFIED, https://orm.drizzle.team/docs/get-started/d1-new). That is `1.0.0-rc.5` — while `latest` on npm is still `0.45.4` (VERIFIED, `registry.npmjs.org/drizzle-orm` dist-tags: `latest: 0.45.4`, `rc: 1.0.0-rc.5`). So the official D1 path is on an RC and the stable line is a major version behind it. Budget for a migration when 1.0 lands, or stay on 0.45.4 and ignore Drizzle's guide.

D1 hard limits that shape the schema (VERIFIED, https://developers.cloudflare.com/d1/platform/limits/): **10 GB per database, and "the 10 GB limit of a D1 database cannot be further increased"**; 30 s max query duration, which also applies to the whole `batch()` call. Cloudflare's stated design intent is horizontal: *"D1 is designed for horizontal scale out across multiple, smaller (10 GB) databases, such as per-user, per-tenant or per-entity databases."*

Two things D1 does not give you:

1. **No interactive transactions.** There is no `BEGIN`/`COMMIT` you can hold across multiple round-trips from a Worker. The only atomic unit is `batch()`, and the docs say exactly that: *"Batched statements are SQL transactions. If a statement in the sequence fails, then an error is returned for that specific statement, and it aborts or rolls back the entire sequence"* (VERIFIED, https://developers.cloudflare.com/d1/worker-api/d1-database/). Any state machine that needs "read, decide, write" atomically must live in a Durable Object, not in D1.
2. **No unbounded write throughput.** *"A database that receives too many concurrent requests will first attempt to queue them. If the queue becomes full, the database will return an 'overloaded' error"* (VERIFIED, https://developers.cloudflare.com/d1/platform/limits/). A control plane that writes a row per heartbeat from 500 machines will meet this.

The corollary, and the pattern that actually works: **D1 is a read-optimised projection, not the source of truth.** See `drydock` below for a working implementation of exactly this.

### Durable Objects: one object per machine is the right granularity, and it is the only place with real transactions

A DO gives you single-threaded execution, SQLite with real transactions, and — critically for a control plane — **no wall-clock limit while something is in flight**: *"No hard limit while the caller stays connected to the Durable Object. Durable Objects remain active while a request, RPC call, response stream, WebSocket, or pending I/O is in flight"* (VERIFIED, https://developers.cloudflare.com/durable-objects/platform/limits/). Alarm handlers, by contrast, are capped at **15 minutes** wall time (VERIFIED, https://developers.cloudflare.com/workers/platform/limits/#wall-time-limits-by-invocation-type).

Limits that matter (VERIFIED, https://developers.cloudflare.com/durable-objects/platform/limits/): **10 GB storage per SQLite-backed DO** on Paid (1 GB Free), 128 MB memory, **32 MiB WebSocket message size**, 30 s CPU per invocation by default and raisable to 5 min.

`drydock` is the best public example of the pattern and is worth reading in full: one DO per server owns the lifecycle state, every transition goes through `ServerObject.transition({ expected, to, actor })` with a generation check and a history row in one SQLite transaction; a second DO per site holds a *drain budget* (max 10% of a site's servers out of service at once) so repairs cannot take a site down; D1 is written after the DO commits and is explicitly *"a projection, not the source of truth"*, with an alarm retrying pending rows every 5 s when D1 is unavailable (VERIFIED, https://github.com/Rakshit-gen/drydock). That is the architecture this lane recommends, minus the simulated fleet.

### Workflows is the only place a long job can live — and it is the piece people miss

The Worker/DO/Queues stack cannot hold a CI job. Workflows can, and the numbers are not marginal (VERIFIED, https://developers.cloudflare.com/workflows/reference/limits/):

- **Duration (wall clock) per step: Unlimited** (CPU per step 30 s default, configurable to 5 min).
- **`step.sleep` up to 365 days.**
- **10,000 steps per Workflow by default, configurable to 25,000.**
- **50,000 concurrent instances per account** on Paid; instances in `waiting` state *do not count* toward concurrency.
- 1 MiB per step result; 1 GB total persisted state per instance; 30-day retention of completed instance state on Paid.

So the correct division of labour is: the API Worker accepts a job, creates a Workflow instance, and returns an id; the Workflow calls the machine's agent through the VPC binding, sleeps, retries each step up to 10,000 times, and writes progress; the DO owns live state and pushes it to the dashboard over a WebSocket. Workflows' own limits page says the quiet part out loud: *"Consider a Workflow that does some work, waits for 30 days, and then continues with more work."*

Pricing (VERIFIED, https://developers.cloudflare.com/workflows/reference/pricing/): **500,000 steps/month included, then $0.80 per additional 100,000**; storage $0.20/GB-month after 1 GB; CPU and requests at Workers rates. Step and storage billing only began **2026-08-10**. For a control plane doing ~5 steps per job, 500k steps is 100k jobs/month before step charges start.

### Queues is a dispatch bus, not an executor

VERIFIED, https://developers.cloudflare.com/queues/platform/limits/: **128 KB max message**, **15 minutes max consumer wall time**, **250 concurrent consumer invocations**, 100-message batches, 60 s max batch wait. A consumer that tries to run a build dies at 15 minutes; a consumer that tries to ship a log chunk over 128 KB fails. Use Queues to hand a job id to a worker that then starts a Workflow or calls an agent — nothing more.

### KV must not hold control state

VERIFIED, https://developers.cloudflare.com/kv/concepts/how-kv-works/: *"KV achieves high performance by being eventually-consistent… In other global network locations changes may take up to 60 seconds or more to be visible"*, and *"KV is not ideal for applications where you need support for atomic operations or where values must be read and written in a single transaction."* Negative lookups are cached too. A dashboard that reads "machine is idle" from KV will show stale state for a minute after a dispatch. Keep KV for feature flags and static config only; put anything a user acts on in D1 or a DO.

### Auth: Access covers the human leg, and it has three sharp edges

Cloudflare Access in front of the Worker is the right answer for the SPA. The pieces:

- **`ctx.access`** gives you the signed-in identity with no JWT parsing: `const identity = await ctx.access.getIdentity()` (VERIFIED, https://developers.cloudflare.com/workers/configuration/cloudflare-access/).
- **But it is `undefined` behind Static Assets**: *"Workers with Static Assets execute behind an internal router Worker. Access still protects the application and its assets. However, the router does not pass `ctx.access` to the user Worker."* This is the single most likely thing to silently break your auth. Since this lane's whole topology is "SPA on Static Assets + API Worker", **assume `ctx.access` is unavailable and validate the JWT yourself.**
- **It does not cross a service binding**: *"Cloudflare Access does not propagate `ctx.access` through Service Binding HTTP requests or remote procedure call (RPC) invocations. The downstream Worker does not receive the caller's Access context."* If you split the API into an `api` Worker and an `authz` Worker, the second one is unauthenticated unless you pass a token explicitly.
- **Worker-level Access policies break WebSockets**: *"Worker-level Access policies do not currently support WebSocket connections. WebSocket upgrade requests to a Worker protected by a worker-level Access policy will fail with a `403` error."* Live log streaming and any terminal-over-WebSocket **must** be behind a **hostname-based** self-hosted Access application, not the "Protect this Worker" toggle. This is a 403 that looks like a bug in your code.

JWT validation, if you do it yourself (VERIFIED, https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/): read `Cf-Access-Jwt-Assertion`, verify RS256 against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` with `jose`'s `createRemoteJWKSet`, check `iss` = team domain and `aud` = the application's AUD tag. Signing keys **rotate every 6 weeks** and the old key stays valid 7 days; match on `kid`, and do not hard-code the PEM. `jose@6.2.14` is current.

Machine-to-machine clients (CLI, CI) should use **Access service tokens**, not a shared secret in the repo: `CF-Access-Client-Id` + `CF-Access-Client-Secret` headers (VERIFIED, https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/). Tokens have a configurable duration and the secret is shown once. Access also supports a single-header mode (`read_service_tokens_from_header`) if a client can only send one custom header.

OIDC: Access can be configured with a **generic OIDC identity provider** (https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/generic-oidc/) and can itself act as an OIDC IdP for SaaS applications (https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/saas-apps/generic-oidc-saas/). Practically, for a self-hosted dashboard, let Access own the login flow and use service tokens for machines — rolling your own OIDC client on Workers buys nothing and loses you the Access policy engine.

### THE HARD PROBLEM: a Worker calling an agent behind a tunnel

**First, the structural fact.** A machine behind `cloudflared` has no inbound port and no public address. A Worker cannot dial it. Cloudflare's own docs frame tunnels as serving one of two consumers: *"Use Tunnels with Zero Trust when you are exposing internal applications securely to your employees… Use Tunnels with Workers VPC when you want to access private APIs, private databases, internal services or other HTTP services within your cloud or on-premise private network from Workers"* (VERIFIED, https://developers.cloudflare.com/workers-vpc/configuration/tunnel/). There is no third mechanism. Anything that claims otherwise is either a public hostname or a VPC binding.

**Service bindings are not the answer, and this is the most common confusion in this design space.** A service binding is Worker→Worker: *"`service`: The name of the target Worker you would like to communicate with. **This Worker must be on your Cloudflare account.**"* (VERIFIED, https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/). It gives you zero-cost, zero-latency RPC between your own Workers — useful for splitting `api` from `authz` — but it cannot name a host, a port, or a machine. It is an internal decomposition tool, not a network transport.

**Workers VPC is the answer, and it comes in two shapes** (VERIFIED, https://developers.cloudflare.com/workers-vpc/):

- **VPC Services** (`vpc_services`): you pre-register each target as `{type: http|tcp, host, ports, tunnel_id}` and bind it. Routing is fixed by the service config — *"The host provided in the `fetch()` operation is not used to route requests… The port provided in the `fetch()` operation is ignored."* Good for a fixed catalogue; it is also explicitly an SSRF control, since a Worker cannot be tricked into hitting a different host.
- **VPC Networks** (`vpc_networks`): bind an entire tunnel by `tunnel_id`, or the whole account with `network_id: "cf1:network"` (which spans Cloudflare Mesh nodes, subnet/hostname routes, and Cloudflare WAN on-ramps). *"At runtime, the URL you pass to `fetch()` or the address you pass to `connect()` determines the destination."*

**For a control plane, `cf1:network` is the correct choice**, because it means onboarding machine #501 is a `cloudflared` install and nothing else — no Worker redeploy, no new binding, no new VPC Service. This matters because **VPC Services are capped at 1000 per account** (VERIFIED, https://developers.cloudflare.com/workers-vpc/platform/limits/), which a per-machine-service design would hit. No limit is documented for VPC Networks.

What the binding gives you (VERIFIED, https://developers.cloudflare.com/workers-vpc/api/ and .../configuration/vpc-networks/):

- `env.MY_VPC.fetch("http://10.0.1.50:8788/health")` — HTTP, with the usual `RequestInit` including `signal` for cancellation.
- `await env.MY_VPC.connect("10.0.1.50:6379")` — raw TCP returning `{readable, writable}`, for Redis/MQTT/SSH/custom protocols.
- Absolute URLs are required; relative paths are not supported.
- Failures throw. The error taxonomy is documented and worth wiring into your UI: `connection_refused`, `connection_timeout`, `destination_not_found`, `dns_error`, `tls_certificate_error`, `connection_limit_reached`, `rate_limited`, `http_upgrade_failed`, and others (VERIFIED, https://developers.cloudflare.com/workers-vpc/reference/troubleshooting/).

**What does not work / what will bite you (all VERIFIED unless marked):**

- **`connect()` is plaintext only.** *"`connect()` over VPC Networks currently supports plaintext TCP only."* No TLS on the TCP path. If your agent protocol needs confidentiality you terminate TLS inside the protocol (or use HTTP via `fetch()` with `https`).
- **TLS to your origin is picky.** Only publicly-trusted CAs and **Cloudflare Origin CA** certificates are accepted: *"If your origin service presents a certificate that is not issued by a publicly trusted CA or by Cloudflare Origin CA, the TLS handshake will fail and `fetch()` will throw an exception."* A self-signed cert on your agent — the obvious homelab choice — fails. Mitigation exists: `--cert-verification-mode verify_ca|disabled`, but `disabled` means no verification.
- **WebSocket over a VPC binding is undocumented.** The troubleshooting page lists an `http_upgrade_failed` error code ("An HTTP upgrade (for example, WebSocket) failed"), which implies upgrades are attempted, but no page states that WebSockets work over VPC. **Do not design live terminal streaming on the assumption that they do.** Use polling or SSE until you have tested it.
- **The tunnel must be QUIC.** *"Workers VPC also requires Cloudflare Tunnel to connect using the QUIC transport protocol using `auto` or `quic`. Ensure outbound UDP traffic on port 7844 is allowed through your firewall."* A tunnel forced to `http2` works for Zero Trust and silently breaks DNS resolution for Workers VPC.
- **`cloudflared` must be ≥ 2025.7.0.** Older versions fail with `ProxyError: dns_error`.
- **No load balancing across replicas.** *"`cloudflared` does not load balance across replicas; replicas are strictly for high availability and requests are routed to the nearest replica."* And *"We do not recommend using `cloudflared` in autoscaling setups."* So a "run cloudflared next to each job" design is explicitly discouraged.
- **Capacity guidance is not trivial:** two replicas on two dedicated hosts per network location, each with **≥4 GB RAM and 4 CPU cores** (VERIFIED, https://developers.cloudflare.com/workers-vpc/configuration/tunnel/hardware-requirements/). That is a real per-site cost you are adding.
- **Beta.** *"Workers VPC is currently in beta. Features and APIs may change before general availability. While in beta, Workers VPC is available for free to all Workers plans."* No GA date, no price. A control plane whose only machine path is a beta feature has a single point of product risk.
- **Local dev needs `remote: true`** on the binding, or `wrangler dev` cannot reach the service.
- **RBAC friction:** binding to an existing VPC Service needs the `Connectivity Directory Bind` role; creating services or binding a tunnel needs `Connectivity Directory Admin`. A control plane that provisions services programmatically needs an API token carrying that role — a broader grant than you would like.

**The GA fallback: public tunnel hostname + Access service token.** This is what `skywatch` calls "direct transport" and it works today with no beta dependency: map `agent.example.com` to `http://127.0.0.1:8788` in `cloudflared` ingress, protect it with a self-hosted Access application, and have the Worker send `CF-Access-Client-Id` / `CF-Access-Client-Secret`. It opens no inbound port on the VPS. The cost is that the agent is on a public hostname and every request traverses Access, and you are trusting Access policy (not network position) for machine auth. **This is the only path I would ship on today.**

**The relay pattern (agent dials out to a DO) also works, and you should not build it.** A Worker cannot accept inbound TCP, but it can accept a WebSocket upgrade, and a DO can hold that socket with hibernation and no wall-clock limit. So an agent can maintain an outbound WSS to a DO and receive commands on it — that is precisely how `Fleet` works (*"Devices maintain outbound WebSocket connections"*, https://github.com/TITOCHAN2023/fleetForAgent) and roughly how `cloudflared` itself works. It is viable, it needs no beta feature, and it gives you server-push for free. But you are then reimplementing tunnel multiplexing, reconnection, backpressure and auth, and you inherit the 32 MiB WebSocket message limit and the 128 MB isolate ceiling for anything you buffer. Use it only if VPC stays in beta past your ship date *and* the Access-service-token path is unacceptable.

**One more thing that is not a solution:** Cloudflare Spectrum can put a TCP endpoint in front of a public hostname, but it is an Enterprise/L4 product and Workers cannot be its origin — the origin must be reachable, which a tunneled machine is not. Rejected.

### Existing projects: the space is nearly empty, and that is the finding

Searched GitHub for `cloudflare workers homelab dashboard`, `proxmox workers`, `vps agent worker`, `ssh terminal workers`, `wake on lan worker`, `durable objects scheduler`, `durable objects job queue`, `portainer cloudflare workers`, `tunnel dashboard`, `server control panel workers`, `mesh agent workers`, and `self-hosted ci runners`, sorted by stars.

There is **no mature open-source Cloudflare-hosted control plane for remote machines.** The two closest are both **0-star, single-author, 2026 projects** — `kodin00/skywatch` (last push 2026-08-11) and `Rakshit-gen/drydock` (2026-10-19). Everything with real adoption in this space (Pangolin at 23,263 stars, Portainer, Coolify, Tailscale) is *not* Cloudflare-hosted — they run their own control plane on a VPS, which is exactly what this study is trying to avoid.

The most useful artefact in the whole search is `skywatch`'s agent README, because it documents all three transports side by side and picks a sane auth model: an HMAC-signed request protocol that is *identical* across VPC, tunnel-hostname and direct-HTTPS transports, with a pairing key exchanged at init and stored encrypted. Its security note is the honest one for this entire category: *"Docker socket access is effectively root access. The API boundary reduces what a remote controller can ask for, but it does not make membership in the docker group unprivileged."* Note also that the Worker→agent leg is **not** authenticated by Cloudflare Access in any of the three modes — the HMAC is the auth. That is the correct model and it is the thing people get wrong.

`drydock` contributes the state-machine architecture (DO per entity, D1 as projection, drain budget as a second DO, Workflows for long jobs) even though its fleet is simulated.

`ShiSheng233/containers-dashboard` is a Portainer-like panel for *Cloudflare's own* Containers, not remote machines, and it **ships without authentication** by its own admission — read it for the Workers-API deployment pattern, not as a control plane.

`newbietan/CloudSSH` (449 stars, Apache-2.0) is the proof that a Worker can do real protocol work over `connect()`: a from-scratch SSH-2.0 stack in TypeScript running on Workers TCP sockets, one Durable Object per session, with the active TCP connection keeping the session alive. It only reaches hosts with a reachable SSH port, so it does not solve the tunnel problem — but it is the reference implementation for "Worker speaks a binary protocol to a machine", and it shows the DO-per-session keepalive trick that any terminal feature will need.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| **Cloudflare Workers VPC** | https://developers.cloudflare.com/workers-vpc/ | proprietary (Cloudflare product) | docs last updated 2026-10-12; beta since 2025-11-05 | The only first-party way for a Worker to reach a tunneled host. `fetch()` + `connect()`, `cf1:network` spans Mesh/WAN/tunnel routes | Beta. No GA date or price. `connect()` plaintext only. WebSocket undocumented. Requires QUIC tunnel + cloudflared ≥2025.7.0. TLS limited to public CA / Origin CA |
| **kodin00/skywatch** | https://github.com/kodin00/skywatch | MIT | 2026-08-11 (0 stars, 0 forks) | The closest thing to this study's target. Worker + React + D1 control plane; Rust agent with 6 Docker verbs; **documents all three Worker→agent transports** (VPC Service, tunnel hostname, direct HTTPS); HMAC request signing | 0 stars, ~6 weeks of one person's work, unproven. No Durable Objects, no Workflows, no live sockets. Agent is Docker-only. Requires you to hand-create the VPC Service and binding |
| **Rakshit-gen/drydock** | https://github.com/Rakshit-gen/drydock | MIT | 2026-10-19 (0 stars) | Best public architecture reference: DO-per-entity state machine with generation checks, D1 as projection with alarm-based retry, DO-per-site drain budget, Workflows for long jobs, tests inside workerd | Simulated fleet — no real machines, no tunnel, no agent. Not deployable as a control plane |
| **ShiSheng233/containers-dashboard** | https://github.com/ShiSheng233/containers-dashboard | MIT | 2026-08-05 (0 stars) | Workers-only panel (React + Hono + D1 + Workflows) driving Cloudflare Containers via the Cloudflare API | Targets CF Containers, not remote machines. **Ships without authentication** — author's own warning. No agent, no tunnel |
| **newbietan/CloudSSH** | https://github.com/newbietan/CloudSSH | Apache-2.0 | 2026-10-29 (449 stars) | Reference for binary protocol over `connect()`: pure-TS SSH-2.0 stack, DO-per-session with TCP keepalive, xterm.js front end, Access + Turnstile integration | Reaches only hosts with a reachable SSH port. No tunnel support. Terminal only — not a control plane |
| **Jxck-S/priv-dns** | https://github.com/Jxck-S/priv-dns | MIT | 2026-10-21 (3 stars) | Small, clean example of "Worker + R2 + dashboard" as a control plane for *resolvers* rather than machines; ~90 KB of code, free-tier sized | No machines, no jobs, no agent. Wrong problem, right shape |
| **cloudflare/computer** | https://github.com/cloudflare/computer | MIT | 2026-10-29 (9,752 stars) | Virtual filesystem inside a DO; three execution backends (container FUSE mount, isolate shell, isolate JS). Shows the DO-as-authority + SQLite + pluggable-runtime pattern | It is a workspace/compute abstraction *inside Cloudflare*, not a control plane for your own machines. Author flags `ContainerBackend` as not production-ready |
| **threepointone/durable-scheduler** | https://github.com/threepointone/durable-scheduler | MIT | 2025-01-05 (56 stars) | DO-alarm scheduler: delayed/cron/scheduled tasks, webhook / DO / service callbacks | **Archived in effect** — README says "Renamed to partywhen, work continues at …/partyserver/tree/main/packages/partywhen". Don't depend on it; read it |
| **TITOCHAN2023/fleetForAgent** | https://github.com/TITOCHAN2023/fleetForAgent | MIT | 2026-10-27 (3 stars) | Working relay architecture: devices hold outbound WSS to a hub, MCP client on top, task survives disconnects | Hub is a **Node/Vite app, not Workers** (`vite dev`, `packages/fleet-hub/index.mjs`). Rejects the study's constraint |
| **fosrl/pangolin** | https://github.com/fosrl/pangolin | NOASSERTION (source-available, not OSI) | 2026-10-29 (23,263 stars) | Mature self-hosted tunneled reverse proxy + identity-aware dashboard, with a Cloudflare Tunnel integration | Its control plane is a VPS you run yourself. That is the thing this study exists to avoid. License is not permissive |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| Workers VPC status | Beta, free during beta | https://developers.cloudflare.com/workers-vpc/platform/pricing/ | "Workers VPC is free during the open beta period. Standard Workers pricing applies for compute time and requests." |
| Workers VPC beta caveat | APIs may change | https://developers.cloudflare.com/workers-vpc/ | "Workers VPC is currently in beta. Features and APIs may change before general availability. While in beta, Workers VPC is available for free to all Workers plans." |
| VPC Services per account | 1000 | https://developers.cloudflare.com/workers-vpc/platform/limits/ | "\| VPC Services per account \| 1000 \|" |
| VPC TCP transport | plaintext only | https://developers.cloudflare.com/workers-vpc/configuration/vpc-networks/ | "`connect()` over VPC Networks currently supports plaintext TCP only." |
| VPC origin TLS trust | public CA or Cloudflare Origin CA only | https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/ | "If your origin service presents a certificate that is not issued by a publicly trusted CA or by Cloudflare Origin CA, the TLS handshake will fail and `fetch()` will throw an exception." |
| VPC requires QUIC | UDP 7844 outbound | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ | "Workers VPC also requires Cloudflare Tunnel to connect using the QUIC transport protocol using `auto` or `quic`. Ensure outbound UDP traffic on port 7844 is allowed through your firewall for QUIC connections." |
| Minimum cloudflared for VPC | 2025.7.0 | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ | "Ensure you are running `cloudflared` version 2025.7.0 or later (latest version recommended)" |
| cloudflared host sizing | 2 hosts/location, ≥4 GB RAM, ≥4 cores each | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/hardware-requirements/ | "Run a cloudflared replica on two dedicated host machines per network location… Size each host with minimum 4GB of RAM and 4 CPU cores." |
| cloudflared replica behaviour | no load balancing | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ | "`cloudflared` does not load balance across replicas; replicas are strictly for high availability and requests are routed to the nearest replica." |
| Service binding scope | same account only | https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/ | "This Worker must be on your Cloudflare account." |
| Service binding Access propagation | does not propagate | https://developers.cloudflare.com/workers/configuration/cloudflare-access/ | "Cloudflare Access does not propagate `ctx.access` through Service Binding HTTP requests or remote procedure call (RPC) invocations." |
| `ctx.access` behind Static Assets | undefined | https://developers.cloudflare.com/workers/configuration/cloudflare-access/ | "Workers with Static Assets execute behind an internal router Worker… However, the router does not pass `ctx.access` to the user Worker." |
| Access + WebSockets | worker-level policy → 403 | https://developers.cloudflare.com/workers/configuration/cloudflare-access/ | "Worker-level Access policies do not currently support WebSocket connections. WebSocket upgrade requests to a Worker protected by a worker-level Access policy will fail with a `403` error." |
| Access signing key rotation | 6 weeks, 7-day overlap | https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/ | "By default, Access rotates the signing key every 6 weeks… Previous keys remain valid for 7 days after rotation" |
| Workers HTTP duration | no hard limit | https://developers.cloudflare.com/workers/platform/limits/ | "There is no hard limit on duration for HTTP-triggered Workers. As long as the client remains connected, the Worker can continue processing" |
| Workers runtime-update grace | 20 minutes | https://developers.cloudflare.com/workers/platform/limits/ | "processes running the previous version of the Workers runtime give existing Workers requests and connections up to 20 minutes to finish" |
| Simultaneous outbound connections | 6 per invocation, but only while awaiting headers | https://developers.cloudflare.com/workers/platform/limits/ | "Each Worker invocation can have up to six connections simultaneously waiting for response headers." / "Once response headers arrive for a connection, it no longer counts toward the six-connection limit." |
| Workflow step wall time | unlimited | https://developers.cloudflare.com/workflows/reference/limits/ | "Duration (wall clock) per step \| Unlimited \| Unlimited - for example, waiting on network I/O calls or querying a database" |
| Workflow sleep | 365 days | https://developers.cloudflare.com/workflows/reference/limits/ | "Maximum `step.sleep` duration \| 365 days (1 year) \| 365 days (1 year)" |
| Workflow steps per instance | 10,000 default / 25,000 max | https://developers.cloudflare.com/workflows/reference/limits/ | "Maximum steps per Workflow \| 1,024 \| 10,000 (default) / configurable up to 25,000" |
| Workflow concurrency | 50,000 instances (Paid) | https://developers.cloudflare.com/workflows/reference/limits/ | "Concurrent Workflow instances (executions) per account \| 100 \| 50,000" |
| Workflow step pricing | 500,000/mo included, $0.80 per +100,000 | https://developers.cloudflare.com/workflows/reference/pricing/ | "Steps \| 3,000 per day \| 500,000 included per month + $0.80/ additional 100,000 per month" |
| Workflow billing start | 2026-08-10 | https://developers.cloudflare.com/workflows/reference/pricing/ | "Billing for Workflows steps and storage will apply starting August 10th, 2026" |
| D1 max database size | 10 GB, not raisable | https://developers.cloudflare.com/d1/platform/limits/ | "Note that the 10 GB limit of a D1 database cannot be further increased." |
| D1 transaction model | batch only | https://developers.cloudflare.com/d1/worker-api/d1-database/ | "Batched statements are SQL transactions. If a statement in the sequence fails, then an error is returned for that specific statement, and it aborts or rolls back the entire sequence." |
| D1 concurrency failure mode | "overloaded" error | https://developers.cloudflare.com/d1/platform/limits/ | "A database that receives too many concurrent requests will first attempt to queue them. If the queue becomes full, the database will return an \"overloaded\" error" |
| DO wall time | no hard limit while in flight | https://developers.cloudflare.com/durable-objects/platform/limits/ | "No hard limit while the caller stays connected to the Durable Object. Durable Objects remain active while a request, RPC call, response stream, WebSocket, or pending I/O is in flight." |
| DO WebSocket message size | 32 MiB | https://developers.cloudflare.com/durable-objects/platform/limits/ | "WebSocket message size \| 32 MiB (only for received messages)" |
| DO alarm wall time | 15 minutes | https://developers.cloudflare.com/workers/platform/limits/ | "Durable Object alarm handlers \| 15 minutes \| Alarm handler invocations have a maximum wall time of 15 minutes." |
| Queues message size | 128 KB | https://developers.cloudflare.com/queues/platform/limits/ | "Message size \| 128 KB" |
| Queues consumer wall time | 15 minutes | https://developers.cloudflare.com/queues/platform/limits/ | "Consumer duration (wall clock time) \| 15 minutes" |
| Queues consumer concurrency | 250 | https://developers.cloudflare.com/queues/platform/limits/ | "Concurrent consumer invocations \| 250 (push-based only)" |
| KV consistency | up to 60 s+, not atomic | https://developers.cloudflare.com/kv/concepts/how-kv-works/ | "KV is not ideal for applications where you need support for atomic operations or where values must be read and written in a single transaction." |
| Static assets file limits | 20,000 Free / 100,000 Paid, 25 MiB each | https://developers.cloudflare.com/workers/platform/limits/#static-assets | "Files per Worker version \| 20,000 \| 100,000" / "Individual file size \| 25 MiB \| 25 MiB" |
| Static asset requests | free and unlimited | https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/ | "Requests to static assets are free and unlimited." |
| hono latest | 4.13.14 (next 5.0.0-rc.1) | https://registry.npmjs.org/hono | `"latest": "4.13.14"`, `"next": "5.0.0-rc.1"` |
| chanfana latest | 3.4.2 | https://registry.npmjs.org/chanfana | `"latest": "3.4.2"` |
| itty-router latest | 5.0.24 | https://registry.npmjs.org/itty-router | `"latest": "5.0.24"` |
| drizzle-orm latest vs rc | 0.45.4 / 1.0.0-rc.5 | https://registry.npmjs.org/drizzle-orm | `"latest": "0.45.4"`, `"rc": "1.0.0-rc.5"` |
| Drizzle D1 install path | `@rc` | https://orm.drizzle.team/docs/get-started/d1-new | "npm i drizzle-orm@rc wrangler dotenv" |
| jose latest | 6.2.14 | https://registry.npmjs.org/jose | `"latest": "6.2.14"` |
| `@hono/cloudflare-access` latest | 0.4.0 | https://registry.npmjs.org/@hono/cloudflare-access | `"latest": "0.4.0"` |
| skywatch stars / license | 0 stars, MIT, pushed 2026-08-11 | https://github.com/kodin00/skywatch | GitHub API: `stargazers_count: 0`, `license.spdx_id: "MIT"`, `pushed_at: 2026-08-11T09:27:25Z` |
| drydock stars / license | 0 stars, MIT, pushed 2026-10-19 | https://github.com/Rakshit-gen/drydock | GitHub API: `stargazers_count: 0`, `license.spdx_id: "MIT"`, `pushed_at: 2026-10-19` |
| CloudSSH stars / license | 449 stars, Apache-2.0 | https://github.com/newbietan/CloudSSH | GitHub API: `stargazers_count: 449`, `license.spdx_id: "Apache-2.0"` |
| pangolin stars / license | 23,263 stars, NOASSERTION | https://github.com/fosrl/pangolin | GitHub API: `stargazers_count: 23263`, `license.spdx_id: "NOASSERTION"` |

## Rejected options

| option | why rejected |
|---|---|
| **Service bindings as the Worker→machine transport** | They are Worker→Worker and same-account only ("This Worker must be on your Cloudflare account"). There is no host or port to specify. They cannot reach a machine, tunneled or otherwise. Keep them for splitting `api`/`authz`, nothing more |
| **`connect()` to a public SSH port on each machine** | Requires every machine to have a routable public IP and an open port — the exact thing Cloudflare Tunnel exists to avoid. It also forfeits the "no inbound ports" property that makes the tunnel architecture defensible |
| **Cloudflare Spectrum in front of the agent** | L4 TCP proxy, but the origin must be reachable and Workers cannot be a Spectrum origin. It does not solve the tunneled-machine case, and it is an Enterprise product |
| **KV for machine/job state** | Eventually consistent, up to 60 s+ stale, negative lookups cached, explicitly "not ideal… where values must be read and written in a single transaction". A dashboard that shows a machine as idle after you dispatched to it is worse than no dashboard |
| **D1 as the authoritative state store for the state machine** | No interactive transactions — only `batch()` is atomic. "Read, decide, write" across round-trips races. Use a DO per machine and project to D1 |
| **D1 (or KV) as the log/artifact store** | 10 GB per database, not raisable; 2 MB max row; 30 s query cap. Build logs go to R2, and the DB holds a key |
| **Queues as the job executor** | 15-minute consumer wall time and 128 KB messages. It can dispatch a job id; it cannot run or report a build |
| **Worker-level ("Protect this Worker") Access policy with any WebSocket feature** | Documented 403 on WebSocket upgrades. Any live log tail or terminal must sit behind a hostname-based Access application |
| **Relying on `ctx.access` in the API Worker** | Undefined whenever Static Assets is enabled — which is this lane's entire topology. Validate `Cf-Access-Jwt-Assertion` yourself with `jose` or `@hono/cloudflare-access` |
| **Rolling your own OIDC client on Workers** | Access already brokers generic OIDC IdPs and can act as an OIDC IdP for SaaS apps. You would rebuild the login flow and lose the policy engine, device posture and service tokens |
| **Hono 5 (`5.0.0-rc.1`)** | Still an RC. Pin `hono@4.13.14` |
| **`drizzle-orm@1.0.0-rc.5` despite Drizzle's own D1 guide** | The official guide says `@rc`; npm `latest` is `0.45.4`. Either way you are choosing between an RC and a major-version-later upgrade. Do not let a docs page silently pin you to an RC |
| **`threepointone/durable-scheduler`** | Superseded — README redirects to `partyserver`'s `partywhen`. Read for the alarm pattern, do not depend on it |
| **`TITOCHAN2023/fleetForAgent` as a base** | Its hub is a Node/Vite app (`vite dev`, `packages/fleet-hub/index.mjs`), not a Worker. Violates the hard constraint. Its outbound-WSS relay design is still worth copying |
| **`fosrl/pangolin`** | Mature (23k stars) and does exactly this job, but its control plane is a VPS you operate — the thing being replaced. License is `NOASSERTION`, i.e. not clearly OSI-approved |
| **`ShiSheng233/containers-dashboard` as-is** | Ships without authentication by the author's own warning, and targets Cloudflare Containers rather than remote machines |
| **Building your own relay (agent → DO WebSocket) first** | It works and avoids the VPC beta, but you inherit multiplexing, reconnect, backpressure, 32 MiB message caps and the 128 MB isolate ceiling. Ship on Access service tokens and revisit only if VPC slips |
| **Running `cloudflared` per job / in autoscaling groups** | Docs: "We do not recommend using `cloudflared` in autoscaling setups because downscaling (removing replicas) will break existing user connections", and replicas do not load balance |

## Open questions

- **Does Workers VPC GA, and at what price?** Docs say only "free during the open beta period" with no date. Settle by watching https://developers.cloudflare.com/changelog/ and the Workers VPC pricing page; a GA announcement with per-GB or per-service pricing would change the cost model for a fleet of hundreds of machines.
- **Do WebSockets work over a VPC binding?** The `http_upgrade_failed` error code implies upgrades are attempted; no page confirms support. Settle by deploying a Worker with a `vpc_networks` binding against an agent that speaks WebSocket and testing an upgrade end to end. This decides whether live terminal/log streaming is a `fetch()` or a polling loop.
- **Is there an account limit on VPC Networks?** The limits page lists only "VPC Services per account 1000" and says nothing about `vpc_networks`. Settle by asking Cloudflare support or by probing the API until it errors.
- **Does `fetch()` over a VPC binding support streaming request bodies and SSE responses?** Not documented either way; only "standard Fetch API Response object" is promised. Settle by testing a chunked upload and an `text/event-stream` response through a VPC binding.
- **Can a locally-managed (not remotely-managed) tunnel be used with VPC?** Docs say locally-managed is supported but "we recommend creating a remotely-managed tunnel". The QUIC requirement and the resolver behaviour may differ. Settle by testing a locally-managed tunnel with a VPC Service.
- **What exactly does the `connection_limit_reached` error mean in practice** — a per-service concurrency cap, and at what number? Not stated. Settle by load-testing one VPC Service with N parallel `fetch()` calls and finding the threshold.
- **Does Chanfana 3.4.2 work with Hono 5 RC?** Chanfana declares no peer dependencies (`peerDependencies: None` in the published manifest), so compatibility is untested by the package manager. Settle by building one route against `hono@5.0.0-rc.1`.
- **When does `drizzle-orm` 1.0 go stable, and what breaks from 0.45.4?** Both lines are live and Drizzle's own D1 guide points at the RC. Settle by following https://github.com/drizzle-team/drizzle-orm/releases.
- **Do Access service tokens count against Zero Trust seat pricing?** Service tokens are non-human, but the pricing page was not fetched in this lane. Settle at https://www.cloudflare.com/zero-trust/pricing/ — matters because a control plane wants one token per machine or per CI job.
- **How does `skywatch` actually behave at scale?** It is 0-star, ~6 weeks old, and untested outside its author. Settle by reading `agent/src` and running it against two VPSes before treating any of its choices as validated.
- **Is there a first-party Cloudflare Terraform resource for VPC Services?** A "Configure with Terraform" page exists under Workers VPC, but the resource name and schema were not read. Settle at https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/terraform/ — relevant if the control plane provisions connectivity as code.
