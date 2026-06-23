| mainmarks.s -- progress markers for the post-swapconf phase of main().
|
| ORDER NOTE (2026-06-22): sys_forkret_hook is placed FIRST and structured to MIRROR the
| proven-working schedpaging marker (linkw first, one-shot via movel/bnew).  The previous
| layout had the hook LAST in this file (link addr 0xd8128, the very tail of .text) and
| entered it with a `movel <.data>,%d0` as its first instruction (no frame); it reproducibly
| double-panicked with a bogus "Line-F vector 0xB @ pc=0xd812c" -- SAME pc for two different
| hook bodies -> the tail address / no-frame entry was the trigger, not the hook logic.
| Mirroring schedpaging (which lives early in .text and works) de-risks both variables.

	.text
| ---------------------------------------------------------------------------
| sched OVERRIDE -- replaces the swapper loop entry (proc 0, called once by main() AFTER
| all 4 daemons are created).  CRITICAL MECHANISM NOTE (2026-06-22): every DETOUR (byte-
| patch a kernel function's prologue with `jmp <hook>`) into this mainmarks.o code
| reproducibly double-panicked with a bogus "Line-F vector 0xB" AT THE HOOK'S FIRST
| INSTRUCTION (a harmless linkw) -- setbackdq, sys_forkret, AND sched detours all failed
| identically, while the --weaken-symbol OVERRIDE schedpaging (entered by the kernel's own
| relink-resolved `jsr schedpaging`) WORKS.  So: detour-jmp entry into relinked code is
| broken on this 040 setup; the jsr-override entry is fine.  This converts the sched probe
| to an OVERRIDE: --weaken-symbol sched makes main's `jsr sched` resolve here.
| It prints maxrunpri ONCE and then spins (measurement only -- we just need the value):
|   maxrunpri >= 0  -> children ARE enqueued+visible -> bug is in swtch/resume (040 ctx).
|   maxrunpri == -1 -> the CL_FORKRET->sys_forkret->setbackdq enqueue did NOT run on 040.
| newproc gives every child SLOAD (proven: child p_flag = (parent & 0x300000) | 0x10) and
| setbackdq makes a SLOAD proc visible by setting maxrunpri, yet swtch idles only when
| maxrunpri == -1 -- this measurement resolves that contradiction.
	.globl	sched
sched:
	linkw	%fp,&0
	movel	maxrunpri,%sp@-		| THE value (-1 == nothing visible to swtch)
	pea	Lsch_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp		| pop 3 longs
|	--- SAFE diagnostic (2026-06-23): read dq_first's SAVED CONTEXT = the address resume would
|	jmp to -- WITHOUT switching/remapping/mid-switch cmn_err/wild-jmp.  All reads go through the
|	already-live kvsegu mapping (kptr040), in the proven-safe sched context (proc 0, low IPL).
|	dq_first = *(dispq + maxrunpri*12).  Its u-area VA = proc@(252).  save() stored the proc's
|	context at u-area+0x318: saved a1 (the jmp target) = +0x318+24, saved sp = +0x318+48.
|	  a1 = 0x070418F8 -> procdup post-save (a freshly created daemon, never run) -> VALID context,
|	       the switch WOULD transfer correctly; the earlier instability was elsewhere (cache/jmp).
|	  a1 = 0x070B904C -> swtch+0x20 (a proc previously saved by swtch) -> also VALID.
|	  a1 = garbage    -> procdup's save()/setuctxt did NOT build a valid 040 child context ->
|	       THE real bug (resume had nothing valid to jmp to; "breakthrough" was a misread).
	movel	maxrunpri,%d0
	movel	%d0,%d1
	asll	&1,%d0
	addl	%d1,%d0
	asll	&2,%d0			| maxrunpri*12 (sizeof dispq_t)
	movel	%d0,%a0
	addal	dispq,%a0		| &dispq[maxrunpri]
	moveal	%a0@,%a1		| a1 = dq_first (the proc swtch would dispatch)
	movel	%a1@(252),%d2		| d2 = u_va = proc@(252) (kvsegu VA)
	beqw	Lsch_spin		| u_va==0 -> can't read its context, skip
	moveal	%d2,%a2
	addal	&0x318,%a2		| a2 = u_va + 0x318 (the save buffer)
	movel	%a2@(48),%sp@-		| arg3 = saved sp
	movel	%a2@(24),%sp@-		| arg2 = saved a1 = the resume jmp target
	movel	%d2,%sp@-		| arg1 = u_va
	pea	Lst_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp		| pop 5 longs
	jsr	swtch			| now do the REAL switch (resume is reliability-fixed).
					| If it transfers, resume jmps to the child -> never returns here.
	movel	maxrunpri,%sp@-		| only reached if swtch did NOT transfer
	pea	Lret_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lsch_spin:
	bra.w	Lsch_spin		| halt here
	nop				| pad .text to a 4-byte multiple

| ---------------------------------------------------------------------------
| schedpaging (GLOBAL T) -- FIRST call after swapconf returns.  Override to print a
| one-shot marker and RETURN (skip the paging-daemon tuning -- harmless with free memory).
| If "MARK: schedpaging" prints, swapconf completed and we are in proc-1 setup.
| schedpaging GLOBAL T -> --weaken-symbol.
	.globl	schedpaging
schedpaging:
	linkw	%fp,&0
	movel	Lsp_n,%d0
	bnew	Lsp_ret			| one-shot print
	moveq	&1,%d0
	movel	%d0,Lsp_n
	pea	Lsp_msg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
Lsp_ret:
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple
	nop

| ---------------------------------------------------------------------------
| idle (GLOBAL T) -- swtch idles here only when maxrunpri==-1.  One-shot marker so we see if
| the post-switch system reaches a clean idle (a child ran + blocked).  idle -> --weaken-symbol.
	.globl	idle
idle:
	movel	Lidle_n,%d0
	bnew	Lidle_stop		| already printed once -> just stop silently
	moveq	&1,%d0
	movel	%d0,Lidle_n
	movel	maxrunpri,%sp@-
	pea	Lidle_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lidle_freeze:
	bra.w	Lidle_freeze		| FREEZE at the FIRST idle -- the screen stops here so the
					| full post-switch sequence stays visible (no scroll/wrap/loop).
Lidle_stop:
	stop	&0x2000			| (subsequent idles, unreached while frozen)
	rts
	nop

| ---------------------------------------------------------------------------
| resume (0x9c, GLOBAL T) -- 040 context-switch core, RELIABILITY-FIXED (2026-06-23).
| The child's saved context is VALID (measured: a1=0x070418F8 procdup-save, sp=0x40001F40
| u-area stack).  The instability was NOT a bad context but resume reading it from the FIXED
| u-area VA (0x40000318) AFTER the remap -- a 040 cache/timing-fragile access that intermittently
| read stale memory -> garbage a1 -> wild jmp -> guru.
| FIX: read the saved context from the STABLE kvsegu VA (curproc@252 + 0x318), which is always
| live in kptr040 (that is exactly how we read a1 reliably in the sched diagnostic).  The
| uarea_pt remap (+cpusha) is still done so the CHILD's stack (fixed VA 0x40000000) works after
| transfer, but the jmp target no longer depends on the remap's timing.
| u_va==0 (proc 0 / early): no remap, read from the fixed VA (arg1) as the stock resume did.
| resume GLOBAL T -> --weaken-symbol.  globals: curproc (C), kptr040 (D).
	.globl	resume
