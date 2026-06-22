| forkdbg.s -- diagnostic stub of hat_dup (0xb502a, GLOBAL T).
|
| newproc "fork failed": main -> newproc -> procdup -> as_dup -> hat_dup.  hat_dup
| walks the inert 030 tree + hat_growsdt -> on 040 it fails -> as_dup returns 0 ->
| "fork failed".  This stub makes hat_dup a no-op (return 0 = success, copy nothing)
| to CONFIRM it's the as_dup blocker.  If fork then proceeds past newproc, hat_dup is
| the culprit (and the NEXT fault -- the child running on the still-030 hat_alloc root
| -- shows what to port next).  NOT a real fix: a no-op hat_dup copies no mappings, and
| hat_alloc still builds a broken 4-entry 030 root.
|
| hat_dup GLOBAL T -> --weaken-symbol.  One-shot CE_WARN marker.  SVR4 gas syntax.

	.text
	.globl	hat_dup
hat_dup:
	linkw	%fp,&0
	movel	Lhd_n,%d0
	bnew	Lhd_ret
	moveq	&1,%d0
	movel	%d0,Lhd_n
	pea	Lhd_msg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
Lhd_ret:
	clrl	%d0
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple
	nop

| anon_resv (0xad69e, GLOBAL T) -- reserves anon/SWAP memory (checks availsmem).
| With swapconf skipped there is no swap -> anon_resv fails -> segu_get -> procdup -1
| -> "fork failed".  Stub it to succeed (return 1) to CONFIRM the no-swap cause and
| expose the NEXT real blocker (proc 1's user as setup -> hat_alloc 128-entry root).
| Diagnostic only -- real fix is to make swapconf configure swap (the namei bug).
	.globl	anon_resv
anon_resv:
	moveq	&1,%d0			| return 1 = reserved OK
	moveal	%d0,%a0
	rts
	nop				| pad .text to a 4-byte multiple

	.data
Lhd_msg:
	.asciz	"DBG hat_dup: STUBBED (returns 0, copies nothing) -- diagnostic"
	.even
Lhd_n:
	.long	0
