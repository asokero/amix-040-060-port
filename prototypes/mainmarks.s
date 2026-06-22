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

	.data
Lsp_msg:
	.asciz	"DBG MARK: schedpaging (swapconf returned) -- entering proc-1 setup"
	.even
Lsp_n:
	.long	0
