| hgfault040.s -- ISSUE-10: complete a user first-touch WRITE one page past the break.
|
| THE DEFECT, in one sentence.  Bourne sh's addblok raises its arena top and writes the
| arena end-sentinel there WITHOUT an sbrk, so the store lands on the first page above the
| process break; no segment covers that page, the kernel refuses the fault, and on the
| 68040 -- unlike the 68030 -- the refusal DISCARDS the store, because a 68040 does not
| re-run a faulted write on `rte`, it hands the pending write-back to the operating system
| in the format-7 frame and `src/wb040.s` may only replay it for a RESOLVED fault.
|
| Measured, on the emulated 040 (docs/ISSUE10-SETUPSH-WALL-260819.md §16, i10r):
|     pre_sr   00000008    S bit CLEAR -> a USER fault
|     pre_fa   800152a0    pre_ssw 0401 (ATC set, RW clear = a WRITE, TM 1 = user data)
|     pre_w3s  00000081    valid write-back, size long
|     pre_w3a  800152a0    pre_w3d 800114b5   (sh's _end+1, the arena sentinel)
|     ret      0000000b    SIGSEGV      sicode 1 (SEGV_MAPERR)   siaddr 800152a0
|     wbrep_pre == wbrep_post          -> wb040_replay NEVER RAN for this fault
|     tv_post  0                       -> the sentinel never reached memory
| The freed arena block's link is therefore left NULL; sh's next coalescing walk follows it
| to address 0, reads the kernel's illegal-at-null sentinel 0x4AFC0000 as a pointer, and
| bus-errors at 4AFC0003 in a flood -- the "setup.sh: no space" wall.
|
| =====================================================================================
| WHERE THE REFUSAL ACTUALLY HAPPENS -- and why this file is NOT an as_fault wrapper.
|
| The obvious hook is `as_fault`, which returns FC_NOMAP when no segment covers the page.
| It is the WRONG hook, and that is measured, not argued.  `usrxmemflt` (the stock body at
| 0x5aede, which this port keeps and calls) does its OWN coverage test before it ever
| reaches as_fault:
|
|     5af5c  as_segat(as, addr)          -> fp@(-4)
|     ...
|     5afc2  tstl  %fp@(-4)              is anything mapped there?
|     5afc6  bnew  5aff6                   yes -> as_fault(as, addr, 1, F_INVAL, rw)
|     5afca  jsr   stackfault              no  -> is it the stack?
|     5afda  beqw  5b02a                   no  -> si_signo = 11, si_code = 1, RETURN
|     5afde  jsr   grow                    yes -> grow the stack, then as_fault
|
| For an address one page past the break, `as_segat` returns 0 and `stackfault` returns 0,
| so the body takes the `5b02a` shortcut: it writes SIGSEGV/SEGV_MAPERR into the siginfo
| and returns -- **as_fault is never called at all**.  Confirmed by direct measurement: the
| i10a audit (src/i10rev040.s PART EIGHT) wraps as_fault, was armed on the marker page and
| then on the exact address, and the wall fired in both passes -- and it recorded
| `i10a_vamatch_n = 0` with `i10a_seen_n` = 417 and 1024.  as_fault ran hundreds of times
| during the wall and NOT ONCE for that address.  A cure hooked there is inert.
|
| So the cure hooks the routine that makes the decision.  `usrxmemflt` is already the
| public wrapper in src/wb040.s; this file inserts itself between that wrapper and the
| stock body by the SAME idiom the kernel-side resolver already uses (relink-040.sh binds
| `krnxmemflt_orig` to our native core and keeps the stock body as `krnxmemflt_stock`):
|
|     usrxmemflt        (wb040.s -- the write-back replay wrapper, UNCHANGED)
|       -> usrxmemflt_orig   (THIS FILE)
|            -> usrxmemflt_stock  (the stock body at 0x5aede, unchanged)
|
| =====================================================================================
| THE POLICY.  On the 68040 only, for a USER-mode WRITE that the stock resolver has just
| refused, and only when the faulting page is EXACTLY the page above the process's own
| break, extend the break by ONE page using brk's own machinery, then hand the fault back
| to the stock body.  The second pass finds a covering segment, takes the F_INVAL demand
| path, faults the zero-fill page in through segvn, and returns 0 -- so wb040.s's gate
| (`tstl %d4 / beqs Lu_replay`) routes into wb040_replay, whose `pflusha` drops the stale
| not-present ATC entry and whose `moves` loop lands the sentinel.  The 68030's guarantee
| -- a faulted write eventually executes -- is restored, in the kernel, before any signal.
|
| Every gate below is a deliberate narrowing, and each one is a decision:
|
|  1. `hg_on` -- one .data long.  0 restores byte-exact stock behaviour (a tail jmp to the
|     stock body), the same escape-hatch discipline as wb_dfc_on / wbf_prop_on.
|  2. **68040 ONLY** (`cputype == 40`).  The 68060 does not reproduce the wall -- it
|     restarts stores natively like the 030 -- and its completion path is the format-4
|     wb060_xpage helper, which would replay neither a single-page sentinel store.  Its
|     behaviour is left byte-exact; enabling it there is a separate, separately-measured
|     decision.
|  3. **The saved SR's S bit must be CLEAR.**  Only a store the CPU executed in USER mode
|     grows the heap.  A kernel-context `copyout`/`uiomove` to a bad user pointer arrives
|     here too (it is a `moves` with DFC = 1, so the SSW's TM says user data and the trap
|     is routed to the user resolver) -- and it keeps its EFAULT, exactly as stock.  The
|     trap frame is this routine's own argument, so the S bit is read directly rather than
|     inferred.  ACCEPTED, IN WRITING: within the one-page window a genuine near-break
|     overrun by USER code is serviced instead of signalled.  That is the residual masking
|     this fix chooses; it is counted (hg_grow_n) and it is one page wide, not a region.
|  4. **A WRITE only** (040 SSW bit 8, RW: 1 = read).  A read past the break still takes
|     its SIGSEGV; only a write can be silently discarded, so only a write is completed.
|  5. **Exactly one page** -- `round4k(p_brkbase + p_brksize)`, and nothing else.  sh's own
|     grow increment caps below 2 KiB, so one page always suffices; a wild write further up
|     still takes a prompt SIGSEGV and is counted separately (hg_far_n).
|  6. **Only a fault the stock body already refused.**  The stock resolver runs FIRST and
|     its return is checked; a resolved fault (the overwhelming majority) costs one call
|     and one `tstl`.  Nothing is grown speculatively.
|  7. **brk's own admission tests are mirrored**, so a fault can never grant what the brk
|     syscall would refuse: the 0xC0000000 ceiling (brk 0x58104) and the process data-size
|     limit at u+0x7b4 (brk 0x5811c).
|
| =====================================================================================
| THE GROW, field by field, taken from brk's own body (0x580e8) so the two paths cannot
| diverge:
|
|   as_map(p_as, base, PAGESZ, segvn_create, zfod_argsp)      brk 0x58184-0x5819c
|         -- note `zfod_argsp` is a POINTER VARIABLE: brk pushes its CONTENTS, and so do we.
|   p_brksize = (base + PAGESZ) - p_brkbase                   brk 0x581f8
|   the u_lock / AS_PAGLCK dance around the as_map            brk 0x58154-0x58180, 0x581b2
|
| THE `u+0x924 & 5` FLAG, answered rather than copied blindly.  u+0x924 is the process's
| memory-LOCK word: `proclock` ORs 1 into it (0x43128), `textlock` 2 (0x42f5e), `datalock`
| 4 (0x42fe4), `memcntl` 8 (0x432fa).  So brk's `& 5` is (PROCLOCK | DATLOCK) -- "has this
| process locked its data down with plock(2)".  If so brk sets bit 0x20 of the FIRST BYTE
| of the address space, and as_map reads exactly that bit -- `btst #5,%a2@` at 0xae578 --
| and, when set, calls `as_ctl(as, addr, size, 2 /* MC_LOCK */, ...)` to lock the pages it
| just mapped, un-mapping them again if the lock fails.  brk sets the bit only if it was
| clear and clears it only if it set it, which is what its `fp@(-12)` flag is for.
|   Is it needed here?  For the ISSUE-10 case, NO: sh never calls plock, so the word is 0
| and the whole dance is skipped.  It is replicated anyway, and deliberately: without it a
| plock'd process would get a fault-grown page that is NOT locked while every brk-grown
| page of the same heap IS, which is a divergence that would only ever be found the hard
| way.  It costs six instructions on a path that already called as_map.
|
| =====================================================================================
| SAFETY / COST.
|   * Hot path: a fault that is not a 040 user-mode write on a format-7 frame pays four
|     compares and a tail `jmp` -- no frame, no saved registers.  A user write fault that
|     the stock body RESOLVES pays one extra call and one `tstl`.
|   * The grow runs strictly BETWEEN two calls of the stock resolver, never nested inside
|     one, so it holds no VM state of the resolver's while it calls as_map (which may
|     sleep).  Re-entry from another process is harmless: everything but the counters is
|     stack-local, and the counters are advisory.
|   * On the second pass the stock body rewrites the siginfo itself -- `fault_to_info(0)`
|     clears si_signo -- so nothing here has to unpick a signal verdict by hand.  That was
|     the hazard that ruled out completing the store from wb040.s's failure arm.
|   * This file returns EXACTLY the stock body's own return value, in d0 and a0, and
|     preserves d2-d7/a2-a4.  d0/d1/a0/a1 are scratch in this ABI.
|   * src/wb040.s is UNCHANGED, and its wbf_dropwarn safety net stays armed: wbf_dropped_n
|     must stop advancing for this case and still counts anything that slips the window.
|
| Frame offsets, relative to the trap-frame argument (16 saved registers, then the CPU
| exception frame at +64), identical to the ones src/wb040.s and src/getfault040.s use:
|     +64 SR (word)   +66 PC   +70 format/vector (high nibble = frame format)
|     +76 SSW (word, 040 format 7: bit 8 = RW, 1 = read)   +84 fault address
| proc offsets: p_brkbase @52, p_brksize @56, p_as @124; curproc = u.u_procp = u+0x730.

	.text
	.globl	usrxmemflt_orig
