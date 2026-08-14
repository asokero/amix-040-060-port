#!/usr/bin/env python3
# patch_pvntrunc.py -- pvn_vptrunc final-page tail zeroing (Codex P1 in
# vm-map/PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md).
#
# Source contract: svr4-src-3b2/usr/src/uts/3b2/vm/vm_pvn.c, pvn_vptrunc().  Described
# rather than quoted: it maps the block containing the new end-of-file through segmap,
# then zeroes from the offset within that block for a length of MAX(zbytes, PAGESIZE -
# (vplen & PAGEOFFSET)) -- i.e. at least to the end of the page the new EOF lands in.
#
# Its purpose, per the commentary in ufs_inode.c, is that the bytes after end-of-file
# must be zero in case the file later grows and makes them reachable again.  The page it
# is clearing is a 4 KiB page, but the PAGESIZE/PAGEOFFSET
# term is still 2 KiB, so a truncation whose offset lands in the LOWER half of a 4 KiB
# page clears only as far as the next 2 KiB boundary and leaves the upper part of the
# final page holding data from beyond the new EOF.
#
# Compiled shape in build/unix-040 (pvn_vptrunc @0xb2370):
#     0xb248c  andil #2047,%d0     vplen & PAGEOFFSET
#     0xb2492  subil #2048,%d0     (vplen & PAGEOFFSET) - PAGESIZE
#     0xb2498  negl  %d0           = PAGESIZE - (vplen & PAGEOFFSET)
#     0xb249e  cmpl  %d2,%d0 / bhi / movel %d2,%d0     = MAX(zbytes, ...)
#
# DO NOT TOUCH -- these are the 8 KiB SEGMAP SLOT, not VM pages, and are asserted as
# canaries on every run:
#     0xb2474  andiw #-8192,%d1    vplen & MAXBMASK   -> segmap_getmap slot base
#     0xb24aa  andil #8191,%d0     vplen & MAXBOFFSET -> offset within the slot
# The neighbouring `(zbytes + (vplen & MAXBOFFSET)) > MAXBSIZE` panic guard is likewise
# MAXBSIZE geometry and is not page geometry.
#
# REACHABILITY -- READ THIS BEFORE CLAIMING THIS FIXES AN OBSERVABLE BUG.
# The term is NOT dead under MAX(): ufs_itrunc passes zbytes = bsize - offset, and for a
# truncation inside the first NDADDR direct blocks bsize = fragroundup(fs, offset), so
# on this 1 KiB-fragment filesystem zbytes <= 1023 and the page term dominates.
# However, a truncate+regrow probe (test-tools/trunctest.c) did NOT reproduce a stale
# tail on UFS: truncate FREES the blocks past fragroundup(new_size), so the region this
# term fails to clear is deallocated, and regrowth re-allocates it through the
# zero-filling path.  The same structural masking defeated the first ISSUE-27 probes.
# This patch is therefore landed as a CONTRACT correction with an unproven live
# exposure on UFS; the NFS and s5 callers (nfs_vnops.c:842, s5alloc.c:481) are not
# mounted here and are not covered by that negative result.
#
# Each site asserts its expected OLD bytes before writing (fail-closed).  Verified
# against build 68040-260725-09.

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
        out[b[so+nm:e].decode()]=(i, u32(b,o+12), u32(b,o+16))
    return out

TEXT = [
 (0xb248c, b"\x02\x80\x00\x00\x07\xff", b"\x02\x80\x00\x00\x0f\xff",
  "pvn_vptrunc:vplen & PAGEOFFSET"),
 (0xb2492, b"\x04\x80\x00\x00\x08\x00", b"\x04\x80\x00\x00\x10\x00",
  "pvn_vptrunc:PAGESIZE - (vplen & PAGEOFFSET)"),
]

CANARY = [
 (0xb2474, b"\x02\x41\xe0\x00", "vplen & MAXBMASK (8 KiB segmap slot)"),
 (0xb24aa, b"\x02\x80\x00\x00\x1f\xff", "vplen & MAXBOFFSET (8 KiB slot offset)"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]
    done=skip=0

    for vaddr, want, what in CANARY:
        fo = toff + (vaddr - taddr)
        if bytes(buf[fo:fo+len(want)]) != want:
            raise SystemExit("ABORT canary @0x%05x (%s): found %s expected %s -- the "
                             "8 KiB segmap-slot constants must stay unchanged"
                             % (vaddr, what, bytes(buf[fo:fo+len(want)]).hex(), want.hex()))

    for vaddr, old, new, name in TEXT:
        fo = toff + (vaddr - taddr)
        where = "@0x%05x" % vaddr
        cur=bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-52s %s already" % (name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-52s %s %s->%s" % (name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    if done and done != len(TEXT) and skip == 0:
        raise SystemExit("ABORT: partial pvn_vptrunc patch (%d/%d) -- the mask and the "
                         "subtraction are one expression" % (done, len(TEXT)))

    open(KERNEL,"wb").write(buf)
    print("patch_pvntrunc: %d patched, %d already, 0 failed (2 canaries intact) -> %s"
          % (done, skip, KERNEL))
    if done + skip != len(TEXT):
        sys.exit(1)

main()
