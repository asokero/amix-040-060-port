| krnxmemflt040.s -- NATIVE 040/060 kernel fault-resolver core (ISSUE-13 capture 2,
| 2026-07-13).  Replaces the stock krnxmemflt_orig body (.text 0x5b140), which was a
| COUPLED 4-defect 030 remnant (Codex 040-FAULT-RESOLVER-AUDIT.md):
|   1. it probed kernel VAs through the shared user-FC1/URP `ptest` -- user roots
|      deliberately hold no kernel entries, so a kernel VA always reported I(nvalid)
|      and resident write-protection was invisible;
|   2. it decoded read-vs-write from the 030 SSW field frame+72 bit 6 (on 040 that is
|      an EA bit, on 060 a fault-address bit) -- the rw it passed to as_fault ->
|      segmap_fault -> VOP_GETPAGE could depend on the ADDRESS, not the access;
|   3. its second write-protection gate ((frame+72 & 0x140) == 0x100) read the same
|      wrong field, ignoring the wrapper's corrected/synthesized frame+76 SSW;
|   4. its admitted PTE branch did the stock 030 leaf walk (*(vatosde+4) + (va>>11)
|      indexing) against the 4-byte 040 pointer descriptor -> nested kernel fault
|      (the crash(1M) /dev/kmem fault-storm amplifier).
| These had to be ported TOGETHER: fixing only the walk keeps wrong status+rw, and
| fixing only the status probe would newly EXPOSE the broken walk.
|
| This core:
|   * fault va from the ported get_fault (fmt-7 +84 / fmt-4 +72);
|   * rw from the 040/synthesized SSW at frame+76 (byte bit 0 = RW, set = pure read;
|     the public krnxmemflt wrapper in wb040.s runs wb060_sswsynth BEFORE calling us,
|     so frame+76 is 040-style on BOTH CPUs);
|   * kernel translation status via a VALIDATED SOFTWARE WALK of the live kernel tree
|     (kptr040 pointer descriptor -> leaf PTE via the current vatosde/vatopte) --
|     identical on 040 and 060, no PTESTR, and NEVER through the user-only ptest
|     (changing global ptest to supervisor FC would break the working user COW path);
|   * walk validation: region-1 range gate, UDT resident bits, leaf-frame bounds
|     (_start>>12 <= frame < pages_end, the hat040.s V2.3 idiom) -- any validation
|     failure degrades to the F_INVAL attempt instead of dereferencing garbage;
|   * bounded nested-fault fail-fast: the k_trap landing-pad window (pad cleared
|     while the resolver runs) let an unresolvable fault inside resolution recurse
|     ~25 deep and eat the kernel stack (ISSUE-13 capture 2).  A depth counter
|     returns 1 (unresolved) beyond depth 4 -> ONE clean krnlflt panic instead of a
|     stack-eating storm.  Legitimate resolution nesting is depth 1-2.
| Return contract (stock-compatible): 0 = resolved (wrapper then runs the 040
| write-back replay), nonzero = unresolved.  The I branch returns as_fault's raw
| result, the protection branch normalizes to 1 -- exactly like the stock body.
|
| Stock constants (from the vanilla disassembly at 0x5b140):
|   as_fault(as, va, len=1, type, rw); F_INVAL=0, F_PROT=1; S_READ=1, S_WRITE=2.
| Linkage: wb040.s's public krnxmemflt wrapper calls krnxmemflt_orig; relink-040.sh
| no longer aliases that name to 0x5b140 (the stock body stays reachable as
| krnxmemflt_stock for reference) so our strong def binds instead.

	.text
	.globl	krnxmemflt_orig
krnxmemflt_orig:
	linkw	%fp,&0
	moveml	%d2-%d4/%a2,%sp@-

| --- bounded nested-fault fail-fast (must be FIRST: it also guards our own body) ---
	movel	Lkx_depth,%d0
	addql	&1,%d0
	movel	%d0,Lkx_depth
	cmpil	&4,%d0
	bgtw	Lkx_fail		| recursion cap: unresolved -> one clean panic

| --- fault address ---
	movel	%fp@(8),%sp@-
	jsr	get_fault
	addqw	&4,%sp
	movel	%d0,%d2			| d2 = fault va

