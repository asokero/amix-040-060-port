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
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
