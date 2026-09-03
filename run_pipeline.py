"""
run_pipeline.py — execute the whole pipeline, in order, with gates.

    python etl/make_demo_corpus.py             # generate the fixture first (~3 min)
    python run_pipeline.py --demo              # then run against it
    python run_pipeline.py                     # real FAERS from config quarters
    python run_pipeline.py --demo --skip-load  # re-run analysis SQL only, keep
                                              # the database and loaded staging rows

Stages run in dependency order. A FAIL-severity data-quality violation aborts
the run before anything reaches the BI layer: a dashboard built on data known to
be broken is worse than no dashboard, because it looks authoritative.

The `mysql` command-line client is shelled out to rather than executing through
pymysql, because several files use DELIMITER to define stored procedures, and
DELIMITER is a client-side directive that the wire protocol does not understand.
Set MYSQL_CLIENT if `mysql` is not on PATH (common on Windows, where the MySQL
installer does not always add it).
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "etl"))
from aegis_common import REPO_ROOT, connect, load_config, log  # noqa: E402

MYSQL = os.environ.get("MYSQL_CLIENT", "mysql")

# (label, path, demo_only)
STAGES: list[tuple[str, str, bool]] = [
    ("__CREATE_DB__",          "sql/00_setup/00_create_database.sql",           False),
    ("__STAGING_DDL__",        "sql/01_staging/01_staging_tables.sql",          False),
    ("__LOAD_STAGING__",       "",                                              False),
    ("staging indexes",        "sql/02_quality/01_staging_indexes.sql",         False),
    ("dedup / case_master",    "sql/02_quality/02_dedup.sql",                   False),
    ("quality gates",          "sql/02_quality/03_quality_gates.sql",           False),
    ("__DQ_GATE__",            "",                                              False),
    ("reference vocabularies", "sql/03_reference/01_reference_data.sql",        False),
    ("drug standardisation",   "sql/03_reference/02_drug_normalisation.sql",    False),
    ("dimension DDL",          "sql/04_warehouse/01_dimensions.sql",            False),
    ("fact DDL",               "sql/04_warehouse/02_fact.sql",                  False),
    ("load dimensions",        "sql/05_transform/01_load_dimensions.sql",       False),
    ("load facts",             "sql/05_transform/02_load_facts.sql",            False),
    ("signal engine",          "sql/06_signal/01_signal_engine.sql",            False),
    ("__COMPUTE_SIGNALS__",    "",                                              False),
    ("ground truth",           "tests/ground_truth.sql",                        True),
    ("FDA reference actions",  "sql/07_backtest/01_fda_safety_actions.sql",     False),
    ("backtest",               "sql/07_backtest/02_backtest.sql",               False),
    ("BI semantic layer",      "sql/08_semantic/01_bi_layer.sql",               False),
    ("detection curve table",  "sql/08_semantic/02_bi_detection_curve.sql",     True),
    ("indexes + evidence",     "sql/09_optimization/01_indexes_and_evidence.sql", False),
    ("detection curve + eval", "tests/02_detection_curve.sql",                  True),
    ("__EXPORT_FLAT__",        "",                                              False),
]


_SENTINEL = object()


def mysql_args(cfg: dict, database=_SENTINEL) -> list[str]:
    """Build the mysql client argv. The password goes via MYSQL_PWD in the
    environment (see run_sql), never on the command line where `ps` exposes it."""
    if database is _SENTINEL:
        database = cfg.get("AEGIS_DB_NAME", "aegis")
    args = [MYSQL, f"-h{cfg.get('AEGIS_DB_HOST','127.0.0.1')}",
            f"-P{cfg.get('AEGIS_DB_PORT','3306')}",
            f"-u{cfg.get('AEGIS_DB_USER','root')}",
            "--local-infile=1", "--default-character-set=utf8mb4", "--table"]
    if database:
        args.append(database)
    return args


def run_sql(cfg: dict, path: Path, database=_SENTINEL) -> None:
    env = dict(os.environ)
    pw = cfg.get("AEGIS_DB_PASSWORD", "")
    if pw:
        env["MYSQL_PWD"] = pw          # keeps the password out of `ps` output
    with path.open("rb") as fh:
        proc = subprocess.run(mysql_args(cfg, database), stdin=fh,
                              capture_output=True, env=env)
    out = proc.stdout.decode("utf-8", "replace").strip()
    err = proc.stderr.decode("utf-8", "replace").strip()
    if out:
        print(out)
    if proc.returncode != 0:
        raise RuntimeError(f"{path.name} failed:\n{err}")
    if err and "Using a password" not in err:
        print(f"  (stderr) {err}")


def dq_gate(cfg: dict) -> None:
    """Abort if any FAIL-severity quality check did not pass."""
    conn = connect(cfg)
    try:
        cur = conn.cursor()
        cur.execute("SELECT check_id, check_name, measured, threshold "
                    "FROM dq_results WHERE status = 'FAIL'")
        bad = cur.fetchall()
        cur.execute("SELECT COALESCE(SUM(status='PASS'),0), COUNT(*) FROM dq_results")
        passed, total = cur.fetchone()
    finally:
        conn.close()
    if total == 0:
        # An empty dq_results is not a pass. Without this the runner printed
        # "quality gate passed (None/0 checks)" and cheerfully published a BI
        # layer built on a database where the checks had never run.
        log("\n  DATA QUALITY GATE FAILED — dq_results is empty, so no check ran.")
        raise SystemExit(2)
    if bad:
        log("\n  DATA QUALITY GATE FAILED — refusing to build the BI layer:")
        for cid, name, measured, threshold in bad:
            log(f"    {cid}  {name}: measured {measured}, threshold {threshold}")
        raise SystemExit(2)
    log(f"  quality gate passed ({passed}/{total} checks)")


def main(argv: list[str]) -> int:
    demo = "--demo" in argv
    skip_load = "--skip-load" in argv
    cfg = load_config()

    log("=" * 74)
    log(f"AEGIS pipeline — {'DEMO (synthetic corpus)' if demo else 'REAL FAERS data'}")
    log("=" * 74)

    t_start = time.time()
    for label, rel, demo_only in STAGES:
        if demo_only and not demo:
            continue
        t0 = time.time()

        if label == "__LOAD_STAGING__":
            if skip_load:
                log("\n>> staging load  [skipped]")
                continue
            log("\n>> staging load")
            import load_staging
            args = ["--demo"] if demo else []
            if load_staging.main(args) != 0:
                return 1
            log(f"   done in {time.time() - t0:.1f}s")
            continue

        if label == "__DQ_GATE__":
            log("\n>> quality gate")
            dq_gate(cfg)
            continue

        if label == "__COMPUTE_SIGNALS__":
            log("\n>> compute signals")
            conn = connect(cfg)
            try:
                cur = conn.cursor()
                cur.callproc("sp_compute_signals", (3,))
                for res in cur.fetchall():
                    log(f"   rows written: {res[0]:,}")
                conn.commit()
            finally:
                conn.close()
            log(f"   done in {time.time() - t0:.1f}s")
            continue

        if label == "staging indexes" and skip_load:
            # These are bare ALTER TABLE ... ADD KEY statements. Re-running them
            # against tables that already carry the keys fails with error 1061
            # (duplicate key name), which aborted every --skip-load run the
            # docstring advertised.
            log("\n>> staging indexes  [skipped: --skip-load keeps the existing indexes]")
            continue

        if label == "__STAGING_DDL__":
            # This file DROPs and recreates every stg_* table, so like
            # __CREATE_DB__ it must be skipped when the caller asked to keep the
            # loaded staging data. Skipping only the load itself still wiped it.
            if skip_load:
                log("\n>> staging tables  [skipped: --skip-load keeps the loaded rows]")
                continue
            log(f"\n>> staging tables  ({rel})")
            run_sql(cfg, REPO_ROOT / rel)
            log(f"   done in {time.time() - t0:.1f}s")
            continue

        if label == "__CREATE_DB__":
            # DROP DATABASE lives in this file, so it must be skipped when the
            # caller asked to keep the staging tables. Running it under
            # --skip-load destroyed exactly what the flag promised to preserve
            # and then died in the quality gates on an empty population.
            if skip_load:
                log("\n>> create database  [skipped: --skip-load keeps the existing database]")
                continue
            log(f"\n>> create database  ({rel})")
            run_sql(cfg, REPO_ROOT / rel, database=None)
            log(f"   done in {time.time() - t0:.1f}s")
            continue

        if label == "__EXPORT_FLAT__":
            # The published CSVs are regenerated here, at the end of every run.
            # They used to be hand-made snapshots that the README described as
            # regenerated — so a threshold change in sql/06_signal produced a
            # different database and byte-identical published output.
            log("\n>> export Power BI extracts")
            import export_flat
            if export_flat.main() != 0:
                return 1
            log(f"   done in {time.time() - t0:.1f}s")
            continue

        path = REPO_ROOT / rel
        if not path.exists():
            if demo_only:
                log(f"\n>> {label}  [missing {rel} — run etl/make_demo_corpus.py first]")
                return 1
            log(f"\n>> {label}  [missing {rel}, skipping]")
            continue

        log(f"\n>> {label}  ({rel})")
        run_sql(cfg, path)
        log(f"   done in {time.time() - t0:.1f}s")

    log("\n" + "=" * 74)
    log(f"PIPELINE COMPLETE in {time.time() - t_start:.1f}s")
    log("=" * 74)
    log("\nNext: load the five CSVs in powerbi/flat/ into Power BI.")
    log("See powerbi/README.md for the page-by-page build.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
