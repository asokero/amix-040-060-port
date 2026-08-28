#!/usr/bin/env python3
# patch_fpe_vec11.py -- install the soft-FPU arm ahead of everything else on vector 11, and
# give it back the handler it displaced (2026-08-26).
#
# TWO relocation retargets, and the second is what makes the first safe.
#
#   1. M68Kvec[11]        <previous>  ->  fpe_vec11
#   2. fpe_decline's jmp  nullvect    ->  <previous>
#
# The arm has to run BEFORE fpsp_vec11's first instruction: frozen decision 10 puts the
# fpu_present test at the top of vector 11 and ahead of any cputype test, and
# FPE-INTEGRATION-CONTRACT.md 6.3 shows the emulator's own format-4 PC reconstruction
# was written for exactly that position.  Retargeting the vector slot is how this port already
# installs a handler ahead of another (src/patch_fpsp_vec11.py), so this is the same mechanism
# applied one layer further out.
#
# Retarget 2 is the interesting one.  fpe_vec11 declines a frame that is not its business --
# a genuine four-word F-line word above all, whose outcome must stay SIGSYS -- and "decline"
# has to mean "the byte-for-byte path this exception took before the arm existed".  That path
# is fpsp_vec11 on a normal build and nullvect on an FPSP=0 one, and src/fpe040.s cannot name
# either without risking a jump to a symbol that is not linked.  So it names nullvect, always
# resolvable, and this script points the same relocation at whatever the vector actually held.
#
# Asserts everything it depends on, is idempotent, and fails closed.

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-fpe"

NEW_TARGET = "fpe_vec11"
DECLINE_SYM = "fpe_decline"
DECLINE_SPAN = 6                 # the jmp <abs.l> that fpe_decline is: opcode + 4-byte operand
ALLOWED_PREV = ("fpsp_vec11", "nullvect")
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

    vec11 = sym_value("M68Kvec") + 11 * 4
    new_idx = sym_index(NEW_TARGET)
    dec = sym_value(DECLINE_SYM)

    vhit = find_reloc(vec11, vec11 + 4)
    if vhit is None:
        raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[11] 0x%x" % vec11)
    vinfo = u32(b, vhit + 4)
    if vinfo & 0xff != R_68K_32:
        raise SystemExit("ABORT: M68Kvec[11] reloc type %d != R_68K_32" % (vinfo & 0xff))
    prev = symname(vinfo >> 8)

    if prev == NEW_TARGET:
        print("  [skip] M68Kvec[11] already -> %s" % NEW_TARGET)
        return
    if prev not in ALLOWED_PREV:
        raise SystemExit("ABORT: M68Kvec[11] holds %s, expected one of %s -- this image is "
                         "not the one this patcher was measured against"
                         % (prev, "/".join(ALLOWED_PREV)))

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
    print("  [ok]   M68Kvec[11] @0x%06x  %s -> %s" % (vec11, prev, NEW_TARGET))

    open(KERNEL, "wb").write(b)
    print("FPE vector-11 arm installed -> %s" % KERNEL)


main()
