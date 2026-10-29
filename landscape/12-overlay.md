# headscale + Tailscale — deep review

## Verdict

Yes — put headscale in the stack, but in exactly one slot: **the encrypted overlay under celld's internal listener**, replacing Cloudflare Mesh for machine-to-machine traffic. It is the right answer to the specific problem celld creates: celld's peer path is plain HTTP inside an upgraded stream (`crates/celld/main/peer_tunnel.rs:1-4`, "an upgraded stream per peer, plain HTTP inside"), and celld's own README tells you to solve it with "an encrypted overlay such as WireGuard or Tailscale" (`README.md:231-234`). headscale + `tailscaled` does that correctly, including over DERP relays, because DERP forwards WireGuard ciphertext it cannot decrypt. It also removes the 50-node Mesh ceiling outright — headscale has no hardcoded node cap at all, and the project's own guidance is "100s of devices" with performance explicitly not a design goal (`docs/about/faq.md:59-106`). The two things it does **not** do: (1) a Workers-hosted dashboard still cannot be a tailnet node — a Worker has no TUN device, no UDP, only outbound TCP `connect()` — so the dashboard leg stays on Cloudflare Tunnel with a gateway host bridging the two overlays; and (2) it is a BSD-3, effectively single-maintainer Go project that ships 0.30 with a hard minimum client version and an out-of-the-box dependency on Tailscale Inc's DERP fleet. Take it as an overlay, not as a platform, and pin the version.

## What it actually is

A **coordination server**, not a VPN. headscale does not carry a single byte of your payload traffic. It exchanges WireGuard public keys, assigns `100.64.0.0/10` addresses, distributes a "netmap" (peer list + packet filters + DERP map) to each node over a Noise-encrypted control channel, and then gets out of the way. The data plane is `tailscaled` on each machine, doing WireGuard, STUN, NAT hole-punching and DERP fallback. That split is the whole design, and it is why the failure modes are mild: kill headscale and existing tunnels keep passing packets on cached keys.

What it is not: a reimplementation of Tailscale's server from scratch. It links `tailscale.com` itself — `go.mod:86` pins `tailscale.com v1.105.0-pre.0.20261022061721-37fc7a7a7260` (a **pre-release** of Tailscale's own module), and the control plane is built on `tailscale.com/control/controlbase` and `tailscale.com/control/controlhttp/controlhttpserver` (`hscontrol/noise.go:22-24`). 196 source files import `tailscale.com`. So headscale tracks Tailscale's client library, not a frozen wire spec. That is the real dependency: not "does headscale work", but "does headscale keep up with whatever Tailscale ships next month".

Scale of the thing: 433 `.go` files, ~79k non-test LOC, 65 direct + 171 indirect module requirements, 738 lines of `go.sum`.

## Architecture (with file paths)

### Control plane

- **Transport.** One HTTP server. `hscontrol/app.go:505-506` registers `/ts2021` for **both GET and POST** — GET is the browser/WASM WebSocket upgrade path, POST is the native client path. The regression that motivated the GET route is guarded by `integration/ts2021_websocket_test.go:1-30` and issue #3357.
- **Handshake.** `NoiseUpgradeHandler` (`hscontrol/noise.go:88-130`) hijacks the connection with `controlhttpserver.AcceptHTTP`, using the server's Noise private key. Everything after that is HTTP/2 **without TLS**, because Noise already encrypts: `srv.Protocols.SetUnencryptedHTTP2(true)` at `hscontrol/noise.go:208-210`. Unauthenticated bodies are capped at 1 MiB (`noiseBodyLimit`, `hscontrol/noise.go:73`) because the Noise handshake accepts any machine key before registration.
- **Routes behind the handshake** (`hscontrol/noise.go:166-202`): `POST /machine/register`, `POST /machine/map`, `GET /machine/ssh/action/{src}/to/{dst}`, `POST /machine/set-dns`. Everything else — `/machine/whoami`, `set-device-attr`, `audit-log`, `id-token`, `feature/query`, `update-health`, `c2n` — is `NotImplementedHandler`. That list is the honest capability boundary: **no device posture, no audit log ingest, no client-initiated feature negotiation**.
- **Netmap streaming.** `hscontrol/poll.go:34-45` — `keepAliveInterval = 50s` with up to 9s of jitter, over a long-lived streamed `MapResponse`. Sessions live in memory in `mapSession` (`hscontrol/poll.go:45-69`); a stopped session gets a 5s write grace before the stream is reset (`stopWriteGrace`, `hscontrol/poll.go:38`).
- **Fan-out.** `hscontrol/mapper/batcher.go` coalesces changes and fans them to sessions; `offlineNodeCleanupThreshold = 15 * time.Minute` (`batcher.go:31-33`) before a disconnected node's in-memory state is dropped.
- **Netmap construction.** `hscontrol/mapper/builder.go:199-233` — `WithPacketFilters()` puts the ACL into `MapResponse.PacketFilters["base"]`, `WithPeers()` emits the full peer list, `WithPeerChanges()` emits deltas.
- **The scaling kernel.** `hscontrol/policy/v2/policy.go:695-698`: *"Compared to [policy.ReduceNodes], which builds the list per node, we end up with doing the full work for every node O(n^2), while this will reduce the list as we see relationships while building the map, making it O(n^2/2) in the end."* Peer-map rebuild is **O(N²)**, with a bitset trick to make each pair cheap (`policy.go:727-731`). Every node also receives every visible peer. That is the ceiling, and it is structural, not a bug.

