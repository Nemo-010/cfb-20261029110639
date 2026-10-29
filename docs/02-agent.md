# 02 — `cfbd`, the node agent

One static binary per server. It is the tunnel connector, the broker, and the local
supervisor. Installing a node means installing this and nothing else.

---

## Why one process

The previous revision installed six: `cloudflared`, Nomad client, Incus, celld, SeaweedFS and
`tailscaled`, each with its own config, auth model, upgrade path and failure mode. Every one
of them had to be reachable from the control plane, so every one needed a route through the
tunnel, its own token, and its own health check.

That is five extra credential stores and five extra upgrade procedures to move a job onto a
box. The agent collapses them:

| Concern | Before | Now |
|---|---|---|
| Egress to control plane | `cloudflared` | agent |
| Remote calls | Nomad HTTP API + Incus REST + celld listener | agent RPC |
| Local supervision | Nomad client | agent |
| Port forwarding | `cloudflared access` | agent |
| Metrics | node_exporter | agent |
| Auth | 5 tokens | 1 |

---

## Process model

```
cfbd (pid 1 in its container, or a systemd unit)
├── tunnel        one outbound QUIC/WebSocket to the control plane
├── broker        msg-id correlated RPC + multiplexed streams
├── supervisor    child processes: workerd, containers, microVMs
├── api           unix socket, local operator access
└── metrics       Prometheus text on the unix socket
```

No listening TCP port on any external interface. Everything is either outbound or on a unix
socket.

---

## The connection

One dial, held open, reconnected forever.

```
cfbd ──TLS/QUIC──▶ edge ──▶ Worker
```

- **Direction:** agent-initiated. The node needs no inbound rule, no public address, no
  certificate for a hostname.
- **Auth:** a node token, exchanged at enrolment for a long-lived credential. mTLS optional
  where a private CA exists.
- **Reconnect:** exponential backoff with jitter, 1 s doubling to 30 s, capped. Listeners and
  child processes survive the reconnect — the agent does not restart workloads because its
  control link blipped.
- **Fencing:** every connection carries a monotonically increasing `conn_id`. A reconnecting
  agent claims ownership in the same write that records the connection, so a stale socket
  cannot issue commands. The predecessor is evicted rather than trusted.

The fencing detail is the one that matters. Without it, a network partition produces two
agents that both believe they own the node, and both reconcile — which means a workload gets
started twice or stopped once too often.

---

## Protocol

Framed messages over the single connection. Two message classes:

### Control (request/reply)

```
Request  { msg_id: u64, capability: string, args: bytes }
Response { msg_id: u64, ok: bool, result: bytes, error: {code, message, retryable} }
```

Correlated by `msg_id`. A caller awaits a specific id; the agent answers out of order. When
the connection drops, every outstanding waiter is failed with `disconnected` rather than
hanging to a timeout — the difference between a 200 ms error and a 30 s one.

### Streams

```
Open  { stream_id, capability, args }
Data  { stream_id, seq, payload }
Window{ stream_id, consumed_bytes }     # credit-based flow control
Close { stream_id, reason }
```

One connection carries N concurrent streams — log tails, exec sessions, port forwards, file
transfers. Credit-based flow control prevents a fast producer from exhausting the agent's
memory when the control plane is slow.

`seq` is monotonic per stream so a consumer detects loss after a reconnect. Streams do not
survive a reconnect; the consumer re-opens with a cursor and the agent replays from its ring
buffer.

The design is borrowed from two projects that solved it: the multiplexed tunnel in
`rivet-gg/rivet` (`engine/packages/pegboard-gateway3/src/http_stream/handler.rs`) and the
msg-id RPC in `ZingerLittleBee/ServerBee` (`crates/server/src/service/agent_manager.rs`).
Neither is copyable as code — rivet is Apache-2.0 (attribution required), ServerBee is AGPL —
so both are reimplemented, not vendored.

### State report and reconciliation

```
StateReport {
  conn_id, generation,
  workloads: [{ id, generation, state, pid?, exit_code?, started_at, cpu_millis, memory_mib }],
  capacity:  { cpu_millis, memory_mib, disk_free_mib },
  capabilities: [string],
}
```

Sent on connect, on change, and every 15 s.

`generation` is the reconciliation key. The control plane compares its desired generation
against this field and pushes the spec only when the agent is behind. Applying the same
`(workload_id, generation)` twice is a no-op on the agent, so a duplicate push cannot start a
second copy.

On reconnect the agent sends a full report and the control plane diffs from scratch. That is
the recovery path, and it is the reason the report must be complete rather than incremental.

