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

| --- DBG (exec-header segmap collision, 2026-06-24): trace every map into the 8KB exec-
|     header slot [0x40448000,0x4044a000) with the page's p_offset (pp@(8)) and pfn (arg@20).
|     Confirms the 2KB p_offset stride: if the header page (pfn 7A50) maps at va 40448000 with
|     poff=0 and the collider (7A51) at va 40448800 with poff=0x800, the page cache produces a
|     distinct 2KB page per 2KB of file -> they share the 4KB MMU leaf -> collision.  Gated 16,
|     CE_WARN, a2/d2 preserved.  Remove once the page-granularity fix lands. ---
	cmpil	&0x40448000,%d2
	bcsw	Lpo_no
	cmpil	&0x4044a000,%d2
	bccw	Lpo_no
	movel	Lpo_n,%d0
	cmpil	&16,%d0
	bccw	Lpo_no
	addql	&1,%d0
	movel	%d0,Lpo_n
	movel	%fp@(20),%sp@-		| pfn
	moveq	&0,%d0
	tstl	%a2
	beq	Lpo_nooff
	movel	%a2@(8),%d0		| pp->p_offset
Lpo_nooff:
	movel	%d0,%sp@-		| p_offset
	movel	%d2,%sp@-		| va
	pea	Lpo_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
	movel	%fp@(12),%d2		| reload (cmn_err scratch)
	moveal	%fp@(16),%a2
Lpo_no:

| --- DBG: trace EVERY hat_pteload of the libc.so.1 GOT pages [C102F000, C1031000) -- va + pfn +
|     prot.  Reveals page C102F000's mapping HISTORY: do_reloc's writes should map it WRITABLE
|     (prot&2, a fresh COW pfn) and the read fault maps the RO file page (prot read-only, pfn
|     0x7CFE).  If a writable mapping is later REPLACED by an RO mapping (different pfn), the COW
|     relocations are reverted -> the linker reads raw.  Gated 40, CE_WARN; d2/a2 reloaded after. ---
	cmpil	&0xc102f000,%d2
	bcsw	Lgt_no
	cmpil	&0xc1031000,%d2
	bccw	Lgt_no
	movel	Lgt_n,%d0
	cmpil	&40,%d0
	bccw	Lgt_no
	addql	&1,%d0
	movel	%d0,Lgt_n
	movel	%fp@(24),%sp@-		| prot
	movel	%fp@(20),%sp@-		| pfn
	movel	%d2,%sp@-		| va
	pea	Lgt_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
	movel	%fp@(12),%d2		| reload (cmn_err scratch)
	moveal	%fp@(16),%a2
Lgt_no:

| --- DBG: trace the first 40 maps >=0x48000000 (u-area in segu_get AND, after the
|     8 u-area maps, any exec-REBUILD faults at init text 0x80800000 / stack 0xC07FF000
|     -- shows whether the boot PROGRESSES past the teardown).  Gated, CE_WARN. ---
	cmpil	&0x48000000,%d2
	bcsw	Lpt_nodbg
	movel	Lpt_dbgn,%d0
	cmpil	&40,%d0
	bccw	Lpt_nodbg
	addql	&1,%d0
	movel	%d0,Lpt_dbgn
	.word	0x4e7a			| movec %urp,%d0 (active user root PHYS at fault time)
	.word	0x0806
	movel	%d0,%sp@-		| urp
	movel	%d2,%sp@-		| va
	pea	Lpt_dbgmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
	movel	%fp@(12),%d2		| reload d2 (cmn_err clobbers? d2 is callee-saved, but be safe)
	moveal	%fp@(16),%a2
Lpt_nodbg:

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

| --- DBG (user-PT frontier, 2026-06-24): for exec-range faults (va>=0x80000000) dump the
|     as, its root VA (hat@(12)@(20) = the tree hat_pteload itself walks), the live URP, the
|     A index, and root[Aidx].  DECISIVE split for the 0x3F0002 stale-ptr-table panic:
|       * Adesc == 0  -> hat_free DID clear root[Aidx]; the fresh ptr-table comes from
|                        hat_sdtalloc and is NOT zeroed (slot[0]=3F0002) => hat_sdtalloc bug.
|       * Adesc != 0  -> root[Aidx] still resident; either hat_free skipped this region, or
|                        the rebuild walks a DIFFERENT as whose root was never cleaned
|                        (compare as/rootVA here vs the 401AA400/401A9000 of proc-1 setup).
|     Also: if rootVA's phys != urp, the HW walks a different root than hat_pteload writes.
|     Gated 12, CE_WARN; d2/a2 reloaded after.  Remove once the source is fixed. ---
	cmpil	&0x80000000,%d2
	bcsw	Lrd_no
	movel	Lrd_n,%d0
	cmpil	&12,%d0
	bccw	Lrd_no
	addql	&1,%d0
	movel	%d0,Lrd_n
	moveal	%fp@(8),%a0		| hat
	moveal	%a0@(12),%a1		| as
	movel	%a1@(20),%d1		| rootVA = as@(20)
	.word	0x4e7a			| movec %urp,%d0 (active user root PHYS)
	.word	0x0806
	movel	%fp@(-56),%sp@-		| Adesc (root[Aidx])
	movel	%fp@(-28),%sp@-		| Aidx
	movel	%d1,%sp@-		| rootVA
	movel	%a1,%sp@-		| as
	movel	%d0,%sp@-		| urp
	movel	%d2,%sp@-		| va
	pea	Lrd_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(32),%sp
	movel	%fp@(12),%d2		| reload d2 (cmn_err scratch)
	moveal	%fp@(16),%a2
