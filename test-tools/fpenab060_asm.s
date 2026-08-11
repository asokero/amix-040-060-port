| fpenab060_asm.s -- one ENABLED IEEE exception per entry point, in Motorola's own fixture
| values, for the five classes F3 M4 wired but never exercised (2026-08-11).
|
| WHY THIS EXISTS.  M4 wired vectors 49-54 into the 68060 FPSP.  Exactly one class, SNAN, is
| measured end to end on silicon; the other five rest on the static map.  Motorola's own suite
| cannot close that: its `enabled` group runs all six sub-tests in ONE process, and on a
| signal-delivering Unix the first SIGFPE kills it before the other five run (test.doc, quoted
| in ftest060.c).  So: one child per class, which is the shape fp060probe / ftunimp0 / isp61ea
| already use for exactly this reason.
|
| VALUES ARE MOTOROLA'S, NOT INVENTED.  FPCR enable, FP0 input, the instruction and the expected
| FP0/FPSR/FPIAR all come from dist/ftest.s via the audit in
| amix-kernel-analysis/vm-map/F3-M4-UNMEASURED-CLASSES-AUDIT.md (OVFL ftest.s:885-933,
| UNFL :937-985, INEX :1040-1087, OPERR :1142-1189, DZ :1193-1240).
|
| *** THE ORDER OF THE SNAPSHOT IS LOAD-BEARING ***
| FPIAR is updated by every FP instruction EXCEPT moves to/from the control registers.  So
| `fmovem.x %fp0,mem` -- the obvious way to capture the result -- OVERWRITES the FPIAR we came
| to read.  FPIAR and FPSR are therefore read first, through control-register moves that cannot
| disturb them, and only then FP0.  Getting this backwards would produce a wrong FPIAR on every
| class and look like a kernel defect.
|
| The handler on the C side must be integer-only and must RETURN: execution resumes after the
| faulting instruction (the package advanced the frame PC), and the snapshot below is the first
| thing that runs.  Nothing FP-related may happen in between.
|
| Each entry point:  void fpe_<class>(unsigned long out[5])
|                    out[0..2] = FP0 as three big-endian words, out[3] = FPSR, out[4] = FPIAR
| The instruction's own address is exported as fpe_<class>_insn so the parent can compare FPIAR
| against it rather than against a number typed in twice.

	.text

| ---- shared epilogue: a6@(-12..-1) holds FP0, d2 = FPIAR, d3 = FPSR ----------------------
#define FPE_TAIL			\
	moveal	%a6@(8),%a0		;\
	movel	%a6@(-12),%a0@		;\
	movel	%a6@(-8),%a0@(4)	;\
	movel	%a6@(-4),%a0@(8)	;\
	movel	%d3,%a0@(12)		;\
	movel	%d2,%a0@(16)		;\
	moveml	%sp@+,%d2-%d3		;\
	unlk	%a6			;\
	rts

| ---- shared prologue: zero FPSR/FPIAR, load FP0, arm ONE enable ---------------------------
| The FPCR enable is NOT a macro parameter: cpp turns `#enab` into `# 0x...` and the
| assembler then reads it as a symbol, not a literal.  It is also the one per-class value most
| worth reading on the line itself, so each entry point arms its own.
#define FPE_HEAD(src)			\
	link	%a6,#-16		;\
	moveml	%d2-%d3,%sp@-		;\
	moveq	#0,%d0			;\
	fmovel	%d0,%fpsr		;\
	fmovel	%d0,%fpiar		;\
	fmovemx	src,%fp0

| ---- snapshot: FPIAR, then FPSR, then FP0.  See the header. ------------------------------
#define FPE_SNAP			\
	fmovel	%fpiar,%d2		;\
	fmovel	%fpsr,%d3		;\
	fmovemx	%fp0,%a6@(-12)		;\
	moveq	#0,%d0			;\
	fmovel	%d0,%fpcr

| ============================================================================
| OPERR, vector 52.  -Inf + +Inf.  FPCR 0x2000.  want fp0 = -Inf, FPSR 0x01002080
| ============================================================================
	.globl	fpe_operr
fpe_operr:
	FPE_HEAD(Lin_operr)
	movel	#0x00002000,%d0
	fmovel	%d0,%fpcr		| arm exactly one enable
	.globl	fpe_operr_insn
