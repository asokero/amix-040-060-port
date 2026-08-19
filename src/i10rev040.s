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
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c i10rev040.s -o build/i10rev040.o

	.text
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
