# Verification contracts

Every testbench in this repository checks one of the contracts below, cycle by
cycle, against vectors produced by the Python reference model
(`model/ca_rng.py`). The vectors describe only the cellular automaton and the
arithmetic definition of the die value, so they stay valid when the mod-6
hardware is replaced (M3). The testbenches apply the `en` protocol themselves.

## Conventions

- Verilog: Icarus Verilog, `iverilog -g2012`; a failing check calls `$fatal`,
  which makes `vvp` exit with status 1. A passing run prints `PASS` and
  `$finish`es (status 0).
- VHDL: GHDL, `--std=08`; a failing run ends with `std.env.finish(1)`
  (status 1), a passing run with `finish(0)`.
- Stimulus changes and checks both happen on the falling clock edge, so the
  testbench never races the design at a rising edge.
- `make test` drives everything; see the Makefile for the exact commands.

### Vector files

`python3 -I model/ca_rng.py vectors --seed S --steps N --out S.states --die-out S.die`

- `S.states`: N+1 lines, line k is `state[k]` as 64 binary digits; line 0 is
  the seed itself (the CA state right after it is loaded).
- `S.die`: N+1 lines, line k is `(state[k] mod 6) + 1` as 3 binary digits.

Seeds used by `make test`: 122059 (the course run), 0xDEADBEEFCAFEF00D,
0 and 0xFFFFFFFFFFFFFFFF. The last two are fixed points of the CA (LUT maps
0000 to 0 and 1111 to 1), so their vectors are constant; the testbench checks
them like any other seed, which documents the weakness instead of hiding it.

## 1. RNG: `rng64` (structural) and `rng64_behavior`

Ports: `seed[63:0]`, `clk`, `sel`, `rng_out[63:0]`.

- Rising edge with `sel = 0`: every cell loads its seed bit.
- Rising edge with `sel = 1`: every cell applies the LUT to
  `{cell[i], cell[i-1], cell[i+2], cell[i+1]}` (indices mod 64).

Testbench protocol (`tb_rng64_check`): `sel = 0` during the first rising
edge, `sel = 1` afterwards. Numbering rising edges from 1, after edge k the
output must equal `state[k-1]`. Checked for every k up to N.

## 2. Die: `electronic_die` and `electronic_die_behavior` (original timing)

Ports: `clk`, `en`, `tossing_result[2:0]`. Parameter `SEED`.
Internal registers: `init_done` (power-up 0), `result_reg` (power-up 1).

Derived from the RTL, edge by edge:

- Edge 1: `init_done` goes 0 to 1 and the CA loads `SEED`. `result_reg` is
  not written whatever `en` is.
- Edge m >= 2: the CA advances to `state[m-1]`. If `en` is 1 at this edge,
  `result_reg <= die(state[m-2])`, where `die(x) = (x mod 6) + 1` and the
  state used is the one the CA held *before* this edge. Otherwise it holds.

Reference sequence kept by the testbench (k = number of rising edges so far,
`en_k` = value of `en` sampled at edge k):

    R[0] = R[1] = 1
    R[k] = en_k ? die(state[k-2]) : R[k-1]        for k >= 2

Checks after every edge: `tossing_result == R[k]`, `1 <= tossing_result <= 6`,
and (structural/behavioural internals aside) the CA state equals
`state[k-1]`. Stimulus phases: `en = 1` from time 0 (so edge 1 must *not*
update the output), `en = 0` for a block (output must hold), alternating,
then pseudo-random `en` for the remaining cycles.

## 3. RAM controller: `seq_rw_ram` (HW3)

Ports: `clk`, `Read`, `Write`, `ID[16:0]`, `Data_Input[7:0]`,
`Data_Output[7:0]`. Generic `ID_CODE` (default 22059). Internal signals
`W_En`, `W_Addr`, `R_Addr` carry `attribute keep` and are observed through
VHDL-2008 external names (`<< signal .tb.dut.W_En : std_logic >>`).

Timing, derived from the RTL. Let e0 be the rising edge at which `Write = 1`
(or `Read = 1`) together with `ID = ID_CODE` is sampled while the FSM is in
`S_IDLE`.

- Write burst: after e0 the FSM is in `S_W1`. At edge e(k+1), k = 0..7,
  `mem[k] <= Data_Input` (the value present at that edge). After e8 the FSM
  is back in `S_IDLE`, so `Data_Input` for entry k must be driven one edge
  later than the command for entry 0 and advance every clock.
- Read burst: at edge e(k+1), `Data_Output <= mem[k]`, so the data for entry
  k is visible between e(k+1) and e(k+2): one clock after the FSM entered
  `S_R(k+1)`. After e8 the FSM is idle.
- In `S_IDLE`, `R_Addr = 000`, so `Data_Output` reloads `mem[0]` at every
  edge. "Output unchanged while idle" is therefore *not* a property.
- A command still asserted at e9 starts another burst, so the testbench
  pulses commands for exactly one clock.
- Priority: the idle branch tests `Write` before `Read`, so both high with a
  matching ID gives a write burst and no read burst.
- Wrong ID: the FSM never leaves `S_IDLE`. Observable as `W_En = 0` and
  `R_Addr = 000` on every following clock (a read burst would show
  `R_Addr = 001` one clock after e0).

Checks (`tb_seq_rw_ram`):

1. Write eight distinct bytes, then read them back: `Data_Output` after
   e(k+1) of the read burst equals byte k; `W_En` is 1 exactly during the
   eight write clocks and 0 otherwise.
2. `Write = 1` and, separately, `Read = 1` with a wrong ID: for 16 clocks
   `W_En = 0` and `R_Addr = 000`; a later valid read returns the old data.
3. `Read = 1` and `Write = 1` together with the right ID and new data: a
   write burst happens (`W_En = 1` for eight clocks, later read returns the
   new data) and no read burst (`R_Addr` stays 000 during the burst).
4. Latency: during a read burst `Data_Output` shows `mem[0]` only after e1,
   not after e0.

## 4. Fast die: `electronic_die_fast` (M3, new timing contract)

Same ports and parameter as `electronic_die`, plus parameter `LATENCY = L`
(number of register stages inside the mod-6 pipeline).

- The CA free-runs exactly as before.
- The mod-6 pipeline is fed from the CA state every clock, unconditionally.
  A `valid` bit travels with the data; it is 0 at power-up and becomes 1 once
  the first loaded state has entered the pipeline, so garbage never reaches
  the output.
- `en` gates only the commit: at edge m, `result_reg <= pipe_out` when
  `en = 1` and the pipeline output is valid; otherwise it holds.

Reference sequence:

    R[k] = 1                                   for k <= 1 + L
    R[k] = en_k ? die(state[k-2-L]) : R[k-1]   for k >= 2 + L

With L = 0 this is contract 2. The equivalence of the new arithmetic itself
is tested separately: `mod6_popcount` with `WIDTH = 16` exhaustively and
with `WIDTH = 64` on random inputs against the `%` operator.
