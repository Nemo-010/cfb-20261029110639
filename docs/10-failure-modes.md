# 10 — Failure modes and the runbook

What breaks, what you see, and what you do. Written before deployment, because at 3am nobody
reads architecture documents.

---

## The failure taxonomy

Three classes, and they need different reflexes:

| Class | Meaning | Reflex |
|---|---|---|
| **Visibility** | you cannot see the fleet | wait, then check the tunnel |
| **Capacity** | work cannot be placed | drain, scale, or shed |
| **Integrity** | state may be wrong | stop writers immediately |

Integrity failures are the only ones that justify waking someone up. Everything else can wait
until morning.

---

## Failure 1 — the tunnel is down

**Symptom:** every node shows stale, all dashboard actions return 503, `cloudflared` logs
show reconnect attempts.

**What still works:** every running job. The scheduler. The overlay. Storage replication.
Nothing on the data plane notices.

**Do:**

1. Confirm it is the tunnel and not Cloudflare: `cloudflared tunnel info <name>`, then check
   the second connector.
2. If both connectors are down, check outbound UDP 7844. Workers VPC requires QUIC; an
   `http2` fallback silently breaks VPC resolution while the tunnel itself looks healthy.
3. If Cloudflare is having an incident, do nothing. The fleet runs. Wait.

**Do not:** restart the gateway host. It will not help and it will take the overlay down too.

---

## Failure 2 — Workers VPC returns errors

**Symptom:** `503 vpc_degraded`, `connect()` timeouts, DNS resolution failures inside the
binding.

**Most common cause:** the tunnel is running `http2` instead of QUIC, or outbound UDP 7844 is
blocked. The tunnel looks fine in the dashboard.

**Do:**

1. Check the tunnel protocol: it must be QUIC for VPC.
2. Check egress firewall on the gateway host for UDP 7844.
3. Fall back to the public-hostname + Access service token path if you built it behind the
   feature flag (you should have).

---

## Failure 3 — a node stops heartbeating

**Symptom:** one node stale in the dashboard; Nomad still shows it as ready.

**Distinguish three cases:**

| Evidence | Meaning | Action |
|---|---|---|
| Nomad shows ready, overlay ping works | the heartbeat path is broken | check the node token, check the relay |
| Nomad shows down | the machine is down | let the scheduler reschedule; drain if it returns |
| Nomad ready, overlay unreachable | network partition | the node may still be running jobs — do not delete it |

**Do not** delete a node that is only unreachable. Deleting it revokes its tokens, and if it
comes back it will not be able to rejoin without a manual enrolment.

---

## Failure 4 — the fleet bucket is unavailable

**Symptom:** celld nodes cannot renew ownership; cells stop being served; SeaweedFS reports
volume errors.

**This is an integrity event.** celld's model is that the bucket decides ownership. Without
it, a node cannot prove it owns a cell.

**Do:**

1. Stop the celld nodes (Nomad: `nomad job stop celld`). Do not let them run while ownership
   is unprovable.
2. Restore the bucket.
3. Restart one node, verify it takes ownership, then the rest.

**Why this matters:** if you let nodes run without ownership records, two nodes can serve the
same cell, and that is silent corruption, not an outage.

---

## Failure 5 — the storage backend stops honouring conditional writes

**Symptom:** celld reports lease conflicts, or worse, no error at all and two nodes serve one
cell.

**This is the single most dangerous failure in the design**, because the good outcome and the
bad outcome look identical from outside.

**Do:**

1. Run the CAS probe before every storage upgrade — a script that does two concurrent
   `If-None-Match: *` PUTs to the same key and asserts exactly one succeeds.
2. If the probe fails, roll back the storage version immediately.
3. Audit the fleet bucket for duplicate ownership records.

**Prevention:** the probe runs as a Nomad `sysbatch` job hourly, and a failure pages.

---

## Failure 6 — a build hangs

**Symptom:** job in `running` past its expected duration.

**Do:**

1. Check the allocation: `nomad alloc status <id>`.
2. If the microVM is alive but the build is stuck, the supervisor's timeout should have fired.
   If it did not, that is a supervisor bug — cancel the job and file it.
3. `nomad job stop` the dispatch, which kills the allocation and the microVM with it.

**Do not** kill the node. Nomad will reschedule the job onto another node, which is the
correct behaviour and the reason you are running a scheduler.

---

## Failure 7 — the manager is fine but a substrate API is not

**Symptom:** dashboard loads, one panel errors.

**Do:** the DO should mark that substrate `degraded` and keep serving the rest. A Nomad
outage must not blank the storage panel.

This is a design requirement on the SPA: every panel loads independently, with its own error
state. A dashboard that fails as a unit is a dashboard you cannot use during an incident,
which is the only time you need it.

---

## Failure 8 — disk full on a storage node

**Symptom:** writes fail, SeaweedFS volume server rejects.

**Do:**

1. Check EC repair backlog — if you never scheduled `ec.rebuild -apply`, you may be at 3×
   replication and out of space for no reason.
2. Add a volume, or expire the cache bucket.
3. The `cfb-cache` lifecycle rule is the thing that should have prevented this.

---

## Failure 9 — certificate or token expiry

**Symptom:** everything returns 401 at once.

Three separate expiry clocks: the Cloudflare Access session, the Nomad ACL token, the overlay
node keys. Put all three in the dashboard with a countdown, and rotate on a schedule rather
than on expiry.

---

## Failure 10 — you are locked out

**Symptom:** the tunnel is up but Access rejects you.

**Do:** Cloudflare Access has a break-glass path via service token. Keep one, stored offline,
with a documented rotation. This is the one credential that must not live only in the
dashboard.

---

## The dashboard's job during an incident

The manager must degrade, not disappear:

| Substrate | Dashboard behaviour |
|---|---|
| Nomad down | job panel shows last-known + "unreachable"; other panels work |
| Incus down | machine panel degraded; create disabled |
| SeaweedFS down | storage panel degraded; presign disabled |
| celld down | app panel degraded; deploy disabled |
| D1 down | read-only mode, cached views |
| Tunnel down | everything stale, banner, actions disabled |

The last row is the one that matters: when you cannot reach the fleet, the dashboard must say
so clearly and stop pretending.

---

## What to monitor

Five signals, no more:

1. **Tunnel connector count** — expect 2 per site; alert at 1.
2. **CAS probe result** — alert on failure; this is the integrity signal.
3. **Nomad node count vs enrolled node count** — divergence means drift.
4. **Storage free space and EC repair backlog**.
5. **Job queue depth and oldest queued job age** — the capacity signal.

Everything else is a dashboard, not an alert. Alert fatigue kills the integrity alert, which
is the only one that matters.

---

## The postmortem question

For every incident, ask: *did the control plane's failure cause a data-plane failure?*

If the answer is ever yes, the three-plane rule has been violated somewhere, and that is the
bug to fix — not the symptom.
