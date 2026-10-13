#!/usr/bin/env python3
"""Reference model for the 64-bit cellular-automaton RNG and the electronic die.

The hardware (electronic-die/rtl) is a periodic one-dimensional cellular
automaton with 64 cells.  Each cell looks at four bits,

    adr = { cell[i], cell[i-1], cell[i+2], cell[i+1] }      (indices wrap mod 64)

and takes its next value from a 16-entry lookup table.  The die value is
(state mod 6) + 1.

This file is both a library and a command-line tool:

    python3 model/ca_rng.py check                     # reproduce the ModelSim run
    python3 model/ca_rng.py vectors --seed 122059 --steps 256 --out file.txt
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

WIDTH = 64
MASK = (1 << WIDTH) - 1

# ca_cell.v / ca_cell.vhd: index = adr as a 4-bit number, value = next state.
LUT = (0, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 1)


def bit(state: int, i: int) -> int:
    return (state >> (i % WIDTH)) & 1


def ca_step(state: int) -> int:
    """One clock of the CA with sel=1 (seed already loaded)."""
    nxt = 0
    for i in range(WIDTH):
        adr = (bit(state, i) << 3) | (bit(state, i - 1) << 2) | (bit(state, i + 2) << 1) | bit(state, i + 1)
        nxt |= LUT[adr] << i
    return nxt


def rng_sequence(seed: int, steps: int) -> list[int]:
    """States after the seed is loaded: element 0 is the seed itself."""
    seq = [seed & MASK]
    for _ in range(steps):
        seq.append(ca_step(seq[-1]))
    return seq


def die_value(state: int) -> int:
    return state % 6 + 1


def fmt(state: int) -> str:
    return format(state, f"0{WIDTH}b")


def cmd_check(args: argparse.Namespace) -> int:
    """Reproduce the ModelSim runs committed under sim/: seed from source_data.txt,
    every line of output_data.txt must equal the model."""
    root = Path(__file__).resolve().parent.parent
    failures = 0
    for sim in ("sim/modelsim", "sim/modelsim-vhdl"):
        d = root / "electronic-die" / sim
        seed = int((d / "source_data.txt").read_text().split()[0], 2)
        expected = [line.strip() for line in (d / "output_data.txt").read_text().splitlines() if line.strip()]
        model = [fmt(s) for s in rng_sequence(seed, len(expected) - 1)]
        bad = [i for i, (a, b) in enumerate(zip(expected, model)) if a != b]
        status = "PASS" if not bad else f"FAIL at lines {bad[:5]}"
        print(f"{sim}: {len(expected)} states from ModelSim, seed={seed}: {status}")
        failures += bool(bad)
    return 1 if failures else 0


def cmd_vectors(args: argparse.Namespace) -> int:
    seq = rng_sequence(args.seed, args.steps)
    text = "\n".join(fmt(s) for s in seq) + "\n"
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text)
    else:
        sys.stdout.write(text)
    return 0


def cmd_die(args: argparse.Namespace) -> int:
    for k, s in enumerate(rng_sequence(args.seed, args.steps)):
        print(f"{k:4d} {fmt(s)} {die_value(s)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="compare the model with the committed ModelSim output").set_defaults(fn=cmd_check)
    v = sub.add_parser("vectors", help="write expected RNG states, one 64-bit binary line per clock")
    v.add_argument("--seed", type=lambda x: int(x, 0), default=122059)
    v.add_argument("--steps", type=int, default=256)
    v.add_argument("--out", default=None)
    v.set_defaults(fn=cmd_vectors)
    d = sub.add_parser("die", help="print state and die value per clock")
    d.add_argument("--seed", type=lambda x: int(x, 0), default=122059)
    d.add_argument("--steps", type=int, default=16)
    d.set_defaults(fn=cmd_die)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
