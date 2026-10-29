# 05 — Economics: the arithmetic is reproducible, the model is not

## Verdict

The cost model is *reproducible* — I recomputed every line and the $292.76, the $2,443, the
21.33 and the 39.1% all fall out of the stated inputs — but it is not *coherent*: the same
document prices ops labour two ways that differ by 2.4×, and the "54.6 nodes per ops person"
is a back-solved constant, not a fleet ratio. Worse, the break-even is computed against a
product the document simultaneously declares unusable, while the one competitor that can
actually run the workload (AWS Fargate) is quoted for its per-second rate and never for its
monthly bill. At the document's own 24% CI duty cycle, owned metal is 3.0× Fargate. The
conclusion — "capability purchase, not cost optimisation" — may still be right, but it does
not follow from the numbers printed here.

## Findings

### [BLOCKER] The labour line is dimensionally wrong, and "54.6 nodes per ops person" is a constant chosen to close the equation

**Where:** `docs/09-cost.md:37`, `docs/09-cost.md:143-144`

**Claim under attack:** `labour     0.5 FTE × $128,869 loaded / 54.6 nodes    = $1,180`

**Why it fails:** As written this is (FTE·dollars/year)/nodes = dollars per node per **year**.
The document puts it in a column headed `node-month = $2,443` (`:39`). Dimensionally it is off
by 12×. But the *number* is not wrong — it is right for a completely different assumption:
`research/lane-10-cost-model.md:88` derives it as `0.10 FTE × $141,614 loaded/yr ÷ 12 = $1,180`,
i.e. **0.10 FTE per node, 10 nodes per FTE**. The published formula describes 0.00916 FTE/node
(109 nodes per FTE) and only lands on $1,180 because it forgot the ÷12.

`54.6` is not a measured ratio. It is exactly `60 × 128,869 / 141,614 = 54.6001` — the single
value that makes the printed formula land on the $1,180 the research file derived from a
different assumption. It encodes two independent labour-rate errors (see next finding) as a
node count.

The document then contradicts itself in the next section: `:119` charges **0.5 FTE (~$5,400)**
to run **11 nodes** — 22 nodes per FTE, i.e. $491/node-month — which is **2.4× less labour per
node** than the $1,180/node-month that produced the 39.1% break-even. Both cannot be true.

Concrete failure: an operator reads "48% of a node-month is a person, $1,180" and then reads
"the whole 11-node fleet is $10,800/month including 0.5 FTE". At the model's own rate, 11
nodes cost **$12,981/month in labour alone** and the fleet total is **~$18,400**, not $10,800 —
the document's headline "what this design actually costs to run" is 70% too low.
Take the other reading and 0.5 FTE covers 11 nodes, so the node-month is $1,361, the
per-container cost is $63.80, and the break-even is **21.8%** — which means owned metal wins at
the document's own 24% CI duty cycle and the entire "Cloudflare is 38% cheaper" paragraph at
`:54-55` reverses. The document's conclusion flips depending on which of its own sentences you
believe.

Note for the other reviews: the tempting fix — "divide by 12, labour is $98/node-month" — is
*also* wrong. It makes the break-even 21.8% and then leaves the fleet table's $5,400 looking
5× too high. There is no single ÷12 that reconciles the two sections.

**What to do instead:** Delete `54.6` and state the assumption as what it is: "0.10 FTE per
node (1 FTE per 10 nodes); 0.10 × $141,614 / 12 = $1,180/node-month", with the sensitivity
expressed in FTE/node. Then recompute the fleet table: 11 nodes × 0.10 FTE = 1.1 FTE =
$12,981/month, total ~$18,400. If you actually believe 0.5 FTE covers the fleet, say so and
recompute the break-even to 21.8% — but then you are arguing the opposite conclusion.

---

### [BLOCKER] The break-even is against a product the document calls unusable, and the competitor that *is* usable is never priced

**Where:** `docs/09-cost.md:52`, `docs/09-cost.md:97`, `docs/09-cost.md:77-78`, `docs/09-cost.md:122-125`

