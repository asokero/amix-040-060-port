#!/usr/bin/env python3
# patch_mincore.py -- Model B (4KB page frame) mincore(2) vector conversion
# (2026-07-19).
#
# Authoritative spec: amix-kernel-analysis/vm-map/MINCORE-VECTOR-PATCH-SPEC.md
# (= census MODEL-B-TEXT-RESIDUAL, commit cbbf40f).  Source contract: 3b2
# os/grow.c mincore() --
#   if (((int)addr & PAGEOFFSET) != 0) return EINVAL;   /* alignment gate */
#   ...
#   rl = btoc(rl);            /* as_incore result bytes -> vec bytes, one   */
#   copyout(vec, ..., rl);    /* vector byte per PAGE                       */
#
# Three sites in mincore (fn @0x585c8):
#   0x585e2  andil #2047,%d0   EINVAL alignment gate on the user address.
#            2047 accepts 2K-aligned (non-page-aligned) addresses under
#            Model B; 4095 restores the exact PAGEOFFSET contract.  Verified
#            against grow.c:523 -- PAGESIZE quantum, NOT the chunk quantum.
#   0x58670  addil #2047,%d0   btoc round-up of as_incore's byte count.
#   0x58678  moveq #11,%d1     the btoc shift (lsrl @0x5867a): one vec byte
#            per 2K page -> under Model B every OTHER vec byte was garbage
#            (uninitialized local past the real vector) and the count was 2x.
# The MC_CACHE chunk quantum 0x40000 (@0x58644) is a fixed 256KB work-window
# byte size, page-size independent: NOT changed.
#
# Each site asserts its expected OLD bytes before writing.  Operates in place
# on build/unix-040, after the other Model B groups (order-independent).

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
 (0x585e2, b"\x02\x80\x00\x00\x07\xff", b"\x02\x80\x00\x00\x0f\xff",
  "mincore:andil #2047 d0 (EINVAL page-alignment gate on addr)"),
 (0x58670, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "mincore:addil #2047 d0 (btoc round-up of as_incore bytes)"),
 (0x58678, b"\x72\x0b", b"\x72\x0c",
  "mincore:moveq #11 d1 (btoc shift: bytes -> vec bytes, 1/page)"),
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

    open(KERNEL,"wb").write(buf)
    print("Model B mincore group: %d patched, %d already -> %s" % (done, skip, KERNEL))

main()
