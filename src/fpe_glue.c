/*
 * fpe_glue.c -- the C half of the AMIX soft-FPU lane: the trap-frame shim, the entry lock,
 * the interposed panic/copy paths, and the SVR4 si_code derivation.  (2026-08-26)
 *
 * FIRST-PARTY.  Nothing here is derived from the NetBSD FPE under build/fpe-src/, which the
 * build extracts and never edits.  The measurements this file is built on are in
 * docs/contracts/FPE-INTEGRATION-CONTRACT.md; every decision it implements is argued in
 * docs/contracts/FPE-GLUE-DESIGN.md.  This header says what, not why.
 *
 * WHY C AND NOT ASSEMBLY, since every other override unit in this port is assembly.  The one
 * job that dominates this file is laying out NetBSD's `struct frame` -- sixteen registers, a
 * packed 2-byte-aligned PC at offset 70, a 4-bit/12-bit bitfield at 74, and a per-format tail.
 * Hand-computed offsets for that are a defect waiting to happen, and the offsets are exactly
 * what the compiler already knows.  So the layout is expressed as the struct it is, and the
 * assumptions the port cannot afford to have wrong are asserted AT COMPILE TIME below.
 * The machine-level work -- the raw exception frame, the register push, ureturn -- stays in
 * src/fpe040.s, which is also the object that closes the link with .balign 4.
 *
 * Compile with the FPE compat include path but WITHOUT the -Dpanic/-Dcopyin/-Dcopyout
 * redirections: this file is the far side of those.
 */

#include <sys/cdefs.h>		/* the compat one: uint32_t and the BSD short names */
#include <sys/types.h>
#include <sys/signal.h>
#include <sys/siginfo.h>
#include <sys/fpu.h>
#include <machine/frame.h>	/* -> m68k/cpuframe.h: struct frame, struct fpframe */
#include <m68k/fpreg.h>		/* FPSR_* */

#include "fpu_emulate.h"

/* ------------------------------------------------------------------ AMIX kernel interface */
extern short cputype;		/* sys/systm.h:18 -- 40 / 60 here, a SHORT */
extern fpu_info *fpu_ptr;	/* = u + 0x9c; asserted below and by check_fpu_relocs.py */
extern char *curproc;
extern int copyin();
extern int copyout();
extern int sleep();
extern void wakeup();
extern void bzero();
extern void printf();
extern void panic();
extern void trapsig();		/* file-local in stock; globalized by relink-040-fpe.sh */
extern int issig();
extern void psig();

/* ------------------------------------------------------------------- src/fpe040.s objects */
extern long fpe_cputype;
extern long fpe_busy, fpe_lock_wait_n, fpe_jb[13], fpe_jb_active;
extern long fpe_done_n, fpe_sig_n;
extern long fpe_sigfpe_n, fpe_sigill_n, fpe_sigsegv_n, fpe_sigother_n;
extern long fpe_last_signo, fpe_last_code, fpe_last_fpsr, fpe_undecoded_n;
extern long fpe_panic_n, fpe_panic_hard_n, fpe_copyfail_n;
extern long fpe_ufetch_n, fpe_ufetchfail_n, fpe_fault_addr;
extern long fpe_advmiss_n, fpe_b_pc, fpe_b_stacked, fpe_b_resume;
extern long fpe_sigpend_n, fpe_sigdeliv_n;
extern int fpe_setjmp();
extern void fpe_longjmp();
extern int fpe_sigpend();	/* u_trap's own three-condition gate -- see src/fpe040.s */

/*
 * PZERO, measured rather than assumed: sleep's own body at 0x4868c reads
 *	moveq #127,%d0 ; andl %d5,%d0 ; moveq #25,%d1 ; cmpl %d0,%d1 ; bge <no signal catch>
 * so a priority whose low seven bits are <= 25 sleeps UNINTERRUPTIBLY.  That is what this
 * lock wants: the wait is bounded by one emulated instruction in another process, and a
 * sleep that could return early would need an unwind path for a lock that is already held.
 */
#define FPE_SLEEP_PRI	25

