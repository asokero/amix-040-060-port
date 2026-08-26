| mcstate_dbg.s -- BLIZZARD F4 round 6: the mc_state latch attempt 5's pre-registration 7
| specified and declined to carry.  (2026-08-25)
|
| Registered in docs/060-F4-M2-ATT6-PREREG-260825.md 2.4, 2.5, 3.1-3.2 and Table L, BEFORE
| this file existed.  Read that document first; this comment does not restate its tables.
|
| THE LEAD.  Five samples across two sessions of
|
|     Bad ucontext checksum (0x%x)in process: init
|
| with printed values FFFFCFFF (x1), FFFFEFFF (x3) and FFFFDFFF (x1).  The guard requires
| FFFFFFFF, so every delta is confined to BITS 12 AND 13 and nowhere else -- and the two bits
| flip INDEPENDENTLY, so it is not the fixed 0x3000 the attempt-5 pre-registration guessed at.
| Attempt-5 pre-reg 7 forbade a verdict without this instrument; Table L is what may take one.
|
| WHAT THE DISASSEMBLY ADDS, and it is the reason two of the three folds below exist.
| restorecontext (0x58d76) does:
|
|     stampsum(ucp+0xD8, 0xC9)     fold #1 over 201 longwords   <-- THE DECISION
|     cmp against FFFFFFFF, and on failure:
|     stampsum(ucp+0xD8, 0xC9)     fold #2 over THE SAME BYTES  <-- THE PRINTED VALUE
|     printf(...) ; psignal(curproc, 9)
|
| So the console value is a RE-READ, microseconds after the read that made the decision, and
| NOBODY HAS EVER SEEN FOLD #1.  If the region is unstable the two need not agree.  savecontext
| (0x58f10) folds 200 longwords over [ucp+0xD8, ucp+0x3F8) and stores ~sum at ucp+0x3F8;
| stampsum (0x59538) is a plain XOR fold.  mc_state therefore BEGINS at ucp+0xD8, which is the
| pointer prgetstate and prsetstate are handed, so mc_state[0..3] is ucp+0xD8 .. ucp+0xE4.
|
| WHY THIS IS SAFE TO READ.  Both ucp values are KERNEL addresses.  setcontext (0x4699e) does
| `linkw %fp,#-1024` and passes %fp-1024 to savecontext and, after a copyin, to restorecontext;
| sendsig (0x59022) does `linkw %fp,#-1192` and passes %fp-1024 to savecontext before
| copyout'ing it.  NOTHING HERE DEREFERENCES A USER ADDRESS -- the same rule src/ufault_dbg.s
| was built under, and the reason a probe that faults while probing cannot cost the boot.
|
| WHAT THE THREE FOLDS SEPARATE.  DTT0 = 0x003FC060 maps logical 0-1 GB cache-inhibited
| (src/pstart040.s:326), but the ucontext buffer is on the kernel stack at ~0x40001Fxx, which
| matches NEITHER TTR and is therefore PTE-mapped with CM from its leaf descriptor.  That CM
| is hat_cm_ram, and it is 0x20 = COPYBACK -- read out of the artifact by
| src/patch_b2_flip.py --check, NOT taken from pstart040.s's comment, which still says
| "hat_cm_ram=0x00 WT in B1" and has been stale since the default was reversed on 2026-07-30.
| The distinction is load-bearing, so it is stated rather than assumed:
|
|   fold_a vs fold_b   two reads back to back, no store between, both able to hit the same
|                      cache lines.  A difference is memory changing under two reads, and it
|                      is the strongest row here BECAUSE it does not depend on the CM at all.
|   fold_b vs fold_c   fold_c comes after `cpushl dc` over all 51 lines of the region.  UNDER
|                      COPYBACK THIS IS NOT A CACHE-VERSUS-RAM TEST: the buffer was just
|                      written by copyin, so its lines are dirty, and the push makes RAM agree
|                      with the cache before the re-read rather than revealing what RAM held.
|                      What it does test is that the write-back and re-fill paths are
|                      self-consistent -- a difference is a bus-level finding.  Revealing a
|                      stale RAM under copyback would need `cinvl dc`, which DISCARDS the
|                      dirty line and would repair or destroy the frame the kernel is about to
|                      act on.  That is a behaviour change, this unit is a census, and so it
|                      is deliberately not built.
|   mcs_s_bad_n        OUR fold, taken immediately after savecontext returns, must read
|                      FFFFFFFF.  If it does not, the stamp is wrong AT BIRTH and every
|                      restorecontext reading is about a frame that was never valid.  This is
|                      also what kills the "the two folds cover different things" reading
|                      before any boot: same algorithm, same 201 longwords, same base.
|
| AND WHAT LOCALIZES.  The XOR fold does not say WHICH longword changed.  mcs_*_blk0..blk7 are
| eight independent folds of the 201 longwords -- 25 each for blocks 0-6, 26 for block 7 -- so
| a good/bad diff names a block of 25.  Blocks 3..7 cover mc_state[77..199], 492 bytes that NO
| CODE EVER WRITES (attempt-5 pre-reg 2.5): uninitialised kernel stack the checksum nevertheless
| covers and copyout ships to userland.  A delta confined there is a stock defect, not a port
| one, and Table L's last row says so.
|
| HOW IT IS BOUND.  savecontext is WRAPPED (the interesting state does not exist until it
| returns) and restorecontext is hooked at its PROLOGUE (the frame to check is its argument).
| Both by `objcopy --weaken-symbol` plus a *_orig alias at the stock address, the same
| composition relink-040-f4arms.sh --dbg uses for swapconf.  savecontext has exactly two
| callers (setcontext+0x3e, sendsig+0x15a); restorecontext has exactly one (setcontext+0x9c).
|
| REGISTERED COST, because it is not small.  This unit folds 201 longwords on every
| savecontext and three times that on every restorecontext.  Attempt 5 boot 3b delivered
| 14,093 signals, so this arm measurably changes signal-path timing.  A BOOT IN WHICH THE
| REFUSAL DOES NOT OCCUR THEREFORE CANNOT BE READ AS "THE DEFECT WENT AWAY" -- it is one draw
| from a distribution this arm has perturbed.  mcs_on is the .data gate for a one-word control.
|
| EVERYTHING IS HEX.  An mcs_* slot reading ffffffff means NOT APPLICABLE, not zero.
|
| 040/060 ops as .word, the house idiom: cpushl dc,(a0) = 0xf468 (the a0 form).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c mcstate_dbg.s -o build/mcstate_dbg.o
| Wire:     relink-040-f6.sh --mcs (objcopy weaken + the two *_orig aliases).
|           Externals: savecontext_orig, restorecontext_orig.
| ============================================================================

	MC_OFF	=	216		| ucp+0xD8 -- mc_state[0], and the fold's base
	MC_STMP	=	1016		| ucp+0x3F8 -- where savecontext stores ~sum
	MC_N	=	201		| longwords restorecontext folds (200 + the stamp)
	MC_LINES =	51		| 201 longwords = 804 bytes = 51 sixteen-byte lines
	ARG	=	32		| after the 28-byte save: the ucp argument

	.text

