# amika — deep review

## Verdict

**Not a compute platform for this stack, but vendor two files out of it and walk away from the rest.** amika is a commercial product (the Amika org `gofixpoint`, `hello@amika.dev`, product at `amika.dev`) whose open-source tree is a *client* for a closed control plane: `README.md:172-184` lists `amika-control-plane`, `amika-ui` and `amika-relay` as closed source, and `docs/self-hosting.md:10` states flatly "There is currently no supported local CLI path." So it cannot occupy the orchestration slot (which the study says is deliberately not Cloudflare, and amika is not self-hostable anyway), it cannot occupy the compute slot for heavy CI (it is a KVM microVM daemon with no scheduler, and its own upstream calls smolvm "not an orchestrator"), and it cannot occupy the edge-runtime slot (the only Worker-side code, the relay, is closed). What *is* genuinely good, Apache-2.0, and directly on-point for a Workers-hosted dashboard talking to self-hosted machines is 479 lines of tunnel multiplexer codec (`js/tunnel-protocol/src/index.ts` + `window.ts`) and 269 lines of service-token signing (`js/service-auth/src/credentials/signing.ts` + `service-tokens.ts`). Vendor those two, treat the rest as a reference architecture to read once. Do not adopt the daemon.

## What it actually is

A dev-workstation product for coding agents, not infrastructure. The pitch is "multiplayer cloud workstations for coding agents and humans" (`README.md:1-6`): provision a VM ("Rig"), load it with Claude/Codex/OpenCode, and remote-control the agents from Slack, a web UI, or a CLI. The commercial surface is `app.amika.dev`.

The open-source tree is 891 files (`git ls-files | wc -l`), 8.8 MB, split roughly:

- **Go CLI** — 28,165 non-test LOC. `go/cmd/amika` (10,183), `go/internal/apiclient` (4,426), `go/internal/ssh` (5,299). Talks to `https://app.amika.dev` by default (`go/internal/config/config.go:29`).
- **TypeScript daemon** — `js/amika-hostd`, 10,655 non-test LOC plus 12,989 LOC of tests. Hono + `ws` + zod + smolvm.
- **TypeScript libraries** — `js/tunnel-protocol` (479 LOC), `js/service-auth` (1,869 LOC), `js/sandbox` (9,682 LOC of provider adapters).
- **Go in-guest daemon** — `go/internal/amikad`, 786 LOC sshd + 780 LOC no-relay WebSocket bridge.

The README's own framing of what is open vs closed is the single most important fact about this repo, and it is honest about it:

- Open: CLI, `amikad`, sandbox images, TS SDK (`README.md:165-170`).
- Closed: control plane, web UI, relay (`README.md:172-178`).
- "Will be open sourced soon": `amika-gateway` and `sandbox-provisioner` (`README.md:181-184`). That promise is the load-bearing one for self-hosting, and it has not been delivered.

`docs/self-hosting.md` is more blunt than the README: the `--local` mode that ran Rigs as Docker containers on the host **was removed** (`docs/self-hosting.md:6-8`), and the eventual self-hosted gateway is scoped as *single-player only*, with no IAM (`docs/self-hosting.md:21`). That is a product decision, not a bug.

There is also live documentation drift that tells you how much the OSS tree is maintained as a product rather than a platform: `docs/architecture/overview.md:39` still documents "`sandbox/` Docker sandbox management" and `:23` still lists `amika sandbox create|list|connect|delete` — the architecture doc describes the Docker architecture that was deleted. And `go/pkg/amika/doc.go:1` advertises "the public programmatic API for Amika operations" while `go/pkg/amika/service.go:157` calls `sandbox.CreateDockerSandbox` — the removed local-Docker path. `go/internal/app` (which imports it) has **zero importers** outside its own tests. If you import `go/pkg/amika` expecting a control-plane client you get a local Docker container creator.

## Architecture (with file paths)

**The daemon (`js/amika-hostd`).** A Hono app (`src/app.ts`, 613 LOC) that serves two APIs on one handler:

- The machine API at `/v0beta1/rigs` (`src/app.ts:484`), plus a legacy `/api/v1/machines` alias (`src/app.ts:281`) kept "for control planes on providers from before `v0beta1`".
- Service routes `/v0beta1/rigs/:name/services/:service/*` (`src/app.ts:248-251`) and preview routes `.../previews/:service/*` (`src/app.ts:266-275`).
- Snapshot routes (`src/app.ts:303-323`) and `/health` (`src/app.ts:233`).

