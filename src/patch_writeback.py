#!/usr/bin/env python3
# patch_writeback.py -- Model B (4KB page frame) writeback/putpage conversion group.
#
# The page-IN side is fully converted (patch_modelb.py Tier-0/1 + patch_modelb_pager.py
# Tier-2, 123/123 sites); the page-OUT side was still 2KB: a dirty 4KB page got only its
# lower 2KB written back while the dirty bit was cleared -> silent data loss under
# fsflush / pageout / mmap-write / big copies.  This was also the gate for re-enabling
# schedpaging (whose runtime040.s rts-override was RETIRED 2026-07-15 together with the
# 'pageoutd' group below) and a precondition for the caches-on track.  sched (process
# swapper) remains disabled in runtime040.s.
#
# Authoritative site list + do-not-patch traps:
#   docs/contracts/PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md
# Task brief: docs/archive/WRITEBACK-TASK.md.  Phase-0 policy ANSWERED 2026-07-15: root fs is UFS,
# fs_bsize 8192 / fs_fsize 1024 -> keep provider shape, require fs_bsize >= 2048 (the
# mountfs gate below).  s5 is not mounted anywhere -> s5putpage NOT converted here
# (512B S5MAXREQ stack hazard; see matrix) -- it keeps writing 2KB, which is only
# reachable if someone mounts an s5 fs.
#
# DO NOT PATCH (traps, from the matrix):
#   * segmap slot constants 0x2000/0x1fff/shift-13 = MAXBSIZE slot design
#   * page-hash moveq #11 = uniform hash, not PFN math
#   * >>9 / 0x200 = 512-byte disk sectors (e.g. ufs_putpage 0x82d06 moveq #9 lsrl)
#   * UFS 0x1fff/0xffffe000 MAXBSIZE rounds
#   * segvn_sync large-range len forward 0xad072 (caller len, not a literal)
#   * pvn_done 0xb1d60 -- ALREADY converted by patch_modelb_pager.py
#
# Bisection: WRITEBACK_GROUPS=spec,pvn,ufs,callers (default all).  Test order per
# docs/archive/WRITEBACK-TASK.md: spec -> spec,pvn -> spec,pvn,ufs -> all.  mountfs gate is in
# group 'ufs' (same policy unit).
#
# Each site asserts its expected OLD bytes before writing.  Operates in place on
# build/unix-040, AFTER patch_modelb.py + patch_modelb_pager.py.

import struct, sys, os
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
GROUPS = set((os.environ.get("WRITEBACK_GROUPS") or "spec,pvn,ufs,callers,pageoutd").split(","))
def group_of(name):
    if name.startswith("spec_putpage"):    return "spec"
    if name.startswith("pvn_range_dirty"): return "pvn"
    if name.startswith("ufs_putpage"):     return "ufs"
    if name.startswith("mountfs"):         return "ufs"
    if name.startswith("setupclock"):      return "pageoutd"
    if name.startswith("pageout"):         return "pageoutd"
    return "callers"

def u16(b,o): return struct.unpack(">H", b[o:o+2])[0]
def u32(b,o): return struct.unpack(">I", b[o:o+4])[0]
def text_sec(b):
    sh=u32(b,32); ent=u16(b,46); n=u16(b,48); st=u16(b,50)
    so=u32(b, sh+st*ent+16)
    for i in range(n):
        o=sh+i*ent; nm=u32(b,o)
        e=b.index(b"\0", so+nm)
        if b[so+nm:e]==b".text": return u32(b,o+12), u32(b,o+16)
    raise SystemExit("no .text")

A47  = b"\x00\x00\x07\xff"; A95 = b"\x00\x00\x0f\xff"   # #2047 -> #4095 (long imm)
A48  = b"\x00\x00\x08\x00"; A96 = b"\x00\x00\x10\x00"   # #2048 -> #4096 (long imm)

