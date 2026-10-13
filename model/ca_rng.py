#!/usr/bin/env python3
"""Reference model for the 64-bit cellular-automaton RNG and the electronic die.

The hardware (electronic-die/rtl) is a periodic one-dimensional cellular
automaton with 64 cells.  Each cell looks at four bits,

    adr = { cell[i], cell[i-1], cell[i+2], cell[i+1] }      (indices wrap mod 64)

and takes its next value from a 16-entry lookup table.  The die value is
(state mod 6) + 1.

This file is both a library and a command-line tool:

    python3 model/ca_rng.py check                     # reproduce the ModelSim run
    python3 model/ca_rng.py vectors --seed 122059 --steps 256 --out states.txt --die-out die.txt
    python3 model/ca_rng.py die --seed 122059 --steps 16
    python3 model/ca_rng.py selftest                  # ca_step_fast == ca_step
"""
from __future__ import annotations

import argparse
import random
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


def ca_step_fast(state: int) -> int:
    """Same result as ca_step(state), computed on the whole 64-bit word at once.

    Cell i reads adr = (s, l, r2, r1) = (cell[i], cell[i-1], cell[i+2], cell[i+1]).
    Three rotations of the word line every neighbour up with its cell:

        L  = rotl(state, 1)   bit i of L  is cell[i-1]
        R1 = rotr(state, 1)   bit i of R1 is cell[i+1]
        R2 = rotr(state, 2)   bit i of R2 is cell[i+2]

    Splitting the LUT on l (bit 2 of adr) leaves two 3-input functions:

        l = 0: adr 0..3 give 0,1,1,0 (= r2 XOR r1) and adr 8..11 give 1,1,1,0
               (= r2 XOR r1, plus the case r2 = r1 = 0), so
               next = (r2 XOR r1) OR (s AND NOT r2)
        l = 1: adr 4..7 give 0,0,0,1 (= r1 AND r2) and adr 12..15 give 0,1,0,1
               (= r1), so
               next = r1 AND (s OR r2)

    Applied bitwise to the words the mux on l becomes
        next = (~L & ((R2 ^ R1) | (S & ~R2))) | (L & R1 & (S | R2)).
    The `selftest` subcommand checks all 16 LUT rows at every one of the 64
    cells, the four fixed points and 10,000 random states against ca_step.
    """
    s = state & MASK
    l = ((s << 1) | (s >> (WIDTH - 1))) & MASK
    r1 = ((s >> 1) | (s << (WIDTH - 1))) & MASK
    r2 = ((s >> 2) | (s << (WIDTH - 2))) & MASK
    return ((l ^ MASK) & ((r2 ^ r1) | (s & (r2 ^ MASK)))) | (l & r1 & (s | r2))


def cmd_check(args: argparse.Namespace) -> int:
    """Reproduce the ModelSim runs committed under sim/: seed from source_data.txt,
    every line of output_data.txt must equal the model."""
    root = Path(__file__).resolve().parent.parent
    failures = 0
    # The committed ModelSim runs hold 32 and 33 states; a shorter file is a failure,
    # not a pass over fewer lines.
    for sim, want in (("sim/modelsim", 32), ("sim/modelsim-vhdl", 33)):
        d = root / "electronic-die" / sim
        seed = int((d / "source_data.txt").read_text().split()[0], 2)
        expected = [line.strip() for line in (d / "output_data.txt").read_text().splitlines() if line.strip()]
        model = [fmt(s) for s in rng_sequence(seed, len(expected) - 1)]
        bad = [i for i, (a, b) in enumerate(zip(expected, model)) if a != b]
        if len(expected) != want:
            status = f"FAIL: expected {want} states, file has {len(expected)}"
            bad = bad or [len(expected)]
        else:
            status = "PASS" if not bad else f"FAIL at lines {bad[:5]}"
        print(f"{sim}: {len(expected)} states from ModelSim, seed={seed}: {status}")
        failures += bool(bad)
    return 1 if failures else 0


