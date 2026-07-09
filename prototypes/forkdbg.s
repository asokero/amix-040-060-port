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

| NOTE 2026-06-23: the anon_resv stub was REMOVED.  Its premise (swapconf skipped ->
| no swap -> anon_resv fails) no longer holds -- swapconf now configures swap (the
| namei/gen_strategy fix), so the REAL anon_resv runs and reserves/releases properly.
| The stub (return 1 without incrementing availsmem) corrupted anon accounting ->
| "anon: reservations below zero???" on every teardown unresv.  Using the real one
| balances the books.  hat_dup stays stubbed (the real fork-COW port is still TODO).

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
Lhd_msg:
	.asciz	"DBG hat_dup: STUBBED (returns 0, copies nothing) -- diagnostic"
	.even
Lhd_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
