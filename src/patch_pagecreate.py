#!/usr/bin/env python3
# patch_pagecreate.py -- ISSUE-27: Model B (4KB page frame) conversion of the
# segmap_pagecreate CONSUMER family (tail-zero bounds + as_iolock page-list geometry).
#
# Authoritative spec:  docs/contracts/PAGECREATE-TAILZERO-SPEC.md
# Authoritative census: docs/contracts/PAGECREATE-TAILZERO-CENSUS.md
#
# ROOT CAUSE
# segmap_pagecreate (0xa9722) already creates COMPLETE 4 KiB pages and deliberately
# leaves them uninitialized -- the caller must zero whatever uiomove did not write.
# But every caller still rounds its zero-fill bound to 2 KiB.  For a partial write at
# the start of a page the interval
#       [ roundup(end, 2048), roundup(end, 4096) )
# is therefore NEVER zeroed and keeps the recycled physical page's old contents; a
# later write into that same cached page turns those bytes into file contents.  On the
# measured root filesystem (UFS, fs_bsize 8192) this is a live, silent data leak.
#
# THE PRODUCER IS ALREADY CONVERTED -- asserted as canaries below:
#       0xa9742  02 42 f0 00        align start & -4096
#       0xa97a0  48 78 10 00        page_get(4096, ...)
#       0xa9892  06 82 00 00 10 00  next VA += 4096
#       0xa9898  06 84 00 00 10 00  next vnode offset += 4096
# (patch_modelb_pager.py:195-197 and patch_modelb.py:557).  If those are NOT already
# 4 KiB this patch refuses to run: converting consumers against a 2 KiB producer would
# be the mirror image of the very bug being fixed.
#
# GROUPS (env PAGECREATE_GROUPS, default all) -- spec "Atomic implementation units":
#   live   as_iolock(12) + rwip(5) + rwvp(5).  ATOMIC: converting as_iolock while its
#          callers still zero at 2 KiB splits the producer/consumer contract; converting
#          only the tails leaves as_iolock making overlapping 2 KiB VOP_GETPAGE calls.
#   fbzero fbzero(2).  Independent of the as_iolock list contract.  It is the only
#          caller passing softlock=1; its fbrelse releases through the already-4 KiB
#          as_fault(F_SOFTUNLOCK) path, so no softlock imbalance is introduced.
#   spec   spec_write(4).  No page-list ownership in the current body; lands alone.
#
# DELIBERATELY NOT IN THIS PATCH:
#   * S5 writei (0x70cfa and its geometry group).  Byte-identical to s5/exp but no
#     available C source is an exact semantic match: AMIX probes source pages with
#     fubyte, calls segmap_pagecreate BEFORE bmapalloc, and its ENOSPC partial branch
#     does not recompute the pagecreate flag.  Spec: separate structural port, safely
#     deferred because S5 is not mounted on this installation.
#   * ufs_bmap's own PAGESIZE arithmetic (0x79d48; 2 KiB sites at 0x79d74, 0x79d7e,
#     0x79d96, 0x79da4, 0x79daa, 0x79ec0, 0x79ee2, 0x7a030).  rwip passes `pagecreate`
#     into ufs_bmap as alloc_only, so this conversion DOES change UFS allocation /
#     read-before-write behaviour -- but the spec is explicit that ufs_bmap's internals
#     are a separate provider/allocation audit and must NOT be converted by matching
#     constants mechanically.  THIS IS THE MAIN RESIDUAL RISK OF THE PATCH and is why
#     the acceptance gate includes disk truth across sync+reboot+fsck.
#   * MAXBSIZE 0x2000/0x1fff/&-0x2000, segmap slot stride, vfs_bshift, >>9 sectors,
#     UFS fragment constants.  None of those are VM page geometry.
#
# Each site asserts its expected OLD bytes before writing (fail-closed).  Old bytes were
# re-verified against build 68040-260725-05 (SHA-256 709263b200486ed3e426ead57eeaff5606
# e5327cb562898bcb29c5383bfbc104); the SHA pinned in the census is an older image, but
# all 32 addresses were confirmed byte-identical in the current one.

import struct, sys, os
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
GROUPS = set((os.environ.get("PAGECREATE_GROUPS") or "live,fbzero,spec").split(","))

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

A48 = b"\x00\x00\x08\x00"; A96 = b"\x00\x00\x10\x00"
R47 = b"\x00\x00\x07\xff"; R95 = b"\x00\x00\x0f\xff"

