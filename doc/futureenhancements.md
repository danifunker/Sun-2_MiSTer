# Future enhancements

What could be made faster, and what it would buy.  None of it is needed: the
measurements below say the machine is good enough as it is.  Each entry says
what it costs and how it was measured, so whoever picks one up starts from
numbers rather than from a hunch.

## Why this list exists: what the colour scan-out costs

The colour board's picture is 1152x900 bytes, 60 times a second, out of the
same SDRAM the CPU uses (`rtl/sun2-vme/sun2_cgtwo_scanout.sv`, through
`rtl/sun2_mister_sdram.sv`).  Measured on 2026-10-04, colour **On** against
**Off** (the OSD's *Colour board*, which also takes the board out of the
machine and shows the mono screen instead):

**On the board, it costs the CPU nothing that can be felt.**  Four sessions,
On, Off, On, Off, each a cold load of the core with the setting changed, the
1 GB 4.0.3 disk, `ps -aux` clean, `/bin/time` user seconds, each loop run
twice a session (the program is in the appendix):

| | On | Off | |
|---|---|---|---|
| registers only (the control) | 9.90 | 9.83 | +0.8% |
| reads over 512 KiB, in order | 10.70 | 10.82 | -1.2% |
| every read a cache miss | 11.23 | 11.10 | **+1.1%**, the worst case |
| reads within 4 KiB | 10.35 | 10.35 | 0 |
| writes over 512 KiB | 11.35 | 11.30 | +0.4% |
| `sum /vmunix` | 9.50 | 9.40 | +1% |
| `cc -O -c` | 2.65 | 2.80 | noise |
| an `awk` loop | 26.25 | 26.00 | +1% |
| SunView start-up, to a shelltool | 10.63 s | 10.64 s | 0 |
| scrolling a shelltool through `termcap` (133 KB) | 39.4 s | 45.8 s | **On is 14% faster** |

The scroll is faster in colour because the colour board's raster-op hardware
moves the pixels, where the mono screen is the CPU's own memory copy.

**In simulation, the cost lands on the colour board instead.**
`make -C tb/verilator tb_emu` now reports where the SDRAM's time goes
(`tb/verilator/emu_stats.svh`); the PROM's run, 1.5 s:

* The colour scan-out holds **56%** of the SDRAM's clocks; the mono scan-out
  it replaces, 7%.
* A CPU cache miss takes **6.89** CPU clocks with colour On, **7.06** with it
  Off, and **6.00** with no scan-out at all.  The mono scan-out is no cheaper:
  it fetches nine bursts back to back at absolute priority, so the rare miss
  that lands behind it takes up to 34 CPU clocks.
* The colour board's engine -- the part that reads and writes the pixels on the
  CPU's behalf -- waits.  Its SDRAM requests average **27.8** memory clocks,
  against **5.6** with the scan-out stopped.  So the CPU spends **3.5 times** as
  long on colour-board accesses (3.42 M CPU clocks against 0.97 M), and the
  PROM's colour start-up (LED `f3` to `f4`, which clears the colour screen)
  takes **363 ms** against **241 ms** (225 ms on the mono machine).
* No colour line was ever late.

The cause is in the handshake, not the bandwidth.  The engine writes a line
back one halfword at a time, and drops its request for a clock between them
(`E_WBW` back to `E_WB` in `rtl/sun2-vme/sun2_cgtwo.sv`).  The arbiter looks
in exactly that clock, finds no engine request, and hands the SDRAM to the
scan-out, which always has a line to fetch.  So every halfword waits behind a
14-clock burst.

**Against a real Sun-2/160** this is an estimate, not a measurement.  The CPU
is about 2.5 times one: a real 10 MHz 2/120 did about 700 dhrystones/s, and
the same core and cache did 1873/s at 19.6 MHz on the Wukong (`CLAUDE.md`);
the MiSTer's cache misses are cheaper than the Wukong's DDR3.  The colour board
is probably about the original's speed: a 68010 VME cycle on a 10 MHz Sun-2 is
400 ns before the bus's own overhead, so call a real access 1 us; ours is
0.5 to 1 us for most accesses and about 2 us for a raster-op write that
rewrites a whole 16-pixel word.

