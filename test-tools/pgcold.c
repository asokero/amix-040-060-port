/* pgcold.c -- ISSUE-27 COLD-CACHE reproducer (two phases, separated by a reboot).
 *
 * Why this exists: test-tools/pgcreatetest.c reads the tail back in the SAME process
 * immediately after writing it, and Codex's reachability analysis
 * (vm-map/PAGECREATE-REACHABILITY-AND-UFSBMAP.md) showed that this can never see the
 * defect: fbread enters through as_fault(..., F_SOFTLOCK, ...), and if the page is
 * still resident the fault path reuses it rather than re-reading the disk image.  So
 * the 0/64 result measured page-cache lifetime, not the tail.
 *
 * The exposure route is instead:
 *
 *     segmap_pagecreate makes a full 4 KiB page from a RECYCLED (non-zero) frame
 *  -> uiomove writes only the first 100 bytes
 *  -> the caller zero-fills only to roundup(end, 2048)          <-- the pre-fix bug
 *  -> ufs_putpage submits the page with a 4096-byte I/O length, clamped to the UFS
 *     block boundary and NOT to i_size (Codex: 0x82c56 / 0x82cac / 0x82cc4..0x82cd2,
 *     no final clamp to i_size - page_offset)
 *  -> the un-zeroed tail reaches the platter
 *  -> REBOOT drops the page cache
 *  -> a later write past the old EOF pages the block back in FROM DISK and the tail
 *     becomes file contents
 *
 * PHASE A (before reboot)   create N files; for each: fill the first 8 KiB UFS block,
 *                           poison the page pool with MARKER, write 100 B at 8192
 *                           (page-aligned -> pagecreate = 1), sync.
 *                           i_size ends at 8292; the pre-fix zero-fill stops at 10240,
 *                           so [10240,12288) is the suspect interval.
 * PHASE B (after reboot)    for each file: first read at 8292 to record the cold i_size,
 *                           then write 10 B at 11192 -- not page aligned, so no
 *                           pagecreate and no zero-fill -- which extends i_size and
 *                           forces the block in from disk.  Then read [8292,12288) and
 *                           require every never-written byte to be zero.
 *
 * A hit whose value == MARKER (0xC5) is the strongest possible evidence: that byte can
 * only have come from a page this test poisoned.
 *
 * Per the spec, a clean PRE-FIX run is still NOT proof of absence -- it only becomes
 * conclusive with provenance instrumentation showing a non-zero page actually entered
 * segmap_pagecreate.  Report accordingly.
 *
 * usage: pgcold A|B [nfiles] [dir]      defaults: 32 files, /pgc
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o pgcold pgcold.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define BLK	8192		/* UFS fs_bsize on the measured root filesystem */
#define OFF1	8192		/* start of the second UFS block, page aligned */
#define LEN1	100
#define OFF2	11192		/* 8192+3000, NOT page aligned -> no pagecreate */
#define LEN2	10
#define CHKLO	(OFF1 + LEN1)	/* 8292 */
#define STALELO	10240		/* roundup(8292,2048): pre-fix zero-fill stops here */
#define PGEND	12288		/* end of the 4 KiB VM page that starts at 8192 */

#define MARKER	0xC5
#define POOLPG	48		/* marker pages churned through a scratch file */

char blkbuf[BLK];
char poolbuf[PGEND];
char w1[LEN1];
char w2[LEN2];
char rd[PGEND - CHKLO + 16];

setpat()
{
	int i;

	for (i = 0; i < BLK; i++)
		blkbuf[i] = (char)(0x40 + (i & 0x1f));
	for (i = 0; i < PGEND; i++)
		poolbuf[i] = (char)MARKER;
	for (i = 0; i < LEN1; i++)
		w1[i] = (char)(0x81 + i);
	for (i = 0; i < LEN2; i++)
		w2[i] = (char)(0x91 + i);
}

/* Put recyclable NON-ZERO pages on the free list: file cache pages, which is the
 * population segmap_pagecreate's page_get draws from. */
poison(dir)
char *dir;
{
	int fd, k;
	char p[128];

	sprintf(p, "%s/poison", dir);
	(void)unlink(p);
	fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return;
	for (k = 0; k < POOLPG; k += 3)
		(void)write(fd, poolbuf, PGEND);
	close(fd);
	(void)unlink(p);
}

