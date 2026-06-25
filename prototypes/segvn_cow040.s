| segvn_cow040.s -- eager copy-on-write for read faults on writable PRIVATE file
| mappings.  Works around an fs-uae 68040 emulation limitation (see ROOT CAUSE below).
|
| ROOT CAUSE (proven 2026-06-25 via the usrxmemflt entry-trace in wb040.s): fs-uae's
| 68040 core does NOT generate the write-protect access error for the WRITE half of a
| read-modify-write instruction when the READ half already demand-faulted the page in
| read-only.  libc.so.1's _relocate relocates its own GOT with an inline loop of
| `addl %d0,%a0@` (RMW: *slot += base) over all 617 .rela.got entries.  The first such
| store to the file-backed GOT page (C102F000, mapped read-only after the loop's RMW
| READ demand-faulted it in) should fault write-protect -> COW.  On the 030 emulator it
| does (golden boots).  On the 040 emulator the store is silently dropped: NO fault ever
| reaches usrxmemflt (the entry-trace logged only the rw=1 READ at C102FE68, never a
| write), so as_fault never COWs the page -> do_reloc's relocations are lost -> the GOT
| stays raw -> the dynamic linker jsr's an unrelocated slot and exit()s before init runs.
| A plain supervisor `moves`/suword to the SAME page DID fault rw=2 and COW it writable
| (pfn 7CFE RO -> 7CF8 writable) -- only RMW stores are dropped.  (page C1030000 escaped
| because it also holds .bss, whose ZFOD write-fault made the whole 4KB page writable.)
|
| FIX: the kernel can't see the missing write fault, so make the page WRITABLE-PRIVATE at
| the READ fault instead of lazily on the (never-arriving) first write.  Wrap segvn_fault:
| for a READ fault (rw==1) on a uniform-prot, writable, PRIVATE (MAP_PRIVATE) segvn
| segment, pass rw=2 (write) to the original.  That drives the exact COW path the suword
| write already proved maps the page writable-private; the RMW store then lands in-place.
| This is eager instead of lazy COW for writable private file pages -- a few extra private
| copies during boot, semantically identical, and harmless on real 040 hardware.
|
| segvn_fault(seg@8, addr@12, len@16, type@20, rw@24).  seg->segvn_data = *(seg+0x1c).
| segvn_data: +2 pageprot (0 = uniform prot in +3), +3 prot byte (PROT_WRITE = bit 1),
| +5 type (2 = MAP_PRIVATE).  rw: 1 = read, 2 = write (verified from the boot fault log).
| Local 't' -> relink globalizes+weakens it, alias segvn_fault_orig=0xac434.

	.text
	.globl	segvn_fault
segvn_fault:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	%fp@(24),%d2		| d2 = rw
	cmpil	&1,%d2			| read fault?
	bnew	Lsc_call		| no -> pass rw through unchanged
	moveal	%fp@(8),%a2		| seg
	moveal	%a2@(0x1c),%a2		| segvn_data
	tstb	%a2@(2)			| pageprot (0 = uniform prot)?
	bnew	Lsc_call		| per-page prot -> leave it a read fault
	cmpib	&2,%a2@(5)		| type == 2 (MAP_PRIVATE)?
	bnew	Lsc_call		| not private -> leave it a read fault
	btst	&1,%a2@(3)		| prot & PROT_WRITE (bit 1)?
	beqw	Lsc_call		| not writable -> leave it a read fault
	moveq	&2,%d2			| writable private read fault -> force rw = write (eager COW)
Lsc_call:
	movel	%d2,%sp@-		| rw (forced to 2 for the eager-COW case)
	movel	%fp@(20),%sp@-		| type
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| seg
	jsr	segvn_fault_orig
	lea	%sp@(20),%sp		| d0/a0 = segvn_fault_orig's return
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
	nop				| pad .text to keep text/data contiguous (adjust after relink)
