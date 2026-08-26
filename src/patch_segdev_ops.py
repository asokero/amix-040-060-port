#!/usr/bin/env python3
# patch_segdev_ops.py -- ISSUE-49: route segdev_setprot and segdev_unmap through the
# alignment checkers in src/segdevchk040.s (2026-08-26).
#
# WHY.  patch_segdev_bridge.py makes segdev step one 4 KiB page while the vpage array keeps
# two entries per page, and that is correct only while both members of every pair are equal.
# They are equal because the generic as_* boundaries round to 4 KiB before segdev is reached
# -- a property of code in another file that nothing connects to this one.  The wrappers
# count any segdev operation arriving on a sub-page address or length, which is the only way
# a pair can be split.  sdc_setprot_bad and sdc_unmap_bad must read 0 forever.
#
# WHY A TABLE RETARGET AND NOT globalize+weaken -- the same reason as patch_a3091_dma.py:
# every segdev_* operation is a file-LOCAL 't' reached only through the segdev_ops vector,
# so there is no global symbol to override and a strong definition would bind nothing.
# The two entries below are relocations in .rela.data pointing into that table; the stock
# bodies stay reachable through the relink --add-symbol aliases segdev_setprot_orig and
# segdev_unmap_orig.
#
# Every edit asserts the relocation's current target by NAME and st_value, so it cannot
# retarget the wrong slot even if the table moved.  Idempotent.

import struct, sys

KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
R_68K_32 = 1

# (segdev_ops slot offset in .data, current symbol, its st_value, wrapper)
SLOTS = [
    (0xb384, "segdev_unmap",   0xa7c08, "segdev_unmap_chk"),
    (0xb398, "segdev_setprot", 0xa80de, "segdev_setprot_chk"),
]

def u16(b, o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b, o): return struct.unpack(">I", b[o:o+4])[0]

def main():
    b = bytearray(open(KERNEL, "rb").read())
    e_shoff, e_shentsize = u32(b, 32), u16(b, 46)
    e_shnum, e_shstrndx = u16(b, 48), u16(b, 50)
    sh = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        sh.append({"name": u32(b, o), "type": u32(b, o + 4), "offset": u32(b, o + 16),
                   "size": u32(b, o + 20), "link": u32(b, o + 24), "entsize": u32(b, o + 36)})
    stro = sh[e_shstrndx]["offset"]
    def nm(s):
        e = b.index(b"\0", stro + s["name"])
        return b[stro + s["name"]:e].decode()
    sec = {nm(s): s for s in sh}

    if ".rela.data" not in sec:
        sys.exit("patch_segdev_ops: ABORT: no .rela.data -- segdev_ops is not relocated here")
    rela, symtab = sec[".rela.data"], sec[".symtab"]
    strtab = sh[symtab["link"]]
    so, se_, sn = symtab["offset"], symtab["entsize"], symtab["size"] // symtab["entsize"]
    stro2 = strtab["offset"]

    def sym_name(i):
        e = b.index(b"\0", stro2 + u32(b, so + i * se_))
        return b[stro2 + u32(b, so + i * se_):e].decode()
    def sym_value(i):
        return u32(b, so + i * se_ + 4)

    idx = {}
    for i in range(sn):
        n = sym_name(i)
        if n in ("segdev_unmap_chk", "segdev_setprot_chk"):
            idx[n] = i
    for _, _, _, w in SLOTS:
        if w not in idx:
            sys.exit("patch_segdev_ops: ABORT: %s not found (segdevchk040.o linked?)" % w)

    ro, re_, rn = rela["offset"], rela["entsize"], rela["size"] // rela["entsize"]
    done = skip = 0
    for off, want, want_val, wrapper in SLOTS:
        hit = False
        for i in range(rn):
            o = ro + i * re_
            if u32(b, o) != off:
                continue
            hit = True
            info = u32(b, o + 4)
            cur, rtype = info >> 8, info & 0xff
            if rtype != R_68K_32:
                sys.exit("patch_segdev_ops: ABORT @0x%05x: reloc type %d != R_68K_32" % (off, rtype))
            if cur == idx[wrapper]:
                print("  [skip] segdev_ops+0x%04x already -> %s" % (off - 0xb380, wrapper))
                skip += 1
                break
            n, v = sym_name(cur), sym_value(cur)
            if n != want or v != want_val:
                sys.exit("patch_segdev_ops: ABORT @0x%05x: slot holds %s@0x%x, expected %s@0x%x"
                         % (off, n, v, want, want_val))
            struct.pack_into(">I", b, o + 4, (idx[wrapper] << 8) | R_68K_32)
            print("  [ok]   segdev_ops+0x%04x  %s@0x%x -> %s" % (off - 0xb380, n, v, wrapper))
            done += 1
            break
        if not hit:
            sys.exit("patch_segdev_ops: ABORT: no relocation at .data+0x%05x -- table moved" % off)

    if done + skip != len(SLOTS):
        sys.exit("patch_segdev_ops: ABORT: handled %d of %d slots" % (done + skip, len(SLOTS)))
    if done:
        open(KERNEL, "wb").write(b)
    print("patch_segdev_ops: %d retargeted, %d already -> %s" % (done, skip, KERNEL))

if __name__ == "__main__":
    main()
