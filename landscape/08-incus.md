# Incus — deep review

## Verdict

Yes — but only in the machine-provisioning slot, and it is *not* a CI orchestrator, so do not
let it drift into the orchestration slot the study explicitly reserved for something else. Incus
is the single best-fit OSS component in this whole landscape for "give me a Linux box, a
container, or a VM on my own hardware, with an HTTP API I can drive": one daemon, one REST
surface, both containers and real VMs behind the same object model, projects with hard quota
limits, profiles for templating, and a Raft-replicated control plane. What it will not do is
queue jobs, run a DAG, schedule across a fleet by resource demand beyond "fewest instances",
autoscale, or survive you treating its API as a durable job store. The seam into your design is
real but narrower than it looks: **a Worker can absolutely drive Incus's JSON API through a
Cloudflare Tunnel, and it cannot use Incus's TLS client-certificate auth or its client IP
attribution once it does.** Everything interactive (exec, console, SFTP) needs care and will
work, but on a different auth path than the rest of the API. Budget for that split.

## What it actually is

A 430,295-line Go monorepo (`find . -name '*.go' -not -name '*_test.go' | xargs wc -l`) that
builds one root daemon (`cmd/incusd`), one CLI (`cmd/incus`), one in-guest agent
(`cmd/incus-agent`), and a handful of converters. It is a fork of Canonical's LXD taken over by
the Linux Containers community after the 2023 Canonical takeover of LXD — `README.md:23-33`
says so plainly, and the commit graph backs it (the top two contributors by commit count are
`stgraber` at 16,473 and `tomponline` at 10,117, both LXD alumni).

What it is *not*, contrary to how it gets pitched in homelab posts:

- **Not a web product.** There is no default UI. `cmd/incusd/api.go:71` reads an `INCUS_UI`
  environment variable and serves whatever static bundle is at that path under `/ui/`. The
  maintainer's own position is explicit: "unlike LXD, Incus doesn't plan on having a default web
  UI" ([discuss.linuxcontainers.org/t/web-ui-for-incus/18198](https://discuss.linuxcontainers.org/t/web-ui-for-incus/18198)).
  The shipped `incus-ui-canonical` package is a 1,200,328-byte static SPA fork of LXD-UI, and —
  this matters for you — it talks to the Incus API **from the browser**, generating a client
  certificate into browser local storage. That architecture is incompatible with a
  Workers-hosted dashboard that proxies API calls. You cannot lift that UI; you write your own.
- **Not a container runtime in the Docker sense.** There is no image build, no layer cache, no
  compose, no registry push. OCI *pull* works (`incus launch oci-docker:hello-world`,
  `doc/howto/instances_create.md:64`) and needs `skopeo` installed
  (`doc/requirements.md`, "OCI" section).
- **Not a Kubernetes replacement.** No pods, no services, no ingress controller, no operator
  loop. Cluster scheduling is "lowest instance count, or a Starlark script you write"
  (`doc/explanation/clustering.md`, "Automatic placement of instances").

It *is* genuinely a small private cloud control plane: 106 top-level API endpoints
(`cmd/incusd/api_1.0.go:43`), 160 documented paths and 301 methods in the OpenAPI spec
(`doc/rest-api.yaml`, 23,975 lines), 577 API extensions
(`internal/version/api.go:23`, first `storage_zfs_remove_snapshots`, last
`nic_sriov_migration_native`).

## Architecture (with file paths)

### Process and endpoints

One daemon, `incusd`, running as root. It binds several independent listeners, all configured
from `core.*` settings:

| Listener | Default port | Constant |
|---|---|---|
| Main REST API (HTTPS) | 8443 | `internal/ports/ports.go:7` `HTTPSDefaultPort` |
| Metrics (HTTPS) | 9100 | `internal/ports/ports.go:8` `HTTPSMetricsDefaultPort` |
| S3 storage buckets (HTTPS) | 9000 | `internal/ports/ports.go:9` `HTTPSStorageBucketsDefaultPort` |
| Authoritative DNS | 53 | `internal/ports/ports.go:6` `DNSDefaultPort` |
| BGP | 179 | `internal/ports/ports.go:5` `BGPDefaultPort` |
| Local unix socket | — | `/var/lib/incus/unix.socket` (`doc/debugging.md:29`) |

The unix socket is the dangerous one and the docs say so without hedging: "Local access to
Incus through the Unix socket always grants full access to Incus. This includes the ability to
attach file system paths or devices to any instance as well as tweak the security features on
any instance" (`README.md:56-60`). Members of `incus-admin` are effectively root
(`doc/packaging.md:17`).

### The REST API

`internal/version/api.go:9` pins `APIVersion = "1.0"` — bumped only for backward-incompatible
changes, which have not happened. All feature growth is additive via the 577-entry
`APIExtensions` slice. Clients are expected to feature-detect. For a dashboard this is good
(no version drift) and bad (577 booleans to reason about, and no schema versioning beyond
"does the server have extension X").

Response envelope is three-shaped: `sync`, `async` (HTTP 202 + `Location` header pointing at
`/1.0/operations/<uuid>`), and `error`. Documented at `doc/rest-api.md:25-105`.

Handler wiring is a flat table. `cmd/incusd/api.go:66` `restServer()` builds an
`http.ServeMux`, then loops over `api10` (`cmd/incusd/api_1.0.go:43`) calling `createCmd`. Each
entry is an `APIEndpoint` with per-verb `APIEndpointAction` carrying a `Handler` and an
`AccessHandler`. Example, `cmd/incusd/instances.go:35-42`:

```go
var instancesCmd = APIEndpoint{
	Path: "instances",
	Get:  APIEndpointAction{Handler: instancesGet, AccessHandler: allowAuthenticated},
	Post: APIEndpointAction{Handler: instancesPost, AccessHandler: allowPermission(auth.ObjectTypeProject, auth.EntitlementCanCreateInstances), LargeRequest: true},
	Put:  APIEndpointAction{Handler: instancesPut, AccessHandler: allowAuthenticated},
}
```

