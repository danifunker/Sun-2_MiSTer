# Vendored third-party RTL

These cores used to be git submodules under `Inputs/`. A MiSTer core has to
build from a plain checkout with nothing but Quartus, so the files the build
needs are copied in here, unmodified, at the commits below. Change them
upstream and re-copy; do not edit them in place.

| directory | upstream | commit | licence | files taken |
|---|---|---|---|---|
| `rd68011/` | https://github.com/MelkhiorVintageComputing/RD68011 | `f768c7f` | CERN-OHL-S-2.0 (`rd68011/LICENSE`) | `rtl/*.sv`, `rtl/gen/*.sv`, `rtl/rd68011.vlt` |
| `z8530_scc/` | https://github.com/vz50938/z8530_scc | `b9bcd67` | GPL-3.0 (`z8530_scc/LICENSE`) | `z8530_scc.sv` |
| `wish5380/` | https://github.com/MelkhiorVintageComputing/Wish5380 | `bde4ef3` | MIT (SPDX header in each file; upstream has no LICENSE file) | `src/wish5380_pkg.sv`, `src/scsi_fabric.sv`, `src/scsi_targ.sv` |
| `wish82586/` | https://github.com/MelkhiorVintageComputing/Wish82586 | `fda7313` | MIT (SPDX header in each file; upstream has no LICENSE file) | `src/*.sv` |

Notes:

* **One file is built from a patched copy instead**: `rd68011_shifter.sv`,
  from `rtl/patched/rd68011/` -- the copy here is left as upstream has it.
  `rtl/patched/README.md` says what changed and why.
* **RD68011** was pinned at `04cd25b` as a submodule. `f768c7f` is three
  commits later and differs from it in `rtl/` only by the licence and SPDX
  comment headers it added. The logic is identical, and the earlier commit
  carried no licence at all.
* **Wish82586** is not in the build yet. It is the 82586 behind the Sun
  MultiBus Ethernet card (`rtl/sun2-multibus/sun2_mb_ether.sv`), kept here for
  when the card is added. The one patch this project carried against it
  (`0004`, a Verilator build fix) touched only its Makefile, so nothing here is
  patched.
* **Wish5380** contributes only the SCSI target and the bus fabric used by
  `rtl/sun2-common/sun2_scsi_core.sv`. Its SD-card back end (`blk_sd`,
  `sd_spi`) is replaced on MiSTer by `rtl/sun2_mister_block.sv`.
