#!/usr/bin/env python3
"""Draw a VCD dump as a timing diagram PNG (for docs/img/die_waveform.png).

    python3 -I tools/wave_png.py build/wave/die_wave.vcd docs/img/die_waveform.png \\
        --clock clk --enable en \\
        --signal course_result "course design (%)" --signal fast_result "residue_s2 (2 stages)"

Every value in the picture is read from the VCD: one column per rising edge of
the clock, each bus cell shows the value it holds after that edge.  Columns in
which the enable signal was sampled low are shaded.  Needs Pillow; nothing
here is part of `make test`.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SCALE = 2                       # draw at 2x so the PNG stays sharp when GitHub scales it
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
SHADE = "#efeee9"
LINE = "#2a78d6"                # clock and enable traces
# Soft tints for the die faces 1..6, so the shifted repetition is visible at a glance;
# the digit in every cell carries the value, the colour only repeats it.
FACE = ["#d6e6fa", "#fde0cc", "#d9f0dd", "#f6d5e3", "#faf0c2", "#e0daf6"]


def font(size: int) -> ImageFont.FreeTypeFont:
    for name in ("DejaVuSansMono.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"):
        try:
            return ImageFont.truetype(name, size * SCALE)
        except OSError:
            continue
    sys.exit("wave_png.py: DejaVu Sans Mono not found")


def read_vcd(path: Path) -> tuple[dict[str, list[tuple[int, int]]], int]:
    """Return {signal name: [(time, value), ...]} and the last timestamp."""
    ids: dict[str, str] = {}
    changes: dict[str, list[tuple[int, int]]] = {}
    t = 0
    in_defs = True
    for raw in path.read_text().split("\n"):
        line = raw.strip()
        if not line:
            continue
        if in_defs:
            if line.startswith("$var"):
                parts = line.split()
                ids[parts[3]] = parts[4]
                changes[parts[4]] = []
            elif line.startswith("$enddefinitions"):
                in_defs = False
            continue
        if line[0] == "#":
            t = int(line[1:])
        elif line[0] == "b":
            bits, ident = line[1:].split()
            if ident in ids and all(c in "01" for c in bits):
                changes[ids[ident]].append((t, int(bits, 2)))
        elif line[0] in "01" and line[1:] in ids:
            changes[ids[line[1:]]].append((t, int(line[0])))
    return changes, t


def value_at(trace: list[tuple[int, int]], t: int) -> int:
    v = trace[0][1]
    for when, val in trace:
        if when > t:
            break
        v = val
    return v


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("vcd", type=Path)
    p.add_argument("out", type=Path)
    p.add_argument("--clock", default="clk")
    p.add_argument("--enable", default="en")
    p.add_argument("--signal", nargs=2, action="append", metavar=("NAME", "LABEL"), required=True)
    p.add_argument("--title", default="")
    p.add_argument("--note", default="")
    args = p.parse_args(argv)

    changes, t_end = read_vcd(args.vcd)
    for name in [args.clock, args.enable] + [s for s, _ in args.signal]:
        if not changes.get(name):
            sys.exit(f"wave_png.py: no signal {name!r} in {args.vcd}")
    clk = changes[args.clock]
    rises = [t for (t, v), (_, prev) in zip(clk[1:], clk) if v == 1 and prev == 0]
    if clk[0][1] == 1:
        rises.insert(0, clk[0][0])
    if len(rises) < 2:
        sys.exit("wave_png.py: fewer than two rising clock edges")
    period = rises[1] - rises[0]
    sample = period // 10           # bus values are read just after each edge

    s = SCALE
    f_label, f_small, f_cell, f_title = font(13), font(11), font(13), font(14)
    col = 34 * s                    # one rising edge per column
    left = 214 * s                  # label column
    top = (56 if args.title else 30) * s
    row_h = 34 * s
    rows = [("clk", None), (args.enable, None)] + [(label, name) for name, label in args.signal]
    n = len(rises)
    width = left + n * col + 20 * s
    height = top + len(rows) * row_h + (44 if args.note else 18) * s
    img = Image.new("RGB", (width, height), SURFACE)
    d = ImageDraw.Draw(img)

    if args.title:
        d.text((16 * s, 14 * s), args.title, font=f_title, fill=INK)
    # Edge numbers, grid lines and the shading for columns where en was sampled low.
    en = changes[args.enable]
    y0, y1 = top, top + len(rows) * row_h
    for i, t in enumerate(rises):
        x = left + i * col
        if value_at(en, t - 1) == 0:   # value present at the edge, before any update after it
            d.rectangle([x, y0, x + col, y1], fill=SHADE)
    for i, t in enumerate(rises):
        x = left + i * col
        d.line([x, y0, x, y1], fill=GRID, width=s)
        label = str(i + 1)
        w = d.textlength(label, font=f_small)
        d.text((x + (col - w) / 2, top - 18 * s), label, font=f_small, fill=MUTED)
    d.text((16 * s, top - 18 * s), "rising edge", font=f_small, fill=MUTED)

    for r, (label, name) in enumerate(rows):
        yt = top + r * row_h
        ym = yt + row_h / 2
        d.text((16 * s, ym - 8 * s), label, font=f_label, fill=INK2 if name is None else INK)
        hi, lo = yt + 8 * s, yt + row_h - 8 * s
        if r == 0:                      # clock: high for the first half of each column
            pts = []
            for i in range(n):
                x = left + i * col
                pts += [(x, lo), (x, hi), (x + col / 2, hi), (x + col / 2, lo), (x + col, lo)]
            d.line(pts, fill=LINE, width=2 * s)
        elif r == 1:                    # enable: drawn at its own change times from the VCD
            t0, t1 = rises[0], rises[0] + n * period

            def xt(when: int) -> float:
                return left + (when - t0) / period * col

            v = value_at(en, t0)
            pts = [(xt(t0), hi if v else lo)]
            for when, val in en:
                if t0 < when < t1 and val != v:
                    pts += [(xt(when), hi if v else lo), (xt(when), hi if val else lo)]
                    v = val
            pts.append((xt(t1), hi if v else lo))
            d.line(pts, fill=LINE, width=2 * s)
        else:                           # bus: one cell per column with the value after that edge
            trace = changes[name]
            vals = [value_at(trace, t + sample) for t in rises]
            i = 0
            while i < n:
                j = i
                while j + 1 < n and vals[j + 1] == vals[i]:
                    j += 1
                x_a, x_b = left + i * col + 2 * s, left + (j + 1) * col - 2 * s
                v = vals[i]
                fill = FACE[v - 1] if 1 <= v <= 6 else SURFACE
                e = 5 * s
                d.polygon([(x_a, ym), (x_a + e, hi), (x_b - e, hi), (x_b, ym), (x_b - e, lo), (x_a + e, lo)],
                          fill=fill, outline=INK2)
                txt = str(v)
                w = d.textlength(txt, font=f_cell)
                d.text(((x_a + x_b - w) / 2, ym - 8 * s), txt, font=f_cell, fill=INK)
                i = j + 1
    if args.note:
        d.text((16 * s, y1 + 14 * s), args.note, font=f_small, fill=INK2)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    img.save(args.out, optimize=True)
    print(f"{args.out}: {n} rising edges from {args.vcd}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
