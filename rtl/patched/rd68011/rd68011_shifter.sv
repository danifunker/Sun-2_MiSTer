// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
//
// PATCHED COPY of rtl/vendor/rd68011/rd68011_shifter.sv (upstream f768c7f),
// carried until upstream takes the change; files.qip builds this one instead.
// The only difference is how the two rotate counts reduce, below: upstream
// writes `count % w` and `count % (w + 1)`, and with `w` a signal Quartus
// builds a general divider for each.  That divider was the longest path in
// the MiSTer core -- microcode ROM to u_biu.d_o, a half-period path -- and
// missed cpu_clk at 20 MHz.  The replacements are exact for every count and
// size; tb/verilator/tb_shifter_equiv checks this copy against upstream's for
// every control input.  See rtl/patched/README.md.
//
// RD68011 - shifter for ASL/ASR, LSL/LSR, ROL/ROR and ROXL/ROXR.
//
// PRM section 4 defines eight operations that differ only in what is shifted
// in and what the condition codes take from the operation. This does all of
// them in one step rather than one bit per clock as the original does: the
// architectural state and the bus behaviour are identical either way, and only
// the cycle count differs -- which doc/timing-divergences.md records.
//
// C is "the last bit shifted out of the operand" in every case, and a count of
// zero clears it -- except for ROXL/ROXR, where a count of zero leaves C equal
// to X. The plain shifts get that for free by placing the operand in a 64-bit
// word with room on the side the bits leave from, so the bit that left last is
// still there to be read afterwards.
//
// V is set only by ASL, and only when the sign changed at any point during the
// shift, which is to say when the top count+1 bits were not all the same.
//
// X follows C wherever the operation writes X at all; `x_upd` says whether it
// does. ROL and ROR never do, and neither does any operation with a zero count.

