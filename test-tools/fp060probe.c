/* fp060probe.c -- which FP instructions does THIS kernel fail to emulate? (2026-08-07)
 *
 * WHY.  On the 68060 every FPSP entry in prototypes/fpsp_glue040.s is gated on
 * `cmpl #40,cputype` and falls through to `nullvect`, so the 68040 FPSP is inert and the
 * 060 has no FP support package at all.  The predicted consequence is that any FP
 * instruction the 060 does not implement in hardware dies on the stock nullvect path --
 * which produces SIGSYS, printed by the shell as "bad system call".
 *
 * That prediction had only one hardware datapoint, and an indirect one: /usr/ccs/lib/acomp
 * dies with status 0140 = SIGSYS on a double-returning Newton sqrt (060-F0-MEASUREMENT-260805.md).
 * The vector was never proven, because the kernel prints a vector only for SIGKILL kills.
 * This probe closes that in USER SPACE, with no kernel code: it executes one named
 * instruction per child and reports how the child died.
 *
 * READING THE RESULT
 *   survived            the 060 implements it in hardware (or something emulated it)
 *   SIGSYS (12)         reached nullvect: unimplemented, and nothing handled it  <- the claim
 *   SIGILL/SIGFPE       a different classification -- interesting, report it
 *   SIGKILL (9)         the vector-61 integer path, NOT this one (console prints its vector)
 *
 * CONTAINMENT: one child per instruction, no handler, so a death is a result and never
 * takes the parent with it.  Same shape as protfault.c.
 *
 * Cross-compiled (m68k-cbm-sysv4-gcc -m68020 -m68881); the guest's own compilers cannot be
 * trusted for FP source on this machine -- that is the very thing being measured.
 *
 * usage: fp060probe
 */

#include <stdio.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

static double in_val = 0.5;
static double out_val = 0.0;

/* Each probe runs exactly one FP instruction on fp0.  Kept as separate functions so the
   instruction under test is the only FP opcode in the child's path after the fork. */

static void
p_fadd()
{
	__asm__ volatile ("fmoved %1,%%fp0\n\tfaddx %%fp0,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : "m" (in_val));
}

static void
p_fsqrt()
{
	__asm__ volatile ("fmoved %1,%%fp0\n\tfsqrtx %%fp0,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : "m" (in_val));
}

static void
p_fintrz()
{
	__asm__ volatile ("fmoved %1,%%fp0\n\tfintrzx %%fp0,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : "m" (in_val));
}

static void
p_fsin()
{
	__asm__ volatile ("fmoved %1,%%fp0\n\tfsinx %%fp0,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : "m" (in_val));
}

static void
p_fetox()
{
	__asm__ volatile ("fmoved %1,%%fp0\n\tfetoxx %%fp0,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : "m" (in_val));
}

static void
p_flogn()
{
	__asm__ volatile ("fmoved %1,%%fp0\n\tflognx %%fp0,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : "m" (in_val));
}

static void
p_fmovecr()
{
	__asm__ volatile ("fmovecrx &0x00,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : );
}

static int
probe(name, fn)
char *name;
void (*fn)();
{
	int status, sig, code;
	pid_t pid, got;

	fflush(stdout);
	pid = fork();
	if (pid < 0) {
		printf("  %-10s SKIP: fork failed\n", name);
		return (0);
	}
	if (pid == 0) {
		(*fn)();
		_exit(0);			/* survived: implemented, or emulated */
	}
	got = wait(&status);
	if (got != pid) {
		printf("  %-10s SKIP: wait mismatch\n", name);
		return (0);
	}
	sig = status & 0x7f;
	code = (status >> 8) & 0xff;
	if (sig == 0) {
		printf("  %-10s survived (exit %d)\n", name, code);
		return (0);
	}
	printf("  %-10s DIED by signal %d%s\n", name, sig,
	       sig == SIGSYS ? "  <- SIGSYS: reached nullvect, nothing emulated it" :
	       sig == SIGILL ? "  <- SIGILL" :
	       sig == SIGFPE ? "  <- SIGFPE" :
	       sig == SIGKILL ? "  <- SIGKILL (vector-61 integer path, not FP)" : "");
	return (1);
}

main()
{
	int died;

	printf("fp060probe: which FP instructions does this kernel leave unhandled?\n");
	printf("  one child per instruction; a death is the result, not a failure of the test\n\n");

	died = 0;
	printf("implemented on both 040 and 060 (control group -- these MUST survive):\n");
	died += probe("fadd", p_fadd);
	died += probe("fsqrt", p_fsqrt);

	/* fintrz was expected to fail here and does NOT: measured 2026-08-07 on real
	   silicon, the 68060 retires it in hardware.  Left in the list as a control. */
	printf("\nunimplemented on the 68060 (the FPSP's job) -- fintrz measured OK:\n");
	died += probe("fintrz", p_fintrz);
	died += probe("fsin", p_fsin);
	died += probe("fetox", p_fetox);
	died += probe("flogn", p_flogn);
	died += probe("fmovecr", p_fmovecr);

	printf("\nFP060PROBE died=%d\n", died);
	printf("FP060PROBE-DONE\n");
	exit(0);
}
