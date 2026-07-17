| hatalloc_dbg.s -- catch the PT-allocator that DOUBLE-returns sh's already-mapped data page.
|
| CONFIRMED 2026-06-26 PM: sh's bss data page (e.g. pfn 7CAB) stays mapped at 0x80010000 but its
| physical RAM is overwritten 0 -> 0xFFFFFFFF DURING sh's run (u_trap crash-probe).  0xFFFFFFFF is
| the hat invalid-PT-descriptor fill pattern, so a page-table allocator handed out sh's IN-USE data
| page (a page-free-list / page-struct accounting bug from fork's 040-no-op hat_dup + the child-exit
| hat_free040 teardown).
|
| Detector: assegat_dbg.s's as_fault wrapper records sh's data-page PHYS base in g_shdatabase (when
| sh faults its data segment [0x8000f000,0x80012000)).  These wrappers compare each hat_sdtalloc /
| hat_ptalloc allocation's phys base to g_shdatabase; a MATCH = the double-allocation.  We log the
| CALLER (return address on entry stack = fp@(4)) so the allocation PATH is identified
| (hat_pteload? hat_growsdt? hat_dup?).  Both are GLOBAL T -> --weaken-symbol + _orig aliases.
| hat_sdtalloc preserves d2(va)/a2(pp) for its caller; we save/restore d2-d3/a2 so the contract holds.

	.data
	.even
	.globl	g_shdatabase
g_shdatabase:
	.long	0
	.globl	g_shdatapp
g_shdatapp:
	.long	0			| page struct (pages + (pfn-pages_base)*60) for sh's data page
	.globl	g_shdataleaf
g_shdataleaf:
	.long	0			| &leaf of sh's data page (assegat_dbg records it with the base)
Lpf_n:
	.long	0
Lhsd_n:
	.long	0
Lhpa_n:
	.long	0
g_pageget_n:
	.long	0			| bumped by the page_get wrapper on every call
	.globl	g_pagefree_n
g_pagefree_n:
	.long	0			| bumped by the page_free wrapper on every call
	.globl	g_ptalloc_n
g_ptalloc_n:
	.long	0			| bumped by the hat_ptalloc wrapper on every call
	.globl	g_sdtalloc_n
g_sdtalloc_n:
	.long	0			| bumped by the hat_sdtalloc wrapper on every call
Lsd_save:
	.long	0			| g_pageget_n snapshot at hat_sdtalloc entry
	.even
Lhsd_msg:
	.asciz	"DBG sdtalloc DOUBLE base=%x == shdata caller=%x pgdelta=%x"
	.even
Lhpa_msg:
	.asciz	"DBG ptalloc DOUBLE base=%x == shdata caller=%x"
	.even
Lhpa_live_msg:
	.asciz	"DBG ptalloc DOUBLE-LIVE *leaf=%x -- sh's PTE STILL MAPS the new PT page (ILLEGAL reuse)"
	.even
Lhpa_stale_msg:
	.asciz	"DBG ptalloc DOUBLE-STALE *leaf=%x -- sh's leaf moved on (legit recycle)"
	.even
Lpf_msg:
	.asciz	"DBG page_free SH DATA pp=%x caller=%x grandcaller=%x (who reclaimed)"
	.even
Lpu_n:
	.long	0
Lpu_msg:
	.asciz	"DBG hat_pageunload CALLED on crash page pp=%x p_mapping=%x (0=>page_abort SKIPS unmap)"
	.even
Lml_n:
	.long	0
Lml_msg:
	.asciz	"DBG hat_memload crash-page va=%x pp=%x p_mapping=%x (after map; 0=>never registered)"
	.even
Lpa_n:
	.long	0
Lpa_msg:
	.asciz	"DBG page_abort crash pp=%x p_mapping=%x caller=%x (0=>SKIPs hat_pageunload, PTE stays)"
	.even
Lpa_ln:
	.long	0
Lpa_lmsg:
	.asciz	"DBG LIVEABORT pp=%x pmap=%x keep=%x vp=%x off=%x c=%x gc=%x ggc=%x"
	.even
Lsu_n:
	.long	0
Lsu_msg:
	.asciz	"DBG segvn_unmap seg=%x as=%x addr=%x len=%x (which segment frees the shared page?)"
	.even
Lad_n:
	.long	0
