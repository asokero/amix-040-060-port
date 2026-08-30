| hat_chgprot040.s -- 040 port of hat_chgprot (orig 0xb4a0a, GLOBAL T).
|
| WHY THIS IS THE COW BLOCKER (2026-06-28):
| segvn_dup (seg_vn.c:540-543) implements fork's copy-on-write by calling
|     hat_chgprot(seg, base, size, ~PROT_WRITE);   (* write-protect the PARENT *)
|     anon_dup(...);                                (* bump each anon's an_refcnt *)
| anon_dup states the CONTRACT explicitly in its own comment (vm_anon.c:284): it assumes the
| caller has ALREADY write-protected, through hat_chgprot, exactly the address range the anon
| array being duplicated refers to.  anon_dup does not do it and does not check that anyone
| has; the whole burden is on the caller.
| The stock 030 hat_chgprot walks the INERT 030 SDE tree (deref as+20 -> 030 SDE,
| index va>>17, 8-byte SDEs) which is empty on 040 -> it is a silent NO-OP.  So the
| parent is never write-protected, the COW invariant is violated, and shared pages
| get freed while a child still maps them (the "ptalloc DOUBLE" / child wild-jump).
|
| 030->040 changes (everything else is VERBATIM 030 logic):
|   * tree walk: 030 SDE (as+20 deref, va>>30&3 region, va>>17&8191 *8) ->
|     040 flat walk root=as@(20): A=va>>25&7f *4, B=va>>18&7f *4, leaf=va>>12&3f *4
|     (identical to hat_unload040's Lhl_leafwalk).
|   * page size: leaf index >>11&63 -> >>12&63 ; step #2048 -> #4096 ;
|     within-leaf advance mask 0x1F800 -> 0x3F000 (64 x 4KB = 256KB per leaf).
|   * PTE bit ops are UNCHANGED -- they already match our 040 PTE status encoding
|     (hat_pteload: RW=status 1 = bit0 set/bit2 clear, RO=status 5 = bit0+bit2):
|       writable  -> andl #-5,*pte  (clear bit2 = clear write-protect)
|       no-access -> andl #-2,*pte  (clear bit0 = clear resident)
|       read-only -> orl  #4,*pte   (set   bit2 = set write-protect)
|   * add cpusha bc + pflusha after the walk (push the modified PTEs to RAM and
|     flush the ATC so the 040 hardware table-walker reloads the new descriptors --
|     same coherency fix hat_pteload/resume040 already apply).
|
| hat_chgprot GLOBAL T -> --weaken-symbol so this strong def wins.  Args:
| fp@8=seg, fp@12=addr, fp@16=len, fp@20=prot.  Returns void.  SVR4 gas syntax.

	.text
	.globl	hat_chgprot
hat_chgprot:
	linkw	%fp,&0
	moveml	%d2-%d5/%a2-%a4,%sp@-
	moveal	%fp@(8),%a0
	moveal	%a0@(12),%a0		| as = seg->s_as
	moveal	%a0@(20),%a4		| a4 = 040 root VA (as@(20), stored by hat_alloc)
| V2.2 guard: after hat_free the root is freed and as@(20)==0 (hat_free040 clears it);
| post-free hat ops must be no-ops (stock semantics) -- walk from 0 would read low RAM.
	movel	%a4,%d0
	beqw	Lcp_done
	movel	%fp@(12),%d2		| d2 = va (running cursor)
	movel	%d2,%d3
	addl	%fp@(16),%d3
	subql	&1,%d3			| d3 = va + len - 1 (inclusive last byte)
	moveq	&7,%d0
	andl	%d0,%fp@(20)		| prot &= 7
| --- one-shot ENTER marker: proves hat_chgprot now runs (fork COW write-protect) ---
	tstl	kdbg_on			| base is SILENT; dbg flips this (kdbg040.s)
	beqw	Lcp_nodbg
	movel	Lcp_n,%d0
	bnew	Lcp_nodbg
	moveq	&1,%d0
	movel	%d0,Lcp_n
	movel	%fp@(20),%sp@-		| prot
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| seg
	pea	Lcp_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lcp_nodbg:
| --- select PTE op mode: 0=writable(clr b2), 1=no-access(clr b0), 2=read-only(set b2) ---
	moveq	&2,%d0
	andl	%fp@(20),%d0
	tstl	%d0
	bnew	Lcp_mw			| prot & PROT_WRITE -> writable
	tstl	%fp@(20)
	bnew	Lcp_mro			| prot != 0 (and no write) -> read-only
	moveq	&1,%d4			| prot == 0 -> no access
	braw	Lcp_chkmore
Lcp_mw:
	moveq	&0,%d4			| writable
	braw	Lcp_chkmore
Lcp_mro:
	moveq	&2,%d4			| read-only

Lcp_chkmore:
	cmpl	%d2,%d3
	bccw	Lcp_walk		| d3 >= va -> more to do
	braw	Lcp_done

Lcp_walk:
| A index = (va>>25)&0x7f ; Adesc = root[A*4]
	movel	%d2,%d0
	moveq	&25,%d5
	lsrl	%d5,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a4@(0,%d0:l),%d0	| Adesc
	movel	%d0,%d1
	andil	&3,%d1			| UDT
	bnew	Lcp_aok
Lcp_nextA:
	movel	%d2,%d0			| A absent/garbage -> next 32MB (2^25) boundary
	andil	&0xfe000000,%d0
	addil	&0x2000000,%d0
	movel	%d0,%d2
	braw	Lcp_chkmore
Lcp_aok:
	andil	&0xfffffe00,%d0		| Btable = Adesc & ~0x1ff
| V2.2 guard (boot-verified crash pc=0xD84C0, pid sac at LOGIN stage): garbage descriptors
| with UDT bits set (the FFFFFFFF fill relics from unported hat_exec/hat_growsdt 030 writes)
| pass the UDT check and deref an unbacked base (FFFFFE00) -> KERNEL FAULT.  Validate the
| table base is a managed RAM frame ([pages_base,pages_end)) -- same test as hat_free040's
| Lf_badleaf -- and treat a bad slot as ABSENT (skip the region; prot change on a garbage
| region is meaningless).
	movel	%d0,%d1
	moveq	&12,%d5
	lsrl	%d5,%d1
	cmpl	pages_base,%d1
	bcsw	Lcp_nextA
	cmpl	pages_end,%d1
	bccw	Lcp_nextA
	movel	%d2,%d1
	moveq	&18,%d5
	lsrl	%d5,%d1
	andil	&0x7f,%d1
	asll	&2,%d1
	addl	%d1,%d0			| &Bdesc
	moveal	%d0,%a3
	movel	%a3@,%d1		| Bdesc
	movel	%d1,%d0
	andil	&3,%d0			| UDT
	bnew	Lcp_bok
Lcp_nextB:
	movel	%d2,%d0			| B absent/garbage -> next 256KB (2^18) boundary
	andil	&0xfffc0000,%d0
	addil	&0x40000,%d0
	movel	%d0,%d2
	braw	Lcp_chkmore
Lcp_bok:
	andil	&0xffffff00,%d1		| leaf base = Bdesc & ~0xff
| same guard for the leaf base (garbage Bdesc FFFFFFFF -> FFFFFF00 deref)
	movel	%d1,%d0
	moveq	&12,%d5
	lsrl	%d5,%d0
	cmpl	pages_base,%d0
	bcsw	Lcp_nextB
	cmpl	pages_end,%d0
	bccw	Lcp_nextB
	moveal	%d1,%a3			| a3 = leaf base

Lcp_pte:
	movel	%d2,%d0			| P index = (va>>12)&0x3f
	moveq	&12,%d5
	lsrl	%d5,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	moveal	%a3,%a2
	addal	%d0,%a2			| a2 = &leaf PTE
	tstl	%a2@
	beqw	Lcp_adv			| empty PTE -> no change, just advance
	tstl	%d4
	bnew	Lcp_op1
	moveq	&-5,%d1			| mode 0 writable: clear bit2 (write-protect off)
	andl	%d1,%a2@
	braw	Lcp_adv
Lcp_op1:
	cmpil	&1,%d4
	bnew	Lcp_op2
	moveq	&-2,%d1			| mode 1 no-access: clear bit0 (resident off)
	andl	%d1,%a2@
	braw	Lcp_adv
Lcp_op2:
	moveq	&4,%d1			| mode 2 read-only: set bit2 (write-protect on)
	orl	%d1,%a2@
Lcp_adv:
	pea	1
	movel	%d2,%sp@-
	jsr	flushmmu		| flushmmu(va, 1)
	addqw	&8,%sp
	addil	&4096,%d2		| va += 4KB
	movel	%d2,%d0
	andil	&0x3f000,%d0		| within-leaf page index bits (12..17)
	tstl	%d0
	beqw	Lcp_chkmore		| crossed 256KB leaf boundary -> re-walk tree
	cmpl	%d2,%d3
	bccw	Lcp_pte			| d3 >= va -> more PTEs in this leaf
	braw	Lcp_done

Lcp_done:
	.word	0xf4f8			| cpusha bc -- push the modified leaf PTEs to RAM
	.word	0xf518			| pflusha   -- flush the ATC so the next walk reloads
	moveml	%sp@+,%d2-%d5/%a2-%a4
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lcp_msg:
	.asciz	"DBG hat_chgprot040 ENTER seg=%x addr=%x len=%x prot=%x (fork COW WP)"
	.even
Lcp_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
