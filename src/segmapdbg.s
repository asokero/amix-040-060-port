| segmapdbg.s -- ISSUE-103: latch the state segmap_unlock panics on, and answer the
| one question statics cannot.  (2026-08-20)
|
| THE PANIC.  On metal, the 68040 kernel now boots past console init and dies:
|
|     PANIC: segmap_unlock
|
| segmap_unlock (.text+0xa8fec) is the F_SOFTUNLOCK arm of segmap_fault -- the
| release half of a softlock/softunlock pair, reached from as_fault during the
| first root-mount I/O.  For each 4 KiB page in [addr, addr+len) it looks the page
| up in the page hash by (vp, off) and refuses to proceed unless it is there and
| usable.  Decompiled from the stock image, its guard at 0xa905e-0xa9074 panics --
| cmn_err(CE_PANIC, "segmap_unlock") -- when any one of three conditions holds: the
| page-hash lookup returned no page (pp is NULL), or the page is still being paged
| in (p_pagein set), or the page is on a free list (p_free set).
|
|   `btst #0,%a2@` is p_pagein and `btst #5,%a2@` is p_free -- byte 0 of the page
|   bitfield unit is p_lock(7) p_want(6) p_free(5) p_intrans(4) p_gone(3) p_mod(2)
|   p_ref(1) p_pagein(0), the same layout page_free's asserts pin (ISSUE-102).
|
| **All three conditions branch to the SAME cmn_err**, so the panic text cannot say
| which one fired -- the identical problem ISSUE-102 had, and the reason this unit
| exists rather than another reading of the disassembly.
|
| WHAT THE STATICS ALREADY SETTLED, so the next boot does not re-ask it:
|
|   * segmap's own memory is NOT a dirty-DRAM repeat of ISSUE-102.  segmap_create
|     (0xa8ea8) takes both the segmap data and the whole smap array from
|     **kmem_zalloc**, so every sm_vp/sm_off/sm_refcnt starts zeroed.
|   * the page-hash shift is CONSISTENT.  page_find, page_exists, page_hashin,
|     page_hashout and segmap_unlock's own inlined copy all use `>>11`, so the
|     hash is uniform and insert and lookup agree.  (`>>11` with 4 KiB pages only
|     halves the effective bucket count -- a distribution loss, not a miss.  The
|     `moveq #12` inside page_hashout is the p_hash FIELD OFFSET, not a shift.)
|   * the geometry is converted.  segmap_unlock steps 4096 per page, as_fault
|     rounds to 4096, segmap slots are MAXBSIZE 8192 (`&0x1FFF`, `>>13`), and the
|     softlock and softunlock halves are symmetric about p_keepcnt: the F_SOFTLOCK
|     arm keeps getpage's hold, and this routine's `subqw #1,%a2@(2)` releases it.
|
| So the geometry is right and the memory is initialised.  What is left is runtime
| STATE: at softunlock time the page is not where the softlock left it.  Which of
| the three, and why, is a fact about the running machine.
|
| HOW IT HOOKS.  patch_segmapdbg.py retargets the single cmn_err relocation at
| 0xa9080 to this island -- the same one-relocation idiom patch_sdtfail.py uses for
| hat_sdtalloc's warning.  The island saves every register, latches, restores, and
| tail-jumps into the real cmn_err, so the panic still prints exactly as before and
| segmap_unlock's stack and arguments are untouched.
|
| **Blast radius on a healthy kernel is zero**: the only path that reaches this code
| is one that was already calling cmn_err(CE_PANIC) on the next instruction.
|
| WHAT IT LATCHES.  At the `jsr`, segmap_unlock's own registers are still live and
| hold everything worth knowing -- a2 = pp (or NULL), a3 = smp, a4 = seg, d2 = the
| page address that failed, d3 = the vnode offset looked up, d4 = the addr argument,
| d5 = rw, d6 = len.  No reconstruction needed; the values are simply read.
|
| THE DISCRIMINATOR, and it is the point of the unit.  After latching, the island
| walks the WHOLE page hash looking for (vp, off) in any bucket:
|
|   smu_scan = 1  the page IS in the cache, in bucket smu_bucket, while
|                 segmap_unlock looked in smu_want.  If those differ, insert and
|                 lookup disagree about the bucket and the defect is in the hash
|                 index -- despite the shift being uniform, e.g. page_hashsz
|                 changing under a live table.  If they are EQUAL, the page was
|                 found on a re-walk of the same bucket that just missed it, which
|                 means the chain was being mutated concurrently (a locking defect).
|   smu_scan = 0  the page is genuinely NOT in the cache: it was freed, or hashed
|                 out, or never entered.  Then smu_why says which of the three
|                 guards fired, and p_free vs pp==NULL separates "returned to the
|                 free list while softlocked" from "gone entirely".
|   smu_scan = 2  the scan hit its own safety budget and proved nothing.
|
| The scan is bounded twice (per-chain and total) because it runs inside a panic on
| a machine whose page structures are already suspect, and an unbounded walk through
| a corrupt chain is exactly how ISSUE-100 turned a panic into a dead machine.
|
| PRE-REGISTERED PREDICTIONS, written before the run:
|   * smu_n == 1 and smu_addr == smu_addr0 -- it fails on the FIRST page of the run,
|     not partway through.  If smu_addr > smu_addr0 the failure is position-
|     dependent and the run length matters, which would be a different bug.
|   * smu_why == 4 (pp == NULL) or 2 (p_free).  p_pagein (1) would mean the page is
|     still being read in under a softlock, which should be impossible.
|   * smu_scan == 0.  If it comes back 1 this entry is wrong about the cause and the
|     hash bucket arithmetic is the place to look.
|   * smu_vp != 0 and smu_smoff is a plausible file offset.  A zero or wild vp means
|     the smap slot itself was recycled under the softlock, which is a third story
|     again and would move the investigation to segmap_getmap/segmap_release.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c segmapdbg.s -o build/segmapdbg.o
| Wire:     patch_segmapdbg.py (relocation retarget).  Externals: page_hash,
|           page_hashsz, page_freelist, freemem (all COMMON) and cmn_err.
|           page_cachelist / page_cachelist_size are file-LOCAL 'b' in the stock
|           image and need --globalize-symbol in relink-040.sh -- without it the
|           two list walks bind to address 0.  The relocation validator refuses
|           that build (BADSHNDX, shndx=0), which is how it was caught here rather
|           than on the card.
| ============================================================================

	.text
	.globl	smu_panic_latch
