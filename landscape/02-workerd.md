# workerd — deep review

## Verdict

**Yes for the edge-runtime slot, no for the compute slot, not yet for the coordination slot.**
workerd is the only honest way to get "Workers, but on my machines": it is the actual runtime, Apache-2.0, actively developed by a large Cloudflare team, and its capability/binding model maps cleanly onto a control plane that pushes config. Put it in the **edge-runtime slot** and stop looking. But the two things this study actually cares about are weak. `ctx.container` is a **Docker-daemon shim bolted onto Durable Objects** — one container per DO, a `NET_ADMIN` sidecar per container, no scheduler, no resource limits actually applied, and the supervising DO evicted after 10 s idle. That is the Cloudflare Containers product shape, not a CI runner; it will not carry heavy CI or long-running containers. And cluster mode — the Durable Object replacement — **landed on main three commits *after* the newest release**, is gated behind `--experimental`, cannot do alarms, and acknowledges every write only after two synchronous round trips to the S3 bucket. It is the first 8.6k-line slice of a port of `denoland/celld` into workerd, by celld's own author. If you want self-hosted DOs today, celld is the complete artefact; workerd's cluster is a fragment of it inside a vendor's monorepo.

## What it actually is

The README sells three things: an application server, a dev tool, and a programmable HTTP proxy. All three are true, and the first one is understated — this is not a reimplementation, it is the same code Cloudflare runs (`README.md:1-3`).

What the README does not say, and the source does:

- **It is a single process with no supervisor, no metrics endpoint, no health check.** Grepping `src/workerd/server/server/*.rs` for `prometheus`, `/metrics`, `health`, `readiness`, `liveness` returns nothing. The only lifecycle signal is SIGTERM → drain (`src/workerd/server/server/entry.rs:200-218`, `src/workerd/server/server/run.rs:388-440`). Observability is JSON logs (`src/workerd/server/json-logger.c++`) and tail workers.
- **It is config-file-driven, not API-driven.** The config is Cap'n Proto text (`src/workerd/server/workerd.capnp`, 57 KB of schema + comments), compiled at startup by `config-compiler.c++` into an encoded message. There is no admin API to add a worker, change a binding, or move a namespace. A change means a new config and a process restart, or `workerd compile` baking config + code into a self-contained binary (`src/workerd/server/cli/lib.rs:80-100, 196-225`).
- **It is not a sandbox.** `README.md:32`: "`workerd` tries to isolate each Worker… However, `workerd` on its own does not contain suitable defense-in-depth… you must run it inside an appropriate secure sandbox, such as a virtual machine." Cloudflare's production isolation is not in this repo.
- **"Always backwards compatible" is about JavaScript, not about you.** The version number is a date equal to the max supported compatibility date (`README.md:38-40`); the guarantee covers Worker JS APIs via `compatibility-date.capnp`. It does not cover the config schema, the on-disk DO format, or the cluster bucket protocol.

Size, measured on the tree at `cd6298ea` (2026-10-29): 703 C++/header files = 316,968 lines; 446 Rust files = 117,604 lines; 299 TypeScript files = 87,525 lines. 434,572 lines of C++/Rust alone. The shipped Linux x64 binary is **148,776,325 bytes** unpacked.

## Architecture (with file paths)

**Entry and lifecycle.** `src/workerd/server/workerd.rs` (3 lines) → `cli/lib.rs::main` → `server/entry.rs` → `server/run.rs`. Three Rust crates sit on a C++ core: `cli/`, `server/`, `factory/` (`src/workerd/server/AGENTS.md:5-12`). The server owns config interpretation, bindings, listeners, actor lifecycle, drain; the factory owns everything that touches the isolate (V8, modules, actors, storage, alarms, containers, capnp RPC).

**Services and sockets.** Four service kinds — `worker`, `network`, `external`, `disk` (`workerd.capnp:262-296`). Sockets can be `http`, `https`, `tcp`, `udp` (`workerd.capnp:205-247`), including `unix:` and `unix-abstract:` addresses. `ExternalServer` (`workerd.capnp:953-1010`) is a plain reverse proxy to one backend over http/https/tcp. `Network` (`workerd.capnp:1011-1055`) is a CIDR allow/deny list, default `["public"]` — i.e. SSRF protection is on by default and internal access is opt-in.

**Durable Objects outside Cloudflare.** Yes, with three storage backends (`workerd.capnp:852-886`):