| ============================================================================
| savecontext(ucp, link) -- wrapper.  The stamp does not exist until the stock body has
| run, so the latch is on the far side of the call.  Stock returns in BOTH %d0 and %a0.
| ============================================================================
	.globl	savecontext
savecontext:
	movel	%sp@(8),%sp@-		| re-push link  (arg2)
	movel	%sp@(8),%sp@-		| re-push ucp   (arg1, now one push further up)
	jsr	savecontext_orig
	addql	&8,%sp
	tstl	mcs_on
	beqw	Lmcs_s_out		| latch off: %d0/%a0 untouched from the stock body
	moveml	%d0-%d3/%a0-%a2,%sp@-
	movel	%sp@(ARG),%d3
	beqw	Lmcs_s_pop		| defensive: no buffer, no reading
	moveal	%d3,%a2
	addql	&1,mcs_s_n
	movel	%a2,mcs_s_ucp
	movel	%d0,mcs_s_ret
	movel	%a2@(MC_STMP),mcs_s_stamp
	movel	%a2@(MC_OFF),mcs_s_ms0
	movel	%a2@(MC_OFF+4),mcs_s_ms1
	movel	%a2@(MC_OFF+8),mcs_s_ms2
	movel	%a2@(MC_OFF+12),mcs_s_ms3
