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
	moveml	%d2-%d4/%a2-%a3,%sp@-

| --- bounded nested-fault fail-fast, PER PROCESS (must be FIRST: it also guards
|     our own body).  Spec: docs/contracts/KRNXMEMFLT-PER-PROC-DEPTH-SPEC.md.
|     The old gate counted ONE machine-global depth, and as_fault may sleep while
|     it is elevated -- so five unrelated processes at depth one looked exactly
|     like one process recursing to depth five, and the fifth was rejected without
|     ever trying as_fault (false EFAULT under u_nofault, kernel panic without it).
|     Refuted as ISSUE-22's cause, but a real latent defect on a loaded machine.
|     The cell is chosen by p_pidp->pid_prslot, which pid_assign sets from
|     (procent - procdir) and pid_exit reads back: stable for the whole process
|     lifetime, and a process cannot finish pid_exit while its own kernel stack is
|     asleep inside as_fault -- so the table has no owner-staleness race.
|     a3 holds the cell for the whole call; it is callee-saved under this ABI and
|     therefore survives as_fault, cmn_err and the far-page helper. ---
	clrl	%d2			| sane FA if the gate logs before the decode
	clrl	%d3			| sane rw likewise (the old code logged stale d2/d3)
	movew	%sr,%d1			| save IPL...
	oriw	&0x0700,%sr		| ...spl7: nothing may re-enter the resolver
					|   between the load and the store of this cell.
					|   Only resident u/proc/pid loads and private data
					|   inside -- no call, no page fault.
	moveal	u+0x730,%a3		| curproc (u.u_procp)
	movel	%a3,%d0
	beqw	Lkx_noproc_hit
	movel	%a3@(264),%d0		| p_pidp
	beqw	Lkx_noproc_hit
	moveal	%d0,%a3
	addql	&1,%a3			| &pid_prslot (24-bit field at pid+1)
	bfextu	%a3@{&0:&24},%d0	| slot
	cmpil	&200,%d0		| v.v_proc; the relink asserts it really is 200
	bccw	Lkx_badslot_hit
	asll	&2,%d0
	lea	Lkx_proc_depth,%a3
	addal	%d0,%a3
	braw	Lkx_slotok
Lkx_badslot_hit:
	addql	&1,Lkx_badslot		| fail VISIBLY, never index past the table
	lea	Lkx_fallback_depth,%a3
	braw	Lkx_slotok
Lkx_noproc_hit:
	addql	&1,Lkx_noproc
	lea	Lkx_fallback_depth,%a3
Lkx_slotok:
	addql	&1,%a3@			| depth = ++*a3  -- THIS process only
	addql	&1,Lkx_depth		| active resolvers: instrumentation ONLY now
	movel	%a3@,%d0		| d0 = this process's depth
	cmpl	Lkx_maxdepth,%d0
	blsw	Lkx_nomax1
	movel	%d0,Lkx_maxdepth
Lkx_nomax1:
	movel	Lkx_depth,%d4
	cmpl	Lkx_maxactive,%d4
	blsw	Lkx_nomax2
	movel	%d4,Lkx_maxactive
Lkx_nomax2:
	movew	%d1,%sr			| restore IPL BEFORE any branch or call
	cmpil	&4,%d0
	bgtw	Lkx_f1			| this process is recursing: unresolved

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
	beqw	Lkx_f2			| no kas segment -> unresolved (ISSUE-22 candidate 2)

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
	braw	Lkx_f3			| as_fault FAILED (this one IS visible in the FAIL logger)

Lkx_inval:
	movel	%d3,%sp@-		| rw
	clrl	%sp@-			| type = F_INVAL
	pea	1			| len
	movel	%d2,%sp@-		| va
	pea	kas			| as
	jsr	as_fault
	lea	%sp@(20),%sp
	braw	Lkx_ret			| raw as_fault result (stock I-branch semantics)

| --- ISSUE-22 EXIT PROBE (2026-07-28).  Evidence: a transient `read: Bad address` under copy
|     pressure reaches user space while the as_fault FAIL logger (cap 64) records ZERO failures, so
|     the EFAULT does not come from a failed page-in.  EFAULT arrives via sf_fault, which needs the
|     RESOLVER to return nonzero -- and this function has exactly three failure exits, two of which
|     never call as_fault at all.  So name the exit instead of guessing which one:
|         w=1  recursion/depth cap exceeded (depth > 4)
|         w=2  no kas segment owns the fault address
|         w=3  as_fault itself failed (cross-check: this one must ALSO appear in the FAIL logger)
|     Cap 8 prints -- enough to characterise, too few to flood a machine already under pressure.
|     Copyback reproduces the EFAULT in the first burst, so one run should be sufficient.
Lkx_f1:
	moveq	&1,%d1
	braw	Lkx_flog
