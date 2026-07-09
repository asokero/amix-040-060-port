| quiet040.s -- QUIET twin of the dbg overlay (2026-07-06): the load-bearing overrides
| from the unix-040-dbg build WITHOUT any probe output.  Built into unix-040-quiet by
| relink-040-quiet.sh (on top of the fully-patched build/unix-040, like the dbg build).
|
| PURPOSE: a serial-capable kernel for real-HW testing whose serial log carries ONLY the
| real console stream (banner / cmn_err / panics via the serdbg.s conputc mirror) -- no
| C<pid>:PC:SR clock samples, no idle W-dumps, no P/S/W/R/I markers, no DBG wrappers.
| The MAIN debug line stays unix-040-dbg on the emulator; keep the two functionally
| IDENTICAL so a dbg-vs-quiet behaviour difference isolates the probes themselves.
|
| Source of truth for each override (keep in sync when those change):
|   sched / schedpaging / idle / resume  <- prototypes/mainmarks.s   (minus markers/W-dump)
|   hardbus page-crossing fix            <- prototypes/sigkill_dbg.s (minus all logging;
|                                           clock_sampler / sigtoproc / getdents NOT taken --
|                                           they are pure diagnostics)
| NOT taken (pure diagnostics): ddopen_dbg blkatoff_dbg assegat_dbg execmark hatalloc_dbg
| ktrap_latch kmem_validate segvn_softunlock_dbg preempt_dbg(+tourniquet) segu_swap_dbg.
| NOTE: dropping preempt_dbg also drops the ISSUE-7 tourniquet -- a boot from a kernel-
| contaminated disk may hit the raw pc=0x4000001E panic here that the dbg build masks.
| NOTE (2026-07-07): hat_dup is NO LONGER overridden here -- the real hat_dup040 port
| (ISSUE-4) is now a finalized strong override in the base build/unix-040 this overlay
| links against; re-weakening it here would just re-open it to being shadowed by
| something else, which we don't want (same reasoning as relink-040-dbg.sh).

	.text
| ---------------------------------------------------------------------------
| sched OVERRIDE (mainmarks.s minus markers) -- proc-0 swapper loop: keep dispatching.
| A one-shot `jsr swtch; spin` deadlocks init the moment proc 1 yields; the loop lets
| swtch hand the CPU back to proc 1 (or idle) each time.  --weaken-symbol sched.
	.globl	sched
sched:
	linkw	%fp,&0
Lq_sch:
	jsr	swtch
	braw	Lq_sch
	nop

| ---------------------------------------------------------------------------
| schedpaging OVERRIDE (mainmarks.s minus marker) -- skip paging-daemon tuning
| (harmless with free memory; same behaviour as the dbg build).  --weaken-symbol.
	.globl	schedpaging
schedpaging:
	rts

| ---------------------------------------------------------------------------
| idle OVERRIDE (mainmarks.s minus 'I' marker + W-dump) -- stock idle wait.
	.globl	idle
idle:
	stop	&0x2000
	rts

| ---------------------------------------------------------------------------
| hardbus PAGE-CROSSING FIX (sigkill_dbg.s minus all logging) -- GENUINE fix, verbatim
| logic.  A multi-word instruction whose extension words cross into a not-yet-resident
| page makes the 040 report FA = the crossing access's START (the mapped page); the
| 030-semantic usrxmemflt tail misroutes the fault to hardbus, which finds the phys OK,
| returns 0, the CPU retries -> infinite loop (the `date` hang).  For USER addresses
| within 8 bytes of a page end: as_fault BOTH the operand's page AND the next page
| (read, F_INVAL); either resolving -> return 0 and retry.  Both fail -> genuine hardbus.
| --weaken-symbol hardbus + --add-symbol hardbus_orig=.text:0x5b3c2.
	.globl	hardbus
hardbus:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(8),%d0		| addr
	cmpil	&0x80000000,%d0
	bcsw	Lq_hbnorm		| kernel/low address -> normal hardbus
	movel	%d0,%d1
	andil	&0xfff,%d1
	cmpil	&0xff8,%d1
	bcsw	Lq_hbnorm		| not within 8 bytes of page end -> normal hardbus
	andil	&0xfffff000,%d0
	movel	%d0,%d3			| d3 = current page base
| -- resolve the CURRENT page (usually already valid -> cheap no-op) --
	pea	1			| rw = read
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d3,%sp@-
	moveal	u+0x730,%a0
	movel	%a0@(124),%sp@-		| as = curproc->p_as
	jsr	as_fault
	lea	%sp@(20),%sp
	movel	%d0,%d2			| remember current-page result
| -- resolve the NEXT page (the actual crossing target) --
	addil	&0x1000,%d3
	pea	1			| rw = read
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d3,%sp@-
	moveal	u+0x730,%a0
	movel	%a0@(124),%sp@-
	jsr	as_fault
	lea	%sp@(20),%sp
	tstl	%d0
	beqw	Lq_hbfixed		| next page mapped -> retry
	tstl	%d2
	beqw	Lq_hbfixed		| current page (re)resolved -> retry
	braw	Lq_hbnorm		| both failed -> genuine hard-error path
