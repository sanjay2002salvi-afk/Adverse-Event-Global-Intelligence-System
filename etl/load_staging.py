"""
load_staging.py — bulk-load FAERS ASCII extracts into the staging layer.

    python etl/load_staging.py                 # config quarter range
    python etl/load_staging.py 2023Q1 2025Q1   # explicit range
    python etl/load_staging.py --demo          # load the bundled demo corpus
    python etl/load_staging.py --demo --force  # reload even if checksums match

WHY LOAD DATA LOCAL INFILE AND NOT executemany():
The DRUG file alone runs to ~4M rows per quarter. Row-by-row INSERT through the
client protocol runs at roughly 5-10k rows/sec, i.e. ~10 minutes per quarter per
file. LOAD DATA pushes the parse into the server and sustains 200k+ rows/sec —
about two orders of magnitude faster. On a 24-quarter load that is the
difference between an afternoon and a week.

SCHEMA DRIFT:
FAERS column sets are not stable across quarters (FDA has added and renamed
fields). Rather than hardcoding a column order, this loader reads the header
line of each file and builds the LOAD DATA column list from it, binding unknown
source columns to a throwaway @variable. A quarter that gains a new column loads
fine and simply ignores it, instead of silently shifting every field one to the
left — which is the classic way FAERS pipelines corrupt themselves.

MALFORMED ROWS:
FAERS free-text fields occasionally contain an unescaped '$', which shifts the
remaining fields on that row. LOAD DATA does not reject these; it pads or
truncates and raises a warning. We count those warnings per file and persist the
count, so the quality gate in sql/02_quality/ can surface them instead of
letting them pass unnoticed.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from aegis_common import (  # noqa: E402
    FAERS_QUARTER_FILES, REPO_ROOT, connect, load_config, log,
    quarter_range, run_log, sha256_file,
)

TARGET_TABLE = {k: f"stg_{k.lower()}" for k in FAERS_QUARTER_FILES}


def table_columns(cur, table: str) -> list[str]:
    cur.execute(
        "SELECT COLUMN_NAME FROM information_schema.COLUMNS "
        "WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=%s ORDER BY ORDINAL_POSITION",
        (table,),
    )
    return [r[0] for r in cur.fetchall()]


def sniff(path: Path) -> tuple[list[str], str]:
    """Return (header columns lowercased, line terminator)."""
    with path.open("rb") as fh:
        head = fh.read(65536)
    terminator = "\r\n" if b"\r\n" in head else "\n"
    first = head.split(terminator.encode(), 1)[0].decode("utf-8", errors="replace")
    cols = [c.strip().lower() for c in first.split("$")]
    return cols, terminator


def load_file(conn, path: Path, table: str, quarter: str, file_kind: str,
              force: bool = False) -> int:
    cur = conn.cursor()

    # Checksum gate. sql/00_setup/00_create_database.sql documents ingest_ledger
    # as skipping unchanged files; until this block existed it wrote the digest
    # and never read it back, so the documented behaviour did not exist.
    digest = sha256_file(path)
    if not force:
        cur.execute(
            "SELECT sha256, row_count FROM ingest_ledger "
            "WHERE quarter_code = %s AND file_kind = %s", (quarter, file_kind))
        prior = cur.fetchone()
        if prior and prior[0] == digest:
            log(f"    {file_kind} {quarter}: unchanged (sha256 match) — skipped")
            return int(prior[1])

    tgt_cols = set(table_columns(cur, table))
    src_cols, terminator = sniff(path)

    # Map each source column either to a real column or to a discard variable.
    bind, seen = [], set()
    for i, c in enumerate(src_cols):
        if c in tgt_cols and c != "src_quarter" and c not in seen:
            bind.append(f"`{c}`")
            seen.add(c)
        else:
            bind.append(f"@discard_{i}")

    if not seen:
        raise RuntimeError(
            f"{path.name}: no source column matched {table}. "
            f"Header was: {src_cols[:8]}"
        )

    # Idempotency: clear this quarter's existing rows first. Without it a
    # re-run appends a second full copy of the quarter to every stg_* table,
    # silently doubling every downstream count — and the module docstring and
    # sql/00_setup/00_create_database.sql both promised re-runs were safe.
    # It only escaped notice because run_pipeline.py drops the database first.
    cur.execute(f"DELETE FROM {table} WHERE src_quarter = %s", (quarter,))
    conn.commit()

    sql = (
        f"LOAD DATA LOCAL INFILE %s INTO TABLE {table} "
        f"CHARACTER SET utf8mb4 "
        f"FIELDS TERMINATED BY '$' "
        f"LINES TERMINATED BY %s "
        f"IGNORE 1 LINES ({', '.join(bind)}) "
        f"SET src_quarter = %s"
    )
    cur.execute(sql, (str(path), terminator, quarter))
    rows = cur.rowcount
    cur.execute("SHOW COUNT(*) WARNINGS")
    warn = cur.fetchone()[0]
    conn.commit()

    missing = sorted(tgt_cols - seen - {"src_quarter"})
    if missing:
        log(f"    note: {file_kind} {quarter} had no source column for {missing}")
    if warn:
        log(f"    note: {warn} field-level warnings on {file_kind} {quarter} "
            f"(unescaped '$' in free text) — see quality gate DQ-006")

    cur.execute(
        "REPLACE INTO ingest_ledger (quarter_code, file_kind, source_file, sha256, row_count) "
        "VALUES (%s,%s,%s,%s,%s)",
        (quarter, file_kind, path.name, digest, rows),
    )
    conn.commit()
    return rows


def find_quarter_files(raw_dir: Path, quarter: str) -> dict[str, Path]:
    """Locate the seven data files plus the deleted-cases file for a quarter.
    FDA is inconsistent about casing and folder depth, so search recursively."""
    base = raw_dir / quarter
    found: dict[str, Path] = {}
    if not base.exists():
        return found
    for p in base.rglob("*.txt"):
        name = p.name.upper()
        if "DELETED" in name:
            found["DELETED"] = p
            continue
        for kind in FAERS_QUARTER_FILES:
            # DEMO24Q1.txt -> kind DEMO
            if name.startswith(kind) and kind not in found:
                found[kind] = p
    return found


def load_quarter(conn, raw_dir: Path, quarter: str, force: bool = False) -> None:
    files = find_quarter_files(raw_dir, quarter)
    if not files:
        log(f"  {quarter}: no files found under {raw_dir / quarter} — skipping")
        return
    log(f"  {quarter}: found {len(files)} files")
    for kind in FAERS_QUARTER_FILES:
        if kind not in files:
            log(f"    {kind}: MISSING")
            continue
        with run_log(conn, "stage_load", TARGET_TABLE[kind], quarter) as rl:
            rl["rows_out"] = load_file(conn, files[kind], TARGET_TABLE[kind],
                                       quarter, kind, force)
    if "DELETED" in files:
        with run_log(conn, "stage_load", "stg_deleted_cases", quarter) as rl:
            rl["rows_out"] = load_file(
                conn, files["DELETED"], "stg_deleted_cases", quarter, "DELETED", force
            )


def main(argv: list[str]) -> int:
    cfg = load_config()
    demo = "--demo" in argv
    force = "--force" in argv
    argv = [a for a in argv if not a.startswith("--")]

    raw_dir = REPO_ROOT / ("data/demo" if demo else cfg.get("AEGIS_RAW_DIR", "data/raw"))
    if demo:
        # data/demo/** is gitignored (244 MB of generated fixture), so on a fresh
        # clone this directory does not exist at all. iterdir() would raise
        # FileNotFoundError and the helpful message below would never print —
        # the first thing a new reader saw would be a traceback.
        if not raw_dir.is_dir():
            log(f"No demo corpus at {raw_dir}.")
            log("Generate it first:  python etl/make_demo_corpus.py")
            return 1
        quarters = sorted(p.name for p in raw_dir.iterdir() if p.is_dir())
        if not quarters:
            log("No demo corpus found. Run: python etl/make_demo_corpus.py")
            return 1
        log(f"DEMO MODE — loading {len(quarters)} synthetic quarters from {raw_dir}")
    else:
        start = argv[0] if len(argv) >= 2 else cfg.get("AEGIS_START_QUARTER", "2019Q1")
        end = argv[1] if len(argv) >= 2 else cfg.get("AEGIS_END_QUARTER", "2025Q1")
        quarters = quarter_range(start, end)
        log(f"Loading {len(quarters)} quarters: {quarters[0]} .. {quarters[-1]}")

    conn = connect(cfg)
    try:
        # MySQL 8.0 ships with the SERVER-side local_infile OFF. The client flag
        # we pass is necessary but not sufficient, and the resulting error 1148
        # ("The used command is not allowed with this MySQL version") names
        # neither the variable nor the fix. Fail here, with the fix, instead.
        cur = conn.cursor()
        cur.execute("SELECT @@GLOBAL.local_infile")
        if not cur.fetchone()[0]:
            log("ERROR: the MySQL server has local_infile = OFF, so LOAD DATA "
                "LOCAL INFILE is refused.")
            log("Fix (as an admin user, once):  SET GLOBAL local_infile = ON;")
            return 1

        for q in quarters:
            load_quarter(conn, raw_dir, q, force)
        cur = conn.cursor()
        cur.execute("""
            SELECT 'stg_demo' t, COUNT(*) n FROM stg_demo
            UNION ALL SELECT 'stg_drug', COUNT(*) FROM stg_drug
            UNION ALL SELECT 'stg_reac', COUNT(*) FROM stg_reac
            UNION ALL SELECT 'stg_outc', COUNT(*) FROM stg_outc
            UNION ALL SELECT 'stg_indi', COUNT(*) FROM stg_indi
            UNION ALL SELECT 'stg_ther', COUNT(*) FROM stg_ther
            UNION ALL SELECT 'stg_rpsr', COUNT(*) FROM stg_rpsr
            UNION ALL SELECT 'stg_deleted_cases', COUNT(*) FROM stg_deleted_cases
        """)
        log("\nStaging row counts:")
        for t, n in cur.fetchall():
            log(f"  {t:<20} {n:>12,}")
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
