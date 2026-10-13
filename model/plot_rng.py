#!/usr/bin/env python3
"""Plot the die-face histograms and the lag autocorrelation from build/rng_analysis.json.

    uv run --with matplotlib python3 model/plot_rng.py build/rng_analysis.json docs/img/die_histogram.png

Panels 1 and 2: counts of the six faces for the two analysed seeds with the
expected count N/6 as a line.  Panel 3: lag-1..8 autocorrelation of the
die-value sequence for both seeds with the 95 % band for independent draws.
Palette: categorical slots 1 and 2 of the dataviz reference palette (blue,
orange; validated for CVD separation and contrast on the light surface).
Needs matplotlib, so it is not part of the standard-library path; every
number comes from the JSON that model/rng_analysis.py wrote.
"""
from __future__ import annotations

import json
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402

# Palette: two categorical hues (blue, orange) for the two seeds, text/axis tokens for the chrome.
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SERIES = ["#2a78d6", "#eb6834"]


def style(ax) -> None:
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(AXIS)
        ax.spines[side].set_linewidth(1)
    ax.tick_params(colors=MUTED, labelcolor=INK2, length=0, labelsize=9)
    ax.yaxis.grid(True, color=GRID, linewidth=1)
    ax.set_axisbelow(True)


def face_panel(ax, entry: dict, color: str) -> None:
    style(ax)
    u = entry["window"]["uniformity"]
    n = u["draws"]
    exp = u["expected_per_face"]
    faces = [str(k + 1) for k in range(6)]
    bars = ax.bar(faces, u["counts"], width=0.56, color=color, linewidth=0)
    ax.axhline(exp, color=INK2, linewidth=1.5, zorder=3)
    ax.text(0.995, exp, "N/6", transform=ax.get_yaxis_transform(), ha="right", va="bottom", fontsize=7.5, color=INK2,
            bbox=dict(facecolor=SURFACE, edgecolor="none", pad=0.8), zorder=4)
    top = max(u["counts"] + [exp])
    for bar, c, dev in zip(bars, u["counts"], u["relative_deviation"]):
        ax.text(bar.get_x() + bar.get_width() / 2, c + 0.015 * top, f"{c / 1000:,.1f}K\n{dev * 100:+.1f} %",
                ha="center", va="bottom", fontsize=7.5, color=INK2, linespacing=1.1, zorder=4,
                bbox=dict(facecolor=SURFACE, edgecolor="none", pad=1.0))
    ax.set_ylim(0, top * 1.30)
    ax.set_xlabel("face", color=INK2, fontsize=9.5)
    ax.set_ylabel("count", color=INK2, fontsize=9.5)
    ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v / 1000:g}K" if v else "0"))
    pr = entry["period"]
    note = (f"cycle of {pr['lam']} states entered after {pr['mu']:,} CA steps" if pr["found"]
            else f"no cycle within {pr['hare_steps']:,} Brent steps")
    ptxt = "p < 1e-300" if u["p_value"] < 1e-300 else f"p = {u['p_value']:.3g}"
    ax.set_title(f"{entry['label']} seed {entry['seed_hex']}, {n:,} draws\n"
                 f"chi-square = {u['chi2']:,.1f} ({u['dof']} dof), {ptxt}\n{note}",
                 fontsize=9.5, color=INK, loc="left", pad=8)


def lag_panel(ax, seeds: list[dict]) -> None:
    style(ax)
    band = seeds[0]["window"]["autocorrelation"]["band95"]
    ax.axhspan(-band, band, color=MUTED, alpha=0.12, linewidth=0)
    ax.axhline(0, color=AXIS, linewidth=1)
    width = 0.36
    lim = band * 3
    for k, e in enumerate(seeds):
        ac = e["window"]["autocorrelation"]
        lags = [x["lag"] + (k - 0.5) * (width + 0.04) for x in ac["lags"]]
        rs = [x["r"] for x in ac["lags"]]
        ax.bar(lags, rs, width=width, color=SERIES[k], linewidth=0, label=f"{e['label']} seed")
        lim = max(lim, max(abs(r) for r in rs) * 1.3)
    ax.set_ylim(-lim, lim)
    ax.set_xticks(range(1, 9))
    ax.set_xlabel("lag (draws)", color=INK2, fontsize=9.5)
    ax.set_ylabel("autocorrelation of die values", color=INK2, fontsize=9.5)
    ax.text(0.98, 0.03, f"grey band: ±{band:.4f}, 95 % band for i.i.d. draws", color=INK2, fontsize=8,
            ha="right", va="bottom", transform=ax.transAxes)
    leg = ax.legend(loc="upper left", frameon=False, fontsize=8.5, labelcolor=INK2)
    for t in leg.get_texts():
        t.set_color(INK2)
    ax.set_title("Lag autocorrelation of the die values, both seeds\n(the dependence is in the face parity bit; section 3)",
                 fontsize=9.5, color=INK, loc="left", pad=8)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
    seeds = d["seeds"][:2]

    plt.rcParams.update({"font.family": ["DejaVu Sans", "sans-serif"], "text.color": INK, "axes.labelcolor": INK2})
    fig, axes = plt.subplots(1, 3, figsize=(14, 4.6), dpi=100, facecolor=SURFACE)
    fig.subplots_adjust(left=0.055, right=0.985, top=0.76, bottom=0.16, wspace=0.30)
    for ax, e, color in zip(axes[:2], seeds, SERIES):
        face_panel(ax, e, color)
    lag_panel(axes[2], seeds)
    fig.text(0.055, 0.02, "Source: build/rng_analysis.json (model/rng_analysis.py). Draws are die(state[j]) = (state[j] mod 6) + 1 "
             "with en held at 1; the horizontal line is the expected count N/6 of a fair die.", fontsize=8, color=MUTED)
    os.makedirs(os.path.dirname(os.path.abspath(argv[2])), exist_ok=True)
    fig.savefig(argv[2], dpi=100, facecolor=SURFACE)
    print(f"wrote {argv[2]} ({os.path.getsize(argv[2]):,} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
