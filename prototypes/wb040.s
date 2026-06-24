| wb040.s -- 68040 access-error WRITE-BACK replay (THE init-hang fix, 2026-06-24).
|
| The 68040 does NOT re-run a faulted WRITE on rte from an access error: the pending store's
| data/address/status sit in the format-7 frame's WB1/WB2/WB3 fields and the operating system
| must complete the write itself.  The stock (030-era) AMIX kernel has no such handler, so
| copyout(icode)'s FIRST faulting `movesl` (the lea word 0x4FFB0170 -> user 0x80800000, captured
| in WB3) was LOST while the rest of the copy landed -> init's lea never set USP -> systrap read
| the syscall args from a stale kernel USP = garbage -> empty exec path -> lookuppn busy-loops ->
| init never starts.  PROVEN: icode page = 0 / 00000028 / 700B4E40 / 60FE2F73 (only the first long
| missing); frame WB3S=0x0081 WB3A=0x80800000 WB3D=0x4FFB0170.
|
| k_trap calls usrxmemflt(frame, info) where arg1 = the trap frame (== get_fault's frame arg);
| usrxmemflt -> as_fault resolves the demand-fault.  This wrapper replays the pending write-backs
| AFTER the page is present (only if as_fault succeeded, ret==0).  Frame offsets (relative to the
| frame arg, empirically dumped via get_fault040): WB3S@+78 WB3A@+88 WB3D@+92 ; WB2S@+80 WB2A@+96
| WB2D@+100 ; WB1S@+82 WB1A@+104 WB1D@+108.  WBxS: valid = bit 7 (0x80); FC = bits 2-0; SIZE =
| bits 6-5 (0=long,1=byte,2=word).  Re-issue with `moves` under the captured FC (DFC = ctrl 0x001).
| --add-symbol usrxmemflt_orig=.text:0x5aede + --weaken-symbol usrxmemflt.

	.text
	.globl	usrxmemflt
usrxmemflt:
	linkw	%fp,&0
	moveml	%d2-%d4/%a2-%a3,%sp@-
	movel	%fp@(12),%sp@-		| arg2 (fault info)
	movel	%fp@(8),%sp@-		| arg1 = trap frame
	jsr	usrxmemflt_orig
	addqw	&8,%sp
	movel	%d0,%d4			| save return (0 = demand-fault resolved)
	tstl	%d4
	bnew	Lwb_done		| not resolved -> do NOT write into a still-unmapped page
	moveal	%fp@(8),%a2		| a2 = frame
	moveq	&0,%d0
	moveb	%a2@(70),%d0		| format/vector high byte
	lsrb	&4,%d0
	cmpiw	&7,%d0			| 040 access-error (format 7) frame?
	bnew	Lwb_done
| --- replay WB1, then WB2, then WB3 (each: valid bit 7 set -> re-issue the store) ---
	clrl	%d3
	movew	%a2@(82),%d3		| WB1S
	btst	&7,%d3
	beqw	Lwb_2
	moveal	%a2@(104),%a3		| WB1A
	movel	%a2@(108),%d2		| WB1D
	bsrw	Lwb_do
Lwb_2:
	clrl	%d3
	movew	%a2@(80),%d3		| WB2S
	btst	&7,%d3
	beqw	Lwb_3
	moveal	%a2@(96),%a3		| WB2A
	movel	%a2@(100),%d2		| WB2D
	bsrw	Lwb_do
Lwb_3:
	clrl	%d3
	movew	%a2@(78),%d3		| WB3S
	btst	&7,%d3
	beqw	Lwb_done
	moveal	%a2@(88),%a3		| WB3A
	movel	%a2@(92),%d2		| WB3D
	bsrw	Lwb_do
Lwb_done:
	movel	%d4,%d0			| restore usrxmemflt's return value
	moveml	%fp@(-20),%d2-%d4/%a2-%a3
	unlk	%fp
	rts

| Lwb_do: d3 = WBxS, a3 = target address, d2 = data.  Set DFC = WBxS&7, moves.<size> d2 -> (a3).
Lwb_do:
	moveq	&7,%d0
	andl	%d3,%d0			| FC = WBxS & 7
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%d3,%d0
	lsrl	&5,%d0
	andil	&3,%d0			| SIZE: 0=long, 1=byte, 2=word
	beqw	Lwb_long
	cmpil	&1,%d0
	beqw	Lwb_byte
	.word	0x0e53,0x2800		| moves.w %d2,%a3@
	rts
Lwb_byte:
	.word	0x0e13,0x2800		| moves.b %d2,%a3@
	rts
Lwb_long:
	.word	0x0e93,0x2800		| moves.l %d2,%a3@
	rts
	nop				| pad .text to keep text/data contiguous
	nop
