| kdbg040.s -- the base kernel is SILENT: one flag that gates the VM diagnostic
| chatter carried by the genuine-fix objects (2026-07-31).
|
| WHY THIS EXISTS
| The 040 port's real fixes (hat040, hat_dup040, hat_chgprot040, getfault040, ...)
| grew ~29 cmn_err sites while they were being developed.  They were gated by
| counters ("first 8", "every 64th") but never by a flag, so the SHIPPING kernel
| narrates its own VM work on the console: 137 x `hat_dup040 ENTER`, 48 x `ufault`,
| 40 x `ptload`, ... on one ordinary boot.  Three reasons that is not cosmetic:
|
|   1. ISSUE-38.  Instrumentation changes behaviour: assegat_dbg's copyout wrapper
|      carried a `cpusha bc` that masked a copyback boot failure for days.  Console
|      output changes timing and cache footprint the same way, so a kernel that
|      prints is a different kernel from one that does not -- which is exactly why
|      this change is its own unit with its own acceptance, not a tidy-up ridden
|      along with something else.
|   2. Cost.  cmn_err -> STREAMS console log -> screen rendering is expensive at
|      25 MHz, and `hat_dup040 ENTER` fires forever (every 64th fork), so the cost
|      grows with uptime.
|   3. The console is the LAST diagnostic channel.  ISSUE-38 was solved from a
|      photograph of the console of a kernel that could not reach telnet.  Noise
|      there costs the signal exactly when there is nothing else left.
|
| WHAT IS GATED, AND WHAT IS NOT.  Classified by what a HEALTHY boot actually does
| (measured over test-tools/issue22-serial45-260728.log, 1835 lines):
|
|   GATED (fires on a healthy boot = narration of normal work):
|     hat040        segmap-map, GOTmap, ptload, ptload2, hat_pteload Lballoc leaf,
|                   hat_unload, htunload FREELEAF, hat_alloc ENTER x2, hat_free ENTER
|     hat_dup040    ENTER, first private-page copy
|     hat_chgprot040 ENTER
|     getfault040   ufault VA
|
|   NOT GATED (never fires on a healthy boot = a real warning, and its silence is
|   what makes it worth reading):
|     hat_unlock invalid sde, hat_unload/hat_free pte not in revmap, hatfree
|     BAD-slot, hat_ptfree LEAK, vtop pool, VTOPALIAS, vtop KERNVA-WITH-PROC,
|     wb040 replay UNRESOLVED, krnxflt FAILEXIT, segkmem_setprot invalid segment.
|
|   COUNTED AND GATED -- the two that made this unit worth doing.  Both are
|   anomaly-shaped, both fire on EVERY healthy boot, and both were capped at 8
|   prints, so nobody has ever known their true rate:
|     hat_pfnmiss_n   hat_pteload found a live leaf PTE naming a DIFFERENT pfn and
|                     overwrote it (this is ISSUE-10's chain; the revmap fix at that
|                     site is what stops it being fatal).
|                     ATTRIBUTED 2026-07-31, one variable at a time on real hardware:
|                     ~10 events during boot, then EXACTLY +2 per devmaptest run
|                     (12 -> 14 -> 16, deterministic).  wolf3d, an X session with
|                     clients, native compiles and two full 16-burst suites
|                     (570 000+ page releases) each moved it by ZERO.  So in normal
|                     operation this is not a stale-PTE anomaly at all: it is the
|                     legitimate case of a DEVICE mapping replacing a managed page's
|                     leaf PTE, which is exactly what /dev/mem mmap does.
|     hat_badaslot_n  hat_free skipped an A region whose pointer-table base failed
|                     the V3 guard -- i.e. page tables deliberately NOT freed
|                     ("bounded leak").  Observed A=4 Adesc=400003 and A=6
|                     Adesc=3F0003 on every boot.
|   The counters are UNCAPPED and free (one memory increment), so the next boot
|   answers with a number what the print cap has been hiding: a small constant per
|   boot means the kernel's own shared tables and the wording is simply wrong; a
|   number that grows with uptime or with process count means a real leak.
|   Read them with kpeek (0x08000000 + textsize + .data offset).
|
| MECHANISM.  kdbg_on ships 0, so the base and quiet kernels are silent; the DBG
| build sets it to 1 (patch_btrace_on.py, which flips both this and btrace_on), and
| it can be poked live through /dev/kmem to turn the chatter on in a shipping
| kernel without a rebuild.  Each gated site is two instructions -- `tstl kdbg_on`
| plus a branch to the site's existing skip label -- and `tstl` on memory touches
| no register, only the condition codes, so no site's register discipline changes.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c kdbg040.s -o build/kdbg040.o

	.text
| ---------------------------------------------------------------------------
| ISSUE-39 (2026-07-31): hat_sdtalloc's "not enough contiguous memory for segment
| tables" warning is a real event that was only ever visible as console text --
| and a base image has no serial hook, so unless a human happened to be watching
| the screen it left no trace at all.  It was first seen during the 16-burst
| acceptance run, where it damaged nothing (96/96 verified byte-exact).
|
| This island counts it and then tail-jumps into cmn_err, so the warning still
| prints exactly as before and hat_sdtalloc's stack, arguments and return path are
| untouched.  patch_sdtfail.py retargets the single cmn_err relocation @0xb64b2
| (the call whose format string is LC%9 @0xb6297) to here.
|
| Reading it: a nonzero hat_sdtfail_n means the machine ran out of contiguous
| memory for a page-table allocation at least that many times.  Compare it across
| a burst run to turn "the machine feels like it is under pressure" -- the standing
| guess behind the b2repro stalls and the amixadm intermittent -- into a number.
| MOVED 2026-08-01: the body now lives in issue39_040.s, which does the same
| increment and additionally latches freemem/availrmem/deficit at the failure --
| the characterisation ISSUE-39 was waiting for.  hat_sdtfail_n stays here with
| the other kdbg counters, and patch_sdtfail.py is unchanged (same symbol name).

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
| kdbg_on: 0 = silent (base/quiet default), nonzero = emit the gated VM chatter.
| A long so a single aligned store (patcher or /dev/kmem poke) flips it; every
| gate reads it with `tstl`, so any nonzero value enables.
	.globl	kdbg_on
kdbg_on:
	.long	0
| Uncapped event counters for the two anomaly-shaped sites that fire on every
| healthy boot.  These count REGARDLESS of kdbg_on -- the point is the rate, and a
| counter costs one increment whether or not anyone is printing.
	.globl	hat_pfnmiss_n
hat_pfnmiss_n:
	.long	0
	.globl	hat_badaslot_n
hat_badaslot_n:
	.long	0
| ISSUE-39: hat_sdtalloc could not get contiguous memory for segment tables.
	.globl	hat_sdtfail_n
hat_sdtfail_n:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
