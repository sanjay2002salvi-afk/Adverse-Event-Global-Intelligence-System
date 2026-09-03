# What was wrong with v1, and what I changed

Written after the first build, before the v2 rebuild. It stays in the repo because
a list of what was wrong is more useful to a reader than a claim that nothing was.

---

## The failure that matters most

**I could not explain my own project out loud.**

That is not a documentation gap. It is the product failing at its primary job — and
I only noticed when I tried to describe it to somebody.

Every artefact in v1 — README, dashboard, code comments — was written for an
imagined hostile interviewer. Not one was written for the person who actually has
to *present* it, which is me. The README opened with:

> "A SQL-native pharmacovigilance signal-detection warehouse over FDA
> adverse-event reports, with a measured detection backtest."

That sentence transfers zero understanding to anyone who does not already know
what pharmacovigilance is. It is written to impress, not to explain — and those
are different goals that happen to use the same words.

Everything below is downstream of this one mistake.

---

## Specific defects

### 1. The dashboard opened with its most expert-only chart
A log-log scatter of expected vs observed co-reports was the first visual on the
page. That chart is the *conclusion* of understanding disproportionality, not an
introduction to it. A newcomer saw a grey diagonal smear and learned nothing.

**Fixed:** the page now explains the idea in plain language with a worked example
first, and the scatter appears afterwards, as evidence for a claim already made.

### 2. Jargon before meaning
"Disproportionality", "IC₀₂₅", "BCPNN", "PRR" all appeared before any sentence a
non-specialist could parse.

**Fixed:** every technical term is now introduced by the plain-English version of
the idea, and the statistical names are given afterwards as labels for something
already understood.

### 3. Dark by default
v1 honoured `prefers-color-scheme`, so on a machine set to dark mode it rendered
dark — which is what happened. For an artefact whose entire purpose is being shown
to other people (recruiters, teammates, friends), inheriting the *viewer's* OS
preference is the wrong default.

**Fixed:** light by default, always. Dark is opt-in via the toggle.

### 4. Caveat before value
The first element after the title was a grey box explaining that the data was
synthetic. Correct information, catastrophic placement — the reader had not yet
been told what the thing *was*, so the first thing they learned was a reason to
distrust it.

**Fixed:** the caveat now sits with the results it qualifies, where it reads as
rigour rather than as an apology.

### 5. No hierarchy — everything at once
A single 3,966-pixel page carrying three charts and four tables, all at equal
visual weight. When everything is equally prominent, nothing is prominent.

**Fixed:** a clear narrative spine, with the dense reference tables (11 quality
assertions, drug-name resolution, cleaning breakdown) moved behind expand-on-click
sections. They are still there; they are no longer in the way.

### 6. The acronym was never expanded
"AEGIS" appeared roughly forty times across the repo without once being spelled
out prominently.

**Fixed:** expanded in the first line of the page and the deck.

### 7. The headline result reads as circular
"100% precision on data we generated ourselves" sounds like cheating until you
explain *why* synthetic ground truth is the only way to measure a detector at all.
v1 buried that explanation in a Limitations section at the very bottom.

**Fixed:** the reasoning now appears immediately before the number, not after.

### 8. The core concept had no picture
Everything in the project rests on one 2×2 contingency table. In v1 that table
existed only as a markdown grid inside the README.

**Fixed:** the idea is now shown as a worked numeric example on the page itself —
one real drug, expected count vs observed count.

### 9. Weight for no benefit
589 KB of HTML, 3,290 individually-drawn SVG circles, of which ~3,130 are
undifferentiated background noise, each carrying its own tooltip attributes.

**Fixed — and it took two attempts, which is the part worth recording.** The first
"fix" only reduced the opacity of the background points. The page was still 587 KB
and still contained 3,290 `<circle>` elements; I had changed how they looked and
written "Fixed" against a defect about how much they weighed. I only caught it
because I checked the byte count instead of trusting my own changelog entry. A
review document that reports a defect as fixed when it is not is worse than one
that never mentioned it.

The actual fix collapses the ~3,100 ordinary points into a single SVG `<path>` of
arc subpaths — no per-point tooltips, because hovering an undifferentiated cloud
tells a reader nothing — while the 33 signal points stay individual and
interactive. Same picture, a third of the bytes.

### 10. No presentation material at all
I had to *present* this — to interviewers, and to two collaborators. v1 produced a
README, a dashboard and a spec, and nothing that could go on a screen in front of
a room.

**Fixed:** an 19-slide deck, large type, one idea per slide, with speaker notes.

---

## The two defects that were flagged and are now FIXED

These were listed as open in the first pass. Both have since been closed, and the
fixes changed the headline result — for the better, by making it honest.

### A. The evaluation was not adversarial — FIXED
The original corpus planted every association at 16–34% excess reporting. Scoring
100% precision and 100% recall against that is a real result on an **easy test
set**, and it says nothing about where the method breaks.

The corpus now plants **43 signals across four strength tiers spanning a 23-fold
range**, from 34% excess down to 1.5%. Scoring each tier separately produces a
detection curve:

| Tier | Excess reporting | Planted | Found | Recall |
|---|---|---:|---:|---:|
| Strong | 16–34% | 27 | 27 | 100% |
| Moderate | 7.5–12% | 5 | 5 | 100% |
| Weak | 4–6% | 5 | 1 | 20% |
| Very weak | 1.5–3% | 6 | 0 | 0% |

The result is a **stated operating limit**: reliable above 7.5% injection rate,
degrading sharply below. Precision remains 100% — zero false positives out of 3,160
candidates. Notably, every missed pair still satisfied 2 of the 3 criteria; they
fail only the effect-size test, which is the same rule holding false positives at
zero. The misses are the explicit price of the precision.

`tests/02_detection_curve.sql` computes this and asserts the curve is monotonic in
signal strength — if a weaker tier ever outscores a stronger one, the planting or
the scoring is broken, and that now fails loudly.

### B. The project could not demonstrate its own value proposition — FIXED
Originally every planted signal was already FDA-labelled by construction, so
"signals not yet known to regulators" was permanently zero and the stated purpose
of the project was undemonstrable.

The corpus now includes pairs **deliberately withheld from the regulatory reference
set**. Six of them are detected. All six are FDA-labelled in reality — withholding
them is what makes them a test rather than a discovery, and I have been careful that
no artefact describes them as things "the FDA has never flagged", because that would
be false. What they demonstrate is narrower and still worth having: a detector that
can only rediscover the contents of its own reference set has not been shown to
generalise beyond it. These six show that this one does.

---

## What v1 got right, and kept

- The pipeline itself is sound, tested end to end, and reproducible from an empty
  database in in about seven and a half minutes.
- The three bugs found by measurement — the significance/effect-size failure, the
  quality gate that could not fire, the normaliser applied to only one side of a
  join — are genuine, and are the most interesting material in the project.
- The deduplication and quality-gate work is rigorous and is the part most
  published FAERS analyses skip.
