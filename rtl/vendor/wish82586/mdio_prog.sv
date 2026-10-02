// SPDX-License-Identifier: MIT
//
// PHY bring-up, as a Wishbone B4 classic master.
//
// The 82586 predates MDIO and none of the drivers in doc/drivers knows a PHY
// exists, so nothing in the software stack will ever configure one.  This
// block does it instead: after reset it walks a short sequence of writes to
// wb_mdio's registers, and raises ready_o when the PHY has been told what to
// do.  Nothing else in the design waits on it - the MAC will happily send into
// a PHY that has not negotiated yet - but a system integrator can.
//
// The target is the Realtek RTL8211EG.  Everything here is generic clause 22,
// which is the honest answer for that part: the only chip-specific setting in
// Linux's driver (doc/drivers/Linux/realtek_main.c, rtl8211e_config_init) is
// the RGMII transmit and receive delay on extension page 0xa4, and it returns
// without touching anything for interfaces that are not RGMII.  This design
// uses GMII, so there is nothing to set.  If an RGMII variant is ever wanted,
// that page is where it goes.
//
// Speed is asked for by advertising exactly that ability and letting
// auto-negotiation settle it.  Forcing the speed by writing it into BMCR
// works for 10 and 100 but is not allowed for 1000BASE-T, which requires
// negotiation to decide master and slave, so advertising one ability is the
// approach that is correct at every speed rather than two approaches.

