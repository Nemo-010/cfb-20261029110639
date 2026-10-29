# 07 — Operations

---

## Install

```bash
# on the node
curl -fsSL https://cfb.example/install.sh | sh -s -- --token <enrolment-token>
```

The script downloads `cfbd`, verifies its signature, writes `/etc/cfbd/config.toml`, installs
the systemd unit and starts it. Idempotent; re-running upgrades in place.

```ini
# /etc/cfbd/config.toml
control_url = "https://cfb.example"
node_id     = "n-7f3a"
token_file  = "/etc/cfbd/node.token"
capabilities = ["exec", "container", "port.forward", "metrics"]
storage_url = "s3://cfb-artifacts?endpoint=http://10.96.0.7:8333&region=us-east-1"
```

## Upgrade

Two things upgrade: the agent, and the workloads.

### Agent

The new binary runs in a **trial window**. It must report healthy within 60 s or the previous
binary is restored and re-executed. A bad agent release that bricks the fleet is the worst
failure in this design and has the least human presence to fix it.

```bash
cfbd upgrade --to 1.4.2      # downloads, swaps, trials, auto-rolls-back
```

Roll one node at a time. Never upgrade the whole fleet in one window.

### Workloads

Immutable images by digest. A spec change bumps `generation`; the agent starts the new
workload and stops the old one. For a Workers app that is a ~5 ms gap; for a long-lived service
use a rolling restart with the control plane draining first.

---

## Backup

| What | How | Where | RPO |
|---|---|---|---|
| D1 (desired state, jobs, audit) | `wrangler d1 export` nightly | R2 `cfb-backups` | 24 h |
| Object data | off-site replica | second site | 1 h |
| celld bucket (if used) | off-site replica | second site | 1 h |
| Node config | this repo + `/etc/cfbd` in git | git | per change |
| Secrets | offline password manager | — | — |

A backup that has not run in 36 hours is a page, not a warning. The silent-stop failure is the
one that ends companies.

## Restore

```bash
# D1
wrangler d1 create cfb-restore
wrangler d1 import cfb-restore --file=cfb-2026-10-29.sql
# repoint the binding, deploy, verify node count

# celld fleet (if used)
cfbd workload stop celld-*        # all nodes first
# restore the bucket
cfbd workload start celld-node-1  # one node, verify ownership, then the rest
```

**Never** start a celld node against a partially restored bucket: half a fleet bucket is two
owners for one cell, which is silent corruption rather than an outage.

Rehearse quarterly on a scratch host and record the time. An untested restore is a hope.

---

## Out-of-band access

The agent has no inbound port by design. That is correct, and it means the operator needs a
deliberate path in.

| Failure | Path |
|---|---|
| A node is unhealthy | `cfbd` local API over the unix socket, or SSH over the overlay |
| The agent is wedged | `systemctl restart cfbd`, or the unit's `ExecStop` |
| The control plane is down | `cfbd apply` locally with a spec from git |
| The node is unreachable | provider console (IPMI, serial, KVM) |

Layer three is the one everybody forgets and everybody needs exactly once. Document the
credential location and test it annually.

---

## Capacity

Three numbers per resource: current, growth per month, headroom in months. A written trigger,
not a vibe.

| Resource | Measure | Add capacity at |
|---|---|---|
| Storage bytes | per bucket | 70% of usable |
| CI capacity | oldest queued job age | > 10 min sustained |
| Node memory | agent-reported free | < 20% |
| Node count | per control-plane DO | 200 |

Measure bytes per build on day one and write it down. It turns the first capacity decision
into arithmetic.

---

## Monitoring

Five signals. More than five and the one that matters gets ignored.

1. **Agent connections** — expected count; alert below it.
2. **Workload failure rate** — crash-loops, not individual failures.
3. **Oldest queued job age** — the capacity signal.
4. **Storage free space and replication backlog.**
5. **Conditional-write probe** (only if running celld) — a failed CAS is silent corruption,
   not an outage.

The CAS probe matters because the good outcome and the bad outcome look identical from
outside. Run two concurrent `If-None-Match: *` PUTs hourly and assert exactly one succeeds.

---

## Failure modes

| Failure | Symptom | Do |
|---|---|---|
| Control link down | nodes stale, actions 503 | check the tunnel; workloads keep running |
| Agent wedged | node reports but does not act | restart the unit; children are reaped by `KillMode=mixed` |
| Workload crash-loop | node capacity falls | stop the workload; fix the image; do not raise the retry budget |
| Node disk full | new workloads refused | expire `cache`, add a volume |
| Storage backend loses CAS | celld lease conflicts, or none | stop celld, roll back the storage version, audit the bucket |
| Cloudflare outage | dashboard gone | do nothing; the fleet runs |

The last row is the design working. The postmortem question for every incident is: *did the
control plane's failure cause a data-plane failure?* If yes, something crossed a plane
boundary, and that is the bug.

---

## Staffing

One full-time person who owns this, plus cover for holidays. Below that you are one illness
away from an unmaintained fleet, and an unowned fleet is more expensive than a managed one —
just in a way that arrives all at once.

Weekly: patch, watch the five signals, handle the two or three real incidents a quarter, keep
the restore rehearsal on the calendar.
