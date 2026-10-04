#!/bin/bash
# Mutation check for tb_mister_enet: each line puts a bug into a copy of
# rtl/sun2_mister_enet.sv and the test must fail.
#
#     tb/verilator/mutate_enet.sh
#
# A "NOT CAUGHT" is a hole in the test, not a pass.
cd "$(dirname "$0")" || exit 1
RTL=../../rtl
W82586=$RTL/vendor/wish82586
W=/tmp/enetmut
mkdir -p $W
run() {
  name="$1"; shift
  cp $RTL/sun2_mister_enet.sv $W/dut.sv
  sed -i "$@" $W/dut.sv
  if cmp -s $RTL/sun2_mister_enet.sv $W/dut.sv; then echo "$name: MUTATION DID NOT APPLY"; return; fi
  rm -rf $W/obj
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-DECLFILENAME -Wno-UNUSED -Wno-PINCONNECTEMPTY --top-module tb_mister_enet --Mdir $W/obj -o tb \
    $W82586/crc32_eth.sv $W82586/mii_tx.sv $W82586/mii_rx.sv $W/dut.sv tb_mister_enet.sv >$W/build.log 2>&1 \
    || { echo "$name: BUILD FAILED"; return; }
  out=$($W/obj/tb 2>&1)
  summary=$(echo "$out" | grep -E "^tb_mister_enet: [0-9]|^timeout")
  first=$(echo "$out" | grep -m1 "^FAIL ")
  if echo "$out" | grep -q "^PASS"; then echo "$name: NOT CAUGHT"; else echo "$name: caught -- $summary -- $first"; fi
}
run "FCS left on transmitted frames" -e "s/tx_len <= tn\[10:0\] - 11'd4;/tx_len <= tn[10:0];/"
run "CRS dropped while copying out"  -e 's/(cable_mm \&\& (tst == T_HELD || tst == T_DONE ||/(cable_mm \&\& (/'
run "loopback ignored on transmit"   -e 's/tn <= MAX_DATA + 12.d4 \&\& cable_mm \&\& on_m)/tn <= MAX_DATA + 12'"'"'d4 \&\& on_m)/'
run "loopback ignored on receive"    -e 's/rx_good  = on \&\& cable \&\&/rx_good  = on \&\&/'
run "Network Off still delivers"     -e 's/rx_good  = on \&\& cable \&\&/rx_good  = cable \&\&/'
run "Off leaves a held frame waiting" -e 's/else if (tx_ready \&\& !on)/else if (1'"'"'b0)/'
run "the FCS not played"             -e 's/if (ri + 1.d1 == rx_len) begin/if (ri + 11'"'"'d5 == rx_len) begin/'
run "the hash read as length"        -e 's/rdata\[10:0\] <= RX_MAX;/rdata[63:0] <= RX_MAX;/'
run "eight RX slots, not sixteen"    -e 's/{rx_rptr\[3:0\], 8.h00}/{1'"'"'b0, rx_rptr[2:0], 8'"'"'h00}/'
run "four TX slots, not eight"       -e 's/{tx_wptr\[2:0\], 8.h00}/{1'"'"'b0, tx_wptr[1:0], 8'"'"'h00}/'
run "the TX ring's room ignored"     -e 's/if (tx_wptr - rdata < TX_RING) begin/if (1'"'"'b1) begin/'
run "a full ring drops at once"      -e 's/end else if (twait == TX_WAIT) begin/end else if (1'"'"'b1) begin/'
run "a full ring never gives up"     -e 's/end else if (twait == TX_WAIT) begin/end else if (1'"'"'b0) begin/'
run "magic published first"          -e 's/(pstep == 3.d6) ? {1.b1, 15.d0, mac_q} : 64.d0,/(pstep == 3'"'"'d6) ? {1'"'"'b1, 15'"'"'d0, mac_q} : (pstep == 3'"'"'d0) ? MAGIC : 64'"'"'d0,/'
run "GEN the same every publish"     -e 's/{32.d0, gen}/{32'"'"'d0, 32'"'"'d1}/'
run "published in machine reset"     -e 's/wire run    = !mrst_s\[1\];/wire run    = 1'"'"'b1;/'
run "a machine reset leaves the magic" -e 's/E_UNPUB: mem(1, A_MAGIC, 64.d0, E_OFF);/E_UNPUB: est <= E_OFF;/'
run "a changed MAC never republished" -e 's/else if (mac_q != mac_pub)/else if (1'"'"'b0)/'
run "RX pointer not advanced"        -e 's/mem(1, A_RXRPTR, rx_rptr + 1.d1, E_IDLE);/mem(1, A_RXRPTR, rx_rptr, E_IDLE);/'
run "a read taken before its answer" -e 's/est      <= DDRAM_RD ? E_MEM_RD : eret;/est      <= eret; rdata <= DDRAM_DOUT;/'
run "no gap after a received frame"  -e 's/rgap     <= RX_GAP;/rgap     <= 6'"'"'d0;/'
run "a frame offered before it is whole" -e 's/T_HELD: begin                       \/\/ the last byte/T_HELD: begin tst <= T_DONE; \/\//'
