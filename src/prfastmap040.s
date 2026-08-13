| prfastmap040.s -- 68040 port of the procfs fast page-mapping shortcut (ISSUE-17) plus
| the shared per-process VA->PTE walker that vtop040 needs for user addresses (ISSUE-18a).
|
| ===========================================================================
| WHY prfastmapin CANNOT BE BYTE-PATCHED
|
| Stock prfastmapin (0x63484) is "a modified version of vtop()" (3b2 prmachdep.c:271)
| and walks the 030 SEGMENT tree:
|
|     sid   = SECNUM(a) = (a >> 30) & 3            ASSERT(sid != SCN0 && sid != SCN1)
|     sp    = p->p_as->a_hat.hat_srama[sid - SCN2] 0x634a4  p_as   @ proc+124
|                                                  0x634a8  *(as+20)
|     sde_p = &sp[SEGNUM(a)]                       0x634ba  *(base + 4 + sid*8)
|     pte_p = &((pte_t *)(sde_p->wd2.address & ~0x1F))[(a >> 11) & 0x3F]
|     return pfntophys(pte_p->pgm.pg_pfn) + PAGOFF(a)
|
| On the 040 port `as@(20)` no longer holds an 030 SDE-array pointer: hat_alloc
| (hat040.s:1211  `movel %a0,%a2@(20)`) stores the **040 root table VA** there -- 128
| four-byte pointer descriptors.  The stock walk therefore reads 040 descriptors as
| 8-byte 030 SDEs, computes a wild `sde_p`, and dereferences it (`bftst %a0@(3)`) --
| garbage at best, a bus error at worst.  Flipping the `>>11`/`<<11`/`0x7ff` immediates
| would leave the *structure* wrong, so the whole walk is replaced here.
|
| The same applies to the slow path: prusrio's fallback is prmapin (0x63462), which is
| nothing but `vtop(addr, p)`, and vtop_orig's proc != 0 branch (0xb75c0) is that same
| dead 030 walk.  So /proc process memory is broken on BOTH paths; one 040 walker fixes
| both.  vtop040.s calls `uvatopte040` below for user VAs.
|
| ===========================================================================
| ADDRESS-SPACE LAYOUT (unchanged from stock; SECNUM = (va >> 30) & 3)
|
|     SCN0  0x00000000-0x3FFFFFFF  low identity RAM (DTT0 transparent, phys == va)
|     SCN1  0x40000000-0x7FFFFFFF  kernel virtual: kvseg/segmap/sptmap, SRP = kroot040
|     SCN2  0x80000000-0xBFFFFFFF  USER  } per-proc URP = as@(20) = root040
|     SCN3  0xC0000000-0xFFFFFFFF  USER  }
|
| Confirmed in-tree: pstart040.s:330 "user VAs >=0x80000000 are legitimate user space",
| hat040.s:1113 "sh's text/data region [0x80000000,0x80080000)", svirtophys 0xb7744
| (accepts SECNUM == 1 only), and stock prfastmapin's own ASSERT(sid != SCN0 && != SCN1).
|
| 040 root/pointer/leaf geometry (identical to hat_pteload / hat_unlock / uvatosde040):
|     A = (va >> 25) & 0x7F   root[A*4]   -> Adesc, ptr-table  = Adesc & 0xFFFFFE00
|     B = (va >> 18) & 0x7F   ptr[B*4]    -> Bdesc, leaf-table = Bdesc & 0xFFFFFF00
|     C = (va >> 12) & 0x3F   leaf[C*4]   -> PTE
| 040 page descriptor: bits 31:12 phys, bit 2 = W (write protected), bits 1:0 = PDT
| (00 = invalid).  A resident PTE is therefore never 0, so 0 is an unambiguous
| "not mapped" return value.  Page tables live in the identity-mapped SDT pool, so a
| descriptor's value IS a readable VA for the next level -- the same assumption
| hat_pteload relies on.  Every level's UDT/PDT is checked BEFORE the next dereference,
| which is what makes this walk safe on an arbitrary (possibly unmapped) user VA;
| uvatosde040 deliberately omits those checks because its caller has already faulted.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c prfastmap040.s -o build/prfastmap040.o
| Wire:     --weaken-symbol prfastmapin  (this strong def wins)
|           uvatopte040 is a new GLOBAL consumed by vtop040.s
| Globals used (all C): pages, pages_base, pages_end
| prfastmapout is NOT overridden -- its only defect is the phys>>PNUMSHFT shift, byte
| patched (11 sites) by patch_procio.py.
| ===========================================================================

	.text

| ===========================================================================
| uvatopte040(va, p) -- resolve a USER virtual address through proc p's 040 page tables.
|   arg@8  = va        (expected >= 0x80000000; not enforced -- callers dispatch)
|   arg@12 = p         (proc_t *)
| Returns the LEAF PTE VALUE in d0 (and a0), or 0 if any level is invalid / absent.
| The caller extracts phys (PTE & 0xFFFFF000) + (va & 0xFFF) and the W bit (PTE & 4).
	.globl	uvatopte040
