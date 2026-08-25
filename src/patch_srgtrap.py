#!/usr/bin/env python3
# patch_srgtrap.py -- ISSUE-106 round 2: retarget the utraps -> u_trap edge so the
# pushed-USP slot address can be recorded for the CURRENT trap (2026-08-21).
# Companion object: src/srgtrap.s.
#
# utraps @0x11ea is:
#     11ea: movel %usp,%a0
#     11ec: movel %a0,%sp@-      ; push USP -- THE slot the trap exit pops at 0x11f4
#     11ee: jsr   u_trap         ; relocation at 0x11f0
#
# Retarget that one relocation to srg_utraps, which records %sp+20 (its own four
# saved registers plus the jsr return address = the pushed word) and tail-jumps
# into u_trap with the stack untouched, so u_trap's %fp+8 still names that slot.
#
# The setregs half is a symbol override (--weaken-symbol setregs +
# --add-symbol setregs_orig), wired in relink-040.sh, not here.
#
# Usage: python3 patch_srgtrap.py <image>
import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
RELOC = 0x000011F0
OLD, NEW = "u_trap", "srg_utraps"


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
            print("  [skip] utraps edge already retargeted @0x%x" % RELOC); return
        if cur != OLD:
            raise SystemExit("ABORT: reloc @0x%x names %r, expected %r" % (RELOC, cur, OLD))
        for j in range(symtab["size"] // symtab["entsize"]):
            if symname(j) == NEW:
                struct.pack_into(">I", buf, o + 4, (j << 8) | (r_info & 0xFF))
                open(IMG, "wb").write(buf)
                print("  [ok]   ISSUE-106 utraps edge installed @0x%x  u_trap -> %s" % (RELOC, NEW))
                return
        raise SystemExit("ABORT: %s not defined (is srgtrap.o linked?)" % NEW)

    raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)


main()
