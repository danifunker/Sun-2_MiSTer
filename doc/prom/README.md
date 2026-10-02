# The boot PROM, disassembled

`boot0.lst` is an annotated disassembly of `Inputs/boot0.rom`, the Sun-2/50 and
2/160 Rev Q boot PROM: the image this core runs, and the one a MiSTer user
puts in `games/Sun-2/boot0.rom`. It is a reference for reading what the PROM
does; it is generated, so don't edit it.

| file | what |
|---|---|
| `boot0.lst` | the listing, from `tools/promdis` |
| `boot0.sym` | the names the listing uses beyond the ROM vectors, each with its source |

The image's sha256 is
`8560ef6848f63e347f5de1f2253a80a9175300c7dae6627c013d7616b4f84a3f`, and it
must be exactly 32768 bytes. A user's dump that hashes differently is not this
PROM.

## Regenerating

`tools/promdis` needs Python 3 and an m68k `objdump`. On Ubuntu or WSL, the
`binutils-m68k-linux-gnu` package has one. Without root it can be unpacked in
place:

```sh
apt-get download binutils-m68k-linux-gnu && dpkg -x binutils-m68k-linux-gnu_*.deb root
export LD_LIBRARY_PATH=$PWD/root/usr/lib/x86_64-linux-gnu
tools/promdis --objdump root/usr/bin/m68k-linux-gnu-objdump \
    --sym doc/prom/boot0.sym -o doc/prom/boot0.lst Inputs/boot0.rom
```

Add a name to `boot0.sym` once it is established, and regenerate. Every name
there says where it came from: a SunOS header, the PROM source, or a patch
file. A guessed name is worse than `sub_ef3d34`.

## Layout

| address | contents | source |
|---|---|---|
| `0xEF0000` | ROM vector table, 50 longwords, then `bootaddr` | `kernel/romvec.s` |
| `0xEF00CC` | text, from `_hardreset` | |
| `0xEF662C` | data: `version.c`'s SCCS id, `_monrev` ("Rev Q"), page-map init tables, the string pool | |
| `0xEF7A20` | `0xFF` fill to the end | |

The first two vectors are the 68010's reset SSP (`0x1000`) and PC
(`0xEF00CC`). `_hardreset` opens with a `reset` instruction.

The source is in the SunOS 3.4 tree at `sun/prom_monitor/msun/mon`, and the
build directory is `RevQs`. That is the only monitor build with `-DS2COLOR`,
which is why this PROM and not the MultiBus one. That tree is no longer a
submodule here; fetch it from https://github.com/calmsacibis995/sunos-34-src
when you need it.

## How the listing is made

objdump does a linear sweep, which goes wrong in this image in three ways.
`promdis` corrects each one, mechanically:

* **Pad words.** Functions start on 4-byte boundaries, so a `0000` pad
  before a `link` decodes as `orib #86,%d0`. There are 18; each is shown as
  data, and disassembly restarts after it.
* **Switch tables.** `movew %pc@(T,%dN:w),%dR; jmp %pc@(T,%dR:w)` has word
  offsets inline at T. There are 134 cases, each labelled `case_`. A bare
  computed `jmp` into code, as `blts.s`'s unrolled copy loops use, is left
  as code.
* **Inline messages.** The assembly diagnostics keep their strings in the
  text after an unconditional branch, reached by `lea %pc@(msg)`.

Data that nothing finds mechanically is declared in `boot0.sym` with
`data=`. So far that is one table, `_fwritestr`'s switch on control
characters.

The result has no undecoded words. Labels are `_name` from the ROM vectors
or the symbols file, `sub_` for a `jsr`/`bsr` target, `fn_` for a `link`
reached only through a pointer, `loc_` for a `jmp` target, and `dat_` for
data the text refers to.

## The colour console, as the PROM drives it

This is what a `cgtwo` model has to answer for the PROM to put its console on
colour. It is everything `_finit` (`0xEF3118`) and `_init_scolor` (`0xEF3D34`)
touch, read from the listing and checked against `dpy/finit.c` and
`dpy/scutils.c`.

1. `_finit` sets video enable (bit 15) in the mono board's control register at
   `VIDEOCTL_BASE` (`0xEE3800`) and sets `g_fbtype = 2` (`FBTYPE_SUN2BW`).
2. If the **colour jumper**, bit 9 of that register (`btst #1,0xee3800`), is
   set, it calls `_init_scolor`. A result of 0 or more sets
   `g_fbtype = 3` (`FBTYPE_SUN2COLOR`); a negative one leaves the console mono.
3. `_init_scolor` maps one page at a time through `VIDEOMEM_BASE`
   (`0xEC0000`) with `_setpgmap`, using these entries. Each is valid,
   read/write, type 2 (VME), with page = VME address >> 11:

   | entry | VME address | register (`cg2reg.h`, `struct cg2fb`) | what the PROM does |
   |---|---|---|---|
   | `PME_COLOR_STAT` `0xEC800E12` | `0x709000` | status | `poke(0)`: a bus error means no board, so return -1 |
   | `PME_COLOR_MAPS` `0xEC800E20` | `0x710000` | red, green, blue shadow maps | 768 halfwords, alternating `0xFFFF`, `0x0000`: even entries white, odd black |
   | `PME_COLOR_STAT` | `0x709000` | status | sets `update_cmap` (bit 1), waits until `retrace` (bit 7) reads 0, then 1, then 0 again, clears `update_cmap` |
   | `PME_COLOR_ZOOM` `0xEC800E18` | `0x70C000` | zoom | writes 0 |
   | `PME_COLOR_WPAN` `0xEC800E16` | `0x70B000` | word pan | writes 0 |
   | `PME_COLOR_PPAN` `0xEC800E1A` | `0x70D000` | pixel pan | writes 0 |
   | `PME_COLOR_VZOOM` `0xEC800E1C` | `0x70E000` | variable zoom | writes `0xFF` |
   | `PME_COLOR_STAT` | `0x709000` | status | clears it, sets `video_enab` (bit 0), reads `resolution` (bits 11:8; nonzero = 1024x1024) |

4. Last, `setupmap(colorzap)` maps `VIDEOMEM_BASE` onto VME `0x400000`, which
   is **bit plane 0** of the board's word-mode memory (`cg2memfb.memplane[0]`).
   From then on the console is drawn exactly as on a mono frame buffer, one bit
   per pixel, and the colour map's alternation makes each bit black or white.

The order in step 3 matters to a model:
* the retrace wait spins until `retrace` toggles, so a status register whose
  bit 7 never moves hangs the PROM;
* `update_cmap` is what copies the shadow maps into the displayed ones at the
  next vertical retrace.

Nothing here uses the raster-op units, the plane mask or the byte-per-pixel
memory. SunOS's own `cgtwo` driver and SunView will; the PROM doesn't.
