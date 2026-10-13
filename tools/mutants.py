#!/usr/bin/env python3
"""Mutation testing: does each testbench notice a broken design?

    python3 -I tools/mutants.py [--make make] [--log docs/logs/mutants.txt] [--only NAME ...]

For every mutant below, the RTL trees are copied to build/mutants/<name>/, one
exact text edit is applied, and a narrowed run of an ordinary Makefile target
is pointed at the copy (DIE_RTL=..., RAM_RTL=..., BUILD=...).  The mutant is
*caught* when that run fails with a FAIL message from a testbench.  A run
that passes means the tests missed the bug (*survived*); a run that fails
without a FAIL message (for example a compile error) means the mutant itself
is broken.  Each narrowed configuration is also run once on an unmodified
copy, which must pass.  The script exits non-zero unless every mutant is
caught and every control passes.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TREES = ("electronic-die/rtl", "ram-controller/rtl")

ONE_SEED = {"SEEDS": "122059"}
TWO_SEEDS = {"SEEDS": "122059 16045690984503111693"}

# name, file, old text, new text, make target, make variables, what it models
MUTANTS = [
    # --- original course designs -------------------------------------------
    ("v_lut_entry", "electronic-die/rtl/verilog/ca_cell.v",
     "4'b0001: next_state = 1'b1;", "4'b0001: next_state = 1'b0;",
     "test-verilog", ONE_SEED, "one wrong entry in the CA lookup table"),
    ("v_en_ignored", "electronic-die/rtl/verilog/electronic_die.v",
     "else if (en)", "else if (1'b1)",
     "test-verilog", ONE_SEED, "output register ignores en"),
    ("v_mod7", "electronic-die/rtl/verilog/modulo_by_6.v",
     "% 6", "% 7", "test-verilog", ONE_SEED, "wrong modulus"),
    ("v_update_on_load", "electronic-die/rtl/verilog/electronic_die.v",
     "            init_done <= 1'b1;\n        else if (en)", "            init_done <= 1'b1;\n        if (en)",
     "test-verilog", ONE_SEED, "result written on the seed-loading edge"),
    ("v_wrong_neighbour", "electronic-die/rtl/verilog/rng64.v",
     "localparam integer IP2 = (i >= 62) ? i - 62 : i + 2;", "localparam integer IP2 = (i >= 61) ? i - 61 : i + 3;",
     "test-verilog", ONE_SEED, "CA reads cell i+3 instead of i+2"),
    ("vb_lut_entry", "electronic-die/rtl/verilog-behavioral/electronic_die_behavior.v",
     "4'b1101: next_state[i] = 1'b1;", "4'b1101: next_state[i] = 1'b0;",
     "test-verilog", ONE_SEED, "behavioural model: one wrong table entry"),
    ("vb_mod_carry", "electronic-die/rtl/verilog-behavioral/electronic_die_behavior.v",
     "if (next_rem >= 4'd6)", "if (next_rem >= 4'd7)",
     "test-verilog", ONE_SEED, "behavioural model: wrong reduction step in mod 6"),
    ("h_lut_entry", "electronic-die/rtl/vhdl/ca_cell.vhd",
     "'1' when \"0001\",", "'0' when \"0001\",",
     "test-vhdl", ONE_SEED, "VHDL: one wrong entry in the CA lookup table"),
    ("h_en_ignored", "electronic-die/rtl/vhdl/electronic_die.vhd",
     "elsif en = '1' then", "elsif true then",
     "test-vhdl", ONE_SEED, "VHDL: output register ignores en"),
    ("h_mod7", "electronic-die/rtl/vhdl/modulo_by_6.vhd",
     "mod to_unsigned(6, 64)", "mod to_unsigned(7, 64)",
     "test-vhdl", ONE_SEED, "VHDL: wrong modulus"),
    ("hb_mod_bit_sense", "electronic-die/rtl/vhdl-behavioral/electronic_die_behavior.vhd",
     "if value(i) = '1' then", "if value(i) = '0' then",
     "test-vhdl", ONE_SEED, "VHDL behavioural model: mod 6 of the inverted state"),
    # --- new mod-6 cores (equivalence benches) -----------------------------
    ("res_node_table", "electronic-die/rtl/verilog/mod6_residue.v",
     "if (s >= 3'd6)      mod3add = 2'd0;", "if (s >= 3'd6)      mod3add = 2'd1;",
     "test-equiv", {"EQ_CONFIGS": '"2 16 3"'}, "residue tree: (3 + 3) mod 3 gives 1"),
    ("res_drop_top_digit", "electronic-die/rtl/verilog/mod6_residue.v",
     "wire [2*LEAVES-1:0] h = x[WIDTH-1:1];", "wire [2*LEAVES-1:0] h = x[WIDTH-2:1];",
     "test-equiv", {"EQ_CONFIGS": '"2 64 5"'}, "residue tree ignores the top input bit"),
    ("res_b0_not_delayed", "electronic-die/rtl/verilog/mod6_residue.v",
     "assign rem = {node[3:2], b0[STAGES]};", "assign rem = {node[3:2], b0[0]};",
     "test-equiv", {"EQ_CONFIGS": '"2 16 3"'}, "residue tree: bit 0 skips the pipeline"),
    ("pop_leaf_swap", "electronic-die/rtl/verilog/mod6_popcount.v",
     "assign even_bits[i] = x[2*i + 2];", "assign even_bits[i] = x[2*i + 2] ^ (i == 30);",
     "test-equiv", {"EQ_CONFIGS": '"1 64 6"'}, "popcount: one leaf inverted"),
    ("pop_final_mod", "electronic-die/rtl/verilog/mod6_popcount.v",
     "wire [1:0]    r_comb = t % 3;", "wire [1:0]    r_comb = (t + 1) % 3;",
     "test-equiv", {"EQ_CONFIGS": '"1 16 4"'}, "popcount: wrong final reduction"),
    ("hres_node_table", "electronic-die/rtl/vhdl/mod6_residue.vhd",
     "when \"0101\" => return \"10\";", "when \"0101\" => return \"01\";",
     "test-m3-vhdl", {"VHDL_EQ_CONFIGS": '"16 3"', "VHDL_FAST_CONFIGS": '"2 2"'},
     "VHDL residue tree: one wrong table entry"),
    ("hres_b0_not_delayed", "electronic-die/rtl/vhdl/mod6_residue.vhd",
     "rem6 <= std_logic_vector(node(1)) & b0(STAGES);", "rem6 <= std_logic_vector(node(1)) & b0(0);",
     "test-m3-vhdl", {"VHDL_EQ_CONFIGS": '"16 3"', "VHDL_FAST_CONFIGS": '"2 2"'},
     "VHDL residue tree: bit 0 skips the pipeline"),
    # --- pipelined die top (die-level contract) ---------------------------
    ("fast_no_valid", "electronic-die/rtl/verilog/electronic_die_fast.v",
     "assign valid[0] = init_done;", "assign valid[0] = 1'b1;",
     "test-fast", {"SEEDS": "122059", "FAST_CONFIGS": '"2 0" "2 2"'}, "pre-seed data may reach the output"),
    ("fast_valid_early", "electronic-die/rtl/verilog/electronic_die_fast.v",
     "if (en && valid[STAGES])", "if (en && valid[STAGES > 0 ? STAGES-1 : 0])",
     "test-fast", {"SEEDS": "122059", "FAST_CONFIGS": '"2 2" "1 1"'}, "valid bit one clock early"),
    ("fast_extra_stage", "electronic-die/rtl/verilog/electronic_die_fast.v",
     "mod6_residue #(.WIDTH(64), .STAGES(STAGES))", "mod6_residue #(.WIDTH(64), .STAGES(STAGES + 1))",
     "test-fast", {"SEEDS": "122059", "FAST_CONFIGS": '"2 1"'}, "core one stage deeper than the top expects"),
    ("fast_percent_delay", "electronic-die/rtl/verilog/electronic_die_fast.v",
     "always @(posedge clk) q <= d[3*(i-1) +: 3];", "always @(posedge clk) q <= d[0 +: 3];",
     "test-fast", {"SEEDS": "122059", "FAST_CONFIGS": '"0 2"'}, "% variant: delay line taps the wrong stage"),
    ("hfast_valid_early", "electronic-die/rtl/vhdl/electronic_die_fast.vhd",
     "if en = '1' and valid(STAGES) = '1' then", "if en = '1' and valid(0) = '1' then",
     "test-m3-vhdl", {"SEEDS": "122059", "VHDL_EQ_CONFIGS": '"16 0"', "VHDL_FAST_CONFIGS": '"2 2"'},
     "VHDL top: valid bit ignores the pipeline"),
    # --- HW3 RAM controller (tb_seq_rw_ram) ---------------------------------
    ("ram_read_priority", "ram-controller/rtl/seq_rw_ram.vhd",
     "                if Write = '1' and ID = ID_CODE then\n                    next_state <= S_W1;\n"
     "                elsif Read = '1' and ID = ID_CODE then\n                    next_state <= S_R1;\n",
     "                if Read = '1' and ID = ID_CODE then\n                    next_state <= S_R1;\n"
     "                elsif Write = '1' and ID = ID_CODE then\n                    next_state <= S_W1;\n",
     "test-ram", {}, "Read wins over Write"),
    ("ram_no_id_write", "ram-controller/rtl/seq_rw_ram.vhd",
     "                if Write = '1' and ID = ID_CODE then\n", "                if Write = '1' then\n",
     "test-ram", {}, "write burst starts without the activation code"),
    ("ram_id_bit16_ignored", "ram-controller/rtl/seq_rw_ram.vhd",
     "                elsif Read = '1' and ID = ID_CODE then\n",
     "                elsif Read = '1' and ID(15 downto 0) = ID_CODE(15 downto 0) then\n",
     "test-ram", {}, "read accepts an ID that differs in bit 16"),
    ("ram_trigger_on_id", "ram-controller/rtl/seq_rw_ram.vhd",
     "                if Write = '1' and ID = ID_CODE then\n", "                if ID = ID_CODE then\n",
     "test-ram", {}, "the right ID alone starts a write burst"),
    ("ram_short_write", "ram-controller/rtl/seq_rw_ram.vhd",
     "            when S_W7 => next_state <= S_W8;\n", "            when S_W7 => next_state <= S_IDLE;\n",
     "test-ram", {}, "write burst of 7 entries"),
    ("ram_short_read", "ram-controller/rtl/seq_rw_ram.vhd",
     "            when S_R7 => next_state <= S_R8;\n", "            when S_R7 => next_state <= S_IDLE;\n",
     "test-ram", {}, "read burst of 7 entries"),
    ("ram_read_sticks", "ram-controller/rtl/seq_rw_ram.vhd",
     "            when S_R8 => next_state <= S_IDLE;\n", "            when S_R8 => next_state <= S_R8;\n",
     "test-ram", {}, "FSM never leaves the last read state"),
    ("ram_write_addr", "ram-controller/rtl/seq_rw_ram.vhd",
     "when S_W1 => W_Addr <= \"000\"; W_En <= '1';", "when S_W1 => W_Addr <= \"001\"; W_En <= '1';",
     "test-ram", {}, "first write goes to entry 1"),
    ("ram_last_write_lost", "ram-controller/rtl/seq_rw_ram.vhd",
     "when S_W8 => W_Addr <= \"111\"; W_En <= '1';", "when S_W8 => W_Addr <= \"111\"; W_En <= '0';",
     "test-ram", {}, "eighth write not enabled"),
    ("ram_read_addr_plus1", "ram-controller/rtl/seq_rw_ram.vhd",
     "            Data_Output <= mem(to_integer(unsigned(R_Addr)));\n",
     "            Data_Output <= mem((to_integer(unsigned(R_Addr)) + 1) mod 8);\n",
     "test-ram", {}, "read port off by one entry"),
]


def prepare(work: Path, edit: tuple[str, str, str] | None) -> None:
    if work.exists():
        shutil.rmtree(work)
    for tree in TREES:
        shutil.copytree(ROOT / tree, work / tree)
    if edit:
        rel, old, new = edit
        path = work / rel
        text = path.read_text()
        count = text.count(old)
        if count != 1:
            raise SystemExit(f"mutant edit for {rel} matches {count} times (expected 1): {old!r}")
        path.write_text(text.replace(old, new))


def run(make: str, target: str, work: Path, variables: dict[str, str]) -> tuple[int, str, float]:
    args = [*make.split(), "--no-print-directory", target,
            f"DIE_RTL={work / TREES[0]}", f"RAM_RTL={work / TREES[1]}", f"BUILD={work / 'build'}"]
    args += [f"{k}={v}" for k, v in variables.items()]
    start = time.monotonic()
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr, time.monotonic() - start


def first_fail(output: str) -> str:
    for line in output.splitlines():
        if "FAIL" in line:
            return line.strip()[:150]
    return ""


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--make", default="make")
    ap.add_argument("--log", default=None)
    ap.add_argument("--only", nargs="*", default=None)
    args = ap.parse_args(argv)
    chosen = [m for m in MUTANTS if not args.only or m[0] in args.only]
    base = ROOT / "build" / "mutants"
    lines, bad = [], 0

    controls = {}
    for _, _, _, _, target, variables, _ in chosen:
        controls.setdefault((target, tuple(sorted(variables.items()))), (target, variables))
    for i, (target, variables) in enumerate(controls.values()):
        work = base / f"control{i}"
        prepare(work, None)
        rc, out, dt = run(args.make, target, work, variables)
        ok = rc == 0
        bad += not ok
        desc = " ".join(f"{k}={v}" for k, v in variables.items())
        lines.append(f"control   {'pass' if ok else 'FAILED':8s} {target} {desc} ({dt:.0f} s)")
        print(lines[-1], flush=True)

    for name, rel, old, new, target, variables, what in chosen:
        work = base / name
        prepare(work, (rel, old, new))
        rc, out, dt = run(args.make, target, work, variables)
        fail = first_fail(out)
        if rc != 0 and fail:
            verdict = "caught"
        elif rc == 0:
            verdict, bad = "SURVIVED", bad + 1
        else:
            verdict, bad = "BROKEN", bad + 1        # failed without a testbench FAIL line
            fail = out.strip().splitlines()[-1][:150] if out.strip() else ""
        lines.append(f"{name:20s} {verdict:8s} {target:13s} {what}  [{rel}] ({dt:.0f} s)\n"
                     f"{'':29s}{fail}")
        print(lines[-1], flush=True)

    caught = sum(1 for line in lines if " caught " in line)
    summary = (f"{caught} of {len(chosen)} mutants caught, "
               f"{len(controls)} controls, {'all passed' if bad == 0 else f'{bad} problem(s)'}")
    print(summary)
    if args.log:
        Path(args.log).parent.mkdir(parents=True, exist_ok=True)
        Path(args.log).write_text("# python3 -I tools/mutants.py   (make test-mutants)\n"
                                  + "\n".join(lines) + "\n" + summary + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
