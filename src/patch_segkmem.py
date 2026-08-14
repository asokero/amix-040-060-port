#!/usr/bin/env python3
# patch_segkmem.py -- CM-campaign B1: Model B (4 KiB) conversion of the LAST
# 2 KiB stragglers in the direct linear-kptbl segkmem family (2026-07-20).
#
# Authoritative spec: docs/contracts/CM-PTE-WRITER-MATRIX.md
# (commit f2b56cd), "Direct segkmem blocker": segkmem_setprot / _checkprot /
# _getprot still computed a 2 KiB PTE index ((addr - s_base) >> 11) and stepped
# +0x800 while segkmem_alloc/free/mapin/mapout were already Model B (>>12 /
# +0x1000, patch_modelb).  The spec requires the family to be ported AS ONE
# UNIT ("A local moveq #11 -> #12 edit without auditing the index formula and
# the companion readers is not an acceptable CM-campaign patch"):
#
#   segkmem_setprot  (WRITER) -> overridden in src/segkmem040.s
#                    (4 KiB geometry + stock cursor-advance defect fix +
#                    cpusha dc/pflusha publication; vtable slot binds by
#                    symbol so globalize+weaken rebinds it).
#   segkmem_checkprot / segkmem_getprot (pure READERS, no publication needed,
#                    same-size immediate flips) -> byte-patched HERE.
#
# The index formula was audited against the already-converted writers on the
# same kptbl: one 4-byte PTE per 4 KiB VA page, index (addr - s_base) >> 12,
# so the reader loops step +0x1000/page and getprot's page-count shift is 12.
#
# ASSERT-ONLY canaries: the stock bodies of segkmem_setprot, sptfree(flag=0)
# and flushmmu stay in the image (overridden, unreachable).  Their old bytes
# are asserted so any base-image drift under the segkmem040.s transcriptions
# aborts the build instead of silently diverging.
#
# Each site asserts its expected OLD bytes before writing.  Operates in place
# on build/unix-040, AFTER the relink (stock .text addresses are unchanged by
# the appended override objects).

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

def u16(b,o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b,o): return struct.unpack(">I", b[o:o+4])[0]

def sections(b):
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48); st=u16(b,50)
    so=u32(b, sh+st*ent+16)
    out={}
    for i in range(n):
        o=sh+i*ent; nm=u32(b,o)
        e=b.index(b"\0", so+nm)
        out[b[so+nm:e].decode()]=(i, u32(b,o+12), u32(b,o+16))  # (index, addr, offset)
    return out

# .text patch sites: (vaddr, expect, new, name)
TEXT = [
 (0xa8550, b"\x72\x0b", b"\x72\x0c",
  "segkmem_checkprot:moveq #11 d1 (PTE index shift 2K->4K)"),
 (0xa859c, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00",
  "segkmem_checkprot:addil #0x800 d2 (page step 2K->4K)"),
 (0xa85d4, b"\x7a\x0b", b"\x7a\x0c",
  "segkmem_getprot:moveq #11 d5 (page-count shift, feeds both asrl)"),
 (0xa85fa, b"\x7a\x0b", b"\x7a\x0c",
  "segkmem_getprot:moveq #11 d5 (PTE index shift 2K->4K)"),
]

# assert-only canaries (overridden stock bodies must match what segkmem040.s
# was transcribed from): (vaddr, expect, name)
CANARY = [
 (0xa8474, b"\x72\x0b",                     "stock segkmem_setprot moveq #11 (overridden)"),
 (0xa84a6, b"\x42\x9a",                     "stock segkmem_setprot clrl a2@+ (overridden)"),
 (0xa84ac, b"\xef\xea\x41\x41\x00\x03",     "stock segkmem_setprot bfins W-bit (overridden)"),
 (0xa84b2, b"\x06\x82\x00\x00\x08\x00",     "stock segkmem_setprot addil #0x800 (overridden)"),
 (0xa8cd0, b"\x42\xb0\x0c\x00",             "stock sptfree flag=0 direct clear (overridden)"),
 (0xb78d0, b"\xf5\x18",                     "stock flushmmu pflusha-only body (overridden)"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]
    done=skip=0

    def patch(fo, old, new, name, where):
        nonlocal done, skip
        cur=bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-62s %s already" % (name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-62s %s %s->%s" % (name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    for vaddr, old, name in CANARY:
        fo = toff + (vaddr - taddr)
        cur = bytes(buf[fo:fo+len(old)])
        if cur != old:
            raise SystemExit("ABORT canary %s @0x%05x: found %s expected %s"
                             % (name, vaddr, cur.hex(), old.hex()))
        print("  [asrt] %-62s @0x%05x ok" % (name, vaddr))

    for vaddr, old, new, name in TEXT:
        patch(toff + (vaddr - taddr), old, new, name, "@0x%05x" % vaddr)

    if done and done != len(TEXT) and skip == 0:
        raise SystemExit("ABORT: partial segkmem reader patch (%d/%d) -- family is atomic" % (done, len(TEXT)))

    open(KERNEL,"wb").write(buf)
    print("CM-B1 segkmem reader group: %d patched, %d already -> %s" % (done, skip, KERNEL))

main()
