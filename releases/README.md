# Sun-2 core: releases

Three files, and where each goes on the MiSTer's SD card:

| file | goes to | what it is |
|---|---|---|
| `Sun-2_20261004.rbf` | `_Computer/` (or `_Unstable/`) | the core: a Sun-2/160 with the colour board, built from master's RTL as of `cb09e19` |
| `boot0.rom` | `games/Sun-2/boot0.rom` | the Sun-2/50 / 2/160 Rev Q boot PROM (sha256 `8560ef68…4a3f`, the same image as `Inputs/boot0.rom`). Main_MiSTer loads it at start-up, and the machine stays in reset until it has |
| `MiSTer` | `/media/fat/MiSTer` | Main_MiSTer with Sun support, for the network and the ID PROM. Without it the core runs, but its Ethernet goes nowhere |

**`MiSTer`** is upstream Main_MiSTer `57276f0` with the `sun-family` branch on
it (`635a7a5`, `support/sun/`), built for the DE10-Nano's ARM with GCC 10.2,
and nothing else. Its source is that branch of
[danifunker/Main_MiSTer](https://github.com/danifunker/Main_MiSTer/tree/sun-family);
like Main_MiSTer itself it is GPL-3.0. A running Main cannot be overwritten in
place, so keep the old one and swap them:

    cp /media/fat/MiSTer /media/fat/MiSTer.old
    cp MiSTer /media/fat/MiSTer.new && mv /media/fat/MiSTer.new /media/fat/MiSTer

then reboot the MiSTer.

| file | md5 |
|---|---|
| `Sun-2_20261004.rbf` | `aeb3582eac9e360f7a062cdf17b26128` |
| `boot0.rom` | `7c3c88f21e215bb41c88abd8b70e2d9e` |
| `MiSTer` | `93d6b7989ec908c8fa583efc2f2fc216` |

The top-level [README](../README.md) covers disks, tapes, installing SunOS and
the OSD.
