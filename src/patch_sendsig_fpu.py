#!/usr/bin/env python3
# patch_sendsig_fpu.py -- F1-M2: gate sendsig's fpu_setup call on fpu_present
# (2026-08-24).
#
# M68060-SUPPORT-LANDSCAPE.md:188-214 recommendation #1: call `fpu_setup` only
# when `fpu_present != 0`.  sendsig does not.  On a 68LC060 the first delivered
# signal therefore executes FRESTORE in supervisor mode on a part with no FPU.
#
# The call is `jsr fpu_setup` at sendsig+0x1f8, whose R_68K_32 relocation sits
# at .text 0x5921c.  Retargeting that relocation to `fpu_setup_gated`
# (src/fpuinit060.s) is the same relocation-retarget mechanism as
# patch_fpsp_vec11.py and patch_dbgpublish.py, and it leaves the 68040 path a
# plain tail jump into the same body it calls today.
#
# The gates inside fpu_setup/fpu_save/fpu_restore (src/fpu060.s) are what
# actually makes the kernel safe -- a relocation census of the pinned image
# finds FIVE ungated call sites, not one, because savecontext and
# restorecontext carry no reference to fpu_present at all.  This patcher exists
# so that the sendsig site is separately COUNTABLE: F1-M2's acceptance gate asks
# for a counter proving signal delivery did not execute FRESTORE, and the
# absence of a crash is not that counter.
#
# Asserts the call opcode and the current target; idempotent; fails closed.

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

CALL_OP   = 0x5921a          # .text offset of the `jsr` itself
RELOC_OFF = 0x5921c          # .text offset of its 32-bit operand
JSR_ABS_L = b"\x4e\xb9"      # jsr xxx.l
OLD_TARGET = "fpu_setup"
NEW_TARGET = "fpu_setup_gated"
TEXT_FILE_OFF = 0x34         # .text starts here in this ET_REL image
R_68K_32 = 1


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
    so, se = symtab["offset"], symtab["entsize"]
    sn = symtab["size"] // se
    stroff = strtab["offset"]

    def symname(i):
        n = u32(b, so + i*se); e = b.index(b"\0", stroff + n)
        return b[stroff+n:e].decode()

    def sym_index(name):
        for i in range(sn):
            if symname(i) == name:
                return i
        raise SystemExit("ABORT: symbol %s not found -- is fpuinit060.o in the link?" % name)

    def sym_value(name):
        return u32(b, so + sym_index(name)*se + 4)

    # The call site must still be the instruction this offset was measured
    # against.  A wrong offset would retarget some other relocation and link
    # cleanly, which is the failure mode this repository exists to prevent.
    op = bytes(b[TEXT_FILE_OFF + CALL_OP: TEXT_FILE_OFF + CALL_OP + 2])
    if op != JSR_ABS_L:
        raise SystemExit("ABORT: 0x%x is %s, not `jsr xxx.l`" % (CALL_OP, op.hex()))
    want = sym_value("sendsig") + 0x1f8
    if CALL_OP != want:
        raise SystemExit("ABORT: sendsig+0x1f8 is 0x%x, not 0x%x" % (want, CALL_OP))

    rela = byname[".rela.text"]
    ro, re = rela["offset"], rela["entsize"]
    rn = rela["size"] // re
    new_idx = sym_index(NEW_TARGET)
    hit = None
    for i in range(rn):
        o = ro + i*re
        if u32(b, o) == RELOC_OFF:
            hit = o; break
    if hit is None:
        raise SystemExit("ABORT: no .rela.text reloc at 0x%x" % RELOC_OFF)
    rinfo = u32(b, hit + 4); cur = rinfo >> 8; typ = rinfo & 0xff
    if typ != R_68K_32:
        raise SystemExit("ABORT: reloc type %d != R_68K_32" % typ)
    if cur == new_idx:
        print("  [skip] sendsig+0x1f8 already -> %s" % NEW_TARGET)
    elif symname(cur) == OLD_TARGET:
        struct.pack_into(">I", b, hit + 4, (new_idx << 8) | R_68K_32)
        print("  [ok]   sendsig+0x1f8 @0x%x  %s -> %s" % (RELOC_OFF, OLD_TARGET, NEW_TARGET))
    else:
        raise SystemExit("ABORT: sendsig's call target is %s, expected %s"
                         % (symname(cur), OLD_TARGET))
    open(KERNEL, "wb").write(b)
    print("sendsig fpu_setup gate installed -> %s" % KERNEL)


main()
