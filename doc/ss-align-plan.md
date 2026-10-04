# Plan for the SPARCstation core (`danifunker/ss`): align with Main's `sun-family`

For the session working on `ss` (branch `danifunker`).  Written 2026-10-03 by
the Sun-2 session, which does not touch `ss`.  Its own half is
`Sun-2_MiSTer/doc/sun-family-plan.md`.

## What is changing in Main_MiSTer

* A new branch **`sun-family`** (from clean master) holds `support/sun/` for
  both Sun cores: the files from `sparcstation-enhancements` (`sun.{h,cpp}`,
  `sun_disk`, `sun_cdrom`, `sun_enet`) plus the Sun-2.  The Mac write-buffer
  commits are not in it.
* `sun_enet.cpp` stays **the SPARC daemon, byte-for-byte in behaviour** for a
  core showing `SSETH001`; it only gains a core table (status bits, ring depth
  by magic).  Nothing on the SPARC side has to change for it to keep working.
* The Sun-2 core moves onto the SPARC's mailbox protocol (its own magic,
  `S2ETH001`) and its OSD order (Network = eth0 default, Off, eth1, macvlan,
  tap0).

## Changes for the `ss` core

### 1. Receive ring of 16 (needed for bursts)

A host delivers fragments together; the core drains at 10 Mb/s.  Measured on
the Sun-2 with a 4-slot ring: 8000-byte pings (6 fragments) all failed; with
16, 8000- and 16000-byte (11 fragments) pings pass.  The SPARC's 8 slots carry
6 fragments but not 11 (e.g. NFS over UDP with 8K blocks plus traffic).

In `rtl/mister/eth_hps.vhd`:
* split `RING` (8) into `TX_RING := 8` and `RX_RING := 16`; the RX ring stays
  at +0x5000 and now ends at +0xD000 (inside the 64 KiB window);
* the magic becomes **`SSETH002`** (0x5353455448303032), so Main knows the
  ring depth -- an old Main with a new core, or the reverse, then simply sees
  no mailbox rather than a corrupt one;
* the header comment's ring sizes.

Test: Main `sun-family` build; ping from the LAN with 16000-byte packets
(11 fragments each way) and 8000-byte; `netstat -s` fragments dropped after
timeout must stay 0.

### 2. The keyboard bell and key click

`rtl/sun4m/ts_sunkb.vhd` documents 02/03 (bell on/off) and 0A/0B (click
on/off) but implements neither, so the machine is silent.  The Sun-2 has both,
and its owner grants them for `ss` under **GPL-2.0-or-later**:

* `Sun-2_MiSTer/rtl/sun2_mister_bell.sv` -- the tone: the Sun keyboard's
  480 us period (~2083 Hz, MAME's hlekbd agrees), a square wave through a
  one-pole low-pass (K=10 at 24.576 MHz, ~3.8 kHz), made on `CLK_AUDIO`;
  `beeper` (a level from any clock) through two flops; volume 0 normal
  (+-6000), 1 loud (+-16000), 2 quiet (+-2000), 3 off; silence is exactly 0.
  Its bench: `Sun-2_MiSTer/tb/verilator/tb_mister_bell.sv` (25 checks) and
  `mutate_bell.sh`.
* The keyboard's side, from `Sun-2_MiSTer/rtl/sun2_mister_kbd_mouse.sv`: a
  `bell` flag (02 sets, 03 clears), `click_en` (0A sets, 0B clears and cuts a
  click short), a 5 ms click started on every key *make* when enabled (not on
  breaks, not on dropped repeats), and RESET (01) clearing all three; then
  `beeper <= bell | click_running`, registered.  In VHDL this belongs in
  `ts_sunkb.vhd`'s command decoder, with the make hook where it emits a make
  code.
* Audio: the core already drives `AUDIO_L/R` from the CS4231 with
  `AUDIO_S = 1`; add the bell sample with a saturating add, both channels.
* OSD: a "Keyboard bell" option (Normal, Loud, Quiet, Off) in a free status
  bit pair.
* Test on SunOS/Solaris: the PROM blips the bell when it finds the keyboard;
  `^G` at the console; `click -y` (SunOS) and type.  The Sun-2's whole-core
  bench saw the PROM's blip at 8.4 ms (BELL and NOBELL one 1200-baud byte
  apart).

### 3. Optional, later: the machine's identity from the host

A blank NVRAM image gets the built-in ID PROM with a serial of its own
(`nvram_sd.vhd`).  Main's `sun_idprom.cpp` (from the Sun-2) can make one from
the host NIC (08:00:20 + its low 3 octets, also the serial), so each MiSTer's
SPARC gets a stable, LAN-unique address and hostid even on a fresh NVRAM.
That needs a way for Main to seed a blank NVRAM -- decide only if wanted.

## Not shared, on purpose

The keyboards (Type 4/5 with layouts vs Type 3), the clocks (M48T08 vs
MM58167) and the NVRAM differ too much; the mailbox engine is the same
protocol in two languages (VHDL here, SystemVerilog there) -- share the spec
and the Main daemon, not the source.