It drives microVMs by shelling out to `smolvm serve` on a loopback port, starting at 23020 and walking upward (`docs/runtime.md`, `src/internal/smolvm-serve.ts`, 489 LOC). smolvm's API has no authentication, so hostd refuses to bind it anywhere but loopback (`docs/runtime.md`). `src/internal/machine-runtime.ts` (450 LOC) maps hostd's contract onto smolvm's, deliberately bypassing the provider abstraction for exec/files because "the resource surface reports no published ports... reads files as text" (`machine-runtime.ts:1-17`).

**Two transports, one code path.** This is the best design idea in the repo and worth stealing even if you take nothing else. `src/internal/tunnel-serving.ts:4-5` — "Tunnel mode binds no port... Anything else is a second serving path that drifts from the first, and the one that drifts is the one that serves the internet." It builds an ordinary `node:http` server and *never calls `listen`*, pushing each tunnel connection in via the `connection` event (`tunnel-serving.ts:56-70`). So tunnel and listener mode share Node's parser, Hono handler, auth middleware and upgrade handler by construction. The cost is honest and documented: `headersTimeout`/`requestTimeout` do not run because `listen` installs them (`tunnel-serving.ts:44-53`).

**The tunnel client** is eight files, flat in `src/internal/`: `tunnel-dial` (WSS handshake + refusal classification), `tunnel-session` (frame loop, stream table, liveness, drain), `tunnel-bridge` (one stream → one request to the local server), `tunnel-socket-pair` (socketpair for `node:http`), `tunnel-serving`, `tunnel-backoff` (full jitter with a floor), `tunnel-client` (the redial loop), `tunnel-target`. 19 of the `src/internal/*.ts` files are tunnel tests — this part is well tested.

**The codec (`js/tunnel-protocol`).** 402 + 77 LOC, one dependency (zod 4.4.3). A 5-byte header (1 type, 4 stream id), nine frame types (open/response/data/end/reset/window/text/binary/close), per-stream per-direction credit flow control. Constants live in exactly one place and nothing negotiates: `INITIAL_WINDOW = 256 KiB` (`index.ts:57`), `MAX_DATA_BYTES = 64 KiB` (`:59`), `MAX_MESSAGE_BYTES = 1 MiB`, `MAX_FRAME_BYTES = 1 MiB + 64` (`:66`), `MAX_CONCURRENT_STREAMS = 256` (`:76`), 30 s ping / 10 s pong timeout / 90 s host silence (`:47-54`). It is explicitly Worker-portable — "uses `Uint8Array`, `DataView` and `TextEncoder`, never `Buffer`" (`index.ts:8`), and `AGENTS.md` makes that a lint-enforced rule.

Three details show real production scar tissue, and are the reason I'd trust this code: (1) the keep-alive strings are namespaced `amika.tunnel.v2.ping` (`index.ts:43`) *because* Cloudflare's `setWebSocketAutoResponse` fires on every WebSocket the relay accepts, including callers' — a bare `ping` would be swallowed and break an application heartbeat (`index.ts:34-42`); (2) `sendableCloseCode` maps 1005/1006/1015 to sendable codes because those are reported-but-never-sent (`index.ts:296-310`); (3) `MalformedHeadError` carries the stream id so one bad `OPEN` gets a `RESET` instead of killing the tunnel (`index.ts:145-160`).

**The relay is closed.** `docs/tunnel.md:10-16` says each host's connection is held by "its own relay (a Cloudflare Durable Object)" and that "The relay is in amika-mono (`js/gateway-cloudflare`)". Not in this repo. So the wire protocol's *server* half is unavailable; only the client half and the shared codec are.

**Auth (`js/service-auth`).** Two entry points. `credentials/` (556 non-test LOC) is the signing primitive: HMAC-SHA256 with per-use label-derived keys (`signing.ts:19-115`), Web Crypto only, constant-time verify, canonical-base64url check to reject four spellings of one digest (`signing.ts:43-46`), bounded 64-entry key cache. `service-tokens.ts` builds `<expiry>.<sig>` over `v1\n<rig>\n<service>\n<expiry>` with a hard 24 h TTL ceiling (`service-tokens.ts:46`) and a 5-minute skew allowance. The newline-delimited signed text is deliberately unambiguous so a service name containing newlines cannot be reinterpreted as a different rig (`service-tokens.ts:22-24`). `gateway/` (1,313 non-test LOC) is the request-authorization policy: three ways in, credential headers stripped before forwarding, guest `Set-Cookie` dropped for gateway cookies, preview responses hardened (`gateway.ts:1-30`).

