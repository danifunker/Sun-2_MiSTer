# Plan: one Sun family in Main_MiSTer, and the Sun-2 on the SPARCstation's protocol

Decided with the user on 2026-10-03.  This comes **before** the cgtwo work in
`RESUME-20261003.md`.  The companion plan for the SPARCstation core (repo
`danifunker/ss`, branch `danifunker`, worked on by another session -- **do not
edit it from here**) is `doc/ss-align-plan.md`; hand it to that session.

## Decisions

* Main_MiSTer branch **`sun-family`**, made from clean `master` (upstream
  `57276f0`), **replaces `sun2-patches`** (local `8f9d474`+`6d067de`, remote
  `origin/sun2-patches` = `8f9d474`).
* `support/sun/` serves both cores: the SunSparcStation's files from
  `origin/sparcstation-enhancements` (`sun.{h,cpp}`, `sun_disk`, `sun_cdrom`,
  `sun_enet`) plus the Sun-2.  `support/sun2/` goes away.  Not the Mac
  write-buffer commits that branch sits on (`sun_disk.cpp` stands alone).
* **One mailbox protocol: the SPARCstation's** (`eth_hps.vhd` in `ss`), with
  the Sun-2 adopting it.  Main pads received frames to 60 and appends the
  FCS; the core's PHY plays them out as given.
* The Sun-2's OSD follows the SPARC's: **Network = eth0 (default), Off, eth1,
  macvlan, tap0** -- value 0 is eth0, 1 is Off.
* The bell (`rtl/sun2_mister_bell.sv` and the beeper logic in
  `sun2_mister_kbd_mouse.sv`) may also be used under **GPL-2.0-or-later**, so
  it can go into `ss` (GPL-2.0).

## The protocol (as `ss` `rtl/mister/eth_hps.vhd`, with a longer RX ring)

DDR3 at ARM physical 0x1FF00000 (word 0x03FE0000), 64-bit little-endian words,
frame byte i in lane i mod 8 of word 1 + i/8 of its slot:

| offset | word | writer |
|---|---|---|
| 0x0000 | MAGIC, written last at start-up | core |
| 0x0008 | GEN, a new value at every start-up (Main resynchronises) | core |
| 0x0010 | TX_WPTR | core |
| 0x0018 | TX_RPTR | Main |
| 0x0020 | RX_WPTR | Main |
| 0x0028 | RX_RPTR | core |
| 0x0030 | MAC: bit 63 valid, 47:40 first byte .. 7:0 last | core |
| 0x1000 | TX ring, 8 slots x 2048: header 10:0 length, then the frame | core |
| 0x5000 | RX ring, **16 slots** x 2048: header 10:0 length **with the 4-byte FCS Main appends**, 21:16 the LADRF index of the destination; then the frame | Main |

Magic per core: Sun-2 **`S2ETH001`** (0x5332455448303031); SPARC `SSETH001`
(RX 8 slots) and, once its core has 16, `SSETH002`.  Main takes the RX ring
depth from the magic it sees.

## Sun-2 core (this repo)

1. `rtl/sun2_mister_enet.sv`, mailbox side (clk_mem):
   * the offsets and magic above; MAC at 0x30; RX slots at 0x5000, 16 of them;
   * **GEN**: write a new value before the magic at every publish (a counter
     that runs freely from power-up, so a core reload differs too);
   * **TX back-pressure**: before copying a frame out, read TX_RPTR; while
     TX_WPTR - TX_RPTR >= 8, keep the frame (CRS stays high, so the 82586
     defers; its own give-up is 2^16 nibbles, 26 ms at 2.5 MHz).  Drop it after
     ~10 ms with no progress (Main not running), as `eth_hps` does.  With the
     network Off, drop at once (as now);
   * RX: the header length now includes the FCS; take bits 10:0, ignore 21:16
     (the 82586 filters addresses itself).  Accept 64..1522.
2. MII side: play a received frame's bytes out **as given** -- delete the
   padding to 60 and the R_FCS state; the `crc32_eth` instance goes.  Keep
   the preamble, the 48-nibble gap, CRS and LOOPB- behaviour.
3. `Sun-2.sv`: `"O[11:9],Network,eth0,Off,eth1,macvlan,tap0;"`, enable =
   `status[11:9] != 3'd1`.  README's network table and text to match.
4. Tests: `tb_mister_enet.sv` -- the daemon half of the bench speaks the new
   layout (GEN, TX_RPTR it advances, RX frames with FCS appended and padded by
   the bench, as Main does); new checks: GEN changes on republish; with the
   bench not advancing TX_RPTR, frames are held (the chip never gives up
   while the ring has room) and then dropped after the wait; a full TX ring
   resumes when TX_RPTR moves.  Update `mutate_enet.sh` (drop the padding /
   FCS mutations, add back-pressure ones).  `tb_emu.sv`'s DDR3 logger: new
   offsets.  Run all of `make -C tb/verilator`.
