| ucp_dbg.s -- BLIZZARD F4 round 7: the PAIRED UCONTEXT BRACKET.  Compare a ucontext at
| restorecontext against ITS OWN EARLIER SELF, longword by longword.  (2026-08-25)
|
| Registered in docs/060-F4-M2-ATT7-PREREG-260825.md 4.1-4.4, BEFORE this file existed, and
| that document was committed (e96face) before a line of this one was written.  Read it
| first; this comment does not restate its tables.  Deviations from it are listed at the end
| of this header and in docs/060-F4-M2-ATT7-UCP-260825.md 4.
|
| THE LEAD.  Attempt 6's register file, re-labelled through the one-longword correction
| (...ATT6-RESULTS... 5.2), reads %a4 = 0, %a5 = 800096FB (odd, and in /sbin/init's data
| rather than libc's), %d2 = 80000001 (bit 31 set in a hash index) -- three implausible
| registers at once, while %a6, %a7, %a1, %d3 and %d4 are ordinary user-stack values.  The
| 0x4AFC0000 that made the wall was not written by anybody: it was READ, from user virtual
| address 0, where the stock kernel's own `MOVE.W #$4AFC,($00000000).L` sentinel lives.  So
| there is no writer to catch, and a multi-register corruption points at a path that writes a
| whole register file at once.  In this kernel's signal loop there is exactly one:
| restorecontext, reloading from a ucontext -- the object this campaign has watched fail its
| checksum on every boot.
|
| WHY A SHADOW AND NOT MORE FOLDS.  Round 6's honest caution was that a 0xA000 delta in a
| 201-longword XOR fold is not a 0xA000 delta in one longword: it can be one longword changing
| by A000, or two changing by 8000 and 2000.  Folds cannot be inverted; bytes can be
| subtracted.  A per-longword compare against the SAME OBJECT'S OWN save-time bytes removes
| that ambiguity completely, and nothing else can.
|
| WHY THE PAIRING FIXES TABLE L.  mcs_g_* was the LAST GOOD restorecontext, rewritten every
| call, so on attempt-6 boot 3 the baseline was a different exception from the failure and no
| row could fire even though the precondition was met.  The shadow here is keyed by the STAMP
| OF THE OBJECT BEING RESTORED, so the baseline is that object's own earlier self: no moving
| baseline, no read-time dependence, and no possibility of comparing unlike frames.
|
| WHY A RING OF FOUR, AND HOW IT SAYS SO ITSELF.  mcs_s_n == mcs_r_n exactly on attempt-6
| boot 2 (193,128 each), so saves and restores are 1:1 and a depth of four covers three levels
| of nesting.  ucp_miss_n counts bad restores whose stamp matched no shadow, so the ring's
| adequacy is MEASURED rather than assumed -- a large ucp_miss_n invalidates the depth, not
| the finding.  ucp_dup_n counts the events where more than one slot carried the stamp, which
| is the other half of the same question: a stamp is a 32-bit fold and is not guaranteed
| unique, and an ambiguous key would be a defect of this instrument rather than of the kernel.
|
| THE ARITHMETIC SELF-CHECK THAT MAKES A NULL RESULT MEAN SOMETHING.  If the stamp matches a
| shadow and our restore-fold is not FFFFFFFF while NO longword differs, that is an arithmetic
| contradiction -- the fold is a pure function of the bytes -- and the block is VOID, not
| negative.  ucp_self_void counts it.  To make that exact rather than argued, each shadow also
| carries OUR fold of the object at save time (slot+12), which savecontext's own construction
| requires to be FFFFFFFF; ucp_s_bad_n counts the saves where it was not, i.e. where the stamp
| was wrong AT BIRTH and every restore reading about that object is about a frame that was
| never valid.
|
| 4.1's KILLER, AND IT IS READ BEFORE ANYTHING ELSE.  ucp_sent0 is the longword at LOGICAL
| ADDRESS 0, read once per boot in supervisor state through the kernel's own DTT0 identity
| window (DTT0 = 0x003FC060, src/pstart040.s:326: base 0x00, mask 0x3F -> logical 0-1 GiB,
| E set, S-field 10 = user AND supervisor, CM 11 = cache-inhibited).  It must read 0x4AFC0000.
| IF IT DOES NOT, ...ATT6-RESULTS... 5.4 IS DEAD, the read-through-a-NULL chain collapses, and
| every G row of 4.3 is withdrawn rather than reinterpreted.
|
| REGISTERED HAZARD, and it is the sharpest one in this file: that read is a bare supervisor
| load of address 0.  If DTT0 were not armed at the moment it runs it would be a supervisor
| bus error inside the signal path, i.e. the whole boot.  It is guarded three ways and none of
| them is an assumption: the write that put the sentinel there is stock kernel code that
| already ran (file offset 0x0073CC, verified in three artifacts of this tree); DTT0's premise
| is an attempt-6 SETTLED row on metal; and bench row 2b of the pre-registration reads
| ucp_sent0 on the emulator BEFORE any metal window is spent on this arm.  ucp_on gates it, so
| a control kernel one word apart never issues the load at all.
|
| WHERE IT HOOKS, AND WHY BOTH BUFFERS ARE SAFE TO READ.  Both ucp values are KERNEL
| addresses: setcontext (0x4699e) does `linkw %fp,#-1024` and passes %fp-1024 to savecontext
| and, after a copyin, to restorecontext; sendsig (0x59022) does `linkw %fp,#-1192` and passes
| %fp-1024 to savecontext before copyout'ing it.  NOTHING HERE DEREFERENCES A USER ADDRESS --
| the same standing rule src/ufault_dbg.s was built under, and the reason a probe that faults
| while probing cannot cost the boot.  savecontext is WRAPPED (the stamp does not exist until
| the stock body returns, which is the whole reason the latch is on the far side of the call);
| restorecontext is hooked at its PROLOGUE (the frame to check IS its argument).  savecontext
| has exactly two callers (setcontext+0x3e, sendsig+0x15a); restorecontext has exactly one
| (setcontext+0x9c).
|
| THE LAYOUT ROW (4.4), WHICH MUST FIRE BEFORE G1 IS INTERPRETED.  mc_state begins at ucp+0xD8
| and round 6 decoded mc_state[0..3] as the format-4 exception frame.  WHERE THE REGISTER FILE
| SITS INSIDE mc_state HAS NEVER BEEN MEASURED, so G1 cannot name a register without it.
| ucp_ms4..ucp_ms19 hold mc_state[4..19] from the LAST savecontext BEFORE THE FIRST WALL
| FAULT, and the freeze key is uft_have -- the flag src/ufault_dbg.s sets on the first fatal
| user-fault NOTICE.  The check is made BEFORE the rewrite, so the block holds the last save
| taken while uft_have was still zero; without that, the sendsig the wall itself provokes
| would overwrite the very frame the row is about.
|
| ucp SUPERSEDES mcs RATHER THAN JOINING IT (4.5).  Both units define savecontext and
| restorecontext, so linking both is not merely wasteful -- it is a multiple definition, and
| relink-040-f7.sh refuses an input that already carries mcs_magic.  mcs's counters are kept
| for continuity by name here: ucp_save_n / ucp_r_n / ucp_bad_n / ucp_s_bad_n are mcs_s_n /
| mcs_r_n / mcs_r_bad_n / mcs_s_bad_n under this round's prefix, and mcs's Table L rows are
| retired.
|
| REGISTERED COST, because it is not small.  This unit folds 201 longwords and copies 804
| bytes on every savecontext, and attempt 6 counted ~190,000 savecontext calls per boot, so
| this arm measurably changes signal-path timing.  A BOOT IN WHICH THE UCONTEXT REFUSAL DOES
| NOT OCCUR THEREFORE CANNOT BE READ AS "THE DEFECT WENT AWAY" -- it is one draw from a
| distribution this arm has perturbed.  ucp_on is the .data gate for a one-word control.
|
| EVERYTHING IS HEX.  A ucp_* slot reading ffffffff means NOT APPLICABLE, not zero.  The
| shadow ring's own "never written" marker is a slot sequence number of ZERO, because the
| sequence number is the validity field and it starts at 1.  It is cleared before a fill and
| written after it, so a slot is EMPTY while it is being written rather than advertising its
| predecessor's stamp over half-copied bytes.
|
| DEVIATIONS FROM THE PRE-REGISTRATION, stated here rather than left to be discovered:
|   1. each shadow slot carries a FOURTH metadata longword, our fold of the object at save
|      time.  4.2 lists three (stamp, ucp, sequence number).  Without the fourth, 4.2's own
|      VOID rule rests on an assumed FFFFFFFF instead of a measured one.
|   2. ucp_dup_n, ucp_hit_n and ucp_diffev_n are additions.  4.2 registers ucp_miss_n so the
|      ring depth is measured; these measure the other three things that decide whether a
|      pairing engaged at all, and cost one longword each.
|   3. ucp_slots / ucp_slot / ucp_doff are the ring geometry stamped into .data, so
|      tools/status-facts.sh reads it out of the artifact instead of carrying a copy.
|   4. the twelve-triple latch is a one-shot claimed only by an event that HAS a difference
|      (two passes over the 201 longwords on that one event), so a VOID event cannot consume
|      it.  4.2 does not say which event owns the latch; this is the reading that keeps both
|      the VOID row and the G rows readable on the same boot.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c ucp_dbg.s -o build/ucp_dbg.o
| Wire:     relink-040-f7.sh --ucp (objcopy weaken + the two *_orig aliases).
|           Externals: savecontext_orig, restorecontext_orig, uft_have.
| ============================================================================

	MC_OFF	=	216		| ucp+0xD8 -- mc_state[0], and the fold's base
	MC_STMP	=	1016		| ucp+0x3F8 -- where savecontext stores ~sum
	MC_N	=	201		| longwords the checksum covers (200 + the stamp)
	MS4	=	MC_OFF+16	| ucp+0xE8 -- mc_state[4], where 4.4 starts looking

	UCP_SLOTS =	4		| ring depth: three levels of nesting
	UCP_DOFF  =	16		| seq, stamp, ucp, fold, then the 804 bytes
	UCP_SLOT  =	820		| 16 + 804.  4 * 820 = 3280 bytes of .data
	UCP_DIFFS =	12		| triples latched in full

	ARG	=	36		| savecontext:    after the 32-byte save, the ucp
	RARG	=	52		| restorecontext: after the 48-byte save, the ucp

	.text

| ============================================================================
| savecontext(ucp, link) -- wrapper.  The stamp does not exist until the stock body has run,
| so the latch is on the far side of the call.  Stock returns in BOTH %d0 and %a0.
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
| DTT0's identity window.  Not a user dereference.  See the hazard note in the header.
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

| ---- our own 201-fold, taken in the same breath as the stamp was written.  It goes into the
| shadow so 4.2's VOID rule compares against a MEASURED FFFFFFFF.
	lea	%a2@(MC_OFF),%a0
	bsrw	Lucp_fold		| -> %d1, and %d1 survives to the slot store below
	moveq	&-1,%d2
	cmpl	%d1,%d2
	beqs	Lucp_s_fok
	addql	&1,ucp_s_bad_n		| the stamp is wrong AT BIRTH
Lucp_s_fok:

| ---- 4.4's layout row: mc_state[4..19] at the last save BEFORE the first wall fault.  The
| freeze key is tested BEFORE the rewrite, or the sendsig the wall provokes eats the frame.
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
| The sequence number is written LAST and cleared FIRST, so a slot is EMPTY while it is being
| filled rather than carrying its predecessor's stamp over this one's half-copied bytes.  A
| reader that lands in the window skips the slot and is counted in ucp_miss_n, which is a
| measured miss; the alternative is an unmeasured pairing against a torn frame.
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
| restorecontext(ucp) -- prologue hook.  The frame to check IS the argument, so the latch runs
| first and the stock body then runs unchanged with the stack byte-identical.
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

| ---- the lookup: this object's OWN earlier self, keyed by the stamp it arrived with.  All
| four slots are scanned so that an ambiguous key is COUNTED rather than silently resolved;
| the newest matching slot wins.
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
| Read this FIRST.  A counter block at a stale address does not fail -- it returns a
| plausible number from whatever now lives there.  Every address for this block comes from
| tools/status-facts.sh against the artifact actually booted, at the load base actually
| observed; NEVER from an on-box nlist of /stand/unix, which is a different kernel because
| the one under test is installed into the BOOT SLICE.
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
	.long	0xffffffff		| OR of every (save XOR restore) -- 4.3's last row
| The twelve triples must stay adjacent and in declaration order: Lucp_p2 writes them with a
| post-increment loop, so a reordering edit would still assemble, still link, and quietly
| mislabel every difference on the console.  relink-040-f7.sh asks the LINK, not this file.
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
| post-increment loop.  relink-040-f7.sh asks the LINK.
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

| ---- the shadow ring itself.  Deliberately NOT named ucp_* : tools/status-facts.sh groups a
| counter block by that prefix, and 3280 bytes inside the block would break the one-kpeek
| read.  Its address and geometry are printed from ucpshadow plus ucp_slots/ucp_slot/ucp_doff.
| A slot whose first longword (the sequence number) is 0 has NEVER BEEN WRITTEN.
	.globl	ucpshadow
ucpshadow:
	.space	UCP_SLOTS*UCP_SLOT,0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