phaseA(n, dir)
int n;
char *dir;
{
	int i, fd, errs;
	char p[128];

	errs = 0;
	printf("PHASE A: %d files in %s\n", n, dir);
	printf("  each: 8 KiB block, then 100 B at %d (pagecreate=1); i_size -> %d\n",
		OFF1, CHKLO);
	printf("  pre-fix zero-fill stops at %d; suspect interval [%d,%d)\n",
		STALELO, STALELO, PGEND);
	for (i = 0; i < n; i++) {
		sprintf(p, "%s/f%d", dir, i);
		(void)unlink(p);
		poison(dir);		/* poison immediately before the pagecreate */
		fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) { errs++; continue; }
		if (write(fd, blkbuf, BLK) != BLK) { errs++; close(fd); continue; }
		if (lseek(fd, (long)OFF1, 0) == -1L) { errs++; close(fd); continue; }
		if (write(fd, w1, LEN1) != LEN1) { errs++; close(fd); continue; }
		close(fd);
	}
	sync();
	sync();
	printf("PHASE-A-DONE files=%d errs=%d  (now sync, reboot, then run phase B)\n",
		n, errs);
	return errs;
}

phaseB(n, dir)
int n;
char *dir;
{
	int i, fd, k, nr, hits, marker_hits, errs, minbad, shortsz;
	int firstbad, badval;
	char p[128];

	hits = 0; marker_hits = 0; errs = 0; minbad = 0x7fffffff; shortsz = 0;
	printf("PHASE B: %d files in %s (cold cache -- data must come from disk)\n", n, dir);
	for (i = 0; i < n; i++) {
		sprintf(p, "%s/f%d", dir, i);
		fd = open(p, O_RDWR, 0);
		if (fd < 0) { errs++; continue; }

		/* record the cold size: a read at CHKLO must return 0 bytes (EOF) */
		if (lseek(fd, (long)CHKLO, 0) == -1L) { errs++; close(fd); continue; }
		nr = read(fd, rd, PGEND - CHKLO);
		if (nr != 0)
			shortsz++;	/* file is longer than expected -- report it */

		/* extend past the old EOF; this pages the block in FROM DISK */
		if (lseek(fd, (long)OFF2, 0) == -1L) { errs++; close(fd); continue; }
		if (write(fd, w2, LEN2) != LEN2) { errs++; close(fd); continue; }

		if (lseek(fd, (long)CHKLO, 0) == -1L) { errs++; close(fd); continue; }
		nr = read(fd, rd, PGEND - CHKLO);
		close(fd);
		if (nr < OFF2 + LEN2 - CHKLO) { errs++; continue; }

		firstbad = -1; badval = 0;
		for (k = 0; k < nr; k++) {
			if (CHKLO + k >= OFF2 && CHKLO + k < OFF2 + LEN2)
				continue;		/* the 10 bytes we just wrote */
			if (rd[k] != 0) {
				firstbad = CHKLO + k;
				badval = rd[k] & 0xff;
				break;
			}
		}
		if (firstbad >= 0) {
			hits++;
			if (badval == MARKER)
				marker_hits++;
			if (firstbad < minbad)
				minbad = firstbad;
			if (hits <= 10)
				printf("  f%d: NONZERO at %d value 0x%02x%s%s\n",
					i, firstbad, badval,
					(badval == MARKER) ? " (== pool MARKER)" : "",
					(firstbad >= STALELO) ? " [IN STALE WINDOW]" : "");
		}
	}
	printf("PGCOLD files=%d hits=%d markerhits=%d longer_than_expected=%d errs=%d",
		n, hits, marker_hits, shortsz, errs);
	if (hits)
		printf(" firstbad_min=%d", minbad);
	printf("\n");
	printf(hits ? "PGCOLD-RESULT DIRTY\n" : "PGCOLD-RESULT CLEAN\n");
	return hits;
}

/* ===========================================================================
 * MODE C -- the in-file partial-page probe.  This is the one that matters.
 *
 * Phases A/B chase a tail past EOF, which UFS masks: with i_size 8292 the bytes
 * beyond the last allocated fragment are a HOLE, and ufs_getapage zero-fills holes
 * explicitly.  So that shape can never show the defect on this filesystem.
 *
 * The reachable case is a page-aligned write, ENTIRELY INSIDE an already-allocated
 * file, whose length is a multiple of 2048 but NOT of 4096.  as_iolock's
 *      if (uio_offset + n < to_filesize) { if ((n &= PAGEMASK) == 0) return iosize; }
 * is what protects against a partial pagecreate, and PAGEMASK was 2 KiB:
 *
 *   pre-fix   6144 & ~2047 = 6144  -> NOT trimmed.  segmap_pagecreate makes TWO
 *             uninitialised pages [8192,12288)+[12288,16384); uiomove fills only
 *             8192..14335; roundup(14336,2048) == 14336 == uio_offset so the tail-zero
 *             does not run AT ALL.  [14336,16384) keeps the recycled page's contents,
 *             DESTROYING VALID FILE DATA that was there before.
 *   post-fix  6144 & ~4095 = 4096 -> one full page, fully written.  The leftover 2048 B
 *             comes back as a second iteration where 2048 & ~4095 == 0, so pagecreate=0
 *             and it is an ordinary read-modify-write.  [14336,16384) is PRESERVED.
 *
 * The signal is "the original pattern is gone", which does NOT depend on the recycled
 * page being non-zero -- zeros are a failure too.  That removes the page-provenance
 * problem that made modes A/B inconclusive.
 * =========================================================================== */

