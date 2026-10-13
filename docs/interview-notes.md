# Interview notes

Things to be able to explain on a whiteboard, with the numbers that back
them. Every number here comes from a file in this repository; the file is
named next to it.

## 1. What the design is

A 64-cell, one-dimensional, periodic cellular automaton (CA) clocks every
cycle. Cell i reads four bits, `{c[i], c[i-1], c[i+2], c[i+1]}` (indices
mod 64), and looks its next value up in a 16-entry table
(`electronic-die/rtl/verilog/ca_cell.v`). The die value is
`(state mod 6) + 1`, captured into a 3-bit `result_reg` when `en` is high.
The first rising edge loads the seed instead of stepping.

Exact timing (docs/verification.md, section 2): numbering rising edges from
1, the CA holds `state[k-1]` after edge k, and if `en` is high at edge k >= 2
then `result_reg <= die(state[k-2])`, the state the CA held *before* that
edge.

## 2. Why the course design only reaches 10.96 MHz

`modulo_by_6.v` is one line, `rng_value % 6`. Quartus implements `%` with
its generic divider (`lpm_divide`), which for a 64-bit dividend is a chain
of 64 conditional-subtract steps. The critical path runs from a CA register
through **298 logic cells** of that divider into `result_reg`: 91.256 ns,
of which 53.4 ns is interconnect (`variants/baseline/baseline.critical_path.txt`).
The divider also costs 616 of the design's 684 ALUTs
(`variants/baseline/baseline.entities.txt`).

The VHDL submission is slower still: 4,359 ALUTs and 4.57 MHz, both in
the June course run and in the recompile here. Its `modulo_by_6.vhd` writes
`unsigned(rng_value) mod to_unsigned(6, 64)`, and Quartus infers a divider
with a 64-bit divisor (`LPM_WIDTHD=64`) instead of the 3-bit one it infers
for Verilog's `% 6` (`LPM_WIDTHD=3`); see `variants/vhdl_baseline/vhdl_baseline.entities.txt`. Same
arithmetic, but the width of a constant changed the hardware by a factor of
seven.

The 64 `ca_cell` instances are not the problem: each is one lookup table
plus a register, and the CA-to-CA path is a single logic level.

Adding a register after the `%` (`percent_s1`) changes almost nothing
(11.30 MHz): the slow logic is still between two registers. Pipelining only
helps once the arithmetic itself is restructured so it can be cut.

## 3. Mod 6 without division

Write x = 2h + b0, where h = x >> 1 and b0 is the lowest bit. Then

    x mod 6 = b0 + 2 * (h mod 3)

because 2h mod 6 = 2 * (h mod 3), and b0 + 2 * (h mod 3) is at most 5, so
no further reduction is needed.

For h mod 3, group h into base-4 digits d_i = h[2i+1:2i]. Since 4 = 1 (mod 3),
every power 4^i = 1 (mod 3), so

    h mod 3 = (d_0 + d_1 + ... + d_31) mod 3

Worked example, the course seed x = 122059 (binary 11101110011001011):

| Step | Value |
|---|---|
| b0 | 1 |
| h = x >> 1 | 61029 |
| base-4 digits of h, low first | 1, 1, 2, 1, 2, 3, 2, 3 |
| digit sum, mod 3 | 15, 0 |
| b0 + 2 * 0 | 1, and indeed 122059 = 6 * 20343 + 1 |
| die value | 2 (first line of `model/ca_rng.py die`) |

The plan's original form of the same fact: 2^k mod 6 is 1 for k = 0, then
alternates 2 (k odd), 4 (k even). So with P_odd and P_even the number of ones
in the odd and even (k >= 2) positions,

    x mod 6 = (b0 + 2 P_odd + 4 P_even) mod 6 = b0 + 2 * ((P_odd + 2 P_even) mod 3)

For the seed: P_odd = 5, P_even = 5, (5 + 10) mod 3 = 0, same answer.

## 4. Two hardware forms and why one wins

Both are verified against `%` for every 16-bit input and for directed plus
random 64-bit inputs (`electronic-die/sim/tb_mod6_equiv.v`).

