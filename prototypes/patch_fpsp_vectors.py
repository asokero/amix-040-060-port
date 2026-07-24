#!/usr/bin/env python3
# patch_fpsp_vectors.py -- FPU Tier-2 M4: retarget the FP ARITHMETIC exception
# vectors M68Kvec[48/51/52/53/54/55] from nullvect to the FPSP dispatch entries
# fpsp_vec48/51/52/53/54/55 in prototypes/fpsp_glue040.s (2026-07-24).
#
# Same relocation-retarget mechanism as patch_fpsp_vec11.py: the vector table
# M68Kvec lives in .text and each slot carries an R_68K_32 relocation in
# .rela.text; the field offsets are derived from the M68Kvec symbol so they
# survive .text layout changes.
#
# Vectors 49 (inexact) and 50 (divide-by-zero) are deliberately NOT retargeted:
# the 68040 completes both in hardware and the Motorola package exports no entry
# for them, so they stay on the stock nullvect -> u_trap -> SIGFPE path.
#
# Motivation: with slot 55 (unimplemented DATA TYPE -- taken whenever an FP
# instruction meets a denormalized or packed operand) left on nullvect, the
# exception reaches user land as SIGILL.  Observed on the 260724-08 kernel:
#   DBG SIG sig=4 pid=208 psargs=/usr/X/bin/Xsvga :0
#
# Asserts the current target of every slot is `nullvect`; idempotent; fails
# closed (any unexpected target or reloc type aborts without writing).

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040-fpsp-dbg"

OLD_TARGET = "nullvect"
R_68K_32 = 1

# vector -> glue dispatch entry (each gates on cputype==40, then jumps to the
# Motorola package entry with the raw exception frame untouched on (sp))
VECTORS = [
    (48, "fpsp_vec48", "bsun   -- branch/set on unordered"),
    (51, "fpsp_vec51", "unfl   -- underflow"),
    (52, "fpsp_vec52", "operr  -- operand error"),
    (53, "fpsp_vec53", "ovfl   -- overflow"),
    (54, "fpsp_vec54", "snan   -- signaling NaN"),
    (55, "fpsp_vec55", "unsupp -- unimplemented DATA TYPE"),
]


def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]


def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff = u32(b, 32); e_shentsize = u16(b, 46)
    e_shnum = u16(b, 48); e_shstrndx = u16(b, 50)
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

    base = sym_value("M68Kvec")
    rela = byname[".rela.text"]
    ro, re, rn = rela["offset"], rela["entsize"], rela["size"]//rela["entsize"]

    # index the .rela.text records by the offset they patch
    at = {}
    for i in range(rn):
        o = ro + i*re
        at[u32(b, o)] = o

    done = 0
    for vec, target, what in VECTORS:
        off = base + vec*4
        hit = at.get(off)
        if hit is None:
            raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[%d] 0x%x" % (vec, off))
        rinfo = u32(b, hit + 4); cur = rinfo >> 8; typ = rinfo & 0xff
        if typ != R_68K_32:
            raise SystemExit("ABORT: M68Kvec[%d] reloc type %d != R_68K_32" % (vec, typ))
        new_idx = sym_index(target)
        if cur == new_idx:
            print("  [skip] M68Kvec[%d] already -> %s" % (vec, target))
            continue
        if symname(cur) != OLD_TARGET:
            raise SystemExit("ABORT: M68Kvec[%d] target is %s, expected %s"
                             % (vec, symname(cur), OLD_TARGET))
        struct.pack_into(">I", b, hit + 4, (new_idx << 8) | R_68K_32)
        print("  [ok]   M68Kvec[%d] @0x%x  %s -> %s   (%s)"
              % (vec, off, OLD_TARGET, target, what))
        done += 1

    # 49/50 must be left alone -- assert we did not disturb them
    for vec in (49, 50):
        hit = at.get(base + vec*4)
        if hit is None:
            raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[%d]" % vec)
        if symname(u32(b, hit + 4) >> 8) != OLD_TARGET:
            raise SystemExit("ABORT: M68Kvec[%d] unexpectedly not %s" % (vec, OLD_TARGET))
    print("  [ok]   M68Kvec[49] inexact / M68Kvec[50] div-by-zero left on %s (by design)"
          % OLD_TARGET)

    open(KERNEL, "wb").write(b)
    print("FPSP arithmetic vectors installed (%d retargeted) -> %s" % (done, KERNEL))


main()
