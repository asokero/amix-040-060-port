/* memwatch.c -- sample the kernel's memory state across a workload, so the
 * ISSUE-39 intermittents can be described by a regime instead of a guess
 * (2026-08-01).
 *
 * THE PROBLEM IT SOLVES.  freemem, availrmem, availsmem, deficit, physmem,
 * maxmem and nscan are COMMON symbols in the ET_REL kernel image: nm reports
 * their SIZE (`00000004 C freemem`), and the AMIX loader is what finally places
 * them in .bss.  There is no address to compute the way counter addresses are
 * computed, which is why every earlier session could count hat_sdtalloc
 * failures but never say what memory looked like when they happened.
 *
 * prototypes/issue39_040.s fixes that with a pointer table: a .data long
 * initialised to each symbol, so the LOADER writes the runtime address into it.
 * This program reads that table through /dev/mem and then follows each pointer.
 *
 * SELF-VERIFYING, like kpeek and for the same reason.  The table starts with
 * i39_magic == 0x49333921 ("I39!").  If that does not read back, the .data
 * address passed in is stale -- which is exactly what happens after a relink,
 * and exactly the failure that made a whole line of readings meaningless on
 * 2026-07-31.  The program refuses to print numbers in that case.
 *
 * It also range-checks each pointer against the kernel image window before
 * following it: a plausible-looking but wrong table address would otherwise
 * produce plausible-looking but wrong page counts.
 *
 * USAGE
 *     memwatch <hex-addr-of-i39_magic> [seconds] [interval-ms]
 *     memwatch 080FCF9C 300 500     <- sample for 5 min, twice a second
 *
 * Recompute the address after EVERY relink:
 *     kernel_base(0x08000000) + textsize + .data offset of i39_magic
 *
 * Run it in the background alongside the burst suite:
 *     ./memwatch 080FCF9C 900 500 > /memwatch.log 2>&1 &
 *     sh burstloop.sh
 * then read the summary at the end of the log, and the kernel's own latch
 * (i39_fail_freemem / i39_fail_availrmem) with kpeek.  The two must agree about
 * the regime; if they do not, one of them is measuring something else.
 *
 * All values are in PAGES (4 KiB on this kernel), which is what the kernel's
 * own counters are in.  Bytes are printed alongside so nobody has to remember
 * whether this port's page is 2 or 4 KiB -- it is 4.
 *
 * K&R C for the AMIX SVR4 native cc.  Compile on AMIX:  cc -o memwatch memwatch.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define MAGIC		0x49333921L	/* "I39!" */
#define KBASE		0x08000000L	/* kernel load address */
#define KTOP		0x08400000L	/* generous upper bound for image + bss */
#define PGBYTES		4096

/* Offsets in LONGS from i39_magic.  This table is the .data order of
 * prototypes/issue39_040.s and nothing else -- keep them in the same order and
 * count them together, because on 2026-08-01 the three latch indices below were
 * each one too high, so a 100-minute run reported i39_fail_freemem where it said
 * "hat_sdtalloc failures" and printed 0 while the real counter read 1.  Nothing
 * else was affected (indices 1..7 were right, and physmem x 4 KiB matching the
 * machine's RAM proved it), and the authoritative reading came from kpeek at the
 * absolute addresses -- but the lesson is the project's own: an instrument is
 * not trusted until it is verified against a known value. */
#define O_MAGIC		0	/* i39_magic */
#define O_FREEMEM	1
#define O_AVAILRMEM	2
#define O_AVAILSMEM	3
#define O_DEFICIT	4
#define O_PHYSMEM	5
#define O_MAXMEM	6
#define O_NSCAN		7
#define O_FAIL_N	8	/* i39_fail_n -- the first of the latch group */
#define O_FAIL_FREE	9
#define O_FAIL_AVAILR	10
#define O_FAIL_DEFICIT	11
#define O_FAIL_FREE_L	12
#define O_FAIL_AVAILR_L	13

static int fd = -1;

static long
rdlong(addr, ok)
unsigned long addr;
int *ok;
{
	unsigned long v;

	*ok = 0;
	if (lseek(fd, (long) addr, 0) == -1)
		return (0);
	if (read(fd, (char *) &v, 4) != 4)
		return (0);
	*ok = 1;
	return ((long) v);
}

static unsigned long
ptrat(base, idx)
unsigned long base;
int idx;
{
	unsigned long p;
	int ok;

	p = (unsigned long) rdlong(base + (unsigned long) (idx * 4), &ok);
	if (!ok)
		return (0);
	if (p < KBASE || p >= KTOP) {
		fprintf(stderr,
			"memwatch: pointer[%d] = 0x%lx is outside the kernel window "
			"0x%lx..0x%lx -- table address wrong, refusing to guess\n",
			idx, p, (unsigned long) KBASE, (unsigned long) KTOP);
		exit(2);
	}
	return (p);
}