| the self-check: our own 201-fold, taken in the same breath as the stamp was written
	lea	%a2@(MC_OFF),%a0
	bsrw	Lmcs_fold
	movel	%d1,mcs_s_fold
	moveq	&-1,%d2
	cmpl	%d1,%d2
	beqs	Lmcs_s_pop
	addql	&1,mcs_s_bad_n		| the stamp is wrong AT BIRTH
Lmcs_s_pop:
	moveml	%sp@+,%d0-%d3/%a0-%a2
Lmcs_s_out:
	moveal	%d0,%a0			| stock hands the result back in both registers
	rts

| ============================================================================
| restorecontext(ucp) -- prologue hook.  The frame to check IS the argument, so the latch
| runs first and the stock body then runs unchanged with the stack byte-identical.
| ============================================================================
	.globl	restorecontext
restorecontext:
	tstl	mcs_on
	beqw	Lmcs_r_pass
	moveml	%d0-%d3/%a0-%a2,%sp@-
	movel	%sp@(ARG),%d3
	beqw	Lmcs_r_pop		| defensive: no buffer, no reading
	moveal	%d3,%a2
	addql	&1,mcs_r_n

| fold #a -- the read that corresponds to the one stock is about to make
	lea	%a2@(MC_OFF),%a0
	bsrw	Lmcs_fold
	movel	%d1,%d0
| fold #b -- the same 804 bytes, back to back, with no store in between
	lea	%a2@(MC_OFF),%a0
	bsrw	Lmcs_fold
	cmpl	%d1,%d0
	beqs	Lmcs_r_stable
	addql	&1,mcs_r_unstb_n	| memory changed under two reads
Lmcs_r_stable:
	moveq	&-1,%d2
	cmpl	%d0,%d2
	bnew	Lmcs_r_bad

| ---- GOOD: rewrite the LAST-GOOD block, so the first bad one has a reference to diff
	movel	%a2,mcs_g_ucp
	movel	%a2@(MC_STMP),mcs_g_stamp
	movel	%a2@(MC_OFF),mcs_g_ms0
	movel	%a2@(MC_OFF+4),mcs_g_ms1
	movel	%a2@(MC_OFF+8),mcs_g_ms2
	movel	%a2@(MC_OFF+12),mcs_g_ms3
	lea	%a2@(MC_OFF),%a0
	lea	mcs_g_blk0,%a1
	bsrw	Lmcs_blk8
	braw	Lmcs_r_pop

| ---- BAD: count every one, latch the first in full
Lmcs_r_bad:
	addql	&1,mcs_r_bad_n
	tstl	mcs_stamp
	bnew	Lmcs_r_pop
	movel	&0x4d434621,mcs_stamp	| "MCF!" -- silence must not look like a null result
	movel	mcs_r_n,mcs_b_seq
	movel	%a2,mcs_b_ucp
	movel	%d0,mcs_b_fold_a
	movel	%d1,mcs_b_fold_b
| fold #c -- after pushing every line of the region out of the data cache
	lea	%a2@(MC_OFF),%a0
	movel	&MC_LINES,%d2