# (vaddr, expect_bytes, new_bytes, name)
P = [
 # ===== spec_putpage (unit 1: simplest provider -- no fs sub-block policy; one dirty
 # VM page becomes one 4KB block-device page-I/O write) =====
 (0x67330, b"\x2d\x7c"+A48, b"\x2d\x7c"+A96, "spec_putpage:movel #2048 fp@(-12) (UNKNOWN_SIZE 1-pg cluster)"),
 (0x6741e, b"\x06\x80"+A47, b"\x06\x80"+A95, "spec_putpage:addil #2047 d0 (bounded fsize round)"),
 (0x67424, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "spec_putpage:andiw #-2048 d0 (bounded fsize mask)"),
 (0x67486, b"\x26\x3c"+A48, b"\x26\x3c"+A96, "spec_putpage:movel #2048 d3 (dirty-page io_len)"),
 # ===== pvn_range_dirty (unit 2: shared by every provider -- a 4KB request must not
 # be collected through a 2KB range scanner) =====
 (0xb2266, b"\x02\x44\xf8\x00", b"\x02\x44\xf0\x00", "pvn_range_dirty:andiw #-2048 d4 (off page-align)"),
 (0xb226a, b"\x06\x83"+A47, b"\x06\x83"+A95, "pvn_range_dirty:addil #2047 d3 (eoff round)"),
 (0xb2270, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00", "pvn_range_dirty:andiw #-2048 d3 (eoff mask)"),
 (0xb22b4, b"\x06\x82"+A48, b"\x06\x82"+A96, "pvn_range_dirty:addil #2048 d2 (main range walk)"),
 (0xb2302, b"\x06\x82\xff\xff\xf8\x00", b"\x06\x82\xff\xff\xf0\x00", "pvn_range_dirty:addil #-2048 d2 (backward cluster)"),
 (0xb2340, b"\x06\x82"+A48, b"\x06\x82"+A96, "pvn_range_dirty:addil #2048 d2 (forward cluster)"),
 # ===== ufs_putpage (unit 3: THE live provider, root is UFS) + mountfs policy gate =====
 (0x82c56, b"\x24\x3c"+A48, b"\x24\x3c"+A96, "ufs_putpage:movel #2048 d2 (initial io_len)"),
 (0x82cac, b"\x06\x82"+A48, b"\x06\x82"+A96, "ufs_putpage:addil #2048 d2 (contig-page io_len growth)"),
 (0x82cd6, b"\x0c\xac"+A47, b"\x0c\xac"+A95, "ufs_putpage:cmpil #2047 a4@(48) (fs_bsize<PAGESIZE gate)"),
 (0x82ce2, b"\x20\x3c"+A48, b"\x20\x3c"+A96, "ufs_putpage:movel #2048 d0 (p_nio numerator)"),
 (0x82d2a, b"\x0c\xac"+A47, b"\x0c\xac"+A95, "ufs_putpage:cmpil #2047 a4@(48) (2nd-write gate)"),
 # mountfs: old gate rejected fs_bsize <= 1023 (PAGESIZE/2 - 1).  Policy (matrix +
 # Phase-0): the provider keeps its "at most two fs blocks per VM page" shape, so
 # REQUIRE fs_bsize >= 2048 -- reject <= 2047.  Live root is bsize 8192 (margin 4x).
 (0x7e67e, b"\x0c\xaa\x00\x00\x03\xff", b"\x0c\xaa"+A47, "mountfs:cmpil #1023 -> #2047 a2@(48) (reject fs_bsize<2048)"),
 # ===== pageout-daemon enablement (unit 5 'pageoutd', 2026-07-15: schedpaging's
 # runtime040.s rts-override retired -> the stock tuning + pageout daemon run again).
 # setupclock (boot): handspread clamp ptob = npages<<11; ONE moveq #11 feeds BOTH
 # asll uses (0x51ef0 compare + 0x51f00 store).  pageout (daemon head): front hand =
 # back hand + btop(handspread)*sizeof(struct page); btop was (x+2047)>>11.  The *60
 # (page struct size) and hand walking are page-size-agnostic.  Stock schedpaging
 # itself (0x51f88) is pure page-count tunable math -- no conversion needed. =====
 (0x51eee, b"\x74\x0b", b"\x74\x0c", "setupclock:handspread ptob moveq #11->#12 (feeds 2 asll)"),
 (0x5204c, b"\x06\x80"+A47, b"\x06\x80"+A95, "pageout:btop(handspread) round +2047"),
 (0x52052, b"\x72\x0b", b"\x72\x0c", "pageout:btop(handspread) shift moveq #11->#12"),
 # ===== generic one-page VOP_PUTPAGE callers (unit 4: AFTER providers can consume a
 # 4KB dirty page; all four pass len as an immediate pea 0x800) =====
 (0x52238, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "checkpage:pea 2048 (pageout B_ASYNC|B_FREE len)"),
 (0x5c1e2, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "fsflush:pea 2048 (async clean len)"),
 (0xacf36, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "segvn_swapout:pea 2048 (per-page len)"),
 (0xad148, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "segvn_sync:pea 2048 (per-page len)"),
]

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    sa, so = text_sec(buf)
    done=skip=off=0
    for vaddr, old, new, name in P:
        assert len(old)==len(new), name
        if group_of(name) not in GROUPS:
            off+=1; continue
        fo = so + (vaddr - sa)
        cur = bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-58s @0x%05x already" % (name,vaddr)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-58s @0x%05x %s->%s" % (name,vaddr,old.hex(),new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s @0x%05x: found %s expected %s" % (name,vaddr,cur.hex(),old.hex()))
    open(KERNEL,"wb").write(buf)
    print("Model B writeback/putpage groups=%s: %d patched, %d already, %d skipped -> %s"
          % (",".join(sorted(GROUPS)),done,skip,off,KERNEL))

main()
