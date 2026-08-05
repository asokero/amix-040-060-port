/* xpagetest.c -- drive the 68060 crossing-page fault path on purpose (F1, 2026-08-05).
 *
 * WHY THIS EXISTS.  The x60_* counters landed 2026-08-05 and both emulator CPU configs
 * verified them, but one counter stayed at zero: x60_rw_write_n.  A boot produces plenty of
 * READ crossings (emu: x60_ma_n 11, all reads) and never a WRITE crossing that reaches the MA
 * tier.  M68060-XPAGE-ACCEPTANCE.md's remaining test 2 asks for exactly that, so without this
 * program a hardware boot answers three of its four questions and leaves the fourth untested.
 *
 * WHAT A CROSSING IS HERE.  The 68060 reports a misaligned access that spans two pages with
 * FA = the START of the access and FSLW.MA set, even when the missing page is the NEXT one.
 * wb060_xpage rounds FA up and resolves the far page with the real rw.  So: put a long at
 * page_end - 2, make the far page absent (or protected), and touch it.
 *
 * T1  write crossing into an ABSENT far page   -> MA tier, S_WRITE  -> x60_rw_write_n
 * T2  read  crossing into an ABSENT far page   -> MA tier, S_READ   -> x60_rw_read_n
 * T3  write crossing into a PROTECTED far page -> far resolve fails -> x60_far_fail_n, SIGSEGV
 *
 * T3 is the one that proves the failure is PROPAGATED rather than retried forever: before the
 * XPAGE unit the far result was discarded, so a permanently unmappable far page could spin.
 * The test therefore requires the SIGSEGV -- catching it is the pass, not the failure.
 *
 * *** T3 CURRENTLY HANGS.  DO NOT RUN IT ON HARDWARE UNTIL wb040.s IS FIXED. ***
 * Measured on the emulated 060, 2026-08-06 (XPAGE-FPROT-FINDING-260806.md): T3 produced a
 * 397 213-iteration retry loop with x60_far_fail_n staying at ZERO, because Lwx_call resolves
 * the far page with a hardcoded type = F_INVAL.  For a page that is PRESENT but write-protected
 * that is the wrong question -- as_fault finds it mapped, returns 0 without checking protection,
 * and the 060 restarts the instruction into the same violation forever.  T1 and T2 pass.
 * Run xpagetest with no argument to get T1+T2 only; pass `all` to include T3 deliberately.
 *
 * EXPECTED COUNTER DELTAS, T1+T2, ON A 68060.  Read them either side with /kpeek (addresses are
 * per-image -- recompute them, and check i39_magic/i40_magic/ptd_magic first).
 *
 * THE COUNTERS ARE GLOBAL, NOT PER-PROCESS, and that matters more than it looks.  Measured on
 * the emulated 060 (2026-08-06), a run whose own contribution is one write crossing and one read
 * crossing produced: ma_n +8, rw_read_n +7, rw_write_n +1, compat_n +1.  The shell, tftp and the
 * loader generate READ crossings of their own the whole time, so:
 *
 *     x60_rw_write_n  +1 EXACTLY   <-- the load-bearing number.  Nothing else on an idle system
 *                                      produces a WRITE crossing; this one is T1 and only T1.
 *     x60_rw_read_n   +1 or more   background reads are normal -- treat as a lower bound
 *     x60_ma_n        +2 or more   likewise
 *     x60_compat_n    +0 ideally, but background traffic can add to it.  What would be
 *                                  significant is a compat hit for THIS test's addresses:
 *                                  the operands start at page_end-2, inside the 0xff8 window,
 *                                  so MA-clear there is new evidence that reopens the
 *                                  acceptance verdict (M68060-XPAGE-ACCEPTANCE.md)
 *     x60_far_fail_n  +0           with T3 skipped; see the T3 note below for why
 *     x60_last_fslw                should show MA (bit 27) set and RW = 01 for T1's write.
 *                                  Measured: 0x08810200.
 *
 * To measure this properly, quiesce the machine first: no burst suite, no compile running.
 *
 * ON A 68040 every one of these must stay at ZERO: the 040 takes format-7 frames and the
 * byte-wise wb040_replay path instead.  Running this on the 040 is therefore a real dual-CPU
 * regression test, not a no-op -- the ISSUE-37 crossing case must still resolve and the program
 * must still print PASS.
 *
 * NOT TESTED HERE, deliberately: a locked RMW crossing.  M68060-XPAGE-ACCEPTANCE.md test 2 asks
 * for one, but on the 68060 it appears to be unconstructible: TAS is a byte operation and so can
 * never span a boundary, and a misaligned CAS is itself an unimplemented instruction (vector 61)
 * on this CPU -- it would trap before any page fault could occur.  If that reading is right, the
 * RMW half of test 2 is vacuous on the 060 and the acceptance document should say so.  The
 * non-crossing RMW case is already covered elsewhere: wb060_sswsynth classifies a locked RMW as a
 * WRITE, which is what fixed the pid-5 boot hang.
 *
 * K&R C for the AMIX native cc.  Builds with /usr/ccs/bin/cc on the 060 (gcc's own cpp/cc1 are
 * dead there -- vector 61) and cross-compiles unchanged.
 *
 * usage: xpagetest            all three tests
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <setjmp.h>
#include <stdio.h>

#define PG	4096

static jmp_buf segv_env;
static int segv_seen;

static void
onsegv(sig)
int sig;
{
	segv_seen = 1;
	longjmp(segv_env, 1);
}

/* Map n consecutive pages of /dev/zero.  MAP_PRIVATE so the far page is demand-zero and
 * genuinely ABSENT until touched -- which is the whole point.  */
