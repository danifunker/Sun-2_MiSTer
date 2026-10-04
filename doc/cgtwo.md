# The Sun-2 Color board (cgtwo), as the software drives it

The colour board for this machine is Sun's "Sun-2 Color" board, `cgtwo`,
`FBTYPE_SUN2COLOR`: 1152x900, 8 bits a pixel, a 256-entry colour map, on VME
A24 at 0x400000. Its raster-op ("rop") chips sit between the bus and the
memory, and SunOS depends on them. The kernel's probe will not accept a board
without them, and libpixrect pushes nearly everything SunView draws through
them.

**No manual for the board or its rop chips has been found.** Bitsavers has
none, and its Graphics Processor manuals describe the GP, not the board. TME
emulates two functions of one mode, which is enough for the probe and a
console but not for SunView. So this document **derives the hardware from the
software that drives it**. Every rule below cites that software. The rules
are encoded in a C model, [`tools/cg2model/cg2model.c`](../tools/cg2model/cg2model.c),
and the model is tested by running **Sun's own object code from the SunOS 4.0
Sun-2 tapes** against it, unmodified, in a 68010 emulator. The model, not
this prose, is the specification the RTL will be tested against. Where the
software never exercises a behaviour, this document says so rather than
guessing.

## Sources

| tag | what | where |
|---|---|---|
| [reg] | `pixrect/cg2reg.h`, `pixrect/memreg.h` | identical in 4.0 (tape 1 file 8, `/usr/include/pixrect`) and 4.1.4 apart from the SCCS line |
| [rop] | libpixrect `cg2_rop.c` | `calmsacibis995/sunos-414-src` `usr.lib/libpixrect/cg2/`; 4.0's is `cg2_rop.c 1.22 88/02/08` |
| [stn] [bat] [vec] [gp] [cm] | `cg2_stencil.c`, `cg2_batch.c`, `cg2_vec.c`, `cg2_getput.c` and `cg2_polypoint.c`, `cg2_colormap.c` | same directory |
| [pl] | the 1985 `cg2_polyline.c` and `cg2_bres.S` | `usr.lib/libpixrect/Attic/` |
| [k34] | `sys/sundev/cgtwo.c` from 3.4 | `calmsacibis995/sunos-34-src` `sun/sys/sundev/cgtwo.c` |
| [k40] | the 4.0 kernel's `cgtwo.o`, `cg2_rop.o`, `cg2_colormap.o` | tape 1 file 9, `./share/sys/sun2/OBJ/` (disassembled) |
| [k414] | `sys/sundev/cgtwo.c` from 4.1.4 | sunos-414-src (its probe and attach are the sequences 4.0's object code performs) |
| [prom] | the Rev Q PROM's `_init_scolor` | [`doc/prom/README.md`](prom/README.md), `boot0.lst` at 0xEF3D34 |
| [x] | Sprite's X11R4 `sunCG2C.c`, `sunCG2M.c` | `OSPreservProject/sprite` `src/X11R4/cmds/X/ddx/sun.old/` |
| [tme] | TME's `machine/sun/sun-cgtwo.c` | `thorpej/tme`; BSD licence, read but not copied |

None of these is in the tree. The harness takes the binaries from the user's
tapes at build time, and the sources were read from the repositories above.

## How the model is checked

[`tools/cg2model/`](../tools/cg2model/) links the 4.0 `libpixrect.a` from the
tape (`aoutlink.py`, a small a.out linker) and runs it on Musashi as a 68010.
RAM is 0 to 8 MiB, the board's 4 MiB window sits at 0x800000, and every access
libpixrect makes there becomes a bus cycle on the model: a byte with one
strobe, a word with both. libc is served by trap stubs. Every operation is
done twice, once through the cg2 routines on the model and once through
libpixrect's memory-pixrect routines on a 1152x900x8 mirror. Every pixel is
then compared with a third, independent reference: pixrect semantics written
out one pixel at a time in C, with generalised `pr_clip`, regions, plane masks,
stencils and reverse video.

```sh
make -C tools/cg2model                        # TAPE40=/mnt/c/Temp/sunos_4.0_sun2
make -C tools/cg2model run N=20000 SEED=7
```

`-k` runs a second image linked from the **4.0 kernel's** objects instead:
the real `cgtwoprobe` and `cgtwoattach`, then the same rasterops through the
kernel's own `cg2_rop` (a different compilation: no ropmode swapping, no 1x1
path). `-S` prints what each routine puts on the bus, and `-t FILE` writes
every bus cycle with its data, which is what the Phase C bench replays into
the RTL.

