# Lane 07 — gofixpoint/amika deep read

Read on 2026-10-29. Cloned `https://github.com/gofixpoint/amika` at
`fe5accb095bffdc2a560706ce92764114dfcfb1f` (2026-10-28T19:53:30Z, "Speak
amika.tunnel.v2 to a per-host relay (#639)"). Read the Go CLI/daemon, the
TypeScript workspace (`js/tunnel-protocol`, `js/service-auth`, `js/sandbox`,
`js/amika-hostd`), `sandbox-image/`, `docs/`, and the publicly served OpenAPI
document. Nothing was run; all statements below are from source or from pages
fetched today.

## Verdict

Amika is **not** a self-hostable compute or CI control plane, and its own docs
say so: the control plane, the web UI and the relay are closed source, and the
`--local` Docker mode was removed, so every `amika` command now talks to
`app.amika.dev`. What *is* open (Apache-2.0, ~28k lines of Go and ~28k of TS)
is a genuinely good set of **node-side and protocol-side primitives**: a
complete BYOC node agent (`amika-hostd`) that runs microVMs through smolvm, a
402-line multiplexed tunnel wire format, an HMAC service-token/browser-session
auth library, a provider-agnostic compute adapter with six backends, and an
in-VM daemon with a loopback-only sshd. The single most important caveat is
that the piece that makes Amika architecturally interesting for this study —
the **per-host tunnel relay implemented as a Cloudflare Durable Object** — is
exactly the piece that is not in the repo (`js/gateway-cloudflare` lives in the
private `amika-mono`). You can copy the pattern and the client half of the
wire protocol; you cannot copy the relay. Also, every reusable package is
`"private": true`, so reuse means vendoring source, not `npm install`.

## Findings

### What is open, what is closed — from the project's own README

The README has an explicit split. Open source: `amika` (CLI), `amikad` (in-VM
daemon), `sandbox-image` (rig images), `amika-sdks`. Closed source, verbatim
from https://github.com/gofixpoint/amika/blob/main/README.md:

> ### Closed source
>
> - `amika-control-plane`: control plane that schedules Rigs and stores references to all Rigs
> - `amika-ui`: web UI for interacting with Amika agents and Rigs
> - `amika-relay`: handles fully e2e encrypted...

and "What will be open sourced soon": `amika-gateway` (the in-cloud gateway
that receives signed/encrypted commands) and `sandbox-provisioner` (the adapter
layer to E2B/K8s/Modal/Daytona).

I verified this is not a documentation slip: the GitHub org has 15 public repos
(`https://forge.web.pkgforge.dev/github/orgs/gofixpoint/repos?per_page=100`)
and none is a control plane, UI, relay or gateway. The only Amika repo with
non-trivial traction is `gofixpoint/amika` itself (295 stars); the rest are
SDK/example repos with 0–3 stars.

### Self-hosting is explicitly unsupported

`docs/self-hosting.md` is blunt:

> The `amika` CLI no longer creates Rigs on your own machine. The `--local` mode,
> which ran each Rig as a Docker container on the host, has been removed, so every
> `amika` command now talks to the Amika control plane.
>
> There is currently no supported local CLI path. Rig commands use the hosted
> Amika control plane.

and the only planned escape hatch is the unshipped gateway:

> when we open source the `amika-gateway`, you can run a fully self-hosted version of Amika
>
> the self-hosted `amika-gateway` is designed for single-player, so it doesn't support identity and access management for multiple users creating and connecting to Rigs

So the vendor's own target for self-hosting is single-player, no IAM. That is a
direct statement that multi-tenant self-hosting is out of scope even after the
gateway ships.

Corroborating detail from the code: `go/internal/sandbox/` still contains
`docker.go`, `volume_store.go`, `file_mount_store.go` and preset-image build
code, but the only remaining importers are `sandbox_create.go` and `skill.go`,
and they use it purely for validation (`ValidateGithubAuthMode`,
`ValidatePreset`, `GenerateName`). The container lifecycle path is vestigial.
`docs/architecture/overview.md` still describes "Docker sandbox management" and
is stale relative to the code.

### The Cloudflare coupling — the interesting finding

Amika runs its own edge exactly where this study wants to run its dashboard:
Cloudflare. `js/amika-hostd/docs/tunnel.md` (verbatim):

> Each host's connection is held by its own relay (a Cloudflare Durable Object),
> which opens one stream for each public request it forwards.

> The relay is in amika-mono (`js/gateway-cloudflare`).

and on the keep-alive:

> The relay registers that pair with Cloudflare's `setWebSocketAutoResponse`, so
> its runtime answers without waking the relay: an idle host costs nothing, and
> the relay is not billed a message for it.

The shared protocol package is written to run on both sides:
`js/tunnel-protocol/AGENTS.md` says "**It runs in a Cloudflare Worker as well as
Node.** Use `Uint8Array`, `DataView` and `TextEncoder`. No `Buffer` and no
`node:` import." Even the keep-alive strings are namespaced (`amika.tunnel.v2.ping`)
because Cloudflare's auto-response applies to every WebSocket the relay accepts,
including the caller's side of a relayed upgrade — a plain `ping` would be
swallowed by the runtime.

**This is the architectural precedent worth stealing.** Amika's split is:
orchestration and state in a non-Cloudflare control plane; Cloudflare holding
only one Durable Object per host as a WebSocket relay; the dashboard on the
edge. That maps almost exactly onto the study's constraint (SPA on Workers,
orchestration off Cloudflare, machines reached over Tunnel). One DO per host is
also the correct sharding: it is a dumb, stateful byte-forwarder with a
credential check and a lease, not a scheduler.

What you cannot take: the relay itself. It is not in the repo. The open half is
the client (`tunnel-dial.ts`, `tunnel-session.ts`, `tunnel-bridge.ts`,
`tunnel-serving.ts`, `tunnel-backoff.ts`) plus the codec. Writing the Worker
side against `amika.tunnel.v2` is a bounded job — the frame set is 9 types
(`open/response/data/end/reset/window/text/binary/close`), with per-stream
credit flow control (`INITIAL_WINDOW` 256 KiB, `MAX_DATA_BYTES` 64 KiB,
`MAX_CONCURRENT_STREAMS` 256) — but it is work you would do yourself.

### Reusable piece 1: `@amika/tunnel-protocol` — a real, small multiplexer

`js/tunnel-protocol/src/index.ts` is 402 lines plus a 77-line `window.ts`. It is
a complete HTTP-over-WebSocket multiplexer: request/response *heads* (not raw
HTTP bytes) as JSON, bodies streamed as `DATA` under credit, WebSocket upgrades
relayed as `message` frames with close codes preserved, zod-validated heads, and
`MalformedHeadError` so one bad `OPEN` resets one stream instead of killing the
connection. Versioning discipline is explicit: "A change to the wire format is a
new subprotocol" and the gateway answers old subprotocols `426`.

Design detail worth reusing regardless of Amika: the relay does not proxy HTTP
bytes because a Worker has no HTTP client that can write into a custom stream.
It sends a *head* and the host reconstructs HTTP with Node's own parser via a
socket pair. That is the correct way to get correct chunked/`Connection`/early-
response handling without reimplementing RFC 9112.

### Reusable piece 2: `@amika/service-auth` — token and session crypto

1869 lines of non-test TS, Web Crypto only, no HTTP server. Two entry points:
`credentials` (sign/verify HMAC-SHA256 service tokens bound to one machine and
one service, ≤1 day; browser login passes; `__Host-` session cookies) and
`gateway` (`authorize(request)` → `forward` | `refuse` | `login` | `not-mine`).
Boundary rule in its `AGENTS.md`: "Credentials use only Web Crypto, so they run
wherever the control plane does" and "No imports from amika-hostd or
`@amika/sandbox`". The `not-mine` verdict is a nice contract: it lets a single
Hono app host both its own routes and the proxied service routes without a
routing table.

Caveat: it signs and verifies; it does not *mint*. Minting is done by the closed
control plane (`signServiceToken` is called from `@amika/sandbox-provisioning`,
which is not in the repo). You would write the issuer — small, but yours.

### Reusable piece 3: `@amika/sandbox` — the provider adapter contract

`js/sandbox/src/providers/provider.ts` opens with "Amika-agnostic primitive
sandbox-provider interfaces… It deliberately knows nothing about Amika workflows
or product features." Six providers are implemented: `daytona`, `e2b`,
`freestyle`, `vercel`, `smol`, `amika-hostd` (`js/sandbox/src/types.ts`,
`SANDBOX_PROVIDER_NAMES`). There is a declared capability matrix
(`lifecycle`, `ssh`, `services`, `exec`, `snapshots`, `streaming`,
`dockerRegistries`, …) so callers gate on capability rather than catching
`SandboxProviderUnsupportedError`. The folder convention is enforced by a custom
eslint rule (`local/no-cross-package-internal`) that makes each provider's
`internal/` unreachable from outside — a clean way to keep vendor SDKs out of
browser bundles, and the reason `capabilities.ts` is a separate SDK-free file.

This is the most directly transplantable idea for a self-hosted control plane:
one adapter contract, per-provider capability flags, vendor SDK quarantined
behind `internal/`.

### Reusable piece 4: `amika-hostd` — a working BYOC node agent

10,655 lines of non-test TS. It is the only component in the repo that is a
*server*: a Hono app on Node that manages VMs and serves them over either a
listening port or an outbound tunnel. Concretely it provides:

- `MachineRuntime`, an 11-method interface (`list/get/create/start/stop/remove/
  exec/readFile/writeFile/checkServices/hostPort`) in
  `js/amika-hostd/src/internal/machine-runtime.ts`. **This is the seam.** The
  only implementation is smolvm; a Docker, Firecracker or K8s runtime behind the
  same interface would drop in, and the HTTP surface, service routing, auth and
  tunnel would all keep working unchanged.
- HTTP surface (`js/amika-hostd/src/app.ts`): `/health`, `/api/v0beta1/rigs`
  (list/create), `/api/v0beta1/rigs/:name` (get/delete),
  `PUT .../:name/services`, `POST .../:name/{start,stop,exec}`,
  `GET|PUT .../:name/files/*`, `/api/v0beta1/snapshots/*`, plus
  `/api/v1/machines` as a legacy alias.
- Service proxying at `/v0beta1/rigs/:name/services/:service/*` with
  `X-Amika-Hostd-Key`, and browser previews at `.../previews/:service/*` with a
  cookie login flow through `/__amika/login` and `/__amika/callback`.
- Managed loopback-only sshd in the guest, deliberately on port 60997 rather
  than 22 because base images may ship a socket-activated `ssh.socket` on
  `*:22` (see `go/internal/constants`).

Its control-plane dependency is tiny. `js/amika-hostd/src/internal/amika-api.ts`
makes exactly six outbound calls, and three of them are the same endpoint:

- `POST /api/v0beta1/hosts` (register: hostname, secret, sizes, transport_mode)
- `PUT /api/v0beta1/hosts/{id}` (url, sizes, transport, secret)
- `POST /api/v0beta1/hosts/{id}/enrolment` (→ credential, generation, gateway_url)

So a self-hosted control plane that drives `amika-hostd` needs to implement
three endpoints, plus a tunnel relay. That is the realistic reuse path, and it
is far smaller than "reimplement the Amika API".

Note also `AMIKA_HOSTD_API_URL` and `AMIKA_HOSTD_TUNNEL_GATEWAY_URL` exist
(`js/amika-hostd/docs/configuration.md`), so hostd is *already* pointable at
your own control plane and your own gateway without patching. The missing pieces
are on the server side, not the node side.

### The public OpenAPI contract — the closed API is fully specified

`https://app.amika.dev/api/openapi.json` is served unauthenticated:
OpenAPI `3.1.0`, `"title":"Amika API","version":"0beta"`, 364 KB, **85 paths and
91 component schemas**. It covers hosts, enrolment, rigs/sandboxes (the same
resources under two path prefixes), services and service tokens, snapshots,
secrets (per-vendor: `secrets/claude`, `secrets/codex`, `secrets/pi`,
`secrets/ssh-public-keys`), API keys, repositories, docker registries, agent
sessions with a streaming endpoint, Slack and Linear settings, and
`storage/uploads` + `storage/downloads`.

This materially changes the assessment: the protocol is open even though the
implementation is not. Combined with two config hooks, a compatible control
plane is feasible without forking any client:

- CLI: `go/internal/config/config.go` — `EnvAPIURL = "AMIKA_API_URL"`,
  `DefaultAPIURL = "https://app.amika.dev"`, and `EnvAPIKey = "AMIKA_API_KEY"`
  takes precedence over stored credentials, so you can bypass WorkOS device auth
  with a static bearer token. WorkOS is otherwise hardcoded
  (`DefaultWorkOSClientID = "client_01KHA495MJS1KT6QBRTYJ239DY"`, overridable via
  `AMIKA_WORKOS_CLIENT_ID`) — i.e. auth is outsourced to a third-party SaaS by
  default.
- `@amika/sdk` (npm, 0.15.0, MIT) also honours `AMIKA_API_URL`.

`HostEnrolmentResponse` in the spec confirms the relay contract exactly:
`credential` ("Sent as `x-amika-host-credential` when the host dials the
gateway"), `generation` ("The gateway fences a stale connection with it"),
`gateway_url` ("The WebSocket address to dial, path included"), `transport_mode`
(always `tunnel`). `CreateSandboxRequest` bounds resources at 1–16 vCPU,
≥64 MiB memory, ≥1 GiB disk, and `auto_stop_interval` ≤ 10080 (7 days).

### What does not work for this study's workloads

- **Heavy CI.** There is no job queue, no runner registration, no matrix, no
  artifact model, no dependency cache, and no build-result API in the 85 paths.
  The GitHub integration is `sandbox-bindings` (bind a rig to a repo+branch) and
  a `github_auth_mode` field — i.e. "spin up a devbox for this branch", not
  "schedule these jobs". Amika's own framing is "plug into your GitHub CI to not
  only run unit tests, but auto-fix failures" (README) — a *consumer* of CI, not
  a replacement.
- **Long-running containers.** Rigs are VMs (smolvm, Daytona VMs, E2B), not
  containers, and there is no `docker run`-shaped API. The Docker path was
  removed. `sandbox-image` produces OCI Dockerfiles, but only as *VM/preset
  image inputs* (`generated/coder.Dockerfile` etc.), and the generated variants
  are filtered per provider (`daytona`, `e2b`).
- **Kubernetes.** The README claims "Create Rigs on Kubernetes nodes" and "a
  node in your Kubernetes cluster", but `kubernetes`/`k8s` appears nowhere in the
  implementation except one comment about the `healthz` naming convention
  (`go/internal/amikad/operations.go:184`). The provider enum has no `k8s`
  value. The Kubernetes adapter is the closed-source `sandbox-provisioner`.
- **Multi-tenant self-hosting.** Even the future self-hosted gateway is
  documented as single-player with no IAM.
- **Snapshots on the BYOC path are partial.** `smolCapabilities` sets
  `snapshots: false`, `fullSnapshotCapture: false`, `ssh: false`,
  `streaming: false`. hostd exposes its own `/api/v0beta1/snapshots` store, but
  the smol provider does not do provider-native snapshots.
- **Published packages.** `@amika/tunnel-protocol`, `@amika/service-auth`,
  `@amika/sandbox`, `@amika/hostd` are all `"private": true` at version 0.0.1.
  Only `@amika/sdk` is on npm. Reuse = vendoring.

### Size and health

28165 lines of non-test Go, 27759 of non-test TS, 228 test files. CI exists
(`.github/workflows/ci.yml`, plus `release.yml`, `zizmor.yml` for Actions
security scanning). Commit cadence is high — five commits on 2026-10-28 alone,
all tunnel-related. The project is `status: beta` per its own README badge and
has 45 open issues. Recent work is concentrated on the tunnel and on BYOC;
the filesystem/data-plane roadmap (`docs/architecture/fs-roadmap.md`) is mostly
🟡/⚪, not built.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| amika (whole) | https://github.com/gofixpoint/amika | Apache-2.0 | `fe5accb` 2026-10-28; release `amika-hostd@v0.6.0-beta.1` 2026-10-28 | CLI + node agent + tunnel protocol + auth lib + provider adapters + rig images | No self-host path; control plane, UI, relay, gateway all closed; `--local` removed |
| `@amika/tunnel-protocol` | `js/tunnel-protocol` | Apache-2.0 (repo) | 2026-10-28 | 402-line HTTP-over-WS multiplexer, zod heads, credit flow control, `amika.tunnel.v2` | Client+codec only; relay is closed; `private: true`, not on npm |
| `@amika/service-auth` | `js/service-auth` | Apache-2.0 (repo) | 2026-10-28 | HMAC service tokens, browser login passes, `__Host-` sessions, `authorize()` → forward/refuse/login/not-mine | Verifies but does not mint; issuer lives in closed `sandbox-provisioning` |
| `@amika/sandbox` | `js/sandbox` | Apache-2.0 (repo) | 2026-10-28 | Provider-agnostic adapter + capability matrix; 6 backends (daytona, e2b, freestyle, vercel, smol, amika-hostd) | No K8s/Docker/Firecracker adapter; vendor SDKs pinned per provider |
| `amika-hostd` | `js/amika-hostd` | Apache-2.0 (repo) | `v0.6.0-beta.1` 2026-10-28 | Real BYOC node agent: VM lifecycle, exec, files, service proxy, previews, outbound tunnel, loopback sshd | Needs a control plane (3 endpoints) + a relay; only smolvm runtime; smol has no snapshots/ssh/streaming |
| `amikad` | `go/cmd/amikad`, `go/internal/amikad` | Apache-2.0 | 2026-10-28 | In-VM daemon: managed loopback sshd on 60997, authorized-keys/token rotation, `norelay` WS→sshd bridge | Narrow; no agent messaging/filesystem layer that ROADMAP promises |
| `sandbox-image` | `sandbox-image/` | Apache-2.0 | 2026-10-28 | Manifest-driven rig image: 15 ordered steps, per-provider generated Dockerfiles | OCI/Docker only; consumed as VM/preset input, not as a container runtime |
| `@amika/sdk` | npm `@amika/sdk` | MIT | 0.15.0, 2026-10-23 | TS client for the hosted API; honours `AMIKA_API_URL` | Client only; generated from a closed server |
| smolvm | https://github.com/smol-machines/smolvm | Apache-2.0 | pushed 2026-10-29, 6868 stars | microVM engine hostd runs on; local or self-hosted, `.smolmachine` artifacts | Separate project; not Amika; no orchestration |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| Repo license | Apache-2.0 | https://github.com/gofixpoint/amika/blob/main/LICENSE | "Apache License / Version 2.0, January 2004" |
| License per GitHub API | `Apache-2.0` | https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika | `"license": {"key":"apache-2.0","spdx_id":"Apache-2.0",…}` |
| Stars / forks / open issues | 295 / 26 / 45 | https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika | `"stargazers_count": 295`, `"forks_count": 26`, `"open_issues_count": 45` |
| Repo created | 2026-02-05 | https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika | `"created_at": "2026-02-05T21:52:07Z"` |
| Last push | 2026-10-28 | https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika | `"pushed_at": "2026-10-28T20:09:37Z"` |
| Latest release | `amika-hostd@v0.6.0-beta.1`, 2026-10-28 | https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika/releases?per_page=5 | `"tag_name": "amika-hostd@v0.6.0-beta.1"`, `"published_at": "2026-10-28T20:10:22Z"` |
| Public repos in org | 15 (none is a control plane/UI/relay/gateway) | https://forge.web.pkgforge.dev/github/orgs/gofixpoint/repos?per_page=100 | `count 15` over the full listing |
| OpenAPI doc | OpenAPI 3.1.0, version `0beta`, 364127 bytes, 85 paths, 91 schemas | https://app.amika.dev/api/openapi.json | `{"openapi":"3.1.0","info":{"title":"Amika API","version":"0beta",…` |
| Default API base URL | `https://app.amika.dev` | https://github.com/gofixpoint/amika/blob/main/go/internal/config/config.go | `DefaultAPIURL = "https://app.amika.dev"` |
| API URL override env | `AMIKA_API_URL` | same file | `EnvAPIURL = "AMIKA_API_URL"` |
| Static bearer override | `AMIKA_API_KEY` wins over stored creds | same file | `// EnvAPIKey is the environment variable that provides a WorkOS organization API key … When set, it takes precedence over stored credentials.` |
| Relay implementation | Cloudflare Durable Object, one per host | https://github.com/gofixpoint/amika/blob/main/js/amika-hostd/docs/tunnel.md | "Each host's connection is held by its own relay (a Cloudflare Durable Object), which opens one stream for each public request it forwards." |
| Relay source location | `js/gateway-cloudflare` in private `amika-mono` | same file | "The relay is in amika-mono (`js/gateway-cloudflare`)." |
| Idle host cost model | auto-response, not billed per message | same file | "The relay registers that pair with Cloudflare's `setWebSocketAutoResponse`, so its runtime answers without waking the relay: an idle host costs nothing, and the relay is not billed a message for it." |
| Tunnel stream limits | 256 concurrent streams; 256 KiB initial window; 64 KiB max DATA; 1 MiB max message | https://github.com/gofixpoint/amika/blob/main/js/tunnel-protocol/src/index.ts | `MAX_CONCURRENT_STREAMS = 256`, `INITIAL_WINDOW = 256 * 1024`, `MAX_DATA_BYTES = 64 * 1024`, `MAX_MESSAGE_BYTES = 1024 * 1024` |
| Keep-alive timing | ping every 30 s, 10 s timeout, host silent at 90 s | same file | `KEEP_ALIVE_INTERVAL_MS = 30_000`, `PING_TIMEOUT_MS = 10_000`, `HOST_SILENCE_MS = 3 * KEEP_ALIVE_INTERVAL_MS` |
| Control-plane calls hostd makes | 6 functions over 3 endpoints | https://github.com/gofixpoint/amika/blob/main/js/amika-hostd/src/internal/amika-api.ts | `registerHost`, `setHostUrl`, `setHostSizes`, `setHostTransport`, `setHostSecret`, `enrolHostTunnel` |
| Managed sshd port | 60997 (deliberately not 22) | https://github.com/gofixpoint/amika/blob/main/go/internal/constants/constants.go | `ManagedSSHDPort = 60997` with "base images may ship a socket-activated system `ssh.socket` bound to the wildcard `*:22`" |
| hostd resource ceilings | 1–16 vCPU, ≥64 MiB, disk ≥1 GiB | https://github.com/gofixpoint/amika/blob/main/js/amika-hostd/src/internal/requests.ts | `cpus: z.number().int().min(1).max(16)`, `memoryMb: z.number().int().min(64)`, `storageGb: z.number().int().positive()` |
| Auto-stop ceiling | 10080 minutes (7 days) | https://app.amika.dev/api/openapi.json | `"auto_stop_interval": {"type":"number","minimum":0,"maximum":10080}` |
| Non-test LOC | 28165 Go, 27759 TS; 228 test files | local clone `fe5accb` | `find go -name '*.go' ! -name '*_test.go' \| xargs wc -l` → 28165 |
| Internal packages published? | no — all `"private": true` at 0.0.1 | local clone, `js/*/package.json` | `"name": "@amika/tunnel-protocol", "version": "0.0.1", "private": true` |
| `@amika/sdk` on npm | 0.15.0, MIT, modified 2026-10-23 | https://registry.npmjs.org/@amika%2Fsdk | `"latest": "0.15.0"`, `"license": "MIT"` |
| smolvm | Apache-2.0, 6868 stars, pushed 2026-10-29 | https://forge.web.pkgforge.dev/github/repos/smol-machines/smolvm | `"stargazers_count": 6868`, `"license": {"spdx_id":"Apache-2.0"}` |
| Amika hosted price, Free | $0, up to 3 active users, $50 credits/org | https://www.amika.dev/pricing | "Up to 3 active users", "$50 of credits per organization to start" |
| Amika hosted price, Team | $30 / mo / active user | https://www.amika.dev/pricing | "$30 / mo / active user" |
| Amika hosted compute | $0.1008/vCPU-h, $0.0324/GiB-h RAM, $0.00216/GiB-h disk | https://www.amika.dev/pricing | "Compute (vCPU) $0.1008 / h", "Memory (GiB) $0.0324 / h", "Storage (GiB) $0.00216 / h" |
| Amika hosted reference rig | ~$0.37/h for 2 vCPU / 4 GiB / 20 GiB | https://www.amika.dev/pricing | "A standard sandbox with 2 vCPU, 4 GiB of memory, and 20 GiB of storage costs about **$0.37 per hour**." |
| Service-account sandboxes | 10 concurrent included, then $2/mo each | https://www.amika.dev/pricing | "10 concurrent service-account sandboxes included, then $2 / mo each" |

## Rejected options

| option | why rejected |
|---|---|
| Use amika as the self-hosted compute/CI control plane | `docs/self-hosting.md`: "There is currently no supported local CLI path. Rig commands use the hosted Amika control plane." Control plane, UI and relay are closed source; nothing to deploy. |
| Self-host by forking the repo and pointing it at yourself | There is no control plane in the repo to fork. `AMIKA_API_URL` lets you point the *client* elsewhere, but the server does not exist in any public artifact. |
| Reuse the Cloudflare Durable Object relay | `js/gateway-cloudflare` is in the private `amika-mono` repo (per `js/amika-hostd/docs/tunnel.md`). Only the client half and the codec are open. |
| `npm install @amika/tunnel-protocol` (or service-auth, sandbox, hostd) | All four are `"private": true` at 0.0.1. Reuse means vendoring the source into your tree. |
| Use Amika as a CI runner for heavy builds | No queue, runner registration, matrix, artifact store, or cache anywhere in the 85-path API. The GitHub surface is `sandbox-bindings` (repo+branch → devbox), not job scheduling. |
| Run long-lived containers on Amika | Rigs are VMs; the Docker container path was removed; `sandbox-image` Dockerfiles are image-build inputs for VM presets, not a container runtime API. |
| Kubernetes as a provider | README advertises it; the provider enum is `daytona/e2b/freestyle/vercel/smol/amika-hostd` and `k8s` appears in no implementation file. The K8s adapter is the unshipped `sandbox-provisioner`. |
| Use `amika-hostd` unmodified as the node agent for a new control plane | Viable *if* you implement `POST /api/v0beta1/hosts`, `PUT /api/v0beta1/hosts/{id}`, `POST /api/v0beta1/hosts/{id}/enrolment` and a relay. Rejected only as a zero-effort drop-in — it is a ~3-endpoint integration, not a turnkey one. |
| Wait for the open-sourced `amika-gateway` | Vendor states the self-hosted gateway is "designed for single-player, so it doesn't support identity and access management for multiple users". Wrong shape for a multi-tenant control plane, and unshipped as of 2026-10-29. |
| Use Amika's WorkOS auth for a self-hosted deployment | `DefaultWorkOSClientID` is a hardcoded third-party SaaS client ID; self-hosting would mean either emulating WorkOS device flow or relying on the `AMIKA_API_KEY` bearer path only. |

## Open questions

- **What exactly is the relay's on-wire behaviour that the client does not
  specify?** The client code and codec are open, but lease renewal, fencing on
  `generation`, `x-amika-connection-id` issuance, and the `4003`/`4008`/`4009`
  close semantics are only described in prose. Settle by reading
  `js/gateway-cloudflare` — not possible while it is private; alternatively
  reverse it from `tunnel-dial.ts`/`tunnel-session.ts` expectations plus a
  hand-written relay and the existing test suite.
- **Is `amika.tunnel.v2` actually stable enough to target?** It was introduced
  in the last commits (`fe5accb`, 2026-10-28) and `v1`/yamux hosts are refused
  with `426`. Settle by watching for a v3 or a 1.0 tag on `amika-hostd`; the
  release is still `v0.6.0-beta.1`.
- **Does the Apache-2.0 grant cover the *protocol* as well as the code?** The
  licence covers the repo. There is no separate patent or spec licence, and no
  CLA/NOTICE file indicating a spec grant. Settle by asking the maintainers;
  practically, implementing a documented wire format from an Apache-2.0 codec
  is low risk.
- **How complete is `amikad` versus the ROADMAP's promises?** `ROADMAP.md`
  describes `amikad` as providing "agent messaging, filesystem management,
  network proxy, and secrets vault", and references an `amikactl` CLI that does
  not exist in the tree. The shipped `amikad` surface is sshd setup, authorized
  keys, connect token, and a `norelay` WS→sshd bridge. Settle by reading
  `go/internal/amikad/operations.go` (done — it is narrow) and by checking
  whether `amikactl` lands in a later release.
- **What is the real per-host rig density and boot time on smolvm?** No
  benchmark in the repo. `smolvm`'s own docs claim sub-second VM starts; not
  verified here. Settle by running `amika-hostd` against smolvm and timing
  `POST /api/v0beta1/rigs` — or by reading smolmachines.com benchmarks.
- **Does the hosted control plane store anything that would block a compatible
  reimplementation?** The `storage/*` endpoints return `bucket`/`path`/
  `download_url`/`expires_in`, implying S3 presigning, but the object-store
  vendor is not disclosed. Settle by calling `POST /api/v0beta1/storage/uploads`
  with a real key and inspecting the returned URL's host.
- **Is `docs/architecture/overview.md` deliberately stale or just forgotten?**
  It still documents Docker sandbox management and `pkg/amika` service types
  that no longer match the code. Settle by opening an issue; until then treat
  every doc under `docs/architecture/` as aspirational except `fs-roadmap.md`'s
  🟢 markers.
