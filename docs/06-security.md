# 06 — Security

Enumerated as attacks, because a list of controls is a wish and a list of attacks is a test
plan.

---

## Trust boundaries

```
browser ──▶ Cloudflare Access ──▶ Worker ──▶ agent ──▶ workload
             (identity)        (credentials) (capability) (isolation)
```

| Boundary | What crosses it | Enforced by |
|---|---|---|
| browser → Worker | Access JWT | Cloudflare Access |
| Worker → agent | capability call | allowlist + agent-side capability policy |
| agent → workload | spec, image, env | runtime isolation |
| workload → network | egress | nftables per slot |

The Worker is the credential holder. The agent is the capability gate. The workload is the
untrusted party. Each boundary is enforced on both sides where it can be.

---

## The blast radius, stated plainly

> **A compromise of the Cloudflare account is a compromise of the fleet.**

The Worker holds the storage credential and can call any capability on any agent. There is no
architecture that removes this while keeping the dashboard on Cloudflare — it is the trade the
design makes deliberately.

What actually reduces it:

| Control | Effect |
|---|---|
| Agent-side capability policy, owned by the agent | the control plane cannot escalate a node |
| Storage credential scoped per bucket | a Worker compromise does not reach every bucket |
| No delete capability on `images` | the image store is append-only from the Worker |
| Hardware-key MFA on the Cloudflare account | raises the cost of the account compromise |
| Break-glass admin identity, held offline | recovery when Access is misconfigured |
| Agents require the tunnel, not a public port | a Worker-only compromise still needs the agent's cooperation |

Residual risk is real. Write it down rather than argue it away.

---

## Attacks

### 1. The unauthenticated object store

SeaweedFS ships with **S3 authentication off by default**. A gateway exposed through a tunnel
without an `s3.json` is a world-readable, world-writable bucket.

**Do:** write `s3.json` before the gateway is reachable; never publish the S3 port on a public
hostname; reach it only from agents and runners.

### 2. The enrolment token

The one credential a human types, and it usually ends up in shell history or a chat message.

**Do:** 15-minute expiry, single use, bound to a pre-created `node_id`, exchanged once for a
long-lived credential written `0600`. A spent token presented again is an alert, not a retry.
A newly enrolled node lands in a `pending` group that can reach nothing until an operator moves
it.

### 3. SSRF through the VPC binding

`vpc_networks` reaches any address in the bound network and the destination is a runtime
string. Any route that builds it from a request is an SSRF primitive.

**Do:** one `vpcFetch()` with a static host/port allowlist; a lint rule that
`env.SITE.fetch` appears exactly once.

### 4. Tenant escape

CI runs arbitrary code from arbitrary repositories. A container escape reaches the node's
network and other jobs' caches.

**Do:** microVM for anything not written in-house; Firecracker jailer (seccomp, cgroups,
chroot, dedicated uid); per-slot nftables; the VM's only route is a node-local pull-through
proxy on one port, which holds the storage credential the VM never sees.

Residual: a microVM escape is a kernel bug. Patch the host, and do not run untrusted code on a
node that also holds fleet-wide credentials.

### 5. Plaintext peer traffic

celld's peer path is plain HTTP inside an upgraded stream and needs an encrypted overlay. If
you run celld, the overlay is mandatory — WireGuard or headscale, with DERP relays forwarding
ciphertext they cannot read.

### 6. The relay

If you keep a relay for a component the agent does not cover (celld's listener, an S3 gateway),
it holds credentials and faces the network. Keep it stateless, log every decision, fail closed.

### 7. Supply chain

**Do:** images by digest, never by tag; the image bucket write-once from the Worker's side;
the Worker's own dependency list as short as possible, because every dependency in the manager
has access to the control plane.

### 8. The self-updating daemon

`cloudflared`'s default install self-updates from `update.argotunnel.com` every 24 hours and
**restarts**. On a host holding long-lived connections that is a scheduled outage.

**Do:** pin the version, disable auto-update, update in a maintenance window.

### 9. Denial of service on the manager

A job logging in a tight loop fills the SSE fanout.

**Do:** rate-limit the log path per job, drop rather than buffer, and let the agent's ring
buffer absorb the rest.

---

## Multi-tenancy

The platform is **single-tenant at the organisation level**. It is **not** single-tenant at the
job level: workloads from different repositories are mutually untrusted and are isolated by
microVM, not by the platform.

There is no billing boundary, no per-tenant quota that is enforced (the container runtime's
cgroup limits are the only real limit), and no per-tenant key management. If you need to host
other organisations' workloads, this is the wrong architecture.

---

## Defaults to check before first boot

| Default | Risk | Fix |
|---|---|---|
| SeaweedFS S3 auth off | unauthenticated store | `s3.json` |
| `cloudflared` auto-update | scheduled restart | pin + disable |
| celld peers plaintext | interception | overlay |
| Workers VPC beta, free | future pricing cliff | keep the fallback path |
| Agent token in shell history | credential leak | exchange once, write 0600 |
| `wrangler.jsonc` with secrets | committed credentials | `wrangler secret put` |

The installer should refuse to start in an insecure configuration, and the dashboard should
read these back in a posture panel.