smu_panic_latch:
	moveml	%d0-%d7/%a0-%a6,%sp@-
	addql	&1,smu_n
	tstl	smu_have
	bnew	Lsmu_go
	movel	&1,smu_have

| --- segmap_unlock's live registers, read straight out ---
	movel	%a2,smu_pp		| the page it found, or 0
	movel	%a3,smu_smp		| the smap slot
	movel	%a4,smu_seg
	movel	%d2,smu_addr		| the page VA that failed
	movel	%d3,smu_off		| the vnode offset looked up
	movel	%d4,smu_addr0		| the addr argument the run started at
	movel	%d5,smu_rw
	movel	%d6,smu_len
	movel	%a3@,smu_vp		| smp->sm_vp
	movel	%a3@(4),smu_smoff	| smp->sm_off
	movel	page_hashsz,smu_hashsz

| --- which of the three guards fired: 4 = pp NULL, 1 = p_pagein, 2 = p_free ---
	moveq	&4,%d0
	tstl	%a2
	beqw	Lsmu_why
	movel	%a2@,smu_pflags		| bitfields + p_keepcnt
	movel	%a2@(4),smu_pvnode
	movel	%a2@(8),smu_poff
	moveq	&0,%d0
	btst	&0,%a2@
	beqw	Lsmu_c1
	addql	&1,%d0
Lsmu_c1:
	btst	&5,%a2@
	beqw	Lsmu_why
	addql	&2,%d0
Lsmu_why:
	movel	%d0,smu_why

| --- the bucket segmap_unlock looked in: ((off>>11) + (vp>>6)) & (hashsz-1) ---
	movel	%d3,%d0
	moveq	&11,%d1
	lsrl	%d1,%d0
	movel	%a3@,%d1
	asrl	&6,%d1
	addl	%d1,%d0
	movel	smu_hashsz,%d1
	subql	&1,%d1
	andl	%d1,%d0
	movel	%d0,smu_want

| --- the discriminator: is (vp, off) anywhere in the hash at all? ---
	movel	&-1,smu_bucket
	moveal	page_hash,%a0
	tstl	%a0
	beqw	Lsmu_lists
	movel	smu_hashsz,%d0		| d0 = bucket count
	beqw	Lsmu_lists
	movel	%a3@,%d5		| d5 = target vp
	movel	%d3,%d6			| d6 = target off
	movel	&100000,%d3		| d3 = total link budget
	moveq	&0,%d1			| d1 = bucket index
Lsmu_b:
	moveal	%a0@(0,%d1:l:4),%a1
	movel	&1024,%d2		| d2 = per-chain cap
Lsmu_c:
	tstl	%a1
	beqw	Lsmu_bn
	subql	&1,%d3
	beqw	Lsmu_budget		| budget gone: prove nothing rather than hang
	cmpl	%a1@(4),%d5		| p_vnode == vp ?
	bnew	Lsmu_nx
	cmpl	%a1@(8),%d6		| p_offset == off ?
	bnew	Lsmu_nx
	movel	%d1,smu_bucket		| FOUND -- and in which bucket
	movel	%a1,smu_scanpp
	movel	&1,smu_scan
	braw	Lsmu_lists
