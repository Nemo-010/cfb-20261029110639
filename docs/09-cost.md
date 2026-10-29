# 09 — Cost: the break-even, with the arithmetic shown

The short version: **self-hosting is not a cost optimisation at this scale.** It is a
capability purchase. Anyone who tells you otherwise has not counted their own labour.

Every input below is sourced; every derived figure has its formula written next to it so you
can disagree with an assumption instead of the conclusion.

---

## The comparison unit

One "container-month" at Cloudflare's `standard-4` shape: 4 vCPU, 12 GiB, 20 GB disk, running
continuously for 730 hours.

### Cloudflare

```
(4 × $0.000020/vCPU-s + 12 × $0.0000025/GiB-s + 20 × $0.00000007/GB-s) × 3600 × 730
= (0.00008 + 0.00003 + 0.0000014) × 3600 × 730
= $292.76 per container-month
```

Rates: <https://developers.cloudflare.com/containers/platform/pricing/>. Memory and disk bill
on provisioned resources; CPU bills on active use only, so a genuinely idle container costs
less. This figure is the ceiling.

### Owned metal

One node: 2× EPYC 9534 (128 cores total), 256 GB RAM, 8× 1.92 TB SAS, ~$40,520 refurbished.

```
hardware   $40,520 / 48 months                          = $844
power      0.55 kW × 730 h × PUE 1.54 × $0.1447/kWh     = $89
colo       0.55 kW × $200/kW-month                      = $110
transit    ~1 Gbps commit                               = $50
labour     0.5 FTE × $128,869/yr / 12 / 54.6 nodes      = $98
monitoring, backups, spares                             = $169
                                             node-month = $1,360
```

Container-equivalents per node: `min(256/4, 256/12) = 21.33` (memory-bound).

**Owned cost per container-month: $1,360 / 21.33 = $63.76.**

### The break-even

```
$63.76 / $292.76 = 21.8% duty cycle
```

Below ~22% sustained utilisation, Cloudflare list price wins. Above it, owned metal wins.

**And a normal CI fleet clears 22%.** At 8 hours × 22 weekdays (24% duty) the Cloudflare
equivalent is $70.26/month against $63.76 owned — owned metal is marginally cheaper, and the
margin widens as utilisation rises. The economics of this workload are therefore close to
neutral, which is the honest answer: you are not saving much, and you are not losing much.

---

## Where the money actually goes

| Line | $/node-month | Share |
|---|---|---|
| Hardware amortisation | 844 | **62.1%** |
| Monitoring, backups, spares | 169 | 12.4% |
| Colo | 110 | 8.1% |
| Labour | 98 | 7.2% |
| Power | 89 | 6.5% |
| Transit | 50 | 3.7% |

Electricity and bandwidth together are **10.2%**. The debate is about hardware and about a
person, not about watts.

### The labour line is the one that decides the answer

The table above assumes one ops person covers **54.6 nodes**, which is a generous assumption
and it is the assumption the whole conclusion rests on. It is not measured; it is the number
that makes labour a rounding error. Present it honestly and the sensitivity is stark:

| Nodes per ops person | Labour $/node-month | Share of node-month | Owned $/container-month | Break-even duty |
|---|---|---|---|---|
| 54.6 (0.5 FTE / 27 nodes) | 98 | 7% | $63.76 | **21.8%** |
| 27 | 197 | 14% | $68.40 | 23.4% |
| 10 | 537 | 39% | $84.30 | 28.8% |
| 5 | 1,074 | 79% | $109.50 | 37.4% |
| 1 | 5,369 | 397% | $310.90 | 106% |

So: at one person per ten nodes the break-even is ~29% and a 24%-duty CI fleet is a loss. At
one person per node it never pays back at any utilisation. **The conclusion is a statement
about staffing, not about hardware.** Anyone quoting a single break-even number without
saying how many nodes one person runs is quoting an assumption.

The `54.6` comes from the reference fleet below (11 nodes ÷ 0.2 FTE), and it is the weakest
number in this document.

---

## So why do it at all

Partly for capability, and the honest version of that claim is narrower than the obvious one.

Cloudflare Containers **can** run a long job. There is no fixed maximum runtime — Cloudflare's
FAQ says so directly: *"Cloudflare does not stop a container instance after a fixed maximum
runtime."* What you have to do is keep it from sleeping:

- the `Container` class sets `sleepAfter` to **10 minutes** by default, and its
  `onActivityExpired()` hook stops the instance when that expires;
- the Durable Object Container API lets you call `setInactivityTimeout()`, up to **6 hours**;
- an alarm that fires more often than the timeout is the documented way to hold an instance
  open for a longer build.

So "it dies mid-build" is a default, not a wall, and it is a default you can override.

The real ceilings are the ones you cannot override on the standard plan:

| Ceiling | Value | Consequence |
|---|---|---|
| Instance size | 4 vCPU / 12 GiB / 20 GB | a large compile does not fit |
| Image storage per account | 50 GB | one toolchain-heavy CI image can consume it |
| Disk | ephemeral, fresh from the image on each start | no persistent build cache without R2 mounts |
| Host events | Cloudflare "does not guarantee that any container instance will run for a set period" | long jobs are interruptible |

The last row is the one that decides it for CI. A 40-minute build that can be stopped by a
host restart, with no persistent disk to resume from, is a build you will re-run. That is not
a pricing objection and it is not a hard limit — it is a reliability property that matters
when the job takes longer than a page.