usrxmemflt_orig:
	tstl	hg_on
	beqw	Lhg_pass		| rollback switch: byte-exact stock behaviour
	cmpil	&40,cputype
	bnew	Lhg_pass		| 68040 ONLY -- the 060 keeps stock behaviour
	moveal	%sp@(4),%a0		| arg1 = the trap frame
	movel	%a0,%d0
	beqw	Lhg_pass		| defensive: no frame, no evidence, no grow
	moveq	&0,%d0
	moveb	%a0@(70),%d0		| format/vector byte: high nibble = frame format
	lsrb	&4,%d0
	cmpiw	&7,%d0
	bnew	Lhg_pass		| not a 68040 format-7 access-error frame
	movew	%a0@(64),%d0		| the SR the CPU saved for the FAULTING context
	andiw	&0x2000,%d0
	bnew	Lhg_pass		| S set -> kernel-context store: its EFAULT is stock's
	moveq	&1,%d0
	andb	%a0@(76),%d0		| 040 SSW bit 8 (RW): 1 = read, 0 = write
	bnew	Lhg_pass		| a read past the break keeps its SIGSEGV
	braw	Lhg_enter
Lhg_pass:
	jmp	usrxmemflt_stock	| tail call: args and return address untouched

| --- a USER-mode WRITE on a 68040 access-error frame.  Let the stock resolver decide
|     first; only a refusal is a candidate for the grow. ---
Lhg_enter:
	linkw	%fp,&0
	moveml	%d2-%d7/%a2-%a4,%sp@-	| callee-saved; d0/d1/a0/a1 are scratch
	addql	&1,hg_seen_n		| user-mode write faults seen (the denominator)
	movel	%fp@(12),%sp@-		| arg2 = infop
	movel	%fp@(8),%sp@-		| arg1 = the trap frame
	jsr	usrxmemflt_stock
	addqw	&8,%sp
	movel	%d0,%d7			| d7 = the verdict we return unless a grow lands
	beqw	Lhg_ret			| 0 = resolved: the overwhelming common case
	addql	&1,hg_cand_n		| the resolver refused this user write
