| resume040.s -- 68040 context-switch resume port (the u-area remap).
|
| ROOT CAUSE (2026-06-22): the 030 resume repoints the u-area (fixed VA u=0x40000000) at the
| new proc's u-area page table by writing *ublksde (= &st_top1[0].word2, the 030 SDE pointer
| half).  On 040 st_top1 is INERT (the live tree is kptr040), so the write is a no-op -> u never
| remaps -> resume restores proc 0's own context -> swtch returns without transferring.
|
| 040 FIX: the u-area's pointer descriptor is kptr040[0] (u>>25=32=root, (u>>18)-4096=0) -> a
| FIXED 256-byte-aligned leaf table `uarea_pt` (built by pstart040 as uarea_pt|UDT).  We cannot
| repoint kptr040[0] at the per-proc PTE copy (proc+0x50 is not 256-aligned, an 040 constraint),
| so resume COPIES the new proc's 2 u-area leaf PTEs into uarea_pt[0],[1] and pflushes.  swtch
| sets curproc=newproc BEFORE jsr resume, and segu_get stores the u-area VA at proc@(252); so
| resume reads u_va=curproc@(252), walks kptr040 for u_va and u_va+0x1000 (vatosde/vatopte
| inline), and writes the 2 leaf PTEs into uarea_pt (found as kptr040[0] & ~0xFF).  No swtch/
| segu_get/ublksde change needed.  u_va==0 -> skip remap (proc 0 / early boot).
|
| resume GLOBAL T -> --weaken-symbol.  globals used: curproc (C), kptr040 (D, pstart040 export).
| The kptr040 walk is INLINE (no bsr/jmp to relinked code -- see memory [[040-detour-jmp-crashes]]).

	.text
	.globl	resume
resume:
	moveal	%sp@(4),%a0		| a0 = arg1 = u+0x318 restore buffer -- KEEP for the moveml
	movew	%sr,%d0			| d0 = sr (preserved to the end)
	movew	&0x2700,%sr		| mask interrupts during the remap
	moveal	curproc,%a1
	movel	%a1@(252),%d1		| d1 = u_va = the new proc's u-area kvsegu VA
	beqw	Lr_rest			| u_va==0 -> skip remap (proc 0 / early boot)
	moveal	kptr040,%a1
	movel	%a1@,%d2
	andil	&0xffffff00,%d2		| d2 = uarea_pt base = kptr040[0] & ~0xFF
	moveal	%d2,%a2			| a2 = uarea_pt (the fixed 256-aligned u-area leaf table)
|	--- page 0: walk kptr040 for u_va -> leaf PTE -> uarea_pt[0] ---
	movel	%d1,%d4
	moveq	&18,%d5
	lsrl	%d5,%d4			| u_va>>18
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4		| &kptr040 pointer descriptor (vatosde)
	moveal	%d4,%a3
	movel	%a3@,%d4		| *sde = leaf | UDT
	andil	&0xffffff00,%d4		| leaf table base
	movel	%d1,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5			| u_va>>12
	andil	&0x3f,%d5
	asll	&2,%d5			| (u_va>>12 & 0x3f)*4
	addl	%d5,%d4			| &leaf PTE (vatopte)
	moveal	%d4,%a3
	movel	%a3@,%a2@		| uarea_pt[0] = *PTE
|	--- page 1: walk kptr040 for u_va+0x1000 -> uarea_pt[1] ---
	movel	%d1,%d3
	addil	&0x1000,%d3
	movel	%d3,%d4
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4
	movel	%d3,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@(4)		| uarea_pt[1] = *PTE
Lr_rest:
	.word	0xf4f8			| cpusha bc (68040) -- push the uarea_pt descriptor writes
					|   out of the copyback D-cache to RAM BEFORE the MMU
					|   tablewalk reads them (else a stale descriptor -> wrong
					|   u-area page -> moveml reads garbage -> jmp wild).
	.word	0xf518			| pflusha (68040) -- then invalidate the ATC
	moveml	%a0@,%d2-%d7/%a1-%sp	| restore the new proc's context (a0 = u+0x318)
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@
	nop				| pad .text to a 4-byte multiple
