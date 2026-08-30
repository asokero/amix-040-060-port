/* fp060probe.c -- which FP instructions does THIS kernel emulate, and does it emulate them
 * CORRECTLY?  (2026-08-07; value checking added for F3 M2b, 2026-08-08)
 *
 * WHY.  On the 68060 every FPSP entry in src/fpsp_glue040.s is gated on
 * `cmpl #40,cputype` and, before F3, fell through to `nullvect`, so the 68040 FPSP was inert
 * and the 060 had no FP support package at all.  Any FP instruction the 060 does not retire
 * in hardware died with SIGSYS -- which the shell prints as "bad system call".
 *
 * Measured 2026-08-07 on real silicon (docs/060-FPU-STATE-260807.md):
 *     fadd fsqrt fintrz          survived
 *     fsin fetox flogn fmovecr   SIGSYS (12)
 *
 * WHY IT NOW CHECKS THE VALUE.  F3 M2b hooks Motorola's M68060 FPSP to vector 11, so the
 * question stops being "does the child live" and becomes "is the answer right".  Those are
 * different questions and this project has already been caught confusing them once: protfault
 * concluded a store had succeeded because the child survived, and the measurement said the
 * opposite.  An FPSP that returns the wrong constant, or reads the wrong operand through a
 * broken memory call-out, is WORSE than one that signals -- it is silent.  So each probe now
 * ships its result back through a pipe and it is compared against the IEEE-754 bit pattern.
 *
 * THE PARENT NEVER TOUCHES A DOUBLE.  Results travel as 8 raw bytes and are compared as two
 * unsigned longs.  That is deliberate: this program has to keep working on a kernel whose FP
 * emulation is broken, and a printf("%f") in the parent would put the diagnostic itself on the
 * path under test.
 *
 * READING THE RESULT
 *   OK                  emulated (or retired in hardware) and the value is right
 *   VALUE WRONG         it survived and lied.  The most important line this program can print.
 *   SIGSYS (12)         reached nullvect: unimplemented, and nothing handled it
 *   SIGILL/SIGFPE       a different classification -- interesting, report it
 *   SIGKILL (9)         the vector-61 integer path, NOT this one (console prints its vector)
 *
 * CONTAINMENT: one child per instruction, no handler, so a death is a result and never takes
 * the parent with it.  Same shape as protfault.c.
 *
 * CROSS-BUILD ONLY -- this does NOT build with the box's native K&R `cc`.  The probes use GNU C
 * `__asm__ volatile`, which the guest's 1991 AT&T cc does not know; a native build dies with
 * "undefined symbol: __asm__".  That is a TOOLCHAIN mismatch, not a measurement -- do not read the
 * native error as a result.  Build only with the m68k-cbm-sysv4 cross toolchain on the host and
 * transfer the binary:
 *     m68k-cbm-sysv4-gcc -m68020 -m68881 -o fp060probe fp060probe.c
 * (See test-tools/mk060.sh, which builds it this way for exactly this reason.)  The guest's own
 * compilers cannot be trusted for FP source anyway -- that is the very thing being measured.
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

/* fmovecr &0x00 is the FPU ROM's pi.  It matters more than it looks: gcc emits fmovecr for
   ordinary FP literals (offset 0x32 = 1.0, 0x0F = 0.0), which is why `x = 1.0;` was enough to
   kill a process on this CPU before F3. */
static void
p_fmovecr()
{
	__asm__ volatile ("fmovecrx &0x00,%%fp0\n\tfmoved %%fp0,%0"
			  : "=m" (out_val) : );
}

/* Expected results as IEEE-754 double bit patterns, high word then low word.
   in_val is 0.5 throughout.  Computed on the host, not on the machine under test. */
