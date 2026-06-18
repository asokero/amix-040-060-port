| hat040.s -- 68040 port of the binary-only HAT page-table layer.
|
| Phase 3 of the AMIX 68040 port (see prototypes/hat-040-port-worklist.md).
| Each function here is a VERBATIM transcription of the kernel's 030 HAT routine
| with surgical 2KB/8-byte-descriptor -> 4KB/4-byte-descriptor edits.  Linked over
| the kernel via --weaken-symbol (the relink-pstart.sh mechanism that finally made
| pstart040 run): the strong definitions here override the weakened originals AND
| existing callers re-resolve to them.
|
| Assemble:  m68k-cbm-sysv4-gcc -m68040 -c hat040.s -o build/hat040.o
| Validate:  disassemble build/hat040.o and diff vs the original function -- every
|            UNCHANGED instruction must match byte-for-byte; only the documented
|            sites differ.  Then check_relink_relocs.py must print "0 complaints".
|
| ============================================================================
| hat_pteload  (orig 0xb4d64, 710 B) -- the central PTE loader: install one
| mapping (va -> pfn) into the process/kernel page tables, allocating a leaf
| page table via hat_ptalloc if the pointer-table slot is empty.
|
| 030->040 changes (all justified in hat-040-port-worklist.md "worked port spec"):
|   * VA decode 2/13/6 -> 7/7/6:  A=va>>25&0x7F  B=va>>18&0x7F  C=va>>12&0x3F
|   * table descriptor stride *8 -> *4; 8-byte long descriptors -> 4-byte 040 descs
|   * root desc: read 1 long, UDT=desc&3, base=desc&0xFFFFFE00 (no 030 limit field)
|   * ptr  desc: base=desc&0xFFFFFF00; build = `*a3 = pagetable | UDT(2)`
|   * leaf: pfn<<11 -> <<12; PFN extract {0:21} -> {0:20}; status {0,1,5} UNCHANGED
| DEFERRED (TODO): per-leaf cache mode for device maps (prot&8); 040 ptdat@(4)
|   re-packing -- both documented in the worklist.  Boot-critical maps are
|   cacheable RAM (device identity regions handled by pstart040's TTRs).
| ============================================================================

	.text
	.globl	hat_pteload
hat_pteload:
	linkw	%fp,&-56
	moveml	%d2-%d3/%a2-%a4,%sp@-
	movel	%fp@(12),%d2		| d2 = va
	moveal	%fp@(16),%a2		| a2 = pp

| --- A (root) index = (va>>25) & 0x7F   [030: >>30 & 3] ---
	movel	%d2,%d0
	moveq	&25,%d3
	lsrl	%d3,%d0
	moveq	&0x7f,%d3
	andl	%d0,%d3
	movel	%d3,%fp@(-28)		| Aidx

| --- B (pointer) index = (va>>18) & 0x7F   [030: >>17 & 0x1FFF] ---
	movel	%d2,%d0
	moveq	&18,%d3
	lsrl	%d3,%d0
	movel	%d0,%d3
	andil	&0x7f,%d3
	movel	%d3,%fp@(-36)		| Bidx

| --- read 040 root descriptor[Aidx] (one 4-byte long) ---
	moveal	%fp@(8),%a0		| hat
	moveal	%a0@(12),%a0		| seg
	movel	%fp@(-28),%d0
	asll	&2,%d0			| Aidx*4   [030: *8]
	moveal	%a0@(20),%a0		| root table base
	movel	%a0@(0,%d0:l),%fp@(-56)	| Adesc (single long)
	bfextu	%fp@(-53){&6:&2},%d0	| UDT = Adesc & 3
	btst	&1,%d0			| resident? (UDT == 2 or 3 -> bit1 set)
	bne	Lrootok
	pea	Lpemsg0
	pea	3
	jsr	cmn_err
	addqw	&8,%sp
Lrootok:
	movel	%fp@(-56),%d0
	andil	&0xfffffe00,%d0		| Btable base (ptr table, 512-aligned)
	moveal	%d0,%a3
	movel	%fp@(-36),%d0
	asll	&2,%d0			| Bidx*4   [030: *8]
	addal	%d0,%a3			| a3 = &Bdesc
	bfextu	%a3@(3){&6:&2},%d0	| UDT of Bdesc (low 2 bits, unchanged)
	tstl	%d0
	bne	Lbhave			| Bdesc valid -> walk to existing leaf

| --- Bdesc invalid: allocate a leaf page table ---
	tstl	%a2			| pp != 0 ?
	beq	Lballoc0
	addqw	&1,%a2@(2)		| pp hold++
	pea	1
	movel	%fp,%d0
	subql	&4,%d0
	movel	%d0,%sp@-
	jsr	hat_ptalloc		| hat_ptalloc(&ptdat, 1)
	moveal	%a0,%a4			| a4 = new page table
	subqw	&1,%a2@(2)		| pp hold--
	addqw	&8,%sp
	bra	Lbfill
Lballoc0:
	pea	1
	movel	%fp,%d0
	subql	&4,%d0
	movel	%d0,%sp@-
	jsr	hat_ptalloc
	moveal	%a0,%a4
	addqw	&8,%sp
Lbfill:
| ptdat bookkeeping (software state -- kept verbatim; @(4) keeps 030 packing)
	moveal	%fp@(-4),%a0		| ptdat
	moveal	%fp@(8),%a1		| hat
	movel	%a1@(12),%a0@		| ptdat->@(0) = seg
	moveal	%fp@(-4),%a0
	movel	%d2,%d0
	moveq	&17,%d3
	lsrl	%d3,%d0
	movew	%d0,%d0
	movew	%d0,%d3
	lslw	&1,%d3
	movew	%d3,%a0@(4)		| ptdat->@(4) = (va>>17)*2  [030 packing, TODO]
	moveal	%fp@(-4),%a0
	moveb	&1,%a0@(6)
	moveal	%fp@(-4),%a0
	clrb	%a0@(7)
| build the 040 pointer descriptor: *a3 = pagetable | UDT(2 resident)
	movel	%a4,%d0
	oril	&2,%d0
	movel	%d0,%a3@
| leaf address (fresh table): a4 += (C)*4 ,  C = (va>>12) & 0x3F
	movel	%d2,%d0
	moveq	&12,%d3
	lsrl	%d3,%d0
	moveq	&63,%d3
	andl	%d3,%d0
	asll	&2,%d0
	addal	%d0,%a4			| a4 = &leaf
	bra	Lwleaf

| --- Bdesc already valid: walk to the existing leaf ---
Lbhave:
	movel	%d2,%d0
	moveq	&12,%d3
	lsrl	%d3,%d0
	moveq	&63,%d3
	andl	%d3,%d0
	asll	&2,%d0
	moveal	%d0,%a4
	movel	%a3@,%d0		| Bdesc (single long)
	andil	&0xffffff00,%d0		| page table base (256-aligned)
	addal	%d0,%a4			| a4 = &leaf
	tstl	%a4@
	beq	Lfreshleaf		| leaf empty -> fill it

| leaf present: verify the pfn matches
	bfextu	%a4@{&0:&20},%d0		| existing PFN (20 bits)  [030: 21]
	cmpl	%fp@(20),%d0
	beq	Lpfnok
	pea	Lpemsg1
	pea	3
	jsr	cmn_err
	addqw	&8,%sp
Lpfnok:
	moveq	&7,%d3
	andl	%d3,%fp@(24)		| prot &= 7
	moveq	&2,%d0
	andl	%fp@(24),%d0
	tstl	%d0
	beq	Lp_ro
	moveq	&1,%d3
	movel	%d3,%fp@(-44)		| writable -> status 1
	bra	Lp_st
Lp_ro:
	tstl	%fp@(24)
	bne	Lp_rop
	clrl	%fp@(-44)		| prot 0 -> status 0
	bra	Lp_st
Lp_rop:
	moveq	&5,%d3
	movel	%d3,%fp@(-44)		| read-only -> status 5 (page+WP)
Lp_st:
| propagate M/U bits from the existing leaf into the pp struct (positions unchanged)
	tstl	%a2
	beq	Lp_noprop
	moveal	%a2,%a0
	bfextu	%a0@{&6:&1},%d0
	bfextu	%a4@(3){&4:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&6:&1}
	moveal	%a2,%a0
	bfextu	%a0@{&5:&1},%d0
	bfextu	%a4@(3){&3:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&5:&1}
Lp_noprop:
	moveq	&1,%d0
	andl	%fp@(28),%d0		| lock flag?
	tstl	%d0
	beq	Lp_nolock
	moveq	&-24,%d0
	addl	%fp,%d0
	movel	%d0,%sp@-
	movel	%a4,%sp@-
	jsr	hat_pt2ptdat		| hat_pt2ptdat(leaf, &fp@(-24))
	movel	%a0,%fp@(-4)
	movel	%fp@(-4),%d0
	moveal	%d0,%a0
	addqb	&1,%a0@(7)
	addqw	&8,%sp
Lp_nolock:
	movel	%fp@(20),%d0		| pfn
	moveq	&12,%d3
	lsll	%d3,%d0			| pfn<<12   [030: <<11]
	movel	%fp@(-44),%d3
	orl	%d0,%d3
	movel	%d3,%a4@		| *leaf = (pfn<<12) | status
	pea	1
	movel	%d2,%sp@-
	jsr	flushmmu		| flushmmu(va, 1)
	bra	Lepi

| --- fresh leaf inside an existing page table ---
Lfreshleaf:
	moveq	&-24,%d0
	addl	%fp,%d0
	movel	%d0,%sp@-
	movel	%a4,%sp@-
	jsr	hat_pt2ptdat		| hat_pt2ptdat(leaf, &fp@(-24))
	movel	%a0,%fp@(-4)
	movel	%fp@(-4),%d0
	moveal	%d0,%a0
	addqw	&6,%a0
	addqb	&1,%a0@
	addqw	&8,%sp
| fall through to Lwleaf

| --- write the leaf PTE (shared by fresh-table and fresh-in-table paths) ---
Lwleaf:
	moveq	&7,%d3
	andl	%d3,%fp@(24)		| prot &= 7
	moveq	&2,%d0
	andl	%fp@(24),%d0
	tstl	%d0
	beq	Lw_ro
	moveq	&1,%d3
	movel	%d3,%fp@(-44)
	bra	Lw_st
Lw_ro:
	tstl	%fp@(24)
	bne	Lw_rop
	clrl	%fp@(-44)
	bra	Lw_st
Lw_rop:
	moveq	&5,%d3
	movel	%d3,%fp@(-44)
Lw_st:
	movel	%fp@(20),%d0
	moveq	&12,%d3
	lsll	%d3,%d0			| pfn<<12   [030: <<11]
	movel	%fp@(-44),%d3
	orl	%d0,%d3
	movel	%d3,%a4@		| *leaf = (pfn<<12) | status
	moveq	&1,%d0
	andl	%fp@(28),%d0
	tstl	%d0
	beq	Lw_nolock
	movel	%fp@(-4),%d0
	moveal	%d0,%a0
	addqb	&1,%a0@(7)
Lw_nolock:
	tstl	%a2
	beq	Lw_nopp
	movel	%a2@(32),%a4@(256)
	movel	%a4,%a2@(32)
Lw_nopp:
	moveal	%fp@(8),%a0
	movel	%a0@(12),%d0
	moveq	&16,%d3
	addl	%d0,%d3
	moveal	%d3,%a0
	addql	&1,%a0@			| (*(seg+16))++
Lepi:
	moveml	%fp@(-76),%d2-%d3/%a2-%a4
	moveal	%d0,%a0
	unlk	%fp
	rts

	.data
	.even
Lpemsg0:
	.asciz	"hat_pteload: root descriptor not resident"
Lpemsg1:
	.asciz	"hat_pteload: pfn mismatch on existing leaf"