**Result, five seeds of 4000 in each mode: 48,642 operations, 0 failures,**
counting a directed pass in each library run that drives every
ropmode-swapping path, and about 110 million bus cycles. The tests cover
fills, overlapping screen-to-screen copies in both directions, 8-bit and 1-bit
memory sources (reverse video too), 1x1 sources, screen-to-memory read-back,
stencils with and without a source, batched glyphs, vectors, get/put,
polypoint, the colour map, region pixrects with offsets and random plane
masks, plus these sequences replayed exactly:

* the 4.0 kernel probe;
* the 3.4 kernel probe;
* the PROM's `init_scolor` and a console row drawn in plane 0;
* the driver's Sun-2/Sun-3 test.

Run as code, the kernel driver prints `cgtwo0: Sun-2 color board`, exactly
what a real 2/160 prints.

The model was written before the harness existed. The first run failed only
read-back with ops other than `PIX_SRC`, and that turned out to be a bug in
SunOS 4.0 itself (below). Every later failure traced to the harness or the
reference, never to a rule in the model.

## Address map

The window is 4 MiB at VME A24 0x400000 (`cgtwo0 at vme24 ? csr 0x400000
priority 4 vector cgtwointr 0xa8` in 4.0's GENERIC). Offsets are from the base.

| offset | size | what | `cg2reg.h` |
|---|---|---|---|
| 0x000000 | 1 MiB | plane-mode memory: plane *p* at *p* x 0x20000, 16-bit words | `cg2memfb.memplane[8]` |
| 0x100000 | 1 MiB | pixel-mode memory: a byte a pixel | `cg2memfb.pixplane` |
| 0x200000 | 1 MiB | rop-mode memory: the same pixels through the rop units | `cg2fb.ropio` |
| 0x300000 | 9 x 4 KiB | rop unit registers: units 0..7, then 8 = all units; each has a prime copy at +0x800 | `ropcontrol[9]` |
| 0x309000 | 4 KiB | status | `status` |
| 0x30A000 | 4 KiB | plane mask | `ppmask` |
| 0x30B000 | 4 x 4 KiB | word pan, zoom, pixel pan, variable zoom | `misc.zoom` |
| 0x30F000 | 4 KiB | interrupt vector | `intrptvec` |
| 0x310000 | 0x600 | colour map, red then green then blue, 256 halfwords each | `redmap` ... `bluemap` |

`CG2_MAPPED_OFFSET` is 0x200000. The kernel and libpixrect map only the part
from there up (`struct cg2fb`), so the plane- and pixel-mode memory is
reached only by the PROM (plane 0) and by programs that `mmap` it ([x]). A
register occupies its whole 4 KiB slot. The model decodes it anywhere in the
slot, which the software never tests. 3.4's `mon3/cg2reg.h` lists 0x800 "PME
offsets" for the status and pan registers, which this decode also answers.

**Pixels.** Pixel *n* = *y* x 1152 + *x*, so pixel-mode offset *n* is pixel
*n*. In plane mode, plane *p*'s word at offset 2*w* holds pixels 16*w* to
16*w* + 15, **the leftmost in bit 15**. 1152 is a multiple of 16, so a word
never straddles a line. Memory is 8 planes of 128 KiB: 910 lines of 1152,
of which 900 are displayed.

**Widths on the bus.** Measured with `-S`, SunOS makes byte and word
accesses only, **never a 32-bit one** (the 68010 would split it anyway).
Registers are read and written as bytes as well as words: the kernel uses
`btst`/`bset`/`bclr` on the status register's low byte and on the word-pan
register's high byte ([k40], `cgtwoattach`). So every register honours
UDS/LDS.

## Registers

### Status (0x309000)

| bits | name | access | notes |
|---|---|---|---|
| 15..14 | | 0 | |
| 13 | fastread | 0 | Sun-3 board feature ([reg] line 61); 0 makes `cgtwoattach` call this a Sun-2 board |
| 12 | id | 0 | the same |
| 11..8 | resolution | 0 | 0 = 1152x900 ([reg] 63-67); the kernel reads it as a byte (`moveb`, `andib #15`) |
| 7 | retrace | read only | 1 during vertical retrace. **It must really move**: the PROM ([prom]) and `cgtwoattach` ([k40]) spin on it, 0 then 1 then 0 |
| 6 | inpend | read only | interrupt pending |
| 5..3 | ropmode | r/w | see the raster-op unit |
| 2 | inten | r/w | "enab interrupt at end of retrace" ([reg] 71). Writing 0 clears inpend: [k34]'s `cgtwointr` is `inten = 0; /* clear pending interrupt. */` |
| 1 | update_cmap | r/w | see the colour map |
| 0 | video_enab | r/w | the DACs. The PROM sets it after clearing the register; the kernel sets it on `FBIOGPIXRECT` |

Writes affect bits 5..0 only. libpixrect toggles the ropmode with
`status ^= 0x10` (a word read-modify-write), so a write must ignore the
read-only bits it carries back. **Interrupt:** level 4. `inpend` is set at
the **trailing** edge of retrace while `inten` is 1, and the request is
`inpend & inten`. The vector is the low byte of the interrupt-vector
register, which `cgtwoattach` writes from the config (0xA8).

### Plane mask (0x30A000)

Eight bits, one a plane, in the low byte ("8 bits 1bit -> wr to plane",
[reg] 177). It gates **every** memory write, plain as well as rop: [x]
enables plane 0 alone before drawing a mono screen into plane 0's plane-mode
memory, and all planes before using the byte-per-pixel memory. It also
selects the units a write to `ropcontrol[8]` reaches (below). **Reset value
0xFF.** The PROM draws its console into plane 0 without ever writing the mask
([prom]), so the mask must come up enabled.

### Zoom and pan (0x30B000..0x30E000)

Word pan, zoom (line offset, pixel zoom), pixel pan (low origin, pixel
offset), variable zoom ([reg] `struct cg2_zoom`). **Nothing in SunOS uses
them** beyond resetting them: the PROM writes 0, 0, 0 and 0xFF, and so do
`cg2_make` and `cgtwoclose`. 3.4's driver says pan and zoom were "never
supported". The model stores them, readable, and does not apply them.
Phase B decides whether the display honours them.

One use is load-bearing. `cgtwoattach` tells a Sun-2 board from a Sun-3 one
by writing word pan 0, setting bit 9 with a byte `bset` (it is the Sun-3
board's double-buffer "wait" bit), waiting out a retrace, and reading it
back. **Still set means Sun-2.** So word pan must hold what is written,
byte-wise.

### Colour map (0x310000)

Three tables of 256 halfwords, red, green and blue. The low byte is the
colour (`cg2_getcolormap` reads into `u_char`). This is the *shadow* ("TTL")
map. The DACs use a second ("ECL") map, which hardware copies from the shadow
"next vert retrace" while `update_cmap` is set ([reg] 72-74). The copy is
modelled at retrace's leading edge, and happens at every retrace while the bit
stays set. `update_cmap` "silently disables writing to TTL cmap", and every
writer clears it before writing: libpixrect ([cm]), the PROM, and [x].
libpixrect sets it again and leaves it set. The PROM sets it, waits a whole
retrace, and clears it. **The model drops shadow writes while the bit is
set.** Whether the bit clears itself after a copy cannot be told from the
software: every writer behaves the same either way.

### The raster-op units (0x300000..0x308FFF)

Each unit is one plane's rop chip, with 16 halfword registers ([reg]
`struct memropc`) at +0..+0x1F of its 4 KiB slot:

| | register | | register |
|---|---|---|---|
| +0 | dest (the destination latch) | +0xC | shift: bits 3..0 count, bit 8 direction |
| +2 | source1 (right) | +0xE | op: an 8-bit truth table |
| +4 | source2 (left) | +0x10 | width |
| +6 | pattern | +0x12 | opcount |
| +8 | mask1 (first word) | +0x14 | decoderout |
| +0xA | mask2 (last word) | +0x16..+0x1E | x11..x15 (diagnostic) |

* **Unit 8, `CG2_ALLROP`, "writes to all units enabled by PPMASK, reads from
  plane zero"** ([reg] 229). The plane mask selecting units is load-bearing:
  libpixrect sets a different function in the planes where the colour has a 1
  by writing the mask, then the function, then the mask back ([rop] fill, [bat],
  [vec], [gp]).
* **Prime registers.** +0x800 holds a second view of the registers, "for
  pixmode src reg prime / byte xfer loads alternate src register bits"
  ([reg] 166-167). Writing a prime source register takes the value **in pixel
  format**: unit *p* gets the even byte's bit *p* in every even bit position
  and the odd byte's bit *p* in every odd one. [pl] loads a colour into the
  FIFO as `color | color << 8`. Only prime source1 (libpixrect) and prime
  source2 ([pl], the 3.4 probe) are written. Other prime registers are stored
  as ordinary ones, and the model warns.
* **What SunOS writes**, measured: source1, source2, pattern, mask1, mask2,
  shift, op, width, opcount, prime source1 (prime source2 in 3.4 and [pl]).
  **It never reads a rop register** and never touches dest, decoderout or
  x11..x15. So whether the registers read back is unconstrained.

## The raster-op unit

Each access to rop-mode memory runs all eight units in parallel, one plane
each. What a unit does depends on the ropmode's three bits ([reg] 205-216,
"LD_DST ON / LD_SRC ON"):

