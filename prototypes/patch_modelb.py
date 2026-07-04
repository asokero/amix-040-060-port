#!/usr/bin/env python3
# patch_modelb.py -- Model B (4KB page frame) Tier-0 byte patches.
#
# The AMIX kernel's "click"/page is 2KB (baked immediates: byte<->click via <<11/
# >>11, page rounding #2047/#2048, leaf PTE pfn in bits 31:11 = bitfield {0:21}).
# The 68040 MMU's minimum page is 4KB, and page_get hands out physically SCATTERED
# 2KB clicks that cannot be paired into 4KB MMU pages (Model A's wall).  Model B
# makes the page frame 4KB everywhere; then each click IS a 4KB page and the
# scattered allocator maps 1:1.  Almost every site is a SAME-SIZE immediate flip,
# so we byte-patch in place (no relink): >>11->>>12, <<11-><<12 (moveq #11->#12),
# #2047->#4095, #2048->#4096, #-2047/#-2048 -> #-4095/#-4096, bitfield {0:21}->
# {0:20} (field word 0x0015->0x0014).  The ONE structural change on this path
# (sysseginit: 8-byte 030 pointer descriptor -> 4-byte 040) is an override in
# kvm040.s, not here.
#
# Tier 0 = just enough to get past kmem_allocspool (segkmem_alloc maps a kmem pool
# of scattered clicks).  Functions: mlsetup (defines the click size: maxclick +
# sptmap), kvm_init (page_hash region size), segkmem_alloc + segkmem_mapin (leaf
# PTE builders), sptalloc (click->byte args).  memialloc/page_get/kmem_allocspool
# are struct-index based (size-agnostic) -> no patch.
#
# Each site is byte-verified before patching.  Operates on build/unix-040 in place;
# run AFTER patch_pflusha_040.py / patch_pmmu_040.py.  Re-run after each relink.

import struct, sys
KERNEL = sys.argv[1] if len(sys.argv) > 1 else "build/unix-040"

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

