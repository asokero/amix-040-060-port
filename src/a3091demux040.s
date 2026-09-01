| a3091demux040.s -- ISSUE-53: separate the A3091 interrupt SOURCES before the WD's
| status register is read.
|
| THE DEFECT.  a3091intr's whole admission test is two conditions: the unit's device pointer
| must be non-null, and ISTR bit 4 must be set.  If either fails the handler returns; if both
| hold it waits for CIP to clear and then reads the WD's status register SS.  There is no
| third test, and nothing between the ISTR read and the SS read narrows what raised the line.
|
| SDMAC ISTR bit 4 is INT_P, and INT_P is an AGGREGATE: the WD33C93A's own request
| (INTS, bit 6), the SDMAC's end-of-process (E_INT, bit 5), and the FIFO under/over-run
| errors all raise it.  So an interrupt that the SCSI controller never asked for is
| admitted as a controller event and dispatched on `SS` -- a register the data sheet
| defines only for a read that follows an asserted WD interrupt.  atab[IDLE][8] then
| returns DEAD, from which AMIX has no path back, and the machine needs a power cycle.
| Four captures on 2026-08-26, across three kernels, all with head=0 dmaon=0 segstate=0
| on units[6].  See docs/A3091-WEDGE-CAPTURED-260826.md and the audit it cites,
| amix-kernel-analysis/vm-map/A3091-SPURIOUS-COMPLETION-AUDIT.md.
|
| NetBSD's sys/arch/amiga/dev/ahsc.c (ahsc_dmaintr) and Linux's drivers/scsi/a3000.c
| (a3000_intr) both put the boundary this driver is missing between "which source
| interrupted" and "read WD status".  Two independent implementations for the same gate
| array; neither reads the WD unless ISTR.INTS says the WD asked.
|
| WHAT THIS DOES.  One snapshot of ISTR at entry -- before anything else, and the only one
| used for classification -- then:
|
|     INT_P clear ............ count, return exactly as the stock body would
|     error source present ... count, print (rate-limited), delegate.  FAIL-STOP KEPT
|     INTS set ............... delegate; afterwards ack a residual E_INT with CINT
|     E_INT alone ............ CINT, count, return WITHOUT reading SS or touching the DFA
|     INT_P with no source ... count, print, delegate.  FAIL-STOP KEPT
|
| Only the fourth line changes what the machine does, and only for a source that is
| PROVEN not to be the WD.  Everything else reaches the stock body unchanged.  That
| restriction is the whole design: the audit shows why the tempting one-byte alternative
| (atab[IDLE][8] -> no-op) is unsafe, because a target that disconnects leaves its request
| on the unit's comhead while istate returns to IDLE, so a GENUINE 0x16 at IDLE is a
| state/status mismatch worth stopping for, not noise.
|
| THE RACE, AND WHY THE PURE-E_INT ARM RE-READS.  INTS is a level indication of the WD's
| INTRQ pin.  The WD can assert it between our snapshot and the CINT.  NetBSD accepts that
| window and relies on INT_P re-asserting; this re-reads ISTR after the CINT and delegates
| if INTS has appeared, which closes it and counts how often it happened
| (a3w_eint_then_ints).  Cheap, and it removes the one way consuming an E_INT could lose a
| real completion.
|
| HOW IT IS REACHED.  int2_tbl is an array of function pointers in .data; the level-2
| dispatcher (amiga/ml/ttrap.s, p2int) walks it and `jsr`s every entry.  src/patch_a3091_intr.py
| retargets the ONE relocation for the a3091 slot, exactly as patch_a3091_dma.py and
| patch_segdev_ops.py do elsewhere.  a3091intr stays a strong global and stays callable by
| name, so no weakening and no --add-symbol alias are needed for it.
|
| CONTRACT, from p2int.
|   * The dispatcher pushes a fake USP and a pointer to it, so sp@(4) at our entry is a
|     `struct pcb *`.  a3091intr declares no parameters and its disassembly never touches
|     %fp@(8) -- checked over the whole body, 0xd0e0..0xd409 -- so delegating with a plain
|     `jsr` is safe even though it shifts that argument.
|   * The return value is DISCARDED: p2loop does `bra p2loop` and never inspects %d0.  The
|     stock body is C void.  So this returns nothing meaningful either.
|   * %a2 holds the walking table pointer ACROSS the jsr, so it must come back intact.  It
|     is callee-saved anyway; this saves %d2 and %a2 and touches no other non-scratch
|     register.
|
| EXPECTED READING, written before the first run:
|   a3w_calls    -- every level-2 interrupt on the machine, so it is large and it is the
|                   denominator that proves the wrapper is in the table at all
|   a3w_notours  -- almost all of them (keyboard, serial, ethernet)
|   a3w_ints_only + a3w_ints_eint -- ordinary disk traffic; must be nonzero or nothing was
|                   measured
|   a3w_eint_only > 0 -- the mechanism the audit predicts, and the point of the whole unit
|   a3w_other    -- 0.  A nonzero value is a source with no recovery contract yet
|   a3w_nodev    -- 0
|   a3d_n        -- 0.  The wedge is what this is for
|   a3w_allones  -- 0 on a healthy machine.  See ISSUE-58: nonzero means ISTR read back as
|                   all ones, which is a read that did not reach the chip rather than a
|                   source.  Measured 11 in 7990 A3091 interrupts on one Mercury 68060 and
|                   0 in hundreds of thousands on an A3640.  Read a3w_allones_re with it:
|                   a plausible second read says the register was fine and the bus was not.
|
| INVARIANTS (all three must hold exactly; two counters that cannot both be true have
| caught more here than green tests have):
|   a3w_calls     = a3w_nodev + a3w_notours + a3w_own + a3w_allones
|   a3w_own       = a3w_ints_only + a3w_ints_eint + a3w_eint_only + a3w_other
|   a3w_eint_acked = (a3w_eint_only - a3w_eint_deleg) + a3w_resid_eint
|
| a3w_or_istr IS A SOURCE CENSUS AND MUST STAY ONE.  An all-ones read is rejected BEFORE the
| OR, because eleven of them put every bit into it on one machine and made the counter say
| that E_INT had asserted when it never had.  A bit in this counter should mean a source
| raised it, not that a read failed.
|
| a3w_consume IS A LIVE A/B.  1 (the default) consumes a pure E_INT; 0 delegates it and the
| unit becomes pure instrumentation with the stock behaviour intact.  kpoke flips it without
| a reboot, which is how the audit's "classification build" is reached without spending a
| second power cycle on it -- and if the machine wedges anyway, a3w_dead_istr holds the
| ENTRY snapshot of the interrupt that did it, which is precisely the datum four captures
| could not produce.

	.text
	.globl	a3091intr_demux