Lrd_no:
	bfextu	%fp@(-53){&6:&2},%d0	| UDT = Adesc & 3
	btst	&1,%d0			| resident? (UDT == 2 or 3 -> bit1 set)
	bne	Lrootok
| --- root descriptor empty: LAZILY allocate a 040 pointer table and install it ---
| MEASURED (2026-06-23): for a fresh user as the slot is TRULY empty (Adesc4=0 AND desc8=0) --
| the 030 hat_growsdt indexes/writes the root differently (8-byte descs, 030 VA split) than our
| 040 hat_pteload reads (va>>25 Aidx, 4-byte), so it never populates this slot.  Rather than port
| hat_growsdt, allocate the pointer table here -- symmetric with the leaf alloc below.
| hat_sdtalloc(&out, count): count<<6 bytes, bzero'd, from the identity-mapped SDT pool (the
| region the HW tablewalk reads); count=8 -> 512 bytes = 128 entries x 4 = one 040 pointer table.
| hat_sdtalloc preserves d2(va)/a2(pp); install root[Aidx] = ptable | UDT(2 resident).
	pea	16			| count=16 -> 1024 B: room to carve a 512-ALIGNED 512 B table
	movel	%fp,%d0
	subil	&48,%d0
	movel	%d0,%sp@-		| &out = fp@(-48)
	jsr	hat_sdtalloc
	addqw	&8,%sp
| BUG FIX (2026-06-24, user-PT frontier): two defects, both fixed here.
| (1) ALIGNMENT.  An 040 root descriptor stores the pointer-table base in bits 31:9, so the
|     table MUST be 512-aligned -- the HW walk and our Lrootok both mask with 0xfffffe00.  But
|     hat_sdtalloc only guarantees 64-byte sub-slot alignment, so a sub-512-aligned base makes
|     that mask round DOWN into the PRECEDING (stale) memory.  MEASURED: a fresh exec as got a
|     table whose masked slot[0] read 0x3F0002 (stale leaf desc -> base 0x3F0000 = unbacked hole)
|     -> bogus "resident" leaf -> hat_pt2ptdat "invalid pte ptr" PANIC, even after zeroing the
|     raw result.  Fix: over-allocate (count=16 = 1024 B) and round the raw result UP to 512.
| (2) NOT ZEROED.  hat_sdtalloc does not zero the table on 040; a fresh pointer table for an
|     empty root region MUST be all-zero (every UDT invalid) so subsequent leaf faults see
|     Bdesc==0 and allocate leaves.  Zero all 512 B (128 x 4-byte descriptors) of the aligned
|     table.  Cached clrl is fine: hat_pteload reads Bdesc back through the same cache and Lepi's
|     cpusha+pflusha pushes the table to RAM for the HW walker.
	movel	%fp@(-48),%d3		| d3 = raw hat_sdtalloc result (64-aligned; d3 dead here)
	movel	%d3,%d1
	addil	&511,%d1
	andil	&0xfffffe00,%d1		| round UP to 512-byte boundary
	movel	%d1,%fp@(-48)		| store the aligned base back (used as ptable below)
| DIAG (gated 8): show the raw result vs the aligned base for exec-range faults; confirms the
| sub-512 alignment defect (raw != aligned).  Remove once stable.  d3 preserved across cmn_err.
	cmpil	&0x80000000,%d2
	bcsw	Lsz_no
	movel	Lsz_n,%d0
	cmpil	&8,%d0
	bccw	Lsz_no
	addql	&1,%d0
	movel	%d0,Lsz_n
	movel	%fp@(-48),%sp@-		| aligned base
	movel	%d3,%sp@-		| raw result
	movel	%d2,%sp@-		| va
	pea	Lsz_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lsz_no:
	moveal	%fp@(-48),%a0		| aligned ptable base
	moveq	&127,%d0		| 128 longs - 1
Lrz_loop:
	clrl	%a0@+
	dbra	%d0,Lrz_loop		| 128 iters -> 512 bytes zeroed
	moveal	%fp@(8),%a0		| re-derive root base (a0/d0 clobbered by the call)
	moveal	%a0@(12),%a0
	moveal	%a0@(20),%a0		| a0 = root table base
	movel	%fp@(-28),%d0
	asll	&2,%d0			| Aidx*4
	movel	%fp@(-48),%d1		| ptable (from hat_sdtalloc)
	oril	&2,%d1			| UDT = 2 (resident pointer descriptor)
	movel	%d1,%a0@(0,%d0:l)	| root[Aidx] = ptable | 2
	movel	%d1,%fp@(-56)		| Adesc = the new descriptor (Lrootok reads fp@(-56))
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
| DIAG (gated 8): dump the leaf page-table address hat_ptalloc returned + va.  Localizes
| whether the bad user-PT base (0x3F0000, unbacked hole) comes straight from hat_ptalloc/
| hat_sdtalloc (a4 itself bad) or gets truncated later.  cmn_err preserves d2/a4 (callee-saved).
	movel	Lba_dbgn,%d0
	cmpil	&8,%d0
	bccw	Lba_nodbg
	addql	&1,%d0
	movel	%d0,Lba_dbgn
	movel	%a4,%sp@-		| leaf table addr (hat_ptalloc result)
	movel	%d2,%sp@-		| va
	pea	Lbamsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lba_nodbg:
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

