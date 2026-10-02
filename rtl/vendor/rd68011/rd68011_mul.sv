// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - the multiplier for MULU and MULS.
//
// Sixteen bits by sixteen to thirty-two, in one clock rather than in the thirty
// or so the original takes.
//
// WHY IT IS NOT IN THE ALU
//
// When it was taken out, the ALU's result fed the zero flag, the zero flag fed
// the micro-address of a conditional microword, that fed the microcode store,
// and the store's output had to reach the bus request pins on the edge that
// ends the current cycle -- all inside half a clock, because read data arrives
// on a falling edge and the request is latched on a rising one. A multiplier in
// that chain put a DSP in it, and synthesis had no way to know that no multiply
// ever takes its operands from read data. Taking it out was worth about ten
// nanoseconds of clock period; doc/timing-divergences.md has the measurement.
//
// Neither end of that chain is there any more. The bus request is steered on
// MOVEM's mask test alone, and the multiplier's operands come from source
// buses that leave read data out, which assemble.py enforces
// (doc/critical-path.md). So the reason is history; the arrangement stays,
// because putting the multiplier back would be a new measurement, not a revert.
//
// So it sits outside, with registered operands and a registered result, exactly
// as the divider does. One microword starts it, the next reads the answer.
// There is no busy signal: the answer is ready on the next edge, always.

module rd68011_mul (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic        is_signed,
    input  logic [15:0] a,
    input  logic [15:0] b,

    output logic [31:0] result
);

  logic [31:0] prod_u;
  logic [31:0] prod_s;

  assign prod_u = {16'd0, b} * {16'd0, a};
  assign prod_s = $signed(b) * $signed(a);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result <= 32'd0;
    end else if (start) begin
      result <= is_signed ? prod_s : prod_u;
    end
  end

endmodule
