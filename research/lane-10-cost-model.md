# Lane 10 — Cost model: Cloudflare list prices versus self-hosting on owned metal

Research date: **2026-10-29**. All figures USD unless marked. Every load-bearing number below carries the URL it came from; arithmetic derived from those numbers is marked *(derived)* and the formula is shown. Prices are point-in-time: Cloudflare changes list prices without notice and refurb hardware prices move weekly.

## Verdict

Self-hosting is **not a cost optimisation at the scale this project is likely to run**. Against Cloudflare's list price, an owned-metal fleet only wins above roughly **40% sustained duty cycle**, and the break-even is set almost entirely by **ops labour (48% of a node-month)** and hardware amortisation (35%) — power is 3.6% and bandwidth 2.0%, i.e. the two numbers people argue about are noise. Against a *competent* cloud the saving is far thinner than the Cloudflare comparison suggests, because Cloudflare Containers are themselves priced **1.8× AWS Fargate per vCPU-second and 2.0× per GiB-second** (verified, both pages fetched), so "Cloudflare is expensive" and "Cloudflare is cheap" are both true depending on which line you read. The genuinely large margins are in **egress** (self-hosted transit is 16–270× cheaper than Cloudflare's $0.025/GB container egress, depending on commit size) and in **object storage above ~80 TB** (2.5× cheaper than R2 at full fill) — and nowhere else. The single most important caveat: the whole comparison is partly hypothetical, because Cloudflare Containers cannot run the target workload at any price (4 vCPU / 12 GiB defaults, container stops when its Durable Object goes inactive), so for heavy CI you are not choosing between $14k and $23k a month — you are choosing between $23k and *nothing available*. What you buy with the premium is capability, not savings.

## Findings

### Method and unit normalisation

Three units matter and they are not interchangeable:

- **vCPU-hour.** Cloudflare bills per vCPU-second at $0.000020 *(VERIFIED)*, i.e. **$0.072/vCPU-hour** *(derived: 0.000020 × 3600)*. A physical core with SMT presents two threads; I count one thread = one vCPU, which is the convention that flatters owned metal. Counting one core = one vCPU multiplies the owned-metal figure by 2.
- **GiB-hour.** Cloudflare bills $0.0000025/GiB-s = **$0.009/GiB-hour** *(derived)*.
- **Container-month.** The only unit in which the two sides are comparable, because Cloudflare's *shape* is fixed at ≤4 vCPU / ≤12 GiB / ≤20 GB disk. I normalise everything to a "standard-4 equivalent": 4 vCPU, 12 GiB, 20 GB. That is **$0.40104/hour, $292.76/month** at 730 h *(derived from the published per-second rates; matches the $0.40/h figure in lane-01)*.

Everything downstream is sensitive to the container-month normalisation. It is the fairest unit available because Cloudflare will not sell you a bigger one by default.

### What Cloudflare actually charges — no volume discounts are published

Fetched 2026-10-29, all from `developers.cloudflare.com`:

| Line | Rate | Source |
|---|---|---|
| R2 Standard storage | $0.015/GB-month | https://developers.cloudflare.com/r2/pricing/ |
| R2 Class A ops | $4.50/million | same |
| R2 Class B ops | $0.36/million | same |
| R2 egress | **free** | same |
| Containers vCPU | $0.000020/vCPU-second | https://developers.cloudflare.com/containers/platform/pricing/ |
| Containers memory | $0.0000025/GiB-second | same |
| Containers disk | $0.00000007/GB-second | same |
| Containers egress, NA/EU | $0.025/GB, first 1 TB/month included | same |
| Workers Paid floor | $5/account/month | https://developers.cloudflare.com/workers/platform/pricing/ |
| Workers egress | **no charge** | same |
| Durable Objects duration | $12.50/million GB-s | https://developers.cloudflare.com/durable-objects/platform/pricing/ |
| Durable Objects rows written | $1.00/million | same |
| Tunnels beyond 1,000 | $4.50/tunnel/month | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ |

Two things the marketing pages do not say, both verified on the pricing page itself:

1. **A Container is not the whole bill.** Verbatim: *"When you use Containers, incoming requests to your containers are handled by your Worker, and each container has its own Durable Object. You are billed for your usage of both Workers and Durable Objects."* A Durable Object held at the flat 128 MB allocation for an hour adds 0.125 × 3600 × $12.50/1e6 = **$0.0056/hour** *(derived)* — about 1.4% on top of $0.40104. Small, but it means the advertised container rate is a floor, not the price.
2. **Workers egress is free while Container egress is $0.025/GB.** Verbatim from the Workers page: *"There are no additional charges for data transfer (egress) or throughput (bandwidth)."* Verbatim from the Containers page: egress *"is priced at the following rates: North America & Europe $0.025 [per GB]"*. The same byte leaving the same account costs $0.025 or $0.00 depending on which primitive produced it. Whether Container→Worker traffic is metered as egress is not documented (see Open questions) — if it is not, proxying bulk transfers through a Worker is a legitimate zero-cost path, and if it is, the "free egress" story for anything behind a Container evaporates.