/* NetBSD's cputype encoding (m68k/m68k.h:66-71), restated here because this file must NOT
 * include the shadow header that redirects the name -- it needs AMIX's `cputype`. */
#define NB_CPU_68040	2
#define NB_CPU_68060	3

/* ---------------------------------------------------------------------------- assertions */
/*
 * Negative array sizes, the idiom src/modelb_geom_probe.c already uses on this compiler
 * ("size of array `...' is negative", with a line number).  Every one of these is something
 * the glue would otherwise be ASSUMING about a layout it did not choose.
 *
 * The first three are the ones that matter most: NetBSD's struct trapframe is
 * __attribute__((packed)), and if this gcc silently ignored that, tf_pc would land at 72
 * instead of 70 and every field the shim writes after it would be two bytes out -- with no
 * diagnostic anywhere, and a kernel that reads the wrong PC out of every FP trap.
 */
#define FOFF(t, m)	((int)&(((t *)0)->m))

char fpe_as_tfsr[(FOFF(struct frame, F_t.tf_sr) == 68) ? 1 : -1];
char fpe_as_tfpc[(FOFF(struct frame, F_t.tf_pc) == 70) ? 1 : -1];
char fpe_as_tail[(FOFF(struct frame, F_u) == 76) ? 1 : -1];
char fpe_as_a7[(FOFF(struct frame, F_t.tf_regs[15]) == 60) ? 1 : -1];
char fpe_as_fmt4a[(FOFF(struct frame, F_u.F_fmt4.f_fa) == 76) ? 1 : -1];
char fpe_as_fmt4b[(FOFF(struct frame, F_u.F_fmt4.f_fslw) == 80) ? 1 : -1];

/*
 * The cheapest seam in the whole document (contract 3.1), and the one that is cheap only
 * while these hold: AMIX's fpu_info.regs is field for field and order for order the tail of
 * NetBSD's struct fpframe -- eight 12-byte registers, then FPCR, FPSR, FPIAR.  So the
 * emulator can be handed a `struct fpframe *` that is a fixed bias off fpu_ptr and it writes
 * the u-area's own programmer's model in place, with no transposition and no copy.
 *
 * fpregset_t (sys/regset.h:42-47) is the layout that is NOT this one -- control words FIRST.
 * prgetfpregs exists to transpose between them.  Confusing the two puts every FP register
 * three longwords out of place, which is why the relation is asserted and not commented.
 */
#define FPF_REGS_OFF	FOFF(struct fpframe, fpf_regs)

char fpe_as_fpfcr[(FOFF(struct fpframe, fpf_fpcr) - FPF_REGS_OFF == 96) ? 1 : -1];
char fpe_as_fpfsr[(FOFF(struct fpframe, fpf_fpsr) - FPF_REGS_OFF == 100) ? 1 : -1];
char fpe_as_fpfiar[(FOFF(struct fpframe, fpf_fpiar) - FPF_REGS_OFF == 104) ? 1 : -1];
char fpe_as_fpusz[(sizeof(fpu_t) == 108) ? 1 : -1];
char fpe_as_uregs[(FOFF(fpu_info, regs) == 4) ? 1 : -1];
char fpe_as_ufsave[(FOFF(fpu_info, fsave) == 112) ? 1 : -1];
char fpe_as_ksi[(sizeof(k_siginfo_t) == 28) ? 1 : -1];

/* ------------------------------------------------------------------------ the abort state */
/*
 * These three, the jmp_buf in src/fpe040.s, and the emulator's own 396 bytes of file-static
 * .bss are all covered by the SAME lock: nothing below is reachable except from inside
 * fpu_emulate(), and exactly one process is ever inside it.  That is the whole justification
 * for their being static, and it is the same justification the serialization decision rests
 * on -- see FPE-GLUE-DESIGN.md section 4.1.
 */
static int fpe_abort_signo;
static int fpe_abort_code;
static long fpe_abort_addr;
static struct frame *fpe_cur;

