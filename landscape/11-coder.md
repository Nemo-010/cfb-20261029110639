# Coder — deep review

## Verdict

Put it in the stack, but in the *developer-workspace* slot, not the CI slot. Coder is the single best fit in this whole study for the specific ingress constraint — its workspace agent is strictly outbound-only and needs nothing but HTTPS+WebSocket to one hostname, which is exactly what Cloudflare Tunnel gives you, and its embedded DERP relay rides the same listener so a single tunnel hostname carries API, dashboard, relay and shell traffic. What it is *not* is a CI executor: there is no pipeline engine, no step graph, no SCM-triggered build, no artifact store and no test reporting, and a "build" is a Terraform apply with a `reason` enum of `initiator|autostart|autostop|dormancy|dashboard|cli|ssh_connection` (`codersdk/workspacebuilds.go:40-64`) — a lifecycle event, not a job. Worse for a CI-heavy profile, the two features that would make it tolerable at volume — external provisioner daemons and prebuilds (warm pools) — are both Premium-gated. Adopt it as the thing humans and long-running agents sit in; keep the heavy CI elsewhere.

## What it actually is

A self-hosted control plane for cloud development environments and AI coding agents. One Go binary (`coderd`) plus PostgreSQL plus a per-workspace agent process. Workspaces are declared in Terraform; a provisioner daemon runs `terraform apply` to create them. Connectivity is an embedded Tailscale/WireGuard overlay ("tailnet") with DERP relays, not a VPN appliance — Coder does not need inbound ports on the machines it manages, only on the control plane.

It is a *workspace lifecycle manager with a mesh attached*, not a job scheduler. Everything it does well is "make an environment exist, let a human or agent get a shell in it, shut it down when idle."

## Architecture (with file paths)

**Control plane.** `coderd/coderd.go` — single chi router. `/api/v2` route tree starts at line 1453; workspace lifecycle at `r.Route("/workspaces")` (~line 1888) with `GET|POST /{workspace}/builds`; template and template-version routes (~line 1605 onward); `workspaceagents` at line 1822; audit at line 1498.

**The agent is outbound-only.** `agent/agent.go:1008 func (a *agent) run()` — the agent calls `a.client.ConnectRPC215WithRole(ctx, "agent")`, i.e. it *dials the control plane* and multiplexes a dRPC connection. There is no listener waiting for the control plane to arrive. Everything else — logs, metadata, PTY, SSH, port forwarding, DERP map subscription — is a goroutine on that outbound connection (`runCoordinator` at `agent/agent.go:1951`, `runDERPMapSubscriber` at `agent/agent.go:2015`, connection accounting at `agent/agent.go:2083-2134`).

**The mesh.** `tailnet/` — `coordinator.go` (server side), `conn.go` (WireGuard `net.Conn`), `tunnel.go` (`SingleTailnetCoordinateeAuth`, `ClientCoordinateeAuth`), `derp.go`, `derpmap.go`, `resume.go`. The agent embeds a userspace Tailscale node (`agent/agent.go:1719-1748` sets `DERPMap`, `DERPForceWebSockets`, `BlockEndpoints`).

**The relay is on the same port as the API.** `coderd/coderd.go:1232-1243`:
```go
if options.DERPServer != nil {
    derpHandler := derphttp.Handler(api.DERPServer)
    derpHandler, api.derpCloseFunc = tailnet.WithWebsocketSupport(api.DERPServer, derpHandler)
    r.Route("/derp", func(r chi.Router) { r.Get("/", derpHandler.ServeHTTP) ... })
}
```
So `https://<access-url>/derp` is the relay. One hostname, one TLS cert, one tunnel.

**Terraform.** `provisioner/terraform/` — `executor.go` (runs terraform), `provision.go`, `modules.go`, `install.go` (downloads the terraform binary), `safeenv.go`, `parse.go`. `provisionerd/` is the daemon that pulls jobs. The in-process daemon is wired at `cli/server.go:1288` / `newProvisionerDaemon` at `cli/server.go:1664`, falling back to `coderAPI.CreateInMemoryProvisionerDaemon` (`cli/server.go:1777`).