**Compute adapters (`js/sandbox`).** 9,682 non-test LOC across six providers: `daytona`, `e2b`, `vercel`, `freestyle`, `smol`, `amika-hostd`. These are **real** SDK integrations, not stubs — the Daytona provider alone is 4,335 LOC of `internal/`. The abstraction is clean: `providers/provider.ts` is 1,018 LOC of provider-agnostic types with a capability-flag system, and `providers/README.md` documents a lint rule (`local/no-cross-package-internal`) enforcing that vendor SDKs stay inside `internal/`. Note the direction of travel though: five of six adapters point at **commercial sandbox clouds** (Daytona, E2B, Vercel Sandbox, Freestyle) — the opposite of self-hosting. There is no Kubernetes, Docker, Firecracker, or containerd adapter in the OSS tree. `grep -rli kubernetes` matches two files, neither a provider.

**The OpenAPI contract** is *not in the repo*. It is served live by the closed control plane at `https://app.amika.dev/api/openapi.json` — I fetched it: 364,127 bytes, OpenAPI 3.1.0, 85 paths, 91 schemas, `info.version = "0beta"`. The repo only carries hand-written Go mirror structs that claim to track it (`go/internal/apiclient/client.go:112-113`: "the 'Sandbox' component schema in the API's OpenAPI document, served at `/api/openapi.json`"). It documents the **control plane's** API (`/api/v0beta1/rigs`, `/sandboxes`, `/secrets`, `/hosts`, `/storage/...`), not hostd's API. hostd's own contract exists only as prose in `js/amika-hostd/docs/api-and-auth.md`.

## The seam into this design

**Where it plugs, precisely:**

1. **`@amika/tunnel-protocol` → your own relay, if you ever replace Cloudflare Tunnel.** This is the one artefact I would actually vendor. 479 LOC, one dep, Worker-safe, Apache-2.0. It solves exactly the "one multiplexed connection from a machine, many concurrent HTTP/WS streams back" problem, with flow control so the relay never buffers a download in the Worker's memory (`docs/tunnel.md`, "Credit" section). If the study ever needs a *self-hosted* replacement for the CF Tunnel leg — rather than consuming CF Tunnel as a given — this is the codec to build it on, and you would have to write the Durable Object relay yourself because `js/gateway-cloudflare` is closed.

2. **`@amika/service-auth/credentials` → dashboard-to-machine auth.** 269 LOC, Web Crypto only, so it runs unmodified in a Worker. `signServiceToken` mints `<expiry>.<HMAC>` scoped to one resource and one service with a 24 h cap; `verifyServiceToken` runs on the machine. No round trip to the dashboard, no shared database, no new secret — both sides derive the key from a per-machine secret with a distinct label. This is a clean fit for "Workers dashboard issues a short-lived scoped token, machine verifies it locally." Take it as a *pattern* even if you rewrite it; the label-derivation and the unambiguous signed-text encoding are the two ideas worth copying.

3. **`tunnel-serving.ts` → the pattern, not the code.** "Never write a second serving path" is the right lesson for any design that has both a listening and a tunnelled ingress.

**Where it will not plug, precisely:**

- **Orchestration / scheduling.** There is no scheduler. `amika-hostd` is one daemon per host, and `up` registers that host with Amika's control plane and enrols it for a gateway (`docs/tunnel.md`, "Enrolment"). The scheduling layer is `amika-control-plane`, closed (`README.md:174`).
- **`amika-hostd up` without `app.amika.dev`.** Impossible. `up` = register + enrol + dial the gateway. The only override is `api_url` pointing at a *different* Amika control plane you do not have.
- **Heavy CI.** smolvm's own documentation is explicit: "Not the right tool when... You need Kubernetes-native scheduling semantics; smol machines is a machine API, not an orchestrator" (smolmachines.com/llms.txt). Rigs are sized 1–16 vCPU / 2–24 GiB / 20–40 GiB disk (`js/amika-hostd/config.example.toml`), one KVM microVM each, booted from a `.smolmachine` image pulled from GHCR. There is no bin-packing, no queue, no autoscaling, no multi-host placement.
- **Long-running containers.** Rigs are VMs, not containers. Docker exists inside the `amika-coder-plus-docker` preset, so you *can* run containers — but nested, one level down, with the VM as the unit of scheduling and restart.
- **The OpenAPI contract as a build target.** It is unlicensed (see below) and describes a service you cannot run.

