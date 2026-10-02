// SPDX-License-Identifier: MIT
//
// Three-way arbiter in front of the memory port.
//
// Priority runs 0, 1, 2.  Port 0 belongs to the SCB handler, whose accesses
// come in short bursts after a channel attention; port 1 is the receive unit,
// which cannot ask the wire to wait; port 2 is the command unit, which can.
//
// A grant is taken when a request first appears and held until the access is
// acknowledged, which is what wb_master expects: the requester keeps req
// asserted for the whole transaction.

module wb_arb (
    input  logic        clk,
    input  logic        rst,

    // ---- port 0 (priority) --------------------------------------------------
    input  logic        p0_req_i,
    input  logic        p0_we_i,
    input  logic [1:0]  p0_size_i,
    input  logic [3:0]  p0_sel_i,
    input  logic [23:0] p0_addr_i,
    input  logic [31:0] p0_wdata_i,
    output logic        p0_ack_o,
    output logic        p0_err_o,

    // ---- port 1 -------------------------------------------------------------
    input  logic        p1_req_i,
    input  logic        p1_we_i,
    input  logic [1:0]  p1_size_i,
    input  logic [3:0]  p1_sel_i,
    input  logic [23:0] p1_addr_i,
    input  logic [31:0] p1_wdata_i,
    output logic        p1_ack_o,
    output logic        p1_err_o,

    // ---- port 2 -------------------------------------------------------------
    input  logic        p2_req_i,
    input  logic        p2_we_i,
    input  logic [1:0]  p2_size_i,
    input  logic [3:0]  p2_sel_i,
    input  logic [23:0] p2_addr_i,
    input  logic [31:0] p2_wdata_i,
    output logic        p2_ack_o,
    output logic        p2_err_o,

    // Read data is shared; each port latches it on its own ack.
    output logic [31:0] rdata_o,

    // ---- to wb_master -------------------------------------------------------
    output logic        req_o,
    output logic        we_o,
    output logic [1:0]  size_o,
    output logic [3:0]  sel_o,
    output logic [23:0] addr_o,
    output logic [31:0] wdata_o,
    input  logic        ack_i,
    input  logic        err_i,
    input  logic [31:0] rdata_i
);

  logic       lock;   // a grant is in progress
  logic [1:0] sel;    // which port holds it

  // Before the grant is locked in, priority decides; afterwards it stays put.
  wire [1:0] pick    = p0_req_i ? 2'd0 : (p1_req_i ? 2'd1 : 2'd2);
  wire [1:0] sel_now = lock ? sel : pick;
  wire       any_req = p0_req_i || p1_req_i || p2_req_i;

  always_ff @(posedge clk) begin
    if (rst) begin
      lock <= 1'b0;
      sel  <= 2'd0;
    end else if (!lock) begin
      if (any_req) begin
        sel  <= pick;
        lock <= 1'b1;
      end
    end else if (ack_i) begin
      lock <= 1'b0;
    end
  end

  always_comb begin
    case (sel_now)
      2'd0: begin
        req_o   = p0_req_i;
        we_o    = p0_we_i;
        size_o  = p0_size_i;
        sel_o   = p0_sel_i;
        addr_o  = p0_addr_i;
        wdata_o = p0_wdata_i;
      end
      2'd1: begin
        req_o   = p1_req_i;
        we_o    = p1_we_i;
        size_o  = p1_size_i;
        sel_o   = p1_sel_i;
        addr_o  = p1_addr_i;
        wdata_o = p1_wdata_i;
      end
      default: begin
        req_o   = p2_req_i;
        we_o    = p2_we_i;
        size_o  = p2_size_i;
        sel_o   = p2_sel_i;
        addr_o  = p2_addr_i;
        wdata_o = p2_wdata_i;
      end
    endcase
  end

  assign p0_ack_o = ack_i && (sel_now == 2'd0);
  assign p0_err_o = err_i && (sel_now == 2'd0);
  assign p1_ack_o = ack_i && (sel_now == 2'd1);
  assign p1_err_o = err_i && (sel_now == 2'd1);
  assign p2_ack_o = ack_i && (sel_now == 2'd2);
  assign p2_err_o = err_i && (sel_now == 2'd2);
  assign rdata_o  = rdata_i;

endmodule
