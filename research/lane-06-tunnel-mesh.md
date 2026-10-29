# Lane 06 — Connectivity: cloudflared, Cloudflare Mesh, Zero Trust Access, and the alternatives

Research date: **2026-10-29**. Sources are `developers.cloudflare.com`, project repos via the GitHub API, and vendor docs, all fetched on that date. Cloudflare ships this area weekly; the beta labels below are as of this date.

## Verdict

The connectivity problem has one clean answer and it is not the one the architecture diagram suggests. A Worker cannot dial a private IP at all — `connect()` from `cloudflare:sockets` refuses `localhost`, Cloudflare ranges and private network ranges outright — so **Workers VPC bindings are the only supported way for the Workers-hosted SPA to reach a machine**, and they work: bind a `vpc_networks` entry to `cf1:network` (Mesh) or to a `tunnel_id` and call `env.BINDING.fetch("http://10.0.1.50:8080/…")`. The relay therefore sits *in the Worker at the edge*, not on a VM. The browser never touches the private network; it talks same-origin to the Worker, which means no CORS, no WARP client, no Chrome Local Network Access prompt, and no mixed-content problem — all three of which bite hard on the "browser joins the mesh" designs. The single most important caveat: **Workers VPC is still beta (public beta for VPC Networks since 2026-04-14), free only while in beta, and it requires the tunnel to speak QUIC with outbound UDP 7844 open** — an `http2` tunnel, which is otherwise perfectly valid for Zero Trust, silently breaks DNS resolution for Workers VPC. Secondary caveats: `connect()` over VPC is plaintext TCP only, Mesh is IP-routing-only from Workers (no hostname routes), and if you decide to give every machine its own tunnel rather than sharing one, tunnels past the 1,000 free ones cost $4.50/month each.

## Findings

### cloudflared: what the tunnel actually is

A tunnel is a persistent UUID object; `cloudflared` (the connector) opens outbound connections to Cloudflare and stays connected. Per the availability doc: *"When you run a tunnel, `cloudflared` establishes four outbound-only connections between the origin server and the Cloudflare network. These four connections are made to four different servers spread across at least two distinct data centers."* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/)

Replicas add four more connections each and are pure failover, not load balancing: *"Replicas do not support traffic steering (such as round-robin or hash-based routing). When a request arrives at Cloudflare, it is forwarded to the geographically closest replica."* (VERIFIED, same page). Cap is **25 active replicas per tunnel** (VERIFIED, https://developers.cloudflare.com/cloudflare-one/account-limits/).

Transport: `--protocol` defaults to `auto`, which *"will automatically configure the `quic` protocol. If `cloudflared` is unable to establish UDP connections, it will fallback to using the `http2` protocol."* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/). QUIC connections are post-quantum by default with fallback; *"Post-quantum key agreements are not supported when using `http2` protocol."* (same page).

Capacity is port-bound, not CPU-bound: Cloudflare recommends *"Allocate 50,000 ports to the `cloudflared` process on each host"* and 4 GB RAM / 4 cores per host, which *"is usually sufficient to handle traffic from 8,000 Cloudflare One Client users (4,000 per host)"* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/system-requirements/). The doc's own `systemctl status` sample shows `Memory: 16.3M` for an idle connector — the connector is cheap; the port and fd limits are what you size for (`ulimit -n` ≥ 70,000 recommended).

