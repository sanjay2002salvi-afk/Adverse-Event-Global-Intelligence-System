"""
export_dashboard_data.py — dump everything docs/dashboard/build_dashboard.py needs.

    python etl/export_dashboard_data.py     # -> docs/dashboard/dashboard_data.json

The dashboard is a single self-contained HTML file with no server and no runtime
database connection, so every number on it has to be baked in at build time. This
script is the only place those numbers are read from MySQL; the builder is pure
presentation and cannot invent a figure that is not in this file.

That separation is deliberate. The first version of the dashboard had its headline
numbers typed directly into the HTML template, so a pipeline change produced a new
database and an unchanged web page — and there was no way to tell by looking.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from aegis_common import REPO_ROOT, connect, load_config, log  # noqa: E402

OUT = REPO_ROOT / "docs" / "dashboard" / "dashboard_data.json"

QUERIES: dict[str, str] = {
    "kpi": "SELECT metric, value_num, value_text FROM bi_kpi ORDER BY display_ord, metric",
    "curve": """SELECT strength_tier, tier_label, excess_min_pct, excess_max_pct,
                       planted, detected, recall_pct, sort_order
                  FROM bi_detection_curve ORDER BY sort_order""",
    "scatter": """SELECT ingredient, pt, soc, a, expected, prr, ic025, is_signal,
                         is_known_labelled, pct_death, pct_serious
                    FROM bi_signal_current""",
    "novel": """SELECT ingredient, pt, soc, a, ROUND(expected,1) AS expected,
                       ROUND(a/NULLIF(expected,0),2) AS times_more, prr, ic025,
                       pct_serious, pct_death, first_signal_quarter
                  FROM bi_signal_current
                 WHERE is_signal = 1 AND is_known_labelled = 0
                 ORDER BY ic025 DESC""",
    "top_signals": """SELECT ingredient, pt, soc, a, ROUND(expected,1) AS expected,
                             ROUND(a/NULLIF(expected,0),2) AS times_more, prr, ic025,
                             pct_serious, pct_death, pct_rechallenge_pos,
                             pct_health_prof, first_signal_quarter, is_known_labelled
                        FROM bi_signal_current
                       WHERE is_signal = 1
                       ORDER BY ic025 DESC""",
    "backtest": """SELECT ingredient, pt, emergence_quarter AS reference_quarter,
                          detected_quarter, lag_quarters, a_at_detection
                     FROM backtest_vs_truth WHERE was_detected = 1
                    ORDER BY lag_quarters, ingredient""",
    "dq": """SELECT check_id, check_name, severity, measured, threshold, status
               FROM bi_data_quality ORDER BY check_id""",
    "dedup": "SELECT metric, value, pct_of_raw FROM dedup_summary ORDER BY metric",
    "coverage": """SELECT match_method, COUNT(*) AS distinct_names,
                          SUM(n_rows) AS drug_rows,
                          ROUND(100.0*SUM(n_rows)/(SELECT SUM(n_rows) FROM drug_name_map),3)
                            AS pct_of_rows
                     FROM drug_name_map GROUP BY match_method ORDER BY match_method""",
    "quarters": "SELECT quarter_code FROM dim_quarter ORDER BY quarter_ord",
    # Transient crossings: pairs that met all three criteria at some quarter and
    # have since fallen back below them. Published rather than filtered out —
    # they are the difference between the two precision figures.
    "transient": """SELECT ingredient, pt, first_signal_quarter, last_signal_quarter,
                           n_quarters_signalling, a_at_detection,
                           ROUND(prr_at_detection,2) AS prr_at_detection
                      FROM signal_first_detection WHERE is_sustained = 0
                      ORDER BY ingredient""",
}

# Five illustrative trajectories for the emergence chart, chosen for SPREAD IN
# DETECTION QUARTER rather than for strength. Taking the top five by score gives
# five pairs that were already above the threshold in the first quarter, so the
# chart whose entire caption is "watch the moment a signal crosses the line"
# showed no line crossing anything. Sampling evenly across the ordered list of
# detection quarters gives one early, one late, and three in between.
SERIES_KEYS_SQL = """
SELECT CONCAT(ingredient,'||',pt) AS k
FROM bi_signal_current
WHERE is_signal = 1 AND first_signal_quarter IS NOT NULL
ORDER BY first_signal_quarter, ic025 DESC
"""
TIMESERIES_SQL = """
SELECT dd.ingredient, dr.pt, t.quarter_code, t.ic025, t.a
FROM bi_signal_timeseries t
JOIN dim_drug     dd ON dd.drug_key     = t.drug_key
JOIN dim_reaction dr ON dr.reaction_key = t.reaction_key
JOIN dim_quarter  q  ON q.quarter_code  = t.quarter_code
WHERE CONCAT(dd.ingredient,'||',dr.pt) IN ({})
ORDER BY dd.ingredient, dr.pt, q.quarter_ord
"""


def fetch(cur, sql: str) -> list[dict]:
    cur.execute(sql)
    cols = [c[0] for c in cur.description]
    out = []
    for row in cur.fetchall():
        rec = {}
        for c, v in zip(cols, row):
            rec[c] = float(v) if hasattr(v, "as_tuple") else v
        out.append(rec)
    return out


def main() -> int:
    cfg = load_config()
    conn = connect(cfg)
    try:
        cur = conn.cursor()
        data: dict = {k: fetch(cur, q) for k, q in QUERIES.items()}
        data["quarters"] = [r["quarter_code"] for r in data["quarters"]]

        cur.execute(SERIES_KEYS_SQL)
        ordered = [r[0] for r in cur.fetchall()]
        n_series = min(5, len(ordered))
        step = (len(ordered) - 1) / max(1, n_series - 1) if n_series > 1 else 1
        keys, seen = [], set()
        for i in range(n_series):
            k = ordered[round(i * step)]
            if k not in seen:
                seen.add(k); keys.append(k)
        for k in ordered:                    # top up if rounding collided
            if len(keys) >= n_series:
                break
            if k not in seen:
                seen.add(k); keys.append(k)
        data["series_keys"] = keys
        placeholders = ",".join(["%s"] * len(keys))
        cur.execute(TIMESERIES_SQL.format(placeholders), keys)
        cols = [c[0] for c in cur.description]
        data["timeseries"] = [
            {c: (float(v) if hasattr(v, "as_tuple") else v) for c, v in zip(cols, row)}
            for row in cur.fetchall()
        ]
    finally:
        conn.close()

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data, default=str))
    log(f"wrote {OUT.relative_to(REPO_ROOT)} "
        f"({OUT.stat().st_size/1024:.0f} KB, {len(data)} sections)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