### DERP and NAT traversal

- **Embedded DERP server**, disabled by default (`config-example.yaml:75-106`). It is Tailscale's own implementation: `tailscale.com/derp` + `tailscale.com/derp/derpserver` (`hscontrol/derp/server/derp_server.go:22-23`). It serves `Upgrade: websocket` **or** `Upgrade: derp` (`derp_server.go:173-190`) and runs a STUN listener on `udp/3478` (`derp_server.go:381-395`, default `stun_listen_addr: "0.0.0.0:3478"`).
- **Default DERP source is Tailscale's.** `config-example.yaml:114-115` ships `urls: [https://controlplane.tailscale.com/derpmap/default]`. Out of the box, your nodes relay through Tailscale Inc's global fleet. `docs/ref/derp.md:30-46` tells you to set `urls: []` to stop that, and warns that doing so leaves a **single point of failure**.
- **NAT traversal is the client's job**, not headscale's. headscale only publishes a DERP map and a STUN endpoint; `tailscaled` does the disco probing and hole-punching.
- **Relay confidentiality.** DERP is a blind forwarder: "it's impossible for a DERP server to decrypt your traffic. A DERP server blindly forwards already-encrypted traffic from one device to another" (Tailscale DERP docs, VERIFIED).
- **Peer relays** are supported (`docs/about/features.md:29`) and preferred over DERP when available, but they listen on a **UDP port** (Tailscale peer-relay docs), so they do not survive a TCP-only path.

### Policy / ACL model

- File-based (`policy.path`) or DB-backed; reloaded by SIGHUP (`docs/ref/policy.md:10-14`). huJSON, same format as Tailscale.
- Both **ACLs** and **Grants** are implemented (`hscontrol/policy/v2/`, 31k lines including tests; `hscontrol/policy/v2/types.go` is 3,409 lines). Autogroups `autogroup:internet`, `autogroup:member`, `autogroup:nonroot`, `autogroup:self` (`types.go:740-746`). Auto-approvers for subnet routers and exit nodes (`hscontrol/policy/policy.go:33-48`). Tailscale SSH (`SSHPolicy` in the `PolicyManager` interface, `hscontrol/policy/pm.go:22`).
- **Not supported**: device postures / `srcPosture`, IP sets, OIDC groups in ACLs, Funnel, network flow logs (`docs/ref/policy.md:78-82`, `docs/about/features.md:42-45`).
- **Enforcement is client-side.** Tailscale's own docs: ACLs are "locally enforced… Rule enforcement happens on each device directly, without further involvement from Tailscale's coordination server." A compromised or hostile node simply ignores its filter. This matters below.

## The seam into this design

There are two seams, and only one of them is clean.

### Seam 1 — celld node↔node peer traffic. This is the win.

celld's peer path is plaintext HTTP inside an h1 upgrade (`crates/celld/main/peer_tunnel.rs:1-4`), authenticated by an HMAC with a 30s clock window and replay cache (`crates/celld/peer_auth.rs:23-30`). celld explicitly delegates confidentiality to the network: *"Put every advertised address on a trusted private network or an encrypted overlay such as WireGuard or Tailscale, and do not publish the internal port"* (`README.md:231-234`).

Run `tailscaled` on every celld node, give each node a tailnet address, set `--advertise` to that `100.64.x.y` address, and the peer tunnel is WireGuard-encrypted end to end. Cell fetch, RPC and fleet-log traffic all inherit it. Nothing in celld changes. This is a **strictly better** fit than Cloudflare Mesh because:

