| inituname040.s -- tag utsname.machine with the 68040 build id.
|
| Wrapper over the kernel's inituname (0x49140).  The stock inituname sets the
| utsname fields at boot: sysname/nodename/release/version, and builds
| machine = "Amiga (Unlimited)" (static utsname.machine = "Amiga" + a runtime
| strcpy of " (Unlimited)"/" (Limited)").  This wrapper calls the original, then
| appends " 68040-<buildid>" to the machine field, so the boot banner (which
| prints utsname.machine) and `uname -a` / `uname -m` identify the exact CPU
| build under test.  <buildid> is stamped post-link by stamp_buildid.py into the
| `buildid` string below (per-day counter, format YYMMDD-NN).
|
| Wired by relink-040*.sh:
|   --weaken-symbol inituname  --add-symbol inituname_orig=.text:0x49140,function,global
| and inituname040.o added to the ld -r object list; then stamp_buildid.py runs.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c inituname040.s -o build/inituname040.o
| inituname takes no args and returns the utsname pointer in a0/d0 like the
| original; main() ignores the return, so we simply preserve the original's.

	.set	UTS_MACHINE, 0x404	| utsname.machine = 4 * SYS_NMLN (SYS_NMLN = 257)

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
	.globl	inituname
inituname:
	jsr	inituname_orig		| stock setup: machine = "Amiga (Unlimited)"
	movel	&utsname+UTS_MACHINE,%a0	| a0 -> utsname.machine
Liu_end:
	tstb	%a0@+
	bnew	Liu_end			| walk to one past the terminating NUL
	subql	&1,%a0			| a0 -> the NUL
	lea	buildid,%a1
Liu_cpy:
	moveb	%a1@+,%a0@+
	bnew	Liu_cpy			| append " 68040-..." including its NUL
	rts
	nop				| pad .text to a 4-byte multiple (36 bytes)

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
	.globl	buildid
buildid:
	.asciz	" 68040-000000-00"	| 16 chars + NUL; stamped post-link
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
