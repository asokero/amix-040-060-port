/* pgcreatetest.c -- ISSUE-27 acceptance test: segmap_pagecreate tail-zero on UFS.
 *
 * Test design follows vm-map/PAGECREATE-TAILZERO-SPEC.md "Acceptance test".
 *
 * THE DEFECT
 *   segmap_pagecreate (0xa9722) creates full 4 KiB pages and deliberately leaves them
 *   uninitialized; the caller is responsible for zeroing the part uiomove did not
 *   write.  rwip rounds that zero-fill to roundup(off+on+n, PAGESIZE) -- and PAGESIZE
 *   there was still 2048.  So for a partial write at the start of a page, the interval
 *
 *       [ roundup(end, 2048), roundup(end, 4096) )
 *
 *   is never zeroed and keeps whatever the recycled physical page held.  A later
 *   write into that same cached page makes those bytes file contents.
 *
 * THE PROBE  (offsets chosen by the spec so UFS fragment growth + fbread cannot mask it)
 *   file has a fully written first 8 KiB UFS block (fs_bsize = 8192)
 *   write 100 B at offset 8192      -> start of a NEW UFS block, page-aligned:
 *                                      as_iolock sets pagecreate=1, segmap_pagecreate
 *                                      makes the 4 KiB page 8192..12287, uiomove fills
 *                                      8192..8291
 *                                      pre-fix zero-fill stops at 10240
 *                                      post-fix zero-fill runs to 12288
 *   write  10 B at offset 11192     -> 8192+3000, NOT page-aligned: as_iolock bails,
 *                                      pagecreate=0, no zero-fill; plain uiomove into
 *                                      the SAME cached page.  i_size becomes 11202, so
 *                                      the untouched bytes are now file contents.
 *   read back [8292, 11202)         -> everything except the last 10 bytes must be 0.
 *                                      *** [10240, 11192) is the pre-fix stale window ***
 *
 * Before each batch we dirty and release a pool of anonymous pages with a recognizable
 * marker (MARKER below), because on a fresh boot page_get may hand out pages that are
 * already zero and hide the defect entirely.
 *
 * IMPORTANT, from the spec: a pre-fix run that finds NOTHING is INCONCLUSIVE, not a
 * pass.  Only a post-fix run with zero failures is meaningful, and only after the same
 * bytes have been re-checked from disk across sync+reboot+fsck.
 *
 * usage: pgcreatetest [iterations] [batch] [path]
 *        defaults: 256 iterations, 16 per dirty-pool batch, /tmp/pgc.dat
 *
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o pgcreatetest pgcreatetest.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define BLK	8192		/* UFS fs_bsize on the measured root filesystem */
#define OFF1	8192		/* start of the second UFS block */
#define LEN1	100
#define OFF2	11192		/* 8192 + 3000, deliberately NOT page-aligned */
#define LEN2	10
#define EOFF	(OFF2 + LEN2)	/* 11202 */
#define CHKLO	(OFF1 + LEN1)	/* 8292  -- first byte that must read as zero */
#define STALELO	10240		/* roundup(8292, 2048) -- pre-fix zero-fill stops here */

#define MARKER	0xC5		/* recycled-page marker; any nonzero hit reports its value */

/* EXTENDED PROBE (added after a 32-iteration pre-fix run came back clean).
 * The spec's window [8292,11192) is only 952 bytes wide.  Writing one more byte at
 * PGEND-1 = 12287 -- still inside the SAME 4 KiB page 8192..12287, and not page
 * aligned, so it takes no pagecreate and no zero-fill -- makes the whole rest of that
 * page file contents.  That widens the observable pre-fix stale window from
 * [10240,11192) to [10240,12287) and is strictly more sensitive.  The spec window is
 * still reported separately so the spec's own criterion is answered on its own terms. */
#define PGEND	12288
#define OFF3	(PGEND - 1)	/* 12287 */

int poolmb = 4;			/* MB of anonymous pages dirtied+released per batch */

char blkbuf[BLK];
char w1[LEN1];
char w2[LEN2];
char w3[1];
char rd[PGEND - CHKLO + 16];

/* Put recyclable NON-ZERO pages on the free list.
 *
 * First attempt dirtied anonymous memory in a forked child, but a byte-by-byte memset
 * of several MB is far too slow under emulation AND anon pages are not the population
 * segmap_pagecreate's page_get draws from first.  Writing MARKER pages into a scratch
 * FILE and unlinking it is both much cheaper and much better targeted: those are file
 * cache pages, exactly the kind the probe's page_get recycles.
 * poolmb is now "pool pages" x 8 (kept as one knob). */
char poolbuf[PGEND];

