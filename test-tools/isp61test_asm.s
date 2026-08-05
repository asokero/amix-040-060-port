| isp61test_asm.s -- the five raw vector-61 multiplies for isp61test.c (F2, 2026-08-06).
|
| WHY A SEPARATE .s FILE.  gcc 2.7.2.3's inline assembler runs the template through its
| MIT->Motorola opcode translator as soon as the asm block has operands, which silently
| mangles mnemonics (`movel` -> `movl`, `moveq` -> `mov`) and then fails to assemble.  A
| standalone .s file is assembled verbatim, exactly like every prototypes/*.s in this tree,
| so the encodings below are the encodings that execute.
|
| Every multiply is emitted as raw words so no toolchain decision can change the requested
| form -- that is the entire point of the test:
|     .word 0x4c3c,<ext>    opword = long multiply, immediate source
|     .long <imm>           the 32-bit immediate
| Extension layout: bit15 = 0, bits14-12 = Dl, bit11 = signed, bit10 = size(1 = 64-bit),
| bits9-3 = 0, bits2-0 = Dh.
|
| Each routine: preset CCR to 0x10 (X set, NZVC clear), load the multiplicand into Dl,
| clear Dh, run the multiply, snapshot CCR IMMEDIATELY, then bump the canary with the very
| next instruction.  The canary must end at exactly 1 -- 0 means the handler never resumed,
| more than 1 means it restarted the instruction.
|
| C ABI (K&R, stack): fn(out, canary)  ->  sp@(4) = out, sp@(8) = canary
|     out@(0) = Dh, out@(4) = Dl, out@(8) = CCR (low byte meaningful)
| d2/d3 are callee-saved in this ABI, so they are preserved around the body.

	.text

| ---- U1: ext 0x1400 -> Dl=d1, Dh=d0, unsigned.  0xffffffff * 2 = 00000001:fffffffe ----
	.globl	isp61_u1
isp61_u1:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0		| a0 = out
	moveal	%sp@(16),%a1		| a1 = canary
	moveq	&16,%d3
	.word	0x44c3			| move %d3,%ccr   -- X = 1, NZVC = 0
	movel	&0xffffffff,%d1		| Dl = multiplicand
	moveq	&0,%d0			| Dh = 0 (so a handler that never writes it shows)
	.word	0x4c3c,0x1400
	.long	2
	.word	0x42c3			| move %ccr,%d3   -- snapshot before anything else
	addql	&1,%a1@			| canary, the very next instruction
	movel	%d0,%a0@		| Dh
	movel	%d1,%a0@(4)		| Dl
	movel	%d3,%a0@(8)		| CCR
	moveml	%sp@+,%d2-%d3
	rts

| ---- U2: ext 0x0401 -> Dl=d0, Dh=d1, unsigned.  0xffffffff^2 = fffffffe:00000001 ----
	.globl	isp61_u2
isp61_u2:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0
	moveal	%sp@(16),%a1
	moveq	&16,%d3
	.word	0x44c3
	movel	&0xffffffff,%d0		| Dl = d0 here
	moveq	&0,%d1			| Dh = d1
	.word	0x4c3c,0x0401
	.long	0xffffffff
	.word	0x42c3
	addql	&1,%a1@
	movel	%d1,%a0@		| Dh
	movel	%d0,%a0@(4)		| Dl
	movel	%d3,%a0@(8)
	moveml	%sp@+,%d2-%d3
	rts

| ---- UZ: ext 0x2400 -> Dl=d2, Dh=d0, unsigned.  0x12345678 * 0 = 0 -> Z set ----
	.globl	isp61_uz
isp61_uz:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0
	moveal	%sp@(16),%a1
	moveq	&16,%d3
	.word	0x44c3
	movel	&0x12345678,%d2		| Dl = d2
	moveq	&0,%d0			| Dh = d0
	.word	0x4c3c,0x2400
	.long	0
	.word	0x42c3
	addql	&1,%a1@
	movel	%d0,%a0@
	movel	%d2,%a0@(4)
	movel	%d3,%a0@(8)
	moveml	%sp@+,%d2-%d3
	rts

| ---- S1: ext 0x2c01 -> Dl=d2, Dh=d1, signed.  -3 * 7 = ffffffff:ffffffeb ----
	.globl	isp61_s1
isp61_s1:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0
	moveal	%sp@(16),%a1
	moveq	&16,%d3
	.word	0x44c3
	moveq	&-3,%d2			| Dl = d2 = -3
	moveq	&0,%d1			| Dh = d1
	.word	0x4c3c,0x2c01
	.long	7
	.word	0x42c3
	addql	&1,%a1@
	movel	%d1,%a0@
	movel	%d2,%a0@(4)
	movel	%d3,%a0@(8)
	moveml	%sp@+,%d2-%d3
	rts

| ---- S2: ext 0x1c02 -> Dl=d1, Dh=d2, signed.  0x80000000 * -1 = 00000000:80000000 ----
| THE LOAD-BEARING CASE: N must be CLEAR here, because N comes from bit 63 of the product,
| not bit 31.  A handler taking N from the low longword passes the other four and fails this.
	.globl	isp61_s2
isp61_s2:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0
	moveal	%sp@(16),%a1
	moveq	&16,%d3
	.word	0x44c3
	movel	&0x80000000,%d1		| Dl = d1
	moveq	&0,%d2			| Dh = d2
	.word	0x4c3c,0x1c02
	.long	0xffffffff
	.word	0x42c3
	addql	&1,%a1@
	movel	%d2,%a0@
	movel	%d1,%a0@(4)
	movel	%d3,%a0@(8)
	moveml	%sp@+,%d2-%d3
	rts
	.balign	4
