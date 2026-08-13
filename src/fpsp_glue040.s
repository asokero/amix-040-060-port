| fpsp_glue040.s -- AMIX OS glue for the Motorola 68040 FPSP (M2, 2026-07-24).
|
| Provides the 12 OS-callback symbols that build/fpsp040.o (M1, build-fpsp040.sh)
| leaves unresolved, plus the vector-11 dispatch entry.  Spec: analyysirepo
| vm-map/FPSP-INTEGRATION-PLAN.md.  MINIMAL M2 scope: get a previously-crashing
| unimplemented FP instruction (fmovecr / fintrz / transcendental) emulated and
| returned to the user.  M4 (2026-07-24) adds the arithmetic-exception vectors
| 48/51/52/53/54/55; full real_* pending-bit cleanup + copy-fault unwind remain.
|
| Assembled with m68k-linux-gnu-gcc -x assembler-with-cpp -m68040 (same as the
| FPSP body), #including fpsp.defs for EXC_SR.  Kernel symbols (cputype, sup_cacr,
| ureturn, nullvect, copyin, copyout, panic) and the package entry fpsp_fline
| resolve at the kernel relink (m68k-cbm-sysv4-ld -r).
|
| Pinned kernel anchors (build/unix-040-dbg, 06515dd): nullvect 0x11b4,
| ureturn 0x11f8, u (fixed u-area) = ABS 0x40000000 -> u_ar0 @ 0x40000864,
| EXC_SR = 4, cache-mode from sup_cacr, exception frame SR at (sp).

#include "fpsp.defs"

	.text

| ============================================================================
| fpsp_vec11 -- vector-11 (F-line) entry.  Installed in M68Kvec[11] in place of
| nullvect by patch_fpsp_vec11.py.  Reached with the RAW 68040 exception frame
| on (sp).  Establish the kernel supervisor cache mode, then jump to the FPSP
| master F-line dispatcher fpsp_fline (which itself routes unimplemented-FP to
| its unimp path and a genuine line-F to real_fline).  Only on a 68040; other
| CPUs fall through to the stock nullvect (SIGSYS) path unchanged.
| ============================================================================
	.globl	fpsp_vec11
fpsp_vec11:
	cmpl	#40,cputype
	bne	Lv11_stock
	movel	%d0,%sp@-		| temp save d0 (plan: touch nothing else)
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr  (kernel cache mode)
	movel	%sp@+,%d0		| restore d0; SP now exactly as CPU left it
	jmp	fpsp_fline		| master F-line dispatcher (raw frame on sp)
Lv11_stock:
| F3 M2a (2026-08-07): the 68060 has its own support package.  Measured before this branch
| existed: an unimplemented FP instruction on the 060 fell through here to nullvect and became
| SIGSYS -- kvp_vec[11] moved 0 -> 4 across fp060probe (docs/060-FPU-STATE-260807.md).  The 040 path
| above is untouched; this only redirects what used to be dropped.
|
| GUARDED BY THE PREPROCESSOR, and that guard is load-bearing: relink-040.sh defines
| HAVE_FPSP060 only when it actually links build/fpsp060_pkg.o.  Without the guard, an
| FPSP060=0 build left `jmp fpsp060_vec11` as an UNRESOLVED reference -- caught by the reloc
| validator (1 complaint, `U fpsp060_vec11`) -- which on a 68060 would have jumped an
| unimplemented FP instruction into whatever the loader left at that address.  That is strictly
| worse than the SIGSYS it replaced, so the branch must not exist unless its target does.
#ifdef HAVE_FPSP060
	cmpl	#60,cputype
	bne	Lv11_null
	jmp	fpsp060_vec11		| 060: Motorola's M68060 FPSP, via src/fpsp060_glue.s
#endif
Lv11_null:
	jmp	nullvect		| no 060 package linked: existing F-line / SIGSYS path