/*
 * fpe_panic -- the eleven emulator panic() sites, reached because those files are compiled
 * with -Dpanic=fpe_panic.  Frozen decision 8: a user process's arithmetic must never take the
 * kernel down.
 *
 * THE HARD PART IS NOT THE POLICY, IT IS THE RETURN.  Emulator code calls panic() as a
 * no-return primitive: fpu_subr.c:91 and :102 fall off the end of a switch afterwards,
 * fpu_calcea.c:78 does the same.  Returning normally from here would resume that code with
 * an undefined result and no diagnostic.  So this does not return: it unwinds to fpe_trap's
 * own frame through fpe_longjmp, which is the reason that mechanism exists at all.
 *
 * Three of the eleven sites use __func__ with %s (fpu_calcea.c:78, :308, :449), so the
 * message is a real format string and its arguments have to survive.  K&R varargs on m68k
 * SysV: the arguments are on the stack, and passing four longs through covers every site.
 *
 * ONE console line, not one per event: this path is reachable once per emulated instruction,
 * so an unthrottled printf would bury the console and change the timing of the thing being
 * measured.  fpe_panic_n counts the rest.
 */
void
fpe_panic(fmt, a1, a2, a3, a4)
	char *fmt;
	long a1, a2, a3, a4;
{

	fpe_panic_n++;
	if (fpe_jb_active == 0) {
		/*
		 * Not from inside the emulator -- so this is not a user process's arithmetic
		 * and decision 8 does not apply.  The kernel's own panic, loud.
		 */
		fpe_panic_hard_n++;
		panic(fmt, a1, a2, a3, a4);
		/* NOTREACHED */
	}
	if (fpe_panic_n == 1) {
		printf("fpe: emulator inconsistency -> SIGILL: ");
		printf(fmt, a1, a2, a3, a4);
		printf("\n");
	}
	fpe_abort_signo = SIGILL;
	fpe_abort_code = ILL_ILLOPC;
	fpe_abort_addr = fpe_cur ? (long)fpe_cur->f_pc : 0;
	fpe_longjmp(fpe_jb, 1);
	/* NOTREACHED */
}

/*
 * fpe_copyin / fpe_copyout -- the six user-memory accesses in fpu_calcea.c, reached because
 * that file is compiled with -Dcopyin/-Dcopyout.
 *
 * THE EMULATOR CODE IGNORES EVERY ONE OF THOSE RETURN VALUES -- measured, all six sites
 * (:330, :378, :413, :475, :491, :533).  FPSP-INTEGRATION-PLAN.md:350-367 makes that
 * unacceptable as an AMIX contract in as many words, and requires instead a defined abort
 * that (1) detects the nonzero return, (2) unwinds, (3) requests the memory-fault signal,
 * (4) reaches ureturn with a coherent frame, and (5) does not advance the PC as if the
 * instruction had succeeded.  Since no extracted byte may change, the check has to happen on
 * this side of the call -- and then the abort has to be non-local, because the caller is
 * about to use the buffer regardless.  The longjmp satisfies (1) through (5) together: the
 * PC advance at fpu_emulate.c:217 is never reached.
 */
int
fpe_copyin(from, to, n)
	char *from;
	char *to;
	int n;
{
	int e;

	e = copyin(from, to, n);
	if (e) {
		fpe_copyfail_n++;
		fpe_fault_addr = (long)from;
		fpe_abort_signo = SIGSEGV;
		fpe_abort_code = SEGV_ACCERR;
		fpe_abort_addr = (long)from;
		if (fpe_jb_active)
			fpe_longjmp(fpe_jb, 1);
		/* NOTREACHED in practice; see the header */
	}
	return e;
}

int
fpe_copyout(from, to, n)
	char *from;
	char *to;
	int n;
{
	int e;

	e = copyout(from, to, n);
	if (e) {
		fpe_copyfail_n++;
		fpe_fault_addr = (long)to;
		fpe_abort_signo = SIGSEGV;
		fpe_abort_code = SEGV_ACCERR;
		fpe_abort_addr = (long)to;
		if (fpe_jb_active)
			fpe_longjmp(fpe_jb, 1);
	}
	return e;
}