Lad_msg:
	.asciz	"DBG anon_decref ap=%x an_refcnt=%x caller=%x (1=>frees page; if child still maps it, fork anon_dup missed the refcnt bump)"
	.even
Lgr_n:
	.long	0
Lgr_n2:
	.long	0
	.even
Lgr_msg:
	.asciz	"DBG grow ENTER sp=%x stkbase=%x stksize=%x rlim=%x"
	.even
Lgr_rmsg:
	.asciz	"DBG grow EXIT ret=%x (1=grown, 0=FAIL->SIGSEGV/BUS)"
	.even

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
| segvn_unmap (0xab63c) wrapper -- log (seg, seg->s_as, addr, len) for every unmap, capped 16, so
| we can see WHICH segment's teardown reaches anon_free->anon_decref->page_abort(crash page).  The
| rogue one's [addr,addr+len) does NOT cover 0x80010000 (so its hat_unload leaves sh's PTE resident)
| yet its anon array SHARES the crash page -> the shared-anon refcount was 1 not 2.  s_as is at
| seg+0 (seg->s_base@? ) -- 3b2 struct seg: s_base, s_size, s_as, ... ; we dump seg@(8)=s_as (best
| effort) plus addr/len.  Tail-calls segvn_unmap_orig (seg@8, addr@12, len@16).
	.globl	segvn_unmap
segvn_unmap:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	Lsu_n,%d0
	cmpil	&16,%d0
	bccw	Lsu_tail
	addql	&1,%d0
	movel	%d0,Lsu_n
	moveal	%fp@(8),%a2		| seg
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| addr
	movel	%a2@(8),%sp@-		| seg->s_as (offset 8)
	movel	%a2,%sp@-		| seg
	pea	Lsu_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lsu_tail:
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| seg
	jsr	segvn_unmap_orig
	lea	%sp@(12),%sp
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
| page_abort (0xaf8d6) wrapper -- logs pp->p_mapping AT ENTRY for the crash page (pp==g_shdatapp),
| i.e. at the moment page_abort decides whether to call hat_pageunload (only if p_mapping!=0).
| hat_memload showed p_mapping was SET at map time; if page_abort sees p_mapping==0 here, something
| CLEARED it between map and reclaim (so the unmap is skipped and the 040 PTE stays resident on the
| freed page).  Tail-calls page_abort_orig.  Cap 6.
	.globl	page_abort
page_abort:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	moveal	%fp@(8),%a2		| pp
	movel	%a2,%d2
| --- ISSUE-7 TRIPWIRE (LIVEABORT), NARROWED 2026-07-06: fires ONLY on p_keepcnt != 0.
|     Codex static analysis established that page_abort on a page with p_mapping!=0 &&
|     p_keepcnt==0 is NORMAL contract (page_abort itself calls hat_pageunload then
|     page_free), so the old `p_mapping!=0 OR keepcnt!=0` gate yielded benign false
|     positives from pvn_vptrunc -- p_mapping alone is NOT corruption.  The real anomaly
|     (the segu-class bug) is aborting a still-HELD page: keepcnt != 0.  Prime suspect:
|     segu_get's page_enter-retry (caller ret-addr 0xaa5fa) aborting another proc's live
|     u-page when a double-allocated anon slot collides.  Cap 8. ---
	tstw	%a2@(2)			| p_keepcnt held? (the only anomaly gate now)
	beqw	Lpa_norm
	movel	Lpa_ln,%d0
	cmpil	&12,%d0
	bccw	Lpa_norm
	addql	&1,%d0
	movel	%d0,Lpa_ln
| frame walk two levels up (all 8 LIVEABORTs came from anon_decref+0x42 -- we need WHO
| called anon_decref and who called THAT): gc = (*(fp))@4, ggc = (*(*(fp)))@4, guarded.
	moveal	%fp@(0),%a0		| a0 = caller's frame (e.g. anon_decref_orig's fp)
	movel	%a0,%d0
	beqw	Lpa_g0
	btst	&0,%d0
	bnew	Lpa_g0
	moveal	%a0@(0),%a1		| a1 = grandcaller's frame
	movel	%a1,%d0
	beqw	Lpa_g1
	btst	&0,%d0
	bnew	Lpa_g1
	movel	%a1@(4),%sp@-		| ggc
	movel	%a0@(4),%sp@-		| gc
	braw	Lpa_gdone
Lpa_g1:
	clrl	%sp@-			| ggc unavailable
	movel	%a0@(4),%sp@-		| gc
	braw	Lpa_gdone
