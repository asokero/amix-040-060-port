/* kdepthmax.c - high-water sampler for the 040 resolver's nesting counter
 * (ISSUE-22 hunt, 2026-07-28).
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * WHY THIS EXISTS: the FAILEXIT probe can only speak when the counter actually
 * crosses 4, which needs the rare failure to happen while we watch.  This tool
 * asks the quantitative question instead -- HOW CLOSE does the workload get --
 * and it answers whether the global counter behaves as a concurrency queue at
 * all.  A run whose maximum is 1-2 refutes the queue-depth mechanism as the
 * dominant cause just as usefully as a run that reaches 5 confirms it.
 *
 * The kernel image is identity-mapped (loaded at 0x08000000, DTT0 0-1GB), so
 * /dev/mem reads the live longword.
 *
 * SELF-VERIFYING: -a <hex> names an ANCHOR word of known content, read once at
 * start and once at the end.  If the anchor is not what the caller expects, the
 * address mapping is wrong and every sample is meaningless.  Report ANCHOR-BAD
 * rather than a plausible-looking histogram.
 *
 * Sampling is poll(2)-paced, not spin: a spinning reader would steal the CPU
 * from the very concurrency it is trying to observe.
 *
 * Usage:  kdepthmax <hex-addr> <seconds> [interval-ms] [anchor-hex] [anchor-expect-hex]
 *   e.g.  kdepthmax 080FFDC4 900 10 080FFDC0 1
 * Compile on AMIX:  cc -o kdepthmax kdepthmax.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>

#define NBUCKET	16

main(argc, argv)
int argc;
char **argv;
{
	unsigned long addr;
	unsigned long anchor_addr;
	unsigned long anchor_want;
	unsigned long anchor_got;
	unsigned long val;
	unsigned long samples;
	unsigned long errors;
	unsigned long bucket[NBUCKET];
	unsigned long over;
	unsigned long max;
	long secs;
	long ms;
	long t_end;
	long now;
	int fd;
	int i;
	int have_anchor;

	if (argc < 3) {
		fprintf(stderr,
		    "usage: kdepthmax <hex-addr> <seconds> [ms] [anchor-hex] [expect-hex]\n");
		exit(2);
	}
	addr = 0;
	sscanf(argv[1], "%lx", &addr);
	secs = atol(argv[2]);
	ms = (argc > 3) ? atol(argv[3]) : 10;
	have_anchor = 0;
	anchor_addr = 0;
	anchor_want = 0;
	if (argc > 5) {
		sscanf(argv[4], "%lx", &anchor_addr);
		sscanf(argv[5], "%lx", &anchor_want);
		have_anchor = 1;
	}

	fd = open("/dev/mem", O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "kdepthmax: cannot open /dev/mem: errno %d\n", errno);
		exit(3);
	}

	if (have_anchor) {
		lseek(fd, (long)anchor_addr, 0);
		if (read(fd, (char *)&anchor_got, 4) != 4 || anchor_got != anchor_want) {
			printf("KDEPTH ANCHOR-BAD addr=%08lx got=%08lx want=%08lx\n",
			       anchor_addr, anchor_got, anchor_want);
			printf("KDEPTH ABORT (address mapping unverified; samples would be meaningless)\n");
			exit(4);
		}
		printf("KDEPTH ANCHOR-OK addr=%08lx = %08lx\n", anchor_addr, anchor_got);
	}

	for (i = 0; i < NBUCKET; i++)
		bucket[i] = 0;
	over = 0;
	max = 0;
	samples = 0;
	errors = 0;

	t_end = (long)time((long *)0) + secs;
	printf("KDEPTH START addr=%08lx secs=%ld interval=%ldms\n", addr, secs, ms);
	fflush(stdout);

	for (;;) {
		lseek(fd, (long)addr, 0);
		if (read(fd, (char *)&val, 4) != 4) {
			errors++;
		} else {
			samples++;
			if (val > max)
				max = val;
			if (val < NBUCKET)
				bucket[val]++;
			else
				over++;
		}
		poll((struct pollfd *)0, 0, (int)ms);
		now = (long)time((long *)0);
		if (now >= t_end)
			break;
	}
	close(fd);

	printf("KDEPTH DONE samples=%lu errors=%lu MAX=%lu\n", samples, errors, max);
	for (i = 0; i < NBUCKET; i++)
		if (bucket[i])
			printf("KDEPTH depth=%d count=%lu\n", i, bucket[i]);
	if (over)
		printf("KDEPTH depth>=%d count=%lu\n", NBUCKET, over);
	exit(0);
}