- No 50-node cap. Mesh nodes per account is hard-capped at **50** (Cloudflare account-limits page, VERIFIED).
- No per-node Cloudflare token to provision; a pre-auth key or an OAuth client mints tagged keys, and `tskey-client-…?baseURL=<headscale>` is supported in 0.30 (`CHANGELOG.md:26-31`).
- Peer traffic does not traverse Cloudflare at all, so a Cloudflare outage is no longer a fleet-durability event.

Ordering caveat: celld binds to an explicit address, so `tailscaled` must have its interface up before celld starts. Make it a `Requires=`/`After=` dependency or celld will fail to bind on boot.

MTU caveat: WireGuard costs 60–80 bytes of MTU. celld's peer tunnel is a long-lived HTTP stream with pooled keep-alive; if you leave the tailnet MTU at default and the underlying path is PPPoE or an IPsec tunnel, large segments will black-hole rather than fragment. Set the tailnet MTU explicitly and test a full cell fetch.

### Seam 2 — Workers-hosted dashboard → overlay-addressed machine. This one does **not** work directly.

A Cloudflare Worker cannot join the tailnet. The runtime gives you `connect()` for **outbound TCP** and WebSockets — that is the entire socket surface (`developers.cloudflare.com/workers/runtime-apis/` lists only "TCP sockets" and "WebSockets"). There is no TUN device, no `udp`, no raw sockets, and no way to install a route. `tailscaled` cannot run there.

So the dashboard leg must remain: **Worker → Workers VPC → a host that is simultaneously in the tailnet and reachable over Cloudflare Tunnel.** Concretely, run `cloudflared` on one tailnet node (or a dedicated gateway node) and have it proxy to `100.64.x.y:port`. Two viable shapes:

1. **One gateway, one binding.** A single VPC Service bound to the gateway's host:port; the Worker calls `gateway/node/<id>/…` and the gateway reverse-proxies by tailnet address. One static binding, N machines. This is the shape I would build. The routing table is code you own, not a Cloudflare config file.
2. **One VPC Service per machine.** Avoid. `vpc_services` binds a specific host and port, so this is N static entries, and it re-creates exactly the "every new CI runner means a redeploy" problem the connectivity review already flagged.

Note the consequence honestly: this does not remove Cloudflare from the dashboard path, and it never could — the dashboard is a hard constraint. What it removes is Cloudflare from the **data plane between celld nodes**, which is where the Mesh 50-node cap was actually going to bite. You end up with two overlays stacked (Cloudflare Tunnel for the control leg, WireGuard for the fleet leg), and that is acceptable because the two have different jobs and different failure domains.

## Limits and failure modes

