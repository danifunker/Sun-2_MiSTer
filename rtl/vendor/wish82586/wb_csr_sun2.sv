// SPDX-License-Identifier: MIT
//
// The Sun-2 on-board Ethernet control register, as a Wishbone slave.
//
// An example of the point of splitting wb_csr out of wish82586: the 82586 has
// no software-visible registers, so a recreated machine brings its own, and
// the Sun-2's has nothing in common with this project's.  Drop this in place of
// wb_csr and an unmodified Sun-2 ROM driver finds the register it expects.
//
// One byte, from doc/sun2_ethernet.pdf (Sun-2 Architecture Manual 6.13) and
// doc/drivers/Sun2120_ROM/if_obie.h, which agree bit for bit:
//
//   bit 7  RESET*  r/w  0 resets the 82586      (obie_noreset)
//   bit 6  LOOPB*  r/w  0 selects loopback      (obie_noloop)
//   bit 5  CA      r/w  channel attention       (obie_ca)
//   bit 4  INTEN   r/w  interrupt enable        (obie_ie)
//   bit 3          ro   unused
//   bit 2          ro   transceiver level; not modelled, reads 0
//   bit 1  ERR     ro   the DMA got a bus error (obie_buserr)
//   bit 0  INT     ro   the 82586 wants service (obie_intr)
//
// "Initialization: cleared on all resets": the byte resets to zero, so the
// chip comes up held in reset and in loopback and the driver has to let it
// out - `*obie = obie_reset' then `obie->obie_noreset = 1' in if_ie.c.
//
// Two things are worth knowing before using this.
//
// CA is a level in the register, not a write-1-to-pulse bit: the ROM driver
// writes it set and then clear (ieca() in if_ie.c).  The 82586 latches channel
// attention on the rising edge of its pin, so that is what this generates -
// one core clock per 0 -> 1 transition of the bit.  Writing it set twice
// without clearing it in between is one channel attention, as on the hardware.
//
// LOOPB* is not something the MAC can honour.  On the Sun-2 it isolates the
// transceiver, which is why the driver keeps the interface in loopback across
// initialisation - "the chip does random things if its 'wire' is active
// between the time it's reset and the first CA".  That is a PHY-side signal,
// so it is brought out as a pin for the system to wire to its transceiver and
// the MAC never sees it.  This is not the 82586's own internal loopback, which
// is a CONFIGURE bit and works already.
//
// The SCP address is a parameter, not a register: the real part has it wired
// to 0xFFFFF6 and the Sun-2 has no way to move it.  The ROM driver instead
// re-maps the page at 0xFFFFF6 to its own memory for as long as the chip needs
// to read the SCP, and puts the mapping back afterwards.
//
// Byte lanes follow the rest of this project: the register is byte 0 of word 0
// and bit 7 is bit 7 of the data bus.  A big-endian host needs the same byte
// swap in its bus glue that the original machine had, exactly as for the
// shared memory - see doc/drivers/NetBSD/README.md.

module wb_csr_sun2 #(
    // Where the 82586 goes looking for the System Configuration Pointer.
    parameter logic [31:0] SCP_ADDR = wish82586_pkg::SCP_ADDR_RESET
) (
    input  logic        clk,
    input  logic        rst,          // Wishbone RST_I: synchronous, active high

    // Wishbone B4 classic slave
    input  logic        wbs_cyc_i,
    input  logic        wbs_stb_i,
    input  logic        wbs_we_i,
    input  logic [3:0]  wbs_sel_i,
    input  logic [5:0]  wbs_adr_i,   // word address: the register is index 0
    input  logic [31:0] wbs_dat_i,
    output logic [31:0] wbs_dat_o,
    output logic        wbs_ack_o,
    output logic        wbs_err_o,

    // to/from the MAC core
    output logic        core_rst_o,   // level, core held in reset
    output logic        ca_o,         // single-cycle channel attention pulse
    output logic [31:0] scp_addr_o,
    input  logic        int_i,        // level interrupt request from the core
    input  logic        bus_err_i,    // one cycle per shared-memory access that failed

    // to the transceiver, not to the MAC
    output logic        loopback_o,   // 1 while the register selects loopback

    output logic        irq_o
);

  // Bit positions in the register byte.
  localparam int BIT_INT     = 0;
  localparam int BIT_ERR     = 1;
  localparam int BIT_LEVEL2  = 2;
  localparam int BIT_UNUSED  = 3;
  localparam int BIT_INTEN   = 4;
  localparam int BIT_CA      = 5;
  localparam int BIT_NOLOOP  = 6;
  localparam int BIT_NORESET = 7;

  logic noreset_q;
  logic noloop_q;
  logic ca_q;
  logic inten_q;
  logic err_q;

  wire acc   = wbs_cyc_i && wbs_stb_i && !wbs_ack_o;
  wire wr    = acc && wbs_we_i && (wbs_adr_i == 6'd0) && wbs_sel_i[0];
  wire ca_wr = wbs_dat_i[BIT_CA];

  always_ff @(posedge clk) begin
    if (rst) begin
      // Cleared on all resets, so the chip is held in reset and in loopback.
      noreset_q <= 1'b0;
      noloop_q  <= 1'b0;
      ca_q      <= 1'b0;
      inten_q   <= 1'b0;
      err_q     <= 1'b0;
      ca_o      <= 1'b0;
    end else begin
      ca_o <= 1'b0;

      // The bus error latch is set by the core and cleared by RESET*, which is
      // the only way the driver has of clearing it.
      if (bus_err_i)   err_q <= 1'b1;
      if (!noreset_q)  err_q <= 1'b0;

      if (wr) begin
        noreset_q <= wbs_dat_i[BIT_NORESET];
        noloop_q  <= wbs_dat_i[BIT_NOLOOP];
        inten_q   <= wbs_dat_i[BIT_INTEN];
        ca_q      <= ca_wr;
        // Channel attention on the rising edge of the bit, as the pin sees it.
        if (ca_wr && !ca_q) ca_o <= 1'b1;
      end
    end
  end

  always_comb begin
    wbs_dat_o = 32'h0;
    if (wbs_adr_i == 6'd0) begin
      wbs_dat_o[BIT_INT]     = int_i;
      wbs_dat_o[BIT_ERR]     = err_q;
      wbs_dat_o[BIT_LEVEL2]  = 1'b0;   // transceiver type, not modelled
      wbs_dat_o[BIT_UNUSED]  = 1'b0;
      wbs_dat_o[BIT_INTEN]   = inten_q;
      wbs_dat_o[BIT_CA]      = ca_q;
      wbs_dat_o[BIT_NOLOOP]  = noloop_q;
      wbs_dat_o[BIT_NORESET] = noreset_q;
    end
  end

  // Single wait state free: acknowledge the cycle after it is presented.
  always_ff @(posedge clk) begin
    if (rst) wbs_ack_o <= 1'b0;
    else     wbs_ack_o <= acc;
  end

  // The whole register is one byte, so no other lane means anything.
  /* verilator lint_off UNUSED */
  wire _unused = &{1'b0, wbs_sel_i[3:1]};
  /* verilator lint_on UNUSED */

  assign wbs_err_o  = 1'b0;
  assign core_rst_o = !noreset_q;      // RESET* is active low
  assign loopback_o = !noloop_q;       // LOOPB* likewise
  assign scp_addr_o = SCP_ADDR;
  assign irq_o      = inten_q && int_i;

endmodule
