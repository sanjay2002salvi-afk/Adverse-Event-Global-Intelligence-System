"""
build_diagrams.py — render the three chart PNGs embedded in README.md.

    python etl/export_dashboard_data.py       # dump numbers from MySQL
    python docs/diagrams/build_diagrams.py    # render the PNGs

These were originally browser screenshots of the dashboard. That was a mistake in
three separate ways: the axis labels were clipped by the viewport, two paragraphs
of body prose were baked into the image as unselectable pixels, and — worst — the
tier bounds shown in the picture had gone stale relative to the data, so the
README's hero image contradicted the caption directly beneath it. A chart drawn
from the same JSON the dashboard uses cannot drift from it.

Palette matches the dashboard: teal for full recall, amber for partial, coral for
none. Checked for adjacent-hue separation under deuteranopia.
"""
from __future__ import annotations

import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
DATA = json.load(open(REPO / "docs" / "dashboard" / "dashboard_data.json"))

TEAL, CORAL, AMBER, INK, MUTE, GRID = "#0f8b7e", "#eb6834", "#eda100", "#1a2230", "#68717f", "#dfe4ea"
plt.rcParams.update({
    "font.family": "DejaVu Sans", "font.size": 13,
    "axes.edgecolor": GRID, "axes.labelcolor": INK, "text.color": INK,
    "xtick.color": MUTE, "ytick.color": MUTE, "figure.facecolor": "white",
    "axes.facecolor": "white", "savefig.facecolor": "white",
})


def pc(v: float) -> str:
    v = float(v)
    return f"{v:.0f}" if abs(v - round(v)) < 1e-9 else f"{v:.1f}"


def detection_curve(out: Path) -> None:
    cv = DATA["curve"]
    labels = [f"{r['tier_label']}\n{pc(r['excess_min_pct'])}–{pc(r['excess_max_pct'])}%"
              for r in cv]
    vals = [float(r["recall_pct"]) for r in cv]
    cols = [TEAL if v >= 99 else (AMBER if v > 0 else CORAL) for v in vals]

    fig, ax = plt.subplots(figsize=(9.4, 4.6))
    bars = ax.bar(labels, vals, color=cols, width=0.62, zorder=3)
    for b, r, v in zip(bars, cv, vals):
        cx = b.get_x() + b.get_width() / 2
        ax.text(cx, v + 3.2, f"{v:.0f}%", ha="center", va="bottom",
                fontsize=15, fontweight="bold", color=INK)
        # A zero bar has no inside, so the count would collide with the 0% label.
        inside = v > 12
        ax.text(cx, 3.5 if inside else v + 12.5,
                f"{r['detected']} of {r['planted']}", ha="center", va="bottom",
                fontsize=11, color="white" if inside else MUTE)
    ax.set_ylim(0, 118)
    ax.set_yticks([0, 25, 50, 75, 100])
    ax.yaxis.set_major_formatter(FuncFormatter(lambda y, _: f"{y:.0f}%"))
    ax.set_ylabel("Planted signals recovered")
    ax.set_xlabel("Planted signal strength — injection rate, the share of that "
                  "drug's reports carrying the side effect", labelpad=12)
    ax.grid(axis="y", color=GRID, zorder=0)
    for sp in ("top", "right", "left"):
        ax.spines[sp].set_visible(False)
    ax.tick_params(axis="both", length=0)
    fig.tight_layout()
    fig.savefig(out, dpi=170)
    plt.close(fig)


def signal_scatter(out: Path) -> None:
    pts = DATA["scatter"]
    ordinary = [(float(r["expected"]), r["a"]) for r in pts if not r["is_signal"]]
    signals = [(float(r["expected"]), r["a"], r["ingredient"], r["pt"])
               for r in pts if r["is_signal"]]

    fig, ax = plt.subplots(figsize=(9.4, 5.6))
    ax.scatter([x for x, _ in ordinary], [y for _, y in ordinary], s=7,
               color="#b8c0cc", alpha=0.55, linewidths=0, zorder=2,
               label=f"Ordinary — no signal ({len(ordinary):,})")
    ax.scatter([x for x, _, _, _ in signals], [y for _, y, _, _ in signals], s=52,
               color=CORAL, edgecolor="white", linewidths=1.2, zorder=4,
               label=f"Flagged as a signal ({len(signals)})")
    lo = max(1, min(min(x for x, _ in ordinary), min(y for _, y in ordinary)))
    hi = max(max(x for x, _ in ordinary), max(y for _, y in ordinary)) * 1.15
    ax.plot([lo, hi], [lo, hi], ls="--", color=MUTE, lw=1.3, zorder=3,
            label="Exactly as expected")
    ax.set_xscale("log"); ax.set_yscale("log")
    ax.set_xlabel("Expected together by chance")
    ax.set_ylabel("Actually reported together")
    ax.grid(True, which="major", color=GRID, zorder=0)
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    ax.legend(loc="upper left", frameon=False, fontsize=11)
    fig.tight_layout()
    fig.savefig(out, dpi=170)
    plt.close(fig)


def signal_emergence(out: Path) -> None:
    qs = DATA["quarters"]
    qi = {q: i for i, q in enumerate(qs)}
    series: dict[tuple[str, str], list] = {}
    for r in DATA["timeseries"]:
        series.setdefault((r["ingredient"], r["pt"]), []).append(r)
    colours = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"]

    fig, ax = plt.subplots(figsize=(9.4, 5.0))
    ax.axhline(0, ls="--", color=MUTE, lw=1.4, zorder=2)
    ax.text(len(qs) * 0.55, 0.09, "alarm threshold", ha="left", va="bottom",
            fontsize=11, color=MUTE)
    for (ing, pt), rows in list(series.items())[:5]:
        rows.sort(key=lambda r: qi[r["quarter_code"]])
        xs = [qi[r["quarter_code"]] for r in rows]
        ys = [float(r["ic025"]) for r in rows]
        c = colours[len(ax.lines) % len(colours)]
        ax.plot(xs, ys, color=c, lw=2.4, zorder=4,
                label=f"{ing.title()} → {pt.title()}")
        cross = next((i for i, y in enumerate(ys) if y > 0), None)
        if cross is not None:
            ax.scatter([xs[cross]], [ys[cross]], s=62, color=c,
                       edgecolor="white", linewidths=1.6, zorder=5)
    ax.set_xticks(range(0, len(qs), 4))
    ax.set_xticklabels([qs[i] for i in range(0, len(qs), 4)])
    ax.set_ylabel("Signal score (IC₀₂₅)")
    ax.set_xlabel("Quarter — evidence accumulating over time", labelpad=10)
    ax.grid(axis="y", color=GRID, zorder=0)
    for sp in ("top", "right"):
        ax.spines[sp].set_visible(False)
    # Below the axes, not inside them: five series names are wide enough that any
    # in-plot placement covered either the threshold line or the crossings, which
    # are the two things the chart exists to show.
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.22), ncol=2,
              frameon=False, fontsize=10.5)
    fig.tight_layout()
    fig.savefig(out, dpi=170, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    for name, fn in [("detection-curve", detection_curve),
                     ("signal-scatter", signal_scatter),
                     ("signal-emergence", signal_emergence)]:
        out = HERE / f"{name}.png"
        fn(out)
        print(f"wrote {out.relative_to(REPO)} ({out.stat().st_size/1024:.0f} KB)")
