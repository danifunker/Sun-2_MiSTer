#!/usr/bin/env python3
#
# Type at the Sun-2 core from a shell on the MiSTer, through a virtual USB
# keyboard (/dev/uinput) that Main_MiSTer picks up like any other.  It exists
# so a board can be driven over ssh, with `echo screenshot > /dev/MiSTer_cmd`
# to see the result:
#
#     ssh root@mister python3 - 'b st()|' < tools/mister_keys.py
#
# The text uses tb/verilator/hps_io_model.sv's conventions, so a sequence that
# works in simulation can be replayed on the board unchanged:
#
#     |    Return
#     !    Right Alt + F1, then A: the Sun's L1-A, the abort to the monitor
#     ~    a half-second pause
#     {^X}    Control-X
#     {NAME}  one key by name: {F12} {ESC} {UP} {DOWN} {LEFT} {RIGHT} {ENTER}
#             {BS} {DEL} {TAB} {F1}..{F11}
#
# Letters, digits, space and . / - , = ; ' and their shifted forms are typed
# as themselves.  Python 3 standard library only; MiSTer's Linux is 32-bit ARM.
#
import fcntl
import os
import struct
import sys
import time

EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502

KEY = {c: n for n, c in enumerate("1234567890", 2)}
KEY.update({c: n for c, n in zip("qwertyuiop", range(16, 26))})
KEY.update({c: n for c, n in zip("asdfghjkl", range(30, 39))})
KEY.update({c: n for c, n in zip("zxcvbnm", range(44, 51))})
KEY.update({"-": 12, "=": 13, " ": 57, ";": 39, "'": 40, ",": 51, ".": 52, "/": 53})
SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
           "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", ":": ";", '"': "'",
           "<": ",", ">": ".", "?": "/"}
NAMED = {"ESC": 1, "BS": 14, "TAB": 15, "ENTER": 28, "DEL": 111, "UP": 103, "DOWN": 108,
         "LEFT": 105, "RIGHT": 106, "F11": 87, "F12": 88}
NAMED.update({f"F{i}": 58 + i for i in range(1, 11)})
LSHIFT, RALT, LCTRL = 42, 100, 29


def main():
    text = sys.argv[1] if len(sys.argv) > 1 else ""
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for code in range(1, 128):
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    # struct uinput_user_dev: name[80], input_id, ff_effects_max, 4 x abs[64]
    dev = struct.pack("80sHHHHI", b"sun2-remote-keyboard", 3, 0x1234, 0x5678, 1, 0)
    os.write(fd, dev + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(2.0)                     # Main_MiSTer notices new input devices by polling

    def emit(code, value):
        t = time.time()
        sec, usec = int(t), int((t % 1) * 1e6)
        os.write(fd, struct.pack("llHHi", sec, usec, EV_KEY, code, value))
        os.write(fd, struct.pack("llHHi", sec, usec, EV_SYN, 0, 0))
        time.sleep(0.04)

    def tap(code, shift=False):
        if shift:
            emit(LSHIFT, 1)
        emit(code, 1)
        emit(code, 0)
        if shift:
            emit(LSHIFT, 0)

    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "{":
            j = text.index("}", i)
            name = text[i + 1:j]
            if name.startswith("^"):            # {^N}: Control-N
                emit(LCTRL, 1)
                tap(KEY[name[1:].lower()])
                emit(LCTRL, 0)
            else:
                tap(NAMED[name.upper()])
            i = j + 1
            continue
        if ch == "|":
            tap(28)
        elif ch == "~":
            time.sleep(0.5)
        elif ch == "!":
            # L1 must still be down when A goes down: that is what the abort
            # is.  The core keeps an F-key's meaning from when it went down, so
            # Right Alt can be let go first.
            emit(RALT, 1)
            emit(59, 1)                 # F1 down: L1 down
            emit(RALT, 0)
            tap(30)                     # A
            emit(59, 0)                 # L1 up
        elif ch in SHIFTED:
            tap(KEY[SHIFTED[ch]], shift=True)
        elif ch.lower() in KEY:
            tap(KEY[ch.lower()], shift=ch.isupper())
        else:
            sys.exit(f"mister_keys: cannot type {ch!r}")
        i += 1

    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


if __name__ == "__main__":
    main()
