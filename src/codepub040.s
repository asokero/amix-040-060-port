| codepub040.s -- USER-CODE-PUBLISH: make mprotect(..., PROT_EXEC) the general
| user-code cache-publication barrier under 68040/68060 copyback (2026-08-01).
| Spec: docs/contracts/USER-CODE-CACHE-ABI-SPEC.md (6c1cb84), the residual
| ISSUE-38 left open and DBG-TEXT-PUBLISH did not cover.
|
| WHY.  ISSUE-38's rule generalises: bytes written with the CPU into a page that
| is later EXECUTED live in dirty copyback data-cache lines, and the 040 ifetch
| does not snoop them.  cb_icode040.s covers proc 1's icode; dbgpublish040.s
| covers the two debugger writers.  Neither covers the case where USER SPACE
| itself generates code -- a runtime linker relocating text, a JIT, or a plain
| read(2) into a buffer that is then jumped to.  Those need a boundary the user
| can name, and mprotect with PROT_EXEC is the natural one.
|
| The kernel as shipped is only ACCIDENTALLY sufficient, in exactly one shape:
|
|   mprotect 0x58550 -> as_setprot -> segvn_setprot -> hat_chgprot -> cpusha bc
|
| so a REAL protection change (RW -> RX) happens to publish, because
| hat_chgprot's page-table-coherency tail is a whole-cache push.  Two holes:
|
|   1. segvn_setprot returns success EARLY when the requested protection equals
|      the segment's current protection -- so a legacy RWX generator (PROC_DATA
|      mappings are RWX on this port) can never publish at all, no matter how
|      many times it calls mprotect.
|   2. hat_chgprot's push is documented as PTE coherency.  A later range
|      optimisation there would be correct on its own terms and would silently
|      delete user-code publication.
|
| WHAT.  A strong `mprotect` wrapping the retained stock body.  After the
| original syscall SUCCEEDS and the REQUESTED protection contains PROT_EXEC
| (0x4), execute `cpusha bc` before returning to user mode.  Whole-cache, not
| ranged, deliberately -- exactly as in cb_icode040/dbgpublish040: CPUSHL takes a
| PHYSICAL address on the 040, so a ranged push of a user VA needs a page-table
| walk that can fault on a partly resident range, and the whole-cache opcode is
| non-faulting, alias-proof and cross-process-proof.  Code generation is an
| infrequent event; this is not an I/O path.  A range optimisation (walk
| uvatopte040, push 16-byte lines) is allowed AFTER acceptance, never before,
| and must not change this ABI.
|
| ERROR PATHS ARE UNTOUCHED.  d0 is the syscall's errno return (0 = success);
| the wrapper tests it and returns it unchanged, and publishes nothing on a
| failed call.  The `moveal %d0,%a0` tail matches the stock body at 0x585c2.
|
| WHY NOT cinva ic ALONE: the newest bytes may exist ONLY in dirty D lines.
| WHY NOT cinva dc: it would DISCARD them.  WHY NOT "a context switch will do
| it": resume040 invalidates the I-cache but does not force the generating
| process's dirty D lines to RAM before an immediate same-process branch.
|
| The alignment gate at 0x58572 (the historical 0x7ff mask on the address) is
| deliberately NOT touched -- it is a separate Model-B public-ABI residual, and
| `cpusha bc` is correct for every range the stock syscall accepts because it
| uses none of the supplied geometry.
|
| codepub_on ships 1.  It exists so the barrier can be A/B'd on hardware without
| a rebuild (kpoke 0, re-run, the generated code must then MISFIRE) -- the same
| idiom as hat_cm_ram / dbg_publish_on / kdbg_on.  An image shipping 0 is a
| bisect image and must be stamped as such.
|
| Counters (uncapped: they are how a boot PROVES the wrapper ran, which "the
| program worked" does not):
|   codepub_calls = every mprotect call reaching the wrapper
|   codepub_exec  = successful calls whose requested prot had PROT_EXEC
|                   (the ABI events; advances even when codepub_on = 0)
|   codepub_push  = `cpusha bc` actually executed  (= the spec's codepub_mprotect)
| With codepub_on = 1 the acceptance invariant is codepub_push == codepub_exec.
|
| Argument block: the syscall body receives ONE pointer (fp@(8)) to
|   args+0 addr   args+4 len   args+8 prot
| verified by disassembly of the stock body (0x58558..0x5856c, which also ORs
| PROT_USER 0x8 into its own copy -- we read the caller's word, not that copy).
|
| Mechanism: --weaken-symbol mprotect + --add-symbol mprotect_orig=.text:0x58550.
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c codepub040.s -o build/codepub040.o

	.text
	.globl	mprotect
mprotect:
	linkw	%fp,&0
	movel	%fp@(8),%sp@-		| the syscall argument block pointer
	jsr	mprotect_orig
	addqw	&4,%sp			| d0 = errno return from here on
	addql	&1,codepub_calls
	tstl	%d0
	bnew	Lcp_out			| failed -> original errno, no publication
	moveal	%fp@(8),%a0
	movel	%a0@(8),%d1		| requested prot (as the caller wrote it)
	andil	&0x4,%d1		| PROT_EXEC
	beqw	Lcp_out			| not an executable transition
	addql	&1,codepub_exec
	tstl	codepub_on
	beqw	Lcp_out			| A/B image: count the event, skip the barrier
	.word	0xf4f8			| cpusha bc -- push dirty data lines to RAM,
					|   invalidate both caches, so the caller's
					|   next instruction fetch sees the bytes
	addql	&1,codepub_push
Lcp_out:
	moveal	%d0,%a0			| SVR4 m68k: a pointer result rides in a0 too
	unlk	%fp
	rts
	nop

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
| codepub_on: 1 = publish (the shipped default), 0 = wrapper counts the ABI
| events but performs no cache operation, for the decisive one-boot A/B.
	.globl	codepub_on
codepub_on:
	.long	1
	.globl	codepub_calls
codepub_calls:
	.long	0
	.globl	codepub_exec
codepub_exec:
	.long	0
	.globl	codepub_push
codepub_push:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