uvatopte040:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(8),%d2		| d2 = va

	movel	%fp@(12),%d0		| p
	beqw	Luvp_fail
	moveal	%d0,%a0
	movel	%a0@(124),%d0		| p->p_as        [same offset as 030]
	beqw	Luvp_fail
	moveal	%d0,%a0
	movel	%a0@(20),%d0		| as@(20) = 040 root table VA (hat_alloc)
	beqw	Luvp_fail		| address space has no root yet
	moveal	%d0,%a0

| --- A (root) index = (va >> 25) & 0x7F -----------------------------------
	movel	%d2,%d0
	moveq	&25,%d3
	lsrl	%d3,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a0@(0,%d0:l),%d1	| d1 = Adesc (040 pointer descriptor)
	movel	%d1,%d0
	andil	&3,%d0			| UDT
	beqw	Luvp_fail		| root entry invalid -> nothing mapped here
	andil	&0xfffffe00,%d1		| pointer-table base (512-aligned)
	moveal	%d1,%a0

| --- B (pointer) index = (va >> 18) & 0x7F --------------------------------
	movel	%d2,%d0
	moveq	&18,%d3
	lsrl	%d3,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a0@(0,%d0:l),%d1	| d1 = Bdesc
	movel	%d1,%d0
	andil	&3,%d0			| UDT
	beqw	Luvp_fail
	andil	&0xffffff00,%d1		| leaf-table base (256-aligned)
	moveal	%d1,%a0

| --- C (leaf) index = (va >> 12) & 0x3F -----------------------------------
	movel	%d2,%d0
	moveq	&12,%d3
	lsrl	%d3,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	movel	%a0@(0,%d0:l),%d0	| d0 = PTE value
	movel	%d0,%d1
	andil	&3,%d1			| PDT
	bnew	Luvp_ret		| resident -> return the PTE
Luvp_fail:
	clrl	%d0
Luvp_ret:
	moveml	%sp@+,%d2-%d3
	moveal	%d0,%a0
	unlk	%fp
	rts

| ===========================================================================
| prfastmapin(p, addr, writing) -- orig 0x63484, GLOBAL T -> --weaken-symbol.
|   arg@8 = p (proc_t *), arg@12 = addr (user VA), arg@16 = writing
| Returns a directly-usable kernel address for addr's page, or NULL to decline (the
| caller, prusrio, then does as_fault(F_SOFTLOCK) + prmapin instead).
| Returned in d0 AND a0 -- prusrio reads a0 (0x645bc `movel %a0,%d2`).
| splhi/splx mirror the stock body (0x63490 `movew %sr,%d3`, 0x63492 `movew #0x2400,%sr`)
| so the walk plus the PAGE_HOLD stay atomic against interrupts.
	.globl	prfastmapin
prfastmapin:
	linkw	%fp,&0
	moveml	%d2-%d4,%sp@-
	movel	%fp@(12),%d2		| d2 = addr
	movew	%sr,%d3			| save IPL
	movew	&0x2400,%sr		| splhi

	movel	%fp@(8),%sp@-		| p
	movel	%d2,%sp@-		| va
	jsr	uvatopte040
	addqw	&8,%sp
	movel	%d0,%d4			| d4 = PTE value (0 = not resident)
	beqw	Lpfi_fail

	tstl	%fp@(16)		| writing?
	beqw	Lpfi_hold
	movel	%d4,%d0
	andil	&4,%d0			| W = write-protected (COW / RO)
	bnew	Lpfi_fail		| decline -> as_fault does the copy-on-write

Lpfi_hold:
| PAGE_HOLD(page_numtopp(pfn)) -- same arithmetic as the stock body: range-check the PFN
| against pages_base..pages_end, then pp = pages + (pfn - pages_base) * 60, keepcnt++
| (p_keepcnt is the WORD at pp+2).
|
| HARDENING vs stock: on an out-of-range PFN stock set pp = NULL (`subal %a0,%a0`
| @0x63546) and then unconditionally executed `addqw #1,%a0@(2)` @0x63568 -- a write to
| absolute address 2, i.e. a bus error for any user mapping whose frame is not managed
| RAM (a device/framebuffer page reached through mmap).  Declining the fast path instead
| is free: prusrio simply takes the as_fault + prmapin route.
	movel	%d4,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0			| d0 = pfn
	cmpl	pages_base,%d0
	bcsw	Lpfi_fail		| pfn < pages_base
	cmpl	pages_end,%d0
	bccw	Lpfi_fail		| pfn >= pages_end
	subl	pages_base,%d0
	moveq	&60,%d1
	mulsl	%d1,%d0			| (pfn - pages_base) * sizeof(page_t)
	moveal	%d0,%a0
	addal	pages,%a0		| a0 = pp
	addqw	&1,%a0@(2)		| pp->p_keepcnt++

	movew	%d3,%sr			| splx
	movel	%d4,%d0
	andil	&0xfffff000,%d0		| physical page base (040 PTE bits 31:12)
	movel	%d2,%d1
	andil	&0xfff,%d1		| PAGOFF(addr) -- 4 KiB, was 0x7ff
	addl	%d1,%d0
	braw	Lpfi_ret

Lpfi_fail:
	movew	%d3,%sr			| splx
	clrl	%d0
Lpfi_ret:
	moveml	%sp@+,%d2-%d4
	moveal	%d0,%a0			| prusrio reads a0
	unlk	%fp
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement:
					| rel.c puts .bss at data_end UNALIGNED)