| mode | | the address is | dest loaded on | source loaded on |
|---|---|---|---|---|
| 0 | PRWWRD | a plane word | read | write |
| 1 | SRWPIX | a pixel | read | write |
| 2 | PWWWRD | a plane word | write | write |
| 3 | SWWPIX | a pixel | write | write |
| 4 | PRRWRD | a plane word | read | read |
| 5 | PRWPIX | "parallel16" pixels | read | write |
| 6 | PWRWRD | a plane word | write | read |
| 7 | PWWPIX | "parallel16" pixels | write | write |

So bit 0 selects pixel mode, bit 1 loads the destination on a write rather
than a read, and in word modes bit 2 loads the source on a read rather than a
write. **Modes 5 and 7 appear in no SunOS code** and are not modelled. In a
word mode the address's plane bits (19..17) are ignored, because all planes
take part. `cg2_rop` always addresses plane 0.

For one access, each unit does the following, in this order:

1. **Source load**, if this access loads the source. The data are: in word
   modes, the CPU's word on a write (the same for every plane) or the
   plane's own memory word on a read; in pixel modes, the CPU's data in pixel
   format (as for prime registers above). A byte write carries its byte on
   both halves, as the 68010 does, so one pixel fills both phases. **Left to
   right (shift bit 8 set), source2 <- source1 and source1 <- data; right to
   left, source1 <- source2 and source2 <- data.**