| ============================================================================
| M4: the FP ARITHMETIC exception vectors 48-55.  Same shape as fpsp_vec11:
| cputype gate (a 68060 boot of this dual-CPU binary must never enter the 040
| package), kernel supervisor cache mode, then the package entry with the raw
| 68040 exception frame untouched on (sp).
|
| Vector 55 (unimplemented data type) is the one that MATTERS in practice: the
| 68040 traps there whenever an FP instruction meets a denormalized or packed
| operand, and with the slot left on nullvect that arrives in user land as
| SIGILL.  Observed 2026-07-24: `DBG SIG sig=4 pid=208 psargs=/usr/X/bin/Xsvga`
| -- the Xsvga X server dying on exactly this.
|
| Vectors 49 (inexact) and 50 (divide-by-zero) are NOT retargeted: the 68040
| completes both in hardware and the Motorola package exports no entry for them,
| so they stay on the stock nullvect -> u_trap -> SIGFPE path.
| ============================================================================
#define FPSP_VEC(name, target)		\
	.globl	name			;\
name:					;\
	cmpl	#40,cputype		;\
	bne	9f			;\
	movel	%d0,%sp@-		;\
	movel	sup_cacr,%d0		;\
	.word	0x4e7b,0x0002		;\
	movel	%sp@+,%d0		;\
	jmp	target			;\
9:	jmp	nullvect

| ============================================================================
| F3 M4 (2026-08-10): the same five arithmetic vectors now need a 68060 branch, and two
| vectors the 68040 deliberately leaves alone need a 68060-only stub.
|
| The 68040 rule was: retarget a vector only if Motorola's package exports an entry for it.
| That is why 49 (inexact) and 50 (divide-by-zero) stayed on nullvect -- the 040 completes both
| in hardware.  The SAME rule applied to the 68060 package lands differently, because that
| package DOES export dz and inex entries and does NOT export a bsun entry:
|
|     68040:  48 hooked,  49 50 not,  51-55 hooked
|     68060:  48 NOT,     49 50 yes,  51-55 hooked
|
| So vector 48 keeps the two-way macro (040 only, 060 falls through to nullvect as before) and
| 49/50 get a 060-only stub.  Neither map was copied from the other.
| ============================================================================
#ifdef HAVE_FPSP060
#define FPSP_VEC3(name, target, t060)	\
	.globl	name			;\
name:					;\
	cmpl	#40,cputype		;\
	bne	8f			;\
	movel	%d0,%sp@-		;\
	movel	sup_cacr,%d0		;\
	.word	0x4e7b,0x0002		;\
	movel	%sp@+,%d0		;\
	jmp	target			;\
8:	cmpl	#60,cputype		;\
	bne	9f			;\
	jmp	t060			;\
9:	jmp	nullvect

#define FPSP_VEC060(name, t060)		\
	.globl	name			;\
name:					;\
	cmpl	#60,cputype		;\
	bne	9f			;\
	jmp	t060			;\
9:	jmp	nullvect
#else
| No 060 package linked: every 060 branch must not exist, or it is a jmp to a symbol that is
| not there.  Same reasoning as vector 11's guard, and the reloc validator enforces it.
#define FPSP_VEC3(name, target, t060)	FPSP_VEC(name, target)
#define FPSP_VEC060(name, t060)		\
	.globl	name			;\
name:					;\
	jmp	nullvect
#endif

	FPSP_VEC(fpsp_vec48, fpsp_bsun)			| 48 bsun: 040 only -- the 060 package
							|    exports a call-out but no entry
	FPSP_VEC060(fpsp_vec49, fpsp060_vec49)		| 49 inexact:        060 only
	FPSP_VEC060(fpsp_vec50, fpsp060_vec50)		| 50 divide-by-zero: 060 only
	FPSP_VEC3(fpsp_vec51, fpsp_unfl,  fpsp060_vec51)	| 51 underflow
	FPSP_VEC3(fpsp_vec52, fpsp_operr, fpsp060_vec52)	| 52 operand error
	FPSP_VEC3(fpsp_vec53, fpsp_ovfl,  fpsp060_vec53)	| 53 overflow
	FPSP_VEC3(fpsp_vec54, fpsp_snan,  fpsp060_vec54)	| 54 signaling NaN