| --- rw from the (synthesized) 040 SSW: frame byte +76 bit 0 = RW, set = read ---
	moveal	%fp@(8),%a0
	moveq	&2,%d3			| d3 = rw = S_WRITE
	moveq	&1,%d0
	andb	%a0@(76),%d0
	beqs	Lkx_haverw
	moveq	&1,%d3			| RW set -> pure read -> S_READ
Lkx_haverw:

| --- a kernel (kas) segment must own the address (stock contract) ---
	movel	%d2,%sp@-
	pea	kas
	jsr	as_segat
	addqw	&8,%sp
	movel	%a0,%d0			| as_segat returns the segment in a0
	tstl	%d0
	beqw	Lkx_fail		| no kas segment -> unresolved

| --- kernel translation status: validated software walk of the LIVE tree ---
	cmpil	&0x40000000,%d2
	bcsw	Lkx_inval		| below region 1: no kernel page tree here
	cmpil	&0x80000000,%d2
	bccw	Lkx_inval		| above region 1
	movel	%d2,%sp@-
	jsr	vatosde
	addqw	&4,%sp
	moveal	%a0,%a2			| a2 = &kptr040 pointer descriptor
	movel	%a2@,%d0
	moveq	&3,%d1
	andl	%d0,%d1
	cmpil	&2,%d1
	bcsw	Lkx_inval		| UDT 0/1: pointer table not resident
	andil	&0xffffff00,%d0
	beqw	Lkx_inval		| zero leaf base: nothing mapped
| leaf-frame sanity (hat040.s V2.3 idiom): _start>>12 <= frame < pages_end
	movel	%d0,%d1
	moveq	&12,%d4
	lsrl	%d4,%d1			| d1 = leaf frame number
	movel	&_start,%d4
	lsrl	&8,%d4
	lsrl	&4,%d4			| d4 = kernel image base frame (_start>>12)
	cmpl	%d4,%d1
	bcsw	Lkx_inval		| garbage descriptor below the kernel image
	cmpl	pages_end,%d1
	bccw	Lkx_inval		| garbage descriptor above RAM
	movel	%a2,%sp@-		| vatopte(va, sde)
	movel	%d2,%sp@-
	jsr	vatopte
	addqw	&8,%sp
	movel	%a0@,%d4		| d4 = leaf PTE
	moveq	&3,%d1
	andl	%d4,%d1
	beqw	Lkx_inval		| PDT 00: page missing -> ordinary demand fault
	cmpil	&2,%d1
	beqw	Lkx_inval		| indirect descriptor: no direct kernel PTE
| resident PTE: classify the fault.  NOTE the de-facto stock contract: the old
| URP-blind ptest reported EVERY kernel VA as I, so stock krnxmemflt gave as_fault
| an F_INVAL attempt for ALL these cases (resident-writable race, stale ATC, W+read)
| and the segment driver revalidated the mapping.  Keep that graceful path -- only a
| genuine write into a write-protected resident page upgrades to F_PROT.
	btst	&2,%d4			| 040 PTE W bit (write-protected)
	beqw	Lkx_inval		| resident+writable yet faulted (race/stale ATC):
					|   F_INVAL revalidation attempt, like stock
	cmpil	&2,%d3
	bnew	Lkx_inval		| W page but READ access: revalidate, like stock
| write into a write-protected resident kernel page -> F_PROT (COW-style)
	movel	%d3,%sp@-		| rw
	pea	1			| type = F_PROT
	pea	1			| len
	movel	%d2,%sp@-		| va
	pea	kas			| as
	jsr	as_fault
	lea	%sp@(20),%sp
	tstl	%d0
	beqw	Lkx_ret			| resolved
	braw	Lkx_fail		| normalize to 1 (stock protection-branch semantics)

Lkx_inval:
	movel	%d3,%sp@-		| rw
	clrl	%sp@-			| type = F_INVAL
	pea	1			| len
	movel	%d2,%sp@-		| va
	pea	kas			| as
	jsr	as_fault
	lea	%sp@(20),%sp
	braw	Lkx_ret			| raw as_fault result (stock I-branch semantics)

Lkx_fail:
	moveq	&1,%d0
Lkx_ret:
	movel	Lkx_depth,%d1
	subql	&1,%d1
	movel	%d1,Lkx_depth
	moveml	%fp@(-16),%d2-%d4/%a2
	unlk	%fp
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
Lkx_depth:
	.long	0
	.balign 4			| pad section to a 4-byte multiple