/*
 * ufetch_short -- the emulator's only user-fetch helper, sixteen call sites (twelve in
 * fpu_calcea.c, four in fpu_emulate.c).  NetBSD's contract delivers the value through the
 * out-parameter and the status through the return, precisely so that an all-ones datum
 * cannot be mistaken for a failure the way AMIX's own fubyte/fuword -1 can.
 *
 * NO LONGJMP HERE, and that is the difference from fpe_copyin above: every one of the
 * sixteen callers DOES test the return and aborts properly (fpu_emulate.c:128 and :147 with
 * SIGSEGV/SEGV_ACCERR).  The emulator code is already correct at these sites, so the glue
 * stays out of its way and merely counts.
 *
 * Implemented over the two-byte copyin shape rather than `moves` under a nofault pad, for the
 * three reasons src/fpsp060_glue.s:66-71 records: copyin is what this port already fetches
 * user instruction words with and it is hardware-accepted; it owns function codes, address
 * validation and the nofault landing pad, so this file cannot get SFC/DFC wrong; and it may
 * legitimately sleep on a page fault, which the entry lock is there to make safe.
 */
int
ufetch_short(uaddr, valp)
	const void *uaddr;
	u_short *valp;
{
	unsigned short tmp;
	int e;

	fpe_ufetch_n++;
	e = copyin((char *)uaddr, (char *)&tmp, 2);
	if (e) {
		fpe_ufetchfail_n++;
		fpe_fault_addr = (long)uaddr;
		return e;
	}
	*valp = tmp;
	return 0;
}

/*
 * fpe_fltcode -- frozen decision 2's other half: the emulator emits si_code 0 for
 * every arithmetic signal (fpu_emulate.c:237-238, `fpe_abort(frame, ksi, sig, 0)`), so the
 * SVR4 code has to be derived here.  The material is exact and it is still in place:
 * fpu_upd_excp() wrote the final FPSR back into fpf_fpsr and returned SIGFPE precisely
 * because (fpsr & fpcr & FPSR_EXCP) was non-empty, so the enabled-and-raised set survives.
 *
 * The mapping is contract 3.3's table.  The ORDER is Motorola's exception priority, highest
 * first, because more than one bit can be set at once and only one code can be delivered.
 *
 * WHAT THIS IS FINER THAN.  Stock u_trap reaches the same five codes through the CPU's own
 * vectors, where 48 BSUN, 52 OPERR, 54 SNAN and 55 unsupported-type all share ONE arm and one
 * code, FPE_FLTINV (contract 5.2).  So the code set is identical -- SVR4 has no finer name
 * for an invalid operation.  What is finer is WHICH EVENTS GET ONE: on a 68LC060 none of
 * vectors 48-55 is ever raised, every FP exception arrives on vector 11, and stock's answer
 * there is SIGSYS.  Deriving the code is what turns that into the SIGFPE a program expects.
 */
static int
fpe_fltcode(fpf)
	struct fpframe *fpf;
{
	uint32_t raised;

	raised = fpf->fpf_fpsr & fpf->fpf_fpcr & FPSR_EXCP;
	fpe_last_fpsr = (long)fpf->fpf_fpsr;

	if (raised & (FPSR_BSUN | FPSR_SNAN | FPSR_OPERR))
		return FPE_FLTINV;	/* 7 */
	if (raised & FPSR_OVFL)
		return FPE_FLTOVF;	/* 4 */
	if (raised & FPSR_UNFL)
		return FPE_FLTUND;	/* 5 */
	if (raised & FPSR_DZ)
		return FPE_FLTDIV;	/* 3 */
	if (raised & (FPSR_INEX1 | FPSR_INEX2))
		return FPE_FLTRES;	/* 6 */
	return 0;			/* nothing enabled and raised: undecodable */
}

