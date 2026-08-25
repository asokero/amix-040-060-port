| pageinitzero.s -- the page-frame database is raw DRAM, and nothing zeroes it.
| ISSUE-102.  Zero it before page_init() publishes it, and count what was in it.
| (2026-08-20)
|
| WHY THIS EXISTS.  Measured on the card, 2026-08-20, from the first 68040 boot
| whose panic path survived long enough to be read (ISSUE-100):
|
|     PANIC: page_free
|     Backtrace: 80F4964:
|
| and, walked out of the boot stack frame chain by hand:
|
|     stext+0x30 -> Lps_nopcr+0x2a (pstart040) -> mlsetup+0xb0 -> kvm_init+0x28e
|       -> memialloc+0x94 -> page_free+0x11c -> cmn_err(CE_PANIC, "page_free")
|
| That is boot-time VM setup handing the page allocator its initial free memory.
| Reading the three routines against the stock image says why it dies:
|
|   1. kvm_init (.text+0x48c2e) sizes the page-frame database and gets memory for
|      it with `sptalloc(npages, 1, first_free_click, 0)`.
|   2. sptalloc (.text+0xa8bb6) branches on that third argument.  Zero means
|      "allocate pages" -> segkmem_alloc.  NON-zero -- this call -- means "map the
|      physical memory that is already at this click" -> **segkmem_mapin**.  It
|      allocates nothing and it clears nothing: the page-frame database is a
|      window onto whatever those DRAM cells already held.
|   3. page_init (.text+0xaf42a) sets `pages`, `epages`, `pages_base`,
|      `pages_end`, `max_page_get`, checks that page_hash/page_hashsz are set --
|      and its ONLY write to the array is `orib #-128,%a0@` per struct, i.e. it
|      ORs p_lock into byte 0 and touches nothing else.  It never zeroes the
|      structs and never zeroes the hash.  Both are ASSUMED to arrive zero.
|   4. kvm_init then calls `memialloc(first_free_click, maxclick)`
|      (.text+0x5289c), which walks the array in 60-byte steps calling
|      `page_free(pp, 1)` on every struct.
|   5. page_free (.text+0xaf9ea) refuses to free a page that is still held:
|      `p_keepcnt` (+2), `p_mapping` (+32), `p_lckcnt` (+36) and `p_cowcnt` (+38)
|      must all be zero, and all four branches converge on the same
|      `cmn_err(CE_PANIC, "page_free")` at .text+0xafb00 -- which is why the panic
|      text names no field.
|
| So a non-zero bit anywhere in those four fields, in any of the structs, panics
| the boot.  At this point nothing in the system has ever mapped, locked or held a
| managed page -- hat_init() has only just returned and no page has been handed
| out -- so a non-zero value there cannot be state.  It can only be whatever the
| DRAM contained.  The assertion is right; the precondition is what is missing.
|
| WHY THE BENCH NEVER SEES IT.  The emulator hands out zero-filled RAM, so the
| assumption "sptalloc'd physical memory is zero" is always true there.  On metal
| the kernel is loaded by a program running under AmigaOS, out of the same Fast
| RAM pool AmigaOS has been allocating from, and the database lands about 1.4 MB
| above the load base -- in memory AmigaOS was recently using.  This is the exact
| failure class AGENTS.md warns about: an untested path in the emulator looks
| identical to a passing one.
|
| WHAT THIS UNIT DOES.  It takes page_init's own arguments -- `pp_base` and
| `npages`, the same two the stock body turns into `pages` and
| `epages = pages + 60*npages` -- zeroes exactly `60 * npages` bytes, zeroes the
| `page_hashsz` 4-byte hash buckets at `page_hash` (set by kvm_init before this
| call, in the same sptalloc'd window), and then tail-jumps to the stock body with
| the stack untouched.  The bounds are the stock body's own arithmetic, so they
| cannot drift from it: there is no second opinion about how big the array is.
|
| Zeroing memory that the code below already requires to be zero cannot change the
| behaviour of a machine where it was already zero.  On the bench this unit is a
| no-op with a counter block; on metal it is the difference between booting and
| not.
|
| THE COUNTER BLOCK IS THE POINT, not decoration.  The diagnosis above says the
| DRAM was dirty.  That is falsifiable, and this unit is what falsifies it,
| because it reads every struct BEFORE it clears it:
|
|     pgz_dirty_n  structs with any non-zero byte
|     pgz_held_n   structs page_free would have REFUSED -- the panic count
|     pgz_first_i  index of the first such struct, with the three field words
|                  (pgz_first_w0 = bitfields+p_keepcnt, pgz_first_map = p_mapping,
|                  pgz_first_lc = p_lckcnt<<16|p_cowcnt) exactly as they were
|     pgz_hash_n   non-zero hash buckets (each one a wild pointer page_find would
|                  have followed later -- a second, quieter bug the same cause)
|
| A boot that comes up with `pgz_held_n` non-zero has PROVEN the diagnosis and
| named the page.  A boot that comes up with `pgz_held_n == 0` has REFUTED it, and
| whatever fixed the boot did so for a different reason -- which is worth more
| than the fix.  Predicted before the run: on the card pgz_held_n > 0; on the
| bench every counter except pgz_calls and pgz_npages is 0.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c pageinitzero.s -o build/pageinitzero.o
| Wire:     --weaken-symbol page_init + --add-symbol page_init_orig=.text:0xaf42a
|           (relink-040.sh).  Externals: page_hash, page_hashsz (both global D).
| ============================================================================

	.text
	.globl	page_init
page_init:
	linkw	%fp,&0
	moveml	%d2-%d7/%a2-%a3,%sp@-
	addql	&1,pgz_calls
	moveal	%fp@(8),%a2		| a2 = pp_base   (becomes `pages`)
	movel	%fp@(12),%d2		| d2 = npages    (epages = pages + 60*npages)
	movel	%d2,pgz_npages
	tstl	%d2
	beqw	Lpgz_hash
	moveq	&0,%d4			| d4 = struct index

Lpgz_page:
| --- read-only: is anything at all in this 60-byte struct non-zero? ---
	moveal	%a2,%a0
	moveq	&0,%d5			| d5 = OR of all 15 longs
	moveq	&14,%d6
Lpgz_scan:
	movel	%a0@+,%d0
	orl	%d0,%d5
	dbf	%d6,Lpgz_scan
	tstl	%d5
	beqw	Lpgz_zero		| already clean -- nothing to count
	addql	&1,pgz_dirty_n

| --- would page_free have REFUSED this page?  its four held-page tests, in one
|     expression: p_keepcnt (+2), p_mapping (+32), and p_lckcnt/p_cowcnt read as
|     the single long at +36 because both halves are tested and both must be 0. ---
	moveq	&0,%d3
	movew	%a2@(2),%d3		| p_keepcnt   (zero-extended: d3 was cleared)
	movel	%a2@(32),%d0		| p_mapping
	orl	%d0,%d3
	movel	%a2@(36),%d0		| p_lckcnt<<16 | p_cowcnt
	orl	%d0,%d3
	tstl	%d3
	beqw	Lpgz_zero
	addql	&1,pgz_held_n
| --- latch the FIRST one, before it is cleared: this is the evidence ---
	tstl	pgz_have
	bnew	Lpgz_zero
	movel	&1,pgz_have
	movel	%d4,pgz_first_i
	movel	%a2@,pgz_first_w0	| bitfields (0..1) + p_keepcnt (2..3)
	movel	%a2@(32),pgz_first_map
	movel	%a2@(36),pgz_first_lc

Lpgz_zero:
	moveal	%a2,%a0
	moveq	&14,%d6
Lpgz_clr:
	clrl	%a0@+
	dbf	%d6,Lpgz_clr		| 15 longs == sizeof(struct page) == 60
	lea	%a2@(60),%a2
	addql	&1,%d4
	cmpl	%d2,%d4
	bcsw	Lpgz_page		| unsigned: i < npages

| --- the hash buckets live in the same sptalloc'd window and are equally raw.
|     page_init itself panics if either of these is unset, so they are valid here. ---
Lpgz_hash:
	moveal	page_hash,%a3
	movel	page_hashsz,%d2
	movel	%d2,pgz_hashsz
	tstl	%a3
	beqw	Lpgz_done
	tstl	%d2
	beqw	Lpgz_done
Lpgz_hb:
	movel	%a3@,%d0
	beqw	Lpgz_hb0
	addql	&1,pgz_hash_n
Lpgz_hb0:
	clrl	%a3@+			| 4-byte buckets (kvm_init: page_hashsz << 2)
	subql	&1,%d2
	bnew	Lpgz_hb

Lpgz_done:
	moveml	%sp@+,%d2-%d7/%a2-%a3
	unlk	%fp
| The stack now holds page_init's own return address and its three arguments,
| exactly as they were on entry, so the stock body's rts returns straight to
| kvm_init (register- and stack-transparent, the config_orig idiom).
	jmp	page_init_orig
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	pgz_magic
pgz_magic:
	.long	0x50475a21		| "PGZ!"
	.globl	pgz_calls
pgz_calls:
	.long	0
| Page structs the database was sized for (page_init's npages argument).
	.globl	pgz_npages
pgz_npages:
	.long	0
| Structs that had ANY non-zero byte before this unit cleared them.
	.globl	pgz_dirty_n
pgz_dirty_n:
	.long	0
| Structs page_free would have refused to free.  Non-zero == the panic, counted.
	.globl	pgz_held_n
pgz_held_n:
	.long	0
| The first refused struct, latched before it was cleared.
	.globl	pgz_have
pgz_have:
	.long	0
	.globl	pgz_first_i
pgz_first_i:
	.long	0
	.globl	pgz_first_w0
pgz_first_w0:
	.long	0
	.globl	pgz_first_map
pgz_first_map:
	.long	0
	.globl	pgz_first_lc
pgz_first_lc:
	.long	0
| Hash buckets that arrived non-zero, and the bucket count they were counted over.
	.globl	pgz_hash_n
pgz_hash_n:
	.long	0
	.globl	pgz_hashsz
pgz_hashsz:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