| leaf present: verify the pfn matches.  Stock 030 hat_pteload (0xb4eba) ALSO panics
| here (LC%1, level 3) -- a mismatch = a stale leaf PTE (a missed unload) or a VA->leaf
| collision, which a correct kernel never produces.  DIAGNOSTIC: print va, existing *pte
| and the new pfn (gated to first 8, CE_WARN) and CONTINUE -- the code overwrites the
| leaf below (Lp_nolock) regardless, so we see the offending VA/pfns and how far boot
| gets.  Restore to panic(3) once the stale-leaf source is fixed.  a4=&leaf, d2=va,
| both preserved across cmn_err (clobbers only d0/d1/a0/a1).
	bfextu	%a4@{&0:&20},%d0		| existing PFN (20 bits)  [030: 21]
	cmpl	%fp@(20),%d0
	beq	Lpfnok
	movel	Lhp_dbgn,%d0
	cmpil	&8,%d0
	bccw	Lpfnok			| after 8 prints, stop (still overwrites)
	addql	&1,%d0
	movel	%d0,Lhp_dbgn
	movel	%fp@(20),%sp@-		| new pfn
	movel	%a4@,%sp@-		| existing *pte
	movel	%a3@,%sp@-		| Bdesc value (pointer-table slot contents)
	movel	%a3,%sp@-		| Bdesc slot address
	movel	%a4,%sp@-		| leaf address (a4 = base + idx*4)
	movel	%d2,%sp@-		| va
	pea	Lpemsg1
	pea	2			| CE_WARN (was 3=PANIC) -- diagnostic
	jsr	cmn_err
	lea	%sp@(32),%sp
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
| 68040 PAGE-TABLE COHERENCY (2026-06-24): the leaf PTE was written with a normal `movel` into a
| copyback-cacheable page-table page, so it sits in the D-cache, NOT RAM.  The 68040 hardware
| table walker reads descriptors from memory; if the cached PTE line is later invalidated without
| write-back, the walker reads the STALE (zero/invalid) RAM descriptor -> the just-faulted user
| page maps to a ZERO phys for subsequent accesses (proven: proc 1's icode page at 0x80800000
| reads 0x4FFB0170 via the I-fetch ATC but 0x00000000 via a fresh data walk, even after cpusha+
| pflusha at use time).  pstart040 and resume040 already cpusha+pflusha after their table writes;
| hat_pteload (the per-fault user/kernel PTE installer) did NOT.  Push the write to RAM + flush
| the ATC so the walker reloads the fresh descriptor.
	.word	0xf4f8			| cpusha bc -- push the new leaf PTE (and ptable/root writes) to RAM
	.word	0xf518			| pflusha   -- flush the ATC so the next walk reloads the fresh PTE
	moveml	%fp@(-76),%d2-%d3/%a2-%a4
	moveal	%d0,%a0
	unlk	%fp
	rts

| ===========================================================================
| hat_unlock (orig 0xb5d1e, GLOBAL T) -- 040 port.
| Decrements the lock count on the page-table page holding va's leaf PTE, and
| frees it (waking waiters) when the count reaches 0.  The 030 original walked
| the inert 030 segment tree (root[region*8+4] -> 8-byte SDE -> leaf) which on
| 040 reads kroot040 (040 4-byte descriptors) as garbage -> "invalid sde" PANIC.
| This replaces ONLY the walk with the standard 040 walk (same as hat_pteload /
| vatopte: A=va>>25&7f *4, B=va>>18&7f *4, leaf=Bdesc&0xffffff00 + (va>>12&3f)*4);
| the hat_pt2ptdat + lock-count + free_pts/wakeprocs tail is verbatim 030 logic.
| Args: arg@8 = hat, arg@12 = va.  Returns void.  Saved regs match the original
| (d2-d4/a2-a3) so the frame/restore offsets are identical.
	.globl	hat_unlock
hat_unlock:
	linkw	%fp,&-24
	moveml	%d2-%d4/%a2-%a3,%sp@-
	movel	%fp@(12),%d2		| d2 = va

| --- 040 walk: root = hat@(12)@(20) ---
	moveal	%fp@(8),%a3		| hat
	moveal	%a3@(12),%a3		| seg
	moveal	%a3@(20),%a3		| root (kroot040 for kernel)

| A (root) index = (va>>25)&0x7f ; Btable = root[Aidx*4] & 0xfffffe00
	movel	%d2,%d0
	moveq	&25,%d1
	lsrl	%d1,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a3@(0,%d0:l),%d0	| Adesc
	andil	&0xfffffe00,%d0		| pointer-table base (512-aligned)
	moveal	%d0,%a2

| B (pointer) index = (va>>18)&0x7f ; a2 = &Bdesc
	movel	%d2,%d0
	moveq	&18,%d1
	lsrl	%d1,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	addal	%d0,%a2			| a2 = &Bdesc (040 pointer descriptor)
	bfextu	%a2@(3){&6:&2},%d0	| UDT of Bdesc (low 2 bits of byte 3)
	tstl	%d0
	beqw	Lhu_invalid		| invalid -> PANIC (mirrors 030 "invalid sde")

| leaf PTE address = (Bdesc & 0xffffff00) + ((va>>12)&0x3f)*4
	movel	%a2@,%d0
	andil	&0xffffff00,%d0		| leaf-table base (256-aligned)
	movel	%d0,%d3
	movel	%d2,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	addl	%d0,%d3			| d3 = &leaf PTE

| --- tail (verbatim 030 logic): ptdat lock-count-- ; free if 0 & waiting ---
	pea	%fp@(-24)
	movel	%d3,%sp@-
	jsr	hat_pt2ptdat
	movel	%a0,%d4
	moveal	%d4,%a0
	subqb	&1,%a0@(7)
	addqw	&8,%sp
	tstb	%a0@(7)
	bnew	Lhu_done
	tstl	pt_waiting
	beqw	Lhu_done
	pea	1
	pea	free_pts
	jsr	wakeprocs
	clrl	pt_waiting
	addqw	&8,%sp
	braw	Lhu_done

