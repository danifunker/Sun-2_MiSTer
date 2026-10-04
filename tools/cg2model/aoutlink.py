#!/usr/bin/env python3
"""
Link SunOS 68010 a.out objects into one flat image for the cg2model harness.

The harness runs Sun's own libpixrect object code -- the 4.0 release for the
Sun-2, from the user's tape -- in a 68010 emulator, so that the board model
is driven by exactly the bus cycles the real machine will see.  This is the
linker for that: it resolves the members a set of root symbols needs out of
an ar archive (and any loose .o files), lays text, data, bss and commons out
from a base address, relocates them, and turns every symbol still undefined
into a stub the harness serves in C (malloc, bzero, Sun's lmult, ...).

  aoutlink.py -o OUT --base 0x1000 --root _cg2_rop --root _mem_rop \
      [--stub _gp1_sync ...] [--obj kernel.o ...] [--lib libpixrect.a]

writes OUT.bin (the image, loaded at --base) and OUT.sym, one line per
global: `ADDR NAME' for definitions and `ADDR NAME stub' for stubs.  A stub is
ILLEGAL; RTS -- the harness's illegal-instruction hook recognises its address.

The format.  A SunOS 68k object is a.out: a 32-byte header (machine byte,
magic, then text, data, bss, syms, entry, trsize, drsize), text, data, text
relocations, data relocations, a symbol table of 12-byte nlists and a string
table.  A relocation is 8 bytes: the address, then 24 bits of symbol number,
pcrel, a 2-bit length (0 byte, 1 word, 2 long) and extern, high bit first.
A non-extern relocation's symbol number is the segment (4 text, 6 data, 8
bss), and the field holds an address in the object's own frame, where text
starts at 0, data at a_text and bss at a_text + a_data -- the same frame the
object's symbol values are in.  An extern undefined symbol with a nonzero
value is a common block of that size.
"""
import argparse, struct, sys

N_UNDF, N_ABS, N_TEXT, N_DATA, N_BSS = 0, 2, 4, 6, 8
N_EXT = 1


def parse_ar(data):
    if data[:8] != b'!<arch>\n':
        raise SystemExit('not an ar archive')
    off, out = 8, []
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[:16].decode().rstrip().rstrip('/')
        size = int(hdr[48:58].decode())
        out.append((name, data[off + 60:off + 60 + size]))
        off += 60 + size + (size & 1)
    return [(n, b) for n, b in out if not n.startswith('__.SYMDEF')]