### Errors

| Code | Meaning | Retryable |
|---|---|---|
| `unknown_capability` | not declared by the agent | no |
| `denied` | the agent's local policy refuses | no |
| `not_found` | workload id unknown | no |
| `busy` | at capacity | yes, with backoff |
| `disconnected` | connection lost mid-call | yes |
| `fenced` | a newer connection owns this node | no — the agent exits |
| `timeout` | capability exceeded its deadline | yes |
| `storage_unavailable` | presign or upload failed | yes |

---

## Capabilities

The agent exposes a fixed set. Each is declared at enrolment and can be disabled locally; the
control plane cannot grant itself one the agent has not declared.

| Capability | What it does | Needs |
|---|---|---|
| `exec` | run a command, stream stdout/stderr, return exit code | — |
| `container.start/stop/rm` | run a container from an image | containerd or Docker socket |
| `vm.start/stop` | boot a Firecracker microVM | `/dev/kvm` |
| `workerd.start/stop` | run a Workers bundle | workerd binary |
| `port.forward` | expose a local port to the control plane | — |
| `fs.read/write` | read/write files under a job directory | — |
| `metrics` | CPU, memory, disk, load, per-workload usage | — |
| `storage.proxy` | presign and proxy S3 requests | storage URL |

Capabilities are checked on **both** ends: the control plane refuses to call one it has not
seen declared, and the agent refuses to execute one that is not in its local policy file. A
compromised control plane cannot escalate a node.

---

## Supervision

The agent owns the workload lifecycle, not a scheduler.

```
desired state (from control plane)  ──▶ reconcile ──▶ actual state (child processes)
```

- Each workload is a child process in its own cgroup, with a restart policy from the spec.
- Restart policies: `never`, `on-failure` (default, with backoff), `always`.
- A workload that crash-loops past its budget is marked `failed` and **not** retried until the
  control plane changes the spec. Infinite restart is how a broken image eats a node.
- Logs are captured to a ring buffer in the agent and shipped to the control plane as streams;
  the agent keeps the last N lines so a reconnecting dashboard can catch up.
- On agent shutdown, children get `SIGTERM`, a grace period, then `SIGKILL`. The order is
  deterministic so that a node reboot does not leave orphans.

### Why not a scheduler

Placement across a small fleet is a decision with few constraints: does this node have the
capability, the free memory, and the right labels. That is a filter and a sort, and it lives
in the control plane where the desired state already is. A real bin-packer (Nomad, Kubernetes)
earns its keep when you have heterogeneous resources and gang scheduling. At 5–50 nodes it is
a second control plane to operate, and it is why revision 2 needed six daemons to run one job.

---

## Local API

A unix socket at `/run/cfbd/agent.sock`, for an operator on the box and for nothing else.

```
cfbd status                 node, connection, workloads
cfbd ps                     running workloads
cfbd logs <id>              tail
cfbd exec <id> -- <cmd>     shell into a workload
cfbd apply <spec.json>      apply desired state locally
cfbd doctor                 capability probe, storage probe, clock skew
```

`cfbd doctor` is the thing you run first when a node misbehaves, and it must be able to
answer without the control plane being reachable.

---

## Enrolment

```
1. Control plane creates the node, returns a token (single use, 15 min, bound to node_id)
2. On the box:  curl -fsSL https://…/install.sh | sh -s -- --token <token>
3. install.sh:  downloads cfbd, verifies signature, writes /etc/cfbd/config.toml,
                installs the systemd unit, starts it
4. cfbd:        exchanges the token for a long-lived credential (0600), dials, declares
                capabilities, sends the first state report
```

The token is the only credential a human types. It is exchanged once and never displayed
again.

---

## Failure behaviour

| Failure | Effect |
|---|---|
| Control link down | workloads keep running; agent buffers state; dashboard shows stale |
| Control link flaps | reconnect with backoff; no workload restart; fences the old connection |
| Agent crash | systemd restarts it; children are reaped by the unit's `KillMode=mixed`; workloads restart per policy |
| Agent upgrade | new binary runs in a trial window; if it does not report healthy, the old binary is restored and re-executed |
| Node reboot | workloads restart per policy; `always` ones come back, `never` ones do not |
| Disk full | agent refuses new workloads, marks node `disk_pressure`, keeps running existing ones |

The trial-window upgrade is worth copying conceptually from ServerBee's
`agent/src/upgrade.rs`: a bad agent release that bricks the fleet is the worst failure in this
design, and it is the one with the least human presence to fix it.
