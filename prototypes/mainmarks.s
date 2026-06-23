| mainmarks.s -- DBG-layer overrides for the 040 bring-up.
|   * resume  -- the 040 context-switch u-area remap FIX (see resume040.s / RESUME-HERE for the
|                root-cause writeup).  Kept in the DBG layer (NOT the base) because adding it to
|                the base relink made the AmigaOS loader GURU (8000 0006) before kernel start;
|                in the dbg layer (as in the milestone build) it loads & runs fine.
|   * schedpaging -- one-shot milestone marker (swapconf returned -> proc-1 setup).
| Pairs with forkdbg.o (hat_dup/anon_resv stubs).  --weaken-symbol resume schedpaging.

	.text
| ---------------------------------------------------------------------------
| resume (0x9c, GLOBAL T) -- 040 context-switch core with the u-area remap fix.
| The 030 resume writes *ublksde (= &st_top1[0].word2) to repoint the u-area at the new proc's
| page table -- a no-op on 040 (st_top1 inert).  FIX: the u-area's 040 ptr descriptor is
| kptr040[0] -> a FIXED 256-aligned leaf `uarea_pt`.  Read u_va=curproc@(252) (segu_get's
| u-area VA; curproc set by swtch@b91fa before jsr resume), walk kptr040 for u_va & u_va+0x1000
| (vatosde/vatopte INLINE), copy the 2 leaf PTEs into uarea_pt[0],[1], pflusha, restore.
| u_va==0 -> skip (proc 0/early).  globals: curproc (C), kptr040 (D, pstart040 export).
	.globl	resume
resume:
	moveal	%sp@(4),%a0		| a0 = arg1 = u+0x318 restore buffer -- KEEP for the moveml
	movew	%sr,%d0			| d0 = sr (preserved to the end)
	movew	&0x2700,%sr		| mask interrupts during the remap
	moveal	curproc,%a1
	movel	%a1@(252),%d1		| d1 = u_va = the new proc's u-area kvsegu VA
	beqw	Lr_rest			| u_va==0 -> skip remap (proc 0 / early boot)
	moveal	kptr040,%a1
	movel	%a1@,%d2
	andil	&0xffffff00,%d2		| d2 = uarea_pt base = kptr040[0] & ~0xFF
	moveal	%d2,%a2			| a2 = uarea_pt (the fixed 256-aligned u-area leaf table)
|	--- page 0: walk kptr040 for u_va -> leaf PTE -> uarea_pt[0] ---
	movel	%d1,%d4
	moveq	&18,%d5
	lsrl	%d5,%d4			| u_va>>18
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4		| &kptr040 pointer descriptor (vatosde)
	moveal	%d4,%a3
	movel	%a3@,%d4		| *sde = leaf | UDT
	andil	&0xffffff00,%d4		| leaf table base
	movel	%d1,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5			| u_va>>12
	andil	&0x3f,%d5
	asll	&2,%d5			| (u_va>>12 & 0x3f)*4
	addl	%d5,%d4			| &leaf PTE (vatopte)
	moveal	%d4,%a3
	movel	%a3@,%a2@		| uarea_pt[0] = *PTE
|	--- page 1: walk kptr040 for u_va+0x1000 -> uarea_pt[1] ---
	movel	%d1,%d3
	addil	&0x1000,%d3
	movel	%d3,%d4
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4
	movel	%d3,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@(4)		| uarea_pt[1] = *PTE
Lr_rest:
	.word	0xf4f8			| cpusha bc (68040) -- push uarea_pt descriptor writes to RAM
	.word	0xf518			| pflusha (68040) -- invalidate the ATC
|	DIAGNOSTIC (2026-06-23): print the TRANSFER TARGET, then HALT (no scroll/wrap -- the screen
|	freezes with this line visible).  a0 = u+0x318 (remapped to the new proc), still the caller's
|	(proc 0) stack here (no moveml yet) so cmn_err is safe.  The saved a1 (a0@(24)) is the address
|	`jmp %a1@` will jump to = the proc's resume PC.  SANE values prove the switch is REAL:
|	  a1 = 0x070B904C  -> swtch+0x20 (a proc saved by swtch resumes here)  -> REAL transfer.
|	  a1 = 0x070418F8  -> procdup post-save (a freshly created proc's first dispatch) -> REAL.
|	  a1 = garbage / 0x48xxxxxx / high-RAM -> the context is WRONG -> the "breakthrough" was a
|	       misread (the user's hypothesis), the switch does NOT really transfer.
|	d1 = u_va (from the walk; 0 if proc 0 / skipped).  sp(a0@(48)) = the proc's saved kernel sp.
	movel	%a0@(48),%sp@-		| arg3 = saved sp
	movel	%a0@(24),%sp@-		| arg2 = saved a1 = the jmp target (resume PC)
	movel	%d1,%sp@-		| arg1 = u_va
	pea	Lrt_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lr_halt:
	bra.w	Lr_halt			| FREEZE here -- read the transfer target off the screen
	moveml	%a0@,%d2-%d7/%a1-%sp	| (unreached) restore the new proc's context
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@

| ---------------------------------------------------------------------------
| schedpaging (GLOBAL T) -- one-shot milestone marker: swapconf returned -> proc-1 setup.
	.globl	schedpaging
schedpaging:
	linkw	%fp,&0
	movel	Lsp_n,%d0
	bnew	Lsp_ret
	moveq	&1,%d0
	movel	%d0,Lsp_n
	pea	Lsp_msg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
Lsp_ret:
	unlk	%fp
	rts
	nop

	.data
Lsp_msg:
	.asciz	"DBG MARK: schedpaging (swapconf returned) -- entering proc-1 setup"
	.even
Lrt_msg:
	.asciz	"DBG resume XFER uva=%x a1=%x sp=%x (HALT -- this is the jmp target)"
	.even
Lsp_n:
	.long	0
