| isp61_060.s -- 68060 vector 61 (unimplemented integer) support, bounded to the ONE
| instruction form the installed userland actually uses (F2, 2026-08-06).
|
| WHY THIS EXISTS, AND WHY IT IS THIS SMALL.  On real 68060 hardware the guest's gcc dies
| instantly and the console names the mechanism itself:
|     SIGKILL sent to pid 263 (.../2.7.2.3/cpp ...) because of vector 0xF4, pc=0x80006ED6
|     SIGKILL sent to pid 2046 (.../2.7.2.3/cc1 ...) because of vector 0xF4, pc=0x80021530
| 0xF4/4 = 61, and both PCs disassemble byte-exact to a 64-bit MULS.L/MULU.L
| (060-F0-MEASUREMENT-260805.md).  An encoding-based scan of the installed binaries
| (test-tools/scan060.py) then bounded the problem:
|     cpp 2 hits, cc1 101 hits, libc.so.1 / ld.so.1 / as / ld ZERO
|     all 103 are the IMMEDIATE form  mulsl/mulul #imm32,Dh:Dl   (68 unsigned, 35 signed)
|     zero 64-bit divides, zero CMP2/CHK2/CAS2
| So one addressing mode covers the entire installed compiler.  Motorola's full 060SP ISP
| remains the general answer; this unit is the measured subset, and everything outside it
| takes a COUNTED, state-preserving fallback to the existing nullvect/SIGKILL path.  It is
| never partly decoded and never silently approximated.
|
| Specification: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md (Codex, 2026-08-06),
| whose five-case product/CCR matrix was recomputed independently before this was written.
|
| FRAME (verified against nullvect's own disassembly, which does btst #5,%sp@(60)):
| vector 61 pushes an 8-byte format-0 frame; after the 60-byte D0-D7/A0-A6 save the raw
| fields sit at
|     base+60  original SR        base+62  faulting PC        base+66  format/vector = 0x00F4
| The frame carries NO instruction bytes, so the opword/extension/immediate must be fetched
| from user space -- with ONE 8-byte copyin, never a supervisor load through the user PC.
| One call also means the existing user-copy path owns function codes, nofault handling and
| a possible page crossing between the extension and the immediate.
|
| TRANSACTIONAL RULE: nothing that can fail may run after the first commit.  Every decline
| path leaves the user registers, the stacked SR and the stacked PC byte-identical to entry,
| so nullvect sees exactly what it would have seen without this unit.
|
| 040 SAFETY: the whole routine is behind `cputype == 60`, and a 68040 implements the
| instruction in hardware so it never traps here in the first place.  The gate uses a
| memory-immediate compare, which touches no register before the save.

	.text
	.globl	isp61_vec

| ---- raw-frame offsets from the saved-register base (a6).  Named, never scattered. ----
	FRM_SR	=	60
	FRM_PC	=	62
	FRM_FV	=	66
	U_AR0	=	0x40000864	| same u.u_ar0 slot fpsp_glue040.s uses

isp61_vec:
	cmpil	&60,cputype		| CPU gate: CCR only, no register touched
	bnew	Lisp_stock
	addql	&1,isp61_entry_n	| counted before any classification
	moveml	%d0-%fp,%sp@-		| 60-byte D0-D7/A0-A6 block (identical to nullvect)
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr
	moveal	%sp,%a6			| a6 = stable saved-register base

	cmpiw	&0x00f4,%a6@(FRM_FV)	| exactly a vector-61 format-0 frame?
	bnew	Lisp_badframe
	btst	&5,%a6@(FRM_SR)		| S bit set = supervisor origin
	bnew	Lisp_nonuser
	movew	%a6@(FRM_SR),%d0
	andiw	&0xc000,%d0		| T1/T0: tracing needs a format-2 trace frame that
	bnew	Lisp_trace		| this unit does not synthesize -- decline loudly
	movel	%a6@(FRM_PC),isp61_last_pc

| ---- fetch the whole 8-byte instruction, once, through copyin ----
	subql	&8,%sp			| supervisor scratch
	moveal	%sp,%a5
	pea	8			| count
	movel	%a5,%sp@-		| kernel dst
	movel	%a6@(FRM_PC),%sp@-	| user src = the faulting PC
	jsr	copyin
	lea	%sp@(12),%sp
	tstl	%d0
	bnew	Lisp_ifetch		| copyin failed: no access-error frame synthesis
	movel	%a5@,isp61_last_insn	| opword:extension, for diagnostics

| ---- decode, before any state changes ----
	cmpiw	&0x4c3c,%a5@		| opword: long multiply, immediate source, ONLY
	bnew	Lisp_unsup		|   (excludes the 0x4c40 divide group and every
					|    register/memory source form)
	moveq	&0,%d1			| ZERO-EXTEND the extension word.  movew alone leaves
	movew	%a5@(2),%d1		| d1's upper half as copyin left it, and the register
					| numbers below are used as a LONG index (%d2:l) --
					| that made the Dh/Dl slot addresses depend on stale
					| bits.  Measured: emu-060 gave two wrong results out
					| of five with the counters reporting five clean
					| successes (2026-08-06).
	movel	%d1,%d0
	andiw	&0x83f8,%d0		| bit15 + bits 9-3 are reserved zero
	bnew	Lisp_unsup
	btst	&10,%d1			| SIZE: 1 = 64-bit product (the trapping form)
	beqw	Lisp_unsup
	movel	%d1,%d2
	rolw	&4,%d2			| bits 15-12 -> bits 3-0 (shift immediates are 1..8,
					| so a 12-bit right shift is not encodable)
	andil	&7,%d2			| d2 = Dl (bits 14-12; bit 15 is fixed zero).
					| LONG mask, deliberately: these feed lsll/lea below
	movel	%d1,%d3
	andil	&7,%d3			| d3 = Dh (bits 2-0)
	cmpw	%d2,%d3
	beqw	Lisp_unsup		| Dh == Dl is architecturally undefined for the
					| 64-bit form; none of the 103 measured sites uses
					| it, so decline rather than invent a result
	lsll	&2,%d2
	lsll	&2,%d3
	leal	%a6@(0,%d2:l),%a4	| a4 = &saved Dl
	leal	%a6@(0,%d3:l),%a3	| a3 = &saved Dh
	movel	%a4@,%d6		| d6 = a = multiplicand (the ORIGINAL Dl)
	movel	%a5@(4),%d7		| d7 = b = the 32-bit immediate

| ---- 32x32 -> 64 unsigned product, the validated lmul060.s core (mulu.w only) ----
	movel	%d6,%d0
	movel	%d7,%d1
	swap	%d0			| d0.w = ah
	swap	%d1			| d1.w = bh
	movel	%d0,%d4
	muluw	%d1,%d4			| hi = ah*bh
	muluw	%d7,%d0			| d0 = ah*bl
	muluw	%d6,%d1			| d1 = bh*al
	movel	%d6,%d5
	muluw	%d7,%d5			| lo = al*bl
	addl	%d0,%d1			| mid = ah*bl + bh*al
	bccw	Lisp_nc1
	addil	&0x10000,%d4		|   mid overflowed 32 bits -> hi += 1<<16
Lisp_nc1:
	movel	%d1,%d0
	swap	%d0
	andil	&0xffff,%d0
	addl	%d0,%d4			| hi += mid>>16
	movel	%d1,%d0
	swap	%d0
	andil	&0xffff0000,%d0
	addl	%d0,%d5			| lo += mid<<16
	bccw	Lisp_nc2
	addql	&1,%d4			|   lo carried -> hi += 1
Lisp_nc2:
	moveq	&0,%d0			| re-read the extension: d1 was consumed above.
	movew	%a5@(2),%d0		| zero-extended for the same reason as at the decode
	btst	&11,%d0			| S: 1 = MULS.L, 0 = MULU.L
	beqw	Lisp_unsigned
	tstl	%d6			| signed correction to the unsigned product:
	bplw	Lisp_sp1
	subl	%d7,%d4			|   a < 0 -> hi -= b
Lisp_sp1:
	tstl	%d7
	bplw	Lisp_sp2
	subl	%d6,%d4			|   b < 0 -> hi -= a
Lisp_sp2:
	addql	&1,isp61_muls_n
	braw	Lisp_commit
Lisp_unsigned:
	addql	&1,isp61_mulu_n

| ---- commit: registers, then SR, then PC.  Nothing below here can fail. ----
Lisp_commit:
	movel	%d5,%a4@		| Dl = low 32 bits
	movel	%d4,%a3@		| Dh = high 32 bits
	movew	%a6@(FRM_SR),%d0
	andiw	&0xfff0,%d0		| keep X (bit 4) and every non-CCR bit; clear NZVC
	tstl	%d4			| N comes from product bit 63, NOT bit 31 --
	bplw	Lisp_noN		| e.g. signed 0x80000000 * -1 = 0:0x80000000 has
	oriw	&0x0008,%d0		| N CLEAR, and unsigned 0xffffffff^2 has N SET
Lisp_noN:
	movel	%d4,%d1
	orl	%d5,%d1			| Z is the whole 64-bit result being zero
	bnew	Lisp_noZ
	oriw	&0x0004,%d0
Lisp_noZ:
	movew	%d0,%a6@(FRM_SR)	| V and C stay clear for the 64-bit form
	movel	%a6@(FRM_PC),%d0
	addql	&8,%d0			| opword 2 + extension 2 + immediate 4
	movel	%d0,%a6@(FRM_PC)	| restarting would trap forever; +4 would execute
					| the immediate as opcodes
	addql	&1,isp61_ok_n

| ---- return to user the AMIX way (the fpsp_done shape), never a bare rte ----
	moveal	%a6,%sp			| drop the scratch; sp = the saved D0 block
	movel	%usp,%a0
	movel	%a0,%sp@-		| push USP as the pseudo-register
	movel	%sp,U_AR0		| u.u_ar0 = &pseudo-register
	moveal	%sp@+,%a0
	movel	%a0,%usp
	jmp	ureturn			| qrun / cl_trapret / s_trap / signals / CACR

| ---- decline paths: restore everything and let the stock path do what it always did ----
Lisp_badframe:
	addql	&1,isp61_badframe_n
	braw	Lisp_unwind
Lisp_nonuser:
	addql	&1,isp61_nonuser_n	| the kernel's own 64-bit multiplies were replaced
	braw	Lisp_unwind		| by lmul060.s; a supervisor hit is a real surprise
Lisp_trace:
	addql	&1,isp61_trace_decline_n
	braw	Lisp_unwind
Lisp_ifetch:
	addql	&1,isp61_ifetch_fail_n
	braw	Lisp_unwind
Lisp_unsup:
	addql	&1,isp61_unsupported_n
Lisp_unwind:
	moveal	%a6,%sp			| a6 is the base whether or not scratch was taken
	moveml	%sp@+,%d0-%fp		| restore D0-D7/A0-A6 exactly
Lisp_stock:
	jmp	nullvect		| raw frame untouched: SR, PC and vector as pushed

	.data
| Counters, in the wb_dfc_* / x60_* convention: .data longs, read with /kpeek at
| 0x08000000 + textsize + nm(.data offset).  Recompute per image; check the magic first.
	.globl	isp61_magic
isp61_magic:
	.long	0x49363121		| "I61!" -- refuse to believe the rest without it
	.globl	isp61_entry_n
isp61_entry_n:
	.long	0			| every cputype==60 entry to slot 61
	.globl	isp61_ok_n
isp61_ok_n:
	.long	0			| fully committed emulations
	.globl	isp61_mulu_n
isp61_mulu_n:
	.long	0
	.globl	isp61_muls_n
isp61_muls_n:
	.long	0
	.globl	isp61_unsupported_n
isp61_unsupported_n:
	.long	0			| fetched, but outside the accepted encoding
	.globl	isp61_ifetch_fail_n
isp61_ifetch_fail_n:
	.long	0			| the 8-byte copyin failed
	.globl	isp61_nonuser_n
isp61_nonuser_n:
	.long	0			| supervisor-origin entry
	.globl	isp61_badframe_n
isp61_badframe_n:
	.long	0			| slot 61 entered without a 0x00F4 frame word
	.globl	isp61_trace_decline_n
isp61_trace_decline_n:
	.long	0			| trace mode active -> declined, no trace frame
	.globl	isp61_last_pc
isp61_last_pc:
	.long	0			| last validated frame's instruction PC
	.globl	isp61_last_insn
isp61_last_insn:
	.long	0			| last fetched opword:extension
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