Note `LargeRequest: true` on the create path — the server will buffer a large body, which is
how rootfs tarball uploads work (`cmd/incusd/instances_post.go:1302-1304`, the
`application/octet-stream` branch reading `X-Incus-pool` / `X-Incus-name` headers).

Everything is `/1.0/...` and resource-oriented: `/1.0/instances`, `/1.0/instances/{name}`,
`/1.0/instances/{name}/state`, `/1.0/instances/{name}/exec`, `/1.0/instances/{name}/console`,
`/1.0/instances/{name}/sftp`, `/1.0/instances/{name}/snapshots`, `/1.0/projects`,
`/1.0/profiles`, `/1.0/storage-pools`, `/1.0/networks`, `/1.0/operations`, `/1.0/events`,
`/1.0/cluster`, `/1.0/cluster/members`, `/1.0/certificates`, `/1.0/metrics`,
`/1.0/storage-pools/{pool}/buckets`. Listing supports `recursion` and `filter` query params.

### Async operations — the thing your dashboard will lean on

`cmd/incusd/operations.go:32-55` defines four endpoints: `operations/{id}` (GET/DELETE),
`operations` (GET), `operations/{id}/wait` (GET, `AllowUntrusted: true`), and
`operations/{id}/websocket` (GET, `AllowUntrusted: true`).

The critical implementation detail: **the operation registry is a plain in-memory map.**
`internal/server/operations/operations.go:31`:

```go
operations = make(map[string]*Operation)
```

Nothing persists it. Restart `incusd` and every operation UUID your dashboard is holding
returns 404. The work itself is unaffected — see restart behaviour below — but any
"job status" state machine built on Incus operation IDs is volatile. If you want durable CI job
state, it lives in your database, not in Incus.

### VM vs container instances

One object model, two drivers, selected by a string on the wire. `shared/api/instance.go:24-28`:

```go
const InstanceTypeContainer = InstanceType("container")
const InstanceTypeVM        = InstanceType("virtual-machine")
```

Internally `internal/server/instance/instancetype/instance_type.go` maps these to `Container = 0`
and `VM = 1`. `cmd/incusd/instances_post.go:1313-1316` defaults an omitted type to container.

The two drivers are where the real complexity lives and they are not remotely comparable:

- `internal/server/instance/drivers/driver_lxc.go` — 10,069 lines. Containers via liblxc,
  shared host kernel, namespaces + cgroups + seccomp + AppArmor/SELinux.
- `internal/server/instance/drivers/driver_qemu.go` — 14,376 lines. VMs via QEMU 8.2+, separate
  kernel, needs `/dev/kvm`, needs `incus-agent` running inside the guest for exec/file/console.

Security default is the right one: containers are unprivileged. `doc/explanation/security.md`
("Container security"): "By default, containers are *unprivileged*, meaning that they operate
inside a user namespace". `security.privileged` defaults to `false`
(`doc/config_options.txt:3117-3124`).

But read the project's own threat model before you put hostile CI code in a container.
`SECURITY.md`:

> We don't consider privileged containers to be root safe, so any exploit allowing someone to
> escape them will not qualify as a security issue.

That sentence is about *privileged* containers only — unprivileged escapes do count. Still, an
unprivileged container shares the host kernel. For "heavy CI" running arbitrary PR code from
strangers, containers are a performance choice, not a security boundary. VMs are the boundary.
Incus giving you both behind one API is precisely why it earns the slot: you can put trusted
builds in containers and untrusted forks in VMs without changing control plane.

### Projects and profiles

These are the two abstractions that make Incus usable multi-tenant, and they are the ones a
dashboard should map onto directly.

**Projects** (`cmd/incusd/api_project.go`, 2,302 lines; `internal/server/project/project.go`,
`permissions.go` at 2,187 lines) are namespaces with teeth. Three families of keys
(`doc/reference/projects.md`):

- `features.*` — which entity types are isolated per project vs inherited from `default`.
- `limits.*` — hard aggregate caps: `limits.containers`, `limits.cpu`, `limits.memory`,
  `limits.processes`, `limits.networks`. Important gotcha documented at
  `doc/reference/projects.md` ("Project limits"): the limit is enforced against the *sum of
  configured instance limits*, not against actual usage. So every instance in the project must
  have the corresponding `limits.*` key set, and `limits.cpu` must be a plain number (not a set
  or range), and `limits.memory` must be absolute (not a percentage). If you build a CI tenant
  model on project limits you must enforce that invariant in your own templates or creates
  will start failing.
- `restricted.*` — blocks security-sensitive features (`security.nesting`,
  `security.privileged`, raw LXC config, device passthrough) unless individually re-allowed.
  `restricted=true` with `restricted.containers.nesting=allow` is the canonical CI shape
  (`doc/reference/projects.md`, "Project restrictions").

Also `GET /1.0/projects/{name}/state` gives allocated-vs-used resources — that is your quota
dashboards.

**Profiles** (`shared/api/profile.go:43-62`) are named, reusable `{config, devices}` bundles
attached to instances. `UsedBy []string` gives you reverse dependency tracking for free
(`profile_usedby` extension). Profiles are per-project, so "ci-small", "ci-gpu" live inside each
tenant project. This is exactly the templating primitive a provisioning layer wants: the
dashboard POSTs an instance with `profiles: ["ci-small"]` and does not restate 30 config keys.

### Clustering

Cowsql, not dqlite. `go.mod` pins `github.com/cowsql/go-cowsql v1.22.1-0.20261014181424-288c15e22ea5`,
and `internal/server/db/raft.go:9-11` imports `github.com/cowsql/go-cowsql/client` and
`.../cluster/db`. 207 references to cowsql across the tree. Cowsql is a fork of Canonical's
dqlite by Free Ekanayaka — the original dqlite author — created 2023-08-08, LGPLv3 with an
explicit static-linking exception.

