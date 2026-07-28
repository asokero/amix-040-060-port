/* kpoke.c - write one kernel longword through /dev/mem (ISSUE-22 hunt, 2026-07-28).
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * PURPOSE: flip a kernel A/B flag live, so the control and the treatment run in
 * the SAME boot with the same page cache, the same uptime and the same load.
 * A reboot between the two halves of an A/B adds a variable we then have to
 * argue away; this removes it.  Built for us_reroute_on (ISSUE-22) and xpage_on.
 *
 * FAILS CLOSED: the caller must state the value it expects to find.  A mismatch
 * means the address is wrong or something else already wrote there -- in either
 * case writing would be a shot in the dark into live kernel memory, so we stop.
 * This is the same old-byte assertion the offline patch scripts use.
 *
 * Usage:  kpoke <hex-addr> <expect-hex> <new-hex>
 *   e.g.  kpoke 080FFD20 1 0        (turn the ISSUE-22 reroute off)
 * Compile on AMIX:  cc -o kpoke kpoke.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

main(argc, argv)
int argc;
char **argv;
{
	unsigned long addr;
	unsigned long want;
	unsigned long newval;
	unsigned long got;
	int fd;

	if (argc != 4) {
		fprintf(stderr, "usage: kpoke <hex-addr> <expect-hex> <new-hex>\n");
		exit(2);
	}
	addr = 0;
	want = 0;
	newval = 0;
	sscanf(argv[1], "%lx", &addr);
	sscanf(argv[2], "%lx", &want);
	sscanf(argv[3], "%lx", &newval);

	fd = open("/dev/mem", O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "kpoke: cannot open /dev/mem read-write: errno %d\n", errno);
		exit(3);
	}
	if (lseek(fd, (long)addr, 0) == -1L || read(fd, (char *)&got, 4) != 4) {
		printf("KPOKE %08lx READFAIL errno=%d\n", addr, errno);
		exit(4);
	}
	if (got != want) {
		printf("KPOKE %08lx REFUSED: holds %08lx, expected %08lx\n", addr, got, want);
		exit(5);
	}
	if (lseek(fd, (long)addr, 0) == -1L || write(fd, (char *)&newval, 4) != 4) {
		printf("KPOKE %08lx WRITEFAIL errno=%d\n", addr, errno);
		exit(6);
	}
	if (lseek(fd, (long)addr, 0) == -1L || read(fd, (char *)&got, 4) != 4) {
		printf("KPOKE %08lx VERIFYFAIL errno=%d\n", addr, errno);
		exit(7);
	}
	printf("KPOKE %08lx = %08lx (was %08lx) %s\n", addr, got, want,
	       (got == newval) ? "OK" : "READBACK-MISMATCH");
	close(fd);
	exit((got == newval) ? 0 : 8);
}
