"""
download_faers.py — fetch and unpack FDA FAERS quarterly ASCII extracts.

    python etl/download_faers.py                    # uses config quarter range
    python etl/download_faers.py 2023Q1 2025Q1      # explicit range

Source: https://fis.fda.gov/extensions/FPD-QDE-FAERS/FPD-QDE-FAERS.html
Each quarter is a ~60-250 MB zip containing an ascii/ folder with the seven
'$'-delimited files plus a deleted-cases file.

Downloads are skipped when a file of the expected size already exists, so this
is safe to re-run over a flaky connection.

NOTE ON DATA VOLUME: the complete 2004-present archive is roughly 40 GB
unpacked and takes many hours to ingest on a laptop. Start with a 3-5 year
window. Every downstream stage is quarter-incremental, so widening the window
later is additive — you do not rebuild from scratch.
"""
from __future__ import annotations

import io
import sys
import zipfile
from pathlib import Path

import urllib.request
import urllib.error

# Must precede the aegis_common import, not follow it. The old placement was
# inside `if __name__ == "__main__"` at the bottom of the file, so it only ever
# ran after the import it exists to enable had already succeeded — by accident,
# because sys.path[0] is etl/ when the file is run as a script. Importing this
# module from anywhere else raised ImportError.
sys.path.insert(0, str(Path(__file__).parent))

from aegis_common import REPO_ROOT, load_config, quarter_range, log, die  # noqa: E402

# FDA has used several URL spellings over the years; try each.
URL_TEMPLATES = [
    "https://fis.fda.gov/content/Exports/faers_ascii_{y}q{q}.zip",
    "https://fis.fda.gov/content/Exports/faers_ascii_{y}Q{q}.zip",
    "https://fis.fda.gov/content/Exports/faers_ascii_{y}q{q}.ZIP",
]
UA = {"User-Agent": "AEGIS-Adverse-Event-Global-Intelligence-System/1.0 (https://github.com/sanjay2002salvi-afk/Adverse-Event-Global-Intelligence-System)"}


def fetch_quarter(quarter: str, raw_dir: Path) -> Path | None:
    year, q = quarter[:4], quarter[-1]
    dest_dir = raw_dir / quarter
    ascii_dir = dest_dir / "ascii"
    if ascii_dir.exists() and any(ascii_dir.glob("DEMO*.txt")):
        log(f"  {quarter}: already unpacked, skipping")
        return dest_dir

    dest_dir.mkdir(parents=True, exist_ok=True)
    last_err = None
    for tmpl in URL_TEMPLATES:
        url = tmpl.format(y=year, q=q)
        try:
            log(f"  {quarter}: downloading {url}")
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=600) as resp:
                blob = resp.read()
            log(f"  {quarter}: {len(blob) / 1e6:.1f} MB downloaded, unpacking")
            with zipfile.ZipFile(io.BytesIO(blob)) as zf:
                zf.extractall(dest_dir)
            # Normalise: some quarters unpack to ASCII/ rather than ascii/
            for cand in ("ASCII", "Ascii"):
                p = dest_dir / cand
                if p.exists() and not ascii_dir.exists():
                    p.rename(ascii_dir)
            return dest_dir
        except (urllib.error.HTTPError, urllib.error.URLError, zipfile.BadZipFile) as exc:
            last_err = exc
            continue
    log(f"  {quarter}: FAILED ({last_err}) — skipping")
    return None


def main(argv: list[str]) -> int:
    cfg = load_config()
    if len(argv) >= 2:
        start, end = argv[0], argv[1]
    else:
        start = cfg.get("AEGIS_START_QUARTER", "2019Q1")
        end = cfg.get("AEGIS_END_QUARTER", "2025Q1")

    raw_dir = REPO_ROOT / cfg.get("AEGIS_RAW_DIR", "data/raw")
    raw_dir.mkdir(parents=True, exist_ok=True)

    quarters = quarter_range(start, end)
    log(f"Fetching {len(quarters)} quarters: {quarters[0]} .. {quarters[-1]}")
    ok = sum(1 for q in quarters if fetch_quarter(q, raw_dir) is not None)
    log(f"Done: {ok}/{len(quarters)} quarters available under {raw_dir}")
    if ok == 0:
        die("No quarters downloaded. Check your network, or download manually "
            "from https://fis.fda.gov/extensions/FPD-QDE-FAERS/FPD-QDE-FAERS.html "
            "and unpack into data/raw/<QUARTER>/ascii/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