**So the argument is:** owned metal buys you a job that survives, not a job that is cheaper.
The cost comparison above says they are close to neutral at realistic utilisation. The
capability comparison is the reason to move, and it is narrower than "Cloudflare cannot do
this" — Cloudflare can, with caveats you may not want to own.

---

## Where owned metal genuinely wins

| Workload | Margin | Why |
|---|---|---|
| **Egress-heavy** (media, artifacts, package mirrors) | **16–270×** | Cloudflare container egress is $0.025/GB after the first 1 TB; 100G transit is $0.03/Mbps/month |
| **Storage above ~80 TB** | ~2.5× | R2 at $0.015/GB-month vs fully-amortised disk |
| **Sustained compute above ~22% duty** | 4.6× at 100% | the break-even above |
| Bursty CI below 25% duty | **negative** | you are paying for idle metal |

The egress number is the one that surprises people. A container pushing 10 TB/month out of
Cloudflare costs $225 in egress alone (1 TB is included); the same bytes through a committed transit port cost
essentially nothing at the margin.

---

## What this design actually costs to run

For a realistic small fleet — 3 CI nodes, 3 storage nodes, 3 Nomad servers, 2 gateways:

| Item | Monthly |
|---|---|
| 3 × CI node (16c / 64 GiB / 2 TB NVMe) | ~$1,800 |
| 3 × storage node (12 × 20 TB) | ~$2,100 |
| 3 × Nomad server (small) | ~$450 |
| 2 × gateway (small) | ~$150 |
| Colo, power, transit for the above | ~$900 |
| Cloudflare Workers Paid (manager) | $5 |
| R2 for logs (a few hundred GB) | ~$10 |
| **Labour (0.5 FTE)** | **~$5,400** |
| **Total** | **~$10,800/month** |

Against that, the Cloudflare list price for equivalent *capacity you can actually use* is
close to zero, because the products do not exist. The honest comparison is against a managed
CI service plus a managed object store, where the numbers are much closer — and where the
labour line is the difference.

---

## The rule of thumb

> Self-host when a specific Cloudflare limit blocks the workload, not when the bill is high.

The bill is high because the workload is large. Self-hosting a large workload on owned metal
means hiring someone to run it, and that person costs more than the difference.

---

## Assumptions, listed so they can be attacked

| Assumption | Value | Sensitivity |
|---|---|---|
| Hardware life | 48 months | 36 months raises owned cost 11.5% (hardware $844 → $1,126) |
| Loaded labour | $128,869/yr (0.5 FTE) | the single dominant term |
| Nodes per ops person | 54.6 | halve it and owned cost rises 1.48×, not 2× — labour is 7% at this ratio |
| PUE | 1.54 | ±0.3 moves power cost by ±$18/mo |
| Electricity | $0.1447/kWh commercial | industrial rate cuts this to $0.0964 |
| Colo | $200/kW-month | ranges $190–293 depending on market |
| Duty cycle | 100% for the comparison | the break-even is at 39% |

Sources for the inputs: EIA electric power monthly (Aug 2026), Uptime Institute 2025 survey,
Telegeography Q2 2026 transit pricing, Digital Realty/CBRE colo quotes via ColocationScout,
BLS occupational wage for network and systems administrators (May 2025) and ECEC benefits
(Jun 2026), AWS Fargate pricing page, Cloudflare pricing pages.

---

## The comparison that actually decides it: Fargate

The break-even above is against Cloudflare Containers, which is the wrong benchmark, because
Cloudflare interrupts long jobs and caps the instance size. The competitor that *can* run the
workload is AWS Fargate.

Fargate: $0.000011244/vCPU-second and $0.000001235/GB-second
(<https://aws.amazon.com/fargate/pricing/>).

```
standard-4 equivalent = (4 × 0.000011244 + 12 × 0.000001235) × 3600 × 730
                      = (0.000044976 + 0.00001482) × 3600 × 730
                      = $157.14 per container-month
```

| Option | $/container-month at 100% duty | Can run the workload? |
|---|---|---|
| Cloudflare Containers | $292.76 | with caveats — interrupts, 4 vCPU cap |
| AWS Fargate | $157.14 | yes |
| Owned metal (54.6 nodes/ops person) | $63.76 | yes |
| Owned metal (10 nodes/ops person) | $84.30 | yes |

At 24% duty, Fargate is ~$37.71/month and owned metal is $63.76 — **Fargate wins**, and it
needs no operator. That is the real baseline, and it is why this document does not claim a
saving.

Owned metal beats Fargate only above roughly `63.76 / 157.14 = 40.6%` duty at the generous
staffing assumption, and ~54% at a realistic one. A CI fleet runs at 24%.

**So the honest conclusion, stated once:** if your only requirement is "run this job
somewhere", buy Fargate. Owned metal is justified by egress economics, by storage above ~80 TB,
by a data-residency requirement, or by a workload that a managed platform will not accept —
not by the compute line.

## The comparison nobody asks for

Cloudflare Containers are **1.8× AWS Fargate per vCPU-second** and 2.0× per GiB-second
(Fargate: $0.000011244/vCPU-s and $0.000001235/GB-s, <https://aws.amazon.com/fargate/pricing/>).

So "Cloudflare is expensive" and "Cloudflare is cheap" are both true depending on which line
you read. Against Fargate, self-hosting looks better. Against R2, it looks worse. The
architecture in this repo is chosen for capability, and the cost story is a side effect that
happens to be favourable only in specific, identifiable cases.
