| hat040.s -- 68040 port of the binary-only HAT page-table layer.
|
| Phase 3 of the AMIX 68040 port (see src/hat-040-port-worklist.md).
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
| --- btrace 'P' one-shot: the FIRST hat_pteload (exercises the CM-B1 Lcm_sel
|     classifier path).  d0 is scratch here; d2(va)/a2(pp) preserved by btrace_mark. ---
	tstl	Lbt_ptl_done
	bnew	Lbt_ptl_skip
	moveq	&1,%d0
	movel	%d0,Lbt_ptl_done
	pea	0x50			| 'P'
	jsr	btrace_mark
	addqw	&4,%sp
Lbt_ptl_skip:

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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lpo_no
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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lgt_no
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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lpt_nodbg
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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lrd_no
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
| V2 (2026-07-02, table-leak fix): allocate the pointer table as a WHOLE 4KB PAGE via
| hat_ptalloc (page_get), exactly like the leaf tables below.  This replaces the old
| hat_sdtalloc(16) + round-up-to-512 + manual-zero dance: a page is naturally 512-aligned
| (the old sub-512-alignment bug can't happen) and hat_ptalloc's Model-B bzero clears the
| full 4096 B (patch_modelb 0xb6904), so the table starts all-invalid.  Crucially it makes
| the pointer table FREEABLE at hat_free040 (page-aligned -> hat_ptfree V2 page_free's it);
| the sdtalloc carves could never be page-freed (shared/offset carve).  This was 17
| hat_sdtalloc calls/exec = the bulk of the ~26-page/exec kernel-heap drain behind
| 'ldterm: out of blocks'.  hat_ptalloc preserves d2(va)/a2(pp) (callee-saved regs).
| flags=3 (2026-07-07, Codex HAT-PTALLOC-AUDIT.md): HAT_CANWAIT(1)|HAT_NOSTEAL(2), not bare
| HAT_CANWAIT(1).  HAT_CANWAIT alone still permits hat_ptalloc_orig's STEAL path on the
| normal-alloc-failure branch, and that path is unported 030-format tree code (8-byte
| descriptors, 21-bit PFNs, 2KB VA stride) -- reachable only under real memory pressure,
| which no test workload so far has hit, but active corruption (not a bounded leak) if it
| ever fires.  HAT_NOSTEAL forces the fallback straight to sleep-and-retry instead.  No
| effect on the (currently always-taken) success path.
	pea	3			| one table
	movel	%fp,%d0
	subil	&48,%d0
	movel	%d0,%sp@-		| &out -- receives the PTDAT DESCRIPTOR (not the table!)
	jsr	hat_ptalloc
	addqw	&8,%sp
| V2.2 (boot-verified V2 bug): hat_ptalloc's out-param is the ptdat DESCRIPTOR (a 16-byte
| hat_sdtalloc carve, e.g. 0x7CB3200) -- the TABLE address is the RETURN VALUE %a0 (identity-
| phys 4KB page base), exactly like the leaf path's `moveal %a0,%a4`.  V2 installed the
| descriptor as the pointer table -> garbage Bdescs (stale 3F0002) -> pfn-mismatch overwrite
| -> PANIC hat_pt2ptdat.  Also: the page_get path bzeros only 256 B (leaf size, 0xb6a7a);
| a pointer table is 512 B, so zero all 128 descriptors ourselves.
	movel	%a0,%fp@(-48)		| table = RETURN VALUE (fresh page, identity phys)
	moveq	&127,%d0
Lrz_loop:
	clrl	%a0@+
	dbra	%d0,Lrz_loop		| zero 512 B (128 x 4-byte descriptors)
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
| flags=3 (2026-07-07, see the root-alloc comment above): HAT_CANWAIT|HAT_NOSTEAL, not bare
| HAT_CANWAIT -- same steal-path hardening, same no-effect-on-success-path reasoning.
	tstl	%a2			| pp != 0 ?
	beq	Lballoc0
	addqw	&1,%a2@(2)		| pp hold++
	pea	3
	movel	%fp,%d0
	subql	&4,%d0
	movel	%d0,%sp@-
	jsr	hat_ptalloc		| hat_ptalloc(&ptdat, 3)
	moveal	%a0,%a4			| a4 = new page table
	subqw	&1,%a2@(2)		| pp hold--
	addqw	&8,%sp
	bra	Lbfill
Lballoc0:
	pea	3
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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lba_nodbg
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

| leaf present: verify the pfn matches.  SAME pfn -> Lpfnok (update prot only; the
| mapping and the page's p_mapping reverse-map already exist).  DIFFERENT pfn = the leaf
| slot already maps a DIFFERENT page (a COW replacement / stale leaf).  Stock 030 panicked
| here, but on 040 the COW fault path legitimately drives this: segvn installs the private
| copy at the SAME va without a preceding hat_unload.  We MUST go through Lreplace, which
| (1) unlinks the OLD page from its p_mapping reverse-map and (2) registers the NEW page in
| p_mapping.  Falling into Lpfnok instead (the old behaviour) wrote the PTE but left the NEW
| page with p_mapping==0 -> anon_decref/page_abort saw PP_ISMAPPED()==false and freed the
| page WHILE its 040 leaf PTE was still live -> page_get re-handed it as a leaf table ->
| 0xFFFFFFFF fill clobbered the live page (THE child-exec wild-jump: User BUS ERROR FFFFFFFF
| PC:800024FE).  Diagnostic print (gated 8) kept.  a4=&leaf, d2=va preserved across cmn_err.
	bfextu	%a4@{&0:&20},%d0		| existing PFN (20 bits)  [030: 21]
	cmpl	%fp@(20),%d0
	beq	Lpfnok
	addql	&1,hat_pfnmiss_n		| UNCAPPED: the true rate is the open question (kdbg040.s)
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lreplace
	movel	Lhp_dbgn,%d0
	cmpil	&8,%d0
	bccw	Lreplace		| after 8 prints, skip log, still go to Lreplace
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
	bra	Lreplace
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
	bsrw	Lcm_sel			| CM-B1: OR the cache-mode class into status (fp@-44)
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
	bsrw	Lcm_sel			| CM-B1: OR the cache-mode class into status (fp@-44)
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

| --- Lreplace: leaf slot maps a DIFFERENT page than requested (COW replacement).
| Reconcile the p_mapping reverse-maps, then write the new leaf PTE.  a4=&leaf,
| a2=new pp (may be 0), d2=va, fp@(20)=new pfn, fp@(24)=prot.  Counts (seg rss,
| leaf lock/use) are intentionally LEFT UNCHANGED: this is a 1:1 replace, not a new
| mapping, so the slot was already counted when the OLD page was loaded.
Lreplace:
| (1) unlink &a4 from the OLD page's p_mapping list (old pfn = current *a4).
	bfextu	%a4@{&0:&20},%d0		| old pfn
	cmpl	pages_base,%d0
	bcsw	Lrp_status		| old pfn < pages[] -> no pp, skip unlink
	cmpl	pages_end,%d0
	bccw	Lrp_status		| old pfn >= end -> skip
	subl	pages_base,%d0
	moveq	&60,%d3
	mulsl	%d3,%d0
	moveal	pages,%a0
	addal	%d0,%a0			| a0 = old_pp
|	--- 2026-07-19 ISSUE-10: harvest the OLD PTE's HW U/M bits into old_pp BEFORE the
|	    different-PFN overwrite destroys them (same contract + bit layout as the
|	    hat_pageunload harvest below: p_ref = pp bf-offset 6, p_mod = bf-offset 5;
|	    PTE U = low-byte bit3 0x08 -> bf-offset 4, M = bit4 0x10 -> bf-offset 3).
|	    Without this an in-slot replacement of a dirty mapping left old_pp->p_mod=0 ->
|	    the old page could later be classified clean and freed with NO swap write
|	    (Codex UM-BIT-LIFECYCLE-CENSUS.md: the one remaining unconditional HAT-side
|	    dirty-loss site).  Done regardless of the unlink search outcome: the PTE
|	    provably mapped this pfn, so the attribution is correct even if the
|	    reverse-map node is missing. ---
	lea	%a4@(3),%a1		| a1 = &old PTE low byte (U/M live here)
	bfextu	%a0@{&6:&1},%d0
	bfextu	%a1@{&4:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&6:&1}		| old_pp->p_ref |= old PTE U
	bfextu	%a0@{&5:&1},%d0
	bfextu	%a1@{&3:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a0@{&5:&1}		| old_pp->p_mod |= old PTE M
	lea	%a0@(32),%a1		| a1 = &old_pp->p_mapping (list head slot)
	movel	&256,%d3		| findmap safety counter
Lrp_find:
	cmpal	%a1@,%a4		| *a1 == &leaf ?
	beq	Lrp_unlink
	subql	&1,%d3
	beq	Lrp_exhaust		| not found -> give up (leave list as-is)
	moveal	%a1@,%a1		| follow: cur = *a1
	addaw	&256,%a1		| next-pointer slot = cur + NPGPT*4
	bra	Lrp_find
| --- ISSUE-10 instrument (2026-08-19, src/i10rev040.s).  This give-up used to
|     branch straight to Lrp_status and was the only one of the three bounded
|     reverse-map unlinks that said NOTHING -- yet it is the worst of them: the
|     leaf is about to be overwritten with a DIFFERENT pfn a few instructions
|     later, so the old page is left holding a chain node that names a slot now
|     mapping somebody else.  Counting it costs one increment.  Lrp_status opens
|     with `moveq &7,%d3`, which reads neither %d3's old value nor the condition
|     codes, so nothing is consumed across this. ---
Lrp_exhaust:
	addql	&1,i10_rpfail_n		| UNCAPPED (i10rev040.s)
	bra	Lrp_status
Lrp_unlink:
	movel	%a4@(256),%a1@		| splice &leaf out: *a1 = leaf->next
| --- ISSUE-10 invariant: how much of the 256-node budget did this search use?
|     %d3 counts DOWN from 256, so %d3 < 128 means more than half the chain was
|     walked.  Once per successful search, not per iteration.  %d3 is dead here
|     (Lrp_status reloads it immediately) and the CCs this cmpil sets are not
|     read by that `moveq`. ---
	cmpil	&128,%d3
	bcc	Lrp_nodeep
	addql	&1,i10_deep_n
Lrp_nodeep:
| (2) compute the PTE status from prot (mirror Lw_st).
Lrp_status:
	moveq	&7,%d3
	andl	%d3,%fp@(24)		| prot &= 7
	moveq	&2,%d0
	andl	%fp@(24),%d0
	tstl	%d0
	beq	Lrp_ro
	moveq	&1,%d3
	movel	%d3,%fp@(-44)		| writable -> status 1
	bra	Lrp_wr
Lrp_ro:
	tstl	%fp@(24)
	bne	Lrp_rop
	clrl	%fp@(-44)		| prot 0 -> status 0
	bra	Lrp_wr
Lrp_rop:
	moveq	&5,%d3
	movel	%d3,%fp@(-44)		| read-only -> status 5
Lrp_wr:
	bsrw	Lcm_sel			| CM-B1: OR the cache-mode class into status (fp@-44)
	movel	%fp@(20),%d0		| new pfn
	moveq	&12,%d3
	lsll	%d3,%d0			| pfn<<12
	movel	%fp@(-44),%d3
	orl	%d0,%d3
	movel	%d3,%a4@		| *leaf = (newpfn<<12) | status
| (3) register the NEW page (a2) in its p_mapping list (mirror Lw_nopp).
	tstl	%a2
	beq	Lrp_flush
	movel	%a2@(32),%a4@(256)	| leaf->next = new_pp->p_mapping
	movel	%a4,%a2@(32)		| new_pp->p_mapping = &leaf
Lrp_flush:
	pea	1
	movel	%d2,%sp@-
	jsr	flushmmu		| flushmmu(va, 1)
	bra	Lepi

| --- Lcm_sel: CM-bit class selector (caches campaign B1, 2026-07-20; spec =
| docs/contracts/CM-PTE-WRITER-MATRIX.md "Required cache-class selector").
| Shared by all three complete leaf constructors (Lpfnok / Lwleaf / Lreplace).
| ORs the 040 CM field (leaf bits 6:5) into the already-computed status word at
| fp@(-44).  Status is always one of {0,1,5} here (CM bits clear), so a plain OR
| composes correctly -- never OR into an unmasked template.
|   seg == segu   -> 0x60 NC   (u-area/segu windows stay noncacheable in B1+B2;
|                    highest priority: segu pages have pp!=NULL but must NOT get
|                    the managed-RAM class -- resume/prumap alias the same frames)
|   pp == NULL    -> 0x40 NCS  (hat_devload path: unmanaged PFN / MMIO;
|                    noncacheable-serialized in B1+B2) UNLESS the pfn falls in a
|                    registered framebuffer interval, which gets 0x60 NC -- see
|                    Lcm_dev and hat_cm_fb below (Zorro III track, change D)
|   else          -> hat_cm_ram (managed RAM stage class: 0x00 WT in B1;
|                    B2 flips the DATA global to 0x20 copyback -- one switch)
| Inputs: fp@(8) = seg (arg0), a2 = pp (live in all three paths), fp@(20) = pfn
| (the same slot in all three constructors -- checked, and it is what makes the
| framebuffer test possible without touching any signature).  Clobbers d0.
| DORMANT until CACR DC-enable + DTT0 handling (Step B, HW-gated): with the data
| cache off these bits are ignored by the 040, so this is a no-op port that can
| run (and be byte-inspected) on the emulator.
Lcm_sel:
	movel	segu,%d0		| the global segu segment pointer
	cmpl	%fp@(8),%d0
	beq	Lcm_nc
	tstl	%a2			| pp == NULL -> device/unmanaged
	beq	Lcm_dev
	movel	hat_cm_ram,%d0		| managed RAM: stage class (B1 0x00 / B2 0x20)
	orl	%d0,%fp@(-44)
	rts
Lcm_nc:
	oril	&0x60,%fp@(-44)		| segu window -> NC
	rts
| --- Lcm_dev: unmanaged PFN.  Default NCS, except for pfns inside a registered
| framebuffer interval (change D, 2026-08-19).
|
| WHY A FRAMEBUFFER IS DIFFERENT.  Serialisation exists so MMIO register accesses
| cannot be reordered.  A framebuffer is memory-like and does not need it, and on
| a Zorro III aperture the serialisation would eat the bandwidth the wider bus is
| there to deliver.  It buys nothing on Zorro II -- measured 2026-08-19, the bus
| is saturated there (docs/Z3-BUSBENCH-VA2000-Z2-260819.md) -- which is exactly
| why it belongs to the Zorro III work and not to a standalone "optimisation".
|
| ORDERING IS SAFE, and it was read out of the manuals rather than assumed:
| write-to-write order is architectural on both CPUs, so an NC framebuffer store
| cannot be overtaken by a later NCS command-register store, and this survives
| enabling the 68060 store buffer.  docs/Z3-CACHE-CLASS-ORDERING-260819.md.
|
| The table is compared with ABSOLUTE addressing so this costs no address
| register: a0/a1 are scratch at all three call sites but relying on that would
| be an invariant nobody restates when the constructors change.
|
| Empty table (the default, both longs zero) can never match: `pfn < 0` is false
| for every unsigned pfn, so both tests fall through to NCS and the behaviour is
| bit-for-bit what it was before this change.
Lcm_dev:
	movel	%fp@(20),%d0		| pfn being mapped
	cmpl	hat_cm_fb+0,%d0
	bcs	Lcm_d1			| pfn < lo0 -> not in slot 0
	cmpl	hat_cm_fb+4,%d0
	bcs	Lcm_fb			| lo0 <= pfn < hi0 -> framebuffer
Lcm_d1:
	cmpl	hat_cm_fb+8,%d0
	bcs	Lcm_dncs
	cmpl	hat_cm_fb+12,%d0
	bcs	Lcm_fb
Lcm_dncs:
	oril	&0x40,%fp@(-44)		| unmanaged PFN -> NCS (unchanged default)
	addql	&1,cmf_ncs_n
	movel	%a4,cmf_ncs_leaf	| a4 = &leaf, live in all three constructors
	rts
Lcm_fb:
	oril	&0x60,%fp@(-44)		| registered framebuffer -> NC, not serialised
	addql	&1,cmf_fb_n
	movel	%a4,cmf_fb_leaf
	rts

| ===========================================================================
| hat_cm_fb_add(lo_pfn, hi_pfn) -- register one half-open framebuffer PFN
| interval.  Returns 1 if the interval is installed (or was already), 0 if it
| was refused.  Change D, 2026-08-19.
|
| THE OWNERSHIP CONTRACT, which is the part that is easy to get wrong:
|   * intervals are half-open [lo, hi) in PAGE FRAME NUMBERS, page-aligned by
|     construction;
|   * a board's interval must be installed BEFORE the device can be opened or
|     mapped, i.e. before any first fault on it;
|   * once installed it is IMMUTABLE for the lifetime of every mapping, and it is
|     never removed on last close -- a mapping can outlive the file descriptor
|     that created it;
|   * re-registering the identical interval succeeds and changes nothing, so an
|     init path that runs twice is harmless.
| Changing a live interval is refused rather than supported.  The retained 2 KiB
| segdev stepping means offsets 0 and 0x800 fault to the SAME 4 KiB pfn, so a
| mapping is re-classified through Lcm_sel more than once; that is only idempotent
| while the classification is stable.  And a same-pfn reclassification would leave
| one leaf in the old class and another in the new one, which is the alias hazard
| docs/contracts/CM-PTE-WRITER-MATRIX.md refuses without a cache-maintenance
| contract.  An immutable table means that case cannot arise.
|
| PUBLICATION.  The two stores go to kernel .data, which lives below 1 GB and is
| therefore reached through the DTT0 identity window uncached -- the same
| assumption bp_map040 already relies on -- so no cache push is needed.  The
| STORE ORDER is load-bearing: LO is written first, because a slot with LO set and
| HI still zero matches nothing, while HI set and LO still zero would match every
| pfn below HI.  HI is the store that arms the interval.
| ===========================================================================
	.globl	hat_cm_fb_add
hat_cm_fb_add:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	%fp@(8),%d2		| lo
	movel	%fp@(12),%d3		| hi
	clrl	%d0
	cmpl	%d2,%d3
	blsw	Lfa_out			| hi <= lo: empty or inverted -> refuse
	lea	hat_cm_fb,%a2
	moveq	&2,%d1			| slot count
Lfa_loop:
	movel	%a2@(0),%d0
	orl	%a2@(4),%d0
	beqw	Lfa_free		| both zero -> slot unused
	cmpl	%a2@(0),%d2
	bne	Lfa_next
	cmpl	%a2@(4),%d3
	bne	Lfa_next
	moveq	&1,%d0			| identical interval already installed
	braw	Lfa_out
Lfa_next:
	addal	&8,%a2
	subql	&1,%d1
	bnew	Lfa_loop
	clrl	%d0			| table full -> refuse
	braw	Lfa_out
Lfa_free:
	movel	%d2,%a2@(0)		| LO first -- see PUBLICATION above
	movel	%d3,%a2@(4)		| HI arms the interval
	moveq	&1,%d0
Lfa_out:
	moveml	%fp@(-12),%d2-%d3/%a2
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
| hat_pageunload (orig 0xb4598, GLOBAL T) -- 040 port.
| Called by page_abort/pageout (and others) to remove ALL mappings of a physical page `pp` before
| the page is freed/reclaimed.  CONTRACT (SVR4 vm_hat.c): walk pp->p_mapping -- a list of pte_t*
| (each = the address of a leaf PTE mapping pp), chained via *(pte + NPGPT) where NPGPT=64 entries
| = +256 bytes (the 512B leaf fragment = 256B PTEs + 256B reverse-map ptrs, see hat_unload) -- and
| INVALIDATE each PTE, then NULL pp->p_mapping.
| WHY a port is needed: the stock-030 hat_pageunload, when a leaf table's in-use count hits 0, takes
| a "table empty" path that invalidates the 030 SDE (via as->a_hat.hat_srama, the INERT 030 tree on
| 040) and hat_ptfree's the table -- WITHOUT clearing the live 040 leaf PTE.  Result (measured): a
| reclaimed page's 040 leaf PTE stays resident (e.g. 7CAB019), so after page_free + page_get
| re-hands the page to hat_sdtalloc (which fills it 0xFFFFFFFF), the original owner still reads it
| through the stale PTE -> bss reads 0xFFFFFFFF -> child malloc bus-errors.
| THIS port: the 040 leaf PTE address is ALREADY in p_mapping (hat_pteload set pp->p_mapping=&PTE),
| so just clrl each PTE (UDT->0 invalid) directly -- no tree walk -- then cpusha+pflusha so the HW
| walker reloads the invalid descriptor and the next access faults & re-maps.  CONSERVATIVE: does
| NOT free the now-emptier leaf tables or adjust as->a_rss (a bounded leak / soft-count drift, same
| philosophy as hat_free040) -- correctness (no stale resident PTE on a freed page) comes first.
|
| 2026-07-18 ISSUE-10 PRODUCER FIX: harvest each PTE's HW U/M bits into pp->p_ref/p_mod BEFORE
| invalidating (SVR4 vm_hat.c contract; hat_pagesync040 mirrors the same bit layout).  Unload is
| the LAST moment the HW-maintained M bit is readable: checkpage's steal and segvn_swapout's
| dirty-vs-clean decision (3b2 seg_vn.c: pages arrive here ALREADY unloaded, hat_pagesync finds an
| empty chain, then `if (p_mod) VOP_PUTPAGE else page_free`) both depend on p_mod surviving the
| unload.  Without the harvest, any anon page written AFTER the last pagesync scan (heaps, stacks)
| was freed as "clean" with NO swap write -> the owner's refault read a never-written swap slot ->
| garbage heap/stack -> the 4AFC005F bus-error avalanche.  Proven live on emu-040 (memwatch: the
| steal's PTE clear = Lpu_loop+0xe; swap partition byte-diff vs golden stayed ~0 while thousands of
| processes died; evidence test-tools/issue10-dirtydiscard-260718.txt).
| Args: arg@8 = pp.  Returns void.
	.globl	hat_pageunload
hat_pageunload:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2-%a3,%sp@-
	moveal	%fp@(8),%a2		| a2 = pp
	movel	%a2@(32),%d2		| d2 = pp->p_mapping (head: &leaf PTE, or 0)
Lpu_loop:
	tstl	%d2
	beqw	Lpu_done
	moveal	%d2,%a3			| a3 = &PTE (current)
	movel	%a3@(256),%d3		| d3 = next = *(pte + NPGPT*4)  (reverse-map chain)
|	--- harvest U/M -> pp->p_ref/p_mod before the invalidate (bit layout = hat_pagesync040,
|	    verbatim from the stock disasm: p_ref = pp bit-offset 6, p_mod = bit-offset 5;
|	    PTE U = low-byte bit3 0x08 -> bf-offset 4, M = bit4 0x10 -> bf-offset 3).
|	    An invalid/zero node contributes 0 bits -> the OR is harmless. ---
	lea	%a3@(3),%a0		| a0 = &PTE low byte (U/M live here)
	bfextu	%a2@{&6:&1},%d0
	bfextu	%a0@{&4:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a2@{&6:&1}		| pp->p_ref |= PTE U
	bfextu	%a2@{&5:&1},%d0
	bfextu	%a0@{&3:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a2@{&5:&1}		| pp->p_mod |= PTE M
	clrl	%a3@			| *pte = 0 -> 040 leaf descriptor INVALID (UDT=0)
	movel	%d3,%d2			| advance to next mapping
	braw	Lpu_loop
Lpu_done:
	clrl	%a2@(32)		| pp->p_mapping = NULL
	.word	0xf4f8			| cpusha bc -- push the cleared PTE lines to RAM
	.word	0xf518			| pflusha   -- flush the ATC so the walker reloads invalid descriptors
	moveml	%sp@+,%d2-%d3/%a2-%a3
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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lhl_nodbg
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
| V2.2 guard: after hat_free (as_free runs hat_free FIRST, seg teardown SECOND) the root is
| freed and as@(20)==0 -- stock semantics make post-free hat ops no-ops.  Without this the
| A-walk reads descriptors from address 0 (low RAM) -> KERNEL FAULT pc=0xD7Dxx (boot-verified).
	beqw	Lhl_rootnull
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
Lhl_nextAreg:
	movel	%d2,%d0			| A absent/garbage -> next 32MB (2^25) boundary
	andil	&0xfe000000,%d0
	addil	&0x2000000,%d0
	movel	%d0,%d2
	braw	Lhl_chkmore
Lhl_aok:
	andil	&0xfffffe00,%d0		| Btable = Adesc & ~0x1ff
| V2.2 guard (mirror of hat_chgprot040 + hat_free040 Lf_badleaf): a garbage descriptor with
| UDT set (FFFFFFFF relics) passes the UDT check and derefs an unbacked base -> KERNEL FAULT.
| V2.3 (ISSUE-7 root fix): lower bound is the KERNEL IMAGE base (_start>>12), NOT pages_base.
| The kernel's A-level pointer tables are the STATIC kptr040 array inside the kernel image
| (pstart040 mmu040_buf, .data) whose frames lie BELOW pages_base -- the old [pages_base,
| pages_end) test rejected them, making hat_unload a SILENT NO-OP for ALL kernel VAs
| (kvseg/kvsegmap/kvsegu).  segu_release's hat_unload therefore never cleared window PTEs /
| reverse-maps: pages were freed still-mapped (LIVEABORT evidence: p_mapping set at
| anon_decref's page_abort), recycled while old window PTEs still pointed at them ->
| zeroed live u-areas -> the recurring pc=0x4000001E / zeroed-u crash family.  The relaxed
| bound still rejects the V2.2 garbage (0 / small ints / FFFFFE00: below kernel base or
| >= pages_end).
	movel	%d0,%d1
	moveq	&12,%d5
	lsrl	%d5,%d1
	movel	&_start,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5			| d5 = kernel base frame (_start>>12)
	cmpl	%d5,%d1
	bcsw	Lhl_nextAreg
	cmpl	pages_end,%d1
	bccw	Lhl_nextAreg
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
Lhl_nextBreg:
	movel	%d2,%d0			| B absent/garbage -> next 256KB (2^18) boundary
	andil	&0xfffc0000,%d0
	addil	&0x40000,%d0
	movel	%d0,%d2
	braw	Lhl_chkmore
Lhl_bok:
	andil	&0xffffff00,%d1		| leaf base = Bdesc & ~0xff
| same guard for the leaf base (garbage Bdesc FFFFFFFF -> FFFFFF00 deref); V2.3: kernel-image
| lower bound here too -- some kernel leaves (early kvm_init/sptalloc tables) are also static.
	movel	%d1,%d0
	moveq	&12,%d5
	lsrl	%d5,%d0
	movel	&_start,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5			| d5 = kernel base frame (_start>>12)
	cmpl	%d5,%d0
	bcsw	Lhl_nextBreg
	cmpl	pages_end,%d0
	bccw	Lhl_nextBreg
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
| ISSUE-10 instrument (2026-08-19, src/i10rev040.s): the cmn_err below stops
| after 4 for the whole uptime, so this site's real rate has never been known.
| The counter is uncapped.  The `movel` that follows loads %d0 outright and does
| not read the condition codes.
	addql	&1,i10_hlfail_n
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
| ISSUE-10 invariant (see Lrp_unlink): %d1 counted down from 256, so %d1 < 128
| means this search walked past the halfway mark of its budget.  %d1 is only
| READ here, and Lhl_aftermap opens with `tstl`, which sets the CCs itself.
	cmpil	&128,%d1
	bcc	Lhl_nodeep
	addql	&1,i10_deep_n
Lhl_nodeep:
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
	orib	&-128,%a4@		| mark page gone
| ---- caches Step B2 ordering fix (2026-07-23, docs/contracts/CB-PAGE-LIFECYCLE-CLOSURE.md
| "hat_unload(HAT_RELEPP) ordering"): the stock order freed the page while its
| resident leaf PTE was still in memory -- the physical page entered a free
| list with a live translation.  Retire the leaf FIRST, publish the descriptor
| clear and drop the stale ATC entry, and only then hand the page to page_free
| (whose central cb_page_release hook cleans the page DATA -- no second data
| cleanup here by design).  The Lhl_cleared join skips the duplicate clear.
	clrl	%a2@			| retire leaf PTE before allocator exposure
	.word	0xf478			| cpusha dc -- publish the descriptor clear
	.word	0xf518			| pflusha -- invalidate the stale ATC entry
	clrl	%sp@-
	movel	%a4,%sp@-
	jsr	page_free
	addqw	&8,%sp
	braw	Lhl_cleared		| leaf already cleared -- skip duplicate clrl
Lhl_clear:
	clrl	%a2@			| *pte = 0
Lhl_cleared:
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
| --- DBG (2026-06-27): trace leaf-table FREE for sh's text/data region [0x80000000,0x80080000).
|     d4 = npgs unloaded THIS call; since pt_inuse just reached 0, npgs == the leaf's pt_inuse just
|     before this decrement = how many active PTEs the leaf had.  SMALL npgs (1-2) while sh's leaf
|     should hold all of text+data = the churn bug (premature pt_inuse==0 -> SD_CLRVALID -> realloc).
|     LARGE npgs = legitimate teardown.  d2=va (advanced to leaf boundary), fp@-36=leaf base.
|     cmn_err preserves d2-d7/a2-a6, so d2/d4 survive.  Capped 12. ---
	cmpil	&0x80000000,%d2
	bcsw	Lhl_freego
	cmpil	&0x80080000,%d2
	bccw	Lhl_freego
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lhl_freego
	movel	Lhul_n,%d0
	cmpil	&12,%d0
	bccw	Lhl_freego
	addql	&1,%d0
	movel	%d0,Lhul_n
	movel	%d4,%sp@-		| npgs (= pt_inuse just before hitting 0)
	movel	%fp@(-36),%sp@-		| leaf base
	movel	%d2,%sp@-		| va (advanced to leaf boundary)
	pea	Lhul_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lhl_freego:
| FIX (2026-06-27): do NOT free the leaf / invalidate the Bdesc when pt_inuse hits 0.
| Freeing here caused leaf-table CHURN -> the child-crash double-alloc: anon_private()'s COW
| does hat_unload(addr) (empties a 1-page leaf -> pt_inuse 0) and IMMEDIATELY hat_memload(new
| page) at the SAME addr.  If we SD_CLRVALID + free the leaf here, that remap calls
| hat_ptalloc->page_get for a fresh leaf, which hands out a still-live page (the very COW page
| being mapped) -> the page is both data AND its own leaf table (offset-32 p_mapping/p_ptdats
| union collision) -> hat fills it 0xFFFFFFFF -> User BUS ERROR FFFFFFFF PC:800024FE.  hat_ptfree
| is ALREADY a no-op (leaf pages leak regardless), so freeing gained nothing.  Keep the empty
| leaf VALID so the immediate remap REUSES it (Lbhave->Lfreshleaf, no page_get, no churn).  Leaf
| tables are reclaimed at hat_free (full AS teardown).  Bounded per-AS leak; correctness > leak.
	nop				| (was: hat_ptfree(leaf) + bfclr Bdesc UDT) -- leaf intentionally KEPT

Lhl_chkmore:
	cmpl	%d2,%d3
	bccw	Lhl_leafwalk		| d3 >= va -> more to unmap
| 040 coherency fix (2026-07-07, Codex HAT-UNLOAD-COHERENCY-AUDIT.md): every OTHER 040 HAT
| writer (hat_pteload/hat_chgprot/hat_pageunload/resume) ends with cpusha bc; pflusha before
| returning; hat_unload was the outlier -- it clrl's each PTE (Lhl_clear, above) but returned
| with no post-clear cache push.  A cleared PTE can sit in copyback data cache while the
| hardware table walker still sees the old valid descriptor -- if the caller then frees/
| reuses the page (segu_release, segu_softunload, segmap_release, anon_private all do exactly
| this), the stale mapping can still translate to the recycled page.  This is a plausible NEW
| root cause for ISSUE-7 (u_procp=0 corruption on a second/dirty boot) that was not on the
| prior "ruled out" list.  Unconditional on every non-rootnull exit (simplest safe fix per the
| audit's own recommendation -- avoids adding a dirty-flag variable to an already delicate
| routine; the extra flush is a no-op cost when nothing was cleared).
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
	moveml	%fp@(-116),%d2-%d5/%a2-%a4
	moveal	%d0,%a0
	unlk	%fp
	rts
Lhl_rootnull:
	moveml	%fp@(-116),%d2-%d5/%a2-%a4
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
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lhae_done
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
| CM-B1 (2026-07-20, docs/contracts/CM-PTE-WRITER-MATRIX.md "Whole-AS allocation/free ordering"):
| publish the ZEROED root before exposing it via as->hat_root.  kmem_zalloc's
| zero stores go through the normal kernel mapping (kvseg VA, not the DTT0
| identity alias); under a copyback DC they could sit dirty while a context
| switch already loads this root into URP.  cpusha dc pushes them to RAM first.
| No-op while DC is off / WT; preserves a0 (cpusha touches no registers).
	.word	0xf478			| cpusha dc -- push the zeroed root page to RAM
	movel	%a0,%a2@(20)		| as->hat_root = 040 root VA (a0 = return value too)
	| --- one-shot DBG marker: proves as_alloc/hat_alloc is reached (newproc returned) ---
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lha_done
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
|   * ISSUE-40 (2026-08-01): the 030 tail ALSO released each region's legacy SDT
|     with hat_growsdt(hatp, section, 0), and that edge was missing entirely --
|     not just for the native pointer tables above but for the allocations the
|     RETAINED stock hat_map/hat_growsdt still makes on every exec.  Restored as
|     a call to hat_legacy_sdt_free (src/legacysdt040.s) at Lhf_nodbg,
|     i.e. BEFORE the A/B/C walk, because the legacy descriptors occupy the same
|     root words the walk reads and clears.
| Frame is identical to the 030 original (linkw -32, d2-d4/a2-a5) so restore offsets
| match.  Arg: arg@8 = as (as@(20) = 040 root).
	.globl	hat_free
hat_free:
	linkw	%fp,&-32
	moveml	%d2-%d4/%a2-%a5,%sp@-
	moveal	%fp@(8),%a0
	moveal	%a0@(20),%a5		| a5 = 040 root base (preserved across hat_ptfree)
| V2 guard: root already freed/never allocated (as@(20)==0) -> nothing to tear down.
| Matters now that Lf_done kmem_frees the root and clears as@(20) (double-free guard).
	movel	%a5,%d0
	beqw	Lf_nullroot
| --- one-shot ENTER marker: proves hat_free runs (exec/exit teardown reached) ---
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lhf_nodbg
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
| --- ISSUE-40 (2026-08-01): release this AS's RETAINED legacy-SDT allocations
|     BEFORE the native walk touches the root page.  The 030 destructor did this
|     with hat_growsdt(hatp, section, 0); we never did, so every dynamic exec
|     permanently kept the 4 KiB page holding libc's 17-unit section-3 SDT
|     (availrmem -1/exec, availrmem + pages_pp_kernel conserved => a REAL page).
|     The order is the whole risk: the legacy section 2/3 descriptors ARE root
|     words 0x10..0x1f, i.e. native entries A4..A7, and the walk below both reads
|     and clears them.  src/legacysdt040.s plus
|     docs/contracts/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md carry the full argument.
	movel	%fp@(8),%sp@-		| as
	jsr	hat_legacy_sdt_free
	addqw	&4,%sp
	moveal	%fp@(8),%a0		| a5 is callee-saved across the call and
	moveal	%a0@(20),%a5		|   as@(20) is unchanged -- reload anyway
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
| --- V3 guard (2026-07-10, FIRST REAL-HW PANIC of the Mercury visit): validate the
|     pointer-table BASE the same way Lf_badleaf validates leaf bases.  init's exec
|     teardown walks relic root slots (030-written hat_exec/hat_growsdt descriptors);
|     the UDT test passes garbage like 0x3F0000/0x400000/0x810000 (Zorro-space/hole
|     addresses).  The emulators read those leniently (open bus) so the B-scan only
|     logs BAD-slots and boots on, but the REAL A3000 bus-errors on the first Bdesc
|     read (`movel %a2@`) -> PANIC KERNEL FAULT pc=Lf_B+0x1a fmt=7 vec=2 (build -25).
|     Bounds: [min(_start>>12, pages_base), pages_end) = the union of Lf_badleaf's
|     pool bound and hat_unload V2.3's static-table bound (kernel statics lie BELOW
|     pages_base on the emulator; bank-1 pool pages lie BELOW _start>>12 on real HW,
|     where the kernel loads in the HIGH 0x08000000 bank).  d0/d1 scratch only.
	movel	%d0,%d1
	moveq	&12,%d0
	lsrl	%d0,%d1			| d1 = pointer-table pfn
	movel	&_start,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0			| d0 = kernel base frame (_start>>12)
	cmpl	pages_base,%d0
	bcsw	Lf_Abnd			| _start below pages_base -> kernel-static bound wins
	movel	pages_base,%d0		| else (high-bank kernel) the pool bound wins
Lf_Abnd:
	cmpl	%d0,%d1
	bcsw	Lf_badA			| below both bounds -> garbage region
	cmpl	pages_end,%d1
	bccw	Lf_badA			| at/above RAM top -> garbage region
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
| --- DBG + ROBUSTNESS (2026-06-26): validate the leaf-table base is a real RAM page-frame before
|     walking it.  A garbage pointer-table slot (UDT set but a bogus leaf base) bus-errors at
|     `tstl %a3@`.  Check leafbase>>12 is in [pages_base, pages_end) -- the SAME test Lf_ppzero
|     applies to PTE pfns.  If valid, walk it (Lf_PTE).  If not, LOG it (cmn_err flushes because we
|     do NOT crash -- we continue) and SKIP the slot (braw Lf_nextB, a bounded leak: the garbage
|     leaf is not freed).  The cmn_err line reveals the bad A/B/Bdesc/leafbase.  d0/d1 scratch. ---
	movel	%fp@(-4),%d0		| leafbase
	moveq	&12,%d1
	lsrl	%d1,%d0			| leafbase >> 12 = page frame
	cmpl	pages_base,%d0
	bcsw	Lf_badleaf
	cmpl	pages_end,%d0
	bccw	Lf_badleaf
	braw	Lf_PTE			| leaf base in managed RAM -> walk it
Lf_badleaf:
	movel	Lhfb_n,%d0
	cmpil	&12,%d0
	bccw	Lf_nextB		| capped -> skip silently
	addql	&1,%d0
	movel	%d0,Lhfb_n
	movel	%fp@(-4),%sp@-		| leafbase (4th %x)
	movel	%a2@,%sp@-		| Bdesc raw (3rd %x)
	movel	%fp@(-24),%sp@-		| B (2nd %x)
	movel	%fp@(-20),%sp@-		| A (1st %x)
	pea	Lhfb_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
	braw	Lf_nextB		| skip the garbage slot (do NOT hat_ptfree it)
| garbage pointer-table base (V3 guard above): log it (capped) and skip the whole A
| region WITHOUT reading or freeing it -- same bounded-leak philosophy as Lf_badleaf.
| root[A] is left as-is; Lf_done frees the whole root page anyway.
Lf_badA:
	addql	&1,hat_badaslot_n		| UNCAPPED: the true rate is the open question (kdbg040.s)
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lf_nextA
	movel	Lhfa_n,%d0
	cmpil	&8,%d0
	bccw	Lf_nextA		| capped -> skip silently
	addql	&1,%d0
	movel	%d0,Lhfa_n
	movel	%fp@(-32),%sp@-		| pointer-table base (3rd %x)
	movel	%d4,%sp@-		| Adesc raw (2nd %x)
	movel	%fp@(-20),%sp@-		| A (1st %x)
	pea	Lhfa_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
	braw	Lf_nextA		| skip the garbage region entirely
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
| ISSUE-10 instrument (2026-08-19, src/i10rev040.s): as at Lhl_findfail, the
| print below is capped at 4.  hat_free clears the leaf PTE on this path anyway
| (Lf_fail_clr), so an exhausted search leaves a chain node naming a zeroed
| slot.  The `movel` that follows does not read the condition codes.
	addql	&1,i10_hffail_n
	movel	Lhf_failn,%d0
	cmpil	&4,%d0
	bccw	Lf_fail_clr		| cap exceeded: still must clear the stale PTE
	addql	&1,%d0
	movel	%d0,Lhf_failn
	movel	%a3,%sp@-		| pte addr
	movel	%a3@,%sp@-		| *pte (read BEFORE clear so log shows real value)
	pea	Lhf_failmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lf_fail_clr:
	clrl	%a3@			| FIX: clear stale 040 leaf PTE (revmap unlink skipped)
	braw	Lf_nextPTE
Lf_unlink:
	movel	%a3@(256),%a4@		| *a4 = pte->revmap_next
| ISSUE-10 invariant (see Lrp_unlink): %d1 counted down from 256.  Read-only
| here; the `clrl` that follows sets its own condition codes.
	cmpil	&128,%d1
	bcc	Lf_nodeep
	addql	&1,i10_deep_n
Lf_nodeep:
	clrl	%a3@			| FIX: clear the 040 leaf PTE -- hat_free only unlinked
					|   p_mapping (pp->p_mapping=0) but left PTE valid.
					|   Later anon_decref->page_abort(p_mapping=0) skips
					|   hat_pageunload and calls page_free directly, so
					|   page_get can re-hand this pfn as a new leaf table
					|   while the old PTE still maps to it (double-alloc bug).
Lf_nextPTE:
	addqw	&4,%a3
	cmpl	%a3,%d3			| d3 - a3
	bhiw	Lf_PTE			| d3 > a3 -> more PTEs in this leaf
| leaf table fully scanned -> free it (hat_ptfree preserves d4/a4/a5)
| CM-B1 teardown ordering (2026-07-20, docs/contracts/CM-PTE-WRITER-MATRIX.md "replacement or
| teardown" protocol): DETACH the parent descriptor and PUBLISH the descriptor
| stores BEFORE the leaf page can reach an allocator.  The stock order freed the
| leaf first and pushed only once at Lf_done -- under a copyback DC the dirty
| PTE-clear lines of an already-recycled leaf page could write back over the new
| owner's data.  a2 = &Bdesc is still live here (the PTE loop and hat_ptfree
| preserve a2).  cpusha dc is a no-op while DC is off / WT -- B2 scaffolding
| that must NOT silently depend on DTT0 staying uncached.
	clrl	%a2@			| Bdesc = 0 (detach the leaf from the tree)
	.word	0xf478			| cpusha dc -- publish PTE clears + Bdesc clear
	movel	%fp@(-4),%sp@-
	jsr	hat_ptfree
	addqw	&4,%sp
Lf_nextB:
	addql	&1,%fp@(-24)
	braw	Lf_B
Lf_freeA:
| V2: FREE the pointer-table page (hat_pteload V2 allocates it via hat_ptalloc = a whole
| page).  hat_ptfree's guards (page-aligned + pfn bounds) leak anything else -- e.g. the
| hat_exec/hat_growsdt 030-written relic tables -- exactly as V1 did.
| CM-B1 reorder (2026-07-20): clear root[A] and publish BEFORE freeing the pointer
| table -- the parent must be detached before its table page can be recycled
| (same protocol as the per-leaf Bdesc detach above; stock order freed first).
	movel	%fp@(-20),%d0
	asll	&2,%d0
	clrl	%a5@(0,%d0:l)		| root[A] = 0 (UDT invalid) -- detach FIRST
	.word	0xf478			| cpusha dc -- publish root[A] clear before table reuse
	movel	%fp@(-32),%sp@-		| pointer-table base (stashed at Lf_A)
	jsr	hat_ptfree
	addqw	&4,%sp
Lf_nextA:
	addql	&1,%fp@(-20)
	braw	Lf_A
Lf_done:
| V2: free the 040 ROOT page (hat_alloc040's kmem_zalloc(0x1000)) and invalidate
| as->hat_root, then flush caches+ATC so no stale user translation references a freed
| table.  Safe: hat_free runs only at AS death (as_free/relvm); kernel/supervisor
| accesses never use urp, and no user-mode access happens before a new root is
| installed (exec installs the new as; exit -> resume loads the next proc's root).
| Mirrors stock 030 hat_free, which frees the SDT here (3B2 vm_hat.c:245 + the
| srama default-SDT switch kludge for the ublock).
| CM-B1 reorder (2026-07-20): retire the root -- clear as->hat_root and publish
| ALL teardown descriptor stores + flush the ATC -- BEFORE kmem_free hands the
| root page back to the allocator.  The stock order (free, clear, push) left a
| window where dirty root lines could write back over a reallocated page (B2)
| and where a stale translation could still name the freed root (matrix: "a
| final whole-cache operation after the frees is too late").
	moveal	%fp@(8),%a0
	clrl	%a0@(20)		| as->hat_root = 0 (detach before the free)
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
	pea	0x1000			| size (kmem_free 2nd arg)
	movel	%a5,%sp@-		| root VA (loaded from as@(20) at entry, callee-saved)
	jsr	kmem_free
	addqw	&8,%sp
	moveml	%fp@(-60),%d2-%d4/%a2-%a5
	moveal	%d0,%a0
	unlk	%fp
	rts
Lf_nullroot:
	moveml	%fp@(-60),%d2-%d4/%a2-%a5
	unlk	%fp
	rts
	| (nops removed: +4B from hat_free040 clrl-PTE fix absorbed here)

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
| V2 (2026-07-02): REAL free.  Under Model B every leaf AND (since the hat_pteload V2
| change) every pointer table is a whole 4KB page from hat_ptalloc/page_get, so the free
| is page_free(pages + (pfn - pages_base)*60, 0).  Guards: page-aligned base + pfn within
| [pages_base, pages_end) -- anything else (hat_exec/hat_growsdt 030-written relics,
| garbage slots, old-style sdtalloc carves) LEAKS exactly as the V1 stub did (logged,
| cap 8).  pp->p_mapping/p_ptdats (offset-32 union) is cleared FIRST so a stale pt_inuse
| count can never be misread as a reverse-map pointer once the page recycles (3B2
| vm/anon page_abort does `if (PP_ISMAPPED) hat_pageunload` on that field).  page_free's
| own entry swap_anon(pp->p_vnode,..) is safe: page_get pages carry no vnode identity.
| Preserves ALL registers (moveml + C callee-saved) -- callers (hat_free B-loop,
| stock hat_unload paths) keep live state across this call.
|
| V3 (2026-08-02, ISSUE-40 part 2): the page's ptdat METADATA is retired before the
| page is.  V2.1 threw away pp->p_ptdats without removing the four records from
| active_pts/free_pts or returning their 64-byte hat_sdtalloc unit, so every table
| page ever allocated left a permanent one-unit crumb in an SDT backing page -- and
| those crumbs are what pinned ISSUE-40's page (part 1 released the legacy SDT and
| got ZERO pages back on hardware; residual p_sdtbits 0x000e5fff .. 0x5fffffff).
| The retirement itself is src/ptdatfree040.s (contract:
| docs/contracts/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md); this routine keeps the page half.
|
| Two changes here beyond the call:
|   * the early `clrl pp@(32)` is GONE from the decision path.  It destroyed the
|     only pointer to the records before this code knew whether it owned the page.
|     p_ptdats is now cleared inside the retirement, still before page_free -- so
|     the "no stale field once the page recycles" invariant is unchanged.
|   * `keepcnt > 1` no longer decrements.  Dropping the hold without retiring the
|     metadata separates the page from the HAT's accounting and leaves no owner
|     that knows which credits and list nodes remain; a counted fail-closed leak is
|     the safer half of that trade (contract P3).  ptd_keepn_n counts it.
| With ptd_on = 0 the whole V2.1 body runs again unchanged (Lpf_old), so the A/B
| control arm is the previous kernel and not a third behaviour.
	moveml	%d0-%d1/%a0-%a2,%sp@-
	movel	%sp@(24),%d0		| table base (20 saved + retaddr + arg0)
	movel	%d0,%d1
	andil	&0xfff,%d1
	bnew	Lpf_leak		| not page-aligned -> not ours -> leak (V1 behavior)
	moveq	&12,%d1
	lsrl	%d1,%d0			| pfn
	cmpl	pages_base,%d0
	bcsw	Lpf_leak
	cmpl	pages_end,%d0
	bccw	Lpf_leak
	subl	pages_base,%d0		| page index
	movel	%d0,%d1
	lsll	&6,%d1			| index * 64
	lsll	&2,%d0			| index * 4
	subl	%d0,%d1			| index * 60 -- no muls.l (ISSUE-34: the 68060
	moveal	%d1,%a2			|   traps every 64-bit muls.l form)
	addal	pages,%a2		| a2 = pp = pages + (pfn - pages_base)*60
| V2.1 (boot-verified V2 hit PANIC page_free: pp@(2) keepcnt!=0): mirror the 3B2 reference
| release (vm_hat.c:2334 PAGE_RELE + accounting).  page_get hands the page out HELD
| (p_keepcnt@(2) = 1) and hat_ptalloc charged availrmem/availsmem/pages_pp_kernel; the
| release must undo both, and page_free panics unless keepcnt/mapping/lck/cow are all 0.
	movel	%a2,%sp@-
	jsr	hat_ptdat_retire	| proves ownership, then REMOVE_PT x4 +
	addqw	&4,%sp			|   hat_sdtfree(ptd,1) + clears p_ptbits/p_ptdats
	tstl	%d0
	beqw	Lpf_release		| 0 = retired -> the page hold is proven 1
	tstl	ptd_on
	beqw	Lpf_old			| gated off -> run the V2.1 body verbatim
	braw	Lpf_ret			| fail closed -> touch NOTHING (counted there)
Lpf_release:
	subqw	&1,%a2@(2)		| PAGE_RELE, proven 1 -> 0
	addql	&1,availrmem
	addql	&1,availsmem
	subql	&1,pages_pp_kernel
	clrl	%sp@-			| dontneed = 0
	movel	%a2,%sp@-		| pp
	jsr	page_free
	addqw	&8,%sp
	addql	&1,ptd_tblfreed_n
| A successful release PUBLISHES a real page, so it is a valid progress event for
| hat_ptalloc's fresh-page retry (it sleeps on &free_pts at 0xb6cd2 under
| HAT_CANWAIT, reachable from hat_pteload and hat_dup under real memory pressure).
| Wake AFTER the accounting and page_free, never on a fail-closed path -- nothing
| became available there.  hat_unlock's existing wake is not a substitute: it
| publishes no page.
	tstl	pt_waiting
	beqw	Lpf_ret
	pea	1
	pea	free_pts
	jsr	wakeprocs
	addqw	&8,%sp
	clrl	pt_waiting
	addql	&1,ptd_wake_n
	braw	Lpf_ret
Lpf_old:
	clrl	%a2@(32)		| clear p_mapping/p_ptdats union (stale pt_inuse)
	tstw	%a2@(2)
	beqw	Lpf_leak		| keepcnt already 0 = not a held page_get page -> leak+log
	subqw	&1,%a2@(2)		| PAGE_RELE: drop our keep (page_get's hold)
	bnew	Lpf_held		| someone else still holds it -> do NOT free
	addql	&1,availrmem
	addql	&1,availsmem
	subql	&1,pages_pp_kernel
	clrl	%sp@-			| dontneed = 0
	movel	%a2,%sp@-		| pp
	jsr	page_free
	addqw	&8,%sp
	braw	Lpf_ret
Lpf_held:
	braw	Lpf_ret			| hold released; another holder keeps the page alive
Lpf_leak:
	movel	Lpf_n,%d0
	cmpil	&8,%d0
	bccw	Lpf_ret			| after 8 prints, silent leak
	addql	&1,%d0
	movel	%d0,Lpf_n
	movel	%sp@(24),%d1		| table arg
	movel	%d1,%sp@-
	pea	Lpf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lpf_ret:
	moveml	%sp@+,%d0-%d1/%a0-%a2
	rts
	nop				| pad .text to a 4-byte multiple

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lpf_msg:
	.asciz	"DBG hat_ptfree LEAK table=%x (guarded: not page-aligned / not in pages[])"
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
Lhul_msg:
	.asciz	"DBG htunload FREELEAF va=%x leaf=%x npgs=%x (pt_inuse hit 0)"
	.even
Lhul_n:
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
Lhfb_msg:
	.asciz	"DBG hatfree BAD-slot A=%x B=%x Bdesc=%x leaf=%x (skipped)"
	.even
Lhfb_n:
	.long	0
Lhfa_msg:
	.asciz	"DBG hatfree BAD-Aslot A=%x Adesc=%x table=%x (skipped)"
	.even
Lhfa_n:
	.long	0
| --- hat_cm_ram: the managed-ordinary-RAM cache-mode class for the caches
| campaign (docs/contracts/CM-PTE-WRITER-MATRIX.md stage table).  B1 = 0x00 (writethrough),
| B2 = 0x20 (copyback).  Read by hat_pteload's Lcm_sel, hat_dup040's private-leaf
| constructor and bp_map040's alias constructor.  GLOBAL + in .data so the stage
| is a 4-byte initializer change (or a boot-time poke) without touching the three
| consumers.
|
| DEFAULT FLIPPED TO COPYBACK 2026-07-30, after ISSUE-38 closed on hardware:
| unix-040-b2-fix38-260730-03 (copyback, NO probes) boots to telnet with
| cb_icode_push=1 and hat_cm_ram=0x20 read back live, and `exectest 20` PASSes on
| it.  Until that day every copyback image had to be produced by patch_b2_flip.py
| from a write-through base, because the probe-less copyback kernel could not boot
| at all: main's copyout(icode) sat in dirty data-cache lines that the 040
| instruction fetch does not snoop (docs/ISSUE38-ICODE-CACHE-FINDING-260730.md,
| src/cb_icode040.s).  The WRITE-THROUGH control is now the derived image:
|   python3 src/patch_b2_flip.py build/unix-040 build/unix-040-wt --wt
| ===========================================================================
| cmf_* -- the framebuffer cache-class census block (change D, 2026-08-19).
|
| WHY IT RECORDS AN ADDRESS RATHER THAN A VALUE.  What has to be proved is what
| ended up IN THE PAGE TABLE, not what the selector decided; those differ if any
| later modifier rewrites the CM field.  So each branch stores the LEAF ADDRESS
| it classified, and the census reads the live PTE from that address afterwards
| through /dev/mem (kernel .data and the leaf tables both sit below 1 GB and are
| identity-mapped, which is what kpeek already relies on).  The counters say the
| branch ran at all; the address says where to look.
|
| a4 holds &leaf at all three Lcm_sel call sites (Lpfnok, Lwleaf, Lreplace) --
| each one stores through it immediately after returning.  INDEPENDENTLY VERIFIED
| against the linked image: the three calls are the only ones in the image, they
| are at 0xd7b10 / 0xd7b84 / 0xd7c80, the callee does not modify a4, and a4 is
| still the leaf at each store.  fp@(20) is the pfn argument at all three, which
| is the other invariant change D rests on.
|
| Unconditional rather than kdbg_on-gated: two instructions on the pp==NULL path
| only, no effect on managed-RAM loads, no live register or condition code
| disturbed, and every hat_pteload exit already pays for cpusha bc + pflusha.
| A gate would weaken the acceptance evidence rather than protect anything.
| hat_pfnmiss_n a few hundred lines up is the precedent for an uncapped counter
| here.  It is an INSTRUMENT: keeping it is a decision to take deliberately, not
| something that should become permanent telemetry by drifting.
|
| WHAT IT DOES AND DOES NOT SUPPORT -- state these before trusting a reading:
|   * cmf_*_n count SELECTOR EVENTS, not unique pages.  The retained 2 KiB segdev
|     stepping can classify the same 4 KiB leaf twice, so require a positive
|     delta, never exactly one.
|   * cmf_magic is an IMAGE SIGNATURE, not a consistency guard: it says the
|     addresses belong to this build, not that the latch is fresh.
|   * the latch is valid only after the faulting access has returned and before
|     the mapping is torn down.
|   * it is a SAMPLER.  Fault ONE page at a time with everything else quiescent,
|     or the most recent leaf belongs to somebody else.
|   * a leaf address masked to its table base describes 64 pages = 256 KiB ONLY.
|     A 4 MB aperture spans at least 16 such tables and a 32 MB one at least 128,
|     so this cannot seed a whole-aperture walk.  Minimum and maximum leaf
|     addresses do not repair that, because page-table allocation order is not VA
|     order.
| A complete per-VA census would need the test process's root.  The cheap way to
| get it, if it is ever wanted, is to latch it at the same event: fp@(8) is the
| seg, seg@(12) its address space, as@(20) the root hat_pteload already uses.
| Deliberately NOT added: nothing uses it yet, and unexercised code is not code
| that works.
| ===========================================================================
	.globl	cmf_magic
	.balign 4
cmf_magic:
	.long	0x434d4642		| "CMFB"
	.globl	cmf_fb_n
cmf_fb_n:
	.long	0			| leaves classified as registered framebuffer (0x60)
	.globl	cmf_fb_leaf
cmf_fb_leaf:
	.long	0			| address of the most recent such leaf
	.globl	cmf_ncs_n
cmf_ncs_n:
	.long	0			| leaves classified as unmanaged/MMIO (0x40)
	.globl	cmf_ncs_leaf
cmf_ncs_leaf:
	.long	0			| address of the most recent such leaf

| --- hat_cm_fb: the registered framebuffer PFN intervals, two slots of
| {lo, hi} half-open PFNs, all zero = none registered = pre-change-D behaviour.
| Two slots because the VA2000 driver supports two boards; written only by
| hat_cm_fb_add, read only by Lcm_dev.  GLOBAL so a census probe can read it.
|
| LAYOUT CONTRACT: this table must stay IMMEDIATELY AFTER the cmf_* block above,
| i.e. at cmf_magic+20, because test-tools/cmfcensus.c reads the intervals at
| that fixed offset from the one address it is given.  Moving it apart is
| allowed, but then the tool needs a second address -- do not let them drift
| silently, which is the whole failure mode the magic word exists for.
	.globl	hat_cm_fb
	.balign 4
hat_cm_fb:
	.long	0			| slot 0 lo
	.long	0			| slot 0 hi
	.long	0			| slot 1 lo
	.long	0			| slot 1 hi

	.globl	hat_cm_ram
	.balign 4
hat_cm_ram:
	.long	0x00000020		| B2: CM=01 copyback for managed RAM (default since 2026-07-30)
	.balign 4
Lbt_ptl_done:
	.long	0			| btrace 'P' one-shot guard (first hat_pteload)
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