Lsmu_nx:
	moveal	%a1@(12),%a1		| p_hash
	subql	&1,%d2
	bnew	Lsmu_c
Lsmu_bn:
	addql	&1,%d1
	cmpl	%d0,%d1
	bcsw	Lsmu_b
	braw	Lsmu_lists
Lsmu_budget:
	movel	&2,smu_scan		| inconclusive, and says so

| --- STAGE 2 (2026-08-21): p_free is set, so the page claims to be on a free
|     list.  WHICH list it is actually linked into is the whole question, and it
|     splits the remaining space three ways.  Both lists are circular and doubly
|     linked through p_next (+16) / p_prev (+20); both walks are budgeted, for the
|     same reason the hash scan is.
Lsmu_lists:
	movel	&0x52414e21,smu_s2ran	| "RAN!" -- set FIRST: an instrument that cannot
					| say whether it ran is indistinguishable from
					| one that ran and found nothing.
	movel	page_cachelist_size,smu_cachesz
	movel	freemem,smu_freemem
| ---- page_cachelist ----
	moveal	page_cachelist,%a1
	tstl	%a1
	beqw	Lsmu_freel
	movel	%a1,%d1			| d1 = head, to close the ring
	movel	&200000,%d0		| budget
Lsmu_cl:
	cmpal	%a1,%a2
	bnew	Lsmu_cln
	movel	&1,smu_oncache
	braw	Lsmu_freel
Lsmu_cln:
	moveal	%a1@(16),%a1		| p_next
	tstl	%a1
	beqw	Lsmu_freel
	addql	&1,smu_cachewalk
	cmpl	%a1,%d1
	beqw	Lsmu_freel		| back at the head: whole ring seen
	subql	&1,%d0
	bnew	Lsmu_cl
| ---- page_freelist ----
Lsmu_freel:
	moveal	page_freelist,%a1
	tstl	%a1
	beqw	Lsmu_done2
	movel	%a1,%d1
	movel	&200000,%d0
Lsmu_fl:
	cmpal	%a1,%a2
	bnew	Lsmu_fln
	movel	&1,smu_onfree
	braw	Lsmu_done2
Lsmu_fln:
	moveal	%a1@(16),%a1		| p_next
	tstl	%a1
	beqw	Lsmu_done2
	addql	&1,smu_freewalk
	cmpl	%a1,%d1
	beqw	Lsmu_done2
	subql	&1,%d0
	bnew	Lsmu_fl

| --- STAGE 3 (2026-08-21): every p_free-touching code path is stock and correct
|     (proved by a stock-vs-built byte diff and by page_get's cascade being
|     unskippable), so p_free was SET on this page after it was acquired, by
|     something that is not one of the two guarded `orib #32` instructions.
|     The question is therefore no longer "which clear is missing" but "how many
|     pages are in this impossible state" -- one means a targeted write at a fixed
|     address, many means something systemic.  One bounded pass over pages..epages.
Lsmu_done2:
	movel	&0x43454e21,smu_s3ran	| "CEN!"
	moveal	pages,%a0
	tstl	%a0
	beqw	Lsmu_go
	moveal	epages,%a1
	tstl	%a1
	beqw	Lsmu_go
	moveq	&0,%d0			| d0 = struct index
	movel	&100000,%d3		| safety cap: pages/epages are themselves suspect
Lsmu_cen:
	cmpal	%a1,%a0
	bccw	Lsmu_go			| reached epages
	moveq	&0,%d1
	moveb	%a0@,%d1		| the flag byte
| --- STAGE 4 (2026-08-21): the POPULATION, over every struct, not just free ones.
|     freeset_n == npages refuted the single-target story; measure the distribution
|     instead of reasoning about it.  One counter per flag bit, plus the two exact
|     byte values that mean something: 0x20 = a clean free page (what page_free
|     leaves), 0xFF = every bit set, which nothing in the page code writes.
	lea	smu_bitpop,%a3
	moveq	&0,%d4
Lsmu_bp:
	btst	%d4,%d1
	beqw	Lsmu_bpn
	addql	&1,%a3@(0,%d4:l:4)
Lsmu_bpn:
	addql	&1,%d4
	moveq	&8,%d5
	cmpl	%d5,%d4
	bnew	Lsmu_bp
	cmpib	&0xff,%d1
	bnew	Lsmu_v1
	addql	&1,smu_b0_ff
Lsmu_v1:
	cmpib	&0x20,%d1
	bnew	Lsmu_v2
	addql	&1,smu_b0_20
