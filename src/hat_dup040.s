| hat_dup040.s -- 68040 port of hat_dup (orig 0xb502a-0xb57e0, 1974 B, GLOBAL T).
|
| fork(): as_dup -> hat_dup(oldas, newas).  The generic C level (as_dup/segvn_dup)
| has already duplicated the segment + anon STRUCTURES; hat_dup's job is (A) give
| newas a page-table tree skeleton matching oldas and (B) walk the old tree and,
| per resident leaf PTE, either SHARE the mapping (copy the PTE + splice it into
| the page's p_mapping reverse-map) or -- for private writable anon pages
| (doanon=1: svd@(5)==2 && svd@(3)&2 && svd@(20)!=0) -- allocate a fresh anon +
| physical page, ppcopy the contents, and map the COPY in the child.
| The old stub (forkdbg.s) returned 0 and copied NOTHING; that was papered over by
| every fork+exec test (exec rebuilds the child as) but is wrong for plain fork.
|
| Port spec: src/hat-040-port-worklist.md "hat_dup -- PORT PLAN (2026-07-04)".
| 030->040 changes (everything else is VERBATIM 030 logic from the disassembly):
|   * Part A (b502a-b50bd): the 030 4-region hat_growsdt loop is REPLACED by the
|     hat040.s lazy pointer-table allocator pattern (Lrz_loop/Lrootok): for each of
|     the 128 040 root slots resident in oldas but absent in newas, hat_ptalloc(1)
|     a fresh page (4KB-aligned under Model B), zero its 128 4-byte descriptors
|     (hat_ptalloc's page_get path bzeros only 256 B) and install root[A]=table|2.
|     hat_growsdt (562 B, never ported) is thereby NOT needed.
|   * Part B tree walk: the 030 SDE-pointer arithmetic (root[A*8]@(4) + Bidx*8,
|     end-SDE compare, +=8 stride) is replaced by hat_chgprot040's per-chunk
|     RE-WALK: at each 256KB chunk recompute A=(va>>25&7f)*4 -> ptr table
|     (Adesc&~0x1ff) -> B=(va>>18&7f)*4 -> leaf table (Bdesc&~0xff).  This also
|     handles segments crossing a 32MB root-slot boundary, which the 030
|     single-region assumption could not.
|   * garbage-slot guards ([pages_base,pages_end) frame check) on the OLD tree's
|     A/B descriptors, verbatim from hat_chgprot040 -- unported-030 relics
|     (hat_exec FFFFFFFF fills) must read as ABSENT, not be dereferenced.
|   * NEW-SDE build-on-demand: 030 copied old SDE long0 (limit/status) + wrote the
|     table addr at +4; 040 = single long *Bslot = table | UDT(2).
|   * page size: click index >>11&63 -> >>12&63; va step 2048 -> 4096; in-leaf
|     mask 0x1F800 -> 0x3F000 (256KB/leaf); page_get(0x800)/anon_free(...,0x800)
|     -> 0x1000; anon page index (va-base)>>11 -> >>12.
|   * leaf PFN: extract {0:21} -> {0:20}; rebuild pfn<<11|1 -> pfn<<12|1.
|   * UNCHANGED: the +256 reverse-map slot (Model B keeps 512B leaf frags =
|     256B PTEs + 256B p_mapping links), pages[] *60 / /60 arithmetic, every
|     page/anon flag bit op, the whole anon_alloc/swap_xlate/page_lookup/page_get/
|     page_enter/ppcopy/page_abort/wakeprocs control flow, ptdat@(4) 030 packing
|     ((va>>17)*2 -- software state, same as the hat_pteload port), and the
|     "old anon refcnt back to 1 -> clear WP on the OLD pte" tail.
|   * hat_ptalloc flags arg: Part B leaf alloc keeps the original's 2 (HAT_NOSTEAL,
|     bit0 clear = do NOT sleep -> may return 0, handled like the original: give
|     up, return 0).  Part A originally used bare 1 (HAT_CANWAIT) mirroring the
|     hat040.s lazy-root pattern in hat_pteload -- CORRECTED 2026-07-07 to 3
|     (HAT_CANWAIT|HAT_NOSTEAL, see HAT-PTALLOC-AUDIT.md): bare HAT_CANWAIT does
|     NOT disable hat_ptalloc_orig's steal path on alloc failure, and that path is
|     unported 030-tree-format code (8-byte descs, 21-bit PFNs) -- active
|     corruption, not a bounded leak, if it ever fires under memory pressure. Same
|     fix applied to hat_pteload's own root+leaf allocations in hat040.s.
|   * cpusha bc + pflusha at exit: the child's tables must be in RAM before its
|     first HW table walk, and the parent's un-write-protected PTEs (old-anon
|     refcnt==1 tail) must be pushed + ATC-flushed (same coherency rule as
|     hat_pteload/hat_chgprot040).
|
| hat_dup is GLOBAL T -> plain --weaken-symbol in relink-040.sh; this strong def
| wins and as_dup's jsr re-resolves here.  Args: fp@(8)=oldas, fp@(12)=newas.
| Returns 0 (d0) on success and on alloc-failure-give-up (mirrors the original's
| b52d4 behaviour -- missing child mappings just fault in later).
| Frame -208, saves d2-d5 (same as original; restore offset fp@(-224)).
| Register use: d2 = va cursor, d3 = segment end va (inclusive), d0/d1/d4/d5 +
| a0/a1 scratch.  SVR4 gas syntax.

	.text
	.globl	hat_dup
