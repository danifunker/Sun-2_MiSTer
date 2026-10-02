// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - SystemVerilog MC68010
//
// Top level. Pin list per doc/pinout.md: every three-state or bidirectional pin
// of the original is split into _i / _o / _oe, with _oe active high meaning the
// core drives.
//
// The whole processor is two units: rd68011_seq runs the microcode and holds
// the datapath, rd68011_biu drives the pins. This wires them together and
// does nothing else.
//
// Note the fully-scoped rd68011_pkg:: references and the plain-vector ports:
// yosys 0.52 supports neither `import pkg::*` nor user types on ports.
// See doc/coding-standard.md.

module rd68011_top #(
    // Passed straight to rd68011_seq, where it is documented. Zero is an
    // MC68010; anything else turns the loop buffer on, which loop_inv_n_i
    // below then belongs to.
    parameter int LOOP_BUF_WORDS = 0,
    // Passed straight to rd68011_seq, where it is documented. Zero -- the
    // default -- exits loop mode on a bus error and lets the DBcc re-enter it;
    // one restores it from the frame. Appendix A is ambiguous and
    // doc/divergences.md argues both readings.
    parameter bit RTE_RESTORES_LOOP = 1'b0,
    // ... and whether the loop buffer's window survives one. Both default to
    // the MC68010; clearing one at a time says which half of the crossing a
    // downstream failure depends on.
    parameter bit RTE_KEEPS_LOOP_BUF = 1'b1
) (
    // Clock and hardware reset -----------------------------------------------
    input  logic        clk,      // free-running, both edges used (UM 3.9)
    input  logic        rst_n,    // not an MC68010 pin: async init, see doc/pinout.md

    // Address bus (UM 3.1) ---------------------------------------------------
    output logic [23:1] a_o,
    output logic        a_oe,

    // Data bus (UM 3.2) ------------------------------------------------------
    input  logic [15:0] d_i,
    output logic [15:0] d_o,
    output logic        d_oe,

    // Asynchronous bus control (UM 3.3) --------------------------------------
    output logic        as_n_o,
    output logic        as_oe,
    output logic        rw_o,      // high = read, low = write
    output logic        rw_oe,
    output logic        uds_n_o,
    output logic        lds_n_o,
    output logic        ds_oe,
    input  logic        dtack_n_i,

    // Bus arbitration (UM 3.4) -----------------------------------------------
    input  logic        br_n_i,
    output logic        bg_n_o,    // never three-stated
    input  logic        bgack_n_i,

    // Interrupt control (UM 3.5) ---------------------------------------------
    input  logic  [2:0] ipl_n_i,

    // System control (UM 3.6) ------------------------------------------------
    input  logic        berr_n_i,
    input  logic        reset_n_i,
    output logic        reset_n_o,  // open drain: constant 0
    output logic        reset_n_oe,
    input  logic        halt_n_i,
    output logic        halt_n_o,   // open drain: constant 0
    output logic        halt_n_oe,
    // Not an MC68010 pin, and meaningless unless LOOP_BUF_WORDS is set: while
    // it is asserted the loop buffer is emptied and kept empty, so a pulse
    // invalidates and a permanent assertion disables. A SystemVerilog port
    // list cannot be made conditional on a parameter across the six front-ends
    // this has to elaborate under, so the pin is always here; tie it high on a
    // core built with the default. See doc/pinout.md.
    input  logic        loop_inv_n_i,

    // M6800 peripheral control (UM 3.7) --------------------------------------
    output logic        e_o,        // never three-stated
    input  logic        vpa_n_i,
    output logic        vma_n_o,
    output logic        vma_oe,

    // Processor status (UM 3.8) ----------------------------------------------
    output logic  [2:0] fc_o,
    output logic        fc_oe
);

  // Bus unit to sequencer.
  logic        req_valid;
  logic  [2:0] req_kind;
  logic  [2:0] req_fc;
  logic [23:1] req_addr;
  logic        req_uds;
  logic        req_lds;
  logic [15:0] req_wdata;
  logic        req_ack;
  logic        req_last;
  logic [15:0] req_rdata;
  logic  [2:0] req_end;
  logic        req_fault;
  logic        req_fault_wr;
  logic        reset_req;
  logic        reset_busy;
  logic  [2:0] ipl_sync_n;
  logic        reset_sync_n;
  logic        halt_sync_n;
  logic        bus_idle;
  logic        dbf;
  logic        bus_granted;
  logic        loop_inv_sync_n;

  rd68011_seq #(.LOOP_BUF_WORDS    (LOOP_BUF_WORDS),
                .RTE_RESTORES_LOOP  (RTE_RESTORES_LOOP),
                .RTE_KEEPS_LOOP_BUF (RTE_KEEPS_LOOP_BUF)) u_seq (
      .clk          (clk),
      .rst_n        (rst_n),
      .req_valid    (req_valid),
      .req_kind     (req_kind),
      .req_fc       (req_fc),
      .req_addr     (req_addr),
      .req_uds      (req_uds),
      .req_lds      (req_lds),
      .req_wdata    (req_wdata),
      .req_ack      (req_ack),
      .req_last     (req_last),
      .req_rdata    (req_rdata),
      .req_end      (req_end),
      .req_fault    (req_fault),
      .req_fault_wr (req_fault_wr),
      .ipl_sync_n   (ipl_sync_n),
      .reset_sync_n (reset_sync_n),
      .halt_sync_n  (halt_sync_n),
      .bus_idle     (bus_idle),
      .bus_granted  (bus_granted),
      .loop_inv_sync_n (loop_inv_sync_n),
      .reset_req    (reset_req),
      .reset_busy   (reset_busy),
      .dbf          (dbf)
  );

  rd68011_biu u_biu (
      .clk        (clk),
      .rst_n      (rst_n),

      .req_valid  (req_valid),
      .req_kind   (req_kind),
      .req_fc     (req_fc),
      .req_addr   (req_addr),
      .req_uds    (req_uds),
      .req_lds    (req_lds),
      .req_wdata  (req_wdata),
      .req_ack    (req_ack),
      .req_last   (req_last),
      .req_rdata  (req_rdata),
      .req_end    (req_end),
      .req_fault  (req_fault),
      .req_fault_wr (req_fault_wr),

      .reset_req  (reset_req),
      .reset_busy (reset_busy),

      .ipl_sync_n   (ipl_sync_n),
      .reset_sync_n (reset_sync_n),
      .halt_sync_n  (halt_sync_n),
      .bus_idle     (bus_idle),
      .dbf          (dbf),
      .bus_granted  (bus_granted),
      .loop_inv_sync_n (loop_inv_sync_n),

      .a_o        (a_o),        .a_oe       (a_oe),
      .d_i        (d_i),        .d_o        (d_o),        .d_oe (d_oe),
      .as_n_o     (as_n_o),     .as_oe      (as_oe),
      .rw_o       (rw_o),       .rw_oe      (rw_oe),
      .uds_n_o    (uds_n_o),    .lds_n_o    (lds_n_o),    .ds_oe (ds_oe),
      .dtack_n_i  (dtack_n_i),
      .br_n_i     (br_n_i),     .bg_n_o     (bg_n_o),     .bgack_n_i (bgack_n_i),
      .ipl_n_i    (ipl_n_i),
      .berr_n_i   (berr_n_i),
      .reset_n_i  (reset_n_i),  .reset_n_o  (reset_n_o),  .reset_n_oe (reset_n_oe),
      .halt_n_i   (halt_n_i),   .halt_n_o   (halt_n_o),   .halt_n_oe  (halt_n_oe),
      .loop_inv_n_i (loop_inv_n_i),
      .e_o        (e_o),        .vpa_n_i    (vpa_n_i),
      .vma_n_o    (vma_n_o),    .vma_oe     (vma_oe),
      .fc_o       (fc_o),       .fc_oe      (fc_oe)
  );

  // Every signal between the two units is connected, so there is nothing for
  // the usual unused-input tie-off to absorb.
  logic unused_biu;
  assign unused_biu = 1'b1;

endmodule
