| i10rev040.s -- ISSUE-10: uncapped counters for the reverse-map (p_mapping)
| unlink paths, whose give-up-on-exhaustion behaviour has never been a number.
|
| WHAT IS BEING MEASURED, AND WHY IT IS WORTH A COUNTER
|
| Three of this port's HAT routines have to REMOVE one leaf-PTE address from a
| page's p_mapping chain, and all three walk that singly-linked chain with the
| same bounded loop:
|
|     movel &256,%dN        | safety counter
|   Lxx_find:
|     cmpal <cursor>,<pte>  | is this the node?
|     beq   Lxx_unlink
|     subql &1,%dN
|     beq   <give up>       | 256 nodes walked and no match
|     ...follow the link...
|
| The bound exists so a corrupt or circular chain cannot hang the kernel, which
| is right.  What is NOT right is that the give-up is a silent (or near-silent)
| success: the PTE is then removed, or overwritten, WITHOUT its reverse-map node
| being unlinked -- leaving a stale p_mapping entry naming a slot that no longer
| maps that page.  That is precisely the shape ISSUE-10 keeps producing, and the
| three sites differ only in how loudly they say nothing:
|
|   hat_pteload  Lrp_find  (hat040.s, COW/different-pfn replacement)
|                completely SILENT.  Falls through to the status computation and
|                overwrites the leaf with a different pfn, so the OLD page keeps
|                a chain node pointing at a slot that now maps somebody else.
|   hat_unload   Lhl_findmap (hat040.s)   cmn_err, capped at 4 for all uptime.
|   hat_free     Lf_find     (hat040.s)   cmn_err, capped at 4 for all uptime.
|
| A print cap is not a measurement.  It answers "did this ever happen" for the
| first four events of a boot and then goes dark, which is the same failure mode
| kdbg040.s describes for hat_pfnmiss_n: nobody has ever known the real rate.
| These counters are the fix for that, and they are deliberately the same shape
| as hat_pfnmiss_n -- one `addql &1,<long>` at the site, UNCAPPED, counted
| whether or not anything is printing, costing one memory increment.
|
| THE FOURTH SITE IS NOT A FOURTH BOUND.  hat_dup040 was on the list of bounded
| unlink paths to check.  It has no such loop: reading it end to end, both of its
| reverse-map edges only ADD to a chain --
|   private-copy path  newpte.next = newpp->p_mapping; newpp->p_mapping = &newpte
|   share path         newpte.next = oldpte.next;      oldpte.next = &newpte
| -- with no bound of any kind, because there is nothing to search.  So hat_dup
| is not a consumer that can give up; it is the PRODUCER that makes chains long
| in the first place, once per shared or copied page per fork.  Counting its
| registrations therefore measures the pressure on the other three bounds, which
| is the useful thing it can contribute, and i10_dupreg_n is that count.
|
| THE INVARIANT (this is the point of i10_deep_n)
|
| A counter that stays at zero proves less than it looks.  It is consistent with
| "the site never fires" and equally with "the site is unreachable in this
| workload", and those have opposite consequences.  i10_deep_n closes that gap
| from the other side: every one of the three find loops, on the path where it
| DID find its node, checks how much of the 256-node budget the search consumed
| and counts the search if it walked past the halfway mark.  The two readings
| constrain each other:
|
|   i10_deep_n == 0   =>  no chain observed was even half the bound long, so
|                         i10_rpfail_n / i10_hlfail_n / i10_hffail_n CANNOT be
|                         nonzero for want of budget.  Zeroes there are then a
|                         structural fact about chain lengths, not a coincidence
|                         of the workload.
|   i10_deep_n >  0   =>  chains are approaching the bound, and a zero fail
|                         count is a near miss worth watching rather than a
|                         clean bill of health.
|
| Two numbers that cannot both be misread the same way.  Reading either alone is
| how a bounded loop stays invisible for another year.
|
| COST AND SAFETY.  Per event: one `addql` to memory (the fail counters, the
| dup registrations) or one `cmpil` against a register that is already live plus
| a not-taken branch (the deep check, once per successful search -- not once per
| iteration).  Every insertion point was chosen so that no register value and no
| condition code is consumed across it; see the site comments in hat040.s and
| hat_dup040.s, each of which names the instruction that follows and why it does
| not care.  The counters are read with kpeek at the runtime address
| tools/status-facts.sh prints for the `i10` block -- read i10_magic FIRST, and
| believe nothing from this block if it does not come back "I10!".
|
| PART TWO -- i10p_probe: WHAT the page that holds the bad pointer actually IS.
|
| The counters above answered "is a bounded unlink giving up" with a measured no.
| What they cannot say is whose page the corrupt word is sitting in.  The wall
| gives us one thing no previous ISSUE-10 trigger did -- a fault address that is
| a CONSTANT, in the kernel's own VA band -- so the page can be found by looking
| for that constant in the victim's memory, at the moment the victim trips over
| it.  That is what this probe does.
|
| WHERE IT HOOKS, AND WHY THERE.  usrxmemflt (wb040.s) is the user-fault wrapper;
| it calls the stock resolver and keeps the verdict in d4.  A NONZERO verdict is
| exactly the moment the wall becomes real: the kernel could not resolve the
| access, the process is about to be told, and the poisoned word is still sitting
| in its memory untouched.  Hooking the mapping side instead (hat_pteload) would
| only see the corruption if it were already in the frame when the frame was
| mapped -- which is one hypothesis out of several, and the probe must not be
| built so that it can only confirm one of them.  Here it does not matter WHEN
| the word arrived: it is found where it is.
|
| WHAT IT CAPTURES -- once per boot, on the first walk that finds something --
| into the i10p block:  (all of it read back
| with `kpeek <i10p_magic address> 58`, magic first)
|   * the fault address, and the value hunted for (fa & i10p_vmask)
|   * what the KERNEL'S OWN MAP says about that value -- the region-1 pointer
|     descriptor and leaf PTE vatosde/vatopte would reach for it.  A value that
|     looks like a kernel pointer and IS one is a very different finding from a
|     value that merely resembles one, and only the live tree can tell them apart
|   * the victim: curproc, u.u_procp beside it (they must agree, or the u-area
|     window is somebody else's), and the 16 bytes at u+0x1C0
|   * the page: user VA, leaf PTE + its address, pfn, page_t address, the flags/
|     keepcnt word, p_vnode, p_offset, p_hash, p_mapping and what the chain head
|     names, the chain's length, and whether THIS page's own leaf PTE is in it
|   * the frame's first eight longs and the matching long itself, so the content
|     can be read rather than inferred
|   * how many pages were walked, and how many of them contained the value
|
| THE GATE IS THE WHOLE COST.  Every user fault that reaches the unresolved tail
| pays one masked compare against i10p_gmask/i10p_gwant (default: is the fault
| address in the kernel VA band 0x40000000-0x4FFFFFFF).  Ordinary user faults --
| a null dereference, a stack overrun -- fail that compare and pay nothing else.
| The walk itself runs at most i10p_maxtry times and stops for good once it finds
| something, so the MEASURED flood of 8048 identical faults in one wall costs one
| increment each; i10p_busy keeps a fault taken inside a walk from re-entering it.
|
| NOTHING IS HARD-CODED.  The value hunted for is derived from the fault address
| the CPU reported, not from a constant recorded on a previous run, so the probe
| still works if the address moves.  All three masks are .data longs, so a
| different one can be tried with kpoke instead of a rebuild -- and the choice of
| mask turned out to decide what the probe finds, which is why i10p_vmask carries
| the longest comment in the block.
|
| SAFETY.  Every table base and every chain node is bounds-checked before it is
| dereferenced (Lip_okbase: the frame must lie at or above the kernel image and
| below pages_end -- the idiom krnxmemflt040.s already uses for the same reason).
| A failed check abandons that branch of the walk instead of following a garbage
| pointer, because a diagnostic that panics the machine it is diagnosing has
| destroyed the evidence it was added to collect.  The chain walk carries the
| same 256-node bound as the HAT's own walks.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c i10rev040.s -o build/i10rev040.o

	.text
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

| ---------------------------------------------------------------------------
| Lip_okbase -- can the kernel read the longword at %a1 without faulting?
| Returns d0 = 1 (yes) / 0 (no); clobbers d0, d1 and a0.
|
| TWO KINDS OF ADDRESS REACH THIS, and the first version of the probe only knew
| about one of them -- which is why its first run walked nothing at all and could
| only report "found nothing".  MEASURED (i10p_rootraw = 0x4014B000):
|
|   identity-mapped RAM.  Page tables allocated by hat_ptalloc/page_get, and the
|   descriptor values inside them, are PHYSICAL addresses, readable as-is because
|   low RAM is identity-mapped.  The test is krnxmemflt040.s's: the frame must sit
|   at or above the kernel image (_start>>12) and below the end of the page array.
|
|   a region-1 KERNEL VA.  The per-process root040 that p_as@(20) hands back is
|   one of these -- it lives in kernel virtual space, not in the identity window.
|   Rejecting it as "not a plausible RAM address" is what stopped the walk before
|   it began.  Such an address is readable only if the kernel's own tree maps it,
|   so it is validated the way vatosde/vatopte would resolve it (kptr040 pointer
|   descriptor, then the leaf's PDT), never by trying the read and seeing.  A
|   diagnostic that discovers an unmapped address by faulting has destroyed the
|   machine state it was added to collect.
Lip_okbase:
	movel	%a1,%d0
	cmpil	&0x40000000,%d0
	bccw	Lip_ok_r1
	lsrl	&8,%d0
	lsrl	&4,%d0			| d0 = candidate's frame number
	movel	&_start,%d1
	lsrl	&8,%d1
	lsrl	&4,%d1			| d1 = kernel image base frame
	cmpl	%d1,%d0
	bcsw	Lip_okno
	cmpl	pages_end,%d0
	bccw	Lip_okno
	moveq	&1,%d0
	rts
Lip_ok_r1:
	cmpil	&0x80000000,%d0
	bccw	Lip_okno		| above region 1: not a kernel VA at all
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&2,%d0			| va>>18
	subil	&4096,%d0		| vatosde's flat region-1 index
	bmiw	Lip_okno
	cmpil	&4096,%d0
	bccw	Lip_okno
	asll	&2,%d0
	addl	kptr040,%d0
	moveal	%d0,%a0
	movel	%a0@,%d0		| the region-1 pointer descriptor
	moveq	&3,%d1
	andl	%d0,%d1
	cmpil	&2,%d1
	bcsw	Lip_okno		| UDT 0/1: no pointer table for this VA
	andil	&0xffffff00,%d0
	moveal	%d0,%a0			| leaf table base (identity, as above)
	movel	%a1,%d1
	lsrl	&8,%d1
	lsrl	&4,%d1
	andil	&0x3f,%d1
	asll	&2,%d1
	addal	%d1,%a0
	movel	%a0@,%d0		| the leaf PTE
	moveq	&3,%d1
	andl	%d0,%d1
	beqw	Lip_okno		| PDT 00: mapped nowhere, do not touch it
	moveq	&1,%d0
	rts
Lip_okno:
	moveq	&0,%d0
	rts

| ---------------------------------------------------------------------------
| i10p_probe(fa) -- called from usrxmemflt's unresolved-fault tail (wb040.s).
| Frame locals: fp@(-4) leaf PTE / chain-count spill, fp@(-8) pfn,
|               fp@(-12) frame base, fp@(-16) &leaf PTE.
	.globl	i10p_probe
i10p_probe:
	linkw	%fp,&-16
	moveml	%d2-%d7/%a2-%a4,%sp@-
	movel	%fp@(8),%d0		| d0 = the fault address, as the CPU reported it
	movel	%d0,%d1
	andl	i10p_gmask,%d1
	cmpl	i10p_gwant,%d1
	bnew	Lip_out			| not a kernel-VA-band fault: not ours, cost ends here
	addql	&1,i10p_n		| UNCAPPED: band faults seen, captured or not
	movel	%d0,i10p_lastfa		| the most recent one, so "are they all the same
					| address" is a reading and not an assumption
	tstl	i10p_have
	bnew	Lip_out			| already captured: there is nothing left to do
	tstl	i10p_busy
	bnew	Lip_out			| a fault taken INSIDE the walk must not re-enter it
| --- The walk retries until it finds a page, up to i10p_maxtry.  The first
|     version stopped after one attempt, on the assumption that the first band
|     fault of a wall is as good as any other.  It is not: the flood is thousands
|     of faults deep, and if that one attempt is taken in a context whose page
|     tree cannot be walked, a single-shot probe reports "nothing found" and
|     cannot tell that apart from "nothing is there".  i10p_tries and i10p_why
|     are what make those two distinguishable. ---
	movel	i10p_tries,%d1
	cmpl	i10p_maxtry,%d1
	bccw	Lip_out			| budget spent: stop paying for the walk
	addql	&1,%d1
	movel	%d1,i10p_tries
	moveq	&1,%d1
	movel	%d1,i10p_busy
	movel	%d1,i10p_done		| at least one walk has run
	movel	%d0,i10p_fa
	movel	i10p_vmask,%d3		| d3 = value mask, live for the whole scan
	movel	%d0,%d2
	andl	%d3,%d2			| d2 = the value to hunt for
	movel	%d2,i10p_want

| --- the victim, read from its own u-area: this fault is taken in its context.
|     u_procp is latched BESIDE curproc deliberately -- if the two disagree, the
|     u-area window is not this process's and every other u-area reading below is
|     about somebody else. ---
	movel	curproc,%d0
	movel	%d0,i10p_curproc
	movel	u+0x730,%d0
	movel	%d0,i10p_uprocp
	movel	u+0x1c0,%d0
	movel	%d0,i10p_comm0
	movel	u+0x1c4,%d0
	movel	%d0,i10p_comm1
	movel	u+0x1c8,%d0
	movel	%d0,i10p_comm2
	movel	u+0x1cc,%d0
	movel	%d0,i10p_comm3

| --- (1) what does the KERNEL'S OWN map say about that value?  vatosde's flat
|         region-1 addressing: &kptr040[((va>>18) - 4096) * 4], then vatopte's
|         leaf = *desc & 0xFFFFFF00 indexed by (va>>12)&0x3F. ---
	movel	%d2,%d0
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&2,%d0			| d0 = want >> 18
	subil	&4096,%d0
	bmiw	Lip_askan		| below region 1: not a region-1 kernel VA
	cmpil	&4096,%d0
	bccw	Lip_askan		| above region 1
	asll	&2,%d0
	addl	kptr040,%d0
	movel	%d0,i10p_kdesca
	moveal	%d0,%a0
	movel	%a0@,%d0
	movel	%d0,i10p_kdesc
	moveq	&3,%d1
	andl	%d0,%d1
	cmpil	&2,%d1
	bcsw	Lip_askan		| UDT 0/1: no pointer table for that VA at all
	andil	&0xffffff00,%d0
	moveal	%d0,%a1
	bsrw	Lip_okbase
	tstl	%d0
	beqw	Lip_askan
	movel	%d2,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	addal	%d0,%a1
	movel	%a1@,i10p_kpte		| the kernel's own leaf PTE for that VA

| --- (2) walk the victim's page tree and look for the value in its pages.
|         curproc -> p_as@(124) -> root040@(20), then the 040 A/B/C walk
|         uvatosde040.s documents: A = va>>25 & 0x7F, B = va>>18 & 0x7F,
|         C = va>>12 & 0x3F. ---
Lip_askan:
	moveq	&1,%d0
	movel	%d0,i10p_why		| 1 = curproc was NULL
	moveal	curproc,%a0
	movel	%a0,%d0
	beqw	Lip_fin
	moveq	&2,%d0
	movel	%d0,i10p_why		| 2 = curproc->p_as was NULL
	moveal	%a0@(124),%a0		| p_as
	movel	%a0,i10p_as
	movel	%a0,%d0
	beqw	Lip_fin
	moveq	&3,%d0
	movel	%d0,i10p_why		| 3 = p_as->root040 was NULL
	moveal	%a0@(20),%a1		| root040 (per-proc root table, built by hat_alloc)
	movel	%a1,i10p_rootraw
	movel	%a1,%d0
	beqw	Lip_fin
	moveq	&4,%d0
	movel	%d0,i10p_why		| 4 = the root table is not a readable address
	bsrw	Lip_okbase
	tstl	%d0
	beqw	Lip_fin
	moveq	&5,%d0
	movel	%d0,i10p_why		| 5 = walked, and no page of it held the value
	moveal	%a1,%a2			| a2 = root table (Lip_okbase answers in d0 and
					| leaves a1 alone, so a1 is still the base)
	movel	%a2,i10p_root
	clrl	%d4			| A = 0
Lip_a:
	movel	%d4,%d0
	asll	&2,%d0
	movel	%a2@(0,%d0:l),%d0	| Adesc
	moveq	&3,%d1
	andl	%d0,%d1
	cmpil	&2,%d1
	bcsw	Lip_anext		| UDT 0/1: no pointer table under this root slot
	andil	&0xfffffe00,%d0
	moveal	%d0,%a1
	bsrw	Lip_okbase
	tstl	%d0
	beqw	Lip_anext
	moveal	%a1,%a3			| a3 = pointer table (d0 is the verdict, not the base)
	clrl	%d5			| B = 0
Lip_b:
	movel	%d5,%d0
	asll	&2,%d0
	movel	%a3@(0,%d0:l),%d0	| Bdesc
	moveq	&3,%d1
	andl	%d0,%d1
	cmpil	&2,%d1
	bcsw	Lip_bnext
	andil	&0xffffff00,%d0
	moveal	%d0,%a1
	bsrw	Lip_okbase
	tstl	%d0
	beqw	Lip_bnext
	moveal	%a1,%a4			| a4 = leaf table
	clrl	%d6			| C = 0
Lip_c:
	movel	%d6,%d0
	asll	&2,%d0
	movel	%d0,%d1			| d1 = C*4
	movel	%a4@(0,%d0:l),%d0	| the leaf PTE
	movel	%d0,%fp@(-4)
	moveal	%a4,%a0
	addal	%d1,%a0
	movel	%a0,%fp@(-16)		| &leaf PTE -- the reverse map's own currency
	moveq	&3,%d1
	andl	%d0,%d1
	beqw	Lip_cnext		| PDT 00: nothing resident in this slot
	cmpil	&2,%d1
	beqw	Lip_cnext		| indirect descriptor: no direct frame here
	movel	%d0,%d1
	lsrl	&8,%d1
	lsrl	&4,%d1			| d1 = pfn
	cmpl	pages_base,%d1
	bcsw	Lip_cnext		| below the managed page array: not a page_t page
	cmpl	pages_end,%d1
	bccw	Lip_cnext		| above it
	movel	%d1,%fp@(-8)
	lsll	&8,%d1
	lsll	&4,%d1			| d1 = frame base (identity phys)
	movel	%d1,%fp@(-12)
	addql	&1,i10p_pgs		| resident user pages actually scanned
	moveal	%d1,%a0
	addil	&4096,%d1
	moveal	%d1,%a1			| a1 = one past the frame
Lip_scan:
	movel	%a0@+,%d0
	andl	%d3,%d0
	cmpl	%d2,%d0
	beqw	Lip_hit
	cmpal	%a1,%a0
	bcsw	Lip_scan
	braw	Lip_cnext

| --- a page of this process holds the value the fault died on ---
Lip_hit:
	addql	&1,i10p_hits		| how many of its pages do, in total
	tstl	i10p_have
	bnew	Lip_cnext		| already latched: from here on just count
	moveq	&1,%d0
	movel	%d0,i10p_have
	movel	%a0,%d0
	subql	&4,%d0			| a0 has post-incremented past the match
	movel	%d0,%d1
	subl	%fp@(-12),%d1
	movel	%d1,i10p_hoff		| byte offset of the match inside the frame
	moveal	%d0,%a1
	movel	%a1@,i10p_hitv		| the matching long itself, unmasked
| the user VA, rebuilt from the three walk indices
	movel	%d4,%d0
	lsll	&8,%d0
	lsll	&8,%d0
	lsll	&8,%d0
	lsll	&1,%d0			| A << 25
	movel	%d5,%d1
	lsll	&8,%d1
	lsll	&8,%d1
	lsll	&2,%d1			| B << 18
	orl	%d1,%d0
	movel	%d6,%d1
	lsll	&8,%d1
	lsll	&4,%d1			| C << 12
	orl	%d1,%d0
	movel	%d0,i10p_uva
	movel	%fp@(-4),%d0
	movel	%d0,i10p_pte
	movel	%fp@(-16),%d0
	movel	%d0,i10p_ptea
	movel	%fp@(-8),%d0
	movel	%d0,i10p_pfn
| the frame's first eight longs: content read, not inferred
	moveal	%fp@(-12),%a1
	movel	%a1@,i10p_w0
	movel	%a1@(4),i10p_w1
	movel	%a1@(8),i10p_w2
	movel	%a1@(12),i10p_w3
	movel	%a1@(16),i10p_w4
	movel	%a1@(20),i10p_w5
	movel	%a1@(24),i10p_w6
	movel	%a1@(28),i10p_w7
| --- ISSUE-10 census (2026-08-19): does the poisoned frame's UPPER half read as
|     sh's own arena carrying one anomalous word -- a stray store into a page that
|     WAS zero-filled correctly -- or as dense foreign content, the fingerprint of
|     a fill that left the 2 KiB tail uncleaned (H1)?  Every named 2 KiB tail-zero
|     site is already converted to 0x1000, so a clean upper half here says the fill
|     did its job and the bad word arrived by a mis-addressed write (H2).  Counts
|     non-zero longs in each half, tracks the longest run of consecutive zero
|     longs, and copies the 64-byte block that contains the hit.  Runs once, on the
|     latched page, using only d0/d1/d7/a0/a1 -- the scan's live registers (d2/d3
|     value+mask, d4-d6 walk indices, a2-a4 tables) are not touched, so the count
|     of remaining hits below is unaffected.
	clrl	i10p_nzlo
	clrl	i10p_nzhi
	clrl	i10p_zrun
	clrl	%d1			| d1 = current run of consecutive zero longs
	moveal	%fp@(-12),%a0		| a0 = frame base (phys, identity, Lip_okbase-validated)
	movel	%a0,%d7
	addil	&2048,%d7		| d7 = upper-half start (base + 0x800)
	movel	%a0,%d0
	addil	&4096,%d0
	moveal	%d0,%a1			| a1 = one past the frame (base + 0x1000)
Lip_cen:
	movel	%a0@+,%d0		| d0 = the long; a0 advances past it
	bnes	Lip_cen_nz
	addql	&1,%d1			| a zero long: extend the run
	cmpl	i10p_zrun,%d1
	blss	Lip_cen_end		| not longer than the record: leave it
	movel	%d1,i10p_zrun		| a new longest zero run
	bras	Lip_cen_end
Lip_cen_nz:
	clrl	%d1			| a non-zero long: the run ends here
	movel	%a0,%d0
	subql	&4,%d0			| a0 post-incremented; d0 = this long's address
	cmpl	%d7,%d0
	bccs	Lip_cen_hi		| at or above the midpoint: upper half
	addql	&1,i10p_nzlo
	bras	Lip_cen_end
Lip_cen_hi:
	addql	&1,i10p_nzhi
Lip_cen_end:
	cmpal	%a1,%a0
	bcss	Lip_cen
| the 64-byte block that holds the hit: base = frame + (hoff & ~0x3F), 16 longs.
| One of them IS the hit; its neighbours are the reading -- 0x8001xxxx links,
| ASCII and zero say valid arena, anything else says foreign content.
	movel	i10p_hoff,%d0
	andil	&0xffffffc0,%d0		| 64-byte align the hit offset down to a block base
	movel	%fp@(-12),%d1
	addl	%d0,%d1
	moveal	%d1,%a0
	movel	%a0@,i10p_h0
	movel	%a0@(4),i10p_h1
	movel	%a0@(8),i10p_h2
	movel	%a0@(12),i10p_h3
	movel	%a0@(16),i10p_h4
	movel	%a0@(20),i10p_h5
	movel	%a0@(24),i10p_h6
	movel	%a0@(28),i10p_h7
	movel	%a0@(32),i10p_h8
	movel	%a0@(36),i10p_h9
	movel	%a0@(40),i10p_h10
	movel	%a0@(44),i10p_h11
	movel	%a0@(48),i10p_h12
	movel	%a0@(52),i10p_h13
	movel	%a0@(56),i10p_h14
	movel	%a0@(60),i10p_h15
| the page_t: pages + (pfn - pages_base) * 60, the stride hat040.s uses
	movel	%fp@(-8),%d0
	subl	pages_base,%d0
	moveq	&60,%d1
	mulsl	%d1,%d0
	addl	pages,%d0
	movel	%d0,i10p_pp
	moveal	%d0,%a1
	movel	%a1@,i10p_pflags	| flags word @0 + p_keepcnt @2, one long
	movel	%a1@(4),i10p_vnode
	movel	%a1@(8),i10p_off
	movel	%a1@(12),i10p_hash
| the reverse map, walked under the HAT's own 256-node bound
	movel	%a1@(32),%d0		| p_mapping: the chain head (a leaf PTE address)
	movel	%d0,i10p_map
	clrl	%d1			| chain length, valid from here on
	tstl	%d0
	beqw	Lip_chdone		| empty chain: nothing to walk
	movel	%d0,%d7			| d7 = cursor
	moveal	%d0,%a1
	movel	%d1,%fp@(-4)
	bsrw	Lip_okbase
	movel	%fp@(-4),%d1
	tstl	%d0
	beqw	Lip_chbad
	moveal	%d7,%a1
	movel	%a1@,i10p_map0		| the PTE the chain head names, by value
Lip_chn:
	addql	&1,%d1
	cmpl	i10p_ptea,%d7
	bnes	Lip_chnx
	movel	%d1,i10p_min		| position of THIS page's own leaf PTE in the chain
Lip_chnx:
	cmpil	&256,%d1
	bccs	Lip_chdone		| the same bound hat_unload/hat_free/hat_pteload use
	moveal	%d7,%a1
	movel	%a1@(256),%d7		| next = *(node + NPGPT*4), the port's chain link
	beqs	Lip_chdone
	moveal	%d7,%a1
	movel	%d1,%fp@(-4)
	bsrw	Lip_okbase
	movel	%fp@(-4),%d1
	tstl	%d0
	bnes	Lip_chn
Lip_chbad:
	addql	&1,i10p_chbad		| a chain node that is not a plausible RAM address
Lip_chdone:
	movel	%d1,i10p_mapn
	braw	Lip_cnext

Lip_cnext:
	addql	&1,%d6
	cmpil	&64,%d6
	bcsw	Lip_c
Lip_bnext:
	addql	&1,%d5
	cmpil	&128,%d5
	bcsw	Lip_b
Lip_anext:
	addql	&1,%d4
	cmpil	&128,%d4
	bcsw	Lip_a
Lip_fin:
	clrl	i10p_busy		| the walk is over: the next band fault may retry
Lip_out:
	moveml	%fp@(-52),%d2-%d7/%a2-%a4
	unlk	%fp
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| i10_magic: "I10!" -- the anchor that says the address you are reading is this
| block and not whatever moved into it after the last relink.
	.globl	i10_magic
i10_magic:
	.long	0x49313021
| hat_pteload's COW/replacement unlink walked 256 nodes without finding the leaf
| and gave up SILENTLY, then overwrote the leaf with a different pfn.  The old
| page keeps a chain node naming that slot.
	.globl	i10_rpfail_n
i10_rpfail_n:
	.long	0
| hat_unload's unlink gave up (Lhl_findfail).  The cmn_err there stops after 4;
| this does not.
	.globl	i10_hlfail_n
i10_hlfail_n:
	.long	0
| hat_free's unlink gave up (Lf_findfail).  Same: the print stops after 4.  Note
| that hat_free clears the leaf PTE either way, so an exhausted search here
| leaves a chain node naming a slot that is now zero.
	.globl	i10_hffail_n
i10_hffail_n:
	.long	0
| hat_dup040 registered a new PTE into a page's chain -- private-copy path or
| share path.  This is chain GROWTH, the pressure the three bounds above are
| bounded against; hat_dup has no bound of its own because it never searches.
	.globl	i10_dupreg_n
i10_dupreg_n:
	.long	0
| A successful reverse-map search that walked at least 128 of its 256-node
| budget, summed over all three find loops.  Zero here is what makes zero in the
| three fail counters mean something.
	.globl	i10_deep_n
i10_deep_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| ---------------------------------------------------------------------------
| The i10p block -- i10p_probe's one-shot capture.  Read i10p_magic FIRST; a
| stale address does not fail, it lies.
	.globl	i10p_magic
i10p_magic:
	.long	0x49313050		| "I10P"
| --- knobs, so a different band can be tried with kpoke instead of a rebuild ---
| Fire only when (fault address & gmask) == gwant.  Default: the fault address
| lies in the kernel VA band 0x40000000-0x4FFFFFFF, which is what makes this
| fault different from an ordinary user SIGSEGV.
	.globl	i10p_gmask
i10p_gmask:
	.long	0xf0000000
	.globl	i10p_gwant
i10p_gwant:
	.long	0x40000000
| The value hunted for is (fault address & vmask) -- derived from what the CPU
| reported, never from a constant carried over from a previous run.
|
| WHY THIS IS NOT A 64 KiB BAND.  The first version used 0xFFFF0000, on the
| reasoning that the recorded faults vary in their low half (4AFC0003 here,
| 4AFC005F in the older amixadm captures) so the page-aligned base is the stable
| part.  MEASURED, and it is the wrong instrument: the first page that walk found
| was /bin/sh's OWN TEXT at user VA 0x80006000, whose word at frame offset 0x92C
| is 0x4AFC0055 -- and that word is `sh` on disk, byte for byte, because 0x4AFC is
| the 68k ILLEGAL opcode and it occurs inside ordinary instruction streams.  Four
| such words exist in that binary.  A band mask cannot tell them from corruption.
|
| WHY THE LOW TWO BITS COME OFF.  Also measured: 0xFFFFFFFF hunts the fault
| ADDRESS, and finds it -- one word, 0x4AFC0003, on the user stack, which is the
| kernel's own residue rather than the corruption.  The word that matters is the
| free-list LINK the allocator loaded, which is the fault address with the q+3
| busy-bit displacement taken back off: 0x4AFC0000.  That byte string occurs ZERO
| times in the whole 60 KB of /bin/sh, so a match on it has no innocent
| explanation available to it, which is the entire point of the scan.
	.globl	i10p_vmask
i10p_vmask:
	.long	0xfffffffc
| --- what happened ---
	.globl	i10p_n
i10p_n:
	.long	0			| band faults seen, UNCAPPED (latched or not)
	.globl	i10p_done
i10p_done:
	.long	0			| at least one walk has run
	.globl	i10p_have
i10p_have:
	.long	0			| a page was found and the tuple below is filled
	.globl	i10p_fa
i10p_fa:
	.long	0			| the fault address of the FIRST walk attempt
	.globl	i10p_lastfa
i10p_lastfa:
	.long	0			| the most recent band fault, walked or not.  Equal to
					| i10p_fa means the flood is one repeated address
	.globl	i10p_want
i10p_want:
	.long	0			| the value that was hunted for
| The walk retries until it finds something, because one attempt cannot tell
| "no page holds this" from "that one attempt could not be walked".
	.globl	i10p_maxtry
i10p_maxtry:
	.long	8			| how many band faults may pay for a walk
	.globl	i10p_tries
i10p_tries:
	.long	0			| how many did
	.globl	i10p_busy
i10p_busy:
	.long	0			| a walk is in progress: do not re-enter
	.globl	i10p_why
i10p_why:
	.long	0			| where the LAST walk stopped:
					|   1 curproc NULL   2 p_as NULL   3 root NULL
					|   4 root not a readable address
					|   5 walked to the end and no page held the value
	.globl	i10p_as
i10p_as:
	.long	0			| curproc->p_as, as read
	.globl	i10p_rootraw
i10p_rootraw:
	.long	0			| p_as->root040, as read (before validation)
| --- the victim ---
	.globl	i10p_curproc
i10p_curproc:
	.long	0
	.globl	i10p_uprocp
i10p_uprocp:
	.long	0			| u.u_procp -- must equal curproc, or the u-area
					| window is not this process's
	.globl	i10p_comm0
i10p_comm0:
	.long	0			| u_comm, 16 bytes: which command was running
	.globl	i10p_comm1
i10p_comm1:
	.long	0
	.globl	i10p_comm2
i10p_comm2:
	.long	0
	.globl	i10p_comm3
i10p_comm3:
	.long	0
| --- what the KERNEL'S OWN map says about the hunted value ---
	.globl	i10p_kdesca
i10p_kdesca:
	.long	0			| &kptr040[flat] -- the region-1 pointer descriptor
	.globl	i10p_kdesc
i10p_kdesc:
	.long	0			| its value (low 2 bits = UDT; 0/1 = not resident)
	.globl	i10p_kpte
i10p_kpte:
	.long	0			| the kernel's leaf PTE for that VA, if it has one
| --- the walk ---
	.globl	i10p_root
i10p_root:
	.long	0			| the victim's root040 table
	.globl	i10p_pgs
i10p_pgs:
	.long	0			| resident user pages scanned
	.globl	i10p_hits
i10p_hits:
	.long	0			| how many of them contained the value
	.globl	i10p_chbad
i10p_chbad:
	.long	0			| chain nodes that were not plausible RAM addresses
| --- the page ---
	.globl	i10p_uva
i10p_uva:
	.long	0			| the user VA it is mapped at
	.globl	i10p_pte
i10p_pte:
	.long	0			| its leaf PTE
	.globl	i10p_ptea
i10p_ptea:
	.long	0			| the ADDRESS of that PTE -- the reverse map's currency
	.globl	i10p_pfn
i10p_pfn:
	.long	0
	.globl	i10p_pp
i10p_pp:
	.long	0			| its page_t
	.globl	i10p_pflags
i10p_pflags:
	.long	0			| flags word @0 + p_keepcnt @2
	.globl	i10p_vnode
i10p_vnode:
	.long	0			| p_vnode -- nonzero means a FILE page
	.globl	i10p_off
i10p_off:
	.long	0			| p_offset
	.globl	i10p_hash
i10p_hash:
	.long	0			| p_hash
	.globl	i10p_map
i10p_map:
	.long	0			| p_mapping, the reverse-map chain head
	.globl	i10p_map0
i10p_map0:
	.long	0			| the PTE that head names, by value
	.globl	i10p_mapn
i10p_mapn:
	.long	0			| chain length (bounded at 256, like the HAT's walks)
	.globl	i10p_min
i10p_min:
	.long	0			| 1-based position of THIS page's own PTE in the
					| chain; 0 = its live mapping is NOT in the chain,
					| which is the chain-II reading, re-measured here
					| for the page that actually holds the corruption
| --- the content ---
	.globl	i10p_hoff
i10p_hoff:
	.long	0			| byte offset of the match inside the frame
	.globl	i10p_hitv
i10p_hitv:
	.long	0			| the matching long itself
	.globl	i10p_w0
i10p_w0:
	.long	0			| the frame's first eight longs
	.globl	i10p_w1
i10p_w1:
	.long	0
	.globl	i10p_w2
i10p_w2:
	.long	0
	.globl	i10p_w3
i10p_w3:
	.long	0
	.globl	i10p_w4
i10p_w4:
	.long	0
	.globl	i10p_w5
i10p_w5:
	.long	0
	.globl	i10p_w6
i10p_w6:
	.long	0
	.globl	i10p_w7
i10p_w7:
	.long	0
| --- follow-the-pointer handles, in issue39_040.s's idiom.  kvseg, segu, segkmap,
| pages, pages_base and pages_end are COMMON symbols, which the LOADER places in
| .bss -- so they have no address that can be computed from the image, and kpeek
| cannot reach them.  A .data long initialised to the symbol turns each into a
| loader-resolved pointer: read the handle, then read what it points at.  They are
| here because the capture above is a set of raw numbers until something says which
| kernel segment an address belongs to and where the page array starts; without
| them the reading is arithmetic against the nearest named symbol, which is exactly
| the step that produced a "u-area pointer" claim from a number that was merely
| some distance above kvsegu.
	.globl	i10p_p_kvseg
i10p_p_kvseg:
	.long	kvseg			| the struct seg ITSELF (COMMON, 0x20 bytes)
	.globl	i10p_p_segu
i10p_p_segu:
	.long	segu			| a POINTER to a struct seg -- two hops
	.globl	i10p_p_segkmap
i10p_p_segkmap:
	.long	segkmap			| likewise
	.globl	i10p_p_pages
i10p_p_pages:
	.long	pages
	.globl	i10p_p_pgbase
i10p_p_pgbase:
	.long	pages_base
	.globl	i10p_p_pgend
i10p_p_pgend:
	.long	pages_end
| --- the census, filled once by the loop in Lip_hit on the latched hit page.
| Appended after the six handles so every offset above is unchanged; the reader
| grows its kpeek count from 58 to 77 and nothing else moves. ---
	.globl	i10p_nzlo
i10p_nzlo:
	.long	0			| non-zero longs in the frame's LOWER half (0x000..0x7FC)
	.globl	i10p_nzhi
i10p_nzhi:
	.long	0			| non-zero longs in the frame's UPPER half (0x800..0xFFC)
	.globl	i10p_zrun
i10p_zrun:
	.long	0			| longest run of consecutive zero longs anywhere in the frame
| The 64-byte block that contains the hit: base = frame + (i10p_hoff & ~0x3F).
| i10p_h0..h15 are that block, low address first; the hit is one of them.
	.globl	i10p_h0
i10p_h0:
	.long	0
	.globl	i10p_h1
i10p_h1:
	.long	0
	.globl	i10p_h2
i10p_h2:
	.long	0
	.globl	i10p_h3
i10p_h3:
	.long	0
	.globl	i10p_h4
i10p_h4:
	.long	0
	.globl	i10p_h5
i10p_h5:
	.long	0
	.globl	i10p_h6
i10p_h6:
	.long	0
	.globl	i10p_h7
i10p_h7:
	.long	0
	.globl	i10p_h8
i10p_h8:
	.long	0
	.globl	i10p_h9
i10p_h9:
	.long	0
	.globl	i10p_h10
i10p_h10:
	.long	0
	.globl	i10p_h11
i10p_h11:
	.long	0
	.globl	i10p_h12
i10p_h12:
	.long	0
	.globl	i10p_h13
i10p_h13:
	.long	0
	.globl	i10p_h14
i10p_h14:
	.long	0
	.globl	i10p_h15
i10p_h15:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

| ===========================================================================
| PART THREE -- i10w_hook: the WRITE-WATCH that names the store.
|
| i10p_probe (part two) answered "whose page, and is the frame clean" with: a
| healthy, singly-mapped anon heap page of sh's arena, correctly zero-filled,
| holding ONE wrong longword (0x4AFC0000 at user 0x80014AA0).  So the word did
| not arrive by a page-lifetime defect or an uncleaned fill -- it was STORED
| there, at the wrong place or with the wrong value, by a deterministic writer
| (the value and the address are constant across processes and boots).  A store
| of one longword into an otherwise clean, valid page need not pass through
| copyout and cannot be found by scanning frames; it has to be caught AS IT
| LANDS.  This is that catch.
|
| HOW IT CATCHES A STORE WITHOUT SINGLE-STEPPING.  On the 68040 a write to a
| write-protected page raises a format-7 access error whose frame already
| carries everything the question needs -- the faulting PC (frame+66), the SR
| whose S bit says user or kernel (frame+64), the fault address (frame+84), the
| pending write's own address and DATA (WB3A@+88 / WB3D@+92, WB2/WB1 likewise),
| and, ahead of the CPU frame, the 16 user registers k_trap saved (frame+0..+60)
| = the register file of the instruction that is about to store.  wb040.s already
| decodes this frame and completes the write-back; this unit rides that path.
|
| THE MECHANISM.  Once armed (see below) the target page's leaf PTE has its
| write-protect bit (bit 2, the same bit hat_chgprot040 flips) SET, so every
| store into that page faults.  The stock resolver treats it as an ordinary
| protection fault, upgrades the page to writable, and wb040_replay lands the
| store -- all correct, reused, not reimplemented.  i10w_hook then runs at the
| resolved tail of BOTH usrxmemflt (a user store) and krnxmemflt (a KERNEL store
| through the user mapping -- copyout / bcopy / uiomove), reads the target
| longword now that the store has landed, and if it has just become 0x4AFC0000
| latches the whole frame.  Then it RE-PROTECTS the page, so the next store
| faults too, and the watch holds until the poisoning store is seen.  A kernel
| writer is named with its exact PC in one shot, which is the discrimination the
| whole question turns on; a user writer likewise.
|
| WHY THIS AND NOT A TRACE-BIT SINGLE-STEP.  A trace watch never touches the VM,
| but a kernel store during a syscall runs with T cleared, so a trace could only
| point at the syscall boundary, not the store.  The write-protect fires on the
| kernel store itself.  It also cannot perturb a boot: i10w_on ships 0, so the
| whole hook is one `tstl`+`beq` on every fault until it is armed on purpose.
|
| ARMING.  i10w_on is kpoked to 1 immediately before the wall.  The FIRST fault
| that DEMAND-ZEROES the target page (0x80014000) for whichever process is
| growing its arena into it -- the wall's sh, since an already-resident page
| does not fault -- protects that page and records the process, so a stray other
| owner of the same VA cannot be armed on by accident.  i10w_armproc is latched
| for the post-hoc check that it was indeed the wall.
|
| SAFETY.  The hook saves and restores d0-d7/a0-a6 across itself, so neither
| wrapper's live state (d4 = the resolver verdict, d5 = the preserved FSLW) is
| disturbed.  The PTE walk is the same curproc->p_as->root040 A/B/C walk
| i10p_probe documents; a non-resident leaf abandons the operation rather than
| following a garbage pointer.  Re-issuing cpusha bc + pflusha after each PTE
| edit is the same publish-then-flush every PTE writer in hat040.s ends with.

	.text
	.balign 4

| ---------------------------------------------------------------------------
| i10w_leafpte -- %d0 = user VA -> %a0 = address of its leaf PTE, or 0 if the
| VA is not resident in the current process.  Clobbers d0/d1/a0/a1; preserves
| d2 (used for the VA across the walk) by saving it.  Same A/B/C split as
| uvatosde040.s and i10p_probe: A = va>>25 & 0x7F, B = va>>18 & 0x7F,
| C = va>>12 & 0x3F.
i10w_leafpte:
	movel	%d2,%sp@-
	movel	%d0,%d2			| d2 = va, live for the whole walk
	moveal	curproc,%a0
	movel	%a0,%d0
	beqw	Liw_lpno
	moveal	%a0@(124),%a0		| p_as
	movel	%a0,%d0
	beqw	Liw_lpno
	moveal	%a0@(20),%a1		| root040 (per-proc root table)
	movel	%a1,%d0
	beqw	Liw_lpno
	movel	%d2,%d0			| A = (va>>25)&0x7F
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&1,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a1@(0,%d0:l),%d1	| Adesc
	moveq	&3,%d0
	andl	%d1,%d0
	cmpil	&2,%d0
	bcsw	Liw_lpno		| UDT 0/1: no table under this root slot
	andil	&0xfffffe00,%d1
	moveal	%d1,%a1			| A table (the B descriptors)
	movel	%d2,%d0			| B = (va>>18)&0x7F
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&2,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a1@(0,%d0:l),%d1	| Bdesc
	moveq	&3,%d0
	andl	%d1,%d0
	cmpil	&2,%d0
	bcsw	Liw_lpno
	andil	&0xffffff00,%d1
	moveal	%d1,%a1			| B table (the leaf PTEs)
	movel	%d2,%d0			| C = (va>>12)&0x3F
	lsrl	&8,%d0
	lsrl	&4,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	moveal	%a1,%a0
	addal	%d0,%a0			| a0 = &leafPTE
	movel	%a0@,%d1
	andil	&3,%d1
	beqw	Liw_lpno		| PDT 00: not resident, do not touch it
	movel	%sp@+,%d2
	rts
Liw_lpno:
	suba	%a0,%a0			| a0 = 0
	movel	%sp@+,%d2
	rts

| ---------------------------------------------------------------------------
| i10w_latch -- copy the format-7 frame in %a2 into the i10w capture block.
| Uses i10w_ptea (already set by the caller) to reach the frame's physical
| base for the content read.  Clobbers d0/d1/a0/a1.
i10w_latch:
	addql	&1,i10w_latch_n
	moveq	&0,%d0
	movew	%a2@(64),%d0		| SR (word) -- S bit = user vs kernel
	movel	%d0,i10w_sr
	movel	%a2@(66),i10w_pc	| the faulting instruction's PC
	movel	%a2@(84),i10w_fa	| the fault address
	moveq	&0,%d0
	movew	%a2@(76),%d0		| SSW
	movel	%d0,i10w_ssw
	moveq	&0,%d0			| WB3: status / address / data
	moveb	%a2@(78),%d0
	movel	%d0,i10w_w3s
	movel	%a2@(88),i10w_w3a
	movel	%a2@(92),i10w_w3d
	moveq	&0,%d0			| WB2
	moveb	%a2@(80),%d0
	movel	%d0,i10w_w2s
	movel	%a2@(96),i10w_w2a
	movel	%a2@(100),i10w_w2d
	moveq	&0,%d0			| WB1
	moveb	%a2@(82),%d0
	movel	%d0,i10w_w1s
	movel	%a2@(104),i10w_w1a
	movel	%a2@(108),i10w_w1d
	moveal	%a2,%a0			| the 16 saved registers, frame+0..+60
	lea	i10w_r0,%a1		| d0-d7 then a0-a6 then supervisor a7
	moveq	&15,%d1
Liw_lr:
	movel	%a0@+,%a1@+
	dbra	%d1,Liw_lr
	moveal	i10w_ptea,%a0		| frame physical base = *ptea & 0xFFFFF000
	movel	%a0@,%d0
	andil	&0xfffff000,%d0
	movel	i10w_target,%d1		| the target longword itself
	andil	&0xfff,%d1
	orl	%d0,%d1
	moveal	%d1,%a0
	movel	%a0@,i10w_hitval
	movel	i10w_target,%d1		| the 64-byte block that contains it
	andil	&0xfc0,%d1
	orl	%d0,%d1
	moveal	%d1,%a0
	lea	i10w_c0,%a1
	moveq	&15,%d1
Liw_lc:
	movel	%a0@+,%a1@+
	dbra	%d1,Liw_lc
	rts

| ---------------------------------------------------------------------------
| i10w_hook(frame, ctx) -- called from usrxmemflt (ctx=1) and krnxmemflt
| (ctx=2), at the resolved tail, AFTER wb040_replay has landed the faulting
| store.  Dormant until i10w_on; then it arms the target page on its first
| demand-zero fault and, once armed, latches the store that leaves the target
| longword holding i10w_wantval and re-protects for the next one.
	.globl	i10w_hook
i10w_hook:
	tstl	i10w_on
	beqw	Liw_h_ret		| dormant: one memory test, nothing saved
	linkw	%fp,&0
	moveml	%d0-%d7/%a0-%a6,%sp@-	| preserve the caller's d4 (verdict) and d5 (FSLW)
	moveal	%fp@(8),%a2		| a2 = frame
	movel	%a2@(84),%d0		| FA
	andil	&0xfffff000,%d0
	cmpl	i10w_armva,%d0
	bnew	Liw_h_out		| this fault is not on the watched page
	tstl	i10w_armed
	bnew	Liw_h_armed
| --- ARM: the first fault that maps the target page.  Record the process, set
|     the write-protect bit, seed prevtval with the value the page starts at. ---
	movel	i10w_armva,%d0
	bsrw	i10w_leafpte
	movel	%a0,%d0
	beqw	Liw_h_out		| not resident yet (should not happen post-resolve)
	movel	%a0,i10w_ptea
	movel	curproc,i10w_armproc
	moveal	%a0,%a1			| seed prevtval from the target longword
	movel	%a1@,%d0
	andil	&0xfffff000,%d0
	movel	i10w_target,%d1
	andil	&0xfff,%d1
	orl	%d0,%d1
	moveal	%d1,%a1
	movel	%a1@,i10w_prevtval
	moveal	i10w_ptea,%a0		| set bit 2 = write-protect, then publish + flush
	orl	&4,%a0@
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
	movel	&1,i10w_armed
	addql	&1,i10w_arm_n
	braw	Liw_h_out
| --- ARMED: a store into the protected page just landed.  Did it leave the
|     target longword == wantval, having not been wantval before?  If so, THIS
|     frame is the writer.  Then re-protect for the next store. ---
Liw_h_armed:
	addql	&1,i10w_fault_n
	movel	i10w_armva,%d0
	bsrw	i10w_leafpte		| re-find the leaf (the resolver may have reloaded it)
	movel	%a0,%d0
	beqw	Liw_h_out		| the page is gone: stop
	movel	%a0,i10w_ptea
	movel	%a0@,%d0		| framebase = *leaf & 0xFFFFF000
	andil	&0xfffff000,%d0
	movel	i10w_target,%d1
	andil	&0xfff,%d1
	orl	%d0,%d1
	moveal	%d1,%a1
	movel	%a1@,%d7		| d7 = current target longword
	cmpl	i10w_wantval,%d7
	bnes	Liw_h_reprot		| not the poison value
	cmpl	i10w_prevtval,%d7
	beqs	Liw_h_reprot		| already was the poison: not a fresh transition
	bsrw	i10w_latch		| a fresh transition INTO the poison: this is the writer
Liw_h_reprot:
	movel	%d7,i10w_prevtval
	moveal	i10w_ptea,%a0		| re-set the write-protect bit + publish + flush
	orl	&4,%a0@
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
Liw_h_out:
	moveml	%sp@+,%d0-%d7/%a0-%a6
	unlk	%fp
Liw_h_ret:
	rts

	.balign 4

	.data
	.even
| ---------------------------------------------------------------------------
| The i10w block -- read i10w_magic FIRST (a stale address does not fail, it
| lies), then 58 longs after it.  Knobs are kpoke-able so the watched VA and
| value can move without a rebuild, the i10p_vmask lesson.
	.globl	i10w_magic
i10w_magic:
	.long	0x49315721		| "I1W!"
| --- knobs ---
	.globl	i10w_on
i10w_on:
	.long	0			| 0 = dormant (ships this way).  kpoke 1 to arm.
	.globl	i10w_armva
i10w_armva:
	.long	0x80014000		| the page whose first demand-zero fault arms the watch
	.globl	i10w_target
i10w_target:
	.long	0x80014aa0		| the longword watched for the poison transition
	.globl	i10w_wantval
i10w_wantval:
	.long	0x4afc0000		| the poison value
| --- state ---
	.globl	i10w_armed
i10w_armed:
	.long	0
	.globl	i10w_ptea
i10w_ptea:
	.long	0			| address of the target page's leaf PTE
	.globl	i10w_prevtval
i10w_prevtval:
	.long	0			| the target longword before the current store
	.globl	i10w_arm_n
i10w_arm_n:
	.long	0
	.globl	i10w_fault_n
i10w_fault_n:
	.long	0			| write faults handled on the armed page
	.globl	i10w_latch_n
i10w_latch_n:
	.long	0			| transitions INTO the poison value (1 = unambiguous)
	.globl	i10w_armproc
i10w_armproc:
	.long	0			| curproc at arm -- must be the wall's process
| --- the capture: the frame of the store that poisoned the longword ---
	.globl	i10w_ctx
i10w_ctx:
	.long	0			| 1 = caught in usrxmemflt (user), 2 = krnxmemflt (kernel)
	.globl	i10w_pc
i10w_pc:
	.long	0			| the faulting instruction's PC -- THE STORE
	.globl	i10w_sr
i10w_sr:
	.long	0			| SR; bit 13 (0x2000) = S: set => kernel store
	.globl	i10w_fa
i10w_fa:
	.long	0			| fault address -- the effective address of the store
	.globl	i10w_ssw
i10w_ssw:
	.long	0			| special status word
	.globl	i10w_w3s
i10w_w3s:
	.long	0			| WB3 status (bit7 valid, bits6-5 size, bits2-0 FC)
	.globl	i10w_w3a
i10w_w3a:
	.long	0			| WB3 address = the store's effective address
	.globl	i10w_w3d
i10w_w3d:
	.long	0			| WB3 data = the value being stored
	.globl	i10w_w2s
i10w_w2s:
	.long	0
	.globl	i10w_w2a
i10w_w2a:
	.long	0
	.globl	i10w_w2d
i10w_w2d:
	.long	0
	.globl	i10w_w1s
i10w_w1s:
	.long	0
	.globl	i10w_w1a
i10w_w1a:
	.long	0
	.globl	i10w_w1d
i10w_w1d:
	.long	0
	.globl	i10w_hitval
i10w_hitval:
	.long	0			| the target longword as latched (must read the poison)
| the 16 saved user registers of the faulting instruction, frame+0..+60:
| d0-d7 (r0..r7), a0-a6 (r8..r14), supervisor a7 (r15).  The address register
| holding the effective address exposes the base/index the store computed.
	.globl	i10w_r0
i10w_r0:
	.long	0
	.globl	i10w_r1
i10w_r1:
	.long	0
	.globl	i10w_r2
i10w_r2:
	.long	0
	.globl	i10w_r3
i10w_r3:
	.long	0
	.globl	i10w_r4
i10w_r4:
	.long	0
	.globl	i10w_r5
i10w_r5:
	.long	0
	.globl	i10w_r6
i10w_r6:
	.long	0
	.globl	i10w_r7
i10w_r7:
	.long	0
	.globl	i10w_r8
i10w_r8:
	.long	0
	.globl	i10w_r9
i10w_r9:
	.long	0
	.globl	i10w_r10
i10w_r10:
	.long	0
	.globl	i10w_r11
i10w_r11:
	.long	0
	.globl	i10w_r12
i10w_r12:
	.long	0
	.globl	i10w_r13
i10w_r13:
	.long	0
	.globl	i10w_r14
i10w_r14:
	.long	0
	.globl	i10w_r15
i10w_r15:
	.long	0
| the 64-byte block that contains the target longword, low address first:
	.globl	i10w_c0
i10w_c0:
	.long	0
	.globl	i10w_c1
i10w_c1:
	.long	0
	.globl	i10w_c2
i10w_c2:
	.long	0
	.globl	i10w_c3
i10w_c3:
	.long	0
	.globl	i10w_c4
i10w_c4:
	.long	0
	.globl	i10w_c5
i10w_c5:
	.long	0
	.globl	i10w_c6
i10w_c6:
	.long	0
	.globl	i10w_c7
i10w_c7:
	.long	0
	.globl	i10w_c8
i10w_c8:
	.long	0
	.globl	i10w_c9
i10w_c9:
	.long	0
	.globl	i10w_c10
i10w_c10:
	.long	0
	.globl	i10w_c11
i10w_c11:
	.long	0
	.globl	i10w_c12
i10w_c12:
	.long	0
	.globl	i10w_c13
i10w_c13:
	.long	0
	.globl	i10w_c14
i10w_c14:
	.long	0
	.globl	i10w_c15
i10w_c15:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

| ===========================================================================
| PART FOUR -- i10g_hook: the GENESIS watch, value-triggered.
|
| i10w_hook (part three) named the store at user 0x80014AA0 that walls: sh's own
| free-block coalescing `move.l (a1),(a0)`, a USER store, correctly addressed --
| a memory-to-memory COPY whose value 0x4AFC0000 was read from another arena slot
| that ALREADY held it (the byte string 4AFC0000 occurs zero times in /bin/sh, so
| it is neither an immediate nor a register value; it was copied).  That store
| PROPAGATES the corrupt free-list link; it does not originate it.  The genesis --
| what FIRST put 0x4AFC0000 into a free-list link -- is one hop upstream, on a
| DIFFERENT page (the source *(a1), which the 0x80013xxx cursors in the capture
| place on page 0x80013000), and the "kernel or user" question is still open there.
|
| This unit answers it, in ONE boot, two independent ways:
|
|   PART W (WRITTEN).  On EVERY resolved fault, the 68040 format-7 frame carries
|   the deferred write-back's own address and DATA (WB3A/WB3D, and WB2/WB1).  When
|   a store faults -- which the FIRST store into a fresh demand-zero arena page
|   always does, and which a copy-on-write break does -- WBnD is the value being
|   stored.  So if any WBnD == 0x4AFC0000, a store of the poison just landed, and
|   the frame names its PC and privilege.  A stale WBnD (a non-store fault leaves
|   the field holding a previous instruction's data) is rejected by CONFIRMING the
|   poison actually landed: the target longword is re-read through its own frame
|   and must equal the poison.  This catches a genesis STORE red-handed -- and its
|   SR bit settles kernel-vs-user for the genesis, which the propagation capture
|   could only settle for the propagation.
|
|   PART I (INHERITED).  If the value is not written but was already in a frame the
|   kernel handed sh -- leftover content of a physical frame whose demand-zero fill
|   skipped it, an ILLEGAL-opcode word being exactly what a prior code page leaves
|   behind -- then NO store of it ever lands and PART W stays silent.  So on every
|   resolved fault in sh's arena band, the just-resolved frame is scanned for the
|   poison; the FIRST frame that holds it is latched with its full identity, its
|   fill census (non-zero longs per half, longest zero run) and the block around
|   the word.  On a demand-zero page-in fault this is the frame AS HANDED OUT.  A
|   frame carrying the poison in a run of dense foreign content is an inherited
|   prior owner's page (a fill gap); the poison isolated in clean zero-fill is a
|   store PART W will have caught.  i10g_iself records whether THIS fault's own
|   store wrote that offset, to tell a self-write from pre-existing content.
|
| WHY NO WRITE-PROTECTION.  Unlike i10w_hook, which pinned one page and forced a
| fault on every store into it, this rides the faults the wall already generates:
| the arena grows by demand-zero page-ins (each first store faults -> PART W sees
| it) and each new frame is scanned once (PART I).  It never protects a page, so it
| perturbs nothing, and it is globally armed rather than pinned to a VA guessed in
| advance -- the poison VALUE, constant across processes and boots, is the anchor.
| It ships dormant (i10g_on = 0, one tstl per resolved fault) and is armed with a
| kpoke immediately before the wall, exactly as i10w_hook is.
|
| SAFETY.  Saves and restores d0-d7/a0-a6, so neither wrapper's live d4/d5 is
| disturbed.  Every frame base comes from i10w_leafpte (the resident-or-nothing
| A/B/C walk part three documents); a non-resident target abandons the operation
| rather than dereferencing a guess.  Both latches are one-shot.

	.text
	.balign 4

| ---------------------------------------------------------------------------
| i10g_ckframe -- %d0 = a user VA -> %a1 = the physical base of its 4 KiB frame,
| or %a1 = 0 if the VA is not resident in the current process.  Clobbers d0/d1/a0
| (via i10w_leafpte, which preserves d2 and touches no other a-register), so a2
| (the trap frame) and d3-d7 survive across it.
i10g_ckframe:
	bsrw	i10w_leafpte		| d0 = VA -> a0 = &leafPTE, or a0 = 0
	movel	%a0,%d0
	beqs	Lig_cf0
	movel	%a0@,%d0		| the leaf PTE
	andil	&0xfffff000,%d0		| frame physical base (identity-mapped low RAM)
	moveal	%d0,%a1
	rts
Lig_cf0:
	suba	%a1,%a1
	rts

| ---------------------------------------------------------------------------
| i10g_wlatch -- PART W capture.  a2 = frame, d3 = which write-back matched
| (1/2/3), d4 = its target address.  i10g_wmem is already set by the caller (the
| confirmed longword at the target).  Clobbers d0/d1/a0/a1.
i10g_wlatch:
	movel	i10g_seq,i10g_wseq
	movel	%fp@(12),i10g_wctx	| the hook's ctx arg: 1 = user wrapper, 2 = kernel
	moveq	&0,%d0
	movew	%a2@(64),%d0		| SR -- bit 13 (0x2000) = S: set => a KERNEL store
	movel	%d0,i10g_wsr
	movel	%a2@(66),i10g_wpc	| the faulting instruction's PC
	movel	%a2@(84),i10g_wfa	| the fault address
	moveq	&0,%d0
	movew	%a2@(76),%d0		| SSW
	movel	%d0,i10g_wssw
	movel	%d3,i10g_wslot
	movel	%a2@(88),i10g_wb3a
	movel	%a2@(92),i10g_wb3d
	movel	%a2@(96),i10g_wb2a
	movel	%a2@(100),i10g_wb2d
	movel	%a2@(104),i10g_wb1a
	movel	%a2@(108),i10g_wb1d
	movel	%d4,i10g_wtgt		| the matched store's effective address
	movel	%d4,%d0
	andil	&0xfff,%d0
	movel	%d0,i10g_wtoff		| its offset inside the frame
	moveal	%a2,%a0			| the 16 saved registers, frame+0..+60
	lea	i10g_wr0,%a1		| d0-d7, a0-a6, supervisor a7
	moveq	&15,%d1
Lig_wlr:
	movel	%a0@+,%a1@+
	dbra	%d1,Lig_wlr
	movel	%d4,%d0			| the 64-byte block around the store target:
	bsrw	i10g_ckframe		| framebase + (tgt & 0xFC0), 16 longs
	movel	%a1,%d0
	beqs	Lig_wl_nb		| target frame not resident: leave the block zero
	movel	%d4,%d0
	andil	&0xfc0,%d0
	movel	%a1,%d1
	addl	%d0,%d1
	moveal	%d1,%a0
	lea	i10g_wc0,%a1
	moveq	&15,%d1
Lig_wlc:
	movel	%a0@+,%a1@+
	dbra	%d1,Lig_wlc
Lig_wl_nb:
| --- identify the COPY SOURCE: for a move.l (aSrc),(aDst) the CPU frame records only
|     the DEST (WB3A); the source is a register.  Scan a0-a6 (wr8..wr14) for one whose
|     target longword == the poison, and dump the 32-byte block around it.  That names
|     the frame the poison was copied FROM -- one hop toward the true genesis, and
|     enough to tell an arena page from a text/data/library page. ---
	movel	&-1,i10g_wsrcr		| -1 = no source register (other than the dest) found
	clrl	i10g_wsrc
	clrl	i10g_wsrcv
	moveq	&8,%d6			| d6 = wr index: 8 = a0 .. 14 = a6
Lig_wsrc:
	movel	%d6,%d0
	asll	&2,%d0
	lea	i10g_wr0,%a0
	movel	%a0@(0,%d0:l),%d7	| d7 = the address register value (survives ckframe)
| record *(aN) for every address register, so intended-source-value can be compared
| to WB3D host-side: for a faithful move.l (aSrc),(aDst) the write-back data MUST equal
| *(aSrc).  If no register except the dest points at the poison, the poison is not a
| copy of any source -- the write-back value itself is fabricated (a 68040 WB defect).
	movel	%d6,%d0
	subql	&8,%d0
	asll	&2,%d0
	lea	i10g_wpv0,%a0
	addal	%d0,%a0			| a0 = &i10g_wpv<N>
	clrl	%a0@			| default: not a readable user pointer
	cmpil	&0x80000000,%d7
	bcss	Lig_wsrc_n		| not a user address
	movel	%d7,%d0
	bsrw	i10g_ckframe		| -> a1 = frame base or 0 (d6/d7 survive)
	movel	%a1,%d0
	beqs	Lig_wsrc_n		| source frame not resident
	movel	%d7,%d0
	andil	&0xfff,%d0
	addl	%d0,%a1			| a1 = physical address of *(aN)
	movel	%a1@,%d5		| d5 = *(aN)
	movel	%d6,%d0
	subql	&8,%d0
	asll	&2,%d0
	lea	i10g_wpv0,%a0
	movel	%d5,%a0@(0,%d0:l)	| i10g_wpv<N> = *(aN)
	cmpl	i10g_wantval,%d5
	bnes	Lig_wsrc_n		| this register does not point at the poison
	cmpl	i10g_wb3a,%d7
	beqs	Lig_wsrc_n		| it IS the destination the store just wrote -- not a source
	movel	%d7,i10g_wsrc		| a genuine SOURCE that already held the poison
	movel	%d6,%d0
	subql	&8,%d0
	movel	%d0,i10g_wsrcr		| 0..6 = a0..a6
	movel	%d5,i10g_wsrcv
	movel	%a1,%d0			| dump the 32-byte block around the source
	andil	&0xffffffe0,%d0
	moveal	%d0,%a0
	lea	i10g_ws0,%a1
	moveq	&7,%d1
Lig_wsb:
	movel	%a0@+,%a1@+
	dbra	%d1,Lig_wsb
	bras	Lig_wsdone
Lig_wsrc_n:
	addql	&1,%d6
	cmpil	&15,%d6
	bcsw	Lig_wsrc
Lig_wsdone:
	movel	&1,i10g_wlatched
	rts

| ---------------------------------------------------------------------------
| i10g_ilatch -- PART I capture.  a1 = frame physical base, i10g_ioff already set
| to the poison's byte offset in the frame, a2 = frame.  Clobbers d0-d7/a0-a4.
i10g_ilatch:
	movel	i10g_seq,i10g_iseq
| the STORING instruction that made the poison appear in this frame -- with the band
| write-protected, a store into it faults, so the frame PC (one past the store, WB
| deferred) and the SR privilege name the genesis instruction; WB3A/WB3D are its target
| and data.  This is what turns PART I from "which frame" into "which store".
	moveq	&0,%d0
	movew	%a2@(64),%d0		| SR: bit 13 (0x2000) = S -> kernel vs user store
	movel	%d0,i10g_isr
	movel	%a2@(66),i10g_ipc	| the storing instruction's PC
	movel	%a2@(88),i10g_iwb3a	| WB3 address
	movel	%a2@(92),i10g_iwb3d	| WB3 data
	movel	%a2@(84),i10g_ifa	| the fault address that brought this frame in
	movel	%a2@(84),%d0
	andil	&0xfffff000,%d0
	movel	%d0,i10g_iuva		| the poison page's user VA base
	movel	%a1,i10g_iframe		| the frame physical base
	movel	%a1,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0
	movel	%d0,i10g_ipfn
	movel	curproc,i10g_iproc	| which process (its u_comm below must read "sh")
	movel	u+0x1c0,i10g_icomm0
	movel	u+0x1c4,i10g_icomm1
	movel	u+0x1c8,i10g_icomm2
	movel	u+0x1cc,i10g_icomm3
	moveal	%a1,%a0			| the frame's first eight longs
	movel	%a0@,i10g_iw0
	movel	%a0@(4),i10g_iw1
	movel	%a0@(8),i10g_iw2
	movel	%a0@(12),i10g_iw3
	movel	%a0@(16),i10g_iw4
	movel	%a0@(20),i10g_iw5
	movel	%a0@(24),i10g_iw6
	movel	%a0@(28),i10g_iw7
| the fill census: non-zero longs in each half, longest run of consecutive zeros.
| A frame the demand-zero fill cleaned correctly reads as a big zero run + sh's own
| 0x8001xxxx arena; a frame handed out with a prior owner's tail reads dense.
	clrl	i10g_inzlo
	clrl	i10g_inzhi
	clrl	i10g_izrun
	clrl	%d1			| current run of consecutive zero longs
	moveal	%a1,%a0
	movel	%a1,%d7
	addil	&2048,%d7		| midpoint (base + 0x800)
	movel	%a1,%d0
	addil	&4096,%d0
	moveal	%d0,%a3			| one past the frame
Lig_cen:
	movel	%a0@+,%d0
	bnes	Lig_cen_nz
	addql	&1,%d1
	cmpl	i10g_izrun,%d1
	blss	Lig_cen_end
	movel	%d1,i10g_izrun
	bras	Lig_cen_end
Lig_cen_nz:
	clrl	%d1
	movel	%a0,%d0
	subql	&4,%d0
	cmpl	%d7,%d0
	bccs	Lig_cen_hi
	addql	&1,i10g_inzlo
	bras	Lig_cen_end
Lig_cen_hi:
	addql	&1,i10g_inzhi
Lig_cen_end:
	cmpal	%a3,%a0
	bcss	Lig_cen
	movel	i10g_ioff,%d0		| the 64-byte block that contains the poison
	andil	&0xffffffc0,%d0
	movel	%a1,%d1
	addl	%d0,%d1
	moveal	%d1,%a0
	lea	i10g_ih0,%a4
	moveq	&15,%d1
Lig_ilb:
	movel	%a0@+,%a4@+
	dbra	%d1,Lig_ilb
	movel	i10g_ipfn,%d0		| the page_t: pages + (pfn - pages_base)*60
	subl	pages_base,%d0
	moveq	&60,%d1
	mulsl	%d1,%d0
	addl	pages,%d0
	movel	%d0,i10g_ipp
	moveal	%d0,%a0
	movel	%a0@,i10g_ipflags	| flags word @0 + p_keepcnt @2
	movel	%a0@(4),i10g_ivnode	| p_vnode -- nonzero here is the anon/swap vnode
	movel	%a0@(8),i10g_ioffp	| p_offset
	movel	%a0@(12),i10g_ihash
	movel	%a0@(32),i10g_imap	| p_mapping
	movel	&1,i10g_ilatched
	rts

| ---------------------------------------------------------------------------
| i10g_hook(frame, ctx) -- called from usrxmemflt (ctx=1) and krnxmemflt (ctx=2)
| at the resolved tail, AFTER wb040_replay has landed the faulting store, right
| after i10w_hook.  Dormant until i10g_on.
	.globl	i10g_hook
i10g_hook:
	tstl	i10g_on
	beqw	Lig_ret			| dormant: one memory test, nothing saved
	linkw	%fp,&0
	moveml	%d0-%d7/%a0-%a6,%sp@-	| preserve the wrappers' d4 (verdict) and d5 (FSLW)
	moveal	%fp@(8),%a2		| a2 = frame
	tstl	i10g_armed
	bnes	Lig_seq
	movel	curproc,i10g_armproc	| the process live at the first armed fault
	movel	&1,i10g_armed
| PART P proactive protect: on THIS first armed fault -- the wall's own sh, freshly
| exec'd right after the kpoke, whose parse has not yet reached the genesis -- write-
| protect every page ALREADY resident in the band [plo,phi).  A page that was resident
| before the watch armed (sh's bss / heap tail, mapped at exec) never faults on its own,
| so a store into it would be invisible to the reactive protect below -- which is exactly
| why the first band run caught only the propagation into the freshly-demand-zeroed
| 0x80014 page and never the genesis into the already-resident 0x80013 page.  One-shot.
	movel	i10g_plo,%d0
	beqs	Lig_seq			| band disabled (plo = 0)
	movel	i10g_plo,%d7		| d7 = page cursor
Lig_pinit:
	movel	%d7,%d0
	bsrw	i10w_leafpte		| -> a0 = &leafPTE or 0 (preserves d2/d7; clobbers d0/d1/a0/a1)
	movel	%a0,%d0
	beqs	Lig_pinit_n		| not resident: nothing to protect yet
	moveal	%a0,%a1
	orl	&4,%a1@			| set write-protect bit 2
Lig_pinit_n:
	addil	&0x1000,%d7
	cmpl	i10g_phi,%d7
	bcss	Lig_pinit
	.word	0xf4f8			| cpusha bc  (once, after protecting the resident band)
	.word	0xf518			| pflusha
Lig_seq:
	addql	&1,i10g_seq		| resolved faults seen since arming
| PART FIVE arm hook (2026-08-19): if the trace-watch knob i10t_want is set, and this
| resolved fault first brings in the poison page (FA in [i10t_armpage, +4K)), install a
| single-step watch on the ORDINARY store path -- no write-protect, so wb040_replay is
| NOT forced.  i10t_maybe_arm is a one-shot; it clobbers only d0/d1/a0/a1 (all restored
| at Lig_out) and reads %a2 (the frame).  See i10t_trace below for the confound this cuts.
	bsrw	i10t_maybe_arm
| ===== PART P: force stores in the heap band [plo,phi) to fault, so PART W sees
|       them.  The first genesis run found the poison is neither inherited (PART I
|       scanned every arena frame at hand-out and found none) nor caught as a
|       faulting store (PART W silent) -- because the genesis store lands on an
|       already-RESIDENT, writable page and does not fault at all.  This write-
|       protects each band page as it is touched (the same bit hat_chgprot040 flips)
|       so every subsequent store into it faults and PART W's WB-data check runs on
|       it.  It protects only the small heap band the poison is known to live in
|       (0x80013xxx source, 0x80014xxx propagation dest), and stops the moment PART W
|       latches, so the flood is bounded.  This is i10w_hook's proven protect/replay/
|       re-protect mechanism, value-triggered instead of pinned to one longword. =====
	tstl	i10g_wlatched
	bnew	Lig_p_done		| already caught (a store): stop perturbing
	tstl	i10g_ilatched
	bnew	Lig_p_done		| already caught (an appearance): stop perturbing
	movel	i10g_plo,%d0
	beqw	Lig_p_done		| band watch disabled (plo = 0)
	movel	%a2@(84),%d1		| FA
	andil	&0xfffff000,%d1		| its page
	cmpl	%d0,%d1
	bcsw	Lig_p_done		| below the band
	cmpl	i10g_phi,%d1
	bccw	Lig_p_done		| at or above the band
	tstl	i10g_p_armed
	bnes	Lig_p_prot
	movel	curproc,i10g_p_proc	| the process whose band we protect (must be sh)
	movel	&1,i10g_p_armed
Lig_p_prot:
	addql	&1,i10g_p_fault_n
	movel	%a2@(84),%d0		| re-protect THIS faulting band page
	bsrw	i10w_leafpte		| -> a0 = &leafPTE of the faulting page, or 0
	movel	%a0,%d0
	beqw	Lig_p_done
	moveal	%a0,%a1
	orl	&4,%a1@			| set write-protect bit 2, then publish + flush
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
Lig_p_done:
| ===== PART W: a CONFIRMED faulting store of the poison? =====
	tstl	i10g_wlatched
	bnew	Lig_inh
	movel	i10g_wantval,%d5
	movel	%a2@(92),%d0		| WB3D
	cmpl	%d5,%d0
	bnes	Lig_w2
	moveq	&3,%d3
	movel	%a2@(88),%d4		| WB3A
	braw	Lig_wconf
Lig_w2:
	movel	%a2@(100),%d0		| WB2D
	cmpl	%d5,%d0
	bnes	Lig_w1
	moveq	&2,%d3
	movel	%a2@(96),%d4
	braw	Lig_wconf
Lig_w1:
	movel	%a2@(108),%d0		| WB1D
	cmpl	%d5,%d0
	bnew	Lig_inh
	moveq	&1,%d3
	movel	%a2@(104),%d4
Lig_wconf:
| d3 = slot, d4 = the store's target.  Reject a non-user or non-resident target,
| and CONFIRM the poison landed there (a stale WBnD field on a non-store fault
| holds a previous instruction's data and must not be believed).
	movel	%d4,%d0
	cmpil	&0x80000000,%d0
	bcsw	Lig_inh			| not a user address
	movel	%d4,%d0
	bsrw	i10g_ckframe		| -> a1 = frame base or 0
	movel	%a1,%d0
	beqw	Lig_inh			| target not resident: cannot confirm
	movel	%d4,%d0
	andil	&0xfff,%d0
	addl	%d0,%a1			| a1 = the target longword's physical address
	movel	%a1@,%d0
	movel	%d0,i10g_wmem		| what the target holds after the store
	cmpl	i10g_wantval,%d0
	bnew	Lig_inh			| the poison did NOT land there: stale WB, reject
	bsrw	i10g_wlatch
Lig_inh:
| ===== PART I: does the faulting page's frame already carry the poison? =====
	tstl	i10g_ilatched
	bnew	Lig_out
	movel	%a2@(84),%d0		| FA
	cmpl	i10g_lova,%d0
	bcsw	Lig_out			| below the arena band
	cmpl	i10g_hiva,%d0
	bccw	Lig_out			| at or above it
	addql	&1,i10g_arena_n
	movel	%a2@(84),%d0
	bsrw	i10g_ckframe		| -> a1 = the faulting page's frame base or 0
	movel	%a1,%d0
	beqw	Lig_out
	moveal	%a1,%a0			| a0 = scan cursor
	movel	%a1,%d6			| d6 = frame base (for the offset), saved across scan
	movel	i10g_wantval,%d5
	movel	%a1,%d0
	addil	&4096,%d0
	moveal	%d0,%a3			| a3 = one past the frame
Lig_iscan:
	movel	%a0@+,%d0
	cmpl	%d5,%d0
	beqs	Lig_ihit
	cmpal	%a3,%a0
	bcss	Lig_iscan
	braw	Lig_out			| the poison is not in this frame
Lig_ihit:
	addql	&1,i10g_scan_hits
	movel	%a0,%d0
	subql	&4,%d0			| a0 post-incremented past the match
	subl	%d6,%d0
	movel	%d0,i10g_ioff		| the poison's byte offset in the frame
| iself: did THIS fault's own store write that exact address?  If so the poison is
| this instruction's doing, not something the frame arrived carrying.
	movel	%a2@(84),%d0
	andil	&0xfffff000,%d0
	addl	i10g_ioff,%d0		| the poison's user VA
	clrl	i10g_iself
	cmpl	%a2@(88),%d0		| WB3A
	bnes	Lig_isf2
	movel	&3,i10g_iself
	bras	Lig_idone
Lig_isf2:
	cmpl	%a2@(96),%d0		| WB2A
	bnes	Lig_isf1
	movel	&2,i10g_iself
	bras	Lig_idone
Lig_isf1:
	cmpl	%a2@(104),%d0		| WB1A
	bnes	Lig_idone
	movel	&1,i10g_iself
Lig_idone:
	moveal	%d6,%a1			| a1 = frame base for the latch
	bsrw	i10g_ilatch
Lig_out:
	moveml	%sp@+,%d0-%d7/%a0-%a6
	unlk	%fp
Lig_ret:
	rts

	.balign 4

	.data
	.even
| ---------------------------------------------------------------------------
| The i10g block -- read i10g_magic FIRST (a stale address does not fail, it
| lies), then 105 longs.  Knobs are kpoke-able: the watched value and the arena
| band can move without a rebuild.
	.globl	i10g_magic
i10g_magic:
	.long	0x49314721		| "I1G!"
| --- knobs ---
	.globl	i10g_on
i10g_on:
	.long	0			| 0 = dormant (ships this way).  kpoke 1 to arm.
	.globl	i10g_wantval
i10g_wantval:
	.long	0x4afc0000		| the poison value hunted for
	.globl	i10g_lova
i10g_lova:
	.long	0x80010000		| PART I arena band: [lova, hiva) -- sh's heap, past
	.globl	i10g_hiva		| its text/data image (sh text has 0x4AFC00xx but not
i10g_hiva:				| 0x4AFC0000, so the exact-value scan cannot false-hit)
	.long	0x80080000
| --- state ---
	.globl	i10g_armed
i10g_armed:
	.long	0
	.globl	i10g_armproc
i10g_armproc:
	.long	0			| curproc at the first armed fault
	.globl	i10g_seq
i10g_seq:
	.long	0			| resolved faults seen since arming (the clock the
					| two latch seqs are ordered against)
	.globl	i10g_arena_n
i10g_arena_n:
	.long	0			| resolved faults in the arena band (PART I scans)
	.globl	i10g_scan_hits
i10g_scan_hits:
	.long	0			| frames found holding the poison (>=1 means PART I fired)
| --- PART W: the store that WROTE the poison (if any) ---
	.globl	i10g_wlatched
i10g_wlatched:
	.long	0			| 1 = a confirmed poison store was caught
	.globl	i10g_wseq
i10g_wseq:
	.long	0			| i10g_seq at the W latch (compare with i10g_iseq)
	.globl	i10g_wctx
i10g_wctx:
	.long	0			| 1 = usrxmemflt (user wrapper), 2 = krnxmemflt (kernel)
	.globl	i10g_wsr
i10g_wsr:
	.long	0			| SR; bit 13 (0x2000) = S: SET => a KERNEL store
	.globl	i10g_wpc
i10g_wpc:
	.long	0			| the storing instruction's PC (040 defers WB by one insn)
	.globl	i10g_wfa
i10g_wfa:
	.long	0			| the fault address
	.globl	i10g_wssw
i10g_wssw:
	.long	0
	.globl	i10g_wslot
i10g_wslot:
	.long	0			| which write-back matched: 3, 2 or 1
	.globl	i10g_wb3a
i10g_wb3a:
	.long	0
	.globl	i10g_wb3d
i10g_wb3d:
	.long	0
	.globl	i10g_wb2a
i10g_wb2a:
	.long	0
	.globl	i10g_wb2d
i10g_wb2d:
	.long	0
	.globl	i10g_wb1a
i10g_wb1a:
	.long	0
	.globl	i10g_wb1d
i10g_wb1d:
	.long	0
	.globl	i10g_wtgt
i10g_wtgt:
	.long	0			| the matched store's effective address
	.globl	i10g_wtoff
i10g_wtoff:
	.long	0			| its offset inside the frame
	.globl	i10g_wmem
i10g_wmem:
	.long	0			| the target longword re-read after the store (== poison)
| the 16 saved registers of the storing instruction (frame+0..+60): d0-d7, a0-a6,
| supervisor a7.  If the store is a move.l (aX),(aY) copy, the source address
| register exposes where it read the poison FROM -- the next hop upstream.
	.globl	i10g_wr0
i10g_wr0:
	.long	0
	.globl	i10g_wr1
i10g_wr1:
	.long	0
	.globl	i10g_wr2
i10g_wr2:
	.long	0
	.globl	i10g_wr3
i10g_wr3:
	.long	0
	.globl	i10g_wr4
i10g_wr4:
	.long	0
	.globl	i10g_wr5
i10g_wr5:
	.long	0
	.globl	i10g_wr6
i10g_wr6:
	.long	0
	.globl	i10g_wr7
i10g_wr7:
	.long	0
	.globl	i10g_wr8
i10g_wr8:
	.long	0
	.globl	i10g_wr9
i10g_wr9:
	.long	0
	.globl	i10g_wr10
i10g_wr10:
	.long	0
	.globl	i10g_wr11
i10g_wr11:
	.long	0
	.globl	i10g_wr12
i10g_wr12:
	.long	0
	.globl	i10g_wr13
i10g_wr13:
	.long	0
	.globl	i10g_wr14
i10g_wr14:
	.long	0
	.globl	i10g_wr15
i10g_wr15:
	.long	0
| the 64-byte block around the store target, low address first:
	.globl	i10g_wc0
i10g_wc0:
	.long	0
	.globl	i10g_wc1
i10g_wc1:
	.long	0
	.globl	i10g_wc2
i10g_wc2:
	.long	0
	.globl	i10g_wc3
i10g_wc3:
	.long	0
	.globl	i10g_wc4
i10g_wc4:
	.long	0
	.globl	i10g_wc5
i10g_wc5:
	.long	0
	.globl	i10g_wc6
i10g_wc6:
	.long	0
	.globl	i10g_wc7
i10g_wc7:
	.long	0
	.globl	i10g_wc8
i10g_wc8:
	.long	0
	.globl	i10g_wc9
i10g_wc9:
	.long	0
	.globl	i10g_wc10
i10g_wc10:
	.long	0
	.globl	i10g_wc11
i10g_wc11:
	.long	0
	.globl	i10g_wc12
i10g_wc12:
	.long	0
	.globl	i10g_wc13
i10g_wc13:
	.long	0
	.globl	i10g_wc14
i10g_wc14:
	.long	0
	.globl	i10g_wc15
i10g_wc15:
	.long	0
| --- PART I: the frame that arrived carrying the poison (if any) ---
	.globl	i10g_ilatched
i10g_ilatched:
	.long	0			| 1 = a frame holding the poison was latched
	.globl	i10g_iseq
i10g_iseq:
	.long	0			| i10g_seq at the I latch
	.globl	i10g_ifa
i10g_ifa:
	.long	0			| the fault address that brought the frame in
	.globl	i10g_iuva
i10g_iuva:
	.long	0			| the poison page's user VA base
	.globl	i10g_iframe
i10g_iframe:
	.long	0			| the frame's physical base
	.globl	i10g_ipfn
i10g_ipfn:
	.long	0
	.globl	i10g_iproc
i10g_iproc:
	.long	0			| curproc at the latch (its u_comm must read "sh")
	.globl	i10g_icomm0
i10g_icomm0:
	.long	0			| u_comm, 16 bytes
	.globl	i10g_icomm1
i10g_icomm1:
	.long	0
	.globl	i10g_icomm2
i10g_icomm2:
	.long	0
	.globl	i10g_icomm3
i10g_icomm3:
	.long	0
	.globl	i10g_ioff
i10g_ioff:
	.long	0			| the poison's byte offset in the frame
	.globl	i10g_iself
i10g_iself:
	.long	0			| nonzero (=slot) if THIS fault's own store wrote that
					| offset; 0 = the frame already held it (inherited)
	.globl	i10g_ipp
i10g_ipp:
	.long	0			| its page_t
	.globl	i10g_ipflags
i10g_ipflags:
	.long	0			| flags word @0 + p_keepcnt @2
	.globl	i10g_ivnode
i10g_ivnode:
	.long	0			| p_vnode
	.globl	i10g_ioffp
i10g_ioffp:
	.long	0			| p_offset
	.globl	i10g_ihash
i10g_ihash:
	.long	0			| p_hash
	.globl	i10g_imap
i10g_imap:
	.long	0			| p_mapping
	.globl	i10g_inzlo
i10g_inzlo:
	.long	0			| non-zero longs in the frame's LOWER half (512)
	.globl	i10g_inzhi
i10g_inzhi:
	.long	0			| non-zero longs in the frame's UPPER half (512)
	.globl	i10g_izrun
i10g_izrun:
	.long	0			| longest run of consecutive zero longs in the frame
	.globl	i10g_iw0
i10g_iw0:
	.long	0			| the frame's first eight longs
	.globl	i10g_iw1
i10g_iw1:
	.long	0
	.globl	i10g_iw2
i10g_iw2:
	.long	0
	.globl	i10g_iw3
i10g_iw3:
	.long	0
	.globl	i10g_iw4
i10g_iw4:
	.long	0
	.globl	i10g_iw5
i10g_iw5:
	.long	0
	.globl	i10g_iw6
i10g_iw6:
	.long	0
	.globl	i10g_iw7
i10g_iw7:
	.long	0
| the 64-byte block that contains the poison, low address first:
	.globl	i10g_ih0
i10g_ih0:
	.long	0
	.globl	i10g_ih1
i10g_ih1:
	.long	0
	.globl	i10g_ih2
i10g_ih2:
	.long	0
	.globl	i10g_ih3
i10g_ih3:
	.long	0
	.globl	i10g_ih4
i10g_ih4:
	.long	0
	.globl	i10g_ih5
i10g_ih5:
	.long	0
	.globl	i10g_ih6
i10g_ih6:
	.long	0
	.globl	i10g_ih7
i10g_ih7:
	.long	0
	.globl	i10g_ih8
i10g_ih8:
	.long	0
	.globl	i10g_ih9
i10g_ih9:
	.long	0
	.globl	i10g_ih10
i10g_ih10:
	.long	0
	.globl	i10g_ih11
i10g_ih11:
	.long	0
	.globl	i10g_ih12
i10g_ih12:
	.long	0
	.globl	i10g_ih13
i10g_ih13:
	.long	0
	.globl	i10g_ih14
i10g_ih14:
	.long	0
	.globl	i10g_ih15
i10g_ih15:
	.long	0
| --- PART P: the heap-band write-protect that forces resident-page stores to fault ---
	.globl	i10g_plo
i10g_plo:
	.long	0x80014000		| protect stores into [plo, phi) so PART W/PART I see them;
	.globl	i10g_phi		| plo = 0 disables PART P.  Default: the SINGLE page 0x80014
i10g_phi:				| the wall reads the corrupt link from -- and where PART I found
					| the poison's FIRST appearance in the arena.  Widening the band
					| (kpoke a lower plo) protects more pages but the flood scales with
					| every store into them, so a multi-page default would grind.
	.long	0x80015000
	.globl	i10g_p_armed
i10g_p_armed:
	.long	0
	.globl	i10g_p_proc
i10g_p_proc:
	.long	0			| the process whose band is protected (must be the wall's sh)
	.globl	i10g_p_fault_n
i10g_p_fault_n:
	.long	0			| store faults forced on the band (i10w saw 1869 for one page)
| --- PART I: the storing instruction that made the poison appear (band write-protected) ---
	.globl	i10g_ipc
i10g_ipc:
	.long	0			| the storing instruction's PC (one past the store: WB deferred)
	.globl	i10g_isr
i10g_isr:
	.long	0			| SR; bit 13 (0x2000) = S: SET => a KERNEL store
	.globl	i10g_iwb3a
i10g_iwb3a:
	.long	0			| WB3 address of that store
	.globl	i10g_iwb3d
i10g_iwb3d:
	.long	0			| WB3 data of that store
| --- PART W: the frame the poison was COPIED FROM (the store's source register) ---
	.globl	i10g_wsrc
i10g_wsrc:
	.long	0			| the source VA (the register that points at the poison)
	.globl	i10g_wsrcr
i10g_wsrcr:
	.long	0			| which address register: 0..6 = a0..a6, -1 = none found
	.globl	i10g_wsrcv
i10g_wsrcv:
	.long	0			| the longword at the source (must be the poison)
	.globl	i10g_ws0
i10g_ws0:
	.long	0			| 32-byte block around the source, low address first
	.globl	i10g_ws1
i10g_ws1:
	.long	0
	.globl	i10g_ws2
i10g_ws2:
	.long	0
	.globl	i10g_ws3
i10g_ws3:
	.long	0
	.globl	i10g_ws4
i10g_ws4:
	.long	0
	.globl	i10g_ws5
i10g_ws5:
	.long	0
	.globl	i10g_ws6
i10g_ws6:
	.long	0
	.globl	i10g_ws7
i10g_ws7:
	.long	0
| *(a0)..*(a6) at the store -- the value each address register points at.  The move's
| intended write value is *(source); comparing these to WB3D (i10g_wb3d) tells a real
| copy (some wpv == the poison, at a non-dest address) from a fabricated write-back
| (no wpv holds the poison except the dest -> the 040 write-back invented the value).
	.globl	i10g_wpv0
i10g_wpv0:
	.long	0
	.globl	i10g_wpv1
i10g_wpv1:
	.long	0
	.globl	i10g_wpv2
i10g_wpv2:
	.long	0
	.globl	i10g_wpv3
i10g_wpv3:
	.long	0
	.globl	i10g_wpv4
i10g_wpv4:
	.long	0
	.globl	i10g_wpv5
i10g_wpv5:
	.long	0
	.globl	i10g_wpv6
i10g_wpv6:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

| ===========================================================================
| PART FIVE -- i10t: the ORDINARY-STORE trace-watch (2026-08-19).
|
| WHAT CONFOUND THIS CUTS.  PART FOUR (i10g) caught the store that lands
| 0x4AFC0000 at 0x80014AA0 by WRITE-PROTECTING the page, which forces the store
| to fault and routes its completion through the 68040 deferred-write-back replay
| in wb040.s.  That capture cannot separate two worlds:
|   A. the ordinary, non-faulting store on the emulated 040 already fabricates the
|      value -> the 040 write-back core (emulator's, possibly silicon's);
|   B. the value appears only because the write-protect forced the deferred/replay
|      path -> an artifact of the method, not of the ordinary store the real wall
|      takes.
| i10g cannot tell them apart because every store it sees has been forced to fault.
| This part observes the SAME store on the path the uninstrumented wall actually
| takes: no write-protect, no fault, no replay.
|
| HOW.  A user store single-steps under the 68040 trace bit (T1), which the write-
| watch header rejected for KERNEL stores (T is clear inside a syscall) -- but this
| store is a USER store (i10g/i10w both measured SR S-bit clear, PC in /bin/sh's own
| text), so T1 is live for it.  On the resolved tail of the fault that FIRST brings
| in the poison page (FA in [i10t_armpage,+4K)) -- an ORDINARY demand-zero, the same
| event i10w armed on -- i10t_maybe_arm sets T1 in the returning user frame, installs
| its own vector-9 handler (saving the stock one to chain), and records the process.
| From there /bin/sh single-steps ON THE ORDINARY PATH; i10t_trace re-reads the
| target longword each step and latches the first transition INTO the poison, with:
|   * i10t_before / i10t_after  -- the destination longword just before and after;
|   * i10t_culpc                -- the instruction that did it (format-2 frame's
|                                  instruction-address field = the store just run);
|   * i10t_wbdelta              -- wb_replay_n across that one step.  ZERO proves the
|                                  store did NOT fault and did NOT go through
|                                  wb040_replay: the ordinary path, replay off it;
|   * i10t_r0..r14, i10t_pv0..6, i10t_srcr/srcv -- the register file after the store
|                                  and the value each address register points at.  If
|                                  no NON-destination register holds the poison
|                                  (srcr = -1) yet after==poison, the ordinary store
|                                  FABRICATED it (world A).  If some non-dest source
|                                  already holds the poison (srcr >= 0), the ordinary
|                                  store faithfully COPIED it and the genesis is one
|                                  hop upstream -- i10g's write-protected attribution
|                                  was the artifact (world B).
| No page is protected and i10g_plo must be kpoked 0 for this run, so PART P of i10g
| never fires; the only faults are /bin/sh's own demand faults.
|
| SAFETY.  Ships dormant: i10t_want = 0, so i10t_maybe_arm is one memory test per
| resolved fault and the stock vector-9 handler is never touched.  Once armed, only
| the recorded process traces (T1 set on it alone); every other trace chains to the
| saved stock handler.  A runaway (poison never seen) auto-disarms after i10t_stepmax
| steps, restoring the stock vector and clearing T1, so the boot always completes.
| The handler saves/restores d0-d7/a0-a6 and reads user memory through i10g_ckframe
| (the same resident-or-abandon walk i10g uses), never a raw user dereference.
| ===========================================================================

	.text
	.balign 4

| i10t_maybe_arm -- called from i10g_hook (a2 = frame) once per resolved fault while
| i10g is armed.  One-shot; arms the trace-watch on the first fault into the poison
| page.  Clobbers d0/d1/a0/a1 only (i10g_hook has saved the full register file).
	.globl	i10t_maybe_arm
i10t_maybe_arm:
	tstl	i10t_want
	beqw	Lit_ma_ret		| dormant knob: nothing armed, stock vector intact
	tstl	i10t_armed_t
	bnew	Lit_ma_ret		| one-shot: already armed
	movel	%a2@(84),%d0		| FA
	andil	&0xfffff000,%d0
	cmpl	i10t_armpage,%d0
	bnew	Lit_ma_ret		| not the poison page's first fault yet
	movel	&1,i10t_armed_t
	movel	curproc,i10t_proc	| the process we single-step (post-hoc: must be sh)
	movel	wb_replay_n,i10t_wbrep_arm
	movel	wb_replay_n,i10t_wbrep_now
	movel	wb_replay_n,i10t_wbrep_prev
| seed i10t_prev from the target (the page was just resolved, so it is resident)
	movel	i10t_tgtva,%d0
	bsrw	i10g_ckframe		| a1 = frame base or 0
	movel	%a1,%d0
	beqs	Lit_ma_noseed
	movel	i10t_tgtva,%d0
	andil	&0xfff,%d0
	addal	%d0,%a1
	movel	%a1@,%d0
	movel	%d0,i10t_prev
	movel	&1,i10t_seeded
Lit_ma_noseed:
| install our vector-9 (trace) handler, saving the stock one to chain/restore
	.word	0x4e7a,0x0801		| movec %vbr,%d0
	moveal	%d0,%a0
	movel	%a0@(0x24),i10t_oldvec	| vector 9 = 0x24
	movel	&i10t_trace,%a0@(0x24)
| set T1 (bit 15) in the returning user frame SR, so /bin/sh single-steps from here
	orw	&0x8000,%a2@(64)
	movel	&1,i10t_on
Lit_ma_ret:
	rts

| i10t_trace -- vector-9 (trace) handler.  Entry: sp -> 68040 format-2 trace frame
| (SR@0, PC-of-next@2, fmt/vec@6, instruction-address@8).  For the watched process
| it re-reads the target and latches the first transition into the poison; every
| other trace chains to the saved stock handler.
	.globl	i10t_trace
i10t_trace:
	moveml	%d0-%d7/%a0-%a6,%sp@-	| save the user register file (60 bytes)
	lea	%sp@(60),%a2		| a2 = format-2 frame base (survives i10g_ckframe)
	tstl	i10t_on
	beqw	Lit_chain
	movel	curproc,%d0
	cmpl	i10t_proc,%d0
	bnew	Lit_chain		| a different process tracing: not ours
	addql	&1,i10t_step_n
	movel	i10t_step_n,%d0
	cmpl	i10t_stepmax,%d0
	bccw	Lit_stop		| runaway guard: disarm, let the boot finish
	movel	i10t_wbrep_now,i10t_wbrep_prev
	movel	wb_replay_n,i10t_wbrep_now
	movel	i10t_tgtva,%d0
	bsrw	i10g_ckframe		| a1 = frame base or 0 (a2/d3-d7 survive)
	movel	%a1,%d0
	beqw	Lit_keep		| target not resident this step
	movel	i10t_tgtva,%d0
	andil	&0xfff,%d0
	addal	%d0,%a1
	movel	%a1@,%d7		| d7 = w (target value now)
	addql	&1,i10t_res_n
	tstl	i10t_seeded
	bnew	Lit_haveprev
	movel	%d7,i10t_prev		| first resident read: establish prev, no compare
	movel	&1,i10t_seeded
	braw	Lit_keep
Lit_haveprev:
	tstl	i10t_latched
	bnew	Lit_keep		| already caught the first transition
	movel	i10t_prev,%d6
	cmpl	i10g_wantval,%d6
	beqw	Lit_updprev		| prev already poison: not a fresh transition
	cmpl	i10g_wantval,%d7
	bnew	Lit_updprev		| w not poison
	bsrw	i10t_do_latch		| *** ORDINARY-PATH transition into the poison ***
	braw	Lit_stop		| caught it: disarm; the wall follows in a few insns
Lit_updprev:
	movel	%d7,i10t_prev
Lit_keep:
	orw	&0x8000,%a2@(0)		| keep T1 set in the returning frame SR
	moveml	%sp@+,%d0-%d7/%a0-%a6
	rte
Lit_stop:
	clrl	i10t_on
	.word	0x4e7a,0x0801		| movec %vbr,%d0
	moveal	%d0,%a0
	movel	i10t_oldvec,%a0@(0x24)	| restore the stock vector-9 handler
	andw	&0x7fff,%a2@(0)		| clear T1: /bin/sh resumes at full speed
	moveml	%sp@+,%d0-%d7/%a0-%a6
	rte
Lit_chain:
	moveml	%sp@+,%d0-%d7/%a0-%a6
	tstl	i10t_oldvec
	bnes	Lit_chain1
	rte				| no saved handler: just discard the trace
Lit_chain1:
	movel	i10t_oldvec,%sp@-	| chain to the stock trace handler, frame intact
	rts

| i10t_do_latch -- a2 = format-2 frame base, d7 = w (the poison just landed).  Capture
| the whole transition: before/after, the culprit PC, the replay delta (0 = no replay),
| the register file after the store, and what each address register points at.
i10t_do_latch:
	movel	&1,i10t_latched
	movel	i10t_step_n,i10t_lseq
	movel	i10t_prev,i10t_before
	movel	%d7,i10t_after
	movel	i10t_wbrep_now,%d0
	subl	i10t_wbrep_prev,%d0
	movel	%d0,i10t_wbdelta	| wb_replay_n across the culprit step: 0 = ordinary
	movel	wb_replay_n,i10t_wbrep_latch
	moveq	&0,%d0
	movew	%a2@(0),%d0		| SR (bit 13 = 0x2000 = S: set would mean a kernel store)
	movel	%d0,i10t_lsr
	movel	%a2@(2),i10t_nextpc	| PC of the next instruction
	movel	%a2@(8),i10t_culpc	| instruction address = the store just executed
| copy the 15 saved user registers (d0-d7, a0-a6) from the stack save block
	lea	%a2@(-60),%a0		| a0 = &saved d0 (frame base - the 60-byte moveml)
	lea	i10t_r0,%a1
	moveq	&14,%d1
Lit_cpr:
	movel	%a0@+,%a1@+
	dbra	%d1,Lit_cpr
	.word	0x4e68			| move %usp,%a0
	movel	%a0,i10t_usp
| identify a genuine COPY SOURCE: for a move.l (aSrc),(aDst) the destination is
| i10t_tgtva; scan a0-a6 (i10t_r8..r14) for one that is NOT the destination and whose
| target longword holds the poison.  None found (srcr = -1) with after == poison means
| the ordinary store FABRICATED the value; one found means it copied it.
	movel	&-1,i10t_srcr
	clrl	i10t_srcv
	moveq	&8,%d6			| d6 = reg index: 8 = a0 .. 14 = a6
Lit_pv:
	movel	%d6,%d0
	asll	&2,%d0
	lea	i10t_r0,%a0
	movel	%a0@(0,%d0:l),%d5	| d5 = aN value (survives i10g_ckframe)
	movel	%d6,%d0
	subql	&8,%d0
	asll	&2,%d0
	lea	i10t_pv0,%a0
	clrl	%a0@(0,%d0:l)		| default: not a readable user pointer
	cmpil	&0x80000000,%d5
	bcss	Lit_pv_n		| not a user address
	movel	%d5,%d0
	bsrw	i10g_ckframe		| a1 = frame base or 0 (d5/d6 survive)
	movel	%a1,%d0
	beqs	Lit_pv_n		| that frame not resident
	movel	%d5,%d0
	andil	&0xfff,%d0
	addal	%d0,%a1
	movel	%a1@,%d4		| d4 = *(aN)
	movel	%d6,%d0
	subql	&8,%d0
	asll	&2,%d0
	lea	i10t_pv0,%a0
	movel	%d4,%a0@(0,%d0:l)	| i10t_pv<N> = *(aN)
	cmpl	i10g_wantval,%d4
	bnes	Lit_pv_n		| this register does not point at the poison
	cmpl	i10t_tgtva,%d5
	beqs	Lit_pv_n		| it IS the destination just written -- not a source
	movel	%d6,%d0
	subql	&8,%d0
	movel	%d0,i10t_srcr		| 0..6 = a0..a6: a genuine non-dest source
	movel	%d4,i10t_srcv
Lit_pv_n:
	addql	&1,%d6
	cmpil	&15,%d6
	bcss	Lit_pv
	rts

	.balign 4

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The i10t block -- read i10t_magic FIRST (a stale address does not fail, it returns
| a plausible number).  Knobs: kpoke i10t_want 1 to enable, and (for this run) kpoke
| i10g_plo 0 so no page is write-protected.  kpeek i10t_magic 50 dumps the whole block.
	.globl	i10t_magic
i10t_magic:
	.long	0x49315421		| "I1T!"
	.globl	i10t_want
i10t_want:
	.long	0			| 0 = dormant (ships this way).  kpoke 1 to arm the watch.
	.globl	i10t_armpage
i10t_armpage:
	.long	0x80014000		| arm on the first fault into this page (the poison page)
	.globl	i10t_tgtva
i10t_tgtva:
	.long	0x80014aa0		| the watched destination longword
	.globl	i10t_stepmax
i10t_stepmax:
	.long	8000000			| runaway guard: auto-disarm after this many traced steps
	.globl	i10t_on
i10t_on:
	.long	0			| 1 while the watch is live (handler installed, T1 set)
	.globl	i10t_armed_t
i10t_armed_t:
	.long	0			| one-shot arm latch
	.globl	i10t_proc
i10t_proc:
	.long	0			| the process being single-stepped (compare to i10g_armproc)
	.globl	i10t_oldvec
i10t_oldvec:
	.long	0			| saved stock vector-9 handler (chain + restore)
	.globl	i10t_seeded
i10t_seeded:
	.long	0			| 1 once i10t_prev holds a real read of the target
	.globl	i10t_prev
i10t_prev:
	.long	0			| the target's value at the previous step
	.globl	i10t_step_n
i10t_step_n:
	.long	0			| traced instructions seen for i10t_proc
	.globl	i10t_res_n
i10t_res_n:
	.long	0			| steps where the target was resident (read ok)
	.globl	i10t_wbrep_arm
i10t_wbrep_arm:
	.long	0			| wb_replay_n at arm (context)
	.globl	i10t_wbrep_prev
i10t_wbrep_prev:
	.long	0			| wb_replay_n at the previous step
	.globl	i10t_wbrep_now
i10t_wbrep_now:
	.long	0			| wb_replay_n at the current step
	.globl	i10t_latched
i10t_latched:
	.long	0			| 1 once the first transition into the poison is caught
	.globl	i10t_lseq
i10t_lseq:
	.long	0			| i10t_step_n at the latch
	.globl	i10t_before
i10t_before:
	.long	0			| the target longword BEFORE the culprit store
	.globl	i10t_after
i10t_after:
	.long	0			| the target longword AFTER it (must be the poison)
	.globl	i10t_culpc
i10t_culpc:
	.long	0			| the instruction that landed it (format-2 instr address)
	.globl	i10t_nextpc
i10t_nextpc:
	.long	0			| the next instruction's PC (format-2 PC)
	.globl	i10t_lsr
i10t_lsr:
	.long	0			| SR at the latch (S bit says user vs kernel store)
	.globl	i10t_wbdelta
i10t_wbdelta:
	.long	0			| wb_replay_n delta across the culprit step: 0 = NO replay
	.globl	i10t_wbrep_latch
i10t_wbrep_latch:
	.long	0			| wb_replay_n at the latch (absolute)
	.globl	i10t_srcr
i10t_srcr:
	.long	-1			| which address reg held the poison as a non-dest source; -1 = none
	.globl	i10t_srcv
i10t_srcv:
	.long	0			| that source's value
	.globl	i10t_usp
i10t_usp:
	.long	0			| the user stack pointer at the latch
| the register file after the culprit store: d0-d7 then a0-a6 (15 longs)
	.globl	i10t_r0
i10t_r0:
	.long	0
	.globl	i10t_r1
i10t_r1:
	.long	0
	.globl	i10t_r2
i10t_r2:
	.long	0
	.globl	i10t_r3
i10t_r3:
	.long	0
	.globl	i10t_r4
i10t_r4:
	.long	0
	.globl	i10t_r5
i10t_r5:
	.long	0
	.globl	i10t_r6
i10t_r6:
	.long	0
	.globl	i10t_r7
i10t_r7:
	.long	0
	.globl	i10t_r8
i10t_r8:
	.long	0
	.globl	i10t_r9
i10t_r9:
	.long	0
	.globl	i10t_r10
i10t_r10:
	.long	0
	.globl	i10t_r11
i10t_r11:
	.long	0
	.globl	i10t_r12
i10t_r12:
	.long	0
	.globl	i10t_r13
i10t_r13:
	.long	0
	.globl	i10t_r14
i10t_r14:
	.long	0
| *(a0)..*(a6): the value each address register points at, after the store
	.globl	i10t_pv0
i10t_pv0:
	.long	0
	.globl	i10t_pv1
i10t_pv1:
	.long	0
	.globl	i10t_pv2
i10t_pv2:
	.long	0
	.globl	i10t_pv3
i10t_pv3:
	.long	0
	.globl	i10t_pv4
i10t_pv4:
	.long	0
	.globl	i10t_pv5
i10t_pv5:
	.long	0
	.globl	i10t_pv6
i10t_pv6:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement)

| ===========================================================================
| PART SIX -- i10r: the RESOLUTION AUDIT (2026-08-19).
|
| WHAT CHANGED UNDER THIS UNIT'S FEET.  Parts THREE to FIVE were built to answer
| "who stores 0x4AFC0000", on the reading that the value was fabricated by the
| 68040 store/write-back mechanism.  An emulator-side watch has since read the
| whole chain end to end and that reading is wrong: 0x4AFC0000 is the KERNEL's own
| ILLEGAL-at-null sentinel (`MOVE.W #$4AFC,(0).L`, bytes 33 fc 4a fc, at file
| offset 0x73CC of stock 2.1, of our 2.1c, and of both unix-040 and unix-060),
| read LEGALLY through user VA 0 by /bin/sh's allocator after its free-list walk
| followed a NULL link.  Nothing fabricates it; sh dereferences a null pointer and
| the kernel's own sentinel word is what lies there.
|
| The NULL is the real defect, and it is one page earlier: sh's addblok writes the
| end-of-arena marker (_end+1 = 0x800114B5) to the newly grown bloktop -- and for
| the fatal grow THAT STORE VANISHES.  The 68040 pushed a format-7 access-error
| frame for it with a VALID pending write-back (measured: ssw=0401, fc=1, rw=W,
| sz=L, atc=1, wb3v=1, wb3s=81, wb3d=800114b5, stacked pc = 8000250E), the kernel
| returned as-if-resolved, and NOTHING happened: no mapping, no zero-fill, no
| replayed store, no signal.  Five ticks later the WALK's byte read faults on the
| same page, and THAT fault maps and zero-fills it -- so the walk reads the zeros
| where its marker should have been, follows the NULL, and walls.
|
| WHAT THIS UNIT MEASURES.  The emulator watch can see that the kernel did nothing;
| it cannot see WHERE in the kernel the doing-nothing happens.  This audit latches
| ONE watched fault from inside the fault path and records what each stage of it
| decided, so the swallowing branch can be named rather than inferred:
|
|   * the frame POINTER the wrapper received (%fp@(8)) and the WB1/WB2/WB3 status,
|     address and data longs AS READ FROM THAT POINTER, at the very offsets
|     wb040_replay reads them.  If the kernel's read of the frame disagrees with
|     what the CPU pushed -- the emulator's own WB7 line prints the same fields --
|     the fault never had a write-back to replay in the first place, and that is a
|     different bug from one that had one and dropped it;
|   * usrxmemflt_orig's verdict (the wrapper's d4), and the k_siginfo_t the wrapper
|     is about to return in, so "no signal was delivered" is a reading of the field
|     u_trap actually consumes rather than an inference from the console;
|   * ptest -- the SAME routine the stock classifier branches on -- called for the
|     watched VA BEFORE the resolver runs and again AFTER it, plus the raw 68040
|     MMUSR both times.  The stock classifier's choice is a pure function of that
|     result and the SSW (src/usrxmemflt040-design.md), so the pair pins the branch
|     from the outside without patching a stock call site;
|   * the leaf PTE and the watched longword before and after, which is "did the
|     resolution map anything, and did the store land" as two numbers;
|   * wb_replay_n across the fault (how many write-back slots were actually
|     re-issued), the write-back denial counters, and a per-slot DECODE of the
|     frame's own valid/skip bits.
|
| DERIVED IS NOT MEASURED, and the block keeps them apart.  i10r_dec1..3 and
| i10r_branch are DECODES of fields recorded here, computed by this code; every
| other field is a value read out of the frame, the u-area or a counter.  A decode
| that disagrees with the measured wb_replay_n delta is the finding, which is only
| possible because the two are not the same number.
|
| WHAT IT DOES NOT DO.  as_fault's own (addr, type, rw) triple is NOT captured: the
| call site is inside the stock resolver's body and reaching it means either a byte
| patch of stock code or wrapping as_fault for every caller in the kernel, neither
| of which is proportionate to one measurement.  The ptest pair plus the SSW gives
| the branch that CHOOSES those arguments, which is the question; if the branch
| turns out to be the F_INVAL demand path after all, as_fault's arguments become
| worth the intrusion and not before.
|
| WHERE IT HOOKS, AND WHY BOTH ENDS.  usrxmemflt only, at two sites: i10r_pre just
| before the wrapper calls usrxmemflt_orig, and i10r_post at the wrapper's single
| exit join.  Both ends are needed because the whole question is what the wrapper
| DID: one hook at the resolved tail (where i10w/i10g ride) can only ever see the
| faults that resolved, so a fault that returned nonzero would leave the block at
| its ship-time zeros -- and reading an instrument's own default back as evidence
| is the exact error section 13 of the ISSUE-10 document had to write down.  The
| exit join is downstream of every path the wrapper has, so the audit fires whatever
| the verdict was.  The kernel wrapper (krnxmemflt) is deliberately NOT hooked: the
| measured frame carries fc = 1, a user-data access, and a narrower instrument is a
| cheaper one to trust.
|
| NESTING.  A fault taken INSIDE the audited fault -- the replay's own byte store is
| the live case -- runs the same wrapper and reaches both hooks.  The pre hook takes
| the latch only if none is pending, so the nested match is counted (i10r_nest_n)
| and ignored; the post hook completes only for the frame pointer the pending latch
| recorded, so a nested exit is counted (i10r_alien_n) and ignored.  The outer fault
| therefore always owns its own audit.
|
| SAFETY AND COST.  Ships dormant: i10r_watchva = 0, so the pre hook is one memory
| test per user fault and the post hook one more, with nothing saved and no call
| made.  Armed, both hooks save and restore d0-d7/a0-a6, so the wrapper's d4 (the
| verdict) and d5 (the preserved FSLW) are untouched, and they save and restore DFC
| and SFC around everything they do -- ptest writes both, and handing ISSUE-22 back
| its victim from a diagnostic would be a poor way to measure a fault path.  User
| memory is read only through i10w_leafpte's resident-or-abandon walk, never by
| dereferencing a user VA.  The raw PTEST is gated on the frame being format 7, so
| it cannot execute on a 68060 (which has no PTEST at all), and i10r_ptest_on = 0
| turns both ptest calls off in one .data long if the extra table search is ever
| suspected of perturbing what it measures -- a 68040 PTEST does load the ATC entry
| it walks, which the stock classifier's own ptest does microseconds later anyway.
|
| ONE READING TRAP, for anyone comparing this block with the i10w one: PART THREE's
| latch records WBxS with `moveb %a2@(78)`, which takes the UPPER byte of the status
| WORD at +78 -- all the status bits (valid, size, TM) live in the lower byte, so
| that field reads 0 whatever the CPU pushed.  This unit reads the WORD, which is
| what wb040_replay's own validity test consumes.  i10w_w3s and i10r_pre_w3s are
| therefore not comparable, and only the second one answers "was there a pending
| write-back".
| ===========================================================================

	.text
	.balign 4

| ---------------------------------------------------------------------------
| i10r_readtgt -- %d0 = a user VA.  Returns %d0 = its leaf PTE (0 = not resident,
| in which case %d1 = 0 too) and %d1 = the longword living at that VA, read
| through the frame rather than by dereferencing the VA.  Clobbers d0/d1/d2/a0/a1
| (i10w_leafpte preserves d2 across itself, which is why the VA can live there).
i10r_readtgt:
	movel	%d0,%d2			| d2 = the VA, live across the walk
	bsrw	i10w_leafpte		| d0 = VA -> a0 = &leafPTE, or a0 = 0
	movel	%a0,%d0
	beqs	Lir_rt_no
	movel	%a0@,%d0		| d0 = the leaf PTE -- the return value
	movel	%d0,%d1
	andil	&0xfffff000,%d1		| its frame's physical base (low RAM is identity-mapped)
	andil	&0xfff,%d2
	addl	%d2,%d1			| + the VA's offset in the page
	moveal	%d1,%a1
	movel	%a1@,%d1		| d1 = the longword itself
	rts
Lir_rt_no:
	moveq	&0,%d0
	moveq	&0,%d1
	rts

| ---------------------------------------------------------------------------
| i10r_doptest -- %d0 = a user VA.  Returns %d0 = ptest's 030-form PSR (the exact
| value the stock classifier branches on, from the exact routine it calls) and
| %d1 = the RAW 68040 MMUSR for the same VA.  Both read 0 when i10r_ptest_on is 0.
| Clobbers d0/d1/d2/a0/a1.  DFC/SFC are saved and restored by the CALLING hook.
i10r_doptest:
	tstl	i10r_ptest_on
	beqs	Lir_pt_off
	movel	%d0,%sp@-		| ptest(va) -- the argument slot doubles as the
	jsr	ptest			| VA's storage across the call, so no register
	movel	%d0,%d1			| d1 = the 030-form PSR
	movel	%sp@+,%d0		| d0 = the VA again
| The raw 040 MMUSR carries what the 030-form result throws away: R (resident),
| W (write-protected), M (modified) and B (bus error on the table search).  A
| 68060 has no PTEST instruction, so this is reached only through the format-7
| gate in the hooks; the cputype test is the same belt-and-braces ptest040.s uses.
	movel	cputype,%d2
	cmpil	&60,%d2
	beqs	Lir_pt_no60
	moveal	%d0,%a0			| a0 = the VA
	moveq	&1,%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc -- the 040 PTEST takes its FC from DFC
	.word	0xf568			| ptestr (%a0)
	.word	0x4e7a,0x0805		| movec %mmusr,%d0
	movel	%d0,%d2			| d2 = the raw MMUSR
	movel	%d1,%d0			| d0 = the 030-form PSR
	movel	%d2,%d1			| d1 = the raw MMUSR
	rts
Lir_pt_no60:
	movel	%d1,%d0			| 68060: the 030-form result only
	moveq	&0,%d1
	rts
Lir_pt_off:
	moveq	&0,%d0
	moveq	&0,%d1
	rts

| ---------------------------------------------------------------------------
| i10r_decode -- DERIVED, and labelled as such everywhere it is read.
|
| Per write-back slot, what wb040_replay's own gating would make of the frame this
| audit latched: bit 7 of the status WORD is the valid bit, and a WB2 whose SIZE
| field is 3 (LINE, a MOVE16 residue) is skipped by name.
|     0 = not valid           -> the replay passes the slot over
|     1 = valid               -> the replay would re-issue this store
|     2 = valid, SIZE = LINE  -> the replay skips it by rule (WB2 only)
| What the replay ACTUALLY did is i10r_wb_d, measured from wb_replay_n.  Keeping
| the two apart is the whole point: "the frame said there was a store to land" and
| "a store was landed" are different claims and this unit must not merge them.
|
| i10r_branch is the stock classifier's own choice, decoded from the ptest result
| and the SSW exactly as src/usrxmemflt040-design.md maps them for THIS kernel
| (with the 5af14 and 5b050 byte patches, which read the 040 SSW bit 8: 1 = read):
|     1 = 030 B  (0x8000) -> 5af6e, SIGSEGV err 9
|     2 = 030 S  (0x2000) -> 5af8c, err 11
|     3 = 030 L|I(0x4400) -> 5afb2 SET -> the F_INVAL demand path at 5aff6
|     4 = 030 W  (0x0800) + a WRITE -> 5b040/5b050 -> as_fault(F_PROT)
|     5 = 030 W  (0x0800) + a READ  -> 5b0f2 hardbus
|     6 = no fault bits at all      -> 5b0f2 hardbus, with nothing to resolve
| Clobbers d0/d1.
i10r_decode:
	clrl	i10r_dec1
	clrl	i10r_dec2
	clrl	i10r_dec3
	movel	i10r_pre_w1s,%d0
	btst	&7,%d0
	beqs	Lir_dc2
	movel	&1,i10r_dec1
Lir_dc2:
	movel	i10r_pre_w2s,%d0
	btst	&7,%d0
	beqs	Lir_dc3
	movel	%d0,%d1
	lsrl	&5,%d1
	andil	&3,%d1			| SIZE: 0 = long, 1 = byte, 2 = word, 3 = line
	cmpil	&3,%d1
	bnes	Lir_dc2v
	movel	&2,i10r_dec2
	bras	Lir_dc3
Lir_dc2v:
	movel	&1,i10r_dec2
Lir_dc3:
	movel	i10r_pre_w3s,%d0
	btst	&7,%d0
	beqs	Lir_dcb
	movel	&1,i10r_dec3
Lir_dcb:
	clrl	i10r_branch
	movel	i10r_pt_pre,%d0
	movel	%d0,%d1
	andil	&0x8000,%d1
	beqs	Lir_db_s
	movel	&1,i10r_branch
	rts
Lir_db_s:
	movel	%d0,%d1
	andil	&0x2000,%d1
	beqs	Lir_db_li
	movel	&2,i10r_branch
	rts
Lir_db_li:
	movel	%d0,%d1
	andil	&0x4400,%d1
	beqs	Lir_db_w
	movel	&3,i10r_branch
	rts
Lir_db_w:
	movel	%d0,%d1
	andil	&0x0800,%d1
	beqs	Lir_db_hb
	movel	i10r_pre_ssw,%d1
	btst	&8,%d1			| SSW bit 8: 1 = a READ access
	bnes	Lir_db_hbr
	movel	&4,i10r_branch
	rts
Lir_db_hbr:
	movel	&5,i10r_branch
	rts
Lir_db_hb:
	movel	&6,i10r_branch
	rts

| ---------------------------------------------------------------------------
| i10r_pre(frame) -- called from usrxmemflt AFTER the DFC/SFC save and the fmt-4
| SSW synthesis, BEFORE usrxmemflt_orig runs.  Dormant until i10r_watchva is
| kpoked to the address to audit.  Takes the latch for the first user fault on
| that address whose access class matches i10r_rwsel.
	.globl	i10r_pre
i10r_pre:
	tstl	i10r_watchva
	beqw	Lir_pre_ret		| dormant: one memory test, nothing saved
	linkw	%fp,&0
	moveml	%d0-%d7/%a0-%a6,%sp@-	| preserve the wrapper's d4/d5 and everything else
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%d6			| d6 = the caller's DFC, restored at the exit
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%d0,%d7			| d7 = the caller's SFC
	moveal	%fp@(8),%a2		| a2 = the frame, as the WRAPPER received it
	moveq	&0,%d0
	moveb	%a2@(70),%d0
	lsrb	&4,%d0
	cmpiw	&7,%d0
	bnew	Lir_pre_out		| not a 68040 format-7 access-error frame: no WBs
	addql	&1,i10r_seen_n		| UNCAPPED: format-7 user faults seen while armed
	tstl	i10r_latched
	bnew	Lir_pre_out		| the audit is complete: one fault, once
	movel	%a2@(84),%d0		| FA, as the CPU reported it
	andl	i10r_famask,%d0
	cmpl	i10r_watchva,%d0
	bnew	Lir_pre_out		| not the address under audit
	moveq	&0,%d1
	movew	%a2@(76),%d1		| SSW: bit 8 set = a READ access
	movel	i10r_rwsel,%d0
	cmpil	&2,%d0
	bccs	Lir_pre_cls		| 2 = either class will do
	btst	&8,%d1
	bnes	Lir_pre_rd
	tstl	%d0			| a WRITE: wanted only when rwsel = 0
	bnew	Lir_pre_out
	bras	Lir_pre_cls
Lir_pre_rd:
	cmpil	&1,%d0			| a READ: wanted only when rwsel = 1
	bnew	Lir_pre_out
Lir_pre_cls:
	addql	&1,i10r_match_n
	tstl	i10r_pend
	beqs	Lir_pre_take
	addql	&1,i10r_nest_n		| a fault nested inside the audited one (the replay's
	braw	Lir_pre_out		| own byte store is the live case): the outer owns it
Lir_pre_take:
	movel	%fp@(8),i10r_frame	| the frame POINTER value, not its contents
	moveq	&0,%d0
	movew	%a2@(70),%d0
	movel	%d0,i10r_fmtvec
	moveq	&0,%d0
	movew	%a2@(64),%d0		| SR: bit 13 (0x2000) = S -> a supervisor fault
	movel	%d0,i10r_pre_sr
	movel	%a2@(66),i10r_pre_pc
	movel	%a2@(84),i10r_pre_fa
	moveq	&0,%d0
	movew	%a2@(76),%d0
	movel	%d0,i10r_pre_ssw
| The write-back fields, read at the offsets and in the WIDTHS wb040_replay uses:
| the status is a WORD (its valid bit is bit 7 of the low byte), the address and
| data are longs.  These are the fields the emulator's own WB7 line prints, so a
| disagreement between the two is directly visible.
	moveq	&0,%d0
	movew	%a2@(78),%d0
	movel	%d0,i10r_pre_w3s
	movel	%a2@(88),i10r_pre_w3a
	movel	%a2@(92),i10r_pre_w3d
	moveq	&0,%d0
	movew	%a2@(80),%d0
	movel	%d0,i10r_pre_w2s
	movel	%a2@(96),i10r_pre_w2a
	movel	%a2@(100),i10r_pre_w2d
	moveq	&0,%d0
	movew	%a2@(82),%d0
	movel	%d0,i10r_pre_w1s
	movel	%a2@(104),i10r_pre_w1a
	movel	%a2@(108),i10r_pre_w1d
	moveal	%a2,%a0			| the 16 saved registers, frame+0..+60:
	lea	i10r_r0,%a1		| d0-d7, a0-a6, supervisor a7 -- the register file
	moveq	&15,%d1			| of the instruction that faulted
Lir_pre_lr:
	movel	%a0@+,%a1@+
	dbra	%d1,Lir_pre_lr
	movel	curproc,i10r_proc
	movel	wb_replay_n,i10r_wbrep_pre	| the counters this fault is measured against
	movel	wbf_fail_n,i10r_wbfail_pre
	movel	wbf_signal_n,i10r_wbsig_pre
	movel	x60_siginfo_n,i10r_x60sig_pre
	movel	%a2@(84),%d0		| the target, BEFORE the resolver has run
	bsrw	i10r_readtgt
	movel	%d0,i10r_pte_pre
	movel	%d1,i10r_tv_pre
	movel	%a2@(84),%d0		| and what ptest says about it -- the classifier's
	bsrw	i10r_doptest		| own input, from the classifier's own routine
	movel	%d0,i10r_pt_pre
	movel	%d1,i10r_mmusr_pre
	movel	%fp@(8),i10r_pendfp	| the frame pointer the completing exit must match
	movel	&1,i10r_pend
Lir_pre_out:
	movel	%d6,%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc -- ptest writes both function-code
	movel	%d7,%d0			| registers and this file does not get to leave
	.word	0x4e7b,0x0000		| movec %d0,%sfc -- them changed (ISSUE-22)
	moveml	%sp@+,%d0-%d7/%a0-%a6
	unlk	%fp
Lir_pre_ret:
	rts

| ---------------------------------------------------------------------------
| i10r_post(frame, infop, ret) -- called from usrxmemflt's single exit join, after
| the DFC/SFC restore and before the return value is loaded.  Every path the
| wrapper has passes through here, resolved or not, which is the reason the audit
| hooks the exit rather than the resolved tail.
	.globl	i10r_post
i10r_post:
	tstl	i10r_pend
	beqw	Lir_post_ret		| no latch pending: one memory test, nothing saved
	linkw	%fp,&0
	moveml	%d0-%d7/%a0-%a6,%sp@-
	movel	%fp@(8),%d0
	cmpl	i10r_pendfp,%d0
	bnew	Lir_post_alien		| a NESTED wrapper's exit: not the audited fault
	addql	&1,i10r_post_n
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%d6
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%d0,%d7
	moveal	%fp@(8),%a2		| a2 = the same frame the pre hook recorded
| --- the frame as it reads NOW.  Equal to the pre-hook fields unless something
|     between the two rewrote it, which would itself be the finding. ---
	moveq	&0,%d0
	movew	%a2@(76),%d0
	movel	%d0,i10r_post_ssw
	moveq	&0,%d0
	movew	%a2@(78),%d0
	movel	%d0,i10r_post_w3s
	movel	%a2@(88),i10r_post_w3a
	movel	%a2@(92),i10r_post_w3d
	moveq	&0,%d0
	movew	%a2@(80),%d0
	movel	%d0,i10r_post_w2s
	moveq	&0,%d0
	movew	%a2@(82),%d0
	movel	%d0,i10r_post_w1s
| --- the verdict, and what the process will actually be told.  si_signo is the
|     field u_trap selects its fault class from and trapsig queues nothing while
|     it is zero (wb040.s Lu_siginfo documents both), so reading it here is what
|     "no signal was delivered" means mechanically. ---
	movel	%fp@(16),i10r_ret	| d4: the value usrxmemflt is about to return
	moveal	%fp@(12),%a0		| infop, the k_siginfo_t the resolver writes
	movel	%a0@,i10r_sisig
	movel	%a0@(4),i10r_sicode
	movel	%a0@(12),i10r_siaddr
| --- what the write-back replay did.  wb_replay_n counts Lwb_do entries, i.e. one
|     per write-back slot actually re-issued, so the delta across this fault is the
|     number of pending stores the kernel landed -- including any a nested fault's
|     own replay landed, which i10r_nest_n makes visible. ---
	movel	wb_replay_n,i10r_wbrep_post
	movel	wb_replay_n,%d0
	subl	i10r_wbrep_pre,%d0
	movel	%d0,i10r_wb_d
	movel	wbf_fail_n,%d0
	subl	i10r_wbfail_pre,%d0
	movel	%d0,i10r_wbfail_d
	movel	wbf_signal_n,%d0
	subl	i10r_wbsig_pre,%d0
	movel	%d0,i10r_wbsig_d
	movel	x60_siginfo_n,%d0
	subl	i10r_x60sig_pre,%d0
	movel	%d0,i10r_x60sig_d	| nonzero here or in wbsig_d means the wrapper
	movel	wbf_slot,i10r_wbslot	| REPLACED d4 with a signal number, so i10r_ret is
	movel	wbf_addr,i10r_wbf_addr	| then the wrapper's verdict and not the stock
	movel	wbf_wbs,i10r_wbf_wbs	| resolver's; both zero means they are the same
	bsrw	i10r_decode		| DERIVED: the per-slot and classifier decodes
| --- and the state the resolution left behind: the leaf PTE and the watched
|     longword (did anything get mapped, did the store land), and ptest again. ---
	movel	i10r_pre_fa,%d0
	bsrw	i10r_readtgt
	movel	%d0,i10r_pte_post
	movel	%d1,i10r_tv_post
	movel	i10r_pre_fa,%d0
	bsrw	i10r_doptest
	movel	%d0,i10r_pt_post
	movel	%d1,i10r_mmusr_post
	movel	&1,i10r_latched
	clrl	i10r_pend
	movel	%d6,%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc -- give the interrupted code its
	movel	%d7,%d0			| function-code registers back, exactly as the
	.word	0x4e7b,0x0000		| movec %d0,%sfc -- wrapper itself just did
	braw	Lir_post_out
Lir_post_alien:
	addql	&1,i10r_alien_n		| a nested exit while a latch is pending: ignored,
Lir_post_out:				| counted, and the outer exit still completes it
	moveml	%sp@+,%d0-%d7/%a0-%a6
	unlk	%fp
Lir_post_ret:
	rts

	.balign 4

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The i10r block -- read i10r_magic FIRST (a stale address does not fail, it
| returns a plausible number), then 79 longs: `kpeek <i10r_magic address> 79`.
| Everything is a .data long so a run can re-aim the audit with kpoke instead of
| a rebuild, which is the i10p_vmask lesson.
	.globl	i10r_magic
i10r_magic:
	.long	0x49315221		| "I1R!"
| --- knobs ---
	.globl	i10r_watchva
i10r_watchva:
	.long	0			| 0 = DORMANT (ships this way).  kpoke the fault
					| address to audit -- the write that vanishes was
					| measured at user 0x800152A0
	.globl	i10r_famask
i10r_famask:
	.long	0xffffffff		| applied to the frame's FA before the compare:
					| 0xffffffff = that exact address, 0xfffff000 =
					| any fault anywhere in that page
	.globl	i10r_rwsel
i10r_rwsel:
	.long	0			| 0 = audit a WRITE-class fault (SSW bit 8 clear),
					| 1 = a READ-class one, 2 = whichever comes first
	.globl	i10r_ptest_on
i10r_ptest_on:
	.long	1			| 1 = call ptest (and read the raw MMUSR) before and
					| after; 0 = leave all four fields 0 and touch the
					| MMU not at all
| --- counters and latch state ---
	.globl	i10r_seen_n
i10r_seen_n:
	.long	0			| format-7 user faults seen while armed (uncapped)
	.globl	i10r_match_n
i10r_match_n:
	.long	0			| ... of which matched watchva and the access class
	.globl	i10r_nest_n
i10r_nest_n:
	.long	0			| matches skipped because a latch was already pending
	.globl	i10r_alien_n
i10r_alien_n:
	.long	0			| exits seen while pending that belong to another frame
	.globl	i10r_post_n
i10r_post_n:
	.long	0			| completions (1 = the audited fault reached its exit)
	.globl	i10r_pend
i10r_pend:
	.long	0			| 1 between the pre hook's latch and its completion
	.globl	i10r_pendfp
i10r_pendfp:
	.long	0			| the frame pointer that completion must match
	.globl	i10r_latched
i10r_latched:
	.long	0			| 1 once the audit is complete -- read this FIRST after
					| the magic: with it 0, every field below is ship-time
					| state and says nothing about any fault
	.globl	i10r_proc
i10r_proc:
	.long	0			| curproc at the latch (compare with i10p_curproc)
| --- the frame the wrapper was handed ---
	.globl	i10r_frame
i10r_frame:
	.long	0			| the POINTER value (%fp@(8)), not its contents
	.globl	i10r_fmtvec
i10r_fmtvec:
	.long	0			| the format/vector word at +70 (high nibble = 7)
	.globl	i10r_pre_sr
i10r_pre_sr:
	.long	0			| SR; bit 13 (0x2000) = S: set would be a kernel fault
	.globl	i10r_pre_pc
i10r_pre_pc:
	.long	0			| the faulting instruction's PC (one PAST a deferred
					| store: the 040 pushes the write-back separately)
	.globl	i10r_pre_fa
i10r_pre_fa:
	.long	0			| the fault address the CPU reported
	.globl	i10r_pre_ssw
i10r_pre_ssw:
	.long	0			| the special status word: bit 10 ATC, bit 8 read,
					| bits 6-5 size, bits 2-0 TM (1 = user data)
	.globl	i10r_pre_w3s
i10r_pre_w3s:
	.long	0			| WB3 status WORD at +78: bit 7 valid, 6-5 size, 2-0 TM
	.globl	i10r_pre_w3a
i10r_pre_w3a:
	.long	0			| WB3 address -- where the pending store must land
	.globl	i10r_pre_w3d
i10r_pre_w3d:
	.long	0			| WB3 data -- the value it must land there
	.globl	i10r_pre_w2s
i10r_pre_w2s:
	.long	0
	.globl	i10r_pre_w2a
i10r_pre_w2a:
	.long	0
	.globl	i10r_pre_w2d
i10r_pre_w2d:
	.long	0
	.globl	i10r_pre_w1s
i10r_pre_w1s:
	.long	0
	.globl	i10r_pre_w1a
i10r_pre_w1a:
	.long	0
	.globl	i10r_pre_w1d
i10r_pre_w1d:
	.long	0
| --- the same frame at the wrapper's exit: any difference is a rewrite ---
	.globl	i10r_post_ssw
i10r_post_ssw:
	.long	0
	.globl	i10r_post_w3s
i10r_post_w3s:
	.long	0
	.globl	i10r_post_w3a
i10r_post_w3a:
	.long	0
	.globl	i10r_post_w3d
i10r_post_w3d:
	.long	0
	.globl	i10r_post_w2s
i10r_post_w2s:
	.long	0
	.globl	i10r_post_w1s
i10r_post_w1s:
	.long	0
| --- the resolution's verdict, and what the process is told ---
	.globl	i10r_ret
i10r_ret:
	.long	0			| the wrapper's d4 at the exit: 0 = resolved.  Equal to
					| usrxmemflt_orig's own return unless wbsig_d or
					| x60sig_d below is nonzero
	.globl	i10r_sisig
i10r_sisig:
	.long	0			| infop->si_signo -- 0 means NO signal will be posted
	.globl	i10r_sicode
i10r_sicode:
	.long	0			| infop->si_code
	.globl	i10r_siaddr
i10r_siaddr:
	.long	0			| infop->_fault._addr
| --- what the write-back replay actually did ---
	.globl	i10r_wbrep_pre
i10r_wbrep_pre:
	.long	0			| wb_replay_n before the resolver ran
	.globl	i10r_wbrep_post
i10r_wbrep_post:
	.long	0			| ... and at the exit
	.globl	i10r_wb_d
i10r_wb_d:
	.long	0			| the delta: write-back slots RE-ISSUED for this fault.
					| 0 with i10r_dec3 = 1 is the whole question in two
					| numbers -- the frame carried a pending store and the
					| kernel landed none
	.globl	i10r_wbslot
i10r_wbslot:
	.long	0			| wbf_slot at the exit (which slot the last replay took)
	.globl	i10r_wbfail_pre
i10r_wbfail_pre:
	.long	0
	.globl	i10r_wbfail_d
i10r_wbfail_d:
	.long	0			| write-backs permanently DENIED during this fault
	.globl	i10r_wbsig_pre
i10r_wbsig_pre:
	.long	0
	.globl	i10r_wbsig_d
i10r_wbsig_d:
	.long	0			| k_siginfo_t records built for a denied write-back
	.globl	i10r_x60sig_pre
i10r_x60sig_pre:
	.long	0
	.globl	i10r_x60sig_d
i10r_x60sig_d:
	.long	0			| 060 far-page failures translated into a signal
	.globl	i10r_wbf_addr
i10r_wbf_addr:
	.long	0			| wbf_addr at the exit: the denied byte + 1, if any
	.globl	i10r_wbf_wbs
i10r_wbf_wbs:
	.long	0			| wbf_wbs at the exit: the denied slot's status
| --- DERIVED (computed by i10r_decode from the fields above, not observed) ---
	.globl	i10r_dec1
i10r_dec1:
	.long	0			| WB1: 0 = not valid, 1 = would be replayed
	.globl	i10r_dec2
i10r_dec2:
	.long	0			| WB2: 0 / 1 / 2 = valid but SIZE = LINE, skipped
	.globl	i10r_dec3
i10r_dec3:
	.long	0			| WB3: 0 = not valid, 1 = would be replayed
	.globl	i10r_branch
i10r_branch:
	.long	0			| the stock classifier's branch, decoded from
					| i10r_pt_pre and i10r_pre_ssw: 1 = 030 B SIGSEGV,
					| 2 = 030 S, 3 = F_INVAL demand, 4 = F_PROT COW,
					| 5 = hardbus (write-protected, read), 6 = hardbus
					| with no fault bits at all
| --- what the MMU said, before and after ---
	.globl	i10r_pt_pre
i10r_pt_pre:
	.long	0			| ptest's 030-form PSR for the fault address BEFORE
					| the resolver: 0x400 = I (not present), 0x800 = W
					| (write-protected), 0 = resident and writable
	.globl	i10r_pt_post
i10r_pt_post:
	.long	0			| ... and after it.  0x400 both times means the
					| resolution mapped nothing at all
	.globl	i10r_mmusr_pre
i10r_mmusr_pre:
	.long	0			| the RAW 68040 MMUSR before: bit 0 R, bit 2 W,
					| bit 4 M, bit 11 B
	.globl	i10r_mmusr_post
i10r_mmusr_post:
	.long	0			| ... and after
	.globl	i10r_pte_pre
i10r_pte_pre:
	.long	0			| the fault address's leaf PTE before (0 = the walk
					| found no resident leaf, which is what a first touch
					| of a fresh anon page looks like)
	.globl	i10r_pte_post
i10r_pte_post:
	.long	0			| ... and after: still 0 = nothing was mapped
	.globl	i10r_tv_pre
i10r_tv_pre:
	.long	0			| the longword AT the fault address before
	.globl	i10r_tv_post
i10r_tv_post:
	.long	0			| ... and after: equal to i10r_pre_w3d only if the
					| pending store was actually landed
| the 16 saved registers of the faulting instruction, frame+0..+60:
| d0-d7 (r0..r7), a0-a6 (r8..r14), supervisor a7 (r15)
	.globl	i10r_r0
i10r_r0:
	.long	0
	.globl	i10r_r1
i10r_r1:
	.long	0
	.globl	i10r_r2
i10r_r2:
	.long	0
	.globl	i10r_r3
i10r_r3:
	.long	0
	.globl	i10r_r4
i10r_r4:
	.long	0
	.globl	i10r_r5
i10r_r5:
	.long	0
	.globl	i10r_r6
i10r_r6:
	.long	0
	.globl	i10r_r7
i10r_r7:
	.long	0
	.globl	i10r_r8
i10r_r8:
	.long	0
	.globl	i10r_r9
i10r_r9:
	.long	0
	.globl	i10r_r10
i10r_r10:
	.long	0
	.globl	i10r_r11
i10r_r11:
	.long	0
	.globl	i10r_r12
i10r_r12:
	.long	0
	.globl	i10r_r13
i10r_r13:
	.long	0
	.globl	i10r_r14
i10r_r14:
	.long	0
	.globl	i10r_r15
i10r_r15:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement)

