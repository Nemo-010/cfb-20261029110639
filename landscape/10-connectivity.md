# cloudflared + Workers VPC — deep review

## Verdict

Put `cloudflared` in the stack, in exactly one slot: **the dashboard's outbound leg**. Use it as a
dumb encrypted pipe that lets the Workers-hosted SPA (via a Worker BFF) reach *one* gateway service
in your private network. Do **not** put Workers VPC in as the data plane for CI, and do not make
Cloudflare the rendezvous point for your orchestration traffic — you would be re-centralising on
Cloudflare at layer 4 the moment you decided to leave it at layer 7. Concretely: `cloudflared` is a
boring, well-maintained, Apache-2.0, 38 MiB static Go binary that punches four outbound QUIC
connections to Cloudflare's edge and needs no inbound ports — that part is genuinely good and there
is no reason to hand-roll it. Workers VPC, the thing layered on top, is a **beta, free-for-now,
control-plane-shaped** API: it does HTTP `fetch()` and (since 2026-06-16) plaintext-only raw TCP
`connect()`, it is configured statically in `wrangler.jsonc` so every new CI runner means a Worker
redeploy, it caps at 1000 VPC Services per account, it silently requires QUIC/UDP-7844 with no
HTTP/2 fallback, and it has **no stream resumption whatsoever** — a tunnel blip kills every
in-flight request and socket. It is an excellent way for a dashboard to call `GET
/agent/status` on a machine. It is a bad way to carry a 40-minute build log.

## What it actually is

Two separable things that the marketing bundles:

1. **`cloudflared`** — a Go daemon (390 `.go` files, 46,305 non-test LOC) that dials out to
   Cloudflare's edge over QUIC, registers itself, and then serves whatever streams the edge pushes
   at it by proxying them to local origins. Its own doc comment is honest: *"Supervisor manages
   non-declarative tunnels. Establishes TCP connections with the edge, and reconnects them if they
   disconnect."* (`supervisor/supervisor.go:28-29`). It is a reverse-proxy client with a reconnect
   loop, an ingress rule table, and a metrics server. That is the whole thing.

2. **Workers VPC** — a Cloudflare control plane that maps a Worker binding (`vpc_services` or
   `vpc_networks`) onto a tunnel ID, and routes the Worker's `fetch()`/`connect()` calls down that
   tunnel. It is *not* in `cloudflared`; it lives entirely on Cloudflare's side. The binary only
   sees an extra stream type arriving. This is the part that is beta, proprietary, unpriced, and
   where all the risk is.

The README-level pitch is "connect your private cloud to Cloudflare". What it actually is: a
NAT-traversal appliance plus a hosted routing table. The appliance is commodity; the routing table
is the lock-in.

## Architecture (with file paths)

### Process shape

One binary, one tunnel, four edge connections.

- `cmd/cloudflared/tunnel/cmd.go:781-785` — `--ha-connections` defaults to **4**, and the flag is
  `Hidden: true`. You get 4 edge connections whether you know it or not.
- `supervisor/supervisor.go:105` — `Run()` is a `select` loop over `tunnelErrors`, `backoffTimer`,
  `nextConnectedSignal`, `gracefulShutdownC`. On a dropped connection it appends the index to
  `tunnelsWaiting`, arms `backoff.BackoffTimer()`, and re-spawns `startTunnel` when it fires
  (`supervisor/supervisor.go:145-171`).
- `supervisor/supervisor.go:23` — `tunnelRetryDuration = 10 * time.Second`; retries use exponential
  backoff from `retry/backoffhandler.go:12-13` (`DefaultBaseTime = 1s`, doubling:
  `exponentialBackoffDuration`, `retry/backoffhandler.go:164-180`). Default `--retries` is **5**
  (`cmd/cloudflared/tunnel/cmd.go:775-779`), and the supervisor passes `retryForever=true`
  (`supervisor/supervisor.go:130`), so the *period* is capped but it retries forever.
