#!/usr/bin/env python3
# patch_memcntl.py -- ISSUE-28: Model B (4KB page frame) page geometry in
# memcntl(2) / mem_unlock, i.e. the mlock-bitmap producer/consumer contract.
#
# Authoritative source contract: svr4-src-3b2/usr/src/uts/3b2/os/lock.c:266-415.
#
# THE ASYMMETRY (same shape as ISSUE-27's segmap_pagecreate family):
#   as_ctl        0xaeafe  -- ALREADY 4 KiB (patch_modelb.py:333-337)
#   segvn_lockop  0xad2f0  -- ALREADY 4 KiB (patch_modelb.py:302-307)
# Those two FILL and index the mlock bitmap in 4 KiB page units.  But memcntl
# still SIZES that bitmap and mem_unlock still WALKS it with 2 KiB arithmetic.
# Consequences on the current build:
#   (a) `if (((int)addr & PAGEOFFSET) != 0) return EINVAL` uses 2047, so an
#       address that is 2048-aligned but NOT 4096-aligned passes the gate;
#       as_ctl then masks it down to a 4 KiB boundary and operates on a
#       DIFFERENT range than the caller asked for.
#   (b) mlock_size = BT_BITOUL(btoc(rlen)) with >>11 allocates twice the bits
#       actually needed.  Harmless over-allocation on its own (as_ctl writes
#       only the 4 KiB-indexed half), but it is the same divergence.
#   (c) THE REAL DEFECT -- on the MC_LOCK/MC_LOCKAS FAILURE path, mem_unlock
#       receives 2 KiB-based bit indices (inlined btoc(seg->s_size)) while the
#       bits were SET with 4 KiB indices, and its own ctob() shifts halve both
#       the byte offset and the byte length handed to as_ctl(MC_UNLOCK).  So the
#       rollback unlocks the wrong address range: some pages stay locked
#       forever (pages_pp_locked / availrmem drift downward) while MC_UNLOCK is
#       issued against ranges that were never locked.
#
# DO NOT TOUCH -- these matched a naive "#2047/#2048/moveq #11" scan but are NOT
# page geometry.  Each was read in context and classified:
#   0x42f58  textlock      moveq #11,%d0  = return EAGAIN  (errno 11, then braw)
#   0x42fde  datalock      moveq #11,%d0  = return EAGAIN
#   0x43080  ublock        moveq #11,%d0  = return EAGAIN
#   0x43212  memcntl       moveq #12,%d0  = return ENOMEM  (errno 12, after
#                                           valid_usr_range() fails)
#   0xad54e  segvn_lockop  moveq #11,%d0  = return EAGAIN
#   ublock/ubunlock `subql #4` / `addql #4` on availrmem + pages_pp_locked =
#     USIZE in PAGES.  It matches segu_release @0xaa78e, which charges the same
#     4 pages; changing one without the other would break u-area accounting.
#     Out of scope for this group.
#   memcntl 0x4339a `addaw #31` + 0x433a0 `lsrl #5` = BT_BITOUL(), bits->longs.
#   segvn_lockop 0xad482 / 0xad536 `pea 0x800` = segvn_fault LENGTH arguments,
#     deliberately WITHDRAWN on 2026-07-03 after the seg-family fault-len batch
#     hung the boot (patch_modelb.py:576-582).  They are not part of the bitmap
#     contract -- segvn_lockop's loop step and bit indices are already 4 KiB --
#     and they stay withdrawn.
#
# NOTE on 0x434ee: ONE `moveq #11,%d7` feeds BOTH `lsll %d7,%d1` (byte offset,
# 0x434f0) and `lsll %d7,%d0` (byte length, 0x434fe) in mem_unlock's as_ctl
# call.  A single site fixes both conversions.
#
# NOTE on 0x4338e: `addaw #2047` -> `#4095`.  ADDA.W sign-extends its 16-bit
# operand; 4095 is positive in 16 bits (< 32767), so d8fc 0fff is correct.
#
# Each site asserts its expected OLD bytes before writing (fail-closed: any
# mismatch aborts the whole run rather than guessing an address).  Operates in
# place on build/unix-040, AFTER patch_modelb.py (which converted as_ctl and
# segvn_lockop).  All 17 old-byte expectations were verified against the build
# carrying ISSUE-15 + ISSUE-17/18 (68040-260725-03).

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
 # ---- memcntl @0x4319a: argument validation -------------------------------
 (0x431f4, b"\x02\x80\x00\x00\x07\xff", b"\x02\x80\x00\x00\x0f\xff",
  "memcntl:(int)addr & PAGEOFFSET (EINVAL alignment gate)"),

 # ---- memcntl MC_LOCKAS: rlen accumulation over the seg list ---------------
 (0x4331c, b"\x02\x46\xf8\x00", b"\x02\x46\xf0\x00",
  "memcntl:MC_LOCKAS raddr = seg->s_base & PAGEMASK"),
 (0x43328, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "memcntl:MC_LOCKAS (s_base+s_size)+PAGEOFFSET"),
 (0x4332e, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00",
  "memcntl:MC_LOCKAS ... & PAGEMASK"),

 # ---- memcntl MC_LOCK: normalize addr/len ---------------------------------
 (0x43348, b"\x02\x46\xf8\x00", b"\x02\x46\xf0\x00",
  "memcntl:MC_LOCK raddr = addr & PAGEMASK"),
 (0x43352, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "memcntl:MC_LOCK (addr+len)+PAGEOFFSET"),
 (0x43358, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00",
  "memcntl:MC_LOCK ... & PAGEMASK"),

 # ---- memcntl: mlock_size = BT_BITOUL(btoc(rlen)) -------------------------
 (0x4338e, b"\xd8\xfc\x07\xff", b"\xd8\xfc\x0f\xff",
  "memcntl:btoc(rlen) round (addaw #2047 -> #4095)"),
 (0x43394, b"\x72\x0b", b"\x72\x0c",
  "memcntl:btoc(rlen) shift >>11 -> >>12"),

 # ---- memcntl MC_LOCKAS failure path: per-seg mem_unlock rollback ----------
 (0x43420, b"\x02\x46\xf8\x00", b"\x02\x46\xf0\x00",
  "memcntl:err path raddr = seg->s_base & PAGEMASK"),
 (0x43428, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "memcntl:err path btoc(s_size) round (npages, inlined seg_pages)"),
 (0x4342e, b"\x72\x0b", b"\x72\x0c",
  "memcntl:err path btoc(s_size) shift (npages)"),
 (0x43450, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "memcntl:err path btoc(s_size) round (inx, inlined seg_pages)"),
 (0x43456, b"\x72\x0b", b"\x72\x0c",
  "memcntl:err path btoc(s_size) shift (inx)"),

 # ---- memcntl MC_LOCK failure path: mem_unlock(..., btoc(rlen)) -----------
 (0x43472, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff",
  "memcntl:MC_LOCK err btoc(rlen) round"),
 (0x43478, b"\x72\x0b", b"\x72\x0c",
  "memcntl:MC_LOCK err btoc(rlen) shift"),

 # ---- mem_unlock @0x434b6: ctob() for the as_ctl(MC_UNLOCK) call ----------
 (0x434ee, b"\x7e\x0b", b"\x7e\x0c",
  "mem_unlock:ctob() shift -- ONE moveq feeds BOTH lsll (offset + length)"),
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
        raise SystemExit("ABORT: partial memcntl patch (%d/%d) -- the bitmap "
                         "sizing/walking group is atomic" % (done, len(TEXT)))

    # Canary: the five classified NON-sites must be untouched.  If a future edit
    # ever "converts" one of these errno constants the kernel starts returning
    # ENOMEM/EAGAIN(12) instead of EAGAIN(11) from lock paths, which is silent.
    for vaddr, want, what in ((0x42f58, b"\x70\x0b", "textlock return EAGAIN"),
                              (0x42fde, b"\x70\x0b", "datalock return EAGAIN"),
                              (0x43080, b"\x70\x0b", "ublock return EAGAIN"),
                              (0x43212, b"\x70\x0c", "memcntl return ENOMEM"),
                              (0xad54e, b"\x70\x0b", "segvn_lockop return EAGAIN")):
        fo = toff + (vaddr - taddr)
        if bytes(buf[fo:fo+2]) != want:
            raise SystemExit("ABORT canary @0x%05x (%s): found %s expected %s"
                             % (vaddr, what, bytes(buf[fo:fo+2]).hex(), want.hex()))

    open(KERNEL,"wb").write(buf)
    print("patch_memcntl: %d patched, %d already, 0 failed (5 canaries intact) -> %s"
          % (done, skip, KERNEL))
    if done + skip != len(TEXT):
        sys.exit(1)

main()