| ===========================================================================
| PART SEVEN -- i10s: the SEGVN-FAULTPAGE DECISION AUDIT (2026-08-20).
|
| WHAT PART SIX LEFT OPEN.  i10r proved the marker write fault (fa 0x800152A0,
| proc 0x4013BE00) is classified F_INVAL demand (branch 3, ptest agrees the page
| is absent), that as_fault(F_INVAL, S_WRITE) returned NONZERO, that usrxmemflt
| returned SIGSEGV code 1 (SEGV_MAPERR), and that the pending write-back was then
| dropped.  The decisive contrast is in the same record: five ticks later the
| WALK's own READ fault on the SAME absent page maps and zero-fills it (doc 14.5).
| Two faults of the same class on the same page, differing ONLY in rw -- S_WRITE
| dies, S_READ succeeds.  That localises the defect to segvn_fault's handling of a
| first-touch WRITE demand-fill, and i10r cannot see inside it BY DESIGN: it
| records the classifier branch that CHOOSES as_fault's arguments, not the segvn
| return path (i10r header, "What it does not do").  Doc 16.4/16.6 name the next
| instrument exactly: wrap segvn_fault/segvn_faultpage for this proc+VA and record
| rw, the faultcode returned, and WHICH segvn_faultpage sub-path failed --
| protection (svd->prot / vpage->vp_prot) vs anon/vpage COVERAGE the brk grow did
| not extend vs anon_zero.  This unit is that instrument.
|
| WHERE IT HOOKS, AND WHY AS AN OUTER WRAPPER.  segvn_prot040.s already owns the
| strong segvn_faultpage: it restores SVR4's per-page permission check and, on a
| PASS, tail-jmps segvn_faultpage_orig (the linked kernel body at 0xac01a).  Its
| deny path returns FC_PROT WITHOUT jmping orig, so a hook placed at orig would
| never see a denied write -- and a denied write is the whole question.  So this
| audit is an OUTER tail-call wrapper that takes the segvn_faultpage symbol for
| itself, OBSERVES the arguments read-only, REPLICATES segvn_prot040's per-page
| decision (so it can say what that wrapper is about to return), and then tail-jmps
| the per-page wrapper -- which is reached under the name segvn_faultpage_prot, a
| pure relink rename of segvn_prot040.o (--redefine-sym, the segu_get idiom), so
| segvn_prot040.s itself is UNTOUCHED and stays a standalone upstreamable fix that
| knows nothing about this audit.  The real decision is still segvn_prot040's; this
| wrapper only latches what it sees and what it predicts.  Chain:
|     segvn_faultpage (i10s, here) -> segvn_faultpage_prot (segvn_prot040.s)
|                                  -> segvn_faultpage_orig (0xac01a, stock body)
|
| ARMING AND MATCHING.  The ARM gate is i10s_watchva: 0 ships dormant, a kpoked VA
| arms it.  A call MATCHES when (addr & i10s_watchmask) == i10s_watchva AND
| rw == i10s_watchrw (default S_WRITE), AND EITHER i10s_watchproc == 0 (any process,
| the default) OR curproc == i10s_watchproc.  The process is deliberately NOT the
| primary key.  A proc pointer is a proc-table slot the wall's sh lands in DIFFERENTLY
| every boot: the first bench run keyed on 0x4013BE00 (PID 9's slot from an earlier
| kernel) and its filter never matched a boot whose wall-sh was PID 40, returning a
| null that was a measurement-setup error and not a finding.  So the VA the marker
| write targets (0x800152A0, specific to the arena-growing sh) is the stable key and
| the proc filter is an optional narrowing.  i10s_vamatch_n counts VA+rw matches
| REGARDLESS of proc, so even a proc-filtered or never-latching run separates "the
| fault reached segvn_faultpage at this VA" from "it never got here": vamatch_n = 0
| while the wall demonstrably fired means as_fault failed UPSTREAM, in the segment
| lookup, before segvn_faultpage was ever called (consistent with i10r's SEGV_MAPERR
| reading = no segment covers the address), and the next probe targets as_fault /
| as_segat instead.
|
| WHAT IT CAPTURES, once, on the first matching call:
|   * rw, the seg pointer, seg->s_base / seg->s_size (so the vpage/anon index range
|     can be checked offline), and svd = seg->s_data;
|   * svd->pageprot (@2) and svd->prot (@3) -- pageprot == 0 says the per-page path
|     is not even entered and any denial is segment-wide (or downstream in anon);
|   * the vpage pointer for this page (arg5), its raw byte, and the decoded vp_prot
|     nibble (top nibble, the bfextu 0,4 segvn_prot040 uses);
|   * protchk for this rw (the exact switch: S_READ->1, S_WRITE->2, S_EXEC->4,
|     else 7), the (vp_prot & protchk) value, and whether that is zero (denied);
|   * whether segvn_prot040's FC_PROT return is TAKEN -- computed by replicating its
|     own guard exactly (pageprot != 0 AND vpage != 0 AND (vp_prot & protchk) == 0)
|     -- and the value it returns on that path (4 = FC_PROT, or -1 = falls through
|     to segvn_faultpage_orig, verdict decided downstream);
|   * the first 16 longs of svd.  The anon-map slot / anon_zero decision is NOT
|     decoded in-kernel: it needs segvn_data's amp/anon_index offsets and the
|     anon_map/ahp layout, none of which is confirmed against this binary, and a
|     diagnostic that dereferences an unverified offset is how a probe panics the
|     machine it was added to measure.  Dumping svd instead makes coverage-vs-
|     protection separable OFFLINE (kpeek the raw block, decode against the headers)
|     without a single guessed dereference -- the i10p_vmask lesson, applied to a
|     struct instead of a mask.
|
| CROSS-CHECK BUILT IN.  segvn_prot040 keeps its OWN counters (segvn_prot_pp_n,
| segvn_prot_n, segvn_prot_last_addr/last_prot).  If i10s_fcprot latches 1 for this
| address, segvn_prot_n must have incremented and segvn_prot_last_addr must equal
| i10s_addr -- two independent readings of the same decision, one predicted here and
| one recorded by the code that actually makes it.
|
| SAFETY AND COST.  Ships dormant: i10s_watchva = 0, so the wrapper is one tstl
| plus the tail jmp on every segvn_faultpage call until it is armed with a kpoke.
| Armed, it saves and restores d0-d7/a0-a6 across the latch, so the ABI is
| undisturbed: d0/d1/a0/a1 are scratch in the frameless-tail-call ABI segvn_prot040
| documents, the caller expects d0 to be the faultcode segvn_faultpage_prot loads,
| and d2-d7/a2-a6 are handed back untouched.  It reads only KERNEL memory (the seg,
| svd and vpage structs, curproc, the u-area) -- never a user VA, no ptest, no MMU
| poke -- so no DFC/SFC dance is needed.  vpage is checked for NULL before it is
| dereferenced, exactly as segvn_prot040 checks it; seg and svd are trusted the same
| way segvn_prot040 trusts them, and the latch fires only for the one watched fault.
| ===========================================================================

	.text
	.balign 4

