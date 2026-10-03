# Patched copies of vendored files

`rtl/vendor/` holds third-party RTL exactly as upstream has it, and is never
edited in place. When the build needs a change before upstream has taken it,
the changed file lives here, under the same name and directory as in
`rtl/vendor/`, and `files.qip` lists this copy instead. Each file says at its
top what it changes and why. When upstream takes the change, re-copy
`rtl/vendor/`, point `files.qip` back at it, and delete the file here.

| file | replaces | change | checked by |
|---|---|---|---|
| `rd68011/rd68011_shifter.sv` | `rtl/vendor/rd68011/rd68011_shifter.sv` at `f768c7f` | the rotate counts reduce without `%`: `count % w` (w = 8, 16, 32) is `count & (w - 1)`, and `count % (w + 1)` (9, 17, 33) is picked from candidate remainders by comparisons against constants | `make -C tb/verilator tb_shifter_equiv`: every shift kind, direction, size, count and X, against upstream's file |

**Why the shifter.** With `w` a signal, Quartus builds a general divider for
each `%`, and that divider sat on the core's longest path: the microcode ROM
through the shift-count decode, the divider and the barrel shifter to
`u_biu.d_o`, a path launched on the rising edge and caught on the falling one,
so it has half a 50 ns clock. It missed timing at 20 MHz by 24 ps with the
seed that had met it before, and by 276 ps with another; no amount of
re-placing fixes a path whose logic is too long.
