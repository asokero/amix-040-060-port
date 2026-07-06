| setuctxt_dbg.s -- wrap setuctxt to check whether u_procp survives setuctxt's OWN
| internal kmem_alloc(KM_SLEEP) loop (ISSUE-7, KNOWN-ISSUES.md "Codex timing hypothesis #1").
|
| setuctxt(childproc@fp+8, up@fp+12) [0x41918] writes up@(0x730)=childproc as its FIRST
| act (0x41954: `movel %fp@(8),%a2@(0x730)`, a2=up), THEN loops (0x41972-0x419a4) calling
| kmem_alloc(0x7c, 0) to duplicate a per-proc 124-byte record list (context/LDT-style;
| a3 walks the list via @(120)=next).  kmem_alloc(size, KM_SLEEP=0) CAN legitimately block
| on kernel heap memory, letting OTHER procs run via swtch DURING setuctxt's own execution
| -- if ISSUE-7's corruption mechanism fires in one of those windows, up+0x730 will already
| read 0 the MOMENT setuctxt returns (the write happens once, near the top, and nothing
| in this function re-asserts it).  A post-return check is therefore sufficient to catch
| this specific window; no need to probe mid-loop (up's register `a2` is reused/clobbered
| inside the loop by kmem_alloc's own return value, so a mid-loop probe would need a full
| transcription of setuctxt -- not worth it if the simple wrap already catches the class).
|
| Caller is procdup (0x418e0: pushes up=childproc@(252), then childproc) -- 2 args only,
| childproc=fp@(8), up=fp@(12) (last-pushed = first arg, C convention).
|
| setuctxt is GLOBAL T (0x41918) -> --weaken-symbol setuctxt + --add-symbol
| setuctxt_orig=.text:0x41918 (relink-040-dbg.sh).  Cap 24 (proc creation is infrequent
| relative to the trap/preempt-rate probes elsewhere in this dbg overlay).

	.data
	.even
Lsu_n:
	.long	0
Lsu_msg:
	.asciz	"DBG setuctxt POST-RETURN u_procp MISMATCH up=%x expected=%x got=%x n=%x"
	.even

	.text
	.globl	setuctxt
setuctxt:
	linkw	%fp,&0
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	setuctxt_orig
	addqw	&8,%sp
	moveal	%fp@(12),%a0		| a0 = up
	moveal	%fp@(8),%a1		| a1 = childproc (expected u_procp)
	cmpl	%a0@(0x730),%a1
	beqw	Lsu_ok
	movel	Lsu_n,%d0
	cmpil	&24,%d0
	bccw	Lsu_ok
	addql	&1,%d0
	movel	%d0,Lsu_n
	movel	%d0,%sp@-
	movel	%a0@(0x730),%sp@-	| got (re-read: cheap, harmless if it changes again)
	movel	%a1,%sp@-		| expected
	movel	%a0,%sp@-		| up
	pea	Lsu_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lsu_ok:
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple (relink contiguity)