module mdio_prog #(
    parameter int SPEED       = 1000,  // 10, 100 or 1000
    parameter bit FULL_DUPLEX = 1'b1,
    parameter int PHY_ADDR    = 1,
    // How long to wait between poking the reset and looking at it, in bus
    // clocks.  The standard gives a PHY 0.5 s to complete a reset; this only
    // has to be long enough that the first poll is not pointless, since the
    // poll then does the waiting.
    parameter int RESET_WAIT  = 1024,
    // How many times to ask whether the reset has finished before giving up
    // and carrying on anyway.  A PHY that is not there must not wedge this.
    parameter int RESET_POLLS = 64,
    // Register index of wb_mdio's registers within this master's address map.
    parameter logic [5:0] MDIO_CTRL   = 6'd0,
    parameter logic [5:0] MDIO_WDATA  = 6'd1,
    parameter logic [5:0] MDIO_RDATA  = 6'd2,
    parameter logic [5:0] MDIO_STATUS = 6'd3
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start_i,       // pulse to run the sequence again
    output logic        ready_o,       // the PHY has been programmed
    output logic        failed_o,      // it never came out of reset

    // ---- Wishbone B4 classic master ----------------------------------------
    output logic        wbm_cyc_o,
    output logic        wbm_stb_o,
    output logic        wbm_we_o,
    output logic [3:0]  wbm_sel_o,
    output logic [5:0]  wbm_adr_o,
    output logic [31:0] wbm_dat_o,
    input  logic [31:0] wbm_dat_i,
    input  logic        wbm_ack_i,
    input  logic        wbm_err_i
);

  // ---- clause 22, from doc/drivers/Linux/mii.h -----------------------------
  localparam logic [4:0]  MII_BMCR     = 5'd0;
  localparam logic [4:0]  MII_ADVERTISE = 5'd4;
  localparam logic [4:0]  MII_CTRL1000 = 5'd9;

  localparam logic [15:0] BMCR_RESET     = 16'h8000;
  localparam logic [15:0] BMCR_ANENABLE  = 16'h1000;
  localparam logic [15:0] BMCR_ANRESTART = 16'h0200;

  localparam logic [15:0] ADVERTISE_CSMA    = 16'h0001;
  localparam logic [15:0] ADVERTISE_10HALF  = 16'h0020;
  localparam logic [15:0] ADVERTISE_10FULL  = 16'h0040;
  localparam logic [15:0] ADVERTISE_100HALF = 16'h0080;
  localparam logic [15:0] ADVERTISE_100FULL = 16'h0100;
  localparam logic [15:0] ADVERTISE_1000HALF = 16'h0100;
  localparam logic [15:0] ADVERTISE_1000FULL = 16'h0200;

  initial begin
    if (SPEED != 10 && SPEED != 100 && SPEED != 1000)
      $fatal(1, "mdio_prog: SPEED must be 10, 100 or 1000");
  end

  // What to advertise: exactly the one ability that was asked for.
  localparam logic [15:0] ADV_VALUE =
      (SPEED == 10)  ? (ADVERTISE_CSMA |
                        (FULL_DUPLEX ? ADVERTISE_10FULL : ADVERTISE_10HALF)) :
      (SPEED == 100) ? (ADVERTISE_CSMA |
                        (FULL_DUPLEX ? ADVERTISE_100FULL : ADVERTISE_100HALF)) :
                       ADVERTISE_CSMA;

  localparam logic [15:0] GIG_VALUE =
      (SPEED == 1000) ? (FULL_DUPLEX ? ADVERTISE_1000FULL : ADVERTISE_1000HALF)
                      : 16'h0000;

  // The sequence, in order.  Each step writes one PHY register.
  localparam int NSTEPS = 4;

  function automatic logic [4:0] step_reg(input logic [1:0] i);
    case (i)
      2'd0: step_reg = MII_BMCR;        // reset the PHY first
      2'd1: step_reg = MII_ADVERTISE;
      2'd2: step_reg = MII_CTRL1000;
      default: step_reg = MII_BMCR;     // then negotiate on what we advertised
    endcase
  endfunction

  function automatic logic [15:0] step_val(input logic [1:0] i);
    case (i)
      2'd0: step_val = BMCR_RESET;
      2'd1: step_val = ADV_VALUE;
      2'd2: step_val = GIG_VALUE;
      default: step_val = BMCR_ANENABLE | BMCR_ANRESTART;
    endcase
  endfunction

  typedef enum logic [3:0] {
    P_IDLE,
    P_WR_DATA,      // put the value in wb_mdio's write data register
    P_WR_CTRL,      // ... and start the transfer
    P_WAIT_BUSY,    // wait for the serial frame to finish
    P_RESET_WAIT,   // give the PHY a moment after the reset
    P_RD_CTRL,      // start a read of BMCR
    P_RD_WAIT,
    P_RD_DATA,      // has the reset bit cleared?
    P_DONE
  } state_e;

  state_e      state;
  logic [1:0]  step;
  logic [31:0] delay;
  logic [7:0]  polls;
  logic        after_reset;   // this write was the reset, so poll for it

  // One outstanding bus access at a time; req is held until ack.
  logic        req;
  logic        we;
  logic [5:0]  adr;
  logic [31:0] dat;

  assign wbm_cyc_o = req;
  assign wbm_stb_o = req;
  assign wbm_we_o  = we;
  assign wbm_sel_o = 4'hf;
  assign wbm_adr_o = adr;
  assign wbm_dat_o = dat;

  wire done = wbm_ack_i || wbm_err_i;

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= P_WR_DATA;   // programming starts on its own after reset
      step        <= 2'd0;
      delay       <= 32'h0;
      polls       <= 8'h0;
      after_reset <= 1'b0;
      req         <= 1'b0;
      we          <= 1'b0;
      adr         <= 6'h0;
      dat         <= 32'h0;
      ready_o     <= 1'b0;
      failed_o    <= 1'b0;
    end else begin
      case (state)
        P_IDLE:
          if (start_i) begin
            step     <= 2'd0;
            polls    <= 8'h0;
            ready_o  <= 1'b0;
            failed_o <= 1'b0;
            state    <= P_WR_DATA;
          end

        P_WR_DATA: begin
          req   <= 1'b1;
          we    <= 1'b1;
          adr   <= MDIO_WDATA;
          dat   <= {16'h0, step_val(step)};
          if (req && done) begin
            req   <= 1'b0;
            state <= P_WR_CTRL;
          end
        end

        P_WR_CTRL: begin
          req <= 1'b1;
          we  <= 1'b1;
          adr <= MDIO_CTRL;
          // start, write, this PHY, this register
          dat <= {7'h0, 1'b1, 7'h0, 1'b0, 3'h0, 5'(PHY_ADDR), 3'h0,
                  step_reg(step)};
          if (req && done) begin
            req         <= 1'b0;
            after_reset <= (step == 2'd0);
            state       <= P_WAIT_BUSY;
          end
        end

        // Poll wb_mdio's status until the serial frame has gone out.
        P_WAIT_BUSY: begin
          req <= 1'b1;
          we  <= 1'b0;
          adr <= MDIO_STATUS;
          if (req && done) begin
            req <= 1'b0;
            if (!wbm_dat_i[0]) begin
              if (after_reset) begin
                delay <= 32'(RESET_WAIT);
                state <= P_RESET_WAIT;
              end else if (step == 2'(NSTEPS - 1)) begin
                state <= P_DONE;
              end else begin
                step  <= step + 2'd1;
                state <= P_WR_DATA;
              end
            end
          end
        end

        P_RESET_WAIT:
          if (delay != 32'h0) delay <= delay - 32'd1;
          else                state <= P_RD_CTRL;

        // Read BMCR back: the reset bit clears itself when the PHY is ready.
        P_RD_CTRL: begin
          req <= 1'b1;
          we  <= 1'b1;
          adr <= MDIO_CTRL;
          dat <= {7'h0, 1'b1, 7'h0, 1'b1, 3'h0, 5'(PHY_ADDR), 3'h0, MII_BMCR};
          if (req && done) begin
            req   <= 1'b0;
            state <= P_RD_WAIT;
          end
        end

        P_RD_WAIT: begin
          req <= 1'b1;
          we  <= 1'b0;
          adr <= MDIO_STATUS;
          if (req && done) begin
            req <= 1'b0;
            if (!wbm_dat_i[0]) state <= P_RD_DATA;
          end
        end

        P_RD_DATA: begin
          req <= 1'b1;
          we  <= 1'b0;
          adr <= MDIO_RDATA;
          if (req && done) begin
            req <= 1'b0;
            if (!wbm_dat_i[15]) begin
              // Out of reset: get on with the rest of the sequence.
              after_reset <= 1'b0;
              step        <= step + 2'd1;
              state       <= P_WR_DATA;
            end else if (polls == 8'(RESET_POLLS - 1)) begin
              // Something is wrong with the PHY, or there is not one there.
              // Say so and carry on: wedging here would be worse.
              failed_o    <= 1'b1;
              after_reset <= 1'b0;
              step        <= step + 2'd1;
              state       <= P_WR_DATA;
            end else begin
              polls <= polls + 8'd1;
              delay <= 32'(RESET_WAIT);
              state <= P_RESET_WAIT;
            end
          end
        end

        P_DONE: begin
          ready_o <= 1'b1;
          state   <= P_IDLE;
        end

        default: state <= P_IDLE;
      endcase
    end
  end

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, wbm_dat_i[31:16], wbm_dat_i[14:1], wbm_err_i};
  // verilator lint_on UNUSED

endmodule
