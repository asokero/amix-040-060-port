| uvatosde040.s -- 68040 port of the per-process user software page-table walker.
|
| Phase 4 (user-VM SW walkers), 2026-06-26.  The stock uvatosde (0xb74f8) walks the
| INERT 030 segment tree (curproc->p_as->region_array[VA region]->st_top[VA seg]) which
| is DEAD on 040 -- the live tree is the per-proc 040 root040 (as@(20), built by
| hat_alloc, filled by hat_pteload).  On 040 the linker calls usrxmemflt for init's
| write-protect (COW) fault; usrxmemflt's F_PROT path calls uvatosde then walks an INLINE
| 030 leaf (`SDE@(4) + (va>>11&0x3F)*4`) and bus-errors at 0x5b088 (garbage SDE + 2KB leaf).
|
| 030->040 CHANGE OF CONTRACT: stock uvatosde returns the address of the 8-byte SEGMENT
| descriptor (caller then does its own +4 leaf walk).  This 040 version does the FULL
| per-proc walk and returns the address of the LEAF PTE directly (a0).  usrxmemflt's two
| inline 030 leaf walks are byte-patched (patch_modelb.py) to `moveal %a0,%a2` + nops so
| they consume this &PTE directly.  (uvirtophys -- the other uvatosde caller, NOT on init's
| path -- still calls stock-style and is left for a later port; documented in RESUME-HERE.)
|
| The 040 walk mirrors hat_pteload (hat040.s): root040[va>>25 & 0x7F] (4-byte pointer desc,
| base = desc & 0xFFFFFE00) -> pointer-table[va>>18 & 0x7F] (4-byte, base = desc & 0xFFFFFF00)
| -> leaf[va>>12 & 0x3F] = &PTE.  The page tables come from the identity-mapped SDT pool, so
| a descriptor's value IS a readable VA (phys == va) for the next level -- same assumption
| hat_pteload relies on.  proc/as navigation (curproc -> p_as@(124) -> root@(20)) is
| format-agnostic and copied verbatim from the 030 original.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c uvatosde040.s -o build/uvatosde040.o
| Wire:     --weaken-symbol uvatosde (relink-040.sh); globals: curproc (C).
| ============================================================================

	.globl	uvatosde
uvatosde:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(8),%d2		| d2 = fault VA
	moveal	curproc,%a0		| a0 = curproc
	moveal	%a0@(124),%a0		| a0 = p_as            [030: same offset]
	moveal	%a0@(20),%a0		| a0 = root040 base VA [030 field repurposed by hat_alloc]

| --- A (root) index = (va>>25) & 0x7F ; read root[A] (4-byte pointer descriptor) ---
	movel	%d2,%d0
	moveq	&25,%d3
	lsrl	%d3,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a0@(0,%d0:l),%d1	| d1 = Adesc
	andil	&0xfffffe00,%d1		| d1 = pointer-table base (512B-aligned)
	moveal	%d1,%a0

| --- B (pointer) index = (va>>18) & 0x7F ; read ptr[B] (4-byte, -> leaf base) ---
	movel	%d2,%d0
	moveq	&18,%d3
	lsrl	%d3,%d0
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a0@(0,%d0:l),%d1	| d1 = Bdesc
	andil	&0xffffff00,%d1		| d1 = leaf-table base (256B-aligned)

| --- C (leaf) index = (va>>12) & 0x3F ; &PTE = leaf_base + C*4 ---
	movel	%d2,%d0
	moveq	&12,%d3
	lsrl	%d3,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	addl	%d0,%d1			| d1 = &PTE
	moveal	%d1,%a0			| return &PTE in a0

	moveml	%sp@+,%d2-%d3
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple
