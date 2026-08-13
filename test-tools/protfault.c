/* protfault.c -- the three protected-page cases, each in its own child (2026-08-06).
 *
 * Spec: amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md Q5 (Codex, 0a3aab3).
 * Replaces xpagetest's T3, which conflated three different faults into one unsafe test
 * and could wedge or panic the machine (docs/XPAGE-FPROT-FINDING-260806.md).
 *
 * WHAT IS BEING SEPARATED.  Codex's static reading of the linked kernel says the missing
 * permission check is in segvn_faultpage's PER-PAGE branch, while segvn_fault's
 * SEGMENT-WIDE branch (0xac486: type==F_PROT && rw==S_WRITE && prot==PROT_READ -> FC_PROT)
 * is intact.  That is a prediction about behaviour, and these three cases test it:
 *
 *   A  one page, whole mapping protected      -> svd->pageprot == 0, segment-wide path
 *   B  two pages, only page 2 protected       -> svd->pageprot != 0, per-page path,
 *                                                aligned write INSIDE page 2 (no crossing)
 *   C  same as B, but the write CROSSES from page 1 into page 2 (the XPAGE case)
 *
 * B is the load-bearing one: it contains no page crossing at all, so on a 68040 it cannot
 * involve any 060 code.  If A terminates and B does not, the defect is in the generic VM
 * layer and nothing to do with the XPAGE unit -- which is exactly the claim under test.
 *
 * CONTAINMENT.  Each case runs in a fresh child with NO signal handler and NO setjmp: the
 * child is supposed to die, and its death is the result.  The parent arms a deadline only
 * after the child reports ready down a pipe, so a slow mmap cannot be mistaken for a hang.
 * A timeout is a DIAGNOSTIC, never a pass -- and it is not full containment either: a
 * kernel panic or a non-preemptible loop needs the host's own timeout on the emulator.
 *
 * Pages are touched before mprotect so that a fault reports policy, not demand paging.
 *
 * 2026-08-07 -- SURVIVAL IS NOT PROOF THAT THE PAGE CHANGED.  This test used to print
 * "the protected store SUCCEEDED (protection bypass)" whenever the child lived, which
 * infers a mechanism it never measured.  Codex's ISSUE-42 audit
 * (amix-kernel-analysis/vm-map/ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md) plus a counter
 * reading on the emulated 040 show the opposite: the 68040 write-back replay store DOES
 * fault (Lwbf_n 0->1 for one case C, with wb_replay_odd unchanged, so FC = 1 user data),
 * and Lwb_fail then swallows the failure and returns the outer resolver's success.  So a
 * surviving child means "no signal arrived", nothing more.
 *
 * The child therefore snapshots the target bytes after mprotect and reads them back if it
 * lives, and the two outcomes are now reported apart:
 *
 *   exit BYPASS    no signal AND the protected bytes changed -> the store reached the page
 *   exit SWALLOWED no signal and the protected bytes are intact -> denial thrown away
 *
 * Both are failures; they are different bugs, and a fix for one is not a fix for the other.
 *
 * usage: protfault [a|b|c]        (default: all three, in order)
 */

#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define PG	4096
#define BYPASS	42		/* survived, and the protected bytes CHANGED */
#define SWALLOWED 43		/* survived, protected bytes intact: the denial was discarded */
#define DEADLINE 8		/* seconds the parent waits after `ready` */

static int alarmed = 0;

static void
on_alarm(sig)
int sig;
{
	alarmed = 1;
}

static char *
zmap(n)
int n;
{
	int zfd;
	char *p;

	zfd = open("/dev/zero", O_RDWR);
	if (zfd < 0)
		return ((char *) 0);
	p = (char *) mmap((caddr_t) 0, (size_t) (n * PG), PROT_READ | PROT_WRITE,
			  MAP_PRIVATE, zfd, (off_t) 0);
	(void) close(zfd);
	if (p == (char *) -1)
		return ((char *) 0);
	return (p);
}

