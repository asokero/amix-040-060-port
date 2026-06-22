#!/usr/bin/env python3
# patch_modelb_pager.py -- Model B (4KB page frame) Tier-2: the PAGER / fs page-I/O
# subsystem.  patch_modelb.py (Tier-0/1) only covered the 26 CORE VM/HAT sites needed
# to boot to swapconf; the pager/fs page-cache path was left at 2KB.  That mismatch is
# why the first fbread() of a directory returns an all-zero page (ufs_getapage page_gets
# / pagezeros / indexes a 4KB frame as 2KB; disk data and the segmap mapping disagree).
#
# This is the directory-read chain (validated first): fbread -> segmap_getmap/fault ->
# ufs_getpage -> [pvn_getpages] -> ufs_getapage -> pageio_setup -> bdevsw -> biowait.
#   * fbread/fbrelse, segmap_getmap/fault, pageio_setup/done: NO PAGESIZE constants --
#     segmap slots are MAXBSIZE=8KB (segmap_fault uses moveq #13 = >>13, NOT PAGESHIFT),
#     pageio is size-agnostic.  Left untouched.
#   * Each #2047->#4095 (07ff->0fff), #2048->#4096 (0800->1000), #-2048->#-4096
#     (f800->f000 / fff8.. ), and PAGESHIFT moveq #11->#12 (only where FOLLOWED by a
#     shift; the moveq #11 sites followed by cmpl are the NDADDR "12 direct blocks"
#     test in ufs_getapage and are LEFT ALONE).  segmap_release bset #21/#17 are B_
#     flag bits, not page size -- left.
#
# Each site byte-verified.  Operates in place on build/unix-040, AFTER patch_modelb.py.