- `none` — no DOs.
- `inMemory` — process lifetime only.
- `localDisk` — a `DiskDirectory` service; **marked `** EXPERIMENTAL; SUBJECT TO BACKWARDS-INCOMPATIBLE CHANGE **`** at `workerd.capnp:869-886`. Layout is `<class>/<id>.sqlite` plus `-wal`/`-shm`.

There is no "Durable Object service" to connect to — DOs run in-process. What is *missing* relative to production is: no alarms in cluster mode, and no object-to-object placement. `preventEviction` and `enableSql` exist per namespace (`workerd.capnp:781-794`), and the note "this is only supported in Workerd; production Durable Objects cannot toggle eviction" tells you which side is the test rig.

**Cluster mode (`Config.cluster`).** `workerd.capnp:98-159`; implementation `src/workerd/server/cluster/` (14 files, 4,936 lines) driven by `src/workerd/server/server/cluster.rs` (542 lines) and wired in `server/config.rs:1068-1105, 1513-1531`.

- Shared state is an S3-compatible bucket under `v1/` (`cluster/lib.rs:6-26`). Membership: `nodes/<node>.json` with a lease. Ownership: `do/<ns>/<actor>/own.json` with an epoch. Data: `do/<ns>/<actor>/{log,snapshot}/<epoch>/…`.
- Rust is split so the decisions are testable: `cluster/logic/lease.rs` is pure, `cluster-logic` has no I/O deps (`AGENTS.md:10`).
- Fencing rests on conditional writes. At startup the node **probes** the bucket with `If-None-Match: *` and `If-Match: "0"` and refuses to start if the store ignores them (`cluster/cluster.rs:330-347`). The comment names the failure: "GCS's S3 API, for one, ignores `If-Match` on a PUT."
- SigV4 is hand-rolled in `cluster/s3.rs:224-320` (path-style, `UNSIGNED-PAYLOAD`, 429/503 retried with 250 ms→2 s backoff at `s3.rs:224-245`).
- Log format is Cap'n Proto frames of SQLite pages, "the storage relay's (SRS's), field for field" (`cluster/frames.capnp:6-10`).
- Peer transport is **HTTP/1.1 `CONNECT` with a MAC**, then a Cap'n Proto `WorkerdDebugPort` session (`server/cluster.rs:1-11, 280-300`). Auth header `cf-cluster-auth: <ms>.<nonce>.<mac>`, 30 s window, nonce replay cache (`server/cluster.rs:49-53, 352-385`). **Traffic is not encrypted** (`workerd.capnp:133-137`). Holders of the key get the debug port, i.e. full access to every service in the process.
- A public bind address is refused unless `unsafePublicAddress` (`server/cluster.rs:149-176`).

**Containers (`ctx.container`).** `workerd.capnp:795-838` (namespace `container` options), `workerd.capnp:894-902` (`containerEngine = localDocker`), `src/workerd/api/container.h/.c++`, `src/workerd/server/container-client.c++` (3,230 lines) + `docker-api.capnp` (414 lines) + `src/workerd/io/container.capnp` (327 lines).

- `ctx.container` is a **DurableObjectState** property (`src/workerd/api/actor-state.h:760`, `getContainer` at `:655`). No DO, no container.
- The backend is **only** the local Docker daemon: `KJ_REQUIRE(engine.isLocalDocker(), "dockerPath must be defined to enable containers on this Durable Object.")` (`src/workerd/server/factory/worker-factory-actor.c++:473-474`). There is no containerd, CRI, Kubernetes, or remote-runtime backend in the tree.
- `containerEgressInterceptorImage` is **mandatory** (`worker-factory-actor.c++:487-489`), and every container gets its own sidecar container `<name>-proxy` with `NET_ADMIN` for iptables/TPROXY (`container-client.c++:2267-2270`), ingress on port **39001** (`container-client.c++:46`), and `publishAllPorts(true)`.
- The sidecar's DNS is **hardcoded to 1.1.1.1 and 8.8.8.8** (`container-client.c++:48-51`).
- Container `HostConfig` sets `RestartPolicy: on-failure`, `NetworkMode: container:<sidecar>`, and `PidMode: host` unless the `containers_pid_namespace` flag is on (`container-client.c++:1938-1951`; flag auto-enables at compat date 2026-04-01, `compatibility-date.capnp:1403-1407`).
- The JS API surface is real and good: `start`, `monitor`, `destroy`, `signal`, `getTcpPort`, `setInactivityTimeout`, `interceptOutboundHttp/Https/Tcp`, `snapshotContainer`, `snapshotDirectory`, `exec` (with PTY, streams, exit codes), `inspect`, `setLabels` (`src/workerd/api/container.h:334-395`).

**Which bindings are HTTP shims you must implement yourself.** This is the single most important practical fact for this study. In `workerd.capnp:465-610`:

| binding | line | what it really is |
|---|---|---|
| `service` | 509 | in-process channel to another service. Real. |
| `durableObjectNamespace` | 516 | in-process DO namespace. Real. |
| **`kvNamespace`** | 524 | "Requests to the namespace will be converted into HTTP requests targeting the given service name." **You implement KV.** |
| **`r2Bucket`** | 529 | "Similar to KV namespaces, this turns operations into HTTP requests aimed at the named service." **You implement R2.** |
| **`queue`** | 538 | "Requests… converted into HTTP requests targeting the given service name." **You implement Queues.** |
| **`analyticsEngine`** | 549 | "workerd will forward AnalyticsEngineEvents to designated service in the body of HTTP requests." **You implement it.** |
| `workerLoader` | 578 | dynamic workers; `--experimental` only |
| `unsafeEval`, `workerdDebugPort` | 564, 601 | `--experimental` only (`server/bindings.rs:460-497`) |

The shim mechanism is `KvNamespace` holding a subrequest channel and calling `context.getHttpClient(channel, …)` (`src/workerd/api/kv.c++:93-120`, call sites at `:226, :405, :535, :669, :731`); `R2Bucket` does the same (`src/workerd/api/r2-bucket.c++:43-50`). **The wire protocol those shims speak is Cloudflare-internal** — nothing in this repo documents it, and no open-source server implements it. If your design uses `env.KV` or `env.MY_BUCKET`, you are writing that protocol by hand and reverse-engineering it.

## The seam into this design

**Where it plugs in cleanly — the edge runtime slot.** workerd is the Workers runtime; a dashboard on Cloudflare Workers can emit either a `.capnp` config or the restricted `wrangler.jsonc` subset that `workerd serve` accepts (`src/workerd/server/cli/wrangler.rs:1-12`: `name`, `main`, `compatibility_date`, `compatibility_flags`, `vars`, `durable_objects`, `migrations`, `no_bundle`, `$schema`, anything else is an error). `workerd compile` then bakes config + code into one binary, so a machine's runtime is a single immutable artefact. Service bindings give you capability-scoped internal calls with no network hop (`README.md:20-26`), which is the right shape for a fleet of small internal services.

**Where it plugs in for coordination — the cluster port over Mesh, and this is a genuinely good fit.** The peer port refuses public IPs, and its definition of "not public" is `a == 100 && (64..128).contains(&b)` — i.e. it treats **100.64.0.0/10 as local** (`server/cluster.rs:155-176`). Cloudflare Mesh assigns every participant an address from **100.96.0.0/12**, which falls inside that range. So the cluster port works over Mesh **without** setting `unsafePublicAddress`, and without any config change. That is the one place where this repo's defaults line up with your network design.

**The seam that will not work: Cloudflare Tunnel cannot carry the cluster port.** The docs are explicit that a `cloudflared` tunnel is outbound-only and "Server-initiated requests (from applications behind the tunnel) use the server's default routing table and do not pass through the tunnel." The cluster is node-to-node, server-initiated TCP dials (`server/cluster.rs:280-300`). Mesh is bidirectional L3/L4 and is the only one of your three transports that can carry it. Workers VPC is for Workers reaching *into* a private network, which is the wrong direction for peer membership.

**The seam that will not work: heavy CI and long-running containers.** See below — this is the decisive mismatch.

## Limits and failure modes

**Cluster mode is not released.** PR #7994 merged 2026-10-29T03:11:43Z. The newest release, `v1.20261029.1`, was tagged from `c8227661` at 2026-10-29T00:53:29Z. GitHub's compare API reports `c8227661...aa494794` as **ahead_by: 3, behind_by: 0** — the cluster code is three commits *after* the release commit. So `npx workerd` today has **no cluster mode at all**. You would be building on `main`, or building Bazel from source.

**Every commit costs two bucket round trips.** `Cluster::sync_actor` → `Owners::commit` waits until `acked >= target`; `push` uploads the batch (`PUT`), then re-reads `own.json` to confirm the epoch still names this node (`cluster/owner.rs:312-359`, `ownership.rs:300-305`). The PR body says it plainly: "an object acknowledges a write only once it is fully synced to the bucket; that is much too slow and expensive for most uses." Over Mesh + R2 that is WAN latency twice per write transaction, plus the upload. celld has a cheaper path (replicate to one or two peers, ack on their disks, bucket later); workerd's cluster does not implement it.

**No alarms in cluster mode.** PR body: "Alarms are not supported yet." If your coordination layer uses `setAlarm`, it does not work here.

**Restart costs up to 20 s of unavailability per object.** Node identity is 16 fresh random bytes per process (`server/cluster.rs:203-210`, `cluster/registry.rs:21-22`). A restarted node's old record still holds a lease, so objects it owned are only taken over once that lease expires — `LEASE_MS = 20_000` (`cluster/logic/lease.rs:12-14`). Graceful SIGTERM calls `start_draining()` + `deregister()` and avoids this (`server/run.rs:405-425`); SIGKILL, OOM, or a container kill does not.

**The node fences itself and stops serving on:** clock skew > `MAX_SKEW_MS = 2_000` ms against the bucket, or a lease that lapsed before it could be renewed (`cluster/logic/lease.rs:17-70`). Renewal cadence is 3 s, bounded at 4 s, retried at 1 s (`lease.rs:14-20`). The comment records a real incident: "R2 stalls writes ~5.5 s at every 5-minute mark; a 2 s bound cancelled them and fenced every node."

**No local disk adoption.** "The bucket's copy of an object replaces the instance's, so a `localDisk` already holding Durable Objects from before cluster mode is refused at startup; they are not imported" (`workerd.capnp:110-113`). And "A local copy is never authoritative at takeover: every acknowledged commit is in the bucket" (`cluster/owner.rs:658-659`).

**Containers: the failure modes are the design.** Concretely:

1. **No resource limits.** `instance: "standard-4"` or `{vcpu, memoryMib, diskMb}` is parsed and validated (`src/workerd/api/container.c++:404-428`) and sent over RPC, but `container-client.c++` never calls `setMemory`, `setNanoCpus`, `setCpuShares`, or `setPidsLimit` — I grepped; there are zero hits. A CI job asking for 2 vCPU and 4 GiB gets whatever Docker gives it. This alone disqualifies it as a CI substrate.
2. **The supervising DO is evicted after 10 s of inactivity**, and the container's namespace entry is dropped after 70 s with no clients (`src/workerd/server/server/actor.rs:67-70`, `take_expired` at `:276-291`, `cleanup_loop` at `:294-306`). Long-running work needs `preventEviction` or a live client forever.
3. **`container.capnp:11-14`**: "When the actor shuts down, workerd will drop the `Container` capability, at which point the container engine should implicitly destroy the container." The container's lifetime is the DO's lifetime.
4. **Two containers per container.** Application container + `-proxy` sidecar with `NET_ADMIN`, per container, each publishing a host port. 50 CI jobs = 100 containers and 50 host ports.
5. **Hardcoded public DNS** (1.1.1.1, 8.8.8.8) in the sidecar. In an air-gapped or split-horizon environment, egress interception silently misresolves.
6. **`enableInternet` defaults to `false`** (`container.capnp:28`), so egress only happens through `interceptOutbound*` bindings back into a Worker — fine for a product, awkward for a CI job that needs to `npm install`.
7. **Docker only.** No Podman/containerd/CRI contract; the client speaks the Docker Engine JSON API over a unix socket (`container-client.c++:1978-1992`). Podman's compat socket will probably work and is entirely untested here.
8. **No scheduler.** There is no queue, no placement, no autoscaling, no retry policy, no job model. A DO *is* your scheduler, and it is single-threaded.

**Operational shape.** One process, one event loop (`kj_rs_tokio::Runtime`, `AGENTS.md:9`). Ports per node: N configured sockets, one cluster port, optional `--debug-port`, plus one published host port per container sidecar and the Docker socket. Moving parts per machine: the 149 MB binary, a config, a bucket, a Docker daemon, the `cloudflare/proxy-everything` image, and a supervisor. No official container image is published — the release workflow only `npm publish`es (``.github/workflows/release.yml:199, 295, 326`); `Dockerfile.release` exists but is a build recipe, not a distribution channel.

**Build cost.** Bazel + a downloaded LLVM 22 toolchain + a Debian sysroot (`README.md:60-75`, `Dockerfile.release`), V8 **15.7.112.5** with ~40 carried patches (`build/deps/v8.MODULE.bazel:25-70`), a patched SQLite with 7 patches (`MODULE.bazel:5-29`), and 345 Rust crates in the lock (64 direct, `deps/rust/Cargo.toml`). Cross-compiling this yourself is a project. Use the npm binaries and pin the version.

## Licence and governance

**Apache-2.0, clean.** `LICENSE` is the unmodified Apache 2.0 text; there is no `NOTICE` file and no additional-terms rider. npm metadata for `@cloudflare/workerd-linux-64@1.20261029.1` reports `"license":"Apache-2.0"` and is published with SLSA provenance attestations by GitHub Actions OIDC. No open-core split, no BSL, no Commons Clause, no field-of-use restriction. Nothing here stops you from running it commercially or shipping a modified binary.

**Contributions require a Cloudflare CLA** (`.github/workflows/cla.yml`, pointing at `https://www.cloudflare.com/cla/`). Irrelevant to you as a consumer, but it tells you who owns the copyright: Cloudflare, essentially entirely. There is no foundation, no governance body, no roadmap you can influence.

**This is a vendor's trunk branch, published.** `CONTRIBUTING.md:11`: "This repository is the canonical source code for the core of Cloudflare Workers. The Workers team actively does their development in this repository. Any changes landed in the main branch will automatically become available on the Cloudflare Workers Platform typically within a week or two." And `CONTRIBUTING.md:13`: the backwards-compatibility commitment means "we are cautious about what we add… For non-trivial changes, always post an issue or discussion before you write code… we set an extremely high bar for new APIs that are not defined by standards."

Consequences you should price in: (a) the config schema, the cluster bucket format and the container API are **not** covered by the JS backwards-compatibility promise — the cluster format is explicitly versioned `v1` in the bucket prefix precisely so a later format can tell an old bucket apart (`cluster/lib.rs:8-10`, `FORMAT` at `cluster/cluster.rs:33-34`); (b) features can be changed or removed while experimental — `--experimental` is required for cluster mode (`server/config.rs:1520-1523`) and for `workerLoader`/`unsafeEval`/`debugPort`/`analyticsEngine` (`server/bindings.rs:454-497`); (c) your priorities are not the roadmap's.

**Not a single-maintainer risk.** ~100 contributors in the top-100 list; top committer 2,824 commits, then 977, 871, 793, 564, 561, 554, 459. In the last 100 commits: 25 by James M Snell, 14 Dan Lapid, 10 Nathan Whitaker, 10 Nicholas Paun, 8 Gyeongjae Choi. 9,093 stars, 810 forks. Daily releases. Bus factor is Cloudflare's staffing, which is high — and also means the project's direction is Cloudflare's product decisions, not yours.

The abandoned-project risk is essentially zero. The *divergence* risk is real: this is a monorepo where the cluster feature is one day old and the container feature is tuned for a product you are not buying.

## Verified facts

| claim | value | source |
|---|---|---|
| Licence | Apache-2.0, unmodified text, no NOTICE file | `LICENSE` (read); https://github.com/cloudflare/workerd/blob/main/LICENSE |
| npm licence field | `Apache-2.0`, with SLSA provenance | https://registry.npmjs.org/@cloudflare/workerd-linux-64/latest |
| Linux x64 binary size | 148,776,325 bytes unpacked, 3 files | https://registry.npmjs.org/@cloudflare/workerd-linux-64/latest |
| Latest release | v1.20261029.1, published 2026-10-29T00:53:29Z | https://github.com/cloudflare/workerd/releases |
| Release cadence | daily (…1025.1, 1026.1, 1027.1, 1028.1, 1029.1) | https://github.com/cloudflare/workerd/releases |
| Cluster code in the latest release? | **No** — release commit `c8227661`; cluster commit `aa494794` is `ahead_by: 3, behind_by: 0` | https://api.github.com/repos/cloudflare/workerd/compare/c82276613b30e6f1a9b5b28067318c5201dc7956...aa494794 |
| Cluster PR | #7994 "Cluster workerd processes over a shared bucket", merged 2026-10-29T03:11:43Z, 57 files, +8,599/−64, authored by Ryan Dahl | https://github.com/cloudflare/workerd/pull/7994 |
| Cluster PR caveats | "beginning of merging celld's functionality into workerd"; "acknowledges a write only once it is fully synced to the bucket; that is much too slow and expensive for most uses"; "Alarms are not supported yet" | https://github.com/cloudflare/workerd/pull/7994 |
| Stars / forks / open issues | 9,093 / 810 / 826 | https://api.github.com/repos/cloudflare/workerd |
| Repo created / last push | 2022-09-15 / 2026-10-29T11:30:04Z | https://api.github.com/repos/cloudflare/workerd |
| V8 version | 15.7.112.5, ~40 local patches | `build/deps/v8.MODULE.bazel:25-70` |
| Rust dependency count | 345 crates resolved, 64 direct | `deps/rust/cargo-bazel-lock.json`, `deps/rust/Cargo.toml` |
| Cluster source size | 14 files, 4,936 lines | `src/workerd/server/cluster/` |
| Lease timings | lease 20 s; renew every 3 s, timeout 4 s, list timeout 2 s, retry 1 s; max clock skew 2 s | `src/workerd/server/cluster/logic/lease.rs:12-30` |
| Cluster needs `--experimental` and a ≥32-byte key | enforced at config time | `src/workerd/server/server/config.rs:1520-1529` |
| Cluster traffic unencrypted | "its traffic is not encrypted: only the cluster's instances should reach it, on a private network" | `src/workerd/server/workerd.capnp:133-137` |
| Bucket must support atomic conditional PUT | startup probe with `If-None-Match:*` / `If-Match`, else refuse to start | `src/workerd/server/cluster/cluster.rs:330-347` |
| R2 S3 API supports conditional PutObject | `If-Match` ✅, `If-None-Match` ✅, evaluated atomically | https://developers.cloudflare.com/r2/api/s3/api/ |
| Cloudflare Mesh address range | 100.96.0.0/12, bidirectional, any participant can initiate | https://developers.cloudflare.com/mesh/concepts/ |
| workerd treats 100.64.0.0/10 as non-public | `a == 100 && (64..128).contains(&b)` → allowed without `unsafePublicAddress` | `src/workerd/server/server/cluster.rs:155-176` |
| Cloudflare Tunnel is outbound-only | "Server-initiated requests… do not pass through the tunnel" | https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/private-net/cloudflared/ |
| Containers require the local Docker daemon | `KJ_REQUIRE(engine.isLocalDocker(), …)` | `src/workerd/server/factory/worker-factory-actor.c++:473-474` |
| Egress interceptor image is mandatory | `KJ_REQUIRE(docker.hasContainerEgressInterceptorImage(), …)` | `src/workerd/server/factory/worker-factory-actor.c++:487-489` |
| Sidecar DNS hardcoded | `1.1.1.1`, `8.8.8.8`; ingress port 39001; `NET_ADMIN` | `src/workerd/server/container-client.c++:46-51, 2267-2270` |
| Container resource limits not applied | no `setMemory` / `setNanoCpus` / `setCpuShares` / `setPidsLimit` in the Docker client | `src/workerd/server/container-client.c++` (grep) |
| DO idle eviction / container expiry | 10 s idle shutdown, 70 s container expiration | `src/workerd/server/server/actor.rs:67-70` |
| `ctx.container` lives on DurableObjectState | `JSG_LAZY_INSTANCE_PROPERTY(container, getContainer)` | `src/workerd/api/actor-state.h:760` |
| KV/R2/Queue/AnalyticsEngine are HTTP shims | "converted into HTTP requests targeting the given service name" | `src/workerd/server/workerd.capnp:524, 529, 538, 549` |
| Not a hardened sandbox | "does not contain suitable defense-in-depth… run it inside an appropriate secure sandbox, such as a virtual machine" | `README.md:32-38` |
| Vendor trunk branch | "canonical source code for the core of Cloudflare Workers… changes landed in main… available on the Cloudflare Workers Platform typically within a week or two" | `CONTRIBUTING.md:11` |
| CLA required | Cloudflare CLA via CLA Assistant | `.github/workflows/cla.yml`; https://www.cloudflare.com/cla/ |
| No published container image | release workflow only runs `npm publish` | `.github/workflows/release.yml:199, 295, 326` |
| Relationship to celld | celld is `denoland/celld`, Apache-2.0, "self-hosted, distributed Durable Objects"; workerd's cluster is "the beginning of merging celld's functionality into workerd" | https://github.com/denoland/celld ; https://github.com/cloudflare/workerd/pull/7994 |
| celld feature surface (for contrast) | KV, Queues, D1, R2, Workflows, Cron, static assets, containers, sandboxes — none of which workerd's cluster implements | https://github.com/denoland/celld (README) |

## Rejected / not for this

- **workerd as the CI / long-running-container substrate. Rejected.** The container model is one Docker container supervised by one Durable Object, with no CPU/memory enforcement, a `NET_ADMIN` sidecar per container, hardcoded public DNS, and a 10 s idle eviction of the supervisor. Heavy CI needs cgroups limits, a job queue, placement, retry, log shipping, and a runtime that does not need to be re-adopted by a stateful actor. workerd gives you none of those; it gives you a `ctx.container.exec()` API. The right shape for that slot is an actual container orchestrator (Kubernetes/Nomad) or a purpose-built runner — which is also what your "orchestration is not Cloudflare" constraint implies.
- **`ctx.container` as a Sandbox replacement. Rejected.** Cloudflare Sandbox is a container-per-sandbox product; here you get the primitives (`exec` with PTY, `snapshotDirectory`, `getTcpPort`) but the isolation story is Docker's, not Cloudflare's, and the DO lifecycle owns the container's life. celld implements the `@cloudflare/sandbox` and `@cloudflare/containers` shapes; workerd's tree does not.
- **The KV / R2 / Queue / AnalyticsEngine bindings as drop-in replacements. Rejected as-is.** They are HTTP shims to an undocumented, Cloudflare-internal wire protocol. Use `service` bindings and a Worker that speaks a protocol you own, or use `ExternalServer`/`Network` to reach a real MinIO/Garage/whatever directly. Do not expect `env.KV` to work.
- **Cluster mode as production coordination *today*. Deferred, not rejected.** It is a genuine, well-tested design (there is a 1,197-line integration test with a fake S3 written as a Worker, `src/workerd/server/tests/cluster/`) and it will get better fast. But it is unreleased, alarm-less, and two bucket round trips per write. Re-evaluate when alarms land and it ships in a tagged release.
- **`inMemory` DOs for anything durable. Rejected.** Process-lifetime only (`workerd.capnp:860-866`).
- **The `--watch` dev loop, `workerd test`, `workerd bench`, `fuzzilli`. Not for this.** Fine tools, wrong slot.

## Open questions

1. **What is the actual p99 of one DO write transaction in cluster mode** over Mesh + R2 versus over a local MinIO? The code says PUT + GET of `own.json` per ack (`cluster/owner.rs:312-359`). If that is 80 ms, the coordination layer is unusable for anything interactive. Measure before designing around it.
2. **Does `check_conditional_writes` pass against your chosen bucket?** It refuses GCS's S3 API by name. Verify against R2 and against whatever you run for object storage — this is a startup-blocking check, not a warning.
3. **Will the cluster bucket format stay `v1`?** `frames.capnp` is deliberately wire-compatible with Cloudflare's internal SRS. If Cloudflare revs it, your bucket needs migration and there is no migration tool in this tree.
4. **Can the sidecar's hardcoded DNS (1.1.1.1/8.8.8.8) be changed without patching?** I found no config field for it. If your machines have no public DNS, every container egress interception is broken until you fork.
5. **Is `localDocker` the intended production backend or a dev convenience?** `workerd.capnp:896-898` says "Only used for local development and testing purposes." Nothing else exists in the tree. That sentence should be read as: Cloudflare's production container backend is not in this repo.
6. **What replaces the missing supervisor?** There is no health endpoint and no readiness signal. Whatever supervises workerd must infer liveness from logs or from a socket. Worth designing explicitly.
7. **Does the `preventEviction` + `setInactivityTimeout` combination actually keep a DO (and its container) alive indefinitely under load?** `preventEviction` is documented as Workerd-only (`workerd.capnp:781-787`) and cluster mode's drain aborts all clustered objects regardless of it (`server/run.rs:405-425`). Test it.
8. **Does the user need DOs at all, or only the Workers runtime?** If the coordination slot can be satisfied by Postgres/etcd/NATS, workerd becomes a much simpler proposition: a stateless edge runtime with `service` bindings, no bucket, no cluster port, no experimental flags. That is the version of this I would ship.