/*
 * fpe_signal -- build AMIX's k_siginfo_t and reach the existing signal policy.
 *
 * The 28-byte kernel structure and its three live offsets are u_trap's own, read out of the
 * binary: si_signo +0, si_code +4, si_errno +8, si_addr +12 (contract 3.3; src/wb040.s:442
 * already records the same four).  u_trap builds one on its stack with bzero(&si, 28) and
 * hands it to trapsig; so does this.
 *
 * _exop[3] IS NOT AVAILABLE AND THE CONTRACT'S "opportunity" IS CLOSED.  sys/siginfo.h:132
 * puts the exceptional-operand slot in the USER-visible siginfo_t; the kernel-side
 * k_siginfo_t at :150 has only _fault._addr, with no _exop at all.  There is nowhere in the
 * structure the kernel actually carries to put it, so it is not a cheap addition -- it is a
 * structure change.  (And the operand itself lives in fpu_emulate.c's file-static `fe`,
 * which the emulator code does not export.)
 *
 * THE issig/psig PAIR IS NOT DECORATION.  s_trap -- which ureturn calls on the way out -- does
 * runrun/preempt and addupc but has NO issig/psig loop; that loop lives in u_trap, which this
 * path deliberately does not run.  Without it a queued signal would wait for the process's
 * next syscall or trap, and under full emulation an FP-only loop makes no syscalls: its next
 * trap is another FP instruction, straight back into this same path.  A SIGFPE that arrives
 * only if the program happens to call write() is not a signal.
 */
static void
fpe_signal(signo, code, addr)
	int signo;
	int code;
	long addr;
{
	k_siginfo_t si;

	bzero((char *)&si, sizeof(si));
	si.si_signo = signo;
	si.si_code = code;
	si.si_errno = 0;
	si.si_addr = (caddr_t)addr;

	fpe_last_signo = (long)signo;
	fpe_last_code = (long)code;

	trapsig(curproc, &si);
	if (issig(0))
		psig();
}

/*
 * fpe_trap -- the one entry point, called from src/fpe040.s's user-origin format-4 arm with
 * the raw exception frame and the 60-byte register block already on the supervisor stack.
 *
 *	uspp	&the USP pseudo-register slot, which is also what u.u_ar0 points at
 *	regs	the 60-byte D0-D7/A0-A6 block, in nullvect's order
 *	xf	the raw eight-word exception frame: SR +0, PC +2, fmt/vec +6, f_fea +8,
 *		f_pcfi +12
 *
 * Returns 0 if the instruction was emulated, 1 if a signal was delivered.  Either way the
 * frame and the register block have been updated in place and the caller goes to ureturn.
 */
