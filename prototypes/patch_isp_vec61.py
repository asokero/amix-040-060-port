#!/usr/bin/env python3
# patch_isp_vec61.py -- retarget M68Kvec[61] (unimplemented integer instruction)
# from nullvect to isp61_vec, the bounded 68060 immediate-multiply unit (F2, 2026-08-06).
#
# Same relocation-retarget mechanism as patch_fpsp_vec11.py: vector 61's field is at
# M68Kvec + 61*4 in .text and carries an R_68K_32 relocation to `nullvect`.  The field
# offset is DERIVED from the M68Kvec symbol, never hard-coded -- on the pinned image it
# happens to be .text:0x146c, but that number moves with any .text change.
#
# No collision with the FPSP scripts: patch_fpsp_vec11.py owns only vector 11, and
# patch_fpsp_vectors.py owns 48 and 51-55 while asserting 49/50.  Nothing reads slot 61.
# This runs AFTER the optional FPSP block so an FPSP `ld -r` cannot supersede the retarget,
# which also means FPSP=0 and FPSP=1 images get identical vector-61 behaviour.
#
# Asserts the current target is `nullvect`; idempotent; fails closed.
# Also asserts vectors 60 stays nullvect, as a cheap check that the table did not shift
# under us (61 without 60 would mean the M68Kvec symbol moved but the layout did not).

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

OLD_TARGET = "nullvect"
NEW_TARGET = "isp61_vec"
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

    base = sym_value("M68Kvec")
    VEC61_OFF = base + 61*4
    VEC60_OFF = base + 60*4
    rela = byname[".rela.text"]
    ro, re, rn = rela["offset"], rela["entsize"], rela["size"]//rela["entsize"]
    new_idx = sym_index(NEW_TARGET)

    slots = {}
    for i in range(rn):
        o = ro + i*re
        off = u32(b, o)
        if off in (VEC60_OFF, VEC61_OFF):
            slots[off] = o
    if VEC61_OFF not in slots:
        raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[61] 0x%x" % VEC61_OFF)
    if VEC60_OFF not in slots:
        raise SystemExit("ABORT: no .rela.text reloc at M68Kvec[60] 0x%x -- table moved?" % VEC60_OFF)

    # vector 60 must still be nullvect: a cheap independent check that we are looking at
    # the vector table and not at something that merely lives at the right offset.
    r60 = u32(b, slots[VEC60_OFF] + 4)
    if symname(r60 >> 8) != OLD_TARGET:
        raise SystemExit("ABORT: M68Kvec[60] is %s, expected %s -- refusing to touch 61"
                         % (symname(r60 >> 8), OLD_TARGET))

    hit = slots[VEC61_OFF]
    rinfo = u32(b, hit + 4); cur = rinfo >> 8; typ = rinfo & 0xff
    if typ != R_68K_32:
        raise SystemExit("ABORT: reloc type %d != R_68K_32" % typ)
    if cur == new_idx:
        print("  [skip] M68Kvec[61] already -> %s" % NEW_TARGET)
    elif symname(cur) == OLD_TARGET:
        struct.pack_into(">I", b, hit + 4, (new_idx << 8) | R_68K_32)
        print("  [ok]   M68Kvec[61] @0x%x  %s -> %s" % (VEC61_OFF, OLD_TARGET, NEW_TARGET))
    else:
        raise SystemExit("ABORT: M68Kvec[61] target is %s, expected %s" % (symname(cur), OLD_TARGET))

    # every ISP symbol the handler needs must be defined in this image
    for s in ("isp61_vec", "isp61_magic", "isp61_entry_n", "isp61_ok_n",
              "isp61_unsupported_n", "isp61_last_pc"):
        i = sym_index(s)
        if u32(b, so + i*se + 12) & 0xffff == 0:      # st_shndx == SHN_UNDEF
            raise SystemExit("ABORT: %s is undefined in %s" % (s, KERNEL))

    open(KERNEL, "wb").write(b)
    print("ISP vector-61 dispatch installed -> %s" % KERNEL)

main()
