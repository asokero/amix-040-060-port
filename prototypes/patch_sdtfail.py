#!/usr/bin/env python3
# patch_sdtfail.py -- ISSUE-39: count hat_sdtalloc's out-of-contiguous-memory
# warning instead of relying on someone watching the console (2026-07-31).
#
# hat_sdtalloc @0xb632e has exactly one cmn_err call, at 0xb64b0 with its
# relocation at 0xb64b2, and its format string is LC%9 @0xb6297:
#   "hat_sdtalloc(0x%x,0x%x,0x%x) - not enough contiguous memory for segment tables;"
# Retarget that relocation to hat_sdtfail_count (kdbg040.s), which increments a
# counter and tail-jumps into cmn_err -- the warning still prints, unchanged.
#
# Usage: python3 patch_sdtfail.py <image>

import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
RELOC = 0x000B64B2
OLD, NEW = "cmn_err", "hat_sdtfail_count"


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
            print("  [skip] hat_sdtalloc warning already counted @0x%x" % RELOC); return
        if cur != OLD:
            raise SystemExit("ABORT: reloc @0x%x names %r, expected %r" % (RELOC, cur, OLD))
        for j in range(symtab["size"] // symtab["entsize"]):
            if symname(j) == NEW:
                struct.pack_into(">I", buf, o + 4, (j << 8) | (r_info & 0xFF))
                open(IMG, "wb").write(buf)
                print("  [ok]   ISSUE-39 counter installed @0x%x  cmn_err -> %s" % (RELOC, NEW))
                return
        raise SystemExit("ABORT: %s not defined (is kdbg040.o linked?)" % NEW)

    raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)


main()
