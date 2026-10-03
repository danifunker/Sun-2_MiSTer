# Installing SunOS on the MiSTer Sun-2

This installs SunOS 4.0 onto an empty disk from the release tapes, the way it
was done on a real Sun-2/160: boot the tape, copy the miniroot onto the disk's
swap partition, boot that, and run `suninstall`. After that, the 4.0.3 upgrade
tapes can bring it to 4.0.3.

**Which tapes.** A full install needs the **SunOS 4.0** Sun-2 tapes (two QIC
volumes, April 1988). The common **4.0.3** set, 700-2157-10, is the *upgrade*
release: its miniroot runs only `sunupgrade`, which upgrades an existing 4.0 or
4.0.1 system, and has no `suninstall`. So 4.0 first, then 4.0.3 over it.

All of it has been done on a MiSTer, with the screens quoted from it: the
install onto the Micropolis disk and onto a 1 GB one, SunView, and the 4.0.3
upgrade. The install, both tapes and every package, takes about an hour on the
Micropolis and an hour and a half on 1 GB, most of the difference being `newfs`;
the upgrade takes under an hour.

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
* `mktape` changes one thing on the way: every `/etc/format.dat` on the tape
  (the miniroot's, MUNIX's, the root tar's and Install's) learns the 128, 256,
  512 and 1024 MB disks `--size` makes, so `format` can label them. Nothing else
  changes, and no tape file changes size. `--no-patch` leaves the tape as it
  came; `tools/mktape --patch old.qic` brings a tape built before this up to
  date, in place, and replaces the entries an older `mktape` added.
* `sd0.img` is a 329 MB Micropolis 1558 (1218 cylinders, 15 heads, 35
  sectors), empty but already labelled -- `/` 16 MB on `a`, swap 32 MB on `b`,
  `/usr` 278 MB on `g` -- so `format` is not needed. Until SunOS is installed
  its boot block says so and returns to the monitor.

