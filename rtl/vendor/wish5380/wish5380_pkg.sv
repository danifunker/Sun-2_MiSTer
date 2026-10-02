// SPDX-License-Identifier: MIT
//
// NCR 5380 constants.
//
// Written from `doc/NCR5380_design_manual_Mar86.pdf` section 6 and appendix
// A7.  `tb/cpp/ncr5380.h` holds the same numbers for the testbench and is
// derived from the same pages, independently: the two are kept in step by
// hand and `tb/cpp/tests/test_layout.cpp` is what stops them drifting apart -
// from each other, and from the two driver headers in `doc/drivers/`.
//
// Page numbers in comments are the printed pages of that manual.
//
// Yosys 0.23 rejects `import pkg::*` in both module headers and module
// bodies, so everything here is referred to as `wish5380_pkg::NAME`.

// This package describes the whole part, not the part of it that happens to be
// wired up today, so a constant with no user yet is expected rather than a
// mistake.  The suppression is deliberately the only one in the RTL: it covers
// a file that holds nothing but constants.
/* verilator lint_off UNUSEDPARAM */

package wish5380_pkg;

  // -------------------------------------------------------------------------
  // Register addresses (p. 10).  A2..A0.  Five of the eight are a different
  // register on read and on write, and four of those are strobes: writing
  // 5, 6 or 7 starts a DMA transfer whatever the data is, and reading 7
  // clears three status bits.  A strobe is an event, not a value, which is
  // why the register file has to see the access and not merely decode it.
  // -------------------------------------------------------------------------

  localparam logic [2:0] A_CSD  = 3'd0;  // r  Current SCSI Data
  localparam logic [2:0] A_ODR  = 3'd0;  // w  Output Data
  localparam logic [2:0] A_ICR  = 3'd1;  // rw Initiator Command
  localparam logic [2:0] A_MR   = 3'd2;  // rw Mode
  localparam logic [2:0] A_TCR  = 3'd3;  // rw Target Command
  localparam logic [2:0] A_CSB  = 3'd4;  // r  Current SCSI Bus Status
  localparam logic [2:0] A_SER  = 3'd4;  // w  Select Enable
  localparam logic [2:0] A_BSR  = 3'd5;  // r  Bus and Status
  localparam logic [2:0] A_SDS  = 3'd5;  // w  Start DMA Send
  localparam logic [2:0] A_IDR  = 3'd6;  // r  Input Data
  localparam logic [2:0] A_SDTR = 3'd6;  // w  Start DMA Target Receive
  localparam logic [2:0] A_RPI  = 3'd7;  // r  Reset Parity/Interrupt
  localparam logic [2:0] A_SDIR = 3'd7;  // w  Start DMA Initiator Receive

  // -------------------------------------------------------------------------
  // Register 1, Initiator Command (pp. 11-12).
  //
  // Bits 6 and 5 are different registers on read and on write - AIP and LA
  // coming back, TEST MODE and DIFF ENBL going in - so a read/modify/write of
  // this register does not preserve what was there.  Both reference drivers
  // know it: NetBSD masks with 0x1f and Linux keeps a shadow copy.
  // -------------------------------------------------------------------------

  localparam int ICR_RST_B  = 7;  // rw assert RST
  localparam int ICR_AIP_B  = 6;  // r  arbitration in progress
  localparam int ICR_TEST_B = 6;  // w  test mode: float the output drivers
  localparam int ICR_LA_B   = 5;  // r  lost arbitration
  localparam int ICR_DIFF_B = 5;  // w  differential enable (NCR 5381 only)
  localparam int ICR_ACK_B  = 4;  // rw assert ACK
  localparam int ICR_BSY_B  = 3;  // rw assert BSY
  localparam int ICR_SEL_B  = 2;  // rw assert SEL
  localparam int ICR_ATN_B  = 1;  // rw assert ATN
  localparam int ICR_DATA_B = 0;  // rw assert data bus

  // The bits that read back what was written.
  localparam logic [7:0] ICR_RW_MASK = 8'h9f;

  // -------------------------------------------------------------------------
  // Register 2, Mode (p. 13).
  // -------------------------------------------------------------------------

  localparam int MR_BLOCK_DMA_B = 7;
  localparam int MR_TARGET_B    = 6;
  localparam int MR_PAR_CHK_B   = 5;
  localparam int MR_PAR_INTR_B  = 4;
  localparam int MR_EOP_INTR_B  = 3;
  localparam int MR_MON_BSY_B   = 2;
  localparam int MR_DMA_B       = 1;
  localparam int MR_ARB_B       = 0;

  // -------------------------------------------------------------------------
  // Register 3, Target Command (p. 14).
  //
  // Bits 6..4 are unimplemented and read as zero; bit 7 is the 53C80's LAST
  // BYTE SENT and reads as zero on the NMOS part (appendix A7).
  // -------------------------------------------------------------------------

  localparam int TCR_LAST_B = 7;  // r  53C80 only
  localparam int TCR_REQ_B  = 3;
  localparam int TCR_MSG_B  = 2;
  localparam int TCR_CD_B   = 1;
  localparam int TCR_IO_B   = 0;

  localparam logic [7:0] TCR_RW_MASK = 8'h0f;

  // -------------------------------------------------------------------------
  // Register 4 read, Current SCSI Bus Status (p. 15).  One means asserted.
  // -------------------------------------------------------------------------

  localparam int CSB_RST_B = 7;
  localparam int CSB_BSY_B = 6;
  localparam int CSB_REQ_B = 5;
  localparam int CSB_MSG_B = 4;
  localparam int CSB_CD_B  = 3;
  localparam int CSB_IO_B  = 2;
  localparam int CSB_SEL_B = 1;
  localparam int CSB_DBP_B = 0;

  // -------------------------------------------------------------------------
  // Register 5 read, Bus and Status (pp. 15-16).
  // -------------------------------------------------------------------------

  localparam int BSR_END_DMA_B    = 7;
  localparam int BSR_DRQ_B        = 6;
  localparam int BSR_PAR_ERR_B    = 5;
  localparam int BSR_IRQ_B        = 4;
  localparam int BSR_PHASE_MATCH_B = 3;
  localparam int BSR_BUSY_ERR_B   = 2;
  localparam int BSR_ATN_B        = 1;
  localparam int BSR_ACK_B        = 0;

  // -------------------------------------------------------------------------
  // Information transfer phases, in the Target Command Register's encoding
  // (p. 14): bit 2 MSG, bit 1 C/D, bit 0 I/O.  The Current SCSI Bus Status
  // Register carries the same three bits two places higher, which is the
  // `>> 2` both drivers apply.
  // -------------------------------------------------------------------------

  localparam logic [2:0] PH_DATA_OUT = 3'b000;
  localparam logic [2:0] PH_DATA_IN  = 3'b001;
  localparam logic [2:0] PH_COMMAND  = 3'b010;
  localparam logic [2:0] PH_STATUS   = 3'b011;
  localparam logic [2:0] PH_MSG_OUT  = 3'b110;
  localparam logic [2:0] PH_MSG_IN   = 3'b111;

  // -------------------------------------------------------------------------
  // The internal SCSI bus.
  //
  // The real part drives an open-collector bus that is active low and shared
  // by every device on the cable.  This design has no SCSI pads - the only
  // target is the SD-backed one inside the chip - so the bus is carried as
  // active-high "asserted" nets and the wired-OR becomes a plain OR of what
  // each device is driving.  Nothing above this layer can tell the
  // difference, and the registers still report the bus exactly as the
  // datasheet describes, because the sense inversion is at the pad and there
  // is no pad.  `doc/interface.md` argues this at length.
  //
  // Every device on the bus drives one of these, and the fabric ORs them all
  // together; each device sees the result, including its own contribution,
  // which is what an open-collector bus does and what the Current SCSI Bus
  // Status Register reports.  ATN and ACK are in here beside the rest even
  // though the status register does not carry them - they are bits 1 and 0 of
  // the Bus and Status Register instead (p. 16).
  //
  // Parity is carried as the parity bit itself rather than as something the
  // fabric computes, because a test has to be able to drive bad parity.
  // -------------------------------------------------------------------------

  // The type itself is `scsi_t`, declared below at file scope rather than in
  // here.  See the note there.