**Cloudflare is not cheap for compute.** Fetched from https://aws.amazon.com/fargate/pricing/: CPU *"$0.000011244 per vCPU second"*, memory *"$0.000001235 per GB per second"*, ephemeral storage *"$0.0000000308 per GB per second"*. Cloudflare is **1.78× Fargate on vCPU, 2.02× on memory, 2.27× on disk** *(derived)*. Anyone who assumes "Cloudflare = cheap serverless" and budgets accordingly will be surprised by the compute line; the cheapness is in R2 and in Workers' request pricing, not in Containers.

### The owned-metal cost stack, line by line

Reference node, from a real listing (ByteStock, refurbished Dell R7625, 5-year return-to-base warranty included):

> "Dell PowerEdge R7625 2 x 64 Core 2.45GHz AMD EPYC 9534 256GB 8 x 1.92TB SAS SSD H755" — **£30,495.00** (from £36,594.00)
> https://shop.bytestock.com/servers/dell/dell-rack-servers/16th-generation/dell-poweredge-r7625

Converted at the ECB reference rate for 2026-10-28 (EUR/USD 1.1133, EUR/GBP 0.83785 → **GBP/USD 1.3288**, *derived*, https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml): **capex ≈ $40,520**.

Spec: 128 cores / **256 threads**, 256 GiB DDR5, 15.36 TB raw SAS SSD, 2U, dual PSU.

| Line | Assumption | Monthly | Source of the input |
|---|---|---|---|
| Amortisation | $40,520 ÷ 48 months, zero residual | $844 | listing above |
| Electricity | 0.55 kW avg IT × 730 h × PUE 1.54 × $0.1447/kWh | $89 | EIA + Uptime (below) |
| Colo | 0.55 kW × $200/kW-month | $110 | CBRE/Digital Realty (below) |
| Bandwidth | 100 Mbps committed × $0.50/Mbps | $50 | TeleGeography (below) |
| Ops labour | 0.10 FTE × $141,614 loaded/yr ÷ 12 | $1,180 | BLS (below) |
| Spares / maintenance | 5%/yr of capex | $169 | *assumption* |
| **Total** | | **$2,443** | |

Inputs, all fetched:

- **Electricity.** EIA Electric Power Monthly, Table 5.6.A, August 2026: **U.S. Total, Commercial = 14.47 ¢/kWh**; Industrial 9.64 ¢/kWh; Residential 18.16 ¢/kWh. https://www.eia.gov/electricity/monthly/epm_table_grapher.php?t=epmt_5_6_a. I use the commercial rate; a colo in an industrial-tariff state (Texas 8.96 ¢) would halve this line, which changes the total by 1.8%.
- **PUE.** Uptime Institute Global Data Center Survey 2025: *"In 2025, respondents' annual PUE had a weighted average of 1.54"*, and *"larger data centers (20 MW and above) averaged a PUE of 1.44 globally"*. https://datacenter.uptimeinstitute.com/rs/711-RIA-145/images/2025.Annual.Survey.Report.pdf?version=0
- **Colo.** Colocation Scout's 2026 compilation, quoting the primary market reports: Digital Realty Q2 2026 *"Base rent per kW, deployments of 0 to 1 MW (Americas) | $293/kW-mo"*; CBRE Q1 2026 *"Asking rent, 250 to 500 kW requirement, Northern Virginia | $190 to $235/kW-mo"*. https://colocationscout.com/colocation-pricing.html (secondary; the underlying CBRE H1 2026 and Digital Realty Q2 filings are primary but not machine-readable). I use $200/kW-month, i.e. a small cage in a secondary market, not a 250 kW commitment.
- **Bandwidth.** TeleGeography, Q2 2026: *"In Q2 2026, the lowest 100 GigE prices on offer in the most competitive markets remained steady at $0.03 per Mbps per month. The lowest for 10 GigE also held at $0.07 per Mbps per month."* https://resources.telegeography.com/ip-transit-price-erosion-significant-regional-differences-remain. I deliberately use **$0.50/Mbps**, 17× the quoted floor, because a 100 Mbps commit on a 1G port in a retail colo is nowhere near 100G pricing. This is the most conservative single assumption in the model and it moves the total by 2%.
- **Labour.** BLS OOH, May 2025: *"The median annual wage for network and computer systems administrators was $99,130 in May 2025."* https://www.bls.gov/ooh/computer-and-information-technology/network-and-computer-systems-administrators.htm. Loaded with the BLS ECEC June 2026 private-industry split — *"Wages and salaries averaged $32.82 and accounted for 70.0 percent of employer costs, while benefit costs averaged $14.07 and accounted for the remaining 30.0 percent"* (https://www.bls.gov/news.release/ecec.nr0.htm) — gives $99,130 / 0.70 = **$141,614 fully loaded** *(derived)*.