- `supervisor/tunnel.go:214` `EdgeTunnelServer.Serve` → `:396 serveTunnel` → `serveConnection`.
  Panics are caught and treated as recoverable (`supervisor/tunnel.go:406-416`). A permanent server
  registration error is not retried (`supervisor/tunnel.go:440-444`).
- `supervisor/tunnel.go:159-193` `IpAddrFallback.ShouldGetNewAddress` — after N retries on one
  edge address it rotates to a different one.

### Control stream and registration

`connection/control.go:78` `ServeControlStream` registers with the edge via capnp RPC
(`tunnelrpc/pogs`, `tunnelrpc/proto`), then blocks in `waitForUnregister`
(`connection/control.go:124-148`), which sends a `GracefulShutdown(ctx, gracePeriod)` RPC on exit.
There is **no session or stream state carried across** that call — it is a courtesy notification,
not a drain protocol.

`connection/connection.go:62-68` — `Credentials{AccountTag, TunnelSecret, TunnelID, Endpoint}`.
`connection/connection.go:75-81` — `TunnelToken` is that struct base64'd as JSON with one-letter
keys (`{"a":..., "s":..., "t":...}`). `cmd/cloudflared/tunnel/subcommands.go:42` — the flag is
`--token`. **One bearer token = full control of one tunnel**, long-lived, no rotation, no scoping.

### Ingress and the origin proxy

- `ingress/rule.go:13-33` — `Rule{Hostname, Path, Service, Handlers, Config}`.
- `ingress/ingress.go:288-330` — `validateIngress` dispatches on scheme prefix: `unix:`, `unix+tls:`,
  `http_status:<code>`, `hello_world`, socks proxy, bastion, else a TCP-over-WS service whose
  default ports for `ssh`/`rdp`/`smb`/`tcp` are set in `ingress/origin_service.go:131-140`.
- `ingress/origin_connection.go:34-42` — `tcpConnection.Stream` is literally
  `stream.Pipe(tunnelConn, tc, logger)`; `stream/stream.go:87` `Pipe` is two `io.Copy` goroutines.
  So a Workers VPC `connect()` socket is an `io.Copy` between a QUIC stream and a `net.Conn`. No
  framing, no retry, no buffering.
- `ingress/config.go:15-19` — `connectTimeout 30s`, `tlsTimeout 10s`, `tcpKeepAlive 30s`,
  `keepAliveTimeout 90s`. `:24-25` — `keepAliveConnections = 100`, `maxActiveFlows = 0` (unlimited).
  `flow/limiter.go:8-9` confirms `0` means unlimited.
- `orchestration/orchestrator.go:176-237` `updateIngress` — hot config reload: it builds the new
  proxy, `proxy.Store(proxy)`, then closes the old `proxyShutdownC`. `:104` `UpdateConfig` is the
  edge-pushed remote-config path. **Your tunnel's routing table can be changed by Cloudflare's API
  at runtime, not just by your local YAML.**

### Remote management (this is the one to read twice)

`cmd/cloudflared/tunnel/cmd.go:462`:

```go
internalRules := []ingress.Rule{ingress.NewManagementRule(mgmt)}
```

That rule is injected into **every** tunnel unconditionally, and
`cmd/cloudflared/tunnel/cmd.go:889-894` sets:

```go
Name:  "management-diagnostics",
Value: true,          // default ON
```

The rule points at an in-process `http.Handler` served through the tunnel's own ingress
(`ingress/origin_service.go:310-333`; `ingress/origin_proxy.go:25-28`) — there is no separate local
listener, so the *only* gate is the edge. That matters because of what the gate does:

```go
// management/token.go:43-58
jwt, err := jwt.ParseSigned(token, []jose.SignatureAlgorithm{jose.ES256})
...
// This is actually safe because we verify the token in the edge before it reaches cloudflared
err = jwt.UnsafeClaimsWithoutVerification(&claims)
```

