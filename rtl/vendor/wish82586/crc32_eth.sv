// SPDX-License-Identifier: MIT
//
// Ethernet FCS (CRC-32) accumulator.
//
// Reflected form: the polynomial is 0xEDB88320, data enters LSB first, the
// register is preset to all ones and the transmitted FCS is the bit-inverted
// residue.  DATA_W selects nibble-wide (MII) or byte-wide operation; nibbles
// are consumed low nibble first, matching the order MII puts them on the wire.
//
// Transmit:  preset with init, feed the frame, then send fcs_o on the wire
//            starting with fcs_o[7:0] (least significant byte first).
// Receive:   preset with init, feed the frame *including* its four FCS bytes;
//            crc_ok_o is then high if the frame was received intact.

module crc32_eth #(
    parameter int DATA_W = 4
) (
    input  logic              clk,
    input  logic              rst,
    input  logic              init,    // synchronous preset to all ones
    input  logic              en,      // consume data_i this cycle
    input  logic [DATA_W-1:0] data_i,
    output logic [31:0]       crc_o,   // running residue
    output logic [31:0]       fcs_o,   // FCS to append, low byte transmitted first
    output logic              crc_ok_o // residue matches the Ethernet magic value
);

  initial begin
    if (DATA_W != 4 && DATA_W != 8) $fatal(1, "crc32_eth: DATA_W must be 4 or 8");
  end

  function automatic logic [31:0] crc_step(input logic [31:0] crc, input logic bit_i);
    logic feedback;
    feedback = crc[0] ^ bit_i;
    crc_step = {1'b0, crc[31:1]} ^ (feedback ? 32'hedb8_8320 : 32'h0);
  endfunction

  function automatic logic [31:0] crc_next(input logic [31:0] crc, input logic [DATA_W-1:0] d);
    logic [31:0] c;
    c = crc;
    for (int i = 0; i < DATA_W; i++) c = crc_step(c, d[i]);
    crc_next = c;
  endfunction

  logic [31:0] crc_q;

  always_ff @(posedge clk) begin
    if (rst || init) crc_q <= 32'hffff_ffff;
    else if (en) crc_q <= crc_next(crc_q, data_i);
  end

  assign crc_o    = crc_q;
  assign fcs_o    = ~crc_q;
  assign crc_ok_o = (crc_q == 32'hdebb_20e3);

endmodule
