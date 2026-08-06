| isp61neg_asm.s -- the NEGATIVE case for the 68060 vector-61 unit (F2, 2026-08-06).
|
| Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md, "negative test".
|
| The handler emulates exactly ONE form: MUL[SU].L #imm32,Dh:Dl (opword 0x4c3c).
| Every other unimplemented-integer instruction must be DECLINED -- counted in
| isp61_unsupported_n, with no register or CCR touched, and passed to the old
| nullvect path so the process dies exactly as it did before the unit existed.
|
| The instruction below is a REGISTER-source 64-bit multiply:
|
|     MULU.L %d1,%d2:%d0        .word 0x4c01,0x0402
|
|     opword 0x4c01 = 0x4c00 | EA(mode 0 = Dn, reg 1)
|     ext    0x0402: bit15 = 0, bits14-12 = Dl = 0 (%d0), bit11 = 0 (unsigned),
|                    bit10 = 1 (64-bit product), bits2-0 = Dh = 2 (%d2)
|
| This is a legal 68020/68040 instruction that the 68060 does not implement, and it
| is NOT the form the handler decodes.  So on a real 68060 it must:
|     isp61_entry_n        +1   (the handler is entered)
|     isp61_unsupported_n  +1   (and declines, by encoding, not by guess)
|     isp61_ok_n           +0   (nothing was emulated)
|   and the process dies of SIGKILL with a console "vector 0xF4" line.
|
| On a 68040 the hardware executes it and the program prints its result and exits 0.
| That asymmetry is the point: the same binary distinguishes the two CPUs.
|
| C ABI (K&R, stack): isp61_neg(out) -> sp@(4) = out
|     out@(0) = Dh(%d2), out@(4) = Dl(%d0)

	.text
	.globl	isp61_neg
isp61_neg:
	moveml	%d2-%d3,%sp@-
	moveal	%sp@(12),%a0		| a0 = out
	movel	&0xffffffff,%d0		| Dl = 0xffffffff
	moveq	&0,%d2			| Dh = 0
	movel	&2,%d1			| register source = 2
	.word	0x4c01,0x0402		| MULU.L %d1,%d2:%d0  -> 00000001:fffffffe
	movel	%d2,%a0@		| only reached on a 68040
	movel	%d0,%a0@(4)
	moveml	%sp@+,%d2-%d3
	rts
	.balign	4