## The enhancements, best first

### 1. The colour board's engine keeps its request, and a scan-out that is not urgent waits

**Tested in simulation, on copies of the two files; the tree is unchanged.**
Two changes, and neither works alone:

* the engine presents its next changed halfword on the clock it sees `m_done`,
  with `m_req` held, so the arbiter sees it at its next look;
* the arbiter serves the CPU and the engine, in turns, before a scan-out that
  is not urgent; urgent still comes first.

Priority alone changed nothing measurable (the engine never has a request up
when the arbiter looks), and the held request alone changes nothing either
(the round robin still gives the next turn to the scan-out).  Together, in
the PROM run:

| | today | with 1 | no scan-out (the floor) |
|---|---|---|---|
| engine request, memory clocks | 27.8 | **12.7** | 5.6 |
| CPU clocks on colour-board accesses | 3.42 M | **1.68 M** | 0.97 M |
| PROM colour start-up | 363 ms | **276 ms** | 241 ms |
| late colour lines | 0 | 0 | -- |
| CPU cache miss | 6.89 | 6.88 | 6.00 |

The screen it drew is byte for byte the same.  It recovers about 70% of what
the scan-out costs the colour board.  Expect it to be felt only where SunView
fills or copies large areas in colour, perhaps 10 to 20% there: most of what
SunView does is CPU work.

The changes as simulated:

```diff
--- a/rtl/sun2_mister_sdram.sv
+++ b/rtl/sun2_mister_sdram.sv
     wire [1:0]  pick =
-        (cs_req & cs_urgent) ? 2'd0 :
-        (last_rr == 2'd0)    ? (wb_want ? 2'd1 : cg_req  ? 2'd2 : 2'd0) :
-        (last_rr == 2'd1)    ? (cg_req  ? 2'd2 : cs_req  ? 2'd0 : 2'd1) :
-                               (cs_req  ? 2'd0 : wb_want ? 2'd1 : 2'd2);
+        (cs_req & cs_urgent)  ? 2'd0 :
+        (wb_want & cg_req)    ? ((last_rr == 2'd1) ? 2'd2 : 2'd1) :
+        wb_want               ? 2'd1 :
+        cg_req                ? 2'd2 : 2'd0;
--- a/rtl/sun2-vme/sun2_cgtwo.sv
+++ b/rtl/sun2-vme/sun2_cgtwo.sv
     reg  [2:0]  wbk   = 3'd0;           // write-back: the next halfword to look at
+    // the first changed halfword after wbk
+    reg  [2:0]  nxt_k;
+    reg         nxt_ok;
+    integer     nk;
+    always @(*) begin
+        nxt_ok = 1'b0;
+        nxt_k  = 3'd0;
+        for (nk = 7; nk >= 0; nk = nk - 1)
+            if (nk > wbk && (chg[15 - 2 * nk] | chg[14 - 2 * nk])) begin
+                nxt_ok = 1'b1;
+                nxt_k  = nk[2:0];
+            end
+    end
 ...
             E_WBW:
                 if (m_done) begin
-                    m_req <= 1'b0;
-                    m_we  <= 1'b0;
-                    if (wbk == 3'd7)
-                        est <= E_IDLE;
-                    else begin
-                        wbk <= wbk + 3'd1;
-                        est <= E_WB;
+                    if (nxt_ok) begin
+                        wbk     <= nxt_k;
+                        m_word  <= nxt_k;
+                        m_wdata <= nline[nxt_k * 16 +: 16];
+                        m_bs    <= {chg[15 - {nxt_k, 1'b0}], chg[14 - {nxt_k, 1'b0}]};
+                    end else begin
+                        m_req <= 1'b0;
+                        m_we  <= 1'b0;
+                        est   <= E_IDLE;
                     end
                 end
```