Lq_hbfixed:
	clrl	%d0			| return 0 = not a hard error, retry
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts
Lq_hbnorm:
	movel	%fp@(12),%sp@-		| ptep
	movel	%fp@(8),%sp@-		| addr
	jsr	hardbus_orig
	addqw	&8,%sp
	moveml	%fp@(-8),%d2-%d3	| d0 = hardbus_orig's ret, untouched
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| resume (0x9c, GLOBAL T) -- 040 context-switch core, VERBATIM from mainmarks.s
| (2026-06-23 reliability fix + 2026-07-04 ISSUE-7 u_va==0 remap; resume in mainmarks
| emits no serial itself, so this IS the identical code).  See mainmarks.s for the full
| history/rationale.  Summary:
|  * read the saved context from the STABLE kvsegu VA (curproc@252 + 0x318), not the
|    fixed VA after the remap (040 cache/timing-fragile -> intermittent wild jmp).
|  * remap the FIXED-VA u-area (uarea_pt = kptr040[0] leaf) to the NEW proc's u-pages:
|    path U = p_ubptbl (proc 0 / static u-area, 2KB clicks -> 4KB PTEs, keep live flags),
|    path V = walk kptr040 for u_va (forked/kvsegu proc, PTEs already 4KB).
|  * u_va==0 (proc 0) MUST also remap via path U (stock resume writes *ublksde
|    unconditionally); skip only if p_ubptbl[0]==0 too (pre-p0init early boot).
| --weaken-symbol resume.  globals: curproc (C), kptr040 (D).
	.globl	resume
resume:
	moveal	curproc,%a1
	movel	%a1@(252),%d1		| d1 = u_va (new proc's u-area kvsegu VA; 0 for proc 0)
	moveal	%sp@(4),%a0		| a0 = arg1 = u+0x318 (fixed VA) -- default read source
	movew	%sr,%d0			| d0 = sr (preserved to the end)
	movew	&0x2700,%sr		| mask interrupts for the remap
	tstl	%d1
	bnew	Lq_remap		| u_va!=0 -> forked/kvsegu proc: remap (path U/V dispatch)
	moveal	curproc,%a3
	movel	%a3,%d3
	addil	&95,%d3
	andil	&0xfffffff0,%d3
	moveal	%d3,%a3			| a3 = &p_ubptbl = (proc+95)&~15 (same calc as path U)
	tstl	%a3@
	beqw	Lq_rest			| no u_va AND no p_ubptbl: early boot, old behaviour safe
Lq_remap:
	moveal	kptr040,%a2
	movel	%a2@,%d2
	andil	&0xffffff00,%d2		| d2 = uarea_pt base = kptr040[0] & ~0xFF
	moveal	%d2,%a2			| a2 = uarea_pt
	moveal	curproc,%a3
	movel	%a3,%d3
	addil	&95,%d3
	andil	&0xfffffff0,%d3
	moveal	%d3,%a3			| a3 = &p_ubptbl = (proc+95)&~15
	tstl	%a3@
	beqw	Lq_kvsegu		| p_ubptbl[0]==0 -> forked proc, walk kvsegu
|	--- path U: p_ubptbl (proc 0 / static u-area); 2KB click -> 4KB 040 PTE, keep live flags ---
	movel	%a2@,%d3
	andil	&0x00000fff,%d3		| d3 = live 040 leaf status flags (e.g. 0x0F9)
	movel	%a3@,%d4		| uarea_pt[0] = (p_ubptbl[0] phys & ~0xFFF) | flags
	andil	&0xfffff000,%d4
	orl	%d3,%d4
	movel	%d4,%a2@
	movel	%a3@(8),%d4		| uarea_pt[1] = (p_ubptbl[2] phys & ~0xFFF) | flags (4KB stride)
	andil	&0xfffff000,%d4
	orl	%d3,%d4
	movel	%d4,%a2@(4)
	braw	Lq_flush
Lq_kvsegu:
|	--- path V: forked proc -- walk kptr040 for u_va & u_va+0x1000 (already 040 4KB leaf PTEs) ---
	movel	%d1,%d4			| page 0: index kptr040 for u_va
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4		| leaf table base
	movel	%d1,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@		| uarea_pt[0] = kvsegu leaf PTE for u_va
	movel	%d1,%d3			| page 1: u_va + 0x1000
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
	movel	%a3@,%a2@(4)		| uarea_pt[1] = kvsegu leaf PTE for u_va+0x1000
Lq_flush:
	.word	0xf4f8			| cpusha bc -- push the uarea_pt writes to RAM for the HW tablewalk
	.word	0xf518			| pflusha -- invalidate the ATC (fixed-VA stack now remaps away!)
Lq_rest:
	moveml	%a0@,%d2-%d7/%a1-%sp
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