endpackage

/* verilator lint_on UNUSEDPARAM */

// Icarus 11 aborts with an internal assertion - elab_type.cc:86 - on any
// packed struct typedef declared inside a package, whether or not it reaches
// a port.  It accepts the identical declaration at file scope, so that is
// where this one lives, and `make lint-icarus` keeps working.
//
// File scope means the compilation unit, which for all three tools here is
// every file given on one command line.  Because this file is first in the
// Makefile's RTL list, the type is in scope for the rest.
//
// There is deliberately no SCSI_W or SCSI_IDLE constant beside it either:
// Yosys 0.23 rejects `$bits` of a type name and Icarus refuses a parameter
// whose type is a struct.  Modules write `scsi_t` and `'0`.
typedef struct packed {
  logic       rst;
  logic       bsy;
  logic       sel;
  logic       req;
  logic       ack;
  logic       atn;
  logic       msg;
  logic       cd;
  logic       io;
  logic [7:0] data;
  logic       dbp;
} scsi_t;

// ---------------------------------------------------------------------------
// The Wishbone B4 classic slave port, in the two directions a slave sees.
//
// Here for the same reason `scsi_t` is: a bundle that crosses three module
// boundaries unchanged is easier to get right as one named thing than as ten
// ports repeated four times.  Wishbone is a published specification and needs
// no local document; `doc/interface.md` records only what this design chose
// within it - word addressing, the little-endian lane convention, and the
// three windows.
//
// SystemVerilog interfaces with modports would be the textbook way to say
// this.  They are not usable here: Icarus 11 raises a syntax error on any
// interface port, and Yosys 0.23 does not implement them at all - it invents
// implicitly declared wires for the interface's fields and elaborates a
// netlist in which the instance is simply not connected, *without failing*.
// A `make synth` that passes while checking nothing is worse than one that
// breaks, so the design uses packed structs, which all three tools agree on.
// ---------------------------------------------------------------------------
typedef struct packed {
  logic        cyc;
  logic        stb;
  logic        we;
  logic [3:0]  sel;
  logic [29:0] adr;
  logic [31:0] dat;
} wb_req_t;

