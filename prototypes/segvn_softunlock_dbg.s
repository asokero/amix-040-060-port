| segvn_softunlock_dbg.s -- DIAGNOSTIC wrapper around segvn_softunlock (0xabd00, file-LOCAL t;
| globalized+weakened by relink-040-dbg.sh so both segvn_fault call sites rebind here).
|
| WHY: fsck of a corrupt UFS panics "PANIC: segvn_softunlock" -- the kernel F_SOFTLOCKs fsck's
| anon read buffer for the raw-device physio, and at softunlock time one page in the range is
| found on the FREE LIST (p_free set): a softlocked page got freed underneath the transfer.
| The panic is a cmn_err(CE_PANIC) INSIDE the original, so a plain tail-call wrapper can't
| observe the failing page.  This wrapper REPLICATES the original's per-page page-find loop
| (transcribed from the 0xabd18..0xabee6 disasm), and for the FIRST page meeting the panic
| condition (pp==NULL || p_pagein || p_free) dumps the page state -- especially p_mapping
| (prime hypothesis: 0, so page_abort freed the page believing it unmapped) -- via
| cmn_err(CE_WARN), THEN tail-calls the original, which re-finds the page and panics as
| before (evidence captured first).
|
| ALGORITHM (== orig 0xabd00, PAGESIZE 4KB Model B):
|   svd = seg@(28); amp = svd@(20)
|   app = amp ? amp@(8) + (svd@(16) + ((addr - seg@(4)) >> 12))*4 : 0
|   for (adr = addr; adr < addr+len; adr += 4096, app && app+=4):
|     if (app && *app)  swap_xlate(*app, &vp, &off)
|     else              vp = svd@(8); off = svd@(12) + (adr - seg@(4))
|     h  = ((off>>12) + (vp>>6)) & (page_hashsz-1)
|     pp = page_hash[h]; while (pp && !(pp@(4)==vp && pp@(8)==off)) pp = pp@(12)
|     if (pp==0 || pp@0.bit0 (p_pagein) || pp@0.bit5 (p_free))  --> DUMP, break
|
| page struct: flags word @0 (byte0 bit0=p_pagein, bit5=p_free), keepcnt word @2,
| p_vnode @4, p_offset @8, p_hash @12, p_mapping @32.
|
| ROBUSTNESS: this runs moments before a panic -- it must NEVER fault itself.  Every pointer
| we dereference (seg, svd, amp, app, pp) is checked non-null + 4-aligned (+ >=0x1000 for the
| anon slot) first; an implausible seg/svd/amp/app just skips the diagnostic (straight to the
| tail-call); an implausible pp is DUMPED without dereferencing (pp value + missed vp/off are
| still informative).  The hash-chain walk is bounded to 4096 links.  The wrapper writes NO
| kernel state -- only its own latch counter Lsv_n (cap 3 firings).

	.text
	.globl	segvn_softunlock
segvn_softunlock:
	linkw	%fp,&-16		| fp@(-4)=vp, fp@(-12)=off (same local layout as orig)
	moveml	%d2-%d6/%a2-%a5,%sp@-	| 9 regs = 36 bytes at fp@(-52)
| --- latch gate: after 3 firings, skip straight to the tail-call ---
	movel	Lsv_n,%d0
	cmpil	&3,%d0
	bccw	Lsv_tail
| --- setup (guard every pointer before deref) ---
	moveal	%fp@(8),%a1		| a1 = seg
	movel	%a1,%d0
	beqw	Lsv_tail
	andil	&3,%d0
	bnew	Lsv_tail
	moveal	%a1@(28),%a5		| a5 = svd = seg->s_data
	movel	%a5,%d0
	beqw	Lsv_tail
	andil	&3,%d0
	bnew	Lsv_tail
	movel	%fp@(12),%d3		| d3 = addr
	movel	%d3,%d4
	addl	%fp@(16),%d4		| d4 = addr + len (loop end)
| --- app = amp ? &amp->anon[anon_index + ((addr - s_base) >> 12)] : 0 ---
	tstl	%a5@(20)		| svd->amp
	beqw	Lsv_noamp
	moveal	%a5@(20),%a0		| a0 = amp
	movel	%a0,%d0
	andil	&3,%d0
	bnew	Lsv_tail		| garbage amp: no safe diagnostic
	movel	%d3,%d0
	subl	%a1@(4),%d0		| addr - seg->s_base
	moveq	&12,%d6
	asrl	%d6,%d0			| >> 12 (arith, as orig)
	addl	%a5@(16),%d0		| + svd->anon_index
	asll	&2,%d0			| *4 (anon slot)
	moveal	%d0,%a4
	addal	%a0@(8),%a4		| a4 = amp->anon array base + slot
	movel	%a4,%d0
	cmpil	&0x1000,%d0
	bcsw	Lsv_tail		| anon slot below 4KB: implausible, bail
	andil	&3,%d0
	bnew	Lsv_tail
	braw	Lsv_loop0
