| lmul060.s -- portable replacement for the kernel's `lmul` 64-bit multiply helper (060-B).
|
| The stock lmul (vanilla 0x1f6d0; callers hrt_alarm@0x1aa20, hrt_newres@0x1b8d6 -- the
| high-resolution timer scaling math, found via .rela.text) is built on THREE 64-bit-form
| `muls.l <ea>,%d0,%d1` instructions.  The 64-bit mul/div forms are UNIMPLEMENTED on the
| 68060 (vector 61 trap); these are the ONLY such sites in the whole kernel (census
| 2026-07-09, see docs/68060-prestudy.md).  This override reproduces the stock routine's exact
| semantics using only 68000-era `mulu.w` (16x16->32) plus 32-bit-form `muls.l` (legal on
| the 060), so ONE routine serves both CPUs -- no cputype dispatch needed.
|
| Stock ABI (from disassembly):
|   stack args:  sp@(4)=a_hi  sp@(8)=a_lo  sp@(12)=b_hi  sp@(16)=b_lo
|   a0 = pointer to the 8-byte result:  a0@ = hi,  a0@(4) = lo
|   returns nothing in registers; stock clobbers only d0/d1 (we save/restore d2-d5).
| Stock math (bug-for-bug):  (hi:lo) = SIGNED 64-bit product a_lo*b_lo, then
|   hi += low32(a_hi*b_lo) + low32(a_lo*b_hi)   (= low 64 bits of the 64x64 product,
|   except the a_lo*b_lo high word uses muls.l's SIGNED semantics -- reproduced here via
|   the standard adjust  hi_unsigned - (a_lo<0 ? b_lo : 0) - (b_lo<0 ? a_lo : 0)).
| Algorithm validated against a muls.l reference model: 202500 random+edge cases, 0 diffs.
|
| Wired via relink-040.sh: --weaken-symbol lmul (GLOBAL T in vanilla).

	.text
	.globl	lmul
lmul:
	moveml	%d2-%d5,%sp@-		| 16 bytes saved -> args now at +20/+24/+28/+32
	movel	%sp@(24),%d2		| d2 = a_lo (kept intact; mulu.w reads sources only)
	movel	%sp@(32),%d3		| d3 = b_lo (kept intact)
	movel	%d2,%d0
	movel	%d3,%d1
	swap	%d0			| d0.w = ah = a_lo>>16
	swap	%d1			| d1.w = bh = b_lo>>16
	movel	%d0,%d4
	muluw	%d1,%d4			| d4 = ah*bh                     (p11 -> hi)
	muluw	%d3,%d0			| d0 = ah*bl                     (p10)
	muluw	%d2,%d1			| d1 = bh*al                     (p01)
	movel	%d2,%d5
	muluw	%d3,%d5			| d5 = al*bl                     (p00 -> lo)
	addl	%d0,%d1			| d1 = mid = p01+p10 (32-bit)
	bccw	Lml_nc1
	addil	&0x10000,%d4		|   mid overflowed 32 bits -> hi += 1<<16
Lml_nc1:
	movel	%d1,%d0
	swap	%d0
	andil	&0xffff,%d0		| d0 = mid>>16
	addl	%d0,%d4			| hi += mid>>16
	movel	%d1,%d0
	swap	%d0
	andil	&0xffff0000,%d0		| d0 = mid<<16
	addl	%d0,%d5			| lo += mid<<16
	bccw	Lml_nc2
	addql	&1,%d4			|   lo carried -> hi += 1
Lml_nc2:
	tstl	%d2			| signed adjust to muls.l semantics:
	bplw	Lml_p1
	subl	%d3,%d4			|   a_lo < 0 -> hi -= b_lo
Lml_p1:
	tstl	%d3
	bplw	Lml_p2
	subl	%d2,%d4			|   b_lo < 0 -> hi -= a_lo
Lml_p2:
	movel	%sp@(20),%d0		| a_hi
	mulsl	%d3,%d0			| low32(a_hi*b_lo)  -- 32-bit form, legal on 060
	addl	%d0,%d4
	movel	%sp@(28),%d0		| b_hi
	mulsl	%d2,%d0			| low32(b_hi*a_lo)
	addl	%d0,%d4
	movel	%d4,%a0@		| result hi
	movel	%d5,%a0@(4)		| result lo
	moveml	%sp@+,%d2-%d5
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
