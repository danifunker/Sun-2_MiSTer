// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - dual-edge output cell.
//
// A few bus signals are asserted on one clock edge and negated on the other.
// AS, for instance, asserts on the rising edge of S2 and negates on the falling
// edge entering S7 (UM 5.1.1). A single flop cannot do that, and a flop clocked
// by a mux of the clock level is not something to hand to a synthesis tool.
//
// The standard answer is two flops -- one per edge -- combined with XOR. Only
// one of them can change at any instant, because they are clocked by opposite
// edges, so the output is glitch-free. To place a value v on the output from
// the positive-edge side, that side stores v ^ (the other side), which is
// stable at that moment by construction.
//
// Both sides reset to 0, so q resets to 0. Callers that need a signal to reset
// high (an active-low strobe, say) invert at the point of use.

module rd68011_dedge_ff #(
    parameter int WIDTH = 1
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             en_p,   // load d_p on the rising edge
    input  logic [WIDTH-1:0] d_p,
    input  logic             en_n,   // load d_n on the falling edge
    input  logic [WIDTH-1:0] d_n,

    output logic [WIDTH-1:0] q
);

  logic [WIDTH-1:0] q_p;
  logic [WIDTH-1:0] q_n;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)     q_p <= '0;
    else if (en_p)  q_p <= d_p ^ q_n;
  end

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n)     q_n <= '0;
    else if (en_n)  q_n <= d_n ^ q_p;
  end

  assign q = q_p ^ q_n;

endmodule
