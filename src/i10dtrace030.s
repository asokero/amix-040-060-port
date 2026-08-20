| i10dtrace030.s -- ISSUE-10 brk/sbrk RING TRACER (+ data-segment extent) for the STOCK
| 68030 kernel.
|
| The CPU-independent half of PART ELEVEN (i10d).  sh is the SAME binary on 030/040/060,
| and i10d already proved brk grants byte-exact IDENTICALLY on 040 and 030, so brk is
| exonerated.  This EXTENDED version also captures the data-segment EXTENT per brk, to
| distinguish how the 030 honours sh's write ~748B past its break where the 040 drops it:
|   (A) reserve-ahead: the data segment reaches PAST the break (seg@(brkend+0x1000) != 0),
|       so sh's past-break write is already in-segment;
|   (B) grow-on-fault: the segment is page-exact to the break, and the 030 fault handler
|       demand-grows it on the past-break write.
| The 040/060 tracer lives in src/i10rev040.s (PART ELEVEN); the stock 030 kernel has
| none of that, so this is a SELF-CONTAINED, generic-68k copy whose I1D! block is
| byte-for-byte the SAME LAYOUT (13 header longs + 16 entries * 9 longs), so one driver
| (test-tools/i10d.sh) reads all three CPUs.
|
| Wire it with relink-030-i10d.sh:  --weaken-symbol brk  --add-symbol
| brk_orig=.text:0x580e8  then ld -r into the base kernel.  Assemble -m68040 (base/68020
| instructions, valid on the 030).  The proc pointer is `curproc` (global, identical on
| every CPU); proc offsets p_brkbase @52, p_brksize @56, p_as @124; struct seg s_base @4,
| s_size @8.  as_segat (the stock SVR4 leaf lookup, global) is called by symbol -- ld -r
| binds it into the base kernel; it is fault-free, safe to call from the brk hook.

	.text
	.balign 4
	.globl	brk
brk:
	tstl	i10d_on
	bnew	Ld_active
	jmp	brk_orig		| dormant: one tstl + tail jmp
Ld_active:
	linkw	%fp,&0
	moveml	%d2-%d7/%a2-%a6,%sp@-
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
| --- three leaf lookups against curproc's address space (p_as = a2@124) ---
	movel	%a2@(52),%d0		| as_segat(p_as, brkbase) -> the data segment
	movel	%d0,%sp@-
	movel	%a2@(124),%sp@-
	jsr	as_segat
	addqw	&8,%sp
	moveq	&0,%d4			| d4 = seg_end (0 if no covering segment)
	tstl	%d0
	beqs	Ld_nseg
	moveal	%d0,%a0
	movel	%a0@(4),%d4
	addl	%a0@(8),%d4		| seg_end = s_base + s_size
Ld_nseg:
	movel	%a2@(52),%d7		| d7 = brkend = brkbase + brksize_after
	addl	%d6,%d7
	movel	%d7,%sp@-		| as_segat(p_as, brkend)
	movel	%a2@(124),%sp@-
	jsr	as_segat
	addqw	&8,%sp
	moveal	%d0,%a3			| a3 = seg@brkend
	movel	%d7,%d0			| as_segat(p_as, brkend + 0x1000)
	addil	&0x1000,%d0
	movel	%d0,%sp@-
	movel	%a2@(124),%sp@-
	jsr	as_segat
	addqw	&8,%sp
	moveal	%d0,%a4			| a4 = seg@(brkend+0x1000): nonzero = reserve-ahead (A)
| --- write the 9-long entry: slot = i10d_ring + head * 36 ---
	movel	i10d_head,%d0
	movel	%d0,%d1
	lsll	&5,%d0			| head * 32
	lsll	&2,%d1			| head * 4
	addl	%d1,%d0			| head * 36
	lea	i10d_ring,%a0
	addal	%d0,%a0
	movel	%d2,%a0@		| [0] newbrk
	movel	%a2@(52),%a0@(4)	| [1] p_brkbase
	movel	%d3,%a0@(8)		| [2] p_brksize before
	movel	%d6,%a0@(12)		| [3] p_brksize after
	movel	%d7,%a0@(16)		| [4] brkend after
	movel	%d5,%a0@(20)		| [5] return code
	movel	%d4,%a0@(24)		| [6] seg_end
	movel	%a3,%a0@(28)		| [7] seg@brkend
	movel	%a4,%a0@(32)		| [8] seg@(brkend+0x1000)
	movel	i10d_head,%d0		| advance head mod 16
	addql	&1,%d0
	cmpil	&16,%d0
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
	moveml	%sp@+,%d2-%d7/%a2-%a6
	unlk	%fp
	rts

	.balign 4

	.data
	.balign 4
| The i10d block -- IDENTICAL LAYOUT to src/i10rev040.s PART ELEVEN, so the same driver
| reads it.  Whole block = `kpeek <i10d_magic addr> 157` (13 header longs + 16*9 ring).
	.globl	i10d_magic
i10d_magic:
	.long	0x49314421		| "I1D!"
	.globl	i10d_on
i10d_on:
	.long	0			| 0 = DORMANT (ships this way).  kpoke 1 to arm.
	.globl	i10d_n
i10d_n:
	.long	0			| total brk calls recorded (ring holds the last 16)
	.globl	i10d_head
i10d_head:
	.long	0			| next write slot (0..15)
	.globl	i10d_size
i10d_size:
	.long	16
	.globl	i10d_stride
i10d_stride:
	.long	9			| longs per entry: newbrk,brkbase,pre,post,brkend,ret,
					| seg_end,seg@brkend,seg@(brkend+0x1000)
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
	.space	576			| 16 entries * 9 longs
	.balign 4
