#!/usr/bin/env python3
"""Draw lines of text files as a PNG (for docs/img/make_test.png and quartus_timing.png).

    python3 -I tools/text_png.py docs/img/make_test.png --theme dark --title '$ make test' \\
        --count PASS --count FAIL --mark PASS docs/logs/make-test.txt:1-12,-8

Each source is FILE or FILE:SPEC, drawn as one panel headed by its path.  SPEC
selects 1-based lines: "3-10", "34-39", "-8" (the last eight), comma-separated.
Selected lines are copied unchanged (long lines wrap); every gap between the
selected ranges becomes one "... N lines not shown ..." line, followed by how
many lines of the whole file contain each --count word, so a shortened log
never hides a failure.  The panel header names the selected lines, so lines
before the first and after the last range are not marked again.  --mark colours the lines that contain a word.
Needs Pillow; nothing here is part of `make test`.
"""
from __future__ import annotations

import argparse
import sys
import textwrap
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SCALE = 2
THEMES = {
    # surface, panel, header ink, text ink, muted ink, mark ink, mark band
    "dark": dict(surface="#0f1115", panel="#161a20", head="#9aa4b2", ink="#d7dae0",
                 muted="#7d8590", mark="#56d364", band=None),
    "light": dict(surface="#fcfcfb", panel="#ffffff", head="#52514e", ink="#0b0b0b",
                  muted="#898781", mark="#0b0b0b", band="#fbf0c2"),
}


def font(size: int) -> ImageFont.FreeTypeFont:
    for name in ("DejaVuSansMono.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"):
        try:
            return ImageFont.truetype(name, size * SCALE)
        except OSError:
            continue
    sys.exit("text_png.py: DejaVu Sans Mono not found")


def select(lines: list[str], spec: str | None) -> list[int]:
    """0-based indices of the lines a SPEC picks, in file order."""
    if not spec:
        return list(range(len(lines)))
    picked: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if part.startswith("-"):
            picked.update(range(max(0, len(lines) - int(part[1:])), len(lines)))
        elif "-" in part:
            a, b = (int(x) for x in part.split("-"))
            picked.update(range(a - 1, min(b, len(lines))))
        else:
            picked.add(int(part) - 1)
    bad = [i + 1 for i in picked if not 0 <= i < len(lines)]
    if bad:
        sys.exit(f"text_png.py: line(s) {bad} outside the file ({len(lines)} lines)")
    return sorted(picked)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out", type=Path)
    p.add_argument("sources", nargs="+", metavar="FILE[:SPEC]")
    p.add_argument("--theme", choices=sorted(THEMES), default="light")
    p.add_argument("--title", default="")
    p.add_argument("--wrap", type=int, default=104, help="wrap lines longer than this many characters")
    p.add_argument("--count", action="append", default=[], help="word to count in the whole file at each gap")
    p.add_argument("--mark", action="append", default=[], help="lines containing this word are highlighted")
    args = p.parse_args(argv)
    th = THEMES[args.theme]

    # Build the rows first: (kind, text) with kind in title, head, line, gap, blank.
    rows: list[tuple[str, str]] = []
    if args.title:
        rows += [("title", args.title), ("blank", "")]
    for n, src in enumerate(args.sources):
        path, _, spec = src.partition(":")
        lines = Path(path).read_text().splitlines()
        idx = select(lines, spec or None)
        if n:
            rows.append(("blank", ""))
        rows.append(("head", path + (f"  (lines {spec})" if spec else "")))
        prev = idx[0] - 1 if idx else -1
        for i in idx:
            if i > prev + 1:
                counts = ", ".join(f"{sum(w in l for l in lines)} contain {w}" for w in args.count)
                gap = i - prev - 1
                rows.append(("gap", f"... {gap} line{'s' * (gap != 1)} not shown"
                             + (f"; of all {len(lines)} lines, {counts}" if counts else "") + " ..."))
            text = lines[i].expandtabs(8)
            kind = "mark" if any(w in text for w in args.mark) else "line"
            for k, piece in enumerate(textwrap.wrap(text, args.wrap, drop_whitespace=False,
                                                    replace_whitespace=False) or [""]):
                rows.append((kind, piece if k == 0 else "    " + piece))
            prev = i

    s = SCALE
    f_text, f_title = font(13), font(14)
    char_w = f_text.getlength("M")
    line_h = 19 * s
    pad = 18 * s
    width = int(pad * 2 + max(f_title.getlength(t) + char_w * 2 if k == "title" else char_w * (len(t) + 2)
                              for k, t in rows))
    height = int(pad * 2 + line_h * len(rows))
    img = Image.new("RGB", (width, height), th["surface"])
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([s, s, width - s, height - s], radius=8 * s, fill=th["panel"])
    y = pad
    for kind, text in rows:
        x = pad + char_w
        if kind == "mark" and th["band"]:
            d.rectangle([pad, y - 2 * s, width - pad, y + line_h - 4 * s], fill=th["band"])
        fill = {"title": th["ink"], "head": th["head"], "gap": th["muted"],
                "mark": th["mark"], "line": th["ink"]}.get(kind, th["ink"])
        d.text((pad if kind in ("title", "head") else x, y), text,
               font=f_title if kind == "title" else f_text, fill=fill)
        y += line_h
    args.out.parent.mkdir(parents=True, exist_ok=True)
    img.save(args.out, optimize=True)
    print(f"{args.out}: {len(rows)} rows from {len(args.sources)} source(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
