# Installing SunOS on the MiSTer Sun-2

This installs SunOS 4.0 onto an empty disk from the release tapes, the way it
was done on a real Sun-2/160: boot the tape, copy the miniroot onto the disk's
swap partition, boot that, and run `suninstall`. After that, the 4.0.3 upgrade
tapes can bring it to 4.0.3.

**Which tapes.** A full install needs the **SunOS 4.0** Sun-2 tapes (two QIC
volumes, April 1988). The common **4.0.3** set, 700-2157-10, is the *upgrade*
release: its miniroot runs only `sunupgrade`, which upgrades an existing 4.0 or
4.0.1 system, and has no `suninstall`. So 4.0 first, then 4.0.3 over it.

Everything below up to and including starting the installation has been done on
a MiSTer, with the screens quoted from it. The rest -- the extraction finishing,
the tape change, the first boot of the installed system and the 4.0.3 upgrade --
follows Sun's *Installing the SunOS 4.0.3 Release* (800-3812-10A) and is marked
where it has not been run here yet.

## 1. Make the images, on a PC

`tools/mktape` needs Python 3 and nothing else (and `unrar` or 7-Zip to read a
`.rar` directly).

```sh
tools/mktape -o sunos-4.0-sun2.qic   sunos_4.0_sun2/     # a folder with tape1/ and tape2/
tools/mktape -o sunos-4.0.3-sun2.qic sunos_4.0.3_sun2.rar
tools/mktape --disk sd0.img
```

* A `.qic` is the whole set: both volumes, every file in order. The OSD's
  *Tape volume* picks which cartridge is in the drive.
* `sd0.img` is a 329 MB Micropolis 1558 (1218 cylinders, 15 heads, 35
  sectors), empty but already labelled -- `/` 16 MB on `a`, swap 32 MB on `b`,
  `/usr` 278 MB on `g` -- so `format` is not needed. Until SunOS is installed
  its boot block says so and returns to the monitor.

Copy all three, with `boot0.rom`, to `/media/fat/games/Sun-2/` on the MiSTer.

## 2. Mount them

In the OSD (F12): *SCSI disk (sd0)* `sd0.img`, *Tape (st0)*
`sunos-4.0-sun2.qic`, *Tape volume* `1`, then *Reset*.

```
Boot: sd(0,0,0)vmunix
This disk is labelled but has no SunOS on it yet.
To install from the tape in st0:  b st()
>
```

The keyboard is a Sun one on a PC: **hold Right Alt + F1 and press A** for the
Sun's `L1-A`, the abort back to this `>` prompt. L1 has to still be down when A
goes down; let go of it first and SunOS just sees an `a`.

## 3. Copy the miniroot onto the swap partition

```
> b st()
Boot: st(0,0,0)
Boot: st(0,0,2)                           tape file 2: the standalone copy program
Size: 18528+6760+113464 bytes
Standalone Copy
From: st(0,0,3)                           tape file 3: the miniroot
To: sd(0,0,1)                             sd0, partition b
Copy completed - 6154240 bytes
Boot:
```

`b st()` loads `tpboot` from the first file on the tape; every `Boot:` prompt
after the first is tpboot's own, and tpboot is what can read a file out of a
file system -- the PROM itself cannot, so `b sd(0,0,1)vmunix` at `>` fails with
a bus error.

## 4. Boot the miniroot

At the same `Boot:` prompt (or `b st()` again first):

```
Boot: sd(0,0,1)vmunix
SunOS Release 4.0 (GENERIC) #3: Sat Apr 9 00:12:28 PDT 1988
...
sd0:  <Micropolis 1558 cyl 1218 alt 2 hd 15 sec 35>
st0 at sc0 slave 32
...
root filesystem type ( spec 4.2 nfs lo ): 4.2
root device ( sd%d[a-h] ): sd0b
root on sd0b fstype 4.2
swap filesystem type ( spec 4.2 nfs lo ): spec
swap device ( sd%d[a-h] ): sd0b
Swapping on root device, ok? y
#
```

The miniroot comes up with its root read-only and no `fstab`, so make it
writable by naming the device -- and then empty `/etc/mtab` again, because the
remount records `sd0b` there and suninstall's `format` will then refuse to label
a disk it believes is mounted ("Operation on mounted disks must be
interactive"):

```
# mount -o remount /dev/sd0b /
# cp /dev/null /etc/mtab
# TERM=sun; export TERM
```

## 5. suninstall

```
# suninstall
```

It asks for the time zone (e.g. `US/Eastern`), whether the date is right, and
the terminal type (`3`, Sun Workstation), then shows its main menu. In the
forms, **x** selects, **space** moves to the next choice, **Ctrl-N** and
**Ctrl-P** move between fields, **Delete** erases, **Return** ends a typed
field.

* **assign host information:** a name (Delete the `noname` first); type
  *standalone*; Ethernet interface **none** -- the network is not wired up yet,
  and the `ie0` default comes with an invalid address; YP none; operation
  *install*. Move past the last field and answer `y` to "Are you finished".
* **assign disk information:** select `sd0`; Disk Label **existing** (the one
  `mktape` wrote); free hog partition **g**. In the table: `a` mount point
  `/`, preserve `n`; `b` and `c` nothing; `g` mount point `/usr`, preserve
  `n`. Then `y` (Return) to "Ok to use this partition table" and `y` to
  "finished".
* **assign software information:** device type **st0**, drive type
  **local** -- it reads the tape's table of contents here -- and **all**, which
  includes SunView. `y` to "Ok to use this extractlist", `y` to "finished".
* **start the installation.**

```
System Installation begin :
Label disk(s) :
        sd0
Create/Check File Systems :
/dev/rsd0a:     32024 sectors in 61 cylinders of 15 tracks, 35 sectors
        16.4Mb in 4 cyl groups (16 c/g, 4.30Mb/g, 1920 i/g)
/dev/rsd0g:     543374 sectors in 1035 cylinders of 15 tracks, 35 sectors
        278.2Mb in 65 cyl groups (16 c/g, 4.30Mb/g, 1984 i/g)
```

then it extracts what was chosen. When it wants the second tape
(*not yet run here*):

```
Load release tape #2 for architecture sun2 and hit <RETURN>:
```

set *Tape volume* to `2` in the OSD, then press Return.

## 6. Boot the installed system

*(Not yet run here.)* At `>`, `b sd()`, or reset: the PROM's auto-boot of
`sd(0,0,0)vmunix` now finds the boot block `installboot` wrote. Log in as
`root`, no password; `suntools` starts SunView.

## 7. Upgrade to 4.0.3 (optional)

*(Not yet run here.)* With 4.0 installed, mount `sunos-4.0.3-sun2.qic`, *Tape
volume* `1`, boot its miniroot exactly as in steps 3-4 (its files are in the
same places), and

```
# cd /usr/etc/upgrade
# sunupgrade
```

## Notes

* **MUNIX** (tape file 4, its file system in file 5) is only needed to run
  `format` on an unlabelled disk. Its questions are: root filesystem type
  `4.2`, root device `rd0`, initialize ram disk from `st0`, tape file number
  `5`, swap filesystem type `spec`, swap device `sd0b`. It needs 4 MB of
  memory; the machine has 8.
* **The date.** The time-of-day chip comes up at December 1987 for now; set the
  date with `date` once the system runs.
* **Small kernel.** GENERIC carries drivers for hardware this machine does not
  have. Build a smaller one from the *Sys* files once the system is up.
* **The tape is read only.** Writes, file marks and erase are refused as write
  protected, as a cartridge with its tab set would be.
