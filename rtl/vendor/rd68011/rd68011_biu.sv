// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - bus interface unit.
//
// Implements UM section 5 (16-bit bus operation) and appendix B (M6800
// peripheral interface): the S0..S7 asynchronous cycle with wait states, the
// S0..S19 read-modify-write cycle, CPU space cycles, the synchronous M6800
// cycle, bus arbitration, bus error / retry / halt, and the RESET instruction's
// 124-clock output pulse.
//
// TIMING MODEL
//
// One bus state per CLK half period. Even states begin on a rising edge, odd
// states on a falling edge; figure 10-4's recovered state ruler puts t=0 at the
// S0 rising edge and every event the manual describes falls out of that:
//
//   S0 rising   FC valid, R/W high            spec 6A, 18
//   S1 falling  address valid                 spec 6
//   S2 rising   AS asserted, R/W low (write)  spec 9, 20
//   S3 falling  write data driven             spec 23
//   S4 rising   data strobes asserted (write) spec 9
//   S4 falling  DTACK / BERR / VPA sampled    spec 47; wait states if none
//   S6 falling  read data latched, AS and data strobes negated   spec 27, 12
//   S7 rising   data bus released, R/W high   spec 7
//
// The state machine is therefore two registers, one per edge, each computing
// its next state from the other. Outputs live in whichever domain drives them;
// the four that change on both edges use rd68011_dedge_ff.
//
// SAMPLING
//
// DTACK, BERR, VPA and HALT are sampled directly by the falling-edge next-state
// logic -- one flop, no extra latency, which is what UM 5.1.1's note and figure
// 10-4 show. BR, BGACK, RESET and IPL go through rd68011_sync, the one-clock
// path of UM 5.3 figure 5-17.