| ---------------------------------------------------------------------------
| segvn_faultpage -- the i10s outer wrapper.  Frameless-tail-call ABI (see
| segvn_prot040.s): sp@(0) = return address, argument N at sp@(4N).  A linkw frame
| then puts arg1 at fp@(8) and argN at fp@(8+4(N-1)); the arguments this audit
| reads are seg = arg1 (fp@8), addr = arg2 (fp@12), vpage = arg5 (fp@24),
| rw = arg9 (fp@40).
	.globl	segvn_faultpage
segvn_faultpage:
	tstl	i10s_watchva
	bnew	Lis_maybe		| armed (watchva != 0): rare -- check the gate
Lis_tail:
	jmp	segvn_faultpage_prot	| dormant OR done: the per-page wrapper decides
Lis_maybe:
	tstl	i10s_latched
	bnew	Lis_tail		| one-shot: the audit is already complete
	addql	&1,i10s_seen_n		| UNCAPPED: segvn_faultpage calls seen while armed
| --- VA + rw match FIRST, proc-independent: this is the stable key.  (d0/d1 scratch.)
	movel	%sp@(8),%d0		| arg2 = the fault address
	andl	i10s_watchmask,%d0
	cmpl	i10s_watchva,%d0
	bnew	Lis_tail		| not the watched address / page
	movel	%sp@(36),%d0		| arg9 = rw
	cmpl	i10s_watchrw,%d0
	bnew	Lis_tail		| not the watched access class (default S_WRITE)
	addql	&1,i10s_vamatch_n	| VA + rw matched, REGARDLESS of proc: the fault
					| DID reach segvn_faultpage at this address
