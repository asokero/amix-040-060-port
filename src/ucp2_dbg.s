| ucp2_dbg.s -- BLIZZARD F4 round 8, ARM I: the paired ucontext bracket of round 7, extended
| with a SECOND fold that sees even parity, a format histogram, a full-frame evidence slot and
| two wall counters.  It supersedes src/ucp_dbg.s (round 7) inside the SAME two hook points and
| adds no new hook site.  (2026-08-25)
|
| Registered in docs/060-F4-M2-ATT8-PREREG-260825.md 4.1, BEFORE this file existed, and that
| document was committed (868936f) before a line of this one was written.  Read it first; this
| comment does not restate its tables.  Deviations from it are listed at the end of this header
| and in docs/060-F4-M2-ATT8-ARMS-260825.md 4.
|
| WHY A SECOND FOLD.  Both folds this campaign has used are the same plain XOR (...ATT7-RESULTS...
| 8.3): stampsum's and ours.  An XOR fold cannot see an EVEN number of flips of one bit -- two
| longwords flipping the same bit cancel exactly -- so every event ever scored has had an odd
| number of differing longwords BY CONSTRUCTION, and the population of even-parity events has
| never been bounded.  A rotating fold, acc = rol(acc,1) ^ word, is position-weighted: two
| longwords flipping the same bit no longer cancel, because they are at different positions.  It
| is one extra instruction per longword and one extra accumulator, computed in the SAME pass as
| the plain fold; no second walk over the 804 bytes.  ucp_rot_bad_n counts the restores where
| the rotating folds disagree WHILE THE PLAIN FOLD PASSED -- the population stock cannot see --
| and ucp_rot_n counts every restore where the comparison was possible at all (a stamp hit), so
| the count has a denominator.
|
| WHY IT CANNOT FALSE-POSITIVE ON A LEGITIMATE ucontext EDIT.  Both folds cover mc_state[0..200]
| only.  A signal handler that legitimately rewrites resume registers writes gregs at ucp+0x24,
| OUTSIDE the fold, so neither fold moves.  A handler that rewrote mc_state itself would not know
| the kernel's internal stamp and could not re-stamp it, so its object would fail the PLAIN fold
| and land in the bad path, never the rot-disagree-plain-pass path.  So a rot disagreement while
| the plain fold passes means the object's XOR was preserved while its bytes changed: an
| even-parity change to a stamped object, which is the invisible corruption and nothing else.
|
| THE FORMAT HISTOGRAM, AND WHY.  ...ATT7-RESULTS... 8.2 named the four flipped bits as the m68k
| exception-frame FORMAT nibble, bits 12-15 of mc_state[1], which prsetstate reads out of the
| user-supplied object and uses to size a bcopy through framesz[].  ucp_fmt_h0..ucp_fmt_h15 count
| every restore by (mc_state[1] >> 12) & 15, so a healthy 68060 boot is dominated by the formats
| it generates (0 for syscall traps, 4 for access errors) and ucp_fmt_bad_n -- nibbles that are
| neither 0 nor 4 -- is the direct test of ...ATT7-RESULTS... 8.2's bridge.  The first such frame
| is latched in full: the nibble, mc_state[0..3], the ucp and the restore sequence number.
|
| THE EVIDENCE SLOT.  ucpev is a fifth 820-byte slot OUTSIDE the ring.  On the first restore that
| carries a real difference it takes a verbatim copy of the whole 804-byte RESTORE-SIDE region;
| the save-side copy is already in the ring slot that paired, and both survive to read time, so
| one boot yields a complete longword-by-longword diff instead of twelve triples.  The live
| kernel buffer is a stack address that is gone by the time an operator reads anything, so this
| is the only way to get the full frame.
|
| THE TWO WALL COUNTERS.  ucp_r_at_wall and ucp_s_at_wall latch ucp_r_n and ucp_save_n at the
| moment uft_have is first seen non-zero -- the same freeze the layout row already runs for
| ucp_ms_lock, two stores beside it.  ucp_r_at_wall == 0 says the first wall preceded every
| restorecontext in the boot, which refutes ...ATT7-RESULTS... 3's hypothesis for that boot from
| counters alone; a non-zero value keeps the hypothesis alive.  Both read ffffffff on a boot the
| wall never touched.
|
| EVERYTHING ELSE IS ROUND 7, UNCHANGED IN INTENT.  The 4.1 sentinel killer (ucp_sent0 at LOGICAL
| 0 through DTT0), the stamp-keyed four-slot shadow ring, the VOID self-check, the twelve-triple
| latch, the 4.4 layout row and the whole inertness set carry over verbatim; the only structural
| difference on the SAVE side is a fifth metadata longword per slot (the save-time rotating
| fold), which grows the slot from 820 to 824 bytes.  See src/ucp_dbg.s's header for the design
| of the parts this file inherits; it is not restated here.
|
| REGISTERED COST, and it is not small.  Round 7 folded 201 longwords and copied 804 bytes per
| save, and folded 201 per restore ONLY on a bad fold.  Arm I adds one instruction per longword
| to both folds, and -- the item to watch -- a four-slot ring scan on EVERY restore rather than
| only bad ones, ~190,000 times a boot, so the comparison of the two folds is always possible.
| A BOOT IN WHICH THE REFUSAL DOES NOT OCCUR STILL CANNOT BE READ AS "THE DEFECT WENT AWAY":
| ...ATT7-UCP... 10 is not repealed and this arm perturbs the same path harder.
|
| EVERYTHING IS HEX.  A ucp_* slot reading ffffffff means NOT APPLICABLE, not zero.  A shadow
| slot's "never written" marker is a sequence number of ZERO, because the sequence number is the
| validity field and starts at 1; it is cleared before a fill and written after it.
|
| DEVIATIONS FROM 4.1, stated here rather than left to be discovered:
|   1. inherited from round 7 and kept: a shadow slot carries our SAVE-TIME PLAIN fold at slot+12
|      (so 4.2's VOID rule compares against a MEASURED ffffffff), and ucp_dup_n / ucp_hit_n /
|      ucp_diffev_n measure whether a pairing engaged at all.
|   2. a rotating fold is stored beside it at slot+16 (a fifth metadata longword; 4.1 says "a
|      fifth" metadata longword and this is it), so the two folds of a shadowed frame can be read
|      out and re-derived by hand -- which is what bench row 4 needs to prove the two folds are
|      DIFFERENT functions rather than one that never disagrees with anything.
|   3. ucp_rot_b_* latch the FIRST rot-disagree-plain-pass event (seq, ucp, stamp, slot, and both
|      rotating folds).  4.1 registers only the counter; without the latch a non-zero
|      ucp_rot_bad_n is a count with no witness, which is the "null result that means nothing"
|      this project refuses.  It is a one-shot and costs six longwords of .data.
|   4. ucpev's 16-byte header is (seq, stamp, ucp, slot) so the slot the operator must read for
|      the save side is named in the evidence itself; 4.1 does not specify the header.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c ucp2_dbg.s -o build/ucp2_dbg.o
| Wire:     relink-040-f8.sh --ucp2 (objcopy weaken + the two *_orig aliases).
|           Externals: savecontext_orig, restorecontext_orig, uft_have.
| ============================================================================

	MC_OFF	=	216		| ucp+0xD8 -- mc_state[0], and the fold's base
	MC_STMP	=	1016		| ucp+0x3F8 -- where savecontext stores ~sum
	MC_N	=	201		| longwords the checksum covers (200 + the stamp)
	MS4	=	MC_OFF+16	| ucp+0xE8 -- mc_state[4], where 4.4 starts looking

	UCP_SLOTS =	4		| ring depth: three levels of nesting
	UCP_DOFF  =	20		| seq, stamp, ucp, PLAIN fold, ROT fold, then the 804 bytes
	UCP_SLOT  =	824		| 20 + 804.  4 * 824 = 3296 bytes of .data
	UCP_DIFFS =	12		| triples latched in full

	EV_DOFF	=	16		| ucpev header: seq, stamp, ucp, slot
	EV_SIZE	=	820		| 16 + 804 -- the whole restore-side region, once

	ARG	=	36		| savecontext:    after the 32-byte save, the ucp
	RARG	=	52		| restorecontext: after the 48-byte save, the ucp

	.text

| ============================================================================
| savecontext(ucp, link) -- wrapper.  The stamp does not exist until the stock body has run, so
| the latch is on the far side of the call.  Stock returns in BOTH %d0 and %a0.
| ============================================================================
	.globl	savecontext
savecontext:
	movel	%sp@(8),%sp@-		| re-push link  (arg2)
	movel	%sp@(8),%sp@-		| re-push ucp   (arg1, now one push further up)
	jsr	savecontext_orig
	addql	&8,%sp
	tstl	ucp_on
	beqw	Lucp_s_out		| latch off: %d0/%a0 untouched from the stock body
	moveml	%d0-%d3/%a0-%a3,%sp@-

| ---- 4.1's killer, once per boot: the longword at LOGICAL 0, in SUPERVISOR state, through
| DTT0's identity window.  Not a user dereference.  See src/ucp_dbg.s for the hazard note.
	tstl	ucp_sent0_n
	bnes	Lucp_s_nos
	subal	%a0,%a0			| a0 = 0 (long: a word-size suba would NOT zero)
	movel	%a0@,ucp_sent0
	addql	&1,ucp_sent0_n
Lucp_s_nos:
	movel	%sp@(ARG),%d3
	beqw	Lucp_s_pop		| defensive: no buffer, no reading
	moveal	%d3,%a2
	addql	&1,ucp_save_n

| ---- BOTH folds, taken in the same breath as the stamp was written.  Lucp_fold2 returns the
| plain XOR in %d1 and the rotating fold in %d0; both go into the shadow.
	lea	%a2@(MC_OFF),%a0
	bsrw	Lucp_fold2		| -> %d1 plain, %d0 rot; both survive to the slot store
	moveq	&-1,%d2
	cmpl	%d1,%d2
	beqs	Lucp_s_fok
	addql	&1,ucp_s_bad_n		| the plain stamp is wrong AT BIRTH
Lucp_s_fok:

| ---- 4.4's layout row: mc_state[4..19] at the last save BEFORE the first wall fault, plus the
| two wall counters.  The freeze key is tested BEFORE the rewrite, or the sendsig the wall
| provokes eats the frame.
	tstl	ucp_ms_lock
	bnew	Lucp_s_ring
	tstl	uft_have
	beqs	Lucp_s_lay
	movel	&1,ucp_ms_lock		| the census has latched a fault: freeze what we hold
	movel	ucp_r_n,ucp_r_at_wall	| ... and the two wall counters, beside the freeze
	movel	ucp_save_n,ucp_s_at_wall
	braw	Lucp_s_ring
Lucp_s_lay:
	movel	ucp_save_n,ucp_ms_seq
	movel	%a2,ucp_ms_ucp
	movel	%a2@(MC_STMP),ucp_ms_stamp
	lea	%a2@(MS4),%a0
	lea	ucp_ms4,%a1
	moveq	&16,%d2
Lucp_s_ll:
	movel	%a0@+,%a1@+
	subql	&1,%d2
	bnes	Lucp_s_ll

| ---- the shadow.  UCP_SLOT does not divide by a shift, so the slot is reached by walking at
| most three times rather than by a multiply.
Lucp_s_ring:
	lea	ucpshadow,%a3
	movel	ucp_ring_i,%d2
	beqs	Lucp_s_got
Lucp_s_adv:
	lea	%a3@(UCP_SLOT),%a3
	subql	&1,%d2
	bnes	Lucp_s_adv
Lucp_s_got:
	clrl	%a3@			| EMPTY for the duration of the fill
	movel	%a2@(MC_STMP),%a3@(4)
	movel	%a2,%a3@(8)
	movel	%d1,%a3@(12)		| our save-time PLAIN fold
	movel	%d0,%a3@(16)		| our save-time ROTATING fold  (the fifth longword)
	lea	%a2@(MC_OFF),%a0
	lea	%a3@(UCP_DOFF),%a1
	movel	&MC_N,%d2
Lucp_s_cp:
	movel	%a0@+,%a1@+
	subql	&1,%d2
	bnes	Lucp_s_cp
	movel	ucp_save_n,%a3@		| ... and VALID only when the sequence number lands
	movel	ucp_ring_i,%d2
	addql	&1,%d2
	cmpil	&UCP_SLOTS,%d2
	bnes	Lucp_s_wrp
	moveq	&0,%d2
Lucp_s_wrp:
	movel	%d2,ucp_ring_i
Lucp_s_pop:
	moveml	%sp@+,%d0-%d3/%a0-%a3
Lucp_s_out:
	moveal	%d0,%a0			| stock hands the result back in both registers
	rts

| ============================================================================
| restorecontext(ucp) -- prologue hook.  Histogram every restore, fold both ways, and on a stamp
| hit compare the rotating fold whether or not the plain fold passed.  The stock body then runs
| unchanged with the stack byte-identical.
| ============================================================================
	.globl	restorecontext
restorecontext:
	tstl	ucp_on
	beqw	Lucp_r_pass
	moveml	%d0-%d7/%a0-%a3,%sp@-
	movel	%sp@(RARG),%d3
	beqw	Lucp_r_pop		| defensive: no buffer, no reading
	moveal	%d3,%a2
	addql	&1,ucp_r_n

| ---- the format histogram, on EVERY restore, indexed by (mc_state[1] >> 12) & 15.
	movel	%a2@(MC_OFF+4),%d4	| mc_state[1] -- the format/vector longword
	moveq	&12,%d0
	lsrl	%d0,%d4
	andil	&15,%d4			| d4 = the format nibble
	movel	%d4,%d0
	lsll	&2,%d0
	lea	ucp_fmt_h0,%a0
	addal	%d0,%a0
	addql	&1,%a0@			| ++ucp_fmt_h<nibble>
	tstl	%d4
	beqs	Lucp_r_fmtok		| format 0 -- expected
	cmpil	&4,%d4
	beqs	Lucp_r_fmtok		| format 4 -- expected
	addql	&1,ucp_fmt_bad_n
	movel	ucp_fmt_bad_nib,%d0
	cmpil	&-1,%d0
	bnes	Lucp_r_fmtok		| already latched a bad-format frame
	movel	%d4,ucp_fmt_bad_nib	| latch the FIRST bad-format frame in full
	movel	%a2@(MC_OFF),ucp_fmt_bad_m0
	movel	%a2@(MC_OFF+4),ucp_fmt_bad_m1
	movel	%a2@(MC_OFF+8),ucp_fmt_bad_m2
	movel	%a2@(MC_OFF+12),ucp_fmt_bad_m3
	movel	%a2,ucp_fmt_bad_ucp
	movel	ucp_r_n,ucp_fmt_bad_seq
Lucp_r_fmtok:

| ---- both folds of the object stock is about to read
	lea	%a2@(MC_OFF),%a0
	bsrw	Lucp_fold2		| -> %d1 plain, %d0 rot
	movel	%d0,%d5			| d5 = restore-side ROTATING fold, kept
	movel	%d1,%d0			| d0 = PLAIN fold, kept for the latch header and compares

| ---- the lookup: this object's OWN earlier self, keyed by the stamp it arrived with, on EVERY
| restore.  All four slots are scanned so an ambiguous key is COUNTED; the newest match wins.
	movel	%a2@(MC_STMP),%d3	| the stamp to find
	subal	%a3,%a3			| no match yet
	moveq	&0,%d4			| best sequence number so far
	moveq	&-1,%d1			| best slot index
	moveq	&0,%d6			| how many slots carry this stamp
	lea	ucpshadow,%a1
	moveq	&0,%d7			| current slot index
	moveq	&UCP_SLOTS,%d2
Lucp_scan:
	tstl	%a1@			| sequence number 0 -- never written
	beqs	Lucp_scnx
	cmpl	%a1@(4),%d3
	bnes	Lucp_scnx
	addql	&1,%d6
	cmpl	%a1@,%d4		| unsigned: a sequence number only grows
	bccs	Lucp_scnx		| already holding one at least as new
	movel	%a1@,%d4
	moveal	%a1,%a3
	movel	%d7,%d1
Lucp_scnx:
	lea	%a1@(UCP_SLOT),%a1
	addql	&1,%d7
	subql	&1,%d2
	bnes	Lucp_scan

	cmpil	&1,%d6
	blss	Lucp_r_look		| nought or one slot matched
	addql	&1,ucp_dup_n		| the stamp is not a unique key on this boot
Lucp_r_look:
	movel	%a3,%d7
	bnew	Lucp_r_hit
| no shadow held this object's earlier self.  If the PLAIN fold said corrupt, this is the
| round-7 miss; otherwise there is simply nothing to pair (the ring had not filled yet).
	moveq	&-1,%d2
	cmpl	%d0,%d2
	beqw	Lucp_r_pop
	addql	&1,ucp_bad_n
	addql	&1,ucp_miss_n
	braw	Lucp_r_pop
Lucp_r_hit:
	addql	&1,ucp_rot_n		| a comparison was possible -- the denominator
	movel	%a3@(16),%d2		| the shadow's SAVE-TIME rotating fold
	moveq	&-1,%d7
	cmpl	%d0,%d7
	bnew	Lucp_r_bad		| the PLAIN fold says corrupt: the round-7 path

| ---- the plain fold PASSED.  If the rotating folds disagree, this is an even-parity event the
| plain fold -- and therefore stock -- could never see.
	cmpl	%d2,%d5
	beqw	Lucp_r_pop		| the two folds agree: an ordinary faithful round trip
	addql	&1,ucp_rot_bad_n	| THE INVISIBLE POPULATION, sized for the first time
	movel	ucp_rot_b_seq,%d7
	cmpil	&-1,%d7
	bnew	Lucp_r_pop		| the rot latch is a one-shot
	movel	ucp_r_n,ucp_rot_b_seq
	movel	%a2,ucp_rot_b_ucp
	movel	%a2@(MC_STMP),ucp_rot_b_stamp
	movel	%d1,ucp_rot_b_slot
	movel	%d5,ucp_rot_b_rot	| restore-side rotating fold
	movel	%d2,ucp_rot_b_s_rot	| save-side rotating fold
	braw	Lucp_r_pop

Lucp_r_bad:
	addql	&1,ucp_bad_n
	addql	&1,ucp_hit_n

| ---- pass 1: count the differences and their bit union.  It stores nothing, so a VOID event
| cannot consume the one-shot latches that a real difference is owed.
	lea	%a2@(MC_OFF),%a0
	lea	%a3@(UCP_DOFF),%a1
	moveq	&0,%d4			| differences
	moveq	&0,%d6			| bit union of (save-time XOR restore-time)
	movel	&MC_N,%d2
Lucp_p1:
	movel	%a1@+,%d3		| save-time
	movel	%a0@+,%d7		| restore-time
	cmpl	%d3,%d7
	beqs	Lucp_p1n
	addql	&1,%d4
	eorl	%d7,%d3
	orl	%d3,%d6
Lucp_p1n:
	subql	&1,%d2
	bnes	Lucp_p1

	tstl	%d4
	bnew	Lucp_r_diff
	addql	&1,ucp_self_void	| the fold says corrupt and every byte agrees: VOID
	braw	Lucp_r_pop
Lucp_r_diff:
	addql	&1,ucp_diffev_n

| ---- the evidence slot, once: the whole 804-byte RESTORE-SIDE region, so one boot yields a
| complete longword-by-longword diff (the save side is in the paired ring slot).
	tstl	ucp_ev_n
	bnew	Lucp_r_evdone
	lea	ucpev,%a0
	movel	ucp_r_n,%a0@		| header +0 seq
	movel	%a2@(MC_STMP),%a0@(4)	| +4 stamp
	movel	%a2,%a0@(8)		| +8 ucp
	movel	%d1,%a0@(12)		| +12 slot -- where the save side is
	lea	%a0@(EV_DOFF),%a1
	lea	%a2@(MC_OFF),%a0
	movel	&MC_N,%d2
Lucp_ev_cp:
	movel	%a0@+,%a1@+
	subql	&1,%d2
	bnes	Lucp_ev_cp
	addql	&1,ucp_ev_n
Lucp_r_evdone:

| ---- the latch, once: the header, then the first twelve differences in full
	tstl	ucp_stamp
	bnew	Lucp_r_pop		| the full latch is a one-shot; the counters are not
	movel	&0x55434621,ucp_stamp	| "UCF!" -- silence must not look like a null result
	movel	ucp_r_n,ucp_b_seq
	movel	%a2,ucp_b_ucp
	movel	%d0,ucp_b_fold		| our plain entry fold -- the read that said "corrupt"
	movel	%a2@(MC_STMP),ucp_b_stamp
	movel	%d1,ucp_b_slot
	movel	%a3@,ucp_b_s_seq
	movel	%a3@(8),ucp_b_s_ucp	| must equal ucp_b_ucp, or the stamp paired two objects
	movel	%a3@(12),ucp_b_s_fold	| must read ffffffff, or the shadow was bad at birth
	movel	%d4,ucp_b_n
	movel	%d6,ucp_b_bits
	lea	%a2@(MC_OFF),%a0
	lea	%a3@(UCP_DOFF),%a1
	lea	ucp_b_i0,%a2		| the ucp is not needed again
	moveq	&0,%d1			| longword index within mc_state
	moveq	&0,%d4			| triples stored
	movel	&MC_N,%d2
Lucp_p2:
	movel	%a1@+,%d3
	movel	%a0@+,%d7
	cmpl	%d3,%d7
	beqs	Lucp_p2n
	movel	%d1,%a2@+		| index
	movel	%d3,%a2@+		| save-time value
	movel	%d7,%a2@+		| restore-time value
	addql	&1,%d4
	cmpil	&UCP_DIFFS,%d4
	beqw	Lucp_r_pop		| twelve is the registered depth
Lucp_p2n:
	addql	&1,%d1
	subql	&1,%d2
	bnes	Lucp_p2

Lucp_r_pop:
	moveml	%sp@+,%d0-%d7/%a0-%a3
Lucp_r_pass:
	jmp	restorecontext_orig

| ============================================================================
| Lucp_fold2 -- %a0 = base.  Returns the plain XOR fold of MC_N longwords in %d1 AND the rotating
| fold acc=rol(acc,1)^word in %d0, in one pass.  Clobbers %d0, %d1, %d2, %d3, %a0.  m68k EOR is
| `EOR Dn,<ea>` only, hence the load into %d3.
| ============================================================================
Lucp_fold2:
	moveq	&0,%d1			| the plain accumulator
	moveq	&0,%d0			| the rotating accumulator
	movel	&MC_N,%d2
Lucp_fl2:
	movel	%a0@+,%d3
	eorl	%d3,%d1			| plain: acc ^= word
	roll	&1,%d0			| rotating: acc = rol(acc,1) ...
	eorl	%d3,%d0			|                      ... ^ word
	subql	&1,%d2
	bnes	Lucp_fl2
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it returns a plausible
| number from whatever now lives there.  Every address for this block comes from
| tools/status-facts.sh against the artifact actually booted, at the load base actually observed;
| NEVER from an on-box nlist of /stand/unix, which is a different kernel because the one under
| test is installed into the BOOT SLICE.
	.globl	ucp_magic
ucp_magic:
	.long	0x55435021		| "UCP!"
	.globl	ucp_on
ucp_on:
	.long	1			| 0 = bracket out of the path, for a one-word control

| ---- the ring geometry, stamped here so no tool carries a second copy of it --------------
	.globl	ucp_slots
ucp_slots:
	.long	UCP_SLOTS
	.globl	ucp_slot
ucp_slot:
	.long	UCP_SLOT		| bytes per slot (824 = 20 metadata + 804 shadowed)
	.globl	ucp_doff
ucp_doff:
	.long	UCP_DOFF		| where the 804 copied bytes start inside a slot (now 20)

| ---- 4.1's KILLER.  ucp_sent0 must read 4afc0000 ----------------------------------------
	.globl	ucp_sent0
ucp_sent0:
	.long	0xffffffff		| the longword at LOGICAL 0, read in supervisor state
	.globl	ucp_sent0_n
ucp_sent0_n:
	.long	0			| 1 once the read has been taken (it is taken once)

| ---- the savecontext side ---------------------------------------------------------------
	.globl	ucp_save_n
ucp_save_n:
	.long	0			| savecontext calls, and therefore shadow copies
	.globl	ucp_s_bad_n
ucp_s_bad_n:
	.long	0			| ... whose plain 201-fold was not FFFFFFFF on return
	.globl	ucp_ring_i
ucp_ring_i:
	.long	0			| the slot the NEXT save will write

| ---- the restorecontext side ------------------------------------------------------------
	.globl	ucp_r_n
ucp_r_n:
	.long	0			| restorecontext calls
	.globl	ucp_bad_n
ucp_bad_n:
	.long	0			| ... whose plain 201-fold was not FFFFFFFF at entry
	.globl	ucp_hit_n
ucp_hit_n:
	.long	0			| ... where the stamp found a shadow AND the plain fold was bad
	.globl	ucp_miss_n
ucp_miss_n:
	.long	0			| ... plain-bad where it did not.  >= ucp_bad_n = scope
	.globl	ucp_dup_n
ucp_dup_n:
	.long	0			| ... where MORE THAN ONE slot carried that stamp
	.globl	ucp_self_void
ucp_self_void:
	.long	0			| fold says corrupt, byte compare says identical: VOID
	.globl	ucp_diffev_n
ucp_diffev_n:
	.long	0			| paired bad restores that really did differ
	.globl	ucp_stamp
ucp_stamp:
	.long	0			| "UCF!" once the twelve-difference body ran

| ---- the FIRST paired difference, latched once ------------------------------------------
	.globl	ucp_b_seq
ucp_b_seq:
	.long	0xffffffff		| ucp_r_n at the moment it fired
	.globl	ucp_b_ucp
ucp_b_ucp:
	.long	0xffffffff
	.globl	ucp_b_fold
ucp_b_fold:
	.long	0xffffffff		| our plain entry fold -- the read that said "corrupt"
	.globl	ucp_b_stamp
ucp_b_stamp:
	.long	0xffffffff
	.globl	ucp_b_slot
ucp_b_slot:
	.long	0xffffffff		| which ring slot paired
	.globl	ucp_b_s_seq
ucp_b_s_seq:
	.long	0xffffffff		| the shadow's save sequence number
	.globl	ucp_b_s_ucp
ucp_b_s_ucp:
	.long	0xffffffff		| must equal ucp_b_ucp
	.globl	ucp_b_s_fold
ucp_b_s_fold:
	.long	0xffffffff		| must read ffffffff
	.globl	ucp_b_n
ucp_b_n:
	.long	0xffffffff		| longwords that differed IN TOTAL (may exceed 12)
	.globl	ucp_b_bits
ucp_b_bits:
	.long	0xffffffff		| OR of every (save XOR restore)
| The twelve triples must stay adjacent and in declaration order: Lucp_p2 writes them with a
| post-increment loop, so a reordering edit would still assemble, still link, and quietly
| mislabel every difference on the console.  relink-040-f8.sh asks the LINK, not this file.
	.globl	ucp_b_i0
ucp_b_i0:
	.long	0xffffffff
	.globl	ucp_b_s0
ucp_b_s0:
	.long	0xffffffff
	.globl	ucp_b_r0
ucp_b_r0:
	.long	0xffffffff
	.globl	ucp_b_i1
ucp_b_i1:
	.long	0xffffffff
	.globl	ucp_b_s1
ucp_b_s1:
	.long	0xffffffff
	.globl	ucp_b_r1
ucp_b_r1:
	.long	0xffffffff
	.globl	ucp_b_i2
ucp_b_i2:
	.long	0xffffffff
	.globl	ucp_b_s2
ucp_b_s2:
	.long	0xffffffff
	.globl	ucp_b_r2
ucp_b_r2:
	.long	0xffffffff
	.globl	ucp_b_i3
ucp_b_i3:
	.long	0xffffffff
	.globl	ucp_b_s3
ucp_b_s3:
	.long	0xffffffff
	.globl	ucp_b_r3
ucp_b_r3:
	.long	0xffffffff
	.globl	ucp_b_i4
ucp_b_i4:
	.long	0xffffffff
	.globl	ucp_b_s4
ucp_b_s4:
	.long	0xffffffff
	.globl	ucp_b_r4
ucp_b_r4:
	.long	0xffffffff
	.globl	ucp_b_i5
ucp_b_i5:
	.long	0xffffffff
	.globl	ucp_b_s5
ucp_b_s5:
	.long	0xffffffff
	.globl	ucp_b_r5
ucp_b_r5:
	.long	0xffffffff
	.globl	ucp_b_i6
ucp_b_i6:
	.long	0xffffffff
	.globl	ucp_b_s6
ucp_b_s6:
	.long	0xffffffff
	.globl	ucp_b_r6
ucp_b_r6:
	.long	0xffffffff
	.globl	ucp_b_i7
ucp_b_i7:
	.long	0xffffffff
	.globl	ucp_b_s7
ucp_b_s7:
	.long	0xffffffff
	.globl	ucp_b_r7
ucp_b_r7:
	.long	0xffffffff
	.globl	ucp_b_i8
ucp_b_i8:
	.long	0xffffffff
	.globl	ucp_b_s8
ucp_b_s8:
	.long	0xffffffff
	.globl	ucp_b_r8
ucp_b_r8:
	.long	0xffffffff
	.globl	ucp_b_i9
ucp_b_i9:
	.long	0xffffffff
	.globl	ucp_b_s9
ucp_b_s9:
	.long	0xffffffff
	.globl	ucp_b_r9
ucp_b_r9:
	.long	0xffffffff
	.globl	ucp_b_i10
ucp_b_i10:
	.long	0xffffffff
	.globl	ucp_b_s10
ucp_b_s10:
	.long	0xffffffff
	.globl	ucp_b_r10
ucp_b_r10:
	.long	0xffffffff
	.globl	ucp_b_i11
ucp_b_i11:
	.long	0xffffffff
	.globl	ucp_b_s11
ucp_b_s11:
	.long	0xffffffff
	.globl	ucp_b_r11
ucp_b_r11:
	.long	0xffffffff

| ---- 4.4's layout row: mc_state[4..19] at the last save before the first wall fault ---------
	.globl	ucp_ms_lock
ucp_ms_lock:
	.long	0			| 1 once uft_have was seen non-zero: the block is frozen
	.globl	ucp_ms_seq
ucp_ms_seq:
	.long	0xffffffff		| ucp_save_n of the save the sixteen longwords are from
	.globl	ucp_ms_ucp
ucp_ms_ucp:
	.long	0xffffffff
	.globl	ucp_ms_stamp
ucp_ms_stamp:
	.long	0xffffffff
| The sixteen must stay adjacent and in declaration order: Lucp_s_ll writes them with a
| post-increment loop.  relink-040-f8.sh asks the LINK.
	.globl	ucp_ms4
ucp_ms4:
	.long	0xffffffff
	.globl	ucp_ms5
ucp_ms5:
	.long	0xffffffff
	.globl	ucp_ms6
ucp_ms6:
	.long	0xffffffff
	.globl	ucp_ms7
ucp_ms7:
	.long	0xffffffff
	.globl	ucp_ms8
ucp_ms8:
	.long	0xffffffff
	.globl	ucp_ms9
ucp_ms9:
	.long	0xffffffff
	.globl	ucp_ms10
ucp_ms10:
	.long	0xffffffff
	.globl	ucp_ms11
ucp_ms11:
	.long	0xffffffff
	.globl	ucp_ms12
ucp_ms12:
	.long	0xffffffff
	.globl	ucp_ms13
ucp_ms13:
	.long	0xffffffff
	.globl	ucp_ms14
ucp_ms14:
	.long	0xffffffff
	.globl	ucp_ms15
ucp_ms15:
	.long	0xffffffff
	.globl	ucp_ms16
ucp_ms16:
	.long	0xffffffff
	.globl	ucp_ms17
ucp_ms17:
	.long	0xffffffff
	.globl	ucp_ms18
ucp_ms18:
	.long	0xffffffff
	.globl	ucp_ms19
ucp_ms19:
	.long	0xffffffff

| ---- ARM I: the rotating fold's counters -----------------------------------------------
	.globl	ucp_rot_n
ucp_rot_n:
	.long	0			| restores where a comparison was possible (a stamp hit)
	.globl	ucp_rot_bad_n
ucp_rot_bad_n:
	.long	0			| ... where the rotating folds disagreed while plain PASSED
| The first rot-disagree-plain-pass event, latched once.
	.globl	ucp_rot_b_seq
ucp_rot_b_seq:
	.long	0xffffffff		| ucp_r_n at the moment the rot latch fired
	.globl	ucp_rot_b_ucp
ucp_rot_b_ucp:
	.long	0xffffffff
	.globl	ucp_rot_b_stamp
ucp_rot_b_stamp:
	.long	0xffffffff
	.globl	ucp_rot_b_slot
ucp_rot_b_slot:
	.long	0xffffffff		| which ring slot paired
	.globl	ucp_rot_b_rot
ucp_rot_b_rot:
	.long	0xffffffff		| the restore-side rotating fold
	.globl	ucp_rot_b_s_rot
ucp_rot_b_s_rot:
	.long	0xffffffff		| the save-side rotating fold (from the shadow)

| ---- ARM I: the evidence slot's counter, and the two wall counters ---------------------
	.globl	ucp_ev_n
ucp_ev_n:
	.long	0			| 1 once ucpev holds the first differing restore-side frame
	.globl	ucp_r_at_wall
ucp_r_at_wall:
	.long	0xffffffff		| ucp_r_n latched when uft_have first went non-zero
	.globl	ucp_s_at_wall
ucp_s_at_wall:
	.long	0xffffffff		| ucp_save_n latched at the same moment

| ---- ARM I: the format histogram, and the first bad-format frame -----------------------
	.globl	ucp_fmt_bad_n
ucp_fmt_bad_n:
	.long	0			| restores whose format nibble was neither 0 nor 4
	.globl	ucp_fmt_bad_nib
ucp_fmt_bad_nib:
	.long	0xffffffff		| the nibble of the first such frame (ffffffff = none yet)
	.globl	ucp_fmt_bad_m0
ucp_fmt_bad_m0:
	.long	0xffffffff		| mc_state[0] of that frame
	.globl	ucp_fmt_bad_m1
ucp_fmt_bad_m1:
	.long	0xffffffff		| mc_state[1] -- the format/vector longword itself
	.globl	ucp_fmt_bad_m2
ucp_fmt_bad_m2:
	.long	0xffffffff
	.globl	ucp_fmt_bad_m3
ucp_fmt_bad_m3:
	.long	0xffffffff
	.globl	ucp_fmt_bad_ucp
ucp_fmt_bad_ucp:
	.long	0xffffffff
	.globl	ucp_fmt_bad_seq
ucp_fmt_bad_seq:
	.long	0xffffffff		| ucp_r_n when it was latched
| The sixteen histogram counters must stay adjacent and in declaration order: the restore hook
| indexes ucp_fmt_h0 by the nibble.  relink-040-f8.sh asks the LINK.
	.globl	ucp_fmt_h0
ucp_fmt_h0:
	.long	0
	.globl	ucp_fmt_h1
ucp_fmt_h1:
	.long	0
	.globl	ucp_fmt_h2
ucp_fmt_h2:
	.long	0
	.globl	ucp_fmt_h3
ucp_fmt_h3:
	.long	0
	.globl	ucp_fmt_h4
ucp_fmt_h4:
	.long	0
	.globl	ucp_fmt_h5
ucp_fmt_h5:
	.long	0
	.globl	ucp_fmt_h6
ucp_fmt_h6:
	.long	0
	.globl	ucp_fmt_h7
ucp_fmt_h7:
	.long	0
	.globl	ucp_fmt_h8
ucp_fmt_h8:
	.long	0
	.globl	ucp_fmt_h9
ucp_fmt_h9:
	.long	0
	.globl	ucp_fmt_h10
ucp_fmt_h10:
	.long	0
	.globl	ucp_fmt_h11
ucp_fmt_h11:
	.long	0
	.globl	ucp_fmt_h12
ucp_fmt_h12:
	.long	0
	.globl	ucp_fmt_h13
ucp_fmt_h13:
	.long	0
	.globl	ucp_fmt_h14
ucp_fmt_h14:
	.long	0
	.globl	ucp_fmt_h15
ucp_fmt_h15:
	.long	0

| ---- the evidence slot: 820 bytes, deliberately OUTSIDE the ucp_ counter block so it does not
| break the one-kpeek read.  Named ucpev, printed by tools/status-facts.sh from its own symbol.
| header: +0 seq  +4 stamp  +8 ucp  +12 slot ; then 804 bytes at +16 = mc_state[0..200].
	.globl	ucpev
ucpev:
	.space	EV_SIZE,0

| ---- the shadow ring itself.  Deliberately NOT named ucp_* : tools/status-facts.sh groups a
| counter block by that prefix, and 3296 bytes inside the block would break the one-kpeek read.
| Its address and geometry are printed from ucpshadow plus ucp_slots/ucp_slot/ucp_doff.  A slot
| whose first longword (the sequence number) is 0 has NEVER BEEN WRITTEN.
	.globl	ucpshadow
ucpshadow:
	.space	UCP_SLOTS*UCP_SLOT,0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
