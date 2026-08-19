| devkvmap040.s -- map a device (MMIO) aperture into kernel VA with an EXPLICIT
| cache class, and tear it down again.  Zorro III RTG track, change A.
|
| WHY THIS EXISTS
|
| A driver cannot reach a Zorro III board at all today.  Drivers dereference
| `cd_BoardAddr` directly as a kernel address; DTT0 = 0x003fc060 identity-maps
| only 0x00000000-0x3FFFFFFF (src/pstart040.s:326), so a Z3 board at 0x40000000+
| lands in the kernel's OWN region-1 VA range, which is fill-on-fault -- the
| access does not fault, it quietly hits kernel memory.  Widening DTT0 (or DTT1,
| 0x807fa060, which covers 0x80000000+) is not available: either widening would
| swallow kvseg/segmap/sptmap, which live exactly there (src/prfastmap040.s:33).
| A real kernel mapping is therefore the only route.
|
| AND WHY IT IS NOT JUST sptalloc()
|
| sptalloc(size, mode, base, flag) with base != 0 maps physical pages, but it
| CANNOT express a cache class:
|
|   sptalloc  0x000a8bb6  never reads its `mode` argument at fp@(12); for
|                         base != 0 it calls segkmem_mapin at 0x000a8c58 with
|                         the template `base << 12` -- every low bit zero.
|   segkmem_mapin 0x000a8904  copies the caller template verbatim into the PTE
|                         (fp@(24) -> fp@(-8) at 0x000a8950) and then touches
|                         ONLY the W bit (bfins at 0x000a8976) and the V bit
|                         (orib at 0x000a897c).  Bits 6:5 come from the cookie.
|
| So a stock-path kernel mapping of MMIO registers is CM=00, i.e. cacheable
| writethrough: a firmware-version read would be answered from the data cache.
| This is not an oversight in the port -- src/segkmem040.s records that the
| segkmem "unmanaged -> NCS" classification was deferred to the segdev-MMIO
| group, and docs/contracts/CM-PTE-WRITER-MATRIX.md:243 specifies it.
|
| THE SHAPE CHOSEN, AND WHY IT IS THIS ONE
|
| This is a WRAPPER plus a CM-ONLY MODIFIER, deliberately not a fifth complete
| leaf constructor:
|
|   * sptalloc owns the sptmap slot bookkeeping, so we do not re-implement it;
|   * sptfree(kva0, npages, 1) is the matching destructor -- it routes through
|     segkmem_mapout, which clears the resident bit, skips the page release for
|     a null page_t and publishes.  Generic hat_unload is NOT a valid teardown
|     here: it reaches hat_pt2ptdat, which cannot derive metadata for a leaf
|     that has no managed table page behind it;
|   * we change only bits 6:5 and assert the PFN we expect in every leaf first,
|     so the existing PTE-writer matrix stays closed rather than gaining a new
|     constructor with its own status/PFN policy.
|
| sptalloc necessarily publishes a WT descriptor for a moment before we fix it.
| That is acceptable ONLY under all four of these, and this code holds them:
|   1. the KVA is not published to the caller until the class is correct;
|   2. no CPU load or store goes through the window in between (we touch page
|      tables, never the mapped aperture);
|   3. every leaf/PFN assertion succeeds, or we sptfree and fail;
|   4. the final class is published (flushmmu = cpusha dc + pflusha) before the
|      KVA is returned.
| The 68040 does not speculatively load data, so an untouched descriptor leaves
| no cache lines behind.
|
| Contract source: the Q3 answer in the kernel-analysis repo's
| vm-map/Z3-DEVICE-APERTURE-AUDIT.md ("Recommended dev_kvmap contract"), which
| is itself grounded on sptalloc/segkmem_mapin/sptfree disassembly plus the USL
| physmap() lifetime precedent (usl-svr42/i386/uts/io/ddi.c:828-896: drivers
| normally retain an MMIO mapping indefinitely).
|
| The leaf tables are addressed through the DTT0 identity window, exactly as
| src/bp_map040.s does: kernel RAM is below 1 GB, so a physical leaf-table
| address is directly usable.  Same assumption, already hardware-accepted.
|
| NOT LINKED INTO THE BASE KERNEL.  Only relink-040-va2000.sh links this, so the
| base image stays byte-identical.  The Lcm_sel framebuffer class (change D) is
| the one that touches the base, and it is a separate step for that reason.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/devkvmap040.s -o build/devkvmap040.o
| Externals: sptalloc, sptfree, vatosde, vatopte, flushmmu.

	.text

| ============================================================================
| char *dev_kvmap(phys, nbytes, cm, flags)
|
|   phys   -- physical base of the aperture window (need not be page-aligned)
|   nbytes -- window length in bytes
|   cm     -- cache class to install: 0x40 = NCS (noncacheable serialised,
|             the class for control/status registers) or 0x60 = NC.  Any other
|             value is rejected: this is not a general PTE-bit poke.
|   flags  -- sptalloc flag word; bit 0 = NOSLEEP (that is what the m68k body
|             tests at 0x000a8c32 before handing segkmem_mapin its sleep arg).
|
| Returns the kernel VA of `phys`, offset within the page preserved, or NULL.
| Pass the SAME nbytes to dev_kvunmap; the page count is derived from the two,
| so the caller cannot desynchronise a separately-stored count.
| ============================================================================
	.globl	dev_kvmap
dev_kvmap:
	linkw	%fp,&-8
	moveml	%d2-%d7/%a2,%sp@-
	movel	%fp@(8),%d2		| d2 = phys
	movel	%fp@(12),%d3		| d3 = nbytes
	movel	%fp@(16),%d4		| d4 = cm

