# digital-design-projects: simulation and self-checking tests.
#
#   make test                       tools on PATH (iverilog, vvp, ghdl, python3)
#   make test EDA_HOME=$HOME/.local/opt/eda
#                                   tools unpacked from .deb files with dpkg -x
#                                   (no root needed); see README.
#   make test-verilog / test-vhdl / test-ram / test-model / test-m3  run one group
#   make test-m3 EQ_N=200000        longer random equivalence run for the mod-6 cores
#   make test-mutants               break the RTL on purpose (tools/mutants.py); every
#                                   mutant must make its test fail
#   make figures                    redraw the README figures in docs/img (needs Pillow;
#                                   reruns make test for the log it shows)
#
# Every test exits non-zero when any check fails, so a red run is a red run.

PYTHON   ?= python3
IVERILOG ?= iverilog
VVP      ?= vvp
GHDL     ?= ghdl

# Optional per-machine settings (git-ignored), e.g. "EDA_HOME := $(HOME)/.local/opt/eda".
-include local.mk

ifneq ($(strip $(EDA_HOME)),)
IVL_DIR  := $(firstword $(wildcard $(EDA_HOME)/usr/lib/*/ivl))
IVERILOG := $(EDA_HOME)/usr/bin/iverilog -B$(IVL_DIR)
VVP      := $(EDA_HOME)/usr/bin/vvp -M$(IVL_DIR)
GHDL     := $(EDA_HOME)/usr/bin/ghdl
export GHDL_PREFIX := $(EDA_HOME)/usr/lib/ghdl/mcode/vhdl
endif

IVFLAGS   ?= -g2012 -Wall -Wno-timescale
GHDLFLAGS ?= --std=08

BUILD ?= build
VEC   := $(BUILD)/vec
STEPS ?= 512
# course seed, an arbitrary dense seed, and the four fixed points of the CA
# (all zeros, all ones, 0x5555..., 0xAAAA...)
SEEDS ?= 122059 16045690984503111693 0 18446744073709551615 6148914691236517205 12297829382473034410

MODEL   := model/ca_rng.py
DIE_RTL ?= electronic-die/rtl
DIE_SIM := electronic-die/sim
RAM_RTL ?= ram-controller/rtl
RAM_SIM := ram-controller/sim

V_STRUCT := $(DIE_RTL)/verilog/ca_cell.v $(DIE_RTL)/verilog/rng64.v \
            $(DIE_RTL)/verilog/modulo_by_6.v $(DIE_RTL)/verilog/electronic_die.v
V_BEHAV  := $(DIE_RTL)/verilog-behavioral/electronic_die_behavior.v
V_CORES  := $(DIE_RTL)/verilog/mod6_popcount.v $(DIE_RTL)/verilog/mod6_residue.v
V_FAST   := $(DIE_RTL)/verilog/ca_cell.v $(DIE_RTL)/verilog/rng64.v \
            $(DIE_RTL)/verilog/modulo_by_6.v $(V_CORES) $(DIE_RTL)/verilog/electronic_die_fast.v
H_STRUCT := $(DIE_RTL)/vhdl/ca_cell.vhd $(DIE_RTL)/vhdl/rng64.vhd \
            $(DIE_RTL)/vhdl/modulo_by_6.vhd $(DIE_RTL)/vhdl/electronic_die.vhd
H_BEHAV  := $(DIE_RTL)/vhdl-behavioral/electronic_die_behavior.vhd
H_FAST   := $(DIE_RTL)/vhdl/mod6_residue.vhd $(DIE_RTL)/vhdl/electronic_die_fast.vhd

VECFILES := $(foreach s,$(SEEDS),$(VEC)/$(s).states $(VEC)/$(s).die)

.PHONY: all test test-model vectors test-verilog test-vhdl test-ram test-m3 test-equiv test-fast test-m3-vhdl check-vhdl93 test-mutants analysis figures clean
.DELETE_ON_ERROR:

all: test

test: test-model test-verilog test-vhdl test-ram test-m3
	@echo "ALL TESTS PASSED"

# --- reference model against the committed ModelSim outputs -----------------
test-model:
	$(PYTHON) -I $(MODEL) check
	$(PYTHON) -I $(MODEL) selftest

# --- expected vectors --------------------------------------------------------
vectors: $(VECFILES)

$(VEC)/%.states $(VEC)/%.die &: $(MODEL)
	@mkdir -p $(VEC)
	$(PYTHON) -I $(MODEL) vectors --seed $* --steps $(STEPS) \
	    --out $(VEC)/$*.states --die-out $(VEC)/$*.die

# --- Verilog (Icarus) --------------------------------------------------------
$(BUILD)/tb_rng64_structural.vvp: $(DIE_SIM)/tb_rng64_check.v $(V_STRUCT)
	@mkdir -p $(BUILD)
	$(IVERILOG) $(IVFLAGS) -o $@ $^
$(BUILD)/tb_rng64_behavioral.vvp: $(DIE_SIM)/tb_rng64_check.v $(V_BEHAV)
	@mkdir -p $(BUILD)
	$(IVERILOG) $(IVFLAGS) -DBEHAVIORAL -o $@ $^

test-verilog: $(VECFILES) $(BUILD)/tb_rng64_structural.vvp $(BUILD)/tb_rng64_behavioral.vvp
	@for v in structural behavioral; do \
	  for s in $(SEEDS); do \
	    echo "== verilog rng64 $$v seed=$$s"; \
	    $(VVP) -N $(BUILD)/tb_rng64_$$v.vvp +states=$(VEC)/$$s.states +steps=$(STEPS) || exit 1; \
	    echo "== verilog electronic_die $$v seed=$$s"; \
	    if [ $$v = structural ]; then src="$(V_STRUCT)"; def=""; else src="$(V_BEHAV)"; def="-DBEHAVIORAL"; fi; \
	    $(IVERILOG) $(IVFLAGS) $$def "-Ptb_die_check.SEED=64'd$$s" \
	        -o $(BUILD)/tb_die_$${v}_$$s.vvp $(DIE_SIM)/tb_die_check.v $$src || exit 1; \
	    $(VVP) -N $(BUILD)/tb_die_$${v}_$$s.vvp +states=$(VEC)/$$s.states +die=$(VEC)/$$s.die +steps=$(STEPS) || exit 1; \
	  done; \
	done

# --- M3: mod-6 cores and the pipelined die (Verilog) -------------------------
# Equivalence with %: "core width max_stages"; WIDTH 16 is exhaustive.
EQ_N       ?= 20000
EQ_CONFIGS ?= "1 16 4" "1 64 6" "2 16 3" "2 64 5"
# Die-level contract: "core stages"
FAST_CONFIGS ?= "0 0" "0 1" "0 2" "1 0" "1 1" "1 2" "1 3" "2 0" "2 1" "2 2" "2 3"

test-m3: test-equiv test-fast test-m3-vhdl

test-equiv: $(DIE_SIM)/tb_mod6_equiv.v $(V_CORES)
	@mkdir -p $(BUILD)/m3
	@for cfg in $(EQ_CONFIGS); do set -- $$cfg; \
	  for st in $$(seq 0 $$3); do \
	    $(IVERILOG) $(IVFLAGS) -Ptb_mod6_equiv.CORE=$$1 -Ptb_mod6_equiv.WIDTH=$$2 -Ptb_mod6_equiv.STAGES=$$st \
	        -o $(BUILD)/m3/eq_$$1_$$2_$$st.vvp $^ || exit 1; \
	    $(VVP) -N $(BUILD)/m3/eq_$$1_$$2_$$st.vvp +n=$(EQ_N) || exit 1; \
	  done; \
	done

test-fast: $(VECFILES) $(DIE_SIM)/tb_die_check.v $(V_FAST)
	@mkdir -p $(BUILD)/m3
	@for cfg in $(FAST_CONFIGS); do set -- $$cfg; \
	  for s in $(SEEDS); do \
	    echo "== verilog electronic_die_fast CORE=$$1 STAGES=$$2 seed=$$s"; \
	    $(IVERILOG) $(IVFLAGS) -DFAST "-Ptb_die_check.SEED=64'd$$s" -Ptb_die_check.CORE=$$1 -Ptb_die_check.LATENCY=$$2 \
	        -o $(BUILD)/m3/die_$$1_$$2_$$s.vvp $(DIE_SIM)/tb_die_check.v $(V_FAST) || exit 1; \
	    $(VVP) -N $(BUILD)/m3/die_$$1_$$2_$$s.vvp +states=$(VEC)/$$s.states +die=$(VEC)/$$s.die +steps=$(STEPS) || exit 1; \
	  done; \
	done

# --- VHDL (GHDL) -------------------------------------------------------------
GHDL_WORK := $(BUILD)/ghdl
GHDL_A    := $(GHDL) -a $(GHDLFLAGS) --workdir=$(GHDL_WORK)
GHDL_RUN  := $(GHDL) --elab-run $(GHDLFLAGS) --workdir=$(GHDL_WORK)

$(GHDL_WORK)/.analysed: $(H_STRUCT) $(H_BEHAV) $(H_FAST) $(DIE_SIM)/tb_rng64_check.vhd $(DIE_SIM)/tb_die_check.vhd $(DIE_SIM)/tb_mod6_equiv.vhd
	@mkdir -p $(GHDL_WORK)
	$(GHDL_A) $(H_STRUCT)
	$(GHDL_A) $(H_BEHAV)
	$(GHDL_A) $(H_FAST)
	$(GHDL_A) $(DIE_SIM)/tb_rng64_check.vhd $(DIE_SIM)/tb_die_check.vhd $(DIE_SIM)/tb_mod6_equiv.vhd
	@touch $@

test-vhdl: $(VECFILES) $(GHDL_WORK)/.analysed
	@for v in structural behavioral; do \
	  for s in $(SEEDS); do \
	    echo "== vhdl rng64 $$v seed=$$s"; \
	    $(GHDL_RUN) tb_rng64_check -gDUT=$$v -gSTATES=$(VEC)/$$s.states -gSTEPS=$(STEPS) || exit 1; \
	    echo "== vhdl electronic_die $$v seed=$$s"; \
	    b=$$($(PYTHON) -c "print(format($$s, '064b'))"); \
	    $(GHDL_RUN) tb_die_check -gDUT=$$v -gSEED=$$b \
	        -gSTATES=$(VEC)/$$s.states -gDIE=$(VEC)/$$s.die -gSTEPS=$(STEPS) || exit 1; \
	  done; \
	done

# VHDL counterpart of test-m3 (mod6_residue and electronic_die_fast, CORE 0 and 2)
VHDL_EQ_CONFIGS   ?= "16 3" "64 5"
VHDL_FAST_CONFIGS ?= "0 0" "0 1" "2 0" "2 1" "2 2" "2 3"

# Quartus II 9.0 reads VHDL-93: analyse the synthesizable VHDL in strict 93 mode.
check-vhdl93: $(H_STRUCT) $(H_FAST)
	@mkdir -p $(BUILD)/ghdl93
	$(GHDL) -a --std=93 --workdir=$(BUILD)/ghdl93 $(H_STRUCT) $(H_FAST)
	@echo "PASS: synthesizable VHDL analyses as strict VHDL-93"

test-m3-vhdl: check-vhdl93 $(VECFILES) $(GHDL_WORK)/.analysed
	@for cfg in $(VHDL_EQ_CONFIGS); do set -- $$cfg; \
	  for st in $$(seq 0 $$2); do \
	    $(GHDL_RUN) tb_mod6_equiv -gWIDTH=$$1 -gSTAGES=$$st -gN=$(EQ_N) || exit 1; \
	  done; \
	done
	@for cfg in $(VHDL_FAST_CONFIGS); do set -- $$cfg; \
	  for s in $(SEEDS); do \
	    echo "== vhdl electronic_die_fast CORE=$$1 STAGES=$$2 seed=$$s"; \
	    b=$$($(PYTHON) -c "print(format($$s, '064b'))"); \
	    $(GHDL_RUN) tb_die_check -gDUT=fast -gCORE=$$1 -gLATENCY=$$2 -gSEED=$$b \
	        -gSTATES=$(VEC)/$$s.states -gDIE=$(VEC)/$$s.die -gSTEPS=$(STEPS) || exit 1; \
	  done; \
	done

# --- RAM controller (HW3, VHDL) ---------------------------------------------
GHDL_WORK_RAM := $(BUILD)/ghdl-ram

test-ram: $(RAM_RTL)/seq_rw_ram.vhd $(RAM_SIM)/tb_seq_rw_ram.vhd
	@mkdir -p $(GHDL_WORK_RAM)
	$(GHDL) -a $(GHDLFLAGS) --workdir=$(GHDL_WORK_RAM) $(RAM_RTL)/seq_rw_ram.vhd $(RAM_SIM)/tb_seq_rw_ram.vhd
	$(GHDL) --elab-run $(GHDLFLAGS) --workdir=$(GHDL_WORK_RAM) tb_seq_rw_ram

# --- M2: RNG quality measurements (standard library only, about 30 s) --------
# The chart needs matplotlib: uv run --with matplotlib python3 model/plot_rng.py \
#     build/rng_analysis.json docs/img/die_histogram.png
analysis:
	$(PYTHON) -I model/rng_analysis.py --md docs/rng_analysis.md --json $(BUILD)/rng_analysis.json

# --- mutation testing: tools/mutants.py copies the RTL, breaks one thing, and
# reruns a narrowed version of the target above; the run must fail.
test-mutants:
	$(PYTHON) -I tools/mutants.py --make "$(MAKE)" --log docs/logs/mutants.txt

# --- README figures (not part of make test; needs Pillow) -------------------
# die_waveform.png: tb_wave runs the course die and residue_s2 side by side
#   from one seed (and fails unless residue_s2 trails by exactly two clocks).
# make_test.png:    a real `make test` run, kept in docs/logs/make-test.txt with
#   the home directory shortened to ~.
# quartus_timing.png: lines of the committed Quartus summaries, unchanged.
FIG := docs/img
QV  := electronic-die/synth/quartus/variants

figures:
	@mkdir -p $(BUILD)/wave
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/wave/tb_wave.vvp $(DIE_SIM)/tb_wave.v $(V_FAST) $(DIE_RTL)/verilog/electronic_die.v
	$(VVP) -N $(BUILD)/wave/tb_wave.vvp +vcd=$(BUILD)/wave/die_wave.vcd > $(BUILD)/wave/tb_wave.log
	$(PYTHON) -I tools/wave_png.py $(BUILD)/wave/die_wave.vcd $(FIG)/die_waveform.png \
	    --clock clk --enable en --signal course_result "course design (%)" --signal fast_result "residue_s2 (2 stages)" \
	    --title "Icarus Verilog simulation, seed 122059: tossing_result of both designs" \
	    --note "residue_s2 repeats the course design's value from two edges earlier whenever en was high at both edges (docs/verification.md, section 4). Shaded: en = 0, both hold."
	$(MAKE) --no-print-directory test > $(BUILD)/make-test.raw 2>&1 || { tail -n 20 $(BUILD)/make-test.raw; exit 1; }
	sed "s#$$HOME#~#g" $(BUILD)/make-test.raw > docs/logs/make-test.txt
	$(PYTHON) -I tools/text_png.py $(FIG)/make_test.png --theme dark --title '$$ make test' \
	    --count PASS --count FAIL --mark PASS docs/logs/make-test.txt:1-12,-8
	$(PYTHON) -I tools/text_png.py $(FIG)/quartus_timing.png --theme light \
	    --title 'Quartus II 9.0 SP2, Stratix II EP2S15F484C3: course design (baseline) and residue_s2' \
	    --mark 'Actual Time' --mark 'Combinational ALUTs' \
	    $(QV)/baseline/baseline.fit.summary:3-10 $(QV)/baseline/baseline.tan.summary:35-40 \
	    $(QV)/residue_s2/residue_s2.fit.summary:3-10 $(QV)/residue_s2/residue_s2.tan.summary:35-40

clean:
	rm -rf $(BUILD)
