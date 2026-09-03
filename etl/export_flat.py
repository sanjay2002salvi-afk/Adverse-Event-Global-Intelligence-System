"""
export_flat.py — write the five Power BI input CSVs from the finished warehouse.

    python etl/export_flat.py            # -> powerbi/flat/*.csv

WHY THIS FILE EXISTS:
Until it did, powerbi/flat/*.csv were hand-produced snapshots committed once and
never regenerated, while README.md claimed "every figure is regenerated on each
run". That is the most corrosive kind of documentation error: it is not wrong
about a number, it is wrong about whether the numbers can be trusted to still
match the code. A reader who changes a threshold in sql/06_signal, re-runs, and
sees identical CSVs has learned that the published output is decorative.

WHY CSV AND NOT A DIRECT POWER BI CONNECTION:
Power BI can talk to MySQL directly, and for a production refresh it should.
Flat files are chosen here so the repository is inspectable without a database:
a reviewer can open Signals.csv on GitHub and check any figure in the README
against it in ten seconds, with no MySQL install and no credentials. The cost is
that the extract is a point in time, which is why every file carries the run's
observation window in _manifest.csv.

COLUMN NAMING:
Column names are the analyst-facing names, not the warehouse names — `Reported`
rather than `a`, `TimesMoreThanExpected` rather than `prr`. Power BI field names
end up on axis labels and card titles in front of non-technical readers, and
renaming 16 columns by hand in Power Query is exactly the kind of manual step
that silently diverges from the source.
"""
from __future__ import annotations

import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from aegis_common import REPO_ROOT, connect, load_config, log  # noqa: E402

OUT_DIR = REPO_ROOT / "powerbi" / "flat"

# (filename, header, SQL). Ordered as the Power BI report consumes them.
EXPORTS: list[tuple[str, list[str], str]] = [
    (
        "Signals.csv",
        ["Drug", "SideEffect", "OrganClass", "Reported", "Expected",
         "TimesMoreThanExpected", "PRR", "ROR", "SignalScore", "Status",
         "ReferenceSetStatus", "PctSerious", "PctFatal",
         "PctRechallengePositive", "PctClinicianReported", "EverFlagged",
         "FirstFlagged"],
        """
        SELECT ingredient, pt, soc, a, ROUND(expected,1),
               ROUND(a/NULLIF(expected,0),2), ROUND(prr,2), ROUND(ror,2),
               ROUND(ic025,3),
               CASE WHEN is_signal = 1 THEN 'Signal' ELSE 'Ordinary' END,
               CASE WHEN is_known_labelled = 1 THEN 'In reference set'
                    ELSE 'Not in reference set' END,
               pct_serious, pct_death, pct_rechallenge_pos, pct_health_prof,
               CASE WHEN ever_signalled = 1 THEN 'Yes' ELSE 'No' END,
               first_signal_quarter
        FROM bi_signal_current
        ORDER BY is_signal DESC, ic025 DESC, a DESC
        """,
    ),
    (
        "Emergence.csv",
        ["Drug", "SideEffect", "Pair", "Quarter", "QuarterOrder", "SignalScore",
         "Reported", "PairOutcome"],
        """
        SELECT dd.ingredient, dr.pt, CONCAT(dd.ingredient,' - ',dr.pt),
               t.quarter_code, q.quarter_ord, ROUND(t.ic025,3), t.a,
               t.pair_outcome
        FROM bi_signal_timeseries t
        JOIN dim_drug     dd ON dd.drug_key     = t.drug_key
        JOIN dim_reaction dr ON dr.reaction_key = t.reaction_key
        JOIN dim_quarter  q  ON q.quarter_code  = t.quarter_code
        ORDER BY dd.ingredient, dr.pt, q.quarter_ord
        """,
    ),
    (
        "Backtest.csv",
        ["Drug", "SideEffect", "StartedIn", "DetectedIn", "QuartersToDetect",
         "ReportsAtDetection", "DetectionSpeed"],
        """
        SELECT ingredient, pt, emergence_quarter, detected_quarter,
               lag_quarters, a_at_detection,
               CASE
                 WHEN lag_quarters = 0 THEN '0 - same quarter'
                 WHEN lag_quarters <= 2 THEN '1-2 - within six months'
                 WHEN lag_quarters <= 4 THEN '3-4 - within a year'
                 ELSE '5+ - over a year'
               END
        FROM backtest_vs_truth
        WHERE was_detected = 1
        ORDER BY lag_quarters, ingredient
        """,
    ),
    (
        "DetectionCurve.csv",
        ["SignalStrength", "MinInjectionRatePct", "MaxInjectionRatePct",
         "Planted", "Detected", "RecallPct", "SortOrder"],
        """
        SELECT tier_label, excess_min_pct, excess_max_pct, planted, detected,
               recall_pct, sort_order
        FROM bi_detection_curve
        ORDER BY sort_order
        """,
    ),
    (
        "DataQuality.csv",
        ["CheckID", "Assertion", "Severity", "Measured", "Threshold", "Result"],
        """
        SELECT check_id, check_name, severity, measured, threshold, status
        FROM bi_data_quality
        ORDER BY check_id
        """,
    ),
]

MANIFEST_SQL = """
SELECT metric, COALESCE(value_text, CAST(value_num AS CHAR))
FROM bi_kpi ORDER BY display_ord, metric
"""


def write_csv(path: Path, header: list[str], rows) -> int:
    # utf-8-sig: Power BI's Text/CSV connector reads a BOM-less UTF-8 file as
    # the system ANSI codepage on Windows, which turns every non-ASCII character
    # in a drug or reaction name into mojibake at import time. The BOM is the
    # documented way to force UTF-8 detection.
    with path.open("w", newline="", encoding="utf-8-sig") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(header)
        n = 0
        for r in rows:
            w.writerow(["" if v is None else v for v in r])
            n += 1
    return n


def main() -> int:
    cfg = load_config()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    conn = connect(cfg)
    try:
        cur = conn.cursor()
        log(f"Exporting Power BI extracts to {OUT_DIR.relative_to(REPO_ROOT)}/")
        for name, header, sql in EXPORTS:
            cur.execute(sql)
            rows = cur.fetchall()
            if len(header) != (len(rows[0]) if rows else len(header)):
                raise RuntimeError(
                    f"{name}: {len(header)} header names but "
                    f"{len(rows[0])} columns returned — the header and the "
                    f"SELECT have drifted apart."
                )
            n = write_csv(OUT_DIR / name, header, rows)
            log(f"  {name:<20} {n:>7,} rows")

        # A manifest so any published figure can be traced to the run that
        # produced it, without re-reading the whole extract.
        cur.execute(MANIFEST_SQL)
        n = write_csv(OUT_DIR / "_manifest.csv", ["Metric", "Value"], cur.fetchall())
        log(f"  {'_manifest.csv':<20} {n:>7,} rows")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
