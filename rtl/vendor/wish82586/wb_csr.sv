// SPDX-License-Identifier: MIT
//
// Wishbone B4 classic slave holding the host-visible control registers.
//
// The real 82586 has no software-visible registers at all: the host only owns
// the RESET and CA pins and reads INT.  On a Wishbone SoC those pins have to
// come from somewhere, so they are exposed here together with the SCP address
// (fixed at 0xFFFFF6 on the real part, programmable here).
//
// Register map (byte offsets, 32-bit accesses):
// The bus is word addressed, so wbs_adr_i is a register index, not a byte
// offset.  The map below is written in byte offsets because that is how a
// driver sees it; the index is the offset divided by four.
//
//   0x00 CTRL     [0] RST (level, 1 = core held in reset, 1 after power-up)
//                 [1] CA  (write 1 to pulse channel attention, reads 0)
//                 [8] IRQ_EN
//   0x04 STATUS   [0] INT  [1] BUSY  [6:4] CUS  [10:8] RUS   (read only)
//   0x08 SCP_ADDR byte address of the System Configuration Pointer
//   0x10 ID       0x82586001 (read only)

module wb_csr (
    input  logic        clk,
    input  logic        rst,          // Wishbone RST_I: synchronous, active high

    // Wishbone B4 classic slave
    input  logic        wbs_cyc_i,
    input  logic        wbs_stb_i,
    input  logic        wbs_we_i,
    input  logic [3:0]  wbs_sel_i,
    input  logic [5:0]  wbs_adr_i,   // word address: register index
    input  logic [31:0] wbs_dat_i,
    output logic [31:0] wbs_dat_o,
    output logic        wbs_ack_o,
    output logic        wbs_err_o,

    // to/from the MAC core
    output logic        core_rst_o,   // level, core held in reset
    output logic        ca_o,         // single-cycle channel attention pulse
    output logic [31:0] scp_addr_o,
    input  logic [2:0]  cus_i,
    input  logic [2:0]  rus_i,
    input  logic        busy_i,
    input  logic        int_i,        // level interrupt request from the core

    output logic        irq_o
);

  logic        rst_q;
  logic        irq_en_q;
  logic [31:0] scp_addr_q;

  wire acc    = wbs_cyc_i && wbs_stb_i && !wbs_ack_o;
  wire wr     = acc && wbs_we_i;
  wire byte0  = wbs_sel_i[0];
  wire byte1  = wbs_sel_i[1];

  always_ff @(posedge clk) begin
    if (rst) begin
      rst_q      <= 1'b1;             // core held in reset until the host says otherwise
      irq_en_q   <= 1'b0;
      scp_addr_q <= wish82586_pkg::SCP_ADDR_RESET;
      ca_o       <= 1'b0;
    end else begin
      ca_o <= 1'b0;
      if (wr) begin
        case (wbs_adr_i)
          wish82586_pkg::CSR_CTRL[7:2]: begin
            if (byte0) begin
              rst_q <= wbs_dat_i[wish82586_pkg::CTRL_RST_BIT];
              ca_o  <= wbs_dat_i[wish82586_pkg::CTRL_CA_BIT];
            end
            if (byte1) irq_en_q <= wbs_dat_i[wish82586_pkg::CTRL_IRQ_EN_BIT];
          end
          wish82586_pkg::CSR_SCP_ADDR[7:2]: begin
            if (wbs_sel_i[0]) scp_addr_q[7:0]   <= wbs_dat_i[7:0];
            if (wbs_sel_i[1]) scp_addr_q[15:8]  <= wbs_dat_i[15:8];
            if (wbs_sel_i[2]) scp_addr_q[23:16] <= wbs_dat_i[23:16];
            if (wbs_sel_i[3]) scp_addr_q[31:24] <= wbs_dat_i[31:24];
          end
          default: ;                  // unmapped writes are dropped
        endcase
      end
    end
  end

  always_comb begin
    wbs_dat_o = 32'h0;
    case (wbs_adr_i)
      wish82586_pkg::CSR_CTRL[7:2]: begin
        wbs_dat_o[wish82586_pkg::CTRL_RST_BIT]    = rst_q;
        wbs_dat_o[wish82586_pkg::CTRL_IRQ_EN_BIT] = irq_en_q;
      end
      wish82586_pkg::CSR_STATUS[7:2]: begin
        wbs_dat_o[wish82586_pkg::STAT_INT_BIT]        = int_i;
        wbs_dat_o[wish82586_pkg::STAT_BUSY_BIT]       = busy_i;
        wbs_dat_o[wish82586_pkg::STAT_CUS_LSB +: 3]   = cus_i;
        wbs_dat_o[wish82586_pkg::STAT_RUS_LSB +: 3]   = rus_i;
      end
      wish82586_pkg::CSR_SCP_ADDR[7:2]: wbs_dat_o = scp_addr_q;
      wish82586_pkg::CSR_ID[7:2]:       wbs_dat_o = wish82586_pkg::CSR_ID_VALUE;
      default: ;                      // unmapped reads return zero
    endcase
  end

  // Single wait state free: acknowledge the cycle after it is presented.
  always_ff @(posedge clk) begin
    if (rst) wbs_ack_o <= 1'b0;
    else     wbs_ack_o <= acc;
  end

  assign wbs_err_o  = 1'b0;
  assign core_rst_o = rst_q;
  assign scp_addr_o = scp_addr_q;
  assign irq_o      = irq_en_q && int_i;

endmodule
