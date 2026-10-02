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

TESTS := tb_mister_sdram tb_mister_block tb_mister_kbd_mouse

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

clean:
	rm -rf obj_*

.PHONY: all clean $(TESTS)