| --- proc filter, OPTIONAL: watchproc 0 = any process (the default); else this one.
	movel	i10s_watchproc,%d1
	beqs	Lis_take		| watchproc 0 = any proc -> take it
	movel	curproc,%d0
	cmpl	%d1,%d0
	bnew	Lis_tail		| watchproc set and curproc differs -> skip
Lis_take:
	addql	&1,i10s_match_n
| --- MATCH: latch the decision once.  Build a frame so every callee-saved register
|     is handed back untouched; segvn_faultpage_prot reloads all args from the stack
|     and treats d0/d1/a0/a1 as scratch, so the tail jmp after unlk is exact. ---
	linkw	%fp,&0
	moveml	%d0-%d7/%a0-%a6,%sp@-
	movel	curproc,i10s_proc
	movel	u+0x1c0,i10s_comm0	| u_comm: the command must read "sh"
	movel	u+0x1c4,i10s_comm1
	movel	u+0x1c8,i10s_comm2
	movel	u+0x1cc,i10s_comm3
	movel	%fp@(12),i10s_addr	| arg2 = the denied fault address
	movel	%fp@(40),i10s_rw	| arg9 = rw
	moveal	%fp@(8),%a0		| arg1 = seg
	movel	%a0,i10s_seg
	movel	%a0@(4),i10s_segbase	| seg->s_base
	movel	%a0@(8),i10s_segsize	| seg->s_size
	moveal	%a0@(28),%a1		| svd = seg->s_data
	movel	%a1,i10s_svd
	moveq	&0,%d0
	moveb	%a1@(2),%d0		| svd->pageprot (0 => per-page path not entered)
	movel	%d0,i10s_pageprot
	moveq	&0,%d0
	moveb	%a1@(3),%d0		| svd->prot (segment-wide protection)
	movel	%d0,i10s_prot
