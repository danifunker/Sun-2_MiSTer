# tb_emu: the whole core, built from the same sources and defines as Quartus.
#
# The file list is files.qip's and the defines are Sun-2.qsf's VERILOG_MACROs,
# read here rather than copied, so the simulation cannot drift from the build.
# Only the framework is replaced: the PLLs (pll_stub.sv), hps_io
# (hps_io_model.sv) and the SDRAM chip (sdram_model.sv).
#
#   make -C tb/verilator tb_emu [MEM_PAGES=512] [TIMEOUT_MS=3000] [ROM=...] [DISK=...] [KEYS=...]
#
# MEM_PAGES is the installed memory in 2 KiB pages.  The PROM writes every
# installed byte before it says anything, so 512 (1 MiB) is the default here;
# the bitstream has 4096 (8 MiB).  The PROM is the simulation-patched image
# (tools/sim_speedup_sun250.txt: delay loop shortened, destructive memory test
# skipped) sent through the real boot0.rom loader.

TOP_DIR    := ../..
QIP_FILES  := $(shell sed -n -E 's/^set_global_assignment -name (SYSTEM)?VERILOG_FILE ([^ ]+).*$$/\2/p' $(TOP_DIR)/files.qip | tr -d '\r')
QSF_DEFS   := $(shell sed -n -E 's/^set_global_assignment -name VERILOG_MACRO "([^"]+)".*$$/+define+\1/p' $(TOP_DIR)/Sun-2.qsf | tr -d '\r')
MEM_PAGES  ?= 512
TIMEOUT_MS ?= 3000
ROM        ?= $(TOP_DIR)/build/rom/sun250-patched.bin
EMU_OBJ    := obj_tb_emu
EMU_SIM_ARGS = +rom=$(abspath $(ROM)) +timeout_ms=$(TIMEOUT_MS) $(if $(DISK),+disk=$(abspath $(DISK))) $(if $(KEYS),+keys=$(KEYS)) $(SIMARGS)

$(TOP_DIR)/build/rom/sun250-patched.bin: $(TOP_DIR)/Inputs/boot0.rom $(TOP_DIR)/tools/sim_speedup_sun250.txt
	mkdir -p $(dir $@)
	tr -d '\r' < $(TOP_DIR)/tools/sim_speedup_sun250.txt > $(dir $@)sim_speedup_sun250.lf.txt
	$(TOP_DIR)/tools/rompatch $< $@ $(dir $@)sim_speedup_sun250.lf.txt

tb_emu: $(ROM)
	mkdir -p $(EMU_OBJ)
	printf '`define BUILD_DATE "sim"\n' > $(EMU_OBJ)/build_id.v
	$(V) $(VFLAGS) -Wno-MULTIDRIVEN -Wno-SYNCASYNCNET -Wno-LATCH -Wno-COMBDLY -Wno-UNOPTFLAT \
	    -Wno-CASEINCOMPLETE -Wno-CASEOVERLAP -Wno-TIMESCALEMOD -Wno-IMPLICIT -Wno-REALCVT \
	    $(QSF_DEFS) +define+MEM_PAGES=$(MEM_PAGES) \
	    -I$(EMU_OBJ) -I$(TOP_DIR) -I$(TOP_DIR)/rtl/sun2-common \
	    --top-module tb_emu --Mdir $(EMU_OBJ) -o tb_emu -j 0 \
	    tb_emu.sv pll_stub.sv hps_io_model.sv sdram_model.sv altddio_out_stub.v \
	    $(addprefix $(TOP_DIR)/,$(QIP_FILES))
	mkdir -p run_tb_emu
	cd run_tb_emu && ../$(EMU_OBJ)/tb_emu $(EMU_SIM_ARGS)

.PHONY: tb_emu
