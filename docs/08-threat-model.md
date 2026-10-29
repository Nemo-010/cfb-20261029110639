# 08 — Threat model

Written as an attack enumeration, because a list of controls is a wish and a list of attacks
is a test plan.

---

## Assets, ranked

1. **The fleet bucket.** Whoever can write celld's ownership records owns every cell in that
   fleet. This is the highest-value target in the system.
2. **Substrate credentials.** The Nomad ACL token, the Incus client certificate, the
   SeaweedFS admin key. Each is cluster-wide.
3. **The build path.** CI runs arbitrary code from repositories. It is the intended entry
   point for an attacker.
4. **Object data.** Artifacts, caches, images.
5. **The audit log.** Integrity matters more than confidentiality.

---

## Attack 1 — the unauthenticated object store

**What happens:** you deploy SeaweedFS, expose port 8333 through the tunnel, and forget
`s3.json`. SeaweedFS's S3 authentication is **off by default**. Anyone who can reach the
hostname has read-write access to every bucket.

**Why it is likely:** it is the default. Nothing warns you.

**Mitigations:**

- Write `s3.json` with explicit users before the gateway is reachable.
- Do not publish the S3 gateway on a public hostname at all. Put it behind `vpc_networks`
  and reach it only from the Worker and from runners over the overlay.
- A startup check in the installer that refuses to start the gateway without a non-empty
  auth config.

---

## Attack 1b — the enrolment token

**What happens:** the enrolment token is the only credential a human ever types, it is
single-use, and it grants a machine the ability to join the overlay and register with Nomad.
It is also pasted into a shell on a console you do not control, and it usually ends up in
shell history, in a chat message, or in a screenshot.

**Why it is likely:** every enrolment flow has this step and every operator is in a hurry.

**Mitigations:**

- 15-minute expiry, single use, bound to a `node_id` that the API already created.
- The token is exchanged **once** for a long-lived node credential, which lives in a file with
  mode 0600 and is never displayed again.
- Enrolment is idempotent only while pending; a second use of a spent token is an alert, not a
  retry.
- The preauth key the API mints for the overlay is short-lived and tagged to that node, so a
  stolen enrolment token cannot enrol a machine you did not name.
- Every enrolment writes an audit row with the source address and the token id.

**Residual risk:** a token stolen before first use enrols an attacker's machine into the
overlay. Mitigate by making the overlay ACL default-deny: a newly enrolled node can reach
nothing until an operator moves it out of the `pending` group.

## Attack 2 — the unauthenticated orchestrator port

**What happens:** E2B Embed exposes orchestrator gRPC on **5008** with no authentication. It
creates and kills sandboxes and starts template builds. Its own reference documentation says
so.

**Mitigations:**

- Bind 5008 to loopback. Never let it appear in a tunnel ingress config.
- If you must reach it, do it over the overlay from a relay that authenticates first.
- Same for 5016/5017/5018 (TCP firewall proxies) and 5010 (egress proxy).

---

## Attack 3 — the tenant escape

**What happens:** a CI job runs untrusted code, escapes its container, and reaches the node's
overlay address, the Nomad client API, or another job's build cache.

**Mitigations:**

- Untrusted code runs in a microVM, not a container (see [`04-compute.md`](04-compute.md)).
- The Firecracker jailer: seccomp filter, cgroup limits, chroot, dedicated uid/gid, network
  namespace. Firecracker does **no** traffic filtering of its own.
- Per-slot nftables rules. Each job gets its own tap device and its own egress policy.
- The Nomad client API (4647) is bound to the overlay and has an ACL token that only the
  servers hold.
- Build caches are per-job-prefix and read-only where possible.

**Residual risk:** a microVM escape is a kernel bug. You are trusting KVM and the guest
kernel. Patch them, and do not run untrusted code on a host that also holds your fleet bucket
credentials.

---

## Attack 4 — the plaintext peer network

**What happens:** celld's peer traffic is plain HTTP inside an upgraded stream. An attacker
on the same L2 segment reads or injects fleet traffic, including ownership records.

**Why it is likely:** celld's own documentation says the network must provide confidentiality.

**Mitigations:**

- The overlay is mandatory, not optional. headscale/WireGuard gives you end-to-end
  encryption; DERP relays forward ciphertext they cannot read.
- Never put celld peers on a flat LAN.
- Verify the overlay is actually carrying the traffic — a misconfigured node that falls back
  to a direct route defeats the whole thing.

---

## Attack 5 — credential theft from the manager

