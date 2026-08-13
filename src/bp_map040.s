| bp_map040.s -- Model-B / 68040 port of bp_map + bp_mapout (ISSUE-13 fix).
|
| The temporary page-I/O mapper (bp_mapin -> bp_map) and its teardown (bp_mapout)
| were left as the STOCK 030 bodies in the 040 port (Codex census 00eb869,
| PAGEIO-BPMAPIN-TEMP-MAPPING-AUDIT.md).  bp_mapin's ALLOCATION side was byte-patched
| to 4 KiB, but the inner mapper bp_map still:
|   - counts 2 KiB pages ((bcount+off+0x7ff)>>11),
|   - walks the RETIRED st_top1 tree (which the 040 port zeros and does NOT populate
|     for syssegs -- sysseginit fills kptr040 instead),
|   - builds an old-format PTE with pfn<<11.
| For a syssegs VA whose st_top1 descriptor is zero, the stock body derives a zero
| leaf base and stores pfn<<11|1 at a tiny LOW-MEMORY offset -> deterministic
| wrong-tree corruption, and the requested translation never appears in the live
| 040 tree (root040->kptr040->kptbl) that the MMU actually walks.  bp_mapout has the
| mirror defect on the clear side.  Active callers: nfs_getapage/nfs_writelbn +
| RFS -- i.e. exactly the real-HW NFS-copy panic chain (ISSUE-13 capture 1).
|
| This override rewrites BOTH functions to use the live 040 tree via the same
| kptr040 geometry as vatosde/vatopte (src/kvm040.s), 4 KiB units, and the
| proven live kvseg leaf-PTE format phys|0x19 (resident, supervisor-writable,
| cacheable-writethrough, U/M preset -- verified by reading live kptr040 leaves).
| It keeps the stock GHOST-MAPPING contract: no pp->p_mapping linkage, no
| ref/mod/keep-count bookkeeping (unlike segkmem_mapin) -- these are transient
| I/O windows owned by the sptmap virtual slot, not managed page mappings.
|
| Wired: --add-symbol bp_map_orig / bp_mapout_orig NOT needed (full replacements);
| --weaken-symbol bp_map + --weaken-symbol bp_mapout, strong defs here win and
| bp_mapin re-resolves bp_map automatically (relink-040.sh / relink-040-dbg.sh).
|
| Externals: kptr040, pages, pages_base (all referenced by the existing 040 kernel),
| sptmap, rmfree.  040 privileged ops emitted as .word: cpusha bc = 0xf4f8,
| pflusha = 0xf518 (same encodings pstart040.s uses).

	.text

| ============================================================================
| bp_map(bp, va) -- map bp's B_PAGEIO page list into consecutive 4 KiB kernel
| pages starting at va (the sptmap slot VA bp_mapin allocated).  Returns end va.
| buf offsets (verified vs stock disasm): b_flags @0, b_bcount @32, b_un.b_addr
| @36, b_pages @60; page-list link @16.
| ============================================================================
	.globl	bp_map
bp_map:
	linkw	%fp,&0
	moveml	%d2/%d3/%a2/%a3,%sp@-
	moveal	%fp@(8),%a2		| a2 = bp
	movel	%fp@(12),%d3		| d3 = va (running)
	| npages = (b_bcount + (b_addr & 0xfff) + 0xfff) >> 12
	movel	%a2@(36),%d0
	andil	&0xfff,%d0
	addl	%a2@(32),%d0
	addil	&0xfff,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0
	movel	%d0,%d2			| d2 = npages
	moveal	%a2@(60),%a3		| a3 = b_pages (first page_t)