| the first 16 longs of svd, for OFFLINE anon-map/vpage-coverage decode
	moveal	%a1,%a0
	lea	i10s_svd0,%a1
	moveq	&15,%d1
Lis_svd:
	movel	%a0@+,%a1@+
	dbra	%d1,Lis_svd
| the vpage pointer for this page (arg5), its byte and decoded vp_prot nibble
	moveal	%fp@(24),%a0		| arg5 = vpage
	movel	%a0,i10s_vpage
	moveq	&0,%d1
	movel	%a0,%d0
	beqs	Lis_novp		| vpage NULL: leave vpbyte / vpprot 0
	moveq	&0,%d1
	moveb	%a0@,%d1		| the vpage byte
	movel	%d1,i10s_vpbyte
	lsrl	&4,%d1			| vp_prot = its TOP nibble (bfextu 0,4)
	andil	&0x0f,%d1
Lis_novp:
	movel	%d1,i10s_vpprot		| 0 when vpage is NULL
| protchk from rw -- the exact switch segvn_prot040 computes
	movel	i10s_rw,%d0
	moveq	&7,%d1			| default = PROT_READ|PROT_WRITE|PROT_EXEC
	cmpil	&1,%d0
	bnes	Lis_nrd
	moveq	&1,%d1			| S_READ  -> PROT_READ
	bras	Lis_pk