| --- argument validation.  Each rejection is a silent NULL: the caller is a
| --- driver init that must degrade to "no board", not a panic path.
	cmpil	&0x40,%d4
	beq	Ldk_cmok
	cmpil	&0x60,%d4
	bnew	Ldk_fail			| unsupported cache class
Ldk_cmok:
	tstl	%d3
	beqw	Ldk_fail			| nbytes == 0
	movel	%d2,%d0
	addl	%d3,%d0
	subql	&1,%d0
	cmpl	%d2,%d0
	bcsw	Ldk_fail			| phys + nbytes - 1 wrapped 32 bits

| --- geometry: page offset, PFN, page count
	movel	%d2,%d5
	andil	&0xfff,%d5		| d5 = offset within the first page
	movel	%d2,%d6
	moveq	&12,%d0
	lsrl	%d0,%d6			| d6 = first PFN
	beqw	Ldk_fail			| PFN 0: sptalloc reads base==0 as
					|   "allocate RAM", a different function
	movel	%d5,%d7
	addl	%d3,%d7
	addil	&0xfff,%d7
	lsrl	%d0,%d7			| d7 = npages
	movel	%d7,%fp@(-8)		| keep npages: d7 becomes the loop counter

| --- sptalloc(npages, 0, pfn, flags): reserve the sptmap slot and let the
| --- kernel's own constructor install the (still WT) translations.
	movel	%fp@(20),%sp@-		| flags
	movel	%d6,%sp@-		| base = PFN  (non-zero -> map, not alloc)
	clrl	%sp@-			| mode -- ignored by this kernel's body
	movel	%d7,%sp@-		| size = npages
	jsr	sptalloc
	lea	%sp@(16),%sp
	movel	%d0,%fp@(-4)		| kva0
	tstl	%d0
	beqw	Ldk_fail			| no kernel virtual space

| --- CM-only fixup, one leaf at a time, asserting the PFN we expect first.
	moveal	%d0,%a2			| a2 = running VA
	movel	%d6,%d3			| d3 = expected PFN (nbytes is done with)
Ldk_loop:
	movel	%a2,%sp@-
	jsr	vatosde			| a0 = &pointer descriptor for this VA
	addqw	&4,%sp
	movel	%a0@,%d0
	andil	&3,%d0			| 040 UDT: 0 = invalid
	beqw	Ldk_unwind
	movel	%a0,%sp@-		| sde
	movel	%a2,%sp@-		| va
	jsr	vatopte			| a0 = &leaf PTE
	addqw	&8,%sp
	movel	%a0@,%d0
	btst	&0,%d0
	beqw	Ldk_unwind		| leaf not resident: sptalloc did not do
					|   what its contract says -- do not guess
	bfextu	%a0@{&0:&20},%d1	| PFN actually installed (20 bits, as
					|   hat_pteload reads it: covers 4 GB)
	cmpl	%d3,%d1
	bnew	Ldk_unwind		| wrong page mapped -- refuse to reclass it
	andil	&0xffffff9f,%d0		| clear CM (bits 6:5), keep PFN/status/U/M
	orl	%d4,%d0			| install the requested class
	movel	%d0,%a0@
	addql	&1,%d3			| next expected PFN
	addal	&4096,%a2		| next page
	subql	&1,%d7
	bnew	Ldk_loop

| --- publish the class change before the KVA is exposed.  flushmmu is this
| --- port's publication choke point (src/segkmem040.s): cpusha dc + pflusha.
	movel	%fp@(-8),%sp@-
	movel	%fp@(-4),%sp@-
	jsr	flushmmu
	addqw	&8,%sp
	movel	%fp@(-4),%d0
	addl	%d5,%d0			| + offset within the page
	braw	Ldk_out

| --- any assertion failed: hand the slot back and fail the map.
Ldk_unwind:
	pea	1			| flag 1 -> segkmem_mapout, the matching path
	movel	%fp@(-8),%sp@-		| npages
	movel	%fp@(-4),%sp@-		| kva0
	jsr	sptfree
	lea	%sp@(12),%sp
Ldk_fail:
	clrl	%d0
Ldk_out:
	moveml	%fp@(-36),%d2-%d7/%a2
	moveal	%d0,%a0
	unlk	%fp
	rts

| ============================================================================
| void dev_kvunmap(kva, nbytes)
|
| Undo one dev_kvmap.  Pass the value dev_kvmap returned and the SAME nbytes;
| the aligned base and the page count are re-derived, so there is no separately
| stored count to get wrong (freeing kva+offset, or passing bytes where pages
| are expected, returns the wrong resource-map range).
|
| Teardown is sptfree(..., 1) -- segkmem_mapout -- and nothing else.  See the
| header: generic hat_unload is not valid for a mapping with no page_t.
| ============================================================================
	.globl	dev_kvunmap
dev_kvunmap:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(8),%d2		| kva
	movel	%fp@(12),%d3		| nbytes
	tstl	%d2
	beq	Ldu_out
	tstl	%d3
	beq	Ldu_out
	movel	%d2,%d0
	andil	&0xfff,%d0		| offset within the page
	movel	%d0,%d1
	addl	%d3,%d1
	addil	&0xfff,%d1
	lsrl	&8,%d1
	lsrl	&4,%d1			| npages = (off + nbytes + 0xfff) >> 12
	andil	&0xfffff000,%d2		| kva0
	pea	1
	movel	%d1,%sp@-
	movel	%d2,%sp@-
	jsr	sptfree
	lea	%sp@(12),%sp
Ldu_out:
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts

	.balign 4			| pad .text to a 4-byte multiple
