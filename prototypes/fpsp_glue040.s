| fpsp_glue040.s -- AMIX OS glue for the Motorola 68040 FPSP (M2, 2026-07-24).
|
| Provides the 12 OS-callback symbols that build/fpsp040.o (M1, build-fpsp040.sh)
| leaves unresolved, plus the vector-11 dispatch entry.  Spec: analyysirepo
| vm-map/FPSP-INTEGRATION-PLAN.md.  MINIMAL M2 scope: get a previously-crashing
| unimplemented FP instruction (fmovecr / fintrz / transcendental) emulated and
| returned to the user.  Vectors 48-55 (arithmetic exceptions) are NOT retargeted
| yet; full real_* pending-bit cleanup + copy-fault unwind = M4.
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
	jmp	nullvect		| non-040: existing F-line / SIGSYS path

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