**What happens:** an XSS in the SPA, or a malicious dependency in the build, exfiltrates the
Worker's secrets.

**Mitigations:**

- The SPA never holds a substrate credential. It holds only its Access session.
- CSP with no `unsafe-inline`, and a dependency policy that pins and audits.
- Secrets are Worker secrets, not bindings, and are read at call time.
- Rotate on a schedule and on any suspicion; the rotation path is an API endpoint, not a runbook.

---

## Attack 6 — the supply chain

**What happens:** a compromised container image, a typosquatted `npm` package, or a malicious
Firecracker rootfs build step.

**Mitigations:**

- Images are content-addressed by digest and pulled by digest, never by tag.
- SeaweedFS image buckets are write-once in practice: the pipeline writes, runners read.
- The Worker's own dependencies are the smallest set possible — Hono, a router, nothing else.
  Every dependency in the manager is a dependency with access to the control plane.

---

## Attack 7 — the relay

**What happens:** the Incus/celld relay is the one component that holds substrate credentials
*and* faces the Worker. An authorisation bug there is a full cluster compromise.

**Mitigations:**

- Stateless. No session, no cache, no queue.
- Log every decision with the caller identity, the action, and the outcome.
- Fail closed on any ambiguity.
- The relay's own token is scoped to the relay, not shared with the Worker's other paths.

---

## Attack 8 — denial of service against the manager

**What happens:** a job that logs in a tight loop fills the SSE fanout; or a fleet of nodes
heartbeating every second exhausts the DO.

**Mitigations:**

- Rate-limit the log path per job, and drop rather than buffer.
- Heartbeats are alarm-driven at a fixed interval, not client-driven.
- Cloudflare Access in front absorbs the trivial cases.
- The DO per node means one noisy node degrades one object, not the fleet.

---

## Attack 9 — the tunnel as an ingress path

**What happens:** `cloudflared` is an outbound connection that creates an inbound path. If the
gateway host is compromised, the attacker has a route into the private network that looks
like legitimate Cloudflare traffic.

**Mitigations:**

- The gateway host runs `cloudflared` and the relays, nothing else.
- Egress policy on the gateway host: it may reach the overlay and the substrate APIs, and
  nothing else.
- Access policies on every published application, with service tokens, never "anyone".
- Two connectors on two hosts, so compromising one does not remove your visibility.

---

## Attack 10 — the self-updating daemon

**What happens:** `cloudflared`'s default install self-updates from `update.argotunnel.com`
every 24 hours and **restarts**. On a host running long-lived connections, that is a
scheduled outage.

**Mitigations:**

- Pin the version and disable auto-update on the gateway.
- Update deliberately, during a maintenance window, one connector at a time.

---

## Attack 11 — server-side request forgery through the VPC binding

**What happens:** `vpc_networks` lets the Worker reach any address in the bound network, and
the destination is a string assembled at runtime. Any route that takes a hostname, a callback
URL, or a stored value and passes it to `env.SITE.fetch()` is an SSRF primitive with a route
into your private network — including the substrate admin ports that are otherwise unreachable.

**Mitigations:**

- One `vpcFetch()` helper, static allowlist, no user-supplied host or port. See
  [`02-connectivity.md`](02-connectivity.md#the-allowlist).
- Lint rule: `env.SITE.fetch` may appear exactly once in the codebase.
- The substrates also require the overlay and their own auth, so a Worker-only compromise
  cannot reach them without the tunnel.

---

## What is explicitly out of scope

- **Multi-tenant isolation between *customers*.** The design is single-tenant at the
  organisation level. It is **not** single-tenant at the job level, and revision 1 of this
  document was wrong to claim otherwise: CI runs arbitrary code from arbitrary repositories,
  so jobs are mutually untrusted and must be isolated from each other. That isolation comes
  from microVMs and per-job network policy (see [`04-compute.md`](04-compute.md)), not from
  Nomad, whose quotas are a no-op in the free build. If you need to host *other
  organisations'* workloads with a billing boundary, this is the wrong architecture.
- **Compliance regimes.** No audit-grade immutability, no WORM by default, no key management
  story. Object lock exists in SeaweedFS; nothing else here is certified for anything.
- **Physical security.** Your racks, your problem.

---

## The one-line summary

Every serious risk in this design is a **default**: auth off in SeaweedFS, an open gRPC port
in E2B, plaintext peers in celld, auto-update in `cloudflared`. None of them is hard to fix.
All of them are easy to miss. The installer should refuse to start in an insecure
configuration, and the dashboard should show a security posture panel that reads those
defaults back.
