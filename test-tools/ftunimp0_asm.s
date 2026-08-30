| ftunimp0_asm.s -- replicate Motorola ftest's unimp_0 sub-test EXACTLY, including the parts
| that make it "fail", and report what actually happened (F3 M2b, 2026-08-08).
|
| CROSS-BUILD ONLY: this is GNU assembler syntax (`#` immediates).  The guest's native
| /usr/ccs/bin/as rejects it ("invalid instruction name") -- that is a toolchain mismatch, not a
| result.  Assemble with the m68k-cbm-sysv4 cross toolchain on the host; see ftunimp0.c's header.
|
| WHY.  Motorola's own FP-unimplemented suite prints "1 failed" on our kernel, and its
| chk_test tells you the sub-test number and nothing else.  Sub-test 1 is unimp_0
| (dist/ftest.s:245), which is one instruction:
|
|     DATA = 0x40000000 c90fdaa2 2168c235       (extended pi)
|     fsin.x DATA(%a6),%fp0
|
| The test then requires ALL of:
|     fp0    = 0xbfbf0000 80000000 00000000     (about -2^-64: sin of the extended pi)
|     FPSR   = 0x08000208                       (N set; INEX2 set; accrued INX set)
|     FPIAR  = the address of the fsin
|     FPCR, CCR, fp1-fp7 and d0-d7/a0-a6 all UNCHANGED across the trap
| and reports one undifferentiated "failed" if any of them is wrong.  Those implicate very
| different things -- a wrong fp0 is the emulation, a wrong FPSR/FPIAR is the package's state
| handling, a clobbered register is OUR call-out glue -- so this unit snapshots the whole
| machine before and after and lets the C side name the field.
|
| Structure copied from Motorola's: every snapshot is a6-relative, so taking it costs no
| register and cannot itself perturb what is being measured.  The out[] pointer lives in the
| frame for the same reason.
|
| Plain user-mode program.  The FPSP under test is the kernel's, on vector 11.

	.text

	FTU_DATA  = -512		| 16: the extended source operand (12 used)
	FTU_IREGS = -496		| 60: d0-d7/a0-a6 before
	FTU_SREGS = -436		| 60: d0-d7/a0-a6 after
	FTU_IFP   = -376		| 96: fp0-fp7 before
	FTU_SFP   = -280		| 96: fp0-fp7 after
	FTU_IFPC  = -184		| 12: fpcr/fpsr/fpiar before
	FTU_SFPC  = -172		| 12: fpcr/fpsr/fpiar after
	FTU_ICCR  = -160		|  4: CCR before (word in the low half)
	FTU_SCCR  = -156		|  4: CCR after
	FTU_OUTP  = -152		|  4: caller's out[]
	FTU_PCV   = -148		|  4: address of the fsin
	FTU_NLONG = 92			| (FTU_PCV + 4 - FTU_DATA) / 4

	.globl	ftunimp0_run
| void ftunimp0_run(unsigned long *out)   -- out must hold FTU_NLONG longs
ftunimp0_run:
	link	%a6,#-512
	moveml	%d2-%d7/%a2-%a5,%sp@-
	movel	%a6@(8),%a6@(FTU_OUTP)

	movel	#0x40000000,%a6@(FTU_DATA)	| Motorola's DATA, byte for byte
	movel	#0xc90fdaa2,%a6@(FTU_DATA+4)
	movel	#0x2168c235,%a6@(FTU_DATA+8)

	clrl	%a6@(FTU_ICCR)			| both CCR slots zeroed while it is still
	clrl	%a6@(FTU_SCCR)			| legal to disturb the flags

	moveq	#0,%d0				| DEF_FPCREGS: fpcr = fpsr = fpiar = 0
	fmovel	%d0,%fpcr
	fmovel	%d0,%fpsr
	fmovel	%d0,%fpiar
	fmovemx	Lftu_deffp,%fp0-%fp7		| all eight FP registers to known normals

	moveml	Lftu_def,%d0-%d7/%a0-%a5	| markers LAST, so nothing below disturbs them

	moveml	%d0-%fp,%a6@(FTU_IREGS)		| 15 longs: d0-d7/a0-a6
	fmovemx	%fp0-%fp7,%a6@(FTU_IFP)
	fmoveml	%fpcr/%fpsr/%fpiar,%a6@(FTU_IFPC)

	movew	#0,%ccr
Lftu_pc:
	fsinx	%a6@(FTU_DATA),%fp0		| <- the whole test

	movew	%ccr,%a6@(FTU_SCCR+2)		| CCR first: everything below disturbs it
	moveml	%d0-%fp,%a6@(FTU_SREGS)
	fmovemx	%fp0-%fp7,%a6@(FTU_SFP)
	fmoveml	%fpcr/%fpsr/%fpiar,%a6@(FTU_SFPC)

	lea	Lftu_pc,%a0
	movel	%a0,%a6@(FTU_PCV)

| ---- copy the whole block out.  Registers are already snapshotted, so clobbering them here
|      is free.
	moveal	%a6@(FTU_OUTP),%a1
	lea	%a6@(FTU_DATA),%a0
	moveq	#FTU_NLONG,%d0
Lftu_copy:
	movel	%a0@+,%a1@+
	subql	#1,%d0
	bnes	Lftu_copy

	moveml	%sp@+,%d2-%d7/%a2-%a5
	unlk	%a6
	rts

	.balign	4
| d0-d7 then a0-a5.  a6 is the frame pointer and a7 the stack, so neither is a marker; both
| are still compared, because a call-out that unbalanced the stack would show up there.
Lftu_def:
	.long	0x00000000, 0x11111111, 0x22222222, 0x33333333
	.long	0x44444444, 0x55555555, 0x66666666, 0x77777777
	.long	0x88888888, 0x99999999, 0xaaaaaaaa, 0xbbbbbbbb
	.long	0xcccccccc, 0xdddddddd
| Motorola's own DEF_FPREGS (dist/ftest.s:1436), byte for byte: eight copies of the extended
| NaN 0x7fff0000 ffffffff ffffffff.  Using their value rather than a convenient one is the
| whole point -- fp1-fp7 have to survive the trap unchanged, and a NaN with an all-ones
| payload is a far harsher round-trip test of the package's fmovem save/restore (and of an
| emulator's FPU representation) than 1.0 would be.
Lftu_deffp:
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.long	0x7fff0000, 0xffffffff, 0xffffffff
	.balign	4
