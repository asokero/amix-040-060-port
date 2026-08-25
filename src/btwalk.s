| btwalk.s -- ISSUE-104: give the panic backtrace a frame-pointer test that admits
| the kernel's real stacks, and a walk that cannot run away.  (2026-08-21)
|
| WHY THIS EXISTS.  Twice during the 68040 metal campaign a panic printed exactly
| one frame address and stopped, and twice the call chain had to be recovered by
| dumping the boot stack and walking the frame pointers by hand.  It is not a
| stalled printer.  `backtrace` (.text+0x595a4) prints each frame BEFORE it
| validates it, and its validity test was:
|
|     5960e:  cmpil #0x3FFFFFFF,%fp@(-4) / blsw  -> invalid
|     5961a:  cmpil #0x4000FFFF,%fp@(-4) / bhiw  -> invalid
|     59626:  moveq #1,%d0                       -> valid
|
| i.e. a frame pointer was accepted only inside **[0x40000000, 0x4000FFFF]** -- a
| 64 KiB window at the u-block base.  The u-block is four times that
| ([0x40000000, 0x40040000)), and the boot and interrupt stacks are in the kernel's
| own .bss, entirely outside it.  So the walk stopped at the first frame every
| time:
|
|   * `Backtrace: 80F4964:` (ISSUE-102) -- 0x080F4964 is `pstack`, in .bss;
|   * `40001DF4: 803E66C->80595` (ISSUE-103) -- in window, so that one frame and its
|     return address printed, and the next frame pointer left the window.
|
| WHY WIDENING THE WINDOW ALONE WOULD HAVE BEEN A BUG.  **That test was the walk's
| only terminator.**  The loop (0x5978e-0x59796) simply follows `*fp` back to the
| top; there is no frame counter and no ordering check.  A wider window on its own
| lets a corrupt chain walk forever *inside a panic* -- which is the failure
| ISSUE-100 exists to prevent, reintroduced by the fix meant to help.  So all three
| bounds land together, and none of them is optional:
|
|   1. RANGE -- the whole u-block [0x40000000, 0x40040000) **or** the kernel's own
|      data+bss [edata, end), which is where `pstack` and the interrupt stack live.
|      Both are taken from the loader's own symbols rather than from constants, so
|      they cannot drift from the image.
|   2. ORDER -- each frame pointer must be strictly GREATER than the last.  Stacks
|      grow down, so caller frames are at higher addresses; this single test kills
|      every cycle, including a frame that points at itself.
|   3. COUNT -- a hard cap of 64 frames per walk.  Belt and braces: a chain that is
|      ascending, in range, and still wrong cannot spin.
|
| Plus one free check: an ODD frame pointer is refused outright, because the next
| thing the walk does with it is a longword read.
|
| HOW IT HOOKS.  patch_btwalk.py replaces the 26 bytes of the old test with
| `bsr.l bt_frame_ok` and NOP padding, leaving the `tstl %d0 / beqw` that follows
| it untouched -- so this routine's contract is exactly the old code's: return
| d0 = 1 to continue the walk, d0 = 0 to stop.  `bsr.l` is PC-relative and needs no
| relocation (the same reasoning as the cb_release hook: a byte-patched ABSOLUTE
| target would need loader rebasing).
|
| ARMING, WITHOUT A SECOND HOOK.  The walk has no "start" callback, but it does not
| need one: `backtrace` seeds its first candidate with its OWN frame pointer
| (0x595f2, `%fp@(-4) = %fp`).  So the first call of every walk is the one where the
| candidate equals `%a6`, and that is where the counters re-arm.  A later frame
| cannot alias it, because rule 2 requires strict increase.
|
| The island reads `%a6@(-4)` directly: `bsr` does not build a frame, so `%a6` is
| still backtrace's own frame pointer while this runs.
|
| WHAT IT DOES NOT DO.  It does not change the output format, the symbol lookup, or
| the printing order -- a frame is still printed before it is judged, so the first
| refused frame still appears.  That is deliberate: the address of the frame that
| ended the walk is itself diagnostic, and it is what made this defect findable.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c btwalk.s -o build/btwalk.o
| Wire:     patch_btwalk.py.  Externals: the loader's `edata` and `end`.
| ============================================================================

	.text
	.globl	bt_frame_ok
bt_frame_ok:
	movel	%d1,%sp@-
	movel	%a6@(-4),%d0		| the candidate frame pointer
| --- first frame of this walk?  backtrace seeds it with its own %fp ---
	cmpl	%a6,%d0
	bnew	Lbt_armed
	clrl	bt_prev
	movel	&64,bt_budget
	addql	&1,bt_walks
Lbt_armed:
| --- 3. COUNT ---
	tstl	bt_budget
	beqw	Lbt_bad
| --- odd frame pointer: the walk would read a longword from it ---
	btst	&0,%d0
	bnew	Lbt_bad
| --- 2. ORDER: strictly increasing (stacks grow down) ---
	movel	bt_prev,%d1
	cmpl	%d1,%d0
	blsw	Lbt_bad
| --- 1. RANGE: the whole u-block ... ---
	cmpil	&0x40000000,%d0
	bcsw	Lbt_krn
	cmpil	&0x40040000,%d0
	bcsw	Lbt_ok
Lbt_krn:
| --- ... or the kernel's own data+bss, where pstack and the interrupt stack are ---
	cmpil	&edata,%d0
	bcsw	Lbt_bad
	cmpil	&end,%d0
	bccw	Lbt_bad
Lbt_ok:
	movel	%d0,bt_prev
	subql	&1,bt_budget
	addql	&1,bt_frames
	moveq	&1,%d0			| continue the walk
	movel	%sp@+,%d1
	rts
Lbt_bad:
	addql	&1,bt_stops
	movel	%d0,bt_laststop		| the frame that ended the walk: diagnostic
	moveq	&0,%d0			| stop
	movel	%sp@+,%d1
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	bt_magic
bt_magic:
	.long	0x42545721		| "BTW!"
| Walks started (= panics that produced a backtrace).
	.globl	bt_walks
bt_walks:
	.long	0
| Frames ACCEPTED across all walks.  Before this unit the answer was always 0 or 1.
	.globl	bt_frames
bt_frames:
	.long	0
| Walks terminated by a refused frame, and the frame pointer that did it.
	.globl	bt_stops
bt_stops:
	.long	0
	.globl	bt_laststop
bt_laststop:
	.long	0
| Working state, re-armed on the first frame of each walk.
	.globl	bt_prev
bt_prev:
	.long	0
	.globl	bt_budget
bt_budget:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