| ============================================================================
| F3 M3 (2026-08-10): vectors 55 and 60 need a THREE-way stub, so they leave the macro.
|
| 55 (unimplemented DATA TYPE) already had a 68040 branch; the 68060 fell through to nullvect.
| 60 (unimplemented EFFECTIVE ADDRESS) is a 68060-only vector -- on the 68040 that slot is
| unassigned and nothing should ever arrive there, so its 040 branch is nullvect by design and
| not by omission.  Verified before wiring: M68Kvec[55], [60] and [61] all point at nullvect in
| the stock kernel (readelf .rela.text, 0x1454 / 0x1468 / 0x146c).
|
| Both guards are load-bearing for the same reason vector 11's is: relink-040.sh defines
| HAVE_FPSP060 only when build/fpsp060_pkg.o is actually linked, and a jmp to a symbol that
| does not exist is worse than the signal it replaces.
| ============================================================================
	.globl	fpsp_vec55
fpsp_vec55:
	cmpl	#40,cputype
	bne	Lv55_not040
	movel	%d0,%sp@-
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002
	movel	%sp@+,%d0
	jmp	fpsp_unsupp		| 040: the 68040 package (denormal / packed operand)
Lv55_not040:
#ifdef HAVE_FPSP060
	cmpl	#60,cputype
	bne	Lv55_null
	jmp	fpsp060_vec55		| 060: _060_fpsp_unsupp
#endif
Lv55_null:
	jmp	nullvect

	.globl	fpsp_vec60
fpsp_vec60:
#ifdef HAVE_FPSP060
	cmpl	#60,cputype
	bne	Lv60_null
	jmp	fpsp060_vec60		| 060: _060_fpsp_effadd
#endif
Lv60_null:
	jmp	nullvect		| 68040: vector 60 is unassigned, so this is unreachable
					| there -- and stays counted by kvp_vec if it ever is not

| ============================================================================
| fpsp_done -- the package fully emulated the instruction (PC already advanced
| in the raw frame) and restored the user register/FP state.  Return to user
| THROUGH the normal AMIX exit (ureturn) so STREAMS qrun / cl_trapret / s_trap /
| signal / CACR housekeeping run -- a bare rte would skip all of that.  Rebuild
| exactly the state that nullvect->utraps->u_trap normally leaves at ureturn,
| WITHOUT calling u_trap (the instruction is already complete).
| Entry: (sp) = raw exception frame, SR word at (sp), registers already restored.
| ============================================================================
	.globl	fpsp_done
fpsp_done:
	btst	#5,%sp@			| SR high byte bit 5 = S-bit (super origin?)
	bne	Lfd_super
Lfd_user:
	moveml	%d0-%fp,%sp@-		| 60-byte D0-D7/A0-A6 block (== nullvect)
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr
	movel	%usp,%a0
	movel	%a0,%sp@-		| push USP as the pseudo-register
	movel	%sp,0x40000864		| u.u_ar0 = &pseudo-register (current sp)
	moveal	%sp@+,%a0		| pop USP slot; sp now at the reg block
	movel	%a0,%usp		| reload USP
	jmp	ureturn			| AMIX user-exception exit
Lfd_super:
	| supervisor-origin FP is not an intended AMIX workload; the package
	| already fixed the frame, so just return.  Counted for the dbg build.
	addql	#1,fpsp_super_done
	rte

