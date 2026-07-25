#!/usr/bin/env python3
# patch_ufsbmap.py -- ISSUE-31: ufs_bmap VM-page geometry (the UFS provider half of the
# ISSUE-27 boundary).
#
# Authoritative analysis: amix-kernel-analysis/vm-map/PAGECREATE-REACHABILITY-AND-UFSBMAP.md
# Source contract:        svr4-v4/usr/src/uts/i386/fs/ufs/ufs_bmap.c
#
# WHY THIS EXISTS
# rwip now passes a 4 KiB-derived pagecreate as ufs_bmap's `alloc_only` argument
# (ISSUE-27, landed), but ufs_bmap's own PAGESIZE arithmetic was still 2 KiB.  That is a
# producer/consumer split of exactly the kind that produced ISSUE-27 and ISSUE-28.
# The behavioural site is
#
#     } else if (!alloc_only || roundup(size, PAGESIZE) < bsize) {   /* read the block */
#
# (ufs_bmap.c:398-399 and :448).  With fs_bsize 8192 and the old 2 KiB rounding, sizes
# 4097..6144 round to 6144 and satisfy `< 8192`, so the block is read; with correct
# 4 KiB rounding they round to 8192 and the read is skipped.  Skipping is only safe
# because the caller will now fill whole 4 KiB pages -- which is precisely what the
# ISSUE-27 PAGEMASK fix guarantees.  THE TWO ARE COUPLED AND ISSUE-27 MUST LAND FIRST.
# It has (patch_pagecreate.py, builds 260725-09/-10).
#
# ELEVEN VM-page sites, one unit:
#   0x79d74  blkpp    = PAGESIZE >= bsize ? PAGESIZE/bsize : 0      (ufs_bmap.c:106)
#   0x79d7e  blkpp    numerator PAGESIZE
#   0x79d96  nblks gate  if (PAGESIZE > bsize)                      (:108)
#   0x79da4  nblks    (i_size + PAGEOFFSET)                         (:109)
#   0x79daa  nblks    >> PAGESHIFT                                  (:109)
#   0x7a494 / 0x7a49e / 0x7a4a4   roundup(size, PAGESIZE) indirect alloc   (:398-399)
#   0x7a520 / 0x7a52a / 0x7a530   roundup(size, PAGESIZE) sync write       (:448)
# The two `addil` per roundup are ONE expression: `+PAGEOFFSET / bpl / +PAGEOFFSET /
# &-PAGESIZE` is the compiler's signed-rounding idiom (same shape as rwip's tail-zero).
#
# THREE `moveq #11` SITES THAT MUST NOT CHANGE -- asserted as canaries:
#   0x79ec0, 0x79ee2, 0x7a030   these are NDADDR-1 (= 11) DIRECT-BLOCK THRESHOLD
#   comparisons, not PAGESHIFT.  Verified in the disassembly: each is
#       moveq #11,%d7 ; cmpl <lbn>,%d7 ; blt
#   i.e. `lbn >= NDADDR`.  Converting them to 12 would move the UFS direct-block
#   boundary and corrupt the allocation algorithm.  This is the exact trap the original
#   task brief fell into: it listed these three as conversion candidates.
#
# NOT IN SCOPE: fs_bsize/fragment/sector constants, and the `fs_bsize == PAGESIZE` or
# smaller configuration, which the AMIX root filesystem (fs_bsize 8192, fs_fsize 1024)
# does not exercise and which must not be inferred from an 8192 result.
#
# Old bytes verified against build 68040-260725-11.

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

R47 = b"\x00\x00\x07\xff"; R95 = b"\x00\x00\x0f\xff"
A48 = b"\x00\x00\x08\x00"; A96 = b"\x00\x00\x10\x00"

TEXT = [
 (0x79d74, b"\x0c\x83"+A48, b"\x0c\x83"+A96, "ufs_bmap:blkpp PAGESIZE >= bsize"),
 (0x79d7e, b"\x24\x3c"+A48, b"\x24\x3c"+A96, "ufs_bmap:blkpp PAGESIZE numerator"),
 (0x79d96, b"\x0c\x83"+R47, b"\x0c\x83"+R95, "ufs_bmap:nblks gate PAGESIZE > bsize"),
 (0x79da4, b"\x06\x80"+R47, b"\x06\x80"+R95, "ufs_bmap:nblks i_size + PAGEOFFSET"),
 (0x79daa, b"\x7e\x0b",     b"\x7e\x0c",     "ufs_bmap:nblks >> PAGESHIFT"),
 (0x7a494, b"\x06\x80"+R47, b"\x06\x80"+R95, "ufs_bmap:indirect roundup(size,PAGESIZE)"),
 (0x7a49e, b"\x06\x80"+R47, b"\x06\x80"+R95, "ufs_bmap:indirect roundup sign correction"),
 (0x7a4a4, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "ufs_bmap:indirect roundup mask"),
 (0x7a520, b"\x06\x80"+R47, b"\x06\x80"+R95, "ufs_bmap:syncwrite roundup(size,PAGESIZE)"),
 (0x7a52a, b"\x06\x80"+R47, b"\x06\x80"+R95, "ufs_bmap:syncwrite roundup sign correction"),
 (0x7a530, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "ufs_bmap:syncwrite roundup mask"),
]

CANARY = [
 (0x79ec0, b"\x7e\x0b", "NDADDR-1 direct-block threshold"),
 (0x79ee2, b"\x7e\x0b", "NDADDR-1 direct-block threshold"),
 (0x7a030, b"\x7e\x0b", "NDADDR-1 direct-block threshold"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]

    for vaddr, want, what in CANARY:
        fo = toff + (vaddr - taddr)
        if bytes(buf[fo:fo+len(want)]) != want:
            raise SystemExit("ABORT canary @0x%05x (%s): found %s expected %s -- these "
                             "are NDADDR-1 comparisons; converting them moves the UFS "
                             "direct-block boundary"
                             % (vaddr, what, bytes(buf[fo:fo+len(want)]).hex(), want.hex()))

    # ISSUE-27 must already be in place: ufs_bmap may only skip the read because the
    # caller now fills whole 4 KiB pages.
    fo = toff + (0xaeeba - taddr)
    if bytes(buf[fo:fo+4]) != b"\x02\x46\xf0\x00":
        raise SystemExit("ABORT: as_iolock @0xaeeba is not 4 KiB (found %s) -- ISSUE-27 "
                         "must land BEFORE ufs_bmap, or the skipped read is unsafe"
                         % bytes(buf[fo:fo+4]).hex())

    done=skip=0
    for vaddr, old, new, name in TEXT:
        fo = toff + (vaddr - taddr)
        where = "@0x%05x" % vaddr
        cur=bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-48s %s already" % (name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-48s %s %s->%s" % (name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    if done and done != len(TEXT) and skip == 0:
        raise SystemExit("ABORT: partial ufs_bmap conversion (%d/%d) -- Codex: do NOT "
                         "patch only the first five obvious literals, that leaves the "
                         "ACTIVE indirect rounding decisions old" % (done, len(TEXT)))

    open(KERNEL,"wb").write(buf)
    print("patch_ufsbmap: %d patched, %d already, 0 failed (3 NDADDR canaries + ISSUE-27 "
          "precondition asserted) -> %s" % (done, skip, KERNEL))
    if done + skip != len(TEXT):
        sys.exit(1)

main()