The signature is **not** verified locally, and neither `exp` nor `aud` is checked — `verify()`
(`management/token.go:18-21, 28-40`) only asserts that `AccountTag`, tunnel `ID` and `Actor.ID` are
non-empty. Cloudflare's edge is trusted to have done the real check. CORS is
`AllowedOrigins: []string{"https://*.cloudflare.com"}` with `AllowCredentials: true`
(`management/service.go:34-43`); the `actor.Support` claim (`management/token.go:33-36`) is what
distinguishes staff. Default hostname is `management.argotunnel.com`
(`cmd/cloudflared/tunnel/cmd.go:1087`). With diagnostics on, that channel serves
`/debug/pprof/heap`, `/debug/pprof/goroutine`, `/metrics`, and `/config`.

**Translation: on a default install there is a permanently-wired, edge-gated channel into your CI
runner's `cloudflared` that can return a heap dump, all goroutines, metrics, and the full ingress
config, and whose token is trusted without local verification.** I am not claiming Cloudflare is
mining your runners; I am claiming the capability is default-on and that the only control on it is
on someone else's side of the wire. For a fleet executing untrusted build code, turn it off.

### Update path

`cmd/cloudflared/updater/update.go:25` — `DefaultCheckUpdateFreq = time.Hour * 24`.
`:30` — `UpdateURL = "https://update.argotunnel.com"`. `cmd/cloudflared/updater/workers_update.go:1-3`
says the update decision is *"normally created by a WorkersService JSON checkin response"* — i.e.
Cloudflare decides what binary you run, and the daemon restarts itself into the new one. Disabled by
`--no-autoupdate` / `NO_AUTOUPDATE` (`cmd/cloudflared/tunnel/cmd.go:924-930`). The most recent
upstream commit in the clone is literally *"TUN-11051: Disable autoupdate in container images via
NO_AUTOUPDATE"* (2026-10-29), and *"TUN-11048: Randomize and enable the cloudflared update timer"*
(2026-10-29) — they are actively widening it, not narrowing it.

### Operational surface

- Metrics/readiness server binds `localhost:20241..20245`, first free one
  (`metrics/metrics.go:47-52`); in containers it binds `0.0.0.0` (`:50`).
- `/ready` returns 200 iff `CountActiveConns() > 0` (`metrics/readiness.go:54-62`) — i.e. one
  surviving edge connection is "ready", even if it is about to be rotated.
- `/healthcheck`, `/metrics`, `/config`, `/debug/pprof/*`, `/debug/vars` are all registered
  (`metrics/metrics.go:75-123`).
- QUIC transport tuning: `quic/constants.go:5-8` — `HandshakeIdleTimeout 5s`, **`MaxIdleTimeout 5s`**,
  `MaxIdlePingPeriod 1s`. Keepalives every second; five seconds of silence and the connection is
  declared dead.

## The seam into this design

There are two distinct paths into the same `cloudflared`, and conflating them is the mistake this
review exists to prevent.

**Path A — Zero Trust (hostname + Access).** Public hostname → Cloudflare edge → Access policy →
tunnel → ingress rule → origin. Auth is Access (SSO or `CF-Access-Client-Id` /
`CF-Access-Client-Secret` service tokens). `cloudflared` can verify the Access JWT itself with
`config/configuration.go:240-251` (`AccessConfig{Required, TeamName, AudTag}`) and
`ingress/ingress.go:274-286`. This is a *user-facing* path.

**Path B — Workers VPC (binding).** Worker code → `env.BINDING.fetch()` / `.connect()` → Cloudflare's
VPC control plane → tunnel ID → `cloudflared` → host:port. **Access is not in this path at all.**
Authorisation is account IAM: `Connectivity Directory Bind` to bind, `Connectivity Directory Admin`
to bind directly to a tunnel. There are no service tokens here.

### Access service tokens: which path they are actually for

Service tokens are a **Path A** mechanism and nothing else. They are a Client ID + Client Secret
pair, sent as `CF-Access-Client-Id` / `CF-Access-Client-Secret`, that lets a non-human client satisfy
an Access policy without SSO. They are the right tool for: a CI job calling the dashboard's API, a
script polling `/health`, an agent posting results. They are the *wrong* tool for anything on the
Workers VPC leg, where the Worker's identity is the account's IAM role, not a token.

