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
# THE COUPLED 4KB PAGE-CACHE CONVERSION (2026-06-24, enabled): groups 'pgget' + 'pvnk'.
# The exec-header read exposed why the page cache produced 2KB pages: pvn_kluster builds a
# read-ahead page at file offset 0x800, which segmap maps at a 2KB VA stride (40448000+0x800)
# into the SAME 4KB MMU leaf as the offset-0 page -> the 2nd clobbers the 1st -> gexec reads
# the wrong page (ELF magic 0) -> ENOEXEC -> init never execs.
#
# WHY pvnk alone broke the early mount dir-read (commit 334b3ae/96834ee), and why it is now
# SAFE *together with* pgget: pvn_kluster's final loop (0xb1976-0xb19bc) does page_get(size),
# then walks the returned circular page LIST calling page_enter, advancing the file offset by
# one page (a3) each iteration.  The loop count == the number of frames page_get returns; the
# offset stride must match the frame size.  page_get's OWN size->count math
# (`(size+2047)>>11`, 0xaffb8/0xaffbe) was still 2KB, UNPATCHED -- so with a 4KB-rounded size
# and 4KB offset stride, page_get returned 2x the frames the loop/offset expected -> the loop
# walked past the cluster -> corruption.  Patching page_get-internal to 4KB (group 'pgget':
# (size+4095)>>12) makes page_get(4KB-rounded size) return exactly size/4096 frames, matching
# pvn_kluster's 4KB offset stride.  The two are a COUPLED set and are enabled together.
#
# pgget is also CONSISTENT with the already-Model-B variable-size callers: segkmem_alloc
# (0xa86fc) walks the whole list writing one PTE/frame at a 4KB vaddr stride (index >>12 @
# 0xa8716, vaddr step #4096 @0xa8764 -- both pre-patched by patch_modelb.py), and hat_sdtalloc
# (0xb6488) requests size = npages<<12 (0xb6484 pre-patched).  Both currently OVER-allocate 2x
# (page_get >>11) harmlessly; pgget removes that waste and maps exactly `size` bytes.  The
# constant 0x800 callers still get 1 frame ((0x800+4095)>>12 == 1), and segu's 0x2000 request
# now yields exactly 2 frames (its map loop was already patched to expect 2).  page_find/
# page_enter use offset>>11 only as a uniform hash bucket (unchanged, stays consistent).
GROUPS = set((os.environ.get("MODELB_PAGER_GROUPS")
              or "ufs,pvngp,pvnk,pgget,segmap,buf,genst,bufbk,dmapio,segu").split(","))
