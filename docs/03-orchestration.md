# 03 — Orchestration: Nomad and Incus

Two layers, because provisioning and scheduling are different jobs and no single tool does
both well.

| Layer | Tool | Job |
|---|---|---|
| Machine | **Incus** (or Proxmox VE) | create a VM or system container, cloud-init it, hand it over |
| Workload | **Nomad** | place jobs on nodes, restart them, drain nodes, run batch work |

Nomad creates zero machines. That is not a defect, it is the boundary. If you try to make
Nomad provision hosts you will end up with a shell script and a `raw_exec` job, and you will
have reinvented a worse Incus.

---

## Why Nomad

### The case for

- **One binary.** Server and client are the same 100 MB static Go binary. Raft and a BoltDB
  client store are compiled in (`nomad/server.go` `setupRaft`, `client/client.go`
  `restoreState`). No etcd, no Consul, no ZooKeeper, no external database.
- **The job model matches the workload.** `service` for long-running containers, `batch`
  for run-to-completion, `system` for one-per-node daemons, `sysbatch` for one-shot
  per-node tasks. That is exactly the four shapes this design needs, with no CRDs.
- **Parameterized dispatch.** One job spec, many invocations with a payload. This is a CI
  trigger with zero extra machinery, and it caps payloads at 16 KiB which is the right
  pressure — put the big thing in object storage and pass a reference.
- **One port.** Everything a dashboard needs is on 4646. Crucially, the servers proxy
  `/v1/client/fs/logs` and `/v1/client/allocation/<id>/exec`, so you never expose 4647
  (RPC) or 4648 (gossip) through the tunnel.
- **Rescheduling and draining** are built in, including node eligibility, which is what
  "drain this node before maintenance" actually needs.

### The case against, stated honestly

- **BUSL-1.1.** Not open source in the OSI sense. Internal use is granted; offering it as a
  hosted service that competes with Nomad Enterprise is not. If this platform is a product
  you sell, read the licence before you build on it. The last MPL releases were v1.6.4 through v1.6.10; the BUSL change is scoped to "Nomad Version 1.7.0 or later", so pinning 1.6.3 for licence reasons means missing seven patch releases of security fixes. Pin v1.6.10.
- **No multi-tenancy.** Resource quotas are a no-op in the free build
  (`nomad/plan_apply_ce.go`). Namespaces exist but they are not a security boundary.
- **It is not a sandbox.** cgroups and chroot, not a microVM. Untrusted code needs
  Firecracker underneath (see [`04-compute.md`](04-compute.md)).
- **Blocking queries default to 300 s**, longer than Cloudflare's 125 s proxy read timeout.
  Set `?wait=60s` or you will get truncated responses through the tunnel.
- **CORS is missing on most routes.** The browser cannot call Nomad directly; it must go
  through the Worker. This is fine — it is the design — but it means the Worker is not
  optional.

### Configuration that matters

```hcl
# server.hcl — one of three
server {
  enabled          = true
  bootstrap_expect = 3
  raft_protocol    = 3
}
advertise {
  http = "10.96.0.11"   # overlay address, NOT a Cloudflare address
  rpc  = "10.96.0.11"
  serf = "10.96.0.11"
}
```

```hcl
# client.hcl
client {
  enabled = true
  servers = ["10.96.0.11:4647", "10.96.0.12:4647", "10.96.0.13:4647"]
  host_volume "build-cache" { path = "/srv/build-cache" }
}
plugin "docker" { config { allow_privileged = false } }
```

Advertise on the overlay, always. If a node advertises a Cloudflare-reachable address the
Raft traffic will try to route through Cloudflare and you will have built the exact thing
this design exists to avoid.

---

## Why Incus for the machine layer

- One daemon, one REST API, real VMs **and** system containers behind the same object model.
- Projects with hard quota limits — the only place in this stack where quotas actually work.
- Profiles for templating, so "2 vCPU / 4 GiB / 40 GiB / ubuntu-24.04" is one object.
- Raft-replicated control plane across cluster members.
- Apache-2.0, no CLA, 7.0 LTS supported to June 2031.

### The three sharp edges

