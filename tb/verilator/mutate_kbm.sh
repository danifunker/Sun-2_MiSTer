#!/bin/bash
# Mutation check for the mouse path: each line puts a bug into a copy of the
# MiSTer bridge or of the Z8530, and the tests must fail -- tb_kbm_scc for
# both, tb_mister_kbd_mouse as well for the bridge.
#
#     tb/verilator/mutate_kbm.sh
#
# A "NOT CAUGHT" is a hole in the tests, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/kbmmut
mkdir -p $W
VFLAGS="--binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
  -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY"
# bench result: "caught -- ..." or "passes"
bench() {
  top="$1"; shift
  rm -rf $W/obj_$top
  verilator $VFLAGS --top-module $top --Mdir $W/obj_$top -o tb "$@" >$W/build.log 2>&1 || { echo "BUILD FAILED"; return; }
  out=$($W/obj_$top/tb 2>&1)
  if echo "$out" | grep -q "^PASS"; then echo "passes"; return; fi
  echo "caught -- $(echo "$out" | grep -E "^$top: [0-9]|timeout" | head -1) -- $(echo "$out" | grep -m1 "^FAIL ")"
}
run() {
  name="$1"; which="$2"; shift 2
  cp $RTL/sun2_mister_kbd_mouse.sv $W/bridge.sv
  cp $RTL/vendor/z8530_scc/z8530_scc.sv $W/scc.sv
  sed -i "$@" $W/$which.sv
  if [ "$which" = bridge ]; then orig=$RTL/sun2_mister_kbd_mouse.sv; else orig=$RTL/vendor/z8530_scc/z8530_scc.sv; fi
  if cmp -s $orig $W/$which.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  r1=$(bench tb_kbm_scc tb_kbm_scc.sv $W/bridge.sv $W/scc.sv)
  r2=""
  [ "$which" = bridge ] && r2=$(bench tb_mister_kbd_mouse tb_mister_kbd_mouse.sv $W/bridge.sv)
  if [ "$r1" = passes ] && { [ -z "$r2" ] || [ "$r2" = passes ]; }; then
    echo "$name: NOT CAUGHT"
  else
    echo "$name: tb_kbm_scc $r1${r2:+; tb_mister_kbd_mouse $r2}"
  fi
}
# the bridge
run "middle and right swapped"     bridge -e 's/eb = {ps2_mouse\[0\], ps2_mouse\[2\], ps2_mouse\[1\]};/eb = {ps2_mouse[0], ps2_mouse[1], ps2_mouse[2]};/'
run "Y inverted"                   bridge -e 's/ay = lim(ay + ey,/ay = lim(ay - ey,/'
run "first delta not kept off 0x80" bridge -e "s/hx = lim(ax, -13'sd112, 13'sd127);/hx = lim(ax, -13'sd128, 13'sd127);/"
run "packet total not limited"     bridge -e "s/hx = lim(ax, (dx1 < 0) ? (-13'sd128 - dx1) : -13'sd112, 13'sd127 - dx1);/hx = ax;/"
run "button changes never queued"  bridge -e 's/if (eb != btn_new) begin/if (1'"'"'b0) begin/'
run "backlog not capped"           bridge -e "s/ACC_MAX = 13'sd255;/ACC_MAX = 13'sd4095;/"
run "no packet ever starts"        bridge -e "s/m_room == 7'd64/m_room == 7'd65/"
# the SCC's channel B
run "B receives A's line"          scc    -e 's/: rxdb_sync_s\[2\];/: rxda_sync_s[2];/'
run "B Rx vector names channel A"  scc    -e "s/rx_int_active_b  ? 3'b010/rx_int_active_b  ? 3'b110/"
run "B receiver waits for DCD"     scc    -e 's/wire rx_dcd_ok_b_s = ~auto_en_b_s | ~dcdb_s_sync\[1\];/wire rx_dcd_ok_b_s = ~dcdb_s_sync[1];/'
