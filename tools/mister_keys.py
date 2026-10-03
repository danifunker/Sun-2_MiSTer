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
#             {BS} {DEL} {TAB} {F1}..{F11}, and {PIPE} for a `|'
#
# and, through a second virtual device -- a USB mouse, created only when the
# text uses one of these:
#
#     {M dx dy}   move the mouse by dx, dy counts (right and down positive,
#                 as Linux reports them), in steps of at most 8
#     {ML} {MM} {MR}         click the left, middle or right button
#     {ML+} {ML-} ...        press or release one, for a drag
#
# Letters, digits, space and . / - , = ; ' and their shifted forms are typed
# as themselves.  Python 3 standard library only; MiSTer's Linux is 32-bit ARM.
#
import fcntl
import os
import struct
import sys
import time

EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y = 0, 1
BTN = {"L": 0x110, "R": 0x111, "M": 0x112}
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
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


def uinput_device(name, product, evbits, keybits, relbits=()):
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    for ev in evbits:
        fcntl.ioctl(fd, UI_SET_EVBIT, ev)
    for code in keybits:
        fcntl.ioctl(fd, UI_SET_KEYBIT, code)
    for code in relbits:
        fcntl.ioctl(fd, UI_SET_RELBIT, code)
    # struct uinput_user_dev: name[80], input_id, ff_effects_max, 4 x abs[64]
    dev = struct.pack("80sHHHHI", name, 3, 0x1234, product, 1, 0)
    os.write(fd, dev + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def main():
    text = sys.argv[1] if len(sys.argv) > 1 else ""
    fd = uinput_device(b"sun2-remote-keyboard", 0x5678, [EV_KEY], range(1, 128))
    mfd = None
    if "{M" in text:
        mfd = uinput_device(b"sun2-remote-mouse", 0x5679, [EV_KEY, EV_REL],
                            BTN.values(), [REL_X, REL_Y])
    time.sleep(2.0)                     # Main_MiSTer notices new input devices by polling

    def emit(code, value, dev=None, etype=EV_KEY):
        t = time.time()
        sec, usec = int(t), int((t % 1) * 1e6)
        f = fd if dev is None else dev
        os.write(f, struct.pack("llHHi", sec, usec, etype, code, value))
        os.write(f, struct.pack("llHHi", sec, usec, EV_SYN, 0, 0))
        time.sleep(0.04)

    def move(dx, dy):
        while dx or dy:
            sx = max(-8, min(8, dx))
            sy = max(-8, min(8, dy))
            t = time.time()
            sec, usec = int(t), int((t % 1) * 1e6)
            if sx:
                os.write(mfd, struct.pack("llHHi", sec, usec, EV_REL, REL_X, sx))
            if sy:
                os.write(mfd, struct.pack("llHHi", sec, usec, EV_REL, REL_Y, sy))
            os.write(mfd, struct.pack("llHHi", sec, usec, EV_SYN, 0, 0))
            dx -= sx
            dy -= sy
            time.sleep(0.02)

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
            if name.startswith("M "):           # {M dx dy}: move the mouse
                _, dx, dy = name.split()
                move(int(dx), int(dy))
            elif name[:1] == "M" and name[1:2] in BTN:     # {ML} {ML+} {ML-}
                b = BTN[name[1]]
                if name[2:] in ("", "+"):
                    emit(b, 1, mfd)
                if name[2:] in ("", "-"):
                    emit(b, 0, mfd)
            elif name.upper() == "PIPE":        # | is Return here, so it has a name
                tap(43, shift=True)
            elif name.startswith("^"):          # {^N}: Control-N
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
    for f in (fd, mfd):
        if f is not None:
            fcntl.ioctl(f, UI_DEV_DESTROY)
            os.close(f)


if __name__ == "__main__":
    main()
