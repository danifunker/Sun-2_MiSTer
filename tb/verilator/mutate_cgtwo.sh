#!/bin/bash
# Mutation check for tb_cgtwo: each line puts a bug into a copy of the colour
# board, and the trace replay must fail.  Run tb_cgtwo once first: this replays
# the trace it left in obj_tb_cgtwo (any CG2_N will do; 100 is quick).
#
#     make -C tb/verilator tb_cgtwo CG2_N=100 && tb/verilator/mutate_cgtwo.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl/sun2-vme
T=obj_tb_cgtwo
W=/tmp/cg2mut
[ -f $T/trace.txt ] || { echo "run make tb_cgtwo first"; exit 1; }
mkdir -p $W
run() {
  name="$1"; shift
  cp $RTL/sun2_cgtwo.sv $W/cg.sv
  sed -i "$@" $W/cg.sv
  if cmp -s $RTL/sun2_cgtwo.sv $W/cg.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_cgtwo \
    --Mdir $W/obj -o tb tb_cgtwo.sv $W/cg.sv >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb +trace=$T/trace.txt +init=$T/init.bin +final=$T/final.bin 2>&1)
  summary=$(echo "$out" | grep -E "^tb_cgtwo: [0-9]+ bus|no DTACK")
  if echo "$summary" | grep -q "PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary"; fi
}
# the source FIFO and the aligner (doc/cgtwo.md, rules 1 and 2)
run "shift 0 takes the newer word"   -e "s/aligned = dir ? s2 : s1;/aligned = dir ? s1 : s2;/"
run "FIFO loads the wrong way"       -e "s/if (u_dir\[p\]) begin/if (!u_dir[p]) begin/"
run "shift ignores its count"        -e "s/aligned = 16'({s2, s1} >> cnt);/aligned = s1;/"
# the function (rule 3)
run "pattern ignored"                -e "s/ropfn\[b\] = op\[{p\[b\], s\[b\], d\[b\]}\];/ropfn[b] = op[{1'b0, s[b], d[b]}];/"
run "source and destination swapped" -e "s/ropfn\[b\] = op\[{p\[b\], s\[b\], d\[b\]}\];/ropfn[b] = op[{p[b], d[b], s[b]}];/"
# pixel format (rule 4)
run "pixel bytes in the wrong phase" -e "s/pixsrc = (d\[8 + p\] ? 16'hAAAA : 16'h0000) | (d\[p\] ? 16'h5555 : 16'h0000);/pixsrc = (d[8 + p] ? 16'h5555 : 16'h0000) | (d[p] ? 16'hAAAA : 16'h0000);/"
run "prime sources not pixel format" -e "s/if (rg_reg == 4'd1) u_src1\[p\] <= pixsrc(r_din, p\[2:0\]);/if (rg_reg == 4'd1) u_src1[p] <= r_din;/"
# the counter and the end masks (rule 5)
# masks from the counter as it stands, on every write: what the PRRWRD/SRWPIX
# middle-of-line writes would get if a write that loads nothing applied them
run "masks on writes that load nothing" -e "s/t_s1 = (ld_dst ? ((first/t_s1 = (1'b1 ? ((first/" \
    -e "s/^                        first\[p\] <= 1'b0;/                        first[p] <= (u_ocnt[p] == u_width[p]);/" \
    -e "s/^                        last\[p\]  <= 1'b0;/                        last[p]  <= (u_ocnt[p] == 16'd0);/"
run "first word is opcount 0"        -e "s/first\[p\]  <= (u_ocnt\[p\] == u_width\[p\]);/first[p]  <= (u_ocnt[p] == 16'd0);/"
run "count never reloads"            -e "s/u_ocnt\[p\] <= (u_ocnt\[p\] == 16'd0) ? u_width\[p\] : u_ocnt\[p\] - 16'd1;/u_ocnt[p] <= u_ocnt[p] - 16'd1;/"
run "destination loaded on reads only" -e "s/wire        ld_dst  = r_we ? ropmode\[1\] : ~ropmode\[1\];/wire        ld_dst  = ~r_we \& ~ropmode[1];/"
# the plane mask and the units it selects
run "ALLROP ignores the plane mask"  -e "s/if (rg_unit == 4'd8 ? ppmask\[p\] : (rg_unit\[2:0\] == p\[2:0\])) begin/if (rg_unit == 4'd8 ? 1'b1 : (rg_unit[2:0] == p[2:0])) begin/"
run "plane mask ignored on rop writes" -e "s/t_s2 = ppmask\[p\] ? (r_we16 \& ~t_s1) : 16'd0;/t_s2 = r_we16 \& ~t_s1;/"
# the memory
run "the line cache never misses"    -e "s/end else if (cvalid \&\& ctag == r_lidx) begin/end else if (cvalid) begin/"
run "the last halfword not written"  -e "s/if (chg\[15 - {wbk, 1'b0}\] | chg\[14 - {wbk, 1'b0}\]) begin/if ((chg[15 - {wbk, 1'b0}] | chg[14 - {wbk, 1'b0}]) \&\& wbk != 3'd7) begin/"
run "byte selects swapped"           -e "s/m_bs    <= {chg\[15 - {wbk, 1'b0}\], chg\[14 - {wbk, 1'b0}\]};/m_bs    <= {chg[14 - {wbk, 1'b0}], chg[15 - {wbk, 1'b0}]};/"
run "a word-mode read returns plane 1" -e "s/rdata_r <= lplane(cline, 3'd0);   \/\/ unknown; nothing uses it/rdata_r <= lplane(cline, 3'd1);/"
# the registers
run "ppmask written from the high byte" -e "s/if (r_we \&\& r_lds) ppmask <= r_din\[7:0\];/if (r_we \&\& r_lds) ppmask <= r_din[15:8];/"
run "colour map writes ignored"      -e "s/if (r_lds \&\& !status\[1\]) begin/if (1'b0) begin/"
