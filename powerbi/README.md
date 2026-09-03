# Power BI report

`etl/export_flat.py` writes six CSVs into `flat/` at the end of every pipeline run
(five report tables plus `_manifest.csv`, which records the headline scalars for
the run that produced them). They are **deliberately pre-joined and
human-readable** — every column is named in plain English and no relationships
need creating in Power BI. Each visual comes off a single table.

Regenerate them without rebuilding the warehouse:

```bash
python etl/export_flat.py
```

Build time from scratch: about 25 minutes.

---

## 1. Load the data

**Home → Get data → Text/CSV**, once per file in `powerbi/flat/`:

| File | Rows | What it is |
|---|---:|---|
| `Signals.csv` | 3,160 | every drug–side-effect pair with its statistics and verdict |
| `Emergence.csv` | 850 | quarterly signal score per pair, for the time series |
| `Backtest.csv` | 33 | how many quarters each detected signal took to surface |
| `DetectionCurve.csv` | 4 | recall by planted signal strength — the operating limit |
| `DataQuality.csv` | 12 | the executable quality assertions and their results |

Choose **Import**, not DirectQuery. The whole model is under 5,000 rows, so it fits
in memory and every interaction is instant.

**Do not create relationships.** The tables are independent by design; each page
reads from exactly one of them. This removes the single most common source of wrong
numbers in a student Power BI model.

### Key columns in `Signals.csv`

- `Status` — `Signal` or `Ordinary`. This is the verdict; filter on it.
- `ReferenceSetStatus` — `In reference set` / `Not in reference set` / `n/a`. The second value
  is the interesting one.
- `Reported` vs `Expected` — observed co-reports vs what chance predicts.
- `TimesMoreThanExpected` — the ratio. **Always display `Reported` beside it**; a
  30x ratio on 5 reports and a 3x ratio on 5,000 are different claims.
- `SignalScore` — the conservative Bayesian score (IC₀₂₅). Above 0 = detectable.

---

## 2. Four pages

### Page 1 — Signal Triage (from `Signals`)
- **Cards:** count of `Drug` filtered to `Status = "Signal"` (33); count of all rows
  (3,160); sum of `Reported`; count filtered to `ReferenceSetStatus = "Not in reference set"` (6)
- **Scatter:** X = `Expected`, Y = `Reported`, legend = `Status`, details = `Drug`.
  **Set both axes to logarithmic** — counts span four orders of magnitude and a
  linear axis collapses everything interesting into one corner. This is the single
  most explanatory visual in the report: signals are the points that break away
  from the diagonal.
- **Table** sorted by `SignalScore` desc: Drug, SideEffect, Reported, Expected,
  TimesMoreThanExpected, PctFatal — filtered to `Status = "Signal"`
- **Slicers:** `OrganClass`, `ReferenceSetStatus`

### Page 2 — How signals emerge (from `Emergence`)
- **Line chart:** X = `Quarter` (sort by `QuarterOrder`), Y = `SignalScore`,
  legend = `Pair`. Filter the legend to 5 pairs or it becomes unreadable.
- Add a **constant line at Y = 0** labelled "detection threshold". Where a line
  crosses it is the quarter that signal became detectable — the clearest single
  picture of what the project does.
- **Slicer:** `Drug`

### Page 3 — Where it stops working (from `DetectionCurve` + `Backtest`)
This is the page that makes the project credible rather than merely impressive.
- **Column chart:** X = `SignalStrength` (sort by `SortOrder`), Y = `RecallPct`.
  Colour the two 100% bars one colour and the 20% / 0% bars another.
- **Card:** average of `QuartersToDetect` from `Backtest` (2.82)
- **Column chart:** X = `DetectionSpeed`, Y = count of `Drug` from `Backtest`
- **Text box:** "Reliable above a 7.5% injection rate; below that recall drops
  sharply. Every missed pair still passed 2 of the 3 statistical tests — they fail
  only the one demanding a large effect, which is the same rule keeping false alarms
  at zero."

### Page 4 — Data quality (from `DataQuality`)
- **Table:** all columns; conditional-format `Result` green for PASS
- **Card:** count where `Result = "PASS"` (12 of 12)
- **Text box:** "FAIL severity means our pipeline is wrong and the run is blocked.
  WARN means the source data is messy and we are disclosing it — the FDA data
  genuinely has 12% missing sex and 38% partial dates."

---

## 3. Design rules

- **One accent colour** for Signal, neutral grey for Ordinary. The reader has one
  question — *is this worth my attention?* — and colour should answer it.
- **Log scales on the scatter.** Non-negotiable; see above.
- **Never label anything "causes".** Use *signal*, *disproportionate reporting*, or
  *warrants review*.
- Keep the caveat text boxes. A dashboard that hides its limitations is less
  trustworthy, not more.

---

## 4. Note on the `.pbix`

A `.pbix` is a binary containing a compiled Analysis Services model, which only
Power BI Desktop can produce — it cannot be generated from outside the application.
An attempt to hand-generate the `.pbit` template equivalent is not included here
because it could not be verified to open correctly, and shipping an unverified
binary is worse than shipping none.

The CSVs above are the reliable path and take about five minutes to load.

**Exporting for people without Power BI:** File → Export → PDF. Keep that PDF in
`docs/presentation/` so the report can be shown without installing anything.