static int
probe(name, fn, exhi, exlo, tol)
char *name;
void (*fn)();
unsigned long exhi, exlo;
unsigned long tol;			/* permitted |low-word| difference, in ULPs */
{
	int status, sig, code, fd[2], n;
	int pid, got;
	unsigned char buf[8];
	unsigned long hi, lo, diff;

	fflush(stdout);
	if (pipe(fd) < 0) {
		printf("  %-10s SKIP: pipe failed\n", name);
		return (1);
	}
	pid = fork();
	if (pid < 0) {
		printf("  %-10s SKIP: fork failed\n", name);
		close(fd[0]); close(fd[1]);
		return (1);
	}
	if (pid == 0) {
		close(fd[0]);
		(*fn)();
		write(fd[1], (char *)&out_val, 8);
		close(fd[1]);
		_exit(0);		/* survived: implemented, or emulated */
	}
	close(fd[1]);
	n = read(fd[0], (char *)buf, 8);
	close(fd[0]);
	got = wait(&status);
	if (got != pid) {
		printf("  %-10s SKIP: wait mismatch\n", name);
		return (1);
	}
	sig = status & 0x7f;
	code = (status >> 8) & 0xff;
	if (sig != 0) {
		printf("  %-10s DIED by signal %d%s\n", name, sig,
		       sig == SIGSYS ? "  <- SIGSYS: reached nullvect, nothing emulated it" :
		       sig == SIGILL ? "  <- SIGILL" :
		       sig == SIGFPE ? "  <- SIGFPE" :
		       sig == SIGKILL ? "  <- SIGKILL (vector-61 integer path, not FP)" : "");
		return (1);
	}
	if (n != 8) {
		printf("  %-10s survived (exit %d) but sent %d bytes, not 8 -- NO VALUE\n",
		       name, code, n);
		return (1);
	}

	/* big-endian: the 68060 hands the bytes over in memory order */
	hi = ((unsigned long)buf[0] << 24) | ((unsigned long)buf[1] << 16)
	   | ((unsigned long)buf[2] << 8)  |  (unsigned long)buf[3];
	lo = ((unsigned long)buf[4] << 24) | ((unsigned long)buf[5] << 16)
	   | ((unsigned long)buf[6] << 8)  |  (unsigned long)buf[7];

	if (hi != exhi) {
		printf("  %-10s survived, VALUE WRONG  got %08lX%08lX  want %08lX%08lX\n",
		       name, hi, lo, exhi, exlo);
		return (1);
	}
	diff = (lo > exlo) ? (lo - exlo) : (exlo - lo);
	if (diff > tol) {
		printf("  %-10s survived, VALUE WRONG  got %08lX%08lX  want %08lX%08lX (%lu ulp)\n",
		       name, hi, lo, exhi, exlo, diff);
		return (1);
	}
	printf("  %-10s OK  %08lX%08lX  (%lu ulp)\n", name, hi, lo, diff);
	return (0);
}

main()
{
	int bad;

	printf("fp060probe: does this kernel emulate these FP instructions, and correctly?\n");
	printf("  one child per instruction; the value comes back through a pipe and is\n");
	printf("  compared against the IEEE-754 bit pattern.  Survival is not correctness.\n\n");

	bad = 0;
	printf("implemented on both 040 and 060 (control group -- these MUST be OK):\n");
	bad += probe("fadd",    p_fadd,    0x3FF00000L, 0x00000000L, 0L);  /* 0.5+0.5 = 1.0     */
	bad += probe("fsqrt",   p_fsqrt,   0x3FE6A09EL, 0x667F3BCDL, 2L);  /* sqrt(0.5)         */

	/* fintrz was expected to fail here and does NOT: measured 2026-08-07 on real
	   silicon, the 68060 retires it in hardware.  Left in the list as a control. */
	printf("\nnot retired by 68060 hardware -- the FPSP's job (fintrz measured OK):\n");
	bad += probe("fintrz",  p_fintrz,  0x00000000L, 0x00000000L, 0L);  /* trunc(0.5) = 0.0  */
	bad += probe("fsin",    p_fsin,    0x3FDEAEE8L, 0x744B05F0L, 2L);  /* sin(0.5)          */
	bad += probe("fetox",   p_fetox,   0x3FFA6129L, 0x8E1E069CL, 2L);  /* exp(0.5)          */
	bad += probe("flogn",   p_flogn,   0xBFE62E42L, 0xFEFA39EFL, 2L);  /* ln(0.5)           */
	bad += probe("fmovecr", p_fmovecr, 0x400921FBL, 0x54442D18L, 0L);  /* pi, exact ROM     */

	printf("\nFP060PROBE bad=%d\n", bad);
	printf("FP060PROBE-DONE\n");
	exit(0);
}