2. **Destination load**, if this access loads it: dest <- the plane's memory
   word (the plane word holding the pixel, in pixel mode), and the counter
   steps (rule 5).
3. **On a write**, for each unit whose plane is enabled, the result
   *f*(pattern, aligned source, dest) is written to that plane's word. In
   pixel mode only the bits of the addressed pixel(s) are written: two for a
   word access, one for a byte. The **end masks** protect bits *only on an
   access that loaded the destination* (rule 5).
4. **On a read**, pixel mode returns the pixel(s). What a word-mode read
   returns is not known. Nothing uses the value (`cg2_rop`'s copy loops write
   it back as a dummy), and the model returns plane 0's word.

The rules, and why:

1. **The FIFO.** [k34], setting up the probe: "set fifo direction to one, ie.
   bus -> src1 -> src2 -> ROPC function unit." [rop] primes a skewed copy by
   reading the first source word and writing the plane-0 value it gets into
   the register *about to be shifted out*: source2 left to right
   (`*somereg = *s++`, `mrc_source2`), source1 right to left. If that write
   were not overwritten by the next load, every plane but 0 would be copied
   wrong.
2. **The aligner.** The function sees a 16-bit window on source2:source1,
   **shifted right by the count; a count of 0 selects the older word whole**
   (source2 left to right, source1 right to left). The evidence is every
   priming decision in the library. With *k* = destination bit offset - source
   bit offset, [rop], [stn] and [bat] set the count to *k* mod 16 and prime
   the FIFO, left to right, exactly when *k* <= 0, **equality included**.
   Right to left the condition is *k* >= 0. A shift of 0 after priming must
   therefore present the first word. [bat]'s unshifted-glyph path confirms it
   from the other side: it primes source1 and ends each glyph with a dummy
   write (`*d = doffset`, [bat] 206-210). [pl] loads a colour into source2
   and draws in PWRWRD, "never load src" ([pl] 146, 163).
