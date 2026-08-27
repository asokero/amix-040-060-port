| scrdevfix040.s -- ISSUE-49: give a /dev/screen bitplane a page it actually owns.
|
| THE DEFECT, in two halves that have to be fixed together.
|
| 1. THE BASE IS 2 KiB ALIGNED.  scrdev.c's allocbmap asks for its planes with
|    AllocMem(size, MEMF_CHIP|MEMF_PAGEB), and the MEMF_PAGEB path in memory.c aligns to
|    param.h's PAGESIZE -- still 0x800.  In this image that is visible at AllocMem+0x32
|    (`addil #2047`) and +0x56 (`andiw #-2048`).  Meanwhile scrmmap returns
|    phystopfn(bp->bpl[n] + offset), and patch_devmmap_pfn.py converted that phystopfn to
|    `lsrl #12` -- a 4 KiB page frame.  So when a plane base is 2048 mod 4096, the frame
|    that comes back STARTS 2048 BYTES BEFORE THE PLANE and every byte the user sees
|    through the mapping is 2048 bytes early.  Measured on 68060-260827-06: a mapped
|    640x512x1 plane at 0x00013800.
|
| 2. THE EXTENT IS NOT A WHOLE NUMBER OF PAGES.  320x256 gives 10240 bytes, and the
|    MEMF_PAGEB path explicitly hands the slack after p1+nbytes back to the chip pool.
|    A 4 KiB mapping of that plane therefore covers 2048 bytes the plane does not own and
|    the allocator may already have given to somebody else.
|
| Fixing only the alignment leaves the tail; fixing only the extent leaves the displacement.
| src/patch_scrdev_pageb.py does the alignment half by widening the three AllocMem
| immediates in place; this file does the extent half, because rounding needs twelve bytes
| where the compiler left eight.
|
| WHY THE WHOLE FUNCTION AND NOT A WRAPPER.  The size is computed INSIDE allocbmap from
| bp->width * bp->height / 8, so a wrapper has nothing to intercept -- the one thing that
| would work, inflating bp->height so the stock body computes the rounded size, needs a
| height that is not an integer for 320x256.  Both bodies are short and their disassembly
| is exact, so they are reproduced here with the rounding added and nothing else changed.
| Reached by retargeting the single call-site relocation each has (allocbmap 0x7e74 in
| srvioc, freebmap 0x7956 in scrclose), exactly as patch_a3091_badhardware.py does.
|
| WHY 4096 AND NOT PAGESIZE.  param.h's PAGESIZE is 0x800 in this tree, so rounding to it
| compiles to a no-op: 10240 is already a 2 KiB multiple.  That is an easy way to ship a
| patch that looks right and changes nothing, and it is why the literal is spelled out.
|
| WHAT IS NOT CHANGED.  scrmmap's bound `offset < width*height/8` is left alone on purpose.
| segdev probes d_mmap on page-aligned offsets only, and the last such offset for a mapping
| of len bytes is roundup(len,4096)-4096, which is always less than the unrounded size.  So
| the bound never rejects a probe, and leaving it narrow keeps it a real guard against an
| offset past the logical image.
|
| COST.  At most 4095 bytes per plane; 10 KB for a 320x256x5 screen.  Correct on a 2 KiB
| kernel too, where a 12288-byte plane is simply six pages instead of five.
|
| CONTRACT.  Both are entered exactly as the stock bodies are: dp at %fp@(8), bp at
| %fp@(12), caller cleans up, result in %d0.  allocbmap returns 0 on success and 1 on
| failure; freebmap returns nothing.  Callee-saved registers preserved.
|
| Struct offsets, all confirmed against this image's own scrmmap disassembly (0x82f8):
| sizeof(struct scrdev) 460 (`mulsl #460`), bitmap[] at scrdev+12 with 44-byte entries,
| and inside struct bitmap: flags +0, width +2, height +4, depth +6, bpl[] +12.

	.text

| --- allocbmap(dp, bp): allocate bp->depth planes of the ROUNDED size, zero each. ---
	.globl	scr_allocbmap
scr_allocbmap:
	link	%fp,&0
	moveml	%d2-%d4/%a2,%sp@-
	moveal	%fp@(12),%a2		| a2 = bp
	moveal	%fp@(8),%a1		| a1 = dp
	clrl	%d0
	movew	%a1@(2),%d0		| dp->type
	cmpil	&1,%d0
	bnew	Lsa_badtype		| the stock body's `default: return 1`

	clrl	%d4
	movew	%a2@(2),%d4		| width
	muluw	%a2@(4),%d4		| * height -- MULU.W, so the 32-bit result is
					| unsigned and the stock body's bpl/addq #7
					| sign fix is dead; lsrl is the honest shift
	lsrl	&3,%d4			| / 8 = the logical plane size
	movel	%d4,scrfix_last_raw
| --- THE FIX.  Identical three instructions in freebmap below; they must stay identical,
|     and scrfix_bytes_alloc / scrfix_bytes_free are the invariant that says they did. ---
	addil	&4095,%d4
	andil	&-4096,%d4
	movel	%d4,scrfix_last_size

	clrl	%d3			| i = 0
Lsa_loop:
	clrl	%d0
	movew	%a2@(6),%d0		| bp->depth
	cmpl	%d3,%d0
	blew	Lsa_done
	movel	&0x4002,%sp@-		| MEMF_CHIP|MEMF_PAGEB
	movel	%d4,%sp@-
	jsr	AllocMem
	addql	&8,%sp
	movel	%d0,%d2			| AllocMem leaves the pointer in BOTH %d0 and
					| %a0 (its epilogue does moveal %d0,%a0); the
					| stock body reads %a0, this reads %d0
	tstl	%d2
	beqw	Lsa_allocfail

	movel	%d2,scrfix_last_ptr
	movel	%d2,%d0
	andil	&0xfff,%d0
	beqs	Lsa_aligned
	addql	&1,scrfix_misalign_n	| MUST STAY 0: a plane that is not 4 KiB aligned
	movel	%d2,scrfix_bad_ptr	| is still displaced -- this is the direct check
					| that the AllocMem immediates were patched
