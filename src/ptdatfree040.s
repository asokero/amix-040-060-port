| ptdatfree040.s -- ISSUE-40 part 2: retire the ptdat metadata a table page owns,
| the half that actually returns the page (2026-08-02).
| Contract: analyysirepo vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md (ac954b3),
| which answers kernelsupport/ISSUE40-PTDAT-CODEX-QUESTIONS.md P1..P5.
| Part 1 and its measurement: src/legacysdt040.s,
| docs/REALHW-ISSUE40-PART1-260801.md.
|
| WHY THIS EXISTS.  Part 1 restored the legacy-SDT lifetime edge and, on real
| hardware, returned exactly zero pages: 3440 releases, i40_pgfreed_n = 0,
| availrmem -315 with the edge on vs -316 with it off.  hat_sdtfree only credits
| availrmem/availsmem/pages_pp_kernel (0xb66e4) when clearing bits leaves
| p_sdtbits ZERO, and the residual bitmaps said who was holding it:
|
|     0x000e5fff  0x000e017f  0x5fffffff  0x000e0017  0x000e0bff
|
| densely shared allocator pages, up to 22 of 32 units occupied, with the freed
| object punched out of the middle.  The only one-unit customer in this kernel is
| hat_ptalloc's ptdat metadata (hat_sdtalloc(..., 1, ...) @0xb69ae), and our
| hat_ptfree threw away the only pointer to it (pp->p_ptdats) without retiring
| its four list nodes or its 64-byte allocation.  So every table page ever
| allocated left a permanent crumb, and the crumbs are what pin the page.
|
| WHAT.  hat_ptdat_retire(pp): the exact retained inverse of the allocation,
| behind an ownership gate stronger than the one hat_ptfree had.  Returns 0 when
| the metadata is retired and the caller may proceed with the page release, and
| nonzero when nothing was touched.  hat_ptfree (hat040.s) does the page half.
|
| LAYOUT, from the contract's P1 and confirmed against the retained loop at
| 0xb6e18..0xb6e5a in this image:
|
|     ptdat_t, 16 bytes, four of them per 64-byte allocator unit
|       +0   union { struct as *pt_as ; pte_t *pt_addr }
|       +4   ushort pt_secseg          (+6 pt_inuse, +7 pt_keepcnt -- bytes)
|       +8   struct ptdat *pt_prev
|       +12  struct ptdat *pt_next
|
|     page_t
|       +2   p_keepcnt   word    physical page holds
|       +8   p_ptbits    long    1 for a fresh hat_ptalloc table page
|       +32  p_ptdats    long    the record array (union with p_mapping/p_sdtbits)
|
| active_pts and free_pts are CIRCULAR doubly linked SENTINEL records: the head
| is list+12 (pt_next) and the tail is list+8 (pt_prev), both pointing at the
| sentinel itself when empty.  So removal needs no idea which list owns a node:
|
|     REMOVE_PT(node):   node->prev->next = node->next
|                        node->next->prev = node->prev
|
| Record 0 goes on active_pts and records 1..3 on free_pts, so removing all four
| in ascending order is exactly the stock teardown -- and is safer than writing
| separate active/free operations, because it never has to decide which is which.
|
| ⚠ pt_prev IS AT +8, NOT +12.  The comment in hat040.s that said "unlink via
| node->prev@(12)" described the STORE (`prev->pt_next` lands at prev+12), not the
| field.  Getting this backwards would corrupt both lists on the first teardown.
|
| WHY NOT CALL THE RETAINED hat_ptfree (contract P2).  Its body at 0xb6cf4 is not
| a helper: it repeats the physical-page lookup, fragment index, bitmap, hold and
| accounting decisions this wrapper must guard; it keeps old fragment arithmetic
| around them; and when pt_waiting != 0 it wakes the sleepers and then
| DELIBERATELY SKIPS the unlink, the hat_sdtfree, the page release and the
| accounting credit.  Its full-release block is reached only when no waiter
| exists, and entering at 0xb6e18 directly would depend on private register and
| stack state.  It is the byte-level template, not a callee.  The one retained
| callee reused here is hat_sdtfree (local `t` @0xb65ca -> globalized, never
| weakened, exactly as part 1 does for hat_growsdt).
|
| THE OWNERSHIP GATE (contract P3).  The old wrapper cleared pp+32 BEFORE it knew
| whether it owned the page -- it destroyed the only pointer to the records and
| then decided.  The new order proves first and mutates second:
|
|     p_keepcnt == 1            exclusive final HAT hold
|     p_ptbits  == 1            fresh hat_ptalloc page, and a far stronger
|                               discriminator than "aligned managed page", which
|                               accepts any held RAM page
|     p_ptdats  != 0 and 64-byte aligned
|     ptdat[0].pt_keepcnt == 0  no translation still soft-locked
|     all four records have reciprocal prev/next links
|
| Two counts, two meanings, do not confuse them: page_t.p_keepcnt (pp+2, word) is
| physical page holds; ptdat.pt_keepcnt (ptd+7, byte) is soft-locked translations
| in that table.
|
| DELIBERATELY NOT REQUIRED: ptdat[0].pt_inuse == 0 and pt_as != 0.  Whole-AS
| hat_free unlinks every mapped page without maintaining per-table pt_inuse on the
| way to whole-table destruction, so a stale nonzero pt_inuse is LEGAL here; and
| lazily allocated 040 pointer-table pages get the record without ever being
| initialised as a leaf owner.  Rejecting either would fail-closed on the normal
| path and leak everything.
|
| VALIDATE ALL FOUR, THEN MUTATE ALL FOUR.  Two passes on purpose: discovering a
| bad fourth record after three have already been unlinked leaves the lists in a
| state nothing can repair.
|
| FAIL CLOSED (contract P3).  On p_keepcnt == 0, p_keepcnt > 1, bad metadata or
| bad links: no list write, no metadata free, no field clear, no accounting, no
| wake.  Note this CHANGES the old p_keepcnt > 1 behaviour, which decremented and
| returned -- that separated the table page from the HAT's accounting without
| retiring the metadata, and no later generic holder release can know which
| credits and list nodes remain.  A bounded, counted leak keeps one diagnosable
| owner instead of creating an orphan.
|
| WHY THE COUNTER IS HERE AND NOT IN THE i40 BLOCK.  Codex's counter-boundary
| correction, and it corrects us: i40_pgfreed_n/i40_held_n sample availrmem only
| around hat_growsdt inside hat_legacy_sdt_free, which runs at hat_free entry --
| BEFORE the A/B/C walk that calls hat_ptfree.  The credit this unit produces
| happens later, outside that window, so requiring i40_pgfreed_n to rise would be
| requiring the wrong instrument to move.  ptd_pgfreed_n samples availrmem across
| THIS hat_sdtfree(ptd,1) call, which is where the backing page can come back.
|
| COUNTERS (all uncapped; a boot that comes up proves nothing):
|   ptd_magic     0x50544421 "PTD!" -- anchor; if this does not read back, every
|                 other address on the line is stale
|   ptd_calls     hat_ptdat_retire entries (= hat_ptfree calls past its PFN guard)
|   ptd_retired_n metadata units actually retired
|   ptd_pgfreed_n PAGES returned BY THE METADATA RELEASE -- the exact attribution
|                 Codex asked for, and the number that says ISSUE-40 is closed
|   ptd_keep0_n   fail closed: p_keepcnt == 0  (double release / wrong page)
|   ptd_keepn_n   fail closed: p_keepcnt > 1   (another holder; was a silent
|                 decrement before, now counted)
|   ptd_meta_n    fail closed: p_ptbits != 1, null/misaligned p_ptdats, or a
|                 still-locked record
|   ptd_badlink_n fail closed: non-reciprocal list links.  MUST be 0; nonzero
|                 means the layout above is wrong for this image and the two
|                 passes just saved both lists
|
| ptd_on ships 1, so the fix can be A/B'd in ONE boot on hardware (kpoke 0, run
| leaktest 300 1, kpoke 1, run it again) -- the same idiom as i40_on / hat_cm_ram
| / codepub_on.  With ptd_on = 0 this returns "not retired" and hat_ptfree falls
| back to exactly the pre-fix behaviour, INCLUDING the old unconditional
| decrement, so the control arm is the old kernel and not a third thing.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c ptdatfree040.s -o build/ptdatfree040.o
| Requires: --globalize-symbol hat_sdtfree (retained local `t` @0xb65ca).

	.text

