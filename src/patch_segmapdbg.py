#!/usr/bin/env python3
# patch_segmapdbg.py -- ISSUE-103: latch the state segmap_unlock panics on
# (2026-08-20).
#
# segmap_unlock @0xa8fec has exactly one cmn_err call.  Its three guards --
# pp == NULL, pp->p_pagein, pp->p_free -- all branch to the SAME call at 0xa907e
# (relocation at 0xa9080), whose format string is LC%0 "segmap_unlock", so the
# panic text cannot say which of the three fired.
#
# Retarget that relocation to smu_panic_latch (segmapdbg.s), which saves every
# register, latches segmap_unlock's live state plus a full-hash search for the
# page it could not find, restores, and tail-jumps into cmn_err -- the panic still
# prints exactly as before.
#
# The only path that reaches this code is one that was already about to panic, so
# a healthy kernel never executes a byte of it.
#
# Usage: python3 patch_segmapdbg.py <image>

import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
RELOC = 0x000A9080
OLD, NEW = "cmn_err", "smu_panic_latch"


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
            print("  [skip] segmap_unlock panic already latched @0x%x" % RELOC); return
        if cur != OLD:
            raise SystemExit("ABORT: reloc @0x%x names %r, expected %r" % (RELOC, cur, OLD))
        for j in range(symtab["size"] // symtab["entsize"]):
            if symname(j) == NEW:
                struct.pack_into(">I", buf, o + 4, (j << 8) | (r_info & 0xFF))
                open(IMG, "wb").write(buf)
                print("  [ok]   ISSUE-103 latch installed @0x%x  cmn_err -> %s" % (RELOC, NEW))
                return
        raise SystemExit("ABORT: %s not defined (is segmapdbg.o linked?)" % NEW)

    raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)


main()