Lsa_aligned:
	movel	%d4,%sp@-
	movel	%d2,%sp@-
	jsr	bzero			| zero the WHOLE rounded plane, pad included, so
	addql	&8,%sp			| the tail page cannot publish stale chip RAM
	movel	%d2,%a2@(12,%d3:l:4)	| bp->bpl[i] = ptr
	addql	&1,scrfix_planes_alloc
	addl	%d4,scrfix_bytes_alloc
	addql	&1,%d3
	braw	Lsa_loop

| --- allocation failed: unwind exactly what we allocated, with the SAME size. ---
Lsa_allocfail:
	addql	&1,scrfix_allocfail_n	| MUST STAY 0 in a healthy run
Lsa_unwind:
	tstl	%d3
	bles	Lsa_bad
	subql	&1,%d3
	movel	%d4,%sp@-
	movel	%a2@(12,%d3:l:4),%sp@-
	jsr	FreeMem
	addql	&8,%sp
	subql	&1,scrfix_planes_alloc	| keep the invariant honest: these never reached
	subl	%d4,scrfix_bytes_alloc	| freebmap, so they must not be counted
	braw	Lsa_unwind

Lsa_badtype:
	addql	&1,scrfix_badtype_n
Lsa_bad:
	moveq	&1,%d0
	braw	Lsa_out
Lsa_done:
	movew	&1,%a2@			| bp->flags = Bf_ACTIVE
	addql	&1,scrfix_alloc_n
	movel	&0x53434652,scrfix_ran	| "SCFR" -- the BODY ran
	clrl	%d0
Lsa_out:
	moveml	%sp@+,%d2-%d4/%a2
	unlk	%fp
	rts
	.balign	4

| --- freebmap(dp, bp): free bp->depth planes of the SAME rounded size. ---
	.globl	scr_freebmap
scr_freebmap:
	link	%fp,&0
	moveml	%d2-%d4/%a2,%sp@-
	moveal	%fp@(12),%a2		| a2 = bp
	moveal	%fp@(8),%a1		| a1 = dp
	clrl	%d0
	movew	%a1@(2),%d0
	cmpil	&1,%d0
	bnew	Lsf_flags		| stock: the switch falls through to flags = 0

	clrl	%d4
	movew	%a2@(2),%d4
	muluw	%a2@(4),%d4
	lsrl	&3,%d4
| --- the SAME three instructions as above.  A difference here frees a different number of
|     bytes than were allocated, which corrupts the chip map silently. ---
	addil	&4095,%d4
	andil	&-4096,%d4

	clrl	%d3
Lsf_loop:
	clrl	%d0
	movew	%a2@(6),%d0		| bp->depth
	cmpl	%d3,%d0
	blew	Lsf_flags
	movel	%d4,%sp@-
	movel	%a2@(12,%d3:l:4),%sp@-
	jsr	FreeMem
	addql	&8,%sp
	addql	&1,scrfix_planes_free
	addl	%d4,scrfix_bytes_free
	addql	&1,%d3
	braw	Lsf_loop
Lsf_flags:
	clrw	%a2@			| bp->flags = 0, outside the switch in the stock body
	addql	&1,scrfix_free_n
	movel	&0x53434652,scrfix_ran
	clrl	%d0
	moveml	%sp@+,%d2-%d4/%a2
	unlk	%fp
	rts
	.balign	4

	.data
	.even
| --- counters, in reading order.  Magic first, and static. ---
	.globl	scrfix_magic
scrfix_magic:
	.long	0x53434621		| "SCF!"
	.globl	scrfix_ran
scrfix_ran:
	.long	0			| "SCFR" once either body has run
	.globl	scrfix_alloc_n
scrfix_alloc_n:
	.long	0			| successful allocbmap calls
	.globl	scrfix_free_n
scrfix_free_n:
	.long	0			| freebmap calls
	.globl	scrfix_planes_alloc
scrfix_planes_alloc:
	.long	0			| planes currently accounted as allocated
	.globl	scrfix_planes_free
scrfix_planes_free:
	.long	0
	.globl	scrfix_bytes_alloc
scrfix_bytes_alloc:
	.long	0			| INVARIANT: equals scrfix_bytes_free once every
	.globl	scrfix_bytes_free	| bitmap has been freed.  A difference means the
scrfix_bytes_free:			| two roundings drifted apart, which corrupts the
	.long	0			| chip map silently and nothing else would say so
	.globl	scrfix_misalign_n
scrfix_misalign_n:
	.long	0			| MUST STAY 0: a plane base that is not 4 KiB
					| aligned.  This is the direct measurement of the
					| AllocMem immediate patch -- if that patch is
					| missing, every plane lands here
	.globl	scrfix_allocfail_n
scrfix_allocfail_n:
	.long	0			| MUST STAY 0: AllocMem returned NULL
	.globl	scrfix_badtype_n
scrfix_badtype_n:
	.long	0			| dp->type != 1
	.globl	scrfix_last_raw
scrfix_last_raw:
	.long	0			| width*height/8 before rounding
	.globl	scrfix_last_size
scrfix_last_size:
	.long	0			| and after -- the rounding is visible, not assumed
	.globl	scrfix_last_ptr
scrfix_last_ptr:
	.long	0			| last plane base
	.globl	scrfix_bad_ptr
scrfix_bad_ptr:
	.long	0			| and the last misaligned one, if any
	.balign	4
