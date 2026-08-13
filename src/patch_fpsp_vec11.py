#!/usr/bin/env python3
# patch_fpsp_vec11.py -- FPU Tier-2 M2: retarget M68Kvec[11] (F-line) from
# nullvect to the FPSP dispatch entry fpsp_vec11 (2026-07-24).
#
# The vector table M68Kvec is in .text; vector 11's field is at M68Kvec + 11*4
# and carries an R_68K_32 relocation (in .rela.text) to `nullvect`.  Retargeting
# that relocation to `fpsp_vec11` (same relocation-retarget mechanism as
# patch_a3091_dma.py) routes 68040 unimplemented-FP / line-F exceptions into the
# Motorola FPSP.  The field offset is derived from the M68Kvec symbol so it
# survives .text layout changes.
#
# ONLY vector 11 is retargeted (M2-minimal).  Vectors 48-55 (FP arithmetic
# exceptions) stay on nullvect until M4.  Asserts the current target is
# `nullvect`; idempotent; fails closed.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-fpsp-dbg"

OLD_TARGET = "nullvect"
NEW_TARGET = "fpsp_vec11"
R_68K_32 = 1

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46); e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append(dict(name=u32(b, o), offset=u32(b, o+16), size=u32(b, o+20),
                       link=u32(b, o+24), entsize=u32(b, o+36)))
    shstr = sh[e_shstrndx]["offset"]
    def nm(s):
        e = b.index(b"\0", shstr + s["name"]); return b[shstr+s["name"]:e].decode()
    byname = {nm(s): s for s in sh}
    symtab = byname[".symtab"]; strtab = sh[symtab["link"]]
    so, se, sn = symtab["offset"], symtab["entsize"], symtab["size"]//symtab["entsize"]
    stroff = strtab["offset"]
    def symname(i):
        n = u32(b, so + i*se); e = b.index(b"\0", stroff + n); return b[stroff+n:e].decode()
    def sym_index(name):
        for i in range(sn):
            if symname(i) == name: return i
        raise SystemExit("ABORT: symbol %s not found" % name)
    def sym_value(name):
        return u32(b, so + sym_index(name)*se + 4)

    VEC11_OFF = sym_value("M68Kvec") + 11*4     # M68Kvec[11], F-line
    rela = byname[".rela.text"]
    ro, re, rn = rela["offset"], rela["entsize"], rela["size"]//rela["entsize"]
    new_idx = sym_index(NEW_TARGET)
    hit = None
    for i in range(rn):
        o = ro + i*re
        if u32(b, o) == VEC11_OFF:
            hit = o; break
    if hit is None:
        raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[11] 0x%x" % VEC11_OFF)
    rinfo = u32(b, hit + 4); cur = rinfo >> 8; typ = rinfo & 0xff
    if typ != R_68K_32:
        raise SystemExit("ABORT: reloc type %d != R_68K_32" % typ)
    if cur == new_idx:
        print("  [skip] M68Kvec[11] already -> %s" % NEW_TARGET)
    elif symname(cur) == OLD_TARGET:
        struct.pack_into(">I", b, hit + 4, (new_idx << 8) | R_68K_32)
        print("  [ok]   M68Kvec[11] @0x%x  %s -> %s" % (VEC11_OFF, OLD_TARGET, NEW_TARGET))
    else:
        raise SystemExit("ABORT: M68Kvec[11] target is %s, expected %s" % (symname(cur), OLD_TARGET))
    open(KERNEL, "wb").write(b)
    print("FPSP vector-11 dispatch installed -> %s" % KERNEL)

main()
