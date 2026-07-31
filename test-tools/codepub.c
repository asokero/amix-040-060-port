/* codepub.c -- acceptance test for the user-code cache-publication ABI
 * (USER-CODE-PUBLISH, 2026-08-01).  Spec: analyysirepo
 * vm-map/USER-CODE-CACHE-ABI-SPEC.md; kernel unit prototypes/codepub040.s.
 *
 * THE ABI UNDER TEST
 *   A successful mprotect(addr, len, prot) whose prot contains PROT_EXEC is a
 *   publication barrier for every CPU store completed before the call -- EVEN
 *   IF the mapping already had exactly that protection.
 *
 * WHY EACH TEST IS SHAPED THE WAY IT IS
 *
 * The whole point is that "the generated code ran" is NOT evidence.  Under
 * write-through, or in Amiberry (which does not model the 040 copyback data
 * cache at all), every one of these tests passes on a kernel with NO
 * publication whatsoever.  The tests are therefore built so that on REAL 68040
 * copyback silicon the unpublished path is *expected to return the stale
 * value*, and the run is only meaningful next to the kernel counters
 * (codepub_calls / codepub_exec / codepub_push read with kpeek).
 *
 * T1 keeps the mapping RWX and publishes with a SAME-PROTECTION mprotect.
 * That is deliberate and is the decisive case: segvn_setprot returns success
 * early when the requested protection equals the current one, so hat_chgprot
 * is never reached and its incidental whole-cache push cannot help.  On a
 * stock kernel T1's publication is a no-op -- if T1 passes on real copyback
 * hardware, the wrapper is the only thing that could have done it.
 *
 * T1 also reports the UNPUBLISHED read (step 3) as data, not as pass/fail:
 *   stale value  = the cache hazard is real on this machine and this run
 *   fresh value  = the line happened to be evicted / the CPU happened to see it
 * Either way the ABI requirement is step 4: after publication the NEW function
 * must run.  A test that demanded staleness would fail for the wrong reason on
 * a write-through image.
 *
 * T2 uses the KERNEL as the writer (read(2) -> copyout into the code page), the
 * producer class that cb_icode040 handles on the boot path and that no user
 * cache operation can reach.
 *
 * T3 is the ordinary W->X path, which works on today's kernel BY ACCIDENT
 * (hat_chgprot's PTE tail).  It is here so the wrapper is proven not to have
 * broken it, not because it is the interesting case.
 *
 * T4 is the error path: the wrapper must return the stock errno untouched and
 * must NOT count a publication.  Checked against the counters afterwards.
 *
 * THE A/B (the actual proof, run from the shell, not from here):
 *   kpeek codepub_on codepub_calls codepub_exec codepub_push   (before)
 *   ./codepub
 *   kpeek ... (after)      -> push must advance exactly as exec did
 *   kpoke codepub_on 0 ; ./codepub ; kpeek ...
 *      -> exec still advances, push does NOT, and on real copyback T1 step 4
 *         is now allowed to FAIL.  That failure is the whole finding.
 *
 * EXPECTED COUNTER DELTAS FOR ONE CLEAN RUN (this is the falsifiable part --
 * "the counters moved" is not a result, these exact numbers are):
 *
 *     codepub_calls  +8    T1 2, T2 2, T3 1, T4 3
 *     codepub_exec   +5    T1 2, T2 2, T3 1, T4 0  (T4's two EXEC calls FAIL,
 *                                                   its third has no PROT_EXEC)
 *     codepub_push   +5    with codepub_on = 1
 *                    +0    with codepub_on = 0     <- the A/B image
 *
 * A run where codepub_exec advances by anything but 5 means the test changed
 * or a call was optimised away; a run where push != exec with the flag on
 * means the barrier did not execute.
 *
 * The generated functions are `moveq #N,d0 ; rts` = 70 NN 4e 75 -- four bytes,
 * one instruction fetch, no relocation, and the returned value NAMES which
 * version of the bytes the CPU actually executed.
 *
 * K&R C for the AMIX SVR4 native cc.  Compile on AMIX:  cc -o codepub codepub.c
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define PG	4096
#define TMPF	"/tmp/codepub.bin"

/* moveq #N,%d0 ; rts */
static
putfn(p, n)
char *p;
int n;
{
	p[0] = 0x70;
	p[1] = (char) n;
	p[2] = 0x4e;
	p[3] = 0x75;
}

static char *
zeromap(prot)
int prot;
{
	int zfd;
	char *p;

	zfd = open("/dev/zero", O_RDWR);
	if (zfd < 0)
		return ((char *) 0);
	p = (char *) mmap((caddr_t) 0, (size_t) PG, prot, MAP_PRIVATE,
			  zfd, (off_t) 0);
	(void) close(zfd);
	if (p == (char *) -1)
		return ((char *) 0);
	return (p);
}

static
callfn(p)
char *p;
{
	int (*fn) ();

	fn = (int (*) ()) p;
	return ((*fn) ());
}

static int fails = 0;

static
check(name, got, want)
char *name;
int got;
int want;
{
	if (got == want) {
		printf("    ok   %-34s -> %d\n", name, got);
	} else {
		printf("    FAIL %-34s -> %d (want %d)\n", name, got, want);
		fails++;
	}
}