| --- identity: the process, its address space, its break ---
	moveal	%fp@(8),%a2		| a2 = the trap frame
	movel	%a2@(84),%d2		| d2 = the fault address (format 7: FA at +0x14)
	moveal	u+0x730,%a3		| a3 = curproc = u.u_procp
	movel	%a3,%d0
	beqw	Lhg_ret
	movel	%a3@(124),%d3		| d3 = p_as
	beqw	Lhg_ret
	movel	%a3@(52),%d4		| d4 = p_brkbase
	beqw	Lhg_ret			| no data segment at all: not a heap fault
| --- the window: EXACTLY the page above the break, and nothing else ---
	movel	%a3@(56),%d0		| p_brksize (brk keeps it UNROUNDED)
	addl	%d4,%d0			| brkend = p_brkbase + p_brksize
	addil	&0xfff,%d0
	andil	&0xfffff000,%d0
	movel	%d0,%d5			| d5 = base = round4k(brkend) = first page past it
	movel	%d2,%d1
	andil	&0xfffff000,%d1		| d1 = the faulting page
	cmpl	%d5,%d1
	beqs	Lhg_inwin
	bcsw	Lhg_ret			| below the window: an ordinary in-heap fault
	addql	&1,hg_far_n		| ABOVE it: a wild write.  Still SIGSEGV, now named.
	movel	%d2,hg_far_addr
	braw	Lhg_ret
