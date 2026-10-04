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
run "short frames not padded"        -e 's/rx_send     <= (rx_len < MIN_DATA) ? MIN_DATA : rx_len;/rx_send     <= rx_len;/'
run "FCS a nibble late"              -e 's/.data_i(rnib),/.data_i(mii_rxd),/'
run "CRS dropped while copying out"  -e 's/(cable_mm \&\& (tst == T_HELD || tst == T_DONE ||/(cable_mm \&\& (/'
run "loopback ignored on transmit"   -e 's/tn <= MAX_DATA + 12.d4 \&\& cable_mm \&\& on_m)/tn <= MAX_DATA + 12'"'"'d4 \&\& on_m)/'
run "loopback ignored on receive"    -e 's/rx_keep <= cable;/rx_keep <= 1'"'"'b1;/' -e 's/> MAX_DATA || rdata\[63:11\] != 0 || !cable)/> MAX_DATA || rdata[63:11] != 0)/'
run "magic published first"          -e 's/E_CLR:     mem(1, A_MAGIC,  64.d0, E_CLR_TX);/E_CLR:     mem(1, A_MAGIC,  MAGIC, E_CLR_TX);/'
run "Off leaves the magic"           -e 's/E_UNPUB:   mem(1, A_MAGIC, 64.d0, E_OFF);/E_UNPUB:   est <= E_OFF;/'
run "a changed MAC never republished" -e 's/end else if (mac_q != mac_pub)/end else if (1'"'"'b0)/'
run "RX pointer not advanced"        -e 's/mem(1, A_RXRPTR, rx_rptr + 1.d1, E_IDLE);/mem(1, A_RXRPTR, rx_rptr, E_IDLE);/'
run "a read taken before its answer" -e 's/est      <= DDRAM_RD ? E_MEM_RD : eret;/est      <= eret; rdata <= DDRAM_DOUT;/'
run "no gap after a received frame"  -e 's/rgap     <= RX_GAP;/rgap     <= 6'"'"'d0;/'
run "a frame offered before it is whole" -e 's/T_HELD: begin                       \/\/ the last byte/T_HELD: begin tst <= T_DONE; \/\//'
