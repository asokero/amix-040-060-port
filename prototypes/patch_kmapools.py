#!/usr/bin/env python3
# patch_kmapools.py -- ISSUE-15: Model B (4KB page frame) KMA pool page counts
# (SMALLCLICKS/BIGCLICKS) + kmem_avail ptob() shift.
#
# Authoritative source contract: svr4-src-3b2/usr/src/uts/3b2/os/kma.c:67-70 --
#   SMALLCLICKS = btoc(SMALLBYTES)   (SMALLBYTES = 4096)
#   BIGCLICKS   = btoc(BIGBYTES)     (BIGBYTES   = 16384)
# btoc() is bytes-to-clicks (pages), compile-time constant for a given PAGESIZE.
# Stock 030 PAGESIZE=2048 -> SMALLCLICKS=2, BIGCLICKS=8.  Model B PAGESIZE=4096 ->
# SMALLCLICKS=1, BIGCLICKS=4.  Today's build still asks sptalloc for the STOCK
# click counts (2 pages / 8 pages) while every other accounting field (bitmap
# size, MAXASMALL/MAXABIG, kmeminfo byte counts) already treats the pool as
# managing exactly SMALLBYTES=4096 / BIGBYTES=16384 bytes of backing.  Result:
# kmem_allocspool maps 2*4096=8192 bytes of virtual space to back a 4096-byte
# pool (double the backing, half of it a dangling alias); kmem_allocbpool maps
# 8*4096=32768 bytes to back a 16384-byte pool.  kmem_freepool tears down the
# same (symmetric) 2/8-click span it allocated, so there's no leak or overlap
# today -- just permanently wasted sptalloc/sptmap virtual space and needless
# sptmap churn on every pool alloc/free.
#
# THE FIX IS SAFE: halving the click count does not change the number of bytes
# each pool manages (still SMALLBYTES=4096 / BIGBYTES=16384 -- those constants
# and every byte-counting site below are UNTOUCHED).  It only makes the backing
# VM allocation (sptalloc/sptfree page count) match the byte count 1:1 on a 4K
# page.  The pool's mapped end address now lands EXACTLY on the allocation's
# end (small pool: 1 click * 4096 = 4096 bytes; big pool: 4 clicks * 4096 =
# 16384 bytes) instead of 4096/16384 bytes past it.
#
# ALSO IN THIS GROUP (found in this session, NOT in the original Codex spec):
# kmem_avail() computes ptob(availrmem - tune.t_minarmem) with a hardcoded
# PAGESIZE-2048 shift of 11 (bytes = pages << 11).  On Model B (4096-byte
# pages) this reports HALF the real available byte count to STREAMS bufcall
# backpressure callers.  Shift must be 12.
#
# DO NOT TOUCH (buffer/hash constants, NOT page-size derived -- verified
# non-overlapping with every other patch_*.py in this tree):
#   SMALLBYTES 4096   (0x41c30 addil #4096,%d3)
#   BIGBYTES   16384  (0x41e1c addil #16384,%d3)
#   MAXASMALL  256    (0x41c3a / 0x41c40 / 0x41d2c, andiw #-256)
#   MAXABIG    4096   (0x41e26 addil #4095 / 0x41e2c andiw #-4096)
#   bitmap size 64 bytes (0x41d38 moveq #64)
#   HASH shift 14 (moveq #14 + andl #127)
#   kmeminfo byte bookkeeping (0x41d52 addil #-512, 0x42cb2 addil #512,
#     0x42c60-0x42c68)
#
# Also NOT in scope: kmem_alloc/kmem_free >4096-byte paths -- already converted
# by patch_modelb.py:606-610 (0x42002/0x420b6/0x4246a = moveq #12).
#
# Each site asserts its expected OLD bytes before writing (fail-closed: any
# mismatch aborts the whole run rather than guessing an address).  Operates in
# place on build/unix-040.  Old bytes below were verified against the build
# committed as of this patch (SHA-256 5bd37386d9c5a0f89be451b187fa5dfe9e4f05b
# cf2f1c37accdc22177a225b38).

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
 # kmem_allocspool @0x41b7e -- SMALLCLICKS 2 -> 1
 (0x41bac, b"\x55\x80", b"\x53\x80",
  "allocspool:subql #2,d0 (availrmem headroom test)"),
 (0x41bc0, b"\x55\x80", b"\x53\x80",
  "allocspool:subql #2,d0 (availsmem headroom test)"),
 (0x41bca, b"\x55\xb9", b"\x53\xb9",
  "allocspool:subql #2,availrmem"),
 (0x41bd0, b"\x55\xb9", b"\x53\xb9",
  "allocspool:subql #2,availsmem"),
 (0x41be4, b"\x48\x78\x00\x02", b"\x48\x78\x00\x01",
  "allocspool:pea SMALLCLICKS (sptalloc arg1)"),
 (0x41bf8, b"\x54\xb9", b"\x52\xb9",
  "allocspool:addql #2,availrmem (sptalloc-fail unwind)"),
 (0x41bfe, b"\x54\xb9", b"\x52\xb9",
  "allocspool:addql #2,availsmem (sptalloc-fail unwind)"),
 (0x41c20, b"\x54\xb9", b"\x52\xb9",
  "allocspool:addql #2,pages_pp_kernel"),

 # kmem_allocbpool @0x41d96 -- BIGCLICKS 8 -> 4
 (0x41dc8, b"\x51\x80", b"\x59\x80",
  "allocbpool:subql #8,d0 (availrmem headroom test)"),
 (0x41ddc, b"\x51\x80", b"\x59\x80",
  "allocbpool:subql #8,d0 (availsmem headroom test)"),
 (0x41de6, b"\x51\xb9", b"\x59\xb9",
  "allocbpool:subql #8,availrmem"),
 (0x41dec, b"\x51\xb9", b"\x59\xb9",
  "allocbpool:subql #8,availsmem"),
 (0x41dfe, b"\x48\x78\x00\x08", b"\x48\x78\x00\x04",
  "allocbpool:pea BIGCLICKS (sptalloc arg1)"),
 (0x41e4a, b"\x48\x78\x00\x08", b"\x48\x78\x00\x04",
  "allocbpool:pea BIGCLICKS (sptfree arg2, kmem_alloc-fail)"),
 (0x41e56, b"\x50\xb9", b"\x58\xb9",
  "allocbpool:addql #8,availrmem (fail unwind)"),
 (0x41e5c, b"\x50\xb9", b"\x58\xb9",
  "allocbpool:addql #8,availsmem (fail unwind)"),
 (0x41e7e, b"\x50\xb9", b"\x58\xb9",
  "allocbpool:addql #8,pages_pp_kernel"),

 # kmem_freepool @0x42a18 -- both branches symmetrically
 (0x42c74, b"\x74\x08", b"\x74\x04",
  "freepool:moveq #8,d2 (BIGCLICKS -> sptfree npages)"),
 (0x42c84, b"\x50\xb9", b"\x58\xb9",
  "freepool:addql #8,availrmem (big)"),
 (0x42c8a, b"\x50\xb9", b"\x58\xb9",
  "freepool:addql #8,availsmem (big)"),
 (0x42c90, b"\x51\xb9", b"\x59\xb9",
  "freepool:subql #8,pages_pp_kernel (big)"),
 (0x42cca, b"\x74\x02", b"\x74\x01",
  "freepool:moveq #2,d2 (SMALLCLICKS -> sptfree npages)"),
 (0x42cda, b"\x54\xb9", b"\x52\xb9",
  "freepool:addql #2,availrmem (small)"),
 (0x42ce0, b"\x54\xb9", b"\x52\xb9",
  "freepool:addql #2,availsmem (small)"),
 (0x42ce6, b"\x55\xb9", b"\x53\xb9",
  "freepool:subql #2,pages_pp_kernel (small)"),

 # kmem_avail @0x42d68 -- ptob() shift
 (0x42d7a, b"\x74\x0b", b"\x74\x0c",
  "kmem_avail:moveq #11,d2 (ptob(availrmem-minarmem) <<11 -> <<12)"),
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
        raise SystemExit("ABORT: partial KMA pool patch (%d/%d) -- group is atomic" % (done, len(TEXT)))

    open(KERNEL,"wb").write(buf)
    print("patch_kmapools: %d patched, %d already, 0 failed -> %s" % (done, skip, KERNEL))
    if done + skip != len(TEXT):
        sys.exit(1)

main()
