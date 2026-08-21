#!/usr/bin/env python3
# patch_inittrap.py -- ISSUE-52 round 3: capture the user PC main hands to the
# initial rte (2026-08-21).  Companion object: src/inittrap.s.
#
# _start @0x44 is `jsr main` with its relocation at 0x46.  Retarget it to ini_main,
# which calls the real main, latches what it returned, and returns that value in d0
# unchanged so _start's `bmis` and frame build are bit-identical.
#
# Usage: python3 patch_inittrap.py <image>
import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
RELOC = 0x00000046
OLD, NEW = "main", "ini_main"


def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]


def main():
    buf = bytearray(open(IMG, "rb").read())
    e_shoff, e_shentsize = u32(buf, 32), u16(buf, 46)
    e_shnum, e_shstrndx = u16(buf, 48), u16(buf, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(buf, o), "offset": u32(buf, o + 16), "size": u32(buf, o + 20),
                   "link": u32(buf, o + 24), "entsize": u32(buf, o + 36)})
    shstr = sh[e_shstrndx]["offset"]

    def nm(s):
        e = buf.index(b"\0", shstr + s["name"])
        return buf[shstr + s["name"]:e].decode()

    sec = {nm(s): s for s in sh}
    rela = sec[".rela.text"]
    symtab = sh[rela["link"]]
    strtab = sh[symtab["link"]]

    def symname(i):
        o = symtab["offset"] + i * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        return buf[strtab["offset"] + n:e].decode()

    for i in range(rela["size"] // rela["entsize"]):
        o = rela["offset"] + i * rela["entsize"]
        if u32(buf, o) != RELOC:
            continue
        r_info = u32(buf, o + 4)
        cur = symname(r_info >> 8)
        if cur == NEW:
            print("  [skip] _start jsr main already retargeted @0x%x" % RELOC); return
        if cur != OLD:
            raise SystemExit("ABORT: reloc @0x%x names %r, expected %r" % (RELOC, cur, OLD))
        for j in range(symtab["size"] // symtab["entsize"]):
            if symname(j) == NEW:
                struct.pack_into(">I", buf, o + 4, (j << 8) | (r_info & 0xFF))
                open(IMG, "wb").write(buf)
                print("  [ok]   ISSUE-52 init entry latch installed @0x%x  main -> %s" % (RELOC, NEW))
                return
        raise SystemExit("ABORT: %s not defined (is inittrap.o linked?)" % NEW)

    raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)


main()
