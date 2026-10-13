# digital-design-projects: simulation and self-checking tests.
#
#   make test                       tools on PATH (iverilog, vvp, ghdl, python3)
#   make test EDA_HOME=~/.local/opt/eda
#                                   tools unpacked from .deb files with dpkg -x
#                                   (no root needed); see README.
#   make test-verilog / test-vhdl / test-ram / test-model  run one group
#
# Every test exits non-zero on the first mismatch, so a red run is a red run.

PYTHON   ?= python3
IVERILOG ?= iverilog
VVP      ?= vvp
GHDL     ?= ghdl

# Optional per-machine settings (git-ignored), e.g. "EDA_HOME := $(HOME)/.local/opt/eda".
-include local.mk

ifneq ($(strip $(EDA_HOME)),)
IVL_DIR  := $(EDA_HOME)/usr/lib/x86_64-linux-gnu/ivl
IVERILOG := $(EDA_HOME)/usr/bin/iverilog -B$(IVL_DIR)
VVP      := $(EDA_HOME)/usr/bin/vvp -M$(IVL_DIR)
GHDL     := $(EDA_HOME)/usr/bin/ghdl
export GHDL_PREFIX := $(EDA_HOME)/usr/lib/ghdl/mcode/vhdl
endif

IVFLAGS   ?= -g2012 -Wall -Wno-timescale
GHDLFLAGS ?= --std=08

BUILD := build
VEC   := $(BUILD)/vec
STEPS ?= 512
# course seed, an arbitrary dense seed, and the two fixed points of the CA
SEEDS ?= 122059 16045690984503111693 0 18446744073709551615

MODEL   := model/ca_rng.py
DIE_RTL := electronic-die/rtl
DIE_SIM := electronic-die/sim
RAM_RTL := ram-controller/rtl
RAM_SIM := ram-controller/sim

V_STRUCT := $(DIE_RTL)/verilog/ca_cell.v $(DIE_RTL)/verilog/rng64.v \
            $(DIE_RTL)/verilog/modulo_by_6.v $(DIE_RTL)/verilog/electronic_die.v
V_BEHAV  := $(DIE_RTL)/verilog-behavioral/electronic_die_behavior.v
H_STRUCT := $(DIE_RTL)/vhdl/ca_cell.vhd $(DIE_RTL)/vhdl/rng64.vhd \
            $(DIE_RTL)/vhdl/modulo_by_6.vhd $(DIE_RTL)/vhdl/electronic_die.vhd
H_BEHAV  := $(DIE_RTL)/vhdl-behavioral/electronic_die_behavior.vhd

VECFILES := $(foreach s,$(SEEDS),$(VEC)/$(s).states $(VEC)/$(s).die)

.PHONY: all test test-model vectors test-verilog test-vhdl test-ram clean
.DELETE_ON_ERROR:

all: test

test: test-model test-verilog test-vhdl test-ram
	@echo "ALL TESTS PASSED"

# --- reference model against the committed ModelSim outputs -----------------
test-model:
	$(PYTHON) -I $(MODEL) check

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

# --- VHDL (GHDL) -------------------------------------------------------------
GHDL_WORK := $(BUILD)/ghdl
GHDL_A    := $(GHDL) -a $(GHDLFLAGS) --workdir=$(GHDL_WORK)
GHDL_RUN  := $(GHDL) --elab-run $(GHDLFLAGS) --workdir=$(GHDL_WORK)

$(GHDL_WORK)/.analysed: $(H_STRUCT) $(H_BEHAV) $(DIE_SIM)/tb_rng64_check.vhd $(DIE_SIM)/tb_die_check.vhd
	@mkdir -p $(GHDL_WORK)
	$(GHDL_A) $(H_STRUCT)
	$(GHDL_A) $(H_BEHAV)
	$(GHDL_A) $(DIE_SIM)/tb_rng64_check.vhd $(DIE_SIM)/tb_die_check.vhd
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

# --- RAM controller (HW3, VHDL) ---------------------------------------------
GHDL_WORK_RAM := $(BUILD)/ghdl-ram

test-ram: $(RAM_RTL)/seq_rw_ram.vhd $(RAM_SIM)/tb_seq_rw_ram.vhd
	@mkdir -p $(GHDL_WORK_RAM)
	$(GHDL) -a $(GHDLFLAGS) --workdir=$(GHDL_WORK_RAM) $(RAM_RTL)/seq_rw_ram.vhd $(RAM_SIM)/tb_seq_rw_ram.vhd
	$(GHDL) --elab-run $(GHDLFLAGS) --workdir=$(GHDL_WORK_RAM) tb_seq_rw_ram

clean:
	rm -rf $(BUILD)