Lsv_noamp:
	subal	%a4,%a4			| app = 0 (long: word-size suba would NOT zero)
Lsv_loop0:
	movel	%d3,%d2			| d2 = adr = addr
	braw	Lsv_cond
| ================= per-page body (transcribed from orig 0xabd6e..0xabdf6) =================
Lsv_body:
	tstl	%a4
	beqw	Lsv_vnode
	tstl	%a4@
	beqw	Lsv_vnode
	pea	%fp@(-12)		| &off
	pea	%fp@(-4)		| &vp
	movel	%a4@,%sp@-		| *app (anon)
	jsr	swap_xlate		| swap_xlate(*app, &vp, &off)
	lea	%sp@(12),%sp
	braw	Lsv_find
Lsv_vnode:
	movel	%a5@(8),%fp@(-4)	| vp = svd->vp
	movel	%d2,%d0
	moveal	%fp@(8),%a1		| reload seg (a1 volatile across calls)
	subl	%a1@(4),%d0		| adr - seg->s_base
	addl	%a5@(12),%d0		| + svd->offset
	movel	%d0,%fp@(-12)		| off
Lsv_find:
| --- PAGE_HASHFUNC: ((off>>11) + (vp>>6)) & (page_hashsz-1); pp = page_hash[h] ---
| NOTE: >>11 (stock), NOT >>12: ALL other inlined PAGE_HASHFUNC sites (page_hashin/
| page_find/page_exists/page_hashout/xpage_find/findpage/segmap_unlock) kept the stock
| >>11 -- consistency is the only hash requirement.  The 0xabdae >>12 byte patch that
| this replica originally copied was the BUG (removed from patch_modelb.py).
	movel	%fp@(-12),%d0
	moveq	&11,%d6
	lsrl	%d6,%d0			| off >> 11 (stock hash, matches page_hashin)
	movel	%fp@(-4),%d1
	asrl	&6,%d1			| vp >> 6 (arith, as orig)
	addl	%d1,%d0
	movel	page_hashsz,%d1
	subql	&1,%d1
	andl	%d1,%d0			| & (page_hashsz-1)
	moveal	page_hash,%a0		| page_hash = pointer to the bucket array
	asll	&2,%d0
	addal	%d0,%a0
	moveal	%a0@,%a2		| a2 = pp = page_hash[h]
	movel	&4096,%d5		| chain-walk bound
Lsv_walk:
	movel	%a2,%d0
	beqw	Lsv_pcheck		| chain end: pp = NULL
	andil	&3,%d0
	bnew	Lsv_dump0		| garbage chain link: dump WITHOUT deref
	movel	%a2@(4),%d6		| pp->p_vnode
	cmpl	%fp@(-4),%d6
	bnew	Lsv_next
	movel	%a2@(8),%d6		| pp->p_offset
	cmpl	%fp@(-12),%d6
	beqw	Lsv_pcheck		| found
Lsv_next:
	moveal	%a2@(12),%a2		| pp = pp->p_hash
	subql	&1,%d5
	bnew	Lsv_walk
	braw	Lsv_tail		| chain > 4096 links: corrupt hash, bail (orig will show)
| --- the orig's panic condition (0xabdf6..0xabe08) ---
Lsv_pcheck:
	movel	%a2,%d0
	beqw	Lsv_dump0		| pp == NULL -> would panic: dump (no deref)
	btst	&0,%a2@			| flags byte0 bit0 = p_pagein
	bnew	Lsv_dump
	btst	&5,%a2@			| flags byte0 bit5 = p_free
	bnew	Lsv_dump
| --- healthy page: advance (orig 0xabed8..0xabeec) ---
	tstl	%a4
	beqw	Lsv_adv
	addqw	&4,%a4			| app++
Lsv_adv:
	addil	&4096,%d2		| adr += PAGESIZE
Lsv_cond:
	cmpl	%d4,%d2
	bcsw	Lsv_body		| adr < addr+len
	braw	Lsv_tail		| whole range clean: no dump
| ================= DUMP: first page meeting the panic condition =================
Lsv_dump:				| a2 = plausible pp with p_pagein/p_free set
	movel	Lsv_n,%d0
	addql	&1,%d0
	movel	%d0,Lsv_n
	movel	%fp@(-12),%sp@-		| off
	movel	%fp@(-4),%sp@-		| vp
	movel	%a2,%sp@-		| pp
	movel	%d2,%sp@-		| adr
	pea	Lsv_m1
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
	movel	%a2@(32),%sp@-		| p_mapping
	moveq	&0,%d0
	movew	%a2@(2),%d0
	movel	%d0,%sp@-		| keepcnt (word @2)
	moveq	&0,%d0
	movew	%a2@(0),%d0
	movel	%d0,%sp@-		| flags (word @0)
	pea	Lsv_m2
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
	braw	Lsv_anon
