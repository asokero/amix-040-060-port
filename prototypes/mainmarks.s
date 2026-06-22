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
| sys_forkret_hook -- a detour for sys_forkret(0xba936), the SYS-class CL_FORKRET op.
| Per sys/class.h, newproc enqueues a child via CL_FORKRET (cl_funcs@16) -> sys_forkret
| (clproc) -> setbackdq(clproc); for the SYS class sys_fork sets clproc = the proc, so
| sys_forkret's arg @(8) IS the child proc.  Runs ONLY from newproc in main() (low IPL,
| single-threaded init) so cmn_err is safe (same context as schedpaging below).
| patch_sys_forkret_hook.py overwrites sys_forkret's first 8 bytes (linkw %fp,&0 ;
| movel %fp@(8),%sp@-) with `jmp sys_forkret_hook` + nop.  The hook prints the child proc
| / p_flag(@4) / p_pri(@24) ONCE, re-executes the displaced insns, jmps to sys_forkret+8.
| KEY: setbackdq makes a proc visible to the dispatcher (updates maxrunpri/dqactmap) only
| when (p_flag & (SLOAD|SPROCIO)) == SLOAD  OR  SSYS(0x1) is set.  If the child reaches
| sys_forkret with BOTH SLOAD(0x10) and SSYS(0x1) clear, it enqueues invisibly ->
| maxrunpri stays -1 -> swtch idles == the observed symptom.  The printed p_flag tells us.
	.globl	sys_forkret_hook
sys_forkret_hook:
	linkw	%fp,&0			| establish a frame FIRST (mirror schedpaging)
	movel	Lsfr_n,%d0
	bnew	Lsfr_done		| one-shot print
	moveq	&1,%d0
	movel	%d0,Lsfr_n
	moveal	%fp@(8),%a0		| a0 = child proc (sys_forkret arg, at fp@(8) after linkw)
	movel	%a0@(24),%sp@-		| p_pri
	movel	%a0@(4),%sp@-		| p_flag
	movel	%a0,%sp@-		| child proc
	pea	Lsfr_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp		| pop 5 longs
Lsfr_done:
	unlk	%fp			| undo our frame
	linkw	%fp,&0			| displaced sys_forkret insn 1
	movel	%fp@(8),%sp@-		| displaced sys_forkret insn 2
	.word	0x4ef9,0x000b,0xa93e	| jmp 0x000ba93e (sys_forkret+8, absolute)
	nop				| pad .text to a 4-byte multiple
	nop

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
| resume (0x9c, GLOBAL T) -- the context-switch core (restores a proc's saved
| registers + SP and jmps to its resume PC).  Verbatim transcription + a one-shot
| ENTRY marker: if "DBG resume ctx=%x" prints, swtch/sleep DO dispatch a proc.
| The 030 pflusha (0xb2) is the 040 form here (.word 0xf518) since this override is a
| separate copy.  resume GLOBAL T -> --weaken-symbol.  ublksde = global D.
	.globl	resume
resume:
	movel	Lrs_n,%d0
	bnew	Lrs_go			| one-shot
	moveq	&1,%d0
	movel	%d0,Lrs_n
	movel	%sp@(8),%sp@-		| the resume context ptr (a1)
	pea	Lrs_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lrs_go:
	moveal	%sp@(4),%a0
	moveal	%sp@(8),%a1
	moveal	ublksde,%a2
	movew	%sr,%d0
	movew	&0x2700,%sr
	movel	%a1,%a2@
	.word	0xf518			| pflusha (68040)
	moveml	%a0@,%d2-%d7/%a1-%sp
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@

	.data
Lsfr_msg:
	.asciz	"DBG sys_forkret child=%x flag=%x pri=%x"
	.even
Lsfr_n:
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