Constraints, straight from `doc/explanation/clustering.md` ("Requirements"):

- **Minimum three members for HA**, so the Raft quorum survives one loss. Two works, badly.
- **Inter-member latency must not exceed 10 ms.** "The distributed database and the heartbeats
  between members are not supported over higher latency links." This is the single most
  important architectural constraint for your design: your cluster must be one region, one
  rack-ish, not geo-distributed.
- Clocks must be NTP-synced or members get falsely marked offline.
- **All members must have identical storage pools and networks.** Only a narrow set of
  member-specific keys may differ (`doc/explanation/clustering.md`, "Member configuration").
  This kills heterogeneous fleets: you cannot have three build hosts with different disk
  layouts and join them to one cluster without pain.

Defaults: `cluster.max_voters` = 3 (`doc/config_options.txt:5716-5720`), `cluster.max_standby` = 2,
`cluster.offline_threshold` = 20s (min 10s). Roles are `database`, `database-leader`,
`database-standby`, `database-client`, `event-hub`, `ovn-chassis`. Instance placement is
fewest-instances-by-default, overridable per member with `scheduler.instance` = `all` |
`manual` | `group`, or globally with a Starlark `instance_placement(request, candidate_members)`
scriptlet (`doc/explanation/clustering.md`, "Instance placement scriptlet") — which is a
genuinely nice escape hatch and also a thing you now have to version-control.

### The remote-cluster join flow

Relevant because the task asks, and because it is a place a dashboard should *not* go.

`POST /1.0/cluster` with `core.https_address`/`cluster.https_address`, then the joining node
runs `incus cluster add <name>` against the existing cluster and gets a join token; the member
is admitted pending, then `POST /1.0/cluster/members/{name}` promotes it. The code lives in
`cmd/incusd/api_cluster.go` (the `core.https_address` → `cluster.https_address` copy logic is
at lines 369-394) and `internal/server/cluster/membership.go`, `connect.go` (399 lines, which
ends at `cowsqlcluster.HasConnectivity(...)`), `internal/server/cluster/gateway.go`.

The join is a mutual-TLS handshake plus a shared secret, and it requires the joining node's
storage and network configuration to already match the bootstrap node or it is rejected. This
is an operator action over an SSH session, not an API call to expose to a web dashboard. Treat
cluster membership as out-of-band.

### Storage and the built-in S3

Nine storage drivers (`internal/server/storage/drivers/`): `dir`, `btrfs`, `lvm`, `zfs`,
`ceph`, `cephfs`, `cephobject`, `linstor`, `truenas`. ZFS and btrfs give you copy-on-write
clones, which is what makes container creation fast — a fresh instance from a cached image is a
snapshot, not a copy.

Worth flagging because it overlaps another slot in your study: **Incus ships an in-process
S3-compatible server** for storage buckets on local pools.
`internal/server/storage/s3/local/server.go:1-16` describes it: "an in-process S3-compatible
HTTP handler that serves objects from a directory on the local filesystem... without spawning
an external S3 server", with on-disk layout `data/<key>`, `data/<key>.meta`,
`data/.uploads/<id>/`. 3,098 lines across `s3/local/` and `s3/`. Listener on port 9000
(`internal/ports/ports.go:9`), enabled via `core.storage_buckets_address`.

It is not an R2 replacement. `internal/server/storage/s3/local/server.go:184` refuses bucket
lifecycle outright ("Bucket lifecycle is managed by the Incus API"), `getBucketVersioning`
returns an empty config because versioning is never on, and `doc/howto/storage_buckets.md`
("Storage buckets in a cluster") says buckets on local pools are **not replicated** — each
bucket lives on exactly one member, and S3 access is only possible through that member. HA
object storage requires `cephobject`. See "Rejected / not for this".

### Moving parts

This is the honest cost. A single `incusd` is not one process:

- 14 `fork*` re-exec helpers under `cmd/incusd/main_*.go`: `forkbpf`, `forkconsole`,
  `forkcoresched`, `forkexec`, `forkfile`, `forklxc`, `forkmigrate`, `forkmount`, `forknet`,
  `forkproxy`, `forkqemu`, `forksyscall`, `forkuevent`, `forkzfs`. Each is a short-lived child
  doing privileged work in a namespace.
- `dnsmasq` per managed bridge (min 2.90, `doc/requirements.md`).
- `lxcfs` strongly recommended for correct `/proc` accounting in containers.
- `qemu` + `virtiofsd` per VM.
- `nftables` >= 1.0.0 for the firewall, `skopeo` for OCI, plus the driver tooling
  (`zpool`, `lvs`, `btrfs`, `rbd`) for whichever backend you pick.
- `incus-agent` inside every VM, for exec/file/console.

The Zabbly `incus-base` package `Depends:` line has **84 comma-separated entries**. Not
minimalist.

## The seam into this design

Your dashboard is a Worker. Incus is an HTTPS JSON API. On paper, perfect. In practice there
are exactly three seams, and two of them are broken in ways you must design around.

### Seam 1 — the transport: unix socket vs TCP/TLS

Locally, Incus speaks HTTP over `/var/lib/incus/unix.socket` (`doc/debugging.md:29`,
`client/connection.go:172`). That socket is root-equivalent and cannot be proxied to a
Cloudflare Tunnel without effectively publishing root. Do not do it.

Remotely, you set `core.https_address` and get the same API over TLS on 8443
(`internal/server/endpoints/network.go`, `networkCreateListener`). Two things make this
*safer* than the socket and one makes it *harder*:

- TLS floor is 1.3, PFS-only ciphers, ECDHE, SHA-2. `doc/authentication.md` is blunt: "Since we
  control both client and server, there is no reason to support any backward compatibility to
  broken protocol or ciphers." Setting `INCUS_INSECURE_TLS` drops to 1.2 and is explicitly
  "not a supported setup".