**To land it:** `make -C tb/verilator tb_cgtwo` with both traces, and
`tb/verilator/mutate_cgtwo.sh` (the replay's memory model must accept a request
that stays up with a new address); `tb_mister_sdram`, which does not drive the colour board's two clients at
all yet and would need to; `tb_emu` On and Off, with no late lines in `emu_stats`; a
Quartus build; and SunView in colour on the board.  Its one risk is the
scan-out: under heavy drawing it now gets only what is left until it is
urgent, and then it takes the SDRAM for up to a line (about 10 us).  The PROM
run had 20% more urgent bursts and no late line; SunView at its heaviest has
not been simulated.

### 2. Write a changed line back in one transaction

Today the engine sends up to eight single-halfword writes per line, each its
own request, handshake and gap.  A line write with a byte mask, issued by
`sun2_mister_sdram` as back-to-back single writes without going back to the
arbiter, would take most of what is left between 1 and the floor (276 ms
against 241 ms above).  It needs a new client port and the engine's write-back
rewritten; both are tested by the same benches as 1.

### 3. Back-to-back reads for the scan-out in `rtl/sdram.sv`

The controller issues single BL8 bursts, about 14 clocks for 8 words.
Pipelining the next READ during a burst would take the colour scan-out from
about 56% of the SDRAM to about 31%.  It would leave more room for 1 and 2, and
does almost nothing for the CPU, whose wait is set by the burst already under
way, not by how many there are.  `rtl/sdram.sv` is the hardware-tested
controller from the Quadra 800 core, so this is the riskiest item here, and
`tb_mister_sdram` with its chip model would have to cover the new path.  Only
if 1 and 2 are not enough.

### 4. A bigger CPU read cache

`sun2_cached_fifo_bridge`'s `IDX` from 9 (8 KiB) to 12 (64 KiB), about 60
M10K of the ~366 free.  **This is not a fix for the scan-out**, which costs
the CPU about 1%.  It would be a speed-up in its own right, of a size nobody
has measured: a miss costs about six CPU clocks, and how many fewer misses
SunOS takes with 64 KiB needs a trace of SunOS running.  `emu_stats.svh`'s
`+mem_trace` writes one, and `tools/cachesim` replays it against
caches of any size.  A kernel boot in `tb_emu` would reach the kernel only
after about 17 s of simulated time (the PROM's boot loader polls between 8 KB
reads), some hours of wall clock, so it has not been done.  Check timing afterwards: the
tag compare is on the hit path.

### 5. A lower raster rate

The scaler keeps HDMI at 60 Hz, so a 30 Hz raster would halve the scan-out's
share.  It changes the analogue output and the retrace rate the software sees,
and nothing above says it is needed.  Not recommended.

## Booting: no fsck after a clean shutdown

**A disk configuration, not a change to the core.**  The 1 GB 4.0.3 disk spends
about three of the four and a half minutes from core load to `login:` in
`fsck`.  SunOS 4.0.3 checks every file system in `/etc/fstab` that has a pass
number, on every boot: it has no clean flag (that came with SunOS 4.1, which
never ran on a Sun-2), so `fsck -p` cannot tell a cleanly unmounted volume from
a crashed one.  Most of the time is `/usr`: 245,760 inodes for about 7,000
files, which is 30 MB of inode blocks read in the first pass.

**The way round it is already on the disk.**  `/etc/rc.boot` skips every check
when `/fastboot` exists ("trust that everything is ok when /fastboot exists"),
`/etc/rc` removes the file once the boot has got past that point, and
`/usr/etc/fasthalt` and `/usr/etc/fastboot` are `halt` and `reboot` that create
it first (`cp /dev/null /fastboot`).  So a disk shut down with `fasthalt` boots
without `fsck`, and one stopped any other way -- the OSD's Reset, a core
switch, a crash -- still gets the full check, which is what is wanted.

What could be done with it, later:

* **Say so in the README**, where it tells people to shut down before a reset:
  `/usr/etc/fasthalt` instead of `/etc/halt`, and why.
* **Make it the default on the disks this project prepares**: root's
  `.bash_profile` and `.cshrc` aliasing `halt` and `reboot` to `fasthalt` and
  `fastboot`.  Less invasive than replacing `/usr/etc/halt`, which `shutdown`
  also runs.
