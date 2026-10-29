# 03 — Workloads

Three isolation levels. Pick by **whose code it is**, not by convenience.

| Level | Runtime | Isolation | Start | Use for |
|---|---|---|---|---|
| Workers | `workerd` child process | V8 isolate | ~5 ms | your own Workers apps |
| Container | containerd / Docker | namespaces + cgroups | ~200 ms | your own services, CI on your code |
| microVM | Firecracker | separate kernel | ~125 ms | untrusted code: dependencies' install scripts, pull requests, agents |

**Rule: anything you did not write runs in a microVM.** A CI job that runs `npm install` runs
code from strangers. So does an agent that writes and executes programs.

---

## Workers

`workerd` runs as a child process of the agent, one per application.

```
cfbd ──spawn──▶ workerd serve /var/lib/cfbd/apps/<app>/config.capnp
```

- `workerd` is the actual runtime Cloudflare uses: Apache-2.0, actively developed, correct
  semantics.
- A Workers app is deployed as a bundle plus a generated `config.capnp`. The control plane
  builds it (`wrangler deploy --dry-run --outdir`), uploads it, and tells the agent to swap it.
- Config changes are a process restart, which is a ~5 ms gap. Acceptable for a Workers app;
  not acceptable for a long-lived socket-heavy service, which should use hibernation and
  reconnect anyway.

### When you need Durable Objects

`workerd` alone gives single-node DOs with no durable backend. Two options:

| Option | When |
|---|---|
| **celld** | you need KV, Queues, D1, Workflows and DOs from an unmodified `wrangler.json`, on a fleet |
| **workerd + your own DO storage** | you need one app on one node and can accept single-node durability |

celld is Apache-2.0, 6,169 stars, v0.6.3, two contributors. It requires an object store with
**conditional writes, exact ranged reads and read-after-write consistency** — S3, R2, GCS,
Azure, Tigris and SeaweedFS qualify; Garage, B2, Hetzner and DO Spaces do not, and will
split-brain silently.

It also runs **one application per fleet**. Multi-app means one fleet per app, each with its
own bucket. Budget for that before promising "we'll host all our Workers internally".

If you do not need DOs, do not run celld. `workerd` is the smaller, better-maintained
dependency.

---

## Containers

The agent speaks **one client: the Docker Engine API** — HTTP/JSON over a unix socket. Probe
order at startup, first hit wins:

1. `/var/run/docker.sock`
2. `$XDG_RUNTIME_DIR/podman/podman.sock`, then `/run/podman/podman.sock`
3. systemd transient units via `StartTransientUnit`
4. `fork/exec` plus cgroup v2 files

Podman's compat API reuses the Docker paths, so **Podman is a socket path, not a code path**.
The client is `net/http` and `encoding/json` in Go, or a unix stream and `serde_json` in Rust:
no gRPC, no protobuf, no codegen.

### Why not containerd first

Containerd's CRI is the *largest* surface of the options, not the smallest: ~34 RPCs on
`RuntimeService`, a mandatory `RunPodSandbox` before any `CreateContainer`, a pause image that
must be pulled first, logs written to a directory the caller supplies and tails, and **no
restart-policy field anywhere in the proto** — the kubelet owns restarts. Choosing it first
costs the most code for the fewest free features.

| Runtime | Free | Missing |
|---|---|---|
| Docker / Podman API | create, start, logs, exec, `RestartPolicy`, `Memory`, `NanoCpus`, `PidsLimit`, image pull | nothing that matters |
| containerd CRI | pull, exec, resource update, stats | restart policy, log API, one-call "run this image" |
| systemd transient | cgroup limits, `Restart=`, journald | image pull, namespace isolation, **exec** |
| fork/exec + cgroup v2 | nothing | everything |

Exec is the discriminator: Docker, Podman and containerd expose it, systemd does not, and
Firecracker needs a guest agent.

What the agent gets from the runtime: image pull, cgroup limits, restart, log capture, exec.
What it implements itself: desired-state reconciliation, port allocation, artifact upload, and
the job lifecycle.

### The CI job

```
spec = {
  image:  "registry/app/ci:sha-...",
  cpu:    4000,             # millicores
  memory: 8192,             # MiB
  timeout: 2700,            # seconds
  mounts: [{from: "cache/<project>", to: "/cache"}],
  env:    {...},
}
```

The agent starts the container, streams logs to the control plane, and on exit uploads
`/workspace/artifacts` to storage using a presigned URL it generated locally. The control
plane never sees the bytes.

---

## microVMs

Firecracker, when the code is not yours.

What the agent does:

1. Resolve the image to a cached ext4 rootfs (content-addressed by digest).
2. Allocate a slot: a tap device, a `/30` from a per-node `/16`, and an nftables ruleset.
3. Boot the VM with the jailer: seccomp filter, cgroup limits, chroot, dedicated uid/gid.
4. Stream the console to the job log.
5. On exit, tear down the slot and GC the rootfs.

What the agent does **not** do: give the VM a route to anything except a node-local
pull-through proxy on one port. The proxy holds the storage credentials; the VM never sees
them, and the VM's prefix is enforced there.

Firecracker does no traffic filtering of its own — the nftables rule is the boundary, and it
must be written per slot, not per node.

---

## Comparing to Cloudflare Containers

Cloudflare Containers are not disqualified by price. They are disqualified by three properties:

| Property | Cloudflare | This design |
|---|---|---|
| Instance ceiling | 4 vCPU / 12 GiB / 20 GB | whatever the node has |
| Image storage | 50 GB per account | the node's disk |
| Interruption | "does not guarantee that any container instance will run for a set period" | the node is yours; it runs until you stop it |
| Disk | ephemeral, fresh from the image each start | volume mounts |

Note the first row is raisable on request, and there is no fixed maximum runtime — the default
`Container` class sleeps after 10 minutes of inactivity and `setInactivityTimeout()` goes to
6 hours. A long build is possible with an alarm. It is the interruption model and the image
budget that make it a poor fit for CI, not a hard limit.

---

## Scheduling

There is no scheduler. The control plane places a workload on a node by filtering and sorting:

```
candidates = nodes with the required capability and free capacity
chosen     = the candidate with the most free memory
```

That is the whole algorithm. It is correct for CI and long-running services at fleet sizes
below a few hundred nodes, and it is one query against D1 rather than a second control plane.

Add a real scheduler when you have gang scheduling, heterogeneous GPU classes, or preemption
requirements. Until then, the filter-and-sort is not the bottleneck — the build is.