**Shell access.** `agent/agentssh/agentssh.go` — an SSH server *inside* the workspace, reached over the tailnet, not over the network. `cli/ssh.go:1296 runRemoteSSH` is the client side; `codersdk/workspacesdk/agentconn.go:354 SSHClient` and `:377 SSHClientOnPort` build it from an HTTP upgrade.

**Dashboard API surface.** Full REST under `/api/v2`, with an OpenAPI document checked in at `coderd/apidoc/swagger.json` (generated into `coderd/apidoc/docs.go`). Auth is a bearer token in a custom header: `codersdk/client.go:38 SessionTokenHeader = "Coder-Session-Token"`.

**Licence split.** `LICENSE` (AGPL-3.0) covers the repo; `LICENSE.enterprise` is a separate source-available licence covering `enterprise/`. Feature gating is enumerated in `codersdk/deployment.go:175-242` (27 `FeatureName` values) and enforced in `enterprise/coderd/coderd.go` via `RequireFeatureMW`.

## The seam into this design

This is where Coder earns its place, and also where it collides with the study's assumptions.

**Tunnel-friendly, genuinely.** The documented requirement is only: "All clients and agents must be able to establish a connection to the control plane (`CODER_ACCESS_URL`) over HTTP/HTTPS" and "any reverse proxy or ingress between the Coder control plane and clients/agents must support WebSockets" (`docs/admin/networking/index.md`). Direct peer-to-peer is an optimisation, not a requirement — when NAT traversal fails, traffic is relayed through the control plane. That is precisely a Cloudflare Tunnel topology: no inbound ports anywhere but the Worker-side tunnel.

**Three flags you must set behind a tunnel**, all present in the source:
- `--derp-force-websockets` / `CODER_DERP_FORCE_WEBSOCKETS` (`codersdk/deployment.go:2607`) — DERP's native upgrade is `Upgrade: derp`, which Cloudflare will not pass. The flag's own description says it exists because that upgrade "may cause issues with some reverse proxies."
- `--block-direct-connections` / `CODER_BLOCK_DIRECT` (`codersdk/deployment.go:2595`) — forces everything through the relay. Correct behind a tunnel, because STUN/UDP cannot work through it anyway.
- `--derp-server-stun-addresses=disable` — the documented trio is spelled out verbatim in `docs/tutorials/faqs.md:79` ("I'm experiencing networking issues, so want to disable Tailscale, STUN, Direct connections and force use of websocket").

**The dashboard seam has a sharp edge.** You said the dashboard stays on Workers. If that dashboard is a *browser* SPA calling `coderd` cross-origin, it will fail: the standard CORS middleware (`coderd/httpmw/cors.go:42-52`) allows only `GET` and `OPTIONS`, only the headers `Accept, Content-Type, X-LATENCY-CHECK, X-CSRF-TOKEN`, and sets `AllowCredentials: false`. It does **not** allow `Coder-Session-Token` and does not allow `POST`/`PUT`/`PATCH`/`DELETE`. The permissive policy (`cors.go:53-79`, allows `Authorization`, `x-api-key`, all methods) is applied only to `/oauth2/*`, `/api/v2/mcp/*`, `/api/experimental/mcp/*` and `/.well-known/oauth-*` (`cors.go:88-100`). Consequence: the Worker must be a **same-origin reverse proxy** in front of coderd, not a browser-side API client. That is fine — it is what you wanted the Worker for — but it means the dashboard's API calls are Worker-proxied, and the Worker becomes the trust boundary holding the token.

**A duplication you should name.** Coder ships its *own* WireGuard mesh (`tailnet/`). The study already has Cloudflare Mesh / Workers VPC for reaching machines. These are two overlays solving overlapping problems. Coder's tailnet is scoped to workspace agents and their clients only — it is not general machine networking — so it does not replace Mesh. But you will be operating two overlays, and the operator-facing mental model ("which network is this hop on?") gets harder, not easier.