a3091intr_demux:
	moveml	%d2/%a2,%sp@-		| %a2 = p2int's table cursor.  Both callee-saved.
	addql	&1,a3w_calls
	movel	&0x41335752,a3w_ran	| "A3WR" -- the BODY ran.  a3w_magic is static and
					| says only that the block is where it is said to be.

	movel	a3091_device,%d0
	beqw	Law_nodev		| the stock body's first test, and its first return
	moveal	%d0,%a2

	clrl	%d2
	movew	%a2@(30),%d2		| THE snapshot.  device->istr, one read, before
					| anything else can change what it says
	cmpil	&0x0000ffff,%d2		| ISSUE-58: a read that did not land, not a source.
	beqw	Law_allones		| Tested BEFORE the OR below, so the census stays
					| a census -- see the counter's own comment.
	orl	%d2,a3w_or_istr

	btst	&4,%d2			| INT_P -- the same gate, unchanged
	beqw	Law_notours
	addql	&1,a3w_own
	movel	%d2,a3w_last_istr

	movel	%d2,%d0
	andil	&0x010c,%d0		| INTX(8) | UE_INT(3) | OE_INT(2)
	bnew	Law_other		| an error source: no recovery contract, so fail-stop

	btst	&6,%d2			| INTS -- did the WD actually ask?
	beqw	Law_noints

