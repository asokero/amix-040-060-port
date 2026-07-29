/* dfcinject.c - ISSUE-22 fault injection harness: arm the kernel's DFC leak
 * microseconds before the read it is meant to hit.  2026-07-29.
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * WHY A PROGRAM AND NOT A SHELL PIPELINE: the injection budget counts down on
 * every kernel fault, and a shell spends it on the faults of its own exec long
 * before the test read happens.  This process arms the budget itself, then
 * immediately reads into pages it has never touched -- which is exactly the
 * copyout-into-non-resident-user-page case ISSUE-22 breaks.
 *
 * WHAT THE TWO OUTCOMES MEAN (run it once with wb_dfc_on=0, once with =1):
 *   wb_dfc_on = 0   the injected DFC survives the fault -> the copy must fail
 *                   with EFAULT.  That proves the causal chain: a leaked DFC
 *                   turns an ordinary page-in into "read: Bad address".
 *   wb_dfc_on = 1   the wrapper restores the caller's DFC -> the same injection
 *                   must be harmless.  That proves the fix, by the same measure
 *                   and in the same boot.
 *
 * The kernel side is self-limiting (the budget counts down), so even if this
 * program dies between arming and disarming, the machine recovers by itself.
 *
 * Usage:
 *   dfcinject <force-addr> <budget-addr> <forced-addr> <fc> <budget> <file>
 *   e.g. dfcinject 080FFED0 080FFED4 080FFED8 5 40 /payload.bin
 * Compile on AMIX:  cc -o dfcinject dfcinject.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define BUFSZ	(1024L * 1024L)
#define CHUNK	65536

static int memfd;

long peek(addr)
unsigned long addr;
{
	unsigned long v;

	v = 0xffffffff;
	if (lseek(memfd, (long)addr, 0) != -1L)
		read(memfd, (char *)&v, 4);
	return ((long)v);
}

int poke(addr, val)
unsigned long addr;
unsigned long val;
{
	if (lseek(memfd, (long)addr, 0) == -1L)
		return (-1);
	if (write(memfd, (char *)&val, 4) != 4)
		return (-1);
	return (0);
}

main(argc, argv)
int argc;
char **argv;
{
	unsigned long force_a;
	unsigned long budget_a;
	unsigned long forced_a;
	unsigned long fc;
	unsigned long budget;
	char *path;
	char *buf;
	int fd;
	int n;
	int e;
	long off;
	long forced_before;
	long forced_after;

	if (argc != 7) {
		fprintf(stderr, "usage: dfcinject <force-addr> <budget-addr> <forced-addr>"
				" <fc> <budget> <file>\n");
		exit(2);
	}
	force_a = budget_a = forced_a = fc = budget = 0;
	sscanf(argv[1], "%lx", &force_a);
	sscanf(argv[2], "%lx", &budget_a);
	sscanf(argv[3], "%lx", &forced_a);
	sscanf(argv[4], "%lu", &fc);
	sscanf(argv[5], "%lu", &budget);
	path = argv[6];

	memfd = open("/dev/mem", O_RDWR);
	if (memfd < 0) {
		fprintf(stderr, "dfcinject: /dev/mem: errno %d\n", errno);
		exit(3);
	}

	/* everything that can fault must happen BEFORE arming: the malloc, the
	 * open, and this program's own text.  Only the read is under injection. */
	buf = (char *)malloc((unsigned)BUFSZ);
	if (buf == (char *)0) {
		fprintf(stderr, "dfcinject: malloc failed\n");
		exit(3);
	}
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "dfcinject: %s: errno %d\n", path, errno);
		exit(3);
	}
	forced_before = peek(forced_a);
	printf("DFCINJ ARM fc=%lu budget=%lu forced_before=%ld\n", fc, budget, forced_before);
	fflush(stdout);

	/* budget FIRST, then the value: the kernel checks the value, then the
	 * budget, so this order can never inject with a stale budget. */
	if (poke(budget_a, budget) < 0 || poke(force_a, fc) < 0) {
		fprintf(stderr, "dfcinject: poke failed, errno %d\n", errno);
		exit(4);
	}

	off = 0;
	e = 0;
	for (;;) {
		n = read(fd, buf + off, CHUNK);
		if (n <= 0) {
			e = (n < 0) ? errno : 0;
			break;
		}
		off += n;
		if (off + CHUNK > BUFSZ)
			break;
	}

	poke(force_a, 0L);
	forced_after = peek(forced_a);

	printf("DFCINJ RESULT read_total=%ld errno=%d injections=%ld\n",
	       off, e, forced_after - forced_before);
	if (e == EFAULT)
		printf("DFCINJ VERDICT EFAULT -- the leaked DFC broke the copy\n");
	else if (e == 0)
		printf("DFCINJ VERDICT CLEAN -- the copy completed under injection\n");
	else
		printf("DFCINJ VERDICT OTHER errno=%d -- not the ISSUE-22 signature\n", e);
	if (forced_after == forced_before)
		printf("DFCINJ WARNING no injection was performed: the verdict above means"
		       " NOTHING (wrong addresses, or no fault happened during the read)\n");
	close(fd);
	close(memfd);
	exit((e == EFAULT) ? 1 : 0);
}