Lis_nrd:
	cmpil	&2,%d0
	bnes	Lis_nwr
	moveq	&2,%d1			| S_WRITE -> PROT_WRITE
	bras	Lis_pk
Lis_nwr:
	cmpil	&3,%d0
	bnes	Lis_pk
	moveq	&4,%d1			| S_EXEC  -> PROT_EXEC
Lis_pk:
	movel	%d1,i10s_protchk
	movel	i10s_vpprot,%d0
	andl	%d1,%d0			| vp_prot & protchk -- the value the check branches on
	movel	%d0,i10s_andval
	moveq	&0,%d0
	tstl	i10s_andval
	bnes	Lis_setd
	moveq	&1,%d0			| (vp_prot & protchk) == 0: the check would deny
Lis_setd:
	movel	%d0,i10s_denied
| whether segvn_prot040's FC_PROT return is TAKEN -- its own guard, replicated:
|   Lsp_pass (no FC_PROT) if pageprot == 0, or vpage == 0, or (vp_prot & protchk)!=0
|   else return FC_PROT (moveq #4).
	clrl	i10s_fcprot
	movel	&-1,i10s_retval		| -1 = falls through to segvn_faultpage_orig
	tstl	i10s_pageprot
	beqs	Lis_done		| pageprot 0: per-page path not entered -> pass
	tstl	i10s_vpage
	beqs	Lis_done		| vpage 0: defensive pass
	tstl	i10s_denied
	beqs	Lis_done		| permitted -> pass
	movel	&1,i10s_fcprot		| the per-page wrapper WILL return FC_PROT here
	movel	&4,i10s_retval		| FC_PROT = 4 (vm/faultcode.h)
Lis_done:
	movel	&1,i10s_latched
	moveml	%sp@+,%d0-%d7/%a0-%a6
	unlk	%fp
	braw	Lis_tail		| hand off: segvn_faultpage_prot makes the REAL decision

	.balign 4

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The i10s block -- read i10s_magic FIRST (a stale address does not fail, it
| returns a plausible number), then 46 longs: `kpeek <i10s_magic address> 46`.
| Everything is a .data long so a run can re-aim the audit with kpoke instead of a
| rebuild, the i10p_vmask lesson.
	.globl	i10s_magic
i10s_magic:
	.long	0x49315321		| "I1S!"
| --- knobs ---
	.globl	i10s_watchproc
i10s_watchproc:
	.long	0			| the OPTIONAL proc filter: 0 = ANY process (ships this
					| way), nonzero = only that curproc.  Do NOT set this to
					| a proc pointer for cross-boot work -- the wall's sh
					| occupies a different proc-table slot each boot, so a
					| pinned pointer (e.g. 0x4013BE00 from one boot) matches
					| nothing on the next.  VA + rw is the stable key.
	.globl	i10s_watchva
i10s_watchva:
	.long	0			| 0 = DORMANT (ships this way): watchva is the ARM gate.
					| kpoke the address to audit; compared as
					| (addr & watchmask) == watchva.  The marker write that
					| vanishes was measured at user 0x800152A0 -- arm with
					| 0x80015000 and watchmask 0xfffff000 to take its page.
	.globl	i10s_watchmask
i10s_watchmask:
	.long	0xfffff000		| 0xfffff000 = any fault in that page, 0xffffffff = the
					| exact address
	.globl	i10s_watchrw
i10s_watchrw:
	.long	2			| the access class to audit: 1 = S_READ, 2 = S_WRITE
					| (the marker store), 3 = S_EXEC
| --- counters and latch state ---
	.globl	i10s_seen_n
i10s_seen_n:
	.long	0			| segvn_faultpage calls seen while armed (uncapped)
	.globl	i10s_match_n
i10s_match_n:
	.long	0			| ... of which matched VA + rw AND the proc filter
	.globl	i10s_vamatch_n
i10s_vamatch_n:
	.long	0			| ... which matched VA + rw REGARDLESS of proc.  vamatch_n
					| > 0 with match_n 0 = a proc filter rejected them; but
					| vamatch_n == 0 while the wall demonstrably fired means
					| the fatal write NEVER reached segvn_faultpage, i.e.
					| as_fault failed upstream in the segment lookup
	.globl	i10s_latched
i10s_latched:
	.long	0			| 1 once the audit is complete -- read this FIRST after
					| the magic: with it 0, every field below is ship-time
					| state and says nothing about any fault
	.globl	i10s_proc
i10s_proc:
	.long	0			| curproc at the latch (equals i10s_watchproc when the
					| proc filter is set; the real proc when it is 0 = any)
	.globl	i10s_comm0
i10s_comm0:
	.long	0			| u_comm, 16 bytes: the command running (expect "sh")
	.globl	i10s_comm1
i10s_comm1:
	.long	0
	.globl	i10s_comm2
i10s_comm2:
	.long	0
	.globl	i10s_comm3
i10s_comm3:
	.long	0
| --- the captured decision ---
	.globl	i10s_addr
i10s_addr:
	.long	0			| arg2: the fault address segvn_faultpage received
	.globl	i10s_rw
i10s_rw:
	.long	0			| arg9: rw (1 S_READ, 2 S_WRITE, 3 S_EXEC)
	.globl	i10s_seg
i10s_seg:
	.long	0			| arg1: the struct seg pointer
	.globl	i10s_segbase
i10s_segbase:
	.long	0			| seg->s_base -- with s_size, bounds the vpage/anon index
	.globl	i10s_segsize
i10s_segsize:
	.long	0			| seg->s_size
	.globl	i10s_svd
i10s_svd:
	.long	0			| svd = seg->s_data (segvn_data)
	.globl	i10s_pageprot
i10s_pageprot:
	.long	0			| svd->pageprot @2: 0 = per-page path NOT entered
	.globl	i10s_prot
i10s_prot:
	.long	0			| svd->prot @3: segment-wide protection (bit1 = WRITE)
	.globl	i10s_vpage
i10s_vpage:
	.long	0			| arg5: the vpage pointer for this page (0 = none)
	.globl	i10s_vpbyte
i10s_vpbyte:
	.long	0			| the raw vpage byte (0 when vpage is NULL)
	.globl	i10s_vpprot
i10s_vpprot:
	.long	0			| vp_prot: the byte's TOP nibble (bfextu 0,4)
	.globl	i10s_protchk
i10s_protchk:
	.long	0			| protchk from rw: S_READ 1, S_WRITE 2, S_EXEC 4, else 7
	.globl	i10s_andval
i10s_andval:
	.long	0			| vp_prot & protchk -- the value the check branches on
	.globl	i10s_denied
i10s_denied:
	.long	0			| 1 if (vp_prot & protchk) == 0 (the per-page check denies)
	.globl	i10s_fcprot
i10s_fcprot:
	.long	0			| 1 if segvn_prot040's FC_PROT return is TAKEN (pageprot
					| != 0 AND vpage != 0 AND denied); 0 = it passes through
	.globl	i10s_retval
