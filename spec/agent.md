# Agent protocol

`cfbd` ⇄ control plane. One outbound connection, framed messages, two classes: control RPC and
streams.

---

## Transport

| | |
|---|---|
| Direction | agent-initiated, held open |
| Transport | QUIC (preferred) or TLS over TCP |
| Framing | length-prefixed: `u32 len` big-endian, then payload |
| Encoding | BARE or MessagePack — fixed schema, versioned |
| Auth | `Authorization: Bearer <node-credential>` on connect |
| Fencing | `conn_id` monotonic per node; a new connection evicts its predecessor |

`conn_id` is claimed in the same write that records the connection, so a stale socket cannot
issue commands. The predecessor's next request fails with `fenced` and it exits.

---

## Control RPC

```
Request  { msg_id: u64, capability: string, args: bytes }
Response { msg_id: u64, ok: bool, result: bytes, error: Error | null }
Error    { code: string, message: string, retryable: bool }
```

Correlated by `msg_id`; responses may arrive out of order. On disconnect every outstanding
waiter fails with `{code:"disconnected", retryable:true}` rather than hanging.

### Capabilities

| Capability | Args | Result |
|---|---|---|
| `exec` | `{argv[], cwd?, env?, timeout_s?}` | `{exit_code, stdout, stderr}` |
| `container.start` | `{image, cpu_millis, memory_mib, mounts[], env{}, restart}` | `{workload_id}` |
| `container.stop` | `{workload_id, signal?, grace_s?}` | `{}` |
| `container.rm` | `{workload_id}` | `{}` |
| `vm.start` | `{image_digest, vcpu, memory_mib, proxy_port}` | `{workload_id}` |
| `workerd.start` | `{bundle_key, config}` | `{workload_id}` |
| `port.forward` | `{local_addr, remote_port}` | `{stream_id}` |
| `fs.read` | `{path}` | stream |
| `fs.write` | `{path}` | stream |
| `metrics` | `{}` | `{cpu, memory_mib, disk_free_mib, load, workloads[]}` |
| `storage.presign` | `{bucket, key, method, expires_s}` | `{url}` |

A capability not declared at enrolment is rejected on both ends.

---

## Streams

```
Open   { stream_id: u32, capability: string, args: bytes }
Data   { stream_id: u32, seq: u64, payload: bytes }
Window { stream_id: u32, consumed_bytes: u64 }
Close  { stream_id: u32, reason: string }
```

Credit-based flow control: the receiver grants `consumed_bytes`, the sender may not exceed the
outstanding window. This prevents a fast log producer from exhausting agent memory when the
control plane is slow.

`seq` is monotonic per stream so a consumer can detect loss after a reconnect. Streams do not
survive a reconnect; the consumer re-opens with a cursor (`{cursor: seq}`) and the agent
replays from its ring buffer.

---

## State report

Sent on connect, on change, and every 15 s.

```
StateReport {
  conn_id: u64,
  generation: u64,              // highest workload generation applied
  workloads: [{
    id: string,
    generation: u64,
    state: "starting"|"running"|"succeeded"|"failed"|"stopped",
    pid: u32?,
    exit_code: i32?,
    started_at: u64,
    cpu_millis: u32,
    memory_mib: u32,
  }],
  capacity: { cpu_millis, memory_mib, disk_free_mib },
  capabilities: [string],
}
```

`generation` is the reconciliation key. The control plane compares its desired generation
against this field and pushes the spec only when the agent is behind. That one integer removes
most reconcile bugs.

---

## Reconciliation

```
control plane                          agent
    │  desired(gen=7) ──────────────────▶ │
    │                                     │ apply
    │ ◀────────────── StateReport(gen=7)  │
    │  match, nothing to do               │
```

On reconnect the agent sends a full report and the control plane diffs from scratch. Applying
a workload that is already running is a no-op keyed on `(workload_id, generation)`, so a
duplicate push cannot start a second copy.

---

## Errors

| Code | Meaning | Retryable |
|---|---|---|
| `unknown_capability` | not declared by the agent | no |
| `denied` | agent's local policy refuses | no |
| `not_found` | workload id unknown | no |
| `busy` | at capacity | yes, with backoff |
| `disconnected` | connection lost mid-call | yes |
| `fenced` | a newer connection owns this node | no — the agent exits |
| `timeout` | the capability exceeded its deadline | yes |
| `storage_unavailable` | presign or upload failed | yes |