Lkx_f2:
	moveq	&2,%d1
	braw	Lkx_flog
Lkx_f3:
	moveq	&3,%d1
Lkx_flog:
	movel	Lkx_fn,%d0
	cmpil	&8,%d0
	bccw	Lkx_fail
	addql	&1,%d0
	movel	%d0,Lkx_fn
	movel	%a3@,%sp@-		| THIS process's depth (not the active count)
	movel	%d3,%sp@-		| rw as decoded from the SSW
	movel	%d2,%sp@-		| the fault address
	movel	%d1,%sp@-		| which exit
	pea	Lkx_fmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lkx_fail:
	moveq	&1,%d0
Lkx_ret:
| --- ISSUE-37 XPAGE (2026-07-28): the 68040 reports FA = the START of a MISALIGNED access even
|     when the page actually missing is the NEXT one (SSW MA bit).  as_fault then resolves the
|     already-present near page, returns 0, the instruction restarts and faults identically --
|     an UNKILLABLE kernel loop, because the fault is taken in kernel mode on the process's behalf.
|
|     This is not a new discovery: wb040.s's wb060_xpage implements exactly this fix for the 060
|     format-4 path, citing Linux/m68k's `if (fslw & MA) addr = (addr + 7) & -8`, and its comment
|     says "Gated on fmt-4: on the 040 the byte-wise replay already covers this."  That is true for
|     WRITE-BACKS -- wb040_replay reissues them byte-wise -- but a READ access error never reaches
|     the replay path at all, so the 040's read side was left uncovered.  ISSUE-37 is that gap.
|
|     MEASURED, three times on real hardware (wolf3d): every loop faults at in-slot offset 0xFFF
|     of an 8 KiB segmap slot -- the LAST BYTE of the slot's first page, i.e. precisely where a
|     misaligned access straddles into the slot's second page -- with type=0 ret=0 and the user PC
|     at libc.so.1+0x13088 = `read`+4.  as_fault(len=1) rounds to a 4096-byte range that covers
|     only the first page, so segmap_fault maps that page and never the second one.
|
|     Same recipe as the 060, deliberately including the same 8-byte window rather than a wider
|     speculative one: after a SUCCESSFUL resolve, if FA lies in the last 8 bytes of its page,
|     resolve the NEXT page too.  A `move16` cannot trigger this (it is 16-byte aligned by
|     definition), and 8 bytes covers every misalignable operand up to an FPU double. ---
	tstl	xpage_on		| ISSUE-22 A/B: one .data byte turns this off in an
	beqw	Lkx_nox			| OTHERWISE IDENTICAL image (patch_xpage_flip.py)
	tstl	%d0
	bnew	Lkx_nox			| only after a SUCCESSFUL resolve