Lpa_g0:
	clrl	%sp@-
	clrl	%sp@-
Lpa_gdone:
	movel	%fp@(4),%sp@-		| caller
	movel	%a2@(8),%sp@-		| p_offset (identity)
	movel	%a2@(4),%sp@-		| p_vnode  (identity)
	moveq	&0,%d0
	movew	%a2@(2),%d0
	movel	%d0,%sp@-		| keepcnt
	movel	%a2@(32),%sp@-		| p_mapping
	movel	%d2,%sp@-		| pp
	pea	Lpa_lmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(40),%sp
Lpa_norm:
| --- UNGATED: log EVERY page_abort (pp, p_mapping, caller) capped 40, so we can find the FREE of the
|     crash page struct (this boot: 0x40069BF8) that sets p_free WHILE the live child still maps it
|     -- that free happens BEFORE g_shdatapp tracks it, so the gated probe missed it.  Correlate the
|     crash pp across the timeline: a page_abort(crashpp) BEFORE the child's hat_memload = the
|     use-after-free that double-lists the page. ---
	movel	Lpa_n,%d0
	cmpil	&40,%d0
	bccw	Lpa_tail
	addql	&1,%d0
	movel	%d0,Lpa_n
	movel	%fp@(4),%sp@-		| caller
	movel	%a2@(32),%sp@-		| p_mapping at entry
	movel	%d2,%sp@-		| pp
	pea	Lpa_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
| --- walk the frame chain ABOVE page_abort ONLY for the crash page (keep output small) ---
	tstl	g_shdatapp
	beqw	Lpa_tail
	movel	%fp@(8),%d0
	cmpl	g_shdatapp,%d0
	bnew	Lpa_tail
	pea	0x2e			| '.' separator before the stack
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	%fp@(0),%a2		| a2 = anon_decref's fp
	movel	&4,%d2			| 4 levels
Lpa_stk:
	tstl	%a2
	beqw	Lpa_tail
	movel	%a2@(4),%sp@-		| return addr at this level
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x20
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	%a2@(0),%a2		| up one frame
	subql	&1,%d2
	bnew	Lpa_stk
Lpa_tail:
	movel	%fp@(8),%sp@-		| pp
	jsr	page_abort_orig
	addqw	&4,%sp
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
| hat_memload (0xb4cb0) wrapper -- logs, for a map into the crash page [0x80010000,0x80011000),
| pp->p_mapping AFTER the map completes.  If p_mapping != 0 here but hat_pageunload is NOT called
| later -> something CLEARED p_mapping (without clearing the 040 PTE) between map and reclaim.
| If p_mapping == 0 here -> hat_pteload never registered the mapping (e.g. pp not passed).
| hat_memload(hat@8, va@12, pp@16, flags@20, arg@24); returns a0.  Cap 8.
	.globl	hat_memload
hat_memload:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	%fp@(24),%sp@-
	movel	%fp@(20),%sp@-
	movel	%fp@(16),%sp@-
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	hat_memload_orig
	lea	%sp@(20),%sp
	movel	%d0,%d2			| save return (a0==d0)
	movel	%fp@(12),%d0		| va
	cmpil	&0x80010000,%d0
	bcsw	Lml_done
	cmpil	&0x80011000,%d0
	bccw	Lml_done
	movel	Lml_n,%d0
	cmpil	&8,%d0
	bccw	Lml_done
	addql	&1,%d0
	movel	%d0,Lml_n
	moveal	%fp@(16),%a2		| pp
	movel	%a2@(32),%sp@-		| p_mapping
	movel	%a2,%sp@-		| pp
	movel	%fp@(12),%sp@-		| va
	pea	Lml_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lml_done:
	moveal	%d2,%a0			| restore return a0
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
| hat_pageunload wrapper -- our 040 hat_pageunload lives in the BASE build (hat040.s, 0xd7b9a).
| This dbg wrapper logs whether it actually runs for the CRASH page (pp == g_shdatapp, now tracking
| ONLY 0x80010000) and what pp->p_mapping is AT ENTRY: p_mapping==0 means hat_pteload never
| registered the mapping -> page_abort's `if(p_mapping) hat_pageunload` SKIPS the unmap -> the 040
| PTE stays resident on the freed page (the bug we still see).  Tail-calls hat_pageunload_orig
| (the real 040 port).  Cap 6.
	.globl	hat_pageunload