| --- the WD asked.  Hand it to the stock body, then clean up a DMA event that rode in
|     with it, so the next interrupt is not a pure E_INT we have to reason about. ---
	btst	&5,%d2
	bnes	Law_both
	addql	&1,a3w_ints_only
	bras	Law_wd
Law_both:
	addql	&1,a3w_ints_eint
Law_wd:
	bsr	Law_call
	movew	%a2@(30),%d0		| residual E_INT after the handler ran?
	btst	&5,%d0
	beqw	Law_out
	movew	&1,%a2@(26)		| CINT
	addql	&1,a3w_resid_eint
	addql	&1,a3w_eint_acked
	braw	Law_out

| --- INT_P without INTS.  E_INT alone is the audit's candidate; anything else is a
|     source we cannot name and must not swallow. ---
Law_noints:
	btst	&5,%d2
	beqw	Law_other
	addql	&1,a3w_eint_only
	tstl	a3w_consume
	bnes	Law_consume
	addql	&1,a3w_eint_deleg	| classification mode: stock behaviour, counted only
	bsr	Law_call
	braw	Law_out
Law_consume:
	movew	&1,%a2@(26)		| CINT: the SDMAC's own latched event, acknowledged
	addql	&1,a3w_eint_acked	| without reading SS and without touching the DFA
	movew	%a2@(30),%d0		| did the WD assert while we were doing that?
	btst	&6,%d0
	beqw	Law_out
	addql	&1,a3w_eint_then_ints	| yes -- deliver it rather than wait for the level
	bsr	Law_call
	braw	Law_out

| --- an error or unclassified source.  Loud, and still fail-stop: the stock body decides,
|     exactly as it does today.  The print is capped so a storm cannot bury the console. ---
Law_other:
	addql	&1,a3w_other
	movel	%d2,a3w_other_istr
	movel	a3w_other_pr,%d0
	cmpil	&4,%d0
	bccs	Law_other_go
	addql	&1,a3w_other_pr
	movel	%d2,%sp@-
	pea	La3w_m1
	jsr	printf
	addql	&8,%sp
Law_other_go:
	bsr	Law_call
	braw	Law_out

| --- ISSUE-58: ISTR read back as all ones.  That is not a register value -- a real error
|     sets its own bit, not every bit including 15-9, which float on this hardware -- so it
|     is a read that did not reach the chip.  Counted apart from a3w_other so that a genuine
|     error source is still visible if one ever occurs, and READ AGAIN immediately: if the
|     second read is plausible, the register was fine and the bus read glitched.  The unit
|     already re-reads this register in the Law_wd path, so this is not a new kind of access.
|     Still fail-stop: the stock body decides, exactly as before. ---
Law_allones:
	addql	&1,a3w_allones
	clrl	%d0
	movew	%a2@(30),%d0		| the second read, taken as soon as possible
	movel	%d0,a3w_allones_re	| ... and latched whatever it says
	cmpil	&0x0000ffff,%d0
	bnes	Law_allones_pr
	addql	&1,a3w_allones_reff	| the second read was all ones too
Law_allones_pr:
	movel	a3w_allones_pr,%d1	| its own cap: an all-ones storm must not hide a
	cmpil	&4,%d1			| genuine a3w_other line, nor the reverse
	bccs	Law_allones_go
	addql	&1,a3w_allones_pr
	movel	%d0,%sp@-		| printf(fmt, first, second) -- args right to left
	movel	%d2,%sp@-
	pea	La3w_m2
	jsr	printf
	lea	%sp@(12),%sp		| addq only reaches 8; lea is the idiom for 12
Law_allones_go:
	bsr	Law_call
	braw	Law_out

Law_notours:
	addql	&1,a3w_notours
	bras	Law_out
Law_nodev:
	addql	&1,a3w_nodev		| MUST STAY 0 after autoconfig
Law_out:
	moveml	%sp@+,%d2/%a2
	rts