**Claim under attack:** "Below ~39% sustained utilisation, Cloudflare list price wins. Above it,
owned metal wins." — and, two pages later, "Cloudflare Containers **cannot run the target
workload at any price**".

**Why it fails:** If Cloudflare cannot run the workload, the 39.1% break-even has no decision
content, and the row `| **Sustained compute above ~40% duty** | 2.6× at 100% | the break-even
above |` (`:97`) is self-refuting: you cannot win 2.6× against something you cannot buy. The
document half-admits this ("the comparison above is partly fictional") and then still uses the
fictional comparison as evidence of a win.

The competitor it should be measured against is named in the document's own last section
(`:157-160`) and never costed. Using the Fargate rates the document itself quotes and I verified
(`$0.000011244/vCPU-s`, `$0.000001235/GB-s`, <https://aws.amazon.com/fargate/pricing/>), a
4 vCPU / 12 GiB container-hour is **$0.21527**, and — unlike Cloudflare — Fargate has no
inactivity stop and allows tasks up to **16 vCPU / 120 GB** (verified on that page: "16 vCPU |
Min. 32 GB and Max. 120 GB"), so it can run the build.

At the 200-concurrent CI fleet the research models, 176 h/month each (the document's own
8 h × 22 weekday shape):

| | monthly |
|---|---|
| AWS Fargate, 200 × 176 h × $0.21527 | **$7,577** |
| Cloudflare Containers, 200 × 176 h × $0.40104 | $14,117 |
| Owned metal, 200/21.33 = 9.38 nodes × $2,443 | **$22,901** |

Owned metal is **3.0× Fargate** and **1.6× Cloudflare** at the exact duty cycle the document
uses to argue Cloudflare is cheaper. `research/lane-10-cost-model.md:122` computes this and
says plainly "AWS Fargate at $0.2154/hour ... = $7,577/month ... cheaper than owned metal by
3×". `09-cost.md` deletes that sentence and keeps only the per-second *ratio* (`:157-160`),
which makes Fargate look expensive per unit while never showing the monthly bill — the one
number that matters. Then `:122-125` gestures at "a managed CI service plus a managed object
store, where the numbers are much closer" without running it, having already run it in the
research file and not liked the answer.

**What to do instead:** Add the Fargate row to the break-even section and state the conclusion
it forces: at 24% duty the owned fleet costs 3× a service that runs the job today. Then make
the capability argument on the axes where Fargate actually loses (data gravity, egress at
scale, control, no per-hour metering) rather than on "nothing else exists", which is false.

---

### [MAJOR] Loaded labour is understated ~10%: $128,869 is $99,130 × 1.30, but BLS says benefits are 30% of *total* compensation

**Where:** `docs/09-cost.md:143`

**Claim under attack:** `| Loaded labour | $128,869/yr (0.5 FTE) |`

**Why it fails:** `99,130 × 1.30 = 128,869` exactly. The BLS wage is verified
("The median annual wage for network and computer systems administrators was $99,130 in May
2025", <https://www.bls.gov/ooh/computer-and-information-technology/network-and-computer-systems-administrators.htm>).
But the ECEC source the document cites says benefits are **30.0 percent of employer costs**,
not 30% of wages: "Wages and salaries averaged $32.82 and accounted for 70.0 percent of
employer costs, while benefit costs averaged $14.07 and accounted for the remaining 30.0
percent" (<https://www.bls.gov/news.release/ecec.nr0.htm>, verified). So the loaded figure is
`99,130 / 0.70 = **$141,614**`, not $128,869. The research file gets this right
(`lane-10-cost-model.md:88`); the published document silently substitutes the multiply-by-1.3
version, understating labour by 9.9% in the direction that flatters self-hosting.

**What to do instead:** `$141,614`, and show `99,130 / 0.70` so the reader can check the
direction of the division. Note the arithmetic consequence: at the research's 0.10 FTE/node the
line is unchanged at $1,180 — because 54.6 was tuned to hide it. Once you fix the node ratio,
the two errors no longer cancel.

---

### [MAJOR] "The largest instance is 4 vCPU / 12 GiB" is a default Cloudflare will raise; "at any price" is therefore false

**Where:** `docs/09-cost.md:82`, and the heading `docs/09-cost.md:77-78`

**Claim under attack:** "- the largest instance is 4 vCPU / 12 GiB;" used to support "Cloudflare
Containers **cannot run the target workload at any price**".

**Why it fails:** The limits page says, verbatim, immediately above the table: "**All instance
size maximums and account limits on this page are defaults and can be increased.** To request
higher limits, contact your account team or Cloudflare Support."
(<https://developers.cloudflare.com/containers/platform/limits/>, verified). The table the
document reads is headed "Custom instance types have the following constraints" — it is a
default ceiling with a documented escalation path, not a wall. The research file records this
verbatim (`lane-10-cost-model.md:229`, "Container limits are raisable | defaults, negotiable")
and `09-cost.md` drops the qualifier; `README.md:100` then propagates it as "Container instance
ceiling | 4 vCPU / 12 GiB / 20 GB".

This matters because "at any price" is the entire justification for a 3× premium. The honest
claim is "the largest *published* instance is 4 vCPU / 12 GiB and larger sizes have no rate
card, so they cannot be priced in this model" — which is a procurement question, not a
capability wall, and would have to be resolved by a sales call before anyone commits capex.

**What to do instead:** Restate as "no published instance above 4 vCPU / 12 GiB; larger sizes
are negotiable with no published rate card". Move it to Unanswered questions. Keep the 6-hour
ceiling (that one is real — see "What the document gets right").

---

### [MAJOR] `~1 Gbps commit = $50` is a 10× mis-transcription of the research input and prices transit below the published market floor

**Where:** `docs/09-cost.md:38`

**Claim under attack:** `transit    ~1 Gbps commit                            = $50`

**Why it fails:** $50/month for 1,000 Mbps is **$0.05/Mbps/month**. TeleGeography, the
document's own source, puts the *lowest* 10 GigE price at **$0.07/Mbps** and the lowest 100 GigE
at **$0.03/Mbps**: "the lowest 100 GigE prices on offer in the most competitive markets remained
steady at $0.03 per Mbps per month. The lowest for 10 GigE also held at $0.07 per Mbps per
month" (<https://resources.telegeography.com/ip-transit-price-erosion-significant-regional-differences-remain>,
verified). A 1 Gbps commit in a retail colo cannot be priced *below* a 10 GigE port in the
most competitive market on earth. The document's own source refutes the number.

The research file had it right: "Bandwidth | 100 Mbps committed × $0.50/Mbps | $50", with the
note "I deliberately use **$0.50/Mbps**, 17× the quoted floor, because a 100 Mbps commit on a 1G
port in a retail colo is nowhere near 100G pricing" (`lane-10-cost-model.md:88`). `09-cost.md`
turned "100 Mbps at $0.50" into "1 Gbps at $50" — 10× the capacity at 10× lower unit price.
It is also internally inconsistent with `:95`, which uses $0.03/Mbps for 100G: that implies a
1.67× volume discount for a 100× larger commit.

**What to do instead:** Either restore "100 Mbps committed at $0.50/Mbps = $50", or keep
1 Gbps and charge $500/month. The node-month only moves 2%, but this figure is the numerator of
the 16–270× egress claim, so it cannot be left wrong.

---

### [MAJOR] The "16–270×" egress margin and "~80 TB / ~2.5×" storage claim do not follow from the document's stated inputs

**Where:** `docs/09-cost.md:95-96`

**Claim under attack:** `| **Egress-heavy** ... | **16–270×** | Cloudflare container egress is
$0.025/GB; 100G transit is $0.03/Mbps/month |` and `| **Storage above ~80 TB** | ~2.5× | R2 at
$0.015/GB-month vs fully-amortised disk |`

**Why it fails:** Two derived numbers with no derivation that survives checking.

*Egress.* The only transit price given is $0.03/Mbps at 100G. Fully filled, 100 Gbps moves
32,850 TB/month for $3,000 = $0.0000913/GB, which is **274×** cheaper than $0.025/GB — that is
the top of the range. The bottom end (16×) requires ~5.8% fill, and no utilisation is stated.
16× is inherited from the research's deleted $0.50/Mbps retail case (`lane-10:137`, which says
"23× to 270×", not 16×), so the published range endpoint has no basis in the published text.
And if you take `:38`'s $0.05/Mbps literally, full fill gives 164× — a third answer.

*Storage.* Using the document's **own** fleet table, a storage node is `$2,100 / 3 = $700/month`
(`:113`). Crossover against R2 at $0.015/GB-month is `$700 / 0.015 / 1000 = **46.7 TB**`, not
80 TB; and at 200 TB fill the ratio is `0.015 / (700/200,000) = **4.3×**`, not 2.5×. The
80 TB / 2.5× pair comes from the research's $1,216/month node — which **includes $590 of
labour** (`lane-10:170`). But `09-cost.md` prices its storage node ex-labour ($700) and counts
labour globally at `:119`. So the published pair either double-counts labour (if you take the
research node) or is simply wrong by 1.7× (if you take the document's own node). Whichever base
you pick, the printed pair is not the one the printed inputs produce.

**What to do instead:** Derive both from `:113`'s $700 node and show the crossover formula
inline: "crossover = node-month / $0.015/GB; at $700 that is 46.7 TB; at 200 TB fill the ratio is
4.3×". If you prefer 80 TB, use the research's $1,216 all-in node and say so, then remove the
separate labour line for storage.

---

### [MAJOR] The egress "win" is against a product whose egress is free

**Where:** `docs/09-cost.md:95`, `docs/09-cost.md:100-102`

**Claim under attack:** "| **Egress-heavy** (media, artifacts, package mirrors) | **16–270×** |
Cloudflare container egress is $0.025/GB ..." — "The egress number is the one that surprises
people."

**Why it fails:** R2 egress is **free**: "Egress (data transfer to Internet) | Free"
(<https://developers.cloudflare.com/r2/pricing/>, verified). The workloads named in the row —
media, artifacts, package mirrors — are object data. For object data the correct Cloudflare
comparison is R2 at **$0.00/GB**, and the 16–270× advantage is exactly 0×. The margin only
exists for bytes that leave a *Container*, which is the primitive the document spends the
previous section arguing you must not use. The research states this explicitly and at length
("**R2 breaks this argument.** ... the entire egress advantage of owned metal disappears",
`lane-10:148`); the published document deletes the caveat and keeps the number. A reader will
budget $50/month of transit as a 270× win against a $0/GB baseline.

**What to do instead:** Keep the row but qualify it in the cell: "only for bytes that must
leave a Container/Worker; R2 egress is $0, so architect the bulk path through R2 and this
advantage vanishes". Then the honest claim is that egress is a reason to *use R2*, not a reason
to own transit.

---

### [MAJOR] 0.5 FTE is not a thing you can buy, and cannot cover 24/7 on-call for six stateful systems

**Where:** `docs/09-cost.md:119`; assumption `docs/09-cost.md:143`

**Claim under attack:** `| **Labour (0.5 FTE)** | **~$5,400** |`

**Why it fails:** 0.5 FTE is 20 h/week of a single named person. Three things break:

1. **It is not purchasable.** You cannot hire half a person; you hire one and allocate half,
   which means the *cost* is 1.0 FTE unless the other half is billed elsewhere. The research
   admits this ("If you cannot actually hire 0.1 of a person — and you cannot",
   `lane-10:174`) and `09-cost.md` drops the admission.
2. **It cannot provide on-call.** The fleet in `:108` is 3 Nomad servers, 3 SeaweedFS nodes, 3
   CI nodes, 2 gateways, one colo, refurb gear on return-to-base warranty, and — per
   `docs/01-architecture.md:15` and `README.md:130-140` — celld, headscale and Incus on top. A
   CI service developers block on needs a pager answered within minutes. One half-time person
   is a bus factor of one and no rotation. The minimum viable is 1.0 FTE plus a second person
   for rotation — and a second person is not 0.5 FTE of work, it is 2.0 FTE of headcount.
3. **It understates by 2.4×** relative to the model's own 0.10 FTE/node (see BLOCKER 1): 11
   nodes at 0.10 FTE = 1.1 FTE = $12,981/month.

**What to do instead:** State the minimum as 1.0 FTE (single-operator, no rotation) and price
the fleet at that, showing the total honestly: ~$18,400/month at 1.1 FTE. Then add a line for
on-call compensation, which is paid time in most jurisdictions and is not in any figure here.

---

### [MINOR] "36 months raises owned cost ~22%" is computed on a base the document never presents

**Where:** `docs/09-cost.md:142`

**Claim under attack:** `| Hardware life | 48 months | 36 months raises owned cost ~22% |`

**Why it fails:** On the document's own $2,443 node-month, hardware goes from $844.17 to
$1,125.56, i.e. +$281.39 = **+11.5%**, and cost per container-month goes $114.50 → $127.69.
The printed 22% is only obtained against the **ex-labour** base of $1,263 (`281.39 / 1,263 =
22.3%`) — a base the document never presents as its cost. So the sensitivity is quoted against
a denominator that contradicts the headline, and a reader will over-estimate the model's
fragility by 2×. (And once BLOCKER 1 is fixed the base changes again.)

**What to do instead:** "36 months → +$281/node-month, +11.5%, break-even 39.1% → 43.6%", and
say which base the percentage is of.

---

### [MINOR] The $169 line is unreproducible, and it double-counts a 5-year warranty the document never mentions

**Where:** `docs/09-cost.md:38`

**Claim under attack:** `monitoring backups, spares                           = $169`

**Why it fails:** No source, no formula, and the label names three things. It is actually
`5%/yr × $40,520 / 12 = $168.83` of spares (per `lane-10:88`), which means monitoring and
backups are *not* in it despite the label. Meanwhile the actual product listing — which I
fetched — says "All systems are supplied ready to install and include a **5-year return-to-base
warranty** as standard" and "**5 Year Bytestock Warranty**"
(<https://shop.bytestock.com/servers/dell/dell-rack-servers/16th-generation/dell-poweredge-r7625>,
verified). So for the entire 48-month amortisation period the box is under warranty for
everything except consumables, and the spares allowance double-counts it. The research admits
the double-count ("my 5%/year spares line is arguably double-counting for years 1–5") and the
published document drops the admission *and* the warranty.

Related: the 48-month life itself is **defensible** — I expected it to be the weak point, and
it is not, precisely because the warranty runs 60 months. But the reader cannot know that,
because the sentence at `:30` says only "~$40,520 refurbished".

**What to do instead:** "hardware $40,520/48 = $844 (includes 5-yr return-to-base warranty;
consumables 1 yr)", drop or halve the spares line for years 1-5, and add the thing the warranty
does *not* buy: MTTR. Return-to-base means shipping a 2U server — days of downtime per failure,
and there is no N+1 anywhere in this model.

---

### [MINOR] "Halve it and owned cost per unit doubles" is +48%, not 2×

**Where:** `docs/09-cost.md:144`

**Claim under attack:** `| Nodes per ops person | 54.6 | halve it and owned cost per unit doubles |`

**Why it fails:** Doubling the labour line from $1,180 to $2,360 takes the node-month from
$2,443 to $3,623 — **+48%**. For the total to double, labour would have to be 100% of the
node-month; it is 48%. This is true under every reading of the labour figure, including the
corrected 0.10 FTE/node one. The stated sensitivity overstates by 2×.

**What to do instead:** "+48% node-month; break-even 39.1% → 58%".

---

### [MINOR] `min(256/4, 256/12)` is unreadable, and 21.33 assumes 100% of RAM is allocatable

**Where:** `docs/09-cost.md:42`

**Claim under attack:** "Container-equivalents per node: `min(256/4, 256/12) = 21.33` (memory-bound)."

**Why it fails:** Two problems.

*Readability.* The node is described at `:30` as "2× EPYC 9534 (**128 cores** total), **256 GB**
RAM". On that text `256/4` has no meaning — 256 is gigabytes, 4 is vCPU. The intended reading
(from `lane-10:96`) is 256 **threads** / 4 vCPU = 64, so the literal `256` does double duty for
threads and GiB and the document never says "256 threads" anywhere. The result is right by luck
(memory binds either way — 128 cores/4 = 32 > 21.33), but any reader who checks the arithmetic
will conclude the document divided gigabytes by vCPUs.

*Overstatement.* 256/12 = 21.33 assumes the full 256 GiB is handed to containers. Nomad, the
container runtime, the host kernel and page cache all take a cut; ~90% allocatable gives 19.2
container-equivalents, and cost per container-month rises from $114.50 to **$127**.

**What to do instead:** Write it out: "capacity = min(256 threads / 4 vCPU, 256 GiB × 0.9 / 12
GiB) = min(64, 19.2) = 19.2". One line, no ambiguity, and 11% more honest.

---

### [MINOR] The reference node is memory-starved by construction, and the cheapest lever in the whole model is never priced

**Where:** `docs/09-cost.md:30`, `docs/09-cost.md:42`

**Claim under attack:** "One node: 2× EPYC 9534 (128 cores total), 256 GB RAM, ... ~$40,520
refurbished." — followed by the observation that the node is "memory-bound" with "67% of its
CPU stranded".

**Why it fails:** 256 GiB across 128 cores is **2 GiB per core**, which is *below* Cloudflare's
own floor of "Minimum 3 GiB memory per vCPU"
(<https://developers.cloudflare.com/containers/platform/limits/>, verified). The document then
reports "memory-bound" as a fact of nature rather than a purchasing decision, and never asks
what the alternative costs. At 2026 DDR5 prices — 64 GB RDIMMs quoted in the **$870 to $2,790**
range depending on the quarter (BELIEVED: search snippets only, I did not fetch a price page;
the channel is in an AI-driven DRAM squeeze) — going to 384 GiB adds roughly **$1,750–$4,750**,
i.e. 4–12% of capex, and lifts capacity from 21.33 to **32** container-equivalents:

| config | capex | node-month | per container-month | break-even |
|---|---|---|---|---|
| 256 GiB (as printed) | $40,520 | $2,443 | $114.50 | 39.1% |
| 384 GiB (+$1,750) | $42,270 | $2,479 | $77.50 | 26.5% |
| 384 GiB (+$4,750) | $45,270 | $2,542 | $79.40 | 27.1% |

A 12-point swing in the break-even — larger than the combined effect of power, colo and transit,
which the document spends two sections arguing about. The model optimises the wrong variable.

**What to do instead:** Either price a memory-balanced node (384–512 GiB) and re-derive, or
state explicitly that the comparison deliberately uses a 2 GiB/core box because that is what the
listing sells, and that a memory-balanced build moves the break-even to ~27%.

---

### [MINOR] 0.55 kW is a 60%-load figure used under an explicit 100%-duty assumption

**Where:** `docs/09-cost.md:34`, assumption `docs/09-cost.md:148`

**Claim under attack:** `power      0.55 kW × 730 h × PUE 1.54 × $0.1447/kWh  = $89` — with
`| Duty cycle | 100% for the comparison |`

**Why it fails:** The research says where 0.55 kW comes from: "2 × 280 W CPU TDP ... plus ~120 W
platform plus fans, **at ~60% average duty**, idling near 220 W" (`lane-10:77`). But the
headline comparison is explicitly at 100% duty. At 100% duty the CPUs alone draw 560 W, plus
platform, 8 SAS SSDs, fan power and PSU losses — the wall figure is ~0.85–0.95 kW, which is
consistent with the 1.0–1.2 kW dual-Genoa anchor the research itself cites. At 0.9 kW: power
$146, colo $180, node-month **$2,570**, per container-month **$120.50**, break-even **41.1%** —
which pushes the break-even *above* the "~40% duty cycle" rule the README advertises, and turns
the document's own 24% example from "Cloudflare 38% cheaper" into "Cloudflare 42% cheaper".

You cannot assume 100% utilisation to make the denominator favourable and 60% load to make the
power line cheap. The research's own defence ("even doubling the figure only adds $200/month,
8%") is true of the node-month but not of the break-even, which is the number the document
actually sells.

**What to do instead:** Use ~0.9 kW at 100% duty and ~0.55 kW at 60%, and show the break-even
for both. Or drop the 100%-duty framing and present the whole model at a stated load.

---

### [NIT] "10 TB/month costs $250" ignores the 1 TB included allotment

**Where:** `docs/09-cost.md:100-102`

**Claim under attack:** "A container pushing 10 TB/month out of Cloudflare costs $250 in egress
alone"

**Why it fails:** The verified rate card includes an allotment: "North America & Europe |
$0.025 | **1 TB**". (10,000 − 1,024) × $0.025 = **$224.40**. Small, but it is a derived number
that does not follow from the rate the document quotes two lines above.

**What to do instead:** $224.40, and show the subtraction.

---

### [NIT] Cost of capital is omitted, and the research already computed it

**Where:** `docs/09-cost.md:33`

**Claim under attack:** `hardware   $40,520 / 48 months                       = $844`

**Why it fails:** Straight-line amortisation at a 0% discount rate. $40,520 up front is not the
same as $844/month for 48 months. At 8%, the annuity payment is **$989/month** — $145 more,
+5.9% on both the node-month and cost per container-month, break-even 39.1% → 41.4%. The
research computed this (`lane-10:181`: "at an 8% discount rate the 48-month amortisation is
really ~$989/month, +$145") and the published document drops it, along with any mention of the
$40,520 × N cash requirement.

**What to do instead:** Add a line `cost of capital  8% over 48 months = $145` and say the
$40,520 is due on day one.

---

## What the document gets right

- **The 6-hour inactivity ceiling is real and exact.** I expected "6 hours" to be folklore. It
  is not: `setInactivityTimeout()` "must be greater than 0 and at most 6 hours
  (`21600000`)" and the promise "rejects when `durationMs` is greater than 6 hours"
  (<https://developers.cloudflare.com/containers/api/durable-object-container/>, verified). The
  `sleepAfter` default of 10 minutes of no *incoming requests* is also real
  (<https://developers.cloudflare.com/containers/api/container-class/>). This is the strongest
  constraint in the document and it is correctly stated.
- **The Cloudflare rate card reproduces to the cent.** All three per-second rates and the
  `standard-4` shape (4 vCPU / 12 GiB / 20 GB) are exactly as published; $292.76 is right; the
  1.78× vCPU and 2.02× memory ratios against Fargate are right. Likewise EIA August 2026
  Commercial 14.47 ¢ and Industrial 9.64 ¢ are exactly as printed in Table 5.6.A.
- **48 months is defensible for this gear**, contrary to my expectation — because the listing
  ships a 5-year return-to-base warranty, so the amortisation period sits inside the warranty.
  The document's failure is not the number, it is never saying why.

## Unanswered questions

- What does the fleet cost at a *purchasable* staffing level — 1.0 FTE plus on-call rotation?
  The document's own node model implies ~$18,400/month; the table says $10,800.
- What is AWS Fargate's monthly bill for the same 200-container CI fleet at 24% duty? (Answer
  from the document's own quoted rates: $7,577. The document never prints it.)
- Will Cloudflare quote instances above 4 vCPU / 12 GiB, and at what $/vCPU-second? The limits
  page says the maximums "can be increased"; the pricing page has no rate card. This single
  answer decides whether the capability argument survives.
- What does redundancy cost? The container-equivalent figure assumes a node that is up 100% of
  the time; a single node with return-to-base warranty is not. N+1 across four tiers is not
  priced anywhere.
- What does the 3-node SeaweedFS actually deliver against R2's eleven nines, and what is that
  durability gap worth? The "~80 TB / 2.5×" row compares $/GB without comparing durability.
- Is the £30,495 ByteStock price ex-VAT? A UK trade site normally quotes ex-VAT but the page
  does not say; if it is VAT-inclusive, capex drops 20% and the break-even moves ~3 points.
- Who answers the pager at 03:00, and is that person inside the 0.5 FTE or additional?
- What happens at month 49? No residual, no refresh capex, no disposal cost is modelled.
- The fleet table's "3 × CI node (16c / 64 GiB / 2 TB NVMe) ~$1,800" has no derivation and does
  not correspond to any node spec used elsewhere in the document.
