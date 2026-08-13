| issue39_040.s -- ISSUE-39 characterisation: make the kernel's memory state
| READABLE from userland, and latch it at the moment hat_sdtalloc fails
| (2026-08-01).
|
| WHY A POINTER TABLE.  freemem, availrmem, deficit, physmem, maxmem, availsmem
| and nscan are all COMMON symbols in the ET_REL kernel image, so nm reports
| their SIZE, not an address (`00000004 C freemem`), and the AMIX loader
| (rel.c) is what finally places them in .bss at load time.  There is therefore
| no address to compute the way counter addresses are computed
| (kernel_base + textsize + .data offset) -- which is why every previous session
| could count hat_sdtalloc failures but never say what the memory looked like
| when they happened.
|
| The fix is one line of assembler per global: a .data long INITIALISED TO THE
| SYMBOL.  That is a relocation, so the loader writes the final runtime address
| into the long as part of loading the kernel.  kpeek then reads
| i39_freemem_p at a computable .data address, gets the runtime address of
| freemem, and reads that.  Two reads, no new syscall, no cost, and it
| generalises to any COMMON global this port ever needs to watch.
|
| WHAT IS LATCHED.  hat_sdtfail_count already counted the "not enough
| contiguous memory for segment tables" warning (kdbg040.s + patch_sdtfail.py).
| It now also records the memory state at the FIRST and the LAST failure. First
| and last, not a ring buffer: the open question is which regime the failure
| lives in, and two samples plus the free-running counter answer that without
| putting a buffer index on a path that runs while memory is already short.
|
| The wrapper still tail-jumps into cmn_err with the stack untouched, so the
| warning prints exactly as before.  It clobbers only d0/d1, which are caller-
| saved scratch under this ABI, so nothing is saved or restored.
|
| Sampling ACROSS a run (the other half of the characterisation) is userland:
| test-tools/memwatch.c polls these same addresses through /dev/mem while the
| burst suite runs, and reports the low-water mark.  The kernel side deliberately
| does NOT track a running minimum -- that would need a compare-and-store on a
| hot path, and this kernel's copyback numbers were measured without one.
|
| hat_sdtfail_count MOVES HERE from kdbg040.s (the counter hat_sdtfail_n stays
| there, where the other kdbg counters live).  patch_sdtfail.py is unchanged: it
| retargets the same relocation to the same symbol name.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c issue39_040.s -o build/issue39_040.o

	.text

| hat_sdtfail_count -- reached by patch_sdtfail.py retargeting hat_sdtalloc's
| single cmn_err relocation @0xb64b2.
	.globl	hat_sdtfail_count
hat_sdtfail_count:
	addql	&1,hat_sdtfail_n
	movel	freemem,%d0
	movel	availrmem,%d1
	movel	%d0,i39_fail_freemem_last
	movel	%d1,i39_fail_availrmem_last
	tstl	i39_fail_n
	bnew	L39_notfirst		| keep the FIRST failure's numbers intact
	movel	%d0,i39_fail_freemem
	movel	%d1,i39_fail_availrmem
	movel	deficit,%d0
	movel	%d0,i39_fail_deficit
L39_notfirst:
	addql	&1,i39_fail_n
	jmp	cmn_err			| print exactly as before; args/stack untouched
	nop

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even

| ------------------------------------------------------------------ pointers
| Each of these is a RELOCATION the loader resolves: after load, the long holds
| the runtime address of the COMMON global named in the comment.  Read the long
| with kpeek, then read what it points at.  i39_magic is the anchor -- if it
| does not read back as 0x49333921 ("I39!") the .data addresses are stale and
| nothing else on the line means anything (the rule that caught a stale read on
| the first line of 2026-07-31).
	.globl	i39_magic
i39_magic:
	.long	0x49333921		| "I39!"
	.globl	i39_freemem_p
i39_freemem_p:
	.long	freemem
	.globl	i39_availrmem_p
i39_availrmem_p:
	.long	availrmem
	.globl	i39_availsmem_p
i39_availsmem_p:
	.long	availsmem
	.globl	i39_deficit_p
i39_deficit_p:
	.long	deficit
	.globl	i39_physmem_p
i39_physmem_p:
	.long	physmem
	.globl	i39_maxmem_p
i39_maxmem_p:
	.long	maxmem
	.globl	i39_nscan_p
i39_nscan_p:
	.long	nscan

| -------------------------------------------------------------- failure latch
| i39_fail_n counts the same events as hat_sdtfail_n; it is separate so that the
| "is this the first failure" test cannot be disturbed by anything else that
| might later touch hat_sdtfail_n.
	.globl	i39_fail_n
i39_fail_n:
	.long	0
	.globl	i39_fail_freemem
i39_fail_freemem:
	.long	0
	.globl	i39_fail_availrmem
i39_fail_availrmem:
	.long	0
	.globl	i39_fail_deficit
i39_fail_deficit:
	.long	0
	.globl	i39_fail_freemem_last
i39_fail_freemem_last:
	.long	0
	.globl	i39_fail_availrmem_last
i39_fail_availrmem_last:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
