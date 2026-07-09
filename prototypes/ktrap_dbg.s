| ktrap_dbg.s -- diagnostic WRAPPER around k_trap (0x5a0e8, GLOBAL T) that DEFINITIVELY
| maps the 68040 exception-frame layout by DUMPING a raw window of the frame whenever the
| icode fault address (0x80800000) appears anywhere in it.
|
| WHY a raw scan+dump: too many frame-offset assumptions are in play (get_fault reads the
| 040 FA at frame+84, userspace reads the SSW at frame+72, the format/vector at frame+70).
| The earlier format-7/PC-gated dump never fired, so at least one of those offsets is wrong
| for the 040 frame as it actually lands here.  Rather than guess, scan frame+64..frame+104
| for the known FA value (0x80800000, the copyout(icode) fault) and print the whole window
| with explicit byte offsets.  From that I can read off exactly where SR / PC / format /
| SSW / FA sit and port userspace() (and verify get_fault) with NO guessing.
|
| FRAME POINTER: ttrap.s nullvect pushes D0-D7/A0-A6 (60 bytes), ktraps pushes USP as the
| arg; at k_trap entry sp@(4)=USP slot, so after `link %fp,&0`, frame = %fp@(8).  The CPU
| exception frame begins around frame+64.  Scan/dump frame+64..frame+104.
|
| Mechanism: objcopy --add-symbol k_trap_orig=.text:0x5a0e8 + --weaken-symbol k_trap; this
| strong wrapper dumps then TAIL-JMPs to k_trap_orig with the stack restored to the original
| `jsr k_trap` state, so k_trap_orig's rts + d0 reach ktraps unchanged.

	.text
	.globl	k_trap
k_trap:
	linkw	%fp,&0
	movel	%a2,%sp@-		| save a2 (cmn_err preserves a2-a6, so frame survives)
	movel	%a3,%sp@-		| save a3 (scan pointer)
	lea	%fp@(8),%a2		| a2 = frame pointer (&USP slot)
| --- scan frame+64 .. frame+104 (11 longs) for a value in the icode page ---
	lea	%a2@(64),%a3		| a3 = scan ptr
	moveq	&10,%d0			| 11 longs (count 10..0 inclusive)
Lkt_scan:
	movel	%a3@,%d1
	subil	&0x80800000,%d1
	cmpil	&0x1000,%d1
	bcsw	Lkt_hit
	addql	&4,%a3
	subql	&1,%d0
	bccw	Lkt_scan		| loop while d0 >= 0 (bcc after subq: no borrow)
	braw	Lkt_done
Lkt_hit:
	movel	Lkt_n,%d0
	cmpil	&4,%d0
	bccw	Lkt_done
	addql	&1,%d0
	movel	%d0,Lkt_n
| --- line A: frame+64 (SR|PC), +68, +72 (SSW?), +76 ---
	movel	%a2@(76),%sp@-
	movel	%a2@(72),%sp@-
	movel	%a2@(68),%sp@-
	movel	%a2@(64),%sp@-
	pea	Lkt_mA
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- line B: frame+80, +84, +88, +92 (FA candidates) ---
	movel	%a2@(92),%sp@-
	movel	%a2@(88),%sp@-
	movel	%a2@(84),%sp@-
	movel	%a2@(80),%sp@-
	pea	Lkt_mB
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- line C: frame+96, +100, +104 ---
	movel	%a2@(104),%sp@-
	movel	%a2@(100),%sp@-
	movel	%a2@(96),%sp@-
	pea	Lkt_mC
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lkt_done:
	moveal	%sp@+,%a3		| restore a3
	moveal	%sp@+,%a2		| restore a2
	unlk	%fp			| sp -> [retaddr][USP arg]: original jsr k_trap state
	jmp	k_trap_orig		| tail-call: k_trap_orig's rts + d0 reach ktraps

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lkt_mA:
	.asciz	"DBG kt +64=%x +68=%x +72=%x +76=%x"
	.even
Lkt_mB:
	.asciz	"DBG kt +80=%x +84=%x +88=%x +92=%x"
	.even
Lkt_mC:
	.asciz	"DBG kt +96=%x +100=%x +104=%x"
	.even
Lkt_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