Published applications (public hostnames) per tunnel are generous: *"A single remotely-managed tunnel supports roughly 5,000–10,000 published applications. The limit is based on the size of the tunnel configuration, which can be up to 1 MB."* (VERIFIED, https://developers.cloudflare.com/tunnel/concepts/routing/). So one tunnel can front thousands of per-machine hostnames; you do **not** need a tunnel per machine for the dashboard path.

Hard limits (VERIFIED, https://developers.cloudflare.com/cloudflare-one/account-limits/): 1,000 tunnels/account, 50,000 routes/account (CIDR + hostname, shared with Mesh), 1,000 virtual networks/account, 25 replicas/tunnel. Beyond 1,000 tunnels: *"Tunnels for Platforms costs $4.50 per additional tunnel per month. The first 1,000 tunnels in every account remain included at no cost."* (VERIFIED, https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/)

Two protocol facts that matter for a build system: WebSockets are fully supported (VERIFIED, https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/), but **gRPC is not supported over public hostnames** — *"Cloudflare Tunnel supports gRPC traffic via private subnet routing. Public hostname deployments are not currently supported."* (VERIFIED, same FAQ, and https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/). Origin servers also never see visitor IPs — *"When using Cloudflare Tunnel, all requests to the origin are made internally between `cloudflared` and the origin."* (VERIFIED, same FAQ).

### The hard boundary — what a Worker can reach

This is the load-bearing fact for the whole study. Plain Workers TCP sockets refuse private destinations. From the TCP sockets troubleshooting section: *"Your socket is connecting to an address that was disallowed. Examples of a disallowed address include Cloudflare IPs, `localhost`, and private network IPs."* (VERIFIED, https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/). Also: *"Outbound TCP sockets to Cloudflare IP ranges are blocked."* and port 25 is blocked.

So there is no such thing as "the Worker joins the mesh". A Worker is not a Cloudflare One Client, cannot run WARP, and cannot be a Mesh node. Every private-network call from a Worker must go through a VPC binding. Anything claiming otherwise is wrong.

### Workers VPC — the only supported Worker→private path

Two binding shapes (VERIFIED, https://developers.cloudflare.com/workers-vpc/):

- **VPC Service** — pre-registered `host:port`. The binding's config always wins: *"The **host** provided in `fetch()` does not control routing. It only populates the `Host` header and, when using `https`, the Server Name Indication (SNI) value"* and *"The **port** provided in `fetch()` is ignored"*. 1,000 services/account.
- **VPC Network** — bind a whole tunnel by `tunnel_id`, or the whole account with `network_id: "cf1:network"`. *"The URL you pass to `fetch()` or the address you pass to `connect()` determines the destination — any hostname or IP address reachable through the bound Cloudflare Tunnel or through Cloudflare Mesh."*

`fetch()` does HTTP/HTTPS (absolute URLs only — *"Relative paths are not supported"*). `connect()` does raw TCP and is restricted: *"`connect()` over VPC Networks currently supports plaintext TCP only."* (VERIFIED, https://developers.cloudflare.com/workers-vpc/api/).

Availability and cost: *"Workers VPC is currently in beta. Features and APIs may change before general availability. While in beta, Workers VPC is available for free to all Workers plans."* and the product page says *"Available on Free and Paid plans"* (VERIFIED, https://developers.cloudflare.com/workers-vpc/ and .../platform/limits/). This is a beta dependency in the critical path of the product.

Requirements and traps (VERIFIED, https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ and .../reference/troubleshooting/):

- `cloudflared` **2025.7.0 or later**; older versions produce `ProxyError: dns_error`.
- *"Workers VPC also requires Cloudflare Tunnel to connect using the QUIC transport protocol using `auto` or `quic`. Ensure outbound UDP traffic on port 7844 is allowed through your firewall for QUIC connections."* An `http2` tunnel works fine for Access and **fails** for Workers VPC. Any corporate firewall that only permits TCP/443 breaks this.
- *"Requests not staying within VPC"* — the Worker must use the internal hostname/IP, not a public hostname, or the request egresses the VPC.
- Error taxonomy is documented (`connection_refused`, `destination_unavailable`, `destination_ip_unroutable`, `destination_ip_prohibited`, `tls_certificate_error`, `rate_limited`, `http_upgrade_failed`, `proxy_loop_detected`). Note `rate_limited`: *"The connection rate limit to this origin has been exceeded."* — no number is published.

Workers-side ceilings that shape the design (VERIFIED, https://developers.cloudflare.com/workers/platform/limits/):

- **6 simultaneous outgoing connections per request** — but only those *still waiting for response headers* count. *"Once response headers arrive for a connection, it no longer counts toward the six-connection limit."* So a 200-machine health sweep queues in sixes rather than failing, and long-lived streams stop counting once headers land.
- *"There is no hard limit on duration for HTTP-triggered Workers. As long as the client remains connected, the Worker can continue processing, making subrequests, and streaming a response body."* — SSE build-log tailing through the Worker relay is viable.
- 10,000 subrequests/request (Paid), 128 MB memory.

WebSocket through VPC is **undocumented**. The troubleshooting table lists `http_upgrade_failed` — *"An HTTP upgrade (for example, WebSocket) failed"* — which implies upgrades are attempted, but there is no support statement. Treat interactive terminal-over-WebSocket through VPC as unproven (see Open questions).

### Cloudflare Mesh (formerly WARP Connector)

Mesh is the L3 overlay: `warp-cli` headless on Linux, or the `cloudflare/mesh` container, gets a Mesh IP from `100.96.0.0/12` (CGNAT) and can reach any other participant over TCP, UDP or ICMP, bidirectionally (VERIFIED, https://developers.cloudflare.com/mesh/concepts/). It preserves long-lived TCP end-to-end, which is what you want for database replication and long RDP sessions.

Constraints (all VERIFIED, https://developers.cloudflare.com/mesh/platform/, .../concepts/, .../features/high-availability/, https://developers.cloudflare.com/cloudflare-one/networks/virtual-networks/):

- **Beta, but available on the Free plan**: *"Cloudflare Mesh is available in beta to Cloudflare One accounts, including accounts on the Free plan."*
- **50 Mesh nodes per account.** For a CI fleet this is the binding constraint if you put a Mesh node on every machine — you would need Cloudflare WAN, or subnet routes from a few gateway nodes, instead.
- MASQUE required. With a WireGuard device profile, *"Hostname routes, IPv6 CIDR routes, and high availability do not work."*
- **Virtual networks are not supported by Mesh** — the support matrix says *"Cloudflare Mesh | Not currently supported | —"*. So overlapping-IP staging/prod isolation is a Tunnel-only feature.
- HA is active-passive replicas of a node, and *"If a node is only used for direct Mesh IP connectivity (no routes), HA has limited benefit because the node's Mesh IP is tied to the individual replica."*
- From a Worker, *"Cloudflare Mesh currently supports IP-based routing only."* (VERIFIED, https://developers.cloudflare.com/workers-vpc/examples/connect-to-cloudflare-mesh/) — hostname routes announced into Mesh are not resolvable through `cf1:network`.

### Zero Trust Access as the private-network front door

Access is the identity-aware proxy in front of a public hostname; it is the only way to put a human login in front of a tunnel-published service. Relevant limits (VERIFIED, https://developers.cloudflare.com/cloudflare-one/account-limits/): 500 applications, 50 service tokens, 50 identity providers, 1,000 rules per application, 5,000 infrastructure targets, 1,000 IPs per rule.

Service tokens are the machine-to-machine path and, critically, are free of seat cost: *"you can use Access service tokens to allow access to applications without consuming seats"* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/). They are presented as two headers — `CF-Access-Client-Id` and `CF-Access-Client-Secret` (VERIFIED, https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/). A Worker can therefore call an Access-protected hostname with a service token if it must go that way — but with VPC bindings it does not need to, and VPC bindings bypass Access entirely (see below).

The SPA-relevant subtlety is cookie scoping: *"Access can preemptively set the cookie for every domain through a series of redirects when the user first authenticates. This allows single-page applications (SPAs) to retrieve data from other subdomains before the user visits each subdomain. Wildcarded subdomains (for example, `*.example.com`) cannot receive preemptive cookies because Access does not know which concrete subdomain to redirect to."* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/). A per-machine scheme like `m-8f2a.machines.example.com` is a wildcard from Access's point of view and loses pre-emptive cookies; you would either enumerate every machine as an explicit domain in a multi-domain application (500-application / 50-domains-per-application ceilings apply) or accept a redirect round-trip per machine.

### What the Workers-hosted SPA can and cannot reach

Three paths exist; only one is robust.

**Path A — browser → Worker → VPC binding → machine. This is the recommended one.** The SPA is served from the Worker's own origin, so every API call is same-origin: no CORS preflight, no third-party cookies, no client software, no Local Network Access prompt, no mixed content. The Worker is the relay and it enforces authorisation in code (the VPC binding is the credential; Access policies on a hostname are *not* in this path). Streaming works because Workers have no hard duration cap while the client is connected. The costs are: 128 MB memory per isolate (never buffer a log or a tarball), 6 header-waiting connections, and the beta status of Workers VPC.

**Path B — browser → public hostname behind Access → tunnel → machine.** Works for plain HTTP, gives you real SSO and audit logs, needs no WARP. Costs: CORS must be handled by each machine's service (most CI daemons ship no CORS headers), the Access cookie dance above, a public hostname per machine, and a licensing landmine — *"On Free, Pro, and Business plans, the service-specific terms require you to use a specific paid service to serve video and other large files"* for public hostname routes (VERIFIED, https://developers.cloudflare.com/tunnel/concepts/routing/). Serving build artifacts through a public hostname on a Free/Pro/Business zone is a terms violation; private network routes are exempt, public hostnames are not.

**Path C — browser with WARP → Mesh IP.** This is the path people assume works and it is the worst one. Four independent things must all hold:

1. The device must have the Cloudflare One Client enrolled and running. Not guaranteed on a contractor's laptop, impossible on a managed device you do not control.
2. Chrome 142 gates all requests from a public origin to a local-network destination behind a permission prompt: *"The Local Network Access permission prompt is launching in Chrome 142."* (VERIFIED, https://developer.chrome.com/blog/local-network-access). Mesh IPs are in `100.64.0.0/10`, and the LNA spec explicitly classifies that block as local: the table reads ``100.64.0.0/10 | Carrier-Grade NAT | [[RFC6598]] | local`` (VERIFIED, https://github.com/WICG/local-network-access — `index.bs`, "Non-public IP address blocks"). So every Mesh-IP fetch from the dashboard prompts the user.
3. Mixed content: an HTTPS dashboard fetching `http://100.96.0.5:8080` is normally blocked. LNA exempts it only when Chrome can tell in advance — *"The request hostname is a private IP literal (e.g., `192.168.0.1`)"*, a `.local` domain, or `fetch(..., { targetAddressSpace: "local" })`. A hostname that merely *resolves* to a Mesh IP is **not** exempt.
4. CORS still applies. The machine's HTTP API must return `Access-Control-Allow-Origin` for the dashboard origin and answer preflights. Nothing in the mesh fixes that.

Add the split-tunnel gotcha: *"By default, WARP excludes traffic bound for RFC 1918 space … you must configure Split Tunnels so that the IP/CIDR of your private network routes through the Cloudflare One Client"* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/). A machine's LAN address will not route through WARP until you change the device profile.

**Interactive terminals.** There is no path from the SPA to a shell through Workers VPC. Cloudflare's own answer is the browser-rendered terminal, and it is constrained: *"Browser rendering is only supported for self-hosted public applications, not private IPs or hostnames"*, *"You can only render a browser-rendered terminal on domains and subdomains, not on specific paths"*, *"Bypass and Service Auth are not supported for browser-rendered applications"*, and *"For SSH and VNC, user email prefixes must match their username on the server"* (VERIFIED, https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/browser-rendering/). So: one public SSH hostname per machine, an `Allow` policy, unix usernames matching email prefixes, and the operator authenticates as themselves. That is workable but it is a per-machine hostname and a naming constraint, not something the Worker can broker.

### Where the relay has to sit

- **Cloudflare-native (Tunnel and/or Mesh): the relay is the Worker.** No extra host. Browser → Worker (public, your origin) → VPC binding → `cloudflared`/Mesh node → machine. This is the whole point of Workers VPC and it is why the "orchestration layer is not Cloudflare" constraint survives contact with reality: only the *ingress* hop is Cloudflare.
- **Non-Cloudflare overlay (Tailscale, Headscale, NetBird, Nebula, WireGuard): you must add an egress relay, and it is a real VM.** Cloudflare's edge cannot route into a foreign overlay — a Worker cannot dial `100.x` (Tailscale) or `100.96.x` (Mesh) without a VPC binding, and a VPC binding only reaches things Cloudflare already has a tunnel or Mesh node on. The relay has to be a host that is simultaneously (a) a peer in the overlay and (b) reachable from Cloudflare, i.e. running `cloudflared` or a Mesh node. Shape: one small relay VM per overlay, joined to both networks, with a `vpc_networks` binding to its `tunnel_id`, and the relay doing L4/L7 forwarding into the overlay. You have now reintroduced exactly the box you were trying to avoid, plus a single point of failure, plus a second overlay to operate.
- **Browser-only, no client software: the relay must be a public hostname.** Path B or the browser-rendered terminal. There is no third option.

### The non-Cloudflare meshes, and why they lose here

All of them are fine products and all of them fail the same test: **nothing at Cloudflare's edge can dial into them**, so the Workers-hosted SPA needs either a client on the user's device or a relay you operate. Tailscale's control plane is proprietary SaaS (the clients and `tailscaled` are open); Headscale replaces it with a self-hosted control server you now have to run; NetBird self-hosts but its `management/`, `signal/` and `relay/` directories are AGPL-3.0; Nebula needs PKI certificates and at least one Lighthouse with public reachability; plain WireGuard has no coordination or NAT traversal at all and needs a hub with a public IP.

Tailscale Funnel is the only one with built-in public ingress, and it is not a substitute: *"Funnel can only listen on ports `443`, `8443`, and `10000`"*, *"Funnel can only use DNS names in your tailnet's domain (`tailnet-name.ts.net`)"*, *"Traffic sent over a Funnel is subject to non-configurable bandwidth limits"*, and it is still beta (VERIFIED, https://tailscale.com/kb/1223/funnel). Non-configurable bandwidth limits on a CI artifact path is disqualifying.

### The operational cost of one connector per machine

If the design puts `cloudflared` or a Mesh node on every machine — which is the natural way to make `cf1:network` reach everything — the account ceilings bite: **50 Mesh nodes** or **1,000 tunnels** free, then **$4.50/tunnel/month**. A 5,000-machine fleet on per-machine tunnels is 4,000 × $4.50 = **$18,000/month** just for tunnels, before any Workers or R2 cost. The correct shape is a small number of gateway nodes advertising CIDR routes, or one shared tunnel with many published applications (5,000–10,000 per tunnel), not a connector per machine.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| cloudflared (Cloudflare Tunnel) | https://github.com/cloudflare/cloudflared | Apache-2.0 | release `2026.10.5`, 2026-10-27 | Outbound-only L4/L7 ingress to Cloudflare's edge; 4 connections per replica, 25 replicas/tunnel; WS yes, gRPC no (public hostname) | Only reaches Cloudflare, not a foreign overlay; 1,000 tunnels/account then $4.50/mo each; public hostnames on Free/Pro/Business cannot serve large files |
| Cloudflare Mesh (ex-WARP Connector) | https://developers.cloudflare.com/mesh/ | proprietary (client free) | docs updated 2026-09-16 | L3 overlay, `100.96.0.0/12`, TCP/UDP/ICMP, bidirectional, long-lived TCP preserved | Beta; **50 nodes/account**; MASQUE only; no virtual networks; Workers get IP routes only |
| Workers VPC (`vpc_networks` / `vpc_services`) | https://developers.cloudflare.com/workers-vpc/ | proprietary | docs 2026-10-15; VPC Networks public beta 2026-04-14 | The only supported Worker→private path; `fetch()` HTTP and `connect()` TCP; free during beta on all plans | Beta; needs QUIC + outbound UDP 7844; `connect()` plaintext TCP only; Mesh IP-only; WebSocket undocumented; 1,000 VPC Services/account |
| Zero Trust Access | https://developers.cloudflare.com/cloudflare-one/ | proprietary | docs 2026-10-16 | SSO/IdP in front of tunnel hostnames; service tokens; browser-rendered SSH/RDP/VNC | 500 apps, 50 service tokens; wildcard subdomains get no pre-emptive cookies; browser rendering needs a public hostname and forbids Service Auth |
| Tailscale | https://github.com/tailscale/tailscale | BSD-3-Clause | `v1.104.4`, 2026-10-28 | WireGuard mesh, NAT traversal, MagicDNS, ACLs, exit nodes | Control plane is Tailscale SaaS; needs a client on every device *and* the operator's device; nothing at Cloudflare can dial it; free Personal = 6 users |
| Headscale | https://github.com/juanfont/headscale | BSD-3-Clause | `v0.29.6`, 2026-10-24 | Self-hosted Tailscale control server, no vendor | Same reachability gap, and you now own the control-plane SPOF |
| NetBird | https://github.com/netbirdio/netbird | BSD-3-Clause, **except** `management/`, `signal/`, `relay/`, `combined/` which are AGPL-3.0 | `v0.82.0-rc.2`, 2026-10-28 | WireGuard mesh + SSO + self-hostable | Same reachability gap; AGPL on exactly the server components you would self-host |
| Nebula | https://github.com/slackhq/nebula | MIT | `v1.11.2`, 2026-09-22 | L3 overlay, PKI-based identity, groups firewall | Needs ≥1 Lighthouse with public reachability; UDP-centric; no HTTP ingress; nothing at Cloudflare can dial it |
| WireGuard | https://www.wireguard.com/ | GPL-2.0 (Linux kernel module) — BELIEVED | kernel mainline | Fast, simple L3 tunnel, kernel data path | No coordination, no NAT traversal, manual key distribution; hub needs a public IP; nothing at Cloudflare can dial it |
| frp | https://github.com/fatedier/frp | Apache-2.0 | `v0.71.1`, 2026-10-14 | Reverse-proxy relay, TCP/HTTP/HTTPS | Needs a public server with open ports — i.e. the relay you were trying to avoid |
| Pangolin | https://github.com/fosrl/pangolin | AGPL-3.0 with some files under a Fossorial Commercial License | `1.25.3`, 2026-10-23 | Closest self-hosted analogue to Tunnel + Access: WireGuard mesh plus zero-trust reverse proxy | Mixed licensing (commercial-only files); needs a public VPS; zero Cloudflare-edge integration |
| Tailscale Funnel | https://tailscale.com/kb/1223/funnel | proprietary service | docs validated 2026-01-20 | Public HTTPS ingress to one tailnet node, no client needed by the visitor | Beta; ports 443/8443/10000 only; `*.ts.net` names only; *"non-configurable bandwidth limits"* |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| Connections per cloudflared replica | 4, to 4 servers, ≥2 data centers | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/ | "`cloudflared` establishes four outbound-only connections between the origin server and the Cloudflare network. These four connections are made to four different servers spread across at least two distinct data centers." |
| Replica traffic steering | none | same | "Replicas do not support traffic steering (such as round-robin or hash-based routing)." |
| Active replicas per tunnel | 25 | https://developers.cloudflare.com/cloudflare-one/account-limits/ | "Active `cloudflared` replicas per tunnel \| 25" |
| Tunnels per account | 1,000 | same | "`cloudflared` tunnels per account \| 1,000" |
| Tunnels for Platforms price | $4.50 per additional tunnel/month after 1,000 | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ | "Tunnels for Platforms costs $4.50 per additional tunnel per month. The first 1,000 tunnels in every account remain included at no cost." |
| Routes per account | 50,000 (CIDR + hostname, shared with Mesh) | https://developers.cloudflare.com/cloudflare-one/account-limits/ | "Routes (CIDR routes + Hostname routes) per account \| 50,000 (shared with Cloudflare Mesh)" |
| Virtual networks per account | 1,000 | same | "Virtual networks per account \| 1,000" |
| Mesh nodes per account | 50 | same | "Mesh nodes per account \| 50" |
| Published applications per tunnel | ~5,000–10,000, capped by 1 MB config | https://developers.cloudflare.com/tunnel/concepts/routing/ | "A single remotely-managed tunnel supports roughly 5,000–10,000 published applications. The limit is based on the size of the tunnel configuration, which can be up to 1 MB." |
| Workers cannot dial private IPs | blocked | https://developers.cloudflare.com/workers/runtime-apis/tcp-sockets/ | "Examples of a disallowed address include Cloudflare IPs, `localhost`, and private network IPs." |
| Workers VPC status | beta, free on all plans | https://developers.cloudflare.com/workers-vpc/ | "Workers VPC is currently in beta. Features and APIs may change before general availability. While in beta, Workers VPC is available for free to all Workers plans." |
| VPC Services per account | 1,000 | https://developers.cloudflare.com/workers-vpc/platform/limits/ | "VPC Services per account \| 1000" |
| Workers VPC transport requirement | QUIC, outbound UDP 7844 | https://developers.cloudflare.com/workers-vpc/configuration/tunnel/ | "Ensure outbound UDP traffic on port 7844 is allowed through your firewall for QUIC connections." |
| Minimum cloudflared for Workers VPC | 2025.7.0 | same | "Ensure you are running `cloudflared` version 2025.7.0 or later (latest version recommended)" |
| Mesh via VPC: addressing | IP only | https://developers.cloudflare.com/workers-vpc/examples/connect-to-cloudflare-mesh/ | "Cloudflare Mesh currently supports IP-based routing only." |
| connect() over VPC | plaintext TCP only | https://developers.cloudflare.com/workers-vpc/api/ | "`connect()` over VPC Networks currently supports plaintext TCP only." |
| Worker simultaneous outbound connections | 6, header-waiting only | https://developers.cloudflare.com/workers/platform/limits/ | "Each Worker invocation can have up to six connections simultaneously waiting for response headers." |
| Worker duration for streaming | no hard limit while client connected | same | "There is no hard limit on duration for HTTP-triggered Workers. As long as the client remains connected, the Worker can continue processing, making subrequests, and streaming a response body." |
| Mesh IP range | 100.96.0.0/12 | https://developers.cloudflare.com/mesh/concepts/ | "Every participant is assigned a private IP from the `100.96.0.0/12` range." |
| Mesh plan availability | beta, Free plan included | https://developers.cloudflare.com/mesh/platform/ | "Cloudflare Mesh is available in beta to Cloudflare One accounts, including accounts on the Free plan." |
| Mesh virtual networks | unsupported | https://developers.cloudflare.com/cloudflare-one/networks/virtual-networks/ | "Cloudflare Mesh \| Not currently supported \| —" |
| Chrome LNA ship version | Chrome 142 | https://developer.chrome.com/blog/local-network-access | "The Local Network Access permission prompt is launching in Chrome 142." |
| CGNAT is "local" for LNA | 100.64.0.0/10 | https://github.com/WICG/local-network-access (`index.bs`, "Non-public IP address blocks") | "`100.64.0.0/10` \| Carrier-Grade NAT \| `[[RFC6598]]` \| [=IP address space/local=]" |
| Access limits | 500 apps, 50 service tokens, 50 IdPs | https://developers.cloudflare.com/cloudflare-one/account-limits/ | "Applications \| 500" / "Service tokens \| 50" |
| Service tokens don't consume seats | free | https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/ | "you can use Access service tokens to allow access to applications without consuming seats" |
| Wildcard subdomains and Access cookies | no pre-emptive cookie | https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/ | "Wildcarded subdomains (for example, `*.example.com`) cannot receive preemptive cookies" |
| gRPC over public hostname | unsupported | https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/ | "Cloudflare Tunnel supports gRPC traffic via private subnet routing. Public hostname deployments are not currently supported." |
| Browser-rendered SSH scope | public apps only | https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/browser-rendering/ | "Browser rendering is only supported for self-hosted public applications, not private IPs or hostnames." |
| Funnel ports | 443, 8443, 10000 | https://tailscale.com/kb/1223/funnel | "Funnel can only listen on ports `443`, `8443`, and `10000`." |
| cloudflared repo | Apache-2.0, 16,336 stars, pushed 2026-10-29 | https://api.github.com/repos/cloudflare/cloudflared | `"stargazers_count": 16336`, `"spdx_id": "Apache-2.0"` |
| Tailscale free users | 6 | https://tailscale.com/pricing | "The new Personal plan now allows 6 users, an increase from the former plan's 3 users." |
| NetBird licence split | BSD-3 except management/signal/relay/combined = AGPL-3.0 | https://github.com/netbirdio/netbird/blob/main/LICENSE | "This BSD-3-Clause license applies to all parts of the repository except for the directories management/, signal/, relay/ and combined/." |

## Rejected options

| option | why rejected |
|---|---|
| Worker calls a private IP directly with `connect()` | Explicitly blocked: private network IPs are a disallowed address. There is no workaround short of a VPC binding. |
| Browser SPA talks to Mesh IPs via WARP as the primary path | Four independent failure modes: no client on many devices, Chrome 142 LNA prompt on every request (100.64/10 is "local"), mixed content unless the host is a bare private IP literal, and CORS on the machine's API. Fine as an operator escape hatch, useless as the product path. |
| One `cloudflared` tunnel per machine | 1,000 free then $4.50/month each; a 5,000-machine fleet is ~$18k/month in tunnels alone. Use gateway nodes with CIDR routes, or one tunnel with thousands of published applications. |
| One Mesh node per machine | 50 Mesh nodes per account. Hard stop. |
| Browser-rendered SSH as the dashboard's terminal for the whole fleet | Requires a public hostname per machine (not a private IP), forbids Service Auth/Bypass policies, and forces unix usernames to match email prefixes. Workable for humans, not for a product feature that must work for every machine out of the box. |
| gRPC between the dashboard and machines over a public hostname | "Public hostname deployments are not currently supported." gRPC needs private subnet routing plus the Cloudflare One Client on the client. |
| Serving build artifacts over a tunnel public hostname on a Free/Pro/Business zone | Service-specific terms require a paid service for video and other large files. Private network routes are exempt; public hostnames are not. |
| Tailscale Funnel as the public ingress for the dashboard's machine API | Beta, three ports, `*.ts.net` only, and "non-configurable bandwidth limits". |
| Plain WireGuard hub-and-spoke as the only transport | No coordination, no NAT traversal, manual keys, and a hub that needs a public IP. You have rebuilt a VPN concentrator and still cannot reach it from a Worker. |
| Headscale / NetBird / Nebula as the primary path | All require a relay VM that is both in the overlay and reachable from Cloudflare, plus a second control plane to operate. They buy you nothing over Tunnel + Mesh for this architecture and add an SPOF. Keep them only as an optional egress option for customers who already run one. |
| Relying on Access policies to authorise Workers VPC traffic | Access is not in the VPC path — the binding is the credential. Authorisation must be enforced in the Worker. (BELIEVED: no doc states Access is evaluated for VPC bindings.) |

## Open questions

- **Zero Trust plan pricing and the free-tier user cap.** `cloudflare.com/plans/zero-trust-services/` renders its pricing client-side; no number could be extracted. Secondary sources consistently say 50 free users then $7/seat, but that is BELIEVED, not verified. Settle it by opening the pricing page in a browser or reading the dashboard's Billing → Cloudflare One plan page.
- **Does Workers VPC `fetch()` support a WebSocket upgrade end to end?** The `http_upgrade_failed` error code implies upgrades are attempted, but there is no support statement anywhere in the VPC docs. Settle it by putting a WS echo server behind a tunnel with a `cf1:network` binding and attempting an upgrade from a Worker.
- **What is the `rate_limited` threshold per origin?** Documented as an error, never as a number. Settle it by load-testing or a support ticket.
- **Is Access evaluated on Workers VPC traffic?** I believe not — the binding is the authorisation — but no page says so explicitly. Settle it by putting an Access application on a hostname and fetching it through a VPC Network binding without any Access credentials.
- **Can a Worker `fetch()` a tunnel-published hostname on its own zone?** Same-zone Worker-to-Worker fetches fail without service bindings (VERIFIED, https://developers.cloudflare.com/workers/platform/limits/), but a tunnel hostname is not a Worker route. This is BELIEVED to work and is untested; it matters only for Path B, and Path A avoids the question.
- **Tunnel throughput ceiling.** Cloudflare publishes port-count sizing but no bandwidth number, and the "large files" clause is a terms restriction rather than a technical limit. Settle it by measuring a 10 GB artifact pull through a tunnel.
- **Workers VPC GA date and post-beta pricing.** Nothing announced. This is a beta dependency in the product's critical path and should be tracked; a pricing change or a breaking API change would be a design-level event.
- **Mesh node HA replica count.** Active-passive is documented; the maximum number of replicas per node is not.
- **Whether `fetch()` through a VPC Network can reach a Mesh *hostname* route.** Docs say "IP-based routing only" for Mesh from Workers, but also that `cf1:network` reaches "hostname routes announced through Cloudflare Tunnel or Cloudflare Mesh". These two statements conflict; settle it by announcing a hostname route and fetching it by name.
