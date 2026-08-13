/* ftest060.c -- run Motorola's own M68060 FPSP test suite against OUR kernel FPSP.
 *
 * WHY THIS AND NOT ONLY fp060probe.  fp060probe checks seven instructions against seven
 * constants I computed on the host.  ftest is Motorola's, it covers far more of the package,
 * and its expected values are the vendor's -- so it can fail in ways our own test cannot
 * even ask about.  That is the point of running it.
 *
 * THE PACKAGE IS IN THE KERNEL, NOT HERE.  This binary contains only Motorola's *test*
 * image (dist/ftest.sa) plus a 128-byte call-out section pointing at printf.  The
 * instructions it executes trap to vector 11 and are emulated by the FPSP the kernel links
 * in (src/fpsp060_glue.s + Motorola's fpsp.sa).  So a pass here is a statement about
 * the kernel, measured with the vendor's own yardstick.
 *
 * WHAT EACH ENTRY POINT MEANS (dist/test.doc), and what to expect on AMIX today:
 *
 *   0x00  main       unimplemented effective address (vector 60), unsupported data types
 *                    (vector 55) and non-maskable overflow/underflow.  Vectors 55 and 60 are
 *                    F3 M3, NOT hooked on the 68060 yet -- so this one is expected to fail or
 *                    die, and it is run anyway because "expected to fail" is a prediction and
 *                    predictions are worth measuring.
 *   0x08  unimp      FP unimplemented instructions.  THIS IS WHAT M2b IMPLEMENTS.
 *   0x10  enabled    enabled snan/operr/ovfl/unfl/dz/inex.  test.doc: "the test expects
 *                    _real_XXXX() to do nothing except clear the exception and rte.  If a
 *                    system's _real_XXXX() handler creates an alternate result, the test will
 *                    print 'failed' but this is acceptable."  AMIX delivers SIGFPE, which is
 *                    the correct Unix behaviour and the documented "acceptable" failure.
 *
 * Each entry runs in its own child, so a signal is a result rather than the end of the run --
 * the containment shape of protfault.c and fp060probe.c.
 *
 * Cross-compiled: m68k-cbm-sysv4-gcc, with the image assembled by m68k-linux-gnu-gcc.
 * See build-ftest060.sh.
 *
 * usage: ftest060 [main|unimp|enabled|all]      default: unimp
 */

#include <stdio.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

extern int ftest060_run();

static int
run_one(name, off)
char *name;
int off;
{
	int status, sig, code;
	int pid, got;

	printf("======== ftest060 %s (entry TOP+128+0x%02x) ========\n", name, off);
	fflush(stdout);
	pid = fork();
	if (pid < 0) {
		printf("  SKIP: fork failed\n");
		return (1);
	}
	if (pid == 0) {
		setbuf(stdout, (char *)0);	/* test.doc: do not buffer, so a crash still
						   shows everything printed before it */
		ftest060_run(off);
		_exit(0);
	}
	got = wait(&status);
	if (got != pid) {
		printf("  SKIP: wait mismatch\n");
		return (1);
	}
	sig = status & 0x7f;
	code = (status >> 8) & 0xff;
	if (sig != 0) {
		printf("  DIED by signal %d\n", sig);
		return (1);
	}
	printf("  child exited %d\n", code);
	return (0);
}

main(argc, argv)
int argc;
char **argv;
{
	char *what;
	int bad;

	what = (argc > 1) ? argv[1] : "unimp";
	bad = 0;

	if (strcmp(what, "main") == 0 || strcmp(what, "all") == 0)
		bad += run_one("main", 0x00);
	if (strcmp(what, "unimp") == 0 || strcmp(what, "all") == 0)
		bad += run_one("unimp", 0x08);
	if (strcmp(what, "enabled") == 0 || strcmp(what, "all") == 0)
		bad += run_one("enabled", 0x10);

	printf("\nFTEST060 died=%d\n", bad);
	printf("FTEST060-DONE\n");
	exit(0);
}
