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
Lsch_spin:
	bra.w	Lsch_spin		| halt here -- measurement only
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
	.asciz	"DBG sched ENTRY maxrunpri=%x"
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