hat_dup:
	linkw	%fp,&-208
	moveml	%d2-%d5,%sp@-

| --- ENTER marker (2026-07-04 NIGHT: rate-limited, was one-shot). A recursive
|     "kstack 0x...!" / KERNEL FAULT panic (NATIVE krnlflt strings, not ours) was
|     seen twice near fork-heavy moments (reboot teardown, login-prompt getty
|     spawns) -- the old one-shot marker only proved hat_dup040 ran ONCE per boot,
|     so a crash log couldn't show which fork (if any) was in flight right before
|     a later panic. Log every call's (pid, oldas, newas, call#) for the first 128
|     calls, then every 64th -- same convention as hardbus/getdents (first-N +
|     every-Nth), generous enough that a crash-adjacent boot log now carries
|     recent hat_dup context instead of just the first fork of the session. ---
	addql	&1,Lhd_n
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lhd_nodbg
	movel	Lhd_n,%d0
	cmpil	&128,%d0
	blsw	Lhd_log			| first 128 -> log
	andil	&0x3f,%d0
	bnew	Lhd_nodbg		| not every 64th -> skip
Lhd_log:
	movel	%fp@(12),%sp@-		| newas
	movel	%fp@(8),%sp@-		| oldas
	moveal	u+0x730,%a0		| curproc
	moveal	%a0@(264),%a0		| p_pidp
	movel	%a0@(4),%sp@-		| pid
	movel	Lhd_n,%sp@-		| call number
	pea	Lhd_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lhd_nodbg:

| ============================================================================
| Part A -- root skeleton: for every 040 root slot resident in oldas but absent
| in newas, allocate + zero + install a pointer table (hat040.s Lrz pattern).
| Replaces the 030 4-region hat_growsdt loop (b502a-b50bd).
| ============================================================================
	clrl	%fp@(-20)		| Aidx = 0
LhdA_loop:
	moveq	&127,%d0
	cmpl	%fp@(-20),%d0		| Aidx > 127 -> done
	bcsw	LhdA_done
	moveal	%fp@(8),%a0
	moveal	%a0@(20),%a0		| old root (as@(20), hat_alloc040 4KB page)
	movel	%fp@(-20),%d0
	asll	&2,%d0			| Aidx*4   [030: *8]
	movel	%a0@(0,%d0:l),%d1	| old Adesc (single long)
	movel	%d1,%d5
	andil	&3,%d5			| UDT
	bnew	LhdA_res
| old slot absent -> invalidate the new slot (mirrors the 030 bfclr at b5068;
| the new root is hat_alloc040-zeroed anyway, this is belt-and-braces)
	moveal	%fp@(12),%a0
	moveal	%a0@(20),%a0
	movel	%fp@(-20),%d0
	asll	&2,%d0
	clrl	%a0@(0,%d0:l)
	braw	LhdA_next
LhdA_res:
| garbage guard (hat_chgprot040 V2.2 pattern): the table frame must be a managed
| RAM page in [pages_base,pages_end) -- FFFFFFFF relics from unported 030 writers
| (hat_exec) have UDT bits set but an unbacked base; treat as ABSENT.
	andil	&0xfffffe00,%d1
	movel	%d1,%d0
	moveq	&12,%d5
	lsrl	%d5,%d0
	cmpl	pages_base,%d0
	bcsw	LhdA_next
	cmpl	pages_end,%d0
	bccw	LhdA_next
| new slot already resident? (fresh fork root is all-zero, but be idempotent)
	moveal	%fp@(12),%a0
	moveal	%a0@(20),%a0
	movel	%fp@(-20),%d0
	asll	&2,%d0
	movel	%a0@(0,%d0:l),%d1
	andil	&3,%d1
	bnew	LhdA_next