- **No hardcoded node cap.** I grepped for `MaxNodes`/`nodeLimit` across `hscontrol/` and found nothing but a SQL `Limit(1)`. The cap is economic, not enforced.
- **The real cap is O(N²) peer-map rebuild plus a full netmap per node.** `docs/about/faq.md:59-106` is blunt: *"Headscale is not enterprise software"*, *"performance is not part of the consideration"*, and *"In the worst case scenario, the queue of nodes waiting for their map will grow to a point where Headscale never will be able to catch up."* Two scenarios are described — 1000 stable servers (fine) and 80 churning laptops (fine) — and the failure is when **both** hold: *"Headscale will start to struggle when the two scenarios overlap."*
- **That is exactly the CI workload.** Ephemeral runners joining and leaving constantly is scenario 2 at scale against scenario 1's node count. Every join/leave triggers a peer-map rebuild and a netmap fan-out. Budget headroom, use `node.ephemeral.inactivity_timeout` deliberately, and load-test at your real churn rate before committing. I would not run 500 churning CI nodes through one headscale without measuring.
- **Control-plane restart is survivable.** WireGuard keys and the last netmap are cached on each node; established tunnels keep passing packets. New node joins fail, and peer changes are not propagated, until headscale returns. This is genuinely better than a Cloudflare Mesh outage.
- **Single instance, no control-plane HA.** SQLite by default (`config-example.yaml:180-211`) or Postgres. The only "HA" in the docs is *subnet router* HA (`docs/ref/routes.md:338-342`), not a second coordination server. Two headscale replicas against one DB is not a supported topology.
- **Restart state:** map sessions are in-memory (`hscontrol/poll.go:45-69`), so a restart drops every stream; clients reconnect with backoff. Pending registration entries expire in 15 minutes (`hscontrol/state/state.go:47-48`).
- **Minimum client version is a hard floor.** `capver.MinSupportedCapabilityVersion = 116` (`hscontrol/capver/capver_generated.go:93`), enforced before the handshake completes (`hscontrol/noise.go:257-259`). 0.30 requires **Tailscale ≥ v1.84.0** (`CHANGELOG.md:5`). Old images in your fleet will simply stop being able to register.
- **Version coupling.** `go.mod:86` pins a `-pre` build of `tailscale.com`. If you build from source you inherit a pre-release of Tailscale's module. Use release binaries.
- **DERP is a single point of failure once self-hosted.** `docs/ref/derp.md:38-46` says so explicitly. And DERP has *"no speed or throughput optimisations, the main purpose is to assist in node connectivity"* (`docs/ref/derp.md:170-171`). Do not push artifact-sized transfers through a relayed path; if a build's cell fetch lands on DERP you will feel it.
- **The embedded DERP needs a public IP and `udp/3478`.** `docs/setup/requirements.md:1-8` requires "a server with a public IP address". Ports in use: `tcp/80` (ACME HTTP-01, optional), `tcp/443`, `udp/3478` (STUN), `tcp/9090` (metrics, not public).
- **Cloudflare Tunnel cannot carry `udp/3478`.** Tunnel is HTTP/TCP-shaped; Spectrum does UDP and is a separate paid product. If headscale lives entirely behind a tunnel you lose STUN and peer relays, and **every** connection falls back to DERP — the slow path, for all fleet traffic, permanently. Put headscale on a real public IP.
- **`verify_clients` fails open at the DERP layer.** For third-party `derper`, `-verify-client-url-fail-open` *"By default… will allow access if Headscale is unreachable"* (`docs/ref/derp.md:155-158`). Your relay does not hard-fail closed when the control plane dies.
- **ACLs are advisory against a compromised node.** Client-side enforcement (see above). For celld this is fine — the HMAC in `peer_auth.rs` is the actual authentication — but do not sell the ACL as a security boundary against a hostile host.
- **No tailnet lock.** I found no tailnet-lock support anywhere in the docs or source. headscale is the sole root of trust: whoever controls it can inject a node and impersonate a peer. Tailscale's own docs describe tailnet lock as the mitigation for exactly this, and point at headscale as the alternative that trades away "availability guarantees and low maintenance overhead" (Tailscale tailnet-lock docs, VERIFIED). Here, you *are* the trust root — accept that or add an application-layer control (celld's fleet HMAC partly does).
- **Binary and moving parts, server:** `headscale_0.29.6_linux_amd64` is **51,519,648 bytes (49.1 MiB)**. One process, one SQLite file, `config.yaml`, a Noise private key, a DERP private key, an optional policy file, a TLS cert. Three public ports.
- **Binary and moving parts, per node:** the `tailscale_1.104.4_amd64.tgz` is **41,395,334 bytes (39.5 MiB)** and contains `tailscaled` + `tailscale` + unit files. Plus a TUN device and `NET_ADMIN`. In a container that means `--cap-add=NET_ADMIN` and `/dev/net/tun` — a real privilege cost per celld node, worth stating next to the privileged `celld-fence` container the celld review already flagged.

## Licence and governance

