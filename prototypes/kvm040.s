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

| ============================================================================
| vatosde (orig 0xb74a2, GLOBAL T) -- given a region-1 kernel VA, return the
| address of its SEGMENT descriptor (the entry svirtophys/krnxmemflt inspect for
| the DT/UDT type, then hand to vatopte).  The 030 original walks `kas@(0x14)` ->
| tbl[1].addr (st_top1) -> &st_top1[(va>>17)&0x1fff] (8-byte SDE).
|
| 040: the live tree is root040 -> kptr040 (built by pstart040, filled by
| sysseginit/kvm_init/segkmem_mapin).  kptr040 is a FLAT array of the region-1
| pointer tables, indexed (va>>18)-4096 -- the exact addressing sysseginit/kvm_init
| use -- so the pointer descriptor for va is simply &kptr040[((va>>18)-4096)*4].
| Its low 2 bits are the 040 UDT (0=invalid, 2=resident); svirtophys reads them via
| `bfextu @(3){6:2}` exactly like the 030 DT (both live in byte-3 bits 1:0), so the
| svirtophys DT-switch is format-agnostic -- only this walk + vatopte change.
| ============================================================================
	.globl	vatosde
vatosde:
	linkw	%fp,&0
	movel	%fp@(8),%d0
	moveq	&18,%d1
	lsrl	%d1,%d0			| va>>18
	subil	&4096,%d0		| - 4096 (region-1 base index)
	asll	&2,%d0			| * 4 (long pointer descriptors)
	addl	kptr040,%d0		| + kptr040 base
	moveal	%d0,%a0			| a0 = &kptr040[flat] = 040 pointer descriptor
	unlk	%fp
	rts

| ============================================================================
| vatopte (orig 0xb7540, GLOBAL T) -- given a VA and its segment descriptor (the
| vatosde result), return the address of the leaf PTE.  030 original: leaf base =
| sde@(4) (the +4 addr field of the 8-byte SDE), index (va>>11)&0x3f, *4.
| 040: the descriptor is a single long `leaf|UDT`; leaf base = *sde & 0xffffff00
| (256 B / 64-entry 4KB-page leaf tables), index (va>>12)&0x3f, *4.  svirtophys then
| reads *PTE and assembles phys with the 4KB page mask (Model B patch in svirtophys).
| ============================================================================
	.globl	vatopte
vatopte:
	linkw	%fp,&0
	moveal	%fp@(12),%a0		| a0 = pointer descriptor address (from vatosde)
	movel	%a0@,%d0
	andil	&0xffffff00,%d0		| d0 = leaf page-table base
	movel	%fp@(8),%d1
	lsrl	&8,%d1
	lsrl	&4,%d1			| d1 = va>>12
	andil	&0x3f,%d1		| & 0x3f (64-entry 4KB-page leaf)
	asll	&2,%d1			| * 4
	addl	%d1,%d0			| d0 = &PTE
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop			| pad .text to a 4-byte multiple (loader copies text+data as one block)

