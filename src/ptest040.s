| ptest040.s -- 68040 port of the kernel's `ptest` (the GOT-relocation / COW-fault fix).
|
| The stock `ptest` (0x3a8) is the 030 `ptestr #1,(a0),7` + `pmove psr` sequence: it returns the
| 030 MMU status (PSR) for a user (FC=1) logical address.  On the 68040 those are illegal F-line
| instructions, so patch_pmmu_040.py STUBS ptest to a constant 0x400 (030 bit10 = I = invalid).
| That constant makes usrxmemflt's classifier (`andil #0x4400` @5afb2) ALWAYS take the F_INVAL
| demand path -- so a write to libc.so.1's read-only GOT page is treated as "not present" and
| demand-re-read instead of copied-on-write (F_PROT).  do_reloc's relocation store is then lost,
| the GOT stays raw, and the dynamic linker jsr's a raw GOT slot and _exit(0)s before init runs.
|
| This is a REAL 040 ptest: it runs the genuine 040 `ptestr` and reads MMUSR, then TRANSLATES the
| 040 status to the 030-form PSR that the rest of usrxmemflt (and krnxmemflt) already understand:
|   040 MMUSR (cpummu.h): R=bit0 resident, W=bit2 write-protected, B=bit11 bus error/invalid.
|   030-form PSR wanted:  I=bit10(0x400) invalid, W=bit11(0x800) write-protected, B=bit15(0x8000).
| Mapping:
|   R==0            -> 0x400 (030 I)  -> usrxmemflt F_INVAL demand path (faults the page in)
|   R==1 && W==1    -> 0x800 (030 W)  -> usrxmemflt F_PROT / COW path (copies the page writable)
|   R==1 && W==0    -> 0              -> present & writable (no fault bits; shouldn't have faulted)
| We deliberately map "not present" to 030 I (demand) not 030 B (which would SIGSEGV).
|
| 040 function code: the 68040 PTEST takes its FC from the DFC register (verified in fs-uae
| cpummu.cpp mmu_op_real: super=dfc&4, data=(dfc&3)!=2).  We set DFC (and SFC, harmless) = 1
| (user data), matching the stock ptest's hardcoded FC=1.  During a user fault URP already points
| at the faulting process, so ptestr tests exactly the page we care about.  DFC/SFC are caller-
| set-as-needed in this kernel (wb040.s sets DFC before its replay moves), so clobbering is safe.
|
| The assembler does not know the 040 PMMU mnemonics, so ptestr / movec MMUSR are emitted as .word
| (same technique as wb040.s's pflusha).  Wired via relink-040.sh: --weaken-symbol ptest (it is a
| GLOBAL 'T' symbol -> a plain weaken lets this strong def win for every caller).
|
| 2026-07-10 (060-B): the 68060 REMOVED PTEST and MMUSR entirely (it only has PLPA, which
| yields a physical address but no protection bits).  When cputype==60 (loader-poked global,
| see cputype060.s) this routine instead walks the live URP tree in SOFTWARE and fabricates
| the same 030-form PSR.  The walk mirrors what the 040 hardware table walker does for an
| FC=1 (user data) access: URP -> root descriptor (RI = VA[31:25]) -> pointer descriptor
| (PI = VA[24:18]) -> page descriptor (PGI = VA[17:12]), 4KB pages.  Table entries hold
| PHYSICAL addresses; kernel phys RAM is < 0x40000000 = identity-mapped through DTT0, so
| plain loads read them (the same trick segu_ubptbl040.s uses to walk the kptr040 tree).
| Descriptor validity: upper levels UDT bit1 (x0=invalid); leaf PDT bits1-0 (00=invalid,
| 10=indirect -> follow one level, indirect-to-indirect = invalid per the 040/060 UM).
| W = descriptor bit2 -> 030 W (0x800, the COW path); resident+writable -> 0; else 0x400.
| The 040 path below is byte-for-byte the proven original -- cputype==40 never reaches the walk.

	.text
	.globl	ptest
ptest:
	movel	cputype,%d0
	cmpil	&60,%d0
	beqw	Lpt_060				| 68060: no PTEST -> software URP walk below
	moveq	&1,%d0
	movec	%d0,%dfc			| FC = 1 (user data) -- 040 PTEST reads DFC
	movec	%d0,%sfc			| harmless; in case of DFC/SFC ambiguity on real HW
	moveal	%sp@(4),%a0			| a0 = fault VA (the one arg)
	.word	0xf568				| ptestr (%a0)  -- walk current URP, fill MMUSR
	.word	0x4e7a,0x0805			| movec %mmusr,%d0
	moveq	&0,%d1
	btst	&0,%d0				| R (resident / present)?
	beqw	Lpt_np				|   R==0 -> not present
	btst	&2,%d0				| W (write-protected)?
	beqw	Lpt_ret				|   R==1 && W==0 -> present+writable -> 030 = 0
	movew	&0x0800,%d1			|   R==1 && W==1 -> 030 W (write-protect) -> COW
	braw	Lpt_ret
Lpt_np:
	moveq	&0,%d1				| clear the WHOLE reg: the 060 walk enters here
						| with d1 = VA (movew alone would leave VA bits
						| 31-16 in the returned PSR)
	movew	&0x0400,%d1			| 030 I (invalid / not present) -> F_INVAL demand
Lpt_ret:
	movel	%d1,%d0				| return 030-form PSR in d0 (stock calling convention)
	rts

| ---- 68060 software table walk (d0/d1/a0/a1 are scratch in this ABI) ----
Lpt_060:
	moveal	%sp@(4),%a0			| a0 = fault VA (mirror the 040/stock path's a0)
	movel	%a0,%d1				| d1 = fault VA
	.word	0x4e7a,0x0806			| movec %urp,%d0  -- active user root (phys, identity)
	moveal	%d0,%a1
	movel	%d1,%d0				| root index RI = VA[31:25]
	swap	%d0
	andil	&0xffff,%d0			| d0 = VA>>16
	lsrl	&8,%d0
	lsrl	&1,%d0				| d0 = VA>>25  (0..127)
	lsll	&2,%d0				| *4 (descriptor = 4 bytes)
	addal	%d0,%a1
	movel	%a1@,%d0			| root descriptor
	btst	&1,%d0				| UDT resident?
	beqw	Lpt_np				|   invalid -> 030 I (demand path)
	andil	&0xfffffe00,%d0			| pointer-table base (512-byte aligned)
	bsrw	Lpt_inram			| ISSUE-59: is that a managed RAM frame?
	tstl	%d1
	beqw	Lpt_np				|   no -> report invalid, do NOT dereference
	movel	%a0,%d1				| the check clobbered d1; a0 still holds the VA
	moveal	%d0,%a1
	movel	%d1,%d0				| pointer index PI = VA[24:18]
	swap	%d0
	andil	&0xffff,%d0			| d0 = VA>>16
	lsrl	&2,%d0				| d0 = VA>>18
	andil	&0x7f,%d0
	lsll	&2,%d0
	addal	%d0,%a1
	movel	%a1@,%d0			| pointer descriptor
	btst	&1,%d0				| UDT resident?
	beqw	Lpt_np
	andil	&0xffffff00,%d0			| page-table base (256-byte aligned)
	bsrw	Lpt_inram			| ISSUE-59: THE one that faulted -- a descriptor
	tstl	%d1				| of 0xFFFFFFFF passes the UDT test above and
	beqw	Lpt_np				| masks to 0xFFFFFF00, which is not RAM
	movel	%a0,%d1				| the check clobbered d1; a0 still holds the VA
	moveal	%d0,%a1
	movel	%d1,%d0				| page index PGI = VA[17:12]
	lsrl	&8,%d0
	lsrl	&4,%d0				| d0 = VA>>12
	andil	&0x3f,%d0
	lsll	&2,%d0
	addal	%d0,%a1
	movel	%a1@,%d0			| page descriptor (PTE)
	moveq	&3,%d1
	andl	%d0,%d1				| PDT field
	beqw	Lpt_np				| 00 = invalid -> 030 I
	cmpib	&2,%d1
	bnew	Lpt_pte				| 01/11 = resident
	andil	&0xfffffffc,%d0			| 10 = indirect: follow the pointer (long-aligned)
	bsrw	Lpt_inram			| ISSUE-59: same guard before the indirect read
	tstl	%d1
	beqw	Lpt_np
	moveal	%d0,%a1
	movel	%a1@,%d0
	moveq	&3,%d1
	andl	%d0,%d1
	beqw	Lpt_np
	cmpib	&2,%d1
	beqw	Lpt_np				| indirect-to-indirect = invalid (040/060 UM)
Lpt_pte:
	moveq	&0,%d1
	btst	&2,%d0				| W (write-protected)?
	beqw	Lpt_ret				|   resident+writable -> 0 (no fault bits)
	movew	&0x0800,%d1			|   write-protected -> 030 W (COW path)
	braw	Lpt_ret
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

| --- ISSUE-59 (2026-09-01): is a descriptor-derived physical address inside managed RAM? ---
|
| The 68060 walk masks a table base out of a descriptor and dereferences it.  A garbage
| descriptor with the UDT bits set -- 0xFFFFFFFF is the one that was captured -- passes the
| resident test and masks to an address that is not memory, and the read takes a kernel bus
| error inside the fault path.  Reported from a Doom timedemo on 68060-260831-01:
|     WARNING: DBG krnxflt FAILEXIT w=2 va=FFFFFF00 rw=1 depth=1
|     PANIC: KERNEL FAULT ... pc=0x80D9EF4  (= object 0x000D9EF4, the page-table read)
|
| The same test already guards hat_chgprot040.s and hat_free040.s; it was missing here.  A
| frame outside [pages_base, pages_end) means the descriptor is not describing memory this
| kernel manages, so the walk reports 030-form 0x0400 (invalid / not present) and the demand
| path deals with it -- exactly what it does for a descriptor whose UDT bits are clear.
|
| in:   d0 = physical address, preserved
| out:  d1 = 0 if the frame is OUTSIDE managed RAM, nonzero if inside
| a0 is untouched, so the caller reloads the fault VA from it after calling.
| Shifts are two immediates because the caller's contract leaves only d0/d1 scratch and
| `lsrl &n` takes n = 1..8 -- the same idiom the walk above already uses for VA>>12.
Lpt_inram:
	movel	%d0,%d1
	lsrl	&8,%d1
	lsrl	&4,%d1				| frame = addr >> 12
	cmpl	pages_base,%d1
	bcss	Lpt_inram_no
	cmpl	pages_end,%d1
	bccs	Lpt_inram_no
	moveq	&1,%d1
	rts
Lpt_inram_no:
	moveq	&0,%d1
	rts
	.balign	4