typedef struct packed {
  logic [31:0] dat;
  logic        ack;
  logic        err;
} wb_rsp_t;

// ---------------------------------------------------------------------------
// The block back end: what a SCSI target asks storage for, and what comes
// back.  `doc/block.md` is this interface's contract - it is the one interface
// in the design with no external authority behind it, so the handshake, the
// buffer's ownership rule and the three ways a back end can fail silently are
// all written down there.
//
// `blk_req_t` always flows from the target to the back end and `blk_rsp_t`
// always the other way, whichever module is being looked at.  `buf_rdata` is
// in the request because the sector buffer lives in the target: it is the
// target answering the back end's read, and it travels with the rest of what
// the target drives.
// ---------------------------------------------------------------------------
typedef struct packed {
  logic        start;      // one cycle: begin a transfer
  logic        we;         // 1 writes the buffer to the media, 0 fills it
  logic [31:0] lba;        // valid with `start`
  logic [7:0]  buf_rdata;  // the buffer's read port, one cycle behind `buf_addr`
} blk_req_t;

typedef struct packed {
  logic        done;       // one cycle: the transfer is over
  logic        err;        // only meaningful in the cycle `done` is high
  logic        ready;      // media present and initialised
  logic [31:0] count;      // capacity, in 512-byte blocks
  logic        buf_we;
  logic [8:0]  buf_addr;
  logic [7:0]  buf_wdata;
} blk_rsp_t;
