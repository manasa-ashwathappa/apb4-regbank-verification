# -----------------------------------------------------------------------------
# Build / run flow for the APB register bank testbench.
#
#   make                       build and run rand_test with seed 1
#   make TEST=irq_w1c_test     pick a test
#   make SEED=42 NUM_TXN=5000  reproduce or lengthen a run
#   make BUG=BUG_STRB          rebuild the DUT with a seeded bug
#   make regress               all tests x several seeds, summary at the end
#   make questa / make xcelium commercial-simulator one-liners (covergroups on)
#
# Verilator 5.028 or newer is needed for constrained randomisation; older
# versions parse the constraints but silently ignore them.
# -----------------------------------------------------------------------------

TEST    ?= rand_test
SEED    ?= 1
NUM_TXN ?=
BUG     ?=
VERILATOR ?= verilator

ROOT    := ..
RTL     := $(ROOT)/rtl/apb_regbank.sv
TB_INC  := $(ROOT)/tb
TB      := $(ROOT)/tb/apb_if.sv $(ROOT)/tb/apb_protocol_checker.sv $(ROOT)/tb/regbank_tb_pkg.sv $(ROOT)/tb/tb_top.sv

BUILD   := build$(if $(BUG),_$(BUG),)
DEFINES := $(if $(BUG),+define+$(BUG),)
RUNARGS := +TEST=$(TEST) $(if $(NUM_TXN),+NUM_TXN=$(NUM_TXN),) \
           +verilator+seed+$(SEED) +verilator+error+limit+1000

# Lint warnings that are noise for testbench code are turned off by name
# rather than with -Wno-fatal, so a new real warning still stops the build.
VFLAGS  := --binary --timing --assert -j 2 --top-module tb_top \
           -I$(TB_INC) $(DEFINES) \
           -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL \
           -Wno-COVERIGN -Wno-INITIALDLY

.PHONY: all build run regress clean questa xcelium

all: run

build: $(BUILD)/Vtb_top

$(BUILD)/Vtb_top: $(RTL) $(TB) $(wildcard $(TB_INC)/*.sv)
	$(VERILATOR) $(VFLAGS) --Mdir $(BUILD) $(RTL) $(TB)

run: build
	@mkdir -p logs
	./$(BUILD)/Vtb_top $(RUNARGS) 2>&1 | tee logs/$(TEST)_s$(SEED)$(if $(BUG),_$(BUG),).log

regress:
	./regress.sh

questa:
	vlog -sv +incdir+$(TB_INC) $(DEFINES) $(RTL) $(TB)
	vsim -c tb_top +TEST=$(TEST) -sv_seed $(SEED) -coverage -do "run -all; quit"

xcelium:
	xrun -sv -incdir $(TB_INC) $(DEFINES) $(RTL) $(TB) -top tb_top \
	     +TEST=$(TEST) -svseed $(SEED) -coverage functional

clean:
	rm -rf build build_* logs
