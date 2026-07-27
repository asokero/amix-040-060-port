/* nfsreadtruth.c -- ISSUE-35 read side: does NFS page-in return every byte?
 *
 * The write side is fixed and proven (ISSUE-35, nfs_putpage 2 sites).  The read side is a
 * separate 13-site group (nfs_getapage/nfs_getpage) with a KNOWN static defect that is NOT
 * a content defect, per Codex vm-map/NFS-REALHW-ISSUE35-FOLLOWUP.md:
 *
 *     pvn_getpages provider plsz = 4096
 *     nfs_getapage @0x8b26c: sz -= 2048 per returned page_t *
 *
 * The provider decrements its remaining capacity by 2048 per page while the caller sized the
 * array for 4096-byte pages, so an 8 KiB cluster can write TWO pointers plus a terminator
 * into room meant for one.  That is a caller-array overrun, and it can happen even when the
 * RPC filled both pages with correct bytes -- so THIS PROGRAM MAY WELL PASS while the
 * invariant is still violated.  Passing here is necessary, not sufficient; the kernel-side
 * pl[] count probe is the other half.
 *
 * WHAT THIS HALF DOES TEST: that a cold page-in returns correct bytes across the 2 KiB,
 * 4 KiB and 8 KiB boundaries and at EOF, including for non-page-multiple lengths.
 *
 * COLDNESS IS THE WHOLE DIFFICULTY.  The files must be written BY THE SERVER (host side),
 * never by this client, and must have names this client has never seen -- otherwise the
 * client page cache serves the read and the test proves nothing.  That is the same masking
 * that defeated three ISSUE-27 probe designs.  So: the host writes them with a unique run
 * tag, and this program only ever READS.
 *
 * First touch is deliberately NON-SEQUENTIAL (last page, first page, then middles) so a
 * read-ahead/clustering path is exercised rather than a tidy forward walk.
 *
 * usage: nfsreadtruth <dir> <tag>        reads <dir>/rd<tag>-<size>.bin
 * K&R C for the AMIX native cc.  cc -o nfsreadtruth nfsreadtruth.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>

/* keep identical to the host-side generator */
int
patbyte(o)
long o;
{
	return (int)(((o >> 9) % 251L) + 1L);
}

static long sizes[] = { 8192L, 8315L, 12288L, 16507L, 0L };   /* 8192+123, 16384+123 */

/* verify a byte range, return count of mismatches, record the first */
long firstbad;

long
vrange(p, base, from, to)
char *p;
long base, from, to;
{
	long o, bad;

	bad = 0L;
	for (o = from; o < to; o++) {
		if ((int)(unsigned char)p[o] != patbyte(base + o)) {
			if (bad == 0L)
				firstbad = o;
			bad++;
		}
	}
	return (bad);
}

int
onefile(dir, tag, sz)
char *dir, *tag;
long sz;
{
	char path[256];
	int fd, fails;
	char *p;
	long bad, o, npg, i;

	sprintf(path, "%s/rd%s-%ld.bin", dir, tag, sz);
	fails = 0;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("RDTRUTH ERR cannot open %s\n", path);
		return (1);
	}
	p = (char *) mmap((caddr_t)0, (size_t)sz, PROT_READ, MAP_PRIVATE, fd, (off_t)0);
	if (p == (char *)-1) {
		printf("RDTRUTH ERR mmap %s failed\n", path);
		(void) close(fd);
		return (1);
	}

	/* NON-SEQUENTIAL first touch: last page, first page, then every other page */
	npg = (sz + 4095L) / 4096L;
	firstbad = -1L;
	{
		volatile char c;
		c = p[sz - 1L];                       /* last byte  */
		c = p[0];                             /* first byte */
		for (i = npg - 2L; i > 0L; i -= 2L)
			c = p[i * 4096L];
		for (i = 1L; i < npg - 1L; i += 2L)
			c = p[i * 4096L];
	}

	/* every byte */
	bad = vrange(p, 0L, 0L, sz);
	if (bad) {
		printf("RDTRUTH FAIL %s: %ld bytes wrong, first at %ld (page %ld half %ld)\n",
		       path, bad, firstbad, firstbad / 4096L, (firstbad % 4096L) / 2048L);
		fails++;
	} else {
		printf("RDTRUTH ok   %s: %ld bytes, every byte matches\n", path, sz);
	}

	/* boundary spot-checks stated separately so a partial failure is legible */
	for (o = 2048L; o < sz; o += 2048L) {
		if ((int)(unsigned char)p[o] != patbyte(o)) {
			printf("RDTRUTH   boundary %ld WRONG (page %ld half %ld)\n",
			       o, o / 4096L, (o % 4096L) / 2048L);
			fails++;
			break;
		}
	}

	(void) munmap(p, (size_t)sz);
	(void) close(fd);
	return (fails ? 1 : 0);
}

main(argc, argv)
int argc;
char **argv;
{
	int i, fails;

	if (argc != 3) {
		printf("usage: nfsreadtruth <dir> <tag>\n");
		exit(2);
	}
	fails = 0;
	for (i = 0; sizes[i] != 0L; i++)
		fails += onefile(argv[1], argv[2], sizes[i]);

	printf("NFSREADTRUTH-RESULT %s (%d file(s) bad)\n", fails ? "FAIL" : "PASS", fails);
	exit(fails ? 1 : 0);
}
