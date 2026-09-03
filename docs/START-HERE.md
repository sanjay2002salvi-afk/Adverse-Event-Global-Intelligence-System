# Start here

Everything in this project, in the order it makes sense to read it.

This is **Sanjay Salvi's** AEGIS — Adverse Event Global Intelligence System.
Open the dashboard with `python serve_dashboard.py` if you want it in a browser
without touching the files.

---

## If you have 5 minutes

**Open [`presentation/AEGIS-explained.pdf`](presentation/AEGIS-explained.pdf).**

19 slides, one idea each, plain English. It answers *what is this, why does it
matter, what did it find, and what does it not prove* — in that order. Every slide
has speaker notes with what to say and what not to claim.

The `.pptx` beside it is the editable version.

## If you have 15 minutes

**Open [`dashboard/AEGIS-dashboard.html`](dashboard/AEGIS-dashboard.html)** in any
browser. It is a single self-contained file — no server, no Power BI, no internet.

It walks the same story with the real numbers, live: a worked example of the core
idea, the detection curve, the six signals with no FDA warning, and every dense
table tucked behind an expand-on-click so it never overwhelms.

## If you want the answers to the obvious questions

[`FAQ.md`](FAQ.md) — why absolute risk is uncomputable, why four statistics, why the
strict operating point, what "signal strength" means, what the deduplication removes,
and what this does not prove.

## If you want to see whether the engineering is real

- [`engineering/performance.md`](engineering/performance.md) — measured timings,
  the covering-index experiment (3.2x), the partition-pruning experiment (5.0x).
- [`engineering/critical-review.md`](engineering/critical-review.md) — a written
  teardown of everything wrong with the first version, and how each was fixed.
  Includes the two defects that were open and are now closed.
- [`../powerbi/README.md`](../powerbi/README.md) — how to build the Power BI report
  from the shipped CSVs.
- [`../README.md`](../README.md) — the technical overview and how to run it.
- [`FAQ.md`](FAQ.md) — the questions this gets asked, answered.

---

## The 60-second version, in case you read nothing else

Some drug side effects are too rare to appear in clinical trials. They only surface
once millions of people are taking the medicine, buried in reports filed to the FDA.
Those reports are public, free, and usually sit unexamined for years before a
warning appears on the label.

**This project measures that gap.** It is a MySQL warehouse that reads the reports,
cleans them properly, and computes for every drug–side-effect pair the exact quarter
the evidence first became statistically detectable.

The hard part is proving a detector like this works at all — on real data nobody
knows the true answer. So the project generates a synthetic corpus with **43
dangerous pairs hidden inside it at deliberately varying strengths**, and scores
itself. It finds **33 of 43 with zero false alarms out of 3,160 candidates**, and —
more usefully — it publishes exactly where it stops working: reliable above about
**7.5% injection rate**, degrading sharply below that.

Six of the pairs it finds were deliberately held back from its own benchmark. All
six are FDA-labelled in reality — they were withheld so the pipeline had something
to return from outside its answer key. That is a capability check, not a discovery.

**It does not prove causation, and it cannot measure risk.** Those limits are
stated everywhere the numbers appear, deliberately.
