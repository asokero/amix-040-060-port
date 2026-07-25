/* bmaptest.c -- ufs_bmap 4 KiB conversion acceptance test (ISSUE-31).
 *
 * Acceptance list from vm-map/PAGECREATE-REACHABILITY-AND-UFSBMAP.md:
 *   "Direct allocation, fragment growth, indirect allocation, and synchronous write
 *    branches are exercised with fs_bsize = 8192."
 *
 * WHAT ACTUALLY CHANGES BEHAVIOUR
 * ufs_bmap.c:398-399 and :448:
 *     } else if (!alloc_only || roundup(size, PAGESIZE) < bsize) {   / * read the block * /
 * With fs_bsize 8192:
 *     old 2 KiB rounding: sizes 4097..6144 round to 6144, 6144 < 8192 -> READ
 *     new 4 KiB rounding: those round to 8192, 8192 < 8192 is false  -> SKIP the read
 * Skipping is only safe because the caller now fills whole 4 KiB pages, which is what
 * the ISSUE-27 PAGEMASK fix guarantees.  So T3 below -- page-aligned writes with a
 * length in 4097..6144, in the INDIRECT region -- is the discriminating test: if the
 * read is skipped and the page is not fully filled, untouched bytes come back wrong.
 *
 * Every test verifies the WHOLE file: each byte must be either P1 (never written) or
 * P2 (written by this test).  Any third value is corruption, and the check is
 * provenance-independent -- zeros are a failure too.
 *
 * usage: bmaptest [dir]        default /pgc
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o bmaptest bmaptest.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define BSIZE	8192			/* fs_bsize on the measured root filesystem */
#define NDADDR	12
#define DIRECT_END (NDADDR * BSIZE)	/* 98304 -- past this the indirect path is used */
#define FSIZE	163840			/* 20 blocks: well into the indirect region */
#define CHUNK	8192

char p1[CHUNK];
char p2[6400];
char rb[CHUNK];

int fails;

mkpat()
{
	int i;

	for (i = 0; i < CHUNK; i++)
		p1[i] = (char)(0x11 + (i % 251));
	for (i = 0; i < 6400; i++)
		p2[i] = (char)(0xA0 + (i % 61));
}

/* create dir/name of FSIZE bytes filled with P1 (P1 repeats every CHUNK) */
int mkfile(path)
char *path;
{
	int fd, off;

	(void)unlink(path);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return -1;
	for (off = 0; off < FSIZE; off += CHUNK)
		if (write(fd, p1, CHUNK) != CHUNK) { close(fd); return -1; }
	close(fd);
	sync();
	return 0;
}

/* verify: bytes in [woff, woff+wlen) must be P2, everything else P1 */
int verify(path, woff, wlen, tag)
char *path;
int woff, wlen;
char *tag;
{
	int fd, off, i, bad, absolute;
	char want;

	fd = open(path, O_RDONLY, 0);
	if (fd < 0) { printf("  %s: open failed errno=%d\n", tag, errno); return 1; }
	bad = 0;
	for (off = 0; off < FSIZE; off += CHUNK) {
		if (read(fd, rb, CHUNK) != CHUNK) {
			printf("  %s: short read at %d\n", tag, off); close(fd); return 1;
		}
		for (i = 0; i < CHUNK; i++) {
			absolute = off + i;
			if (absolute >= woff && absolute < woff + wlen)
				want = p2[absolute - woff];
			else
				want = p1[absolute % CHUNK];
			if (rb[i] != want) {
				if (bad < 3)
					printf("  %s: MISMATCH at %d got 0x%02x want 0x%02x\n",
						tag, absolute, rb[i] & 0xff, want & 0xff);
				bad++;
			}
		}
	}
	close(fd);
	if (bad)
		printf("  %s: %d bad bytes\n", tag, bad);
	return bad ? 1 : 0;
}

int dowrite(path, off, len, sync_flag)
char *path;
int off, len, sync_flag;
{
	int fd, fl;

	fl = O_RDWR;
#ifdef O_SYNC
	if (sync_flag)
		fl |= O_SYNC;
#endif
	fd = open(path, fl, 0);
	if (fd < 0)
		return -1;
	if (lseek(fd, (long)off, 0) == -1L) { close(fd); return -1; }
	if (write(fd, p2, len) != len) { close(fd); return -1; }
	close(fd);
	return 0;
}

