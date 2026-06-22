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
| sched_hook -- a detour for sched(0x46e94), the swapper loop entry (proc 0, called once
| by main() AFTER all 4 daemons are created).  Same low-IPL main context as schedpaging
| below, so cmn_err is safe (the sys_forkret/setbackdq probes crashed because their first
| call is deep in newproc / an early disk-I/O wakeup, where a cmn_err-triggered exception
| hit the unported 040 trap frame).  This RESOLVES the core contradiction: newproc gives
| every child SLOAD(0x10) (proven statically: child p_flag = (parent & 0x300000) | 0x10),
| and setbackdq makes a SLOAD proc visible by setting maxrunpri -- yet swtch idles, which
| happens ONLY when maxrunpri == -1.  Print maxrunpri (and srunprocs) at sched entry:
|   maxrunpri >= 0  -> children ARE enqueued+visible -> bug is in swtch/resume (040 ctx).
|   maxrunpri == -1 -> the CL_FORKRET->sys_forkret->setbackdq enqueue did NOT run on 040.
| patch_sched_hook.py overwrites sched's first 8 bytes (linkw %fp,&-32 ; moveml
| %d2-%d5/%a2-%a3,%sp@-) with `jmp sched_hook` + nop; the hook prints once, re-executes
| the displaced insns, and jmps to sched+8 (0x46e9c).
	.globl	sched_hook
sched_hook:
	linkw	%fp,&0			| establish a frame FIRST (mirror schedpaging)
	movel	Lsch_n,%d0
	bnew	Lsch_done		| one-shot print
	moveq	&1,%d0
	movel	%d0,Lsch_n
	movel	srunprocs,%sp@-		| total runnable procs
	movel	maxrunpri,%sp@-		| THE value (-1 == nothing visible)
	pea	Lsch_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp		| pop 4 longs
Lsch_done:
	unlk	%fp			| undo our frame
	linkw	%fp,&-32		| displaced sched insn 1 (linkw %fp,#-32)
	moveml	%d2-%d5/%a2-%a3,%sp@-	| displaced sched insn 2
	.word	0x4ef9,0x0004,0x6e9c	| jmp 0x00046e9c (sched+8, absolute)
	nop				| pad .text to a 4-byte multiple
	nop
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
Lsch_msg:
	.asciz	"DBG sched ENTRY maxrunpri=%x srunprocs=%x"
	.even
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
