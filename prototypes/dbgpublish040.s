| dbgpublish040.s -- DBG-TEXT-PUBLISH: publish debugger writes to user memory so
| the 68040/68060 instruction fetch can see them under copyback (2026-07-31).
| Spec: analyysirepo vm-map/DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md (6c1cb84),
| which answers the residual left open when ISSUE-38 closed.
|
| WHY.  ISSUE-38 established the rule the hard way: bytes the KERNEL CPU writes
| into user memory live in dirty copyback data-cache lines, and the 040 ifetch
| does not snoop them.  cb_icode040.s covers the one such writer on the boot path
| (main's copyout of proc 1's icode).  The census found two more, both debugger
| control paths, and both write into another process's TEXT by definition:
|
|   1. ptrace POKETEXT/POKEDATA -> procxmt -> suword       (two call sites)
|   2. /proc/<pid> memory writes -> prusrio -> uiomove     (one call site)
|
| Without publication a debugger sets a breakpoint or patches an instruction, the
| store sits in cache, and the target executes the ORIGINAL bytes from RAM -- the
| defect is invisible until someone debugs something.
|
| WHAT.  Two wrappers reached by relocation retargeting (patch_dbgpublish.py), so
| the stock control flow, both ptrace protection branches, and every error path
| stay exactly as they were.
|
| Publication is `cpusha bc` (whole cache), deliberately:
|   * CPUSHL takes a PHYSICAL address on the 040, so a ranged push of a target
|     process's VA would need a walk of ANOTHER address space's tables -- while
|     holding a procfs page mapping.  The whole-cache opcode is non-faulting and
|     keeps that property.
|   * It covers physical aliases and cross-process instruction-cache lines.
|   * These are debugger/control paths, not I/O paths: a four-byte poke or a
|     bounded procfs write, not a per-read cost.  A range optimization is
|     optional AFTER acceptance, never before.
|
| Published even when the call returns an error: an error return does not prove
| that no prefix or crossing bytes changed.  The cache operation moves no data
| and cannot make a failed write worse.
|
| The procfs wrapper gates on direction (UIO_WRITE == 1): the same prusrio body
| serves debugger READS, and a target-to-debugger read creates no user
| instruction bytes.  UIO_READ=0 / UIO_WRITE=1 per <sys/uio.h> and prwrite's
| literal 1.
|
| dbg_publish_on ships 1.  It exists so publication can be A/B'd on hardware
| (kpoke it to 0, re-run, compare) without a rebuild -- the same idiom as
| hat_cm_ram / btrace_on / kdbg_on.  An image shipping 0 is a bisect image and
| must be stamped as such.  Counters are uncapped and free: they are how a boot
| proves the wrappers actually ran, which "it still works" does not.
|
| Wired by patch_dbgpublish.py:
|   0x47eb8  suword  -> dbg_suword_publish     (ptrace, already-writable path)
|   0x47eea  suword  -> dbg_suword_publish     (ptrace, temporarily-writable path)
|   0x64626  uiomove -> dbg_uiomove_publish    (procfs page chunk)
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c dbgpublish040.s -o build/dbgpublish040.o

	.text

| ---------------------------------------------------------------------------
| dbg_suword_publish(addr, value) -- ptrace POKETEXT/POKEDATA.
| Return value is passed through untouched (procxmt feeds it into d2 and a
| nonzero reaches the normal ptrace error exit).
	.globl	dbg_suword_publish
dbg_suword_publish:
	linkw	%fp,&0
	movel	%fp@(12),%sp@-		| value
	movel	%fp@(8),%sp@-		| addr
	jsr	suword
	addqw	&8,%sp
	addql	&1,dbg_ptrace_calls
	tstl	dbg_publish_on
	beqw	Lds_out
	.word	0xf4f8			| cpusha bc -- publish to RAM, invalidate both caches
	addql	&1,dbg_ptrace_publish
Lds_out:
	moveal	%d0,%a0			| SVR4 m68k: a pointer result rides in a0 too
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| dbg_uiomove_publish(kaddr, len, rw, uio) -- /proc/<pid> memory writes.
| rw is arg3 at fp@(16); publish only for UIO_WRITE.
	.globl	dbg_uiomove_publish
dbg_uiomove_publish:
	linkw	%fp,&0
	movel	%fp@(20),%sp@-		| uio
	movel	%fp@(16),%sp@-		| rw
	movel	%fp@(12),%sp@-		| len
	movel	%fp@(8),%sp@-		| kaddr
	jsr	uiomove
	lea	%sp@(16),%sp
	cmpil	&1,%fp@(16)		| UIO_WRITE?
	bnew	Ldu_out			| a read creates no user instruction bytes
	addql	&1,dbg_procfs_calls
	tstl	dbg_publish_on
	beqw	Ldu_out
	.word	0xf4f8			| cpusha bc
	addql	&1,dbg_procfs_publish
Ldu_out:
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
| dbg_publish_on: 1 = publish (the shipped default), 0 = wrappers pass through
| unchanged so the publication can be A/B'd live via /dev/kmem.
	.globl	dbg_publish_on
dbg_publish_on:
	.long	1
	.globl	dbg_ptrace_calls
dbg_ptrace_calls:
	.long	0
	.globl	dbg_ptrace_publish
dbg_ptrace_publish:
	.long	0
	.globl	dbg_procfs_calls
dbg_procfs_calls:
	.long	0
	.globl	dbg_procfs_publish
dbg_procfs_publish:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
