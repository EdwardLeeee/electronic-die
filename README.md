# Electronic die: a verified, measured and pipelined 64-bit CA random-number generator

A small digital-design project built on top of a course assignment. A
64-cell cellular automaton (CA) produces a new 64-bit state every clock; the
die shows `(state mod 6) + 1`. This repository adds a reference model,
self-checking testbenches in Verilog and VHDL, a statistical look at the
generator, and a division-free mod-6 stage that raises the synthesized
clock rate from 10.96 MHz to the device's 500 MHz clock-pin limit.

## Where it started

The RTL in `electronic-die/rtl/{verilog,vhdl}` and
`electronic-die/rtl/*-behavioral`, the ModelSim scripts and outputs in
`electronic-die/sim/modelsim*`, the original Quartus project in
`electronic-die/synth/quartus/`, and the RAM controller in
`ram-controller/rtl/` are homework for *Computer-Aided Design for VLSI
Design* at National Taiwan Normal University (spring 2026). They are kept as
submitted: the original Quartus and ModelSim scripts refer to the flat
course folders and are records, not meant to be rerun from this layout
(recompiles go through `electronic-die/synth/quartus/variants/`). Their logic is
unchanged; only the seed and the activation code became parameters, and the
RAM controller entity was renamed from `hw3` to `seq_rw_ram` (its original
Quartus summaries still show `hw3`).

Everything else was added afterwards:

| Added | Where |
|---|---|
| Python reference model that reproduces the original ModelSim runs | `model/ca_rng.py` |
| Cycle-exact timing contracts derived from the RTL | `docs/verification.md` |
| Self-checking testbenches (Icarus Verilog, GHDL) | `electronic-die/sim/tb_*`, `ram-controller/sim/` |
| Mutation testing: deliberately broken copies of the RTL that the tests must reject | `tools/mutants.py`, `docs/logs/mutants.txt` |
| `make test` and a CI workflow | `Makefile`, `.github/workflows/test.yml` |
| RNG quality measurements | `model/rng_analysis.py`, `docs/rng_analysis.md` |
| Division-free mod-6 cores, pipelined top level (Verilog; residue core also in VHDL) | `electronic-die/rtl/{verilog,vhdl}/mod6_*`, `electronic_die_fast.*` |
| Quartus variant projects and the generated results table | `tools/quartus.py`, `electronic-die/synth/quartus/variants/`, `docs/results.md` |
| Derivations and design notes | `docs/interview-notes.md` |

## How it works

```
            +----------------------+  64  +-----------------------+   3  +--------------+
  SEED ---->| 64-cell CA (rng64)   |----->| mod 6, then +1        |----->| result_reg   |---> tossing_result[2:0]
            | one 16-entry LUT per |      | course: % operator    |      | written when |
  clk  ---->| cell, steps every    |      | new: mod-3 residue    |      | en = 1       |
            | clock after the seed |      | tree, STAGES pipeline |      |              |
            +----------------------+      +-----------------------+      +--------------+
```

Cell i looks up `adr = {c[i], c[i-1], c[i+2], c[i+1]}` (indices mod 64):

| adr  | 0000 | 0001 | 0010 | 0011 | 0100 | 0101 | 0110 | 0111 | 1000 | 1001 | 1010 | 1011 | 1100 | 1101 | 1110 | 1111 |
|------|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| next | 0 | 1 | 1 | 0 | 0 | 0 | 0 | 1 | 1 | 1 | 1 | 0 | 0 | 1 | 0 | 1 |

The mod-6 stage uses `x mod 6 = b0 + 2 * ((x >> 1) mod 3)` and, because
4 = 1 (mod 3), `(x >> 1) mod 3` is the sum of its base-4 digits mod 3: a
five-level tree of identical 4-input nodes instead of a 64-step divider.
The derivation, a worked example and the pipeline timing are in
`docs/interview-notes.md`.

## Results

<!-- results:begin -->
Quartus II 9.0 SP2, Stratix II EP2S15F484C3, same settings for every row. Generated
from the committed `*.summary` files by `tools/quartus.py collect`; all rows are in
[docs/results.md](docs/results.md).

| Variant | Pipeline stages | ALUTs (total / mod 6) | Registers | fmax (MHz) | vs. course design, same language |
|---|---:|---:|---:|---:|---:|
| course design (`%` operator) | 0 | 684 / 618 | 68 | 10.96 | 1.0x |
| `%` plus an output register | 1 | 686 / 620 | 72 | 11.30 | 1.0x |
| `popcount_s0` | 0 | 202 / 130 | 72 | 75.95 | 6.9x |
| `popcount_s3` | 3 | 214 / 146 | 165 | 115.22 | 10.5x |
| `residue_s0` | 0 | 110 / 41 | 69 | 270.86 | 24.7x |
| `residue_s1` | 1 | 113 / 45 | 78 | 468.38 | 42.7x |
| `residue_s2` | 2 | 108 / 40 | 92 | 500.00 (clock-pin cap) | 45.6x |
| course design, VHDL (`mod` operator) | 0 | 4359 / 4293 | 68 | 4.57 | 1.0x |
| `vhdl_residue_s2` | 2 | 109 / 40 | 93 | 493.34 | 108.0x |
<!-- results:end -->

## Running it

```
sudo apt install -y iverilog ghdl make python3      # Ubuntu; CI uses the same packages
make test                                           # every self-checking test
```

Without root, the same Ubuntu packages can be unpacked into a directory and
used from there (run from the repository root; amd64 or any other Debian
architecture):

```
mkdir -p ~/.cache/eda-debs && cd ~/.cache/eda-debs
apt-get download iverilog ghdl-mcode ghdl-common make
for f in *.deb; do dpkg -x "$f" ~/.local/opt/eda; done
cd -  &&  ~/.local/opt/eda/usr/bin/make test EDA_HOME=$HOME/.local/opt/eda
```

| Target | What it checks |
|---|---|
| `make test-model` | the Python model reproduces both committed ModelSim outputs |
| `make test-verilog`, `make test-vhdl` | RNG and die, structural and behavioural, six seeds (the course seed, a dense seed, the four CA fixed points), every clock |
| `make test-ram` | the RAM controller: bursts, wrong ID, write priority, read latency |
| `make test-m3` | both mod-6 cores against `%` (all 16-bit inputs, random 64-bit) and the pipelined die, Verilog and VHDL |
| `make analysis` | regenerates `docs/rng_analysis.md` from the reference model (about 30 s; the chart is redrawn with `model/plot_rng.py`) |
| `make test-mutants` | every mutant in `tools/mutants.py` must make its test fail (not part of `make test`; a few minutes) |

The synthesis numbers come from Quartus II 9.0 SP2 Web Edition, the version
the course used (current Quartus releases no longer support Stratix II):

```
QUARTUS_BIN=<directory with quartus_sh> tools/run_quartus.sh   # Linux runs it through Wine
```

## Limits

- The designs were synthesized, placed, routed and timed; none was run on
  an FPGA board.
- fmax figures are from unconstrained compiles with default settings, the
  same settings as the course run, on one device.
- The CA is a teaching example of a hardware RNG, not a certified or
  cryptographic generator. `docs/rng_analysis.md` lists what was measured
  and its known weaknesses: four fixed points, a bias toward even faces,
  and the course seed itself falling into a 128-state cycle after
  305,754 CA steps.