**Machines.** Because the agent is outbound-only, adding a machine to Coder is "run the agent with a token," not "open a port and register a route." Nothing about the Cloudflare Tunnel/VPC layer is on the critical path for workspace reachability. That is a strength here.

## Limits and failure modes

**It cannot be a CI executor.** Concretely absent from the source: no pipeline/job/step model, no matrix, no artifact store, no test-result reporting, no cache primitive, no SCM webhook trigger. A grep for webhooks in `coderd/` finds only notification dispatch (`coderd/notifications/dispatch/webhook.go`) and chat lifecycle hooks — nothing that turns a `git push` into a build. Build reasons are lifecycle-only (`codersdk/workspacebuilds.go:40-64`). The closest thing to "run my CI job" is `POST /api/v2/workspaces/{workspace}/builds` followed by `coder ssh <ws> -- <cmd>` (`cli/ssh.go:1296 runRemoteSSH`, which returns combined output and wraps the SSH exit status as an error). That is a remote shell with a start/stop around it, not a runner. You would be rebuilding GitHub Actions' job semantics on top of a workspace lifecycle API.

**Startup latency is the wrong order of magnitude.** A workspace start is a Terraform apply plus agent boot plus startup scripts. Tens of seconds to minutes, not sub-second. For heavy CI where the job itself is long this is tolerable; for anything short it is fatal. Warm pools would fix it — and warm pools are Premium.

**Premium gates that bite this specific workload:**
- `FeatureWorkspacePrebuilds` — prebuilt/warm workspaces (`codersdk/deployment.go:234`, `AlwaysEnable` map at `:281`).
- `FeatureExternalProvisionerDaemons` — gated by `api.RequireFeatureMW(codersdk.FeatureExternalProvisionerDaemons)` at `enterprise/coderd/coderd.go:594`. **This is the big one.** Without a licence, all Terraform applies run *in-process inside coderd* (`cli/server.go:1288`, `CreateInMemoryProvisionerDaemon` at `:1777`). At CI volume that is a scaling wall and a single point of failure: a slow apply stalls the control plane.
- Also Premium and relevant to a large deployment: `FeatureHighAvailability`, `FeatureMultipleOrganizations`, `FeatureAuditLog`, `FeatureSCIM`, `FeatureWorkspaceProxy`, `FeatureAdvancedTemplateScheduling`.

**Stateful dependency.** PostgreSQL is required — in air-gapped installs the docs state "An external database is required, you must specify a PostgreSQL connection URL" (`docs/install/prepare/airgap.md:15`). Another stateful service to back up and run, alongside whatever you already have.

**Idle shutdown is user-shaped, not job-shaped.** Autostart/autostop are cron-plus-activity (`coderd/autobuild/lifecycle_executor.go`), with `dormancy` as a build reason. There is no "job finished, tear down now" primitive that understands exit status.

**The mesh is a single-writer coordinator per agent.** `tailnet/coordinator.go` holds per-agent state; scaling the control plane means coordinating that state. HA is Premium, so the free path is one coderd.

## Licence and governance

**AGPL-3.0** (`LICENSE`, and GitHub reports `spdx_id: agpl-3.0`). The practical consequence for this design: AGPL §13 obliges you to offer the Corresponding Source to anyone who interacts with a *modified* version over a network. You are exposing coderd through a public-facing tunnel, and your own staff count as users. So: run it unmodified and you are fine; fork `coderd`, patch it, and keep the patch private, and you are in violation. Since the study's whole premise is "self-host, replace SaaS," the temptation to patch is real — treat "no local patches to coderd" as a hard rule, or budget for publishing them.

**`enterprise/` is not open source.** `LICENSE.enterprise` is a source-available licence: it forbids moving/disabling/circumventing the licence-key functionality, and — the clause that matters — "This Enterprise Software may only be used in production, if you (and any entity that you represent) have agreed to, and are in compliance with, the Coder's Terms of Service." That is a ToS-linked production restriction, not an OSS grant. Reading it is fine; production use is conditional on accepting a vendor ToS.

**Licence validation is offline.** Keys are signed JWTs validated locally with no outbound call (`docs/install/prepare/licensing.md`), so this works air-gapped and behind a tunnel with no egress exception. Seats are counted by 90-day-active users.