Lmcs_push:
	.word	0xf468			| cpushl dc,(a0)
	nop
	lea	%a0@(16),%a0
	subql	&1,%d2
	bnes	Lmcs_push
	lea	%a2@(MC_OFF),%a0
	bsrw	Lmcs_fold
	movel	%d1,mcs_b_fold_c
	movel	%a2@(MC_STMP),mcs_b_stamp
	movel	%a2@(MC_OFF),mcs_b_ms0
	movel	%a2@(MC_OFF+4),mcs_b_ms1
	movel	%a2@(MC_OFF+8),mcs_b_ms2
	movel	%a2@(MC_OFF+12),mcs_b_ms3
	lea	%a2@(MC_OFF),%a0
	lea	mcs_b_blk0,%a1
	bsrw	Lmcs_blk8

Lmcs_r_pop:
	moveml	%sp@+,%d0-%d3/%a0-%a2
Lmcs_r_pass:
	jmp	restorecontext_orig

| ============================================================================
| Lmcs_fold -- %a0 = base.  Returns the XOR fold of MC_N longwords in %d1.
| Clobbers %d1, %d2, %d3, %a0.  m68k EOR is `EOR Dn,<ea>` only, hence the load into %d3.
| ============================================================================
Lmcs_fold:
	moveq	&0,%d1
	movel	&MC_N,%d2
Lmcs_fl:
	movel	%a0@+,%d3
	eorl	%d3,%d1
	subql	&1,%d2
	bnes	Lmcs_fl
	rts

| ============================================================================
| Lmcs_blk8 -- %a0 = base, %a1 = eight consecutive longwords to fill.  Blocks 0-6 fold 25
| longwords each and block 7 folds 26, so the eight together cover exactly MC_N and their
| XOR is the whole fold.  Clobbers %d0, %d1, %d2, %d3, %a0, %a1.
| ============================================================================
Lmcs_blk8:
	movel	&8,%d0
Lmcs_b8:
	movel	&25,%d2
	cmpil	&1,%d0
	bnes	Lmcs_b8n
	movel	&26,%d2			| the last block takes the odd longword: 7*25 + 26 = 201
Lmcs_b8n:
	moveq	&0,%d1
Lmcs_b8i:
	movel	%a0@+,%d3
	eorl	%d3,%d1
	subql	&1,%d2
	bnes	Lmcs_b8i
	movel	%d1,%a1@+
	subql	&1,%d0
	bnes	Lmcs_b8
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it returns a
| plausible number from whatever now lives there.  Every address for this block comes from
| tools/status-facts.sh against the artifact actually booted, at the load base actually
| observed; NEVER from an on-box nlist of /stand/unix, which is a different kernel because
| the one under test is installed into the BOOT SLICE.
	.globl	mcs_magic
mcs_magic:
	.long	0x4d435321		| "MCS!"
	.globl	mcs_on
mcs_on:
	.long	1			| 0 = latch out of the path, for a one-word control
	.globl	mcs_s_n
mcs_s_n:
	.long	0			| savecontext calls
	.globl	mcs_s_bad_n
mcs_s_bad_n:
	.long	0			| ... whose 201-fold was not FFFFFFFF on return (self-check)
	.globl	mcs_r_n
mcs_r_n:
	.long	0			| restorecontext calls
	.globl	mcs_r_bad_n
mcs_r_bad_n:
	.long	0			| ... whose 201-fold was not FFFFFFFF at entry
	.globl	mcs_r_unstb_n
mcs_r_unstb_n:
	.long	0			| ... where two back-to-back folds DISAGREED
	.globl	mcs_stamp
mcs_stamp:
	.long	0			| "MCF!" once the first-bad body ran

| ---- the LAST savecontext, rewritten every call -----------------------------------------
	.globl	mcs_s_ucp
mcs_s_ucp:
	.long	0xffffffff
	.globl	mcs_s_ret
mcs_s_ret:
	.long	0xffffffff
	.globl	mcs_s_stamp
mcs_s_stamp:
	.long	0xffffffff
	.globl	mcs_s_fold
mcs_s_fold:
	.long	0xffffffff
	.globl	mcs_s_ms0
