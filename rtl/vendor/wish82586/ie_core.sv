// SPDX-License-Identifier: MIT
//
// Initialisation sequencer and System Control Block handler.
//
// This is the part of the chip that talks to the host through shared memory.
// After reset the first channel attention makes it walk the pointer chain the
// driver set up:
//
//   SCP  (at the address in CSR SCP_ADDR)  -> bus width, address of the ISCP
//   ISCP                                    -> SCB offset, control block base
//
// It then clears the ISCP busy flag, reports CX and CNA in the SCB status and
// raises the interrupt, which is what the drivers in doc/drivers wait for.
//
// Every later channel attention means "look at the SCB command word": the
// acknowledge bits are applied to the status, the command unit control field
// is passed on to ie_cu, the command word is cleared and the updated status is
// written back.  The receive unit control field is decoded but has nowhere to
// go yet.
//
// The status is also written back on its own whenever the command unit reports
// something, so what the host reads from memory is always current.  The
// interrupt follows the *published* flags, never the internal ones, so a
// driver woken by it always finds the status already in memory.

module ie_core (
    input  logic        clk,
    input  logic        rst,          // bus reset
    input  logic        core_rst_i,   // CSR CTRL.RST, holds the core in reset
    input  logic        ca_i,         // channel attention, one cycle
    input  logic [31:0] scp_addr_i,

    output logic [2:0]  cus_o,
    output logic [2:0]  rus_o,
    output logic        busy_o,
    output logic        int_o,

    // ---- command unit ------------------------------------------------------
    output logic [23:0] cbbase_o,
    output logic        cu_start_o,
    output logic [15:0] cu_cbl_o,
    output logic        cu_resume_o,
    output logic        cu_suspend_o,
    output logic        cu_abort_o,
    input  logic [2:0]  cus_i,
    input  logic        ev_cx_i,
    input  logic        ev_cna_i,

    // ---- receive unit ------------------------------------------------------
    output logic [23:0] scb_addr_o,
    output logic        ru_start_o,
    output logic [15:0] ru_rfa_o,
    output logic        ru_resume_o,
    output logic        ru_suspend_o,
    output logic        ru_abort_o,
    input  logic [2:0]  rus_i,
    input  logic        ev_fr_i,
    input  logic        ev_rnr_i,

    // ---- memory port (see wb_master) --------------------------------------
    output logic        bus_req_o,
    output logic        bus_we_o,
    output logic [1:0]  bus_size_o,
    output logic [3:0]  bus_sel_o,
    output logic [23:0] bus_addr_o,
    output logic [31:0] bus_wdata_o,
    input  logic        bus_ack_i,
    input  logic [31:0] bus_rdata_i,
    input  logic        bus_err_i
);

  // Read data comes back a full word wide; these blocks all want the
  // 16-bit field that was addressed.
  wire [15:0] rdata = bus_rdata_i[15:0];

  // ---- shared memory layout, byte offsets ---------------------------------
  localparam logic [23:0] SCP_ISCP_LO = 24'd6;   // 24-bit ISCP address
  localparam logic [23:0] SCP_ISCP_HI = 24'd8;
  localparam logic [23:0] ISCP_BUSY   = 24'd0;
  localparam logic [23:0] ISCP_SCB    = 24'd2;
  localparam logic [23:0] ISCP_CB_LO  = 24'd4;   // 24-bit control block base
  localparam logic [23:0] ISCP_CB_HI  = 24'd6;
  localparam logic [23:0] SCB_STATUS  = 24'd0;
  localparam logic [23:0] SCB_CMD     = 24'd2;
  localparam logic [23:0] SCB_CBL     = 24'd4;
  localparam logic [23:0] SCB_RFA     = 24'd6;

  // Software reset lives in the SCB command word; see doc/interface.md.
  localparam int SCB_CMD_RESET_BIT = wish82586_pkg::SCB_CMD_RESET;

  typedef enum logic [3:0] {
    S_UNINIT,        // out of reset, waiting for the first channel attention
    S_SCP_SYSBUS,
    S_SCP_ISCP_LO,
    S_SCP_ISCP_HI,
    S_ISCP_SCB,
    S_ISCP_CB_LO,
    S_ISCP_CB_HI,
    S_ISCP_CLR_BUSY,
    S_IDLE,          // initialised, waiting for something to do
    S_SCB_RD_CMD,
    S_SCB_RD_CBL,
    S_SCB_RD_RFA,
    S_SCB_WR_STATUS, // after a command word was taken
    S_SCB_CLR_CMD,
    S_WR_STATUS      // status changed on its own, publish it
  } state_e;

  state_e      state;
  logic [23:0] iscp_addr;
  logic [15:0] scb_off;
  logic [15:0] scb_cmd;
  logic [15:0] status_tx;   // the status word being written back
  logic [3:0]  flags;       // {CX, FR, CNA, RNR} as the chip knows them
  logic        bus16;       // SCP bus width byte, 0 => 16-bit host bus
  logic        ca_pending;
  logic [15:0] status_pub;   // the status word the host can currently see

  wire [23:0] scb_addr = cbbase_o + {8'h00, scb_off};
  wire [2:0]  cuc      = rdata[10:8];   // valid while the command is read
  wire [2:0]  ruc      = rdata[6:4];

  // Status word as the host will read it, for a given set of flags.
  // {CX, FR, CNA, RNR} at [15:12], CUS at [10:8], RUS at [6:4].
  function automatic logic [15:0] mk_status(input logic [3:0] f);
    mk_status = {f, 1'b0, cus_i, 1'b0, rus_o, 4'b0000};
  endfunction

  // ---- flags ---------------------------------------------------------------
  // Events set, acknowledgements clear, and setting wins: an event that lands
  // in the same cycle as its acknowledgement must not be lost.
  wire       taking_cmd = (state == S_SCB_RD_CMD) && bus_ack_i;
  wire       init_done  = (state == S_ISCP_CLR_BUSY) && bus_ack_i;
  wire       ack_apply  = taking_cmd && !rdata[SCB_CMD_RESET_BIT];
  wire [3:0] ack_mask   = rdata[15:12];

  logic [3:0] flags_next;
  always_comb begin
    flags_next = flags;
    if (ack_apply) flags_next = flags_next & ~ack_mask;
    if (init_done) flags_next = flags_next | 4'b1010;   // CX, CNA
    if (ev_cx_i)   flags_next[3] = 1'b1;
    if (ev_fr_i)   flags_next[2] = 1'b1;
    if (ev_cna_i)  flags_next[1] = 1'b1;
    if (ev_rnr_i)  flags_next[0] = 1'b1;
  end

  wire status_written = bus_ack_i && ((state == S_SCB_WR_STATUS) ||
                                      (state == S_WR_STATUS));

  // What the chip knows, versus what it has actually put in memory.  Comparing
  // the two is what decides whether a status write is owed: a flag would be
  // cleared by a write that carried a value latched before the units reacted,
  // and the change would be lost.
  wire [15:0] status_now   = mk_status(flags);
  wire        status_stale = (status_pub != status_now);

  always_ff @(posedge clk) begin
    if (rst || core_rst_i) begin
      flags      <= 4'h0;
      status_pub <= 16'h0;
    end else begin
      flags <= (taking_cmd && rdata[SCB_CMD_RESET_BIT]) ? 4'h0 : flags_next;
      if (status_written) status_pub <= status_tx;
    end
  end

  // ---- request presented to the memory port -------------------------------
  always_comb begin
    bus_req_o   = 1'b0;
    bus_we_o    = 1'b0;
    bus_size_o  = wish82586_pkg::BUS_SZ_HALF;
    bus_sel_o   = 4'h0;
    bus_addr_o  = 24'h0;
    bus_wdata_o = 32'h0;
    case (state)
      S_SCP_SYSBUS: begin
        bus_req_o  = 1'b1;
        bus_size_o = wish82586_pkg::BUS_SZ_BYTE;
        bus_addr_o = scp_addr_i[23:0];
      end
      S_SCP_ISCP_LO: begin
        bus_req_o  = 1'b1;
        bus_addr_o = scp_addr_i[23:0] + SCP_ISCP_LO;
      end
      S_SCP_ISCP_HI: begin
        bus_req_o  = 1'b1;
        bus_addr_o = scp_addr_i[23:0] + SCP_ISCP_HI;
      end
      S_ISCP_SCB: begin
        bus_req_o  = 1'b1;
        bus_addr_o = iscp_addr + ISCP_SCB;
      end
      S_ISCP_CB_LO: begin
        bus_req_o  = 1'b1;
        bus_addr_o = iscp_addr + ISCP_CB_LO;
      end
      S_ISCP_CB_HI: begin
        bus_req_o  = 1'b1;
        bus_addr_o = iscp_addr + ISCP_CB_HI;
      end
      S_ISCP_CLR_BUSY: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_size_o  = wish82586_pkg::BUS_SZ_BYTE;
        bus_addr_o  = iscp_addr + ISCP_BUSY;
        bus_wdata_o = 32'h0;
      end
      S_SCB_RD_CMD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = scb_addr + SCB_CMD;
      end
      S_SCB_RD_CBL: begin
        bus_req_o  = 1'b1;
        bus_addr_o = scb_addr + SCB_CBL;
      end
      S_SCB_RD_RFA: begin
        bus_req_o  = 1'b1;
        bus_addr_o = scb_addr + SCB_RFA;
      end
      S_SCB_CLR_CMD: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = scb_addr + SCB_CMD;
        bus_wdata_o = 32'h0;
      end
      S_SCB_WR_STATUS, S_WR_STATUS: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = scb_addr + SCB_STATUS;
        bus_wdata_o = {16'h0, status_tx};
      end
      default: ;
    endcase
  end

  // ---- sequencer ----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst || core_rst_i) begin
      state        <= S_UNINIT;
      iscp_addr    <= 24'h0;
      cbbase_o     <= 24'h0;
      scb_off      <= 16'h0;
      scb_cmd      <= 16'h0;
      status_tx    <= 16'h0;
      bus16        <= 1'b1;
      ca_pending   <= 1'b0;
      cu_start_o   <= 1'b0;
      cu_cbl_o     <= 16'h0;
      cu_resume_o  <= 1'b0;
      cu_suspend_o <= 1'b0;
      cu_abort_o   <= 1'b0;
      ru_start_o   <= 1'b0;
      ru_rfa_o     <= 16'h0;
      ru_resume_o  <= 1'b0;
      ru_suspend_o <= 1'b0;
      ru_abort_o   <= 1'b0;
    end else begin
      cu_start_o   <= 1'b0;
      cu_resume_o  <= 1'b0;
      cu_suspend_o <= 1'b0;
      cu_abort_o   <= 1'b0;
      ru_start_o   <= 1'b0;
      ru_resume_o  <= 1'b0;
      ru_suspend_o <= 1'b0;
      ru_abort_o   <= 1'b0;

      if (ca_i) ca_pending <= 1'b1;

      case (state)
        S_UNINIT:
          if (ca_pending) begin
            ca_pending <= 1'b0;
            state      <= S_SCP_SYSBUS;
          end

        S_SCP_SYSBUS:
          if (bus_ack_i) begin
            bus16 <= ~rdata[0];   // 0 => 16-bit bus, 1 => 8-bit bus
            state <= S_SCP_ISCP_LO;
          end

        S_SCP_ISCP_LO:
          if (bus_ack_i) begin
            iscp_addr[15:0] <= rdata;
            state           <= S_SCP_ISCP_HI;
          end

        S_SCP_ISCP_HI:
          if (bus_ack_i) begin
            iscp_addr[23:16] <= rdata[7:0];
            state            <= S_ISCP_SCB;
          end

        S_ISCP_SCB:
          if (bus_ack_i) begin
            scb_off <= rdata;
            state   <= S_ISCP_CB_LO;
          end

        S_ISCP_CB_LO:
          if (bus_ack_i) begin
            cbbase_o[15:0] <= rdata;
            state          <= S_ISCP_CB_HI;
          end

        S_ISCP_CB_HI:
          if (bus_ack_i) begin
            cbbase_o[23:16] <= rdata[7:0];
            state           <= S_ISCP_CLR_BUSY;
          end

        S_ISCP_CLR_BUSY:
          if (bus_ack_i) begin
            // Initialisation done: report command executed and command unit
            // not active, which is what the drivers poll for.
            status_tx <= mk_status(flags_next);
            state     <= S_WR_STATUS;
          end

        S_IDLE:
          if (ca_pending) begin
            ca_pending <= 1'b0;
            state      <= S_SCB_RD_CMD;
          end else if (status_stale) begin
            status_tx <= status_now;
            state     <= S_WR_STATUS;
          end

        S_SCB_RD_CMD:
          if (bus_ack_i) begin
            scb_cmd   <= rdata;
            status_tx <= mk_status(flags_next);
            if (rdata[SCB_CMD_RESET_BIT]) begin
              // Software reset: behave as if RESET had been pulled.  Clear the
              // command word first so the host sees the command taken.
              state <= S_SCB_CLR_CMD;
            end else begin
              // The control fields decide what the two units do next.  A
              // start needs its list pointer fetching first.
              case (cuc)
                wish82586_pkg::CUC_RESUME:  cu_resume_o  <= 1'b1;
                wish82586_pkg::CUC_SUSPEND: cu_suspend_o <= 1'b1;
                wish82586_pkg::CUC_ABORT:   cu_abort_o   <= 1'b1;
                default: ;
              endcase
              case (ruc)
                wish82586_pkg::RUC_RESUME:  ru_resume_o  <= 1'b1;
                wish82586_pkg::RUC_SUSPEND: ru_suspend_o <= 1'b1;
                wish82586_pkg::RUC_ABORT:   ru_abort_o   <= 1'b1;
                default: ;
              endcase
              if (cuc == wish82586_pkg::CUC_START)      state <= S_SCB_RD_CBL;
              else if (ruc == wish82586_pkg::RUC_START) state <= S_SCB_RD_RFA;
              else                                     state <= S_SCB_WR_STATUS;
            end
          end

        S_SCB_RD_CBL:
          if (bus_ack_i) begin
            cu_cbl_o   <= rdata;
            cu_start_o <= 1'b1;
            state      <= (scb_cmd[6:4] == wish82586_pkg::RUC_START) ?
                          S_SCB_RD_RFA : S_SCB_WR_STATUS;
          end

        S_SCB_RD_RFA:
          if (bus_ack_i) begin
            ru_rfa_o   <= rdata;
            ru_start_o <= 1'b1;
            state      <= S_SCB_WR_STATUS;
          end

        // The status is written back before the command word is cleared, so a
        // driver that polls the command word and then reads the status never
        // sees stale bits.
        S_SCB_WR_STATUS:
          if (bus_ack_i) state <= S_SCB_CLR_CMD;

        S_SCB_CLR_CMD:
          if (bus_ack_i) state <= scb_cmd[SCB_CMD_RESET_BIT] ? S_UNINIT : S_IDLE;

        S_WR_STATUS:
          if (bus_ack_i) state <= S_IDLE;

        default: state <= S_UNINIT;
      endcase
    end
  end

  assign rus_o      = rus_i;
  assign cus_o      = cus_i;
  assign scb_addr_o = scb_addr;
  assign busy_o = (state != S_IDLE) && (state != S_UNINIT);
  assign int_o  = |status_pub[15:12];

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, bus_rdata_i[31:16], bus_err_i, bus16, scb_cmd[14:0], scp_addr_i[31:24]};
  // verilator lint_on UNUSED

endmodule