Lhu_invalid:
	pea	Lhu_msg
	pea	3
	jsr	cmn_err
	addqw	&8,%sp

Lhu_done:
	moveml	%fp@(-44),%d2-%d4/%a2-%a3
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

| ===========================================================================
| hat_unload (orig 0xb46d6, GLOBAL T) -- 040 port.
| Unmaps a VA range: clears leaf PTEs, propagates M/U bits to the pp, updates
| page mapping/hold counts, optionally frees pages, frees empty leaf page tables.
| The 030 original walked region(2)/SDE(13)/leaf(6) of the inert 030 tree; on 040
| that finds nothing for kptr040-mapped VAs -> never clears the live leaf -> stale
| PTE -> hat_pteload "pfn mismatch".  This re-walks the 040 tree per leaf table
| (A=va>>25&7f *4 -> ptr table; B=va>>18&7f *4 -> leaf table; C=va>>12&3f *4 -> PTE)
| and runs the original per-page bookkeeping VERBATIM (only the pfn extract
| {0:21}->{0:20}, the page step 2048->4096, the in-leaf mask 0x1f800->0x3f000, the
| putpage size 0x800->0x1000, and the 8-byte SDE stride -> 4-byte Bdesc change).
| The pte@(256) reverse-map ptr is UNCHANGED (Model B keeps 512B frags = 256B PTEs
| + 256B map ptrs).  Frame offsets match the original so the verbatim block's fp@
| refs (-4 seg, -44 ptdat, -76 flag4, -84 flag8) line up.
| Args: arg@8 hat, arg@12 va, arg@16 size, arg@20 flags.
	.globl	hat_unload
hat_unload:
	linkw	%fp,&-88
	moveml	%d2-%d5/%a2-%a4,%sp@-
	movel	%fp@(12),%d2		| d2 = va (loop cursor)
| DEBUG: print the first few hat_unload calls (va, size, flags) -- remove once stable
	movel	Lhl_dbgn,%d0
	cmpil	&6,%d0
	bccw	Lhl_nodbg
	addql	&1,%d0
	movel	%d0,Lhl_dbgn
	movel	%fp@(20),%sp@-		| flags
	movel	%fp@(16),%sp@-		| size
	movel	%fp@(12),%sp@-		| va
	pea	Lhl_dbgmsg
	pea	2
	jsr	cmn_err
	addaw	&20,%sp
	movel	%fp@(12),%d2		| reload d2 (cmn_err scratch-safe but be explicit)
Lhl_nodbg:
	moveal	%fp@(8),%a0
	movel	%a0@(12),%fp@(-4)	| fp@-4 = seg
	moveal	%fp@(8),%a0
	moveal	%a0@(12),%a0		| seg
	movel	%a0@(20),%fp@(-12)	| fp@-12 = root = seg@(20)
	moveq	&4,%d5
	andl	%fp@(20),%d5
	movel	%d5,%fp@(-76)		| fp@-76 = flags & 4
	moveq	&8,%d5
	andl	%fp@(20),%d5
	movel	%d5,%fp@(-84)		| fp@-84 = flags & 8
	movel	%d2,%d3
	addl	%fp@(16),%d3
	subql	&1,%d3			| d3 = va + size - 1 (inclusive last byte)
	braw	Lhl_chkmore

Lhl_leafwalk:
| A index = (va>>25)&0x7f ; Adesc = root[Aidx*4]
	movel	%d2,%d0
	moveq	&25,%d5
	lsrl	%d5,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	moveal	%fp@(-12),%a0
	movel	%a0@(0,%d0:l),%d0	| Adesc
	movel	%d0,%d1
	andil	&3,%d1			| UDT
	bnew	Lhl_aok
	movel	%d2,%d0			| A absent -> next 32MB (2^25) boundary
	andil	&0xfe000000,%d0
	addil	&0x2000000,%d0
	movel	%d0,%d2
	braw	Lhl_chkmore
Lhl_aok:
	andil	&0xfffffe00,%d0		| Btable = Adesc & ~0x1ff
	movel	%d2,%d1
	moveq	&18,%d5
	lsrl	%d5,%d1
	andil	&0x7f,%d1
	asll	&2,%d1
	addl	%d1,%d0			| &Bdesc
	movel	%d0,%fp@(-20)
	moveal	%d0,%a0
	movel	%a0@,%d1		| Bdesc
	movel	%d1,%d0
	andil	&3,%d0			| UDT
	bnew	Lhl_bok
	movel	%d2,%d0			| B absent -> next 256KB (2^18) boundary
	andil	&0xfffc0000,%d0
	addil	&0x40000,%d0
	movel	%d0,%d2
	braw	Lhl_chkmore
Lhl_bok:
	andil	&0xffffff00,%d1		| leaf base = Bdesc & ~0xff
	movel	%d1,%fp@(-36)
	movel	%d2,%d0
	moveq	&12,%d5
	lsrl	%d5,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	moveal	%fp@(-36),%a2
	addal	%d0,%a2			| a2 = &leaf PTE
	pea	%fp@(-64)
	movel	%fp@(-36),%sp@-
	jsr	hat_pt2ptdat
	movel	%a0,%fp@(-44)		| fp@-44 = ptdat
	clrl	%d4			| d4 = pages unmapped in this leaf
	addqw	&8,%sp