**The one genuinely standalone seam.** `amika-hostd serve` runs "the HTTP server in the foreground **without registering**" (`src/internal/cli.ts:95`), and the code path requires only `secretKey` — `withSecrets(resolved, deps, { apiKey: false })` then `requireSettings(config, ["secretKey"])` (`cli.ts:288-297`). No API key, no control plane, no enrolment. In `transport = "listen"` mode behind your own CF Tunnel, that gives you a working single-host microVM API: create/get/delete/start/stop/exec/file-read/file-write/service-publish/snapshot, authenticated by one bearer secret. That is a legitimate "node agent" to study — but it is one host, it needs KVM, and you would still be writing the scheduler. If that is all you want, you are better served by an agent that speaks your orchestrator's API directly than by adapting a daemon whose contract is prose-only and whose maintainers removed their own local mode.

## Limits and failure modes

**Quantified:**

| Measure | Value | How |
|---|---|---|
| Repo | 891 files, 8.8 MB | `git ls-files`, `du -sh` |
| hostd bundle | 1,154,504 B (1.13 MB) single ESM file | downloaded `amika-hostd_0.5.0.tar.gz` |
| hostd release tarball | 305,922 B compressed, 1.6 MB unpacked, 29 files | same |
| hostd runtime deps | 9 direct (4 workspace + hono, @hono/node-server, smol-toml, smolmachines, ws, zod) | `js/amika-hostd/package.json` |
| Go CLI | 9 direct deps; 3.8–4.3 MB compressed binaries | `go/go.mod`; release assets |
| Ports | 3020 hostd, 23020 smolvm serve, 60999 amikad | `config.example.toml`; `docs/runtime.md`; `go/internal/amikad/command.go:15` |
| Tunnel limits | 256 streams, 256 KiB window, 64 KiB DATA, 1 MiB message, 90 s silence | `js/tunnel-protocol/src/index.ts:47-76` |
| Test volume | 915 Go test funcs / 125 files; 99 TS test files | `grep -c '^func Test'` |

The test-to-source ratio in hostd is 12,989 test LOC to 10,655 source LOC. That is a real signal, and it is why I trust the tunnel codec.

**What breaks on restart.** `js/amika-hostd/README.md:97-98`: "Stops the daemon and the VMs it is running, keeping their disks. The next `up` brings the daemon back, **but not the rigs**: start those with `amika rig start`." Disks survive; running state does not. There is no reconciliation loop, no desired-state controller. For CI this is the wrong shape — a runner that does not come back after a daemon restart is a runner you have to supervise.

Other failure modes worth knowing:

- **A stale smolvm wedges startup.** `docs/runtime.md`: hostd refuses to start if a smolvm from an earlier run is still alive (checked via `smolvm.pid`), and it refuses to attach to a smolvm it did not start, because that would expose VMs that are not its to stop or drain.
- **smolvm exiting kills hostd** with exit code 1 rather than serving 502s forever (`docs/runtime.md` step 6). Correct, but it means one crash takes the whole node down.
- **Tunnel disconnects do not fail over.** `docs/tunnel.md`: "Disconnecting is **not** shutdown... and it never falls back to opening a port." A host that loses its gateway is simply unreachable until it redials.
- **First `up` is slow and racy.** `README.md:86-88`: the first `up` downloads preset images in the background, and "a rig created before that finishes can time out."
- **Host-side resource exhaustion.** Snapshots are multi-gigabyte `.smolmachine` files on local disk (`config.example.toml`, `snapshot_dir`), and disks under 20 GiB skip smolvm's image cache entirely, so every create re-downloads the whole image.
- **`serve` mode is not the supported path.** It is a debug/dev entry point. Nothing in the docs promises its contract; `docs/api-and-auth.md` documents it, but the product's own guidance is `up`.

## Licence and governance

**Licence: clean.** Apache-2.0, confirmed via the GitHub API (`license.spdx_id = "Apache-2.0"`) and `LICENSE` in-tree. No `NOTICE` file, so no §4(d) propagation obligation. Dependencies are compatible: `smolmachines@1.22.2` is Apache-2.0 (verified in the shipped `package.json` inside the release tarball) and `smolvm` itself is Apache-2.0 (GitHub API, 6,868 stars, pushed 2026-10-29).

**Four licensing/governance traps, in order of how much they matter:**