#define CSIZE	32768		/* 4 UFS blocks, all allocated */
#define CWOFF	8192		/* page- and block-aligned */
#define CWLEN	6144		/* 3*2048: multiple of 2048, NOT of 4096 */
#define CKEEP	(CWOFF + CWLEN)	/* 14336 -- first byte that MUST be untouched */
#define CPEND	16384		/* end of the second 4 KiB page */

char big[CSIZE];
char c2[CWLEN];
char cr[CPEND - CWOFF + 16];

int phaseC(n, dir)
int n;
char *dir;
{
	int i, fd, k, nr, hits, zerohits, markerhits, errs, minbad;
	int firstbad, badval;
	char p[128];

	for (i = 0; i < CSIZE; i++)
		big[i] = (char)(0x11 + (i % 251));	/* position-dependent P1 */
	for (i = 0; i < CWLEN; i++)
		c2[i] = (char)(0xA0 + (i & 0x0f));	/* P2 */

	hits = 0; zerohits = 0; markerhits = 0; errs = 0; minbad = 0x7fffffff;
	printf("PHASE C: %d files in %s\n", n, dir);
	printf("  file %d B all-allocated; write %d B of P2 at %d\n", CSIZE, CWLEN, CWOFF);
	printf("  [%d,%d) MUST still hold the ORIGINAL pattern P1\n", CKEEP, CPEND);

	for (i = 0; i < n; i++) {
		sprintf(p, "%s/c%d", dir, i);
		(void)unlink(p);
		fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) { errs++; continue; }
		if (write(fd, big, CSIZE) != CSIZE) { errs++; close(fd); continue; }
		close(fd);
		sync();
		poison(dir);		/* recycled pages should be non-zero */

		fd = open(p, O_RDWR, 0);
		if (fd < 0) { errs++; continue; }
		if (lseek(fd, (long)CWOFF, 0) == -1L) { errs++; close(fd); continue; }
		if (write(fd, c2, CWLEN) != CWLEN) { errs++; close(fd); continue; }
		if (lseek(fd, (long)CWOFF, 0) == -1L) { errs++; close(fd); continue; }
		nr = read(fd, cr, CPEND - CWOFF);
		close(fd);
		if (nr != CPEND - CWOFF) { errs++; continue; }

		firstbad = -1; badval = 0;
		/* the written range must be P2 */
		for (k = 0; k < CWLEN; k++) {
			if (cr[k] != c2[k]) {
				firstbad = CWOFF + k; badval = cr[k] & 0xff; break;
			}
		}
		/* and the rest of the page must still be the ORIGINAL P1 */
		if (firstbad < 0) {
			for (k = CWLEN; k < CPEND - CWOFF; k++) {
				if (cr[k] != big[CWOFF + k]) {
					firstbad = CWOFF + k; badval = cr[k] & 0xff; break;
				}
			}
		}
		if (firstbad >= 0) {
			hits++;
			if (badval == 0) zerohits++;
			if (badval == MARKER) markerhits++;
			if (firstbad < minbad) minbad = firstbad;
			if (hits <= 10)
				printf("  c%d: at %d got 0x%02x want 0x%02x%s%s\n",
					i, firstbad, badval,
					big[firstbad] & 0xff,
					(badval == MARKER) ? " (== pool MARKER)" : "",
					(badval == 0) ? " (zeroed)" : "");
		}
	}
	printf("PGCOLD-C files=%d hits=%d zeroed=%d marker=%d errs=%d",
		n, hits, zerohits, markerhits, errs);
	if (hits)
		printf(" firstbad_min=%d", minbad);
	printf("\n");
	printf(hits ? "PGCOLD-C-RESULT DATA-DESTROYED\n" : "PGCOLD-C-RESULT PRESERVED\n");
	return hits;
}

/* ===========================================================================
 * MODES D / E -- mode C's probe, but COLD.
 *
 * Mode C came back PRESERVED because segmap_pagecreate does a page_lookup first: the
 * file had just been written, so its pages were still in the vnode page cache and were
 * reused WITH their contents instead of a fresh recycled frame.  sync() flushes, it does
 * not evict.  So the partial-page probe has to cross a reboot too:
 *
 *   D   create N files of CSIZE with pattern P1, sync            -> then REBOOT
 *   E   per file: poison the pool, write CWLEN bytes of P2 at CWOFF, read back and
 *       require [CKEEP,CPEND) to still be P1
 *
 * After the reboot the page is cold, page_lookup misses, page_get hands back a recycled
 * frame, and the pre-fix kernel never zeroes the part uiomove did not write.
 * =========================================================================== */