Lsv_dump0:				| pp NULL or garbage link: dump value + missed (vp,off)
	movel	Lsv_n,%d0
	addql	&1,%d0
	movel	%d0,Lsv_n
	movel	%fp@(-12),%sp@-		| off
	movel	%fp@(-4),%sp@-		| vp
	movel	%a2,%sp@-		| pp (0 or the garbage link)
	movel	%d2,%sp@-		| adr
	pea	Lsv_m1
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| ================= anon-slot forensics (shared by both dump paths) =================
| The hash lookup failed/flagged, but the anon slot's an_page HINT (anon@4) still points at
| the page struct the slot believes it owns -- so we can inspect the page's ACTUAL identity
| and state even though it is gone from page_hash.  Distinguishes: paged-out / freed /
| re-identified (double-use) / hashout'ed.  struct anon (16B): an_refcnt@0, an_page@4,
| an_bap@8, an_flag+an_use@12.  page struct extras: p_next@16, p_lckcnt@36(w), p_cowcnt@38(w).
Lsv_anon:
	movel	%a4,%d0			| app
	beqw	Lsv_args		| vnode branch / no amp: nothing anon to show
	andil	&3,%d0
	bnew	Lsv_args
	moveal	%a4@,%a3		| a3 = anon = *app
	movel	%a3,%d0
	beqw	Lsv_an0			| empty slot: dump app + zeros
	andil	&3,%d0
	bnew	Lsv_an0			| garbage anon ptr: dump raw value, no deref
	movel	%a3@(12),%sp@-		| an_flag/an_use
	movel	%a3@(8),%sp@-		| an_bap
	movel	%a3@(0),%sp@-		| an_refcnt
	movel	%a3,%sp@-		| anon
	movel	%a4,%sp@-		| app
	pea	Lsv_m4
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	moveal	%a3@(4),%a3		| a3 = an_page (hint; cmn_err preserves a2-a5)
	movel	%a3,%d0
	beqw	Lsv_args		| no hint page
	andil	&3,%d0
	bnew	Lsv_args
	movel	%a3@(32),%sp@-		| hint page: p_mapping
	moveq	&0,%d0
	movew	%a3@(0),%d0
	movel	%d0,%sp@-		| flags word (byte0: bit5=p_free, bit0=p_pagein)
	movel	%a3@(8),%sp@-		| p_offset (its ACTUAL identity)
	movel	%a3@(4),%sp@-		| p_vnode  (its ACTUAL identity)
	movel	%a3,%sp@-		| an_page
	pea	Lsv_m5
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	movel	%a3@(16),%sp@-		| p_next (free/intrans list linkage)
	movel	%a3@(12),%sp@-		| p_hash
	moveq	&0,%d0
	movew	%a3@(38),%d0
	movel	%d0,%sp@-		| p_cowcnt
	moveq	&0,%d0
	movew	%a3@(36),%d0
	movel	%d0,%sp@-		| p_lckcnt
	moveq	&0,%d0
	movew	%a3@(2),%d0
	movel	%d0,%sp@-		| p_keepcnt
	pea	Lsv_m6
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	braw	Lsv_args
Lsv_an0:
	clrl	%sp@-			| flg=0
	clrl	%sp@-			| bap=0
	clrl	%sp@-			| ref=0
	movel	%a3,%sp@-		| anon raw value (0 or garbage)
	movel	%a4,%sp@-		| app
	pea	Lsv_m4
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
Lsv_args:
	movel	%fp@(4),%sp@-		| caller (return address)
	movel	%fp@(20),%sp@-		| rw
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| seg
	pea	Lsv_m3
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
| ================= tail-call the original (re-finds and really panics) =================
Lsv_tail:
	moveml	%fp@(-52),%d2-%d6/%a2-%a5
	unlk	%fp			| sp -> [ret][seg][addr][len][rw]: original call state
	jmp	segvn_softunlock_orig
	nop				| pad .text to a multiple of 4 (relink contiguity)

	.data
	.even
Lsv_m1:
	.asciz	"DBG SVUNLOCK adr=%x pp=%x vp=%x off=%x"
	.even
Lsv_m2:
	.asciz	"DBG SVUNLOCK flags=%x cnt=%x p_mapping=%x"
	.even
Lsv_m3:
	.asciz	"DBG SVUNLOCK seg=%x addr=%x len=%x rw=%x caller=%x"
	.even
Lsv_m4:
	.asciz	"DBG SVUNLOCK2 app=%x anon=%x ref=%x bap=%x flg=%x"
	.even
Lsv_m5:
	.asciz	"DBG SVUNLOCK3 anpg=%x pvn=%x poff=%x pflg=%x pmap=%x"
	.even
Lsv_m6:
	.asciz	"DBG SVUNLOCK4 keep=%x lck=%x cow=%x hash=%x next=%x"
	.even
Lsv_n:
	.long	0
