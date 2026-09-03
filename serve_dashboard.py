#!/usr/bin/env python3
"""Serve the AEGIS results dashboard locally (no database required)."""
from __future__ import annotations

import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DASHBOARD = "docs/dashboard/AEGIS-dashboard.html"
DEFAULT_PORT = 43147


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/index.html"):
            self.path = "/" + DASHBOARD
        return super().do_GET()


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve the AEGIS dashboard")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    handler = functools.partial(Handler, directory=str(ROOT))
    httpd = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"AEGIS dashboard → http://127.0.0.1:{args.port}/")
    print(f"Serving {ROOT / DASHBOARD}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