* **Make the check itself shorter** for the boots that still need it: a disk
  made with fewer inodes (`newfs -i` with a larger number of bytes per inode)
  has less for the first pass to read.  It has to be decided when the disk is
  made, by `tools/mktape --disk` or `suninstall`, and should be measured.
* **Not** a pass number of 0 for `/usr` in `/etc/fstab`: that skips the check
  after a crash as well.

One caveat: `/fastboot` survives until `/etc/rc` runs, so if the boot after a
`fasthalt` is itself cut off before that, the next boot skips `fsck` too.

## How to measure again

**In simulation**, `make -C tb/verilator tb_emu` prints a line of figures every
`+stats_ms` (100 by default) and the whole run's at the end: the SDRAM's
clocks by owner, CPU reads' wait and service with percentiles, the colour
engine's, urgent scan-out bursts, the colour lines and how far ahead each was
fetched, CPU cache hits and misses with each miss's latency.  `SIMARGS=+status=1000`
is colour Off.  `+pc_watch=FILE` logs the first fetch from each listed kernel
address, and `+mem_trace=FILE` writes every memory access through the bridge.

**On the board**, without the OSD and without screenshots:

* the core's serial port is the HPS's: SunOS's `/dev/ttya` is `/dev/ttyS1` on
  the MiSTer, so `stty -F /dev/ttyS1 9600 raw` and read it, and anything the
  Sun writes to `/dev/ttya` arrives as text;
* *Colour board* is status bit 12, byte 1 bit 4 of `config/Sun-2.CFG`; write
  the file and `load_core` the MGL, and Main applies it as the core loads.
  Put it back to all zeros afterwards;
* `tools/mister_keys.py` types C now (`[ ] \` and `{LBRACE}`).  Old `awk` reads
  standard input even with only a `BEGIN`, so run scripts `< /dev/null`.

## Appendix: the board benchmark

`/bench/bench.c`, built with `cc -O`; the argument is the loop and the count:

```c
long a[131072];
main(argc, argv)
char **argv;
{
	register long *p, s;
	register int i, j, k, m;

	m = atoi(argv[2]);
	s = 0;
	switch (atoi(argv[1])) {
	case 0:
		for (k = 0; k < m; k++)
			for (i = 0; i < 100000; i++)
				s += i ^ k;
		break;
	case 1:
		for (k = 0; k < m; k++)
			for (p = a, i = 131072; i > 0; i--)
				s += *p++;
		break;
	case 2:
		for (k = 0; k < m; k++)
			for (p = a, i = 32768; i > 0; i--, p += 4)
				s += *p;
		break;
	case 3:
		for (k = 0; k < m; k++)
			for (j = 0; j < 128; j++)
				for (p = a, i = 1024; i > 0; i--)
					s += *p++;
		break;
	case 4:
		for (k = 0; k < m; k++)
			for (p = a, i = 131072; i > 0; i--)
				*p++ = k;
		break;
	}
	printf("%d\n", s);
}
```

`/bench/run.sh`, run as `sh /bench/run.sh NAME < /dev/null`:

```sh
exec > /dev/ttya 2>&1
echo === start $1 `date`
ps -aux
for t in 0 1 2 3 4 0 1 2 3 4
do
	case $t in
	2) m=120;;
	*) m=40;;
	esac
	echo case $t $m
	/bin/time /bench/bench $t $m
done
sum /vmunix
/bin/time sum /vmunix
/bin/time sum /vmunix
cd /tmp; /bin/time cc -O -c /bench/bench.c
/bin/time awk 'BEGIN { for (i = 0; i < 30000; i++) s += i }'
echo === done $1 `date`
```

And SunView, started as `echo st-begin > /dev/ttya; suntools -s /bench/st.rc`
with the serial port read by a reader that stamps each line with the time;
start-up is `st-begin` to `st-up`:

```
shelltool -Wp 0 0 -Ws 1150 880 sh -c "echo st-up > /dev/ttya; /bin/time cat /usr/share/lib/termcap 2> /dev/ttya; echo st-done > /dev/ttya; sync; exec csh"
```
