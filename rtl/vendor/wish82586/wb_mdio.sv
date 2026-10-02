// SPDX-License-Identifier: MIT
//
// MDIO station management, as a Wishbone B4 classic slave.
//
// This is the management side of MII, and it has nothing to do with the 82586:
// the chip predates it, and none of the drivers in doc/drivers knows a PHY
// exists.  It is here so that something can set the PHY up regardless - see
// mdio_prog, which drives these registers without any software involvement.
//
// Clause 22 frame, 64 bit times: 32 ones of preamble, the 01 start delimiter,
// the opcode (10 read, 01 write), five bits of PHY address, five of register
// address, two of turnaround, then sixteen of data.  The station drives MDIO
// on the falling edge of MDC and the PHY samples it on the rising edge; on a
// read the station lets go during turnaround and samples on the rising edge
// instead.
//
// Registers, byte offsets; the bus is word addressed so the index is the
// offset over four:
//
//   0x00 CTRL    [4:0] register address, [12:8] PHY address,
//                [16] 1 = read, [24] start (write one, reads as zero)
//   0x04 WDATA   [15:0] data for a write
//   0x08 RDATA   [15:0] data from the last read (read only)
//   0x0C STATUS  [0] busy, [1] the last read finished and RDATA is good
//   0x10 DIV     [7:0] MDC divider: MDC = clk / (2 * (DIV + 1))
//   0x14 ID      0x4d444a4f, "MDIO", for probing

