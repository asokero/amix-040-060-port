| legacysdt040.s -- ISSUE-40: restore the address space's LEGACY-SDT lifetime
| edge, the one hat_free040 never had (2026-08-01).
| Contract: analyysirepo vm-map/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md, which
| answers docs/archive/ISSUE40-CODEX-FOLLOWUP-QUESTIONS.md; root cause in
| vm-map/AVAILRMEM-ACCOUNTING-AUDIT.md (d27a303) and
| kernelsupport/ISSUE40-AVAILRMEM-DECLINE-260801.md.
|
| WHAT IS BROKEN.  Every dynamic exec permanently loses one 4 KiB page of real
| memory.  Measured on hardware with an exact denominator (test-tools/leaktest.c),
| 300 iterations per phase:
|
|     300 x fork        availrmem   +8    availsmem  +123   pages_pp_kernel   -8
|     300 x fork+exec   availrmem -319    availsmem  -319   pages_pp_kernel +319
|     300 x fork+exec   availrmem -308    availsmem  -308   pages_pp_kernel +308
|     300 x fork        availrmem   -8    availsmem    -8   pages_pp_kernel   +8
|
| `availrmem + pages_pp_kernel` is CONSERVED in every phase.  That is the whole
| argument for this file rather than a one-line credit: the page is not lost
| accounting, it is genuinely still held, so `availrmem++` would make the kernel
| offer a page that does not exist -- a worse machine than the leaking one.
| ~6900 pages at boot; a burst suite eats 5000 in 100 minutes and the same suite
| slowed 24m37s -> 45m56s across that span.
|
| MECHANISM.  A dynamic exec maps libc through the RETAINED stock path
|     segvn_create -> hat_map -> hat_growsdt -> hat_sdtalloc
| which makes a 17-unit legacy-SDT allocation (130 entries at UVSHM = 0xc1000000,
| ceil(130/8) = 17 of the allocator's 64-byte units).  The p_sdtbits bitmap holds
| 32 units, so two 17-unit allocations cannot share a backing page and every exec
| address space gets a page of its own.  The 030 destructor released it with
| `hat_growsdt(hatp, section, 0)` (3B2 vm/vm_hat.c:356).  Our hat_free040 walks
| only the live 040 A/B/C tree and ends at kmem_free(root, 0x1000): the debit is
| in retained stock code, the missing credit is in OUR override.  This file is
| that one edge and nothing else.
|
| WHY BEFORE THE A/B/C WALK (contract Q1).  The legacy descriptors live in the
| SAME 4 KiB root page the native walk owns:
|
|     section 2 descriptor  root+0x10..0x13   = native root entry A4
|     section 2 table base  root+0x14..0x17   = native root entry A5
|     section 3 descriptor  root+0x18..0x1b   = native root entry A6
|     section 3 table base  root+0x1c..0x1f   = native root entry A7
|
| The walk usually skips A4/A6 via Lf_badA, but that is a bounds check, not an
| ownership contract -- it may traverse and it will clear root words as it goes.
| So the call belongs after hat_free's null-root guard and BEFORE the first
| read of root[A].  After the walk it would be reading rubble.
|
| WHY nentries = 0 IS THE ACCEPTED CALL (contract Q2).  With nentries = 0,
| hat_growsdt takes a byte-visible no-iteration path (0xb60e4..0xb610c): it frees
| the ENTIRE original allocation from its ORIGINAL base via hat_sdtfree at
| 0xb611e, then clears the section's UDT, then returns 0.  It never performs the
| unsafe nonzero partial shrink (obase + nsize*64).  hat_sdtfree's two PFN shifts
| are already Model-B (patch_modelb.py: 0xb65e4 and 0xb6610 = `72 0c`), and
| hat_map's vnode preload is disabled, hat_exec is our no-op, hat_dup is native
| and stock hat_swapout is unreachable -- so the legacy object holds coverage
| allocation, not live old PTE children.  This narrow acceptance does NOT reopen
| nonzero partial legacy resize, vnode preload, old hat_exec or old hat_swapout.
|
| ABI TRAP: argument 1 is `as + 0x14`, the ADDRESS of the root-pointer field --
| hat_growsdt+0x26 dereferences it to obtain root.  Passing root itself would
| make it treat root[0] as a pointer.
|
| THE SHAPE GUARD IS OURS, NOT THE CONTRACT'S.  The contract argues sections 2
| and 3 are safe because user VAs live at 0xC0000000+ (root entries 96..127), so
| native entries A4..A7 are never real.  That argument is correct today and it is
| an argument.  A native descriptor at A4/A6 would have UDT = 3 too, and handing
| its neighbour word to hat_sdtfree as a base would free a LIVE pointer table --
| silent corruption, the one failure class this port can least afford to debug.
| So before calling we re-derive exactly what hat_sdtfree will compute and refuse
| anything that is not a plausible allocator object (contract Q3's formulas):
|
|     entries = be16(rdesc) + 1            n = (entries + 7) >> 3
|     base    = be32(rdesc + 4)
|     require base>>12 in [pages_base, pages_end)
|     require n <  32 ->  ((base & 0x7ff) >> 6) + n <= 32   (fits p_sdtbits)
|     require n >= 32 ->  (base & 0xfff) == 0               (whole-page groups)
|
| A native descriptor fails these: its base word carries UDT bits in the low two
| bits, so it is not 64-byte aligned and the index+n test rejects it.  The guard
| costs ~15 instructions on a per-teardown path and turns "safe by argument" into
| "safe by construction" -- and i40_bad_n turns the argument into a NUMBER.  The
| same lesson as hat_free's own V3 Lf_badA guard, which was added only after the
| first real-hardware panic of the Mercury visit.
|
| WHY NO CACHE OPERATION (contract Q4).  The legacy table is reached through the
| retained D0-NC physical alias while it is owned as an SDT; a page that actually
| becomes free crosses the existing central cb_page_release barrier inside
| page_free; and hat_free's own final `cpusha bc; pflusha` before kmem_free(root)
| is still the native tree's publication point.  Adding cpusha/cinva per call
| would duplicate both without closing a new ownership transition.
|
| SCOPE (contract Q5).  This unit fixes the legacy-SDT lifetime only.  The ptdat
| metadata leak in hat_ptfree (one 64-byte unit per newly allocated table page,
| reachable from fork -- the likely source of the +-8..16 background drift) and
| the USIZE-as-4-KiB-page-count question are separate units on purpose.  They
| share allocator capacity, so residual TIMING can move; they do not share
| ownership, so they do not need to land together.  Acceptance therefore requires
| the deterministic ~1-page-per-dynamic-exec slope to be GONE, not perfect zero
| drift while ptdat is still open.
|
| COUNTERS (uncapped: a boot that comes up is not evidence that the edge fired;
| only a counter is).  Anchor first, per the rule that caught a stale read:
|   i40_magic     0x49343021 "I40!" -- if this does not read back, every other
|                 address on the line is stale and nothing below means anything
|   i40_calls     hat_free teardowns that reached the edge
|   i40_sec2_n    section-2 legacy objects released
|   i40_sec3_n    section-3 legacy objects released  (the libc/UVSHM one; this is
|                 the counter that should track the dynamic-exec count)
|   i40_empty_n   sections with UDT = 0 -- nothing allocated, nothing to free
|   i40_bad_n     sections whose descriptor did NOT have allocator shape.  MUST
|                 be 0 on a healthy boot; nonzero means the aliasing argument
|                 above is false on this workload and the guard just saved us
|   i40_err_n     hat_growsdt returned nonzero on a zero-length call, which the
|                 disassembly says is impossible.  Nonzero = the binary is not
|                 what we read; stop and re-derive before trusting anything
|   i40_pgfreed_n PAGES actually returned (availrmem delta across the call)
|   i40_held_n    releases that returned NOTHING because p_sdtbits still had
|                 bits from another owner -- releasing the object and getting a
|                 page back are different events, and this is the difference
|   i40_last_n    unit count of the last object released (the audit's model says
|                 17 for the libc/UVSHM section-3 object; check, do not assume)
|
| i40_on ships 1.  It exists so the fix can be A/B'd IN ONE BOOT on hardware
| (kpoke 0, run leaktest 300 1, kpoke 1, run it again) -- the same idiom as
| hat_cm_ram / codepub_on / kdbg_on.  With i40_on = 0 the counters still advance
| through i40_calls, so "the gate is where I think it is" stays checkable.  An
| image SHIPPING 0 is a bisect image and must be stamped as such.
|
| Register contract: called from hat_free with fp intact.  Saves d2-d4 (used as
| scratch across the call); d0/d1/a0/a1 are caller-saved under this ABI and
| hat_growsdt itself preserves d2-d7/a2, so the section number survives in d4.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c legacysdt040.s -o build/legacysdt040.o
| Requires: --globalize-symbol hat_growsdt (it is a file-LOCAL `t` at 0xb6058;
| globalized, never weakened or replaced -- we CALL the retained body).

	.text

	.globl	hat_legacy_sdt_free
hat_legacy_sdt_free:
	linkw	%fp,&0
	moveml	%d2-%d4,%sp@-
	addql	&1,i40_calls
	tstl	i40_on
	beqw	L40_out			| A/B image: count the teardown, free nothing
	moveal	%fp@(8),%a0
	movel	%a0@(20),%d0		| root (hat_free already proved it non-NULL,
	beqw	L40_out			|   but this routine states its own guard)
	moveq	&2,%d4
	bsrw	L40_section
	moveq	&3,%d4
	bsrw	L40_section
L40_out:
	moveml	%sp@+,%d2-%d4
	unlk	%fp
	rts

| --- one legacy section, number in d4 (2 or 3).  Clobbers d0-d3/a0/a1. --------
L40_section:
	moveal	%fp@(8),%a0		| as
	moveal	%a0@(20),%a1		| root
	movel	%d4,%d0
	asll	&3,%d0			| section * 8 (030 SDEs are 8 bytes)
	lea	%a1@(0,%d0:l),%a1	| a1 = rdesc
	movel	%a1@,%d1
	andil	&3,%d1			| UDT -- the same two bits hat_growsdt reads
	bnew	L40_live		|   as bfextu rdesc@(3){6:2}
	addql	&1,i40_empty_n
	rts
L40_live:
	clrl	%d1
	movew	%a1@,%d1		| 16-bit section limit = entries - 1
	addql	&1,%d1			| entries
	addql	&7,%d1
	lsrl	&3,%d1			| d1 = n = ceil(entries/8) 64-byte units
	movel	%a1@(4),%d0		| d0 = legacy table PHYSICAL base
| --- shape guard: refuse anything hat_sdtfree could not have allocated --------
	movel	%d0,%d2
	moveq	&12,%d3
	lsrl	%d3,%d2			| d2 = pfn
	cmpl	pages_base,%d2
	bcsw	L40_bad			| below the managed pool -> hat_sdtfree would
	cmpl	pages_end,%d2		|   take its NULL-page_t path and then write
	bccw	L40_bad			|   through it at 0xb6670
	cmpil	&32,%d1
	bccw	L40_big
	movel	%d0,%d2
	andil	&0x7ff,%d2
	lsrl	&6,%d2			| 64-byte index within the 2 KiB bitmap span
	addl	%d1,%d2
	cmpil	&33,%d2
	bccw	L40_bad			| index + n > 32 -> not a p_sdtbits object
	braw	L40_go
L40_big:
	movel	%d0,%d2
	andil	&0xfff,%d2
	bnew	L40_bad			| >= 32 units must start page-aligned
L40_go:
	movel	%d1,i40_last_n		| latch n and base BEFORE the call: hat_growsdt
	movel	%d0,i40_last_base	|   preserves d2-d7/a2 only, so d0/d1 are gone
	movel	availrmem,%d3		| see i40_pgfreed_n / i40_held_n below
	clrl	%sp@-			| nentries = 0 -> whole-object release
	movel	%d4,%sp@-		| section
	moveal	%fp@(8),%a0
	lea	%a0@(20),%a0
	movel	%a0,%sp@-		| hatp = &as->a_hat = as + 0x14, NOT root
	jsr	hat_growsdt
	lea	%sp@(12),%sp
	movel	availrmem,%d2
	subl	%d3,%d2			| did hat_sdtfree reach its credit at 0xb66e4?
	beqw	L40_held
	addl	%d2,i40_pgfreed_n	| yes: the backing page went back to the pool
	braw	L40_acct
L40_held:
	addql	&1,i40_held_n		| no: p_sdtbits still has bits from another owner
| Latch WHO still owns bits in that backing page.  "The release returned no
| page" is a fact; "a leaked ptdat crumb is why" is a hypothesis, and the
| residual bitmap is the difference between them.  pp = pages + (pfn -
| pages_base)*60, computed WITHOUT muls.l (ISSUE-34: the 68060 traps every
| 64-bit muls.l form; 60 = 64 - 4 costs the same and boots on both CPUs).
	movel	i40_last_base,%d1
	moveq	&12,%d2
	lsrl	%d2,%d1			| pfn
	subl	pages_base,%d1		| page index
	movel	%d1,%d2
	lsll	&6,%d2			| index * 64
	lsll	&2,%d1			| index * 4
	subl	%d1,%d2			| index * 60
	moveal	%d2,%a0
	addal	pages,%a0		| a0 = pp
	movel	%a0@(32),i40_last_bits	| p_sdtbits union
L40_acct:
	tstl	%d0
	beqw	L40_ok
	addql	&1,i40_err_n		| impossible per the disassembly -> say so
L40_ok:
	cmpil	&2,%d4
	bnew	L40_ok3
	addql	&1,i40_sec2_n
	rts
L40_ok3:
	addql	&1,i40_sec3_n
	rts
L40_bad:
	addql	&1,i40_bad_n
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even

	.globl	i40_magic
i40_magic:
	.long	0x49343021		| "I40!"
| i40_on: 1 = release the legacy SDT (the shipped default), 0 = count the
| teardowns and change nothing, for the decisive one-boot A/B in both directions.
	.globl	i40_on
i40_on:
	.long	1
	.globl	i40_calls
i40_calls:
	.long	0
	.globl	i40_sec2_n
i40_sec2_n:
	.long	0
	.globl	i40_sec3_n
i40_sec3_n:
	.long	0
	.globl	i40_empty_n
i40_empty_n:
	.long	0
	.globl	i40_bad_n
i40_bad_n:
	.long	0
	.globl	i40_err_n
i40_err_n:
	.long	0
| i40_pgfreed_n / i40_held_n: THE question this unit cannot answer from its own
| success.  hat_sdtfree only credits availrmem/availsmem/pages_pp_kernel (0xb66e4)
| when clearing our bits leaves p_sdtbits ZERO -- i.e. when nothing else in that
| 2 KiB bitmap span is still allocated.  So "we released the object" and "the
| machine got a page back" are different events, and the difference is exactly
| Codex's Q5 warning: a leaked one-unit ptdat record in the same backing page
| keeps it charged.  Sampling availrmem across the call turns that from an
| argument into a number: i40_pgfreed_n counts PAGES actually returned,
| i40_held_n counts releases that returned nothing.
	.globl	i40_pgfreed_n
i40_pgfreed_n:
	.long	0
	.globl	i40_held_n
i40_held_n:
	.long	0
| i40_last_n: the unit count of the most recently released object.  The audit's
| model says the libc/UVSHM section-3 object is 17 units (130 entries); this is
| how that model is checked on THIS machine instead of assumed.
	.globl	i40_last_n
i40_last_n:
	.long	0
	.globl	i40_last_base
i40_last_base:
	.long	0
| i40_last_bits: p_sdtbits of the backing page right after a release that
| returned nothing.  17 units at index 0 would clear mask 0x0001ffff, so any
| residual tells you both HOW MANY units and WHERE the other owner sits.
	.globl	i40_last_bits
i40_last_bits:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
