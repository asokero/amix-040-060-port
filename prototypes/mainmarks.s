| mainmarks.s -- progress markers for the post-swapconf phase of main().
|
| After the gen_strategy read fix + segu u-area fix, the kernel boots through swap
| config (swapconf opens slice 2, r=0) and then goes IDLE at 0% CPU with no panic.
| main()'s post-swapconf sequence is: swapconf -> schedpaging -> newproc (proc 1) ->
| as_alloc -> segvn_create -> as_map -> copyout(icode) -> newproc (proc 2) ...
| The "DBG hat_dup STUBBED" marker did NOT print, and procdup skips as_dup for proc 1,
| so the idle is either in swapconf's tail (reading the swap header) or in proc 1's
| address-space setup.  This marker localizes it:
|
|   schedpaging is the FIRST call after swapconf returns.  Override it to print a
|   one-shot marker and RETURN (skip the paging-daemon tuning -- harmless with free
|   memory, and it contains no waits, so skipping cannot hide the idle).  If
|   "MARK: schedpaging (swapconf returned)" prints, swapconf completed and the idle is
|   in the proc-1 as-setup (newproc/segvn/as_map/copyout) -> port the per-proc hat.
|   If it does NOT print, swapconf itself hangs (swap-header read).
|
| schedpaging GLOBAL T -> --weaken-symbol.  SVR4 gas syntax.

	.text
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
| ENTRY marker: if "DBG resume ctx=%x" prints, swtch/sleep DO dispatch a proc (so the
| children run and the idle is a FAULT on resume / in the child path); if it never
| prints, proc 0 never yields (sched spins) and the issue is the swapper/run-queue.
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

| ---------------------------------------------------------------------------
| setrun_hook -- a detour for setrun(0x489c2): does CL_FORK/ts_fork make the children
| RUNNABLE?  patch_setrun_hook.py overwrites setrun's first 8 bytes (linkw + moveml)
| with `jmp setrun_hook` + nop.  The hook prints a one-shot marker (the proc being made
| runnable), re-executes the displaced linkw/moveml, then jmps back to setrun+8 (0x489ca).
| If "DBG setrun proc=%x" prints, setrun IS reached (so dispq/maxrunpri update via
| CL_SETRUN is the bug); if not, the CL_FORK path never reaches setrun.
	.globl	setrun_hook
setrun_hook:
	movel	Lsrn_n,%d0
	bnew	Lsrn_skip		| one-shot
	moveq	&1,%d0
	movel	%d0,Lsrn_n
	movel	%sp@(4),%sp@-		| the proc arg (sp@(4) at entry = setrun's arg)
	pea	Lsrn_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lsrn_skip:
	linkw	%fp,&0			| displaced setrun insn 1
	moveml	%d2/%a2,%sp@-		| displaced setrun insn 2
	.word	0x4ef9,0x0004,0x89ca	| jmp 0x000489ca  (setrun+8, absolute)

	.data
Lsrn_msg:
	.asciz	"DBG setrun proc=%x (made runnable)"
	.even
Lsrn_n:
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
