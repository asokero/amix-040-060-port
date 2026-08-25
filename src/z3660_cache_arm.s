| z3660_cache_arm.s -- give z3660_cache a .data home so the cache arm can be selected
| at link time, in THIS repository, without editing the driver.
|
| THE PROBLEM.  amix-z3660scsi/src/z3660.c:320 declares
|
|     long	z3660_cache;		/* 0 = off (default), 40 = 68040 DC, 60 = 68060 DC */
|
| which is a C tentative definition, so the compiled object carries it as a COMMON
| symbol.  A common has no file storage: the loader allocates it in bss and zeroes it.
| There is therefore NO byte in the linked kernel to poke, and the 2026-08-25 attempt-3
| record says so in as many words -- "z3660_cache is a COMMON symbol zeroed into bss, so
| no file patch reaches it".  That is why arm B has never been reachable except through
| /dev/kmem, i.e. only from a multiuser system, i.e. never from the boot that is failing.
|
| THE FIX, and why it is legitimate.  A defined symbol beats a common: linking this
| object absorbs the driver's common into this .data definition, and every reference in
| the driver relocates here instead.  The driver source is not touched, and neither is
| its repository.  With the value left at 0 this is behaviourally identical to the
| common it replaces -- the driver reads 0 either way -- so the CONTROL build and the
| arm-B build differ by exactly one word, which src/patch_z3660_cache.py stamps.
|
| DELIBERATELY NOT INCLUDED: z3660eth_cache.  The ethernet driver's arm is a separate
| question with its own predicted PASS, and mixing the two would make the SCSI answer
| a two-variable one.  It stays common, stays 0.
|
| The block is laid out magic / value / witness so one read of three words off the
| firmware console proves both that the address is right and that the stamp took.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c z3660_cache_arm.s

	.data
	.globl	zc_magic
zc_magic:
	.long	0x5a434121		| 'ZCA!' -- read this FIRST
	.globl	z3660_cache
z3660_cache:
	.long	0			| 0 = arm A (shipping default); 40/60 = arm B
	.globl	zc_armed
zc_armed:
	.long	0			| stamped to the same value; a witness, not a knob
	.balign	4			| pad .data to a 4-byte multiple