Lsmu_v2:
	btst	&5,%d1			| p_free?
	beqw	Lsmu_cnx
	addql	&1,smu_freeset_n	| should track freemem + cachelist
	movel	%d1,%d2
	andil	&0x11,%d2		| p_intrans (0x10) | p_pagein (0x01)
	beqw	Lsmu_cnx
	addql	&1,smu_imposs_n		| free AND in transit -- impossible
	tstl	smu_imposs_pp
	bnew	Lsmu_cnx
	movel	%a0,smu_imposs_pp	| latch the first one
	movel	%d0,smu_imposs_i
Lsmu_cnx:
	lea	%a0@(60),%a0
	addql	&1,%d0
	subql	&1,%d3
	bnew	Lsmu_cen

Lsmu_go:
	moveml	%sp@+,%d0-%d7/%a0-%a6
| The stack now holds cmn_err's return address and its two arguments (CE_PANIC and
| the format string), exactly as segmap_unlock pushed them.
	jmp	cmn_err
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	smu_magic
smu_magic:
	.long	0x534d5521		| "SMU!"
| Times the panic site was reached.  1 on a normal failure.
	.globl	smu_n
smu_n:
	.long	0
	.globl	smu_have
smu_have:
	.long	0
| 4 = pp was NULL, 1 = p_pagein set, 2 = p_free set (1|2 both).
	.globl	smu_why
smu_why:
	.long	0
| 0 = (vp,off) not in the hash at all, 1 = found (see smu_bucket), 2 = budget hit.
	.globl	smu_scan
smu_scan:
	.long	0
| Bucket the full scan found it in, or -1.  Compare against smu_want.
	.globl	smu_bucket
smu_bucket:
	.long	0
	.globl	smu_want
smu_want:
	.long	0
	.globl	smu_scanpp
smu_scanpp:
	.long	0
| segmap_unlock's live state at the failure.
	.globl	smu_pp
smu_pp:
	.long	0
	.globl	smu_smp
smu_smp:
	.long	0
	.globl	smu_seg
smu_seg:
	.long	0
	.globl	smu_addr
smu_addr:
	.long	0
	.globl	smu_off
smu_off:
	.long	0
	.globl	smu_addr0
smu_addr0:
	.long	0
	.globl	smu_len
smu_len:
	.long	0
	.globl	smu_rw
smu_rw:
	.long	0
	.globl	smu_vp
smu_vp:
	.long	0
	.globl	smu_smoff
smu_smoff:
	.long	0
	.globl	smu_hashsz
smu_hashsz:
	.long	0
| The page struct it did find, if any (smu_why == 1 or 2).
	.globl	smu_pflags
smu_pflags:
	.long	0
	.globl	smu_pvnode
smu_pvnode:
	.long	0
	.globl	smu_poff
smu_poff:
	.long	0
| STAGE 2: which free list the page is ACTUALLY linked into, and the ring sizes
| to judge the walks by.  1 = found on that list.
| "CEN!" once the stage-3 census has executed, and its results.  smu_imposs_n == 1
| means exactly one page in the array is both free and in transit -- a targeted
| event at a fixed address, not a systemic accounting failure.
	.globl	smu_s3ran
smu_s3ran:
	.long	0
| Population of each flag bit across the whole array, bit 0 (p_pagein) first,
| bit 7 (p_lock) last.  page_get's cascade clears bits 7,5,4,2,0 on every page it
| hands out, so a large bit-7 or bit-2 population means the cascade did not take.
	.globl	smu_bitpop
smu_bitpop:
	.long	0,0,0,0,0,0,0,0
| Exact byte-0 values worth counting: 0x20 is a clean free page, 0xFF is all bits.
	.globl	smu_b0_ff
smu_b0_ff:
	.long	0
	.globl	smu_b0_20
smu_b0_20:
	.long	0
	.globl	smu_freeset_n
smu_freeset_n:
	.long	0
	.globl	smu_imposs_n
smu_imposs_n:
	.long	0
	.globl	smu_imposs_i
smu_imposs_i:
	.long	0
	.globl	smu_imposs_pp
smu_imposs_pp:
	.long	0
| "RAN!" once the stage-2 block has executed.  Zero here means the block was never
| reached, which is a DIFFERENT fact from every walk field being zero.
	.globl	smu_s2ran
smu_s2ran:
	.long	0
	.globl	smu_oncache
smu_oncache:
	.long	0
	.globl	smu_onfree
smu_onfree:
	.long	0
	.globl	smu_cachewalk
smu_cachewalk:
	.long	0
	.globl	smu_freewalk
smu_freewalk:
	.long	0
	.globl	smu_cachesz
smu_cachesz:
	.long	0
	.globl	smu_freemem
smu_freemem:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
