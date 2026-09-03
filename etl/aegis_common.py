"""
aegis_common.py — shared config, DB connection and run-logging helpers.

Deliberately thin. This project's logic lives in SQL; Python is here only to
move bytes off disk and into MySQL, and to record what happened. If you find
yourself writing analysis here, it belongs in sql/ instead.
"""
from __future__ import annotations

import hashlib
import os
import sys
import time
from contextlib import contextmanager
from pathlib import Path

import pymysql

REPO_ROOT = Path(__file__).resolve().parents[1]
FAERS_QUARTER_FILES = ["DEMO", "DRUG", "REAC", "OUTC", "RPSR", "THER", "INDI"]


# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
def load_config() -> dict:
    """Read config/db.env, falling back to config/db.example.env, then to the
    process environment. Real credentials never enter version control."""
    cfg: dict[str, str] = {}
    for name in ("db.example.env", "db.env"):  # db.env wins
        path = REPO_ROOT / "config" / name
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    cfg.update({k: v for k, v in os.environ.items() if k.startswith("AEGIS_")})
    return cfg


def connect(cfg: dict | None = None, database: str | None = None):
    cfg = cfg or load_config()
    return pymysql.connect(
        host=cfg.get("AEGIS_DB_HOST", "127.0.0.1"),
        port=int(cfg.get("AEGIS_DB_PORT", 3306)),
        user=cfg.get("AEGIS_DB_USER", "root"),
        password=cfg.get("AEGIS_DB_PASSWORD", ""),
        database=database if database is not None else cfg.get("AEGIS_DB_NAME", "aegis"),
        charset="utf8mb4",
        local_infile=True,       # required for LOAD DATA LOCAL INFILE
        autocommit=False,
    )


# --------------------------------------------------------------------------- #
# Quarter helpers
# --------------------------------------------------------------------------- #
def quarter_range(start: str, end: str) -> list[str]:
    """'2019Q1','2020Q2' -> ['2019Q1',...,'2020Q2']. Inclusive."""
    def parse(q):
        return int(q[:4]), int(q[-1])

    sy, sq = parse(start)
    ey, eq = parse(end)
    out, y, q = [], sy, sq
    while (y, q) <= (ey, eq):
        out.append(f"{y}Q{q}")
        q += 1
        if q == 5:
            q, y = 1, y + 1
    return out


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


# --------------------------------------------------------------------------- #
# Run logging — every stage is auditable
# --------------------------------------------------------------------------- #
@contextmanager
def run_log(conn, stage: str, object_name: str | None = None,
            quarter_code: str | None = None):
    """Context manager writing a RUNNING row on entry and finalising it on exit.

    Usage:
        with run_log(conn, 'stage_load', 'stg_demo', '2024Q1') as rl:
            ...
            rl['rows_out'] = n
    """
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO etl_run_log (stage, object_name, quarter_code) VALUES (%s,%s,%s)",
        (stage, object_name, quarter_code),
    )
    run_id = cur.lastrowid
    conn.commit()
    box: dict = {"run_id": run_id, "rows_in": None, "rows_out": None, "message": None}
    t0 = time.time()
    try:
        yield box
    except Exception as exc:
        cur.execute(
            "UPDATE etl_run_log SET finished_at=NOW(3), status='FAILED', message=%s "
            "WHERE run_id=%s",
            (f"{type(exc).__name__}: {exc}"[:4000], run_id),
        )
        conn.commit()
        raise
    else:
        cur.execute(
            "UPDATE etl_run_log SET finished_at=NOW(3), status='SUCCESS', "
            "rows_in=%s, rows_out=%s, message=%s WHERE run_id=%s",
            (box["rows_in"], box["rows_out"], box["message"], run_id),
        )
        conn.commit()
        print(f"  [{stage}] {object_name or ''} {quarter_code or ''} "
              f"rows_out={box['rows_out']} in {time.time() - t0:.1f}s", flush=True)


def log(msg: str) -> None:
    print(msg, flush=True)


def die(msg: str, code: int = 1):
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)
