| ============================================================================
| segu_ubptbl040.s -- post-fix wrappers for segu_get + swapinub: REBUILD the
| per-proc p_ubptbl from the live kptr040 tree after the stock fill loops run.
|
| BUG (ISSUE-7 family, PREEMPT5-confirmed pubt0=0 pubt2=0): on the 040 port,
| hat_memload -> our hat_pteload writes the u-area leaf PTEs ONLY into the live
| kptr040 tree.  But stock segu_get (0xaa466, tail loop 0xaa6c4-0xaa706) and
| stock swapinub (0xa9e5c, loop 0xa9ee0-0xa9f22) each contain an INLINE walk of
| the inert 030 st_top1 tree (va>>17 SDE, va>>11 leaf, 4 x 2KB steps) to copy
| the u-area PTEs into p_ubptbl = (proc+95)&~15.  Nobody populates st_top1 on
| the 040, so those walks read the empty leaf slots and p_ubptbl ends up ZEROS.
| Consumers of p_ubptbl then read garbage: prumap040's kvsegu slot-0 alias
| (/proc), segu_softunload's page lookup (swap round-trip -- it SKIPS every
| page whose entry is invalid, so the u-area is never written to swap), and
| the u_procp=0 corruption chain.
|
| FIX (approved design): do NOT transcribe or byte-patch the complex stock
| functions.  Wrap them: call the original (whole chain intact), then OVERWRITE
| p_ubptbl with the truth by walking the live kptr040 tree for the two 4KB
| u-area pages.  The stock tail loops still run and write zeros first; the
| stray st_top1 leaf reads hit valid RAM (0x0714Exxx) -- harmless.
|
| ENTRY FORMAT (verified against p0init's own fill, vanilla 0x490b0-0x49128:
| phys = (svirtophys(u + i*2048) + 2047) & ~2047, entry = phys | 1, 4 entries
| at 2KB VA steps; prumap040/resume040 consume entries 0 and 2 as the two 4KB
| frames): for u-area pages phys0 = pte(va)&~0xFFF, phys1 = pte(va+0x1000)&~0xFFF:
|	ubptbl[0] = phys0 | 1		ubptbl[1] = (phys0 + 0x800) | 1
|	ubptbl[2] = phys1 | 1		ubptbl[3] = (phys1 + 0x800) | 1
| If the pointer desc (UDT bit1) or leaf PTE (PDT bit0) is not resident, the
| two entries for that page are written 0 (invalid, same as p_ubptbl's reset
| state) instead of garbage.
|
| THE WALK (resume040/prumap040 path-V idiom; kptr040 = GLOBAL exported by
| pstart040.s, holds the base of the FLAT 32x128-entry pointer-table run):
|	desc  = *(kptr040 + ((va>>18) - 4096)*4)	| pointer descriptor
|	leaf  = desc & 0xffffff00			| (UDT bit1 must be set)
|	pte   = *(leaf + ((va>>12) & 0x3f)*4)		| (PDT bit0 must be set)
|	phys  = pte & 0xfffff000
|
| CHAINS (one strong def per symbol per build):
|   base:  segu_get(HERE) -> segu_get_lockfix (segu_lockfix.o, renamed by
|          objcopy --redefine-sym in relink-040.sh) -> segu_get_orig (stock);
|          swapinub(HERE) -> swapinub_stock (stock 0xa9e5c, --add-symbol).
|   dbg:   segu_swap_dbg probe swapinub -> swapinub_orig (now resolved at
|          build time to THIS wrapper's address in $IN, HPU_ORIG-style) ->
|          swapinub_stock.  segu_get chain inherited from base unchanged.
|   quiet: both chains inherited from base unchanged.
|
| CALLING CONVENTIONS (verified from stock disasm):
|   segu_get(cp)@fp@(8): returns the mapped u-area base VA in BOTH d0 and a0
|     (stock tail 0xaa70a: movel %d4,%d0 ... moveal %d0,%a0; procdup reads a0),
|     0 on failure -> rebuild skipped, 0 passed through in both regs.
|   swapinub(p)@fp@(8): u-area VA = p->p_segu = p@(252) (stock 0xa9eda:
|     movel %a2@(252),%d1); returns 1 in d0 AND a0 (0xa9f2c) -- preserved.
|     p_segu==0 -> rebuild skipped.
| No cache ops: D-cache is off on this port, p_ubptbl is CPU-read only.
| ============================================================================

	.text

| ---- segu_get: alloc + map a u-area window, then rebuild p_ubptbl ----
	.globl	segu_get
segu_get:
	linkw	%fp,&0
	moveml	%d2-%d5/%a2-%a3,%sp@-
	movel	%fp@(8),%sp@-		| arg: cp
	jsr	segu_get_lockfix	| lockfix wrapper -> stock segu_get
	addqw	&4,%sp
	movel	%d0,%d3			| stash return (u-area VA, 0 on failure)
	beqw	Lsg_ret			| failed -> pass 0 through, no rebuild
	movel	%d3,%d2			| d2 = u-area VA
	moveal	%fp@(8),%a2		| a2 = proc
	bsrw	Lrebuild
Lsg_ret:
	movel	%d3,%d0			| return value in BOTH d0 and a0
	moveal	%d3,%a0			|   (stock segu_get convention; procdup reads a0)
	moveml	%sp@+,%d2-%d5/%a2-%a3
	unlk	%fp
	rts

| ---- swapinub: swap the u-area back in, then rebuild p_ubptbl ----
	.globl	swapinub
swapinub:
	linkw	%fp,&0
	moveml	%d2-%d5/%a2-%a3,%sp@-
	movel	%fp@(8),%sp@-		| arg: p
	jsr	swapinub_stock		| stock swapinub (0xa9e5c)
	addqw	&4,%sp
	movel	%d0,%d3			| stash return value
	moveal	%fp@(8),%a2		| a2 = proc
	movel	%a2,%d2			| guard: proc nonzero
	beqw	Lsi_ret
	movel	%a2@(252),%d2		| d2 = p->p_segu = u-area VA
	beqw	Lsi_ret			| no segu window -> skip rebuild
	bsrw	Lrebuild
Lsi_ret:
	movel	%d3,%d0			| return value in BOTH d0 and a0
	moveal	%d3,%a0			|   (stock 0xa9f2c: moveal %d0,%a0)
	moveml	%sp@+,%d2-%d5/%a2-%a3
	unlk	%fp
	rts

| ---- Lrebuild: p_ubptbl = live kptr040 truth for the 2 u-area 4KB pages ----
| in:  d2 = u-area VA (4KB-aligned kvsegu window base), a2 = proc
| out: p_ubptbl[0..3] written (p0init 2KB-entry format, or 0 if unmapped)
| clobbers d0/d1/d2/d4/d5/a0/a3 (all saved by the callers above)
Lrebuild:
	movel	%a2,%d0
	addil	&95,%d0
	andil	&0xfffffff0,%d0		| p_ubptbl = (proc + 95) & ~15
	moveal	%d0,%a3
	moveq	&1,%d5			| 2 pages (loop counter for dbf)
Lrb_page:
	movel	%d2,%d4
	moveq	&18,%d0			| register-form shift (imm lsrl max is 8)
	lsrl	%d0,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a0
	movel	%a0@,%d4		| pointer descriptor
	btst	&1,%d4			| UDT: 10/11 = resident
	beq	Lrb_bad
	andil	&0xffffff00,%d4		| d4 = leaf table base
	movel	%d2,%d1
	moveq	&12,%d0
	lsrl	%d0,%d1
	andil	&0x3f,%d1
	asll	&2,%d1
	addl	%d1,%d4
	moveal	%d4,%a0
	movel	%a0@,%d4		| leaf PTE
	btst	&0,%d4			| PDT: 01/11 = resident (00 inv, 10 indirect)
	beq	Lrb_bad
	andil	&0xfffff000,%d4		| d4 = phys frame
	moveq	&1,%d1
	addl	%d4,%d1			| phys | 1  (p0init entry format)
	movel	%d1,%a3@
	addil	&0x800,%d1		| (phys + 0x800) | 1
	movel	%d1,%a3@(4)
	bra	Lrb_next
Lrb_bad:
	clrl	%a3@			| unmapped -> invalid entries, not garbage
	clrl	%a3@(4)
Lrb_next:
	addil	&0x1000,%d2		| next 4KB u-area page
	addqw	&8,%a3			| next p_ubptbl entry pair
	dbf	%d5,Lrb_page
	rts
	nop				| pad .text to a multiple of 4 (relink contiguity)
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
