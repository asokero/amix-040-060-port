/* trunctest.c -- pvn_vptrunc final-page tail zeroing (Codex P1, ISSUE-30 candidate).
 *
 * CONTRACT (svr4-src-3b2/usr/src/uts/3b2/vm/vm_pvn.c, pvn_vptrunc), described rather than
 * quoted: it maps the block containing the new end-of-file through segmap, then zeroes from
 * the offset within that block for a length of at least PAGESIZE minus the offset within the
 * page -- i.e. always out to the end of the page the new EOF falls in.  The commentary in
 * ufs_inode.c gives the reason: bytes past end-of-file must read as zero in case the file
 * later grows and makes them reachable again.
 *
 * Only the PAGESIZE/PAGEOFFSET term is VM page geometry; MAXBMASK/MAXBOFFSET are the
 * 8 KiB segmap slot and must not be touched.  In build/unix-040 the term is
 *     0xb248c  andil #2047,%d0      (vplen & PAGEOFFSET)
 *     0xb2492  subil #2048,%d0      then negl -> PAGESIZE - (vplen & PAGEOFFSET)
 * i.e. still 2 KiB, while the page it is zeroing is 4 KiB.
 *
 * REACHABILITY (this is why the term is not dead under MAX()):
 *   ufs_itrunc passes zbytes = bsize - offset, and for a truncation inside the first
 *   NDADDR direct blocks bsize = fragroundup(fs, offset), so zbytes <= 1023 on a
 *   1 KiB-fragment filesystem.  The page term (up to 2048 pre-fix / 4096 post-fix)
 *   therefore dominates the MAX and is what actually decides the zeroed length.
 *
 * PROBE
 *   file of CSIZE bytes filled with pattern P1, then truncate to TLEN = 8692.
 *   8692 is inside the 4 KiB page [8192,12288) at page offset 500.
 *     pre-fix   zero length = MAX(524, 2048-500) = 1548 -> zeroes 8692..10239 only,
 *               so [10240,12288) keeps the OLD P1 past the new EOF
 *     post-fix  zero length = MAX(524, 4096-500) = 3596 -> zeroes 8692..12287
 *   Then grow the file again by writing one byte at 12287 (same page, not page
 *   aligned, so no pagecreate) and read back [8692,12288).
 *
 * No reboot is needed: pvn_vptrunc aborts only pages whose offset >= vplen, so the
 * final partial page stays resident with whatever it was left holding.
 *
 * Failure signal is "old file data reappeared after truncate", which is
 * provenance-independent -- it does not depend on any page being recycled.
 *
 * usage: trunctest [nfiles] [dir]        defaults: 8 files, /pgc
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o trunctest trunctest.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define CSIZE	32768
#define TLEN	8692		/* page [8192,12288), page offset 500 */
#define PGLO	8192
#define PGHI	12288
#define STALE	10240		/* roundup(8692,2048): pre-fix zeroing stops here */
#define GROW	(PGHI - 1)	/* 12287 -- last byte of the same page */

char big[CSIZE];
char rd[PGHI - TLEN + 16];

/* SVR4 truncate: prefer ftruncate, fall back to fcntl(F_FREESP). */
int trunc_to(fd, len)
int fd;
long len;
{
	struct flock fl;

	if (ftruncate(fd, len) == 0)
		return 0;
	fl.l_type = F_WRLCK;
	fl.l_whence = 0;
	fl.l_start = len;
	fl.l_len = 0;
	if (fcntl(fd, F_FREESP, &fl) == 0)
		return 0;
	return -1;
}

main(argc, argv)
int argc;
char **argv;
{
	int n, i, fd, k, nr, hits, errs, firstbad, badval, minbad;
	char *dir;
	char p[128];
	char one[1];

	setbuf(stdout, (char *)0);
	n = (argc > 1) ? atoi(argv[1]) : 8;
	dir = (argc > 2) ? argv[2] : "/pgc";

	for (i = 0; i < CSIZE; i++)
		big[i] = (char)(0x11 + (i % 251));
	one[0] = (char)0xEE;

	printf("trunctest: %d files in %s\n", n, dir);
	printf("  %d B of P1, truncate to %d (page offset %d), grow back at %d\n",
		CSIZE, TLEN, TLEN - PGLO, GROW);
	printf("  pre-fix zeroing stops at %d; [%d,%d) must be ZERO after truncate\n",
		STALE, TLEN, PGHI);

	hits = 0; errs = 0; minbad = 0x7fffffff;
	for (i = 0; i < n; i++) {
		sprintf(p, "%s/t%d", dir, i);
		(void)unlink(p);
		fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) { errs++; continue; }
		if (write(fd, big, CSIZE) != CSIZE) { errs++; close(fd); continue; }

		if (trunc_to(fd, (long)TLEN) < 0) {
			printf("  t%d: TRUNCATE FAILED errno=%d (no ftruncate/F_FREESP?)\n",
				i, errno);
			errs++; close(fd); continue;
		}

		/* grow back into the SAME page; not page aligned -> no pagecreate */
		if (lseek(fd, (long)GROW, 0) == -1L) { errs++; close(fd); continue; }
		if (write(fd, one, 1) != 1) { errs++; close(fd); continue; }

		if (lseek(fd, (long)TLEN, 0) == -1L) { errs++; close(fd); continue; }
		nr = read(fd, rd, PGHI - TLEN);
		close(fd);
		if (nr != PGHI - TLEN) { errs++; continue; }

		firstbad = -1; badval = 0;
		for (k = 0; k < nr; k++) {
			if (TLEN + k == GROW)
				continue;		/* the byte we just wrote */
			if (rd[k] != 0) {
				firstbad = TLEN + k; badval = rd[k] & 0xff;
				break;
			}
		}
		if (firstbad >= 0) {
			hits++;
			if (firstbad < minbad) minbad = firstbad;
			if (hits <= 8)
				printf("  t%d: NONZERO at %d value 0x%02x (P1 there = 0x%02x)%s\n",
					i, firstbad, badval, big[firstbad] & 0xff,
					(firstbad >= STALE) ? " [PAST THE 2K STOP]" : "");
		}
	}

	printf("TRUNCTEST files=%d hits=%d errs=%d", n, hits, errs);
	if (hits)
		printf(" firstbad_min=%d", minbad);
	printf("\n");
	printf(hits ? "TRUNCTEST-RESULT STALE-DATA\n" : "TRUNCTEST-RESULT ZEROED\n");
	exit(hits ? 1 : 0);
}