| ============================================================================
| mem_read / mem_write -- FPSP operand access (netbsd.sa ABI).
|   mem_read:  a0=user src, a1=super dst(stack), d0=count (<=12)
|   mem_write: a0=super src(stack), a1=user dst, d0=count (<=12)
| a6 = the package's local frame; EXC_SR(a6) holds the exception SR.
| Supervisor-origin: dumb byte copy.  User-origin: copyin/copyout.
| M2-minimal: a copy fault is COUNTED (fpsp_copy_fault) but not yet unwound --
| the milestone operands are resident so no fault occurs; full fault unwind = M4.
| ============================================================================
	.globl	mem_read
mem_read:
	btst	#5,EXC_SR(%a6)
	beq	Lmr_user
Lmr_super:
	moveb	%a0@+,%a1@+
	subql	#1,%d0
	bne	Lmr_super
	rts
Lmr_user:
	movel	%d1,%sp@-
	movel	%d0,%sp@-		| count
	movel	%a1,%sp@-		| kernel dst
	movel	%a0,%sp@-		| user src
	jsr	copyin
	lea	%sp@(12),%sp
	tstl	%d0			| copyin != 0 -> fault
	bne	Lmr_fault
	movel	%sp@+,%d1
	rts
Lmr_fault:
	addql	#1,fpsp_copy_fault
	movel	%sp@+,%d1
	rts

	.globl	mem_write
mem_write:
	btst	#5,EXC_SR(%a6)
	beq	Lmw_user
Lmw_super:
	moveb	%a0@+,%a1@+
	subql	#1,%d0
	bne	Lmw_super
	rts
Lmw_user:
	movel	%d1,%sp@-
	movel	%d0,%sp@-		| count
	movel	%a1,%sp@-		| user dst
	movel	%a0,%sp@-		| kernel src
	jsr	copyout
	lea	%sp@(12),%sp
	tstl	%d0
	bne	Lmw_fault
	movel	%sp@+,%d1
	rts
Lmw_fault:
	addql	#1,fpsp_copy_fault
	movel	%sp@+,%d1
	rts

| ============================================================================
| real_* -- the package DECLINED the exception and restored the pre-FPSP machine
| state (raw exception frame on sp).  Route into the stock vector dispatch
| (nullvect), which pushes the register block, runs u_trap, and delivers the
| correct signal for the frame's vector (SIGSYS for a genuine line-F via
| real_fline; SIGFPE for arithmetic vectors).  M2-minimal: uniform + safe; the
| milestone inputs do not raise these.  M4 adds per-class FPSR pending-bit
| cleanup before hand-off (plan) so an enabled exception cannot retrap.
| ============================================================================
	.globl	real_fline
real_fline:
	jmp	nullvect
	.globl	real_bsun
real_bsun:
	jmp	nullvect
	.globl	real_inex
real_inex:
	jmp	nullvect
	.globl	real_operr
real_operr:
	jmp	nullvect
	.globl	real_ovfl
real_ovfl:
	jmp	nullvect
	.globl	real_snan
real_snan:
	jmp	nullvect
	.globl	real_unfl
real_unfl:
	jmp	nullvect
	.globl	real_trace
real_trace:
	rte				| netbsd-matching; no tracing in the M2 test

| ============================================================================
| fpsp_fmt_error -- package hit a frame it cannot classify (kernel invariant
| failure, not a user arithmetic exception).  Panic (dbg build records the frame
| first via the counter + the raw frame is still on sp for a debugger).
| ============================================================================
	.globl	fpsp_fmt_error
fpsp_fmt_error:
	addql	#1,fpsp_fmt_err_cnt
	pea	Lfmtmsg
	jsr	panic
	| panic never returns
Lfmtmsg:
	.asciz	"bad 68040 FPSP frame"
	.balign 4

	.data
	.balign 4
	.globl	fpsp_super_done
fpsp_super_done:
	.long	0
	.globl	fpsp_copy_fault
fpsp_copy_fault:
	.long	0
	.globl	fpsp_fmt_err_cnt
fpsp_fmt_err_cnt:
	.long	0
	.balign 4
