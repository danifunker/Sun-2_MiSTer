#!/bin/bash
# Mutation check for the keyboard's beeper: each line puts a bug into a copy of
# the tone generator (tb_mister_bell must fail) or of the keyboard bridge's bell
# and click commands (tb_mister_kbd_mouse must fail).
#
#     tb/verilator/mutate_bell.sh
#
# A "NOT CAUGHT" is a hole in the tests, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/bellmut
mkdir -p $W
VFLAGS="--binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
  -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-INITIALDLY"
run() {
  name="$1"; which="$2"; shift 2
  if [ "$which" = tone ]; then orig=$RTL/sun2_mister_bell.sv; top=tb_mister_bell
  else orig=$RTL/sun2_mister_kbd_mouse.sv; top=tb_mister_kbd_mouse; fi
  cp $orig $W/dut.sv
  sed -i "$@" $W/dut.sv
  if cmp -s $orig $W/dut.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator $VFLAGS --top-module $top --Mdir $W/obj -o tb $top.sv $W/dut.sv >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^$top: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
# the tone
run "an octave up"                 tone -e 's|\* 240 / 1000;|* 120 / 1000;|'
run "no filter"                    tone -e 's/parameter int K      = 10 /parameter int K      = 1  /'
run "silence left at -1"           tone -e 's/if (!on \&\& \&acc\[W-1:K\])/if (1'"'"'b0)/'
run "Loud and Quiet swapped"       tone -e "s/(vol == 2'd1) ? 16'sd16000/(vol == 2'd1) ? 16'sd2000/" \
                                        -e "s/(vol == 2'd2) ? 16'sd2000 /(vol == 2'd2) ? 16'sd16000/"
run "Off is not silent"            tone -e "s/16'sd2000  : 16'sd0;/16'sd2000  : 16'sd500;/"
run "a beep starts where the last ended" tone -e 's/high <= 1.b1;                   \/\/ every beep/high <= high; \/\//'
# the keyboard's commands
run "the bell is a one-shot"       kbd  -e "s/8'h02: bell <= 1'b1;/8'h02: click_left <= CLICK_TICKS;/"
run "0x0A ignored"                 kbd  -e "s/8'h0A: click_en <= 1'b1;/8'h0A: ;/"
run "0x0B ignored"                 kbd  -e "s/8'h0B: begin click_en <= 1'b0; click_left <= '0; end/8'h0B: ;/"
run "a 10 ms click"                kbd  -e 's|CLICK_TICKS = CLK_HZ / 200;|CLICK_TICKS = CLK_HZ / 100;|'
run "a click on the break too"     kbd  -e "s/ev_v   <= 1'b1; ev_b <= kc | 8'h80;/ev_v   <= 1'b1; ev_b <= kc | 8'h80; if (click_en) click_left <= CLICK_TICKS;/"
run "RESET keeps the click"        kbd  -e "s/bell <= 1'b0; click_en <= 1'b0; click_left <= '0;/bell <= 1'b0; click_left <= '0;/"
run "RESET keeps the bell"         kbd  -e "s/bell <= 1'b0; click_en <= 1'b0; click_left <= '0;/click_en <= 1'b0; click_left <= '0;/"