module rd68011_biu #(
    // The address bus goes to high impedance at the rising edge that ends the
    // cycle and comes back out entering S1, which is what every source says:
    // UM 5.1.1 state 7, 5.1.2 state 7 and 5.1.3 state 19 (and their 8-bit
    // twins in section 4), appendix B twice -- "at state 0 (S0) in the cycle,
    // the address bus is in the high-impedance state" -- specification 7 in
    // the read-write AC table, which gives the time it takes at every speed
    // grade, and figures 5-3 and 10-4, which draw the address on the mid rail
    // there while drawing FC2-FC0 as a crossover. Table 3-4 is not a
    // counter-example: its only two columns are RESET and bus relinquish, and
    // the address bus reads Yes in both. Clearing this parameter keeps the
    // address driven between cycles for a board that needs it.
    parameter bit ADDR_HIZ_BETWEEN_CYCLES = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // -- Sequencer request ----------------------------------------------------
    // req_valid is held until req_ack. All request fields must be stable from
    // req_valid until req_ack, except req_wdata for a read-modify-write, which
    // need only be valid by S15 (four states of modify time, UM 5.1.3).
    input  logic        req_valid,
    input  logic  [2:0] req_kind,     // rd68011_pkg::cycle_kind_e
    input  logic  [2:0] req_fc,
    input  logic [23:1] req_addr,
    input  logic        req_uds,      // assert UDS for this transfer
    input  logic        req_lds,      // assert LDS for this transfer
    input  logic [15:0] req_wdata,
    output logic        req_ack,      // one clk pulse: cycle complete
    output logic        req_last,     // combinational: cycle ends at the next
                                      // rising edge. A sequencer that does not
                                      // want the next cycle to start back to
                                      // back must drop req_valid on this.
    output logic [15:0] req_rdata,
    output logic  [2:0] req_end,      // rd68011_pkg::cycle_end_e, valid with req_ack
    // Valid *with* req_last rather than after it, because the sequencer has to
    // decide on the same edge whether the microword retires normally or
    // becomes a bus error. `req_end` is a clock later, which is too late.
    output logic        req_fault,    // this cycle is ending in a bus error
    output logic        req_fault_wr, // ... and it was writing when it did

    // -- RESET instruction ----------------------------------------------------
    input  logic        reset_req,    // pulse to start a 124-clock RESET output
    output logic        reset_busy,

    // -- Status to the sequencer ---------------------------------------------
    output logic  [2:0] ipl_sync_n,   // synchronised IPL pins, still active low
    output logic        reset_sync_n,
    output logic        halt_sync_n,
    output logic        bus_idle,     // no cycle in progress and bus is ours
    input  logic        dbf,          // double bus fault: drive HALT out (UM 5.4.4)
    // Two things the loop buffer has to know and only this unit can see: that
    // the bus has gone to another master, and that the board is asking for an
    // invalidate. Both are ignored unless rd68011_seq's LOOP_BUF_WORDS is set.
    output logic        bus_granted,     // the buses belong to someone else
    output logic        loop_inv_sync_n, // synchronised loop_inv_n_i

    // -- Pins -----------------------------------------------------------------
    output logic [23:1] a_o,
    output logic        a_oe,
    input  logic [15:0] d_i,
    output logic [15:0] d_o,
    output logic        d_oe,
    output logic        as_n_o,
    output logic        as_oe,
    output logic        rw_o,
    output logic        rw_oe,
    output logic        uds_n_o,
    output logic        lds_n_o,
    output logic        ds_oe,
    input  logic        dtack_n_i,
    input  logic        br_n_i,
    output logic        bg_n_o,
    input  logic        bgack_n_i,
    input  logic  [2:0] ipl_n_i,
    input  logic        berr_n_i,
    input  logic        reset_n_i,
    output logic        reset_n_o,
    output logic        reset_n_oe,
    input  logic        halt_n_i,
    output logic        halt_n_o,
    output logic        halt_n_oe,
    input  logic        loop_inv_n_i,
    output logic        e_o,
    input  logic        vpa_n_i,
    output logic        vma_n_o,
    output logic        vma_oe,
    output logic  [2:0] fc_o,
    output logic        fc_oe
);

  // ===========================================================================
  // Synchronised inputs (UM 5.3, figure 5-17)
  // ===========================================================================
  logic br_n_s, bgack_n_s;

  rd68011_sync #(.WIDTH(1)) u_sync_br    (.clk(clk), .rst_n(rst_n), .d(br_n_i),    .q(br_n_s));
  rd68011_sync #(.WIDTH(1)) u_sync_bgack (.clk(clk), .rst_n(rst_n), .d(bgack_n_i), .q(bgack_n_s));
  rd68011_sync #(.WIDTH(1)) u_sync_reset (.clk(clk), .rst_n(rst_n), .d(reset_n_i), .q(reset_sync_n));
  rd68011_sync #(.WIDTH(1)) u_sync_halt  (.clk(clk), .rst_n(rst_n), .d(halt_n_i),  .q(halt_sync_n));
  rd68011_sync #(.WIDTH(3)) u_sync_ipl   (.clk(clk), .rst_n(rst_n), .d(ipl_n_i),   .q(ipl_sync_n));

  // The loop-buffer invalidate is asynchronous like the rest of them, and goes
  // through the same two ranks. That is what sets its minimum assertion width
  // at two clock periods, which doc/pinout.md states.
  rd68011_sync #(.WIDTH(1)) u_sync_linv  (.clk(clk), .rst_n(rst_n), .d(loop_inv_n_i),
                                          .q(loop_inv_sync_n));

  // ===========================================================================
  // M6800 enable clock (UM 3.7, appendix B)
  //
  // Ten clock periods, six low then four high. Specification 41 measures the
  // transition from CLK low, so this is a falling-edge counter. The real part's
  // ring counter comes up in an arbitrary state; ours is defined at reset.
  // ===========================================================================
  logic [3:0] e_cnt;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e_cnt <= 4'd0;
      e_o   <= 1'b0;
    end else begin
      e_cnt <= (e_cnt == rd68011_pkg::E_PERIOD_CLKS - 4'd1) ? 4'd0 : e_cnt + 4'd1;
      e_o   <= (e_cnt >= rd68011_pkg::E_LOW_CLKS - 4'd1) &&
               (e_cnt != rd68011_pkg::E_PERIOD_CLKS - 4'd1);
    end
  end

  // E rises at the falling edge where e_cnt is 5 and falls where it is 9.
  // Appendix B: VMA may only be asserted with at least three clocks left before
  // E rises; asserting later misses this E cycle and waits for the next, which
  // is exactly the manual's best case / worst case pair.
  logic e_vma_window;   // >= 3 clocks before E rises
  logic e_last_high;    // this falling edge is one clock before E falls

  assign e_vma_window = (e_cnt <= 4'd2);
  assign e_last_high  = (e_cnt == 4'd8);

  // ===========================================================================
  // Bus state machine
  // ===========================================================================
  rd68011_pkg::bus_state_e st_p;      // state entered on rising edges (even states)
  rd68011_pkg::bus_state_e st_n;      // state entered on falling edges (odd states)
  rd68011_pkg::bus_state_e st_p_nxt;
  rd68011_pkg::bus_state_e st_n_nxt;

  // Latched cycle parameters, so a retry reruns with the same values (UM 5.4.2).
  logic  [2:0] cyc_kind;
  logic  [2:0] cyc_fc;
  logic [23:1] cyc_addr;
  logic        cyc_uds, cyc_lds;
  logic        cyc_is_write;
  logic        cyc_is_rmw;

  // Termination state, captured on falling edges.
  logic        term_berr;    // BERR seen without DTACK: run on to S9 / S21
  // The MC68010's late bus error is a fault too, but not the same fault: the
  // transfer has already terminated normally and must still end in S7, so this
  // cannot share term_berr, which sends the state machine on to S9. It feeds
  // req_fault and nothing else.
  logic        term_berr_late;
  logic        term_halt;    // HALT seen with DTACK: halt after this cycle
  logic        term_retry;   // BERR+HALT: release buses and rerun
  logic        term_vpa;     // VPA seen: this is an M6800 cycle
  logic        vma_asserted;
  logic        vma_set;      // this falling edge is where VMA may assert
  logic  [2:0] end_code;

  // Asserted-high views of the pins sampled by the falling-edge logic.
  logic dtack_a, berr_a, halt_a, vpa_a;
  assign dtack_a = ~dtack_n_i;
  assign berr_a  = ~berr_n_i;
  assign halt_a  = ~halt_n_i;
  assign vpa_a   = ~vpa_n_i;

  // Arbitration, declared here because the state machine consults it.
  //
  // Only the *next* form exists, and every use below is deliberate. The output
  // enables are registered from it, so after any rising edge the buses belong
  // to the alternate master exactly when this was high at that edge -- and the
  // state machine has to make the same decision from the same signal, or the
  // two disagree for a clock. See `arb_freeze`.
  logic arb_bus_released_nxt;  // after this edge, the buses are the master's
  logic arb_hold;              // do not start a new cycle

  // True at the rising edge that starts a cycle with a fresh request, as
  // opposed to a retry rerunning the previous one (UM 5.4.2).
  logic start_new;

  // Is this request a write? CT_WRITE and the write half of CT_RMW.
  logic req_is_write, req_is_rmw;
  assign req_is_write = (req_kind == rd68011_pkg::CT_WRITE);
  assign req_is_rmw   = (req_kind == rd68011_pkg::CT_RMW);

  // ---------------------------------------------------------------------------
  // Where a completed cycle goes next. Halt takes effect at the end of the
  // current bus cycle (UM 5.4.3); arbitration likewise (UM 5.2.1).
  //
  // With a request already pending the next cycle starts immediately: figure
  // 5-3 draws S7 followed straight by the next S0, with no idle state, so
  // back-to-back cycles are four clocks apart and not five.
  // ---------------------------------------------------------------------------
  // A plain signal rather than a function: a function that reads module state
  // instead of its arguments is re-evaluated differently by different tools --
  // iverilog keys a continuous assignment's sensitivity off the arguments
  // alone. See doc/coding-standard.md.
  rd68011_pkg::bus_state_e after_cycle;

  always_comb begin
    if (term_retry)                   after_cycle = rd68011_pkg::ST_RETRY;
    else if (term_halt)               after_cycle = rd68011_pkg::ST_HALT;
    else if (arb_bus_released_nxt)    after_cycle = rd68011_pkg::ST_ARB;
    else if (req_valid && !arb_hold)  after_cycle = rd68011_pkg::ST_S0;
    else                              after_cycle = rd68011_pkg::ST_IDLE;
  end

  // ---------------------------------------------------------------------------
  // Rising-edge next state: from the odd state we are in, the even state we
  // enter. Only rising edges start a cycle -- S0 is a high state.
  // ---------------------------------------------------------------------------
  always_comb begin
    st_p_nxt = st_p;
    unique case (st_n)
      rd68011_pkg::ST_IDLE:
        if (arb_bus_released_nxt)            st_p_nxt = rd68011_pkg::ST_ARB;
        else if (!halt_sync_n)               st_p_nxt = rd68011_pkg::ST_HALT;
        else if (req_valid && !arb_hold)     st_p_nxt = rd68011_pkg::ST_S0;
        else                                 st_p_nxt = rd68011_pkg::ST_IDLE;

      rd68011_pkg::ST_S1:   st_p_nxt = rd68011_pkg::ST_S2;
      rd68011_pkg::ST_S3:   st_p_nxt = rd68011_pkg::ST_S4;
      rd68011_pkg::ST_WL:   st_p_nxt = rd68011_pkg::ST_WH;
      rd68011_pkg::ST_S5:   st_p_nxt = rd68011_pkg::ST_S6;

      // End of S7: a read-modify-write goes on to its modify states, a
      // BERR-without-DTACK cycle runs one more clock to S9, anything else is
      // finished (UM 5.1.1 note).
      rd68011_pkg::ST_S7:
        if (cyc_is_rmw && !term_berr && !term_retry)
                                             st_p_nxt = rd68011_pkg::ST_M8;
        else if (term_berr)                  st_p_nxt = rd68011_pkg::ST_BE8;
        else                                 st_p_nxt = after_cycle;

      rd68011_pkg::ST_BE9:  st_p_nxt = after_cycle;

      rd68011_pkg::ST_M9:   st_p_nxt = rd68011_pkg::ST_M10;
      rd68011_pkg::ST_M11:  st_p_nxt = rd68011_pkg::ST_S12;
      rd68011_pkg::ST_S13:  st_p_nxt = rd68011_pkg::ST_S14;
      rd68011_pkg::ST_S15:  st_p_nxt = rd68011_pkg::ST_S16;
      rd68011_pkg::ST_WL2:  st_p_nxt = rd68011_pkg::ST_WH2;
      rd68011_pkg::ST_S17:  st_p_nxt = rd68011_pkg::ST_S18;

      rd68011_pkg::ST_S19:
        if (term_berr)                       st_p_nxt = rd68011_pkg::ST_BE20;
        else                                 st_p_nxt = after_cycle;

      rd68011_pkg::ST_BE21: st_p_nxt = after_cycle;

      // Halted: UM 5.4.3, resume when HALT is negated. Arbitration still runs.
      rd68011_pkg::ST_HALT:
        if (arb_bus_released_nxt)            st_p_nxt = rd68011_pkg::ST_ARB;
        else if (!halt_sync_n)               st_p_nxt = rd68011_pkg::ST_HALT;
        else                                 st_p_nxt = rd68011_pkg::ST_IDLE;

      // Bus granted away: UM 5.2.
      rd68011_pkg::ST_ARB:
        if (arb_bus_released_nxt)            st_p_nxt = rd68011_pkg::ST_ARB;
        else if (!halt_sync_n)               st_p_nxt = rd68011_pkg::ST_HALT;
        else                                 st_p_nxt = rd68011_pkg::ST_IDLE;

      // Retry: UM 5.4.2, rerun the cycle once HALT is negated.
      rd68011_pkg::ST_RETRY:
        if (!halt_sync_n)                    st_p_nxt = rd68011_pkg::ST_RETRY;
        else if (arb_bus_released_nxt)       st_p_nxt = rd68011_pkg::ST_ARB;
        else                                 st_p_nxt = rd68011_pkg::ST_S0;

      default:                               st_p_nxt = rd68011_pkg::ST_IDLE;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Falling-edge next state: from the even state we are in, the odd state we
  // enter. This is where DTACK, BERR, VPA and HALT are sampled.
  // ---------------------------------------------------------------------------

  // Termination decision at a sampling edge (the falling edge ending S4, ending
  // any wait state, or ending S16). UM table 5-1 cases 1, 2, 3 and 5.
  logic samp_retry, samp_berr, samp_done, samp_vpa;

  assign samp_retry = berr_a && halt_a && !cyc_is_rmw;  // UM 5.4.2: RMW never retries
  assign samp_berr  = berr_a && !samp_retry;
  assign samp_vpa   = vpa_a && !dtack_a && !berr_a;

  // An autovectored interrupt acknowledge is not an M6800 cycle.
  //
  // UM 5.1.4: "the interrupt acknowledge cycle can be autovectored. The
  // interrupt acknowledge cycle is the same, except the interrupting device
  // asserts VPA instead of DTACK." UM 6.3.4 says the same from the other side,
  // listing DTACK, AVEC/VPA and BERR as the three ways to "terminate the vector
  // acquisition". So VPA acts here exactly where DTACK acts, on the same edge,
  // and the cycle is four clocks like any other.
  //
  // Appendix B.2 describes something else, and the difference is the whole
  // point: sections 5 and 6 are the native bus and native exceptions, while
  // appendix B is the M6800 compatibility mode. VPA is the one pin doing two
  // jobs -- "this is an M6800 peripheral, run the synchronous cycle" outside
  // CPU space, and "autovector this acknowledge" inside it. What appendix B
  // says about VMA belongs to its own mode, where an M6800 peripheral is being
  // addressed; it does not describe the native autovector, and it hedges in any
  // case ("the processor *or external circuitry*"). Later parts split the pin
  // in two, VPA and AVEC, precisely to remove the ambiguity this one carries.
  //
  // So no VMA here, and nothing for E to synchronise: the vector is generated
  // internally and no transfer happens at all. doc/bugs-found.md has the
  // measurement that found it.
  logic cyc_is_iack;
  assign cyc_is_iack = (cyc_kind == rd68011_pkg::CT_IACK);

  // An M6800 cycle leaves the wait loop only when it is aligned with E.
  assign samp_done  = dtack_a || samp_berr || samp_retry ||
                      (samp_vpa && cyc_is_iack) ||
                      (term_vpa && vma_asserted && e_last_high);

  always_comb begin
    st_n_nxt = st_n;
    unique case (st_p)
      rd68011_pkg::ST_IDLE:  st_n_nxt = rd68011_pkg::ST_IDLE;
      rd68011_pkg::ST_S0:    st_n_nxt = rd68011_pkg::ST_S1;
      rd68011_pkg::ST_S2:    st_n_nxt = rd68011_pkg::ST_S3;

      rd68011_pkg::ST_S4,
      rd68011_pkg::ST_WH:
        if (samp_done)         st_n_nxt = rd68011_pkg::ST_S5;
        else                   st_n_nxt = rd68011_pkg::ST_WL;

      rd68011_pkg::ST_S6:    st_n_nxt = rd68011_pkg::ST_S7;
      rd68011_pkg::ST_BE8:   st_n_nxt = rd68011_pkg::ST_BE9;

      rd68011_pkg::ST_M8:    st_n_nxt = rd68011_pkg::ST_M9;
      rd68011_pkg::ST_M10:   st_n_nxt = rd68011_pkg::ST_M11;
      rd68011_pkg::ST_S12:   st_n_nxt = rd68011_pkg::ST_S13;
      rd68011_pkg::ST_S14:   st_n_nxt = rd68011_pkg::ST_S15;

      rd68011_pkg::ST_S16,
      rd68011_pkg::ST_WH2:
        if (samp_done)         st_n_nxt = rd68011_pkg::ST_S17;
        else                   st_n_nxt = rd68011_pkg::ST_WL2;

      rd68011_pkg::ST_S18:   st_n_nxt = rd68011_pkg::ST_S19;
      rd68011_pkg::ST_BE20:  st_n_nxt = rd68011_pkg::ST_BE21;

      // The between-cycle conditions are entered on rising edges; the
      // falling-edge register just follows.
      rd68011_pkg::ST_HALT:  st_n_nxt = rd68011_pkg::ST_HALT;
      rd68011_pkg::ST_ARB:   st_n_nxt = rd68011_pkg::ST_ARB;
      rd68011_pkg::ST_RETRY: st_n_nxt = rd68011_pkg::ST_RETRY;

      default:               st_n_nxt = rd68011_pkg::ST_IDLE;
    endcase
  end

  // Convenience: are we entering this state on the coming edge?
  `define ENTER_P(s) (st_p_nxt == rd68011_pkg::s)
  `define ENTER_N(s) (st_n_nxt == rd68011_pkg::s)

  assign start_new = `ENTER_P(ST_S0) && (st_n != rd68011_pkg::ST_RETRY);

  // The cycle's last state: the rising edge that ends it either acknowledges
  // the request or, with req_valid still asserted, starts the next cycle
  // straight away (figure 5-3).
  //
  // Not for a retry. UM 5.4.2 has the bus unit rerunning the cycle itself, so
  // the attempt that failed must not look finished to the sequencer -- it holds
  // its request and never learns the rerun happened.
  //
  // Written out of registers rather than out of st_p_nxt, which would be the
  // shorter way to say the same thing: the sequencer builds its next request
  // from req_last, and the state machine consults req_valid, so routing this
  // through the next state closes a combinational loop between the two units.
  // Everything below is a register, so there is no loop to close.
  assign req_last = (((st_n == rd68011_pkg::ST_S7) &&
                      !(cyc_is_rmw && !term_berr && !term_retry) &&
                      !term_berr) ||
                     ((st_n == rd68011_pkg::ST_S19) && !term_berr) ||
                      (st_n == rd68011_pkg::ST_BE9) ||
                      (st_n == rd68011_pkg::ST_BE21)) && !term_retry;

  // The bus error, reported early. `term_berr` is set at the falling-edge
  // sampling point, well before the rising edge `req_last` names, so the
  // sequencer can see both at once.
  //
  // A read-modify-write runs its read in S0-S7 and its write in S8-S19, so
  // which half faulted is which of the two bus-error exits it takes (UM 5.4.1).
  assign req_fault    = term_berr || term_berr_late;
  assign req_fault_wr = cyc_is_write ||
                        (cyc_is_rmw && (st_n == rd68011_pkg::ST_BE21));

  // ---------------------------------------------------------------------------
  // State registers and the posedge-domain bookkeeping.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_p         <= rd68011_pkg::ST_IDLE;
      cyc_kind     <= rd68011_pkg::CT_READ;
      cyc_fc       <= rd68011_pkg::FC_SUPER_P;
      cyc_addr     <= '0;
      cyc_uds      <= 1'b0;
      cyc_lds      <= 1'b0;
      cyc_is_write <= 1'b0;
      cyc_is_rmw   <= 1'b0;
      req_ack      <= 1'b0;
      req_end      <= rd68011_pkg::CE_NONE;
    end else begin
      st_p    <= st_p_nxt;
      req_ack <= 1'b0;

      // Latch the request as the cycle starts, so a retry can rerun it with the
      // same function code, address and data (UM 5.4.2).
      if (start_new) begin
        cyc_kind     <= req_kind;
        cyc_fc       <= req_fc;
        cyc_addr     <= req_addr;
        cyc_uds      <= req_uds;
        cyc_lds      <= req_lds;
        cyc_is_write <= req_is_write;
        cyc_is_rmw   <= req_is_rmw;
      end

      // The cycle is over at the rising edge that ends its last state.
      if (req_last) begin
        // A retry is invisible to the sequencer: the bus unit reruns the cycle
        // itself and does not acknowledge (UM 5.4.2).
        req_ack <= !term_retry;
        req_end <= end_code;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Falling-edge bookkeeping: sampling the termination signals, latching read
  // data, and the M6800 synchronisation.
  // ---------------------------------------------------------------------------
  logic samp_edge;   // this falling edge is a termination sampling point
  assign samp_edge = (st_p == rd68011_pkg::ST_S4)  || (st_p == rd68011_pkg::ST_WH) ||
                     (st_p == rd68011_pkg::ST_S16) || (st_p == rd68011_pkg::ST_WH2);

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_n           <= rd68011_pkg::ST_IDLE;
      term_berr      <= 1'b0;
      term_berr_late <= 1'b0;
      term_halt    <= 1'b0;
      term_retry   <= 1'b0;
      term_vpa     <= 1'b0;
      vma_asserted <= 1'b0;
      req_rdata    <= '0;
      end_code     <= rd68011_pkg::CE_NONE;
    end else begin
      st_n <= st_n_nxt;

      // Clear the per-cycle flags as the cycle begins (S0 -> S1).
      if (st_p == rd68011_pkg::ST_S0) begin
        term_berr      <= 1'b0;
        term_berr_late <= 1'b0;
        term_halt    <= 1'b0;
        term_retry   <= 1'b0;
        term_vpa     <= 1'b0;
        vma_asserted <= 1'b0;
        end_code     <= rd68011_pkg::CE_NONE;
      end

      if (samp_edge) begin
        // UM table 5-1, sampled together so simultaneous assertions are seen in
        // the same bus state.
        if (samp_retry) begin
          term_retry <= 1'b1;
          end_code   <= rd68011_pkg::CE_RERUN;
        end else if (samp_berr) begin
          term_berr  <= 1'b1;
          end_code   <= rd68011_pkg::CE_BERR;
        end else if (dtack_a) begin
          term_halt  <= halt_a;                   // case 2: terminate, then halt
          end_code   <= rd68011_pkg::CE_DTACK;
        end else if (samp_vpa) begin
          term_vpa   <= 1'b1;
          end_code   <= (cyc_kind == rd68011_pkg::CT_IACK)
                          ? rd68011_pkg::CE_AVEC : rd68011_pkg::CE_VPA;
        end

      end

      // Appendix B: once VPA is recognised, wait for E low with at least three
      // clocks before it rises, then assert VMA.
      if (vma_set) begin
        vma_asserted <= 1'b1;
      end

      // UM 5.1.1: read data is latched on the falling edge of S6. The same edge
      // carries the MC68010's late bus error window -- BERR asserted one clock
      // after DTACK was recognised (UM 5.4.1, table 5-1 cases 4 and 6).
      if (st_p == rd68011_pkg::ST_S6) begin
        req_rdata <= d_i;
        if (berr_a && (end_code == rd68011_pkg::CE_DTACK)) begin
          if (halt_a && !cyc_is_rmw) begin
            term_retry <= 1'b1;
            end_code   <= rd68011_pkg::CE_RERUN;
          end else begin
            end_code       <= rd68011_pkg::CE_BERR;
            // The sequencer acts on req_fault and never on req_end, which is a
            // clock later than the microword can use, so recording the fault in
            // end_code alone would report it to nobody.
            term_berr_late <= 1'b1;
            // Late BERR does not extend the cycle to S9: the transfer already
            // terminated normally, and figure 5-26 shows stacking beginning
            // straight after S7. That is why this is not term_berr.
          end
        end
      end
    end
  end

  // ===========================================================================
  // Bus arbitration (UM 5.2, 5.3, figure 5-18)
  //
  // BG is asserted on a rising edge once BR is valid internally, which puts
  // BR-asserted to BG-asserted at 1.5 clocks minimum -- specification 35. The
  // buses are released once AS is negated (figure 5-18 note 2), held while
  // BGACK is asserted, and re-driven 1.5 clocks after BGACK is negated, which
  // satisfies specifications 57 and 57A.
  //
  // Figure 5-18 note 1: the arbitration state machine does not advance while
  // the bus is in S0 or S1, which delays BG by one rising edge (figure 5-21).
  // ===========================================================================
  typedef enum logic [1:0] {
    ARB_IDLE   = 2'd0,
    ARB_GRANT  = 2'd1,   // BG asserted, waiting for BGACK or for BR to go away
    ARB_ACK    = 2'd2,   // BGACK asserted, BG negated, buses released
    ARB_RESUME = 2'd3    // BGACK gone, taking the buses back
  } arb_state_e;

  arb_state_e arb_st;
  arb_state_e arb_st_nxt;
  logic       arb_freeze;

  // S0 and S1 are the two states of a cycle in which AS has not been asserted
  // yet, so `arb_bus_released_nxt` -- which reads AS to know whether a cycle is
  // in flight -- cannot tell them from an idle bus. Freezing the arbitration
  // state across them is what stops a request arriving there from handing the
  // buses away in the middle of the cycle that has just begun.
  //
  // The freeze runs from the rising edge entering S0 to the falling edge
  // entering S3, because `st_n` is still ST_S1 through the first half of S2 --
  // and AS is asserted at the rising edge entering S2. There is no gap.
  //
  // The freeze is not by itself enough. It stops the arbiter *changing* state
  // during S0 and S1, but says nothing about it already being in ARB_GRANT when
  // S0 begins -- and the rising edge that ends S7 both starts the next cycle and
  // lets ARB_IDLE go to ARB_GRANT, so a cycle could start with the buses about
  // to be released and lose every output enable a clock later, with AS and the
  // strobes still asserted. What closes that is the state machine deciding from
  // `arb_bus_released_nxt`, the same signal the output enables are registered
  // from, so a cycle can never start on an edge that hands the buses over.
  // sim/tb/core_arb_tb.sv sweeps the grant across a longword read, which is the
  // shortest thing that shows it.
  assign arb_freeze = (st_p == rd68011_pkg::ST_S0) || (st_n == rd68011_pkg::ST_S1);

  always_comb begin
    arb_st_nxt = arb_st;
    if (!arb_freeze) begin
      unique case (arb_st)
        ARB_IDLE:   if (!br_n_s)      arb_st_nxt = ARB_GRANT;
        ARB_GRANT:  if (!bgack_n_s)   arb_st_nxt = ARB_ACK;
                    else if (br_n_s)  arb_st_nxt = ARB_RESUME;
        ARB_ACK:    if (bgack_n_s)    arb_st_nxt = ARB_RESUME;
        ARB_RESUME:                   arb_st_nxt = ARB_IDLE;
        default:                      arb_st_nxt = ARB_IDLE;
      endcase
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) arb_st <= ARB_IDLE;
    else        arb_st <= arb_st_nxt;
  end

  assign bg_n_o = ~(arb_st == ARB_GRANT);

  // The buses go to the alternate master once the grant is out and AS has been
  // negated (figure 5-18 note 2), and stay there until the acknowledge is gone.
  //
  // Built from the NEXT arbitration state, so it says what will be true after
  // the coming rising edge. UM 5.3: "State changes (valid outputs) occur on the
  // next rising edge of the clock after the internal signal is valid." Building
  // it from the current state instead would cost an extra clock at both ends of
  // the handover -- still inside specifications 57 and 57A, which have no
  // maximum, but slower than the part.
  //
  // Everything it is made of is a register, so a next-state signal is safe to
  // feed the bus state machine's own next state: there is no loop to close.
  // That is what lets `st_p` be ST_ARB on exactly the clocks the output enables
  // are off, rather than on a set of clocks that nearly matches.
  assign arb_bus_released_nxt = ((arb_st_nxt == ARB_GRANT) && as_n_o) ||
                                 (arb_st_nxt == ARB_ACK);

  // Do not begin a cycle while arbitration is in progress.
  assign arb_hold = (arb_st != ARB_IDLE);

  // ===========================================================================
  // RESET instruction output (UM 5.5): assert RESET for 124 clock periods
  // without disturbing any internal state.
  // ===========================================================================
  logic [7:0] reset_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reset_cnt  <= 8'd0;
      reset_busy <= 1'b0;
    end else if (reset_busy) begin
      if (reset_cnt == 8'd123) begin
        reset_busy <= 1'b0;
        reset_cnt  <= 8'd0;
      end else begin
        reset_cnt <= reset_cnt + 8'd1;
      end
    end else if (reset_req) begin
      reset_busy <= 1'b1;
      reset_cnt  <= 8'd0;
    end
  end

  assign reset_n_o  = 1'b0;          // open drain: only ever pulls low
  assign reset_n_oe = reset_busy;

  // Double bus fault drives HALT out until an external reset (UM 5.4.4).
  assign halt_n_o  = 1'b0;
  assign halt_n_oe = dbf;

  // ===========================================================================
  // Pin outputs
  // ===========================================================================

  // -- Function code: valid from S0 (spec 6A, clock high to FC valid) ---------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               fc_o <= rd68011_pkg::FC_SUPER_P;
    else if (`ENTER_P(ST_S0)) fc_o <= start_new ? req_fc : cyc_fc;
  end

  // -- Address: valid entering S1 (spec 6, clock low to address valid) --------
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n)             a_o <= '0;
    else if (`ENTER_N(ST_S1)) a_o <= cyc_addr;
  end

  // -- R/W: high in S0, low on the rising edge of S2 for a write, low on the
  //    rising edge of S14 for the write half of a read-modify-write, and back
  //    high at the rising edge ending the cycle (specs 18, 20).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                                     rw_o <= 1'b1;
    else if (`ENTER_P(ST_S0))                       rw_o <= 1'b1;
    else if (`ENTER_P(ST_S2)  && cyc_is_write)      rw_o <= 1'b0;
    else if (`ENTER_P(ST_S14))                      rw_o <= 1'b0;
    else if (`ENTER_P(ST_IDLE) || `ENTER_P(ST_HALT) ||
             `ENTER_P(ST_ARB) || `ENTER_P(ST_RETRY)) rw_o <= 1'b1;
  end

  // -- Write data: driven during S3, and during S15 for the write half of a
  //    read-modify-write (spec 23, clock low to data-out valid).
  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n)                                       d_o <= '0;
    else if (`ENTER_N(ST_S3) && cyc_is_write)         d_o <= req_wdata;
    else if (`ENTER_N(ST_S15))                        d_o <= req_wdata;
  end

  // -- AS: asserted on the rising edge of S2, negated on the falling edge
  //    entering S7 -- or entering S19 for a read-modify-write, which holds AS
  //    across the whole indivisible cycle (UM 5.1.3).
  logic as_set_p, as_clr_n, as_q;

  assign as_set_p = `ENTER_P(ST_S2);
  assign as_clr_n = (`ENTER_N(ST_S7) && !cyc_is_rmw) || `ENTER_N(ST_S19);

  rd68011_dedge_ff u_as (
      .clk (clk), .rst_n (rst_n),
      .en_p (as_set_p), .d_p (1'b1),
      .en_n (as_clr_n), .d_n (1'b0),
      .q    (as_q)
  );
  assign as_n_o = ~as_q;

  // -- Data strobes: a read asserts them with AS on the rising edge of S2; a
  //    write asserts them one clock later, on the rising edge of S4 (UM 5.1.1,
  //    5.1.2). The write half of a read-modify-write asserts them at S16.
  //    All of them negate on the falling edge entering S7 or S19.
  logic ds_set_p, ds_clr_n;
  logic uds_q, lds_q;

  assign ds_set_p = (`ENTER_P(ST_S2) && !cyc_is_write) ||
                    (`ENTER_P(ST_S4) &&  cyc_is_write) ||
                     `ENTER_P(ST_S16);
  assign ds_clr_n = `ENTER_N(ST_S7) || `ENTER_N(ST_S19);

  rd68011_dedge_ff u_uds (
      .clk (clk), .rst_n (rst_n),
      .en_p (ds_set_p), .d_p (cyc_uds),
      .en_n (ds_clr_n), .d_n (1'b0),
      .q    (uds_q)
  );
  rd68011_dedge_ff u_lds (
      .clk (clk), .rst_n (rst_n),
      .en_p (ds_set_p), .d_p (cyc_lds),
      .en_n (ds_clr_n), .d_n (1'b0),
      .q    (lds_q)
  );
  assign uds_n_o = ~uds_q;
  assign lds_n_o = ~lds_q;

  // -- Data bus drive: out of high impedance during S3 (or S15), back to high
  //    impedance at the rising edge that ends S7 (or S19) -- spec 7.
  logic doe_set_n, doe_clr_p;

  assign doe_set_n = (`ENTER_N(ST_S3) && cyc_is_write) || `ENTER_N(ST_S15);
  assign doe_clr_p = (st_n == rd68011_pkg::ST_S7) || (st_n == rd68011_pkg::ST_S19) ||
                     (st_n == rd68011_pkg::ST_BE9) || (st_n == rd68011_pkg::ST_BE21);

  logic doe_q;

  rd68011_dedge_ff u_doe (
      .clk (clk), .rst_n (rst_n),
      .en_p (doe_clr_p), .d_p (1'b0),
      .en_n (doe_set_n), .d_n (1'b1),
      .q    (doe_q)
  );

  // -- Address bus drive: out of high impedance entering S1, with the address
  //    itself (spec 6), and back to high impedance at the rising edge that
  //    ends the cycle (spec 7). Between cycles and through S0 the address bus
  //    is not driven at all, which is what appendix B says outright.
  //    The clear term is the data bus's, minus the S7 a read-modify-write
  //    passes through on its way to the modify states: AS is held across that
  //    whole cycle (UM 5.1.3) and so is the address. The data bus does not
  //    care -- it is not driven there either way -- so it keeps the simpler
  //    condition.
  logic aoe_set_n, aoe_clr_p, aoe_q;

  assign aoe_set_n = `ENTER_N(ST_S1);
  assign aoe_clr_p = ((st_n == rd68011_pkg::ST_S7) &&
                      (st_p_nxt != rd68011_pkg::ST_M8)) ||
                     (st_n == rd68011_pkg::ST_S19) ||
                     (st_n == rd68011_pkg::ST_BE9) ||
                     (st_n == rd68011_pkg::ST_BE21);

  rd68011_dedge_ff u_aoe (
      .clk (clk), .rst_n (rst_n),
      .en_p (aoe_clr_p), .d_p (1'b0),
      .en_n (aoe_set_n), .d_n (1'b1),
      .q    (aoe_q)
  );

  // Whether the bus belongs to someone else. Declared here rather than with the
  // output enables below, which are its main use, because d_oe reads it too and
  // a name has to be declared before it is used (doc/coding-standard.md).
  assign bus_granted = arb_bus_released_nxt;

  // Table 3-4 again: the data bus is also released while RESET is asserted and
  // while the bus belongs to someone else.
  assign d_oe = doe_q && reset_sync_n && !bus_granted;

  // -- VMA: asserted once the cycle is synchronised with E, negated entering
  //    S7 (appendix B). Falling-edge domain throughout.
  // Not for an autovectored interrupt acknowledge: there is no transfer to
  // synchronise, and appendix B's own warning about an unintended access to the
  // device is reason enough not to strobe one. See samp_done above.
  assign vma_set = samp_edge && (term_vpa || samp_vpa) && !vma_asserted &&
                   !e_o && e_vma_window && !cyc_is_iack;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n)                vma_n_o <= 1'b1;
    else if (`ENTER_N(ST_S7))  vma_n_o <= 1'b1;
    else if (vma_set)          vma_n_o <= 1'b0;
  end

  // -- Output enables. Table 3-4 gives three behaviours: the address and data
  //    buses go to high impedance on RESET as well as on bus relinquish, the
  //    control group only on bus relinquish, and RESET/HALT are open drain.
  logic a_oe_hold;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_oe_hold <= 1'b0;
      as_oe <= 1'b0;
      rw_oe <= 1'b0;
      ds_oe <= 1'b0;
      fc_oe <= 1'b0;
      vma_oe <= 1'b0;
    end else begin
      // Halted or granted away: everything the alternate master needs.
      as_oe  <= !bus_granted;
      rw_oe  <= !bus_granted;
      ds_oe  <= !bus_granted;
      fc_oe  <= !bus_granted;
      vma_oe <= !bus_granted;
      // Table 3-4: the address bus is the one output that also goes to high
      // impedance while the RESET pin is asserted, and while halted (UM 5.4.3).
      // UM 5.4.2: a retry also "puts the address and data lines in the
      // high-impedance state" until HALT is negated.
      a_oe_hold <= !bus_granted && reset_sync_n &&
                   !(st_p == rd68011_pkg::ST_HALT) &&
                   !(st_p == rd68011_pkg::ST_RETRY);
    end
  end

  // Those four conditions last whole clocks, so they are registered on the
  // rising edge like the rest of the enables. The end of a cycle does not: the
  // address is released half a clock before the next one drives it, so that
  // half comes from the dual-edge flop above.
  assign a_oe = a_oe_hold && (aoe_q || !ADDR_HIZ_BETWEEN_CYCLES);

  assign bus_idle = (st_p == rd68011_pkg::ST_IDLE) && !arb_hold;

  `undef ENTER_P
  `undef ENTER_N

endmodule