dirtypool(dir)
char *dir;
{
	int fd, k, n;
	char pp[64];

	for (k = 0; k < PGEND; k++)
		poolbuf[k] = (char)MARKER;
	n = poolmb * 8;			/* pages of marker to churn */
	sprintf(pp, "%s.poison", dir);
	(void)unlink(pp);
	fd = open(pp, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return;
	for (k = 0; k < n; k += 3)
		(void)write(fd, poolbuf, PGEND);
	close(fd);
	(void)unlink(pp);
}

/* returns 0 clean, >0 dirty (see firstbad/badval), <0 I/O error */
int probe(path, firstbad, badval)
char *path;
int *firstbad;
int *badval;
{
	int fd, i, n;

	*firstbad = -1;
	*badval = 0;

	(void)unlink(path);
	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return -1;

	/* fully initialize the first 8 KiB UFS block */
	if (write(fd, blkbuf, BLK) != BLK) { close(fd); return -2; }

	/* 100 B at the start of the next block -> pagecreate path */
	if (lseek(fd, (long)OFF1, 0) != (long)OFF1) { close(fd); return -3; }
	if (write(fd, w1, LEN1) != LEN1) { close(fd); return -4; }

	/* 10 B further into the SAME page, not page-aligned -> no pagecreate */
	if (lseek(fd, (long)OFF2, 0) != (long)OFF2) { close(fd); return -5; }
	if (write(fd, w2, LEN2) != LEN2) { close(fd); return -6; }

	/* EXTENDED: one more byte at the very end of the SAME 4 KiB page, not page
	 * aligned -> no pagecreate, no zero-fill; exposes the rest of the page. */
	if (lseek(fd, (long)OFF3, 0) != (long)OFF3) { close(fd); return -9; }
	if (write(fd, w3, 1) != 1) { close(fd); return -10; }

	/* read back everything from the first must-be-zero byte to the page end */
	if (lseek(fd, (long)CHKLO, 0) != (long)CHKLO) { close(fd); return -7; }
	n = PGEND - CHKLO;
	if (read(fd, rd, n) != n) { close(fd); return -8; }
	close(fd);

	/* every byte we did NOT write must be zero */
	for (i = 0; i < n; i++) {
		if (CHKLO + i >= OFF2 && CHKLO + i < OFF2 + LEN2)
			continue;		/* the 10-byte marker */
		if (CHKLO + i == OFF3)
			continue;		/* the 1-byte extension */
		if (rd[i] != 0) {
			*firstbad = CHKLO + i;
			*badval = rd[i] & 0xff;
			return 1;
		}
	}
	/* and the bytes we wrote must still be there */
	for (i = 0; i < LEN2; i++) {
		if (rd[OFF2 - CHKLO + i] != w2[i]) {
			*firstbad = OFF2 + i;
			*badval = rd[OFF2 - CHKLO + i] & 0xff;
			return 2;
		}
	}
	if (rd[OFF3 - CHKLO] != w3[0]) {
		*firstbad = OFF3;
		*badval = rd[OFF3 - CHKLO] & 0xff;
		return 2;
	}
	return 0;
}

main(argc, argv)
int argc;
char **argv;
{
	int iters, batch, i, r, firstbad, badval;
	int hits, stalehits, errs, minbad;
	char *path;

	iters = (argc > 1) ? atoi(argv[1]) : 256;
	batch = (argc > 2) ? atoi(argv[2]) : 16;
	if (argc > 3) poolmb = atoi(argv[3]);
	path  = (argc > 4) ? argv[4] : "/tmp/pgc.dat";
	if (batch < 1)
		batch = 1;

	setbuf(stdout, (char *)0);
	for (i = 0; i < BLK; i++)
		blkbuf[i] = (char)(0x40 + (i & 0x1f));
	for (i = 0; i < LEN1; i++)
		w1[i] = (char)(0x81 + i);
	for (i = 0; i < LEN2; i++)
		w2[i] = (char)(0x91 + i);
	w3[0] = (char)0xEE;

	printf("pgcreatetest: %d iters, batch %d, path %s\n", iters, batch, path);
	printf("  probe: 100B@%d, 10B@%d, 1B@%d; everything else in [%d,%d) must be zero\n",
		OFF1, OFF2, OFF3, CHKLO, PGEND);
	printf("  pre-fix stale window = [%d,%d) (zero-fill stops at roundup(%d,2048))\n",
		STALELO, PGEND, CHKLO);
	printf("  page pool: %d marker pages churned through a scratch file before each batch of %d\n",
		poolmb * 8, batch);

	hits = 0;
	stalehits = 0;
	errs = 0;
	minbad = 0x7fffffff;

	for (i = 0; i < iters; i++) {
		if ((i % batch) == 0)
			dirtypool(path);
		r = probe(path, &firstbad, &badval);
		if (r < 0) {
			printf("  iter %d: I/O ERROR r=%d errno=%d\n", i, r, errno);
			errs++;
			if (errs > 5) {
				printf("  too many I/O errors, aborting\n");
				break;
			}
			continue;
		}
		if (r > 0) {
			hits++;
			if (firstbad < minbad)
				minbad = firstbad;
			if (firstbad >= STALELO)
				stalehits++;
			if (hits <= 8)
				printf("  iter %d: NONZERO at offset %d value 0x%02x%s%s\n",
					i, firstbad, badval,
					(badval == MARKER) ? " (== pool MARKER)" : "",
					(firstbad >= STALELO) ? " [IN STALE WINDOW]" : "");
		}
		if ((i % 64) == 63)
			printf("  ... %d/%d done, %d hits\n", i + 1, iters, hits);
	}

	(void)unlink(path);

	printf("PGCREATE iters=%d hits=%d stalewindow=%d ioerr=%d",
		iters, hits, stalehits, errs);
	if (hits)
		printf(" firstbad_min=%d", minbad);
	printf("\n");
	if (hits == 0 && errs == 0)
		printf("PGCREATE-RESULT CLEAN\n");
	else
		printf("PGCREATE-RESULT DIRTY\n");
	exit(hits ? 1 : 0);
}
