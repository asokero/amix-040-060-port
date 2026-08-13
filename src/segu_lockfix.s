| segu_lockfix.s -- override segu_get (orig 0xaa466, GLOBAL T) to RESTORE the
| SEGU_LOCKED bit in the freshly-allocated slot's su_flags (ISSUE-7 root fix).
| See amix-kernel-analysis/vm-map/SEGU-AUDIT.md (Codex's audit) and 3b2 seg_u.c:755-760.
|
| ROOT CAUSE: segu_get sets the new slot's su_flags at 0xaa6aa (`movel %d5,%a3@(20)`)
| from %d5 -- the SAME register that is the u-area map-loop bound set at 0xaa6a2.
| Stock 2KB kernel: `moveq #3,%d5` = 4-click loop AND su_flags = 3 =
| SEGU_ALLOCATED|SEGU_LOCKED.  The Model-B 4KB patch (patch_modelb_pager.py:226)
| correctly changed the loop bound to `moveq #1,%d5` (2 x 4KB pages) -- but d5's
| double duty means su_flags became 1 = ALLOCATED only, DROPPING SEGU_LOCKED (bit1).
| Consequence: segu_release (`btst #1,%a2@(23)`) sees LOCKED clear and passes
| hat_unload flags=0 instead of HAT_UNLOCK|HAT_RELEPP (0xa), so page_get's
| keepcnt=1 hold on the u-pages is never dropped; anon_decref -> page_abort then
| frees a still-held u-page -> the page is recycled while a live u-area still uses
| it -> zeroed live u-areas -> the recurring kernel panics.
|
| WHY A WRAPPER, NOT A BYTE PATCH: d5 must be 1 for the loop compare at 0xaa6a4 and
| 3 for the su_flags store at 0xaa6aa, and there is no room to insert an extra
| instruction between them in place.  So: objcopy --weaken-symbol segu_get +
| --add-symbol segu_get_orig=.text:0xaa466; this strong wrapper calls the original,
| then ORs SEGU_LOCKED back into the new slot's su_flags, restoring the stock
| value ALLOCATED|LOCKED so segu_release again passes HAT_UNLOCK|HAT_RELEPP and
| the u-page hold is released.  The map loop itself stays 2-page (the patch at
| 0xaa6a2 is untouched and still correct).
|
| SLOT LOOKUP: replicated VERBATIM from segu_release's disassembly (0xaa724-0xaa754):
|	moveal segu,%a0 ; moveal %a0@(28),%a3	| a3 = segu->usd base ptr
|	d0 = u_va - %a0@(4)			| offset from segu window base
|	if (d0 < 0) d0 += 8191			| (mirrors segu_release exactly)
|	d0 >>= 13				| 8KB per slot
|	d0 *= 28				| sizeof(usd_t)
|	a2 = d0 + %a3@				| a2 = &slot
| (register-form shifts/mul cribbed from the original: immediate asrl only goes to
| 8, and mulsl is used in the same moveq+mulsl.l Dn,Dn encoding as at 0xaa746-0xaa74c.)
| su_flags is the LONG at slot@(20); LOCKED is bit1 of its LSB byte slot@(23)
| (segu_release: btst #1,%a2@(23)) -> set it with orib &2,%a2@(23).
|
| CALLING CONVENTION: segu_get(struct proc *cp) at %fp@(8); returns p_segu (the
| u-area window VA) in BOTH %d0 and %a0 (procdup at 0x418a8 consumes %a0:
| `movel %a0,%a3@(252)`), or 0 on failure.  The wrapper preserves that contract:
| the return value is stashed in %d1 across the fix and restored into d0 AND a0.
| GUARDS (the fix must never fault): skip the orib if the original returned 0,
| if segu is NULL, or if the computed slot pointer is NULL or odd.  No other
| memory is written.

	.text
	.globl	segu_get
segu_get:
	linkw	%fp,&0
	movel	%d2,%sp@-		| callee-saved scratch for the slot math
	movel	%a2,%sp@-
	movel	%a3,%sp@-
	movel	%fp@(8),%sp@-		| arg: cp
	jsr	segu_get_orig
	addqw	&4,%sp
	movel	%d0,%d1			| stash return (u_va == p_segu) across the fix
	tstl	%d1
	beqw	Lsl_ret			| allocation failed -> return 0 unchanged
| ---- replicate segu_release's slot lookup (a0=segu, a3=segu@28, index from u_va) ----
	moveal	segu,%a0
	movel	%a0,%d2			| guard: segu non-null
	beqw	Lsl_ret
	moveal	%a0@(28),%a3
	movel	%d1,%d2			| d2 = u_va
	subl	%a0@(4),%d2
	bpl	Lsl_pos
	addil	&8191,%d2
Lsl_pos:
	moveq	&13,%d0			| register-form shift (imm asrl max is 8);
	asrl	%d0,%d2			|   same moveq+asrl pair as segu_release 0xaa746
	moveq	&28,%d0
	mulsl	%d0,%d2			| same mulsl.l Dn,Dn encoding as 0xaa74c
	moveal	%d2,%a2
	addal	%a3@,%a2		| a2 = &slot (this proc's segu usd_t)
	movel	%a2,%d2			| guard: slot ptr non-null ...
	beqw	Lsl_ret
	btst	&0,%d2			| ... and even (plausible kernel pointer)
	bnew	Lsl_ret
	orib	&2,%a2@(23)		| su_flags |= SEGU_LOCKED (bit1)
Lsl_ret:
	movel	%d1,%d0			| return value in BOTH d0 and a0
	moveal	%d1,%a0			|   (segu_get's convention; procdup reads a0)
	movel	%sp@+,%a3
	movel	%sp@+,%a2
	movel	%sp@+,%d2
	unlk	%fp
	rts
	nop				| pad .text to a multiple of 4 (relink contiguity)
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