resume:
	moveal	curproc,%a1
	movel	%a1@(252),%d1		| d1 = u_va (the new proc's u-area kvsegu VA; 0 for proc 0)
	moveal	%sp@(4),%a0		| a0 = arg1 = u+0x318 (fixed VA) -- default read source
	movew	%sr,%d0			| d0 = sr (preserved to the end)
	movew	&0x2700,%sr		| mask interrupts for the remap
	tstl	%d1
	beqw	Lr_rest			| u_va==0 -> no remap, read from fixed VA (stock behaviour)
|	--- remap uarea_pt[0],[1] = the child's 2 u-area leaf PTEs (for the child's stack) ---
	moveal	kptr040,%a2
	movel	%a2@,%d2
	andil	&0xffffff00,%d2		| d2 = uarea_pt base = kptr040[0] & ~0xFF
	moveal	%d2,%a2			| a2 = uarea_pt
	movel	%d1,%d4			| page 0: walk kptr040 for u_va
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4
	movel	%d1,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@		| uarea_pt[0] = child page-0 PTE
	movel	%d1,%d3			| page 1: walk kptr040 for u_va+0x1000
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
	movel	%a3@,%a2@(4)		| uarea_pt[1] = child page-1 PTE
	.word	0xf4f8			| cpusha bc -- push uarea_pt writes to RAM for the HW tablewalk
	.word	0xf518			| pflusha -- invalidate the ATC
	moveal	%d1,%a0			| a0 = u_va + 0x318 = the STABLE kvsegu read source
	addal	&0x318,%a0
Lr_rest:
	moveml	%a0@,%d2-%d7/%a1-%sp	| restore the new proc's context (reliable: stable VA)
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@

	.data
Lsch_msg:
	.asciz	"DBG sched ENTRY maxrunpri=%x"
	.even
Lst_msg:
	.asciz	"DBG saved-ctx uva=%x a1=%x sp=%x (a1 = where resume would jmp)"
	.even
Lret_msg:
	.asciz	"DBG swtch RETURNED maxrunpri=%x (no transfer)"
	.even
Lidle_msg:
	.asciz	"DBG idle maxrunpri=%x (a child ran + blocked -> clean idle)"
	.even
Lidle_n:
	.long	0
Lsch_n:
	.long	0
Lsp_msg:
	.asciz	"DBG MARK: schedpaging (swapconf returned) -- entering proc-1 setup"
	.even
Lsp_n:
	.long	0
Lrs_msg:
	.asciz	"DBG resume ctx=%x (dispatching a proc)"
	.even
Lrs_n:
	.long	0
