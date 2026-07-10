| vtop040.s -- override vtop (0xb7568, GLOBAL T) for the 68040 DTT0 identity region.
|
| vtop(va, proc) returns the PHYSICAL address used to program disk DMA
| (alien/dd.c:240  dp->com.addr = vtop(bp->b_un.b_addr, bp->b_proc)).  For va < 0x40000000 the
| DTT0 transparent-translation register makes phys == va (identity), so return va directly; for
| va >= 0x40000000 (kvseg / per-proc user) defer to stock vtop (svirtophys / user walk).
|
| 2026-06-27 DIAGNOSTIC: the child-crash corruptor is a disk DMA that writes a 0xFF block into a
| user page (sh's data page, e.g. phys 0x07CAB000) -- proven via fs-uae (the 0xFFFFFFFF appears with
| NO CPU write; it is SCSI put_byte = DMA).  vtop computes the DMA target phys.  Log every vtop whose
| RESULT lands in the high page pool [0x07800000,0x08000000) (where user data pages live) with the
| buffer va, proc and caller -> tells us WHICH I/O (which buffer/proc/path) targets the page that is
| also sh's mapped data page (= the double-allocation), and whether the buffer va is a kernel
| identity VA (buffer cache / pagein) or a user VA (raw I/O).  Capped at 40.
|
| vtop(va, proc): va @ fp@(8), proc @ fp@(12); returns paddr in d0 (and a0).
| (--add-symbol vtop_orig=.text:0xb7568; --weaken-symbol vtop so this strong def wins.)

	.text
	.globl	vtop
vtop:
	linkw	%fp,&0
	movel	%d2,%sp@-		| save d2 (callee-saved; holds the result)
	movel	%fp@(8),%d0		| d0 = va
	cmpil	&0x40000000,%d0
	bccw	Lvt_stock
	movel	%d0,%d2			| identity: phys == va
	braw	Lvt_log
Lvt_stock:
	movel	%fp@(12),%sp@-		| proc
	movel	%fp@(8),%sp@-		| va
	jsr	vtop_orig
	addqw	&8,%sp
	movel	%d0,%d2			| stock result (svirtophys / user walk)
Lvt_log:
	cmpil	&0x07c00000,%d2		| user-page region (below the 0x7EEx buffer cache)
	bcsw	Lvt_done
	cmpil	&0x07e00000,%d2
	bccw	Lvt_done
	movel	Lvt_n,%d0
	cmpil	&200,%d0
	bccw	Lvt_done
	addql	&1,%d0
	movel	%d0,Lvt_n
	movel	%fp@(4),%sp@-		| caller (return addr at vtop entry)
	movel	%fp@(12),%sp@-		| proc
	movel	%fp@(8),%sp@-		| va (buffer)
	movel	%d2,%sp@-		| phys (DMA target)
	pea	Lvt_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lvt_done:
| ISSUE-10 v6 (2026-07-10): vtop computes every disk-DMA target (alien/dd.c).  PGALIAS
| proved page_get never hands out mapped pages, and SEGVPP showed sh's page is (most
| plausibly) a LEGIT anon page whose CONTENT gets overwritten with 1KB-buffer-granular
| directory/file bytes -> the writer is a DMA aimed at the wrong phys.  Chokepoint check:
| translate the DMA target phys -> page_t (page_numtouserpp) and if that page has a LIVE
| MAPPING (p_mapping != 0), the DMA is about to overwrite somebody's mapped page -> log
| va/phys/map/caller (cap 16).  Normal traffic stays silent: buffer-pool pages are
| unmapped kernel identity pages, and pagein DMA happens BEFORE hat_pteload registers.
	tstl	%fp@(12)		| proc != 0 = raw/physio user I/O -> mapped target is LEGIT
	bnew	Lvt_ret
	movel	%d2,%d0
	andil	&0xfffff000,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0			| pfn of the DMA target
	movel	%d0,%sp@-
	jsr	page_numtouserpp
	addqw	&4,%sp
	movel	%d0,%d1
	andil	&0xf0000000,%d1
	cmpil	&0x40000000,%d1		| pp must be kvseg to deref
	bnew	Lvt_ret
	moveal	%d0,%a0
	tstl	%a0@(32)		| p_mapping live?
	beqw	Lvt_ret
	movel	Lva_n,%d0
	cmpil	&16,%d0
	bccw	Lvt_ret
	addql	&1,%d0
	movel	%d0,Lva_n
	movel	%fp@(4),%sp@-		| caller
	movel	%a0@(32),%sp@-		| p_mapping (whose PTE the DMA is about to shoot)
	movel	%d2,%sp@-		| phys (DMA target)
	movel	%fp@(8),%sp@-		| va (buffer)
	pea	Lva_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lvt_ret:
	movel	%d2,%d0			| return paddr in d0
	moveal	%d2,%a0			| and a0 (vtop returns both)
	movel	%fp@(-4),%d2		| restore d2
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lvt_n:
	.long	0
Lvt_msg:
	.asciz	"DBG vtop pool phys=%x va=%x proc=%x caller=%x"
	.even
Lva_n:
	.long	0
Lva_msg:
	.asciz	"DBG VTOPALIAS va=%x phys=%x map=%x caller=%x (DMA target page has a LIVE mapping!)"
	.even
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
