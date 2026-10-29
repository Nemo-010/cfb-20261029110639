# 08 — Cost

All prices verified 2026-10-29. Every derived figure carries its formula.

---

## The unit

One container-month at `standard-4`: 4 vCPU, 12 GiB, 20 GB, 730 hours.

```
Cloudflare = (4×0.000020 + 12×0.0000025 + 20×0.00000007) × 3600 × 730 = $292.76
Fargate    = (4×0.000011244 + 12×0.000001235)            × 3600 × 730 = $157.14
Owned      = node-month / 21.33 container-equivalents
```

Owned node-month, one node = 2× EPYC 9534 (128 cores), 256 GB, 8× 1.92 TB, ~$40,520 refurb:

```
hardware   $40,520 / 48 months                       = $844
power      0.55 kW × 730 h × PUE 1.54 × $0.1447/kWh  = $89
colo       0.55 kW × $200/kW-month                   = $110
transit    ~1 Gbps commit                            = $50
labour     0.5 FTE × $128,869/yr / 12 / 54.6 nodes   = $98
monitoring, backups, spares                          = $169
                                          node-month = $1,360
```

`min(256/4, 256/12) = 21.33` container-equivalents (memory-bound), so **$63.76 per
container-month**.

---

## Break-even

```
63.76 / 292.76 = 21.8%   vs Cloudflare
63.76 / 157.14 = 40.6%   vs Fargate
```

**Against Fargate, owned metal needs ~41% sustained duty to win. A CI fleet runs at 24%**
(8 h × 22 weekdays). At that duty Fargate is ~$37.71/month and owned metal is $63.76.

So on the compute line alone, Fargate wins and needs no operator. That is the honest answer and
it is the reason this document does not claim a saving.

---

## Where owned metal actually wins

| Workload | Margin | Why |
|---|---|---|
| Egress-heavy | **16–270×** | container egress $0.025/GB after 1 TB; 100G transit $0.03/Mbps/mo |
| Storage above ~80 TB | ~2.5× | R2 $0.015/GB-mo vs fully-amortised disk |
| Sustained compute above ~41% | 2.5× at 100% | the break-even above |
| Bursty CI below 25% | **negative** | paying for idle metal |

Egress is the one that surprises people. 10 TB/month out of Cloudflare Containers is $225;
through a committed port it is noise.

---

## The labour assumption decides everything

| Nodes per ops person | Labour $/node-month | Owned $/container-month | Break-even vs Fargate |
|---|---|---|---|
| 54.6 | 98 | $63.76 | 40.6% |
| 27 | 197 | $68.40 | 43.5% |
| 10 | 537 | $84.30 | 53.6% |
| 5 | 1,074 | $109.50 | 69.7% |
| 1 | 5,369 | $310.90 | 198% |

At one person per ten nodes owned metal never wins against Fargate. **The conclusion is a
statement about staffing, not about hardware.**

This is where the single-agent design pays for itself. Revision 2 required six daemons per
node — `cloudflared`, Nomad, Incus, celld, SeaweedFS, `tailscaled` — each with its own config,
auth, upgrade path and failure mode. Revision 3 requires one. That does not change the
arithmetic in the table above, but it moves you up it: fewer components means more nodes per
person, and the table shows every step is worth more than any hardware decision.

---

## The realistic fleet

3 CI nodes, 1 storage node, 2 gateways:

| Item | Monthly |
|---|---|
| 3 × CI node (16c / 64 GiB / 2 TB NVMe) | ~$1,800 |
| 1 × storage node (12 × 20 TB) | ~$700 |
| 2 × gateway (small) | ~$150 |
| Colo, power, transit | ~$600 |
| Cloudflare Workers Paid | $5 |
| R2 for logs | ~$10 |
| Labour (0.5 FTE) | ~$5,400 |
| **Total** | **~$8,700** |

Labour is 62% of it. The infrastructure is not the expensive part.

---

## Rule

> Self-host when a specific Cloudflare limit blocks the workload, not when the bill is high.

The bill is high because the workload is large, and a large workload on owned metal means
hiring someone to run it. That person costs more than the difference — unless you were going
to hire them anyway, which is the only case where the numbers work.

---

## Assumptions

| Assumption | Value | Sensitivity |
|---|---|---|
| Hardware life | 48 months | 36 months: +11.5% ($844 → $1,126) |
| Loaded labour | $128,869/yr | dominant term |
| Nodes per ops person | 54.6 | see table above |
| PUE | 1.54 | ±0.3 → ±$18/mo |
| Electricity | $0.1447/kWh | industrial $0.0964 cuts power to $59 |
| Colo | $200/kW-month | $190–293 by market |
| Duty cycle | 100% for comparison | break-even 40.6% vs Fargate |

Sources: EIA electric power monthly (Aug 2026), Uptime Institute 2025, TeleGeography Q2 2026,
Digital Realty / CBRE via ColocationScout, BLS OEWS (May 2025) and ECEC (Jun 2026), AWS
Fargate pricing, Cloudflare pricing pages.
