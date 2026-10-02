# Installing SunOS on the MiSTer Sun-2

This installs SunOS 4.0 onto an empty disk from the release tapes, the way it
was done on a real Sun-2/160: boot the tape, copy the miniroot onto the disk's
swap partition, boot that, and run `suninstall`. After that, the 4.0.3 upgrade
tapes can bring it to 4.0.3.

**Which tapes.** A full install needs the **SunOS 4.0** Sun-2 tapes (two QIC
volumes, April 1988). The common **4.0.3** set, 700-2157-10, is the *upgrade*
release: its miniroot runs only `sunupgrade`, which upgrades an existing 4.0 or
4.0.1 system, and has no `suninstall`. So 4.0 first, then 4.0.3 over it.

Everything below up to and including SunView on the installed system has been
done on a MiSTer, with the screens quoted from it; the whole install, both tapes
and every package, takes about an hour. Only the 4.0.3 upgrade follows Sun's
*Installing the SunOS 4.0.3 Release* (800-3812-10A) and the upgrade tape's own
README without having been run
here yet.

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
The names are free -- the OSD browses for them -- as long as disks end in
`.img` or `.vhd` and tapes in `.qic`. For a bigger disk, with just `/` and
swap, see [A 1 GB disk](#a-1-gb-disk) at the end.

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

then it extracts what was chosen -- `usr`, about 19 MB, takes some fifteen
minutes, the whole first volume about twenty-five. When it wants the second
tape:

```
Extracting "SunView_Users" files from "/dev/nrst0" release tape.
Load release tape #2 for architecture sun2 and hit <RETURN>:
```

open the OSD, set *Tape volume* to `2`, close it, and press Return:

```
Extracting "SunView_Programmers" files from "/dev/nrst0" release tape.
```

It finishes by checking both file systems:

```
sun2 Installation Completed.
System installation continues ....
File systems check :
/dev/rsd0a: 366 files, 1533 used, 13438 free
/dev/rsd0g: 6653 files, 53546 used, 200963 free
System installation completed.
Reboot your system and configure a kernel for your system.
#
```

## 6. Boot the installed system

`sync`, then L1-A, then `b sd()` (or just reset: the PROM's auto-boot of
`sd(0,0,0)vmunix` now finds the boot block `installboot` wrote):

```
> b sd()
Boot: sd(0,0,0)vmunix
root on sd0a fstype 4.2
Boot: vmunix
SunOS Release 4.0 (GENERIC) #3: Sat Apr 9 00:12:28 PDT 1988
...
starting rpc and net services: portmap keyserv routed.
...
sun2 login:
```

Log in as `root`, no password (set one with `passwd`). `suntools` starts
SunView.

## 7. Upgrade to 4.0.3 (optional)

*(Not yet run here. This follows the upgrade tape's own
`/usr/etc/upgrade/README` and the `sunupgrade` scripts beside it, read off the
4.0.3 miniroot; the prompts below are quoted from those scripts.)*

The 4.0.3 tapes upgrade a running 4.0 or 4.0.1 system in place: `sunupgrade`
mounts the installed disk under `/a` and extracts the new files over it.

**It needs a separate `/usr`.** `sunupgrade` decides what kind of machine it is
upgrading from the installed disk's `/etc/fstab`, and a system with no `/usr`
file system of its own looks to it like a *dataless client*, whose `/usr` comes
from a server over the network -- which it then tries to mount. The standard
layout (`/usr` on `g`, as in step 5) is fine; the 1 GB root-and-swap layout
below is not.

1. **Back up the disk image first** -- Sun's README says so in capitals, and a
   copy of the image is a complete, bootable copy of the machine.
2. Shut the 4.0 system down cleanly (`sync`, then L1-A, or `/etc/halt`).
3. In the OSD, mount `sunos-4.0.3-sun2.qic` as the tape, *Tape volume* `1`.
   Leave the installed disk mounted.
4. Copy the 4.0.3 miniroot onto swap and boot it, as in steps 3 and 4 -- the
   upgrade tape has its files in the same places. This only overwrites the
   swap partition; `/` and `/usr` are not touched:

   ```
   > b st()
   Boot: st(0,0,2)
   From: st(0,0,3)
   To: sd(0,0,1)
   Boot: sd(0,0,1)vmunix
   ```

   The kernel calls itself `SunOS Release 4.0.3 (SUNUPGRADE)`. Answer its
   questions as before, then make the miniroot writable -- `sunupgrade` writes
   into its `/tmp`, `/dev` and its own directory:

   ```
   # mount -o remount /dev/sd0b /
   ```

5. Run it, in single-user mode, as the miniroot is:

   ```
   # cd /usr/etc/upgrade
   # sunupgrade
   Enter root disk partition for sun2 architecture (e.g. xy0a): sd0a
   Where is the tape drive located? (local | remote): local
   Enter controller type ( st | mt | xt ): st
   ...
   Starting upgrade now. Continue ? (y/n): y
   This is going to take some time.
   ```

   It checks the tape is a 4.0.3 sun2 release, mounts `/dev/sd0a` on `/a`
   and the rest of the installed `fstab` under it, and extracts. If it asks
   for the second volume, set *Tape volume* to `2` in the OSD and press
   Return, as during the install.
6. **The small kernel, before rebooting.** 4.0.3 comes with a preconfigured
   small kernel for SCSI-only machines -- which this is -- and the script that
   installs it depends on files `sunupgrade` has just left, so the README says
   not to reboot first:

   ```
   # /usr/etc/upgrade/install_small_kernel
   Do you wish to continue? (y/n):  y
   Install small kernel on sun2? (y/n)  y
   ```

7. `sync`, L1-A, `b sd()`. The machine comes up on 4.0.3; the old kernel is
   kept beside the new one under a `pre`-release name.
8. **Customised files are not overwritten.** Files under `/etc` and `/var`
   that the upgrade carries new versions of are installed beside the old ones
   with the release as a suffix (Sun's example: `rc.local-4.0_REV_B` next to
   `rc.local`), and the list of them is in
   `/usr/etc/upgrade/save/special_files`. On a fresh install nothing was
   customised, so moving each new one into place is enough; otherwise merge
   your changes into the new copy first.

## A 1 GB disk

*(The disk image and the `format.dat` lines are checked; the install onto this
layout has not been run here yet.)*

1 GiB is the most a Sun-2 can address: every Sun-2 SCSI driver sends the
six-byte READ and WRITE, whose block address is 21 bits. To install onto a
disk that size with one big root and swap -- no separate `/usr`.

**This layout cannot be upgraded to 4.0.3 with `sunupgrade`**, which takes a
system without its own `/usr` file system for a dataless client (see step 7).
Install it to stay on 4.0, or keep the standard layout if 4.0.3 is the goal.

### How big to make swap

**32 MB, with `/` taking the rest -- 991 MB.** That is `mktape`'s default:

* The miniroot (5.9 MB) has to fit in swap during the install, and a crash
  dump goes there too and needs the size of memory, 8 MB.
* SunOS 4.0 reserves every process's memory against swap rather than RAM, so
  swap is in effect how much memory all running programs can have between
  them. SunView and a few tools want tens of megabytes; 32 MB, four times the
  machine's memory, is comfortable.
* Beyond that it buys nothing on an 8 MB machine, and every 32 MB is only 3%
  of the disk either way.

Cylinders are half a megabyte, so `--swap` is rounded to that.

### Steps

1. Keep a copy of any disk you want back (a copy of the image is a bootable
   copy of the machine).
2. Make the disk:

   ```sh
   tools/mktape --disk sd0-1g.img --size 1024
   ```

   It is 16 heads of 64 sectors on 2048 cylinders, two of them alternates:
   `/` 991 MB on `a`, swap 32 MB on `b` at the end. `mktape` prints the two
   lines step 4 needs.
3. Mount it as the *SCSI disk*, the 4.0 tape at volume 1, reset, and do steps
   3 and 4 above unchanged: copy the miniroot to `sd(0,0,1)`, boot it, remount
   it and empty `/etc/mtab`.
4. Before suninstall, tell `format` about the disk. SunOS 4.0's
   `/etc/format.dat` knows no SCSI disk bigger than the 327 MB Micropolis, and
   suninstall labels the disk with `format`:

   ```
   # cp /etc/format.dat /etc/format.dat.orig
   # echo 'disk_type = "MiSTer 1024MB" : ctlr = MD21 : ncyl = 2046 : acyl = 2 : pcyl = 2048 : nhead = 16 : nsect = 64 : rpm = 3600 : bpt = 32768' >> /etc/format.dat
   # echo 'partition = "MiSTer 1024MB" : disk = "MiSTer 1024MB" : ctlr = MD21 : a = 0, 2029568 : b = 1982, 65536 : c = 0, 2095104' >> /etc/format.dat
   # tail -2 /etc/format.dat
   ```

   Check them; after a typo, `cp /etc/format.dat.orig /etc/format.dat` and
   type them again. These lines are for the default 32 MB swap: another
   `--size` or `--swap` gives other numbers, so use the lines `mktape`
   printed.
5. `TERM=sun; export TERM`, `suninstall`, and the forms as in step 5, except
   the disk form: label **existing**, free hog **a**, and only `a` gets a
   mount point, `/` (preserve `n`); `b` and `c` stay empty.
6. Boot it as in step 6. `newfs` and the `fsck` on every boot take longer on
   a root this size than on 16 MB.

### Getting the most out of the root

The partition split is the small decision. Two things `newfs` does cost more,
and suninstall runs `newfs` with its defaults:

* **10% is kept back for root** -- about 99 MB here. After the install, boot
  single-user and lower it:

  ```
  > b sd()vmunix -s
  # tunefs -m 2 /dev/rsd0a
  ```

  then go straight to L1-A and `b sd()` -- **without** `sync`, which can write
  the old superblock held in memory back over the one `tunefs` just changed.
  That gives about 80 MB back to everyone.
* **One inode for every 2 KB** of disk: about half a million inodes on a
  991 MB root, roughly 60 MB of inode tables, against the 7,000 or so files a
  full install has. Only `newfs` sets this. One way round it -- *untried
  here*, so an experiment: on the miniroot, before suninstall, run
  `newfs -i 8192 /dev/rsd0a` yourself, and in the disk form answer preserve
  **y** for `a`, so suninstall installs into that file system instead of
  making its own. That would bring the inode tables to about 15 MB.

A full install uses about 55 MB, so even with neither change there is well over
800 MB free.

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