1. **The OpenAPI document is unlicensed.** `https://app.amika.dev/api/openapi.json` has `info` keys of exactly `title`, `version`, `description` — **no `license` field**, and it lives outside the Apache-2.0 repo, served by a closed service. The repo's Apache-2.0 grant does not reach it. If your plan was "read the OpenAPI and build a compatible control plane," you have no licence to do so from that artefact. The Go mirror structs in `go/internal/apiclient` *are* Apache-2.0, so reimplement from those if you must.
2. **The packages are `"private": true` and export raw `.ts`.** `js/tunnel-protocol/package.json` and `js/service-auth/package.json` both set `"private": true`, version `0.0.1`, and export `./src/index.ts` directly. They are not published to npm and are not consumable as dependencies. Apache-2.0 lets you copy the files, but you are **vendoring source**, not depending on a package — which means you inherit maintenance of the fork on day one.
3. **Contributions are actively discouraged.** `CONTRIBUTING.md:3`: "Instead of submitting PRs, we prefer you open issues... Since AI agents make it easy to generate code, we have a much easier time turning your human-readable prompts and requests into code, than reviewing code you submit." Apache-2.0 gives you the legal right to fork; this tells you the practical cost. If you vendor the codec and find a bug, upstream will not take your patch.
4. **Bus factor 2.** Seven contributors total, of whom `dbmikus` (719 commits) and `jdc123` (703) account for essentially all of it. `claude` (14), `dependabot[bot]` (5), `spline2hg` (3), `cursoragent` (2), `57hemanth` (1) are noise. Both principals are at the company; if Amika pivots, the OSS tree stops.

**Not abandoned.** This is the opposite of a dead repo: created 2026-02-05, pushed 2026-10-28 (yesterday), 295 stars, 26 forks, 45 open issues, releases shipping weekly (`amika@v0.24.0`, `amika-hostd@v0.5.0`, `amikad@v0.2.1` all within the last week). The tunnel protocol itself is brand new — commit `639` "Speak amika.tunnel.v2 to a per-host relay" landed 2026-10-28T19:53Z, and `v0.5.0` still dials the legacy `v1` yamux path. **The v2 tunnel codec is one day old — every file in `js/tunnel-protocol` was last touched 2026-10-28 — and has exactly one production user.** That is a real risk to weigh against its quality.

**The strategic read:** the open/closed split is a moat, not an oversight. The control plane, the UI, the relay and the scheduler are all closed; what is open is the client, the in-VM daemon, and the image. The "will be open sourced soon" gateway (`README.md:181-184`) has been pending long enough that the self-hosting doc now scopes it down to single-player with no IAM. Plan as if it never lands.

## Verified facts

| claim | value | source |
|---|---|---|
| Licence | Apache-2.0 | `https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika` (`license.spdx_id`), `LICENSE` in tree |
| Repo created / last push | 2026-02-05 / 2026-10-28 | same API response (`created_at`, `pushed_at`) |
| Stars / forks / open issues | 295 / 26 / 45 | same API response |
| Contributors | 7 total; 719 + 703 commits from two humans | `https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika/contributors?per_page=30` |
| Closed-source components | control plane, UI, relay | `README.md:172-178` |
| Self-hosting status | "There is currently no supported local CLI path." | `docs/self-hosting.md:10` |
| Local Docker mode | removed | `docs/self-hosting.md:6-8` |
| Self-hosted gateway | not released; single-player, no IAM when it is | `README.md:181-184`, `docs/self-hosting.md:19-21` |
| PR policy | "Instead of submitting PRs, we prefer you open issues" | `CONTRIBUTING.md:3` |
| hostd bundle size | 1,154,504 bytes | downloaded `amika-hostd_0.5.0.tar.gz` from GitHub releases |
| hostd tarball | 305,922 B / 1.6 MB unpacked / 29 files | same |
| hostd deps | 9 direct (6 external) | `js/amika-hostd/package.json` |
| CLI binary | 3,830,828–4,317,672 B compressed | `https://forge.web.pkgforge.dev/github/repos/gofixpoint/amika/releases/tags/amika%40v0.24.0` |
| Go deps | 9 direct | `go/go.mod` |
| Ports | 3020 / 23020 / 60999 | `config.example.toml`; `docs/runtime.md`; `go/internal/amikad/command.go:15` |
| Tunnel stream cap | 256 concurrent | `js/tunnel-protocol/src/index.ts:76` |
| Tunnel window | 256 KiB initial, 64 KiB DATA | `js/tunnel-protocol/src/index.ts:57-59` |
| Service token max TTL | 86,400 s (24 h) | `js/service-auth/src/credentials/service-tokens.ts:46` |
| OpenAPI document | 364,127 B, OpenAPI 3.1.0, 85 paths, 91 schemas, **no licence field** | `https://app.amika.dev/api/openapi.json` (fetched) |
| Relay implementation | Cloudflare Durable Object, in closed `amika-mono` | `docs/tunnel.md:10-16` |
| smolvm licence | Apache-2.0, 6,868 stars, pushed 2026-10-29 | `https://forge.web.pkgforge.dev/github/repos/smol-machines/smolvm` |
| smolmachines npm licence | Apache-2.0 | `package.json` inside the shipped release tarball |
| smolvm scheduling position | "a machine API, not an orchestrator"; "not... Kubernetes-native scheduling semantics" | `https://smolmachines.com/llms.txt` |
| KVM requirement | "Linux x86_64 or arm64 with glibc 2.34+ and KVM, or macOS on Apple silicon" | `js/amika-hostd/README.md:19` |
| Rigs do not restart | "The next `up` brings the daemon back, but not the rigs" | `js/amika-hostd/README.md:97-98` |
| Test volume | 915 Go test funcs / 125 files; 99 TS test files | `grep -c '^func Test'`; `git ls-files '*.test.ts'` |

