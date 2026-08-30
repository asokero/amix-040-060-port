/* kpeek.c - read kernel longwords through /dev/mem (ISSUE-22 hunt, 2026-07-28).
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * PURPOSE: the 040 resolver's nesting counter Lkx_depth is a plain .data
 * longword.  Its RESTING value answers a question the FAILEXIT probe cannot:
 * whether the counter merely rises under concurrency (Codex's queue-depth
 * mechanism) or whether it LEAKS -- a permanently elevated counter would mean
 * every kernel fault gets closer to the cap for the rest of the uptime.
 *
 * The kernel image is identity-mapped (DTT0 covers 0-1GB), so /dev/mem at the
 * kernel VA reads the live longword.  /dev/kmem is tried as a fallback.
 *
 * THE LOAD BASE IS AN ARGUMENT, NOT A CONSTANT.  This program takes the address
 * from argv[1] and is therefore correct on any card, but the number you pass is
 * not: a Mercury loads the kernel at 0x08000000 and an A3640, which has no RAM
 * of its own, at 0x07000000.  Generate the address with
 * `tools/status-facts.sh <image> <load-base>` and read the block's magic word
 * first -- a stale address returns a plausible number rather than an error.
 * See ISSUE-57 for what that costs when nobody checks.
 *
 * SELF-VERIFYING BY CONSTRUCTION: never read the unknown word alone.  Pass a
 * range that also covers a word of KNOWN content (e.g. xpage_on == 1 and the
 * "segk" string that follows the counter).  If the anchors do not read back as
 * expected, the address mapping is wrong and the unknown word means nothing --
 * the same failure that made a dead serial capture look like a clean result.
 *
 * Usage:  kpeek <hex-address> [count]        e.g.  kpeek 0710f6e4 21
 * Compile on AMIX:  cc -o kpeek kpeek.c
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
	unsigned long val;
	int count;
	int fd;
	int i;
	char *dev;

	if (argc < 2) {
		fprintf(stderr, "usage: kpeek <hex-address> [count]\n");
		exit(2);
	}
	addr = 0;
	sscanf(argv[1], "%lx", &addr);
	count = (argc > 2) ? atoi(argv[2]) : 1;

	dev = "/dev/mem";
	fd = open(dev, O_RDONLY);
	if (fd < 0) {
		dev = "/dev/kmem";
		fd = open(dev, O_RDONLY);
	}
	if (fd < 0) {
		fprintf(stderr, "kpeek: cannot open /dev/mem or /dev/kmem: errno %d\n",
			errno);
		exit(3);
	}

	for (i = 0; i < count; i++) {
		if (lseek(fd, (long)(addr + i * 4), 0) == -1L) {
			printf("KPEEK %08lx SEEKFAIL errno=%d\n", addr + i * 4, errno);
			continue;
		}
		if (read(fd, (char *)&val, 4) != 4) {
			printf("KPEEK %08lx READFAIL errno=%d\n", addr + i * 4, errno);
			continue;
		}
		printf("KPEEK %08lx = %08lx  (%s)\n", addr + i * 4, val, dev);
	}
	close(fd);
	exit(0);
}