int phaseD(n, dir)
int n;
char *dir;
{
	int i, fd, errs;
	char p[128];

	for (i = 0; i < CSIZE; i++)
		big[i] = (char)(0x11 + (i % 251));
	errs = 0;
	printf("PHASE D: creating %d files of %d B (pattern P1) in %s\n", n, CSIZE, dir);
	for (i = 0; i < n; i++) {
		sprintf(p, "%s/c%d", dir, i);
		(void)unlink(p);
		fd = open(p, O_RDWR | O_CREAT | O_TRUNC, 0600);
		if (fd < 0) { errs++; continue; }
		if (write(fd, big, CSIZE) != CSIZE) errs++;
		close(fd);
	}
	sync(); sync();
	printf("PHASE-D-DONE files=%d errs=%d  (now reboot, then run mode E)\n", n, errs);
	return errs;
}

int phaseE(n, dir)
int n;
char *dir;
{
	int i, fd, k, nr, hits, zerohits, markerhits, errs, minbad;
	int firstbad, badval;
	char p[128];

	for (i = 0; i < CSIZE; i++)
		big[i] = (char)(0x11 + (i % 251));
	for (i = 0; i < CWLEN; i++)
		c2[i] = (char)(0xA0 + (i & 0x0f));

	hits = 0; zerohits = 0; markerhits = 0; errs = 0; minbad = 0x7fffffff;
	printf("PHASE E: %d files, COLD cache; write %d B of P2 at %d\n", n, CWLEN, CWOFF);
	printf("  [%d,%d) MUST still hold the ORIGINAL P1\n", CKEEP, CPEND);

	for (i = 0; i < n; i++) {
		sprintf(p, "%s/c%d", dir, i);
		poison(dir);
		fd = open(p, O_RDWR, 0);
		if (fd < 0) { errs++; continue; }
		if (lseek(fd, (long)CWOFF, 0) == -1L) { errs++; close(fd); continue; }
		if (write(fd, c2, CWLEN) != CWLEN) { errs++; close(fd); continue; }
		if (lseek(fd, (long)CWOFF, 0) == -1L) { errs++; close(fd); continue; }
		nr = read(fd, cr, CPEND - CWOFF);
		close(fd);
		if (nr != CPEND - CWOFF) { errs++; continue; }

		firstbad = -1; badval = 0;
		for (k = 0; k < CWLEN; k++)
			if (cr[k] != c2[k]) { firstbad = CWOFF + k; badval = cr[k] & 0xff; break; }
		if (firstbad < 0)
			for (k = CWLEN; k < CPEND - CWOFF; k++)
				if (cr[k] != big[CWOFF + k]) {
					firstbad = CWOFF + k; badval = cr[k] & 0xff; break;
				}
		if (firstbad >= 0) {
			hits++;
			if (badval == 0) zerohits++;
			if (badval == MARKER) markerhits++;
			if (firstbad < minbad) minbad = firstbad;
			if (hits <= 10)
				printf("  c%d: at %d got 0x%02x want 0x%02x%s%s\n",
					i, firstbad, badval, big[firstbad] & 0xff,
					(badval == MARKER) ? " (== pool MARKER)" : "",
					(badval == 0) ? " (zeroed)" : "");
		}
	}
	printf("PGCOLD-E files=%d hits=%d zeroed=%d marker=%d errs=%d",
		n, hits, zerohits, markerhits, errs);
	if (hits)
		printf(" firstbad_min=%d", minbad);
	printf("\n");
	printf(hits ? "PGCOLD-E-RESULT DATA-DESTROYED\n" : "PGCOLD-E-RESULT PRESERVED\n");
	return hits;
}

main(argc, argv)
int argc;
char **argv;
{
	int n, r;
	char *dir;

	setbuf(stdout, (char *)0);
	if (argc < 2) {
		printf("usage: pgcold A|B|C|D|E [nfiles] [dir]\n");
		exit(2);
	}
	n = (argc > 2) ? atoi(argv[2]) : 32;
	dir = (argc > 3) ? argv[3] : "/pgc";
	setpat();

	if (argv[1][0] == 'A' || argv[1][0] == 'a')
		r = phaseA(n, dir);
	else if (argv[1][0] == 'C' || argv[1][0] == 'c')
		r = phaseC(n, dir);
	else if (argv[1][0] == 'D' || argv[1][0] == 'd')
		r = phaseD(n, dir);
	else if (argv[1][0] == 'E' || argv[1][0] == 'e')
		r = phaseE(n, dir);
	else
		r = phaseB(n, dir);
	exit(r ? 1 : 0);
}