import struct, sys, os
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"
# Bisection: MODELB_PAGER_GROUPS=ufs,pvn,segmap (default all).  Each patch entry's name
# starts with its function; we map fn->group and skip groups not selected.
# DEFAULT excludes pvnk: pvn_kluster's patch HANGS pre-banner (it runs in the putpage/
# sync path during mount).  ufs+pvngp+segmap boots cleanly but the dir read still returns
# zeros -> the fix needs either a CORRECT pvn_kluster patch (find the bad site) or it is a
# deeper hat_memload file-page mapping issue.  Bisection: set MODELB_PAGER_GROUPS to a
# comma list of {ufs,pvngp,pvnk,segmap}.
GROUPS = set((os.environ.get("MODELB_PAGER_GROUPS") or "ufs,pvngp,segmap").split(","))
def group_of(name):
    if name.startswith("ufs_get"):      return "ufs"
    if name.startswith("pvn_getpages"): return "pvngp"
    if name.startswith("pvn_kluster"):  return "pvnk"
    if name.startswith("segmap"):       return "segmap"
    return "ufs"

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
 # ===== ufs_getapage: page-round byte masks (the #11 followed by cmpl = NDADDR, LEFT) =====
 (0x81dde, b"\x0c\xae"+A47, b"\x0c\xae"+A95, "ufs_getapage:cmpil #2047 fp@(-44)"),
 (0x81eb4, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (a)"),
 (0x81ebe, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (b)"),
 (0x81ec4, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "ufs_getapage:andiw #-2048 d0 (a)"),
 (0x81eda, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (c)"),
 (0x81ee4, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (d)"),
 (0x81eea, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "ufs_getapage:andiw #-2048 d0 (b)"),
 (0x82038, b"\x06\x80\xff\xff\xf8\x00", b"\x06\x80\xff\xff\xf0\x00", "ufs_getapage:addil #-2048 d0"),
 (0x820b2, b"\x02\x80"+A47, b"\x02\x80"+A95, "ufs_getapage:andil #2047 d0"),
 (0x820c0, b"\x22\x3c"+A48, b"\x22\x3c"+A96, "ufs_getapage:movel #2048 d1"),
 (0x82114, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (e)"),
 (0x8211a, b"\x72\x0b", b"\x72\x0c", "ufs_getapage:PAGESHIFT >>11 (a, lsrl)"),
 (0x82194, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (f)"),
 (0x8219e, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (g)"),
 (0x821a4, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "ufs_getapage:andiw #-2048 d0 (c)"),
 (0x821ba, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (h)"),
 (0x821c4, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (i)"),
 (0x821ca, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "ufs_getapage:andiw #-2048 d0 (d)"),
 (0x82342, b"\x02\x80"+A47, b"\x02\x80"+A95, "ufs_getapage:andil #2047 d0 (b)"),
 (0x82350, b"\x22\x3c"+A48, b"\x22\x3c"+A96, "ufs_getapage:movel #2048 d1 (b)"),
 (0x82396, b"\x06\x80"+A47, b"\x06\x80"+A95, "ufs_getapage:addil #2047 d0 (j)"),
 (0x8239c, b"\x72\x0b", b"\x72\x0c", "ufs_getapage:PAGESHIFT >>11 (b, lsrl)"),
 (0x824b4, b"\x06\x87"+A48, b"\x06\x87"+A96, "ufs_getapage:addil #2048 d7"),
 # ===== ufs_getpage =====
 (0x82600, b"\x06\x81"+A47, b"\x06\x81"+A95, "ufs_getpage:addil #2047 d1"),
 (0x8268c, b"\x0c\x84"+A48, b"\x0c\x84"+A96, "ufs_getpage:cmpil #2048 d4"),
 # ===== pvn_getpages =====
 (0xb25f8, b"\x2a\x3c"+A48, b"\x2a\x3c"+A96, "pvn_getpages:movel #2048 d5"),
 (0xb260e, b"\x06\x80"+A48, b"\x06\x80"+A96, "pvn_getpages:addil #2048 d0"),
 (0xb26c6, b"\x06\x82"+A48, b"\x06\x82"+A96, "pvn_getpages:addil #2048 d2"),
 (0xb26cc, b"\x06\x83"+A48, b"\x06\x83"+A96, "pvn_getpages:addil #2048 d3"),
 # ===== pvn_kluster =====
 (0xb1822, b"\x72\x0b", b"\x72\x0c", "pvn_kluster:PAGESHIFT <<11 (asll)"),
 (0xb183a, b"\x20\x3c"+A48, b"\x20\x3c"+A96, "pvn_kluster:movel #2048 d0 (a)"),
 (0xb186c, b"\x0c\x84"+A48, b"\x0c\x84"+A96, "pvn_kluster:cmpil #2048 d4"),
 (0xb1886, b"\x0c\x84"+A47, b"\x0c\x84"+A95, "pvn_kluster:cmpil #2047 d4"),
 (0xb1896, b"\x20\x3c"+A48, b"\x20\x3c"+A96, "pvn_kluster:movel #2048 d0 (b)"),
 (0xb18a2, b"\x24\x3c"+A48, b"\x24\x3c"+A96, "pvn_kluster:movel #2048 d2"),
 (0xb18dc, b"\x06\x82"+A48, b"\x06\x82"+A96, "pvn_kluster:addil #2048 d2"),
 # backward-scan page step: pea -2048(a0) -- a DISPLACEMENT, must match the d3=-4096 below
 (0xb18f8, b"\x48\x68\xf8\x00", b"\x48\x68\xf0\x00", "pvn_kluster:pea -2048(a0) backward step"),
 (0xb1912, b"\x06\x83\xff\xff\xf8\x00", b"\x06\x83\xff\xff\xf0\x00", "pvn_kluster:addil #-2048 d3"),
 (0xb195c, b"\x06\x82"+A47, b"\x06\x82"+A95, "pvn_kluster:addil #2047 d2 (a)"),
 (0xb1966, b"\x06\x82"+A47, b"\x06\x82"+A95, "pvn_kluster:addil #2047 d2 (b)"),
 (0xb1970, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "pvn_kluster:andiw #-2048 d2"),
 (0xb19b2, b"\xd6\xfc\x08\x00", b"\xd6\xfc\x10\x00", "pvn_kluster:addaw #2048 a3"),
 # ===== segmap_pagecreate =====
 (0xa9742, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "segmap_pagecreate:andiw #-2048 d2"),
 (0xa9892, b"\x06\x82"+A48, b"\x06\x82"+A96, "segmap_pagecreate:addil #2048 d2"),
 (0xa9898, b"\x06\x84"+A48, b"\x06\x84"+A96, "segmap_pagecreate:addil #2048 d4"),
 # ===== segmap_unlock =====
 # NOTE: 0xa901e (va>>11) is the page_hash INDEX term, identical to page_find/page_enter/
 # page_lookup's PAGE_HASH macro -- a uniform hash, NOT a byte<->page conversion.  Those
 # callers are unpatched (>>11), so this MUST stay >>11 or segmap_unlock indexes the wrong
 # bucket -> page never found -> infinite loop/HANG.  Do NOT patch it.  (The #2048 below
 # are real page-size byte rounds and DO change.)
 (0xa90f4, b"\x06\x82"+A48, b"\x06\x82"+A96, "segmap_unlock:addil #2048 d2"),
 (0xa90fa, b"\x06\x83"+A48, b"\x06\x83"+A96, "segmap_unlock:addil #2048 d3"),
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
            print("  [skip] %-46s @0x%05x already" % (name,vaddr)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-46s @0x%05x %s->%s" % (name,vaddr,old.hex(),new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s @0x%05x: found %s expected %s" % (name,vaddr,cur.hex(),old.hex()))
    open(KERNEL,"wb").write(buf)
    print("Model B Tier-2 (pager dir-read chain) groups=%s: %d patched, %d already, %d skipped -> %s"
          % (",".join(sorted(GROUPS)),done,skip,off,KERNEL))

main()
