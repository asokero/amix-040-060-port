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