Three things to get right if you use them:

1. **One token per machine, not one token for the fleet.** A service token is a bearer credential
   with no per-host binding. A shared token in a shared CI image is a shared secret in a shared
   image. Issue per-runner tokens so revocation is a single-machine operation.
2. **They expire.** The API takes an explicit `duration` (the docs' example is `8760h` — one year),
   after which requests fail. Rotation is supported with a grace window where both secrets work, but
   nothing rotates them for you unless you wire it up. An expired token on 400 runners is a
   fleet-wide outage that looks like a network problem.
3. **`cloudflared` itself can enforce Access on Path A** — `config/configuration.go:240-251`
   (`AccessConfig{Required, TeamName, AudTag}`), validated at `ingress/ingress.go:274-286`. Setting
   `access.required: true` with the right `audTag` means even a request that somehow bypasses the
   edge policy is rejected at the origin. Do this. It is the only defence-in-depth this product
   offers on the inbound side.

There is no equivalent knob on Path B. Workers VPC has no per-request auth token, no mTLS, no
signed identity handed to your gateway. If you need to know *which Worker* called you, you must
carry your own credential in the request — which is another reason the gateway pattern is right:
one place to terminate that credential.

So the answer to "what can the SPA on Workers reach" is:

- The **browser** can reach nothing private. `env.BINDING` exists only in the Worker's server-side
  handlers. A static SPA asset cannot call `connect()` or `fetch()` on a VPC binding.
- The **Worker** can reach whatever the binding scope allows: one pinned host:port per
  `vpc_services` entry, or *anything reachable from that tunnel* per `vpc_networks` entry, or
  **anything in the account** with `network_id: "cf1:network"`.

That makes the Worker a mandatory BFF. The SPA talks to your Worker over the public internet
(protected by Access on the Worker's hostname — Access can protect a Worker directly, not just a
hostname); the Worker talks to the machine over Workers VPC. That part is sound and is the one place
Workers VPC earns its keep.

**Where it does not fit — and this is the load-bearing finding — Workers VPC bindings are static
deploy-time configuration.** `vpc_services` / `vpc_networks` live in `wrangler.jsonc`. There is no
API to add a binding at runtime. For an elastic CI fleet this means: *every new runner requires
redeploying the dashboard Worker.* Combine that with the 1000-VPC-Services-per-account cap and the
`cf1:network` blast radius, and the per-machine binding model collapses at fleet scale.

**The seam that actually works:** terminate Workers VPC at **one** gateway, not at N machines.

```
SPA (Workers assets)
  └─ same Worker, BFF routes  ── vpc_services ──▶  ONE gateway host  ──▶ your orchestrator's own
                                                                          routing table ──▶ runners
```

One binding, pinned host:port, redeployed never. The gateway is your software, so orchestration
stays off Cloudflare — which is exactly the constraint. The Worker gets a stable, narrow,
SSRF-proof door; the fleet churns behind it. Workers VPC degrades gracefully into "an encrypted
pipe with a Cloudflare-shaped NAT traversal", which is the only role it is good at.

The other seam that does not fit: **orchestration traffic through the tunnel.** If your scheduler
and your runner agents both connect out to Cloudflare and meet there, you have re-centralised the
orchestration data plane on Cloudflare. Use a direct WireGuard mesh (Headscale/Netbird/Tailscale)
or your orchestrator's own agent protocol for that leg, and keep `cloudflared` for the dashboard.

## Limits and failure modes

### The tunnel drop

There is **no stream resumption anywhere in the tree.** `grep -rn 'resume\|Resume'` over non-test
Go returns nothing. When the QUIC connection dies, every multiplexed stream dies with it; the origin
`net.Conn` is closed by `stream.Pipe`'s `io.Copy` returning. Recovery is: supervisor notices, backs
off, redials, re-registers. Recovery is **connection**-level, never **request**-level.

Timings, all from source and docs:

| thing | value | where |
|---|---|---|
| QUIC idle timeout | 5 s | `quic/constants.go:7` |
| QUIC keepalive ping | 1 s | `quic/constants.go:8` |
| first reconnect delay | 10 s | `supervisor/supervisor.go:23` |
| backoff sequence | 1,2,4,8,16 s | `retry/backoffhandler.go:164-180`, docs |
| default `--retries` | 5 | `cmd/cloudflared/tunnel/cmd.go:775-779` |
| graceful drain on SIGTERM | 30 s default, **3 min hard max** | docs; `connection/connection.go:26` |

So a 5-second packet-loss event is enough to kill the tunnel, and anything in flight with it. A
`connect()` socket held open by a Worker for a CI job is gone, and the Worker gets
`connection_terminated` or `destination_unavailable` (documented error codes). There is no
`Last-Event-ID`, no offset, no resume token. Your Worker code must be written to treat every VPC
call as idempotent and retryable, and it must re-establish from scratch.

### The daily self-inflicted outage

Auto-update is on by default, every 24 h, from `update.argotunnel.com`, and it **restarts the
daemon**. Restart = `GracefulShutdown` with a 30 s grace = every stream older than 30 s is killed.
For a workload whose defining property is "long-running", this is a scheduled outage you did not
ask for. `--no-autoupdate` / `NO_AUTOUPDATE` is not optional in this design; treat a default
install as misconfigured.

### No load balancing, no draining, don't autoscale

From the Workers VPC tunnel docs, verbatim: *"We do not recommend using `cloudflared` in autoscaling
setups because downscaling (removing replicas) will break existing user connections. Additionally,
`cloudflared` does not load balance across replicas; replicas are strictly for high availability and
requests are routed to the nearest replica."* And from the tunnel-availability page: *"Replicas do
not support traffic steering... forwarded to the geographically closest replica. If that connection
fails, Cloudflare retries with other replicas, but there is no guarantee about which one is chosen."*

Consequence for a CI fleet: you cannot run 50 runners as 50 *replicas of one tunnel* — a request for
runner-7 may land on runner-12's `cloudflared`. You need **one tunnel per machine**, addressed by
`tunnel_id`. Which brings back the static-binding problem.

### QUIC-only for Workers VPC

Workers VPC requires the tunnel to run `--protocol quic` or `auto`, with **outbound UDP 7844** open.
There is no HTTP/2 fallback for this path — the troubleshooting page lists exactly this as the cause
of `ProxyError: dns_error` when someone sets `TUNNEL_TRANSPORT_PROTOCOL: http2`. The same binary
*can* serve Zero Trust over HTTP/2/443. So a runner behind a UDP-blocking egress firewall is
reachable via Path A and **unreachable** via Path B, with an error message that says "DNS error".
That is a nasty debugging trap.

### Workers-side ceilings

- **6 simultaneous connections in the "waiting for response headers" phase** per invocation
  (`connect()` counts). Not 6 total — once headers arrive the slot frees — but a fan-out that opens
  50 sockets at once will serialise behind 6. Documented, not a bug, still a design constraint.
- **128 MB per isolate.** Buffering a large artifact or a long log in memory is out. You must stream.
- **CPU: 30 s default, 5 min max on Paid.** Waiting on network doesn't count, so this only bites if
  the Worker does real work on the payload — e.g. parsing a build log.
- **No hard wall-clock limit** for HTTP-triggered Workers, *but* "during routine runtime updates,
  processes give existing requests and connections up to 20 minutes to finish" and then terminate
  them. So even a perfectly-behaved infinite stream gets cut on Cloudflare's schedule, not yours.

Put together: Workers VPC can carry a long stream, but neither end will guarantee it survives, and
neither end will tell you where it broke.

### Blast radius

- `vpc_services` pins host:port — good, this is the SSRF-resistant default.
- `vpc_networks` with `tunnel_id` — the Worker can reach **any host:port reachable from that
  `cloudflared`**, including `169.254.169.254`, the orchestrator API, and every runner's Docker
  socket if it is on the host network.
- `vpc_networks` with `network_id: "cf1:network"` — **the entire account**. Every tunnel, every Mesh
  node, every WAN route.

One bug that lets a user-supplied URL reach `env.VPC.fetch()` is a full private-network SSRF. Use
`vpc_services` exclusively; the extra config is the security control.

### Ports and moving parts

Inbound: **none** (that is the point). Outbound: UDP 7844 (QUIC), TCP 443 (edge fallback, update,
management), plus whatever origin ports the ingress rules name. Local listeners:
`127.0.0.1:20241-20245` (or `0.0.0.0` in containers — note `metrics/metrics.go:47-52`).

Moving parts: 1 binary, 1 token, 4 edge connections, N replicas, 1 metrics endpoint, 1 management
channel, plus two proprietary Cloudflare services (the tunnel edge and the VPC control plane) that
you cannot inspect or replace.

### Size

`cloudflared-linux-amd64` = 40,263,303 bytes (38.4 MiB); the FIPS build is 40,263,349 bytes; the
`.deb` is 19,919,388 bytes. 43 direct + 45 indirect Go modules, 126 unique modules in `go.sum`,
46,305 non-test LOC. That is a chunky but normal Go daemon. It is not a 2 MB sidecar; budget for it
in the image.

## Licence and governance

- **Apache-2.0** (`LICENSE`, and GitHub reports `spdx_id: Apache-2.0`). Clean, permissive, no
  copyleft surprise, no open-core carve-out in the repo. This is genuinely the good case.
- **Not abandoned, not single-maintainer.** 16,337 stars, 1,506 forks, 572 open issues, not
  archived, pushed within the hour of this review. The contributors API returns 100+ (paged cap),
  with a dozen Cloudflare employees in the hundreds of commits each. Releases land roughly weekly
  (2026.10.4 on 2026-10-27, 2026.10.5 the same day). The risk is **velocity, not neglect**.
- **Velocity is a real risk.** `CHANGES.md` shows `2026.2.0` **deleted `proxy-dns` outright** and
  `2026.4.0` changed the `--edge-ip-version` default from `4` to `auto`. Two breaking changes in a
  year, shipped in a daemon that auto-updates itself daily. **Pin the version and set
  `NO_AUTOUPDATE`.** This is the single most important operational instruction in this document.
- **The licence trap is not the client, it is the service.** `cloudflared` is Apache-2.0; Cloudflare
  Tunnel, Workers VPC, and Access are proprietary SaaS with no source and no exit path. Workers VPC
  is **beta** — the docs say on every page *"Features and APIs may change before general
  availability"* — and **free only during open beta**. You are building a dashboard dependency on an
  unpriced product. Model the post-GA price as unknown, because it is.
- **Governance of your own fleet.** Two defaults are hostile to a CI environment:
  `management-diagnostics: true` with `https://*.cloudflare.com` CORS (support can pull pprof/logs/
  config through your tunnel), and 24-hourly self-updating from `update.argotunnel.com`. Both are
  one flag away from off. Turn them off.
- **Remote config.** `orchestration/orchestrator.go:104` `UpdateConfig` lets the edge push a new
  ingress table into a remotely-managed tunnel at runtime. Your routing table is not solely yours.

## Verified facts

| claim | value | source |
|---|---|---|
| cloudflared licence | Apache-2.0 | `LICENSE` (local clone); `https://forge.web.pkgforge.dev/github/repos/cloudflare/cloudflared` → `license.spdx_id` |
| latest release | 2026.10.5, published 2026-10-27T13:31:37Z | `https://forge.web.pkgforge.dev/github/repos/cloudflare/cloudflared/releases/latest` |
| linux-amd64 binary size | 40,263,303 bytes (38.4 MiB) | same releases API, asset `cloudflared-linux-amd64` |
| repo activity | 16,337 stars, 1,506 forks, 572 open issues, not archived, pushed 2026-10-29T11:46:20Z | repo API |
| Go module graph | 43 direct + 45 indirect requires; 126 unique modules in `go.sum`; 302 lines | `go.mod:1-106`, `go.sum` |
| source size | 390 `.go` files; 46,305 non-test LOC | local clone, `find`/`wc -l` |
| default HA edge connections | 4, flag hidden | `cmd/cloudflared/tunnel/cmd.go:781-785` |
| QUIC idle timeout / keepalive | 5 s / 1 s | `quic/constants.go:5-8` |
| default retries / first reconnect delay | 5 / 10 s | `cmd/cloudflared/tunnel/cmd.go:775-779`, `supervisor/supervisor.go:23` |
| graceful shutdown window | 30 s default, 3 min hard max | `connection/connection.go:26`; run-parameters docs |
| auto-update default | every 24 h from `https://update.argotunnel.com` | `cmd/cloudflared/updater/update.go:25,30` |
| remote diagnostics default | `management-diagnostics = true`, CORS `https://*.cloudflare.com` | `cmd/cloudflared/tunnel/cmd.go:889-894`; `management/service.go:34-43` |
| management JWT verification | signature **not** verified locally (`UnsafeClaimsWithoutVerification`); only non-empty claims checked; no `exp`/`aud` check | `management/token.go:43-58`, `:18-21, 28-40` |
| management rule injected unconditionally | yes, into every tunnel | `cmd/cloudflared/tunnel/cmd.go:462` |
| management hostname default | `management.argotunnel.com` | `cmd/cloudflared/tunnel/cmd.go:1087` |
| metrics listener | `localhost:20241-20245` (0.0.0.0 in containers) | `metrics/metrics.go:47-52` |
| origin timeouts | connect 30 s, TLS 10 s, keepalive 30 s / 90 s | `ingress/config.go:15-19` |
| max active flows default | 0 = unlimited | `ingress/config.go:25`; `flow/limiter.go:8-9` |
| stream resumption | none — no `resume` symbol in non-test Go | local clone, grep |
| Workers VPC status | open beta; free on all Workers plans while beta | https://developers.cloudflare.com/workers-vpc/ |
| Workers VPC requires QUIC | `auto` or `quic`; outbound UDP 7844; `http2` breaks DNS resolution | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ ; .../reference/troubleshooting/ |
| minimum cloudflared version for Workers VPC | 2025.7.0 | .../workers-vpc/configuration/tunnel/ |
| `connect()` availability | VPC Networks only; **plaintext TCP only** | https://developers.cloudflare.com/workers-vpc/api/ ; .../configuration/vpc-networks/ |
| `connect()` over VPC Networks GA date | 2026-06-16 | https://developers.cloudflare.com/changelog/post/2026-06-16-tcp-connect-vpc-networks/ |
| VPC Services TCP | only via Hyperdrive; `app_protocol` postgresql/mysql | .../workers-vpc/configuration/vpc-services/ |
| VPC Service limits | 1000 per account | https://developers.cloudflare.com/workers-vpc/platform/limits/ |
| Workers VPC pricing | free during open beta; Workers compute/requests billed normally | https://developers.cloudflare.com/workers-vpc/platform/pricing/ |
| Workers simultaneous open connections | 6 in "waiting for response headers" phase; `connect()` counts | https://developers.cloudflare.com/workers/platform/limits/ |
| Workers memory / CPU | 128 MB per isolate; 30 s default CPU, 5 min max on Paid | same page |
| Workers runtime-update grace for in-flight connections | up to 20 minutes, then terminated | same page |
| replica behaviour | no traffic steering; nearest replica; downscaling breaks live connections; no autoscaling | .../workers-vpc/configuration/tunnel/ ; .../cloudflare-tunnel/configure-tunnels/tunnel-availability/ |
| recommended tunnel host size | 4 GB RAM, 4 vCPU, 2 hosts per network location | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/hardware-requirements/ |
| Access service token headers | `CF-Access-Client-Id` / `CF-Access-Client-Secret`; example duration 8760 h | https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/ |
| Access can protect a Worker directly | yes, by Worker name, not just hostname | https://developers.cloudflare.com/workers/configuration/cloudflare-access/ |
| `connect()` broken in `wrangler dev` with remote bindings | `TypeError: Incoming CONNECT on a worker not supported`; fixed/closed 2026-07-24 | https://forge.web.pkgforge.dev/github/repos/cloudflare/workers-sdk/issues/14710 |
| `proxy-dns` removed | breaking, 2026.2.0 | `CHANGES.md:5-20` |
| `--edge-ip-version` default changed 4 → auto | breaking, 2026.4.0 | `CHANGES.md:1-4` |

## Rejected / not for this

- **Workers VPC as the CI data plane.** No stream resumption, 128 MB isolate, 6-connection header
  phase, per-request billing, beta API. Streaming a 40-minute build log through a Worker to a
  browser is possible and will fail in ways you cannot debug from the Worker side. Use the
  orchestrator's own ingress for logs and artifacts.
- **`vpc_networks` with `cf1:network`.** Account-wide private-network reachability from a dashboard
  Worker is an SSRF catastrophe waiting for one missing URL validation. `vpc_services` only.
- **One VPC Service per runner.** Hits the 1000/account cap and forces a Worker redeploy per fleet
  change. Terminate at a gateway instead.
- **`cloudflared` replicas as a load balancer.** Explicitly not what they do (nearest-replica, no
  steering). If you need balancing, that is your gateway's job.
- **`cloudflared` as the orchestrator's rendezvous.** Re-centralises orchestration on Cloudflare at
  L4 after you decided to leave it at L7. Direct mesh for that leg.
- **`--protocol http2` for anything Workers VPC touches.** Silently breaks DNS resolution in the VPC
  path and surfaces as a misleading `dns_error`.
- **Default install settings** (`autoupdate` on, `management-diagnostics` on). Both are wrong for a
  CI fleet.
- **Quick tunnels (`trycloudflare.com`)** and `proxy-dns` — the latter is gone as of 2026.2.0.

## Open questions

1. **What is the Workers VPC binding limit per Worker?** Docs state 1000 VPC Services per account
   but say nothing about how many `vpc_networks` bindings a single Worker may declare. This decides
   whether the gateway pattern is merely advisable or mandatory.
2. **Does `connect()` over VPC Networks honour `secureTransport: "on"` / `startTls()`?** The docs say
   "plaintext TCP only" but the generic `SocketOptions` API offers TLS. If TLS is genuinely
   unavailable, `rediss://` and `sslmode=require` Postgres are both impossible over Path B and must
   be terminated at the gateway. Unresolved; assume unavailable.
3. **What is the per-connection throughput and concurrent-connection ceiling of one tunnel?** The
   hardware page gives 4 GB/4 vCPU but no numbers. `MaxConcurrentStreams = math.MaxUint32`
   (`connection/connection.go:27`) is a lie told to the QUIC library; the real ceiling is the edge's.
   Needs a load test before you commit.
4. **Is there a per-request wall-clock limit on `fetch()` through a VPC binding?** The Workers limits
   page says no hard duration limit for HTTP-triggered Workers, but says nothing specific to VPC
   bindings. The 20-minute runtime-update grace suggests there is an implicit one.
5. **Post-GA pricing for Workers VPC.** Unknown, and it is the entire cost model of this leg.
6. **Can the management channel be removed entirely, or only de-fanged?** `--management-diagnostics`
   controls the diagnostic routes, but the management *rule* is injected unconditionally at
   `cmd/cloudflared/tunnel/cmd.go:462` and the JWT is not locally verified
   (`management/token.go:51`). Setting `--management-hostname` to a name you do not own appears to be
   the only lever. Not documented; test before you assume you have closed the door.
7. **Does Access on the Worker's hostname cover the VPC binding calls?** It covers browser→Worker.
   It does not appear to touch Worker→origin. If your threat model assumes end-to-end auth on the
   private leg, you need mTLS or a shared secret between the Worker and the gateway — Workers VPC
   gives you neither.