**Power draw is the weakest input.** 0.55 kW average is my estimate, not a measurement: 2 × 280 W CPU TDP (https://www.amd.com/en/products/processors/server/epyc/4th-generation-9004-and-8004-series/amd-epyc-9354.html, "280W") plus ~120 W platform plus fans, at ~60% average duty, idling near 220 W. The nearest measured anchor I could find is ServeTheHome on dual-socket Genoa: *"We generally saw between 1kW-1.2kW testing dual socket AMD EPYC 9654 systems"* (https://www.servethehome.com/amd-epyc-genoa-gaps-intel-xeon-in-stunning-fashion/9/) — but that is the 96-core part under benchmark load, not this 64-core config. Even doubling my figure to 1.1 kW only adds $200/month — $90 of electricity and $110 of colo power — i.e. 8% of the node-month. **The conclusion is insensitive to the power number**, which is the point.

### Where the money actually goes

Decomposition of the $2,443 node-month *(derived)*:

| Line | $/month | Share |
|---|---|---|
| Ops labour | 1,180 | **48.3%** |
| Hardware amortisation | 844 | 34.6% |
| Spares / maintenance | 169 | 6.9% |
| Colo | 110 | 4.5% |
| Electricity | 89 | 3.6% |
| Bandwidth | 50 | 2.0% |

Labour and silicon are 83% of the cost. Every "owned metal is cheap because power is cheap" argument is arguing about 3.6%. Conversely, the model is dominated by two numbers nobody can source precisely: your loaded salary and your FTE-per-node ratio. That is why the sensitivity table below is the honest artefact, not a single break-even figure.

### Break-even table — compute

Capacity of one node: 256 threads, 256 GiB. At Cloudflare's minimum ratio of 3 GiB per vCPU (verified below), memory binds first: 256 GiB ÷ 12 GiB = **21.3 standard-4 equivalents per node**, using 85 of 256 threads. So the node is memory-bound and 67% of its CPU is stranded. **This is the single most important physical fact in the model**: matching Cloudflare's memory-to-vCPU ratio costs real money, and a 256 GiB / 256-thread box cannot compete on a memory-heavy workload at any price.

Base case: **$114.50 per container-month owned vs $292.76 on Cloudflare → break-even at 39% sustained duty cycle** *(derived)*. Excluding ops labour entirely (i.e. if you already employ the person): **$59.18 → break-even at 20%**.

Sensitivity *(derived; each cell is break-even duty cycle against Cloudflare's $292.76)*:

| Capex ↓ / ops FTE → | 0.05 FTE | 0.10 FTE | 0.25 FTE |
|---|---|---|---|
| $20,000 (used market) | 21% | 31% | 59% |
| **$40,520 (ByteStock refurb)** | 30% | **39%** | 67% |
| $60,000 (new, list) | 37% | 47% | 75% |

Read it as: the break-even moves 20 points for a 2× change in capex, and 28 points for a 2.5× change in ops effort. **Ops effort is the dominant risk, and it is the number you have least control over.**

### Workload shapes — bursty CI loses, always-on wins

200 concurrent 4 vCPU / 12 GiB builds *(derived; owned fleet = 200 ÷ 21.33 = 9.4 nodes × $2,443)*:

| Workload shape | Cloudflare | Owned metal | Winner |
|---|---|---|---|
| CI, 8 h × 22 weekdays (24% duty) | **$14,117/mo** | $22,903/mo | Cloudflare, by 38% |
| CI, 60% duty | $35,131/mo | **$22,903/mo** | owned, by 35% |
| CI, 100% duty | $58,552/mo | **$22,903/mo** | owned, by 61% |
| 20 always-on services | $5,855/mo | **$2,291/mo** | owned, by 61% |
| 100 always-on services | $29,276/mo | **$11,453/mo** | owned, by 61% |

The classic CI pattern — busy 8 hours a day, dead at weekends — sits at 24% duty, *below* the 39% break-even. **On pure price, Cloudflare Containers would beat owned metal for exactly the workload this project says it is built for.** The reason that comparison is academic is that Cloudflare will not run it: the 6-hour inactivity stop kills a long build even when it is busy inside, and 4 vCPU / 12 GiB is the default ceiling. So the correct framing is not "we save 40% by self-hosting"; it is "we pay 62% more than a service that does not exist, in order to be able to run at all". If you want an honest cost benchmark for heavy CI, it is **AWS Fargate at $0.2154/hour for 4 vCPU / 12 GB** *(derived from the verified per-second rates)* = $7,577/month for the same 200 × 176 h — cheaper than owned metal by 3×, and it actually runs the job. That is the number the project has to beat, and it does not beat it on price. It beats it only on data-gravity, egress, and control.

Two further Cloudflare pricing details that punish CPU-bound CI:

- **The 3 GiB-per-vCPU minimum is enforced.** Verbatim: *"Memory to vCPU ratio | Minimum 3 GiB memory per vCPU"* (https://developers.cloudflare.com/containers/platform/limits/). A build that needs 4 vCPU and 4 GiB still pays for 12 GiB. Memory is **27% of the Cloudflare bill for a CPU-bound job** ($0.108 of $0.401/hour) and it is not optional.
- **Included allotments are rounding error at CI scale.** 375 vCPU-minutes/month is 6.25 vCPU-hours — about 90 minutes of one standard-4. The 25 GiB-hour memory inclusion is ~2 container-hours.

### Storage — R2 is very hard to beat, and the crossover is ~80 TB

Storage node, priced from real listings: R7625 12 × 3.5" chassis, diskless, **£11,500 → $15,281** (same ByteStock page, "Dell PowerEdge R7625 12 x 3.5" 2U Rack Server - Configure Your Own") + 12 × 20 TB SAS at **$677 each = $8,124** (https://serverpartdeals.com/collections/20tb-to-30tb-hard-drives, *"Seagate Exos X20 ST20000NM007D 20TB ... Recertified HDD ... $677.00 $33.85 / TB"*). Capex **$23,405**.

Monthly *(derived)*: amortisation $390 (60 mo), power $49 (0.30 kW), colo $60, bandwidth $30, ops 0.05 FTE $590, spares $98 → **$1,216/month**.

| Scheme | Usable | $/GB-month | vs R2 ($0.015) |
|---|---|---|---|
| RAIDZ2 / 4+2 erasure | 200 TB | $0.0061 | 2.5× cheaper at full fill |
| 3× replication | 80 TB | $0.0152 | **loses** |

Because the cost is fixed, the crossover is simply $1,216 ÷ $0.015 = **81 TB stored**, independent of the redundancy scheme — what changes is whether the node has the capacity to reach 81 TB. With erasure coding it does (200 TB); with 3× replication it does not (80 TB capacity, crossover at 81 TB). So:

- **Below ~80 TB: R2 wins outright.** At 20 TB, owned costs $1,216/20,000 GB = $0.061/GB against R2's $0.015 — R2 is 4× cheaper.
- **Above ~80 TB: owned wins, but modestly** — 2.5× at 200 TB fill, saving ~$21k/year, in exchange for owning durability.
- **R2's eleven nines is not replicable at this budget.** Verbatim: *"R2 is designed to provide 99.999999999% (eleven 9s) of annual durability. This means that if you store 10,000,000 objects on R2, you can expect to lose an object once every 10,000 years on average."* (https://developers.cloudflare.com/r2/reference/durability/). A single 12-disk RAIDZ2 node is roughly three orders of magnitude off that and has no geo-redundancy. You are comparing $0.0061/GB against $0.015/GB while silently accepting a materially worse durability SLA. For a CI artefact store that may be fine; for anything you cannot rebuild, it is not a cost question at all.

Also note the R2 billing-rounding trap that bites artifact churn: *"If you have used 1.1 GB-month, you will be billed for 2 GB-month"* and *"If you have performed one million and one operations, you will be billed for two million operations"* (https://developers.cloudflare.com/r2/pricing/). A bucket holding many small, short-lived objects pays the ceiling, not the mean.

### Egress — the one place self-hosting wins by an order of magnitude

This is the only line where the self-hosted number is not close. Serving 100 TB/month *(derived)*:

- **Cloudflare Containers:** 102,400 GB, less the 1 TB inclusion, × $0.025 = **$2,534/month**.
- **Owned metal, retail transit at $0.50/Mbps:** 100 TB/month averages 309 Mbps; at 2× average for 95th-percentile billing that is 617 Mbps → **$309/month**.
- **Owned metal, mid-market at $0.35/Mbps:** **$216/month**.
- **Owned metal, competitive 100G at $0.03/Mbps:** **$19/month**.

Per-GB equivalent: **$0.000093/GB at the TeleGeography floor, $0.0011/GB at $0.35/Mbps, against Cloudflare's $0.025/GB** — a 23× to 270× spread. Transit is billed on 95th percentile, so the comparison is really "peak rate" vs "per byte", which is why the gap narrows if your traffic is spiky; but for a CI fleet pushing artifacts and logs continuously it does not narrow much.

**R2 breaks this argument.** R2 egress is free, so if the artifacts live in R2 and are served from R2, the $2,534 becomes $0 and the entire egress advantage of owned metal disappears. The egress case for self-hosting only exists for bytes that must leave a *Container* or a *Worker-mediated* path. Architect around R2 and this is a non-issue; route bulk bytes through Containers and it is a $30k/year line item.

### The Cloudflare side of the architecture is almost free

The hard constraint — dashboard/SPA hosted on Cloudflare — costs approximately nothing:

- Workers Paid floor **$5/month** for the whole account, including 10M requests and 30M CPU-ms (https://developers.cloudflare.com/workers/platform/pricing/). A dashboard SPA is static assets, and *"Requests to static assets are free and unlimited"* (same page, footnote 3).
- Tunnels: *"Every account includes 1,000 tunnels at no cost"*, then $4.50 each (https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/). With gateway nodes advertising CIDR routes rather than one connector per machine (lane-06's conclusion), this is $0.
- Cloudflare Mesh is in beta and included on the Free plan (per lane-06, verified there).

So the entire "management plane on Cloudflare" cost is **$5–60/month**. The cost model is really a model of the *data plane*, and the constraint the user is worried about is financially irrelevant. Worth saying plainly, because it means the architecture should be chosen for capability, not to amortise a Cloudflare bill.

### What breaks this model

- **Refresh and failure.** A 48-month life assumes the box survives it. The ByteStock listing includes a 5-year return-to-base warranty, which is why my 5%/year spares line is arguably double-counting for years 1–5 — but return-to-base means shipping a 2U server, i.e. days of downtime per failure, not hours. No HA is priced here. Adding N+1 across every tier adds 50–100% to capex.
- **Utilisation is a forecast, not a fact.** The break-even at 39% duty is a statement about *average* utilisation. CI utilisation is not average — it is a weekday daytime plateau and a weekend zero. The model's 24% CI case is the realistic one, and it loses.
- **The 0.10 FTE assumption is doing 48% of the work.** One engineer at 10% per node means 10 nodes consumes a whole FTE. If you cannot actually hire 0.1 of a person — and you cannot — then below ~10 nodes the labour line is either 1.0 FTE spread over 3 nodes (break-even 100%+, i.e. never) or it is unpaid founder time, which is a cost you are choosing not to count.
- **Bandwidth attacks and egress spikes.** A retail transit commit is fine until a CI artifact gets hot. Cloudflare absorbs that; a 1G port does not. Not priced.
- **Capex is a balance-sheet event.** $40,520 × N up front at 2026 interest rates, versus $0 up front on Cloudflare. The model ignores cost of capital; at an 8% discount rate the 48-month amortisation is really ~$989/month, +$145 *(derived)*.

## Candidate table

| name | repo/url | license | last commit or release | what it gives | gap / why it fails |
|---|---|---|---|---|---|
| Cloudflare Containers | https://developers.cloudflare.com/containers/platform/pricing/ | proprietary | pricing page updated 2026-10-05 | Zero capex, per-second billing, scale to zero, no ops labour, free-ish ingress via Tunnel | 1.78× Fargate on vCPU; default cap 4 vCPU / 12 GiB / 20 GB; stops when its DO goes inactive (6 h max); no persistent disk; egress $0.025/GB. Cannot run heavy or long CI at any price |
| Cloudflare R2 | https://developers.cloudflare.com/r2/pricing/ | proprietary | pricing page updated 2026-10-26 | $0.015/GB-month, **free egress**, 11 nines, zero ops | Cheapest credible option below ~80 TB. Loses on $/GB above ~80 TB. Partial S3 API (no bucket policies, object lock, replication) |
| Owned metal in colo (refurb R7625 class) | https://shop.bytestock.com/servers/dell/dell-rack-servers/16th-generation/dell-poweredge-r7625 | n/a (hardware) | listing checked 2026-10-29 | 256 threads + 256 GiB for $2,443/mo all-in; wins above 39% duty; 16–270× cheaper egress | 48% of the cost is a person; 5-year return-to-base warranty = days of downtime per failure; 3 GiB/vCPU memory ratio strands 2/3 of the CPU |
| Owned metal on-premises (office/closet) | — | n/a | — | Removes the colo line (~$110/mo) and possibly the power line | Removes N+1 power and cooling, adds a building you must keep cool and powered; insurance and physical access become the problem. Saves 8% of the model and adds an unquantified outage class |
| Rented bare metal (Hetzner/OVH class) | https://www.hetzner.com/dedicated-rootserver/ | n/a | prices JS-rendered, not extractable | Same metal economics without capex, with provider-side ops labour included | Not verifiable from a static page in this environment (see Open questions). If the €60–100/month class of box really exists at 16 cores/128 GB, it undercuts the entire owned-metal case and should be the default answer |
| AWS Fargate | https://aws.amazon.com/fargate/pricing/ | proprietary | page checked 2026-10-29 | $0.0405/vCPU-hr, $0.004446/GB-hr (derived from verified per-second rates); runs the CI job today. Max task size 16 vCPU / 120 GB — BELIEVED, not checked on the page | 3× cheaper than owned metal at 24% duty and it actually works — this is the real benchmark, not Cloudflare |

## Verified numbers

| claim | value | source URL | verbatim quote |
|---|---|---|---|
| R2 Standard storage | $0.015/GB-month | https://developers.cloudflare.com/r2/pricing/ | "Storage \| $0.015 / GB-month \| $0.01 / GB-month" |
| R2 Class A / Class B | $4.50 / $0.36 per million | https://developers.cloudflare.com/r2/pricing/ | "Class A Operations \| $4.50 / million requests" |
| R2 egress | free | https://developers.cloudflare.com/r2/pricing/ | "Egress (data transfer to Internet) \| Free" |
| R2 rounds up to billing unit | 1.1 → 2 | https://developers.cloudflare.com/r2/pricing/ | "If you have used 1.1 GB-month, you will be billed for 2 GB-month." |
| R2 durability | eleven nines | https://developers.cloudflare.com/r2/reference/durability/ | "R2 is designed to provide 99.999999999% (eleven 9s) of annual durability." |
| Containers CPU rate | $0.000020/vCPU-s ($0.072/vCPU-hr) | https://developers.cloudflare.com/containers/platform/pricing/ | "+ $0.000020 per additional vCPU-second" |
| Containers memory rate | $0.0000025/GiB-s ($0.009/GiB-hr) | https://developers.cloudflare.com/containers/platform/pricing/ | "+$0.0000025 per additional GiB-second" |
| Containers disk rate | $0.00000007/GB-s | https://developers.cloudflare.com/containers/platform/pricing/ | "+$0.00000007 per additional GB-second" |
| Containers egress NA/EU | $0.025/GB, 1 TB included | https://developers.cloudflare.com/containers/platform/pricing/ | "North America & Europe \| $0.025 \| 1 TB" |
| Containers billed with Workers + DO | extra cost per container | https://developers.cloudflare.com/containers/platform/pricing/ | "You are billed for your usage of both Workers and Durable Objects." |
| Containers default max instance | 4 vCPU / 12 GiB / 20 GB | https://developers.cloudflare.com/containers/platform/limits/ | "Maximum vCPU \| 4" / "Maximum Memory \| 12 GiB" |
| Container limits are raisable | defaults, negotiable | https://developers.cloudflare.com/containers/platform/limits/ | "All instance size maximums and account limits on this page are defaults and can be increased." |
| Container memory:vCPU floor | 3 GiB per vCPU | https://developers.cloudflare.com/containers/platform/limits/ | "Memory to vCPU ratio \| Minimum 3 GiB memory per vCPU" |
| Workers Paid floor | $5/month | https://developers.cloudflare.com/workers/platform/pricing/ | "a minimum charge of $5 USD per month for an account" |
| Workers egress | no charge | https://developers.cloudflare.com/workers/platform/pricing/ | "There are no additional charges for data transfer (egress) or throughput (bandwidth)." |
| Workers static assets | free and unlimited | https://developers.cloudflare.com/workers/platform/pricing/ | "Requests to static assets are free and unlimited." |
| DO duration | $12.50/million GB-s | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "400,000 GB-s / month, + $12.50/million GB-s" |
| DO rows written | $1.00/million | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "First 50 million / month included + $1.00 / million rows" |
| DO storage | $0.20/GB-month | https://developers.cloudflare.com/durable-objects/platform/pricing/ | "5 GB-month, + $0.20/ GB-month" |
| Tunnels past 1,000 | $4.50/tunnel/month | https://developers.cloudflare.com/tunnel/features/tunnels-for-platforms/ | "Tunnels for Platforms costs $4.50 per additional tunnel per month." |
| US commercial electricity | 14.47 ¢/kWh (Aug 2026) | https://www.eia.gov/electricity/monthly/epm_table_grapher.php?t=epmt_5_6_a | "U.S. Total \| 18.16 \| 17.57 \| 14.47 \| 13.87 \| 9.64 \| 8.98" |
| US industrial electricity | 9.64 ¢/kWh (Aug 2026) | https://www.eia.gov/electricity/monthly/epm_table_grapher.php?t=epmt_5_6_a | same row, Industrial column |
| Industry average PUE | 1.54 (2025) | https://datacenter.uptimeinstitute.com/rs/711-RIA-145/images/2025.Annual.Survey.Report.pdf?version=0 | "In 2025, respondents' annual PUE had a weighted average of 1.54" |
| 100G IP transit floor | $0.03/Mbps/month (Q2 2026) | https://resources.telegeography.com/ip-transit-price-erosion-significant-regional-differences-remain | "the lowest 100 GigE prices on offer in the most competitive markets remained steady at $0.03 per Mbps per month" |
| 10G IP transit floor | $0.07/Mbps/month (Q2 2026) | same | "The lowest for 10 GigE also held at $0.07 per Mbps per month." |
| Colo, Americas <1 MW | $293/kW-month (Digital Realty Q2 2026) | https://colocationscout.com/colocation-pricing.html | "Digital Realty, Q2 2026 \| Base rent per kW, deployments of 0 to 1 MW (Americas) \| $293/kW-mo" |
| Colo, 250–500 kW NoVA | $190–235/kW-month (CBRE Q1 2026) | https://colocationscout.com/colocation-pricing.html | "CBRE, Q1 2026 \| Asking rent, 250 to 500 kW requirement, Northern Virginia \| $190 to $235/kW-mo" |
| Sysadmin median wage | $99,130 (May 2025) | https://www.bls.gov/ooh/computer-and-information-technology/network-and-computer-systems-administrators.htm | "The median annual wage for network and computer systems administrators was $99,130 in May 2025." |
| Benefits share of comp | 30.0% private industry (Jun 2026) | https://www.bls.gov/news.release/ecec.nr0.htm | "benefit costs averaged $14.07 and accounted for the remaining 30.0 percent" |
| GBP/USD | 1.3288 (2026-10-28) | https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml | "Cube currency='USD' rate='1.1133'" / "Cube currency='GBP' rate='0.83785'" |
| Refurb 128-core node capex | £30,495 ≈ $40,520 | https://shop.bytestock.com/servers/dell/dell-rack-servers/16th-generation/dell-poweredge-r7625 | "£36,594.00 £30,495.00" (2 × EPYC 9534, 256GB, 8 × 1.92TB SAS) |
| Diskless 12×3.5" chassis | £11,500 ≈ $15,281 | same page | "£13,800.00 £11,500.00" |
| 20 TB SAS drive | $677 ($33.85/TB) | https://serverpartdeals.com/collections/20tb-to-30tb-hard-drives | "Seagate Exos X20 ST20000NM007D 20TB ... $677.00$33.85 / TB" |
| AWS Fargate CPU | $0.000011244/vCPU-s | https://aws.amazon.com/fargate/pricing/ | "CPU cost: $0.000011244 per vCPU second" |
| AWS Fargate memory | $0.000001235/GB-s | https://aws.amazon.com/fargate/pricing/ | "memory cost: $0.000001235 per GB per second" |
| EPYC 9354 TDP | 280 W | https://www.amd.com/en/products/processors/server/epyc/4th-generation-9004-and-8004-series/amd-epyc-9354.html | "280W" |
| Dual Genoa system draw | 1.0–1.2 kW under test | https://www.servethehome.com/amd-epyc-genoa-gaps-intel-xeon-in-stunning-fashion/9/ | "We generally saw between 1kW-1.2kW testing dual socket AMD EPYC 9654 systems." |

Derived figures, with formulas (all from the verified inputs above):

| derived claim | value | formula |
|---|---|---|
| Cloudflare standard-4 container-month | $292.76 | (4×0.000020 + 12×0.0000025 + 20×0.00000007) × 3600 × 730 |
| Owned node-month | $2,443 | 40,520/48 + 0.55×730×1.54×0.1447 + 0.55×200 + 50 + 1,180 + 169 |
| Container-equivalents per node | 21.33 | min(256/4, 256/12) |
| Owned cost per container-month | $114.50 | 2,443 / 21.33 |
| Break-even duty cycle | 39% (20% ex-labour) | 114.50 / 292.76 |
| Cloudflare premium over Fargate | 1.78× CPU, 2.02× RAM | 0.000020/0.000011244 |
| 100 TB egress, Cloudflare | $2,534 | (102,400 − 1,024) × 0.025 |
| 100 TB egress, owned @ $0.35/Mbps | $216 | 617 Mbps 95th pct × 0.35 |
| Storage break-even vs R2 | 81 TB | 1,216 / 0.015 / 1000 |

## Rejected options

| option | why rejected |
|---|---|
| Self-host object storage to beat R2 below ~80 TB | The cost is fixed at $1,216/month; below 81 TB stored, R2 is cheaper per GB (4× cheaper at 20 TB) *and* has eleven-nines durability and free egress. Self-hosting here is a pure loss. |
| 3× replication for the self-hosted store | Usable capacity drops to 80 TB, which is below the 81 TB crossover — the node can never fill enough to beat R2. Erasure coding is mandatory for the economics to work at all. |
| Pricing the fleet at 100% utilisation | Every favourable number in this model assumes sustained duty. Real CI runs at ~24%, which is below the 39% break-even. Any business case built on nameplate capacity is wrong by ~1.6×. |
| One tunnel per machine | 1,000 free, then $4.50 each — a 5,000-machine fleet is $18k/month in tunnels alone, which would dwarf the compute bill. Gateway nodes with CIDR routes are the only sane shape. |
| Quoting power as the reason to self-host | Electricity is 3.6% of the node-month. Even at 1.1 kW it is 7%. It cannot carry an argument. |
| Comparing against Cloudflare Containers as if it were a like-for-like option | It cannot run a long build (stops when the DO goes inactive), cannot exceed 4 vCPU / 12 GiB by default, and has no persistent disk. Pricing a workload you cannot run is not a comparison. |
| Assuming Cloudflare is the cheap baseline | Containers cost 1.78× Fargate per vCPU-second and 2.02× per GiB-second. The "cheap" reputation comes from R2 and Workers requests, not compute. |
| Buying new at Dell list | Refurb with a 5-year warranty is the only capex figure I could source concretely, and new-list would be higher with no measurable reliability gain at this duty cycle. Not modelled for lack of a citable quote. |
| Ignoring cost of capital | $40,520 × N up front versus $0 on Cloudflare. At 8%, the true amortisation is ~$989/month not $844 — a 6% understatement of the owned-metal cost, in owned metal's favour. |

## Open questions

- **Are the ByteStock prices ex-VAT?** A UK trade site normally quotes ex-VAT, but the page does not say. If the £30,495 is VAT-inclusive, capex drops 20% to $32,416 and break-even falls from 39% to ~36%. Settle by adding to cart and reading the invoice line, or by asking sales.
- **Can the 4 vCPU / 12 GiB container cap actually be raised, and at what price?** The limits page says *"All instance size maximums and account limits on this page are defaults and can be increased"* — but no rate card exists for larger instances, and the pricing page only prices the six published types. If Cloudflare will sell a 32 vCPU instance at the same $0.072/vCPU-hour, the whole cost comparison changes; if the price scales superlinearly, it does not. Settle with a sales conversation, or by finding an enterprise contract.
- **Does Container→Worker traffic count as billable egress?** The Workers page says egress is free; the Containers page charges $0.025/GB. Nothing documents which applies to traffic that leaves a Container and is proxied out through its Worker. This is a $2.5k/month question at 100 TB. Settle by reading a real invoice with a Worker in front of a Container.
- **Is there any committed-use or enterprise discount on Containers?** Nothing published. Secondary sources claim 10–20% off annual pricing for multi-year Enterprise contracts (https://blog.blazingcdn.com/en-us/exploring-cloudflares-enterprise-plan-features-and-pricing — **secondary, unverified**). Settle with a quote.
- **What does rented bare metal actually cost right now?** Hetzner's and OVH's pricing pages render client-side and could not be extracted; the only numbers I saw in the parsed text (€1.70/month, €21.00/quarter) are clearly add-on SKUs, not server prices. If a 16-core/128 GB box really rents for €60–100/month, it beats owned metal outright and should replace it in this model. Settle by loading the page in a browser or querying Hetzner's Robot API.
- **Real measured power for this exact config.** My 0.55 kW is TDP arithmetic, not a measurement. The only measured anchor I found (1.0–1.2 kW) is a different, larger CPU. Settle with a wall meter on one node for a week, or a Dell Energy Calculator run for the exact SKU.
- **Hardware failure rate and MTTR.** No spares or HA cost is modelled; the 5%/year spares line is a guess. Return-to-base warranty means days, not hours, of downtime per failure. Settle with vendor field data or the first year of real incidents.
- **Whether 0.10 FTE per node is realistic.** This single assumption moves break-even by 28 points across the plausible range. It is not a fact that can be looked up — it is a claim about your team. Settle by asking whoever would actually be on call.