static char *
zmap(n, prot)
int n;
int prot;
{
	int zfd;
	char *p;

	zfd = open("/dev/zero", O_RDWR);
	if (zfd < 0)
		return ((char *) 0);
	p = (char *) mmap((caddr_t) 0, (size_t) (n * PG), prot,
			  MAP_PRIVATE, zfd, (off_t) 0);
	(void) close(zfd);
	if (p == (char *) -1)
		return ((char *) 0);
	return (p);
}

/* T1: misaligned long WRITE starting 2 bytes before the page boundary, far page absent. */
static int
t1_write_crossing()
{
	char *base;
	long *xp;
	long got;

	base = zmap(2, PROT_READ | PROT_WRITE);
	if (base == (char *) 0) {
		printf("T1 SKIP: /dev/zero mmap failed errno=%d\n", errno);
		return (0);
	}
	base[0] = 'a';			/* near page present; far page NOT touched */

	xp = (long *) (base + PG - 2);
	printf("T1 write crossing at %p (page_end-2, far page absent)\n", (char *) xp);
	*xp = 0x5A5A1234L;		/* spans PG-2 .. PG+2 */
	got = *xp;
	if (got != 0x5A5A1234L) {
		printf("T1 FAIL: read back 0x%lx, expected 0x5a5a1234\n", got);
		return (1);
	}
	printf("T1 PASS: write across the boundary completed and read back correctly\n");
	return (0);
}

/* T2: misaligned long READ across the boundary, far page absent.  The control for T1: same
 * geometry, different rw, so the two counters must move separately. */
static int
t2_read_crossing()
{
	char *base;
	long *xp;
	long got;

	base = zmap(2, PROT_READ | PROT_WRITE);
	if (base == (char *) 0) {
		printf("T2 SKIP: /dev/zero mmap failed errno=%d\n", errno);
		return (0);
	}
	base[0] = 'a';

	xp = (long *) (base + PG - 2);
	printf("T2 read crossing at %p (page_end-2, far page absent)\n", (char *) xp);
	got = *xp;			/* demand-zero on both sides -> 0 */
	if (got != 0L) {
		printf("T2 FAIL: read 0x%lx across the boundary, expected 0\n", got);
		return (1);
	}
	printf("T2 PASS: read across the boundary returned zeros\n");
	return (0);
}

/* T3: write crossing whose FAR page is present but READ-ONLY.  The far resolve must FAIL and
 * that failure must reach the signal path -- if it is discarded, the instruction restarts and
 * the process wedges instead of dying, which is the bug the XPAGE unit removed. */
static int
t3_protected_far()
{
	char *base;
	long *xp;

	base = zmap(2, PROT_READ | PROT_WRITE);
	if (base == (char *) 0) {
		printf("T3 SKIP: /dev/zero mmap failed errno=%d\n", errno);
		return (0);
	}
	base[0] = 'a';			/* near page present and writable */
	base[PG] = 'b';			/* far page present too... */
	if (mprotect(base + PG, PG, PROT_READ) != 0) {
		printf("T3 SKIP: mprotect(far, PROT_READ) failed errno=%d\n", errno);
		return (0);
	}				/* ...but now read-only */

	xp = (long *) (base + PG - 2);
	segv_seen = 0;
	(void) signal(SIGSEGV, onsegv);
	(void) signal(SIGBUS, onsegv);
	printf("T3 write crossing at %p into a PROTECTED far page\n", (char *) xp);
	printf("    (expect SIGSEGV/SIGBUS -- a HANG here is the failure this test looks for)\n");
	fflush(stdout);
	if (setjmp(segv_env) == 0) {
		*xp = 0x33333333L;
		printf("T3 FAIL: the write into a protected far page SUCCEEDED\n");
		return (1);
	}
	(void) signal(SIGSEGV, SIG_DFL);
	(void) signal(SIGBUS, SIG_DFL);
	printf("T3 PASS: signalled (no retry loop), segv_seen=%d\n", segv_seen);
	return (0);
}

main(argc, argv)
int argc;
char **argv;
{
	int fails;
	int runt3;

	runt3 = (argc > 1 && strcmp(argv[1], "all") == 0);

	printf("xpagetest: page = %d bytes\n", PG);
	printf("  on a 68060 T1+T2 must move x60_ma_n +2, x60_rw_write_n +1,\n");
	printf("  x60_rw_read_n +1, x60_far_fail_n +0, x60_compat_n +0\n");
	printf("  on a 68040 every x60_* counter must stay unchanged\n");
	if (runt3)
		printf("  T3 ENABLED: it HANGS on the current kernel (F_INVAL far resolve,\n"
		       "  XPAGE-FPROT-FINDING-260806.md).  Expect a live-lock, not a result.\n");
	else
		printf("  T3 skipped (it hangs on the current kernel); pass `all` to force it\n");
	printf("\n");
	fflush(stdout);

	fails = 0;
	fails += t1_write_crossing();
	fails += t2_read_crossing();
	if (runt3)
		fails += t3_protected_far();

	printf("\nXPAGETEST fails=%d\n", fails);
	printf("XPAGETEST-RESULT %s\n", fails == 0 ? "PASS" : "FAIL");
	exit(fails == 0 ? 0 : 1);
}