module rd68011_shifter (
    input  logic  [2:0] sh,      // {kind[1:0], left}: 0 AS, 1 LS, 2 ROX, 3 RO
    input  logic  [1:0] size,    // 0 byte, 1 word, 2 long
    input  logic  [5:0] count,
    input  logic [31:0] din,
    input  logic        x_in,
    output logic [31:0] dout,
    output logic        c_out,
    output logic        v_out,
    output logic        x_upd
);

  localparam logic [1:0] K_AS  = 2'd0;
  localparam logic [1:0] K_LS  = 2'd1;
  localparam logic [1:0] K_ROX = 2'd2;
  localparam logic [1:0] K_RO  = 2'd3;

  logic [1:0] kind;
  logic       left;
  assign kind = sh[2:1];
  assign left = sh[0];

  // -- The operand at its own width -------------------------------------------
  logic [5:0]  w;
  logic [31:0] mask;
  logic [31:0] v;         // zero-extended to 32 bits
  logic [31:0] vs;        // sign-extended to 32 bits
  logic        sign;

  always_comb begin
    unique case (size)
      2'd0:    begin w = 6'd8;  mask = 32'h0000_00FF; end
      2'd1:    begin w = 6'd16; mask = 32'h0000_FFFF; end
      default: begin w = 6'd32; mask = 32'hFFFF_FFFF; end
    endcase
  end

  // The operand's top bit, as a five-bit index: a 32-bit width wraps to 31,
  // which is exactly the position wanted.
  logic [4:0] topbit;
  assign topbit = w[4:0] - 5'd1;

  assign v    = din & mask;
  assign sign = v[topbit];
  assign vs   = sign ? (v | ~mask) : v;

  // -- Left shift -------------------------------------------------------------
  // The operand sits in the low half, so a bit leaving the top of the field
  // lands at position w and survives to be read as the carry. Right shifts go
  // through the shared barrel below.
  logic [63:0] lsh;

  assign lsh   = {32'd0, v} << count;


  // -- Rotates ----------------------------------------------------------------
  // Doubling the operand turns a rotate into a shift: rotating w bits right by
  // k takes bits [k+w-1 : k] of the doubled value, and rotating left by k is
  // the same as rotating right by w-k.
  logic [63:0] dd;
  logic  [5:0] rk, rsh_amt;

  // w is a power of two, so the count modulo w is the count's low bits.
  always_comb begin
    unique case (size)
      2'd0:    dd = {48'd0, v[7:0],  v[7:0]};
      2'd1:    dd = {32'd0, v[15:0], v[15:0]};
      default: dd = {v, v};
    endcase
    rk      = count & (w - 6'd1);
    rsh_amt = left ? (w - rk) : rk;
  end

  // -- Rotate through the extend bit -----------------------------------------
  // Here the operand is w+1 bits wide, X being the extra one, so the count
  // reduces modulo w+1 and the doubled value is 2(w+1) bits.
  logic [32:0]  xext;
  logic [71:0]  xdd;
  logic  [5:0]  xk, xsh_amt;

  // X sits immediately above the operand, at bit w -- not at bit 32. For a
  // byte operand the rotated value is nine bits, not thirty-three.
  assign xext = ({32'd0, x_in} << w) | {1'b0, v};

  // The count is below 64 and w+1 is 9, 17 or 33, so the quotient is at most
  // seven, three or one: each candidate remainder is formed side by side and
  // comparisons against constants pick the right one.
  always_comb begin
    xdd     = {39'd0, xext} | ({39'd0, xext} << (w + 6'd1));
    unique case (size)
      2'd0:    xk = (count >= 6'd63) ? count - 6'd63 :
                    (count >= 6'd54) ? count - 6'd54 :
                    (count >= 6'd45) ? count - 6'd45 :
                    (count >= 6'd36) ? count - 6'd36 :
                    (count >= 6'd27) ? count - 6'd27 :
                    (count >= 6'd18) ? count - 6'd18 :
                    (count >= 6'd9)  ? count - 6'd9  : count;
      2'd1:    xk = (count >= 6'd51) ? count - 6'd51 :
                    (count >= 6'd34) ? count - 6'd34 :
                    (count >= 6'd17) ? count - 6'd17 : count;
      default: xk = (count >= 6'd33) ? count - 6'd33 : count;
    endcase
    xsh_amt = left ? ((w + 6'd1) - xk) : xk;
  end

  // One barrel for all four of the kinds that shift right -- logical,
  // arithmetic, rotate and rotate-through-X. They differ only in what goes in
  // and by how much, so a multiplexer in front of one shifter is far cheaper
  // than four shifters, and holds `din`'s fan-out down as well.
  // doc/size-and-speed.md measures both.
  //
  // The plain shifts sit at bits 39:8 with 32 fill bits above and eight below,
  // so that out[39:8] is the result and out[7] is the bit that fell off the
  // end -- the carry. Filling with the sign is what makes the arithmetic shift
  // arithmetic, so no separate `>>>` is needed.
  //
  // The amount saturates at 32 because the operand is never wider, and two
  // carries need saying explicitly afterwards: past 32 places a 32-bit operand
  // has gone entirely, and a shifter told to stop at 32 still reports the bit
  // that left at 32. Narrower operands need no such thing -- v is zero-extended
  // and vs sign-extended, so the bit the barrel finds there is already right.
  logic [71:0] sh_in, sh_out;
  logic  [5:0] sh_amt;
  logic        fill;

  assign fill = (kind == K_AS) && sign;

  always_comb begin
    unique case (kind)
      K_RO:    begin sh_in = {8'd0, dd};                  sh_amt = rsh_amt; end
      K_ROX:   begin sh_in = xdd;                         sh_amt = xsh_amt; end
      default: begin sh_in = {{32{fill}}, (fill ? vs : v), 8'd0};
                     sh_amt = (count > 6'd32) ? 6'd32 : count; end
    endcase
    sh_out = sh_in >> sh_amt;
  end

  logic [31:0] rsh;      // the plain right shift, either kind
  logic        rsh_c;    // and the bit that left the operand

  assign rsh   = sh_out[39:8];
  assign rsh_c = sh_out[7];

  // -- The overflow flag of an arithmetic left shift --------------------------
  // Set when the sign changed at any point during the shift, which is to say
  // when the top count+1 bits of the operand were not all equal. A mask of
  // those bits says so without a loop -- and without a loop variable, which
  // yosys turns into a latch.
  logic [31:0] vmask;
  logic [31:0] vbits;

  always_comb begin
    if (count >= w) vmask = mask;
    else            vmask = mask & ~((32'd1 << (w - count - 6'd1)) - 32'd1);
    vbits = v & vmask;
  end

  // -- Result and flags -------------------------------------------------------
  logic [31:0] res;
  logic        c, vf, xu;

  always_comb begin
    res = v;
    c   = 1'b0;
    vf  = 1'b0;
    xu  = 1'b0;

    unique case (kind)
      K_AS: begin
        if (left) begin
          res = lsh[31:0] & mask;
          c   = lsh[w];
          // The sign changed at some point unless the top count+1 bits of the
          // operand were all equal to it.
          if (count != 6'd0) begin
            vf = (vbits != 32'd0) && (vbits != vmask);
          end
        end else begin
          res = rsh & mask;
          c   = rsh_c;
        end
        xu = (count != 6'd0);
      end

      K_LS: begin
        if (left) begin
          res = lsh[31:0] & mask;
          c   = lsh[w];
        end else begin
          res = rsh & mask;
          // Past 32 places a 32-bit operand has gone entirely and nothing is
          // left to be the carry. The barrel stopped at 32 and is still
          // reporting the bit that left there.
          c   = (count > 6'd32) ? 1'b0 : rsh_c;
        end
        xu = (count != 6'd0);
      end

      K_RO: begin
        res = sh_out[31:0] & mask;
        if (count == 6'd0) begin
          res = v;
          c   = 1'b0;
        end else begin
          // The last bit out of a left rotate is the one that wrapped into
          // bit 0; of a right rotate, the one that wrapped into the top.
          c = left ? res[0] : res[topbit];
        end
      end

      K_ROX: begin
        res = sh_out[31:0] & mask;
        if (count == 6'd0) begin
          res = v;
          c   = x_in;          // C takes X, and X itself is left alone
        end else begin
          c  = sh_out[{1'b0, w}];
          xu = 1'b1;
        end
      end

      default: begin
        res = v;
      end
    endcase
  end

  // The barrel is as wide as the widest thing put through it -- the doubled
  // operand a rotate-through-X needs -- and every kind reads its own slice of
  // the result, so the rest is deliberately unread.
  logic unused;
  assign unused = &{1'b1, sh_out[71:40], sh_out[6:0], lsh[63:33]};

  assign dout  = res;
  assign c_out = c;
  assign v_out = vf;
  assign x_upd = xu;

endmodule