i10s_retval:
	.long	0			| the value the per-page wrapper returns on this path:
					| 4 = FC_PROT, -1 = falls through to segvn_faultpage_orig
| the first 16 longs (64 bytes) of svd, for OFFLINE anon-map / vpage-coverage
| decode against the segvn_data layout -- no field offset is guessed in-kernel
	.globl	i10s_svd0
i10s_svd0:
	.long	0
	.globl	i10s_svd1
i10s_svd1:
	.long	0
	.globl	i10s_svd2
i10s_svd2:
	.long	0
	.globl	i10s_svd3
i10s_svd3:
	.long	0
	.globl	i10s_svd4
i10s_svd4:
	.long	0
	.globl	i10s_svd5
i10s_svd5:
	.long	0
	.globl	i10s_svd6
i10s_svd6:
	.long	0
	.globl	i10s_svd7
i10s_svd7:
	.long	0
	.globl	i10s_svd8
i10s_svd8:
	.long	0
	.globl	i10s_svd9
i10s_svd9:
	.long	0
	.globl	i10s_svd10
i10s_svd10:
	.long	0
	.globl	i10s_svd11
i10s_svd11:
	.long	0
	.globl	i10s_svd12
i10s_svd12:
	.long	0
	.globl	i10s_svd13
i10s_svd13:
	.long	0
	.globl	i10s_svd14
i10s_svd14:
	.long	0
	.globl	i10s_svd15
i10s_svd15:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement)

| ===========================================================================
| PART EIGHT -- i10a: the as_fault-level AUDIT (2026-08-20).
|
| WHAT PART SEVEN SETTLED.  i10s armed on the VA (proc filter off) and its run was
| decisive: the wall fired (BUS ERROR 4AFC0003 flood, PID 41) but i10s_vamatch_n = 0
| with i10s_seen_n = 663 -- the marker WRITE fault at 0x800152A0 NEVER reaches
| segvn_faultpage.  The per-page protection restorer (segvn_prot040) is exonerated.
| The refusal is one level UP, in as_fault: as_segat finds no segment covering the
| address, and as_fault returns FC_PROT's neighbour FC_NOMAP.  This is not inference
| -- it is in the stock body: as_fault (0xae108) calls as_segat (0xadefc); a NULL
| return takes the `moveq #3` at as_fault+0x7a, and 3 = FC_NOMAP, which u_trap maps to
| SEGV_MAPERR (sicode 1 -- exactly what i10r measured).  The guest's own "no space"
| is Bourne sh's setbrk reporting brk() failed, so the arena GROW / segment machinery
| is implicated.  This unit audits that decision from inside as_fault.
|
| WHERE IT HOOKS, AND WHY A CALL-AND-RETURN WRAPPER.  as_fault is stock (not wrapped),
| so this takes the as_fault symbol by the segu_get/segvn_faultpage relink idiom
| (--weaken-symbol as_fault + --add-symbol as_fault_orig = 0xae108) and provides a
| strong as_fault here.  Unlike i10s -- which only needed the ARGUMENTS and so could
| tail-jmp -- this audit wants as_fault's RETURN CODE (was it FC_NOMAP?) and whether a
| covering segment appears during resolution, so on the one matched fault it CALLS
| as_fault_orig (re-pushing the 5 args unchanged) and records d0.  as_segat is a pure
| lookup (the stock body caches as->a_seglast and has no other side effect), so this
| calls it directly -- once before as_fault_orig (is there a segment now?) and once
| after (did one appear?) -- without perturbing the resolution.
|
| WHAT IT CAPTURES, once, on the first call matching (addr & i10a_watchmask) ==
| i10a_watchva AND rw == i10a_watchrw (default S_WRITE), with the proc filter
| i10a_watchproc OPTIONAL (0 = any process, the default -- the i10s lesson: a proc
| pointer is a table slot the wall's sh lands in differently each boot, so VA + rw is
| the stable key, and i10a_vamatch_n counts VA+rw matches regardless of proc):
|   * as_fault's own arguments -- the address space (arg1), addr (arg2), type (arg4:
|     F_INVAL 1 / F_PROT 2 / ...), rw (arg5);
|   * the as_segat result for the page BEFORE resolution (i10a_seg: 0 = NO covering
|     segment, which is the FC_NOMAP cause) and, if found, the seg's s_base/s_size --
|     so "no segment" vs "segment too short to cover the address" is separable;
|   * the as's segment-list head (a_segs @4, a_seglast @8) for offline decode;
|   * the process BREAK extent as brk keeps it -- u.u_procp's p_brkbase (@52),
|     p_brksize (@56) and their sum (the current break), plus p_as (@124).  This is
|     what makes "brk did not grow the segment" (break < addr) directly readable
|     against "brk grew but the lookup misses" (break >= addr yet as_segat NULL);
|   * as_fault's ACTUAL return code (i10a_ret: 3 = FC_NOMAP), and the as_segat result
|     AFTER resolution (i10a_seg_post) -- did a segment appear during the fault?
|
| SAFETY AND COST.  Ships dormant: i10a_watchva = 0, so every as_fault call pays one
| tstl and a tail jmp to as_fault_orig -- the shape i10s already proved does not mask
| the wall.  Armed, non-matching faults pay one gate compare and the same tail jmp;
| only the single matched fault builds a frame, and it saves/restores d2-d7/a2-a6 and
| returns as_fault_orig's own d0, so the ABI is exact (d0/d1/a0/a1 are scratch in this
| ABI; d0 is the faultcode the caller reads).  i10a_busy guards against re-entry from
| a fault taken inside as_fault_orig.  It reads only kernel memory (the as/seg structs,
| the proc, the u-area) and calls only the stock as_segat and as_fault_orig -- no user
| dereference, no MMU poke.
| ===========================================================================

	.text
	.balign 4

| ---------------------------------------------------------------------------
| as_fault -- the i10a outer wrapper.  Frameless entry: sp@(0) = return address,
| argument N at sp@(4N) (as_fault(as, addr, size, type, rw), confirmed from the stock
| prologue at 0xae108).  A linkw frame puts arg1 at fp@(8), argN at fp@(8+4(N-1)).
	.globl	as_fault
as_fault:
	tstl	i10a_watchva
	bnew	Lia_maybe		| armed (watchva != 0): rare -- check the gate
Lia_fwd:
	jmp	as_fault_orig		| dormant / no match / done: forward unchanged
Lia_maybe:
	tstl	i10a_latched
	bnew	Lia_fwd			| one-shot: the audit is complete
	tstl	i10a_busy
	bnew	Lia_fwd			| inside our own as_fault_orig call: do not re-enter
	addql	&1,i10a_seen_n		| UNCAPPED: as_fault calls seen while armed
	movel	%sp@(8),%d0		| arg2 = addr
	andl	i10a_watchmask,%d0
	cmpl	i10a_watchva,%d0
	bnew	Lia_fwd			| not the watched address / page
	movel	%sp@(20),%d0		| arg5 = rw
	cmpl	i10a_watchrw,%d0
	bnew	Lia_fwd			| not the watched access class (default S_WRITE)
	addql	&1,i10a_vamatch_n	| VA + rw matched, REGARDLESS of proc
	movel	i10a_watchproc,%d1
	beqs	Lia_take		| watchproc 0 = any proc -> take it
	movel	curproc,%d0
	cmpl	%d1,%d0
	bnew	Lia_fwd			| watchproc set and curproc differs -> skip
Lia_take:
	addql	&1,i10a_match_n
	linkw	%fp,&0
	moveml	%d2-%d7/%a2-%a6,%sp@-	| callee-saved; d0/d1/a0/a1 scratch, d0 = our return
| --- identity ---
	movel	curproc,i10a_proc
	movel	u+0x1c0,i10a_comm0	| u_comm: the command must read "sh"
	movel	u+0x1c4,i10a_comm1
	movel	u+0x1c8,i10a_comm2
	movel	u+0x1cc,i10a_comm3
| --- as_fault's own arguments ---
	movel	%fp@(12),i10a_addr	| arg2 = the faulting address
	movel	%fp@(20),i10a_type	| arg4 = fault type (1 = F_INVAL, 2 = F_PROT)
	movel	%fp@(24),i10a_rw	| arg5 = rw
	movel	%fp@(8),i10a_as		| arg1 = the address space
| --- as_segat(as, pagebase) BEFORE the resolver: is there a covering segment? ---
	movel	i10a_addr,%d0
	andil	&0xfffff000,%d0		| page base, as_fault's own rounding (andiw #-4096)
	movel	%d0,%sp@-		| push addr (page base)
	movel	%fp@(8),%sp@-		| push as
	jsr	as_segat
	addqw	&8,%sp
	movel	%d0,i10a_seg		| 0 = NO covering segment -> the FC_NOMAP cause
	tstl	%d0
	beqs	Lia_noseg
	moveal	%d0,%a0
	movel	%a0@(4),i10a_segbase	| seg->s_base
	movel	%a0@(8),i10a_segsize	| seg->s_size  (s_base + s_size <= addr = too short)
Lia_noseg:
	moveal	%fp@(8),%a0		| the as's segment-list head, for offline decode
	movel	%a0@(4),i10a_a_segs	| as->a_segs
	movel	%a0@(8),i10a_a_seglast	| as->a_seglast
| --- the process break extent, as brk keeps it (u.u_procp) ---
	moveal	u+0x730,%a2		| curproc = u.u_procp (the proc brk() updates)
	movel	%a2,i10a_uprocp
	movel	%a2@(52),i10a_brkbase	| p_brkbase
	movel	%a2@(56),i10a_brksize	| p_brksize
	movel	%a2@(52),%d0
	addl	%a2@(56),%d0
	movel	%d0,i10a_brkend		| p_brkbase + p_brksize = the current break
	movel	%a2@(124),i10a_pas	| p_as (must equal i10a_as for a user data fault)
| --- call the real as_fault, capture its verdict ---
	movel	&1,i10a_busy
	movel	%fp@(24),%sp@-
	movel	%fp@(20),%sp@-
	movel	%fp@(16),%sp@-
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-		| re-push the 5 args unchanged
	jsr	as_fault_orig
	lea	%sp@(20),%sp		| pop them
	movel	%d0,i10a_ret		| the faultcode as_fault actually returned (3 = FC_NOMAP)
	movel	%d0,%d7			| keep for our own rts (survives the post-latch below)
	clrl	i10a_busy
| --- as_segat AFTER: did a covering segment appear during resolution? ---
	movel	i10a_addr,%d0
	andil	&0xfffff000,%d0
	movel	%d0,%sp@-
	movel	%fp@(8),%sp@-
	jsr	as_segat
	addqw	&8,%sp
	movel	%d0,i10a_seg_post
	movel	&1,i10a_latched
	movel	%d7,%d0			| restore as_fault_orig's return for our rts
	moveml	%sp@+,%d2-%d7/%a2-%a6
	unlk	%fp
	rts

	.balign 4

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The i10a block -- read i10a_magic FIRST (a stale address does not fail, it returns
| a plausible number), then 31 longs: `kpeek <i10a_magic address> 31`.  Everything is
| a .data long so a run can re-aim with kpoke instead of a rebuild (the i10p_vmask
| lesson).
	.globl	i10a_magic
i10a_magic:
	.long	0x49314121		| "I1A!"
| --- knobs ---
	.globl	i10a_watchproc
i10a_watchproc:
	.long	0			| OPTIONAL proc filter: 0 = ANY process (ships this way);
					| do NOT pin a proc pointer -- it is a table slot the
					| wall's sh lands in differently each boot (the i10s lesson)
	.globl	i10a_watchva
i10a_watchva:
	.long	0			| 0 = DORMANT (ships this way): watchva is the ARM gate.
					| kpoke the address to audit; compared as
					| (addr & watchmask) == watchva.  The marker write that
					| vanishes was measured at user 0x800152A0 -- arm with
					| 0x80015000 and watchmask 0xfffff000 to take its page.
	.globl	i10a_watchmask
i10a_watchmask:
	.long	0xfffff000		| 0xfffff000 = any fault in that page, 0xffffffff = exact
	.globl	i10a_watchrw
i10a_watchrw:
	.long	2			| the access class to audit: 1 = S_READ, 2 = S_WRITE
					| (the marker store), 3 = S_EXEC
| --- counters and latch state ---
	.globl	i10a_seen_n
i10a_seen_n:
	.long	0			| as_fault calls seen while armed (uncapped)
	.globl	i10a_match_n
i10a_match_n:
	.long	0			| ... which matched VA + rw AND the proc filter
	.globl	i10a_vamatch_n
i10a_vamatch_n:
	.long	0			| ... which matched VA + rw REGARDLESS of proc
	.globl	i10a_busy
i10a_busy:
	.long	0			| 1 while our own as_fault_orig call is running (re-entry guard)
	.globl	i10a_latched
i10a_latched:
	.long	0			| 1 once the audit is complete -- read this FIRST after the
					| magic: with it 0, every field below is ship-time state
	.globl	i10a_proc
i10a_proc:
	.long	0			| curproc at the latch
	.globl	i10a_comm0
i10a_comm0:
	.long	0			| u_comm, 16 bytes: the command running (expect "sh")
	.globl	i10a_comm1
i10a_comm1:
	.long	0
	.globl	i10a_comm2
i10a_comm2:
	.long	0
	.globl	i10a_comm3
i10a_comm3:
	.long	0
| --- the captured decision ---
	.globl	i10a_addr
i10a_addr:
	.long	0			| arg2: the faulting address
	.globl	i10a_type
i10a_type:
	.long	0			| arg4: fault type (1 = F_INVAL demand, 2 = F_PROT)
	.globl	i10a_rw
i10a_rw:
	.long	0			| arg5: rw (1 = S_READ, 2 = S_WRITE)
	.globl	i10a_as
i10a_as:
	.long	0			| arg1: the address space as_fault was called with
	.globl	i10a_seg
i10a_seg:
	.long	0			| as_segat(as, page) BEFORE: 0 = NO covering segment (the
					| FC_NOMAP cause); nonzero = a seg was found
	.globl	i10a_segbase
i10a_segbase:
	.long	0			| that seg's s_base (valid only when i10a_seg != 0)
	.globl	i10a_segsize
i10a_segsize:
	.long	0			| s_size: s_base + s_size <= addr means the seg is TOO
					| SHORT to cover the address (a gap), distinct from no seg
	.globl	i10a_seg_post
i10a_seg_post:
	.long	0			| as_segat(as, page) AFTER as_fault_orig: did a covering
					| segment appear during the resolution?
	.globl	i10a_ret
i10a_ret:
	.long	0			| as_fault's ACTUAL return: 3 = FC_NOMAP, 0 = resolved
| --- the process break extent, so "brk did not grow" vs "grew but lookup misses" reads directly ---
	.globl	i10a_uprocp
i10a_uprocp:
	.long	0			| u.u_procp -- must equal i10a_proc
	.globl	i10a_brkbase
i10a_brkbase:
	.long	0			| p_brkbase (@52)
	.globl	i10a_brksize
i10a_brksize:
	.long	0			| p_brksize (@56)
	.globl	i10a_brkend
i10a_brkend:
	.long	0			| p_brkbase + p_brksize = the current break.  brkend <
					| addr = the break never reached the write (brk did not
					| grow / failed); brkend >= addr with i10a_seg = 0 = brk's
					| bookkeeping grew but the segment lookup does not cover it
	.globl	i10a_pas
i10a_pas:
	.long	0			| p_as (@124) -- should equal i10a_as for a user data fault
| --- the as's segment-list head, for offline decode ---
	.globl	i10a_a_segs
i10a_a_segs:
	.long	0			| as->a_segs (@4)
	.globl	i10a_a_seglast
i10a_a_seglast:
	.long	0			| as->a_seglast (@8, the lookup cache)
	.balign 4			| pad section to a 4-byte multiple (bss placement)

| ===========================================================================
| PART NINE -- i10b: the GROW-FAILURE CONFIRMATION PROBE (2026-08-20).
|
| WHAT THIS CONFIRMS.  i10s exonerated the per-page check; i10a placed the refusal in
| as_fault (as_segat finds no covering segment -> FC_NOMAP).  The synthesis is that the
| arena grow itself fails one step earlier: brk -> as_map -> hat_map -> hat_growsdt ->
| hat_sdtalloc "not enough contiguous memory for segment tables", the 040 4 KiB-page
| pressure, so the data segment is never extended and the later write to it finds no
| segment.  sh's own "no space" is setbrk reporting that brk() returned an error.  This
| probe turns that synthesis into a line-level reading: it catches the FIRST brk whose
| grow FAILS and records, at that instant, brk's own numbers and the contiguous-memory
| shortfall the ISSUE-39 counters already track.
|
| WHY A brk WRAPPER IS GUARANTEED ON THE LIVE PATH (the i10a lesson).  The kernel is
| ET_REL: every cross-reference is a relocation resolved at relink, not a hard-coded
| address.  brk (0x580e8) has EXACTLY ONE reference in the whole image -- the sysent
| dispatch slot (reloc at 0x69d4) -- so weakening brk and providing a strong wrapper
| re-binds that one slot and intercepts 100% of brk syscalls, with no other call path to
| bypass it.  (Contrast as_fault, which has many callers.)  The relink hard check asserts
| the strong brk moved off 0x580e8 and brk_orig still points at it.
|
| HOW IT DECIDES "the grow failed".  From the stock brk body: a grow calls as_map
| (0x5819c) and, if as_map returns non-zero, brk returns that errno WITHOUT advancing
| p_brksize (0x581ba-0x581c6); on success it sets p_brksize (0x581f8).  So this wrapper
| calls brk_orig, and latches the first call that (a) returned non-zero AND (b) was a
| GROW -- the requested new break is above the current break end (p_brkbase + p_brksize),
| the only case that reaches as_map.  That is precisely "an as_map grow that failed".
|
| WHAT IT RECORDS at the failing grow: the requested new break, p_brkbase, p_brksize
| before and after (equal = not advanced), the current break end, brk's return (the
| as_map errno), curproc/u_comm/p_as, and -- reusing the ISSUE-39 island -- hat_sdtfail_n
| before and after (a non-zero delta = hat_sdtalloc's "not enough contiguous memory" path
| fired for THIS grow) and availrmem/freemem via i39_availrmem_p/i39_freemem_p (the
| contiguous-memory shortfall, read directly).
|
| SAFETY AND COST.  Throwaway confirmation instrument.  Ships dormant: i10b_on = 0, so
| every brk pays one tstl and a tail jmp to brk_orig (brk is a syscall, not a hot fault
| path).  Armed, it wraps brk call-and-return, saving/restoring d2-d7/a2-a6 and returning
| brk_orig's own d0, so the syscall ABI is exact.  It reads only kernel memory and the
| ISSUE-39 counters; it never changes brk's behaviour.  One-shot (i10b_latched).
| ===========================================================================

	.text
	.balign 4

| ---------------------------------------------------------------------------
| brk -- the i10b wrapper.  brk(uap): fp@(8) = uap, *uap = the requested new break.
| The brk wrapper is SHARED by i10b (the one-shot grow-failure latch) and i10d (the
| ring tracer, PART ELEVEN): brk has a single strong def, so one wrapper serves both.
| Active when EITHER i10b_on or i10d_on; both dormant = one/two tstl + tail jmp.
	.globl	brk
brk:
	tstl	i10d_on
	bnew	Lbrk_active
	tstl	i10b_on
	bnew	Lbrk_active
Lbrk_fwd:
	jmp	brk_orig		| both dormant: forward unchanged
Lbrk_active:
	linkw	%fp,&0
	moveml	%d2-%d7/%a2-%a6,%sp@-
	moveal	%fp@(8),%a0		| uap
	movel	%a0@,%d2		| d2 = requested new break (*uap)
	moveal	u+0x730,%a2		| curproc = u.u_procp (the proc brk updates)
	movel	%a2@(56),%d3		| d3 = p_brksize BEFORE
	movel	%a2@(52),%d7
	addl	%d3,%d7			| d7 = current break end = p_brkbase + p_brksize
	movel	hat_sdtfail_n,%d4	| d4 = hat_sdtfail_n BEFORE (i10b)
| --- call the real brk, capture its verdict ---
	movel	%fp@(8),%sp@-
	jsr	brk_orig
	addqw	&4,%sp
	movel	%d0,%d5			| d5 = brk's return (0 = ok; grow-fail = as_map errno)
	movel	%a2@(56),%d6		| d6 = p_brksize AFTER
| === i10d: record EVERY brk into the ring (if armed and band-matched) ===
	tstl	i10d_on
	beqs	Lbrk_i10b
	bsrw	i10d_record		| in: d2 newbrk, d3 pre, d5 ret, d6 post, a2 proc
Lbrk_i10b:
| === i10b: one-shot latch on the first FAILING grow ===
	tstl	i10b_on
	beqw	Lbrk_done
	addql	&1,i10b_seen_n		| brk calls seen while i10b armed
	tstl	i10b_latched
	bnew	Lbrk_done		| already caught the first failing grow
	tstl	%d5
	beqw	Lbrk_done		| brk succeeded: not a failing grow
	addql	&1,i10b_fail_n		| any failing brk (grow or early reject)
	cmpl	%d7,%d2			| requested new break vs current end
	blsw	Lbrk_done		| not above the end: an early reject/shrink, not an as_map grow
	movel	&1,i10b_latched
| --- latch the failing GROW ---
	movel	curproc,i10b_proc
	movel	u+0x1c0,i10b_comm0	| u_comm: expect "sh"
	movel	u+0x1c4,i10b_comm1
	movel	u+0x1c8,i10b_comm2
	movel	u+0x1cc,i10b_comm3
	movel	%d2,i10b_newbrk
	movel	%a2@(52),i10b_brkbase
	movel	%d3,i10b_brksize_pre
	movel	%d6,i10b_brksize_post
	movel	%d7,i10b_brkend_pre
	movel	%d5,i10b_ret
	movel	&1,i10b_isgrow		| we latch only grows (new break above the end)
	movel	%d4,i10b_sdtfail_pre
	movel	hat_sdtfail_n,i10b_sdtfail_post	| delta > 0 = the hat_sdtalloc fail path fired
	moveal	i39_availrmem_p,%a0
	movel	%a0@,i10b_availrmem	| availrmem at the failing grow (contiguous-mem shortfall)
	moveal	i39_freemem_p,%a0
	movel	%a0@,i10b_freemem
	movel	%a2,i10b_uprocp
	movel	%a2@(124),i10b_pas	| p_as