- **`mod6_popcount`**: two popcount adder trees, then `(P_odd + 2 P_even) mod 3`.
  130 ALUTs for the mod-6 logic, 75.95 MHz unpipelined. Even with three pipeline stages it stops
  at 115.22 MHz: the remaining `% 3` on the 8-bit count sum is again an
  `lpm_divide`, and that small divider plus the adder carry chain is the new
  critical path (20 logic levels, `variants/popcount_s3/popcount_s3.critical_path.txt`).
- **`mod6_residue`**: never forms a count. A perfect binary tree of identical
  nodes, each `(a + b) mod 3` on two 2-bit residues, which is a 4-input,
  2-output function: one lookup table per output bit. 32 digits need
  log2(32) = 5 levels. 41 ALUTs for the mod-6 logic (the divider used 618)
  and 270.86 MHz with no pipeline at all: 24.7 times the baseline, from
  arithmetic alone. Critical path: 5 logic levels, 3.692 ns.

The lesson: an identity that removes the division is not enough if the
implementation reintroduces a wide carry chain or a divider. Keeping only
residues keeps every node tiny and the tree shallow.

## 5. Pipelining and the new timing contract

`electronic_die_fast` has a `STAGES` parameter. Registers are inserted at
evenly spaced tree depths (and `b0` is delayed alongside), so every path
from the CA to `result_reg` crosses exactly `STAGES` registers.

- The CA still free-runs and the tree is fed every clock.
- A `valid` bit travels with the data; it starts at 0 so the CA's pre-seed
  contents never reach the output.
- `en` keeps its meaning: it gates only the commit into `result_reg`.
- Contract (docs/verification.md, section 4): with L = STAGES,
  `R[k] = 1` for k <= 1 + L, else `R[k] = en_k ? die(state[k-2-L]) : R[k-1]`.
  With L = 0 it is exactly the original contract.

Results (docs/results.md):

| Variant | ALUTs (total / mod 6) | fmax | Note |
|---|---:|---:|---|
| baseline (course design) | 684 / 618 | 10.96 MHz | 298-level divider path |
| residue, 0 stages | 110 / 41 | 270.86 MHz | 5 logic levels |
| residue, 1 stage | 113 / 45 | 468.38 MHz | |
| residue, 2 stages | 108 / 40 | 500 MHz (cap) | slowest path needs 1.829 ns of the 2.000 ns |
| VHDL residue, 2 stages | 109 / 40 | 493.34 MHz | same tree in VHDL-93, against 4.57 MHz for the VHDL course design |

500 MHz is reported as "fmax restricted to clock pin edge rate 2.0 ns": the
clock input pin, not the logic, sets the limit. So two stages is the
sensible stopping point on this device; a third stage only adds registers.

## 6. How the verification is built

- A Python reference model (`model/ca_rng.py`) reproduces the original
  ModelSim output files line for line (`python3 -I model/ca_rng.py check`).
- The model writes expected CA states and die values; the testbenches apply
  the `en` protocol themselves, so they do not trust any mod-6 hardware.
- Each bench checks every clock and exits non-zero on the first mismatch,
  so `make test` and CI fail loudly.
- The benches were mutation-tested: deliberately broken copies of the RTL
  (a wrong table entry, `en` ignored, `% 7`, an update on the seed-loading
  edge, an extra cycle of latency, a wrong mod-3 node, a dropped digit, a
  misaligned `b0`, a valid bit one cycle early) all fail.
- The four fixed points are tested on purpose: all zeros and all ones (the
  table maps 0000 to 0 and 1111 to 1) and the two alternating patterns
  0x5555... and 0xAAAA... (every cell sees 0101 or 1010, which map back to
  its own value). The die then shows 1, 4, 6 or 5 forever.

## 7. Limits to state honestly

- Started as a course assignment (NTNU, Computer-Aided Design for VLSI
  Design, spring 2026); the reference model, testbenches, analysis, new
  arithmetic and pipeline were added afterwards.
- Synthesized and timed only (Quartus II 9.0 SP2, Stratix II EP2S15F484C3,
  no timing constraints, Classic Timing Analyzer). Not run on a board.
- The fmax numbers come from an unconstrained compile with default
  settings, the same as the course run, so the comparison is like for like.
- The CA is a teaching RNG, not a cryptographic or statistically certified
  one; see docs/rng_analysis.md for what was measured.