| --- delegate, and notice if the stock body shut the driver down while we were in it.
|     a3d_n is a3091dbg040.s's DEAD counter; the entry snapshot in %d2 is the one thing
|     that instrument cannot see, because it runs after `SS` has already been read. ---
Law_call:
	movel	a3d_n,%d0
	movel	%d0,%sp@-
	jsr	a3091intr
	movel	%sp@+,%d0
	cmpl	a3d_n,%d0
	beqs	Law_call_ret
	movel	%d2,a3w_dead_istr
	addql	&1,a3w_dead_n
Law_call_ret:
	rts
	.balign	4

	.data
	.even
La3w_m1:
	.asciz	"a3091demux: unclassified istr=%x\n"
	.even
La3w_m2:
	.asciz	"a3091demux: istr all ones, reread=%x\n"
	.even
	.balign	4			| .asciz + .even can leave this 2 mod 4; the counter
					| block below is longwords and every tool that
					| computes offsets into it deserves better than luck
| --- counters, in reading order.  Magic first, as everywhere in this port. ---
	.globl	a3w_magic
a3w_magic:
	.long	0x41335721		| "A3W!" -- STATIC: proves the address
	.globl	a3w_ran
a3w_ran:
	.long	0			| "A3WR" once the body has run
	.globl	a3w_consume
a3w_consume:
	.long	1			| 1 = consume a pure E_INT; 0 = delegate it (A/B)
	.globl	a3w_calls
a3w_calls:
	.long	0			| every level-2 interrupt: the denominator
	.globl	a3w_nodev
a3w_nodev:
	.long	0			| MUST STAY 0: device was NULL
	.globl	a3w_notours
a3w_notours:
	.long	0			| INT_P clear at entry
	.globl	a3w_own
a3w_own:
	.long	0			| INT_P set at entry
	.globl	a3w_ints_only
a3w_ints_only:
	.long	0			| WD asked, no DMA event
	.globl	a3w_ints_eint
a3w_ints_eint:
	.long	0			| WD asked and a DMA event rode in with it
	.globl	a3w_eint_only
a3w_eint_only:
	.long	0			| SDMAC alone -- the audit's candidate mechanism
	.globl	a3w_other
a3w_other:
	.long	0			| MUST STAY 0: error or unnameable source
	.globl	a3w_eint_acked
a3w_eint_acked:
	.long	0			| CINT strobes this wrapper issued
	.globl	a3w_eint_deleg
a3w_eint_deleg:
	.long	0			| pure E_INTs handed to the stock body (consume=0)
	.globl	a3w_resid_eint
a3w_resid_eint:
	.long	0			| E_INT still set after a delegated WD event
	.globl	a3w_eint_then_ints
a3w_eint_then_ints:
	.long	0			| the WD asserted inside the pure-E_INT window
	.globl	a3w_last_istr
a3w_last_istr:
	.long	0			| entry snapshot of the last INT_P interrupt
	.globl	a3w_or_istr
a3w_or_istr:
	.long	0			| OR of every entry snapshot: which bits ever appear
	.globl	a3w_other_istr
a3w_other_istr:
	.long	0			| entry snapshot of the last unclassified one
	.globl	a3w_other_pr
a3w_other_pr:
	.long	0			| console lines spent on the above; capped at 4
	.globl	a3w_dead_n
a3w_dead_n:
	.long	0			| times the stock body reached DEAD under us
	.globl	a3w_dead_istr
a3w_dead_istr:
	.long	0			| and the ENTRY istr of the interrupt that did it
| --- ISSUE-58, appended at the END so no existing offset moves (the a3d block gained its
|     last two counters the same way on 2026-08-27) ---
	.globl	a3w_allones
a3w_allones:
	.long	0			| ISTR read back 0xffff: a read that did not land
	.globl	a3w_allones_re
a3w_allones_re:
	.long	0			| the immediate second read of the last such
	.globl	a3w_allones_reff
a3w_allones_reff:
	.long	0			| ... of which the second read was all ones too
	.globl	a3w_allones_pr
a3w_allones_pr:
	.long	0			| console lines spent on the above; capped at 4
	.balign	4