| hat_ptdat_retire(pp) -> d0: 0 = retired, caller may release the page
|                             1 = fail closed, caller must not mutate anything
	.globl	hat_ptdat_retire
hat_ptdat_retire:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2-%a4,%sp@-
	addql	&1,ptd_calls
	tstl	ptd_on
	beqw	Lpr_fail		| A/B image: count the call, retire nothing
	moveal	%fp@(8),%a2		| a2 = pp (callee-saved: survives hat_sdtfree)
| ---------------------------------------------------------------- ownership gate
	cmpiw	&1,%a2@(2)		| p_keepcnt EXACTLY one
	beqw	Lpr_keepok
	tstw	%a2@(2)
	bnew	Lpr_keepn
	addql	&1,ptd_keep0_n		| zero hold: double release or wrong page
	braw	Lpr_fail
Lpr_keepn:
	addql	&1,ptd_keepn_n		| another holder: do NOT decrement (P3)
	braw	Lpr_fail
Lpr_keepok:
	cmpil	&1,%a2@(8)		| p_ptbits == 1 -> a fresh hat_ptalloc page
	bnew	Lpr_meta
	movel	%a2@(32),%d0		| p_ptdats
	beqw	Lpr_meta
	movel	%d0,%d1
	andil	&0x3f,%d1		| the allocator unit is 64-byte aligned
	bnew	Lpr_meta
	moveal	%d0,%a3			| a3 = record array base
	clrl	%d1
	moveb	%a3@(7),%d1		| ptdat[0].pt_keepcnt -- soft-locked xlations
	bnew	Lpr_meta		| (pt_inuse@+6 and pt_as@+0 are NOT tested)