**Governance risk: single vendor.** Coder Technologies Inc. controls the roadmap, the `enterprise/` boundary, and the licence terms. The open-core line can move — features that are AGPL today can become Premium tomorrow (prebuilds and external provisioners already did). Budget for that: anything you build on a currently-free feature is a feature you may have to pay for or replace.

## Verified facts

| claim | value | source |
|---|---|---|
| Licence is AGPL-3.0 | `spdx_id: agpl-3.0`, "GNU Affero General Public License v3.0" | GitHub REST `/repos/coder/coder`, VERIFIED; `LICENSE` header, VERIFIED |
| `enterprise/` has a separate, ToS-linked source-available licence | "may only be used in production, if you … have agreed to … Coder's Terms of Service"; forbids circumventing licence-key functionality | `LICENSE.enterprise`, VERIFIED |
| Agent connection is outbound-only dRPC to the control plane | `a.client.ConnectRPC215WithRole(a.hardCtx, "agent")` | `agent/agent.go:1008-1020`, VERIFIED |
| Embedded DERP relay is served on the same HTTP listener at `/derp` | `r.Route("/derp", ...)` with `derphttp.Handler` + `tailnet.WithWebsocketSupport` | `coderd/coderd.go:1232-1243`, VERIFIED |
| Clients/agents need only HTTPS+WebSocket to `CODER_ACCESS_URL` | "must be able to establish a connection to the control plane … over HTTP/HTTPS"; ingress "must support WebSockets" | `docs/admin/networking/index.md`, VERIFIED |
| Flag exists to force WebSocket DERP for reverse proxies | `--derp-force-websockets` / `CODER_DERP_FORCE_WEBSOCKETS` | `codersdk/deployment.go:2607`, VERIFIED |
| Flag exists to block all P2P and force relay | `--block-direct-connections` / `CODER_BLOCK_DIRECT` | `codersdk/deployment.go:2595`, VERIFIED |
| Documented "tunnel-unfriendly network" recipe | `CODER_BLOCK_DIRECT=true`, `CODER_DERP_SERVER_STUN_ADDRESSES="disable"`, `CODER_DERP_FORCE_WEBSOCKETS=true` | `docs/tutorials/faqs.md:79`, VERIFIED |
| Standard CORS allows only GET/OPTIONS, no credentials, no session-token header | `AllowedMethods: [OPTIONS, GET]`, `AllowedHeaders: [Accept, Content-Type, X-LATENCY-CHECK, X-CSRF-TOKEN]`, `AllowCredentials: false` | `coderd/httpmw/cors.go:42-52`, VERIFIED |
| Permissive CORS is limited to OAuth2/MCP/well-known paths | `strings.HasPrefix(path, "/oauth2/")` etc. | `coderd/httpmw/cors.go:88-100`, VERIFIED |
| Auth header is `Coder-Session-Token` | `SessionTokenHeader = "Coder-Session-Token"` | `codersdk/client.go:38`, VERIFIED |
| Build reasons are lifecycle-only (no CI trigger) | `initiator, autostart, autostop, dormancy, dashboard, cli, ssh_connection, vscode_connection, jetbrains_connection` | `codersdk/workspacebuilds.go:40-64`, VERIFIED |
| External provisioner daemons are Premium-gated | `api.RequireFeatureMW(codersdk.FeatureExternalProvisionerDaemons)` | `enterprise/coderd/coderd.go:594`, VERIFIED |
| Prebuilds are a gated feature | `FeatureWorkspacePrebuilds` in `AlwaysEnable` map | `codersdk/deployment.go:234,281`, VERIFIED |
| 27 gated feature names total | `FeatureNames` slice | `codersdk/deployment.go:175-242`, VERIFIED |
| Unlicensed path runs the provisioner in-process in coderd | `newProvisionerDaemon` → `CreateInMemoryProvisionerDaemon` | `cli/server.go:1288,1664,1777`, VERIFIED |
| PostgreSQL is required | "An external database is required, you must specify a PostgreSQL connection URL" | `docs/install/prepare/airgap.md:15`, VERIFIED |
| OpenAPI spec is shipped in-repo | `coderd/apidoc/swagger.json`, `coderd/apidoc/docs.go` | repo tree, VERIFIED |
| Remote exec is SSH with exit-status-as-error | `runRemoteSSH` → `sess.CombinedOutput(cmd)`, error wraps exit status | `cli/ssh.go:1296-1318`, VERIFIED |
| Repo scale/activity | 17,220 stars, 1,641 forks, 1,168 open issues, `pushed_at` 2026-10-29, not archived | GitHub REST `/repos/coder/coder`, VERIFIED |
| Latest release | `v2.37.8`, published 2026-10-28 | GitHub REST `/repos/coder/coder/releases/latest`, VERIFIED |
| Module requires Go 1.26.10 | `go 1.26.10` | `go.mod:3`, VERIFIED |
| Helm chart ships in-repo | `helm/coder/{Chart.yaml,values.yaml,templates}` | repo tree, VERIFIED |
| Coder's docs market it as dev environments + AI agents, not CI | "Self-Hosted Cloud Development Environments and AI Agents" | `README.md`, VERIFIED |
| No SCM-webhook-to-build trigger in coderd | only notification dispatch + chat lifecycle hooks matched | grep over `coderd/`, VERIFIED (absence) |

