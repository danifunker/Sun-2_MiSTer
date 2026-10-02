// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - asynchronous input synchroniser.
//
// UM 5.3, figure 5-17: "All asynchronous bus arbitration signals to the
// processor are synchronized before being used internally. [...] The input
// asynchronous signal is sampled on the falling edge of the clock and is valid
// internally after the next falling edge."
//
// Two falling-edge stages, so an input that meets specification 47 before a
// falling edge is valid internally one clock later. Combined with the rule that
// arbitration outputs change on rising edges (UM 5.3), this puts BR-asserted to
// BG-asserted at a minimum of 1.5 clocks, which is exactly specification 35's
// lower limit.
//
// This is NOT the path used for DTACK, BERR and VPA. Those are sampled directly
// by the bus state machine's own falling-edge decision, with no extra clock of
// latency -- figure 10-4 shows DTACK asserted 0.45 states before the S4/S5
// falling edge and S5 entered at that same edge.
//
// RESET_VAL is the inactive level: 1 for the active-low pins, which is all of
// them except IPL's encoded value (also active low, so also 1 = no interrupt).

module rd68011_sync #(
    parameter int   WIDTH     = 1,
    parameter logic RESET_VAL = 1'b1
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);

  logic [WIDTH-1:0] meta;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      meta <= {WIDTH{RESET_VAL}};
      q    <= {WIDTH{RESET_VAL}};
    end else begin
      meta <= d;
      q    <= meta;
    end
  end

endmodule
