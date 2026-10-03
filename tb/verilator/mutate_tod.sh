#!/bin/bash
# Mutation check for tb_mister_tod: each line puts a bug into a copy of the
# timestamp converter or of the MM58167, and the test must fail.
#
#     tb/verilator/mutate_tod.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W=/tmp/todmut
mkdir -p $W
run() {
  name="$1"; which="$2"; shift 2
  cp $RTL/sun2_mister_tod.sv $W/conv.sv
  cp $RTL/sun2-common/mm58167.v $W/chip.v
  if [ "$which" = conv ]; then f=$W/conv.sv; orig=$RTL/sun2_mister_tod.sv; else f=$W/chip.v; orig=$RTL/sun2-common/mm58167.v; fi
  sed -i "$@" $f
  if cmp -s $orig $f; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY -I$RTL/sun2-common --top-module tb_mister_tod \
    --Mdir $W/obj -o tb tb_mister_tod.sv $W/conv.sv $W/chip.v >$W/build.log 2>&1 || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mister_tod: [0-9]|timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
# The chip holds the time modulo SunOS's 365-day year and the year comes from
# the root file system, so a shift that differs from 36 years by whole 365-day
# years loads the very same registers; 38 years crosses 1988's leap day and
# moves every date by one.
run "38 years, not 36"            conv -e "s/ys  = yy - 7'd6; /ys  = yy - 7'd8; /"
run "leap years counted from 1971" conv -e "s/((ys\[1:0\] == 2'd3) ? 10'd1 : 10'd0)/((ys[1:0] == 2'd2) ? 10'd1 : 10'd0)/"
run "the Sun's own leap day missed" conv -e "s/((ys\[1:0\] == 2'd2 \&\& m > 7'd2) ? 10'd1 : 10'd0)/10'd0/"
run "no wrap at 365"              conv -e "s/(sum >= 10'd365) ? sum - 10'd365 : sum/sum/"
run "weekday from 0"              conv -e "s/bcd(wd\[6:0\] + 7'd1)/bcd(wd[6:0])/"
run "March starts a day late"     conv -e "s/4'd2:  monthdays = 9'd59;/4'd2:  monthdays = 9'd60;/"
run "1970 and 2070 are loaded"    conv -e "s/yy <= 7'd69 \&\&/yy <= 7'd99 \&\&/"
run "every update loads"          conv -e "s/if (!(ONCE \&\& loaded) \&\& /if (/"
run "a load during reset is lost" chip -e 's/if (LD) ld_pend <= 1.b1;/if (LD \&\& reset_n) ld_pend <= 1'"'"'b1;/'
run "fractions not zeroed"        chip -e "/ld_pend  <= 1'b0;/{n;s/r_ms     <= 4'd0;/r_ms     <= 4'd5;/}"