fpe_operr_insn:
	fadds	#0x7f800000,%fp0	| + Inf
	FPE_SNAP
	FPE_TAIL

| ============================================================================
| OVFL, vector 53.  +2 * max finite extended.  FPCR 0x1000.  want fp0 = +Inf, FPSR 0x02001048
| The vector is non-maskable, so the package is entered either way; the ENABLE is what selects
| _060_real_ovfl over _060_fpsp_done.  That distinction is the whole point of this case.
| ============================================================================
	.globl	fpe_ovfl
fpe_ovfl:
	FPE_HEAD(Lin_two)
	movel	#0x00001000,%d0
	fmovel	%d0,%fpcr		| arm exactly one enable
	.globl	fpe_ovfl_insn
fpe_ovfl_insn:
	fmulx	Lin_ovfl_src,%fp0
	FPE_SNAP
	FPE_TAIL

| ============================================================================
| UNFL, vector 51.  min extended / 2.  FPCR 0x0800.  want FPSR 0x00000800 -- Motorola's
| fixture expects NO accrued bit here, which is worth not "correcting".
| ============================================================================
	.globl	fpe_unfl
fpe_unfl:
	FPE_HEAD(Lin_unfl)
	movel	#0x00000800,%d0
	fmovel	%d0,%fpcr		| arm exactly one enable
	.globl	fpe_unfl_insn
fpe_unfl_insn:
	fdivb	#2,%fp0
	FPE_SNAP
	FPE_TAIL

| ============================================================================
| DZ, vector 50.  +2 / 0.  FPCR 0x0400.  want fp0 unchanged (+2), FPSR 0x02000410
| ============================================================================
	.globl	fpe_dz
fpe_dz:
	FPE_HEAD(Lin_two)
	movel	#0x00000400,%d0
	fmovel	%d0,%fpcr		| arm exactly one enable
	.globl	fpe_dz_insn
fpe_dz_insn:
	fdivb	#0,%fp0
	FPE_SNAP
	FPE_TAIL

| ============================================================================
| INEX, vector 49.  Add 2 to a value whose rounded result is unchanged.  FPCR 0x0200.
| want fp0 unchanged, FPSR 0x00000208.  This is the class the audit flagged as the one to
| think about: it is quiet in normal programs only because its enable is normally clear.
| ============================================================================
	.globl	fpe_inex
fpe_inex:
	FPE_HEAD(Lin_inex)
	movel	#0x00000200,%d0
	fmovel	%d0,%fpcr		| arm exactly one enable
	.globl	fpe_inex_insn
fpe_inex_insn:
	faddb	#2,%fp0
	FPE_SNAP
	FPE_TAIL

| ============================================================================
| SNAN, vector 54 -- the CONTROL.  Already proven on silicon in M4, included so this
| instrument is checked against a known-good class in the same run.
| ============================================================================
	.globl	fpe_snan
fpe_snan:
	FPE_HEAD(Lin_snan)
	movel	#0x00004000,%d0
	fmovel	%d0,%fpcr		| arm exactly one enable
	.globl	fpe_snan_insn
fpe_snan_insn:
	faddb	#2,%fp0
	FPE_SNAP
	FPE_TAIL

	.data
	.balign	4
Lin_two:				| +2.0 extended
	.long	0x40000000,0x80000000,0x00000000
Lin_operr:				| -Inf
	.long	0xffff0000,0x00000000,0x00000000
Lin_unfl:				| smallest extended, per Motorola's fixture
	.long	0x00000000,0x80000000,0x00000000
Lin_inex:				| large enough that adding 2 rounds away
	.long	0x50000000,0x80000000,0x00000000
Lin_snan:				| a SIGNALLING NaN.  The quiet bit is mantissa bit 62 =
					| 0x40000000 in this word: SETTING it makes the NaN QUIET,
					| which is what the first version of this file did -- and a
					| quiet NaN does not signal, so the case measured nothing
					| (f60_vec54_n stayed 0, 2026-08-11).  Integer bit set, quiet
					| bit CLEAR, one mantissa bit set so it is a NaN not an Inf.
	.long	0x7fff0000,0x80000000,0x00000001
Lin_ovfl_src:				| maximum finite extended
	.long	0x7ffe0000,0x80000000,0x00000000