def group_of(name):
    if name.startswith("page_get"):     return "pgget"
    if name.startswith("ufs_get"):      return "ufs"
    if name.startswith("pvn_getpages"): return "pvngp"
    if name.startswith("pvn_kluster"):  return "pvnk"
    if name.startswith("pvn_done"):     return "pvnk"
    if name.startswith("segmap"):       return "segmap"
    if name.startswith("bp_map"):       return "buf"
    if name.startswith("gen_strategy"): return "genst"
    if name.startswith("buf_breakup"):  return "bufbk"
    if name.startswith("dma_pageio"):   return "dmapio"
    if name.startswith("segu_"):        return "segu"
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
 # ===== page_get internal size->frame-count (group pgget): THE coupling keystone =====
 # page_get(size,flags): frames = (size+2047)>>11 (2KB).  Convert to (size+4095)>>12 (4KB) so
 # a 4KB-rounded size yields exactly size/4096 frames, matching pvn_kluster's 4KB offset stride
 # and the pre-patched segkmem_alloc/hat_sdtalloc/segu callers.  Shift count is the moveq #11
 # into d1 at 0xaffbe (the lsrl at 0xaffc0 reads d1), NOT a baked shift -- patch the moveq.
 (0xaffb8, b"\x06\x82"+A47, b"\x06\x82"+A95, "page_get:size round +2047->+4095"),
 (0xaffbe, b"\x72\x0b", b"\x72\x0c", "page_get:size>>11 shift count (moveq #11->#12 d1)"),
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
 # ===== pvn_done: the read-completion page-list walker.  Loops `while d4 < b_bcount`,
 # pulling ONE page off b_pages (page_sub) per iteration and stepping d4 by PAGESIZE.  With
 # 4KB pages the step must be 4KB or the loop runs ceil(bcount/2048) times over only
 # ceil(bcount/4096) pages -> page_sub walks off the end -> "pp >= pages && pp < epages"
 # panic (vm_page.c:1192).  Sole page-size constant in pvn_done; rest is p_next/flag walking. =====
 (0xb1d60, b"\x06\x84"+A48, b"\x06\x84"+A96, "pvn_done:page-walk step d4 #2048"),
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
 # ===== bp_mapin / bp_mapout: map a paged (B_PAGEIO) buf into kernel VA for the I/O.
 # The disk read IS issued (ufs_getapage reaches bdevsw strategy) but the page stays
 # zero -> the buf->VA mapping here is 2KB while the page is 4KB.  All moveq #11 are
 # PAGESHIFT (followed by lsrl/asll = btop/ptob), not NDADDR. =====
 (0x59388, b"\x02\x82"+A47, b"\x02\x82"+A95, "bp_mapin:andil #2047 d2"),
 (0x5939a, b"\x06\x80"+A47, b"\x06\x80"+A95, "bp_mapin:addil #2047 d0"),
 (0x593a2, b"\x74\x0b", b"\x74\x0c", "bp_mapin:PAGESHIFT >>11 d2 (lsrl)"),
 (0x59402, b"\x74\x0b", b"\x74\x0c", "bp_mapin:PAGESHIFT <<11 d2 (asll)"),
 (0x59478, b"\x02\x80"+A47, b"\x02\x80"+A95, "bp_mapout:andil #2047 d0"),
 (0x59484, b"\x06\x82"+A47, b"\x06\x82"+A95, "bp_mapout:addil #2047 d2"),
 (0x5948a, b"\x72\x0b", b"\x72\x0c", "bp_mapout:PAGESHIFT >>11 d1 (lsrl)"),
 (0x59494, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "bp_mapout:andiw #-2048 d0"),
 (0x594c8, b"\x72\x0b", b"\x72\x0c", "bp_mapout:PAGESHIFT >>11 d1 (lsrl b)"),
 (0x594e8, b"\x06\xae"+A48, b"\x06\xae"+A96, "bp_mapout:addil #2048 fp@(-4)"),
 (0x594fe, b"\x72\x0b", b"\x72\x0c", "bp_mapout:PAGESHIFT >>11 d1 (lsrl c)"),
 (0x59518, b"\x02\xaa"+A47, b"\x02\xaa"+A95, "bp_mapout:andil #2047 a2@(36)"),
 # ===== gen_strategy (group genst): THE disk-read DEPOSIT bug.  For a B_PAGEIO buf it
 # converts the page (b_pages @60) to a PHYSICAL DMA target = PFN<<11 and stores it in
 # b_addr (a2@(36)); the device strategy then DMAs to that phys.  Under Model B the page
 # is at PFN<<12, so PFN<<11 writes the data to HALF the address -> the 4KB page stays
 # zero (exactly the blkatoff "PAGE phys=9D8B000 ram=[0 0 0 0]").  Two <<11 phys sites
 # (single-page @3d9c0, breakup-setup @3dae6) + the page-count/round/threshold consts. =====
 (0x3d994, b"\x0c\xaa"+A48, b"\x0c\xaa"+A96, "gen_strategy:cmpil #2048 a2@(32) single-page thresh"),
 (0x3d9c0, b"\x7a\x0b", b"\x7a\x0c", "gen_strategy:PFN<<11 phys (single-page) [THE BUG]"),
 (0x3d9ec, b"\x7a\x0b", b"\x7a\x0c", "gen_strategy:bcount>>11 npages"),
 (0x3d9f4, b"\x02\x80"+A47, b"\x02\x80"+A95, "gen_strategy:andil #2047 bcount remainder"),
 (0x3da30, b"\x02\x80"+A47, b"\x02\x80"+A95, "gen_strategy:andil #2047 last-chunk"),
 (0x3da40, b"\x22\x3c"+A48, b"\x22\x3c"+A96, "gen_strategy:movel #2048 chunk = full page"),
 (0x3dae6, b"\x7a\x0b", b"\x7a\x0c", "gen_strategy:PFN<<11 phys (breakup) [THE BUG]"),
 # ===== buf_breakup (group bufbk): splits a >1-page transfer into per-page sub-bufs,
 # chunking at the 2KB page boundary; calls gen_strategy per sub-buf (which then hits the
 # single-page phys path above).  All page-boundary chunk math. =====
 (0x3d1b8, b"\x02\x80"+A47, b"\x02\x80"+A95, "buf_breakup:andil #2047 addr page-offset"),
 (0x3d1be, b"\x22\x3c"+A48, b"\x22\x3c"+A96, "buf_breakup:movel #2048 (bytes to page bound)"),
 (0x3d1da, b"\x0c\x82"+A47, b"\x0c\x82"+A95, "buf_breakup:cmpil #2047 chunk full-page?"),
 # ===== dma_pageio (group dmapio): DMA alignment/bounce wrapper; its ALIGNED path splits
 # the transfer at 2KB page boundaries before calling the real strategy.  The sector (512)
 # / >>9 logic at 20c48/20dee/20ef6 is NOT page-size and is left.  Only the 2KB page-chunk
 # math is flipped.  (Lower confidence than genst -- if a regression appears, drop dmapio.) =====
 (0x20e1c, b"\x02\x80"+A47, b"\x02\x80"+A95, "dma_pageio:andil #2047 addr page-offset (a)"),
 (0x20e22, b"\x04\x80"+A48, b"\x04\x80"+A96, "dma_pageio:subil #2048 (bytes to page bound a)"),
 (0x20e3c, b"\x02\x80"+A47, b"\x02\x80"+A95, "dma_pageio:andil #2047 addr page-offset (b)"),
 (0x20e42, b"\x04\x80"+A48, b"\x04\x80"+A96, "dma_pageio:subil #2048 (bytes to page bound b)"),
 (0x20e4e, b"\x0c\x80"+A47, b"\x0c\x80"+A95, "dma_pageio:cmpil #2047 chunk full-page? (a)"),
 (0x20e92, b"\x0c\x82"+A47, b"\x0c\x82"+A95, "dma_pageio:cmpil #2047 remaining vs page"),
 (0x20ea2, b"\x20\x3c"+A48, b"\x20\x3c"+A96, "dma_pageio:movel #2048 chunk = full page"),
 # ===== segu (group segu): the per-proc U-AREA mapping.  segu_get allocates an 8KB
 # u-area (anon_resv/page_get 0x2000) and maps it as a hardcoded 4 x 2KB pages; under
 # Model B page_get(8192) returns 2 x 4KB pages, so the loop maps consecutive 4KB pfns
 # (X, X+1) at 2KB-spaced VAs -> both index the SAME 4KB leaf -> hat_pteload "pfn
 # mismatch va=4844x800 *pte=...X newpfn=...X+1".  Fix the MAP loops to step 4KB / 2
 # iterations (the per-page page_get/anon_alloc/page_enter/hat_memload/swap_xlate calls
 # are page-size-agnostic -- only the loop step + count + array index change).  segu_get's
 # SECOND loop (st_top1, the INERT 030 u-area page table) is LEFT -- dead on 040 until
 # uvirtophys/uvatosde is ported.  segu_softunload (the unmap) is added once the map side
 # is confirmed. =====
 (0xaa69c, b"\x06\x83"+A48, b"\x06\x83"+A96, "segu_get:va step #2048 (map loop)"),
 (0xaa6a2, b"\x7a\x03", b"\x7a\x01", "segu_get:loop bound moveq #3->#1 (4->2 pages)"),
 (0xaaa12, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "segu_softload:va align &-2048"),
 (0xaaa1c, b"\x06\x80"+A47, b"\x06\x80"+A95, "segu_softload:len round +2047"),
 (0xaaa22, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "segu_softload:len round &-2048"),
 (0xaaa3e, b"\x06\x84"+A47, b"\x06\x84"+A95, "segu_softload:index round +2047"),
 (0xaaa44, b"\x72\x0b", b"\x72\x0c", "segu_softload:array index >>11 (page idx)"),
 (0xaab80, b"\x06\x82"+A48, b"\x06\x82"+A96, "segu_softload:va step #2048 (map loop)"),
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
