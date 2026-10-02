#!/usr/bin/env python3
#
# The tapes tb_mt02 reads, built through tools/mktape so that the image format
# is tested from both ends.  Every 512-byte block says where it came from --
# "V<volume>F<file>B<block>" and then a pattern of the three -- so a block read
# from the wrong place cannot pass for the right one.
#
#   two.qic   volume 1: files of 3, 1, 70 and 2 blocks
#             volume 2: files of 2, 0 and 5 blocks
#   raw.qic   no header: 9 blocks of volume 1, file 0, as one file
#
import os
import subprocess
import sys

out = sys.argv[1]
mktape = sys.argv[2]


def block(v, f, b):
    tag = f"V{v}F{f:02d}B{b:04d}".encode()
    body = bytes((v * 31 + f * 7 + b + i) & 0xFF for i in range(512 - len(tag)))
    return tag + body


def write_volume(d, v, sizes):
    os.makedirs(d, exist_ok=True)
    for f, n in enumerate(sizes):
        with open(os.path.join(d, f"{f + 1:02d}"), "wb") as fh:
            for b in range(n):
                fh.write(block(v, f, b))


root = os.path.join(out, "mt02")
write_volume(os.path.join(root, "two", "tape1"), 1, [3, 1, 70, 2])
write_volume(os.path.join(root, "two", "tape2"), 2, [2, 0, 5])
subprocess.run([sys.executable, mktape, "-o", os.path.join(out, "two.qic"),
                os.path.join(root, "two")], check=True)
with open(os.path.join(out, "raw.qic"), "wb") as fh:
    for b in range(9):
        fh.write(block(1, 0, b))