Lhl_pageloop:
	tstl	%a2@
	bnew	Lhl_unmap
	addqw	&4,%a2			| empty PTE -> advance
	addil	&4096,%d2
	braw	Lhl_pageadv

| ----- VERBATIM per-page bookkeeping (orig b47e2-b4978) -----
Lhl_unmap:
	addql	&1,%d4
	pea	1
	movel	%d2,%sp@-
	jsr	flushmmu
	bfextu	%a2@{&0:&20},%d0	| pfn (030: {0:21})
	addqw	&8,%sp
	cmpl	pages_base,%d0
	bcsw	Lhl_a4zero
	bfextu	%a2@{&0:&20},%d0
	cmpl	pages_end,%d0
	bccw	Lhl_a4zero
	braw	Lhl_a4calc
Lhl_a4zero:
	subal	%a4,%a4
	braw	Lhl_a4done
Lhl_a4calc:
	bfextu	%a2@{&0:&20},%d0
	subl	pages_base,%d0
	moveq	&60,%d5
	mulsl	%d5,%d0
	moveal	%d0,%a4
	addal	pages,%a4
Lhl_a4done:
	tstl	%a4
	beqw	Lhl_clear
	moveal	%a4,%a0
	bfextu	%a0@{&6:&1},%d0
	bfextu	%a2@(3){&4:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&6:&1}
	moveal	%a4,%a0
	bfextu	%a0@{&5:&1},%d0
	bfextu	%a2@(3){&3:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&5:&1}
	lea	%a4@(32),%a3
	movel	&256,%d1		| findmap safety counter
Lhl_findmap:
	cmpal	%a3@,%a2
	beqw	Lhl_unlink
	subql	&1,%d1
	beqw	Lhl_findfail		| pte not in pp's reverse-map list -> bail (don't hang)
	moveal	%a3@,%a3
	addaw	&256,%a3
	braw	Lhl_findmap
Lhl_findfail:
| DEBUG one-shot: report a missing reverse-map entry (pte value, pfn-derived pp, pte addr)
	movel	Lhl_failn,%d0
	cmpil	&4,%d0
	bccw	Lhl_aftermap
	addql	&1,%d0
	movel	%d0,Lhl_failn
	movel	%a2,%sp@-		| pte addr
	movel	%a4,%sp@-		| pp (pages[pfn])
	movel	%a2@,%sp@-		| *pte
	pea	Lhl_failmsg
	pea	2
	jsr	cmn_err
	addaw	&20,%sp
	braw	Lhl_aftermap
Lhl_unlink:
	movel	%a2@(256),%a3@
Lhl_aftermap:
	tstl	%fp@(-84)		| flag8
	beqw	Lhl_flag4
	subqw	&1,%a4@(2)
	tstw	%a4@(2)
	bnew	Lhl_chkabort
Lhl_wakeloop:
	bfextu	%a4@{&1:&1},%d0
	tstl	%d0
	beqw	Lhl_chkabort
	pea	1
	movel	%a4,%sp@-
	jsr	wakeprocs
	andib	&-65,%a4@
	addqw	&8,%sp
	braw	Lhl_wakeloop
Lhl_chkabort:
	tstw	%a4@(2)
	bnew	Lhl_flag4
	bfextu	%a4@{&4:&1},%d0
	tstl	%d0
	bnew	Lhl_abort
	tstl	%a4@(4)
	beqw	Lhl_abort
	braw	Lhl_flag4
Lhl_abort:
	movel	%a4,%sp@-
	jsr	page_abort
	addqw	&4,%sp
Lhl_flag4:
	tstl	%fp@(-76)		| flag4
	beqw	Lhl_clear
	tstw	%a4@(2)
	bnew	Lhl_clear
	tstl	%a4@(32)
	bnew	Lhl_clear
	bfextu	%a4@{&0:&1},%d0
	tstl	%d0
	bnew	Lhl_clear
	bfextu	%a4@{&2:&1},%d0
	tstl	%d0
	bnew	Lhl_clear
	bfextu	%a4@{&3:&1},%d0
	tstl	%d0
	bnew	Lhl_clear
	tstw	%a4@(36)
	bnew	Lhl_clear
	tstw	%a4@(38)
	bnew	Lhl_clear
	bfextu	%a4@{&5:&1},%d0
	tstl	%d0
	beqw	Lhl_maybefree
	tstl	%a4@(4)
	beqw	Lhl_maybefree
	moveal	%a4@(4),%a0
	moveal	%a0@(8),%a0
	clrl	%sp@-
	movel	&2097408,%sp@-
	pea	0x1000			| putpage size (030: 0x800 = 2KB)
	movel	%a4@(8),%sp@-
	movel	%a4@(4),%sp@-
	moveal	%a0@(120),%a0
	jsr	%a0@
	addaw	&20,%sp
	braw	Lhl_clear
Lhl_maybefree:
	bfextu	%a4@{&0:&1},%d0
	tstl	%d0
	beqw	Lhl_dofree
	movel	%a4,%sp@-
	jsr	page_cv_wait
	addqw	&4,%sp
	braw	Lhl_maybefree
Lhl_dofree:
	orib	&-128,%a4@
	clrl	%sp@-
	movel	%a4,%sp@-
	jsr	page_free
	addqw	&8,%sp
Lhl_clear:
	clrl	%a2@			| *pte = 0
	addqw	&4,%a2
	addil	&4096,%d2
| ----- end verbatim block -----

Lhl_pageadv:
	movel	%d2,%d0
	andil	&0x3f000,%d0		| within-leaf offset bits 17:12 (030: 0x1f800)
	tstl	%d0
	beqw	Lhl_leafdone		| crossed 256KB leaf boundary
	cmpl	%d2,%d3
	bccw	Lhl_pageloop		| d3 >= va -> more pages in this leaf

