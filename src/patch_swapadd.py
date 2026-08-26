#!/usr/bin/env python3
# patch_swapadd.py -- BLIZZARD F4 round 6: latch swapconf's swapadd operands on both sides of
# the call (2026-08-25).  Companion object: src/swapadd_dbg.s.
#
# `swapadd` is a FILE-LOCAL symbol (nm: `t swapadd` at .text 0xb3138), so it cannot be
# weakened and overridden the way swapconf, savecontext and restorecontext are.  What CAN be
# retargeted is the one call site that matters: swapconf's `jsr swapadd` at .text 0xb409c,
# relocation at 0xb409e.  That site is pointed at `swa_latch`, which re-pushes the four
# arguments, calls the real body through the `swapadd_real` global objcopy adds at 0xb3138,
# and latches the return.  Every other view of swapadd in the kernel is untouched.
#
# WHY THE CALL SITE AND NOT THE BODY.  swapadd has exactly one caller and the operands are
# what is being measured, not the internals.  Retargeting the body would also catch any future
# caller and would make `swa_n == 1` -- the self-check that says the latch caught the site it
# was measured on -- meaningless.
#
# Five refusals, all fail-closed:
#   1. no relocation at 0xb409e                  -> the base drifted; the address is wrong
#   2. relocation is not R_68K_32                -> not the call operand this was measured on
#   3. current target is not swapadd             -> something already retargeted this site
#                                                   (already-swa_latch is a skip)
#   4. swa_latch undefined                       -> swapadd_dbg.o is not in the link
#   5. swa_magic is not a .data symbol           -> the block has no file storage, so
#                                                   status-facts.sh cannot read its magic out
#                                                   of the artifact and the address printed
#                                                   for it would be a guess
# and one more, because the wrapper's `jsr` needs a target: swapadd_real must be defined, i.e.
# the relink's objcopy --add-symbol must have run before the link.
#
# Idempotent.  Usage: python3 patch_swapadd.py <image>
import struct
import sys

IMG = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
RELOC = 0x000B409E
OLD, NEW = "swapadd", "swa_latch"
REAL = "swapadd_real"
BLOCK_MAGIC = "swa_magic"
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

    def symvalue(i):
        return u32(buf, symtab["offset"] + i * symtab["entsize"] + 4)

    def sym_index(name):
        for i in range(nsyms):
            if symname(i) == name:
                return i
        return None

    # Refusal 4/6: the wrapper and the body it calls must both exist before anything is
    # rewritten.  swapadd_real is added by the relink's objcopy; without it the wrapper's
    # `jsr` has no target and the link would have failed -- assert it here anyway, because a
    # patcher that trusts an earlier step is how a silent half-build happens.
    new_idx = sym_index(NEW)
    if new_idx is None:
        raise SystemExit("ABORT: %s not defined -- is swapadd_dbg.o in the link?" % NEW)
    ri = sym_index(REAL)
    if ri is None:
        raise SystemExit("ABORT: %s not defined -- objcopy --add-symbol did not run" % REAL)
    print("  [ok]   %s resolves to .text 0x%x" % (REAL, symvalue(ri)))

    # Refusal 5: the counter block must live in .data (see patch_ufault.py for the argument).
    mi = sym_index(BLOCK_MAGIC)
    if mi is None:
        raise SystemExit("ABORT: %s not defined -- swapadd_dbg.o is not in the link" % BLOCK_MAGIC)
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
            print("  [skip] swapadd operand latch already bound @0x%x" % RELOC)
            return
        if cur != OLD:
            raise SystemExit(
                "ABORT: reloc @0x%x names %r, expected %r -- something else already"
                " retargeted swapconf's call site." % (RELOC, cur, OLD))
        struct.pack_into(">I", buf, o + 4, (new_idx << 8) | R_68K_32)
        open(IMG, "wb").write(buf)
        print("  [ok]   swapadd operand latch bound @0x%x  swapconf -> %s -> %s"
              % (RELOC, NEW, REAL))
        print("         %s is in .data, so status-facts.sh can read its magic" % BLOCK_MAGIC)
        return

    raise SystemExit("ABORT: relocation @0x%x not found (base drifted?)" % RELOC)


main()
