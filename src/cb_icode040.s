| cb_icode040.s -- ISSUE-38 fix: publish main()'s icode copyout to RAM so the
| 68040 INSTRUCTION FETCH can see it under copyback (2026-07-30).
|
| WHY (measured, not inferred):
| main+0x1e8 does  copyout(icode, 0x80800000, szicode)  -- the kernel CPU writes
| proc 1's bootstrap text into a fresh user page, and _start then rte's proc 1
| to user mode at 0x80800000, where it runs `lea stack,sp; moveq #11,d0; trap #0`
| = exec("/sbin/init").  On the 68040 the data cache is NOT snooped by the
| instruction fetch (M68040UM: software must push dirty data before it is
| executed).  With hat_cm_ram=0x00 (write-through) the icode is in RAM the moment
| copyout returns, so this never mattered.  With hat_cm_ram=0x20 (copyback) the
| icode exists ONLY as dirty data-cache lines: the ifetch reads the still-zero
| RAM page, executes 0x00000000 as a harmless `ori.b #0,%d0` about a thousand
| times, runs off the end of the 4 KiB page into the UNMAPPED 0x80801000, and
| proc 1 dies of SIGSEGV before exec is ever entered.  AMIX icode has no other
| exit, so proc 1 becomes a zombie and swtch's delayed cleanup calls
| segu_release -> the terminal console line
|   WARNING: DBG hat_unload va=48442000 size=2000 flags=A
| which is the u-area slot being reclaimed, NOT an exec-header release.
|
| EVIDENCE (all six ISSUE-38 rows are explained by this one mechanism):
|   * bisect D's console (photo 2026-07-29 20:59) shows `ufault VA=80801000`
|     TWICE right after the icode page is faulted in, then the address-space
|     teardown; the two booting captures (issue22-serial36/45-260728.log) never
|     fault at 0x80801000 at all -- and there main's copyout returns 0, i.e. the
|     bytes WERE copied.  Copied but not fetchable = a cache-visibility defect.
|   * `-04` (write-through) boots, `-07` (the same image with hat_cm_ram=0x20)
|     hangs: a two-byte A/B.
|   * it boots in Amiberry, which does not model the 040 copyback data cache.
|   * the masking object of the E-minus-D bisect is assegat_dbg.s, whose copyout
|     wrapper executes an UNCONDITIONAL `cpusha bc` (.word 0xf4f8) immediately
|     after copyout_orig -- the masker is literally this cache push, not chatter
|     and not timing.  hatalloc_dbg prints far more and masks nothing, because it
|     has no cache op between copyout and proc 1's first ifetch.
|
| WHAT THIS DOES: wrap copyout; when the destination is the icode page, push the
| caches after a successful copy.  `cpusha bc` (push all dirty data lines, then
| invalidate both caches) is used deliberately:
|   * CPUSHL takes a PHYSICAL address on the 040 (see cb_release040.s, which has
|     to convert pfn<<12 first), so a ranged push of a USER VA would need a
|     page-table walk here.  This site runs once per boot; the whole-cache form
|     is address-free and is the form already proven on hardware by assegat_dbg
|     (bisect E boots; the 72-min copyback acceptance ran on an image carrying
|     it, at the measured +63 %).
|   * BC, not DC: the physical page may be recycled from a previous text page
|     whose lines are still valid in the instruction cache, so the IC has to be
|     invalidated too.
|
| WHY GATED and not "after every copyout": copyout is on every read(2)-style
| return path, and a whole-cache push+invalidate there would throw away exactly
| the copyback win being landed.  The icode page is the ONLY user TEXT the kernel
| CPU writes in this port -- all other user text arrives via page-in DMA (whose
| prepare/complete hooks already maintain coherency) -- so the gate is the
| mechanism's real scope, not a shortcut.
| KNOWN RESIDUAL (deliberate, tracked in KNOWN-ISSUES): ptrace/adb text pokes
| (PTRACE POKETEXT) write user text through copyout as well and are NOT covered
| by this gate; a general fix needs the VA->phys walk described above.  That is a
| separate unit and must not ride along with the ISSUE-38 A/B.
|
| Register contract: copyout returns in d0 and d0 is NOT touched after
| copyout_orig returns -- the gate uses d1 (scratch under this ABI) and the two
| counters are memory increments, so the wrapper is return-value transparent.
| Counters (read afterwards with kpeek; the mechanism must be VERIFIED, not
| assumed from "it booted"): cb_icode_calls = copyouts into the icode window,
| cb_icode_push = pushes actually performed.  Both must read 1 after a boot.
|
| Mechanism: --weaken-symbol copyout + --add-symbol copyout_orig=.text:0x576.
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c cb_icode040.s -o build/cb_icode040.o

	.text
	.globl	copyout
copyout:
	linkw	%fp,&0
	movel	%fp@(16),%sp@-		| count
	movel	%fp@(12),%sp@-		| to   = user VA
	movel	%fp@(8),%sp@-		| from = kernel VA
	jsr	copyout_orig
	lea	%sp@(12),%sp		| d0 = copyout's return value from here on
	movel	%fp@(12),%d1		| d1 = to
	cmpil	&0x80800000,%d1
	bcsw	Lcbi_out		| below the icode page (unsigned)
	cmpil	&0x80801000,%d1
	bccw	Lcbi_out		| at/above the next page
	addql	&1,cb_icode_calls
	tstl	%d0
	bnew	Lcbi_out		| copyout failed -> nothing to publish
	.word	0xf4f8			| cpusha bc -- push dirty data lines to RAM,
					|   invalidate both caches, so proc 1's
					|   instruction fetch sees the icode
	addql	&1,cb_icode_push
Lcbi_out:
	unlk	%fp
	rts
	nop

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
	.globl	cb_icode_calls
cb_icode_calls:
	.long	0
	.globl	cb_icode_push
cb_icode_push:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