Lhg_inwin:
	addql	&1,hg_win_n
| --- is the page genuinely uncovered?  If a segment already reaches it the refusal had
|     some other cause and as_map could only fail; do not touch it. ---
	movel	%d5,%sp@-
	movel	%d3,%sp@-
	jsr	as_segat
	addqw	&8,%sp
	tstl	%d0
	beqs	Lhg_uncovered
	addql	&1,hg_cover_n
	braw	Lhg_ret
Lhg_uncovered:
| --- brk's own admission tests, mirrored: a fault must not grant what brk refuses ---
	movel	%d5,%d6
	addil	&0x1000,%d6		| d6 = the new logical break
	cmpil	&0xc0000000,%d6
	bhiw	Lhg_lim			| brk 0x58104: never into the stack band
	subl	%d4,%d6			| d6 = the new p_brksize
	cmpl	u+0x7b4,%d6
	bhiw	Lhg_lim			| brk 0x5811c: the process data-size limit
| --- brk's u_lock / AS_PAGLCK dance (see the header for what the flag means).  a4 carries
|     "we set the bit, so we must clear it" -- d7 must keep the first pass's verdict, which
|     is what we return on every path that does NOT complete a grow. ---
	moveal	&0,%a4
	movew	u+0x924,%d0		| u_lock: PROCLOCK 1 | DATLOCK 4
	andiw	&5,%d0
	beqs	Lhg_nolock
	moveal	%d3,%a0
	moveq	&0,%d0
	moveb	%a0@,%d0
	andib	&0x20,%d0
	bnes	Lhg_nolock		| already set: leave it, and do not clear it later
	orib	&0x20,%a0@
	moveal	&1,%a4
Lhg_nolock:
	addql	&1,hg_grow_n
	movel	%d2,hg_last_addr
	movel	%d5,hg_last_base
	movel	zfod_argsp,%sp@-	| brk pushes the CONTENTS of the pointer variable
	pea	segvn_create
	movel	&0x1000,%sp@-
	movel	%d5,%sp@-
	movel	%d3,%sp@-
	jsr	as_map
	lea	%sp@(20),%sp
	movel	%d0,%d1			| d1 = as_map's return (0 = the page is mapped)
	movel	%a4,%d0
	beqs	Lhg_noclr
	moveal	%d3,%a0
	andib	&0xdf,%a0@		| clear AS_PAGLCK again, exactly as brk 0x581b2
Lhg_noclr:
	tstl	%d1
	beqs	Lhg_mapped
	addql	&1,hg_mapfail_n		| the grow was refused: the process keeps its SIGSEGV
	movel	%d1,hg_last_err
	braw	Lhg_ret
Lhg_mapped:
	movel	%d6,%a3@(56)		| p_brksize -- brk's own write at 0x581f8, so a later
					| brk computes its old end from the grown extent