## Rejected / not for this

- **`amika-hostd` as the compute layer.** Rejected. No scheduler, KVM-only, one microVM per rig, no restart recovery, and the supported entry point (`up`) requires a control plane you cannot run. Its standalone mode (`serve`) is a debug path with a prose-only contract.
- **The Go CLI.** Rejected. It is a thin HTTP client for `app.amika.dev` with `DefaultAPIURL = "https://app.amika.dev"` (`go/internal/config/config.go:29`); 28k LOC to talk to a service you are not using.
- **`go/pkg/amika`.** Rejected, and flagged as a trap: it advertises itself as "the public programmatic API" but `service.go:157` creates local Docker containers — the removed `--local` path — and its only consumer (`go/internal/app`) has no importers.
- **The five commercial sandbox adapters** (Daytona, E2B, Vercel, Freestyle). Rejected. They are well-built, but they point at vendor clouds, which is the thing this study is replacing. Useful only as a worked example of a provider-abstraction contract (`js/sandbox/src/providers/provider.ts`).
- **`amikad`'s no-relay WebSocket SSH bridge** (`go/internal/amikad/norelay`, 780 LOC). Interesting — an authenticated WS→loopback-sshd bridge with a rotating on-disk bearer token re-read on every upgrade (`norelay/token.go:1-20`) — but it solves SSH-over-relay, which CF Tunnel already gives you.
- **The OpenAPI document as a contract to implement.** Rejected on licensing grounds: unlicensed, outside the repo, describing a closed service.
- **`docs/architecture/overview.md` as documentation.** Rejected as stale — it describes the deleted Docker architecture.

## Open questions

1. **Does `amika-hostd serve` in `listen` mode survive as an interface you could target?** It works standalone today (`cli.ts:288-297` needs only `secretKey`), but it is undocumented as a product surface and the team has already deleted one local mode. What is the actual stability commitment?
2. **Will `amika-gateway` ship, and under what licence?** `README.md:181` says "soon." Until it does, the tunnel's server half does not exist outside Amika's own infrastructure. If it ships Apache-2.0, the calculus for `tunnel-protocol` changes from "vendor a codec" to "adopt a tunnel."
3. **Is `amika.tunnel.v2` stable enough to build on?** It is one day old, `v0.5.0` still speaks v1, and `AGENTS.md` says any wire change bumps the subprotocol. Fine for a reference, risky as a dependency.
4. **What is the real throughput ceiling of the 256 KiB window with no window scaling?** A single stream is capped at one 256 KiB window in flight, and the relay grants credit only after the consumer takes the bytes. For a CI workload pulling multi-GB artifacts this is a latency product worth measuring before committing — I did not benchmark it.
5. **Would the maintainers accept an external relay implementation?** The codec is Apache-2.0 so you may write one, but `CONTRIBUTING.md:3` says they would rather you filed an issue than sent a patch. Worth asking on their Discord before investing.
6. **Does the `smolmachines` npm package's missing LICENSE in the release tarball matter?** The tarball ships `README.md`, `package.json` and `dist/` but no `LICENSE`, despite `package.json` `files` listing it. Apache-2.0 §4(a) wants a copy of the licence with redistribution. Minor, but if you redistribute the hostd bundle you should add it yourself.
