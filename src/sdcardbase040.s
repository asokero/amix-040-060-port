| sdcardbase040.s -- sdcardbase(card): the physical AutoConfig base sd's init() recorded for a
| card (2026-09-28).
|
| The a4091 driver maps each board's register pages from this (dev_kvmap, NCS) instead of from
| a fixed address, so one queue function can drive whichever board autocon() found.  The stock
| sd.o has no such entry point; the kerntools sd.c template adds one at source level, and this
| is the same answer for a kernel that exists only as a binary.
|
| sd.o keeps one 16-byte record per registered controller in a file-static array: queue
| function at +0, the card's autocon index at +4, the recorded base at +8, the name at +12
| (sdqueue, sdhardwarename and insert all index it with `asl #4`).  The array has no global
| name -- and the kernel has a second, unrelated `queue` -- so the pass that links this file
| (relink-040-a4091.sh, or relink-040-rth1.sh on a base without it) reads its address from the
| relocation sdhardwarename's `lea` carries and exposes it as sd_queue_tbl.
|
| card >= SDCARDS (2) answers 0, as a card autocon() never found does: the driver treats 0 as
| "no board" and maps nothing.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/sdcardbase040.s -o build/sdcardbase040.o
| Linked LAST in its pass: it carries the .balign 4 that closes both sections.

	.text
	.globl	sdcardbase
sdcardbase:
	movel	%sp@(4),%d0		| card
	moveq	&1,%d1			| SDCARDS - 1
	cmpl	%d0,%d1
	bcss	Lsdcb_none		| card > 1 (unsigned): not a slot
	asll	&4,%d0			| 16-byte records
	lea	sd_queue_tbl,%a0
	movel	%a0@(8,%d0:l),%d0	| the recorded base
	moveal	%d0,%a0			| a pointer result, in both registers like the compiled code
	rts
Lsdcb_none:
	clrl	%d0
	subal	%a0,%a0
	rts
	.balign 4			| pad .text to a 4-byte multiple

	.data
	.balign 4			| pad .data likewise