def cmd_vectors(args: argparse.Namespace) -> int:
    """Write the expected per-clock RNG states (and optionally the die values).

    states file: one 64-bit binary line per clock, line 0 is the seed itself.
    die file:    one 3-bit binary line per clock, line k = (state[k] mod 6) + 1.
    Both are in $readmemb / textio friendly form.  The testbenches apply the
    `en` protocol themselves (see docs/verification.md), so these files are
    independent of any mod-6 implementation in the RTL.
    """
    seq = rng_sequence(args.seed, args.steps)
    text = "\n".join(fmt(s) for s in seq) + "\n"
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text)
    else:
        sys.stdout.write(text)
    if args.die_out:
        Path(args.die_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.die_out).write_text("\n".join(format(die_value(s), "03b") for s in seq) + "\n")
    return 0


def cmd_die(args: argparse.Namespace) -> int:
    for k, s in enumerate(rng_sequence(args.seed, args.steps)):
        print(f"{k:4d} {fmt(s)} {die_value(s)}")
    return 0


def cmd_selftest(args: argparse.Namespace) -> int:
    """ca_step_fast must equal ca_step: every LUT row placed at every one of the
    64 cells over a random background (so the wrap-around cells 0, 1, 62, 63 are
    covered), the four fixed points, and 10,000 random states.

    Both implementations compute bit i from the same four bits, so a match of
    all 16 rows at all 64 cells is a proof of equality for every state; the
    random states are a second, independent check."""
    bad = 0
    # Each LUT row placed at cell i: the four neighbourhood bits are forced, the
    # other 60 cells are random; bit i of the next state must be LUT[adr].
    background = random.Random(64)
    placements = 0
    for i in range(WIDTH):
        pos = (i, (i - 1) % WIDTH, (i + 2) % WIDTH, (i + 1) % WIDTH)  # s, l, r2, r1
        keep = MASK
        for p_ in pos:
            keep &= ~(1 << p_)
        for adr in range(16):
            state = background.getrandbits(WIDTH) & keep
            for k, p_ in enumerate(pos):
                state |= ((adr >> (3 - k)) & 1) << p_
            placements += 1
            if bit(ca_step_fast(state), i) != LUT[adr] or bit(ca_step(state), i) != LUT[adr]:
                print(f"LUT row {adr:04b} at cell {i}: mismatch")
                bad += 1
    alternating = int("01" * (WIDTH // 2), 2)  # 0x5555...: LUT[1010] = 1, LUT[0101] = 0 keep it fixed
    fixed = ((0, "all-zero"), (MASK, "all-one"), (alternating, "alternating 0101"), (MASK ^ alternating, "alternating 1010"))
    for state, name in fixed:
        if ca_step(state) != state or ca_step_fast(state) != state:
            print(f"{name} state {state:#018x} is not a fixed point of both implementations")
            bad += 1
    rnd = random.Random(2026)
    for _ in range(10000):
        state = rnd.getrandbits(WIDTH)
        if ca_step_fast(state) != ca_step(state):
            print(f"mismatch for state {state:#018x}")
            bad += 1
    print(f"selftest: {placements} LUT placements (16 rows x {WIDTH} cells), {len(fixed)} fixed points, "
          f"10000 random states: {'PASS' if not bad else f'{bad} FAILURES'}")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="compare the model with the committed ModelSim output").set_defaults(fn=cmd_check)
    v = sub.add_parser("vectors", help="write expected RNG states, one 64-bit binary line per clock")
    v.add_argument("--seed", type=lambda x: int(x, 0), default=122059)
    v.add_argument("--steps", type=int, default=256)
    v.add_argument("--out", default=None, help="states file (default: stdout)")
    v.add_argument("--die-out", default=None, help="also write the die value per clock to this file")
    v.set_defaults(fn=cmd_vectors)
    d = sub.add_parser("die", help="print state and die value per clock")
    d.add_argument("--seed", type=lambda x: int(x, 0), default=122059)
    d.add_argument("--steps", type=int, default=16)
    d.set_defaults(fn=cmd_die)
    sub.add_parser("selftest", help="check ca_step_fast against ca_step; exit 1 on any mismatch").set_defaults(fn=cmd_selftest)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
