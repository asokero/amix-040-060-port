| segkmem040.s -- CM-campaign B1 group: the direct linear-kptbl segkmem writers +
| the global flushmmu descriptor-publication lever (2026-07-20).
|
| Spec: analyysirepo amix-kernel-analysis/vm-map/CM-PTE-WRITER-MATRIX.md
| ("Direct segkmem blocker", "Census closure", "B1 implementation group" items
| 5-6) against kernel 4aad0a9 / build/unix-040 sha256 bc5a43e6...  Companion
| byte patches (segkmem_checkprot/segkmem_getprot READERS, same 2 KiB geometry
| family) live in patch_segkmem.py -- the whole family is ONE unit; do not ship
| a build with only part of it (the spec's explicit rejection rule).
|
| Overrides here (all verbatim transcriptions of the stock bodies, disasm from
| the linked image, with only the documented deltas):
|
|   flushmmu        (stock 0xb78c4, GLOBAL T; body was pflusha ONLY)
|                   + cpusha dc before the pflusha.  Every bare-flushmmu caller
|                   (segkmem_alloc/free/mapin/mapout per-page loops, hat_pteload,
|                   hat_unload...) thereby gets descriptor PUBLICATION, closing
|                   the "only bare flushmmu where present" census gap in one
|                   choke point.  dc (not bc): descriptor publication needs the
|                   DATA cache only -- bc would invalidate the now-enabled IC on
|                   every call (perf) AND would change the IC-coherency posture
|                   the HW-accepted Step-A build was validated with.  No-op while
|                   DC is off (B1 dormant scaffolding, exercisable on emu).
|
|   segkmem_setprot (stock 0xa8442, file-LOCAL t; vtable slot segkmem_ops+0x18
|                   binds by SYMBOL -> globalize+weaken override works, same
|                   mechanism as sysseginit).  Stock body was still Model A:
|                   PTE index (addr-s_base)>>11, page step +0x800 -- writing the
|                   WRONG live PTE for any odd 4 KiB page (B1 blocker, latent
|                   live bug regardless of caches).  Deltas vs stock:
|                     * index shift 11 -> 12, step 0x800 -> 0x1000 (Model B);
|                     * FIX a stock defect: the prot!=0 path never advanced the
|                       PTE cursor (clrl %a2@+ vs bfins with no increment) --
|                       every iteration rewrote PTE[0]'s W bit.  Both paths now
|                       share one +4 step.  (3b2 reference walks pte++ per page.)
|                     * CM preservation is inherent: the bfins touches only the
|                       W bit (byte 3 bit-offset 5 = 0x04); the clear path
|                       invalidates outright.  No CM choice is made here.
|                     * publication tail (cpusha dc + pflusha): stock had NO
|                       flush at all -- a W-bit tightening could keep writing
|                       through a stale ATC entry.
|
|   sptfree         (stock 0xa8c6c, GLOBAL T).  The flag=0 path clears linear
|                   kptbl PTEs directly with NO cache/ATC operation at all
|                   (census: the only writer with zero publication) and then
|                   rmfree's the VA range for reuse.  Delta vs stock: cpusha dc
|                   + pflusha between the clear loop and the rmfree tail.
|                   Geometry was already Model B (patch_modelb).  The flag!=0
|                   path goes through segkmem_mapout -> flushmmu (covered by the
|                   flushmmu override above).
|
| NOTE (B1 scope, documented -- not an oversight): segkmem_alloc / segkmem_mapin
| leaf CONSTRUCTORS keep building CM=00 writethrough PTEs, which IS the B1
| managed-RAM target; their B2 stage-class (CB) conversion and the mapin
| unmanaged->NCS classification belong to the B2 delta / segdev-MMIO group
| (roadmap: "segdev-toteutusryhmaan ... segkmem_mapin-MMIO").
|
| Assemble:  m68k-cbm-sysv4-gcc -m68040 -c segkmem040.s -o build/segkmem040.o
| Externals: hat_vtokp_prot, cmn_err, kptbl, syssegs, sptmap, kvseg,
|            segkmem_mapout, rmfree.
| 040 privileged ops as .word: cpusha dc = 0xf478, pflusha = 0xf518.

	.text

| ============================================================================
| flushmmu(va, cnt) -- stock args are read then ignored (kept verbatim so the
| register/return behaviour is byte-equivalent to stock: d0=va, d1=cnt, a0=d0).
| ============================================================================
	.globl	flushmmu
flushmmu:
	linkw	%fp,&0
	movel	%fp@(8),%d0
	movel	%fp@(12),%d1
	.word	0xf478			| cpusha dc -- publish descriptor stores (CM-B1; no-op DC-off)
	.word	0xf518			| pflusha   (the entire stock body)
	nop
	moveal	%d0,%a0
	unlk	%fp
	rts

| ============================================================================
| segkmem_setprot(seg, addr, len, prot) -- Model B port, see header.
| Frame/register discipline identical to stock (linkw #0, d2-d4/a2-a3).
| ============================================================================
	.globl	segkmem_setprot
segkmem_setprot:
	linkw	%fp,&0
	moveml	%d2-%d4/%a2-%a3,%sp@-
	moveal	%fp@(8),%a3		| a3 = seg
	movel	%fp@(12),%d2		| d2 = addr
	movel	%fp@(20),%d3		| d3 = prot
	beqw	Lsp_ptbl
	movel	%d3,%sp@-
	jsr	hat_vtokp_prot		| d0 = W-bit value for this prot
	movel	%d0,%d4
	addqw	&4,%sp
Lsp_ptbl:
	tstl	%a3@(28)		| seg->s_ptbl (kptbl slice)
	beqw	Lsp_panic
	movel	%d2,%d0
	subl	%a3@(4),%d0		| addr - s_base
	moveq	&12,%d1			| Model B 4 KiB PTE index  [stock: moveq #11]
	lsrl	%d1,%d0
	asll	&2,%d0
	moveal	%a3@(28),%a2
	addal	%d0,%a2			| a2 = &PTE
	braw	Lsp_bound
Lsp_panic:
	pea	Lsp_msg
	pea	3
	jsr	cmn_err			| panic -- never returns (stock semantics)
Lsp_bound:
	movel	%d2,%d0
	addl	%fp@(16),%d0		| d0 = end = addr + len
	cmpl	%d2,%d0
	blsw	Lsp_out			| empty range -> nothing written, no flush
Lsp_loop:
	tstl	%d3
	bnew	Lsp_wbit
	clrl	%a2@			| prot==0: invalidate the PTE
	braw	Lsp_step
Lsp_wbit:
	bfins	%d4,%a2@(3){&5:&1}	| write ONLY the W bit; CM/U/M/PDT preserved
Lsp_step:
	addqw	&4,%a2			| FIX: stock prot!=0 path never advanced the cursor
	addil	&4096,%d2		| Model B 4 KiB step  [stock: +0x800]
	cmpl	%d2,%d0
	bhiw	Lsp_loop
	.word	0xf478			| cpusha dc -- publish the PTE stores (stock: no flush)
	.word	0xf518			| pflusha   -- no stale W/valid translation survives
Lsp_out:
	clrl	%d0
	moveml	%fp@(-20),%d2-%d4/%a2-%a3
	moveal	%d0,%a0
	unlk	%fp
	rts

| ============================================================================
| sptfree(va, npages, flag) -- verbatim stock transcription + the flag=0
| teardown publication.  flag!=0 -> segkmem_mapout (bookkeeping teardown);
| flag=0 -> direct linear kptbl clear (ghost-mapping teardown).
| ============================================================================
	.globl	sptfree
sptfree:
	linkw	%fp,&0
	moveml	%d2-%d5,%sp@-
	movel	%fp@(8),%d0		| d0 = va
	movel	%fp@(12),%d3		| d3 = npages
	movel	%d0,%d2
	addil	&4095,%d2
	moveq	&12,%d4
	lsrl	%d4,%d2			| d2 = base page number (round va up)
	tstl	%fp@(16)		| flag?
	beqw	Lsf_direct
	movel	%d3,%d5
	asll	%d4,%d5			| len = npages << 12
	movel	%d5,%sp@-
	movel	%d0,%sp@-
	pea	kvseg
	jsr	segkmem_mapout		| -> flushmmu (publication via the override above)
	addaw	&12,%sp
	braw	Lsf_rm
Lsf_direct:
	clrl	%d1
	cmpl	%d1,%d3
	blew	Lsf_rm			| npages <= 0 -> nothing to clear
	moveal	kptbl,%a0		| linear kernel page table (hoisted, as stock)
Lsf_loop:
	movel	%d2,%d0
	addl	%d1,%d0
	moveq	&12,%d4
	asll	%d4,%d0
	subil	&syssegs,%d0
	lsrl	%d4,%d0
	andil	&0x7ffff,%d0		| kptbl index
	clrl	%a0@(0,%d0:l:4)		| kptbl[idx] = 0 (live 040 leaf invalidated)
	addql	&1,%d1
	cmpl	%d1,%d3
	bgtw	Lsf_loop
| CM-B1: full teardown publication BEFORE rmfree makes the VA range reusable
| (matrix sptfree(flag=0) row: "No current cache/ATC operation").
	.word	0xf478			| cpusha dc -- push the PTE clears to RAM
	.word	0xf518			| pflusha   -- drop stale translations of the freed range
Lsf_rm:
	movel	%d2,%sp@-
	movel	%d3,%sp@-
	pea	sptmap
	jsr	rmfree			| rmfree(&sptmap, npages, basepage)
	moveml	%fp@(-16),%d2-%d5
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.balign 4			| pad section (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lsp_msg:
	.asciz	"segkmem_setprot: invalid segment"
	.balign 4			| pad section to a 4-byte multiple