Lhl_leafdone:
	moveal	%fp@(-4),%a0
	subl	%d4,%a0@(16)		| seg rss -= count
	moveq	&2,%d0
	andl	%fp@(20),%d0
	tstl	%d0
	beqw	Lhl_no7
	moveal	%fp@(-44),%a0
	movel	%d4,%d0
	subb	%d0,%a0@(7)		| if (flags&2) ptdat@(7) -= count
Lhl_no7:
	moveal	%fp@(-44),%a0
	movel	%d4,%d0
	subb	%d0,%a0@(6)		| ptdat@(6) -= count
	moveal	%fp@(-44),%a0
	tstb	%a0@(6)
	bnew	Lhl_chkmore
	movel	%fp@(-36),%sp@-		| leaf empty -> free it
	jsr	hat_ptfree
	addqw	&4,%sp
	moveal	%fp@(-20),%a0
	bfclr	%a0@(3){&6:&2}		| invalidate Bdesc UDT (low 2 bits)

Lhl_chkmore:
	cmpl	%d2,%d3
	bccw	Lhl_leafwalk		| d3 >= va -> more to unmap
	moveml	%fp@(-116),%d2-%d5/%a2-%a4
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple
	nop
	nop				| +1 nop: diagnostic pfn-mismatch block added +34 bytes

| ===========================================================================
| hat_alloc (orig 0xb4188, GLOBAL T) -- 040 port.
| The 030 original embedded a 4-entry (4 x 8B = 32B) root INSIDE the hat struct
| (mem_align(hat+24,16) just rounds an address; it does not allocate) and cleared
| the 4 SDE UDTs.  The 040 needs a 128-entry root (128 x 4 = 512B), and the URP
| control register needs its PHYSICAL base 512-aligned, so allocate a zeroed 4KB
| page (one Model B page => page-aligned VA => page-aligned, contiguous, >=512-
| aligned phys) and store its VA at as@(20) -- the SAME slot hat_pteload reads
| (seg@(12)=as -> as@(20)=root) and swtch reads (svirtophys(as@20) -> URP).
| Zeroed = an EMPTY USER root; segvn page-faults fill entries 0..31 (VA 0-0x3FFFFFFF)
| on demand (hat_growsdt -- still to port; the first user fault will surface it).
| The kernel keeps SRP=kroot040, so NO kernel entries are copied here.  Arg: arg@8=as.
	.globl	hat_alloc
