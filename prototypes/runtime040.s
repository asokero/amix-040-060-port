| runtime040.s -- load-bearing 040/060 runtime overrides PROMOTED INTO THE BASE LINK
| (2026-07-12).  Formerly these lived only in the quiet/dbg overlays (quiet040.s /
| mainmarks.s), which made bare build/unix-040 a NON-bootable intermediate while its
| build script claimed "ready to boot" -- the packaging hazard flagged by the Codex
| PROCESS-MMU-CONTEXT-SWITCH-CONTRACT.md + 040-FAULT-RESOLVER-AUDIT.md audits:
|   * stock resume writes the new u-block table into the retired 030 `ublksde`
|     structure, which is INERT on the 040 tree -> fixed-u (0x40000000) never remaps
|     -> the deferred segu_release(zombie) frees u-pages the fixed alias still maps.
|   * stock hardbus returns 0 for a crossing read/ifetch whose first page is resident
|     -> the CPU retries the same instruction forever (the old `date` hang).
| Overlay layering after this promotion:
|   base  unix-040       = THIS file (strong defs) -- self-contained, bootable
|   quiet unix-040-quiet = base + serdbg.s conputc serial mirror only
|   dbg   unix-040-dbg   = base with these re-weakened; mainmarks.s/sigkill_dbg.s
|                          overlay the instrumented twins (markers + probes)
| Keep this file and mainmarks.s IN SYNC: dbg minus markers must equal this file.
|
| NOTE (deliberate disable, not a fix): sched below DISABLES the SVR4 process
| swapper (whole-process u-area swap-out is still unvalidated on 040).
| schedpaging's rts-override was RETIRED 2026-07-15: the pageout/writeback group
| is now Model-B-converted (patch_writeback.py incl. the pageoutd sites in
| setupclock/pageout), so the stock schedpaging tuning + pageout daemon run again
| and page reclaim works under memory pressure.

	.text
| ---------------------------------------------------------------------------
| sched OVERRIDE -- proc-0 swapper loop: keep dispatching, never swap.  A one-shot
| `jsr swtch; spin` deadlocks init the moment proc 1 yields; the loop lets swtch hand
| the CPU back to proc 1 (or idle) each time.  --weaken-symbol sched.
	.globl	sched
sched:
	linkw	%fp,&0
Lrt_sch:
	jsr	swtch
	braw	Lrt_sch
	nop

| ---------------------------------------------------------------------------
| idle OVERRIDE -- stock idle wait.  --weaken-symbol idle.
	.globl	idle
idle:
	stop	&0x2000
	rts

| ---------------------------------------------------------------------------
| hardbus PAGE-CROSSING FIX -- GENUINE fix (origin: sigkill_dbg.s, minus logging).
| A multi-word instruction whose extension words cross into a not-yet-resident page
| makes the 040 report FA = the crossing access's START (the mapped page); the
| 030-semantic usrxmemflt tail misroutes the fault to hardbus, which finds the phys
| OK, returns 0, the CPU retries -> infinite loop (the `date` hang).  For USER
| addresses within 8 bytes of a page end: as_fault BOTH the operand's page AND the
| next page (read, F_INVAL); either resolving -> return 0 and retry.  Both fail ->
| genuine hardbus.
| --weaken-symbol hardbus + --add-symbol hardbus_orig=.text:0x5b3c2.
	.globl	hardbus
hardbus:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(8),%d0		| addr
	cmpil	&0x80000000,%d0
	bcsw	Lrt_hbnorm		| kernel/low address -> normal hardbus
	movel	%d0,%d1
	andil	&0xfff,%d1
	cmpil	&0xff8,%d1
	bcsw	Lrt_hbnorm		| not within 8 bytes of page end -> normal hardbus
	andil	&0xfffff000,%d0
	movel	%d0,%d3			| d3 = current page base
| -- resolve the CURRENT page (usually already valid -> cheap no-op) --
	pea	1			| rw = read
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d3,%sp@-
	moveal	u+0x730,%a0
	movel	%a0@(124),%sp@-		| as = curproc->p_as
	jsr	as_fault
	lea	%sp@(20),%sp
	movel	%d0,%d2			| remember current-page result
| -- resolve the NEXT page (the actual crossing target) --
	addil	&0x1000,%d3
	pea	1			| rw = read
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d3,%sp@-
	moveal	u+0x730,%a0
	movel	%a0@(124),%sp@-
	jsr	as_fault
	lea	%sp@(20),%sp
	tstl	%d0
	beqw	Lrt_hbfixed		| next page mapped -> retry
	tstl	%d2
	beqw	Lrt_hbfixed		| current page (re)resolved -> retry
	braw	Lrt_hbnorm		| both failed -> genuine hard-error path