- Auth is mutual TLS with a client certificate in the trust store, or OIDC.
- `core.https_address` binds wherever you tell it. Bind it to `127.0.0.1:8443` and let
  `cloudflared` be the only thing that can reach it. That is the correct posture and it works.

**The break:** cloudflared cannot present a client certificate to the origin. The origin
parameter reference lists `originServerName`, `matchSNItoHost`, `caPool`, `noTLSVerify`,
`tlsTimeout`, `http2Origin`, `httpHostHeader`, `disableChunkedEncoding`, `connectTimeout` — and
nothing for a client cert
([Cloudflare origin parameters](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/)).
So every request arriving from the tunnel is *untrusted* to Incus. mTLS is not available to you
through this path. Full stop.

That leaves exactly two working auth paths, both of which Incus anticipated:

**(a) OIDC.** `oidc.*` server options, browser code flow at `/oidc/login` →
`/oidc/callback` → `/oidc/logout` (`cmd/incusd/api.go:97-112`), plus a device-code flow for
CLIs. Your Worker becomes an OIDC client and forwards the bearer token. This is the cleanest
fit. Read the warning first — `doc/authentication.md`: "Any user that authenticates through the
configured OIDC Identity Provider gets full access to Incus." There is no role model. To
restrict, you must also run OpenFGA. For a multi-tenant CI dashboard, that means OIDC **plus**
an external OpenFGA server, which is one more service to operate
(`internal/server/auth/driver_openfga.go`, 1,672 lines; model at
`driver_openfga_model.openfga`, 150 lines). Budget for it.

**(b) TLS JWT in a cookie.** Incus lets you sign a JWT with a trusted client cert's private key
and exchange it for a cookie at `POST /tls/login`. This exists *precisely* for your case —
`doc/authentication.md` (authentication-tls-jwt): "Browser based clients which cannot set HTTP
headers on WebSocket connections can instead send the token once through a `POST` request to
`/tls/login`... Incus stores the token in a `Secure`, `HttpOnly` cookie named `tls_jwt`."
Verification is `internal/server/util/http.go:393` `VerifyJwtToken`: the token's `sub` must be
the fingerprint of a certificate in the trust store, the signature is checked against that
cert's public key, and tokens carrying an `iss` are rejected outright (line 413) so an OIDC
token can't be smuggled in.

Two hard constraints on path (b), both citable:

- `cmd/incusd/tls_jwt.go:47` — `if r.TLS == nil { ... "TLS JWT login requires a TLS connection" }`.
  The origin leg from cloudflared must be HTTPS, not HTTP.
- `cmd/incusd/tls_jwt.go:15-32` — the cookie is `Secure: true, HttpOnly: true,
  SameSite: SameSiteStrictMode`. Combined with the CSRF guard at `cmd/incusd/tls_jwt.go:42`
  which rejects `Sec-Fetch-Site: cross-site` and `same-site`, **your dashboard must be served
  from the same origin as the Incus API.** If the dashboard is `dash.example.com` and the API
  is `incus.example.com`, the cookie flow dies. Put both behind one tunnel hostname with the
  API under a path prefix, or accept that you're proxying everything from the Worker and the
  cookie never reaches a browser at all.

And path (b) means the Worker holds a long-lived private key for a cert with full API access.
That is a serious credential to put in a Worker.

### Seam 2 — the client IP

**Incus does not read `X-Forwarded-For`.** Not anywhere. `grep -rn 'X-Forwarded-For\|X-Real-IP'
--include=*.go .` returns nothing. The requestor address is taken verbatim from the socket:
`internal/server/request/request.go:27`:

```go
requestor.Address = r.RemoteAddr
```

Incus's only mechanism for recovering a real client IP is PROXY protocol, and only from
explicitly trusted peers. `internal/server/endpoints/listeners/fancytls.go:36-45`:

```go
if isProxy(c.RemoteAddr().String(), l.trustedProxy) {
	c = proxyproto.NewConn(c, proxyproto.WithPolicy(proxyproto.USE))
}
```

