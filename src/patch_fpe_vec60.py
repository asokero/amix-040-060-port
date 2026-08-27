#!/usr/bin/env python3
# patch_fpe_vec60.py -- install the soft-FPU arm ahead of everything else on vector 60, and
# give it back the handler it displaced (2026-08-27, round 10).
#
# THE SAME TWO RETARGETS src/patch_fpe_vec11.py MAKES, one vector over:
#
#   1. M68Kvec[60]          <previous>  ->  fpe_vec60
#   2. fpe_decline60's jmp  nullvect    ->  <previous>
#
# WHY VECTOR 60 NEEDS AN ARM AT ALL.  On a 68060 the effective address of an FP operand is
# computed by the INTEGER unit, and the two immediate formats whose operand is twelve bytes --
# extended-precision real and packed decimal -- are the ones it does not implement.  Those
# instructions therefore raise "FP unimplemented effective address" BEFORE any F-line path
# runs, so the vector-11 arm never sees them.  Round 10 measured three of them on real 68LC060
# silicon: three vector-60 entries, three SIGSYS deaths, and every fpe_* counter still at its
# initialiser.  docs/contracts/FPE-R10-VEC60.md is the trace and the design.
#
# THE DISPLACED HANDLER.  M68Kvec[60] holds fpsp_vec60 on a normal build -- the dispatcher in
# src/fpsp_glue040.s that sends a 68060 into Motorola's package -- and nullvect on an FPSP=0
# one.  src/fpe040.s cannot name either without risking a jump to a symbol that is not linked,
# so it names nullvect, always resolvable, and this points the same relocation at whatever the
# vector actually held.  A declined vector-60 event then takes the pre-arm path instruction for
# instruction, which is what makes the arm safe to install on an FPU-present rig.
#
# WHY NOT RETARGET THE PACKAGE'S FPU-DISABLED CALL-OUT INSTEAD, which is where the SIGSYS
# actually comes from and which would hand over a frame Motorola has already normalised:
# because fpe_decline would then reach fpsp_vec11 -> the package -> the same call-out -> the
# arm, an unbreakable loop on the first declined frame; because that call-out is also where the
# vector-11 declines land, supervisor origin included; and because an FPSP=0 kernel has no such
# call-out to retarget.  FPE-R10-VEC60.md 4.
#
# Asserts everything it depends on, is idempotent, and fails closed.

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-fpe"

VECTOR = 60
NEW_TARGET = "fpe_vec60"
DECLINE_SYM = "fpe_decline60"
DECLINE_SPAN = 6                 # the jmp <abs.l> that fpe_decline60 is: opcode + 4-byte operand
ALLOWED_PREV = ("fpsp_vec60", "nullvect")
R_68K_32 = 1


def u16(b, o): return struct.unpack(">H", b[o:o + 2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o + 4])[0]


def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46)
    e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(b, o), offset=u32(b, o + 16), size=u32(b, o + 20),
                       link=u32(b, o + 24), entsize=u32(b, o + 36)))
    shstr = sh[e_shstrndx]["offset"]

    def secname(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr + s["name"]:e].decode()

    byname = {secname(s): s for s in sh}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se = symtab["offset"], symtab["entsize"]
    sn = symtab["size"] // se
    stroff = strtab["offset"]

    def symname(i):
        n = u32(b, so + i * se); e = b.index(b"\0", stroff + n)
        return b[stroff + n:e].decode()

    def sym_index(name):
        for i in range(sn):
            if symname(i) == name:
                return i
        raise SystemExit("ABORT: symbol %s not found" % name)

    def sym_value(name):
        return u32(b, so + sym_index(name) * se + 4)

    rela = byname[".rela.text"]
    ro, re = rela["offset"], rela["entsize"]
    rn = rela["size"] // re

    def find_reloc(lo, hi):
        for i in range(rn):
            o = ro + i * re
            if lo <= u32(b, o) < hi:
                return o
        return None

    vec = sym_value("M68Kvec") + VECTOR * 4
    new_idx = sym_index(NEW_TARGET)
    dec = sym_value(DECLINE_SYM)

    vhit = find_reloc(vec, vec + 4)
    if vhit is None:
        raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[%d] 0x%x" % (VECTOR, vec))
    vinfo = u32(b, vhit + 4)
    if vinfo & 0xff != R_68K_32:
        raise SystemExit("ABORT: M68Kvec[%d] reloc type %d != R_68K_32" % (VECTOR, vinfo & 0xff))
    prev = symname(vinfo >> 8)

    if prev == NEW_TARGET:
        print("  [skip] M68Kvec[%d] already -> %s" % (VECTOR, NEW_TARGET))
        return
    if prev not in ALLOWED_PREV:
        raise SystemExit("ABORT: M68Kvec[%d] holds %s, expected one of %s -- this image is "
                         "not the one this patcher was measured against"
                         % (VECTOR, prev, "/".join(ALLOWED_PREV)))

    dhit = find_reloc(dec, dec + DECLINE_SPAN)
    if dhit is None:
        raise SystemExit("ABORT: no .rela.text reloc inside %s (0x%x..0x%x) -- the decline is "
                         "supposed to be one jmp with a patchable operand"
                         % (DECLINE_SYM, dec, dec + DECLINE_SPAN))
    dinfo = u32(b, dhit + 4)
    if dinfo & 0xff != R_68K_32:
        raise SystemExit("ABORT: %s reloc type %d != R_68K_32" % (DECLINE_SYM, dinfo & 0xff))
    dcur = symname(dinfo >> 8)
    if dcur != "nullvect":
        raise SystemExit("ABORT: %s already names %s, expected nullvect" % (DECLINE_SYM, dcur))

    # Order: give the arm its exit BEFORE the vector can reach the arm.  A half-applied patch
    # then leaves a kernel that still works rather than one whose decline path is a lie.
    struct.pack_into(">I", b, dhit + 4, ((vinfo >> 8) << 8) | R_68K_32)
    print("  [ok]   %s @0x%06x  nullvect -> %s   (the displaced handler)"
          % (DECLINE_SYM, dec, prev))
    struct.pack_into(">I", b, vhit + 4, (new_idx << 8) | R_68K_32)
    print("  [ok]   M68Kvec[%d] @0x%06x  %s -> %s" % (VECTOR, vec, prev, NEW_TARGET))

    open(KERNEL, "wb").write(b)
    print("FPE vector-60 arm installed -> %s" % KERNEL)


main()