Lbm_loop:
	subql	&1,%d2
	moveq	&-1,%d1
	cmpl	%d2,%d1
	beqw	Lbm_done		| npages iterations done
	| --- live leaf-PTE address for d3=va (vatosde+vatopte geometry) ---
	movel	%d3,%d0
	moveq	&18,%d1
	lsrl	%d1,%d0
	subil	&4096,%d0		| (va>>18) - 4096
	asll	&2,%d0
	addl	kptr040,%d0		| &kptr040[idx]
	moveal	%d0,%a0
	movel	%a0@,%d0		| pointer descriptor
	andil	&0xffffff00,%d0		| leaf table base
	beqw	Lbm_next		| no leaf -> skip (must not write low mem)
	moveal	%d0,%a1
	movel	%d3,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0			| va>>12
	andil	&0x3f,%d0
	asll	&2,%d0
	addal	%d0,%a1			| a1 = &PTE
	| --- pfn = (pp - pages)/60 + pages_base ; PTE = (pfn<<12) | 0x19 ---
	movel	%a3,%d0
	subl	pages,%d0
	moveq	&60,%d1
	divsll	%d1,%d0			| d0 = d0 / 60
	addl	pages_base,%d0
	moveq	&12,%d1
	lsll	%d1,%d0			| phys page base
	oril	&0x19,%d0		| resident|W=0|U|M, CM=writethrough (base class)
	orl	hat_cm_ram,%d0		| CM-B1: managed-RAM stage class (0x00 WT / B2 0x20 CB;
					|   matrix bp_map row: temporary MANAGED page alias must
					|   track the RAM class, not stay hardcoded)
	movel	%d0,%a1@		| write live 040 leaf PTE
Lbm_next:
	moveal	%a3@(16),%a3		| next page in I/O list
	addil	&4096,%d3		| va += 4 KiB
	braw	Lbm_loop
Lbm_done:
	.word	0xf4f8			| cpusha bc  -- push PTE writes out of D-cache
	.word	0xf518			| pflusha    -- invalidate stale ATC entries
	movel	%d3,%d0			| return end va
	moveml	%fp@(-16),%d2/%d3/%a2/%a3
	moveal	%d0,%a0
	unlk	%fp
	rts

| ============================================================================
| bp_mapout(bp) -- tear down the temporary mapping established by bp_map.
| Clears the live leaf PTEs by VA (does not need the page list), publishes the
| clears (cpusha bc + pflusha), returns the sptmap slots, restores the byte
| offset in b_un.b_addr, and clears B_REMAPPED.
| ============================================================================
	.globl	bp_mapout
bp_mapout:
	linkw	%fp,&0
	moveml	%d2/%d3/%d4/%a2,%sp@-
	moveal	%fp@(8),%a2		| a2 = bp
	movel	%a2@,%d0
	andil	&0x100000,%d0		| B_REMAPPED?
	beqw	Lmo_done
	| base va = b_addr & 0xfffff000
	movel	%a2@(36),%d0
	andil	&0xfffff000,%d0
	movel	%d0,%d3			| d3 = va (running)
	| npages = (b_bcount + (b_addr & 0xfff) + 0xfff) >> 12
	movel	%a2@(36),%d0
	andil	&0xfff,%d0
	addl	%a2@(32),%d0
	addil	&0xfff,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0
	movel	%d0,%d2			| d2 = npages (kept for rmfree)
	movel	%d2,%d4			| d4 = loop counter
Lmo_loop:
	subql	&1,%d4
	moveq	&-1,%d1
	cmpl	%d4,%d1
	beqw	Lmo_free
	| --- live leaf-PTE address for d3=va ---
	movel	%d3,%d0
	moveq	&18,%d1
	lsrl	%d1,%d0
	subil	&4096,%d0
	asll	&2,%d0
	addl	kptr040,%d0
	moveal	%d0,%a0
	movel	%a0@,%d0
	andil	&0xffffff00,%d0
	beqw	Lmo_step		| no leaf -> skip (never write low mem)
	moveal	%d0,%a1
	movel	%d3,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	addal	%d0,%a1
	clrl	%a1@			| clear live 040 leaf PTE
Lmo_step:
	addil	&4096,%d3
	braw	Lmo_loop
Lmo_free:
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
	| rmfree(&sptmap, npages, base>>12)
	movel	%a2@(36),%d0
	andil	&0xfffff000,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0
	movel	%d0,%sp@-		| slot = base>>12
	movel	%d2,%sp@-		| npages
	pea	sptmap
	jsr	rmfree
	lea	%sp@(12),%sp
	| restore byte offset in b_un.b_addr, clear B_REMAPPED
	andil	&0xfff,%a2@(36)
	moveal	%a2,%a0
	andil	&0xffefffff,%a0@
Lmo_done:
	moveml	%fp@(-16),%d2/%d3/%d4/%a2
	unlk	%fp
	rts
	nop				| pad .text to 4-byte multiple (loader copies text+data as one block)

	.balign	4			| bss placement: rel.c puts .bss at data_end UNALIGNED
	.data
	.balign	4