Copy all three, with `boot0.rom`, to `/media/fat/games/Sun-2/` on the MiSTer.
The names are free -- the OSD browses for them -- as long as disks end in
`.img` or `.vhd` and tapes in `.qic`. For a bigger disk, see
[A 1 GB disk](#a-1-gb-disk) at the end.

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

The 4.0.3 tapes upgrade a running 4.0 or 4.0.1 system in place: `sunupgrade`
mounts the installed disk under `/a` and extracts the new files over it. Done
here on the 1 GB disk below, in about fifty minutes.

**It needs a separate `/usr`.** `sunupgrade` decides what kind of machine it is
upgrading from the installed disk's `/etc/fstab` (`get_machtype`), and a system
with no 4.2 `/usr` file system of its own looks to it like a *dataless client*,
whose `/usr` comes from a server over the network -- which it then tries to
mount. The standard layout (`/usr` on `g`, as in step 5) is fine, and so is the
1 GB disk made with `--root`; the 1 GB root-and-swap layout is not.

1. **Back up the disk image first** -- Sun's README says so in capitals, and a
   copy of the image is a complete, bootable copy of the machine.
2. Shut the 4.0 system down cleanly: log in as root and `/etc/halt`.
3. Mount `sunos-4.0.3-sun2.qic` as the tape, *Tape volume* `1`, with the
   installed disk still mounted, and reset. The PROM now finds SunOS on the
   disk and boots it: let it reach `login:`, log in, and `/etc/halt` again.
4. Copy the 4.0.3 miniroot onto swap and boot it, as in steps 3 and 4 -- the
   upgrade tape has its files in the same places. This only overwrites the
   swap partition; `/` and `/usr` are not touched:

   ```
   > b st()
   Boot: st(0,0,2)
   Size: 20536+5856+82752 bytes
   Standalone Copy
   From: st(0,0,3)
   To: sd(0,0,1)
   Copy completed - 6154240 bytes
   Boot: sd(0,0,1)vmunix
   SunOS Release 4.0.3 (SUNUPGRADE) #1: Wed Apr 19 17:17:24 PDT 1989
   ...
   root on sd0b fstype 4.2
   swap on sd0b fstype spec size 32256K
   #
   ```

   It asks nothing about root and swap, unlike 4.0's. Make it writable --
   `sunupgrade` writes into its `/tmp`, `/dev` and its own directory:

   ```
   # mount -o remount /dev/sd0b /
   ```

5. Run it:

   ```
   # cd /usr/etc/upgrade
   # ./sunupgrade
   Enter root disk partition for sun2 architecture (e.g. xy0a): sd0a
   Wait ...
   Is this a file-server (as opposed to standalone/dataless-client) ? (y/n): n
   Where is the tape drive located? (local | remote): local
   Enter controller type ( st | mt | xt ): st
   Extracting TOC (Table Of Contents)
   Starting upgrade now. Continue ? (y/n): y
   This is going to take some time.
   Extracting "root" files
   Extracting "usr" files
   Extracting "Kvm" files
   Extracting "Install" files
   Load tape volume 2 for sun2 and <RETURN>
   ```

   `Wait ...` is `fsck` and the mounts under `/a`, a few minutes on 1 GB. At
   the volume prompt set *Tape volume* to `2` in the OSD and press Return, as
   during the install. It ends:

   ```
   Installing bootblock to root partition /dev/rsd0a ..
   Installing /sbin files ..
   Doing file system checks
   ...
   sunupgrade: Done upgrading to 4.0.3.
   ```

6. **The small kernel, before rebooting.** 4.0.3 comes with a preconfigured
   small kernel for SCSI-only machines -- which this is -- and the script that
   installs it depends on files `sunupgrade` has just left, so the README says
   not to reboot first:

   ```
   # /usr/etc/upgrade/install_small_kernel
   Do you wish to continue? (y/n):  y
   The small pre-configured kernel has been installed on:
           sun2
   ```

   It keeps the GENERIC kernel as `/vmunix.orig` (and `sunupgrade` kept 4.0's
   as `/vmunix.pre_4.0.3`), so `b sd()vmunix.orig` is the way back if the small
   one ever will not do.
7. `sync`, L1-A, `b sd()`:

   ```
   SunOS Release 4.0.3 (GENERIC_SMALL) #1: Mon Apr 24 15:28:53 PDT 1989
   ...
   sun2 login:
   ```

   The small kernel leaves 7,278,592 bytes free against GENERIC's 7,098,368.
8. **Customised files are not overwritten.** Files under `/etc` and `/var`
   that the upgrade carries new versions of are installed beside the old ones
   with the release as a suffix (Sun's example: `rc.local-4.0_REV_B` next to
   `rc.local`), and the list of them is in
   `/usr/etc/upgrade/save/special_files`. On a fresh install nothing was
   customised, so moving each new one into place is enough; otherwise merge
   your changes into the new copy first.

## A 1 GB disk

1 GiB is the most a Sun-2 can address: every Sun-2 SCSI driver sends the
six-byte READ and WRITE, whose block address is 21 bits. `mktape` makes a disk
that size in two layouts:

```sh
tools/mktape --disk sd0-1g.img --size 1024 --root 32   # / 31.5 MB, swap 31.5 MB, /usr 960 MB
tools/mktape --disk sd0-1g.img --size 1024             # / 991.5 MB, swap 31.5 MB
```

**The first is the one to use, and the one done here**: installed from the 4.0
tapes, booted, and upgraded to 4.0.3 on a MiSTer. The second, root and swap
only, cannot be upgraded -- `sunupgrade` takes it for a dataless client (step
7) -- and has not been installed here, though nothing in it differs in kind.

Both are 16 heads of 64 sectors on 2048 cylinders, two of them alternates, and
the tape already knows them as `MiSTer 1024MB` (step 1), so nothing has to be
typed into `format.dat`.

**Why 31.5 MB and not 32.** The standalone disk driver -- in the copy program,
`tpboot`, and the installed system's `boot` -- keeps a partition's size in 16
bits and clips every transfer to it. A partition of exactly 32 MB is 65536
blocks, which it reads as 0, so the miniroot copy fails at once:

```
To: sd(0,0,1)
Write error
Copy completed - 0 bytes
```

and a 32 MB root would leave `boot` unable to read the kernel. So `mktape`
keeps `a` and `b` a cylinder clear of any multiple of 32 MB, whatever `--root`
and `--swap` ask for. The kernel's own driver has no such limit.

### How big to make swap and root

**Swap 32 MB** (`--swap`, 31.5 after the above):

* The miniroot (5.9 MB) has to fit in swap during the install, and a crash
  dump goes there too and needs the size of memory, 8 MB.
* SunOS 4.0 reserves every process's memory against swap rather than RAM, so
  swap is in effect how much memory all running programs can have between
  them. SunView and a few tools want tens of megabytes; 32 MB, four times the
  machine's memory, is comfortable.
* Beyond that it buys nothing on an 8 MB machine.

**Root 32 MB** (`--root`): a full 4.0 install puts 1.5 MB there, and 4.0.3
brings it to 3.2 MB, with the old and the GENERIC kernels kept beside the new
one. `/var` and `/tmp` live in it too, which is what the rest is for.

### Steps

1. Make the disk, as above, and mount it as the *SCSI disk* with the 4.0 tape
   at volume 1. Reset.
2. Steps 3 and 4 unchanged: copy the miniroot to `sd(0,0,1)`, boot it, remount
   it and empty `/etc/mtab`. The kernel reports
   `sd0: <MiSTer 1024MB cyl 2046 alt 2 hd 16 sec 64>`.
3. suninstall as in step 5, the disk form showing the label:

   ```
   PARTITION START_CYL BLOCKS    SIZE     MOUNT PT        PRESERVE(Y/N)
       a     0         64512     33       /               n
       b     63        64512     33
       c     0         2095104   1072
       g     126       1966080   1006     /usr            n
   ```

   Label **existing**, free hog **g**, `/` on `a` and `/usr` on `g`, neither
   preserved. (SIZE is in millions of bytes.) It labels the disk and makes the
   file systems:

   ```
   Label disk(s) :
           sd0
   Create/Check File Systems :
   /dev/rsd0a:     64512 sectors in 63 cylinders of 16 tracks, 64 sectors
           33.0Mb in 4 cyl groups (16 c/g, 8.39Mb/g, 2048 i/g)
   /dev/rsd0g:     1966080 sectors in 1920 cylinders of 16 tracks, 64 sectors
           1006.6Mb in 120 cyl groups (16 c/g, 8.39Mb/g, 2048 i/g)
   ...
   /dev/rsd0a: 356 files, 1533 used, 29618 free
   /dev/rsd0g: 6653 files, 53547 used, 896835 free
   System installation completed.
   ```

4. Boot it as in step 6, and upgrade it as in step 7 if you want 4.0.3:

   ```
   Filesystem            kbytes    used   avail capacity  Mounted on
   /dev/sd0a              31151    3236   24799    12%    /
   /dev/sd0g             950382   58849  796494     7%    /usr
   ```

**`SUMMARY INFORMATION BAD (SALVAGED)` and `Reboot failed...help!`** on `/usr`
mean a boot stopped in single user after `fsck` repaired it. It follows a stop
without `/etc/halt` -- leaving the core, or a reset, while SunOS runs -- and
was seen once after a clean halt on 4.0. `rc.boot` mounts `/usr` read-only
before checking it, so the repair is made under a mounted file system, and
`fsck` then exits 8, which `rc.boot` reads as failure. **Do not `sync` or
`/etc/halt` from there**: that writes the kernel's old copy of the summary back
over the repair, and the next boot finds the same fault. What works:

```
# umount /usr                 (complains about /etc/mtab; the unmount happens)
# fsck -y /dev/rsd0g
# reboot
```

and it comes up multi-user with `/usr` clean.

### Getting the most out of /usr

suninstall runs `newfs` with its defaults, and two of them cost more on a big
file system than the partition split does:

* **10% is kept back for root** -- about 95 MB of `/usr`. After the install,
  boot single-user and lower it:

  ```
  > b sd()vmunix -s
  # tunefs -m 2 /dev/rsd0g
  ```

  then go straight to L1-A and `b sd()` -- **without** `sync`, which can write
  the old superblock held in memory back over the one `tunefs` just changed.
* **One inode for every 2 KB** of disk: about half a million inodes on 960 MB,
  roughly 60 MB of inode tables, against the 7,000 or so files a full install
  has. Only `newfs` sets this. One way round it -- *untried here*, so an
  experiment: on the miniroot, before suninstall, run `newfs -i 8192
  /dev/rsd0g` yourself, and in the disk form answer preserve **y** for `g`, so
  suninstall installs into that file system instead of making its own.

**Any other size** `--size` makes is not on the tape unless it is 128, 256 or
512 MB; `mktape` prints the two `format.dat` lines for it, to add to the
miniroot's copy before suninstall:

```
# cp /etc/format.dat /etc/format.dat.orig
# echo '<the disk_type line mktape printed>' >> /etc/format.dat
# echo '<the partition line>' >> /etc/format.dat
```

**Why `format.dat` matters at all.** suninstall labels the disk with `format`,
and SunOS reports this machine's SCSI disk as an Adaptec ACB4000 -- `format`
offers the ACB4000 types for it. Given a labelled disk of a type it does not
know, `format` builds one from the label but stops to ask for the two things an
ACB4000 type carries and a label does not, `Need info -- Enter buffer skew` and
`write precomp cylinder`; and choosing that built type again from its `type`
menu crashed it (`Memory fault - core dumped`). The tape's entries are ACB4000
ones with both filled in, and `format` then selects the disk without a
question.

## Notes

* **MUNIX** (tape file 4, its file system in file 5) is only needed to run
  `format` on an unlabelled disk. Its questions are: root filesystem type
  `4.2`, root device `rd0`, initialize ram disk from `st0`, tape file number
  `5`, swap filesystem type `spec`, swap device `sd0b`. It needs 4 MB of
  memory; the machine has 8.
* **The date.** The time-of-day chip comes up at December 1987 for now; set the
  date with `date` once the system runs.
* **Small kernel.** GENERIC carries drivers for hardware this machine does not
  have. On 4.0.3, step 7's `install_small_kernel` puts in Sun's own
  (`GENERIC_SMALL`), which finds everything this machine has; on 4.0, build a
  smaller one from the *Sys* files once the system is up.
* **The tape is read only.** Writes, file marks and erase are refused as write
  protected, as a cartridge with its tab set would be.