hat_pageunload:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	moveal	%fp@(8),%a2		| pp
	movel	%a2,%d2
	tstl	g_shdatapp
	beqw	Lpu_tail
	cmpl	g_shdatapp,%d2
	bnew	Lpu_tail
	movel	Lpu_n,%d0
	cmpil	&6,%d0
	bccw	Lpu_tail
	addql	&1,%d0
	movel	%d0,Lpu_n
	movel	%a2@(32),%sp@-		| p_mapping at entry
	movel	%d2,%sp@-		| pp
	pea	Lpu_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lpu_tail:
	movel	%fp@(8),%sp@-		| pp
	jsr	hat_pageunload_orig
	addqw	&4,%sp
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
| page_free (0xaf9ea) wrapper -- catch the SPURIOUS free of sh's still-mapped data page.  as_fault
| computes g_shdatapp = the page struct for sh's data page; if page_free is called on that exact pp
| while the page is live, THIS is the bug -- the freed page re-enters page_get's free list and gets
| handed to hat_sdtalloc.  Log the caller = the buggy free site (likely hat_sdtfree from a malformed
| fork tree, or relvm/anon teardown).  Cap 6.  Register-transparent (page_free returns void).
	.globl	page_free
page_free:
	addql	&1,g_pagefree_n
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	moveal	%fp@(8),%a2		| pp
	movel	%a2,%d2
	tstl	g_shdatapp
	beqw	Lpf_call
	cmpl	g_shdatapp,%d2
	bnew	Lpf_call
	movel	Lpf_n,%d0
	cmpil	&6,%d0
	bccw	Lpf_call
	addql	&1,%d0
	movel	%d0,Lpf_n
	moveal	%fp@(0),%a2		| a2 = page_abort's fp (our saved fp = caller's fp)
	movel	%a2@(4),%sp@-		| grandcaller = page_abort's return addr = WHO reclaimed pp
	movel	%fp@(4),%sp@-		| caller (= page_abort's jsr site)
	moveal	%fp@(8),%a2		| restore a2 = pp for the dump
	movel	%a2,%sp@-		| pp
	pea	Lpf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lpf_call:
	movel	%fp@(8),%sp@-		| pp
	jsr	page_free_orig
	addqw	&4,%sp
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
| anon_decref (0xad798) wrapper -- the grandcaller that frees the live SH DATA page (page_abort
| stack-walk already showed grandcaller=anon_decref).  This logs (ap, an_refcnt AT ENTRY) for the
| last-reference frees (an_refcnt<=2), but ONLY after g_shdatapp is set (= after sh's data page has
| faulted) so unrelated teardown anons don't flood the cap.  an_refcnt is offset 0 of struct anon
| (svr4-src-3b2 vm/anon.h:30).  Decisive reading: an_refcnt==1 here => anon_decref frees the page as
| its LAST reference; if that page is still 040-mapped in the running child (the SH-DATA page_free/
| page_abort probes fire right after), then the child's mapping was NOT counted -> fork-time anon_dup
| failed to bump the shared anon's refcnt (it should be 2 = parent + child).  an_refcnt==2 here =>
| the bump WAS there and the bug is a double-decref elsewhere.  Cap 16.  anon_decref returns void;
| tail-calls anon_decref_orig(ap@8).
	.globl	anon_decref
anon_decref:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
| NO g_shdatapp gate: anon_decref(old) in anon_private runs BEFORE segvn_faultpage
| -> as_fault sets g_shdatapp, so gating here suppressed the very decref we care about.
| Log ALL decrefs, cap 16 globally.
	moveal	%fp@(8),%a2		| ap
	movel	%a2@(0),%d2		| an_refcnt at entry
	movel	Lad_n,%d0
	cmpil	&16,%d0
	bccw	Lad_call
	addql	&1,%d0
	movel	%d0,Lad_n
	movel	%fp@(4),%sp@-		| caller
	movel	%d2,%sp@-		| an_refcnt
	movel	%a2,%sp@-		| ap
	pea	Lad_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lad_call:
	movel	%fp@(8),%sp@-		| ap
	jsr	anon_decref_orig
	addqw	&4,%sp
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
| page_get (0xaffa4) wrapper -- counts calls (for hat_sdtalloc's double-page discrimination)
| AND -- ISSUE-10 v5 (2026-07-10) -- catches the FREE-LIST DOUBLE-ALLOCATION in the act:
| SEGVPP proved the corrupt phys page is simultaneously a live file page (vn/off set,
| mod+ref) AND still carries sh's heap PTE in p_mapping (leaf entry 0x11*4 = VA 0x80011000,
| math-verified).  A page handed out by page_get with p_mapping != 0 is that exact bug
| firing (a MAPPED page must never be on the free list).  Log the first 8 with the caller.
| page_get(size, flags) RETURNS THE PAGE IN %a0 (callers do `movel %a0,...`); d0 mirrored.
	.globl	page_get
page_get:
	addql	&1,g_pageget_n
	linkw	%fp,&0
	movel	%a2,%sp@-
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	page_get_orig
	addqw	&8,%sp
	moveal	%a0,%a2			| a2 = returned pp
	movel	%a0,%d0
	cmpil	&0x40000000,%d0		| NULL / non-kvseg -> done
	bcsw	Lpg_out
	tstl	%a2@(32)		| p_mapping on a freshly allocated page?!
	beqw	Lpg_out
	movel	Lpg_n,%d0
	cmpil	&8,%d0
	bccw	Lpg_out
	addql	&1,%d0
	movel	%d0,Lpg_n
	movel	%fp@(4),%sp@-		| caller (return address)
	movel	%a2@(8),%sp@-		| p_offset
	movel	%a2@(4),%sp@-		| p_vnode
	movel	%a2@(32),%sp@-		| p_mapping (the ghost PTE pointer)
	movel	%a2,%sp@-		| pp
	pea	Lpg_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
Lpg_out:
	moveal	%a2,%a0			| restore the return value (a0 + d0 mirror)
	movel	%a2,%d0
	moveal	%sp@+,%a2
	unlk	%fp
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lpg_n:
	.long	0
Lpg_msg:
	.asciz	"DBG PGALIAS pp=%x map=%x vn=%x off=%x caller=%x (MAPPED page handed out by page_get!)"
	.even
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
| hat_sdtalloc(&out, count): *out = allocated table base (identity phys).  Compare base page to
| g_shdatabase.
	.globl	hat_sdtalloc
hat_sdtalloc:
	addql	&1,g_sdtalloc_n
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	g_pageget_n,%d0		| snapshot page_get call count at entry
	movel	%d0,Lsd_save
	movel	%fp@(12),%sp@-		| count
	movel	%fp@(8),%sp@-		| &out
	jsr	hat_sdtalloc_orig
	addqw	&8,%sp
	movel	%d0,%d3			| preserve return value (d0)
	moveal	%fp@(8),%a2		| &out
	movel	%a2@,%d2		| *out = allocated base
	andil	&0xfffff000,%d2		| -> phys page base
	tstl	g_shdatabase
	beqw	Lhsd_done
	cmpl	g_shdatabase,%d2
	bnew	Lhsd_done
	movel	Lhsd_n,%d0
	cmpil	&4,%d0
	bccw	Lhsd_done
	addql	&1,%d0
	movel	%d0,Lhsd_n
	movel	g_pageget_n,%d0
	subl	Lsd_save,%d0		| pgdelta = page_get calls during this hat_sdtalloc
	movel	%d0,%sp@-		| pgdelta (0=from sdtfreelist, >0=from page_get)
	movel	%fp@(4),%sp@-		| caller (return addr at wrapper entry)
	movel	%d2,%sp@-		| base
	pea	Lhsd_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lhsd_done:
	movel	%d3,%d0			| restore return value
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	rts

| hat_ptalloc(&ptdat, n): returns a0 = new page table (identity phys).  Compare base page.
	.globl	hat_ptalloc
hat_ptalloc:
	addql	&1,g_ptalloc_n
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	%fp@(12),%sp@-		| n
	movel	%fp@(8),%sp@-		| &ptdat
	jsr	hat_ptalloc_orig
	addqw	&8,%sp
	movel	%a0,%d3			| preserve return a0 (page table base)
	movel	%a0,%d2
	andil	&0xfffff000,%d2		| -> phys page base
	tstl	g_shdatabase
	beqw	Lhpa_done
	cmpl	g_shdatabase,%d2
	bnew	Lhpa_done
	movel	Lhpa_n,%d0
	cmpil	&4,%d0
	bccw	Lhpa_done
	addql	&1,%d0
	movel	%d0,Lhpa_n
	movel	%fp@(4),%sp@-		| caller
	movel	%d2,%sp@-		| base
	pea	Lhpa_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
| LIVE-vs-STALE discriminator (2026-07-16): does sh's leaf PTE STILL point at the frame
| hat_ptalloc just handed out as a page table?  *g_shdataleaf & ~0xFFF == base -> the reuse
| is ILLEGAL (sh's live mapping survived the page's free/realloc = the ISSUE-10 missing-
| entry producer caught in the act); != -> g_shdatabase was just a stale snapshot (legit
| recycle after sh exited/remapped).  Leaf deref is phys-range gated.  d2 = base survives
| cmn_err (callee-saved); a2 is saved/restored by this wrapper.
	movel	g_shdataleaf,%d0
	beqw	Lhpa_done
	movel	%d0,%d1
	andil	&0xf0000003,%d1		| leaf ptr: phys < 0x10000000 AND 4-byte aligned?
	bnew	Lhpa_done
	moveal	%d0,%a2
	movel	%a2@,%d1		| d1 = *leaf = sh's data-page PTE right now
	movel	%d1,%d0
	andil	&0xfffff000,%d0
	cmpl	%d2,%d0			| still maps the just-allocated PT frame?
	beqw	Lhpa_live
	movel	%d1,%sp@-		| *leaf
	pea	Lhpa_stale_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
	braw	Lhpa_done
Lhpa_live:
	movel	%d1,%sp@-		| *leaf
	pea	Lhpa_live_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lhpa_done:
	moveal	%d3,%a0			| restore return a0
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lhx_n:
	.long	0
	.even
Lhx_emsg:
	.asciz	"DBG hat_exec ENTER oas=%x nas=%x shd@e48=%x freemem=%x availrmem=%x availsmem=%x pg=%x pf=%x pt=%x sdt=%x"
	.even
Lhx_xmsg:
	.asciz	"DBG hat_exec EXIT ret=%x shd@e48=%x"
	.even

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
| hat_exec (0xb6f20) wrapper -- hat_exec is the exec-time STACK MOVE (3B2 vm_hat.c:2723): it moves
| the new-image stack pages from the old AS to the new AS by DIRECT 030 SDE/PTE-table writes and
| calls hat_growsdt (030 SD-invalid fill).  NEITHER is 040-ported, and as_exec(0xaed8a)->hat_exec
| is the ONLY live hat_growsdt caller in this build (hat_alloc040 replaced stock hat_alloc,
| hat_dup is stubbed) -- so this runs stock-030 table writes on EVERY exec.  Suspected corruptor
| of live user pages (FFFFFFFF fill / stray p_mapping-chain write hits sh's data page).
| Probe: log the 6 args + sh-data-page RAM @ +0xe48 (g_shdatabase phys, DTT0 identity) at ENTRY
| and EXIT -- a 0 -> FFFFFFFF transition INSIDE the bracket = smoking gun.  Cap 24.
	.globl	hat_exec
hat_exec:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	Lhx_n,%d0
	cmpil	&64,%d0
	bccw	Lhx_call
	addql	&1,%d0
	movel	%d0,Lhx_n
	bsrw	Lhx_read		| d0 = RAM@e48 (or -2 if base unset)
	movel	g_sdtalloc_n,%sp@-	| total hat_sdtalloc calls (ptr/SDT tables)
	movel	g_ptalloc_n,%sp@-	| total hat_ptalloc calls (leaf tables)
	movel	g_pagefree_n,%sp@-	| total page_free calls
	movel	g_pageget_n,%sp@-	| total page_get calls (pg-pf = net pages held)
	movel	availsmem,%sp@-		| availsmem (4KB clicks)
	movel	availrmem,%sp@-		| availrmem (4KB clicks)
	movel	freemem,%sp@-		| freemem (4KB clicks) -- leak trajectory per exec
	movel	%d0,%sp@-		| shd@e48
	movel	%fp@(20),%sp@-		| nas
	movel	%fp@(8),%sp@-		| oas
	pea	Lhx_emsg
	pea	2
	jsr	cmn_err
	lea	%sp@(48),%sp
Lhx_call:
	movel	%fp@(28),%sp@-
	movel	%fp@(24),%sp@-
	movel	%fp@(20),%sp@-
	movel	%fp@(16),%sp@-
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	hat_exec_orig
	lea	%sp@(24),%sp
	movel	%d0,%d3			| preserve ret
	movel	Lhx_n,%d0
	cmpil	&64,%d0
	bccw	Lhx_done
	bsrw	Lhx_read
	movel	%d0,%sp@-		| shd@e48
	movel	%d3,%sp@-		| ret
	pea	Lhx_xmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lhx_done:
	movel	%d3,%d0			| return orig's ret
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	rts
| helper: d0 = *(g_shdatabase | 0xe48) read via DTT0 identity; -2 if g_shdatabase unset
Lhx_read:
	movel	g_shdatabase,%d0
	beqs	Lhxr_unset
	andil	&0xfffff000,%d0
	oril	&0xe48,%d0
	moveal	%d0,%a2
	movel	%a2@,%d0
	rts
Lhxr_unset:
	moveq	&-2,%d0
	rts
| grow (0x5820e, GLOBAL T) wrapper -- the stack-growth syscall/fault helper (os/grow.c).
| /usr/lib/saf/listen dies 'User BUS ERROR at C07FC5D0' = a fault ~3 pages below the 1-page
| initial stack -> the FIRST real stack growth in the boot; if grow fails (ret 0) the trap
| delivers SIGSEGV/SIGBUS.  Log args (sp, p_stkbase@60, p_stksize@64, rlimit-STACK@u+0x7bc)
| + ret to see WHY it fails (rlimit garbage? stkbase wrong from unpatched execstk_addr?
| as_map overlap?) -- or whether it is never called (trap routing).  Cap 16 each.
	.globl	grow
grow:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	Lgr_n,%d0
	cmpil	&16,%d0
	bccw	Lgr_call
	addql	&1,%d0
	movel	%d0,Lgr_n
	moveal	u+0x730,%a2		| u.u_procp
	movel	u+0x7bc,%sp@-		| u_rlimit[RLIMIT_STACK].rlim_cur
	movel	%a2@(64),%sp@-		| p_stksize
	movel	%a2@(60),%sp@-		| p_stkbase
	movel	%fp@(8),%sp@-		| sp arg
	pea	Lgr_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lgr_call:
	movel	%fp@(8),%sp@-
	jsr	grow_orig
	addqw	&4,%sp
	movel	%d0,%d2
	movel	Lgr_n2,%d0
	cmpil	&16,%d0
	bccw	Lgr_done
	addql	&1,%d0
	movel	%d0,Lgr_n2
	movel	%d2,%sp@-		| ret
	pea	Lgr_rmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
Lgr_done:
	movel	%d2,%d0
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
	nop				| pad (freemem-trace edit changed size by 2)
	nop				| pad (counter edit changed size by 2)
	nop				| pad .text to keep text/data contiguous
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop
	nop

| ---------------------------------------------------------------------------
| hat_pteload WRAPPER (2026-07-17, ISSUE-10 producer hunt).  Overnight SEGVND/SEGVVN
| proved the corruption = a UFS file's page-0 frame (p_vnode!=0, p_offset==0, VREG)
| mapped into a user HEAP-family VA (chain node at PGI 0x16 alongside the legit PGI-0
| text mapping).  hat_pteload registers it cleanly (in=1), so the PRODUCER is whoever
| hands the file page to a heap fault.  Log every hat_pteload of a file-off-0 page
| into a suspicious VA: va in [0x80001000, 0xC0000000) -- i.e. NOT the text base page
| 0x80000000 (the only legit low-VA home for file offset 0) and NOT the libc range
| C1000000+ (legit shared-lib header map).  Dump va/pp/vnode + a 3-deep caller chain
| (c1 = direct caller e.g. hat_memload; c2/c3 walk the saved-fp chain -> names the
| segvn/anon/segmap path).  Cap 8.  Tail-jmp keeps the arg stack intact (arg count
| irrelevant).  hat_pteload args: hat@8, va@12, pp@16 (hat040.s prologue).
	.balign 4
	.data
	.even
Lptl_n:
	.long	0
Lptl_msg:
	.asciz	"DBG PTLFILE0 va=%x pp=%x vn=%x c1=%x c2=%x c3=%x"
	.even
	.balign 4
	.text
	.globl	hat_pteload
hat_pteload:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	Lptl_n,%d0
	cmpil	&8,%d0
	bccw	Lptl_pass		| cap reached -> zero-cost pass-through
	movel	%fp@(12),%d2		| va
	cmpil	&0x80000000,%d2		| user range only (run 260717-02: the chain's illegal
	bcsw	Lptl_pass		|  nodes are PGI-0 = VA 0x80000000, BELOW the old floor!)
	movel	%d2,%d0
	andil	&0xfffff000,%d0
	cmpil	&0x80002000,%d0		| va page == 0x80002000 = the LEGIT AMIX ELF text base
	beqw	Lptl_pass		|  (boot run 260717-01: 5 distinct vnodes map off-0 there)
	cmpil	&0xc0000000,%d2
	bccw	Lptl_pass		| libc/shared-lib range -> legit
	movel	%fp@(16),%d0		| pp
	moveal	%d0,%a2
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lptl_pass		| pp not kvseg -> can't inspect
	tstl	%a2@(4)			| p_vnode == 0 -> anon page, legit
	beqw	Lptl_pass
	tstl	%a2@(8)			| p_offset != 0 -> not the header page, pass
	bnew	Lptl_pass
	addql	&1,Lptl_n
| caller chain: c1 = my return addr; c2/c3 via the saved-fp chain (gated derefs --
| frames live on the kernel/u stack, kvseg 0x4xxxxxxx)
	moveq	&0,%d2			| c2 default 0
	moveq	&0,%d1			| c3 default 0
	movel	%fp@(0),%d0		| caller's fp
	moveal	%d0,%a2
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lptl_c0			| caller fp not kvseg -> stop the walk
	movel	%a2@(4),%d2		| c2 = caller's return addr
	movel	%a2@(0),%d0		| grandcaller's fp
	moveal	%d0,%a2
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lptl_c0
	movel	%a2@(4),%d1		| c3
Lptl_c0:
	movel	%d1,%sp@-		| c3
	movel	%d2,%sp@-		| c2
	movel	%fp@(4),%sp@-		| c1
	moveal	%fp@(16),%a2
	movel	%a2@(4),%sp@-		| vn
	movel	%a2,%sp@-		| pp
	movel	%fp@(12),%sp@-		| va
	pea	Lptl_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(32),%sp
Lptl_pass:
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	jmp	hat_pteload_orig

| ---------------------------------------------------------------------------
| page_hashin WRAPPER (2026-07-17, ISSUE-10 producer hunt, direction B).  If the file
| identity (vp, off) is hashed onto a frame that STILL HAS live mappings
| (pp->p_mapping != 0), the vnode side is claiming a frame some AS still maps -- the
| other way the double-registration can arise (hat_pteload's PTLFILE0 covers direction
| A: file page loaded into an illegal VA).  Log pp/vp/off/p_mapping + 3-deep caller
| chain.  Cap 8.  page_hashin(pp@8, vp@12, offset@16, lock@20) -- vanilla 0xb02ac.
	.balign 4
	.data
	.even
Lphi_n:
	.long	0
Lphi_msg:
	.asciz	"DBG HASHINMAP pp=%x vn=%x off=%x map=%x c1=%x c2=%x c3=%x"
	.even
	.balign 4
	.text
	.globl	page_hashin
page_hashin:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	Lphi_n,%d0
	cmpil	&8,%d0
	bccw	Lphi_pass
	movel	%fp@(8),%d0		| pp
	moveal	%d0,%a2
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lphi_pass		| pp not kvseg -> skip inspection
	tstl	%a2@(32)		| p_mapping != 0 = live mappings at hashin time?
	beqw	Lphi_pass
	addql	&1,Lphi_n
| caller chain (gated, as in PTLFILE0)
	moveq	&0,%d2			| c2
	moveq	&0,%d1			| c3
	movel	%fp@(0),%d0
	moveal	%d0,%a2
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lphi_c0
	movel	%a2@(4),%d2
	movel	%a2@(0),%d0
	moveal	%d0,%a2
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lphi_c0
	movel	%a2@(4),%d1
Lphi_c0:
	movel	%d1,%sp@-		| c3
	movel	%d2,%sp@-		| c2
	movel	%fp@(4),%sp@-		| c1
	moveal	%fp@(8),%a2
	movel	%a2@(32),%sp@-		| p_mapping
	movel	%fp@(16),%sp@-		| off
	movel	%fp@(12),%sp@-		| vn
	movel	%a2,%sp@-		| pp
	pea	Lphi_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(36),%sp
Lphi_pass:
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	jmp	page_hashin_orig
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