Documented in full in [`../landscape/08-incus.md`](../landscape/08-incus.md):

1. **mTLS does not survive the tunnel.** `cloudflared` has no client-certificate origin
   option, so Incus sees every request as untrusted. Your options are OIDC (which needs
   OpenFGA for role mapping) or the `tls_jwt` cookie (which is `SameSite=Strict` with a
   `Sec-Fetch-Site` guard, so dashboard and API must share an origin).
2. **Client IP is unrecoverable.** Incus reads `r.RemoteAddr` only; there is no
   `X-Forwarded-For` support anywhere in the tree. Its only mechanism is the PROXY protocol,
   which `cloudflared` does not send.
3. **Operations are in-memory.** Restart the daemon and every operation UUID 404s while the
   containers keep running. The dashboard must treat an unknown operation as "check the
   resource state", never as "the action failed".

**Consequence:** put Incus on the overlay and put a small relay in front of it. The relay
terminates OIDC, holds the client certificate, forwards to the unix socket, and translates
Incus's operation model into something the Worker can poll.

---

## Why not Kubernetes

Because you do not need it, and it costs more than it gives here:

- The target workloads are "one long-running container" and "one batch job". That is a
  scheduler, not a cluster OS.
- Every ingress, CNI and CSI plugin is another thing to operate.
- k3s needs UDP 8472 for flannel, which Cloudflare Tunnel cannot carry, so you would need
  the overlay anyway — at which point you have paid for Kubernetes without using the part
  that would have justified it.

**The one case where k3s wins:** if you need pod-per-job CI executors for GitHub Actions
Runners Controller or the GitLab Kubernetes executor. Both are Kubernetes-only. If that is
your requirement, accept k3s and run its control plane entirely on the overlay.

---

## Why not Docker Swarm

It works, it is simple, and it is effectively feature-frozen. No batch job model, no
parameterized dispatch, weak rescheduling, and VXLAN on 4789/udp. It is a fine choice for
"three containers on three boxes" and a bad one for CI.

---

## Why not Proxmox instead of Incus

Proxmox VE is the more mature hypervisor platform, with a better UI and a longer track
record. Choose it if your machines are VMs on a hypervisor cluster and you want the
management surface that comes with it.

Choose Incus if you want a single API for both VMs and containers, and if you would rather
have an object model than a web UI. Incus's API is the better fit for a Worker-driven
dashboard; Proxmox's is more RPC-shaped and expects the UI.

Either way, the orchestration layer above is identical.

---

## The decision that actually matters

Not "Nomad vs Kubernetes". It is **whether the scheduler's control plane crosses Cloudflare**.

If Nomad's Raft peers reach each other over Cloudflare, then:

- every log append costs a WAN round trip through a third party;
- a Cloudflare incident can cost you quorum;
- your scheduler's availability is the product of your availability and Cloudflare's.

Put the three servers on the overlay, in one site or in sites joined by a real network path.
Never across the tunnel. This is the single most important line in this document after the
three-plane rule.

---

## Sizing

| Role | vCPU | RAM | Disk |
|---|---|---|---|
| Nomad server ×3 | 2 | 8 GiB | 50 GiB SSD |
| Nomad client (CI) | 8–16 | 32–64 GiB | 200 GiB NVMe |
| Incus host | 8 | 32 GiB | 500 GiB + VM storage |
| Gateway | 2 | 4 GiB | 20 GiB |
| SeaweedFS volume | 4 | 16 GiB | 4 × 20 TB HDD |

Three servers is the minimum for Raft quorum. Two is worse than one, because you have
neither redundancy nor simplicity.

---

## Migration off Cloudflare, in order

1. Move CI to Nomad batch jobs. This is the biggest single saving and the clearest win,
   because Workers Builds cannot do it at all.
2. Move artifacts and build caches to SeaweedFS. Keep R2 for logs.
3. Move long-running containers to Nomad service jobs.
4. Only then consider moving Workers applications to celld. It is the least mature part of
   the stack and the least urgent.

Do not do these in parallel. Each one changes what "normal" looks like, and you want to
learn the failure modes one at a time.