/* The child. Returns only if the protected store did NOT fault, which is itself a result. */
static void
child(kase, wfd)
int kase;
int wfd;
{
	char *base;
	char *target;
	int npages;
	int prot_off;
	int i;
	int changed;
	volatile long *lp;
	volatile char *vp;
	unsigned char before[4];
	unsigned char after[4];

	npages = (kase == 'a') ? 1 : 2;
	base = zmap(npages);
	if (base == (char *) 0)
		_exit(70);			/* mmap failed: environment, not kernel */

	base[0] = 1;				/* touch page 1 */
	if (npages == 2)
		base[PG] = 1;			/* touch page 2 */

	if (kase == 'a') {
		if (mprotect(base, (size_t) PG, PROT_READ) < 0)
			_exit(71);
		target = base;			/* aligned write inside the protected page */
		prot_off = 0;			/* all four bytes are on the protected page */
	} else {
		if (mprotect(base + PG, (size_t) PG, PROT_READ) < 0)
			_exit(71);
		if (kase == 'b') {
			target = base + PG + 64;	/* wholly inside page 2, aligned */
			prot_off = 0;
		} else {
			target = base + PG - 2;		/* CROSSES into page 2 */
			prot_off = 2;			/* target[2],[3] land on page 2 */
		}
	}

	/* Snapshot AFTER mprotect: the protected page stays readable, so this is the
	   reference the post-store comparison needs.  Read through a volatile pointer so
	   the compiler cannot satisfy the second read from this one. */
	vp = (volatile char *) target;
	for (i = 0; i < 4; i++)
		before[i] = (unsigned char) vp[i];

	(void) write(wfd, "r", 1);		/* ready: arm the parent's deadline */
	(void) close(wfd);

	lp = (volatile long *) target;
	*lp = 0x5a5a5a5aL;			/* exactly one store; this must fault */

	/* Reached only if no signal arrived -- which says nothing yet about whether the
	   protected bytes moved.  Read them back and report which of the two it was. */
	for (i = 0; i < 4; i++)
		after[i] = (unsigned char) vp[i];

	changed = 0;
	for (i = prot_off; i < 4; i++)
		if (after[i] != before[i])
			changed = 1;

	printf("  child survived the store.  protected bytes:");
	for (i = prot_off; i < 4; i++)
		printf(" %02x->%02x", before[i], after[i]);
	if (prot_off > 0) {
		printf("   unprotected half:");
		for (i = 0; i < prot_off; i++)
			printf(" %02x->%02x", before[i], after[i]);
	}
	printf("\n");
	fflush(stdout);

	_exit(changed ? BYPASS : SWALLOWED);
}

static int
run(kase)
int kase;
{
	int fds[2], status, sig, code, verdict;
	char rb;
	pid_t pid, got;

	printf("---- case %c: %s\n", kase,
	       kase == 'a' ? "one page, whole mapping protected (segment-wide path)" :
	       kase == 'b' ? "two pages, page 2 protected, aligned write INSIDE page 2" :
			     "two pages, page 2 protected, write CROSSING into it");
	fflush(stdout);

	if (pipe(fds) < 0) {
		printf("case %c SKIP: pipe failed errno=%d\n", kase, errno);
		return (0);
	}
	pid = fork();
	if (pid < 0) {
		printf("case %c SKIP: fork failed errno=%d\n", kase, errno);
		return (0);
	}
	if (pid == 0) {
		(void) close(fds[0]);
		child(kase, fds[1]);
		_exit(72);
	}
	(void) close(fds[1]);

	if (read(fds[0], &rb, 1) != 1) {
		/* The child died before reaching the store -- still a real result. */
		printf("  (child produced no ready byte)\n");
	}
	(void) close(fds[0]);

	alarmed = 0;
	(void) signal(SIGALRM, on_alarm);
	(void) alarm(DEADLINE);
	got = wait(&status);
	(void) alarm(0);

	if (got != pid && alarmed) {
		(void) kill(pid, SIGKILL);
		(void) wait(&status);
		printf("case %c TIMEOUT after %ds -- RETRY LOOP (kernel still schedulable)\n",
		       kase, DEADLINE);
		printf("  this is a diagnostic, NOT a pass\n");
		return (1);
	}

	sig = status & 0x7f;
	code = (status >> 8) & 0xff;
	if (sig == SIGSEGV) {
		printf("case %c PASS: child terminated by SIGSEGV\n", kase);
		verdict = 0;
	} else if (sig == SIGBUS) {
		printf("case %c FAIL: SIGBUS, not SIGSEGV (wrong classification)\n", kase);
		verdict = 1;
	} else if (sig != 0) {
		printf("case %c FAIL: terminated by signal %d\n", kase, sig);
		verdict = 1;
	} else if (code == BYPASS) {
		printf("case %c FAIL: no signal AND the protected bytes CHANGED\n", kase);
		printf("  the store reached the protected page -- a real protection bypass\n");
		verdict = 1;
	} else if (code == SWALLOWED) {
		printf("case %c FAIL: no signal, but the protected bytes are INTACT\n", kase);
		printf("  the store was denied and the denial was discarded -- ISSUE-42, not a bypass\n");
		verdict = 1;
	} else {
		printf("case %c SKIP: child exited %d (setup failure, not a kernel result)\n",
		       kase, code);
		verdict = 0;
	}
	return (verdict);
}

main(argc, argv)
int argc;
char **argv;
{
	int fails;

	printf("protfault: protected-page fault contract, one child per case\n");
	printf("  PREDICTION under test (XPAGE-FPROT-CONTRACT.md Q3): on a kernel without\n");
	printf("  the segvn_faultpage permission check, A terminates and B does NOT --\n");
	printf("  and B contains no page crossing, so on a 68040 no 060 code is involved.\n\n");
	fflush(stdout);

	fails = 0;
	if (argc > 1) {
		fails += run(argv[1][0]);
	} else {
		fails += run('a');
		fails += run('b');
		fails += run('c');
	}
	printf("\nPROTFAULT fails=%d\n", fails);
	printf("PROTFAULT-RESULT %s\n", fails == 0 ? "PASS" : "FAIL");
	exit(fails == 0 ? 0 : 1);
}
