// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - the divider for DIVU and DIVS.
//
// Thirty-two bits by sixteen, producing a sixteen-bit quotient and a
// sixteen-bit remainder, which PRM section 4 puts in the low and high halves
// of the destination register respectively.
//
// SEQUENTIAL, DELIBERATELY
//
// Every other arithmetic unit in this design is combinational, because doing
// the work in one step costs only cycle count and the bus behaviour is
// identical either way. A 32-by-16 divider is the exception: combinationally
// it would be both large and slow, and the critical path through the microcode
// store is already what limits the design's frequency. So this shifts and
// subtracts, one bit per clock, and the sequencer waits on `busy` the same way
// it waits on a bus cycle.
//
// Thirty-two iterations rather than sixteen: the quotient of a 32-bit dividend
// can need all thirty-two bits, and finding out that it does is how overflow
// is detected.
//
// SIGNS
//
// DIVS divides magnitudes and applies the signs afterwards: the quotient takes
// the exclusive-or of the operand signs and the remainder takes the dividend's
// (PRM section 4). Overflow is tested against the signed range, so a quotient
// of exactly 0x8000 is representable when negative and is not when positive.

module rd68011_divider (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic        is_signed,
    input  logic [31:0] dividend,
    input  logic [15:0] divisor,

    output logic        busy,
    output logic [15:0] quotient,
    output logic [15:0] remainder,
    output logic        ovf
);

  logic [31:0] q;
  logic [31:0] rem;
  logic [31:0] den;
  logic  [5:0] count;
  logic        neg_q, neg_r;
  // Latched, because the overflow test below is read long after `start`: by
  // then the microword driving is_signed has moved on, and reading the live
  // input would test a signed division against the unsigned range.
  logic        signed_r;
  logic [31:0] rem_shift;

  // The magnitudes the loop actually works on.
  logic [31:0] abs_dividend;
  logic [15:0] abs_divisor;
  assign abs_dividend = (is_signed && dividend[31]) ? (~dividend + 32'd1)
                                                    : dividend;
  assign abs_divisor  = (is_signed && divisor[15])  ? (~divisor + 16'd1)
                                                    : divisor;

  assign rem_shift = {rem[30:0], q[31]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy  <= 1'b0;
      q     <= 32'd0;
      rem   <= 32'd0;
      den   <= 32'd0;
      count <= 6'd0;
      neg_q <= 1'b0;
      neg_r <= 1'b0;
      signed_r <= 1'b0;
    end else if (start && !busy) begin
      busy  <= 1'b1;
      q     <= abs_dividend;
      rem   <= 32'd0;
      den   <= {16'd0, abs_divisor};
      count <= 6'd32;
      // The quotient is negative when exactly one operand was; the remainder
      // follows the dividend.
      neg_q <= is_signed && (dividend[31] ^ divisor[15]);
      neg_r <= is_signed && dividend[31];
      signed_r <= is_signed;
    end else if (busy) begin
      if (count == 6'd0) begin
        busy <= 1'b0;
      end else begin
        // Shift the next dividend bit into the remainder and subtract if it
        // fits, recording a quotient bit either way.
        if (rem_shift >= den) begin
          rem <= rem_shift - den;
          q   <= {q[30:0], 1'b1};
        end else begin
          rem <= rem_shift;
          q   <= {q[30:0], 1'b0};
        end
        count <= count - 6'd1;
      end
    end
  end

  // The results, with the signs put back.
  logic [15:0] mag_q;
  logic [15:0] mag_r;
  assign mag_q = q[15:0];
  assign mag_r = rem[15:0];

  assign quotient  = neg_q ? (~mag_q + 16'd1) : mag_q;
  assign remainder = neg_r ? (~mag_r + 16'd1) : mag_r;

  // Overflow. Unsigned: anything above sixteen bits. Signed: anything outside
  // the range a sixteen-bit signed quotient can hold, which is asymmetric.
  // The top bit of the remainder register never survives a shift, so it is
  // never read back.
  logic unused;
  assign unused = &{1'b1, rem[31]};

  assign ovf = signed_r ? ((q[31:16] != 16'd0) ||
                            (neg_q ? (mag_q > 16'h8000) : (mag_q > 16'h7FFF)))
                         :  (q[31:16] != 16'd0);

endmodule
