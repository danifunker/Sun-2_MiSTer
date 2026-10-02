// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// RD68011 - arithmetic and logic unit, with the condition codes.
//
// The operation and flag-rule encodings come from rd68011_ucode_pkg, which is
// generated from tools/ucode/isa.py, so adding an operation means adding it
// there and regenerating.
//
// SIZE
//
// The 68000 is a 32-bit machine with byte, word and long operations, and the
// condition codes are taken from the operated-on width, not from the full 32
// bits: a byte operation's N flag is bit 7 and its Z flag covers bits 7-0
// (PRM section 3). The result written back is likewise only as wide as the
// operation -- the upper bits of a data register survive a byte MOVE -- which
// is handled by the destination merge, not here.
//
// V AND C
//
// PRM's definitions, per operation:
//   ADD  V = Sm.Dm.!Rm + !Sm.!Dm.Rm      C = Sm.Dm + !Rm.Dm + Sm.!Rm
//   SUB  V = !Sm.Dm.!Rm + Sm.!Dm.Rm      C = Sm.!Dm + Rm.!Dm + Sm.Rm
// where S is the source, D the destination and R the result, m the most
// significant bit of the operation's size. CMP uses SUB's rules. The logical
// operations clear both.
//
// TWO PAIRS OF OPERANDS
//
// `a` and `b` may carry the data a bus cycle has just read; `a_op` and `b_op`
// are the same sources with that one left out. Only the operations the
// microprogram applies to read data take the first pair -- passing it, CAT,
// CAT8, SXW and OR, which is isa.READ_DATA_ALU -- and everything else,
// the adders and the decimal correction in particular, takes the second. The
// result multiplexer is where the two meet. rd68011_seq.sv says why.

