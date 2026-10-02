// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - SystemVerilog MC68010
//
// Shared types and constants.
//
// References are to the split Motorola manuals under
// Inputs/doc/MC68030_Doc_More_Readable/ :
//   UM  = MC68000UM_split  (M68000 8-/16-/32-Bit Microprocessors User's Manual)
//   PRM = M68000PRM_split  (M68000 Family Programmer's Reference Manual)

`ifndef RD68011_PKG_SV
`define RD68011_PKG_SV

package rd68011_pkg;

  // ---------------------------------------------------------------------------
  // Function codes -- UM Table 3-3
  // ---------------------------------------------------------------------------
  localparam logic [2:0] FC_UNDEF0   = 3'b000;
  localparam logic [2:0] FC_USER_D   = 3'b001;
  localparam logic [2:0] FC_USER_P   = 3'b010;
  localparam logic [2:0] FC_UNDEF3   = 3'b011;
  localparam logic [2:0] FC_UNDEF4   = 3'b100;
  localparam logic [2:0] FC_SUPER_D  = 3'b101;
  localparam logic [2:0] FC_SUPER_P  = 3'b110;
  localparam logic [2:0] FC_CPU      = 3'b111;

  // ---------------------------------------------------------------------------
  // Bus states -- UM section 5, keeping the manual's own state names.
  //
  // One state per CLK half period. Even-numbered states begin on a rising edge
  // and odd-numbered ones on a falling edge: UM 5.1.1 has the processor
  // asserting AS "on the rising edge of S2" and driving the address "entering
  // S1", and figure 10-4's recovered state ruler puts t=0 at the S0 rising edge.
  //
  // A minimum-length asynchronous cycle is S0..S7, four clocks. Wait states are
  // inserted as (low, high) pairs between S4 and S5 until DTACK, BERR or VPA is
  // recognised on a falling edge. A cycle terminated by BERR alone runs one
  // clock longer, to S9 (UM 5.1.1 note, 5.4.1).
  //
  // Read-modify-write keeps AS asserted across S0..S19: read in S0..S7, four
  // states of internal modification in S8..S11, write in S12..S19, with the
  // bus-error extension at S21 (UM 5.1.3, 5.4.1).
  //
  // ST_IDLE, ST_HALT, ST_ARB and ST_RETRY are not manual state names; they are
  // the between-cycle conditions of UM 5.4.3, 5.2 and 5.4.2.
  // ---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    ST_IDLE  = 5'd0,
    ST_S0    = 5'd1,
    ST_S1    = 5'd2,
    ST_S2    = 5'd3,
    ST_S3    = 5'd4,
    ST_S4    = 5'd5,
    ST_WL    = 5'd6,   // wait pair, low half
    ST_WH    = 5'd7,   // wait pair, high half; sampled on its falling edge
    ST_S5    = 5'd8,
    ST_S6    = 5'd9,
    ST_S7    = 5'd10,
    ST_BE8   = 5'd11,  // BERR without DTACK: cycle runs on to S9
    ST_BE9   = 5'd12,
    ST_M8    = 5'd13,  // read-modify-write internal modification, S8..S11
    ST_M9    = 5'd14,
    ST_M10   = 5'd15,
    ST_M11   = 5'd16,
    ST_S12   = 5'd17,  // read-modify-write, write portion
    ST_S13   = 5'd18,
    ST_S14   = 5'd19,
    ST_S15   = 5'd20,
    ST_S16   = 5'd21,
    ST_WL2   = 5'd22,  // wait pair in the write portion
    ST_WH2   = 5'd23,
    ST_S17   = 5'd24,
    ST_S18   = 5'd25,
    ST_S19   = 5'd26,
    ST_BE20  = 5'd27,  // RMW write BERR extension, terminates in S21
    ST_BE21  = 5'd28,
    ST_HALT  = 5'd29,  // halted by the HALT input (UM 5.4.3)
    ST_ARB   = 5'd30,  // bus relinquished to an external master (UM 5.2)
    ST_RETRY = 5'd31   // BERR+HALT: buses released, waiting for HALT (UM 5.4.2)
  } bus_state_e;

  // ---------------------------------------------------------------------------
  // Operand sizes
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    SZ_BYTE = 2'b00,
    SZ_WORD = 2'b01,
    SZ_LONG = 2'b10
  } opsize_e;

  // ---------------------------------------------------------------------------
  // Bus cycle kinds the sequencer can request of the bus interface.
  // ---------------------------------------------------------------------------
  // A read-modify-write is one request, not two: the bus unit runs the whole
  // indivisible S0..S19 sequence and the sequencer supplies the write data
  // during the four modify states (UM 5.1.3).
  typedef enum logic [2:0] {
    CT_READ  = 3'd0,
    CT_WRITE = 3'd1,
    CT_RMW   = 3'd2,  // TAS: read, modify, write, with AS held throughout
    CT_IACK  = 3'd3,  // interrupt acknowledge, CPU space
    CT_BKPT  = 3'd4   // breakpoint acknowledge, CPU space -- MC68010 only
  } cycle_kind_e;

  // How a bus cycle ended.
  typedef enum logic [2:0] {
    CE_NONE    = 3'd0,  // still running
    CE_DTACK   = 3'd1,  // normal termination
    CE_BERR    = 3'd2,  // bus error -> exception
    CE_RERUN   = 3'd3,  // BERR + HALT -> retry the cycle
    CE_VPA     = 3'd4,  // M6800 synchronous termination / autovector
    CE_AVEC    = 3'd5   // autovector during interrupt acknowledge
  } cycle_end_e;

  // ---------------------------------------------------------------------------
  // Status register bit positions -- PRM section 1
  // ---------------------------------------------------------------------------
  localparam int SR_C  = 0;
  localparam int SR_V  = 1;
  localparam int SR_Z  = 2;
  localparam int SR_N  = 3;
  localparam int SR_X  = 4;
  localparam int SR_I0 = 8;
  localparam int SR_S  = 13;
  localparam int SR_T  = 15;   // MC68010 has a single trace bit (T0/T1 is 68020+)

  localparam logic [15:0] SR_IMPLEMENTED = 16'b1010_0111_0001_1111;

  // ---------------------------------------------------------------------------
  // The format $8 frame's processor version number -- UM 6.4
  //
  // "This word contains a processor version number (in bits 10-13) and
  // proprietary internal information that must match the version number of the
  // MC68010 attempting to read the data. [...] If the version number is
  // incorrect for this processor, the RTE instruction is aborted and exception
  // processing begins for a format error exception."
  //
  // So the sixteen internal words are private to an implementation, and the
  // architecture's own mechanism for saying so is this number. RD68011 uses
  // its own, and refuses any frame that does not carry it -- which is exactly
  // what the manual prescribes, and what makes doc/checkpoint.md's encoding
  // legitimate rather than a divergence.
  localparam logic [3:0] FRAME_VERSION = 4'hB;   // "RD68011"

  // The long frame: 29 words of stack, of which 26 are written (UM figure 6-8).
  localparam int FRAME_LONG_BYTES = 58;
  // Where the version word sits within it.
  localparam int FRAME_VERSION_OFF = 26;

  // ---------------------------------------------------------------------------
  // Exception vector numbers -- UM Table 6-2 / PRM Appendix B
  // ---------------------------------------------------------------------------
  localparam logic [7:0] VEC_RESET_SP    = 8'd0;
  localparam logic [7:0] VEC_RESET_PC    = 8'd1;
  localparam logic [7:0] VEC_BUS_ERROR   = 8'd2;
  localparam logic [7:0] VEC_ADDR_ERROR  = 8'd3;
  localparam logic [7:0] VEC_ILLEGAL     = 8'd4;
  localparam logic [7:0] VEC_ZERO_DIV    = 8'd5;
  localparam logic [7:0] VEC_CHK         = 8'd6;
  localparam logic [7:0] VEC_TRAPV       = 8'd7;
  localparam logic [7:0] VEC_PRIVILEGE   = 8'd8;
  localparam logic [7:0] VEC_TRACE       = 8'd9;
  localparam logic [7:0] VEC_LINE_A      = 8'd10;
  localparam logic [7:0] VEC_LINE_F      = 8'd11;
  localparam logic [7:0] VEC_FORMAT_ERR  = 8'd14;  // MC68010: RTE on a bad frame
  localparam logic [7:0] VEC_UNINIT_IRQ  = 8'd15;
  localparam logic [7:0] VEC_SPURIOUS    = 8'd24;
  localparam logic [7:0] VEC_AUTOVEC0    = 8'd24;  // autovector n is 24+n
  localparam logic [7:0] VEC_TRAP0       = 8'd32;

  // ---------------------------------------------------------------------------
  // Stack frame format codes -- UM section 6. The MC68010 defines two:
  // format 0 (four words) for everything except bus and address error, and
  // format 8 (twenty-nine words) for those two.
  // ---------------------------------------------------------------------------
  localparam logic [3:0] FRAME_SHORT = 4'h0;
  localparam logic [3:0] FRAME_FAULT = 4'h8;

  // ---------------------------------------------------------------------------
  // M6800 enable -- UM section 3.7: ten clock periods, six low then four high.
  // Specification 41 measures the E transition from CLK low, so E is generated
  // in the negative-edge domain and these are counted in whole clocks.
  // ---------------------------------------------------------------------------
  localparam logic [3:0] E_PERIOD_CLKS = 4'd10;
  localparam logic [3:0] E_LOW_CLKS    = 4'd6;

endpackage

`endif