## Rejected / not for this

- **As the CI executor.** Rejected outright. No pipeline semantics, no artifact store, no trigger. Building them means writing a CI system whose backend is a Terraform lifecycle API. Wrong layer.
- **As the object-storage layer (vs R2).** Not applicable — no S3-compatible API. The `coderd/files` endpoint is a small blob store for workspace/template uploads, not general object storage.
- **As the edge runtime (vs Workers).** Not applicable. `coderd` is a stateful Go server that wants PostgreSQL; it cannot run at the edge.
- **As the Durable Objects replacement.** Wrong shape. `tailnet/coordinator.go` is stateful coordination, but it is per-agent single-writer state tied to workspace identity, not a general keyed actor runtime with storage and alarms. Using it as a DO substitute would mean bending workspace identity into an actor model.
- **As a replacement for Cloudflare Mesh / Workers VPC.** Explicitly no. Coder's tailnet reaches workspace agents and their clients only; it is not a general machine-to-machine network. Running it *alongside* Mesh is duplication to be accepted, not a substitution to be made.
- **As a general-purpose container orchestrator (vs Containers/Sandbox).** No. Coder schedules workspaces onto provisioners; the actual scheduling is delegated to Terraform (Kubernetes, Docker, EC2). It is a layer above the orchestrator, not one.

## Open questions

1. **Licence or no licence?** The answer changes the architecture. Unlicensed means in-process provisioners inside `coderd` — fine for tens of workspaces, wrong for CI volume. Licensed means a cost line and a ToS acceptance. This should be decided before anything is built on prebuilds.
2. **Does the Worker dashboard hold the token, or does the browser?** Given the CORS finding, it must be the Worker (same-origin proxy). Confirm that is acceptable from a blast-radius standpoint — a compromised Worker means full control-plane access.
3. **What is the actual workspace start latency on your infrastructure?** Everything about whether this can front a CI-like workload depends on a number I have not measured here. Measure a cold `POST /builds` → SSH-ready on the real target before committing.
4. **Does the Terraform provider for templates (`coder/coder` TF provider, separate repo) get reached over the tunnel too?** Template pushes are a control-plane API call, so presumably yes, but the provider's URL override behaviour (`provider "coder" { url = ... }`) should be tested through the tunnel rather than assumed.
5. **Two overlays: who owns which?** If Coder's tailnet and Cloudflare Mesh both exist, document the rule for which hop a given connection takes, or debugging becomes folklore.
6. **AGPL patch policy.** Is "never patch `coderd`" an enforceable team rule? If not, the licence exposure needs a legal read before the first local fork.
7. **What replaces the CI slot?** This review only establishes that Coder is not it. The heavy-CI requirement is still unassigned in this study.