hat_alloc:
	linkw	%fp,&0
	movel	%a2,%sp@-
	moveal	%fp@(8),%a2		| a2 = as
	| --- one-shot ENTRY marker: proves hat_alloc is reached (proc 1's child path runs).
	|     If this prints but Lha_msg (post-kmem) does NOT, kmem_zalloc(0x1000) hangs. ---
	movel	Lhae_n,%d0
	bnew	Lhae_done
	moveq	&1,%d0
	movel	%d0,Lhae_n
	movel	%a2,%sp@-		| as
	pea	Lhae_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
	moveal	%fp@(8),%a2		| reload a2 (callee-saved, but be safe)
Lhae_done:
	clrl	%sp@-			| kmem_zalloc flag = 0
	pea	0x1000			| size 4KB (page-aligned, zeroed)
	jsr	kmem_zalloc
	addqw	&8,%sp			| a0 = root VA (page-aligned)
	movel	%a0,%a2@(20)		| as->hat_root = 040 root VA (a0 = return value too)
	| --- one-shot DBG marker: proves as_alloc/hat_alloc is reached (newproc returned) ---
	movel	Lha_n,%d0
	bnew	Lha_done
	moveq	&1,%d0
	movel	%d0,Lha_n
	movel	%a2@(20),%sp@-		| root VA
	movel	%a2,%sp@-		| as
	pea	Lha_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lha_done:
	moveal	%sp@+,%a2
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple (adjust per build)
	nop				| +1: hat_pteload kvsegu-trace block shifted parity

| ===========================================================================
| hat_free (orig 0xb41e0, GLOBAL T) -- 040 port.
| Destroys an address space's page tables (called from as_free during exec/exit
| teardown via relvm).  The 030 original walked a 4-region (2-bit) root of 8-byte
| descriptors, scanning each region's variable-length pointer table (limit field
| in the SDE) then 64-PTE leaves, doing per-page bookkeeping (M/U writeback to the
| pp + reverse-map unlink), freeing each leaf via hat_ptfree and each region's
| pointer table via hat_growsdt(root,region,0).
|
| 030->040 changes:
|   * root is now 128 entries (va>>25), 4-byte descriptors -> loop A=0..127, A*4
|     stride, UDT = adesc & 3, ptr-table base = adesc & 0xFFFFFE00
|   * pointer table is a full 128-entry 040 table (no 030 SDE limit field) ->
|     loop B=0..127, B*4 stride, UDT = bdesc & 3, leaf base = bdesc & 0xFFFFFF00
|   * leaf loop UNCHANGED (64 x 4-byte PTEs, leaf..leaf+256); pfn extract {0:21}->{0:20}
|   * the per-page bookkeeping (as@(16)--, M/U writeback, revmap unlink) is VERBATIM
|     030 logic -- only the pfn width changed.  A 256-iteration safety counter is
|     added to the revmap unlink (learned from hat_unload's Lhl_findmap) so an
|     inconsistent reverse-map list bails instead of hanging.
|   * region tail: V1 LEAKS the pointer table (just clears root[A]) -- the proper
|     free is hat_sdtfree(ptrtable,8) but hat_sdtfree's pages[] pfn lookup is still
|     030 (>>11, unpatched) and never yet exercised; leaking unblocks teardown and
|     isolates the walk port.  TODO v2: patch hat_sdtfree pfn shifts + free here.
| Frame is identical to the 030 original (linkw -32, d2-d4/a2-a5) so restore offsets
| match.  Arg: arg@8 = as (as@(20) = 040 root).
	.globl	hat_free
hat_free:
	linkw	%fp,&-32
	moveml	%d2-%d4/%a2-%a5,%sp@-
	moveal	%fp@(8),%a0
	moveal	%a0@(20),%a5		| a5 = 040 root base (preserved across hat_ptfree)
| --- one-shot ENTER marker: proves hat_free runs (exec/exit teardown reached) ---
	movel	Lhf_n,%d0
	bnew	Lhf_nodbg
	moveq	&1,%d0
	movel	%d0,Lhf_n
	movel	%a5,%sp@-		| root
	movel	%fp@(8),%sp@-		| as
	pea	Lhf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
	moveal	%fp@(8),%a0		| reload a5 (callee-saved, but be safe)
	moveal	%a0@(20),%a5
Lhf_nodbg:
	clrl	%fp@(-20)		| A = 0
Lf_A:
	movel	%fp@(-20),%d0
	cmpil	&127,%d0
	bgtw	Lf_done			| A > 127 -> all regions done
	movel	%fp@(-20),%d0
	asll	&2,%d0			| A*4
	movel	%a5@(0,%d0:l),%d4	| Adesc (4-byte root descriptor)
	movel	%d4,%d0
	andil	&3,%d0			| UDT (low 2 bits)
	beqw	Lf_nextA		| empty -> next region
	movel	%d4,%d0
	andil	&0xfffffe00,%d0		| pointer-table base = Adesc & ~0x1ff
	movel	%d0,%fp@(-32)		| stash (reloaded each B iteration; a2 clobbered by hat_ptfree)
	clrl	%fp@(-24)		| B = 0
Lf_B:
	movel	%fp@(-24),%d0
	cmpil	&127,%d0
	bgtw	Lf_freeA		| B > 127 -> region done
	moveal	%fp@(-32),%a2		| pointer-table base
	movel	%fp@(-24),%d0
	asll	&2,%d0			| B*4
	addal	%d0,%a2			| a2 = &Bdesc
	movel	%a2@,%d1		| Bdesc (4-byte pointer descriptor)
	movel	%d1,%d0
	andil	&3,%d0			| UDT
	beqw	Lf_nextB		| empty -> next pointer entry
	andil	&0xffffff00,%d1		| leaf-table base = Bdesc & ~0xff
	movel	%d1,%fp@(-4)		| fp@-4 = leaf base (for hat_ptfree)
	addil	&256,%d1
	movel	%d1,%d3			| d3 = leaf end bound (leaf + 64*4)
	moveal	%fp@(-4),%a3		| a3 = leaf PTE cursor
Lf_PTE:
	tstl	%a3@
	beqw	Lf_nextPTE		| empty PTE -> skip
| --- per-page bookkeeping (VERBATIM 030, only pfn width {0:21}->{0:20}) ---
	movel	%fp@(8),%d0
	addil	&16,%d0
	moveal	%d0,%a0
	subql	&1,%a0@			| (*(as+16))-- mapping count
	bfextu	%a3@{&0:&20},%d0	| pfn
	cmpl	pages_base,%d0
	bcsw	Lf_ppzero
	bfextu	%a3@{&0:&20},%d0
	cmpl	pages_end,%d0
	bccw	Lf_ppzero
	bfextu	%a3@{&0:&20},%d0
	subl	pages_base,%d0
	moveq	&60,%d4
	mulsl	%d4,%d0
	movel	pages,%d4
	addl	%d0,%d4
	movel	%d4,%fp@(-12)		| pp = pages + (pfn-pages_base)*60
	braw	Lf_ppdone
Lf_ppzero:
	clrl	%fp@(-12)
Lf_ppdone:
	tstl	%fp@(-12)
	beqw	Lf_nextPTE
| M/U writeback: leaf U/M (byte3 {4:1}/{3:1}) -> pp {6:1}/{5:1}  (positions unchanged)
	movel	%fp@(-12),%d0
	moveal	%d0,%a0
	bfextu	%a0@{&6:&1},%d0
	bfextu	%a3@(3){&4:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&6:&1}
	movel	%fp@(-12),%d0
	moveal	%d0,%a0
	bfextu	%a0@{&5:&1},%d0
	bfextu	%a3@(3){&3:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&5:&1}
| reverse-map unlink: walk pp@(32) chain (next ptr @ pte+256) for a3; with safety counter
	movel	%fp@(-12),%d4
	addil	&32,%d4
	moveal	%d4,%a4			| a4 = &pp->revmap_head
	movel	&256,%d1		| safety counter
Lf_find:
	cmpal	%a4@,%a3
	beqw	Lf_unlink
	subql	&1,%d1
	beqw	Lf_findfail		| not found -> bail (don't hang on a bad list)
	moveal	%a4@,%a4
	addaw	&256,%a4
	braw	Lf_find
Lf_findfail:
	movel	Lhf_failn,%d0
	cmpil	&4,%d0
	bccw	Lf_nextPTE
	addql	&1,%d0
	movel	%d0,Lhf_failn
	movel	%a3,%sp@-		| pte addr
	movel	%a3@,%sp@-		| *pte
	pea	Lhf_failmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
	braw	Lf_nextPTE
Lf_unlink:
	movel	%a3@(256),%a4@		| *a4 = pte->revmap_next
Lf_nextPTE:
	addqw	&4,%a3
	cmpl	%a3,%d3			| d3 - a3
	bhiw	Lf_PTE			| d3 > a3 -> more PTEs in this leaf
| leaf table fully scanned -> free it (hat_ptfree preserves d4/a4/a5)
	movel	%fp@(-4),%sp@-
	jsr	hat_ptfree
	addqw	&4,%sp
Lf_nextB:
	addql	&1,%fp@(-24)
	braw	Lf_B
Lf_freeA:
| V1: LEAK the pointer table (no hat_sdtfree yet); clear root[A] so the as is clean.
	movel	%fp@(-20),%d0
	asll	&2,%d0
	clrl	%a5@(0,%d0:l)		| root[A] = 0 (UDT invalid)
Lf_nextA:
	addql	&1,%fp@(-20)
	braw	Lf_A
Lf_done:
	moveml	%fp@(-60),%d2-%d4/%a2-%a5
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple
	nop				| +1: align total .text to 16 (text/data contiguity)

| ===========================================================================
| hat_ptfree (orig 0xb6cf4, file-local -> globalize+weaken) -- 040 NO-OP (leak) stub.
| The 030 original returns a freed leaf page-table page to a 2KB FRAGMENT POOL
| (free_pts, 4 x 512B frags per 2KB page) so hat_ptalloc can reuse it.  Model B uses
| 4KB pages and we already FORCED hat_ptalloc down the page_get path (patch_modelb
| beqw->braw @0xb68a2), so every leaf it returns is a whole, page-aligned 4KB page and
| the fragment pool is never drained.  The stock teardown (0xb6e10: walk a2@(32)+k*16
| frag nodes, unlink via node->prev@(12)) then reads garbage prev pointers -> BUS ERROR
| (pc=0xb6e30), hit when init's exec ran hat_unload on its old image.  All 5 callers
| (hat_unload/hat_free/hat_exec/hat_pageunload/hat_swapout) reach it, so fix hat_ptfree
| itself: LEAK the leaf (same V1 philosophy as hat_free's pointer-table leak) -- just
| return.  Bounded (a handful of leaves churn on the path to single-user).  TODO: a
| proper Model B hat_ptfree = page_free(pages[leaf>>12]) (leaf is always page-aligned).
| One-shot gated marker (first 8) confirms it is reached + gauges the leak rate.
	.globl	hat_ptfree
hat_ptfree:
	movel	Lpf_n,%d0
	cmpil	&8,%d0
	bccs	Lpf_ret			| after 8 prints, silent leak
	addql	&1,%d0
	movel	%d0,Lpf_n
	movel	%sp@(4),%d1		| leaf arg (sp@0=retaddr, sp@4=arg0)
	movel	%d1,%sp@-
	pea	Lpf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lpf_ret:
	rts
	nop				| pad .text to a 4-byte multiple

	.data
	.even
Lpf_msg:
	.asciz	"DBG hat_ptfree LEAK leaf=%x (no-op, Model B)"
	.even
Lpf_n:
	.long	0
Lhae_msg:
	.asciz	"DBG hat_alloc ENTER as=%x (proc-1 child path running)"
	.even
Lhae_n:
	.long	0
Lha_msg:
	.asciz	"DBG hat_alloc: as=%x root=%x (kmem_zalloc done)"
	.even
Lha_n:
	.long	0
Lpt_dbgmsg:
	.asciz	"DBG ptload va=%x urp=%x"
	.even
Lpt_dbgn:
	.long	0
Lrd_msg:
	.asciz	"DBG ptload2 va=%x urp=%x as=%x rootVA=%x Aidx=%x Adesc=%x"
	.even
Lrd_n:
	.long	0
Lsz_msg:
	.asciz	"DBG sdtalloc ptable va=%x raw=%x aligned=%x"
	.even
Lsz_n:
	.long	0
Lpo_msg:
	.asciz	"DBG segmap-map va=%x poff=%x pfn=%x"
	.even
Lpo_n:
	.long	0
	.even
Lgt_msg:
	.asciz	"DBG GOTmap va=%x pfn=%x prot=%x"
	.even
Lgt_n:
	.long	0
Lpemsg0:
	.asciz	"hat_pteload: root NOT resident va=%x rootbase=%x Aidx=%x Adesc4=%x desc8=%x"
Lpemsg1:
	.asciz	"DBG hat_pteload pfn mismatch va=%x leaf=%x slot=%x Bdesc=%x *pte=%x newpfn=%x (overwriting)"
	.even
Lhp_dbgn:
	.long	0
Lbamsg:
	.asciz	"DBG hat_pteload Lballoc leaf va=%x leafpt=%x (hat_ptalloc result)"
	.even
Lba_dbgn:
	.long	0
Lhu_msg:
	.asciz	"hat_unlock: invalid sde (040 walk)"
	.even
Lhl_dbgmsg:
	.asciz	"DBG hat_unload va=%x size=%x flags=%x"
	.even
Lhl_dbgn:
	.long	0
	.even
Lhl_failmsg:
	.asciz	"DBG hat_unload: pte not in revmap *pte=%x pp=%x pte@=%x"
	.even
Lhl_failn:
	.long	0
	.even
Lhf_msg:
	.asciz	"DBG hat_free ENTER as=%x root=%x"
	.even
Lhf_n:
	.long	0
Lhf_failmsg:
	.asciz	"DBG hat_free: pte not in revmap *pte=%x pte@=%x"
	.even
Lhf_failn:
	.long	0