int
fpe_trap(uspp, regs, xf)
	unsigned int *uspp;
	int *regs;
	char *xf;
{
	struct frame f;
	struct fpframe *fpf;
	ksiginfo_t ksi;
	unsigned short fmtvec;
	unsigned int stacked_pc;
	int i, r, signo, code;

	/*
	 * THE ENTRY LOCK.  fpu_emulate() keeps its per-invocation state in file-static objects
	 * -- `insn` and `fe` at fpu_emulate.c:89-90, and function-local statics in
	 * fpu_log.c:199 and fpu_rem.c:105 -- so a second process entering while the first is
	 * asleep in a copyin would overwrite the first one's working state.  Serialising entry
	 * is the only shape that fixes all three files without editing one of them.
	 *
	 * Test-then-sleep is safe here because this kernel is uniprocessor and non-preemptive
	 * between sleep points, and nothing between the test and the sleep can sleep.  The
	 * priority is uninterruptible on purpose: see FPE_SLEEP_PRI above.
	 */
	while (fpe_busy) {
		fpe_lock_wait_n++;
		sleep((caddr_t)&fpe_busy, FPE_SLEEP_PRI);
	}
	fpe_busy = 1;

	/*
	 * Keep the CPU-type redirection current.  Cheap enough to do per entry rather than to
	 * rely on a boot-time write staying true, and the value is the one the extracted tree
	 * compares against, not AMIX's 40/60.
	 */
	fpe_cputype = (cputype == 60) ? NB_CPU_68060 : NB_CPU_68040;

	/*
	 * THE FRAME SHIM.  AMIX's trap block is FIFTEEN registers -- D0-D7 and A0-A6 -- with A7
	 * living outside it as the USP pseudo-register at u_ar0; NetBSD's tf_regs[16] wants A7
	 * at index 15.  That single difference is why a `struct frame *` cannot simply point at
	 * the AMIX block: f_regs[15] would read the exception SR.
	 *
	 * The format-4 tail is carried across UNCLOBBERED.  f_pcfi at +12 is the field
	 * fpu_emulate.c:108-125 takes the faulting instruction's address from, and it is the
	 * whole reason this arm sits at the top of the vector rather than downstream of the
	 * 060 package (contract 6.3).
	 */
	for (i = 0; i < 15; i++)
		f.f_regs[i] = regs[i];
	f.f_regs[15] = (int)*uspp;
	f.F_t.tf_pad = 0;
	f.f_stackadj = 0;
	f.f_sr = *(unsigned short *)(xf + 0);
	stacked_pc = *(unsigned int *)(xf + 2);
	f.f_pc = stacked_pc;
	fmtvec = *(unsigned short *)(xf + 6);
	f.f_format = (fmtvec >> 12) & 0xf;
	f.f_vector = fmtvec & 0x0fff;
	f.f_fmt4.f_fa = *(unsigned int *)(xf + 8);
	f.f_fmt4.f_fslw = *(unsigned int *)(xf + 12);

	/*
	 * The FP state, as a fixed bias off fpu_ptr.  No transposition and no copy: the
	 * assertions at the top of this file are what make that legitimate, and a grep gate in
	 * relink-040-fpe.sh is what keeps it legitimate -- the emulator must reference only the
	 * four tail members, never the FSAVE union in front of them, which this pointer does
	 * not address.
	 */
	fpf = (struct fpframe *)((char *)&fpu_ptr->regs - FPF_REGS_OFF);

	ksi.ksi_signo = 0;
	ksi.ksi_code = 0;
	ksi.ksi_errno = 0;
	ksi.ksi_addr = (void *)0;
	ksi.ksi_trap = 0;
	fpe_abort_signo = 0;
	fpe_abort_code = 0;
	fpe_abort_addr = 0;
	fpe_cur = &f;

	/*
	 * The abort target.  fpe_setjmp/fpe_longjmp save and restore exactly the callee-saved
	 * set (d2-d7/a2-a6) plus SP and the return address, so every local that matters here is
	 * either in one of those or reloaded from a stack slot the way an ordinary call already
	 * requires.  No local is written between the setjmp and a possible longjmp.
	 */
	if (fpe_setjmp(fpe_jb) == 0) {
		fpe_jb_active = 1;
		r = fpu_emulate(&f, fpf, &ksi);
	} else {
		r = -1;
		ksi.ksi_signo = fpe_abort_signo;
		ksi.ksi_code = fpe_abort_code;
		ksi.ksi_addr = (void *)fpe_abort_addr;
	}
	fpe_jb_active = 0;
	fpe_cur = (struct frame *)0;

	fpe_busy = 0;
	wakeup((caddr_t)&fpe_busy);

	/*
	 * WRITE BACK.  Registers, the final PC, and A7 through the pseudo-register slot.
	 *
	 * NO SECOND PC ADJUSTMENT.  The emulator advanced f_pc itself -- including its own
	 * one-shot format-4 reconstruction from f_pcfi, which the top-of-vector attach point
	 * guarantees runs exactly once (contract 3.7 item 1, 6.3).  Adding anything here would
	 * resume the process one instruction late.
	 *
	 * SR, the format/vector word and the format-4 tail are left exactly as the CPU wrote
	 * them: the frame stays an eight-word format-4 frame, and the RTE at the end of ureturn
	 * pops sixteen bytes.  No FP instruction writes the integer condition codes, so there
	 * is nothing in SR for the emulation to have changed -- and the extracted tree touches
	 * neither f_sr nor f_stackadj, which is checked by grep and not assumed.
	 */
	for (i = 0; i < 15; i++)
		regs[i] = f.f_regs[i];
	*uspp = (unsigned int)f.f_regs[15];
	*(unsigned int *)(xf + 2) = f.f_pc;

	if (r == 0) {
		/*
		 * INSTRUCTION-LENGTH INSTRUMENTATION, pre-registered for round 3 and free.
		 * On a format-4 frame the CPU stacks the PC of the instruction AFTER the
		 * faulting one, and the emulator independently computes f_pcfi +
		 * insn.is_advance.  They must agree.  Contract 6.3 names a wrong is_advance as
		 * the sharpest standing risk in the package -- NetBSD's own comment calls the
		 * format-4 path a hack, because it presumes the emulator knows the length of
		 * every instruction it meets, and on an LC060 it is not a corner case but the
		 * only path.  Comparing the two costs one compare per instruction and turns
		 * that from an argument into a number.
		 *
		 * MEASURED, NOT ACTED ON: the emulator's PC is used either way, so this cannot
		 * change what the lane does.
		 */
		if (f.f_pc != stacked_pc) {
			fpe_advmiss_n++;
			if ((unsigned long)fpe_b_pc == 0xffffffff) {
				fpe_b_pc = (long)f.f_fmt4.f_fslw;
				fpe_b_stacked = (long)stacked_pc;
				fpe_b_resume = (long)f.f_pc;
			}
		}
		fpe_done_n++;

		/*
		 * ASYNCHRONOUS SIGNAL DELIVERY, and it is not optional.  s_trap -- which ureturn
		 * calls on the way out -- has no issig/psig loop; that loop lives in u_trap,
		 * which this path deliberately does not run.  Until round 4 the pair was reached
		 * only from fpe_signal(), i.e. only when the EMULATOR raised a signal, so a
		 * process whose only traps were successful emulations never looked at its pending
		 * signals: round 3 measured alarm(2) never firing into a pure-FP loop and `kill
		 * -9` returning success while the process kept accumulating CPU time.  Three such
		 * processes could not be removed and the rig had to be power-cut.
		 *
		 * THE GATE IS WHAT MAKES IT AFFORDABLE.  This is the hot path -- one entry per
		 * emulated FP instruction -- so fpe_sigpend() reproduces u_trap's own cheap
		 * three-condition proc-structure test (p_cursig, p_sig, p_flag & SPRSTOP) and
		 * issig() runs only when it says there is something to look at.  Sixteen
		 * instructions and four loads, against the 8.6 user-memory fetches the emulator
		 * already makes per instruction.  The decode is in src/fpe040.s.
		 *
		 * THE INSTANT IS RIGHT, and that is why this sits here and not earlier: the
		 * registers, the USP and the final PC have already been written back into the
		 * supervisor-stack block above, and u.u_ar0 was set before the emulator ran.  So
		 * sendsig, reaching through u_ar0, finds the post-emulation state a handler must
		 * resume on -- exactly the state u_trap is in when it runs the same two calls.
		 * psig() may not return (a fatal signal exits); neither may u_trap's.
		 */
		if (fpe_sigpend()) {
			fpe_sigpend_n++;
			if (issig(0)) {
				fpe_sigdeliv_n++;
				psig();
			}
		}
		return 0;
	}

	/* ---- a signal was requested ---- */
	fpe_sig_n++;
	signo = ksi.ksi_signo;
	code = ksi.ksi_code;

	if (signo == SIGFPE && code == 0) {
		code = fpe_fltcode(fpf);
		if (code == 0) {
			/*
			 * SIGFPE with nothing enabled and raised.  There is no honest SVR4 code
			 * for that, and inventing one would be worse than saying so: frozen
			 * decision 8's fallback is SIGILL plus a latched counter.
			 */
			fpe_undecoded_n++;
			signo = SIGILL;
			code = ILL_ILLOPC;
		}
	}

	switch (signo) {
	case SIGFPE:
		fpe_sigfpe_n++;
		break;
	case SIGILL:
		fpe_sigill_n++;
		break;
	case SIGSEGV:
		fpe_sigsegv_n++;
		break;
	default:
		fpe_sigother_n++;
		break;
	}

	fpe_signal(signo, code, (long)ksi.ksi_addr);
	return 1;
}
