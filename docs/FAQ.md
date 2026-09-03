# FAQ

The questions this project gets asked, and the answers — including the ones that
are least flattering.

---

### Why can't you just measure how risky a drug is?

FAERS records problems, never safe use. You learn that 1,400 people reported a
tendon rupture while taking a drug; you never learn how many took it and were fine.
The denominator does not exist, so absolute risk is uncomputable — permanently, by
any method.

What *is* computable is **disproportionality**: whether a reaction is reported more
often with one drug than with all other drugs. Both sides of that comparison come
from the same database, so the unknown denominator appears twice and cancels. Every
statistic here is a variation on that one move.

### Why four statistics instead of one?

They disagree in informative ways. ROR is better-behaved when the *reaction* is
rare; PRR is more stable when the *drug* is rare; Yates-corrected chi-square guards
against extreme ratios built from tiny counts; the Information Component applies
Bayesian shrinkage and is the only one honest about `a = 3` being weak evidence
however extreme the ratio looks.

### Why require all three criteria rather than a majority?

Because a majority was measurably worse. At "2 of 3" the engine flags 61 pairs, of
which only 43 are real — precision 64.2%. Every false positive sits between PRR 1.05
and 1.22.

That is not an arithmetic bug. Two of the three criteria (ROR lower CI > 1, IC₀₂₅ > 0)
test only whether an association is *distinguishable from zero*. Neither carries a
minimum effect size, and at N = 373,446 an **8% elevation** clears both. Only Evans's
PRR criterion demands PRR ≥ 2, and at "2 of 3" the two significance-only criteria
could outvote it.

Requiring all three makes the effect-size floor mandatory: false alarms go from 18 to
0. It costs recall — 43 real pairs found drops to 33 — and every one lost is
weak-tier. That is a real trade, not a free lunch.

**The general point:** as N grows, statistical significance stops being evidence of
importance.

### Isn't testing on data you generated yourself circular?

It is the opposite, and it is the reason the synthetic corpus exists.

Curated reference sets for pharmacovigilance do exist (OMOP, EU-ADR), but they are
small, contested and drug-class specific — you cannot get a clean precision and
recall on real FAERS inside a self-contained project. Planted ground truth is the
only way to compute either, or to draw a detection curve at all.

The corpus tests the **detector**. Real FDA data produces **findings**. Different
jobs; the same SQL runs on both.

### What does "signal strength" actually mean?

The **injection rate**: the share of that drug's reports carrying the planted side
effect on top of its normal background. It is *not* a percentage change in the
reporting ratio.

At the 7.5% floor the association surfaces as roughly a **2.2x** reporting ratio.
The strongest planted signals (34%) reach about **12x**.

### What was the hardest correctness problem?

Not the statistics — the drug names. `SINGULAIR`, `Singulair 10mg` and
`MONTELUKAST SODIUM` are one exposure. Left separate, one real signal splits into
several under-powered fragments and **disappears with no error raised anywhere**.
Silent absence is far more dangerous than a crash.

The fix that mattered was structural rather than a patch: define the normalisation
once and push *both* sides of the join through it. That turned a whole class of bug
into an impossibility instead of a bug that had been fixed.

### Why is every staging column a VARCHAR?

Because FAERS is dirty in specific, documented ways. `event_dt` arrives as YYYYMMDD,
YYYYMM or YYYY depending on what the reporter knew — a DATE column rejects two of the
three. If staging enforced types the loader would silently drop those rows and the
pipeline would under-report with no error anywhere. Loading as text means bad rows
arrive intact and get **counted** by the quality gates, where they are visible.

### What does the deduplication actually remove?

FAERS is versioned: an amended case is republished in full with the same `caseid` and
a higher `caseversion`, and both rows sit in the extract. Count rows and amended cases
count twice — and amendment is more likely for *serious* cases, so the bias inflates
exactly the events that matter. Versions also span quarters, so the max must be taken
across the whole window. Separately, the FDA retracts cases in a file most published
analyses ignore.

Together: **46,784 rows, 11.1% of the raw data.**

### Why key the time series on receipt date rather than event onset?

Two reasons. About 38% of cases have an absent or partial onset date, and it is not
missing at random — older and foreign reports are worse — so an onset-keyed series
would drop a third of the data non-randomly. And the question being asked is "when
could a regulator have known?", which a regulator can only answer once the report has
arrived.

Note the subtlety: it must be the date the FDA **first** received the case, not the
receipt date of the latest amendment. Keying on the amendment would place a case
first reported in 2019 entirely in 2023 and remove it from every quarter in between.

### Does a signal mean the drug causes the reaction?

No, and this is the most important caveat in the project. Confounding by indication
(the underlying disease causes the event, not the drug) is the big one. Notoriety
bias: publicity drives reporting, so a news story manufactures a signal.
Litigation-driven reporting shows up as lawyer-sourced reports — which is why reporter
qualification is kept as a dimension and the clinician-reported share is surfaced.

Disproportionality generates hypotheses. It does not confirm them.

### What would you do next?

1. **Run it on real FAERS and publish Mode B** — the lead time between first
   detectable signal and the actual FDA action date. The code exists and has never
   been run on real data; that table is the single highest-value thing missing.
2. **Time-to-onset analysis.** The `THER` table has therapy start dates, so you can
   test whether the reaction plausibly follows exposure — real causality evidence
   rather than co-occurrence.
3. **Indication-stratified analysis** to attack confounding by indication directly.
   The `INDI` table is already loaded and unused.

### What is the weakest part?

The brand-to-ingredient vocabulary is hand-curated at 160 entries. Fine for the demo;
real FAERS has thousands of products and coverage would drop. The right fix is linking
RxNorm rather than curating by hand. Combination products are flagged but not yet split
into component ingredients.
