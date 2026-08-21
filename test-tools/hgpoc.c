/* hgpoc.c - ISSUE-10 cure acceptance probe (2026-08-21).
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at the top of the
 * block).  It is also cross-buildable host-side with m68k-cbm-sysv4-gcc, which is
 * how it reaches the install miniroot -- that root has no compiler, so the binary
 * is parked in the free tail of the source disk's raw slice and dd'd out, exactly
 * as kpeek/kpoke are.
 *
 * WHAT IT MEASURES, and why it is not just "run sh and see".
 * The ISSUE-10 wall is a first-touch WRITE one page past the process break whose
 * store the 68040 discards, so the datum never reaches memory.  sh's failure is a
 * long way downstream of that (a NULL arena link, then a bus-error flood).  This
 * probe tests the mechanism DIRECTLY: it performs the same shaped store and reads
 * the value back.  A dropped write-back reads back as 0 -- the page is freshly
 * zero-filled -- so "wrote 0x5A5A1234, read 0" IS the defect, with no interpretation
 * in between, and "read it back" is the cure.
 *
 *   grow  <npages>   sbrk npages pages, then write one byte per page TOP-DOWN and
 *                    read every one back.  Top-down forces the deepest first-touch
 *                    shape (each page's first access is a write to an absent page).
 *   past  <kib>      store one longword <kib> KiB above the page-rounded break,
 *                    WITHOUT sbrk'ing for it -- addblok's shape.  kib 0 = inside
 *                    the one-page window, which the cure must complete; kib 1024 =
 *                    a wild write, which must still be killed by SIGSEGV.
 *   churn <rounds>   sbrk up and back down repeatedly, writing and verifying a
 *                    canary in the newest page each round: sh's morecore(-512)
 *                    give-back oscillation, the pattern that produces the wall.
 *
 * Exit status: 0 = pass, 1 = a value did not read back, 2 = usage/sbrk failure,
 * 3 = killed by SIGSEGV (which is a PASS for `past 1024` and a FAIL otherwise --
 * the driver script knows which it asked for).
 *
 * Compile on AMIX:  cc -o hgpoc hgpoc.c
 */

#include <sys/types.h>
#include <signal.h>
#include <stdio.h>

#define PGSZ  4096
#define PGMSK 0xfff

char *sbrk();

/* When growatsegv is set the handler behaves like sh's own: it extends the break
   past the faulting address and RETURNS, so the interrupted store gets its chance
   to execute again.  That is the whole 030-vs-040 difference in six lines -- a
   68030 re-runs the store on rte and the value lands; a 68040 has already handed
   the pending write-back to the kernel, which dropped it, so the value is gone and
   the read-back below is 0.  With the cure in place the signal never arrives at
   all, because the fault was resolved before any signal was chosen. */
int	growatsegv = 0;
unsigned long	segvtarget = 0;
int	segvcount = 0;

segvhandler(sig)
int sig;
{
	segvcount++;
	signal(SIGSEGV, segvhandler);		/* SVR4 signal() resets to SIG_DFL */
	signal(SIGBUS, segvhandler);
	if (growatsegv && segvcount < 4) {
		while ((unsigned long) sbrk(0) <= segvtarget + 8) {
			if (sbrk(PGSZ) == (char *) -1)
				break;
		}
		return;				/* retry the store, 68030-style */
	}
	printf("SIGSEGV/SIGBUS taken (signal %d, count %d)\n", sig, segvcount);
	fflush(stdout);
	_exit(3);
}

/* the first address at or above the break that no mapping can already cover:
   the segment behind the break is page-rounded, so anything below this is live */
unsigned long
pastbreak()
{
	unsigned long b;

	b = (unsigned long) sbrk(0);
	return ((b + PGMSK) & ~PGMSK);
}

dogrow(npages)
int npages;
{
	char *base;
	int i;
	int bad;
	long want;

	base = sbrk(npages * PGSZ);
	if (base == (char *) -1) {
		printf("sbrk(%d pages) FAILED\n", npages);
		return (2);
	}
	printf("grow: base %lx npages %d\n", (unsigned long) base, npages);
	/* TOP-DOWN: the last page is touched first, so no earlier touch has
	   already faulted a neighbour in */
	for (i = npages - 1; i >= 0; i--)
		base[i * PGSZ] = (char) (0x40 + (i & 0x3f));
	bad = 0;
	for (i = 0; i < npages; i++) {
		want = 0x40 + (i & 0x3f);
		if ((base[i * PGSZ] & 0xff) != want) {
			printf("grow: page %d read back %x, wanted %lx\n",
			       i, base[i * PGSZ] & 0xff, want);
			bad++;
		}
	}
	printf("grow: %d pages, %d bad\n", npages, bad);
	return (bad ? 1 : 0);
}

dopast(kib)
int kib;
{
	unsigned long a;
	long *p;
	long got;

	a = pastbreak() + ((unsigned long) kib * 1024) + 0x2a0;
	p = (long *) a;
	printf("past: break %lx target %lx (%d KiB above)\n",
	       (unsigned long) sbrk(0), a, kib);
	fflush(stdout);
	/* Inside the one-page window this imitates sh: grow on the signal and let the
	   store retry, so a dropped write-back shows up as a zero read-back rather
	   than as a dead process.  Far above it, a signal is the CORRECT outcome and
	   the handler must not paper over it. */
	segvtarget = a;
	if (kib < 64)
		growatsegv = 1;
	*p = 0x5a5a1234;
	got = *p;
	printf("past: wrote 5a5a1234 read %lx (signals taken: %d)\n", got, segvcount);
	if (got != 0x5a5a1234) {
		printf("past: THE STORE WAS DROPPED\n");
		return (1);
	}
	printf("past: the store landed\n");
	return (0);
}

dochurn(rounds)
int rounds;
{
	int i;
	int bad;
	long *p;

	bad = 0;
	for (i = 0; i < rounds; i++) {
		if (sbrk(PGSZ + 512) == (char *) -1) {
			printf("churn: sbrk up failed at round %d\n", i);
			return (2);
		}
		p = (long *) (pastbreak() - PGSZ);
		*p = 0xc0de0000 + i;
		if (*p != (long) (0xc0de0000 + i)) {
			printf("churn: round %d canary read %lx\n", i, *p);
			bad++;
		}
		if (sbrk(-512) == (char *) -1) {
			printf("churn: sbrk down failed at round %d\n", i);
			return (2);
		}
	}
	printf("churn: %d rounds, %d bad, break %lx\n",
	       rounds, bad, (unsigned long) sbrk(0));
	return (bad ? 1 : 0);
}

main(argc, argv)
int argc;
char **argv;
{
	int n;

	signal(SIGSEGV, segvhandler);
	signal(SIGBUS, segvhandler);
	if (argc < 3) {
		printf("usage: hgpoc grow <npages> | past <kib> | churn <rounds>\n");
		exit(2);
	}
	n = atoi(argv[2]);
	if (strcmp(argv[1], "grow") == 0)
		exit(dogrow(n));
	if (strcmp(argv[1], "past") == 0)
		exit(dopast(n));
	if (strcmp(argv[1], "churn") == 0)
		exit(dochurn(n));
	printf("hgpoc: unknown mode %s\n", argv[1]);
	exit(2);
}