3. **The function.** An 8-bit truth table indexed pattern x 4 + source x 2 +
   dest ([reg] `CG_MASK 0xf0`, `CG_SRC 0xcc`, `CG_DEST 0xaa`). With the
   pattern zero, a pixrect op is its low nibble. [stn] puts a stencil word in
   the pattern register and builds `op << 4 | CG_DEST & CG_NOTMASK`: op where
   the stencil is set, the destination elsewhere. For a fill with no stencil
   it puts the colour's bit in the pattern of each plane. libpixrect makes a
   function ignore the source with `rop << 2 | rop & 3` (source = 0) or
   `rop & 0xC | rop >> 2` (source = 1). The pattern is not shifted: [stn]
   aligns it itself (`stword >> stshift`) and changes it every 8 pixel-mode
   writes.
4. **Pixel format.** A pixel's bit for each plane is **replicated across the
   unit's 16 bits**, even pixel in the even positions. That is why an aligned
   pixel copy works with a shift of 0 whatever bit position its destination
   pair sits at ([rop] 447-469). It is also what makes the misaligned case
   come out as [stn]'s comment describes: "the LSB of the left source
   register and the MSB of the right source register are written to the two
   destination pixels" ([stn] 341-345), with the count set to the pair's bit
   position + 1 before every write ([rop] 498, 515). A pixel copy is one
   write behind its source, so it primes the FIFO with the first pair
   (`prime.mrc_source1`) and ends each line with a dummy write ([rop] 464-466).
