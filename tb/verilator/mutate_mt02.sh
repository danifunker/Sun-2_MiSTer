#!/bin/bash
# Mutation check for tb_mt02: each line puts back a bug, and the test must
# fail.  Run after `make tb_mt02` (it reads the tapes that left in obj_tb_mt02):
#
#     tb/verilator/mutate_mt02.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
mkdir -p /tmp/mt02mut
run() {
  name="$1"; shift
  cp $RTL/sun2-common/sun2_mt02.sv /tmp/mt02mut/m.sv
  sed -i "$@" /tmp/mt02mut/m.sv
  if cmp -s $RTL/sun2-common/sun2_mt02.sv /tmp/mt02mut/m.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf /tmp/mt02mut/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD --top-module tb_mt02 --Mdir /tmp/mt02mut/obj -o tb \
    $RTL/vendor/wish5380/wish5380_pkg.sv $RTL/vendor/wish5380/scsi_fabric.sv /tmp/mt02mut/m.sv tb_mt02.sv >/tmp/mt02mut/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$(/tmp/mt02mut/obj/tb +dir=obj_tb_mt02 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mt02:|timed out")
  first=$(echo "$out" | grep -m3 "^FAIL:" | tr '\n' ';')
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT ($summary)"; else echo "$name: caught -- $summary -- $first"; fi
}
run "no PROM bit in sense byte 4"   -e 's/s_info\[23:16\] | 8'"'"'h01/s_info[23:16]/'
run "sense capped at 18"            -e "s/(alloc_len < 10'd16) ? alloc_len : 10'd16/(alloc_len < 10'd18) ? alloc_len : 10'd18/"
run "fetch while busy"              -e 's/end else if (!blk_busy) begin/end else begin/'
run "file mark not crossed by READ" -e '/s_info    <= {8'"'"'d0, blk_left};/{n;s/pos_file  <= pos_file + 5'"'"'d1;/pos_file  <= pos_file;/}'
run "space blocks off by one"       -e "s/{8'd0, cdb_count} <= blocks_ahead/{8'd0, cdb_count} < blocks_ahead/"
run "no raw fallback"               -e "s/end else if (t_vol == 2'd0) begin/end else if (1'b0) begin/"
run "file mark error code"          -e "s/EM_FILE_MARK     = 8'h1c/EM_FILE_MARK     = 8'h1d/"
run "no residue, blank or error"    -e "s/s_info  <= {8'd0, blk_left};/s_info  <= 32'd0;/"
run "no residue at a file mark"     -e "s/s_info    <= {8'd0, blk_left};/s_info    <= 32'd0;/"
run "volume change ignored"         -e 's/if (need_load || volume_i != t_vol) begin/if (need_load) begin/'
run "write not protected"           -e 's/else          check_cond(SK_PROTECT, EM_PROTECTED);/else ;/'
run "10-byte CDB cut short"         -e "s/if (idx + 10'd1 == {6'd0, cdb_len}) begin/if (idx == 10'd5) begin/"
run "INQUIRY longer than five bytes" -e "s/(alloc_len < 10'd5) ? alloc_len : 10'd5/(alloc_len < 10'd36) ? alloc_len : 10'd36/"