/* one case: fresh file, one write, full verify */
docase(dir, tag, off, len, sync_flag)
char *dir, *tag;
int off, len, sync_flag;
{
	char path[128];

	sprintf(path, "%s/bm", dir);
	if (mkfile(path) < 0) { printf("  %s: mkfile FAILED errno=%d\n", tag, errno); fails++; return; }
	if (dowrite(path, off, len, sync_flag) < 0) {
		printf("  %s: write FAILED errno=%d\n", tag, errno); fails++; return;
	}
	if (verify(path, off, len, tag))
		fails++;
	else
		printf("  %-34s off=%-7d len=%-5d %s OK\n", tag, off, len,
			sync_flag ? "SYNC " : "     ");
	(void)unlink(path);
}

main(argc, argv)
int argc;
char **argv;
{
	char *dir;
	char path[128];
	int fd, i, off;

	setbuf(stdout, (char *)0);
	dir = (argc > 1) ? argv[1] : "/pgc";
	mkpat();
	fails = 0;

	printf("bmaptest: fs_bsize %d, NDADDR %d (direct ends at %d), file %d B\n",
		BSIZE, NDADDR, DIRECT_END, FSIZE);
	printf("  the behaviour-changing interval is roundup(size,PAGESIZE) vs bsize:\n");
	printf("  sizes 4097..6144 round to 6144 (<8192, READ) old vs 8192 (SKIP) new\n");

	/* T1 direct allocation: page-aligned writes below DIRECT_END */
	docase(dir, "T1a direct, len 4096",      8192,  4096, 0);
	docase(dir, "T1b direct, len 6144",      8192,  6144, 0);

	/* T2 the discriminating interval, INDIRECT region, page-aligned */
	docase(dir, "T2a indirect, len 4097",  106496,  4097, 0);
	docase(dir, "T2b indirect, len 5000",  106496,  5000, 0);
	docase(dir, "T2c indirect, len 6144",  106496,  6144, 0);
	/* controls just outside the interval */
	docase(dir, "T2d indirect, len 4096",  106496,  4096, 0);
	docase(dir, "T2e indirect, len 6145",  106496,  6145, 0);

	/* T3 same interval but NOT page aligned (as_iolock bails, pagecreate=0) */
	docase(dir, "T3  indirect unaligned",  106496+500, 6144, 0);

	/* T4 synchronous write over the interval */
	docase(dir, "T4a indirect SYNC 5000",  106496,  5000, 1);
	docase(dir, "T4b direct   SYNC 6144",    8192,  6144, 1);

	/* T5 fragment growth: append in sub-fragment increments and verify */
	sprintf(path, "%s/bmg", dir);
	(void)unlink(path);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0) {
		printf("  T5 fragment growth: open FAILED errno=%d\n", errno); fails++;
	} else {
		for (i = 0; i < 200; i++)
			if (write(fd, p1, 100) != 100) break;
		close(fd);
		sync();
		fd = open(path, O_RDONLY, 0);
		off = 0;
		if (fd >= 0) {
			int n, k, bad = 0;
			while ((n = read(fd, rb, CHUNK)) > 0) {
				for (k = 0; k < n; k++)
					if (rb[k] != p1[(off + k) % 100])
						bad++;
				off += n;
			}
			close(fd);
			if (off != 20000 || bad) {
				printf("  T5 fragment growth: size %d (want 20000) bad %d\n",
					off, bad); fails++;
			} else
				printf("  %-34s 200 x 100 B appends           OK\n",
					"T5  fragment growth");
		} else { printf("  T5: reopen FAILED\n"); fails++; }
		(void)unlink(path);
	}

	printf("BMAPTEST fails=%d\n", fails);
	printf(fails ? "BMAPTEST-RESULT FAIL\n" : "BMAPTEST-RESULT PASS\n");
	exit(fails ? 1 : 0);
}