5. **The word counter and the end masks.** `setwidth(w, w)` loads width and
   opcount with the line's word count - 1 ([reg] `cg2_setwidth`). Each
   **destination load** is the first word while opcount = width (mask1 applies)
   and the last while opcount = 0 (mask2 applies, and opcount reloads from
   width). Otherwise opcount decrements. A mask bit of 1 keeps the
   destination's bit: `mrc_lmask(x) = 0xffff0000 >> x` protects the pixels left
   of the first, and `mrc_rmask(x) = 0x7fff >> x` those right of the last
   ([reg] memreg.h 61-62). The evidence is the **ropmode swap**. For a long
   line whose op needs no destination, [rop], [vec] and [stn] write the first
   two words in a mode that loads the destination on a write, XOR the status
   to a mode that doesn't (PWRWRD to PRRWRD, PWWWRD to PRWWRD, SWWPIX to
   SRWPIX), write the middle, and switch back for the last word, with
   `setwidth(2, 2)`. The middle writes find opcount already at 0. So writes
   that load nothing must neither count nor apply masks, and the last word
   then finds opcount at 0 for mask2. In a copy the middle *reads* load the
   destination in PRRWRD, so they count, and the width is not reset there. [pl]
   says it in a comment: `ropmode = PWRWRD; /* ld dst for mask */`.

What these rules do not settle, because no SunOS code depends on it: the
parallel16 pixel modes; what a word-mode read returns; reading rop registers;
the registers' reset values (the 4.0 probe is robust to them, the 3.4 probe
needs source1's even bits clear and passes from a zeroed reset, which the
model has); masks on a no-load write when a load just decided first or last
(the model applies none); and 32-bit accesses.

### The probes, worked through

**4.0 and later** ([k40]): the probe sets ropmode SWWPIX, plane mask 0xFF,
op `CG_SRC`, masks 0, shift `1 << 8`; then writes 0xA5 to pixel 0, writes 0,
and reads pixel 0. It must be 0xA5: the write of 0 outputs the *previous*
word (rule 2, shift 0). It then sets the mask to 0xCC and op to `~CG_DEST`,
writes again, sets the mask back to 0xFF, and needs 0xA5 ^ 0xCC = 0x69.
**3.4**: it primes source2 with 0 through the prime register, writes 0xFF, then
writes 0 through mask 0xAA, and expects 0xAA. Under these rules the result is
(whatever source1 held) & 0x55 | 0xAA. The 4.0 rewrite reads like the fix.

## What SunOS uses

Measured with `-S`, 4.0 library and kernel. `r`/`w` is read/write, `.b`/`.w`
byte/word.

| routine | rop memory | registers written |
|---|---|---|
| `cg2_rop` fill | PWRWRD w.w, PRRWRD w.w | pattern mask1 mask2 op width opcount |
| `cg2_rop` screen to screen | PWRWRD r.w w.w, PRRWRD r.w w.w | + source2 shift |
| `cg2_rop` 8-bit memory | SWWPIX w.w, SRWPIX w.w | + shift, prime source1 |
| `cg2_rop` 1-bit memory | PWWWRD w.w, PRWWRD w.w | + source1 shift |
| `cg2_rop` to memory | SRWPIX r.b | none |
| `cg2_stencil` | PWWWRD w.w, SWWPIX w.w | source1 pattern mask1 mask2 shift op width opcount, prime source1 |
| `cg2_batchrop` (text) | PWWWRD w.w | source1 pattern mask1 mask2 shift op width opcount |
| `cg2_vector` | SWWPIX w.b, SRWPIX w.b; PWRWRD/PRRWRD w.w for horizontal lines | pattern mask1 mask2 shift op width opcount |
| `cg2_get`, `cg2_put`, `cg2_polypoint` | SRWPIX r.b; SRWPIX/SWWPIX w.b | mask1 mask2 op (pattern) |
| kernel `cg2_rop` | PWRWRD, PWWWRD, SWWPIX, SRWPIX r.b; no swapping | as the library |
| kernel probe | SWWPIX w.b r.b | mask1 mask2 shift op |
| PROM | plane mode, plane 0 | none: status, colour map, zoom/pan |

## Bugs in SunOS 4.0's libpixrect

The harness ran into these. They are **in the software**, not the hardware:
the board model cannot change them, and every real Sun-2 shipped with them.

