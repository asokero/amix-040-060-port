| isp61xf_asm.s -- page-crossing instruction fetch for the vector-61 unit (F2, 2026-08-06).
|
| Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md, "page-crossing fetch".
|
| WHAT THIS TESTS.  The handler reads the faulting instruction with ONE 8-byte copyin
| from the exception frame's PC.  That is only safe if the 8 bytes may legally span a
| page boundary -- opword+extension in one page, the 32-bit immediate in the next,
| which is the ordinary case for a 6-in-8-bytes instruction and happens roughly once
| per 512 sites.  If the second page were absent, a handler that read the two halves
| separately, or that assumed one page, would either fetch garbage or fail.  copyin
| resolves the fault; this test makes the case actually occur instead of trusting it.
|
| HOW THE PLACEMENT IS FORCED.  Lxf_base is 4096-aligned by .balign, and the padding
| is computed from the assembler's own location counter, so the multiply lands at
| offset 0xffc of that page no matter how the prologue above it is encoded:
|
|     .space 0xffc - (. - Lxf_base)
|
|     page+0xffc: .word 0x4c3c,0x1400     opword + extension   (page N)
|     page+0x1000: .long 2                the immediate        (page N+1)
|
| THE PADDING IS DATA, NOT CODE, and the branch over it is load-bearing.  The first
| version of this file let execution fall THROUGH the padding.  Zero fill decodes as
| `ori.b #0,%d0` (4 bytes each), the pad length happened to be 2 mod 4, and the stream
| desynchronised: the multiply's own opword was eaten as an immediate operand, giving
| `ori.b #0x3c,%d0` / `move.b %d0,%d2` / `ori.b #2,%d0` -> %d0 = 0x3e.  The test printed
| FAIL with Dh = 0000003e and isp61_entry_n stayed 0 -- the counter is what showed the
| instruction had never trapped at all, i.e. the test was broken, not the kernel.
| The fill is now 0xfcfc (Line-F, an unimplemented instruction) so any future
| desynchronisation dies loudly instead of quietly computing something plausible.
|
| The C side VERIFIES the placement at run time via isp61_xf_addr() and reports SKIP
| rather than PASS if the linker or loader did not honour it.  A test that silently
| stops testing what it is named after is worse than no test.
|
| The case is U1 from isp61test (0xffffffff * 2 = 00000001:fffffffe, CCR 0x10 with X
| preset), so the expected values are already established on both CPUs.
|
| C ABI (K&R, stack): isp61_xf(out, canary) -> sp@(4) = out, sp@(8) = canary
|     out@(0) = Dh(%d0), out@(4) = Dl(%d1), out@(8) = CCR

	.text
	.balign	4096
Lxf_base:

| Returns the address of the multiply, so the C side can check it really is at 0xffc.
	.globl	isp61_xf_addr
isp61_xf_addr:
	lea	Lxf_insn,%a0
	movel	%a0,%d0
	rts

	.globl	isp61_xf
isp61_xf:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0		| a0 = out
	moveal	%sp@(16),%a1		| a1 = canary
	moveq	&16,%d3
	.word	0x44c3			| move %d3,%ccr   -- X = 1, NZVC = 0
	movel	&0xffffffff,%d1		| Dl = multiplicand
	moveq	&0,%d0			| Dh = 0
	braw	Lxf_insn		| jump OVER the padding: it is data, never executed
	.space	0xffc - (. - Lxf_base), 0xfc	| pad to page offset 0xffc; 0xfcfc = Line-F trap
Lxf_insn:
	.word	0x4c3c,0x1400		| MULU.L #2,%d0:%d1   -- opword+ext, last 4 bytes of the page
	.long	2			| the immediate, first 4 bytes of the NEXT page
	.word	0x42c3			| move %ccr,%d3
	addql	&1,%a1@			| canary, the very next instruction
	movel	%d0,%a0@		| Dh
	movel	%d1,%a0@(4)		| Dl
	movel	%d3,%a0@(8)		| CCR
	moveml	%sp@+,%d2-%d3
	rts
	.balign	4
