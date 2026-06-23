| getfault040.s -- override get_fault to decode the 68040 format-7 access-error frame.
|
| Stock get_fault (binary, 0x5b49c) extracts the fault address from a 68030 bus-error stack
| frame and handles ONLY formats 0xA (short) and 0xB (long, the 030 page-fault frame).  The
| 68040 pushes a format-0x7 access-error frame instead, so the stock code fell through to its
| "get_fault: Get help!" default and returned -1 (0xFFFFFFFF) -> the page fault could not be
| resolved -> "User BUS ERROR at FFFFFFFF" on proc 1's (init's) very first user instruction.
|
| get_fault(frame) returns the fault address in %d0 (the caller, u_trap, stores it and uses it
| as the page-fault address).  Frame layout, relative to the arg pointer (16 saved regs first,
| then the CPU exception frame at +64):  +64 SR(word)  +66 PC(long)  +70 format&vector(word).
| 040 format 7 (access error): the Fault Address (FA) is at CPU+0x14 = frame+84.
| 030 format B (page fault): frame+100.  030 format A: frame+66 (+4).
|
| This override matches the project's binary-function pattern (--weaken-symbol get_fault); it
| reproduces the stock 030 paths exactly (the SSW bit-8 early-out at +80, the bit-15 "-2" PC
| adjustment) so non-040 frames behave identically, and adds the format-7 case.  get_fault is
| GLOBAL T -> --weaken-symbol get_fault makes u_trap's `jsr get_fault` resolve here.

	.text
	.globl	get_fault
get_fault:
	linkw	%fp,&0
	moveal	%fp@(8),%a0		| a0 = frame
	moveq	&0,%d0
	moveb	%a0@(70),%d0		| high byte of format&vector word
	lsrb	&4,%d0			| d0 = exception frame format nibble (top 4 bits)
	cmpiw	&7,%d0
	bnew	Lgf_030
	movel	%a0@(84),%d0		| 040 format 7: FA at CPU+0x14 = frame+84 -> return it
	braw	Lgf_ret
Lgf_030:
	movel	%a0@(72),%d0		| 030 early-out: SSW (at +72) bit 8 -> fault addr at +80
	andil	&0x100,%d0
	beqw	Lgf_fmt
	movel	%a0@(80),%d0
	braw	Lgf_ret
Lgf_fmt:
	moveq	&0,%d0
	moveb	%a0@(70),%d0
	lsrb	&4,%d0
	cmpiw	&10,%d0			| 0xA: 030 short frame
	bnew	Lgf_notA
	movel	%a0@(66),%d1
	addql	&4,%d1
	braw	Lgf_tail
Lgf_notA:
	cmpiw	&11,%d0			| 0xB: 030 long (page-fault) frame
	bnew	Lgf_unk
	movel	%a0@(100),%d1
	braw	Lgf_tail
Lgf_unk:
	moveq	&-1,%d0			| genuinely unknown format -> -1 (should not occur now)
	braw	Lgf_ret
Lgf_tail:
	movel	%a0@(72),%d0		| 030 SSW bit 15 -> fault PC adjusted by -2, else as-is
	andil	&0x8000,%d0
	bnew	Lgf_sub2
	movel	%d1,%d0
	braw	Lgf_ret
Lgf_sub2:
	movel	%d1,%d0
	subql	&2,%d0
Lgf_ret:
	moveal	%d0,%a0			| stock returns the address in both d0 and a0
	unlk	%fp
	rts
