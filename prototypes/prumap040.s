| ============================================================================
| prumap040.s -- prumap override: lazily install the kvsegu SLOT-0 (proc 0)
| u-area alias into the live kptr040 tree.
|
| WHY (boot-13/14 panic, 2026-07-04): /proc readers (prioctl -> prgetpsinfo,
| scrmenu pid 43) access a TARGET process's u-area through the fixed kvsegu
| window returned by prumap() = p->p_segu.  Every slot EXCEPT slot 0 is mapped
| at runtime by segu_get/segu_softload -> hat_memload -> our 040 hat_pteload,
| so those leaf PTEs live in kptr040 and the window works.  Slot 0 (proc 0 /
| sched, the static u-area) is set up ONCE at boot by p0init (file-LOCAL 't'
| 0x48fcc -- --weaken can't rebind its caller, the anon_decref lesson), whose
| tail loop writes the alias PTEs with a raw 030 walk (va>>17 SDE, va>>11 leaf,
| 2KB steps) into st_top1 -- INERT on 040.  So VA p0seguser (0x48440000) has no
| live mapping: the first /proc query that looks at pid 0 faults, segu_fault
| finds slot 0 SEGU_LOCKED and returns FC_MAKE_ERR(EINVAL) (= the logged
| as_fault ret=0x1605), and prgetpsinfo's raw movel %a5@(0x900) panics
| (KERNEL FAULT pc=0x7064436 fmt=7 vec=2).
|
| FIX: prumap is the choke point every /proc u-area access goes through, and it
| is GLOBAL T (0x631c0) -> --weaken-symbol override.  Stock body is just
| `return p->p_segu` (p@252) -- fully replicated here, no _orig needed.  On the
| first call with p->p_segu == p0seguser we copy proc 0's two u-area page frames
| out of p_ubptbl ((p+95)&~15, filled by p0init: entries (phys&~0x7FF)|1 at 2KB
| steps -> entries 0 and 2 are the two 4KB pages) into the kvsegu slot-0 leaf
| PTEs via the kptr040 walk.  This is the exact DUAL of resume040's path U
| (mainmarks.s:293), which already proves both the p_ubptbl source and the
| (phys&~0xFFF)|flags PTE form live-correct on this 040 (proc 0 runs on them).
| cpusha bc pushes the PTE writes to RAM for the HW tablewalk (no pflusha
| needed: these VAs were never valid, the 040 doesn't cache invalid entries).
|
| One-shot (Lpm_done).  If the kvsegu leaf table doesn't exist yet (no proc's
| u-area mapped in slots 0-31 -- impossible once /proc is in use since init's
| own slot shares the 256KB leaf region, but guard anyway) or p_ubptbl[0] is
| empty, we skip WITHOUT setting done and retry on a later call.
|
| The write goes through DTT0-identity kernel VAs; slot 0 stays SEGU_LOCKED
| (never softunloaded -- proc 0 is SSYS/SLOCK, immortal), so the mapping is
| permanent and segu_fault never sees this slot again.
| ============================================================================
	.text
	.globl	prumap
prumap:
	linkw	%fp,&0
	moveal	%fp@(8),%a0		| p
	movel	%a0@(252),%d0		| d0 = p->p_segu = the kvsegu window VA (return value)
	tstl	Lpm_done
	bnew	Lpm_ret
	cmpl	p0seguser,%d0		| slot-0 owner (proc 0)?
	bnew	Lpm_ret
	moveml	%d3-%d5/%a2-%a3,%sp@-
|	--- dest: kvsegu slot-0 leaf PTE pair -- kptr040 walk for d0 (resume040 path-V idiom) ---
	movel	%d0,%d4
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4		| pointer descriptor
	moveq	&3,%d5
	andl	%d4,%d5			| UDT: 0/1 = invalid, 2/3 = resident
	subql	&2,%d5
	bcsw	Lpm_out			| leaf table absent -> retry on a later call
	andil	&0xffffff00,%d4		| d4 = leaf table base
	movel	%d0,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5			| va>>12
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3			| a3 = &leaf[slot-0 page 0]
|	--- source: p_ubptbl = (p+95)&~15 (p0init-filled, 2KB entries) -- resume040 path-U idiom ---
	moveal	%fp@(8),%a2
	movel	%a2,%d3
	addil	&95,%d3
	andil	&0xfffffff0,%d3
	moveal	%d3,%a2			| a2 = p_ubptbl
	movel	%a2@,%d4
	beqw	Lpm_out			| not filled -> bail (retry later)
	movel	%d4,%d5
	andil	&0x00000fff,%d5		| d5 = live PTE flags (p0init wrote |1)
	andil	&0xfffff000,%d4
	orl	%d5,%d4
	movel	%d4,%a3@		| leaf[0] = u-area page 0
	movel	%a2@(8),%d4		| p_ubptbl[2] = page 1 (2KB entries -> 4KB stride)
	andil	&0xfffff000,%d4
	orl	%d5,%d4
	movel	%d4,%a3@(4)		| leaf[1] = u-area page 1
	.word	0xf4f8			| cpusha bc -- push the PTE writes to RAM for the HW tablewalk
	moveq	&1,%d4
	movel	%d4,Lpm_done
Lpm_out:
	moveml	%sp@+,%d3-%d5/%a2-%a3
Lpm_ret:
	moveal	%d0,%a0			| return p->p_segu (stock prumap semantics)
	unlk	%fp
	rts
	nop			| pad .text to a 4-byte multiple (loader copies text+data as one block)

	.data
Lpm_done:
	.long	0