Lrt_hbfixed:
	clrl	%d0			| return 0 = not a hard error, retry
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts
Lrt_hbnorm:
	movel	%fp@(12),%sp@-		| ptep
	movel	%fp@(8),%sp@-		| addr
	jsr	hardbus_orig
	addqw	&8,%sp
	moveml	%fp@(-8),%d2-%d3	| d0 = hardbus_orig's ret, untouched
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| resume OVERRIDE (stock at .text 0x9c) -- native 040 context-switch core.
| Contract (matches the actual code; an older header claimed the context was read
| through the kvsegu window and that proc 0 has p_segu==0 -- both stale, see Codex
| PROCESS-MMU-CONTEXT-SWITCH-CONTRACT.md):
|  * remap the FIXED-VA u-area first: uarea_pt = kptr040[0] leaf; write the NEW
|    proc's two 4KB u-page PTEs while interrupts are masked at IPL 7.
|    path U = p_ubptbl (proc 0 / rebuilt compat table: 2KB clicks 0 and 2 -> 4KB
|    PTEs, keep the live leaf status flags),
|    path V = walk kptr040 for p_segu & p_segu+0x1000 (fallback when p_ubptbl[0]==0;
|    PTEs already 4KB).
|  * publish with cpusha bc + pflusha, THEN restore d2-d7/a1-sp from the fixed VA
|    (arg1 = u+0x318), which now names the target's physical u-area.  No stack access
|    after the pflusha.
|  * p_segu==0 AND p_ubptbl[0]==0 (pre-p0init early boot) -> skip the remap.
| --weaken-symbol resume.  globals: curproc (C), kptr040 (D).
	.globl	resume
resume:
	moveal	curproc,%a1
	movel	%a1@(252),%d1		| d1 = p_segu (new proc's u-area kvsegu VA; may be 0)
	moveal	%sp@(4),%a0		| a0 = arg1 = u+0x318 (fixed VA) -- context read source
	movew	%sr,%d0			| d0 = sr (preserved to the end)
	movew	&0x2700,%sr		| mask interrupts for the remap
	tstl	%d1
	bnew	Lrt_remap		| p_segu!=0 -> forked/kvsegu proc: remap (path U/V dispatch)
	moveal	curproc,%a3
	movel	%a3,%d3
	addil	&95,%d3
	andil	&0xfffffff0,%d3
	moveal	%d3,%a3			| a3 = &p_ubptbl = (proc+95)&~15 (same calc as path U)
	tstl	%a3@
	beqw	Lrt_rest		| no p_segu AND no p_ubptbl: early boot, old behaviour safe
Lrt_remap:
	moveal	kptr040,%a2
	movel	%a2@,%d2
	andil	&0xffffff00,%d2		| d2 = uarea_pt base = kptr040[0] & ~0xFF
	moveal	%d2,%a2			| a2 = uarea_pt
	moveal	curproc,%a3
	movel	%a3,%d3
	addil	&95,%d3
	andil	&0xfffffff0,%d3
	moveal	%d3,%a3			| a3 = &p_ubptbl = (proc+95)&~15
	tstl	%a3@
	beqw	Lrt_kvsegu		| p_ubptbl[0]==0 -> forked proc, walk kvsegu
|	--- path U: p_ubptbl (proc 0 / static u-area); 2KB click -> 4KB 040 PTE, keep live flags ---
	movel	%a2@,%d3
	andil	&0x00000fff,%d3		| d3 = live 040 leaf status flags (e.g. 0x0F9)
	movel	%a3@,%d4		| uarea_pt[0] = (p_ubptbl[0] phys & ~0xFFF) | flags
	andil	&0xfffff000,%d4
	orl	%d3,%d4
	movel	%d4,%a2@
	movel	%a3@(8),%d4		| uarea_pt[1] = (p_ubptbl[2] phys & ~0xFFF) | flags (4KB stride)
	andil	&0xfffff000,%d4
	orl	%d3,%d4
	movel	%d4,%a2@(4)
	braw	Lrt_flush
Lrt_kvsegu:
|	--- path V: forked proc -- walk kptr040 for p_segu & p_segu+0x1000 (already 040 4KB leaf PTEs) ---
	movel	%d1,%d4			| page 0: index kptr040 for p_segu
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4		| leaf table base
	movel	%d1,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@		| uarea_pt[0] = kvsegu leaf PTE for p_segu
	movel	%d1,%d3			| page 1: p_segu + 0x1000
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
	movel	%a3@,%a2@(4)		| uarea_pt[1] = kvsegu leaf PTE for p_segu+0x1000
Lrt_flush:
	.word	0xf4f8			| cpusha bc -- push the uarea_pt writes to RAM for the HW tablewalk
	.word	0xf518			| pflusha -- invalidate the ATC (fixed-VA stack now remaps away!)
Lrt_rest:
	| caches-on Step A (2026-07-15): invalidate the IC on every context switch so a
	| physical code page reused for new code cannot execute stale cached instructions
	| (the 040 IC is physically tagged and does not snoop CPU/DMA writes).  Covers the
	| dominant cases -- cross-process reload and post-schedule demand-paged text.  Blunt
	| (whole-IC) but correct; a per-page cinvl at code pagein is the future optimization.
	| Harmless while IC is disabled (early boot, before pstart040 enables CACR).
	.word	0xf498			| cinva ic
	moveml	%a0@,%d2-%d7/%a1-%sp
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
