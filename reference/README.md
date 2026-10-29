# reference/

A skeleton, not a product. It contains the pieces that are hard to get right and easy to get
subtly wrong, written so they can be read in one sitting.

| File | What it is | Real or stub |
|---|---|---|
| `manager/src/vpc.ts` | The single allowlisted VPC call site | real |
| `manager/src/do.ts` | `NodeDO` with connection fencing and reconcile | real |
| `manager/migrations/0001_init.sql` | D1 schema | real |
| `manager/wrangler.jsonc` | bindings, including `vpc_networks` | real |
| `probe/cas-probe.sh` | Conditional-write probe | real, runnable |
| `installer/install.sh` | Node enrolment | real, POSIX sh |
| `agent/` | `cfbd` structure and protocol types | stub — types and TODO |

## What is deliberately absent

The agent's tunnel handshake, the Firecracker driver and the portability adapter are described
in `docs/` and not implemented here. They are the parts that depend on choices this skeleton
cannot make for you: which tunnel transport, which container runtime, which adapter surfaces
your application actually needs.

## Running the pieces that run

```bash
# conditional-write probe against any S3 endpoint
S3_ENDPOINT=http://127.0.0.1:8333 S3_KEY=... S3_SECRET=... \
  sh reference/probe/cas-probe.sh cfb-probe
# exit 0 = exactly one writer won; exit 1 = the store is not safe for celld
```

```bash
# enrolment (needs a control plane)
sh reference/installer/install.sh --token "$TOKEN" --control https://cfb.example
```