# (group, vaddr, expect, new, name)
TEXT = [
 # ---- as_iolock 0xaee34, size 0x294 -- ALL 12 sites, spec census table -----
 ("live", 0xaee6a, b"\x02\x80"+R47, b"\x02\x80"+R95, "as_iolock:input offset page-alignment test"),
 ("live", 0xaeeba, b"\x02\x46\xf8\x00", b"\x02\x46\xf0\x00", "as_iolock:below-EOF trim (n &= PAGEMASK)"),
 ("live", 0xaeece, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "as_iolock:source VA page base"),
 ("live", 0xaeed6, b"\x02\x80"+R47, b"\x02\x80"+R95, "as_iolock:source-page offset"),
 ("live", 0xaeedc, b"\x26\x3c"+A48, b"\x26\x3c"+A96, "as_iolock:first-page copy length"),
 ("live", 0xaef02, b"\x06\x80"+A48, b"\x06\x80"+A96, "as_iolock:page-end test"),
 ("live", 0xaef10, b"\x06\x80\xff\xff\xf8\x00", b"\x06\x80\xff\xff\xf0\x00", "as_iolock:last-page length correction"),
 ("live", 0xaefdc, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "as_iolock:VOP_GETPAGE plsz"),
 ("live", 0xaefe4, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "as_iolock:VOP_GETPAGE len"),
 ("live", 0xaf000, b"\x26\x3c"+A48, b"\x26\x3c"+A96, "as_iolock:loop copy length"),
 ("live", 0xaf006, b"\x06\x82"+A48, b"\x06\x82"+A96, "as_iolock:loop source VA"),
 ("live", 0xaf01c, b"\x02\x80"+R47, b"\x02\x80"+R95, "as_iolock:final pagecreate decision"),

 # ---- rwip 0x7f4ca -- UFS, LIVE root filesystem: tail-zero bound ----------
 ("live", 0x7f9b6, b"\x06\x80"+R47, b"\x06\x80"+R95, "rwip:roundup(off+on+n, PAGESIZE)"),
 ("live", 0x7f9bc, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "rwip:roundup mask"),
 ("live", 0x7f9d6, b"\x06\x80"+R47, b"\x06\x80"+R95, "rwip:kzero length round (n+PAGEOFFSET)"),
 ("live", 0x7f9e0, b"\x06\x80"+R47, b"\x06\x80"+R95, "rwip:kzero length round (negative correction)"),
 ("live", 0x7f9e6, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "rwip:kzero length mask"),

 # ---- rwvp 0x88d4c -- NFS: same tail-zero shape ---------------------------
 ("live", 0x88fba, b"\x06\x80"+R47, b"\x06\x80"+R95, "rwvp:roundup(off+on+n, PAGESIZE)"),
 ("live", 0x88fc0, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "rwvp:roundup mask"),
 ("live", 0x88fd4, b"\x06\x80"+R47, b"\x06\x80"+R95, "rwvp:kzero length round"),
 ("live", 0x88fde, b"\x06\x80"+R47, b"\x06\x80"+R95, "rwvp:kzero length round (negative correction)"),
 ("live", 0x88fe4, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "rwvp:kzero length mask"),

 # ---- fbzero 0x3fa22 -- the only softlock=1 caller ------------------------
 ("fbzero", 0x3fa90, b"\x06\x83"+R47, b"\x06\x83"+R95, "fbzero:roundup"),
 ("fbzero", 0x3fa96, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00", "fbzero:roundup mask"),

 # ---- spec_write 0x66470 -- block-device path ----------------------------
 ("spec", 0x6666c, b"\x06\x80"+R47, b"\x06\x80"+R95, "spec_write:roundup"),
 ("spec", 0x66672, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "spec_write:roundup mask"),
 ("spec", 0x66688, b"\x06\x80"+R47, b"\x06\x80"+R95, "spec_write:kzero length round"),
 ("spec", 0x6668e, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "spec_write:kzero length mask"),
]

# producer must ALREADY be 4 KiB (spec "Patch assertions")
PRODUCER = [
 (0xa9742, b"\x02\x42\xf0\x00",             "segmap_pagecreate:align start &-4096"),
 (0xa97a0, b"\x48\x78\x10\x00",             "segmap_pagecreate:page_get(4096)"),
 (0xa9892, b"\x06\x82\x00\x00\x10\x00",     "segmap_pagecreate:next VA +4096"),
 (0xa9898, b"\x06\x84\x00\x00\x10\x00",     "segmap_pagecreate:next offset +4096"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    secs=sections(bytes(buf))
    tidx, taddr, toff = secs[".text"]

    for vaddr, want, what in PRODUCER:
        fo = toff + (vaddr - taddr)
        if bytes(buf[fo:fo+len(want)]) != want:
            raise SystemExit("ABORT producer @0x%05x (%s): found %s expected %s -- "
                             "segmap_pagecreate is NOT the 4 KiB producer this patch "
                             "assumes; refusing to convert its consumers"
                             % (vaddr, what, bytes(buf[fo:fo+len(want)]).hex(), want.hex()))
    print("  [prod] segmap_pagecreate 4 KiB producer asserted (4 sites)")

    done=skip=off=0
    sel=[t for t in TEXT if t[0] in GROUPS]

    for grp, vaddr, old, new, name in TEXT:
        fo = toff + (vaddr - taddr)
        where = "@0x%05x" % vaddr
        if grp not in GROUPS:
            off += 1; continue
        cur=bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-8s %-52s %s already" % (grp, name, where)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-8s %-52s %s %s->%s" % (grp, name, where, old.hex(), new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s %s: found %s expected %s" % (name, where, cur.hex(), old.hex()))

    if "live" in GROUPS and done and (done+skip) != len(sel):
        raise SystemExit("ABORT: partial conversion (%d/%d) -- the live as_iolock/rwip/"
                         "rwvp unit is ATOMIC" % (done+skip, len(sel)))

    open(KERNEL,"wb").write(buf)
    print("patch_pagecreate groups=%s: %d patched, %d already, %d not-selected -> %s"
          % (",".join(sorted(GROUPS)), done, skip, off, KERNEL))
    if done + skip != len(sel):
        sys.exit(1)

main()
