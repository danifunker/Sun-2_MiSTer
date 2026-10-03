# The shifter's two `%` become dividers, and sit on the core's longest path

Files implicated: `rtl/rd68011_shifter.sv`, lines 92 and 109 at `f768c7f`:

```systemverilog
rk      = (count % w);
...
xk      = count % (w + 6'd1);
```

Observed against RD68011 `f768c7f` (logic identical to `04cd25b`) in the
Sun-2/160 MiSTer core, Cyclone V 5CSEBA6U23I7, Quartus Prime Lite 17.0.2, at
20 MHz with a 52/48 clock.

**What happens.** `w` is a signal (8, 16 or 32 by `size`), so both
operators synthesise as general dividers (`u_shifter|Mod0|...|divider`, three
chained carry stages). That divider is on the critical path of the whole core:
microcode ROM -> `u_seq.u_urom` control decode -> the shift count -> the
divider -> the `w - rk` subtract -> the barrel -> `u_biu.d_o`. It is launched
on the rising edge and caught on the falling one, so it has half a period.
Measured, the worst path is 24.256 ns of data against a 26.000 ns
relationship with -1.688 ns of skew: slack -0.024 ns. The divider stages alone
are about 5.5 ns of it, and the subtract after them about 1.7 ns. A second
placement seed made it -0.276 ns; a third had met it at +0.272 ns. Changing a
string in the MiSTer menu was enough to tip it, which is the sign of a path
whose logic is too long rather than badly placed.

**The fix is exact and small.** `w` is a power of two, so `count % w` is
`count & (w - 1)`. `count` is six bits and `w + 1` is 9, 17 or 33, so the
quotient is at most 7, 3 or 1, and every candidate remainder can be formed
side by side and picked by comparisons against constants:

```systemverilog
rk = count & (w - 6'd1);
...
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
```

Nothing else in the module changes.

**Checked.** An equivalence bench compares the patched module with the
upstream one on every combination of `sh` (8), `size` (4, including the
unused one), `count` (64) and `x_in` (2), each with ten edge-pattern operands
and 24 random ones: 139,264 comparisons of `dout`, `c_out`, `v_out` and
`x_upd`, none different. Two mutations of the patch (one mod-9 threshold off
by one; the ROL/ROR mask one bit short) fail it with 1,278 and 15,984
differences, so the bench would see a wrong reduction.

The MiSTer core carries the patched file as `rtl/patched/rd68011/
rd68011_shifter.sv` until upstream has the change; the bench is
`tb/verilator/tb_shifter_equiv.sv`.