module rd68011_alu (
    input  logic [rd68011_ucode_pkg::U_ALU_W-1:0]  op,
    input  logic [rd68011_ucode_pkg::U_SIZE_W-1:0] size,
    input  logic                            [31:0] a,      // source
    input  logic                            [31:0] b,      // destination
    input  logic                            [31:0] a_op,   // the same two,
    input  logic                            [31:0] b_op,   // without read data
    input  logic                                   x_in,   // the X flag
    output logic                            [31:0] y,
    output logic                                   n_out,
    output logic                                   z_out,
    output logic                                   v_out,
    output logic                                   c_out
);

  logic [32:0] sum;
  logic [32:0] dif;
  logic        is_byte, is_word;
  logic        sm, dm, rm;          // sign bits at the operation's width
  logic        carry;

  assign is_byte = (size == rd68011_ucode_pkg::U_SIZE_BYTE);
  assign is_word = (size == rd68011_ucode_pkg::U_SIZE_WORD);

  // The adders are always 32 bits wide; the flags are taken at the width the
  // operation actually used.
  assign sum = {1'b0, b_op} + {1'b0, a_op};
  assign dif = {1'b0, b_op} - {1'b0, a_op};

  // The extended forms carry X in and out, for multi-precision arithmetic.
  logic [32:0] sumx, difx;
  assign sumx = {1'b0, b_op} + {1'b0, a_op} + {32'd0, x_in};
  assign difx = {1'b0, b_op} - {1'b0, a_op} - {32'd0, x_in};

  // -- Binary-coded decimal --------------------------------------------------
  //
  // PRM section 4's ABCD, SBCD and NBCD. The part does not work digit by
  // digit: it adds or subtracts in binary and then corrects, which is why an
  // operand whose digits are not valid BCD comes out the way it does rather
  // than the way a digit-at-a-time model would predict. Both forms below are
  // settled against the reference vectors, 1088 of one and 1085 of the other.
  //
  // This sits above the operation mux because the mux reads bcd_add and
  // bcd_sub, and a name has to be declared before it is used: Vivado and
  // Questa reject the other order, and the remaining tools silently invent an
  // implicit net. See doc/coding-standard.md. (Do not start a comment line with
  // the word "Verilator" -- it reads one as a lint directive and fails to parse
  // it.)
  //
  // Addition: correct the low digit by six when it carried out of nine, and
  // the high digit by sixty when the *uncorrected* binary sum passed 0x99 or
  // overflowed a byte. Testing the uncorrected sum is the part that matters --
  // 0x1b + 0x7d + 1 comes to 0x99 exactly, which is not a carry, and testing
  // the corrected 0x9f would have made it one.
  logic [8:0] bcd_sum;
  logic [5:0] bcd_lo_sum;
  logic [8:0] bcd_add_adj;
  logic [7:0] bcd_add;
  logic       bcd_add_c;

  assign bcd_sum     = {1'b0, b_op[7:0]} + {1'b0, a_op[7:0]} + {8'd0, x_in};
  assign bcd_lo_sum  = {2'd0, b_op[3:0]} + {2'd0, a_op[3:0]} + {5'd0, x_in};
  assign bcd_add_c   = bcd_sum[8] || (bcd_sum[7:0] > 8'h99);
  assign bcd_add_adj = {3'd0, (bcd_lo_sum > 6'd9) ? 6'h06 : 6'h00} +
                       (bcd_add_c ? 9'h060 : 9'h000);
  assign bcd_add     = bcd_sum[7:0] + bcd_add_adj[7:0];

  // Subtraction: the same shape, with the corrections taken away instead of
  // added. The carry out is a borrow from either the binary subtraction or
  // from the correction itself -- 0xb2 minus 0xad borrows only once the six
  // comes off, and the reference says that still counts.
  logic [9:0] bcd_dif;
  logic       bcd_lo_borrow, bcd_hi_borrow;
  logic [9:0] bcd_sub_t;
  logic [7:0] bcd_sub;
  logic       bcd_sub_c;

  assign bcd_dif       = {2'b0, b_op[7:0]} - {2'b0, a_op[7:0]} - {9'd0, x_in};
  assign bcd_hi_borrow = bcd_dif[9] | bcd_dif[8];
  assign bcd_lo_borrow = ({2'd0, b_op[3:0]} - {2'd0, a_op[3:0]} - {5'd0, x_in}) > 6'd15
                         || (({1'b0, b_op[3:0]} < ({1'b0, a_op[3:0]} + {4'd0, x_in})));
  assign bcd_sub_t     = bcd_dif
                       - (bcd_lo_borrow ? 10'd6   : 10'd0)
                       - (bcd_hi_borrow ? 10'h060 : 10'h000);
  assign bcd_sub       = bcd_sub_t[7:0];
  assign bcd_sub_c     = bcd_hi_borrow || bcd_sub_t[9] || bcd_sub_t[8];

  always_comb begin
    unique case (op)
      rd68011_ucode_pkg::U_ALU_A:   y = a;
      rd68011_ucode_pkg::U_ALU_B:   y = b;
      rd68011_ucode_pkg::U_ALU_ADD: y = sum[31:0];
      rd68011_ucode_pkg::U_ALU_SUB: y = dif[31:0];
      rd68011_ucode_pkg::U_ALU_AND: y = a_op & b_op;
      rd68011_ucode_pkg::U_ALU_OR:  y = a | b;
      rd68011_ucode_pkg::U_ALU_EOR: y = a_op ^ b_op;
      rd68011_ucode_pkg::U_ALU_NOT: y = ~a_op;
      rd68011_ucode_pkg::U_ALU_CAT:  y = {a[15:0], b[15:0]};
      rd68011_ucode_pkg::U_ALU_SXW:  y = {{16{a[15]}}, a[15:0]};
      rd68011_ucode_pkg::U_ALU_SXB:  y = {{24{a_op[7]}},  a_op[7:0]};
      rd68011_ucode_pkg::U_ALU_SWAP: y = {a_op[15:0], a_op[31:16]};
      rd68011_ucode_pkg::U_ALU_NOTX: y = ~b_op;
      // MOVEP, which moves a register through alternate byte addresses,
      // high-order byte first (PRM section 4). Reading, a byte shifts in at
      // the bottom; writing, the byte wanted is brought down to where a byte
      // write takes it from.
      rd68011_ucode_pkg::U_ALU_CAT8:  y = {b[23:0], a[7:0]};
      rd68011_ucode_pkg::U_ALU_SHR8:  y = {8'd0,  a_op[31:8]};
      rd68011_ucode_pkg::U_ALU_SHR16: y = {16'd0, a_op[31:16]};
      rd68011_ucode_pkg::U_ALU_SHR24: y = {24'd0, a_op[31:24]};
      rd68011_ucode_pkg::U_ALU_ANDN: y = b_op & ~a_op;
      // MULU and MULS produce nothing here: the microword carrying them
      // starts rd68011_mul, and the microword after it reads the answer. See
      // that file for why the multiplier is not in this module.
      rd68011_ucode_pkg::U_ALU_ABCD: y = {b_op[31:8], bcd_add};
      rd68011_ucode_pkg::U_ALU_SBCD: y = {b_op[31:8], bcd_sub};
      rd68011_ucode_pkg::U_ALU_ADDX: y = sumx[31:0];
      rd68011_ucode_pkg::U_ALU_SUBX: y = difx[31:0];
      default:                      y = a;
    endcase
  end

  // Sign bits, and the carry out, at the operation's width. The carry is the
  // bit that falls off the top of the operation, which for a subtraction is
  // the borrow -- so both come out of one extra bit above the width, not out
  // of a comparison.
  logic  [8:0] sum_b, dif_b, sumx_b, difx_b;
  logic [16:0] sum_w, dif_w, sumx_w, difx_w;
  logic        xb;

  assign xb     = x_in;
  assign sum_b  = {1'b0, b_op[7:0]}  + {1'b0, a_op[7:0]};
  assign dif_b  = {1'b0, b_op[7:0]}  - {1'b0, a_op[7:0]};
  assign sumx_b = {1'b0, b_op[7:0]}  + {1'b0, a_op[7:0]}  + {8'd0, xb};
  assign difx_b = {1'b0, b_op[7:0]}  - {1'b0, a_op[7:0]}  - {8'd0, xb};
  assign sum_w  = {1'b0, b_op[15:0]} + {1'b0, a_op[15:0]};
  assign dif_w  = {1'b0, b_op[15:0]} - {1'b0, a_op[15:0]};
  assign sumx_w = {1'b0, b_op[15:0]} + {1'b0, a_op[15:0]} + {16'd0, xb};
  assign difx_w = {1'b0, b_op[15:0]} - {1'b0, a_op[15:0]} - {16'd0, xb};

  always_comb begin
    if (is_byte) begin
      sm    = a_op[7];
      dm    = b_op[7];
      rm    = y[7];
      unique case (op)
        rd68011_ucode_pkg::U_ALU_SUB:  carry = dif_b[8];
        rd68011_ucode_pkg::U_ALU_ADDX: carry = sumx_b[8];
        rd68011_ucode_pkg::U_ALU_SUBX: carry = difx_b[8];
        default:                       carry = sum_b[8];
      endcase
    end else if (is_word) begin
      sm    = a_op[15];
      dm    = b_op[15];
      rm    = y[15];
      unique case (op)
        rd68011_ucode_pkg::U_ALU_SUB:  carry = dif_w[16];
        rd68011_ucode_pkg::U_ALU_ADDX: carry = sumx_w[16];
        rd68011_ucode_pkg::U_ALU_SUBX: carry = difx_w[16];
        default:                       carry = sum_w[16];
      endcase
    end else begin
      sm    = a_op[31];
      dm    = b_op[31];
      rm    = y[31];
      unique case (op)
        rd68011_ucode_pkg::U_ALU_SUB:  carry = dif[32];
        rd68011_ucode_pkg::U_ALU_ADDX: carry = sumx[32];
        rd68011_ucode_pkg::U_ALU_SUBX: carry = difx[32];
        default:                       carry = sum[32];
      endcase
    end
  end

  assign n_out = rm;

  always_comb begin
    if (is_byte)      z_out = (y[7:0]  == 8'd0);
    else if (is_word) z_out = (y[15:0] == 16'd0);
    else              z_out = (y       == 32'd0);
  end

  always_comb begin
    unique case (op)
      rd68011_ucode_pkg::U_ALU_ADD,
      rd68011_ucode_pkg::U_ALU_ADDX: begin
        v_out = (sm && dm && !rm) || (!sm && !dm && rm);
        c_out = carry;
      end
      rd68011_ucode_pkg::U_ALU_SUBX,
      rd68011_ucode_pkg::U_ALU_SUB: begin
        v_out = (!sm && dm && !rm) || (sm && !dm && rm);
        c_out = carry;
      end
      // PRM leaves V undefined for all three decimal operations. What the
      // part actually does is report the overflow the decimal correction
      // introduced: a sum whose top bit the correction turned on, or a
      // difference whose top bit it turned off. Undefined is undefined, but
      // matching something real beats matching nothing.
      rd68011_ucode_pkg::U_ALU_ABCD: begin
        v_out = ~bcd_sum[7] & bcd_add[7];
        c_out = bcd_add_c;
      end
      rd68011_ucode_pkg::U_ALU_SBCD: begin
        v_out = bcd_dif[7] & ~bcd_sub[7];
        c_out = bcd_sub_c;
      end
      default: begin
        // The logical operations and the plain moves clear both (PRM
        // section 4, under each instruction's condition codes).
        v_out = 1'b0;
        c_out = 1'b0;
      end
    endcase
  end

  // X takes its value from C where an operation sets it at all; which
  // operations those are is the microcode's decision, through the flag rule.
  //
  // The low bits of the narrow adders are not used: the result comes from the
  // 32-bit adders, and these exist only for the bit that falls off the top.
  logic unused;
  assign unused = &{1'b1, sum_b[7:0], dif_b[7:0], sum_w[15:0], dif_w[15:0],
                    sumx_b[7:0], difx_b[7:0], sumx_w[15:0], difx_w[15:0],
                    bcd_add_adj[8]};

endmodule
