// SPDX-License-Identifier: MIT
//
// Wish82586 - Intel 82586 software-compatible Ethernet MAC.
//
//   host side : RESET, CA and INT, plus the SCP address, as pins
//               Wishbone B4 classic master (DMA into the shared host memory)
//   PHY side  : MII or GMII
//
// The real 82586 has no software-visible registers at all, only those three
// pins, and every machine that used one wrapped them in a control register of
// its own devising - see doc/sun2_ethernet.pdf for what the Sun-2 did, which
// agrees with wb_csr about nothing except that the three signals exist.  So
// they are pins here too, and the register block that drives them is a
// separate module: wb_csr for the Wishbone convention this project defines,
// something else for a machine being recreated.  wish82586_wb is the two of
// them wired together, which is what a system wanting the default gets.
//
// PHY management is not here: the 82586 predates MDIO and no driver expects
// it, so wb_mdio and mdio_prog do that job beside the MAC rather than inside
// it.  See doc/interface.md.
//
// What is left is the diagnostic commands; everything else - initialisation,
// the SCB, both units and both directions of the datapath - works.  The
// contract the testbench in tb/ drives is in doc/interface.md.

module wish82586 #(
    // 4 selects MII, 8 selects GMII.  With GMII the transmit clock is sourced
    // by the MAC side: feed mii_tx_clk from the fabric's 125 MHz and take
    // GTX_CLK from the same place.
    parameter int PHY_DATA_W = 4,
    parameter int WB_DATA_W = 32,   // fixed at 32, see doc/interface.md
    parameter int WB_ADDR_W = 30,  // word address lines, see doc/interface.md
    // How long transmit will defer to a carrier that never goes away, in
    // symbol times.  Zero restores the real part's behaviour, which is to
    // defer for ever; see mii_tx for why the default is not that.
    parameter int DEFER_LIMIT = 1 << 16
) (
    input  logic                   clk,
    input  logic                   rst,          // Wishbone RST_I: synchronous, active high

    // ---- host control, as the chip's own pins -----------------------------
    input  logic                   core_rst_i,  // level: holds the core in reset
    input  logic                   ca_i,        // channel attention, one cycle
    input  logic [31:0]            scp_addr_i,  // hard-wired to 0xFFFFF6 on the part
    output logic [2:0]             cus_o,       // command unit status
    output logic [2:0]             rus_o,       // receive unit status
    output logic                   busy_o,
    output logic                   int_o,       // level interrupt request
    // One cycle per shared-memory access the bus answered with ERR.  The
    // Sun-2's control register has a bit for exactly this.
    output logic                   bus_err_o,

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

  // ---------------------------------------------------------------------------
  // Initialisation sequencer and SCB handler, and the memory port it drives.
  //
  // wb_arb shares that one port between the SCB handler, the receive unit and
  // the command unit, in that priority order: the receive unit comes before
  // the command unit because it cannot ask the wire to wait.
  // ---------------------------------------------------------------------------
  // Memory port, shared by all three.
  logic        bus_req, bus_we, bus_ack, bus_err;
  logic [1:0]  bus_size;
  logic [3:0]  bus_sel;
  logic [23:0] bus_addr;
  logic [31:0] bus_wdata, bus_rdata, bus_rdata_raw;

  logic        scb_req, scb_we, scb_ack, scb_err;
  logic [1:0]  scb_size;
  logic [3:0]  scb_sel;
  logic [23:0] scb_addr;
  logic [31:0] scb_wdata;

  logic        cu_req, cu_we, cu_ack, cu_err;
  logic [1:0]  cu_size;
  logic [3:0]  cu_sel;
  logic [23:0] cu_addr;
  logic [31:0] cu_wdata;

  logic        ru_req, ru_we, ru_ack, ru_err;
  logic [1:0]  ru_size;
  logic [3:0]  ru_sel;
  logic [23:0] ru_addr;
  logic [31:0] ru_wdata;

  // Receive unit control and the receive FIFO between the two clock domains.
  logic [23:0] scb_base;      // absolute address of the SCB
  logic        ru_start, ru_resume, ru_suspend, ru_abort;
  logic [15:0] ru_rfa;
  logic [2:0]  ru_rus;
  logic        ev_fr, ev_rnr;
  logic        rxf_wr, rxf_full, rxf_rd, rxf_empty;
  logic [11:0] rxf_wdata, rxf_rdata;
  logic        rx_active;     // observation only
  logic [15:0] rx_bytes;

  // Command unit control and the parameters it captures.
  logic [23:0] cbbase;
  logic        cu_start, cu_resume, cu_suspend, cu_abort;
  logic [15:0] cu_cbl;
  logic [2:0]  cu_cus;
  logic        ev_cx, ev_cna;
  logic [47:0] ia_addr;
  logic [95:0] cfg_bytes;

  // Transmit staging and the transmitter handshake.
  logic        tx_ram_we;
  logic [10:0] tx_ram_waddr, tx_ram_raddr;
  logic [7:0]  tx_ram_wdata, tx_ram_rdata;
  logic        tx_go, tx_done, tx_ok, tx_xcoll, tx_defer, tx_no_crs;
  logic [3:0]  tx_ncoll;
  logic [15:0] tx_len;

  // CONFIGURE parameters the transmitter needs, by byte offset in the block.
  wire [7:0]  cfg_ifs      = cfg_bytes[47:40];
  wire [10:0] cfg_slot     = {cfg_bytes[58:56], cfg_bytes[55:48]};
  wire [3:0]  cfg_retry    = cfg_bytes[63:60];
  wire        cfg_no_crc   = cfg_bytes[68];
  wire [7:0]  cfg_min_len  = cfg_bytes[87:80];
  wire        cfg_int_lb   = cfg_bytes[30];   // CONFIGURE byte 3, bit 6

  // Internal loopback: the transmit side hands frames straight to the receive
  // unit through this FIFO instead of putting them on the wire.
  logic        mc_clear, mc_wr, mc_all;
  logic [47:0] mc_addr;
  logic        lb_wr, lb_full, lb_rd, lb_empty;
  logic [11:0] lb_wdata, lb_rdata;
  logic [6:0]  lb_level;   // observation only

  // ---- reset, per clock domain --------------------------------------------
  // rst arrives synchronous to clk, and the PHY clocks are unrelated to it.
  // Feeding it straight into mii_rx, mii_tx and the receive FIFO's write side
  // -- which is what this used to do -- has two consequences on real silicon.
  //
  // A reset shorter than one PHY clock period is missed entirely by those
  // domains while everything on clk resets: at 10 Mb/s an mii_rx_clk period is
  // 400 ns, and a reset released synchronously to a 12.5 MHz clk can easily be
  // shorter than that.  The receive FIFO then keeps its write pointer while its
  // read pointer is zeroed, so it is neither empty nor coherent, and the first
  // thing the receive unit does afterwards is file a frame of noise into the
  // host's descriptor ring.  And each of the forty-odd registers in those
  // domains samples the reset independently, so an asynchronous edge can leave
  // some in reset and some not.
  //
  // core_rst_i -- the Sun-2's RESET* bit, which its driver asserts on every
  // ieinit -- did not reach those domains at all.  Resetting the chip during a
  // frame therefore left the half-received tail in the FIFO for the next frame
  // to inherit, and left mii_tx driving tx_en at a PHY that had been told the
  // chip was in reset.
  //
  // Async assert, synchronous release, one per PHY clock, so each domain sees a
  // reset at least three of its own cycles long however short the request was.
  //
  // The linter sees one net used as an asynchronous reset here and as an
  // ordinary synchronous one in the clk domain below, and says so.  That is
  // the arrangement on purpose: core_rst is generated on clk, so in that
  // domain it is synchronous by construction, and it is only asynchronous
  // where it crosses into a PHY clock - which is what these two synchronisers
  // are for.
  // verilator lint_off SYNCASYNCNET
  wire core_rst = rst | core_rst_i;
  // verilator lint_on SYNCASYNCNET

  (* ASYNC_REG = "TRUE" *) logic [2:0] rx_rst_q;
  always_ff @(posedge mii_rx_clk or posedge core_rst)
    if (core_rst) rx_rst_q <= 3'b111;
    else          rx_rst_q <= {rx_rst_q[1:0], 1'b0};
  wire rx_rst = rx_rst_q[2];

  (* ASYNC_REG = "TRUE" *) logic [2:0] tx_rst_q;
  always_ff @(posedge mii_tx_clk or posedge core_rst)
    if (core_rst) tx_rst_q <= 3'b111;
    else          tx_rst_q <= {tx_rst_q[1:0], 1'b0};
  wire tx_rst = tx_rst_q[2];

  ie_core u_core (
      .clk          (clk),
      .rst          (rst),
      .core_rst_i   (core_rst_i),
      .ca_i         (ca_i),
      .scp_addr_i   (scp_addr_i),
      .cus_o        (cus_o),
      .rus_o        (rus_o),
      .busy_o       (busy_o),
      .int_o        (int_o),
      .cbbase_o     (cbbase),
      .cu_start_o   (cu_start),
      .cu_cbl_o     (cu_cbl),
      .cu_resume_o  (cu_resume),
      .cu_suspend_o (cu_suspend),
      .cu_abort_o   (cu_abort),
      .cus_i        (cu_cus),
      .ev_cx_i      (ev_cx),
      .ev_cna_i     (ev_cna),
      .scb_addr_o   (scb_base),
      .ru_start_o   (ru_start),
      .ru_rfa_o     (ru_rfa),
      .ru_resume_o  (ru_resume),
      .ru_suspend_o (ru_suspend),
      .ru_abort_o   (ru_abort),
      .rus_i        (ru_rus),
      .ev_fr_i      (ev_fr),
      .ev_rnr_i     (ev_rnr),
      .bus_req_o    (scb_req),
      .bus_we_o     (scb_we),
      .bus_size_o   (scb_size),
      .bus_sel_o    (scb_sel),
      .bus_addr_o   (scb_addr),
      .bus_wdata_o  (scb_wdata),
      .bus_ack_i    (scb_ack),
      .bus_rdata_i  (bus_rdata),
      .bus_err_i    (scb_err)
  );

  ie_cu u_cu (
      .clk          (clk),
      .rst          (rst),
      .core_rst_i   (core_rst_i),
      .cbbase_i     (cbbase),
      .start_i      (cu_start),
      .start_cbl_i  (cu_cbl),
      .resume_i     (cu_resume),
      .suspend_i    (cu_suspend),
      .abort_i      (cu_abort),
      .cus_o        (cu_cus),
      .ev_cx_o      (ev_cx),
      .ev_cna_o     (ev_cna),
      .ia_addr_o     (ia_addr),
      .cfg_bytes_o   (cfg_bytes),
      .tx_ram_we_o   (tx_ram_we),
      .tx_ram_addr_o (tx_ram_waddr),
      .tx_ram_data_o (tx_ram_wdata),
      .tx_go_o       (tx_go),
      .tx_len_o      (tx_len),
      .tx_done_i     (tx_done),
      .tx_ok_i       (tx_ok),
      .tx_ncoll_i    (tx_ncoll),
      .tx_xcoll_i    (tx_xcoll),
      .tx_defer_i    (tx_defer),
      .tx_no_crs_i   (tx_no_crs),
      .lb_enable_i   (cfg_int_lb),
      .lb_wr_o       (lb_wr),
      .lb_data_o     (lb_wdata),
      .lb_full_i     (lb_full),
      .mc_clear_o    (mc_clear),
      .mc_wr_o       (mc_wr),
      .mc_addr_o     (mc_addr),
      .mc_all_o      (mc_all),
      .bus_req_o    (cu_req),
      .bus_we_o     (cu_we),
      .bus_size_o   (cu_size),
      .bus_sel_o    (cu_sel),
      .bus_addr_o   (cu_addr),
      .bus_wdata_o  (cu_wdata),
      .bus_ack_i    (cu_ack),
      .bus_rdata_i  (bus_rdata),
      .bus_err_i    (cu_err)
  );

  // Receive path: front end in the PHY clock domain, FIFO across, receive unit
  // on the system clock.
  mii_rx #(.DATA_W(PHY_DATA_W)) u_mii_rx (
      .rx_clk       (mii_rx_clk),
      .rst          (rx_rst),
      .rxd          (mii_rxd),
      .rx_dv        (mii_rx_dv),
      .rx_er        (mii_rx_er),
      .fifo_wr_o    (rxf_wr),
      .fifo_data_o  (rxf_wdata),
      .fifo_full_i  (rxf_full),
      .active_o     (rx_active),
      .byte_count_o (rx_bytes)
  );

  // Deep enough to ride out the descriptor work between buffers.  Word-wide
  // DMA fixed the sustained rate; what is left is the pause while the next
  // buffer descriptor is fetched, and depth is the right tool for that.  At
  // gigabit with small buffers those pauses are what decide it.
  async_fifo #(.WIDTH(12), .DEPTH(256)) u_rx_fifo (
      .wclk    (mii_rx_clk),
      .wrst    (rx_rst),
      .wr_en   (rxf_wr),
      .wr_data (rxf_wdata),
      .wfull   (rxf_full),
      .rclk    (clk),
      .rrst    (core_rst),
      .rd_en   (rxf_rd),
      .rd_data (rxf_rdata),
      .rempty  (rxf_empty)
  );

  sync_fifo #(.WIDTH(12), .DEPTH(64)) u_lb_fifo (
      .clk     (clk),
      .rst     (core_rst),
      .flush   (1'b0),
      .wr_en   (lb_wr),
      .wr_data (lb_wdata),
      .full    (lb_full),
      .rd_en   (lb_rd),
      .rd_data (lb_rdata),
      .empty   (lb_empty),
      .level   (lb_level)
  );

  // The receive unit takes frames from the wire, or from the loopback path
  // when the chip is configured that way.
  wire        ru_src_empty = cfg_int_lb ? lb_empty : rxf_empty;
  wire [11:0] ru_src_data  = cfg_int_lb ? lb_rdata : rxf_rdata;
  logic       ru_src_rd;
  assign lb_rd   = ru_src_rd &&  cfg_int_lb;
  assign rxf_rd  = ru_src_rd && !cfg_int_lb;

  ie_ru u_ru (
      .clk             (clk),
      .rst             (rst),
      .core_rst_i      (core_rst_i),
      .cbbase_i        (cbbase),
      .scb_addr_i      (scb_base),
      .start_i         (ru_start),
      .start_rfa_i     (ru_rfa),
      .resume_i        (ru_resume),
      .suspend_i       (ru_suspend),
      .abort_i         (ru_abort),
      .rus_o           (ru_rus),
      .ev_fr_o         (ev_fr),
      .ev_rnr_o        (ev_rnr),
      .ia_addr_i       (ia_addr),
      .promisc_i       (cfg_bytes[64]),
      .no_bcast_i      (cfg_bytes[65]),
      .addr_in_buffer_i(cfg_bytes[27]),
      .mc_clear_i      (mc_clear),
      .mc_wr_i         (mc_wr),
      .mc_addr_i       (mc_addr),
      .mc_all_i        (mc_all),
      .save_bad_i      (cfg_bytes[23]),
      .min_frame_len_i (cfg_bytes[87:80]),
      .rx_empty_i      (ru_src_empty),
      .rx_data_i       (ru_src_data),
      .rx_rd_o         (ru_src_rd),
      .bus_req_o       (ru_req),
      .bus_we_o        (ru_we),
      .bus_size_o      (ru_size),
      .bus_sel_o       (ru_sel),
      .bus_addr_o      (ru_addr),
      .bus_wdata_o     (ru_wdata),
      .bus_ack_i       (ru_ack),
      .bus_rdata_i     (bus_rdata),
      .bus_err_i       (ru_err)
  );

  wb_arb u_arb (
      .clk        (clk),
      .rst        (rst),
      .p0_req_i   (scb_req),
      .p0_we_i    (scb_we),
      .p0_size_i  (scb_size),
      .p0_sel_i   (scb_sel),
      .p0_addr_i  (scb_addr),
      .p0_wdata_i (scb_wdata),
      .p0_ack_o   (scb_ack),
      .p0_err_o   (scb_err),
      .p1_req_i   (ru_req),
      .p1_we_i    (ru_we),
      .p1_size_i  (ru_size),
      .p1_sel_i   (ru_sel),
      .p1_addr_i  (ru_addr),
      .p1_wdata_i (ru_wdata),
      .p1_ack_o   (ru_ack),
      .p1_err_o   (ru_err),
      .p2_req_i   (cu_req),
      .p2_we_i    (cu_we),
      .p2_size_i  (cu_size),
      .p2_sel_i   (cu_sel),
      .p2_addr_i  (cu_addr),
      .p2_wdata_i (cu_wdata),
      .p2_ack_o   (cu_ack),
      .p2_err_o   (cu_err),
      .rdata_o    (bus_rdata),
      .req_o      (bus_req),
      .we_o       (bus_we),
      .size_o     (bus_size),
      .sel_o      (bus_sel),
      .addr_o     (bus_addr),
      .wdata_o    (bus_wdata),
      .ack_i      (bus_ack),
      .err_i      (bus_err),
      .rdata_i    (bus_rdata_raw)
  );

  wb_master #(
      .WB_ADDR_W (WB_ADDR_W),
      .WB_DATA_W (WB_DATA_W)
  ) u_wbm (
      .clk       (clk),
      .rst       (rst),
      .req_i     (bus_req),
      .we_i      (bus_we),
      .size_i    (bus_size),
      .sel_i     (bus_sel),
      .addr_i    (bus_addr),
      .wdata_i   (bus_wdata),
      .ack_o     (bus_ack),
      .rdata_o   (bus_rdata_raw),
      .err_o     (bus_err),
      .wbm_cyc_o (wbm_cyc_o),
      .wbm_stb_o (wbm_stb_o),
      .wbm_we_o  (wbm_we_o),
      .wbm_sel_o (wbm_sel_o),
      .wbm_adr_o (wbm_adr_o),
      .wbm_dat_o (wbm_dat_o),
      .wbm_dat_i (wbm_dat_i),
      .wbm_ack_i (wbm_ack_i),
      .wbm_err_i (wbm_err_i)
  );

  // Transmit path: the command unit stages a frame here, mii_tx clocks it out.
  dp_ram #(.WIDTH(8), .DEPTH(2048)) u_tx_ram (
      .wclk    (clk),
      .wr_en   (tx_ram_we),
      .wr_addr (tx_ram_waddr),
      .wr_data (tx_ram_wdata),
      .rclk    (mii_tx_clk),
      .rd_addr (tx_ram_raddr),
      .rd_data (tx_ram_rdata)
  );

  mii_tx #(
      .DATA_W      (PHY_DATA_W),
      .DEFER_LIMIT (DEFER_LIMIT)
  ) u_mii_tx (
      .tx_clk        (mii_tx_clk),
      .rst           (tx_rst),
      .go_i          (tx_go),
      .len_i         (tx_len),
      .done_o        (tx_done),
      .ok_o          (tx_ok),
      .ncoll_o       (tx_ncoll),
      .xcoll_o       (tx_xcoll),
      .defer_o       (tx_defer),
      .no_crs_o      (tx_no_crs),
      .retry_limit_i (cfg_retry),
      .ifs_i         (cfg_ifs),
      .slot_time_i   (cfg_slot),
      .min_len_i     (cfg_min_len),
      .no_crc_i      (cfg_no_crc),
      .ram_addr_o    (tx_ram_raddr),
      .ram_data_i    (tx_ram_rdata),
      .txd           (mii_txd),
      .tx_en         (mii_tx_en),
      .tx_er         (mii_tx_er),
      .crs           (mii_crs),
      .col           (mii_col)
  );

  // A machine's own control register may want to latch this; the Sun-2's has
  // an ERR bit that inhibits further channel activity until RESET clears it.
  assign bus_err_o = bus_err;

  // Only some of cfg_bytes is sliced out above - the rest of the CONFIGURE
  // block is captured but has no consumer - and the three counters exist to be
  // looked at in a waveform.  Keep the linter quiet about them; shrink this
  // rather than widen it.
  // verilator lint_off UNUSED
  wire _unused = &{1'b0, cfg_bytes, rx_active, rx_bytes, lb_level};
  // verilator lint_on UNUSED

endmodule