5. Quartus build (kill at 45 min; check cpu_clk stays on a GCLK), board test
   with the Main below.

## Main_MiSTer `sun-family` (in `C:\Temp\mistercore\Main_MiSTer`)

Build from a `git archive` copy in WSL (`/opt/gcc-arm-10.2-...`), never in
the checkout; the checkout is the user's and may be switched only to make the
branch.

1. `git checkout -b sun-family master`; bring `support/sun/*` from
   `origin/sparcstation-enhancements` (files only) and its `user_io.cpp` /
   `support.h` hunks (sun_enet start/stop/poll, sun_mount_hook, sun_unmount,
   sun_poll, sun_sd_service) -- the `mac_sd_service(..., fileTYPE *f, ...)`
   signature change belongs to the Mac branch: leave it out.
2. `sun.cpp`: a core table -- `{"SunSparcStation", status "[26:24]",
   disk/CD slots}`, `{"Sun-2", status "[11:9]", no disk/CD hooks}`;
   `is_sun_family()` for the Ethernet and ID PROM, `is_sun_scsi_family()`
   stays SPARC-only for the disk write buffer and the CD.
3. `sun_enet.cpp`: one daemon (the SPARC one) taking the status bits from
   the table and the RX depth from the magic (`SSETH001` 8, `SSETH002` and
   `S2ETH001` 16).
4. `sun_idprom.cpp`: `make_idprom()`/`send_idprom()` from `sun2_enet.cpp`
   (boot1.rom, else 08:00:20 + the host NIC's low 3 octets, also the serial;
   machine type 0x02), called for the Sun-2 from `sun_enet_start()` before the
   boot ROMs (the hook already sits there).
5. One-line comments, sparse (the user's rule).  Build; the binary must
   behave identically for the SPARC with `SSETH001`.
6. Board (with the user's standing OK: `sync`, `/etc/halt`, copy the binary
   to `/media/fat/MiSTer` keeping the old one, `reboot`): **reset
   `config/Sun-2.CFG` to zeros** (bit 9 set means Off under the new order),
   load the new Sun-2 core, ping both ways incl. 8000/16000-byte pings, FTP.
7. Delete local `sun2-patches` after `sun-family` works; deleting the remote
   branch and pushing are the user's call.

## Status (2026-10-04)

**Done and tested on the board.**  Main_MiSTer `sun-family` is `635a7a5`, pushed to
origin; the core is Sun-2_MiSTer `9b26106` on master.  Left to the user: step 7 of
Main's half -- deleting `sun2-patches`, local (it holds an unpushed `6d067de`, a
comment trim the new branch supersedes) and on origin -- and handing
`doc/ss-align-plan.md` to the session working on `ss`, which works with this Main
unchanged until it moves to `SSETH002`.

* Core: `rtl/sun2_mister_enet.sv` on the protocol above.  Two things the plan did not
  say and Main forced: the mailbox is published each time the **machine leaves
  reset** (Main clears a stale magic when it starts, then sends boot0.rom, which holds
  the machine in reset -- publishing at PLL lock, as before, would be cleared and never
  redone), and withdrawn when it goes back in; and it **stays published with Network
  Off**, because Main reads the mode only while it sees the magic and would otherwise
  never close its host link.  The TX wait is 10 ms (`TX_WAIT`), retried every 10 us.
* Tests: `tb_mister_enet` 48 checks, `mutate_enet.sh` 22 of 22 caught; all of
  `make -C tb/verilator` passes; `tb_emu` publishes the mailbox 200 ns after
  boot0.rom arrives.  Quartus 18 min: 77% ALMs (32,167), cpu_clk +1.84 ns
  (still a GCLK), clk_mem +0.76, hold +0.19.
* Main `sun-family`: `support/sun/` from `sparcstation-enhancements`, a core table in
  `sun.cpp` (`is_sun_family()`, the status bits), RX depth from the magic,
  `sun_idprom.cpp`.  The board runs fast-mac-scsi + that diff (as before, to keep the
  Mac write buffer); `build/main_mister/` holds both binaries and the patch.
* Board (`Sun-2_20261003h.rbf`, CFG zeroed): ID PROM from Main; pings 56 to 16000 bytes
  from the LAN, 0% loss (8000 = 6 fragments, 16000 = 11); 256 KiB through telnetd each
  way, sums equal; ftpd answers; `netstat -s`: 196 fragments in, 0 dropped, 0
  retransmits, 0 bad checksums.  `ie0` showed 1 input error in 5,756 packets that a
  further 440 fragments did not move -- unexplained, not load-related.
