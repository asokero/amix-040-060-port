| cb_release040.s -- caches Step B2: copyback page-lifecycle release barrier
| (2026-07-23).  Spec: docs/contracts/CB-PAGE-LIFECYCLE-CLOSURE.md
| (pinned bc27d81 / base sha d3e1f80a).
|
| WHY: under copyback (hat_cm_ram=0x20) the newest bytes of a mapped page can
| exist ONLY as dirty data-cache lines.  Clearing the PTE / p_mapping does not
| remove the physical line; if the page is freed and reused, the old owner's
| line can be evicted LATER and overwrite the new owner's RAM.  The closure
| verdict: every managed page must be pushed+invalidated (cpushl per line, 040
| physically-tagged) BEFORE either free-list publication path makes it visible:
|   choke point 1: page_free   @0xafb08 (all early-outs passed, before freemem++/p_free)
|   choke point 2: free_vp_pages @0xafd98 (vnode-range shortcut, bypasses page_free)
| Hooking only page_free is a FAILED B2 build (free_vp_pages sets p_free itself).
|
| The release runs unconditionally (never skipped on p_mod/p_mapping/vnode):
| VM dirty state and cache dirty state are related but not interchangeable.
| In the WT-hooks baseline build this is still correct: no dirty lines exist,
| so the loop only invalidates clean lines (harmless refetch) -- which lets the
| hook transcription be regression-tested before the CM flip.
|
| MECHANISM (both hooks patched by patch_cb_release.py):
|   page_free:   the 6 displaced bytes 40c3 46fc 2400 (movew %sr,%d3 + raise
|                IPL) are replaced by `bsr.l cb_pgfree_enter` (61ff+disp32,
|                PC-relative -- NO raw absolute address: a byte-patched abs jmp
|                is the known 040 Line-F trap, see 040-detour-jmp memory).
|                The island replays the displaced pair, then releases a2=pp.
|                d3 (the caller's saved SR) is set here and NOT clobbered after.
|   free_vp_pages: the 6 displaced bytes 52b9+reloc(freemem) are replaced by
|                `jsr cb_vpfree_enter` -- opcode byte 4eb9 written in place and
|                the EXISTING freemem relocation at 0xafd9a retargeted to the
|                island symbol (same proven mechanism as patch_a3091_dma.py;
|                leaving the old reloc in place would have the loader stomp the
|                operand).  The island replays addql &1,freemem itself (its own
|                relocation binds at ld -r).
|
| 040 ops as .word: cpushl dc,(a0) = 0xf468 (push dirty line + invalidate).
| divul &60,%d0 assembles natively (4c7c 0000 0000003c) -- verified.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c cb_release040.s -o build/cb_release040.o

	.text

| ============================================================================
| cb_page_release core -- push+invalidate all 256 data-cache lines of pp's
| physical page.  Entry Lcb_core: pp in a0; clobbers d0/d1/a0/a1 ONLY.
| C-callable cb_page_release(pp) provided for completeness/tests.
| Rejects pp outside [pages, epages) or a wrapping physical range: counted,
| never a panic (base build must fail soft; counters expose it).
| ============================================================================
	.globl	cb_page_release
cb_page_release:
	moveal	%sp@(4),%a0
Lcb_core:
	movel	%a0,%d0
	subl	pages,%d0		| d0 = (char *)pp - (char *)pages
	bcsw	Lcb_rej			| pp below the page array
	movel	%a0,%d1
	cmpl	epages,%d1
	bccw	Lcb_rej			| pp >= epages
	divul	&60,%d0			| d0 = page index (sizeof(page_t) == 60)
	addl	pages_base,%d0		| d0 = pfn
	moveq	&12,%d1
	lsll	%d1,%d0			| d0 = physical base (pfn << 12)
	cmpil	&0xfffff000,%d0
	bccw	Lcb_rej			| pa + 0x1000 would wrap
	moveal	%d0,%a0
	movew	&255,%d1		| 256 lines x 16 bytes = 4 KiB page
Lcb_loop:
	.word	0xf468			| cpushl dc,(a0) -- push if dirty, invalidate
	addaw	&16,%a0
	dbf	%d1,Lcb_loop
	addql	&1,cb_rel_count
	rts
Lcb_rej:
	addql	&1,cb_rel_reject
	rts

| ============================================================================
| cb_pgfree_enter -- island for the page_free choke point (bsr.l from 0xafb08).
| Displaced originals FIRST (the epilogue restores SR from d3, so d3 must be
| written here exactly as the original did, and stays untouched afterwards).
| pp is in a2 at this point (asserted from the pinned disassembly: every
| p_free/wakeup reference after the hook site is a2-relative).
| ============================================================================
	.globl	cb_pgfree_enter
cb_pgfree_enter:
	movew	%sr,%d3			| displaced: save SR for the epilogue
	movew	&0x2400,%sr		| displaced: raise IPL before list state
	moveml	%d0-%d1/%a0-%a1,%sp@-
	moveal	%a2,%a0			| pp
	bsrw	Lcb_core
	moveml	%sp@+,%d0-%d1/%a0-%a1
	rts

| ============================================================================
| cb_vpfree_enter -- island for the free_vp_pages choke point (jsr via the
| retargeted freemem relocation at 0xafd9a).  SR is already raised (0xafc88).
| Replays the displaced freemem++ (own relocation).  pp is in a2 (asserted:
| the p_mod/p_mapping skips and the p_free set at 0xafe04 are a2-relative).
| ============================================================================
	.globl	cb_vpfree_enter
cb_vpfree_enter:
	moveml	%d0-%d1/%a0-%a1,%sp@-
	moveal	%a2,%a0			| pp
	bsrw	Lcb_core
	moveml	%sp@+,%d0-%d1/%a0-%a1
	addql	&1,freemem		| displaced: the original 0xafd98 operation
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.balign 4
| Release-barrier instrumentation (read via /dev/kmem or Amiberry IPC):
| cb_rel_count MUST climb under any page-churn workload once the hooks are in;
| cb_rel_reject staying 0 is part of the static+runtime acceptance.
	.globl	cb_rel_count
cb_rel_count:
	.long	0
	.globl	cb_rel_reject
cb_rel_reject:
	.long	0
	.balign 4			| pad section to a 4-byte multiple
