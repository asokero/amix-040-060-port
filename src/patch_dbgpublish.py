#!/usr/bin/env python3
# patch_dbgpublish.py -- DBG-TEXT-PUBLISH wiring: retarget the three debugger
# user-memory write calls to the publishing wrappers in dbgpublish040.o
# (2026-07-31).  Spec: analyysirepo vm-map/DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md
# (6c1cb84).  Rationale in src/dbgpublish040.s.
#
#   0x47eb8  suword  -> dbg_suword_publish    ptrace POKETEXT, already-writable
#   0x47eea  suword  -> dbg_suword_publish    ptrace POKETEXT, temporarily writable
#   0x64626  uiomove -> dbg_uiomove_publish   procfs per-chunk write
#
# The image is ET_REL: the RELOCATION is the call's identity, not the zero
# placeholder in the JSR operand, so a patch that writes an absolute operand and
# leaves the relocation alone would be silently undone by the loader.
#
# Every site asserts the symbol it currently names, so a drifted base fails the
# build rather than mis-wiring a debugger path.  Idempotent.
#
# Usage: python3 patch_dbgpublish.py <image>

import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

SITES = {
    0x00047EB8: ("suword",  "dbg_suword_publish",  "ptrace POKETEXT (writable)"),
    0x00047EEA: ("suword",  "dbg_suword_publish",  "ptrace POKETEXT (temp writable)"),
    0x00064626: ("uiomove", "dbg_uiomove_publish", "procfs chunk write"),
}


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
    rela = sec.get(".rela.text")
    if rela is None:
        raise SystemExit("ABORT: no .rela.text (is this the relinked image?)")
    symtab = sh[rela["link"]]
    strtab = sh[symtab["link"]]

    def symname(i):
        o = symtab["offset"] + i * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        return buf[strtab["offset"] + n:e].decode()

    def symindex(want):
        for i in range(symtab["size"] // symtab["entsize"]):
            if symname(i) == want:
                return i
        raise SystemExit("ABORT: %s not defined (is dbgpublish040.o linked?)" % want)

    seen = set()
    for i in range(rela["size"] // rela["entsize"]):
        o = rela["offset"] + i * rela["entsize"]
        r_off = u32(buf, o)
        if r_off not in SITES:
            continue
        old, new, what = SITES[r_off]
        r_info = u32(buf, o + 4)
        cur = symname(r_info >> 8)
        if cur == new:
            print("  [skip] %-32s @0x%x already -> %s" % (what, r_off, new))
        elif cur == old:
            struct.pack_into(">I", buf, o + 4, (symindex(new) << 8) | (r_info & 0xFF))
            print("  [ok]   %-32s @0x%x  %s -> %s" % (what, r_off, old, new))
        else:
            raise SystemExit("ABORT: reloc @0x%x names %r, expected %r or %r"
                             % (r_off, cur, old, new))
        seen.add(r_off)

    missing = set(SITES) - seen
    if missing:
        raise SystemExit("ABORT: relocation(s) not found: %s (base drifted?)"
                         % ", ".join("0x%x" % m for m in sorted(missing)))

    open(IMG, "wb").write(buf)
    print("DBG-TEXT-PUBLISH wired (3 sites) -> %s" % IMG)


main()