class Obj:
    def __init__(self, name, d):
        self.name = name
        text, dat, bss, syms, entry, trsize, drsize = struct.unpack('>7I', d[4:32])
        if struct.unpack('>H', d[2:4])[0] != 0o407:
            raise SystemExit(f'{name}: not an OMAGIC object')
        p = 32
        self.text = bytearray(d[p:p + text]); p += text
        self.data = bytearray(d[p:p + dat]); p += dat
        self.bss = bss
        self.trel = self._rel(d[p:p + trsize]); p += trsize
        self.drel = self._rel(d[p:p + drsize]); p += drsize
        stroff = p + syms
        self.syms = []
        for i in range(syms // 12):
            strx, typ, other, desc, value = struct.unpack('>IBBhI', d[p + 12 * i:p + 12 * i + 12])
            name_ = ''
            if strx:
                name_ = d[stroff + strx:d.index(b'\0', stroff + strx)].decode()
            self.syms.append((name_, typ, value))
        self.defs = {n for n, t, v in self.syms
                     if t & N_EXT and not t & 0xe0 and t & 0x1e}
        self.undefs = {n for n, t, v in self.syms
                       if t == N_UNDF | N_EXT and v == 0}
        self.commons = {n: v for n, t, v in self.syms
                        if t == N_UNDF | N_EXT and v != 0}

    @staticmethod
    def _rel(b):
        out = []
        for i in range(len(b) // 8):
            addr, w = struct.unpack('>II', b[8 * i:8 * i + 8])
            out.append((addr, w >> 8, (w >> 7) & 1, (w >> 5) & 3, (w >> 4) & 1))
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', required=True)
    ap.add_argument('--base', type=lambda s: int(s, 0), default=0x1000)
    ap.add_argument('--lib', action='append', default=[])
    ap.add_argument('--obj', action='append', default=[])
    ap.add_argument('--root', action='append', default=[])
    ap.add_argument('--stub', action='append', default=[],
                    help='serve this symbol as a stub even if the library defines it')
    a = ap.parse_args()

    stubbed = set(a.stub)
    objs = [Obj(f, open(f, 'rb').read()) for f in a.obj]
    lib = []
    for path in a.lib:
        lib += [Obj(n, b) for n, b in parse_ar(open(path, 'rb').read())]
    provider = {}
    for o in lib:
        for s in o.defs:
            provider.setdefault(s, o)

    chosen = list(objs)
    defined = set().union(*(o.defs for o in chosen)) if chosen else set()
    want = set(a.root)
    for o in chosen:
        want |= o.undefs
    while True:
        missing = {s for s in want - defined - stubbed if s in provider}
        if not missing:
            break
        for s in sorted(missing):
            o = provider[s]
            if o not in chosen:
                chosen.append(o)
                defined |= o.defs
                want |= o.undefs
    for r in a.root:
        if r not in defined:
            raise SystemExit(f'root {r} is not defined anywhere')

    # layout: all text, then all data, then all bss, then commons, then stubs
    addr = a.base
    for o in chosen:
        o.tbase = addr
        addr += (len(o.text) + 3) & ~3
    for o in chosen:
        o.dbase = addr
        addr += (len(o.data) + 3) & ~3
    for o in chosen:
        o.bbase = addr
        addr += (o.bss + 3) & ~3
    gsym = {}
    for o in chosen:
        for n, t, v in o.syms:
            if not (t & N_EXT) or t & 0xe0 or n in stubbed:
                continue
            seg = t & 0x1e
            if seg == N_TEXT:
                gsym[n] = o.tbase + v
            elif seg == N_DATA:
                gsym[n] = o.dbase + v - len(o.text)
            elif seg == N_BSS:
                gsym[n] = o.bbase + v - len(o.text) - len(o.data)
            elif seg == N_ABS:
                gsym[n] = v
    commons = {}
    for o in chosen:
        for n, size in o.commons.items():
            if n not in gsym:
                commons[n] = max(commons.get(n, 0), size)
    for n, size in sorted(commons.items()):
        gsym[n] = addr
        addr += (size + 3) & ~3
    undefined = sorted({s for o in chosen for s in o.undefs} - set(gsym))
    stubs = {}
    for n in undefined:
        stubs[n] = gsym[n] = addr
        addr += 4
    end = addr

    image = bytearray(end - a.base)
    for o in chosen:
        for seg, base, body, rels in ((N_TEXT, o.tbase, o.text, o.trel),
                                      (N_DATA, o.dbase, o.data, o.drel)):
            body = bytearray(body)
            for raddr, sym, pcrel, length, ext in rels:
                fmt = {0: '>b', 1: '>h', 2: '>i'}[length]
                size = 1 << length
                old = struct.unpack(fmt, body[raddr:raddr + size])[0]
                if ext:
                    target = gsym[o.syms[sym][0]]
                    new = old + target
                else:
                    s = sym & 0x1e
                    if s == N_TEXT:
                        new = old - 0 + o.tbase
                    elif s == N_DATA:
                        new = old - len(o.text) + o.dbase
                    elif s == N_BSS:
                        new = old - len(o.text) - len(o.data) + o.bbase
                    elif s == N_ABS:
                        new = old
                    else:
                        raise SystemExit(f'{o.name}: relocation to segment {sym}')
                if pcrel:
                    # Sun's cc emits none for these libraries; refuse
                    # rather than guess at the convention
                    raise SystemExit(f'{o.name}: pc-relative relocation')
                mask = (1 << (8 * size)) - 1
                body[raddr:raddr + size] = (new & mask).to_bytes(size, 'big')
            image[base - a.base:base - a.base + len(body)] = body
    for n, ad in stubs.items():
        image[ad - a.base:ad - a.base + 4] = b'\x4a\xfc\x4e\x75'

    open(a.o + '.bin', 'wb').write(image)
    with open(a.o + '.sym', 'w', newline='\n') as f:
        for n, ad in sorted(gsym.items(), key=lambda x: x[1]):
            f.write(f'{ad:06x} {n}{" stub" if n in stubs else ""}\n')
        f.write(f'{end:06x} _end\n')
    print(f'{a.o}: {len(chosen)} objects, {len(stubs)} stubs, '
          f'{a.base:#x}..{end:#x}: ' + ' '.join(o.name for o in chosen),
          file=sys.stderr)


if __name__ == '__main__':
    main()
