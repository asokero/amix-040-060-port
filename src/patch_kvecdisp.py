#!/usr/bin/env python3
# patch_kvecdisp.py -- BLIZZARD F4 round 6: chain the vector-dispatch census in front of the
# ISSUE-106 user-trap latch (2026-08-25).  Companion object: src/kvecdisp040.s.
#
# `utraps` (inside nullvect_orig, .text 0x11ea) calls the user-trap handler from the site at
# 0x11ee, relocation at 0x11f0.  Stock names `u_trap` there; src/patch_srgtrap.py has already
# pointed it at `srg_utraps`; this points it at `kvd_utraps`, which tail-jumps to srg_utraps,
# which tail-jumps to u_trap.  All three instruments run and the trap path is unchanged.
#
# The ORDER is the whole point of the refusals below.  If this patcher ran on an image where
# patch_srgtrap.py had not run, it would chain in front of u_trap directly, link cleanly, boot,
# and SILENTLY DROP the ISSUE-106 srg latch -- a kernel that looks built and measures less than
# it should.  So the current target is asserted to be exactly srg_utraps, and a raw u_trap
# target is refused rather than accepted.
#
# Five refusals, all fail-closed:
#   1. no relocation at 0x11f0                   -> the base drifted; the address is wrong
#   2. relocation is not R_68K_32                -> not the call operand this was measured on
#   3. current target is not srg_utraps          -> see above (already-kvd_utraps is a skip)
#   4. kvd_utraps undefined                      -> kvecdisp040.o is not in the link
#   5. kvd_magic is not a .data symbol           -> the block has no file storage, so
#                                                   status-facts.sh cannot read its magic out
#                                                   of the artifact and the address printed
#                                                   for it would be a guess
# and one more, because a tail jump needs a target: srg_utraps must still be defined.
#
# Idempotent.  Usage: python3 patch_kvecdisp.py <image>
import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
RELOC = 0x000011F0
OLD, NEW = "srg_utraps", "kvd_utraps"
BLOCK_MAGIC = "kvd_magic"
R_68K_32 = 1


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


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

    secs = {nm(s): s for s in sh}
    names = [nm(s) for s in sh]
    rela = secs[".rela.text"]
    symtab = sh[rela["link"]]
    strtab = sh[symtab["link"]]
    nsyms = symtab["size"] // symtab["entsize"]

    def symname(i):
        o = symtab["offset"] + i * symtab["entsize"]
        n = u32(buf, o)
        e = buf.index(b"\0", strtab["offset"] + n)
        return buf[strtab["offset"] + n:e].decode()

    def symshndx(i):
        return u16(buf, symtab["offset"] + i * symtab["entsize"] + 14)

    def sym_index(name):
        for i in range(nsyms):
            if symname(i) == name:
                return i
        return None

    # Refusal 4/6: both ends of the chain must exist before anything is rewritten.
    new_idx = sym_index(NEW)
    if new_idx is None:
        raise SystemExit("ABORT: %s not defined -- is kvecdisp040.o in the link?" % NEW)
    if sym_index(OLD) is None:
        raise SystemExit("ABORT: %s not defined -- the tail jump has no target" % OLD)

    # Refusal 5: the counter block must live in .data.  A COMMON or a .bss home has no bytes
    # in the file, so `tools/status-facts.sh` could not read the magic out of the artifact and
    # every address it printed for this block would be unverifiable at the console.
    mi = sym_index(BLOCK_MAGIC)
    if mi is None:
        raise SystemExit("ABORT: %s not defined -- kvecdisp040.o is not in the link" % BLOCK_MAGIC)
    sec_of_magic = names[symshndx(mi)] if symshndx(mi) < len(names) else "(special)"
    if sec_of_magic != ".data":
        raise SystemExit("ABORT: %s is in %r, expected .data" % (BLOCK_MAGIC, sec_of_magic))

    for i in range(rela["size"] // rela["entsize"]):
        o = rela["offset"] + i * rela["entsize"]
        if u32(buf, o) != RELOC:
            continue
        r_info = u32(buf, o + 4)
        if (r_info & 0xFF) != R_68K_32:
            raise SystemExit("ABORT: reloc @0x%x type %d != R_68K_32" % (RELOC, r_info & 0xFF))
        cur = symname(r_info >> 8)
        if cur == NEW:
            print("  [skip] vector-dispatch census already chained @0x%x" % RELOC)
            return
        if cur != OLD:
            raise SystemExit(
                "ABORT: reloc @0x%x names %r, expected %r.  Run src/patch_srgtrap.py first --"
                " chaining in front of %r would silently drop the ISSUE-106 srg latch."
                % (RELOC, cur, OLD, cur))
        struct.pack_into(">I", buf, o + 4, (new_idx << 8) | R_68K_32)
        open(IMG, "wb").write(buf)
        print("  [ok]   vector-dispatch census chained @0x%x  %s -> %s -> u_trap"
              % (RELOC, NEW, OLD))
        print("         %s is in .data, so status-facts.sh can read its magic" % BLOCK_MAGIC)
        return

    raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)


main()