- **headscale: BSD-3-Clause.** `LICENSE:1-3`, "Copyright (c) 2020, Juan Font". Confirmed via GitHub API (`license.spdx_id = BSD-3-Clause`). Permissive, no copyleft, no network-service clause. No CLA — `CONTRIBUTING.md` has no contributor agreement, just a contribution policy.
- **Tailscale client: BSD-3-Clause.** `tailscale/tailscale` `LICENSE:1-3`, "Copyright (c) 2020 Tailscale Inc & contributors". The Windows/macOS/iOS **GUI** apps are proprietary; the daemon and CLI you would actually deploy are BSD-3. For Linux CI nodes this is a non-issue.
- **Governance is the risk, not the licence.** `CONTRIBUTING.md:3` — *"Headscale is 'Open Source, acknowledged contribution', this means that any contribution will have to be discussed with the maintainers before being added."* `CONTRIBUTING.md:8` — *"Headscale has a small maintainer team."* And `CONTRIBUTING.md:26` — maintainers *"reserve themselves the right to remove features they redeem as unmaintainable."* This is a curated project, not an open commons.
- **Bus factor is close to one.** Contributor commit counts: kradalby 2,562, juanfont 1,011, then a cliff — nblock 182, restanrm 124, github-actions[bot] 123, everyone else double digits. Over the last ~3 months, of 200 commits sampled, **167 are kradalby** (76 of the first 100, 91 of the second 100). One person is writing the overwhelming majority of this server right now.
- **And that person is employed by Tailscale.** `README.md:88-92`: *"one of the active maintainers for Headscale is employed by Tailscale and he is allowed to spend work hours contributing to the project. Contributions from this maintainer are reviewed by other maintainers."* Not a problem — arguably why the project is good — but it means the maintainer's day job and the project's direction are not fully independent. Plan for the project to be slower and more opinionated than a normal OSS dependency.
- **Release cadence is healthy**: v0.29.2 (2026-07-01) → v0.29.6 (2026-10-24), with 0.30 in development on `main` (`CHANGELOG.md:1-5`). Not abandoned. 45,164 stars, 2,622 forks, last push 2026-10-29.
- **Not a licence trap, but a support trap.** `README.md:54-56`: *"we do not support nor encourage the use of reverse proxies and container to run Headscale."* `docs/about/faq.md:38-48` repeats it. This study is container-native. You will be running headscale in a way upstream has explicitly declined to support. That is a real operational risk with no contractual backstop.

## Verified facts

| claim | value | source |
|---|---|---|
| headscale licence | BSD-3-Clause | `LICENSE:1-3`; GitHub API `license.spdx_id` |
| headscale stars / forks | 45,164 / 2,622 | GitHub API `repos/juanfont/headscale` |
| latest stable release | v0.29.6, 2026-10-24 | GitHub releases API |
| headscale linux/amd64 binary | 51,519,648 B (49.1 MiB) | release asset `headscale_0.29.6_linux_amd64` |
| tailscale client tarball (amd64) | 41,395,334 B (39.5 MiB) | `pkgs.tailscale.com/stable/tailscale_1.104.4_amd64.tgz` |
| tailscale client licence | BSD-3-Clause | `tailscale/tailscale LICENSE:1-3` |
| go module deps | 65 direct, 171 indirect, 738 `go.sum` lines | `go.mod`, `go.sum` |
| source size | 433 `.go` files, ~79k non-test LOC | repo count |
| pinned Tailscale module | `v1.105.0-pre.0.20261022061721-37fc7a7a7260` | `go.mod:86` |
| min client capability version | 116 (`v1.84.0` for 0.30) | `hscontrol/capver/capver_generated.go:93`; `CHANGELOG.md:5` |
| hardcoded node cap | none found | grep `MaxNodes`/`nodeLimit` over `hscontrol/` |
| peer-map rebuild complexity | O(N²), "O(n^2/2)" with pruning | `hscontrol/policy/v2/policy.go:695-698` |
| map keepalive | 50s + ≤9s jitter | `hscontrol/poll.go:34-35,63` |
| offline node state cleanup | 15 min | `hscontrol/mapper/batcher.go:31-33` |
| unauthenticated body limit | 1 MiB | `hscontrol/noise.go:73` |
| public ports | tcp/443, udp/3478 (STUN), tcp/9090 (metrics), tcp/80 (ACME) | `docs/setup/requirements.md:11-27` |
| default DERP map source | `https://controlplane.tailscale.com/derpmap/default` | `config-example.yaml:114-115` |
| embedded DERP disabled by default | `enabled: false` | `config-example.yaml:79` |
| DERP cannot decrypt relayed traffic | "impossible for a DERP server to decrypt your traffic" | https://tailscale.com/docs/reference/derp-servers |
| ACL enforcement location | client-side, "locally enforced" | https://tailscale.com/docs/features/access-control/acls |
| Cloudflare Mesh node cap | 50 nodes per account | https://developers.cloudflare.com/cloudflare-one/account-limits/ |
| Workers socket surface | outbound TCP `connect()` + WebSockets only; no UDP | https://developers.cloudflare.com/workers/runtime-apis/ |
| Workers VPC shape | `vpc_services` (host:port) or `vpc_networks` (whole tunnel/Mesh); beta, free | https://developers.cloudflare.com/workers-vpc/ |
| headscale contributor commits | kradalby 2,562; juanfont 1,011; nblock 182 | GitHub contributors API |
| recent commit concentration | 167 of 200 commits by kradalby (last ~3 mo) | GitHub commits API, sampled |
| maintainer employed by Tailscale | yes, disclosed | `README.md:88-92` |
| container deployment support | explicitly not supported | `README.md:54-56`; `docs/about/faq.md:38-48` |
| celld peer traffic is plain HTTP in a tunnel | "an upgraded stream per peer, plain HTTP inside" | `crates/celld/main/peer_tunnel.rs:1-4` |
| celld delegates encryption to the overlay | "an encrypted overlay such as WireGuard or Tailscale" | `celld README.md:231-234` |