/* ------------------------------------------------------------------ T1 */
static
t1()
{
	char *p;
	int i;
	int v;

	printf("  T1 same-protection RWX publication (the decisive case)\n");
	p = zeromap(PROT_READ | PROT_WRITE | PROT_EXEC);
	if (p == (char *) 0) {
		printf("    SKIP: RWX /dev/zero mmap failed errno=%d\n", errno);
		return;
	}

	/* A = 11: written, published, and thereby forced out to RAM. */
	putfn(p, 11);
	if (mprotect(p, PG, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
		printf("    FAIL mprotect(RWX) errno=%d\n", errno);
		fails++;
		return;
	}
	check("A after publication", callfn(p), 11);

	/* Execute A hard, so the instruction cache is holding A's line. */
	for (i = 0; i < 4000; i++)
		(void) callfn(p);

	/* B = 22: CPU stores only.  Under copyback these are dirty D lines and
	 * RAM still holds A; the 040 ifetch does not snoop them. */
	putfn(p, 22);
	v = callfn(p);
	printf("    data B before publication          -> %d  (%s)\n", v,
	       v == 11 ? "STALE: the hazard is real here"
		       : (v == 22 ? "already coherent (write-through, or evicted)"
				  : "unexpected"));

	/* The ABI requirement.  Same protection -> segvn_setprot short-circuits
	 * -> only the codepub040 wrapper can publish this. */
	if (mprotect(p, PG, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
		printf("    FAIL mprotect(RWX) 2 errno=%d\n", errno);
		fails++;
		return;
	}
	check("B after publication", callfn(p), 22);
}

/* ------------------------------------------------------------------ T2 */
static
t2()
{
	char *p;
	char buf[4];
	int fd;
	int n;

	printf("  T2 kernel writer: read(2) copyout into the code page\n");
	p = zeromap(PROT_READ | PROT_WRITE | PROT_EXEC);
	if (p == (char *) 0) {
		printf("    SKIP: RWX /dev/zero mmap failed errno=%d\n", errno);
		return;
	}
	putfn(p, 11);
	(void) mprotect(p, PG, PROT_READ | PROT_WRITE | PROT_EXEC);
	(void) callfn(p);

	putfn(buf, 33);
	fd = creat(TMPF, 0644);
	if (fd < 0) {
		printf("    SKIP: creat %s errno=%d\n", TMPF, errno);
		return;
	}
	(void) write(fd, buf, 4);
	(void) close(fd);

	fd = open(TMPF, O_RDONLY, 0);
	if (fd < 0) {
		printf("    SKIP: open %s errno=%d\n", TMPF, errno);
		return;
	}
	n = read(fd, p, 4);		/* the KERNEL writes the code bytes */
	(void) close(fd);
	if (n != 4) {
		printf("    FAIL read returned %d errno=%d\n", n, errno);
		fails++;
		return;
	}
	if (mprotect(p, PG, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
		printf("    FAIL mprotect(RWX) errno=%d\n", errno);
		fails++;
		return;
	}
	check("C from read(2) after publication", callfn(p), 33);
	(void) unlink(TMPF);
}

/* ------------------------------------------------------------------ T3 */
static
t3()
{
	char *p;

	printf("  T3 W->X transition (works today by accident; must not regress)\n");
	p = zeromap(PROT_READ | PROT_WRITE);
	if (p == (char *) 0) {
		printf("    SKIP: RW /dev/zero mmap failed errno=%d\n", errno);
		return;
	}
	putfn(p, 44);
	if (mprotect(p, PG, PROT_READ | PROT_EXEC) != 0) {
		printf("    FAIL mprotect(RX) errno=%d\n", errno);
		fails++;
		return;
	}
	check("D after RW->RX", callfn(p), 44);
}

/* ------------------------------------------------------------------ T4 */
static
t4()
{
	char *p;
	int r;

	printf("  T4 error paths: stock errno preserved, no publication counted\n");

	/* Unaligned address: the historical 0x7ff gate at 0x58572 -> EINVAL.
	 * This returns BEFORE valid_usr_range, so it never touches the VM. */
	errno = 0;
	r = mprotect((char *) 0x80800001L, PG,
		     PROT_READ | PROT_WRITE | PROT_EXEC);
	printf("    unaligned addr  -> r=%d errno=%d %s\n", r, errno,
	       (r == -1 && errno == EINVAL) ? "(ok EINVAL)" : "(CHECK)");
	if (!(r == -1 && errno == EINVAL))
		fails++;

	/* Aligned but not in this address space -> ENOMEM from valid_usr_range
	 * or as_setprot.  Either way the wrapper must not publish. */
	errno = 0;
	r = mprotect((char *) 0x7f000000L, PG,
		     PROT_READ | PROT_WRITE | PROT_EXEC);
	printf("    unmapped addr   -> r=%d errno=%d %s\n", r, errno,
	       (r == -1) ? "(ok, failed as expected)" : "(CHECK: succeeded!)");
	if (r != -1)
		fails++;

	/* A successful call WITHOUT PROT_EXEC: counts as a call, must not count
	 * as a publication event.  Verified against codepub_exec afterwards. */
	p = zeromap(PROT_READ | PROT_WRITE);
	if (p != (char *) 0) {
		errno = 0;
		r = mprotect(p, PG, PROT_READ | PROT_WRITE);
		printf("    RW (no PROT_EXEC) -> r=%d errno=%d %s\n", r, errno,
		       r == 0 ? "(ok, must NOT advance codepub_exec)" : "(CHECK)");
	}
}

main(argc, argv)
int argc;
char **argv;
{
	printf("codepub: user-code publication ABI acceptance\n");
	printf("  page size assumed %d; read the counters with kpeek around this run\n",
	       PG);
	t1();
	t2();
	t3();
	t4();
	printf("codepub: %s (%d failures)\n", fails == 0 ? "PASS" : "FAIL", fails);
	return (fails != 0);
}
