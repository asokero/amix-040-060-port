#!/usr/bin/env python3
# patch_swapgeom.py -- Model B (4KB page frame) swap resource GEOMETRY conversion
# group (2026-07-19).
#
# Authoritative spec: docs/contracts/SWAPADD-MODEL-B-PATCH-SPEC.md
# (commit cbbf40f).  swap_xlate (0xb2aea) is already Model B (slot k -> si_soff +
# (k << 12)), but the resource CONSTRUCTORS/DESTRUCTORS still count and step 2KB
# slots.  Live-observed symptom: swapadd allocates 51199 swapent slots for a
# 25600-page (100MiB) resource -- double slot table, si_soff/si_eoff rounded at
# 2KB, kmem_free size disagreeing with the allocation, and undelswap stepping
# +0x800 (two entries per Model B page, disagreeing with swap_xlate).
#
# This is ONE correctness patch across five functions; the five swapadd sites
# alone are NOT sufficient (spec: "Reject a build in which only the five swapadd
# sites changed"):
#   swapdel_byname/swapdel  must reconstruct the exact si_soff swapadd stored,
#                           or an existing resource cannot be found;
#   swapinfo_free           must pass the exact original si_npgs*16 allocation
#                           size to kmem_free or the kernel heap corrupts;
#   undelswap               walks the slot table recreating vnode offsets and
#                           must step one Model B page per slot.
# Disk-block conversions (<<9/>>9) are 512-byte units and DO NOT change.
#
# swap_maxcontig (.data+0xb544 = 0x200) intentionally NOT touched: policy-review
# item, rotation no-op with a single swap area (same stance as patch_swapin.py).
#
# Each site asserts its expected OLD bytes before writing.  Operates in place on
# build/unix-040, AFTER patch_modelb*.py + patch_writeback.py + patch_swapin.py.

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

# .text sites: (vaddr, expect, new, name)
TEXT = [
 (0xb2d60, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff",
  "swapdel_byname:addil #2047 d2 (round lowblk<<9 up)"),
 (0xb2d66, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00",
  "swapdel_byname:andiw #0xf800 d2 (align start down)"),
 (0xb321e, b"\x06\x83\x00\x00\x07\xff", b"\x06\x83\x00\x00\x0f\xff",
  "swapadd:addil #2047 d3 (round start up)"),
 (0xb3224, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00",
  "swapadd:andiw #0xf800 d3 (align start)"),
 (0xb3228, b"\x02\x44\xf8\x00", b"\x02\x44\xf0\x00",
  "swapadd:andiw #0xf800 d4 (align end)"),
 (0xb323c, b"\x06\x85\x00\x00\x07\xff", b"\x06\x85\x00\x00\x0f\xff",
  "swapadd:addil #2047 d5 (round byte span before page count)"),
 (0xb3242, b"\x72\x0b", b"\x72\x0c",
  "swapadd:moveq #11 d1 (bytes to pages shift)"),
 (0xb349c, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "swapdel:addil #2047 d0 (round lowblk<<9 up)"),
 (0xb34a2, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00",
  "swapdel:andiw #0xf800 d0 (align start)"),
 (0xb369c, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "swapinfo_free:addil #2047 d0 (recompute table page count)"),
 (0xb36a2, b"\x72\x0b", b"\x72\x0c",
  "swapinfo_free:moveq #11 d1 (bytes to pages before *16)"),
 (0xb3d70, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00",
  "undelswap:addil #2048 d2 (advance backing offset per slot)"),
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

    for vaddr, old, new, name in TEXT:
        patch(toff + (vaddr - taddr), old, new, name, "@0x%05x" % vaddr)

    if done and done != len(TEXT) and skip == 0:
        raise SystemExit("ABORT: partial swap geometry patch (%d/%d) -- group is atomic" % (done, len(TEXT)))

    open(KERNEL,"wb").write(buf)
    print("Model B swap geometry group: %d patched, %d already -> %s" % (done, skip, KERNEL))

main()