* **`cg2_rop`, screen to memory with any op but `PIX_SRC`** (or a plane-masked
  memory destination). The routine copies through a temporary, but the copy
  loop keeps the caller's `mpr_data`, fetched into `a2` before `mem_create`.
  So the raw pixels land at (0,0) of the caller's pixrect, and the op is then
  applied at the right place from a zeroed temporary. 4.1.4's source has the
  missing `mprd = mprp_d(dpr)`. `PIX_SRC`, the path SunView's screen saves
  use, is right.
* **`cg2_batchrop`, a NULL glyph** `continue`s before the list pointer
  advances. The same entry is re-read for every remaining count, its offset
  re-added each time, and nothing after it is drawn. This is in 4.1.4's
  source too.
* **A 1x1 1-bit source** becomes a fill with `pr_get`'s value, and `mem_get`
  applies reverse video to the *bit*. So there reverse video means "colour or
  zero" where everywhere else it inverts the expanded pixel. `mem_rop` agrees.
* **`mem_rop`, a narrow 1-bit source** (one to three pixels whose last pixel
  is bit 15 of its word) takes the wrong source bits. `mem_stencil` inherits
  it. The cg2 path gets these right.
* **`mem_polypoint`, depth 8**, draws every point one pixel to the left.

These could be **patched on the disk image**: `libpixrect.a` and
`libpixrect.so.2.2` in `/usr/lib`, with the same check-the-bytes-first
discipline as `tools/rompatch`. The first needs about six bytes. Statically
linked programs carry their own copies (`sysdiag/color` has `cg2_rop.c 1.22`
twice). Nothing here depends on it.

## The hardware

[`rtl/sun2-vme/sun2_cgtwo.sv`](../rtl/sun2-vme/sun2_cgtwo.sv) is the board,
[`rtl/sun2-vme/sun2_cgtwo_scanout.sv`](../rtl/sun2-vme/sun2_cgtwo_scanout.sv)
its picture. The board is the model above, rule for rule, with one change in
substance: the end masks, the FIFO and the counter act on all 16 pixels of a
plane word at once, and the eight units share a single data path.

**The OSD's "Colour board"**, On by default, fits the board. It also sets the
colour jumper (bit 9 of the video control register, `sun2_fb_ctl.v`), so the
PROM puts its console on the colour screen, and it selects that screen for
display. The mono board stays in the machine, as it does in a real 2/160, but
is not shown. Off is the machine without the board: nothing answers at
0x400000, the jumper reads 0, and the mono screen is shown.

**Where it sits.** The board is a card in TYPE 2 space beside the VME SCSI
board. `top_fpga.v` brings out a slot for it (`slot_*`, under `SUN2_CGTWO`),
and the card itself is instantiated at the board top, because its pixels are
in the board's SDRAM. `sun2_fpga.v` gained three things:

