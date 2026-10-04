# Verilator unit tests for the MiSTer glue.
#
#   make -C tb/verilator            all of them
#   make -C tb/verilator tb_mister_sdram
#
# Verilator 5 with --timing; each target builds into obj_<name>/ and runs.

V      ?= verilator
RTL    := ../../rtl
VFLAGS := --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          -Wno-UNSIGNED -Wno-CMPCONST -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY \
          +define+SIMULATION=1

TESTS := tb_mister_sdram tb_mister_block tb_mister_kbd_mouse tb_mister_bell tb_mister_enet tb_kbm_scc tb_mister_tod tb_mt02 tb_scsi_odd tb_shifter_equiv

# The whole core is its own makefile; it is a run, not a quick test, so it is
# not part of `all'.
.DEFAULT_GOAL := all
include emu.mk

all: $(TESTS)

tb_mister_sdram:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv sdram_model.sv altddio_out_stub.v $(RTL)/sdram.sv $(RTL)/sun2_mister_sdram.sv
	./obj_$@/$@

tb_mister_block:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun2_mister_block.sv
	./obj_$@/$@

tb_mister_kbd_mouse:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun2_mister_kbd_mouse.sv
	./obj_$@/$@

# The keyboard's beeper as sound, on the audio clock.
tb_mister_bell:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun2_mister_bell.sv
	./obj_$@/$@

# The wire behind the 82586: its own MII transmitter and receiver against the
# PHY side and a DDR3 mailbox.
W82586 := $(RTL)/vendor/wish82586
tb_mister_enet:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(W82586)/crc32_eth.sv $(W82586)/mii_tx.sv $(W82586)/mii_rx.sv \
	    $(RTL)/sun2_mister_enet.sv $@.sv
	./obj_$@/$@

# The bridge into the keyboard/mouse Z8530 as sun2_fpga.v builds it, programmed
# and serviced the way SunOS 4 does: the mouse is the only channel-B receiver.
tb_kbm_scc:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $@.sv $(RTL)/sun2_mister_kbd_mouse.sv $(RTL)/vendor/z8530_scc/z8530_scc.sv
	./obj_$@/$@

# MiSTer's timestamp into the time-of-day clock, read back as SunOS 4 reads it.
tb_mister_tod:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ -I$(RTL)/sun2-common \
	    $@.sv $(RTL)/sun2_mister_tod.sv $(RTL)/sun2-common/mm58167.v
	./obj_$@/$@

# The tapes it reads are built by tools/mktape itself, so the image format is
# tested from both ends.
tb_mt02:
	mkdir -p obj_$@
	python3 mk_mt02_tapes.py obj_$@ ../../tools/mktape
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(RTL)/vendor/wish5380/wish5380_pkg.sv $(RTL)/vendor/wish5380/scsi_fabric.sv \
	    $(RTL)/sun2-common/sun2_mt02.sv $@.sv
	./obj_$@/$@ +dir=obj_$@

tb_scsi_odd:
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(RTL)/vendor/wish5380/wish5380_pkg.sv $(RTL)/vendor/wish5380/scsi_fabric.sv \
	    $(RTL)/vendor/wish5380/scsi_targ.sv $(RTL)/sun2-common/sun2_mt02.sv \
	    -I$(RTL)/sun2-common $(RTL)/sun2-common/sun2_scsi_core.sv $@.sv
	./obj_$@/$@

# The patched shifter against upstream's, renamed so both can be in one model.
tb_shifter_equiv:
	mkdir -p obj_$@
	sed 's/^module rd68011_shifter /module rd68011_shifter_ref /' \
	    $(RTL)/vendor/rd68011/rd68011_shifter.sv > obj_$@/rd68011_shifter_ref.sv
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(RTL)/patched/rd68011/rd68011_shifter.sv obj_$@/rd68011_shifter_ref.sv $@.sv
	./obj_$@/$@

# The colour board against the C model: a bus trace of SunOS 4.0's own
# libpixrect (CG2_KERNEL=1: the kernel's cg2_rop and cgtwo driver) recorded by
# tools/cg2model's harness, replayed into the RTL, every read and the whole
# megabyte checked.  Needs the harness, and so the SunOS 4.0 tapes: see
# tools/cg2model/Makefile.  Not part of `all' for that reason.
CG2_N      ?= 400
CG2_SEED   ?= 1
CG2_KERNEL ?=
CG2_DIR    := ../../build/cg2model
CG2_IMG    := $(if $(CG2_KERNEL),kern40,lp40)
tb_cgtwo:
	$(MAKE) -C ../../tools/cg2model $(CG2_DIR:../../%=../../%)/harness \
	    ../../build/cg2model/lp40.bin ../../build/cg2model/kern40.bin
	mkdir -p obj_$@
	$(CG2_DIR)/harness $(CG2_DIR)/$(CG2_IMG).bin $(CG2_DIR)/$(CG2_IMG).sym \
	    $(if $(CG2_KERNEL),-k) -n $(CG2_N) -s $(CG2_SEED) \
	    -t obj_$@/trace.txt -I obj_$@/init.bin -F obj_$@/final.bin
	$(V) $(VFLAGS) --top-module $@ --Mdir obj_$@ -o $@ \
	    $(RTL)/sun2-vme/sun2_cgtwo.sv $@.sv
	./obj_$@/$@ +trace=obj_$@/trace.txt +init=obj_$@/init.bin +final=obj_$@/final.bin

clean:
	rm -rf obj_* run_*

.PHONY: all clean $(TESTS) tb_cgtwo