# (vaddr, expect_bytes, new_bytes, name)
P = [
 # --- hat_ptalloc: zero the FULL 4KB leaf-table page, not just 256 B (2026-06-27 EXPERIMENT).
 #     hat_ptalloc is forced to page_get (page-aligned full pages); it bzero's only the 64-PTE
 #     region (256 B), leaving [256,4096) STALE.  Under the 040 page-recycling double-allocation
 #     (a still-mapped child data page is re-handed as a leaf table), that stale tail = 0xFFFFFFFF
 #     corrupts the child's bss (malloc global @0x80010e48 reads 0xFFFFFFFF -> bus error).  Zeroing
 #     the whole page makes the recycled data read 0 (correct for bss) -> benign.  NOTE: a band-aid
 #     for the deeper free-while-mapped / p_mapping bug, not a root fix. ---
 (0xb6904, b"\x48\x78\x01\x00", b"\x48\x78\x10\x00", "hat_ptalloc:bzero leaf table 256->4096 (full-page, recycled-page band-aid)"),
 # --- mlsetup: define click = 4KB (maxclick) + sptmap range in 4KB clicks ---
 (0x48af4, b"\x76\x0b", b"\x76\x0c", "mlset:VSIZOFMEM>>11 (memsize clicks)"),
 (0x48b1a, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "mlset:maxclick round +2047"),
 (0x48b20, b"\x76\x0b", b"\x76\x0c", "mlset:maxclick >>11/<<11"),
 (0x48b5e, b"\x76\x0b", b"\x76\x0c", "mlset:sptmap base syssegs>>11"),
 (0x48b64, b"\x48\x78\x08\x00", b"\x48\x78\x04\x00", "mlset:sptmap size 2048->1024 clicks"),
 # --- kvm_init: page_hash region size (clicks) ---
 (0x48e64, b"\x06\x83\x00\x00\x07\xff", b"\x06\x83\x00\x00\x0f\xff", "kvm:page_hash round +2047"),
 (0x48e6a, b"\x7c\x0b", b"\x7c\x0c", "kvm:page_hash region >>11"),
 # --- segkmem_alloc: leaf PTE builder (the Tier-0 blocker) ---
 (0xa8716, b"\x76\x0b", b"\x76\x0c", "ska:leaf index >>11"),
 (0xa8742, b"\xef\xee\x00\x15\xff\xf8", b"\xef\xee\x00\x14\xff\xf8", "ska:PTE pfn bfins {0:21}->{0:20}"),
 (0xa8764, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "ska:addr step #2048->#4096"),
 # --- segkmem_mapin: leaf PTE builder ---
 (0xa892e, b"\x7c\x0b", b"\x7c\x0c", "skm:leaf index >>11"),
 (0xa898a, b"\xe9\xee\x60\x15\xff\xf8", b"\xe9\xee\x60\x14\xff\xf8", "skm:pfn bfextu {0:21}->{0:20}"),
 (0xa89b0, b"\xe9\xd3\x60\x15", b"\xe9\xd3\x60\x14", "skm:old-pfn bfextu {0:21}->{0:20}"),
 (0xa89bc, b"\x02\x40\xf8\x01", b"\x02\x40\xf0\x01", "skm:page mask -2047->-4095"),
 (0xa89c4, b"\x02\x41\xf8\x01", b"\x02\x41\xf0\x01", "skm:page mask -2047->-4095"),
 (0xa8a3c, b"\xe9\xee\x00\x15\xff\xf8", b"\xe9\xee\x00\x14\xff\xf8", "skm:adv bfextu {0:21}->{0:20}"),
 (0xa8a44, b"\xef\xee\x00\x15\xff\xf8", b"\xef\xee\x00\x14\xff\xf8", "skm:adv bfins {0:21}->{0:20}"),
 (0xa8a4e, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "skm:addr step #2048->#4096"),
 (0xa8a54, b"\x06\x83\xff\xff\xf8\x00", b"\x06\x83\xff\xff\xf0\x00", "skm:len step #-2048->#-4096"),
 # --- sptalloc: click->byte args for segkmem (<<11 -> <<12) ---
 (0xa8bfa, b"\x72\x0b", b"\x72\x0c", "spt:click<<11 (alloc branch)"),
 (0xa8c3e, b"\x72\x0b", b"\x72\x0c", "spt:click<<11 (mapin branch)"),
 # ===== Tier-1: kvsegmap/segmap setup (seg_alloc -> as_addseg) =====
 # seg_alloc: round base down / size up to a PAGE (2KB -> 4KB)
 (0xb2832, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "seg_alloc:base &-2048->-4096"),
 (0xb283e, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "seg_alloc:size round +2047"),
 (0xb2844, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "seg_alloc:size &-2048->-4096"),
 # kvm_init segmap byte size: segment 128KB->256KB (smsegs halved under B, so <<18
 # restores the 030-equivalent byte size); kvsegmap (48ee6) + kvsegu (48f58)
 (0x48ee6, b"\x7c\x11", b"\x7c\x12", "kvm:kvsegmap size <<17->18"),
 (0x48f58, b"\x7c\x11", b"\x7c\x12", "kvm:kvsegu size <<17->18"),
 # svirtophys: final phys assembly is page-granular (2KB->4KB).  The DT/UDT switch
 # and vatosde/vatopte are handled by the 040 ports (kvm040.s); only the leaf-PTE
 # masking here is a size flip: phys = (PTE & ~page) | (va & page-1).
 (0xb77c0, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "svp:PTE page mask &-2048->-4096"),
 (0xb77c8, b"\x02\x81\x00\x00\x07\xff", b"\x02\x81\x00\x00\x0f\xff", "svp:va off &2047->4095"),
 # ===== HAT page-table allocators: click->byte uses a 2KB shift -> 4KB =====
 # hat_pteload itself is REPLACED by hat040.s (040 walk).  Its allocator callees
 # are byte-patched in place (success path only; the steal/reuse paths that need
 # structural 8->4-byte descriptor edits are not hit while memory is plentiful).
 # Each `moveq #11,Dn` (click<<11 / addr>>11, 2KB) becomes `#12` (4KB click).
 (0xb6a74, b"\x76\x0b", b"\x76\x0c", "hat_ptalloc:pfn<<11 (phys page base)"),
 (0xb63d6, b"\x7a\x0b", b"\x7a\x0c", "hat_sdtalloc:pfn<<11 (free-list node)"),
 (0xb6484, b"\x7a\x0b", b"\x7a\x0c", "hat_sdtalloc:page_get size d3<<11"),
 (0xb6524, b"\x7a\x0b", b"\x7a\x0c", "hat_sdtalloc:pfn<<11 (new node base)"),
 (0xb5e1c, b"\x78\x0b", b"\x78\x0c", "hat_pt2ptdat:pt>>11 (page-frame index)"),
 # hat_ptfree: pages[] index is the 4KB pfn (>>12, matching hat_pt2ptdat) -- the 030
 # >>11 gave pages[2*pfn] -> garbage page struct -> garbage a2@(32) -> bad free-list
 # pointer -> bus error in the unlink (0xb6ecc).  ONLY the two pfn shifts change; the
 # fragment layout (b6d48 #11 / b6d56 #9 = 4 frags @ 512B in a 2KB region) is UNCHANGED
 # and matches hat_ptalloc (which Model B left at #11/#9, page table = 256B via bzero).
 (0xb6d00, b"\x72\x0b", b"\x72\x0c", "hat_ptfree:pfn>>11 (pages bounds chk)"),
 (0xb6d2c, b"\x72\x0b", b"\x72\x0c", "hat_ptfree:pfn>>11 (pages[] index)"),
 # anon_resv / anon_unresv: byte-size -> swap-click conversion (round up, then shift).
 # availsmem/anoninfo are maintained in Model B 4KB clicks, but these two converted the
 # request with the 2KB round/shift (+2047 >>11) -> reserved/released 2x the clicks ->
 # anon_resv saw the request as twice as large and returned ENOMEM (errno 12) the first
 # time exec mapped init's writable (zfod) data/bss segment, AFTER the HAT page-table layer
 # finally let exec reach the anon reservation.  Convert both to 4KB (+4095 >>12).
 (0xad6a8, b"\x06\x81\x00\x00\x07\xff", b"\x06\x81\x00\x00\x0f\xff", "anon_resv:size round +2047->+4095"),
 (0xad6ae, b"\x74\x0b", b"\x74\x0c", "anon_resv:size>>11 shift count (#11->#12)"),
 (0xad736, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "anon_unresv:size round +2047->+4095"),
 (0xad73c, b"\x72\x0b", b"\x72\x0c", "anon_unresv:size>>11 shift count (#11->#12)"),
 # execmap bss handling (0x57c0e..0x57c80): the zero-fill (bss) part of a data segment is
 # mapped by as_map starting at the first WHOLE page after the file content.  The 030 code
 # rounded that bss start UP to a 2KB boundary (d2 = (vaddr+filesz+2047)>>11<<11).  On Model B
 # the file-backed part is mapped in 4KB pages, so as_map_reliably already owns the 4KB page
 # holding the file tail (e.g. [0x80009000,0x8000A000)); a 2KB-rounded bss start (0x80009800)
 # lands INSIDE that page -> as_map overlaps an existing mapping -> ENOMEM (errno 12) ->
 # 'elf exec: error 12: pid 1 killed' the first time init's data/bss segment is mapped.  Round
 # to 4KB instead (the single moveq #11->#12 drives BOTH the >>11 and the <<11), so the bss
 # as_map starts exactly where the file pages end, and uvbzero clears the full last-page tail.
 (0x57c1c, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "execmap:bss-start round +2047->+4095"),
 (0x57c22, b"\x74\x0b", b"\x74\x0c", "execmap:bss-start >>11/<<11 (#11->#12, 2KB->4KB page)"),
 # elfexec aux-vector AT_PAGESZ (type 6) value @0xb842c: the kernel reports the page size
 # to userland (getpagesize(2) / the dynamic linker reads it from the aux vector to align
 # its mmaps and round segment/bss boundaries).  The stock value is 2048; on Model B the MMU
 # page is 4096, so libc.so.1's runtime linker (do_reloc) rounded a segment/link-map boundary
 # with 2KB granularity and dereferenced a wrongly-relocated pointer (0x66000030) -> USER BUS
 # ERROR PC=C101100E in /sbin/init's interpreter, the first time init runs.  Report 4096.
 (0xb842c, b"\x24\xfc\x00\x00\x08\x00", b"\x24\xfc\x00\x00\x10\x00", "elfexec:AT_PAGESZ 2048->4096"),
 # brk(2) / grow (os/grow.c, binary 0x580e8/0x5820e): the sbrk/brk syscall handler rounds the
 # new and old break addresses to 2KB (+2047 >>11 <<11).  execmap (patched above) creates the
 # data/bss segment 4KB-rounded (e.g. sh's ends at 0x80012000), so ova = roundup2K(brkbase+
 # brksize) = 0x80011800 lands INSIDE the existing segment -> as_map(ova, change) overlaps ->
 # error -> brk returns ENOMEM -> libc sbrk returns -1 -> sh's malloc stores -1 in its arena
 # head (0x80010e48) and dereferences it -> the deterministic child crash "User BUS ERROR at
 # FFFFFFFF PC:800024FE" (PC = insn after `movel %a0,%a1@`, a1 = -1).  PROVEN 2026-07-02 by the
 # fs-uae AMIXE48 watch: `addr=80010e48 val=ffffffff s=0 PC=80002494` = sh ITSELF stores sbrk's
 # -1 -- NOT kernel page corruption (that whole framing is retired).  init survives only because
 # its break happens to round identically at 2KB and 4KB.  One moveq drives all four shifts in
 # brk (nva >>11 <<11, ova >>11 <<11); same pattern in grow (stack growth) for the stack rlimit
 # compare and the as_map addr/size click<->byte conversions.
 (0x58130, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "brk:nva round +2047->+4095"),
 (0x58136, b"\x72\x0b", b"\x72\x0c", "brk:nva/ova >>11<<11 shift count (#11->#12, all 4 shifts)"),
 (0x58144, b"\x06\x83\x00\x00\x07\xff", b"\x06\x83\x00\x00\x0f\xff", "brk:ova round +2047->+4095"),
 (0x58222, b"\x06\x83\x00\x00\x07\xff", b"\x06\x83\x00\x00\x0f\xff", "grow:stksize round +2047->+4095"),
 (0x58228, b"\x72\x0b", b"\x72\x0c", "grow:stksize/growth >>11 shift count (#11->#12, both)"),
 (0x58234, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "grow:growth round +2047->+4095"),
 (0x58270, b"\x72\x0b", b"\x72\x0c", "grow:total clicks<<11 (stack rlimit compare, #11->#12)"),
 (0x582ba, b"\x72\x0b", b"\x72\x0c", "grow:as_map addr/size clicks<<11 (#11->#12, both shifts)"),
 # grow SUCCESS/SHRINK TAIL (missed by the first pass -- its scan window ended at 0x582e0;
 # ALWAYS scan to the function's real end).  BOOT-PROVEN bug: as_map mapped d2<<12 bytes but
 # the bookkeeping moved p_stkbase/-size by d2<<11 (half) -> stkbase=C07FE000/stksize=2000
 # after a 2-page map [C07FD000,C07FF000) -> the process's SECOND grow as_map overlaps ->
 # grow ret=0 -> 'User BUS ERROR at C07FC5D0' (/usr/lib/saf/listen tcp at the login prompt).
 (0x5830c, b"\x72\x0b", b"\x72\x0c", "grow:shrink as_unmap size d2<<11 (#11->#12)"),
 (0x58328, b"\x72\x0b", b"\x72\x0c", "grow:success tail p_stksize+=/p_stkbase-= d2<<11 (#11->#12, one moveq drives both)"),
 # USER-VM PER-PAGE-ARRAY COMPLETION (2026-07-02): the seg_vn/as family was only PARTIALLY
 # converted (segvn_fault/as_fault/anon_dup/anon_free/anon_resv 4KB, everything else 2KB) --
 # exactly the mixed-granularity hazard the as_setprot post-mortem warned about.  Symptom:
 # PANIC swap_xlate once rc-script fork/exec/unmap churn started (segvn_fault -> anon_getpage
 # got a garbage anon ptr): e.g. segvn_unmap's partial-unmap/split path computes anon_index and
 # the anon_free range with 2KB math against arrays the 4KB fault path populates.  Fix = convert
 # the WHOLE coupled set in one sweep (sites classified by detect_pagesize.py, byte-verified by
 # gen_uservm_patches.py): segvn_create/extend_prev/extend_next/anonmap_alloc/dup/unmap/free/
 # softunlock/non_anon/faulta/unload/setprot/checkprot/getprot/kluster/swapout/sync/incore/
 # lockop/vpage/isanon + as_faulta/setprot/checkprot/unmap/map/incore/ctl + map_addr.
 # DEFERRED (noted, not converted): as_iolock (async-IO path), execstk_addr (works today;
 # interacts with as_exec/hat_exec stack move), phystopp (verify pages[] index basis first),
 # vm_swap internals (2KB-consistent internally; matters only when real swap-out starts).
 (0xaacb8, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "segvn_create:offset mask &-2048"),
 (0xaad34, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "segvn_create:offset mask &-2048"),
 (0xaae8e, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "segvn_create:offset mask &-2048"),
 (0xaaf1c, b"\x06\x86\x00\x00\x07\xff", b"\x06\x86\x00\x00\x0f\xff", "segvn_create:npages round +2047"),
 (0xaaf22, b"\x72\x0b", b"\x72\x0c", "segvn_create:npages >>11"),
 (0xaafc4, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "segvn_create:vpage-loop va step"),
 (0xab10c, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "segvn_extend_prev:offset mask"),
 (0xab146, b"\x78\x0b", b"\x78\x0c", "segvn_extend_prev:pages<<11"),
 (0xab1c2, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_extend_prev:npages round"),
 (0xab1c8, b"\x78\x0b", b"\x78\x0c", "segvn_extend_prev:npages >>11"),
 (0xab1e0, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_extend_prev:npages round"),
 (0xab26c, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "segvn_extend_next:offset mask"),
 (0xab2a0, b"\x76\x0b", b"\x76\x0c", "segvn_extend_next:pages<<11"),
 (0xab2ee, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_extend_next:npages round"),
 (0xab340, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_extend_next:npages round"),
 (0xab346, b"\x76\x0b", b"\x76\x0c", "segvn_extend_next:npages >>11"),
 (0xab366, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_extend_next:npages round"),
 (0xab3e6, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "anonmap_alloc:anon slots round +2047"),
 (0xab3ec, b"\x72\x0b", b"\x72\x0c", "anonmap_alloc:anon slots >>11"),
 (0xab430, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "segvn_dup:npages round (vpage copy)"),
 (0xab436, b"\x72\x0b", b"\x72\x0c", "segvn_dup:npages >>11"),
 (0xab670, b"\x02\x80\x00\x00\x07\xff", b"\x02\x80\x00\x00\x0f\xff", "segvn_unmap:addr pageoff &2047"),
 (0xab67c, b"\x02\x80\x00\x00\x07\xff", b"\x02\x80\x00\x00\x0f\xff", "segvn_unmap:len pageoff &2047"),
 (0xab754, b"\x06\x85\x00\x00\x07\xff", b"\x06\x85\x00\x00\x0f\xff", "segvn_unmap:anon_free npages round"),
 (0xab75a, b"\x72\x0b", b"\x72\x0c", "segvn_unmap:anon_free npages >>11"),
 (0xaba08, b"\x06\x84\x00\x00\x07\xff", b"\x06\x84\x00\x00\x0f\xff", "segvn_unmap:split anon_index round"),
 (0xaba0e, b"\x72\x0b", b"\x72\x0c", "segvn_unmap:split anon_index >>11"),
 (0xaba3a, b"\x06\x84\x00\x00\x07\xff", b"\x06\x84\x00\x00\x0f\xff", "segvn_unmap:split vpage idx round"),
 (0xaba40, b"\x72\x0b", b"\x72\x0c", "segvn_unmap:split vpage idx >>11"),
 (0xaba9c, b"\x72\x0b", b"\x72\x0c", "segvn_unmap:split idx >>11"),
 (0xabb8e, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "segvn_free:anon array npages round"),
 (0xabb94, b"\x72\x0b", b"\x72\x0c", "segvn_free:anon array npages >>11"),
 (0xabd2e, b"\x7c\x0b", b"\x7c\x0c", "segvn_softunlock:page idx >>11"),
 (0xabd56, b"\x7c\x0b", b"\x7c\x0c", "segvn_softunlock:page idx >>11"),
 (0xabdae, b"\x7c\x0b", b"\x7c\x0c", "segvn_softunlock:page idx >>11"),
 (0xabee0, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "segvn_softunlock:loop bound step"),
 (0xabf2e, b"\x06\x80\x00\x00\x08\x00", b"\x06\x80\x00\x00\x10\x00", "non_anon:next-page step"),
 (0xabf4e, b"\x06\x80\x00\x00\x08\x00", b"\x06\x80\x00\x00\x10\x00", "non_anon:next-page step"),
 (0xac868, b"\x74\x0b", b"\x74\x0c", "segvn_faulta:page idx >>11"),
 (0xac922, b"\x7a\x0b", b"\x7a\x0c", "segvn_unload:page idx >>11"),
 (0xaca92, b"\x7c\x0b", b"\x7c\x0c", "segvn_setprot:page idx >>11"),
 (0xacab6, b"\x7c\x0b", b"\x7c\x0c", "segvn_setprot:page idx >>11"),
 (0xacb5e, b"\x06\x85\x00\x00\x08\x00", b"\x06\x85\x00\x00\x10\x00", "segvn_setprot:va loop step"),
 (0xacb84, b"\x7c\x0b", b"\x7c\x0c", "segvn_setprot:page idx >>11"),
 (0xacc2e, b"\x78\x0b", b"\x78\x0c", "segvn_checkprot:page idx >>11"),
 (0xacc9a, b"\x76\x0b", b"\x76\x0c", "segvn_getprot:page idx >>11"),
 (0xaccd2, b"\x76\x0b", b"\x76\x0c", "segvn_getprot:page idx >>11"),
 (0xacd80, b"\x06\x81\x00\x00\x07\xff", b"\x06\x81\x00\x00\x0f\xff", "segvn_kluster:idx round"),
 (0xacd86, b"\x78\x0b", b"\x78\x0c", "segvn_kluster:idx >>11"),
 (0xace4c, b"\x72\x0b", b"\x72\x0c", "segvn_swapout:npages >>11"),
 (0xace98, b"\x72\x0b", b"\x72\x0c", "segvn_swapout:page<<11"),
 (0xacf7a, b"\x72\x0b", b"\x72\x0c", "segvn_swapout:page<<11"),
 (0xad034, b"\x72\x0b", b"\x72\x0c", "segvn_sync:page idx >>11"),
 (0xad096, b"\x72\x0b", b"\x72\x0c", "segvn_sync:page idx >>11"),
 (0xad0dc, b"\x06\x84\x00\x00\x08\x00", b"\x06\x84\x00\x00\x10\x00", "segvn_sync:va loop step"),
 (0xad162, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "segvn_sync:va loop step"),
 (0xad1aa, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_incore:npages round"),
 (0xad1b0, b"\x7c\x0b", b"\x7c\x0c", "segvn_incore:npages >>11"),
 (0xad1c8, b"\x7c\x0b", b"\x7c\x0c", "segvn_incore:page idx >>11"),
 (0xad2c0, b"\x06\x84\x00\x00\x08\x00", b"\x06\x84\x00\x00\x10\x00", "segvn_incore:va loop step"),
 (0xad3b6, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_lockop:npages round"),
 (0xad3bc, b"\x7c\x0b", b"\x7c\x0c", "segvn_lockop:npages >>11"),
 (0xad3f4, b"\x7c\x0b", b"\x7c\x0c", "segvn_lockop:page idx >>11"),
 (0xad41e, b"\x7c\x0b", b"\x7c\x0c", "segvn_lockop:page idx >>11"),
 (0xad596, b"\x06\x84\x00\x00\x08\x00", b"\x06\x84\x00\x00\x10\x00", "segvn_lockop:va loop step"),
 (0xad59c, b"\x06\xae\x00\x00\x08\x00", b"\x06\xae\x00\x00\x10\x00", "segvn_lockop:va loop step (fp-var)"),
 (0xad5ea, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_vpage:npages round"),
 (0xad5f0, b"\x74\x0b", b"\x74\x0c", "segvn_vpage:npages >>11"),
 (0xad672, b"\x72\x0b", b"\x72\x0c", "segvn_isanon:page idx >>11"),
 (0xae26a, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "as_faulta:addr mask &-2048"),
 (0xae272, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_faulta:size round +2047"),
 (0xae278, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "as_faulta:size mask &-2048"),
 (0xae2cc, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "as_faulta:addr step"),
 (0xae2d2, b"\x06\x83\xff\xff\xf8\x00", b"\x06\x83\xff\xff\xf0\x00", "as_faulta:size step -2048"),
 (0xae2fc, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00", "as_setprot:addr mask"),
 (0xae304, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_setprot:size round"),
 (0xae30a, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "as_setprot:size mask"),
 (0xae3a8, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00", "as_checkprot:addr mask"),
 (0xae3b0, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_checkprot:size round"),
 (0xae3b6, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "as_checkprot:size mask"),
 (0xae456, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00", "as_unmap:addr mask"),
 (0xae460, b"\x06\x84\x00\x00\x07\xff", b"\x06\x84\x00\x00\x0f\xff", "as_unmap:size round"),
 (0xae466, b"\x02\x44\xf8\x00", b"\x02\x44\xf0\x00", "as_unmap:size mask"),
 (0xae50e, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "as_map:addr mask"),
 (0xae516, b"\x06\x81\x00\x00\x07\xff", b"\x06\x81\x00\x00\x0f\xff", "as_map:size round"),
 (0xae51c, b"\x02\x41\xf8\x00", b"\x02\x41\xf0\x00", "as_map:size mask"),
 (0xaea34, b"\x02\x43\xf8\x00", b"\x02\x43\xf0\x00", "as_incore:addr mask"),
 (0xaea3c, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_incore:size round"),
 (0xaea42, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "as_incore:size mask"),
 (0xaeac0, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_incore:npages round"),
 (0xaeac6, b"\x7c\x0b", b"\x7c\x0c", "as_incore:npages >>11"),
 (0xaeb78, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_ctl:npages round"),
 (0xaeb7e, b"\x72\x0b", b"\x72\x0c", "as_ctl:npages >>11"),
 (0xaebe0, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "as_ctl:addr mask"),
 (0xaebe8, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_ctl:size round"),
 (0xaebee, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "as_ctl:size mask"),
 (0xaf0f0, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "map_addr:addr round"),
 (0xaf0f6, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "map_addr:addr mask"),
 (0xaf11e, b"\xd2\xfc\x08\x00", b"\xd2\xfc\x10\x00", "map_addr:addr += pagesize"),
 # segu_softunload (u-area TEARDOWN, proc death): segu_softload was 4KB-converted (pager table)
 # but softUNLOAD stayed 2KB -> the u-area/kernel-stack pages are looked up with wrong index/
 # range math at process exit and not returned -> part of the ~26-pages-per-exec kernel-heap
 # drain behind 'ldterm: out of blocks'.  Same-pattern flips incl. the two PTE pfn bitfields
 # {0:21}->{0:20}.  segu_getprot's page-index shift converted for symmetry.  NOT converted
 # (deliberate): segu_get 0xaa6dc/0xaa6fa -- those belong to an inline 030-format table walk
 # (va>>17 SDE + va>>11 leaf, copies u-area PTEs into the ublk save area) that is structurally
 # 030 and inert on 040 (resume040 reads the kvsegu VA + kptr040 instead); flipping its shifts
 # would just make a differently-wrong 030 walk.
 (0xaa386, b"\x74\x0b", b"\x74\x0c", "segu_getprot:page idx >>11"),
 (0xaa884, b"\x02\x42\xf8\x00", b"\x02\x42\xf0\x00", "segu_softunload:addr mask &-2048"),
 (0xaa88c, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segu_softunload:size round +2047"),
 (0xaa892, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "segu_softunload:size mask &-2048"),
 (0xaa8f4, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segu_softunload:PTE idx round +2047"),
 (0xaa8fa, b"\x7a\x0b", b"\x7a\x0c", "segu_softunload:PTE idx >>11"),
 (0xaa91e, b"\xe9\xd3\x00\x15", b"\xe9\xd3\x00\x14", "segu_softunload:pfn bfextu {0:21}->{0:20}"),
 (0xaa940, b"\xe9\xd3\x00\x15", b"\xe9\xd3\x00\x14", "segu_softunload:pfn bfextu {0:21}->{0:20} (pages[] idx)"),
 (0xaa9c2, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "segu_softunload:va loop step"),
 # segu softload/softunload VOP_GETPAGE/VOP_PUTPAGE lens (2026-07-04, boot-13 panic): the
 # segu round/index/step math is already 4KB (softunload above, softload in patch_modelb_pager)
 # but the pager calls still passed len 0x800 -> VOP_GETPAGE rejects the sub-page request
 # (as_fault ret=0x1605 = FC_MAKE_ERR(EINVAL)) -> the kvsegu window page never maps ->
 # prgetpsinfo's raw movel from 0x48440900 -> KERNEL FAULT pc=0x7064436 (scrmenu ioctl, pid 43).
 (0xaaaa4, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "segu_softload:VOP_GETPAGE plsz 0x800->0x1000"),
 (0xaaaae, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "segu_softload:VOP_GETPAGE len 0x800->0x1000"),
 (0xaa9ae, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "segu_softunload:VOP_PUTPAGE len 0x800->0x1000"),
 # USER DEMAND-FAULT PATH (as_fault + segvn_fault) -- the MINIMAL coupled set, 4KB.
 # The 030 path rounds the fault VA to 2KB and the anon map is a 2KB-granular array.  On Model B a
 # fault in the UPPER 2KB of a 4KB page (libc.so.1's GOT at C102FE68) maps at C102F800, which shares
 # hat_pteload's leaf slot (va>>12)&0x3F with C102F000 -> the 2nd 2KB fault overwrites the 1st's 4KB
 # leaf PTE -> GOT corruption -> /sbin/init's runtime linker (libc.so.1 do_reloc) USER BUS ERROR at
 # 0x66000030.  Fix: round the fault to 4KB (as_fault) and loop/index the anon array at 4KB
 # granularity (segvn_fault), so one fault -> one 4KB page -> one leaf, no collision.
 #
 # WHAT THE STRUCTS PROVE (vanilla/usr/include/vm/{anon,seg_vn}.h, read 2026-06-25):
 #   struct anon_map { u_int refcnt; u_int size; struct anon **anon; u_int swresv; }
 #   The anon[] array holds ONE struct anon* PER PAGE; #slots = size/PAGESIZE, indexed off/PAGESIZE.
 #   So PAGESIZE 2048->4096 means alloc (size+4095)>>12 slots and index (addr-base)>>12 -- a SELF-
 #   consistent set as long as the loop stride matches (4096) so a2 advances one slot per page.
 # segvn_faultpage (0xac01a) was claimed to "hardcode >>12 @0xac0d2": NOT a page shift -- 0xac0d2 is
 #   `moveq #12,d0` = errno ENOMEM (12) into the return value.  segvn_faultpage has NO page-size
 #   const; it receives the anon slot ptr + page already resolved by segvn_fault.  So the entire
 #   granularity lives in segvn_fault (these 8 sites) + as_fault (3 sites).  Verified by full
 #   disassembly 2026-06-25.
 #
 # WHY as_faulta + as_setprot are OMITTED (the 2026-06-25 21dda30 both-4KB failure post-mortem):
 #   21dda30 converted as_fault+segvn_fault (CORRECT bytes) BUT ALSO as_faulta + as_setprot, and
 #   bus-errored in kmem_alloc.  Root cause = OVER-conversion: as_setprot rounds the protection
 #   range, then calls segvn_setprot which sizes/indexes the per-page vpage[] array -- still 2KB,
 #   UNCONVERTED.  4KB-rounded range vs 2KB vpage math overruns the vpage array -> kernel heap
 #   corruption -> the next kmem_zalloc (segvn_fault's anon array @0xac50c) bus-errors.  So the
 #   prior "anon-map kmem_alloc" blame was a SYMPTOM, not the cause.  Leaving as_setprot at 2KB is
 #   safe here: it issues redundant 2KB hat_chgprot calls WITHIN a 4KB leaf (same prot both halves;
 #   init's ELF segment boundaries are 4KB-aligned via p_align), never overrunning anything.
 #   as_faulta (the lock-fault entry) is not on init's demand-fault path.  Both can be converted
 #   later TOGETHER with segvn_setprot's vpage math as their own coupled set.
 # --- as_fault: round the fault range DOWN/UP to a 4KB page (then calls segvn_fault per seg) ---
 (0xae156, b"\x02\x43\xf8\x00",         b"\x02\x43\xf0\x00",         "as_fault:round start -2048->-4096"),
 (0xae15e, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "as_fault:round end +2047->+4095"),
 (0xae164, b"\x02\x40\xf8\x00",         b"\x02\x40\xf0\x00",         "as_fault:round end -2048->-4096"),
 # --- segvn_fault: anon-array alloc (size/PAGE slots) + fault index + plist alloc + single-page
 #     test + per-page loop stride (addr & file-offset) + in-memory fast-path page index ---
 (0xac4fe, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segvn_fault:anon array (size+2047)>>11 -> +4095>>12"),
 (0xac504, b"\x76\x0b", b"\x76\x0c", "segvn_fault:anon array alloc shift >>11->>>12"),
 (0xac52e, b"\x76\x0b", b"\x76\x0c", "segvn_fault:fault-page anon index (addr-base)>>11->>>12"),
 (0xac59a, b"\x76\x0b", b"\x76\x0c", "segvn_fault:plist array (len>>11)+1 -> (len>>12)+1"),
 (0xac5d4, b"\x0c\xae\x00\x00\x08\x00", b"\x0c\xae\x00\x00\x10\x00", "segvn_fault:single-page test len<=2048 -> <=4096"),
 (0xac726, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "segvn_fault:loop addr stride +2048->+4096"),
 (0xac72c, b"\x06\x85\x00\x00\x08\x00", b"\x06\x85\x00\x00\x10\x00", "segvn_fault:loop file-offset stride +2048->+4096"),
 (0xac778, b"\x76\x0b", b"\x76\x0c", "segvn_fault:in-memory fast-path page index >>11->>>12"),
 # ANON-ARRAY CONSUMERS -- the rest of the coupled set.  The anon[] array is now sized one-slot-
 # per-4KB-page (segvn_fault site 1).  Every function that WALKS or FREES that array by a
 # byte-size->slot-count conversion MUST also use >>12, else it runs off the (now smaller) array.
 # This is what bus-errored kmem_alloc in the both-4KB attempt (21dda30): NOT as_setprot, but the
 # relvm teardown.  Confirmed call path 2026-06-25: as_free -> seg_unmap -> segvn_unmap; for a
 # WHOLE-segment unmap (ab72a: addr==s_base && len==s_size, always true during relvm) segvn_unmap
 # calls seg_free -> segvn_free, which calls anon_free(base, BYTE size) + kmem_free(anon array,
 # (size>>shift)*4).  segvn_unmap's PARTIAL-unmap split/realloc paths (ab74c+) do NOT run during
 # relvm, so they stay 2KB for now (TODO: convert with the rest if munmap-in-the-middle is used).
 # anon_free walks (size+2047)>>11 slots calling anon_decref -- off the end of a 4KB array it
 # decrefs garbage -> corrupts the kmem free list -> the next kmem_zalloc (segvn_fault anon array)
 # bus-errors.  vpage[] stays 2KB everywhere (init segments have uniform prot -> vpage==NULL), so
 # segvn_free's vpage free (abb8e/abbbe) is left untouched.
 (0xad852, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "anon_free:(size+2047)>>11 slot count -> +4095>>12"),
 (0xad858, b"\x72\x0b", b"\x72\x0c", "anon_free:slot-count shift >>11->>>12"),
 (0xad810, b"\x06\x81\x00\x00\x07\xff", b"\x06\x81\x00\x00\x0f\xff", "anon_dup:(size+2047)>>11 slot count -> +4095>>12 (fork)"),
 (0xad816, b"\x74\x0b", b"\x74\x0c", "anon_dup:slot-count shift >>11->>>12 (fork)"),
 (0xabc3e, b"\x72\x0b", b"\x72\x0c", "segvn_free:anon array kmem_free size (size>>11)*4 -> >>12 (match 4KB alloc)"),
 # PHYSICAL PAGE PRIMITIVES (ppcopy / pagecopy / pagezero) -- pfn->phys shift + copy size.
 # These take a struct page* and compute the physical address as `((page-pages)/60 + pages_base)
 # << 11`, then bcopy/copyin/bzero a hardcoded 0x800 (2048) bytes.  On Model B both are wrong:
 #   (a) pfn<<11 yields phys/2 -- a completely WRONG (half) physical address (the same pfn<<11->
 #       <<12 fix already applied to gen_strategy, hat_sdtalloc, etc.; pages_base-relative pfns are
 #       4KB on Model B so phys = pfn<<12).
 #   (b) the hardcoded 0x800 copies/zeros only the LOWER 2KB of the 4KB page.
 # THIS is the /sbin/init dynamic-linker bug (NOT the as_fault collision, which the 4KB demand-fault
 # conversion already fixed): do_reloc WRITES the GOT (a private, file-backed page) -> the first
 # copy-on-write of init's run -> segvn_faultpage -> anon_private -> ppcopy(orig,new).  ppcopy read
 # from the wrong phys and copied only 2KB, so the new private GOT page's upper 2KB (the GOT slot at
 # C102FE68 = _GLOBAL_OFFSET_TABLE_+0xDC) held garbage; do_reloc relocated it (+C1000000, wrapping
 # ~0xA5xxxxxx -> 0x66000030) and dereferenced it -> USER BUS ERROR at 0x66000030 PC=C101100E.
 # ppcopy (0xaf200): fix the shared shift (#11 drives BOTH lsll for from+to phys) and the size.
 (0xaf230, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "ppcopy:copy size 2048->4096"),
 (0xaf234, b"\x74\x0b", b"\x74\x0c", "ppcopy:pfn->phys shift <<11->>><12 (both from+to)"),
 # pagecopy (0xaf24e): copyin a full page from a user addr into a phys page.
 (0xaf268, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "pagecopy:copy size 2048->4096"),
 (0xaf26c, b"\x72\x0b", b"\x72\x0c", "pagecopy:pfn->phys shift <<11->>><12"),
 # pagezero (0xaf282): bzero; the byte count is a caller arg (left to the caller), only the base
 # phys shift is wrong here.
 (0xaf29c, b"\x72\x0b", b"\x72\x0c", "pagezero:pfn->phys shift <<11->>><12"),
 # hat_ptalloc: FORCE the page_get path; never reuse a pooled PT page.  The free_pts
 # reuse path (0xb68a6..0xb6918) sub-allocates 512B fragments inside a page using 030
 # 2KB-page math (b68ec #11 / b68f6 #9) and bzero's the stored fragment address -- on
 # Model B (4KB pages, leaves from the patched page_get path) that path bzero'd a bad
 # address (KERNEL FAULT pc inside bzero @0x31C, exec rebuild's first leaf for
 # va=80009000).  The page_get path (b691c+) is already Model-B-patched (pfn<<12 @b6a74)
 # and produces correct leaves (it ran for all of proc-1 setup).  Change the `free_pts
 # empty?` branch from beqw to an unconditional braw so every leaf is a fresh page (the
 # pool fills but is never drained -- a bounded leak, same philosophy as hat_free's V1
 # pointer-table leak).  TODO: port the 4KB fragment pool if leaf churn ever matters.
 (0xb68a2, b"\x67\x00\x00\x78", b"\x60\x00\x00\x78", "hat_ptalloc:force page_get (skip free_pts reuse)"),
 # ----------------------------------------------------------------------------------------------
 # 68040 ACCESS-ERROR FRAME: read/write classification in usrxmemflt (NOT a Model B page-size
 # patch -- an 040 trap-frame port, lives here because patch_modelb.py is the 040-only byte-patch
 # pass).  usrxmemflt computes the fault's rw (read vs write) for as_fault from the SSW:
 #   5af14: moveq #64,%d0          ; mask 0x40
 #   5af16: andl  %a0@(72),%d0     ; & frame+72   -> (bit set) rw=1 read, else rw=2 write (=COW)
 # frame+72 = the 030 SSW, but on the 68040 format-7 access-error frame +72 (=CPU+0x08) is the
 # EFFECTIVE ADDRESS, not the SSW.  The 040 SSW is at frame+76 (CPU+0x0C) and its RW bit is bit 8
 # (0x100; 1=read, 0=write) -- same place userspace040.s already reads for the FC/TM bits.  So on
 # 040 the rw was derived from bit 6 of the fault EA = garbage -> a USER WRITE (do_reloc relocating
 # libc.so.1's GOT, a private file-backed page) was misclassified as a READ -> segvn never COW'd
 # the page -> the relocation writes never persisted -> the GOT stayed RAW (every slot = its file
 # value, unrelocated) -> the dynamic linker called a raw GOT slot and exit()'d before transferring
 # to /sbin/init.  PROVEN by the rexit GOT dump (all 40 slots raw 0x000xxxxx, e.g. +0x58 = 0001116E
 # instead of the relocated C101116E _rtmalloc).
 # Fix (6 bytes in place): read the 040 SSW high byte at frame+76 and test bit 8 via a byte AND:
 #   moveq #1,%d0 ; andb %a0@(76),%d0   -> d0 = SSW bit 8 (RW).  bit set (read) -> rw=1; clear
 #   (write) -> rw=2 (COW).  Same rw=1/rw=2 semantics the 030 path produced.  (usrxmemflt is also
 #   wrapped by wb040.s, which calls usrxmemflt_orig = this patched code, so the fix is live.)
 (0x5af14, b"\x70\x40\xc0\xa8\x00\x48", b"\x70\x01\xc0\x28\x00\x4c", "usrxmemflt:040 SSW rw bit (frame+72 030 -> frame+76 bit8 040)"),
 # usrxmemflt SECOND SSW read (5b050), on the W (write-protect / COW) path.  After ptest040 routes
 # a write to a read-only page here (MMUSR W set), 5b050 gates the COW: the 030 code tested
 #   5b054: movel %a0@(72),%d0 ; andil #0x140 ; cmpil #0x100  (frame+72 030 SSW: bit8 set, bit6 clr)
 # but frame+72 is the 040 EFFECTIVE ADDRESS (garbage) -> the test fails for our GOT VA and mis-
 # routes to 5b0f2/hardbus.  Mirror the 5af14 fix: read the 040 SSW at frame+76 bit 8 (1=read) and
 # branch to 5b0f2 only on a READ fault; a WRITE (bit8==0, our COW case) falls through to 5b068.
 #   5b054: moveq #1,%d0 ; andb %a0@(76),%d0 ; bnew 0x5b0f2 ; <5x nop>  (same 20 bytes)
 # (bnew disp = 0x5b0f2 - 0x5b05c = 0x96.)  The moveal %fp@(8),%a0 at 5b050 is left untouched.
 (0x5b054,
  b"\x20\x28\x00\x48\x02\x80\x00\x00\x01\x40\x0c\x80\x00\x00\x01\x00\x66\x00\x00\x8c",
  b"\x70\x01\xc0\x28\x00\x4c\x66\x00\x00\x96\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71",
  "usrxmemflt:040 SSW 2nd read on COW path (frame+72 030 -> frame+76 bit8 040)"),
 # usrxmemflt INLINE leaf walk (TWO sites) -- consume uvatosde040's &PTE directly.
 # Stock usrxmemflt calls uvatosde (030: returns &SDE) then walks an INLINE 030 leaf:
 #   moveal %a0,%a3 ; d0=VA ; d0=(VA>>11)&0x3F ; d0<<=2 ; a2=d0 ; addal %a3@(4),%a2  -> a2=&PTE
 # That is the 030 8-byte-SDE format (leaf at SDE+4) + a 2KB leaf index -- both wrong on 040,
 # and the SDE itself is garbage (stock uvatosde walks the inert 030 tree).  uvatosde040.s
 # (--weaken-symbol uvatosde) now does the FULL per-proc 040 walk and returns &PTE in %a0.
 # So replace each 22-byte inline 030 leaf walk with `moveal %a0,%a2` + 10x nop: a2 = &PTE.
 # Site 1 (0x5b072): F_PROT/COW path -- the bfextu %a2@(3) PTE read at 0x5b088 (the actual
 #   bus-error site that blocked init at pid 5) then chooses the as_fault rw variant.
 # Site 2 (0x5b0fc): the hardbus (genuine bus-error reporting) path -- passes &PTE to hardbus.
 # Both sequences are byte-identical (same instructions), so old/new are shared.
 (0x5b072,
  b"\x26\x48\x20\x2e\xff\xdc\x72\x0b\xe2\xa8\x72\x3f\xc0\x81\xe5\x80\x24\x40\xd5\xeb\x00\x04",
  b"\x24\x48\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71",
  "usrxmemflt:inline 030 leaf -> moveal a0,a2 (uvatosde040 returns &PTE) site1 F_PROT/COW"),
 (0x5b0fc,
  b"\x26\x48\x20\x2e\xff\xdc\x72\x0b\xe2\xa8\x72\x3f\xc0\x81\xe5\x80\x24\x40\xd5\xeb\x00\x04",
  b"\x24\x48\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71\x4e\x71",
  "usrxmemflt:inline 030 leaf -> moveal a0,a2 (uvatosde040 returns &PTE) site2 hardbus"),

 # ---- 2026-07-03 "Killed" frontier: main banner + execstk_addr (the last exec-path 2KB relic).
 # main (0x59890/0x598ac): the boot banner's "real/avail mem" = physmem<<11 / freemem<<11.
 # Model B made those counters 4KB clicks, so the banner printed HALF the real memory
 # (8MB on the 16MB machine).  Purely cosmetic, but it made "memory accounting halved" look
 # like a live kernel-wide bug -- fix it so the banner becomes a truthful diagnostic again.
 (0x59890, b"\x72\x0b", b"\x72\x0c", "main:banner real-mem physmem<<11 -> <<12"),
 (0x598ac, b"\x72\x0b", b"\x72\x0c", "main:banner avail-mem freemem<<11 -> <<12"),
 # execstk_addr (0xaf2b8, DEFERRED until now): picks the user-VA hole where exec builds the
 # new image's arg/env stack.  All its pads/bounds are NBPC=2KB: size+2048 headroom, region
 # bounds 0xBFFFF800 (=0xC0000000-NBPC) / 0xFFFFF800 (=-NBPC), and two +2048 rounding
 # compensations in the 128KB-chunk hole scan.  A 2KB-but-not-4KB-aligned pick makes the
 # address math disagree with the (now 4KB) segvn mapping of the stack -> setregs's
 # copyin(args->u_psargs) EFAULTs -> exece answers with a SILENT psignal(p,9) (0x566b6)
 # = the instant 'Killed' on exec.  Whether a given exec dies depends on the 2KB slot
 # parity of its arg/env size -- matching "uname/ls die, other execs fine".
 (0xaf2ca, b"\x06\x87\x00\x00\x08\x00", b"\x06\x87\x00\x00\x10\x00", "execstk_addr:size+2048 headroom -> +4096"),
 (0xaf310, b"\x28\x3c\xbf\xff\xf8\x00", b"\x28\x3c\xbf\xff\xf0\x00", "execstk_addr:region2 end 0xC0000000-NBPC (2KB->4KB)"),
 (0xaf320, b"\x28\x3c\xff\xff\xf8\x00", b"\x28\x3c\xff\xff\xf0\x00", "execstk_addr:region3 end -NBPC (2KB->4KB)"),
 (0xaf37a, b"\x06\x82\x00\x00\x08\x00", b"\x06\x82\x00\x00\x10\x00", "execstk_addr:hole-scan +NBPC compensation 1 (2KB->4KB)"),
 (0xaf3a4, b"\x06\x83\x00\x00\x08\x00", b"\x06\x83\x00\x00\x10\x00", "execstk_addr:hole-scan +NBPC compensation 2 (2KB->4KB)"),

 # ---- 2026-07-03 THE `pea 0x800` FAMILY (the rtld-kill root cause).  detect_pagesize.py's
 # idiom scan keys on IMMEDIATES (#2048 etc); `pea 800` assembles as ABSOLUTE-ADDRESS pea
 # (4878 0800) and evaded every audit.  Systematic whole-kernel triage of all 44 sites
 # (function + callee): the VM family below carries PAGE-SIZE semantics and was still 2KB.
 # ★ THE KILLER: anon_zero's pagezero(pp, 0, 0x800) zeroes only HALF of every zero-fill-
 # on-demand page -> the UPPER 2KB keeps the previous owner's data.  The exec arg block
 # relies on ZFOD zeros for its argv/envp NULL TERMINATORS (extractarg/copyarglist never
 # write them!) -> a recycled dirty page puts garbage in the envp NULL slot -> rtld's auxv
 # scan runs past it, eats the auxv as environ, finds no AT_BASE -> _rt_setup+0xE2 silent
 # self-SIGKILL (boot-4 X-dumps: auxv INTACT at the right place on all 7 victims, overshoot
 # = exactly envc+1+15 words).  Same dirty-upper-half explains the ls user-mode loop, the
 # `open (%%%%/dev/console)` garbage path (dirty argv NULL), and bss flakiness.
 (0xaddfa, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "anon_zero:pagezero len 2048->4096 (ZFOD half-zero = THE rtld killer)"),
 (0x744f0, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "s5getapage:pagezero len (file-page tail zero)"),
 (0x81f50, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "ufs_getapage:pagezero len (file-page tail zero)"),
 # (0xadc24 anon_private:hat_unload len -- WITHDRAWN with the seg-family batch below)
 # page_get(size,flag): btoc(0x800)==btoc(0x1000)==1 page -> functionally identical, flipped
 # for unit consistency (a future btoc change must not halve these).
 (0x74494, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "s5getapage:page_get size"),
 (0x81f1a, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "ufs_getapage:page_get size"),
 (0xa12e2, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "rfc_writefill:page_get size"),
 (0xa1cc0, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "rfc_pageget:page_get size"),
 (0xa97a0, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "segmap_pagecreate:page_get size"),
 (0xadb64, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "anon_private:page_get size (COW new page)"),
 (0xadd62, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "anon_zero:page_get size"),
 (0xb1124, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "page_delmem:page_get size"),
 (0xb6974, b"\x48\x78\x08\x00", b"\x48\x78\x10\x00", "hat_ptalloc:page_get size (hat040 leaf/ptr tables)"),
 # hardbus (0x5b3c2, found 2026-07-04 chasing the date fault loop): computes the PHYSICAL
 # probe address from the leaf PTE with 2KB masks -- `(*ptep & 0xFFFFF800) + (addr & 0x7FF)`.
 # On Model B the PTE phys base is bits 31:12 and the page offset is addr & 0xFFF; the old
 # mask even leaks PTE bit 11 (a non-address bit on 040) into the "phys" -> bprobe tests a
 # garbage address -> wrong hard-error verdicts both ways (spurious kills OR eternal retries).
 (0x5b3cc, b"\x02\x40\xf8\x00", b"\x02\x40\xf0\x00", "hardbus:PTE->phys mask ~0x7FF -> ~0xFFF"),
 (0x5b3d4, b"\x02\x81\x00\x00\x07\xff", b"\x02\x81\x00\x00\x0f\xff", "hardbus:page offset mask 0x7FF -> 0xFFF"),
 # REVERTED 2026-07-03 NIGHT (boot-7 clock-sampler verdict): the seg-family fault-len flips
 # are WITHDRAWN pending individual analysis.  Boot 5/6 hung deterministically at date
 # (pid 24) in an infinite unresolvable-fault loop (samples: u_trap -> usrxmemflt ->
 # hardbus -> trapsig -> ts_trapret -> fault again, with ptest/wb040_replay active); boot 4
 # WITHOUT this batch passed the same point.  The pagezero trio + page_get sizes are kept
 # (page_get's btoc is (x+4095)>>12 -> 0x800 and 0x1000 both = 1 page, verified in-binary).
 # Withdrawn (re-add ONE AT A TIME with a boot test each, after reading how each len is
 # bounds-checked downstream -- suspect: a still-2KB bound check turns off+0x1000 into
 # EFAULT where off+0x800 passed, e.g. at a segment's last page):
 #  (0xac13e segvn_faultpage:anon_getpage len)  <- prime suspect, hot COW/anon fault path
 #  (0xad9a6 anon_getpage:VOP_GETPAGE len)      <- prime suspect, same path
 #  (0xadc24 anon_private:hat_unload len)       <- 1 page either way, but on the loop path
 #  (0xac8c2 segvn_faulta) (0xa93ba segmap_faulta) (0xacf36 segvn_swapout)
 #  (0xad148 segvn_sync) (0xad482/0xad536 segvn_lockop)
 # REVERTED 2026-07-03 EVE (boot-5 hang suspect): the as_iolock and prusrio pea-len flips
 # are WITHDRAWN.  Both functions' INTERNALS are still 2KB (as_iolock: ~10 unpatched
 # mask/step sites 0xaee6a..0xaf01c incl. loop step `movel #2048,%d3`; prusrio: 0x64580/
 # 0x64586) -- they were DELIBERATELY deferred, and flipping only their lock/fault LENGTHS
 # made lock-len 4KB vs step 2KB = OVERLAPPING SOFTLOCKS = p_lck imbalance = hang risk.
 # The partial-conversion hazard, self-inflicted.  Convert them as complete sets later:
 #  (0x645d8/0x6467a prusrio as_fault lens) + (0x64580 andiw#-2048, 0x64586 addil#2048)
 #  (0xaefdc/0xaefe4 as_iolock SOP lens) + (0xaee6a/0xaeed6/0xaf01c andil#2047,
 #   0xaeeba/0xaeece andiw#-2048, 0xaeedc/0xaf000 movel#2048,%d3, 0xaef02/0xaf006
 #   addil#2048, 0xaef10 addil#-2048) + audit as_iounlock's mirror.
 # ========================================================================
 # SPTMAP ARENA FAMILY COMPLETION (2026-07-04, boot-14 ttymon kmem free-list
 # corruption panic pc=0x704211C).  The kvseg sptmap arena is 4KB-click since
 # Tier 0 (mlsetup base syssegs>>12 @0x48b5e, sptalloc va=click<<12 @0xa8bfa/
 # 0xa8c3e) -- but only the ALLOC side was converted.  The FREE side stayed
 # 2KB: sptfree computed the rmfree slot as va>>11 = DOUBLE the click index,
 # so every >4KB kmem_free freed the WRONG arena range (the real slot leaked,
 # a live neighbor's slot was marked free) -> the next sptalloc hands out an
 # OVERLAPPING va -> kernel heap corruption; ttymon's STREAMS open/close churn
 # (allocq etc.) exposed it as a corrupted Km_FreeLists node.  bp_mapin/
 # bp_mapout (dmapio group) were already 4KB and PROVE the arena unit.
 # Coupled set (all remaining sptmap users + the mapout/free PTE walkers):
 # --- kmem_alloc/kmem_free oversize (>4KB) btoc: clicks + accounting ---
 (0x41ffc, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "kmem_alloc:oversize btoc round +2047"),
 (0x42002, b"\x72\x0b", b"\x72\x0c", "kmem_alloc:oversize btoc >>11 (clicks; also availrmem units)"),
 (0x420b6, b"\x72\x0b", b"\x72\x0c", "kmem_alloc:oversize kmeminfo bytes clicks<<11"),
 (0x42464, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "kmem_free:oversize btoc round +2047"),
 (0x4246a, b"\x7c\x0b", b"\x7c\x0c", "kmem_free:oversize shift (one moveq feeds >>11 clicks AND <<11 kmeminfo)"),
 # --- sptfree: THE wrong-slot bug + mapout byte len (one moveq feeds both) ---
 (0xa8c7e, b"\x06\x82\x00\x00\x07\xff", b"\x06\x82\x00\x00\x0f\xff", "sptfree:va->slot round +2047"),
 (0xa8c84, b"\x78\x0b", b"\x78\x0c", "sptfree:shift (va>>11 rmfree slot + clicks<<11 mapout bytes)"),
 (0xa8cbe, b"\x78\x0b", b"\x78\x0c", "sptfree:flag=0 kptbl path click<</>> (dead path, kept consistent)"),
 # --- segkmem_mapout: PTE unload walker (mirror of patched segkmem_alloc) ---
 (0xa8b06, b"\x72\x0b", b"\x72\x0c", "segkmem_mapout:leaf index (va-s_base)>>11 -> >>12"),
 (0xa8b26, b"\xe9\xd3\x10\x15", b"\xe9\xd3\x10\x14", "segkmem_mapout:pfn bfextu {0:21}->{0:20}"),
 (0xa8b88, b"\x06\x82\xff\xff\xf8\x00", b"\x06\x82\xff\xff\xf0\x00", "segkmem_mapout:loop step -2048 -> -4096"),
 (0xa8b96, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segkmem_mapout:flushmmu pages round"),
 (0xa8b9c, b"\x72\x0b", b"\x72\x0c", "segkmem_mapout:flushmmu pages >>11"),
 # --- segkmem_free: the OTHER PTE unload walker (unkseg path; same 5-site mirror) ---
 (0xa87e8, b"\x72\x0b", b"\x72\x0c", "segkmem_free:leaf index (va-s_base)>>11 -> >>12"),
 (0xa8814, b"\xe9\xee\x10\x15", b"\xe9\xee\x10\x14", "segkmem_free:pfn bfextu {0:21}->{0:20}"),
 (0xa888a, b"\x06\x82\xff\xff\xf8\x00", b"\x06\x82\xff\xff\xf0\x00", "segkmem_free:loop step -2048 -> -4096"),
 (0xa8898, b"\x06\x80\x00\x00\x07\xff", b"\x06\x80\x00\x00\x0f\xff", "segkmem_free:flushmmu pages round"),
 (0xa889e, b"\x72\x0b", b"\x72\x0c", "segkmem_free:flushmmu pages >>11"),
 # --- kseg/unkseg: remaining sptmap users (cinit/msginit/RFS; effectively dead
 #     in current config -- cinit passes 0 clicks -- but unpatched they'd map at
 #     click<<11 = a WRONG, sub-arena VA; patched they're correct if ever used).
 #     ksegtbl key (va-syssegs)>>17 needs no change: ptmalloc's 0x3f align makes
 #     kseg VAs 256KB-apart -> key stays unique. ---
 (0xa8db6, b"\x72\x0b", b"\x72\x0c", "kseg:segkmem_alloc va/len clicks<<11 (one moveq, both args)"),
 (0xa8dea, b"\x72\x0b", b"\x72\x0c", "kseg:va = click<<11 -> <<12 (ksegtbl key + bzero + return)"),
 (0xa8e0a, b"\x72\x0b", b"\x72\x0c", "kseg:bzero len clicks<<11"),
 (0xa8e34, b"\x70\x0b", b"\x70\x0c", "unkseg:rmfree slot va>>11 -> >>12"),
 (0xa8e58, b"\x70\x0b", b"\x70\x0c", "unkseg:segkmem_free len clicks<<11"),
 # NOT flipped (audited, symmetric as-is): kmem_allocspool/bpool + kmem_freepool
 # hardcoded 2/8-click pool sizes (pea 2/pea 8/moveq -- alloc AND free use the
 # same constants at the same, now-correct slot => pools are merely 2x oversized
 # maps, ~4KB+16KB waste per pool; flip the whole 8+-site set later if memory
 # matters).  kvm_init's sptalloc caller 0x48e7e already passes 4KB clicks
 # (0x48e64/0x48e6a flipped in Tier 0).  bp_mapin/bp_mapout already 4KB (dmapio).
]
# pea-800 sites DELIBERATELY NOT flipped (triaged 2026-07-03): 0xdbbe/0xdd58/0x20c60/0x20c9c
# (ngeteblk/allocb buffer sizes -- STREAMS/block semantics, not page), 0xee3e/0xee90 (bbmem
# kmem 2KB buffer), 0x3d21e (buf_breakup chunk min -- disk transfer, audit separately),
# 0x48b64 (mlsetup sptmap arena -- known latent, fix with the vm_swap/units pass),
# 0x52238 (checkpage/pageout -- read before touching, pageout barely runs at 16MB),
# 0x599be (main as_map 0x800 for icode/u -- works, p0/p1 layout risk), 0x5c1e2 (pathname
# buffer), 0xb4936/0xb53e0/0xb543e (stock 030 hat_unload/hat_dup -- dead
# code in our build, superseded by hat040/stub).
# NOTE: ppcopy 0xaf230 / pagecopy 0xaf268 pea-800s were ALREADY patched (entries above);
# elfexec auxv AT_PAGESZ 2048->4096 likewise (0xb842c) -- userland saw 4096 all along.

def main():
    buf=bytearray(open(KERNEL,"rb").read())
    sa, so = text_sec(buf)
    done=skip=0
    for vaddr, old, new, name in P:
        assert len(old)==len(new), name
        fo = so + (vaddr - sa)
        cur = bytes(buf[fo:fo+len(old)])
        if cur==new:
            print("  [skip] %-44s @0x%05x already" % (name,vaddr)); skip+=1
        elif cur==old:
            buf[fo:fo+len(new)]=new
            print("  [ok]   %-44s @0x%05x %s->%s" % (name,vaddr,old.hex(),new.hex())); done+=1
        else:
            raise SystemExit("ABORT %s @0x%05x: found %s expected %s" % (name,vaddr,cur.hex(),old.hex()))
    open(KERNEL,"wb").write(buf)
    print("Model B Tier-0: %d patched, %d already -> %s" % (done,skip,KERNEL))

main()