| allocate a whole 4KB page as the pointer table (Model-B hat_ptalloc = page_get,
| page-aligned => 512-aligned; flags=3: HAT_CANWAIT|HAT_NOSTEAL -- sleep for
| memory, never steal (see the header note: bare CANWAIT permits the unsafe
| 030-format steal path on alloc failure)
	pea	3
	movel	%fp,%d0
	subil	&76,%d0
	movel	%d0,%sp@-		| &fp@(-76): ptdat out (bookkeeping, discarded)
	jsr	hat_ptalloc
	addqw	&8,%sp
	movel	%a0,%d1			| table = RETURN VALUE (fp@(-76) is the ptdat!)
	bnew	LhdA_have
	clrl	%d0			| no memory -> give up like the original's
	braw	Lhd_out			| Part B alloc-fail path (return 0)
LhdA_have:
	movel	%d1,%fp@(-28)		| stash table VA
	moveq	&127,%d0
LhdA_z:
	clrl	%a0@+			| zero 128 x 4-byte descriptors (512 B --
	dbra	%d0,LhdA_z		| the page_get path bzeroed only 256 B)
	moveal	%fp@(12),%a0
	moveal	%a0@(20),%a0		| new root (a0/d0 clobbered by the call)
	movel	%fp@(-20),%d0
	asll	&2,%d0
	movel	%fp@(-28),%d1
	oril	&2,%d1			| UDT = 2 (resident pointer-table descriptor)
	movel	%d1,%a0@(0,%d0:l)	| newroot[Aidx] = table | 2
LhdA_next:
	addql	&1,%fp@(-20)
	braw	LhdA_loop
LhdA_done:

| ============================================================================
| Part B -- parallel segment walk (b50be-b57d4), re-walk restructure.
| ============================================================================
	moveal	%fp@(8),%a0
	movel	%a0@(4),%d0		| oldas first seg (circular list head)
	movel	%d0,%fp@(-124)		| old seg cursor
	movel	%d0,%fp@(-116)		| head (loop termination)
	moveal	%fp@(12),%a0
	movel	%a0@(4),%fp@(-132)	| new seg cursor (as_dup built it in lockstep)
| defensive (not in the 030 original): an empty segment list must not walk NULL
	tstl	%d0
	beqw	Lhd_ok

Lhd_seg:
	moveal	%fp@(-124),%a0
	cmpil	&segvn_ops,%a0@(24)	| non-segvn segment (device etc.) -> skip
	beqw	Lhd_isvn
	braw	Lhd_nextseg
Lhd_isvn:
	moveal	%fp@(-124),%a0
	movel	%a0@(28),%fp@(-140)	| old svd = seg->s_data
	moveal	%fp@(-140),%a0
	tstb	%a0@(2)			| svd@(2) != 0 -> skip whole segment (verbatim)
	beqw	Lhd_svdok
	braw	Lhd_nextseg
Lhd_svdok:
| --- doanon mode select (verbatim b5106-b5186): private (svd@(5)==2) AND
|     writable (svd@(3)&2) AND has an anon map (svd@(20)) -> doanon=1 ---
	moveal	%fp@(-140),%a0
	cmpib	&2,%a0@(5)
	bnew	Lhd_noanon
	moveal	%fp@(-140),%a0
	moveb	%a0@(3),%d0
	andib	&2,%d0
	tstb	%d0
	beqw	Lhd_noanon
	moveal	%fp@(-140),%a0
	movel	%a0@(20),%d0
	movel	%d0,%fp@(-156)		| old amp
	tstl	%d0
	beqw	Lhd_noanon
	moveq	&1,%d4
	movel	%d4,%fp@(-92)		| doanon = 1
	moveal	%fp@(-132),%a0
	movel	%a0@(28),%fp@(-148)	| new svd
	moveal	%fp@(-148),%a0
	movel	%a0@(20),%fp@(-164)	| new amp
	braw	Lhd_vasetup
Lhd_noanon:
	clrl	%fp@(-92)		| doanon = 0
Lhd_vasetup:
	moveal	%fp@(-124),%a0
	movel	%a0@(4),%d2		| d2 = va = seg base
	movel	%d2,%d3
	addl	%a0@(8),%d3
	subql	&1,%d3			| d3 = seg end (inclusive last byte)

| --- chunk loop: re-walk both trees at va (hat_chgprot040 Lcp_chkmore/Lcp_walk
|     pattern; one iteration covers up to one 256KB leaf's worth of pages) ---
Lhd_chunk:
	cmpl	%d2,%d3
	bcsw	Lhd_nextseg		| d3 < va -> segment done
| recompute the anon-slot cursors from va (the 030 original recomputed them only
| on absent chunks, b5236-b527e, and advanced them per page otherwise; they are a
| pure function of va, so recomputing every chunk is equivalent)
	tstl	%fp@(-92)
	beqw	Lhd_walko
	moveal	%fp@(-124),%a0
	movel	%d2,%d0
	subl	%a0@(4),%d0
	movel	%d0,%d5
	moveq	&12,%d4
	asrl	%d4,%d5			| pageidx = (va - segbase) >> 12  [030: >>11]
	movel	%d5,%fp@(-188)
	moveal	%fp@(-156),%a0		| old amp
	moveal	%fp@(-140),%a1		| old svd
	movel	%a1@(16),%d0
	addl	%fp@(-188),%d0
	asll	&2,%d0
	movel	%a0@(8),%d4
	addl	%d0,%d4
	movel	%d4,%fp@(-172)		| old anon slot = amp@(8)+(svd@(16)+pgidx)*4
	moveal	%fp@(-164),%a0		| new amp
	moveal	%fp@(-148),%a1		| new svd
	movel	%a1@(16),%d0
	addl	%fp@(-188),%d0
	asll	&2,%d0
	movel	%a0@(8),%d4
	addl	%d0,%d4
	movel	%d4,%fp@(-180)		| new anon slot
Lhd_walko:
| --- OLD tree walk: A level ---
	moveal	%fp@(8),%a0
	moveal	%a0@(20),%a1		| old root
	movel	%d2,%d0
	moveq	&25,%d4
	lsrl	%d4,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a1@(0,%d0:l),%d1	| old Adesc
	movel	%d1,%d5
	andil	&3,%d5			| UDT
	bnew	Lhd_aok
Lhd_nextA:
	movel	%d2,%d0			| A absent/garbage -> next 32MB boundary
	andil	&0xfe000000,%d0
	addil	&0x2000000,%d0
	movel	%d0,%d2
	braw	Lhd_chunk
Lhd_aok:
	andil	&0xfffffe00,%d1		| old Btable = Adesc & ~0x1ff
	movel	%d1,%d0
	moveq	&12,%d4
	lsrl	%d4,%d0
	cmpl	pages_base,%d0		| garbage-frame guard (hat_chgprot040 V2.2)
	bcsw	Lhd_nextA
	cmpl	pages_end,%d0
	bccw	Lhd_nextA
	movel	%d2,%d0
	moveq	&18,%d4
	lsrl	%d4,%d0
	andil	&0x7f,%d0
	asll	&2,%d0			| Bidx*4   [030: (va>>17&0x1fff)*8]
	addl	%d0,%d1
	moveal	%d1,%a0
	movel	%a0@,%d1		| old Bdesc
	movel	%d1,%d0
	andil	&3,%d0			| UDT
	bnew	Lhd_bok
Lhd_nextB:
	movel	%d2,%d0			| B absent/garbage -> next 256KB boundary
	andil	&0xfffc0000,%d0		| [030: 128KB, b5222]
	addil	&0x40000,%d0
	movel	%d0,%d2
	braw	Lhd_chunk
Lhd_bok:
	andil	&0xffffff00,%d1		| old leaf base = Bdesc & ~0xff
	movel	%d1,%d0
	moveq	&12,%d4
	lsrl	%d4,%d0
	cmpl	pages_base,%d0		| same guard for the leaf frame
	bcsw	Lhd_nextB
	cmpl	pages_end,%d0
	bccw	Lhd_nextB
	movel	%d2,%d0
	moveq	&12,%d4
	lsrl	%d4,%d0
	moveq	&63,%d4
	andl	%d4,%d0			| Pidx = (va>>12)&63  [030: >>11&63]
	movel	%d0,%fp@(-12)
	asll	&2,%d0
	addl	%d0,%d1
	movel	%d1,%fp@(-60)		| &old leaf PTE
| --- NEW tree walk: A level (Part A guarantees residence when old is resident,
|     but stay defensive: absent -> skip the chunk, the child page just faults) ---
	moveal	%fp@(12),%a0
	moveal	%a0@(20),%a1		| new root
	movel	%d2,%d0
	moveq	&25,%d4
	lsrl	%d4,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a1@(0,%d0:l),%d1	| new Adesc
	movel	%d1,%d0
	andil	&3,%d0
	beqw	Lhd_nextB		| (defensive, see above)
	andil	&0xfffffe00,%d1		| new Btable
	movel	%d2,%d0
	moveq	&18,%d4
	lsrl	%d4,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	addl	%d0,%d1
	movel	%d1,%fp@(-52)		| &new Bdesc
	moveal	%d1,%a0
	bfextu	%a0@(3){&6:&2},%d0	| UDT of new Bdesc
	tstl	%d0
	bnew	Lhd_newbok

| --- new Bdesc absent: allocate a leaf table (verbatim b52b6-b5320, 040 build).
|     flags=2 (verbatim): no-steal + no-sleep -> may fail; original gives up
|     with return 0 (missing child mappings fault in later). ---
	pea	2
	moveq	&-76,%d0
	addl	%fp,%d0
	movel	%d0,%sp@-
	jsr	hat_ptalloc		| hat_ptalloc(&ptdat, 2)
	movel	%a0,%fp@(-68)		| new leaf table (4KB page; first 256 B zeroed)
	addqw	&8,%sp
	tstl	%fp@(-68)
	bnew	Lhd_ptok
	clrl	%d0
	braw	Lhd_out			| verbatim b52d4: alloc failed -> return 0
Lhd_ptok:
| ptdat bookkeeping (verbatim b52da-b5302; @(4) keeps the 030 packing, same
| TODO as the hat_pteload port -- hat_pt2ptdat/hat_ptfree read it consistently)
	moveal	%fp@(-76),%a0
	movel	%fp@(12),%a0@		| ptdat@(0) = newas
	moveal	%fp@(-76),%a0
	movel	%d2,%d0
	moveq	&17,%d4
	lsrl	%d4,%d0
	movew	%d0,%d0
	movew	%d0,%d4
	lslw	&1,%d4
	movew	%d4,%a0@(4)		| ptdat@(4) = (va>>17)*2  [030 packing]
	moveal	%fp@(-76),%a0
	clrb	%a0@(6)			| in-use count 0 (incremented per copied PTE)
	moveal	%fp@(-76),%a0
	clrb	%a0@(7)			| lock count 0
| install the 040 pointer descriptor  [030: copy old SDE long0+long1, then
| overwrite the addr word -- b5306-b531a; 040 tables carry no limit/status]
	moveal	%fp@(-52),%a0
	movel	%fp@(-68),%d0
	oril	&2,%d0			| UDT = 2 (resident)
	movel	%d0,%a0@		| *newBdesc = leaftable | 2
	braw	Lhd_join
Lhd_newbok:
| new leaf table exists: base from the single long  [030: SDE@(4), b5324-b5342]
	moveal	%fp@(-52),%a0
	movel	%a0@,%d0
	andil	&0xffffff00,%d0
	movel	%d0,%fp@(-68)
	moveq	&-84,%d0
	addl	%fp,%d0
	movel	%d0,%sp@-
	movel	%fp@(-68),%sp@-
	jsr	hat_pt2ptdat		| hat_pt2ptdat(table, &fp@(-84))
	movel	%a0,%fp@(-76)		| ptdat
	addqw	&8,%sp
Lhd_join:
	movel	%fp@(-12),%d0
	asll	&2,%d0
	addl	%d0,%fp@(-68)		| &new leaf PTE = table + Pidx*4

| --- per-PTE loop (verbatim b534e-b5782 except the documented swaps) ---
Lhd_pte:
	moveal	%fp@(-60),%a0
	bfextu	%a0@(3){&7:&1},%d0	| old PTE bit0 (resident) -- same bit on 040
	tstl	%d0
	bnew	Lhd_valid
	braw	Lhd_adv			| absent -> just advance
Lhd_valid:
	tstl	%fp@(-92)
	beqw	Lhd_share		| doanon==0 -> share the PTE
	moveal	%fp@(-172),%a0
	tstl	%a0@
	beqw	Lhd_share		| no old anon here (file page) -> share
| --- private-anon copy path (verbatim b5374-b5706) ---
	jsr	anon_alloc
	movel	%a0,%d0
	moveal	%fp@(-180),%a0
	movel	%d0,%a0@		| *newslot = fresh anon
	moveal	%fp@(-180),%a0
	tstl	%a0@
	bnew	Lhd_anok
	clrl	%fp@(-92)		| anon_alloc failed -> fall back to sharing
	moveal	%fp@(-180),%a0		| (for the REST of the segment, verbatim)
	moveal	%fp@(-172),%a1
	movel	%a1@,%a0@		| *newslot = *oldslot
	braw	Lhd_share
Lhd_anok:
	movel	%fp,%d0
	addil	&-204,%d0
	movel	%d0,%sp@-		| &off
	movel	%fp,%d0
	addil	&-196,%d0
	movel	%d0,%sp@-		| &vp
	moveal	%fp@(-180),%a0
	movel	%a0@,%sp@-
	jsr	swap_xlate		| swap_xlate(anon, &vp, &off)
	addaw	&12,%sp
Lhd_lookup:
	movel	%fp@(-204),%sp@-
	movel	%fp@(-196),%sp@-
	jsr	page_lookup		| page_lookup(vp, off)
	movel	%a0,%fp@(-100)		| new pp
	addqw	&8,%sp
	tstl	%fp@(-100)
	bnew	Lhd_found
	clrl	%sp@-
	pea	0x1000			| page_get(4096, 0)  [030: 0x800]
	jsr	page_get
	movel	%a0,%fp@(-100)
	addqw	&8,%sp
	tstl	%fp@(-100)
	bnew	Lhd_enter
| page_get failed: release the fresh anon, revert to sharing (verbatim b53f8-b5458)
	clrl	%fp@(-92)
	moveal	%fp@(-180),%a0
	movel	%a0@,%d0
	moveal	%d0,%a0
	andiw	&-2,%a0@(12)		| anon@(12) &= ~1 (unlock)
	moveal	%fp@(-180),%a0
	moveal	%a0@,%a0
	movew	%a0@(12),%d0
	andiw	&2,%d0
	tstw	%d0
	beqw	Lhd_anfree
	moveal	%fp@(-180),%a0
	movel	%a0@,%d0
	moveal	%d0,%a0
	andiw	&-3,%a0@(12)		| clear "wanted"
	pea	1
	moveal	%fp@(-180),%a0
	movel	%a0@,%sp@-
	jsr	wakeprocs
	addqw	&8,%sp
Lhd_anfree:
	pea	0x1000			| anon_free(&slot, 4096)  [030: 0x800]
	movel	%fp@(-180),%sp@-
	jsr	anon_free
	moveal	%fp@(-180),%a0
	moveal	%fp@(-172),%a1
	movel	%a1@,%a0@		| *newslot = *oldslot (share fallback)
	addqw	&8,%sp
	braw	Lhd_share
Lhd_enter:
	movel	%fp@(-204),%sp@-
	movel	%fp@(-196),%sp@-
	movel	%fp@(-100),%sp@-
	jsr	page_enter		| page_enter(pp, vp, off)
	addaw	&12,%sp
	tstl	%d0
	beqw	Lhd_gotpage		| 0 = entered -> proceed with the fresh page
| page_enter raced (someone else entered vp/off): release ours, retry the lookup
| (verbatim b547a-b54ea)
	moveal	%fp@(-100),%a0
	subqw	&1,%a0@(2)		| hold--
	tstw	%a0@(2)
	bnew	Lhd_pe_rel
Lhd_pe_wake:
	moveal	%fp@(-100),%a0
	bfextu	%a0@{&1:&1},%d0		| "wanted"?
	tstl	%d0
	beqw	Lhd_pe_rel
	pea	1
	movel	%fp@(-100),%sp@-
	jsr	wakeprocs
	moveal	%fp@(-100),%a0
	andib	&-65,%a0@
	addqw	&8,%sp
	braw	Lhd_pe_wake
Lhd_pe_rel:
	moveal	%fp@(-100),%a0
	tstw	%a0@(2)
	bnew	Lhd_lookup		| still held elsewhere -> retry lookup
	moveal	%fp@(-100),%a0
	bfextu	%a0@{&4:&1},%d0
	tstl	%d0
	bnew	Lhd_pe_ab
	moveal	%fp@(-100),%a0
	tstl	%a0@(4)
	beqw	Lhd_pe_ab
	braw	Lhd_lookup
Lhd_pe_ab:
	movel	%fp@(-100),%sp@-
	jsr	page_abort
	addqw	&4,%sp
	braw	Lhd_lookup
| page_lookup found an existing page: hold it, wait it unlocked, lock it
| (verbatim b54f2-b5520)
Lhd_found:
	moveal	%fp@(-100),%a0
	addqw	&1,%a0@(2)		| hold++  [orig: addqw #2,a0; addqw #1,a0@]
Lhd_fw:
	moveal	%fp@(-100),%a0
	bfextu	%a0@{&0:&1},%d0		| locked?
	tstl	%d0
	beqw	Lhd_flock
	movel	%fp@(-100),%sp@-
	jsr	page_cv_wait
	addqw	&4,%sp
	braw	Lhd_fw
Lhd_flock:
	moveal	%fp@(-100),%a0
	orib	&-128,%a0@		| lock it
Lhd_gotpage:
| attach the page to the fresh anon + copy the contents (verbatim b5524-b5706)
	moveal	%fp@(-180),%a0
	moveal	%a0@,%a0
	movel	%fp@(-100),%a0@(4)	| anon->an_page = pp
	moveal	%fp@(-100),%a0
	orib	&16,%a0@
	moveal	%fp@(-100),%a0
	orib	&1,%a0@
| old pp from the old PTE's pfn, guarded by the pages[] range (b5540-b558c)
	moveal	%fp@(-60),%a0
	bfextu	%a0@{&0:&20},%d0	| old pfn  [030: {0:21}]
	cmpl	pages_base,%d0
	bcsw	Lhd_oldnull
	moveal	%fp@(-60),%a0
	bfextu	%a0@{&0:&20},%d0
	cmpl	pages_end,%d0
	bccw	Lhd_oldnull
	braw	Lhd_oldcalc
Lhd_oldnull:
	clrl	%fp@(-108)		| out of range -> oldpp = NULL (ppcopy zero-fills)
	braw	Lhd_copy
Lhd_oldcalc:
	moveal	%fp@(-60),%a0
	bfextu	%a0@{&0:&20},%d0	| [030: {0:21}]
	subl	pages_base,%d0
	moveq	&60,%d4
	mulsl	%d4,%d0
	movel	pages,%d4
	addl	%d0,%d4
	movel	%d4,%fp@(-108)		| oldpp = pages + (pfn-pages_base)*60
Lhd_copy:
| --- one-shot marker: the FIRST real private-page duplication (the code path the
|     old stub never ran; confirms plain-fork COW dup actually happens) ---
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lhd_cnodbg
	movel	Lhd_cn,%d0
	bnew	Lhd_cnodbg
	moveq	&1,%d0
	movel	%d0,Lhd_cn
	movel	%fp@(-100),%sp@-	| newpp
	movel	%fp@(-108),%sp@-	| oldpp
	movel	%d2,%sp@-		| va
	pea	Lhd_cmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lhd_cnodbg:
	movel	%fp@(-100),%sp@-
	movel	%fp@(-108),%sp@-
	jsr	ppcopy			| ppcopy(oldpp, newpp)
	moveal	%fp@(-100),%a0
	orib	&4,%a0@			| mark modified
	moveal	%fp@(-100),%a0
	andib	&-17,%a0@
	moveal	%fp@(-100),%a0
	andib	&-2,%a0@
| write the child PTE: pfn(newpp)<<12 | 1  [030: <<11, b55b6-b55d8]
	moveal	%fp@(-68),%a0
	movel	%fp@(-100),%d0
	subl	pages,%d0
	moveq	&60,%d4
	divsll	%d4,%d0,%d0		| pfn = (pp - pages)/60 + pages_base
	addl	pages_base,%d0
	moveq	&12,%d4			| [030: #11]
	lsll	%d4,%d0
	moveq	&1,%d4
	orl	%d0,%d4
	orl	hat_cm_ram,%d4		| CM-B1: explicit managed-RAM stage class (0x00 WT in
					|   B1, 0x20 CB in B2 -- hat040.s data global; matrix
					|   "hat_dup private child leaf" row)
	movel	%d4,%a0@		| *newpte = pfn<<12 | 1 | CM (writable resident)
| register the new PTE in newpp's p_mapping reverse-map (verbatim; +256 = Model B
| unchanged 512B frag layout)
	moveal	%fp@(-68),%a0
	addaw	&256,%a0
	moveal	%fp@(-100),%a1
	movel	%a1@(32),%a0@		| newpte.next = newpp->p_mapping
	moveal	%fp@(-100),%a0
	movel	%fp@(-68),%a0@(32)	| newpp->p_mapping = &newpte
	movel	%fp@(-76),%d0
	moveal	%d0,%a0
	addqb	&1,%a0@(6)		| ptdat in-use++
	moveal	%fp@(12),%a0
	addql	&1,%a0@(16)		| newas rss++
	moveal	%fp@(-100),%a0
	andib	&127,%a0@		| unlock newpp
	addqw	&8,%sp			| pop the ppcopy args (verbatim placement)
Lhd_w1:
	moveal	%fp@(-100),%a0
	bfextu	%a0@{&1:&1},%d0		| wanted?
	tstl	%d0
	beqw	Lhd_rel
	moveal	%fp@(-100),%a0
	andib	&-65,%a0@
	pea	1
	movel	%fp@(-100),%sp@-
	jsr	wakeprocs
	addqw	&8,%sp
	braw	Lhd_w1
Lhd_rel:
	moveal	%fp@(-100),%a0
	subqw	&1,%a0@(2)		| hold--
	tstw	%a0@(2)
	bnew	Lhd_anrel
Lhd_w2:
	moveal	%fp@(-100),%a0
	bfextu	%a0@{&1:&1},%d0
	tstl	%d0
	beqw	Lhd_relab
	pea	1
	movel	%fp@(-100),%sp@-
	jsr	wakeprocs
	moveal	%fp@(-100),%a0
	andib	&-65,%a0@
	addqw	&8,%sp
	braw	Lhd_w2
Lhd_relab:
	moveal	%fp@(-100),%a0
	tstw	%a0@(2)
	bnew	Lhd_anrel
	moveal	%fp@(-100),%a0
	bfextu	%a0@{&4:&1},%d0
	tstl	%d0
	bnew	Lhd_doab
	moveal	%fp@(-100),%a0
	tstl	%a0@(4)
	beqw	Lhd_doab
	braw	Lhd_anrel
Lhd_doab:
	movel	%fp@(-100),%sp@-
	jsr	page_abort
	addqw	&4,%sp
Lhd_anrel:
| release the fresh anon's lock + wake (verbatim b56aa-b56ea)
	moveal	%fp@(-180),%a0
	movel	%a0@,%d0
	moveal	%d0,%a0
	andiw	&-2,%a0@(12)
	moveal	%fp@(-180),%a0
	moveal	%a0@,%a0
	movew	%a0@(12),%d0
	andiw	&2,%d0
	tstw	%d0
	beqw	Lhd_oldref
	moveal	%fp@(-180),%a0
	movel	%a0@,%d0
	moveal	%d0,%a0
	andiw	&-3,%a0@(12)
	pea	1
	moveal	%fp@(-180),%a0
	movel	%a0@,%sp@-
	jsr	wakeprocs
	addqw	&8,%sp
Lhd_oldref:
| old anon refcnt--; back to 1 => sole owner again => clear the COW
| write-protect on the OLD (parent) PTE (verbatim b56ec-b5704)
	moveal	%fp@(-172),%a0
	moveal	%a0@,%a0
	subql	&1,%a0@
	moveq	&1,%d4
	cmpl	%a0@,%d4
	bnew	Lhd_adv
	movel	%fp@(-60),%d0
	moveal	%d0,%a0
	moveq	&-5,%d4
	andl	%d4,%a0@		| clear bit2 (WP) -- PTE bit ops unchanged on 040
	braw	Lhd_adv

| --- share path (doanon==0 or no anon slot): copy the PTE + splice it into the
|     page's p_mapping chain right after the old PTE (verbatim b570a-b5740) ---
Lhd_share:
	moveal	%fp@(-68),%a0
	moveal	%fp@(-60),%a1
	movel	%a1@,%a0@		| *newpte = *oldpte
	moveal	%fp@(-68),%a0
	addaw	&256,%a0
	moveal	%fp@(-60),%a1
	addaw	&256,%a1
	movel	%a1@,%a0@		| newpte.next = oldpte.next
	moveal	%fp@(-60),%a0
	addaw	&256,%a0
	movel	%fp@(-68),%a0@		| oldpte.next = &newpte
	movel	%fp@(-76),%d0
	moveal	%d0,%a0
	addqb	&1,%a0@(6)		| ptdat in-use++
	moveal	%fp@(12),%a0
	addql	&1,%a0@(16)		| newas rss++

| --- advance one page (verbatim b5746-b5782, Model B steps) ---
Lhd_adv:
	addql	&4,%fp@(-60)		| old pte++
	addql	&4,%fp@(-68)		| new pte++
	addql	&4,%fp@(-172)		| old anon slot++
	addql	&4,%fp@(-180)		| new anon slot++
	addil	&4096,%d2		| va += 4KB  [030: 2048]
	tstl	kprunrun
	beqw	Lhd_nopre
	jsr	preempt
Lhd_nopre:
	movel	%d2,%d0
	andil	&0x3f000,%d0		| in-leaf page bits 17:12  [030: 0x1f800]
	tstl	%d0
	beqw	Lhd_chunk		| crossed a 256KB leaf boundary -> re-walk
	cmpl	%d2,%d3
	bcsw	Lhd_chunk		| va > end -> chunk loop exits at the top
	braw	Lhd_pte

| --- next segment pair (verbatim b57a4-b57ca; list is circular, stop at head) ---
Lhd_nextseg:
	moveal	%fp@(-132),%a0
	movel	%a0@(16),%fp@(-132)	| new seg = new seg->next
	moveal	%fp@(-124),%a0
	movel	%a0@(16),%d1
	movel	%d1,%fp@(-124)		| old seg = old seg->next
	cmpl	%fp@(-116),%d1
	beqw	Lhd_ok			| back at the head -> done
	braw	Lhd_seg

Lhd_ok:
	clrl	%d0			| success
Lhd_out:
| 68040 page-table coherency (hat_pteload/hat_chgprot040 rule): push the child's
| new tables + the parent's un-write-protected PTEs to RAM, flush the ATC.
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
	moveml	%fp@(-224),%d2-%d5
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple (adjust as needed)

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lhd_msg:
	.asciz	"DBG hat_dup040 ENTER n=%x pid=%d oldas=%x newas=%x"
	.even
Lhd_cmsg:
	.asciz	"DBG hat_dup040 first private-page copy va=%x oldpp=%x newpp=%x"
	.even
Lhd_n:
	.long	0
Lhd_cn:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