| ------------------------------------------------- pass 1: validate all four links
	moveal	%a3,%a4
	moveq	&3,%d2
Lpr_chk:
	moveal	%a4@(8),%a0		| prev
	movel	%a0@(12),%d0		| prev->next
	cmpl	%a4,%d0
	bnew	Lpr_badlink
	moveal	%a4@(12),%a0		| next
	movel	%a0@(8),%d0		| next->prev
	cmpl	%a4,%d0
	bnew	Lpr_badlink
	lea	%a4@(16),%a4
	dbra	%d2,Lpr_chk
| --------------------------------------------------- pass 2: REMOVE_PT all four
| Ascending order = record 0 off active_pts, records 1..3 off free_pts, which is
| byte-for-byte the retained loop at 0xb6e18.  The generic two-store form needs
| no idea which sentinel owns a node.
	moveal	%a3,%a4
	moveq	&3,%d2
Lpr_rm:
	moveal	%a4@(8),%a0		| prev
	moveal	%a4@(12),%a1		| next
	movel	%a1,%a0@(12)		| prev->next = next
	movel	%a0,%a1@(8)		| next->prev = prev
	lea	%a4@(16),%a4
	dbra	%d2,Lpr_rm
| ------------------------------------------------------- free the allocator unit
	clrl	%a2@(8)			| p_ptbits = 0
	movel	availrmem,%d3		| sample: does THIS release return a page?
	pea	1			| n = 1 unit
	movel	%a3,%sp@-		| base
	jsr	hat_sdtfree
	addqw	&8,%sp
	movel	availrmem,%d0
	subl	%d3,%d0			| hat_sdtfree credits at 0xb66e4 only when
	beqw	Lpr_nopage		|   p_sdtbits reached ZERO
	addl	%d0,ptd_pgfreed_n	| ISSUE-40's page, coming back
Lpr_nopage:
	clrl	%a2@(32)		| p_ptdats = NULL.  No ptd field may be read
					|   after hat_sdtfree; pp is a different page
	addql	&1,ptd_retired_n
	clrl	%d0			| 0 = retired, release the page
	braw	Lpr_out
Lpr_badlink:
	addql	&1,ptd_badlink_n	| both lists still intact: nothing mutated yet
	braw	Lpr_fail
Lpr_meta:
	addql	&1,ptd_meta_n
Lpr_fail:
	moveq	&1,%d0			| 1 = fail closed, caller mutates nothing
Lpr_out:
	moveml	%sp@+,%d2-%d3/%a2-%a4
	unlk	%fp
	rts
	nop

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even

	.globl	ptd_magic
ptd_magic:
	.long	0x50544421		| "PTD!"
| ptd_on: 1 = retire the metadata (the shipped default), 0 = hat_ptfree behaves
| exactly as it did before this unit, so the A/B control arm is the old kernel.
	.globl	ptd_on
ptd_on:
	.long	1
	.globl	ptd_calls
ptd_calls:
	.long	0
	.globl	ptd_retired_n
ptd_retired_n:
	.long	0
	.globl	ptd_pgfreed_n
ptd_pgfreed_n:
	.long	0
	.globl	ptd_keep0_n
ptd_keep0_n:
	.long	0
	.globl	ptd_keepn_n
ptd_keepn_n:
	.long	0
	.globl	ptd_meta_n
ptd_meta_n:
	.long	0
	.globl	ptd_badlink_n
ptd_badlink_n:
	.long	0
	.globl	ptd_wake_n
ptd_wake_n:
	.long	0
	.globl	ptd_tblfreed_n
ptd_tblfreed_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