| --- v2 (2026-07-28), on Codex's XPAGE-COVERAGE-AUDIT.  v1 used the 060 sibling's address
|     heuristic verbatim and inherited three defects it names precisely:
|       * NOT CPU-GATED -- v1 had no format test, so on a 060 kernel fault the next page was
|         resolved TWICE, once here and again in wb060_xpage;
|       * S_READ hardcoded, including for write faults;
|       * a permanent far-page failure discarded, so an unmappable far page could still retry.
|     All three are fixed here, and the address window is replaced by the architectural test.
|
|     WHY MA IS BETTER THAN THE LAST-8-BYTES WINDOW, and why it had to come first: the 040 sets
|     SSW MA precisely when the fault is on the SECOND page of a transfer that spans two pages,
|     which is the exact condition the window only approximates.  Without MA, this block also
|     pre-faults a successor for a NON-crossing byte access at offset 0xFFF -- harmless while the
|     far result is discarded, but it would turn into a SPURIOUS FAILURE the moment we propagate
|     that result.  So MA is what makes error propagation safe, not merely tidier.  (The 060 path
|     cannot do this yet: wb060_sswsynth overwrites the FSLW word holding MA before its helper
|     runs.  That belongs to Codex's six-item frame-aware unit, not here.)
|     The 040 SSW is intact at frame+76 -- this function already reads its RW bit -- and MA is
|     bit 11 of that word.
	moveal	%fp@(8),%a0
	moveq	&0,%d1
	moveb	%a0@(70),%d1		| format/vector high byte
	lsrb	&4,%d1
	cmpiw	&7,%d1
	bnew	Lkx_nox			| not an 040 format-7 access-error frame -> not ours
| --- TWO TIERS, deliberately.  MA is the architectural truth, but v1's address window is what
|     was PROVEN on hardware (wolf3d, three loops, then a clean run).  Trading a proven fix for a
|     stricter-but-more-elegant gate on the strength of a manual would be exactly the kind of
|     unforced regression this project keeps finding in other people's code:
|       MA set                 -> the transfer really spans two pages: resolve and KEEP the result,
|                                 because a permanent failure here must reach the caller.
|       MA clear, last 8 bytes -> v1's behaviour verbatim: resolve and DISCARD, since without MA we
|                                 cannot distinguish a real crossing from a byte access that merely
|                                 sits at 0xFFF, and failing that access would be a NEW bug.
|     So v2 is a strict superset of v1: everything v1 resolved is still resolved.
	movew	%a0@(76),%d1		| 040 SSW (intact on the 040; this function reads its RW bit)
	andiw	&0x0800,%d1		| MA: the faulted transfer spans two pages
	bnew	Lkx_xp_ma
	movel	%d2,%d1
	andil	&0xfff,%d1
	cmpil	&0xff8,%d1
	bcsw	Lkx_nox			| neither MA nor the window -> nothing to do
	movel	%d0,%sp@-		| v1 tier: preserve the return value, discard the far one
	bsrw	Lkx_farfault
	movel	%sp@+,%d0
	braw	Lkx_nox
Lkx_xp_ma:
	bsrw	Lkx_farfault		| MA tier: d0 = the far result, KEPT on purpose
	braw	Lkx_nox
Lkx_farfault:
	movel	%d2,%d1
	andil	&0xfffff000,%d1
	addil	&0x1000,%d1		| the page the transfer actually needs
	movel	%d3,%sp@-		| rw = the REAL access kind (d3, decoded above)
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d1,%sp@-		| addr = next page
	pea	kas			| as   = kernel address space
	jsr	as_fault
	lea	%sp@(20),%sp
	rts
Lkx_nox:
| Every return funnels through here, including the depth-five rejection, so the
| increment is always balanced.  d0 is the resolver's return value and must not be
| touched by accounting; d1 and the saved SR are the only scratch.
	movew	%sr,%d1
	oriw	&0x0700,%sr
	tstl	%a3@
	bnew	Lkx_dec1
	addql	&1,Lkx_underflow	| fail soft: never wrap a depth to UINT_MAX
	braw	Lkx_dec2
Lkx_dec1:
	subql	&1,%a3@
Lkx_dec2:
	tstl	Lkx_depth
	bnew	Lkx_dec3
	addql	&1,Lkx_underflow
	braw	Lkx_dec4
Lkx_dec3:
	subql	&1,Lkx_depth
Lkx_dec4:
	movew	%d1,%sr
	moveml	%fp@(-20),%d2-%d4/%a2-%a3
	unlk	%fp
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lkx_fmsg:
	.asciz	"DBG krnxflt FAILEXIT w=%d va=%x rw=%d depth=%d"
	.even
Lkx_fn:
	.long	0
	.globl	xpage_on
xpage_on:
	.long	1			| 1 = xpage handling live (default); 0 = the A/B control
	.balign 4			| pad section to a 4-byte multiple

	.data
	.even
| Lkx_depth is now AGGREGATE INSTRUMENTATION ONLY: how many resolvers are active
| machine-wide.  It must never decide a failure again -- that is Lkx_proc_depth's
| job.  The symbol is kept so existing kpeek recipes keep meaning something.
Lkx_depth:
	.long	0
	.balign	4
| One depth cell per process slot.  200 == v.v_proc; if that tunable ever grows,
| this table must grow in the same change (the relink asserts the value).
Lkx_proc_depth:
	.space	800,0
Lkx_fallback_depth:
	.long	0			| no proc / out-of-range slot land here
Lkx_badslot:
	.long	0			| slot >= 200 seen (must stay 0)
Lkx_noproc:
	.long	0			| curproc or p_pidp NULL at fault time
Lkx_underflow:
	.long	0			| a decrement found the counter already 0
Lkx_maxdepth:
	.long	0			| deepest single-process recursion seen
Lkx_maxactive:
	.long	0			| most resolvers active at once (the old gate's
					|   view -- if this exceeds 4 while maxdepth
					|   stays low, the old global gate WOULD have
					|   produced a false EFAULT right there)
	.balign 4			| pad section to a 4-byte multiple
