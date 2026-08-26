| ucz_dbg.s -- BLIZZARD F4 round 8, ARM II: the paired ucontext bracket of round 7 plus ONE
| gated bzero of the never-written field, so every bit the mechanism sets is visible over zeros
| and the 784-byte kernel-memory disclosure is closed at the same time.  It supersedes
| src/ucp_dbg.s (round 7) inside the SAME two hook points and adds no new hook site.  (2026-08-25)
|
| Registered in docs/060-F4-M2-ATT8-PREREG-260825.md 4.2, BEFORE this file existed, and that
| document was committed (868936f) before a line of this one was written.  Read it first; this
| comment does not restate its tables.  Deviations from it are listed at the end of this header
| and in docs/060-F4-M2-ATT8-ARMS-260825.md 4.
|
| WHAT IT DOES.  ...ATT7-RESULTS... 7.3 measured that mc_state[4..199] -- 784 of the 800
| checksummed bytes, 97.5% -- are UNWRITTEN kernel stack on this LC68060, and copyout ships them
| to userland on every signal.  This arm zeroes exactly that field at save.  Over a zeroed field
| every source nibble is 0, so every bit the mechanism sets is VISIBLE (including bit 14, which
| ...ATT7-RESULTS... 8.2's S3 says was clear only by an artefact of the data); and the leak is
| closed, which is a real defect on its own merits (4.2, 6).
|
| WHY IT IS AN INSTRUMENT AND NOT A CURE.  A flip of 00000000 to 00002000 breaks the fold exactly
| as before, so this does NOT stop the SIGKILL.  6 forbids shipping it as a cure in any artifact
| of this round, and R14 forbids reading a quiet boot as one.  The bzero is behind the ucp_on
| gate the rest of the unit uses AND behind its own ucp_z_on word, so the shipping default cannot
| become a silent behaviour change.
|
| THE THREE GATES, and each is a way this arm can be wrong:
|   * IT MUST NOT ZERO ON A PART WITH AN FPU.  On such a part prgetfpstate writes the FP machine
|     state from mc_state[23] onward and zeroing it would destroy real state.  The gate is read
|     out of the object itself: uc_flags bit 3 is clear exactly when savecontext saw prhasfp()
|     return zero, so the arm declines when it is SET.  ucp_z_fpu_n counts the declines, so Rig
|     B's inertness is a MEASUREMENT (ucp_z_fpu_n = ucp_save_n, ucp_z_n = 0), not an argument.
|   * IT MUST NOT ZERO A FRAME FORMAT IT DOES NOT UNDERSTAND.  Zeroing from mc_state[4] is safe
|     for format 0 (8 bytes written) and format 4 (16 written) and for nothing else -- formats 7,
|     9, 10 and 11 write up to 92.  A 68060 generates neither, but the arm CHECKS: if
|     (mc_state[1] >> 12) & 15 is not 0 or 4 it declines and ucp_z_skip_n counts it.  The 68040
|     generates format 7 for access errors, so ucp_z_skip_n > 0 is the EXPECTED reading on the
|     040 bench, not a fault.
|   * IT MUST BE SHOWN TO HAVE WORKED.  ucp_z_n counts the frames zeroed, and the shadow ring is
|     read on the bench to confirm mc_state[4..199] really is all zero in a slot while
|     mc_state[0..3] and the stamp are intact.
|
| WHY THE STAMP IS RE-COMPUTED, AND WHY THAT IS UNAVOIDABLE.  savecontext is WRAPPED, so the
| stock body -- including its stampsum over mc_state[0..199] -- has ALREADY run when this code
| gets control, and the FPU gate can only be read from uc_flags AFTER that (savecontext writes
| uc_flags).  So the zeroing is necessarily on the far side of the stock stamp, which leaves that
| stamp covering the OLD bytes.  Left so, every restore of a zeroed object would fold non-FFFFFFFF
| and be counted a false bad, ucp_s_bad_n would climb, the guest would fail its own checksum on
| every signal and never boot.  So the arm RE-STAMPS: mc_state[200] = ~(XOR of mc_state[0..199]),
| which after zeroing [4..199] is ~(mc_state[0]^[1]^[2]^[3]) -- exactly what stock's stampsum
| would have written over the zeroed field, since ...ATT7-RESULTS... 8.1 established that our XOR
| fold IS stock's fold.  The object is then self-consistent over zeros, the DETECTOR IS KEPT (a
| post-save flip still breaks the fold), and 4.2's "the stamp stock computes already covers zeros"
| holds as a re-stamp rather than as a stock stamp.  This deviation is forced by the FPU gate's
| own requirement and is recorded rather than absorbed.
|
| EVERYTHING ELSE IS ROUND 7, UNCHANGED.  The 4.1 sentinel killer, the stamp-keyed four-slot
| shadow ring (820-byte slots, unchanged geometry), the VOID self-check, the twelve-triple latch
| (whose ucp_b_bits over a zeroed save side reads the mechanism's set bits directly), and the 4.4
| layout row all carry over verbatim -- but note that on this arm the layout row necessarily reads
| mc_state[4..19] = 0, because it runs downstream of the zeroing; that is a confirmation the
| zeroing reached the pre-wall save, not a defect.  See src/ucp_dbg.s's header for the design of
| the parts this file inherits.
|
| EVERYTHING IS HEX.  A ucp_* slot reading ffffffff means NOT APPLICABLE, not zero.
|
| DEVIATIONS FROM 4.2, stated here rather than left to be discovered:
|   1. the re-stamp described above -- forced by the FPU gate, keeps the object bootable and the
|      detector alive.
|   2. ucp_z_fpu_n and ucp_z_on are additions.  4.2 registers ucp_z_n and ucp_z_skip_n; ucp_z_fpu_n
|      makes Rig B's safety inertness a positive count rather than an inference from ucp_z_n = 0,
|      and ucp_z_on is a one-word control that turns the zeroing off while leaving the rest of the
|      unit running -- which is R14's registered control for separating "value-dependent" from
|      "the arm perturbed the timing".
|   3. the round-7 additions this file inherits (the fourth metadata longword ucp_b_s_fold, and
|      ucp_dup_n / ucp_hit_n / ucp_diffev_n) are kept; see src/ucp_dbg.s.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c ucz_dbg.s -o build/ucz_dbg.o
| Wire:     relink-040-f8.sh --ucz (objcopy weaken + the two *_orig aliases).
|           Externals: savecontext_orig, restorecontext_orig, uft_have.
| ============================================================================

	MC_OFF	=	216		| ucp+0xD8 -- mc_state[0], and the fold's base
	MC_STMP	=	1016		| ucp+0x3F8 -- where savecontext stores ~sum
	MC_N	=	201		| longwords the checksum covers (200 + the stamp)
	MS4	=	MC_OFF+16	| ucp+0xE8 -- mc_state[4], where 4.4 starts looking
	MC_ZOFF	=	MC_OFF+16	| ucp+0xE8 -- mc_state[4], where the bzero starts
	MC_ZN	=	196		| mc_state[4..199] -- 784 bytes, the never-written field

	UCP_SLOTS =	4		| ring depth: three levels of nesting
	UCP_DOFF  =	16		| seq, stamp, ucp, fold, then the 804 bytes (unchanged)
	UCP_SLOT  =	820		| 16 + 804.  4 * 820 = 3280 bytes of .data (unchanged)
	UCP_DIFFS =	12		| triples latched in full

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

| ---- ARM II: zero the never-written field, gated, and re-stamp so the object stays consistent.
| This runs BEFORE our fold, so the shadow records the zeroed frame and ucp_s_bad_n stays 0.
	tstl	ucp_z_on
	beqs	Lucz_zdone
	movel	%a2@(0),%d0		| uc_flags
	btst	&3,%d0			| bit 3 set = the part has an FPU
	beqs	Lucz_zfmt		| clear = no FPU -- proceed to the format gate
	addql	&1,ucp_z_fpu_n		| FPU present: decline (the safety gate)
	bras	Lucz_zdone
Lucz_zfmt:
	movel	%a2@(MC_OFF+4),%d0	| mc_state[1] -- the format/vector longword
	moveq	&12,%d1
	lsrl	%d1,%d0
	andil	&15,%d0			| the format nibble
	beqs	Lucz_zgo		| format 0 -- 8 bytes written, safe
	cmpil	&4,%d0
	beqs	Lucz_zgo		| format 4 -- 16 bytes written, safe
	addql	&1,ucp_z_skip_n		| any other format: decline (68040 format 7 lands here)
	bras	Lucz_zdone
Lucz_zgo:
	lea	%a2@(MC_ZOFF),%a0	| mc_state[4]
	moveq	&0,%d0
	movel	&MC_ZN,%d1
Lucz_zbz:
	movel	%d0,%a0@+
	subql	&1,%d1
	bnes	Lucz_zbz
| re-stamp: mc_state[200] = ~(XOR mc_state[0..199]); with [4..199] now zero this is
| ~(mc_state[0] ^ mc_state[1] ^ mc_state[2] ^ mc_state[3]) -- what stock would have stamped.
	movel	%a2@(MC_OFF),%d0
	movel	%a2@(MC_OFF+4),%d1
	eorl	%d1,%d0
	movel	%a2@(MC_OFF+8),%d1
	eorl	%d1,%d0
	movel	%a2@(MC_OFF+12),%d1
	eorl	%d1,%d0
	notl	%d0
	movel	%d0,%a2@(MC_STMP)
	addql	&1,ucp_z_n
Lucz_zdone:

| ---- our own 201-fold, taken over the (now zeroed) frame.  It goes into the shadow so 4.2's
| VOID rule compares against a MEASURED FFFFFFFF.
	lea	%a2@(MC_OFF),%a0
	bsrw	Lucp_fold
	moveq	&-1,%d2
	cmpl	%d1,%d2
	beqs	Lucp_s_fok
	addql	&1,ucp_s_bad_n		| the stamp is wrong AT BIRTH
Lucp_s_fok:

| ---- 4.4's layout row: mc_state[4..19] at the last save BEFORE the first wall fault.  On this
| arm those sixteen read 0, because the zeroing above already ran -- a confirmation, not a defect.
	tstl	ucp_ms_lock
	bnew	Lucp_s_ring
	tstl	uft_have
	beqs	Lucp_s_lay
	movel	&1,ucp_ms_lock		| the census has latched a fault: freeze what we hold
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
	movel	%d1,%a3@(12)		| our save-time fold
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
| restorecontext(ucp) -- prologue hook.  Unchanged from round 7: fold the frame and, on a bad
| fold, pair it with its own earlier self and latch the first twelve differing longwords.  Over a
| zeroed save side, ucp_b_bits reads the mechanism's set bits directly.
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

| ---- the fold that corresponds to the read stock is about to make
	lea	%a2@(MC_OFF),%a0
	bsrw	Lucp_fold
	movel	%d1,%d0			| the entry fold, kept for the latch header
	moveq	&-1,%d2
	cmpl	%d0,%d2
	beqw	Lucp_r_pop		| the object is good: there is nothing to pair
	addql	&1,ucp_bad_n

| ---- the lookup: this object's OWN earlier self, keyed by the stamp it arrived with.  All four
| slots are scanned so an ambiguous key is COUNTED; the newest matching slot wins.
	movel	%a2@(MC_STMP),%d3	| the stamp to find
	subal	%a3,%a3			| no match yet
	moveq	&0,%d4			| best sequence number so far
	moveq	&-1,%d5			| best slot index
	moveq	&0,%d6			| how many slots carry this stamp
	lea	ucpshadow,%a1
	moveq	&0,%d1			| current slot index
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
	movel	%d1,%d5
Lucp_scnx:
	lea	%a1@(UCP_SLOT),%a1
	addql	&1,%d1
	subql	&1,%d2
	bnes	Lucp_scan

	cmpil	&1,%d6
	blss	Lucp_r_look		| nought or one slot matched
	addql	&1,ucp_dup_n		| the stamp is not a unique key on this boot
Lucp_r_look:
	movel	%a3,%d1
	bnew	Lucp_r_hit
	addql	&1,ucp_miss_n		| the ring did not hold this object's earlier self
	braw	Lucp_r_pop
Lucp_r_hit:
	addql	&1,ucp_hit_n

| ---- pass 1: count the differences and their bit union.  It stores nothing, so a VOID event
| cannot consume the one-shot latch that a real difference is owed.
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
	tstl	ucp_stamp
	bnew	Lucp_r_pop		| the full latch is a one-shot; the counters are not

| ---- the latch, once: the header, then the first twelve differences in full
	movel	&0x55434621,ucp_stamp	| "UCF!" -- silence must not look like a null result
	movel	ucp_r_n,ucp_b_seq
	movel	%a2,ucp_b_ucp
	movel	%d0,ucp_b_fold
	movel	%a2@(MC_STMP),ucp_b_stamp
	movel	%d5,ucp_b_slot
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
| Lucp_fold -- %a0 = base.  Returns the XOR fold of MC_N longwords in %d1.
| Clobbers %d1, %d2, %d3, %a0.  m68k EOR is `EOR Dn,<ea>` only, hence the load into %d3.
| ============================================================================
Lucp_fold:
	moveq	&0,%d1
	movel	&MC_N,%d2
Lucp_fl:
	movel	%a0@+,%d3
	eorl	%d3,%d1
	subql	&1,%d2
	bnes	Lucp_fl
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
	.long	UCP_SLOT		| bytes per slot
	.globl	ucp_doff
ucp_doff:
	.long	UCP_DOFF		| where the 804 copied bytes start inside a slot

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
	.long	0			| ... whose 201-fold was not FFFFFFFF on return
	.globl	ucp_ring_i
ucp_ring_i:
	.long	0			| the slot the NEXT save will write

| ---- the restorecontext side ------------------------------------------------------------
	.globl	ucp_r_n
ucp_r_n:
	.long	0			| restorecontext calls
	.globl	ucp_bad_n
ucp_bad_n:
	.long	0			| ... whose 201-fold was not FFFFFFFF at entry
	.globl	ucp_hit_n
ucp_hit_n:
	.long	0			| ... where the stamp found a shadow
	.globl	ucp_miss_n
ucp_miss_n:
	.long	0			| ... where it did not.  >= ucp_bad_n = scope, not a row
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
	.long	0xffffffff		| our entry fold -- the read that said "corrupt"
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
	.long	0xffffffff		| OR of every (save XOR restore) -- the mechanism's bits
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

| ---- 4.4's layout row: mc_state[4..19] at the last save before the first wall fault -------
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

| ---- ARM II: the zeroing gate and its counters -----------------------------------------
	.globl	ucp_z_on
ucp_z_on:
	.long	1			| 0 = zeroing off (R14's control), rest of the unit still runs
	.globl	ucp_z_n
ucp_z_n:
	.long	0			| frames actually zeroed and re-stamped
	.globl	ucp_z_skip_n
ucp_z_skip_n:
	.long	0			| declines on an unhandled frame format (68040 format 7)
	.globl	ucp_z_fpu_n
ucp_z_fpu_n:
	.long	0			| declines because uc_flags bit 3 was set (an FPU part)

| ---- the shadow ring itself.  Deliberately NOT named ucp_* : tools/status-facts.sh groups a
| counter block by that prefix, and 3280 bytes inside the block would break the one-kpeek read.
| Its address and geometry are printed from ucpshadow plus ucp_slots/ucp_slot/ucp_doff.  A slot
| whose first longword (the sequence number) is 0 has NEVER BEEN WRITTEN.
	.globl	ucpshadow
ucpshadow:
	.space	UCP_SLOTS*UCP_SLOT,0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
