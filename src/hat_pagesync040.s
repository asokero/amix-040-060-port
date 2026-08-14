| hat_pagesync040.s -- 040 port of hat_pagesync (stock orig 0xb4be8, GLOBAL T).
|
| CONTRACT (SVR4 vm_hat.c hat_pagesync): walk pp->p_mapping (the reverse-map list
| of leaf-PTE addresses, chained via *(pte + NPGPT*4) = +256), OR each PTE's HW
| Used/Modified bits into pp->p_ref / pp->p_mod, then CLEAR them in the PTE and
| flush the MMU ATC so the hardware re-marks U/M on the next access.  This is the
| sampling gate the pageout/pvn_done B_FREE reclaim path uses to decide keep-vs-free
| (referenced ⇒ the process still needs the page ⇒ do NOT free it).
|
| WHY A PORT IS NEEDED: the stock body's U/M gather+clear is CORRECT on the 040
| (immu.h PG_REF=0x08 bit3 == 040 U, PG_M=0x10 bit4 == 040 M; pp->p_ref = bitfield
| off6 = bit25, pp->p_mod = off5 = bit26 -- verbatim from the stock disasm).  BUT the
| stock then flushes CONDITIONALLY via hat_pt2ptdat -> flushmmu using the 030
| ptdat/secseg machinery, which is RETIRED/INERT on the 040 tree: it computes a
| garbage flush address (or the as-check fails and nothing flushes).  Result: after
| PG_CLRREF clears the PTE's U bit, the 040 ATC still holds the entry with U set, so
| the HW never re-marks the in-memory PTE -> the next reclaim scan reads p_ref==0 for
| an ACTIVELY-USED page and frees it.  A concurrent segmap/exec disk-read then reuses
| the freed frame while the owner's PTE still maps it -> the owner reads freshly
| disk-read ELF content (ISSUE-10 reuse-while-mapped; latent until the pageout daemon
| went live, schedpaging retirement 6f53d5c).
|
| THIS PORT: same U/M gather+clear (bit ops mirror the stock, proven correct), but
| replace the whole conditional flushmmu block with an UNCONDITIONAL cpusha bc +
| pflusha after the walk -- push the cleared PTEs to RAM (harmless while DC off) and
| flush the single 040 ATC so the HW reloads each descriptor and re-marks U/M on next
| access.  Mirrors hat_pageunload040's publish tail.  Only flushes when the page
| actually had mappings (perf: skip the pflusha for the common p_mapping==0 scan).
| Args: arg@8 = pp.  Returns void.  --weaken-symbol hat_pagesync (full replacement,
| no _orig call).
|
| FUTURE OPT: a per-address pflush (VA reachable from the leaf table index) instead of
| the blanket pflusha would cut the pageout-scan cost; correctness (any flush) first.

	.text
	.globl	hat_pagesync
hat_pagesync:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-		| callee-saved regs we clobber (d0/d1/a0/a1 = scratch)
	moveal	%fp@(8),%a2		| a2 = pp
	movel	%a2@(32),%d2		| d2 = pp->p_mapping (head: &leaf PTE, or 0)
	tstl	%d2
	beqw	Lps_ret			| no mappings -> nothing to sample, no flush
Lps_loop:
	moveal	%d2,%a1			| a1 = &PTE (current)
	lea	%a1@(3),%a0		| a0 = &PTE low byte (U/M live here)
|	--- U (referenced): pp->p_ref{6:1} |= PTE U (byte{4:1} = PTE bit3 0x08) ---
	bfextu	%a2@{&6:&1},%d0
	bfextu	%a0@{&4:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a2@{&6:&1}
|	--- M (modified): pp->p_mod{5:1} |= PTE M (byte{3:1} = PTE bit4 0x10) ---
	bfextu	%a2@{&5:&1},%d0
	bfextu	%a0@{&3:&1},%d1
	orl	%d1,%d0
	bfins	%d0,%a2@{&5:&1}
|	--- clear U+M (bits 3,4 = 0x18) in the PTE so the HW re-marks on next access ---
	movel	%a1@,%d0
	andil	&0xffffffe7,%d0		| ~0x18
	movel	%d0,%a1@
|	--- advance: next = *(pte + NPGPT*4) ---
	movel	%a1@(256),%d2
	tstl	%d2
	bnew	Lps_loop
	.word	0xf4f8			| cpusha bc -- push the cleared PTE lines to RAM
	.word	0xf518			| pflusha   -- flush the ATC so HW reloads + re-marks U/M
Lps_ret:
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	rts
	.balign	4			| pad section to a 4-byte multiple (bss placement guard)
