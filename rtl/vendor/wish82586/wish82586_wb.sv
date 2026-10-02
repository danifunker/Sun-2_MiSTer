// SPDX-License-Identifier: MIT
//
// Wish82586 with this project's own control registers on it.
//
// The MAC core has the 82586's three host signals as pins and nothing else,
// because that is all the real part has and because every machine that used
// one wrapped them differently - doc/sun2_ethernet.pdf is the Sun-2's byte,
// with RESET and LOOPB active low, CA at bit 5 and a bus error bit.  Recreating
// such a machine means writing that register block and instantiating the core
// beside it.
//
// This is the same thing for the convention doc/interface.md defines: wb_csr
// on a Wishbone slave port, and the core behind it.  It is the default wiring,
// and what the testbench and the co-simulation drive.

module wish82586_wb #(
    parameter int PHY_DATA_W = 4,    // 4 = MII, 8 = GMII
    parameter int WB_DATA_W = 32,
    parameter int WB_ADDR_W = 30,
    parameter int DEFER_LIMIT = 1 << 16   // see wish82586
) (
    input  logic                   clk,
    input  logic                   rst,

    // ---- Wishbone B4 classic slave: control registers ---------------------
    input  logic                   wbs_cyc_i,
    input  logic                   wbs_stb_i,
    input  logic                   wbs_we_i,
    input  logic [3:0]             wbs_sel_i,
    input  logic [5:0]             wbs_adr_i,   // word address
    input  logic [31:0]            wbs_dat_i,
    output logic [31:0]            wbs_dat_o,
    output logic                   wbs_ack_o,
    output logic                   wbs_err_o,

    // ---- Wishbone B4 classic master: shared memory ------------------------
    output logic                   wbm_cyc_o,
    output logic                   wbm_stb_o,
    output logic                   wbm_we_o,
    output logic [WB_DATA_W/8-1:0] wbm_sel_o,
    output logic [WB_ADDR_W-1:0]   wbm_adr_o,   // word address
    output logic [WB_DATA_W-1:0]   wbm_dat_o,
    input  logic [WB_DATA_W-1:0]   wbm_dat_i,
    input  logic                   wbm_ack_i,
    input  logic                   wbm_err_i,

    output logic                   irq_o,

    // ---- MII --------------------------------------------------------------
    input  logic                   mii_tx_clk,
    output logic [PHY_DATA_W-1:0]  mii_txd,
    output logic                   mii_tx_en,
    output logic                   mii_tx_er,
    input  logic                   mii_rx_clk,
    input  logic [PHY_DATA_W-1:0]  mii_rxd,
    input  logic                   mii_rx_dv,
    input  logic                   mii_rx_er,
    input  logic                   mii_crs,
    input  logic                   mii_col
);

  logic        core_rst;
  logic        ca;
  logic [31:0] scp_addr;
  logic [2:0]  cus;
  logic [2:0]  rus;
  logic        busy;
  logic        core_int;
  logic        bus_err;

  wb_csr u_csr (
      .clk        (clk),
      .rst        (rst),
      .wbs_cyc_i  (wbs_cyc_i),
      .wbs_stb_i  (wbs_stb_i),
      .wbs_we_i   (wbs_we_i),
      .wbs_sel_i  (wbs_sel_i),
      .wbs_adr_i  (wbs_adr_i),
      .wbs_dat_i  (wbs_dat_i),
      .wbs_dat_o  (wbs_dat_o),
      .wbs_ack_o  (wbs_ack_o),
      .wbs_err_o  (wbs_err_o),
      .core_rst_o (core_rst),
      .ca_o       (ca),
      .scp_addr_o (scp_addr),
      .cus_i      (cus),
      .rus_i      (rus),
      .busy_i     (busy),
      .int_i      (core_int),
      .irq_o      (irq_o)
  );

  wish82586 #(
      .PHY_DATA_W  (PHY_DATA_W),
      .WB_DATA_W   (WB_DATA_W),
      .WB_ADDR_W   (WB_ADDR_W),
      .DEFER_LIMIT (DEFER_LIMIT)
  ) u_mac (
      .clk        (clk),
      .rst        (rst),
      .core_rst_i (core_rst),
      .ca_i       (ca),
      .scp_addr_i (scp_addr),
      .cus_o      (cus),
      .rus_o      (rus),
      .busy_o     (busy),
      .int_o      (core_int),
      .bus_err_o  (bus_err),
      .wbm_cyc_o  (wbm_cyc_o),
      .wbm_stb_o  (wbm_stb_o),
      .wbm_we_o   (wbm_we_o),
      .wbm_sel_o  (wbm_sel_o),
      .wbm_adr_o  (wbm_adr_o),
      .wbm_dat_o  (wbm_dat_o),
      .wbm_dat_i  (wbm_dat_i),
      .wbm_ack_i  (wbm_ack_i),
      .wbm_err_i  (wbm_err_i),
      .mii_tx_clk (mii_tx_clk),
      .mii_txd    (mii_txd),
      .mii_tx_en  (mii_tx_en),
      .mii_tx_er  (mii_tx_er),
      .mii_rx_clk (mii_rx_clk),
      .mii_rxd    (mii_rxd),
      .mii_rx_dv  (mii_rx_dv),
      .mii_rx_er  (mii_rx_er),
      .mii_crs    (mii_crs),
      .mii_col    (mii_col)
  );

  // wb_csr has nowhere to report a bus error; the Wishbone convention here
  // leaves that to the master's own ERR line.
  /* verilator lint_off UNUSED */
  wire _unused = &{1'b0, bus_err};
  /* verilator lint_on UNUSED */

endmodule
