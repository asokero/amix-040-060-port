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
]

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
