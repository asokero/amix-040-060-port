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
| k_trap routes a fault through userspace(frame): user faults -> usrxmemflt(frame, info), kernel
| faults -> krnxmemflt(frame).  Both run get_fault+ptest then as_fault to resolve the demand-fault.
| BOTH need the write-back replay (a supervisor store into a not-yet-present kernel page faults the
| same way), so this file wraps BOTH (same frame layout, same replay).  The replay runs ONLY after
| as_fault succeeded (orig ret == 0) so we never write into a still-unmapped page.
|
| Frame offsets (relative to the frame arg = fp@(8), == get_fault's frame, empirically dumped):
|   WB3S@+78 WB3A@+88 WB3D@+92 ; WB2S@+80 WB2A@+96 WB2D@+100 ; WB1S@+82 WB1A@+104 WB1D@+108.
| WBxS: valid = bit 7 (0x80); FC = bits 2-0; SIZE = bits 6-5 (0=long,1=byte,2=word).  Re-issue
| each valid write-back with `moves.<size> WBxD -> (WBxA)` under DFC = WBxS&7.
|
| Both are file-LOCAL ('t'): relink-040.sh globalizes+weakens them and aliases the originals
| (usrxmemflt_orig=0x5aede, krnxmemflt_orig=0x5b140).

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
	bnew	Lu_done
	moveal	%fp@(8),%a2		| a2 = frame
	bsrw	wb040_replay
Lu_done:
	movel	%d4,%d0			| restore usrxmemflt's return value
	moveml	%fp@(-20),%d2-%d4/%a2-%a3
	unlk	%fp
	rts

	.globl	krnxmemflt
krnxmemflt:
	linkw	%fp,&0
	moveml	%d2-%d4/%a2-%a3,%sp@-
	movel	%fp@(8),%sp@-		| arg1 = trap frame (krnxmemflt takes ONE arg)
	jsr	krnxmemflt_orig
	addqw	&4,%sp
	movel	%d0,%d4			| save return (0 = demand-fault resolved)
	tstl	%d4
	bnew	Lk_done
	moveal	%fp@(8),%a2		| a2 = frame
	bsrw	wb040_replay
Lk_done:
	movel	%d4,%d0			| restore krnxmemflt's return value
	moveml	%fp@(-20),%d2-%d4/%a2-%a3
	unlk	%fp
	rts

| wb040_replay: a2 = trap frame.  If it is an 040 format-7 access-error frame, re-issue every
| valid write-back (WB1, then WB2, then WB3).  Clobbers d0-d3/a3; preserves d4 (the orig return)
| and a2 (the frame) for the calling wrapper.  No stack frame (leaf-ish; only bsr to Lwb_do).
wb040_replay:
	moveq	&0,%d0
	moveb	%a2@(70),%d0		| format/vector high byte
	lsrb	&4,%d0
	cmpiw	&7,%d0			| 040 access-error (format 7) frame?
	bnew	Lwr_ret
	clrl	%d3
	movew	%a2@(82),%d3		| WB1S
	btst	&7,%d3
	beqw	Lwr_2
	moveal	%a2@(104),%a3		| WB1A
	movel	%a2@(108),%d2		| WB1D
	bsrw	Lwb_do
Lwr_2:
	clrl	%d3
	movew	%a2@(80),%d3		| WB2S
	btst	&7,%d3
	beqw	Lwr_3
	moveal	%a2@(96),%a3		| WB2A
	movel	%a2@(100),%d2		| WB2D
	bsrw	Lwb_do
Lwr_3:
	clrl	%d3
	movew	%a2@(78),%d3		| WB3S
	btst	&7,%d3
	beqw	Lwr_ret
	moveal	%a2@(88),%a3		| WB3A
	movel	%a2@(92),%d2		| WB3D
	bsrw	Lwb_do
Lwr_ret:
	rts

| Lwb_do: d3 = WBxS, a3 = target address, d2 = data.  Set DFC = WBxS&7, then replay the store
| BYTE-WISE (most-significant byte first), NOT with one wide moves.  A single wide moves on an
| UNALIGNED store that crosses a page boundary re-faults with FA = the NEAR address; as_fault
| resolves only the near (already-present) page, the far page never resolves, and the replay
| re-crosses forever -> infinite kernel-fault recursion eating the u-area stack (ISSUE-7,
| measured: WB3 FC=5 SIZE=long addr=0x40736FFE).  Per-byte moves.b gives each byte its OWN
| access: a byte in a not-yet-resident page faults with the CORRECT per-byte FA, as_fault
| resolves exactly that page, and the nested fault+replay converges (<=1 nested fault per page
| spanned).  Same bytes at the same addresses as the old wide moves for the aligned case.
| pflusha FIRST: when the faulting write was a write-PROTECT fault on a PRESENT page (do_reloc
| relocating libc.so.1's GOT, which it had just READ -> the page was resident read-only), as_fault
| COW'd it to a fresh writable page, but the 68040 ATC still holds the OLD read-only translation
| for this VA.  Without flushing, this moves re-issues the store through the stale read-only ATC
| entry and the write is lost -> the GOT stayed unrelocated.  (A not-present demand-fault write,
| e.g. suword, has no stale entry, which is why those persisted.)  Flush the whole ATC so the
| moves re-walks the page table and picks up the new writable PTE.
Lwb_do:
	.word	0xf518			| pflusha -- drop stale ATC entries before re-issuing the store
	moveq	&7,%d0
	andl	%d3,%d0			| FC = WBxS & 7
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%d2,%d1			| d1 = data, to be left-justified -- BEFORE the size decode: movel
					| sets the CCs, and it must not clobber the Z flag between the
					| andil (Z = size==0) and the beqw that tests it
	movel	%d3,%d0
	lsrl	&5,%d0
	andil	&3,%d0			| SIZE: 0=long, 1=byte, 2=word; Z = (size==0), tested by the next insn
	beqw	Lwb_long
	cmpil	&1,%d0
	beqw	Lwb_byte
	swap	%d1			| word: d1 = d2<<16
	moveq	&2,%d0			| 2 bytes
	braw	Lwb_loop
Lwb_byte:
	swap	%d1
	lsll	&8,%d1			| byte: d1 = d2<<24
	moveq	&1,%d0			| 1 byte
	braw	Lwb_loop
Lwb_long:
	moveq	&4,%d0			| long: d1 = d2 as-is, 4 bytes
Lwb_loop:
	roll	&8,%d1			| rotate next MSB down into bits 7..0
	.word	0x0e1b,0x1800		| moves.b %d1,%a3@+  (per-byte access -> correct per-byte FA on fault)
	subql	&1,%d0
	bnew	Lwb_loop
	rts
	nop				| pad .text to a multiple of 4 to keep text/data contiguous