Lbrk_done:
	movel	%d5,%d0			| return brk_orig's value unchanged
	moveml	%sp@+,%d2-%d7/%a2-%a6
	unlk	%fp
	rts

	.balign 4

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The i10b block -- read i10b_magic FIRST, then 23 longs: `kpeek <i10b_magic> 23`.
	.globl	i10b_magic
i10b_magic:
	.long	0x49314221		| "I1B!"
	.globl	i10b_on
i10b_on:
	.long	0			| 0 = DORMANT (ships this way).  kpoke 1 to arm; it then
					| latches the FIRST brk whose as_map grow fails (no VA/proc
					| filter -- a proc pointer is not stable across boots)
	.globl	i10b_seen_n
i10b_seen_n:
	.long	0			| brk calls seen while armed (uncapped)
	.globl	i10b_fail_n
i10b_fail_n:
	.long	0			| ... which returned non-zero (grow-fail OR early reject)
	.globl	i10b_latched
i10b_latched:
	.long	0			| 1 once the first failing GROW is caught -- read FIRST
					| after the magic; with it 0 every field below is ship-time
	.globl	i10b_proc
i10b_proc:
	.long	0			| curproc at the latch
	.globl	i10b_comm0
i10b_comm0:
	.long	0			| u_comm, 16 bytes (expect "sh")
	.globl	i10b_comm1
i10b_comm1:
	.long	0
	.globl	i10b_comm2
i10b_comm2:
	.long	0
	.globl	i10b_comm3
i10b_comm3:
	.long	0
	.globl	i10b_newbrk
i10b_newbrk:
	.long	0			| the requested new break (*uap) -- expect a heap addr
					| whose page covers 0x800152A0
	.globl	i10b_brkbase
i10b_brkbase:
	.long	0			| p_brkbase (@52)
	.globl	i10b_brksize_pre
i10b_brksize_pre:
	.long	0			| p_brksize BEFORE the call
	.globl	i10b_brksize_post
i10b_brksize_post:
	.long	0			| p_brksize AFTER (== pre for a failed grow: not advanced)
	.globl	i10b_brkend_pre
i10b_brkend_pre:
	.long	0			| p_brkbase + p_brksize = the break end before the grow.
					| newbrk > this = it was a real grow that reached as_map;
					| brkend_pre < 0x800152A0 = the break never covered the write
	.globl	i10b_ret
i10b_ret:
	.long	0			| brk's return: 0 = ok, else the as_map errno (12 = ENOMEM)
	.globl	i10b_isgrow
i10b_isgrow:
	.long	0			| 1 = the latched call was a grow (always 1 at a latch)
	.globl	i10b_sdtfail_pre
i10b_sdtfail_pre:
	.long	0			| hat_sdtfail_n BEFORE (ISSUE-39 "not enough contiguous mem")
	.globl	i10b_sdtfail_post
i10b_sdtfail_post:
	.long	0			| ... and AFTER: a non-zero delta means hat_sdtalloc's fail
					| path fired for THIS grow -- the segment-table shortfall
	.globl	i10b_availrmem
i10b_availrmem:
	.long	0			| availrmem at the failing grow (via i39_availrmem_p)
	.globl	i10b_freemem
i10b_freemem:
	.long	0			| freemem at the failing grow (via i39_freemem_p)
	.globl	i10b_uprocp
i10b_uprocp:
	.long	0			| u.u_procp -- must equal i10b_proc
	.globl	i10b_pas
i10b_pas:
	.long	0			| p_as (@124)
	.balign 4			| pad section to a 4-byte multiple (bss placement)

| ===========================================================================
| PART TEN -- i10c: the GENESIS INTROSPECTION, at the one site that fires once.
|
| WHY HERE, AND WHY IT IS GUARANTEED TO FIRE EXACTLY ONCE.  Every symbol-wrapper probe
| so far (as_fault, segvn_faultpage) kept catching ADJACENT events -- the watched VA or
| access class matched innocent faults before the genesis.  But wb040's drop-warning
| safety net (wbf_dropwarn) fires on precisely one thing: a fault that came back
| UNRESOLVED with a VALID pending write-back still in its 040 frame, and on the setup.sh
| wall wbf_dropped_n reached exactly 1 -- the genesis, the store the kernel dropped.  At
| that instant the trap is still on the faulting process's stack: curproc is sh, the CPU
| frame holds fa/WB3D/PC/SR/SSW, and sh's address space is walkable.  So this hook rides
| the SAME site (called right after wbf_dropwarn in both usrxmemflt and krnxmemflt) and,
| once armed, synchronously reads the GROUND TRUTH of why that one first-touch write did
| not resolve.  It does NOT change the outcome (report-only, exactly like wbf_dropwarn):
| the fault still signals and the replay is still skipped.
|
| THE FORK IT SETTLES.  i10a placed the refusal in as_fault (no covering segment) and
| i10b synthesised a late brk grow-failure.  This asks the genesis-specific question the
| wrapper probes could not: at THIS fault, is fa IN a segment with the break already past
| it (=> a demand-zero resolution corner: the page should have been zero-fillable and was
| not) or NOT covered (=> brk/grow had not extended the segment before sh wrote)?  And is
| it EARLY (tiny arena, memory plentiful) or LATE (the 16 MB grow-failure)?  It records
| both sides so the answer is a reading, not a choice.
|
| WHAT IT CAPTURES, once, on the first unresolved-fault-with-valid-WB3 while armed:
|   * the fault essentials the frame carries -- fa (WB3A), WB3D (the dropped value,
|     expect 0x800114B5), WB3S, the faulting PC, SR (S bit), SSW, and rw DERIVED from the
|     040 SSW bit 8 (1 = read, 0 = write -- the exact source usrxmemflt's classifier uses,
|     src/usrxmemflt040-design.md; the stock resolver's own type/rw locals are gone by
|     this point, so rw is re-derived and ptest re-measured here, which is ground truth at
|     the introspection instant rather than a stale copy);
|   * as_segat(curproc->p_as, fa & ~0xFFF): does a segment COVER fa?  seg (0 = none),
|     s_base, s_size, s_data, svd->pageprot, and a decoded i10c_covered;
|   * the break extent -- p_brkbase, p_brksize, their sum, and i10c_fa_covered (fa <
|     brkend: had sh's break already reached this address?);
|   * ptest(fa) via i10r_doptest -- the 030-form PSR and the raw 040 MMUSR (resident /
|     write-protected / invalid), the classifier's own input, re-measured;
|   * the leaf PTE and the longword at fa via i10r_readtgt (present-but-something vs truly
|     absent), availrmem/freemem (plentiful = early), and wb_replay_n (a cheap count of
|     resolved store-faults so far: small = the genesis is early, a tiny arena).
|
| SAFETY AND COST.  Ships dormant: i10c_on = 0, one memory test per drop-warning call.
| Armed, it saves/restores d0-d7/a0-a6 AND DFC/SFC (i10r_doptest writes DFC for the 040
| ptestr, and this must hand the interrupted fault path its function-code registers back,
| the ISSUE-22 discipline), so neither the wrapper's d4/d5 nor the DFC/SFC accounting is
| disturbed.  It calls only leaf lookups -- as_segat, and i10r_doptest/i10r_readtgt which
| walk the page tree the resident-or-abandon way -- so nothing it does can fault.  One-shot.
| ===========================================================================

	.text
	.balign 4

| ---------------------------------------------------------------------------
| i10c_hook(frame, ctx) -- called right after wbf_dropwarn in usrxmemflt (ctx=1) and
| krnxmemflt (ctx=2).  frame = sp@(4), ctx = sp@(8).  Dormant until i10c_on.
	.globl	i10c_hook
i10c_hook:
	tstl	i10c_on
	beqw	Lic_ret			| dormant: one memory test, nothing saved
	tstl	i10c_latched
	bnew	Lic_ret			| one-shot: the genesis is already captured
	linkw	%fp,&0
	moveml	%d0-%d7/%a0-%a6,%sp@-	| preserve the wrapper's d4/d5 and everything else
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%d6			| d6 = caller DFC (i10r_doptest writes DFC)
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%d0,%d7			| d7 = caller SFC
	moveal	%fp@(8),%a2		| a2 = frame (survives all leaf calls below)
| gate on the SAME condition wbf_dropwarn latched on: a format-7 frame with a valid WB3
	moveq	&0,%d0
	moveb	%a2@(70),%d0
	lsrb	&4,%d0
	cmpiw	&7,%d0
	bnew	Lic_out			| not a 68040 format-7 frame
	moveq	&0,%d0
	movew	%a2@(78),%d0		| WB3S
	btst	&7,%d0
	beqw	Lic_out			| no valid pending write-back: not a real drop
	addql	&1,i10c_seen_n
	movel	&1,i10c_latched
	movel	i10c_seen_n,i10c_seq
	movel	%fp@(12),i10c_ctx	| ctx: 1 = user (usrxmemflt), 2 = kernel (krnxmemflt)
	movel	curproc,i10c_proc
	movel	u+0x1c0,i10c_comm0	| u_comm: expect "sh"
	movel	u+0x1c4,i10c_comm1
	movel	u+0x1c8,i10c_comm2
	movel	u+0x1cc,i10c_comm3
| --- fault essentials, from the frame ---
	movel	%a2@(88),i10c_fa	| WB3A = the store target / fault address
	movel	%a2@(92),i10c_wb3d	| WB3D = the dropped value (expect 0x800114B5)
	moveq	&0,%d0
	movew	%a2@(78),%d0
	movel	%d0,i10c_wb3s
	movel	%a2@(84),i10c_fa2	| the CPU's own fault address at +84 (cross-check)
	movel	%a2@(66),i10c_pc
	moveq	&0,%d0
	movew	%a2@(64),%d0		| SR: bit 13 (0x2000) = S -> supervisor
	movel	%d0,i10c_sr
	moveq	&0,%d0
	movew	%a2@(76),%d0		| SSW
	movel	%d0,i10c_ssw
	moveq	&2,%d1			| rw: default S_WRITE
	btst	&8,%d0			| SSW bit 8: 1 = a READ access
	beqs	Lic_rw
	moveq	&1,%d1			| S_READ
Lic_rw:
	movel	%d1,i10c_rw
| --- does a segment COVER fa?  d3 = fa page base, live across the leaf calls ---
	movel	%a2@(88),%d3
	andil	&0xfffff000,%d3
	clrl	i10c_covered
	clrl	i10c_as
	moveal	curproc,%a0
	movel	%a0,%d0
	beqw	Lic_brk			| no curproc: skip the VM reads
	moveal	%a0@(124),%a1		| p_as
	movel	%a1,i10c_as
	movel	%a1,%d0
	beqw	Lic_brk
	movel	%d3,%sp@-		| as_segat(p_as, page base)
	movel	%a1,%sp@-
	jsr	as_segat
	addqw	&8,%sp
	movel	%d0,i10c_seg		| 0 = NO covering segment
	tstl	%d0
	beqs	Lic_brk
	moveal	%d0,%a0
	movel	%a0@(4),i10c_segbase	| s_base
	movel	%a0@(8),i10c_segsize	| s_size
	movel	%a0@(28),i10c_svd	| s_data
	moveal	%a0@(28),%a1
	moveq	&0,%d0
	moveb	%a1@(2),%d0		| svd->pageprot
	movel	%d0,i10c_pageprot
	movel	%a0@(4),%d0		| covered = s_base <= fa < s_base + s_size
	cmpl	%d3,%d0
	bhis	Lic_brk			| s_base > fa
	movel	%a0@(4),%d0
	addl	%a0@(8),%d0
	cmpl	%d3,%d0
	blss	Lic_brk			| s_base + s_size <= fa: a gap
	movel	&1,i10c_covered
Lic_brk:
| --- the break extent: had sh's break already reached fa? ---
	moveal	u+0x730,%a0		| u.u_procp
	movel	%a0@(52),i10c_brkbase
	movel	%a0@(56),i10c_brksize
	movel	%a0@(52),%d0
	addl	%a0@(56),%d0
	movel	%d0,i10c_brkend
	clrl	i10c_fa_covered
	cmpl	%d0,%d3			| fa page base vs brkend
	bccs	Lic_pt			| fa >= brkend: the break did not cover it
	movel	&1,i10c_fa_covered	| fa < brkend: the break already covered it
Lic_pt:
| --- ptest(fa): resident / write-protected / invalid, synchronously ---
	movel	%d3,%d0
	bsrw	i10r_doptest		| d0 = 030-form PSR, d1 = raw 040 MMUSR
	movel	%d0,i10c_ptpsr
	movel	%d1,i10c_mmusr
	movel	%a2@(88),%d0		| the exact fa (not page base) for the value read
	bsrw	i10r_readtgt		| d0 = leaf PTE (0 = not resident), d1 = longword at fa
	movel	%d0,i10c_pte
	movel	%d1,i10c_ptev
| --- memory state, and a cheap resolved-fault clock (small = the genesis is early) ---
	moveal	i39_availrmem_p,%a0
	movel	%a0@,i10c_availrmem
	moveal	i39_freemem_p,%a0
	movel	%a0@,i10c_freemem
	movel	wb_replay_n,i10c_wbrep
Lic_out:
	movel	%d6,%d0			| restore DFC/SFC (i10r_doptest wrote DFC) -- ISSUE-22
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%d7,%d0
	.word	0x4e7b,0x0000		| movec %d0,%sfc
	moveml	%sp@+,%d0-%d7/%a0-%a6
	unlk	%fp
Lic_ret:
	rts

	.balign 4

	.data
	.balign 4
| ---------------------------------------------------------------------------
| The i10c block -- read i10c_magic FIRST, then 37 longs: `kpeek <i10c_magic> 37`.
	.globl	i10c_magic
i10c_magic:
	.long	0x49314321		| "I1C!"
	.globl	i10c_on
i10c_on:
	.long	0			| 0 = DORMANT (ships this way).  kpoke 1 to arm; it then
					| latches the FIRST unresolved fault carrying a valid pending
					| write-back -- the genesis (no VA/proc filter)
	.globl	i10c_seen_n
i10c_seen_n:
	.long	0			| drop events seen while armed (should reach 1 = the genesis)
	.globl	i10c_latched
i10c_latched:
	.long	0			| 1 once the genesis is captured -- read FIRST after the
					| magic; with it 0 every field below is ship-time state
	.globl	i10c_seq
i10c_seq:
	.long	0			| i10c_seen_n at the latch (1 = it was the first drop)
	.globl	i10c_ctx
i10c_ctx:
	.long	0			| 1 = usrxmemflt (user store), 2 = krnxmemflt (kernel store)
	.globl	i10c_proc
i10c_proc:
	.long	0			| curproc at the genesis (u_comm below must read "sh")
	.globl	i10c_comm0
i10c_comm0:
	.long	0			| u_comm, 16 bytes
	.globl	i10c_comm1
i10c_comm1:
	.long	0
	.globl	i10c_comm2
i10c_comm2:
	.long	0
	.globl	i10c_comm3
i10c_comm3:
	.long	0
| --- fault essentials (from the 040 frame) ---
	.globl	i10c_fa
i10c_fa:
	.long	0			| WB3A -- the store's target address (the fault address)
	.globl	i10c_wb3d
i10c_wb3d:
	.long	0			| WB3D -- the dropped value (expect 0x800114B5, sh's marker)
	.globl	i10c_wb3s
i10c_wb3s:
	.long	0			| WB3S -- bit 7 = valid (the gate)
	.globl	i10c_fa2
i10c_fa2:
	.long	0			| the CPU fault address at frame+84 (must equal i10c_fa)
	.globl	i10c_pc
i10c_pc:
	.long	0			| the faulting instruction's PC (one past a deferred store)
	.globl	i10c_sr
i10c_sr:
	.long	0			| SR; bit 13 (0x2000) = S: set = a supervisor fault
	.globl	i10c_ssw
i10c_ssw:
	.long	0			| SSW; bit 8 = read, bits 6-5 size, bits 2-0 TM
	.globl	i10c_rw
i10c_rw:
	.long	0			| rw derived from SSW bit 8: 1 = S_READ, 2 = S_WRITE
| --- DECISIVE: does a segment cover fa, and had the break reached it? ---
	.globl	i10c_as
i10c_as:
	.long	0			| curproc->p_as
	.globl	i10c_seg
i10c_seg:
	.long	0			| as_segat(p_as, fa&~0xFFF): 0 = NO segment covers fa
	.globl	i10c_segbase
i10c_segbase:
	.long	0			| s_base of that segment (valid only when i10c_seg != 0)
	.globl	i10c_segsize
i10c_segsize:
	.long	0			| s_size
	.globl	i10c_covered
i10c_covered:
	.long	0			| 1 = s_base <= fa < s_base + s_size (a segment DOES cover fa
					| -> a demand-zero corner); 0 = not covered (-> brk/grow gap)
	.globl	i10c_svd
i10c_svd:
	.long	0			| seg->s_data (segvn_data)
	.globl	i10c_pageprot
i10c_pageprot:
	.long	0			| svd->pageprot (@2): 0 = segment-wide protection
	.globl	i10c_brkbase
i10c_brkbase:
	.long	0			| p_brkbase (@52)
	.globl	i10c_brksize
i10c_brksize:
	.long	0			| p_brksize (@56): SMALL here = early (tiny arena), not the
					| late 16 MB grow-failure
	.globl	i10c_brkend
i10c_brkend:
	.long	0			| p_brkbase + p_brksize = the current break
	.globl	i10c_fa_covered
i10c_fa_covered:
	.long	0			| 1 = fa < brkend (sh's break already reached this address,
					| so it should have been demand-zero-able); 0 = past the break
| --- what the MMU and the frame say about fa ---
	.globl	i10c_ptpsr
i10c_ptpsr:
	.long	0			| ptest 030-form PSR: 0x400 = I (not present), 0x800 = W
					| (write-protected), 0 = resident and writable
	.globl	i10c_mmusr
i10c_mmusr:
	.long	0			| raw 040 MMUSR: bit 0 R (resident), bit 2 W, bit 4 M, bit 11 B
	.globl	i10c_pte
i10c_pte:
	.long	0			| the leaf PTE for fa (0 = no resident leaf: truly absent)
	.globl	i10c_ptev
i10c_ptev:
	.long	0			| the longword at fa if resident
	.globl	i10c_availrmem
i10c_availrmem:
	.long	0			| availrmem at the genesis (plentiful = early)
	.globl	i10c_freemem
i10c_freemem:
	.long	0			| freemem at the genesis
	.globl	i10c_wbrep
i10c_wbrep:
	.long	0			| wb_replay_n at the genesis: resolved store-faults so far.
					| Small = the genesis is early in the wall, not a late grow
	.balign 4			| pad section to a 4-byte multiple (bss placement)

| ===========================================================================
| PART ELEVEN -- i10d: the CPU-INDEPENDENT brk/sbrk RING TRACER (2026-08-20).
|
| WHY.  User ruling: sh is the SAME binary on 030/040/060, so ISSUE-10's desync (sh's
| blok arena top 0x800152A0 lands past its break 0x80014FB4) must be the 040 kernel
| granting a DIFFERENT brk result than 030/060 for identical requests.  This records a
| ring of the last 24 brk syscalls -- {requested newbrk, p_brkbase, p_brksize before,
| p_brksize after, brkend after, return} -- so the same probe run on 040, 030 and 060
| shows whether the 040 UNDER-GROWS (grants a smaller break than 030/060) for the
| identical sbrk sequence, and by how much.
|
| WHY ONE PROBE RUNS ON ALL THREE.  brk is the same sysent slot on every CPU, and this
| build's brk hook is the proven-100% weaken/redefine (a single sysent reloc, no bypass;
| the i10b hard check asserts it).  The 040 and 060 run this exact image; the 030 gets
| the SAME ring via a standalone generic-68k copy (src/i10dtrace030.s, relink-030-i10d.sh)
| whose I1D! block is byte-for-byte the same layout, so one driver reads all three.
|
| SHARED WRAPPER.  i10d rides the brk wrapper above (PART NINE): on every armed brk it
| calls i10d_record, which appends one ring entry.  Report-only, never changes brk.  It
| ships dormant (i10d_on = 0).  An optional band filter (i10d_lo/i10d_hi, default all)
| narrows the ring to sh's arena grows (e.g. [0x80011000, 0x80020000)) when other procs
| would otherwise share the ring.
|
| READ IT.  status-facts finds the block by i10d_magic; the whole block is
| `kpeek <i10d_magic addr> 157` -- 13 header longs then 16 * 9 ring longs.  i10d_head is
| the next write slot, i10d_n the total; entries [0..min(n,16)-1] chronological unless n>16,
| when the oldest is at head and the newest at head-1.  Each entry is 9 longs:
| newbrk, brkbase, brksize_pre, brksize_post, brkend (= brkbase + post), ret, seg_end,
| seg@brkend, seg@(brkend+0x1000) -- the last three name the data-segment extent, which
| tells reserve-ahead (seg reaches past the break) from grow-on-fault (page-exact).

	.text
	.balign 4
| ---------------------------------------------------------------------------
| i10d_record -- append the current brk to the ring, INCLUDING the data-segment extent
| that distinguishes reserve-ahead from grow-on-fault.  in: d2 = newbrk, d3 = brksize_pre,
| d5 = ret, d6 = brksize_post, a2 = proc (u.u_procp).  Fully register-transparent (saves
| and restores d0-d7/a0-a6), so it can call as_segat freely and the caller's d2-d7/a2-a6
| survive for the i10b latch.  as_segat is a leaf lookup, fault-free -- safe from here.
| Entry = 9 longs: newbrk, brkbase, pre, post, brkend, ret, seg_end, seg@brkend,
| seg@(brkend+0x1000).  seg_end = s_base + s_size of the seg covering brkbase (the data
| segment).  seg@(brkend+0x1000) nonzero = the segment reaches PAST the break = A
| (reserve-ahead); seg_end == round-up(break) with seg@nextpage == 0 = B (grow-on-fault).
	.globl	i10d_record
i10d_record:
	moveml	%d0-%d7/%a0-%a6,%sp@-
	movel	%d2,%d0			| band filter on the requested new break
	cmpl	i10d_lo,%d0
	bcsw	Lidr_out		| newbrk < lo
	cmpl	i10d_hi,%d0
	bccw	Lidr_out		| newbrk >= hi (default hi = 0xffffffff -> all)
| --- three leaf lookups against curproc's address space (p_as = a2@124) ---
	movel	%a2@(52),%d0		| as_segat(p_as, brkbase) -> the data segment
	movel	%d0,%sp@-
	movel	%a2@(124),%sp@-
	jsr	as_segat
	addqw	&8,%sp
	moveq	&0,%d4			| d4 = seg_end (0 if no covering segment)
	tstl	%d0
	beqs	Lidr_nseg
	moveal	%d0,%a0
	movel	%a0@(4),%d4
	addl	%a0@(8),%d4		| seg_end = s_base + s_size
Lidr_nseg:
	movel	%a2@(52),%d7		| d7 = brkend = brkbase + brksize_after
	addl	%d6,%d7
	movel	%d7,%sp@-		| as_segat(p_as, brkend) -> seg covering the break
	movel	%a2@(124),%sp@-
	jsr	as_segat
	addqw	&8,%sp
	moveal	%d0,%a3			| a3 = seg@brkend (pointer, 0 = none)
	movel	%d7,%d0			| as_segat(p_as, brkend + 0x1000) -> the page PAST the break
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
	movel	%d4,%a0@(24)		| [6] seg_end (of the data segment)
	movel	%a3,%a0@(28)		| [7] seg@brkend
	movel	%a4,%a0@(32)		| [8] seg@(brkend+0x1000)
	movel	i10d_head,%d0		| advance head mod 16
	addql	&1,%d0
	cmpil	&16,%d0
	bcss	Lidr_nw
	moveq	&0,%d0
Lidr_nw:
	movel	%d0,i10d_head
	addql	&1,i10d_n
	movel	%a2,i10d_proc		| last recorder's proc + u_comm (for context)
	movel	u+0x1c0,i10d_comm0
	movel	u+0x1c4,i10d_comm1
	movel	u+0x1c8,i10d_comm2
	movel	u+0x1cc,i10d_comm3
Lidr_out:
	moveml	%sp@+,%d0-%d7/%a0-%a6
	rts

	.balign 4

	.data
	.balign 4
| The i10d block -- read i10d_magic FIRST; whole block = `kpeek <magic> 157`
| (13 header longs + 16 entries * 9 longs).
	.globl	i10d_magic
i10d_magic:
	.long	0x49314421		| "I1D!"
	.globl	i10d_on
i10d_on:
	.long	0			| 0 = DORMANT (ships this way).  kpoke 1 to arm the ring.
	.globl	i10d_n
i10d_n:
	.long	0			| total brk calls recorded (the ring holds the last 16)
	.globl	i10d_head
i10d_head:
	.long	0			| next write slot (0..15); if n>16 the oldest is here
	.globl	i10d_size
i10d_size:
	.long	16			| ring capacity (entries)
	.globl	i10d_stride
i10d_stride:
	.long	9			| longs per entry: newbrk,brkbase,pre,post,brkend,ret,
					| seg_end,seg@brkend,seg@(brkend+0x1000)
	.globl	i10d_lo
i10d_lo:
	.long	0			| band filter: record only newbrk in [lo, hi).  Default all;
	.globl	i10d_hi			| kpoke lo=0x80011000 hi=0x80020000 to keep only sh's grows
i10d_hi:
	.long	0xffffffff
	.globl	i10d_proc
i10d_proc:
	.long	0			| curproc of the last recorded call
	.globl	i10d_comm0
i10d_comm0:
	.long	0			| u_comm, 16 bytes (expect "sh")
	.globl	i10d_comm1
i10d_comm1:
	.long	0
	.globl	i10d_comm2
i10d_comm2:
	.long	0
	.globl	i10d_comm3
i10d_comm3:
	.long	0
| the ring: 16 entries * 9 longs.  One symbol; the reader indexes it by entry*36 bytes.
	.globl	i10d_ring
i10d_ring:
	.space	576
	.balign 4			| pad section to a 4-byte multiple (bss placement)