* a second vectored interrupter (level 4, vector from the card's `intrptvec`;
  the acknowledge's level picks which interrupter answers);
* `mb_hold`, which exempts from the bus timeout a cycle the card has decoded.
  This is memory's bargain: an address the card does not decode still times
  out, which is what the probes depend on;
* the colour jumper.

**Two clocks.** The slot side runs on `cpu_clk`. It sends one request per
68010 data phase, keyed on the strobes rather than on AS, so the two halves of
a read-modify-write are two requests. The engine runs on `clk_mem` and owns
everything the board holds: the registers, the eight units, the colour maps
and the pixels. Requests cross as a toggle with the request held stable, and
answers come back the same way. A request is never dropped, so a reset
(P.RESET-) clears the registers without ever handing the CPU a stale answer.

**The pixels** are SDRAM byte *n* of a megabyte 24 MiB up, in its own bank. A
16-pixel plane word is then exactly one aligned 16-byte line, one BL8 burst.
So every access, whether plane mode, pixel mode or rop, is one line read
followed by a write-back of only the halfwords that changed. The engine keeps
the last line it touched. It is the only writer, so that copy cannot go stale,
and the eight pixel-mode writes that cover a line cost one read. The CPU gets
its answer as soon as the answer is known, which for a write is before the
write-back, and the next request waits for the write-back to finish.

**The picture** is fetched into a ring of four lines, up to three lines ahead
of the one on screen, and goes out through the active colour map, two clocks
behind the raster (the syncs are delayed to match). Scan-out is 62 MB/s of an
SDRAM the CPU shares, about half its time with this controller's single-burst
reads. Taking it on demand would stop the CPU dead for the 10 us a line costs,
every line. So the fetcher takes turns with the CPU and the engine
(`sun2_mister_sdram.sv` serves the three round robin) and asks for priority
only when the next line to be shown is not complete. The mono scan-out keeps
its absolute priority and is gated off when it is not the screen shown.

**The colour map.** The shadow map is a 1024x8 RAM in the engine; the active
one is a dual-clock 256x24 RAM in the scan-out. At the leading edge of each
retrace with `update_cmap` set, the engine copies the 768 entries across
(about 8 us of a 580 us blank). Shadow writes are dropped while
`update_cmap` is set.

**Not done:** pan and zoom are stored but not applied (nothing in SunOS sets
them), and the rop registers read back but decoderout and x11..x15 are not
kept.

### How it is tested

* **`make -C tb/verilator tb_cgtwo`** replays a harness trace into the RTL.
  Each cycle is a 68010 data phase on `cpu_clk`, against a line-port memory
  with random latency on a memory clock at an awkward ratio. Every read must
  return the model's value (except retrace/pending in the status register,
  which follow the bench's own display), and the megabyte must match the
  model's at the end, byte for byte. `CG2_KERNEL=1` uses the kernel's trace.
  Four traces, two library and two kernel, **7.7 million bus cycles: PASS**.
* **`tb/verilator/mutate_cgtwo.sh`** puts 19 bugs into a copy of the board,
  one rule at a time, and the replay must fail: **19 of 19 caught**. One
  mutation tests a rule rather than code: the end masks applied from the
  counter on every write, the reading the ropmode swap rules out. It fails
  with 11,263 errors, so the rule is now settled by experiment as well as by
  argument.
* **`make -C tb/verilator tb_emu`** runs the whole core. With the board fitted
  (the default), the PROM's banner reads **"Model Sun-2/160"**, the string it
  prints only after its colour probe succeeds (0xEF10D8 drops the "Sun-2/50
  or " prefix when `g_fbtype` is 3, `FBTYPE_SUN2COLOR`, which `_finit` sets
  only when `init_scolor` returns success), and the console is drawn
  through the colour board. With it Off (`SIMARGS=+status=1000`) the banner is
  "Model Sun-2/50 or Sun-2/160". The bus-error count is 5 both ways, so
  nothing else moved.
* **On the MiSTer** (core `Sun-2_20261004a`, the 1 GB 4.0.3 disk):
  * the PROM's banner reads "Model Sun-2/160", with its console on the colour
    board;
  * 4.0.3 GENERIC (`/vmunix.orig`) prints `cgtwo0 at vme24 0x400000 vec 0xa8`
    and `cgtwo0: Sun-2 color board`;
  * `spheresdemo` draws shaded colour spheres full-screen;
  * `suntools` comes up on the colour screen, with `spheresdemo` drawing
    clipped colour spheres in a window beside the mono desktop.

  The cursor tracking that runs throughout is the kernel's own `cg2_rop`.

**The cost:** 83% of the ALMs (34,889; the board is +2,722), 187 RAM blocks
(+9), all corners met. Worst setup slacks are `clk_mem` +0.33 ns, `cpu_clk`
+1.20 ns and the pixel clock +2.05 ns, and `cpu_clk` stays on a global clock.
