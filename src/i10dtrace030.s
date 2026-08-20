| i10dtrace030.s -- ISSUE-10 brk/sbrk RING TRACER for the STOCK 68030 kernel.
|
| The CPU-independent half of PART ELEVEN (i10d).  sh is the SAME binary on 030/040/060,
| so if the 040 grants a different brk result than the 030 for identical sbrk requests,
| that is the ISSUE-10 desync.  The 040/060 tracer lives in src/i10rev040.s; the stock
| 030 kernel has none of that infrastructure, so this is a SELF-CONTAINED, generic-68k
| (no 040-only instructions) copy whose I1D! block is byte-for-byte the SAME LAYOUT, so
| one driver (test-tools/i10d.sh) reads all three CPUs.
|
| It weakens/redefines the 030 sysent `brk` (0x580bc; a single sysent reloc, no bypass --
| the same 100%-bind technique the 040 build uses) and, once armed (i10d_on), records a
| ring of the last 24 brk calls: {newbrk, p_brkbase, p_brksize before, after, brkend
| after, ret}.  Report-only; never changes brk.  Ships dormant.
|
| Wire it with relink-030-i10d.sh:  --weaken-symbol brk  --add-symbol
| brk_orig=.text:0x580bc  then ld -r into the stock 030 unix.  Assemble with -m68040
| (the same driver relink-030-dbg.sh uses -- the instructions here are base/68020, valid
| on the 030): m68k-cbm-sysv4-gcc -m68040 -c src/i10dtrace030.s
|
| The proc pointer is `curproc` (the global, identical on every CPU), so this does not
| depend on the u-area mapping.  struct proc offsets p_brkbase @52, p_brksize @56 are the
| same on the 030 and the 040 (confirmed from both stock brk prologues).

	.text
	.balign 4
	.globl	brk
brk:
	tstl	i10d_on
	bnew	Ld_active
	jmp	brk_orig		| dormant: one tstl + tail jmp
Ld_active:
	linkw	%fp,&0
	moveml	%d2-%d6/%a2,%sp@-
	moveal	%fp@(8),%a0		| uap
	movel	%a0@,%d2		| d2 = requested new break (*uap)
	moveal	curproc,%a2		| proc pointer (CPU-independent global)
	movel	%a2@(56),%d3		| d3 = p_brksize BEFORE
	movel	%fp@(8),%sp@-
	jsr	brk_orig
	addqw	&4,%sp
	movel	%d0,%d5			| d5 = brk's return
	movel	%a2@(56),%d6		| d6 = p_brksize AFTER
	movel	%d2,%d0			| band filter on the requested new break
	cmpl	i10d_lo,%d0
	bcsw	Ld_done			| newbrk < lo
	cmpl	i10d_hi,%d0
	bccw	Ld_done			| newbrk >= hi (default all)
	movel	i10d_head,%d0		| slot address = i10d_ring + head * 24
	moveq	&24,%d1
	mulsl	%d1,%d0
	lea	i10d_ring,%a0
	addal	%d0,%a0
	movel	%d2,%a0@		| [0] newbrk
	movel	%a2@(52),%a0@(4)	| [1] p_brkbase
	movel	%d3,%a0@(8)		| [2] p_brksize before
	movel	%d6,%a0@(12)		| [3] p_brksize after
	movel	%a2@(52),%d0		| [4] brkend after = brkbase + brksize_after
	addl	%d6,%d0
	movel	%d0,%a0@(16)
	movel	%d5,%a0@(20)		| [5] return code
	movel	i10d_head,%d0		| advance head mod 24
	addql	&1,%d0
	cmpil	&24,%d0
	bcss	Ld_nw
	moveq	&0,%d0
Ld_nw:
	movel	%d0,i10d_head
	addql	&1,i10d_n
	movel	%a2,i10d_proc		| last proc + u_comm (u is 0x40000000 on the 030 too)
	movel	u+0x1c0,i10d_comm0
	movel	u+0x1c4,i10d_comm1
	movel	u+0x1c8,i10d_comm2
	movel	u+0x1cc,i10d_comm3
Ld_done:
	movel	%d5,%d0			| return brk_orig's value unchanged
	moveml	%sp@+,%d2-%d6/%a2
	unlk	%fp
	rts

	.balign 4

	.data
	.balign 4
| The i10d block -- IDENTICAL LAYOUT to src/i10rev040.s PART ELEVEN, so the same driver
| reads it.  Whole block = `kpeek <i10d_magic addr> 157` (13 header longs + 24*6 ring).
	.globl	i10d_magic
i10d_magic:
	.long	0x49314421		| "I1D!"
	.globl	i10d_on
i10d_on:
	.long	0			| 0 = DORMANT (ships this way).  kpoke 1 to arm.
	.globl	i10d_n
i10d_n:
	.long	0			| total brk calls recorded (ring holds the last 24)
	.globl	i10d_head
i10d_head:
	.long	0			| next write slot (0..23)
	.globl	i10d_size
i10d_size:
	.long	24
	.globl	i10d_stride
i10d_stride:
	.long	6			| longs per entry: newbrk,brkbase,pre,post,brkend,ret
	.globl	i10d_lo
i10d_lo:
	.long	0			| band filter: only newbrk in [lo, hi).  Default all;
	.globl	i10d_hi			| kpoke lo=0x80011000 hi=0x80020000 to keep only sh's grows
i10d_hi:
	.long	0xffffffff
	.globl	i10d_proc
i10d_proc:
	.long	0
	.globl	i10d_comm0
i10d_comm0:
	.long	0
	.globl	i10d_comm1
i10d_comm1:
	.long	0
	.globl	i10d_comm2
i10d_comm2:
	.long	0
	.globl	i10d_comm3
i10d_comm3:
	.long	0
	.globl	i10d_ring
i10d_ring:
	.space	576			| 24 entries * 6 longs
	.balign 4