module wb_mdio #(
    // Default divider, chosen so MDC stays under the 2.5 MHz the standard
    // allows from a 50 MHz bus.  Software can change it.
    parameter int DIV_RESET = 12
) (
    input  logic        clk,
    input  logic        rst,

    // ---- Wishbone B4 classic slave -----------------------------------------
    input  logic        wbs_cyc_i,
    input  logic        wbs_stb_i,
    input  logic        wbs_we_i,
    input  logic [3:0]  wbs_sel_i,
    input  logic [5:0]  wbs_adr_i,     // word address: register index
    input  logic [31:0] wbs_dat_i,
    output logic [31:0] wbs_dat_o,
    output logic        wbs_ack_o,
    output logic        wbs_err_o,

    // ---- MDIO ---------------------------------------------------------------
    output logic        mdc,
    output logic        mdio_o,
    output logic        mdio_oe,       // 1 while the station drives MDIO
    input  logic        mdio_i
);

  localparam logic [5:0] REG_CTRL   = 6'd0;   // 0x00
  localparam logic [5:0] REG_WDATA  = 6'd1;   // 0x04
  localparam logic [5:0] REG_RDATA  = 6'd2;   // 0x08
  localparam logic [5:0] REG_STATUS = 6'd3;   // 0x0c
  localparam logic [5:0] REG_DIV    = 6'd4;   // 0x10
  localparam logic [5:0] REG_ID     = 6'd5;   // 0x14

  localparam logic [31:0] ID_VALUE = 32'h4d44_4a4f;

  logic [4:0]  regad, phyad;
  logic        is_read;
  logic [15:0] wdata, rdata;
  logic [7:0]  divisor;
  logic        busy, rvalid;
  logic        start;

  // ---- register file ------------------------------------------------------
  wire acc = wbs_cyc_i && wbs_stb_i && !wbs_ack_o;
  wire wr  = acc && wbs_we_i;

  always_ff @(posedge clk) begin
    if (rst) begin
      regad   <= 5'h0;
      phyad   <= 5'h0;
      is_read <= 1'b0;
      wdata   <= 16'h0;
      divisor <= 8'(DIV_RESET);
      start   <= 1'b0;
    end else begin
      start <= 1'b0;
      if (wr) begin
        case (wbs_adr_i)
          REG_CTRL: begin
            regad   <= wbs_dat_i[4:0];
            phyad   <= wbs_dat_i[12:8];
            is_read <= wbs_dat_i[16];
            // Starting while one is in flight would corrupt it; the requester
            // is expected to look at STATUS first.
            start   <= wbs_dat_i[24] && !busy;
          end
          REG_WDATA: wdata   <= wbs_dat_i[15:0];
          REG_DIV:   divisor <= wbs_dat_i[7:0];
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    wbs_dat_o = 32'h0;
    case (wbs_adr_i)
      REG_CTRL: begin
        wbs_dat_o[4:0]   = regad;
        wbs_dat_o[12:8]  = phyad;
        wbs_dat_o[16]    = is_read;
      end
      REG_WDATA:  wbs_dat_o = {16'h0, wdata};
      REG_RDATA:  wbs_dat_o = {16'h0, rdata};
      REG_STATUS: wbs_dat_o = {30'h0, rvalid, busy};
      REG_DIV:    wbs_dat_o = {24'h0, divisor};
      REG_ID:     wbs_dat_o = ID_VALUE;
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) wbs_ack_o <= 1'b0;
    else     wbs_ack_o <= acc;
  end

  assign wbs_err_o = 1'b0;

  // ---- MDC ----------------------------------------------------------------
  logic [7:0] div_cnt;
  logic       tick;          // one system clock at each MDC edge

  always_ff @(posedge clk) begin
    if (rst) begin
      div_cnt <= 8'h0;
      mdc     <= 1'b0;
      tick    <= 1'b0;
    end else if (div_cnt == divisor) begin
      div_cnt <= 8'h0;
      mdc     <= ~mdc;
      tick    <= 1'b1;
    end else begin
      div_cnt <= div_cnt + 8'd1;
      tick    <= 1'b0;
    end
  end

  wire falling = tick && !mdc;   // mdc has just gone low
  wire rising  = tick && mdc;    // mdc has just gone high

  // The last system clock before MDC goes low to high, which is where a read
  // has to take its bit.  A PHY drives its answer between 0 and 300 ns after a
  // rising edge and holds it until the next one, so the bit an edge clocks in
  // is the one that has been sitting on the wire through the low period before
  // it - not whatever is there a cycle after the edge, which at 50 MHz is 20 ns
  // into the window where the PHY is entitled to be changing it.
  //
  // Sampling after the edge worked against a model that changed its output at
  // the same moment, and against nothing else; NetBSD's station reads a bit
  // time earlier than that and got every value shifted by one.
  wire sample  = (div_cnt == divisor) && !mdc;

  // ---- the frame ----------------------------------------------------------
  // Bit 63 goes out first: 32 ones, 01, the opcode, addresses, turnaround,
  // then the data.
  localparam int FRAME_BITS = 64;

  logic [63:0] shifter;
  logic [6:0]  bits_left;
  logic        active;
  // A request waits here for the next falling edge, so the first bit is
  // always presented before the rising edge that samples it.  Starting on
  // whatever edge came next would spend a bit time driving nothing and put
  // the whole frame out by one.
  logic        armed;

  wire [63:0] frame = {32'hffff_ffff, 2'b01, is_read ? 2'b10 : 2'b01,
                       phyad, regad, 2'b10, wdata};

  // Where in the frame the turnaround and data are.
  wire in_data = (bits_left <= 7'd16);
  wire in_ta   = (bits_left > 7'd16) && (bits_left <= 7'd18);

  assign busy = active || armed;

  always_ff @(posedge clk) begin
    if (rst) begin
      shifter   <= 64'h0;
      bits_left <= 7'h0;
      active    <= 1'b0;
      armed     <= 1'b0;
      mdio_o    <= 1'b1;
      mdio_oe   <= 1'b0;
      rdata     <= 16'h0;
      rvalid    <= 1'b0;
    end else begin
      if (start && !active && !armed) begin
        armed  <= 1'b1;
        rvalid <= 1'b0;
      end else if (armed && falling) begin
        // Present the first bit now; the rest follow one per falling edge.
        {mdio_o, shifter} <= {frame, 1'b0};
        bits_left <= 7'(FRAME_BITS);
        active    <= 1'b1;
        armed     <= 1'b0;
        mdio_oe   <= 1'b1;
      end else if (active) begin
        // The station changes MDIO on the falling edge so the PHY has it
        // settled by the rising edge, where everyone samples.
        if (falling) begin
          mdio_o  <= shifter[63];
          // On a read the station lets go for the turnaround and the data,
          // and the PHY drives instead.
          mdio_oe <= !(is_read && (in_ta || in_data));
          shifter <= {shifter[62:0], 1'b0};
        end
        if (sample && is_read && in_data) rdata <= {rdata[14:0], mdio_i};
        if (rising) begin
          if (bits_left == 7'd1) begin
            active  <= 1'b0;
            mdio_oe <= 1'b0;
            rvalid  <= is_read;
          end
          bits_left <= bits_left - 7'd1;
        end
      end else begin
        mdio_oe <= 1'b0;
        mdio_o  <= 1'b1;
      end
    end
  end

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, wbs_sel_i, wbs_dat_i[23:17], wbs_dat_i[31:25]};
  // verilator lint_on UNUSED

endmodule
