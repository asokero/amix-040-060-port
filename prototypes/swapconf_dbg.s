| swapconf_dbg.s -- diagnostic override of swapconf (0xb401e, GLOBAL T).
|
| swapconf panics (CE_PANIC) when lookupname("/dev/dsk/c6d0s2") returns ENOENT.
| On 040 (same disk that reaches login on 030) this is the FIRST namei path lookup
| of the boot and it fails -- likely a 040 namei/buffer-cache bug.  This override
| SKIPS swap config (warn + return 0) so the boot proceeds; if a LATER namei (init
| reading /etc/inittab etc.) also fails, the bug is namei-wide, not swap-specific.
| If the boot reaches single-user, swap was the only namei consumer at this stage.
|
| swapconf GLOBAL T -> --weaken-symbol.  Returns 0 (success) so callers continue.
| SVR4 gas syntax.

	.text
	.globl	swapconf
swapconf:
	linkw	%fp,&0
	pea	Lsc_msg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
	clrl	%d0
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.data
Lsc_msg:
	.asciz	"DBG swapconf: SKIPPED (diagnostic) -- boot continues without swap"