mcs_s_ms0:
	.long	0xffffffff
	.globl	mcs_s_ms1
mcs_s_ms1:
	.long	0xffffffff
	.globl	mcs_s_ms2
mcs_s_ms2:
	.long	0xffffffff
	.globl	mcs_s_ms3
mcs_s_ms3:
	.long	0xffffffff

| ---- the FIRST BAD restorecontext, latched once -----------------------------------------
	.globl	mcs_b_seq
mcs_b_seq:
	.long	0xffffffff		| mcs_r_n at the moment it fired
	.globl	mcs_b_ucp
mcs_b_ucp:
	.long	0xffffffff
	.globl	mcs_b_fold_a
mcs_b_fold_a:
	.long	0xffffffff		| read 1
	.globl	mcs_b_fold_b
mcs_b_fold_b:
	.long	0xffffffff		| read 2 -- back to back, no store between
	.globl	mcs_b_fold_c
mcs_b_fold_c:
	.long	0xffffffff		| read 3 -- after cpushl dc over all 51 lines
	.globl	mcs_b_stamp
mcs_b_stamp:
	.long	0xffffffff
	.globl	mcs_b_ms0
mcs_b_ms0:
	.long	0xffffffff
	.globl	mcs_b_ms1
mcs_b_ms1:
	.long	0xffffffff
	.globl	mcs_b_ms2
mcs_b_ms2:
	.long	0xffffffff
	.globl	mcs_b_ms3
mcs_b_ms3:
	.long	0xffffffff
| The eight block folds must stay adjacent and in declaration order: Lmcs_blk8 writes them
| with a post-increment loop, so a reordering edit would still assemble, still link, and
| quietly mislabel every block on the console.  relink-040-f6.sh asks the LINK, not this file.
	.globl	mcs_b_blk0
mcs_b_blk0:
	.long	0xffffffff
	.globl	mcs_b_blk1
mcs_b_blk1:
	.long	0xffffffff
	.globl	mcs_b_blk2
mcs_b_blk2:
	.long	0xffffffff
	.globl	mcs_b_blk3
mcs_b_blk3:
	.long	0xffffffff
	.globl	mcs_b_blk4
mcs_b_blk4:
	.long	0xffffffff
	.globl	mcs_b_blk5
mcs_b_blk5:
	.long	0xffffffff
	.globl	mcs_b_blk6
mcs_b_blk6:
	.long	0xffffffff
	.globl	mcs_b_blk7
mcs_b_blk7:
	.long	0xffffffff

| ---- the LAST GOOD restorecontext, rewritten every time ---------------------------------
	.globl	mcs_g_ucp
mcs_g_ucp:
	.long	0xffffffff
	.globl	mcs_g_stamp
mcs_g_stamp:
	.long	0xffffffff
	.globl	mcs_g_ms0
mcs_g_ms0:
	.long	0xffffffff
	.globl	mcs_g_ms1
mcs_g_ms1:
	.long	0xffffffff
	.globl	mcs_g_ms2
mcs_g_ms2:
	.long	0xffffffff
	.globl	mcs_g_ms3
mcs_g_ms3:
	.long	0xffffffff
	.globl	mcs_g_blk0
mcs_g_blk0:
	.long	0xffffffff
	.globl	mcs_g_blk1
mcs_g_blk1:
	.long	0xffffffff
	.globl	mcs_g_blk2
mcs_g_blk2:
	.long	0xffffffff
	.globl	mcs_g_blk3
mcs_g_blk3:
	.long	0xffffffff
	.globl	mcs_g_blk4
mcs_g_blk4:
	.long	0xffffffff
	.globl	mcs_g_blk5
mcs_g_blk5:
	.long	0xffffffff
	.globl	mcs_g_blk6
mcs_g_blk6:
	.long	0xffffffff
	.globl	mcs_g_blk7
mcs_g_blk7:
	.long	0xffffffff
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