| --- hand the SAME fault back to the stock resolver.  It now finds a covering segment,
|     takes the F_INVAL demand path, faults the zero-fill page in through segvn, and
|     rewrites the siginfo itself.  This is the eager fault-in: the PTE is resident before
|     we return, so wb040's replay re-walks to a present, writable page. ---
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	usrxmemflt_stock
	addqw	&8,%sp
	movel	%d0,%d7			| the second pass's verdict is now ours
	bnes	Lhg_unres
	addql	&1,hg_landed_n		| grown AND resolved: the store will be replayed
	braw	Lhg_ret
Lhg_unres:
	addql	&1,hg_unres_n		| grown but still unresolved -- read this with
	movel	%d7,hg_last_err		| hg_grow_n: the two cannot both be right
	braw	Lhg_ret
Lhg_lim:
	addql	&1,hg_lim_n		| brk would have refused this too
Lhg_ret:
	movel	%d7,%d0
	moveal	%d0,%a0			| the stock body returns in both d0 and a0
	moveml	%fp@(-36),%d2-%d7/%a2-%a4
	unlk	%fp
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement)

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The hg block -- read hg_magic FIRST.  A stale address does not fail; it returns a
| plausible number from whatever now lives there.  tools/status-facts.sh prints the
| runtime address of hg_magic and the whole block in one kpeek-able run.
	.globl	hg_magic
hg_magic:
	.long	0x48474621		| "HGF!"
| --- the knob ---
	.globl	hg_on
hg_on:
	.long	1			| 1 = the cure is live.  0 = pure pass-through to the
					| stock body, byte-exact stock behaviour, so the wall
					| can be reproduced in the SAME boot with one kpoke.
| --- counters, in reading order ---
	.globl	hg_seen_n
hg_seen_n:
	.long	0			| USER-mode WRITE faults on a 040 format-7 frame.
					| The denominator: with this 0 nothing below means
					| anything, because the gate never admitted a fault.
	.globl	hg_cand_n
hg_cand_n:
	.long	0			| ... of which the stock resolver REFUSED (nonzero
					| return).  Every candidate for the grow.
	.globl	hg_win_n
hg_win_n:
	.long	0			| ... whose page is exactly round4k(brkbase+brksize)
	.globl	hg_cover_n
hg_cover_n:
	.long	0			| in-window but a segment already covered the page ->
					| the refusal had another cause; nothing was grown
	.globl	hg_lim_n
hg_lim_n:
	.long	0			| in-window but brk's own limits refuse it (0xC0000000
					| ceiling or the data-size limit at u+0x7b4)
	.globl	hg_grow_n
hg_grow_n:
	.long	0			| as_map calls made: one page each
	.globl	hg_landed_n
hg_landed_n:
	.long	0			| ... after which the stock resolver returned 0, so
					| wb040_replay runs and the store lands.  The cure is
					| confirmed only by hg_landed_n == hg_grow_n.
	.globl	hg_mapfail_n
hg_mapfail_n:
	.long	0			| as_map REFUSED the grow.  Nonzero with hg_landed_n
					| 0 means the defect is in as_map/segvn_create, not
					| here, and this fix is inert but harmless.
	.globl	hg_unres_n
hg_unres_n:
	.long	0			| grown, mapped, and the resolver STILL refused --
					| the invariant-breaking case.  Must stay 0.
	.globl	hg_far_n
hg_far_n:
	.long	0			| a refused user write ABOVE the one-page window: a
					| genuinely wild store.  Named and counted, still
					| SIGSEGV -- this is the isolation the window buys.
| --- last-event latches, for reading a run that did something unexpected ---
	.globl	hg_last_addr
hg_last_addr:
	.long	0			| the fault address of the last grow
	.globl	hg_last_base
hg_last_base:
	.long	0			| the page it mapped (== round4k of the old break)
	.globl	hg_last_err
hg_last_err:
	.long	0			| the last as_map errno, or the last unresolved verdict
	.globl	hg_far_addr
hg_far_addr:
	.long	0			| the last out-of-window address seen
	.balign 4			| pad section to a 4-byte multiple (bss placement)
