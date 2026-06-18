| kvm040.s -- 68040 STRUCTURAL override for the static kernel-VM path.
|
| MODEL B (4KB page frame everywhere; the 2KB-click model could not map page_get's
| physically-scattered clicks as 4KB MMU pages -- see worklist).  Under Model B each
| "click" IS a 4KB page, so the scattered-page allocator maps cleanly.  Most Model B
| edits are SAME-SIZE immediate flips done by patch_modelb.py (byte patches, no
| relink).  This file holds ONLY the ONE structural change on the Tier-0 path:
| sysseginit, which must build 4-byte 040 POINTER descriptors into kptr040 instead
| of the 8-byte 030 descriptors it wrote into st_top1 (a size change -> needs a real
| transcription + the globalize+weaken override, not a byte patch).
|
| (segkmem_mapin/segkmem_alloc write 4-byte leaf PTEs on both 030 and 040 -- no
| structural change -- so they are byte-patched in place by patch_modelb.py, not
| overridden here.)
|
| Assemble:  m68k-cbm-sysv4-gcc -m68040 -c kvm040.s -o build/kvm040.o

	.text

| ============================================================================
| sysseginit (orig 0x48ba2, LOCAL t) -- build the kvseg/syssegs (VA 0x40040000,
| 4 MB) page-table mappings and set kptbl = v<<12.  Arg fp@8 = v (4KB-click leaf
| base).  Returns (a0/d0) the click past the leaf area (-> kvm_init's v).
|
| Model B: a 040 pointer entry covers 256 KB = 64 x 4KB pages, so the 4 MB region
| needs 16 entries (loop d1 += 64 clicks while <= 1023; 1024 4KB-clicks = 4 MB).
| Leaf tables are 64-PTE / 256 B, contiguous.  Single 4-byte 040 pointer descriptor
| into kptr040.  (vs Model A this changes: v<<11 -> v<<12, click step 128 -> 64,
| limit 2047 -> 1023, return round 2047/>>11 -> 4095/>>12.)
| ============================================================================
	.globl	sysseginit
sysseginit:
	linkw	%fp,&-8
	moveml	%d2-%d3,%sp@-
	movel	%fp@(8),%d2		| v = 4KB-click leaf base
	| 040 pointer slot for syssegs: &kptr040[(syssegs>>18) - 4096]  (VA decode,
	| independent of click/page size)
	movel	&syssegs,%d0
	moveq	&18,%d3
	lsrl	%d3,%d0
	subil	&4096,%d0
	asll	&2,%d0
	moveal	%d0,%a0
	addal	kptr040,%a0		| a0 = &kptr040[flat]
	movel	%d2,%d0
	moveq	&12,%d3
	asll	%d3,%d0			| d0 = v<<12 = leaf base (kptbl), 4KB clicks
	clrl	%d1			| click counter
Lss_loop:
	movel	%d0,%d3
	oril	&0x02,%d3		| leaf | UDT(2 resident)
	movel	%d3,%a0@
	addil	&256,%d0		| next leaf table (64 PTEs)
	addqw	&4,%a0			| next pointer slot
	addil	&64,%d1			| Model B: 64 4KB-clicks / 256KB pointer entry
	cmpil	&1023,%d1
	ble	Lss_loop		| 16 iterations (4 MB / 256 KB)
	moveq	&12,%d3
	asll	%d3,%d2			| d2 = v<<12
	movel	%d2,kptbl		| kptbl = v<<12 (= seg->s_ptbl)
	addil	&4095,%d0
	lsrl	%d3,%d0			| d0 = end click past the leaf area
	moveml	%fp@(-16),%d2-%d3
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop			| pad .text to a 4-byte multiple (loader copies text+data as one block)