`l.trustedProxy` is populated from `core.https_trusted_proxy`
(`doc/config_options.txt:5845-5849`: "comma-separated list of IP addresses of trusted servers
that provide the client's address through the proxy connection header").

**cloudflared does not send PROXY protocol.** It is not among the origin parameters, and it is
not in the configuration file reference. So `core.https_trusted_proxy` is dead weight in your
design, and:

- Every request appears to come from `127.0.0.1`.
- Audit logs (`lifecycle` events carry `requestor.address`) record `127.0.0.1` for everything.
  Your audit trail is worthless for attribution.
- The OIDC `incus.allowed_subnets` claim — which restricts a user to a set of CIDRs — cannot
  work, because the source IP is always localhost.

Mitigation: do the attribution in the Worker. Have the Worker stamp a header with the
`CF-Connecting-IP` it saw and log that alongside the Incus operation ID. Incus will not help
you here and there is no config flag that makes it.

### Seam 3 — interactive sessions: exec, console, SFTP

This is the part that will actually bite you.

`incus exec` is not one WebSocket. It is **four**, multiplexed by a `?websocket=N` query
parameter against a single operation's `/1.0/operations/{id}/websocket` URL.
`cmd/incusd/instance_exec.go:48-51`:

```go
execWSControl = -1
execWSStdin   = 0
execWSStdout  = 1
execWSStderr  = 2
```

The client must POST `/1.0/instances/{name}/exec`, receive an operation, read the per-fd
secrets out of the operation metadata (`{"fds": {"0": "...", "1": "...", "2": "...",
"control": "..."}}` — see `doc/rest-api.md:78-84`), then open four WebSocket upgrades **within a
short window**. `cmd/incusd/instance_exec.go:196-201`:

```go
// As this function only gets called when the exec request has WaitForWS enabled, we expect the client to
// connect to all of the required websockets within a short period of time and we won't proceed until then.
select {
case <-s.waitRequiredConnected.Done():
case <-time.After(time.Second * 10):
	return errors.New("Timed out waiting for websockets to connect")
}
```

Console is the same shape with `const consoleConnectTimeout = 10 * time.Second`
(`cmd/incusd/instance_console.go:76-77`), and VGA console opens *dynamic* per-channel
WebSockets on top of the control socket (see the `dynamic map[*websocket.Conn]*os.File` field
at `instance_console.go:52` and `connectVGA`).

Consequences for a Worker-fronted dashboard:

- If the **browser** opens the four sockets directly through the tunnel, fine — but then the
  browser holds the credential and the Worker is only serving static JS. That contradicts
  "dashboard on Workers, machines reached over tunnel" if you meant the Worker proxies.
- If the **Worker** opens them, you need four concurrent `fetch()` upgrades from one
  invocation. Workers allow 6 simultaneous connections but only while *waiting for response
  headers*; once the 101 arrives the slot frees
  ([Workers limits](https://developers.cloudflare.com/workers/platform/limits/)). Four
  WebSocket upgrades fit. It is tight, and any retry logic that overlaps sockets will hit the
  queue.
- The 10-second window is the real hazard. Cold start, OIDC token refresh, or a tunnel
  reconnect mid-handshake and the exec fails with "Timed out waiting for websockets to
  connect". You need retry-at-the-top, not retry-per-socket.
- `op.IsSameRequestor(r)` is enforced on both exec and console
  (`instance_exec.go:96`, `instance_console.go:94`). It compares **username and protocol only**
  (`internal/server/operations/operations.go:225-238`) — not address. So the exec POST and the
  four upgrades must share an auth identity and auth *method*. Do not POST with OIDC and
  upgrade with the `tls_jwt` cookie; that is two protocols and you get a 403.

Practical recommendation: **do not build interactive exec into the Workers dashboard in v1.**
Use `POST /1.0/instances/{name}/exec` with `wait-for-websocket: false` and non-interactive
stdio, collect output, and let CI logs flow through your own log pipeline. Add console/exec
later, direct from the browser through the tunnel, with the credential in the browser. That is
also the better security shape.

### What a Worker can comfortably do

The JSON CRUD path is unambiguously fine and is the bulk of the value:

- `POST /1.0/instances` with `{name, type, source: {type: "image", alias, server, protocol},
  profiles, config, devices, ephemeral: true}` → 202 + operation.
- `GET /1.0/operations/{id}/wait?timeout=N` to block on it (it's `AllowUntrusted: true`, so no
  auth dance for the wait itself).
- `PUT /1.0/instances/{name}/state` with `{action: "start"|"stop"|"restart"|"freeze"}`.
- `GET /1.0/instances?recursion=1&project=...` for inventory.
- `GET /1.0/projects/{name}/state` for quota.
- `POST /1.0/instances/{name}/snapshots` for build cache.
- `DELETE /1.0/instances/{name}`.
- `ephemeral: true` (`shared/api/instance.go:175-177`, "Whether the instance is ephemeral
  (deleted on shutdown)") is the CI primitive you want — the container deletes itself on stop,
  so a crashed job cannot leak a machine.

For events, `/1.0/events` is a WebSocket streaming `logging`, `operation` and `lifecycle`
messages (`doc/events.md`). Useful, but note the documented behaviour: "A listener that cannot
keep up with the stream is disconnected rather than having events silently skipped. After
reconnecting, anything being tracked from the event stream should be re-fetched." And
`doc/events.md` ("Event ordering") warns the Go client's `AddHandler` is concurrent — use
`AddChannel` for ordering. Your Worker will be one listener among many; plan to resync from
REST on every reconnect, not to treat the stream as a log.

## Limits and failure modes

**Restart semantics are better than you'd fear.** `doc/daemon-behavior.md` ("Signal handling"):
on `SIGINT`/`SIGQUIT`/`SIGTERM`, "The instances will keep running and Incus will close all
connections and exit cleanly." Containers and VMs survive a daemon restart; only the control
plane drops. On startup (`cmd/incusd/daemon.go:1752`, `instancesStart`), Incus walks the
instances table and restarts anything whose `volatile.last_state.power` says `running`
(`cmd/incusd/instances.go:274-283`, `instanceShouldAutoStart`), with `boot.autostart`,
`boot.autostart.priority` and `boot.autostart.delay` for ordering, and up to 3 start attempts.
`SIGPWR` is the host-going-down signal and does a clean 30-second shutdown.

**What actually breaks on restart:**
1. All operation UUIDs. In-memory map, `internal/server/operations/operations.go:31`. Any
   in-flight dashboard poll gets 404.
2. All WebSockets: exec, console, events, SFTP. Client must reconnect.
3. In-flight migrations. A half-finished `copy` or `move` is not resumable from the API's
   point of view.
4. `incusd` upgrades are the nasty case: you cannot upgrade a cluster member's daemon without
   either evacuating it (`cluster.healing_threshold`, `cmd/incusd/api_cluster_evacuation.go`)
   or accepting that its instances keep running an old userspace against a new database
   schema. `internal/server/cluster/upgrade.go` gates on version compatibility across members.

**Throughput / scale ceilings you should design against:**
- Cluster latency ceiling: 10 ms between members. Hard. `doc/explanation/clustering.md`.
- Quorum: lose one voter of three and you keep going; lose two and "no operations are possible
  on this member, and neither are operations that require a state change across all members".
  Read that sentence twice — a degraded cluster is not read-only, it is *write-blocked*.
- `cluster.offline_threshold` default 20s, minimum 10s. Below that you get false offline marks
  on a loaded host.
- Metrics are per-member. `doc/metrics.md`: "In a cluster environment, Incus returns only the
  values for instances running on the server that is being accessed. Therefore, you must scrape
  each cluster member separately." Your dashboard must fan out.
- Metrics are expensive and cached 8 seconds. `doc/metrics.md`: "Fetching metrics is a
  relatively expensive operation for Incus to perform."

**Kernel and platform requirements are not negotiable** (`doc/requirements.md`): kernel 6.12
minimum, cgroups v2 with `blkio/cpuset/devices/freezer/memory/pids`, seven namespace types,
seccomp, native Linux AIO. Go 1.26+ to build. This is a modern-Linux-only product; there is no
"just run it in a container on macOS" story for the daemon.

**The cgo coupling.** 158 files carry `//go:build linux && cgo`. `incusd` links liblxc,
libcowsql, libsqlite3, libseccomp, libapparmor, libudev. You are not shipping a static Go
binary; you are shipping a system package. That has real consequences for "how do I deploy
this": it is `apt install` from Zabbly or your distro, not `docker run`.

**Install footprint, measured** (Zabbly `bookworm` amd64, version `1:7.5.1-debian12-202610262250`):

| Package | .deb size | Installed size |
|---|---|---|
| `incus-base` (contains `incusd`) | 52,719,236 B | 235,896 KiB |
| `incus` (VM/QEMU extras) | 89,768,388 B | 234,156 KiB |
| `incus-client` | — | 27,090 KiB |
| `incus-ui-canonical` | 1,200,328 B | 4,573 KiB |

Source tree is 34 MB shallow-cloned, release tarball 26,030,475 B, published `bin.linux.incus.x86_64`
client binary 26,046,624 B. Note `incusd` itself is *not* published as a release asset — only
the client and agent are; the daemon comes from packages.

**Dependency surface:** 77 direct Go modules, 100 indirect, 177 total (`go.mod`). AWS SDK v2
(pulled in for the S3 client side), OpenFGA SDK, OIDC, gobgp, OVN libovsdb, golinstor,
opencontainers/umoci, Starlark. This is a large, security-relevant dependency graph in a
root-running daemon.

## Licence and governance

**Apache-2.0**, verified from the GitHub API (`license.spdx_id: "Apache-2.0"`). `README.md:29-31`
states it and adds the thing that matters: "a true open source community project, free of any
CLA". No contributor licence agreement, no open-core, no "community edition" gate, no
relicensing risk of the Elastic/MongoDB kind. This is the strongest governance position of any
project in this landscape.

**Cowsql is the one licensing wrinkle, and it is fine.** `cowsql/cowsql` reports
`license: NOASSERTION` on GitHub, which will trip a naive licence scanner. The actual
`LICENSE` file says LGPLv3 with a carve-out:

> This software is licensed under the LGPLv3... As a special exception to the GNU Lesser
> General Public License version 3 ("LGPL3"), the copyright holders of this Library give you
> permission to convey to a third party a Combined Work that links statically or dynamically to
> this Library without providing any Minimal Corresponding Source...

So static linking is explicitly permitted. `incusd` links it dynamically anyway. Apache-2.0 +
LGPLv3-with-static-exception is a clean combination for you. But if your legal review runs an
automated scanner it *will* flag `NOASSERTION`, so pre-empt that.

**Bus factor is the real governance risk, and it is stark.** Of the last 100 commits on `main`,
`stgraber` authored 58. The next four are 12, 10, 9 and 7. All-time, two people (16,473 +
10,117 commits) dominate a project with 513 forks and 6,524 stars. `freeekanayaka` — who also
owns cowsql — is third at 1,500. This is a two-maintainer project wearing a community's clothes.
It has been that way since LXD, and it has survived, but you should price in the scenario where
Stéphane Graber stops. There is no foundation, no corporate sponsor with a support contract
beyond Zabbly (a one-person shop selling packages), and no vendor SLA.

**Support lifecycle is genuinely good.** Incus 7.0 LTS released 2026-05-05, supported until
**June 2031** — two years of bug and security fixes plus minor usability improvements, then
three years of security-only
([announcement](https://discuss.linuxcontainers.org/t/incus-7-0-lts-has-been-released/26641),
[LWN](https://lwn.net/Articles/1071469/)). Feature releases are monthly and supported only until
the next one. For a self-hosted stack you want 7.0 LTS, not 7.5.x.

One documentation bug worth knowing: `doc/support.md:7` still says "Long term support (LTS)
releases: 6.0" and cites June 2029, even though 7.0 LTS shipped in May 2026 and the file itself
references "Incus 7.0 LTS' release" two lines later at `doc/support.md:14`. The in-tree support
page is stale; trust the announcement, not `doc/support.md`.

Security policy (`SECURITY.md`): feature releases get no backports, LTS gets accumulated
bugfixes. Privileged-container escapes are explicitly out of scope as security issues.
Unprivileged escapes are in scope.

## Verified facts

| claim | value | source |
|---|---|---|
| Licence | Apache-2.0, SPDX `Apache-2.0` | https://api.github.com/repos/lxc/incus (via forge proxy) — VERIFIED |
| Stars / forks / open issues | 6,524 / 513 / 35 | same — VERIFIED |
| Repo created / last push | 2023-07-22 / 2026-10-29T03:31:05Z | same — VERIFIED |
| HEAD commit | `18068492788d26b3aad307b1331703c0d69c27db`, 2026-10-28 | `git log -1` in clone — VERIFIED |
| In-tree version | `7.5.1` | `internal/version/flex.go:4` — VERIFIED |
| API base version | `"1.0"` | `internal/version/api.go:9` — VERIFIED |
| API extensions | 577, last `nic_sriov_migration_native` | `internal/version/api.go:23` (counted) — VERIFIED |
| Top-level API endpoints | 106 entries in `var api10` | `cmd/incusd/api_1.0.go:43` (counted) — VERIFIED |
| OpenAPI surface | 160 paths, 301 methods, 23,975 lines | `doc/rest-api.yaml` (counted) — VERIFIED |
| Go LOC (non-test) | 430,295 across 1,292 files; 134 test files | `find`/`wc -l` in clone — VERIFIED |
| Go modules | 77 direct + 100 indirect = 177 | `go.mod` (counted) — VERIFIED |
| Go toolchain required | 1.26+ | `doc/requirements.md`; `go.mod` says `go 1.26.7` — VERIFIED |
| Minimum kernel | 6.12 | `doc/requirements.md` — VERIFIED |
| LXC / QEMU / dnsmasq / nftables minimums | 6.0.0 / 8.2 / 2.90 / 1.0.0 | `doc/requirements.md` — VERIFIED |
| API port | 8443 | `internal/ports/ports.go:7` — VERIFIED |
| Metrics port | 9100 | `internal/ports/ports.go:8` — VERIFIED |
| Storage-bucket S3 port | 9000 | `internal/ports/ports.go:9` — VERIFIED |
| Local socket path | `/var/lib/incus/unix.socket` | `doc/debugging.md:29` — VERIFIED |
| TLS floor | 1.3, PFS-only, ECDHE, SHA-2 | `doc/authentication.md` — VERIFIED |
| Operations registry | in-memory `map[string]*Operation` | `internal/server/operations/operations.go:31` — VERIFIED |
| Client IP source | `r.RemoteAddr` only; no XFF support anywhere | `internal/server/request/request.go:27`; repo-wide grep for `X-Forwarded-For` returns 0 hits — VERIFIED |
| Real-IP mechanism | PROXY protocol from `core.https_trusted_proxy` peers | `internal/server/endpoints/listeners/fancytls.go:36-45`; `doc/config_options.txt:5845` — VERIFIED |
| cloudflared origin params | no client cert, no PROXY protocol | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/ — VERIFIED |
| cloudflared WS behaviour | "long-lived HTTP requests (for example, Websocket)... will be dropped" when a replica stops | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/configuration-file/ — VERIFIED |
| Workers simultaneous connections | 6, only while awaiting response headers | https://developers.cloudflare.com/workers/platform/limits/ — VERIFIED |
| Workers CPU time | 10 ms free / 5 min paid (default 30 s) | same — VERIFIED |
| Workers duration for HTTP | no limit | same — VERIFIED |
| `exec` WebSockets per call | 4 (control, stdin, stdout, stderr) | `cmd/incusd/instance_exec.go:48-51` — VERIFIED |
| exec WS connect window | 10 seconds | `cmd/incusd/instance_exec.go:196-201` — VERIFIED |
| console WS connect window | 10 seconds | `cmd/incusd/instance_console.go:76-77` — VERIFIED |
| Requestor check | username + protocol only | `internal/server/operations/operations.go:225-238` — VERIFIED |
| tls_jwt cookie | Secure, HttpOnly, SameSite=Strict | `cmd/incusd/tls_jwt.go:15-32` — VERIFIED |
| tls_jwt CSRF guard | rejects `Sec-Fetch-Site: cross-site\|same-site` | `cmd/incusd/tls_jwt.go:42` — VERIFIED |
| tls_jwt requires TLS | `if r.TLS == nil` → 400 | `cmd/incusd/tls_jwt.go:47-50` — VERIFIED |
| JWT verification | `sub` = cert fingerprint, sig vs cert pubkey, `iss` rejected | `internal/server/util/http.go:393-470` — VERIFIED |
| Cluster minimum for HA | 3 members | `doc/explanation/clustering.md` — VERIFIED |
| Cluster latency ceiling | 10 ms | same — VERIFIED |
| `cluster.max_voters` / `max_standby` | 3 / 2 | `doc/config_options.txt:5716`; `internal/server/cluster/config/config.go:136-146` — VERIFIED |
| `cluster.offline_threshold` | 20 s default, 10 s min | `doc/explanation/clustering.md` — VERIFIED |
| Replication engine | Cowsql (dqlite fork), Raft | `go.mod`; `internal/server/db/raft.go:9-11`; `doc/explanation/clustering.md` — VERIFIED |
| Cowsql licence | LGPLv3 + static-linking exception | https://github.com/cowsql/cowsql/blob/main/LICENSE — VERIFIED |
| Cowsql provenance | fork of Canonical dqlite by its original author | https://github.com/cowsql/cowsql README — VERIFIED |
| Container/VM types | `"container"` / `"virtual-machine"` | `shared/api/instance.go:24-28` — VERIFIED |
| Driver sizes | LXC 10,069 lines; QEMU 14,376 lines | `wc -l` — VERIFIED |
| Containers default | unprivileged | `doc/explanation/security.md`; `doc/config_options.txt:3117-3124` — VERIFIED |
| Privileged escapes | not treated as security issues | `SECURITY.md` — VERIFIED |
| Daemon restart effect | instances keep running, connections closed | `doc/daemon-behavior.md` — VERIFIED |
| Storage drivers | 9 (dir, btrfs, lvm, zfs, ceph, cephfs, cephobject, linstor, truenas) | `internal/server/storage/drivers/` — VERIFIED |
| Built-in S3 | in-process, port 9000, no bucket lifecycle, no versioning | `internal/server/storage/s3/local/server.go:1-16, 184`; `getBucketVersioning` — VERIFIED |
| Bucket replication | none on local pools; cephobject for HA | `doc/howto/storage_buckets.md` — VERIFIED |
| No default web UI | `INCUS_UI` env points at a static bundle | `cmd/incusd/api.go:71`; https://discuss.linuxcontainers.org/t/web-ui-for-incus/18198 — VERIFIED |
| 7.0 LTS support window | released 2026-05-05, supported to June 2031 | https://discuss.linuxcontainers.org/t/incus-7-0-lts-has-been-released/26641 — VERIFIED |
| In-tree support doc | stale — still says 6.0 LTS / June 2029 | `doc/support.md:7,12,14` — VERIFIED |
| Package sizes (Zabbly bookworm amd64, 1:7.5.1) | incus-base 52,719,236 B / 235,896 KiB; incus 89,768,388 B / 234,156 KiB; incus-client 27,090 KiB; incus-ui-canonical 1,200,328 B / 4,573 KiB | https://pkgs.zabbly.com/incus/stable/dists/bookworm/main/binary-amd64/Packages — VERIFIED |
| `incus-base` Depends entries | 84 comma-separated | same — VERIFIED |
| Release binaries | client `bin.linux.incus.x86_64` 26,046,624 B; tarball 26,030,475 B; no `incusd` asset | https://github.com/lxc/incus/releases/tag/v7.0.2 — VERIFIED |
| Bus factor | stgraber 58/100 recent commits; 16,473 all-time vs tomponline 10,117 | GitHub commits + contributors API — VERIFIED |
| cgo coupling | 158 files `//go:build linux && cgo` | repo grep — VERIFIED |
| Fork helpers | 14 `fork*` subcommands | `cmd/incusd/main_*.go` — VERIFIED |
| OIDC users | full access unless OpenFGA configured | `doc/authentication.md`; `doc/authorization.md` — VERIFIED |
| OpenFGA requires external server | yes | `doc/authorization.md` — VERIFIED |
| Project limits semantics | sum of configured instance limits, not actual usage | `doc/reference/projects.md` — VERIFIED |

## Rejected / not for this

**Rejected as the CI orchestrator.** No job queue, no DAG, no dependency graph, no retry
policy, no artifact model, no runner registration. The closest thing is a Starlark placement
scriptlet and that only answers "which member". If you make Incus your orchestrator you will
rebuild a worse Jenkins inside a root daemon's API.

**Rejected as durable job state.** Operations are an in-memory map
(`internal/server/operations/operations.go:31`). Never let the CI job's source of truth be an
Incus operation UUID.

**Rejected as the R2 replacement.** The embedded S3 server is a nice bonus and not a product.
`internal/server/storage/s3/local/server.go:184` refuses bucket lifecycle, versioning is
stubbed to empty, `doc/howto/storage_buckets.md` confirms buckets on local pools are not
replicated and are reachable only through the member that owns them. No lifecycle rules, no
object lock, no replication, no cross-region, no CDN, no signed-URL story comparable to R2's.
Use it for build-cache buckets that live next to the builder; do not put your primary object
store on it. If you want HA S3 from Incus you need Ceph RGW behind `cephobject`, which means
operating Ceph — a much bigger commitment than the thing you were replacing.

**Rejected as the Workers runtime replacement.** Different layer entirely. Incus does not run
JS.

**Rejected for heterogeneous fleets.** `doc/explanation/clustering.md` requires identical
storage and network config across members and ≤10 ms latency. If your build machines are
rented from three providers in three regions, you get three single-node Incus installs, not one
cluster, and you lose every cluster feature (migration, evacuation, unified view).

**Rejected as a hardened multi-tenant boundary on its own.** Unprivileged containers share the
kernel. For arbitrary PR code, use `type: virtual-machine`. And note the project will not treat
privileged-container escapes as vulnerabilities at all (`SECURITY.md`), so a "we'll just run
privileged, it's fine" shortcut has zero upstream backing.

**Rejected: exposing the unix socket through the tunnel.** `README.md:56-60` — that socket is
root. `core.https_address` bound to `127.0.0.1` with `cloudflared` in front is the only
defensible shape.

**Rejected: reusing `incus-ui-canonical`.** It is a browser-side SPA that generates a client
cert into local storage and talks to the API directly. It cannot sit behind a Worker that
proxies, and it cannot work through a tunnel without mTLS. 1.2 MB of code you cannot reuse.

## Open questions

1. **Does the design want the Worker to proxy the API, or only to serve the dashboard?** These
   are very different systems. If the browser talks to Incus directly through the tunnel, mTLS
   is unavailable but the `tls_jwt` cookie flow works cleanly and the Worker never holds a
   credential. If the Worker proxies, you need OIDC + OpenFGA and you lose per-user audit
   attribution. I would pick browser-direct and treat the Worker as UI + orchestration glue.

2. **Is OIDC+OpenFGA worth it, or is one shared credential acceptable?** For a single-team CI
   system, one `tls_jwt`-capable client cert held by the Worker is simpler and Incus's own
   `doc/authentication.md` warns that OIDC without OpenFGA grants full access to everyone who
   authenticates. But "everyone who can log into your IdP is a cluster admin" is a sentence
   that ends badly.

3. **Where does the 10 ms cluster latency budget actually land?** This decides whether you have
   one cluster or N standalone nodes. If the build hosts are in one rack, Incus clustering is a
   real win (live migration, evacuation, unified inventory). If they're spread, you are running
   N single-node daemons and the "cluster" section of this review is moot.

4. **Do you need live migration?** If yes, note `doc/explanation/clustering.md` ("Cluster CPU
   baseline"): Incus computes a QEMU CPU baseline across members and mixed CPU generations or
   vendors may break it. Homogeneous hardware is a prerequisite you may not control.

5. **What is the container-start latency from a cold image cache, and does it matter?** First
   create on a host pulls the image (`doc/requirements.md` needs `skopeo`); subsequent creates
   are snapshot clones. For CI, the warm path is what counts, and I did not measure it. Worth a
   benchmark before committing.

6. **Does anything actually need `incusd` restart-tolerant exec?** If a Worker holds a 4-socket
   exec session and the daemon is upgraded, the session dies with no resume. If long-running
   interactive shells matter, that is a design constraint to state up front.

7. **Who owns the Cowsql fork if Free Ekanayaka stops?** Cowsql has 249 stars, 18 forks, last
   push 2026-06-22, and is the single point of failure for Incus's entire control plane. Incus
   forked off dqlite precisely because of Canonical; if cowsql stalls, Incus has nowhere to go.
   I did not find a stated contingency.
