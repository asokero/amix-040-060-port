| config040.s -- ISSUE-21 fix candidate: config() cache-handoff wrapper (2026-07-22).
|
| _start calls config() as the FIRST kernel C function, BEFORE pstart040.  The
| intermittent real-HW early-boot fault (ILLEGAL@memcpy inside config; ADDRERR@bzero
| in pstart) occurs whenever the 68040 INSTRUCTION cache is ON in this window --
| inherited from AmigaOS (68040.library leaves IC on).  Proven by the CACR/RAMSEY
| dump: cpu nocache (CACR=0) -> 15/15 reboots; IC-only (CACR=0x00008000) -> faults.
| The loader-side copyit CACR=0 does NOT stick to this window (CACR still reads
| 0x00008000 at pstart040 'A' despite a verified fixed loader), so a kernel-side
| fix is used instead.
|
| This wrapper runs at the very start of config (via a relocation retarget of
| _start's single `jsr config`), disables the caches -- cinva ic + CACR=0 -- so
| config's memcpy and pstart's bzero execute cache-off, then tail-calls the real
| config.  pstart040 re-enables the IC at its 'D' step (Step A / the 2x speedup is
| preserved).  Loader-independent (travels in the kernel image, definitely runs).
|
| Why this should stick where the loader did not: cpu nocache sets CACR=0 at the
| AmigaOS level and that value DOES persist to pstart040 'A' (the dump reads 0),
| i.e. nothing in _start/config re-enables the caches (verified: no CACR writer in
| _start/config; the interrupt/exception handlers reload CACR from sup_cacr=0x1019
| = IC-off on the 040).  So a CACR=0 set here, in the kernel, will likewise persist
| through config+pstart until pstart040's 'D'.
|
| Wired: relink assembles this, adds config_orig=.text:0x18f5c, links config040.o,
| and patch_config_cachefix.py retargets _start's `jsr config` reloc (.rela.text
| r_offset 0x26) to config_cachefix.  Other references to the `config` symbols
| (the separate bss data object; any later config() call) are untouched.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c config040.s -o build/config040.o
| 040 ops as .word: cinva ic = 0xf498, movec d0,cacr = 0x4e7b,0x0002,
| movec cacr,d0 = 0x4e7a,0x0002.

	.text
	.globl	config_cachefix
config_cachefix:
	.word	0xf498			| cinva ic  -- drop any stale/inherited IC lines
	moveq	&0,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr -- all caches OFF (IC bit15 + DC bit31)
| --- dbg confirmation (flag-gated: silent in base/quiet): 'K' + CACR read-back ---
	pea	0x4b			| 'K' = config cachefix ran
	jsr	btrace_mark
	addqw	&4,%sp
	.word	0x4e7a,0x0002		| movec %cacr,%d0  (read back; should be 0)
	movel	%d0,%sp@-
	jsr	btrace_hex
	addqw	&4,%sp
| --- tail-call the real config: the stack still holds _start's return address and
|     the pushed args, so config_orig's rts returns straight to _start (transparent).
	jmp	config_orig
	.balign 4			| pad section to a 4-byte multiple (bss placement safety)