main(argc, argv)
int argc;
char **argv;
{
	unsigned long base;
	unsigned long p_free, p_availr, p_avails, p_def, p_phys, p_max, p_nscan;
	long magic, v, fr, ar, as, df, ns;
	long minfr, maxfr, minar, maxar;
	long sumfr;
	long n;
	int secs, ival, ok;
	int i, iters;

	if (argc < 2) {
		fprintf(stderr, "usage: memwatch <hex-addr-of-i39_magic> [seconds] [interval-ms]\n");
		exit(2);
	}
	base = 0;
	sscanf(argv[1], "%lx", &base);
	secs = (argc > 2) ? atoi(argv[2]) : 60;
	ival = (argc > 3) ? atoi(argv[3]) : 1000;
	if (ival < 100)
		ival = 100;

	fd = open("/dev/mem", O_RDONLY, 0);
	if (fd < 0) {
		fprintf(stderr, "memwatch: /dev/mem: errno=%d (run as root)\n", errno);
		exit(2);
	}

	/* ANCHOR FIRST.  Nothing below is printed unless this reads back. */
	magic = rdlong(base, &ok);
	if (!ok || magic != MAGIC) {
		fprintf(stderr,
			"memwatch: anchor at 0x%lx reads 0x%lx, expected 0x%lx (\"I39!\").\n"
			"          The address is stale -- recompute it from THIS kernel:\n"
			"          0x08000000 + textsize + .data offset of i39_magic.\n",
			base, magic, (long) MAGIC);
		exit(1);
	}

	p_free   = ptrat(base, O_FREEMEM);
	p_availr = ptrat(base, O_AVAILRMEM);
	p_avails = ptrat(base, O_AVAILSMEM);
	p_def    = ptrat(base, O_DEFICIT);
	p_phys   = ptrat(base, O_PHYSMEM);
	p_max    = ptrat(base, O_MAXMEM);
	p_nscan  = ptrat(base, O_NSCAN);

	printf("memwatch: anchor OK at 0x%lx; page = %d bytes\n", base, PGBYTES);
	printf("  freemem @0x%lx  availrmem @0x%lx  availsmem @0x%lx\n",
	       p_free, p_availr, p_avails);
	v = rdlong(p_phys, &ok);
	printf("  physmem = %ld pages (%ld KiB)\n", v, v * (PGBYTES / 1024));
	v = rdlong(p_max, &ok);
	printf("  maxmem  = %ld pages (%ld KiB)\n", v, v * (PGBYTES / 1024));
	printf("  sampling %d s every %d ms\n\n", secs, ival);
	printf("    t(s)  freemem  availrmem  availsmem  deficit  nscan  sdtfail\n");
	(void) fflush(stdout);

	iters = (secs * 1000) / ival;
	if (iters < 1)
		iters = 1;
	minfr = maxfr = -1;
	minar = maxar = -1;
	sumfr = 0;
	n = 0;

	for (i = 0; i < iters; i++) {
		fr = rdlong(p_free, &ok);
		ar = rdlong(p_availr, &ok);
		as = rdlong(p_avails, &ok);
		df = rdlong(p_def, &ok);
		ns = rdlong(p_nscan, &ok);
		v  = rdlong(base + (O_FAIL_N * 4), &ok);

		if (minfr < 0 || fr < minfr) minfr = fr;
		if (maxfr < 0 || fr > maxfr) maxfr = fr;
		if (minar < 0 || ar < minar) minar = ar;
		if (maxar < 0 || ar > maxar) maxar = ar;
		sumfr += fr;
		n++;

		/* One line per second of wall clock, whatever the interval:
		 * the log is meant to be read, and the min/max below is what
		 * actually answers the question. */
		if ((i % (1000 / ival ? 1000 / ival : 1)) == 0) {
			printf("  %6ld  %7ld  %9ld  %9ld  %7ld  %5ld  %7ld\n",
			       (long) ((long) i * ival / 1000), fr, ar, as, df, ns, v);
			(void) fflush(stdout);
		}
		poll((char *) 0, 0, ival);	/* SVR4 sub-second sleep */
	}

	printf("\nmemwatch summary over %ld samples\n", n);
	printf("  freemem   min %ld  max %ld  mean %ld pages   (min = %ld KiB)\n",
	       minfr, maxfr, n ? sumfr / n : 0, minfr * (PGBYTES / 1024));
	printf("  availrmem min %ld  max %ld pages\n", minar, maxar);

	v = rdlong(base + (O_FAIL_N * 4), &ok);
	printf("  hat_sdtalloc failures during/before this run: %ld\n", v);
	if (v > 0) {
		printf("  latched at the FIRST failure: freemem %ld  availrmem %ld  deficit %ld\n",
		       rdlong(base + (O_FAIL_FREE * 4), &ok),
		       rdlong(base + (O_FAIL_AVAILR * 4), &ok),
		       rdlong(base + (O_FAIL_DEFICIT * 4), &ok));
		printf("  latched at the LAST  failure: freemem %ld  availrmem %ld\n",
		       rdlong(base + (O_FAIL_FREE_L * 4), &ok),
		       rdlong(base + (O_FAIL_AVAILR_L * 4), &ok));
	}
	(void) close(fd);
	return (0);
}