## Rejected / not for this

- **Workers VPC / Cloudflare Mesh as the celld fleet overlay.** Rejected on the 50-node cap alone; the connectivity review's other findings (no stream resumption, static `wrangler.jsonc` config, plaintext-only `connect()`) make it worse. Mesh stays only as the dashboard's leg, if at all.
- **A Worker as a tailnet node.** Rejected. No TUN, no UDP, no route table. The only theoretical path is the `@tailscale/connect` JS/WASM client (`cmd/tsconnect` in the Tailscale repo) speaking DERP over WebSocket from inside a Durable Object — DERP-only forever, stateful, unsupported, and far more moving parts than one gateway host. Not worth it.
- **`tailscale serve` / Funnel as the dashboard's ingress.** Funnel is unimplemented in headscale (`docs/about/features.md:43`, issue #1040), and `serve` is tailnet-only — it does not help a Worker that is not on the tailnet.
- **Tailscale's hosted coordination server.** The whole point is not doing that.
- **Defaulting to Tailscale Inc's DERP fleet.** It works, it is free, and it is the wrong default for this study: you would be trading a Cloudflare dependency for a Tailscale dependency at layer 4. Set `derp.urls: []` and run the embedded DERP on a public IP.
- **WireGuard + static config, as the alternative.** It is the boring option and it is genuinely simpler — a kernel module, no daemon, no control plane, no Go binary, ~zero CPU. But it fails this workload on three counts that are not fixable with a config file: (1) **no NAT traversal** — CI runners behind cloud NAT need a reachable endpoint or a public hub, which means either a static public relay per site or a hub-and-spoke you now operate; (2) **no automated key distribution** — adding an ephemeral runner means editing every peer's config, which is exactly the churn problem; (3) **no identity or ACL** — `AllowedIPs` is routing, not authorization, so any peer with a key can reach any port on any other peer, and celld's internal listener is unauthenticated by design. WireGuard-plus-static is the right answer for a fixed 5-node cluster with public IPs. It is the wrong answer for a fleet of CI runners. If you want the middle ground, WireGuard with a config-management-generated mesh and a public relay is defensible — but you are then building a worse headscale.

## Open questions

1. **What is the actual churn rate?** The O(N²) peer-map rebuild is fine at 200 stable nodes and fatal at 200 nodes joining/leaving per minute. I have no benchmark numbers in-repo — `hscontrol/mapper/batcher_scale_bench_test.go:20-30` defines the tiers (100 → 50,000) but ships no results. Measure at your real rate before committing.
2. **Can `cloudflared` pass the `Upgrade: derp` header?** The embedded DERP accepts both `websocket` and `derp` upgrades (`derp_server.go:173-190`). Cloudflare's edge may normalise non-WebSocket `Upgrade` tokens. If it does not, DERP-behind-tunnel needs clients forced onto the WebSocket path — untested, and I would not ship it without a connectivity test. This is a further argument for a public IP.
3. **Does `udp/3478` survive your network policy?** If not, no STUN, no direct paths, everything on DERP. Test `tailscale netcheck` from a representative runner before rollout.
4. **What is the MTU on the celld peer path?** WireGuard overhead plus a long-lived pooled HTTP stream is the classic black-hole setup. Needs a real cell-fetch test at production MTU.
5. **Does the gateway node become a bottleneck?** Shape 1 puts every dashboard→machine call through one host. That host is now in the control path for the whole fleet. It needs to be the most boring, most monitored machine you own — or you accept N VPC Services and the config sprawl.
6. **What happens at the 0.30 → 0.31 key migration?** `CHANGELOG.md:40-52` lays out a multi-release credential migration (bcrypt dropped in 0.32, legacy key formats dropped in 0.32) with a hard requirement to use every key at least once on 0.30 or 0.31. Automate key rotation now, or you will discover this during an upgrade.
7. **Who maintains this in two years?** 167 of the last 200 commits are one person who works at Tailscale. There is no foundation, no commercial support contract, and container deployment is explicitly unsupported. Have a fork-and-patch plan, and pin to a tag with a tested upgrade path.
