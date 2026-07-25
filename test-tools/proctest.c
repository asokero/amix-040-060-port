/* proctest.c -- ISSUE-17/18 acceptance test: /proc process-memory read AND write.
 *
 * Exercises the whole procfs user-memory I/O unit on a LIVE OTHER PROCESS, which is the
 * only way to prove the 040 per-process page-table walk:
 *
 *   prusrio  ->  prfastmapin   (fast path: page already resident, no COW needed)
 *                 |                040 override in prototypes/prfastmap040.s
 *                 +-> declines -> as_fault(F_SOFTLOCK) + prmapin -> vtop(addr, p)
 *                                  -> uvatopte040                (ISSUE-18a fix)
 *            ->  prfastmapout  (byte-patched phys >> PNUMSHFT, 11 sites)
 *
 * Three target regions, each hitting a different branch:
 *
 *   R1 "priv"   child writes it AFTER fork -> private, resident, WRITABLE
 *               => prfastmapin succeeds for both read and write (fast path, both ways)
 *   R2 "cow"    parent fills it BEFORE fork, child never touches it -> COW, write-protected
 *               => read: prfastmapin succeeds (W set but writing==0)
 *                  write: prfastmapin DECLINES on the W bit -> as_fault does the COW copy
 *                         -> prmapin -> vtop user branch.  Proves the slow path.
 *   R3 "absent" neither process ever touches it -> not resident at all
 *               => prfastmapin declines (PDT==0) -> as_fault faults it in; reads as 0
 *
 * Each region is 3 pages of .bss and the tested window is the page-ALIGNED middle page,
 * so "absent" really is a page nobody has touched (an unaligned window would share a page
 * with a filled neighbour and make the zero check lie).  T7 then deliberately reads a
 * PAGE-CROSSING unaligned window, which is what exercises prusrio's own page loop
 * (0x64580 `a & PAGEMASK` / 0x64586 `page + PAGESIZE`, the two sites whose earlier
 * half-conversion hung the kernel on 2026-07-03).
 *
 * A wrong walk shows up as: garbage instead of the pattern, EIO/EFAULT from read/write,
 * a write that does not land in the child, or a panic.  Under the stock 030 walk the
 * kernel reads our 040 root table as 8-byte SDEs, so anything but a clean PASS is a fail.
 *
 * Sync: two pipes, so the child is blocked in read() while the parent pokes it.
 * No PIOCSTOP needed -- prread/prwrite take prlock(pnp, ZNO, 0), which does not
 * require the target to be stopped (3b2 prvnops.c:281,350).
 *
 * K&R C for the native AMIX SVR4 cc (no ANSI prototypes, decls at top of block).
 * Build on AMIX:  cc -o proctest proctest.c
 * Run as root:    ./proctest
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define PGSZ	4096
#define WIN	4096		/* tested window = one page */
#define ASZ	(3 * PGSZ)	/* 3 pages so an aligned middle page always exists */

char a_priv[ASZ];
char a_cow[ASZ];
char a_absent[ASZ];

/* page-aligned middle window of an array */
char *win(a)
char *a;
{
	unsigned long v;

	v = ((unsigned long)a + PGSZ - 1) & ~((unsigned long)PGSZ - 1);
	return (char *)v;
}

fill(buf, n, seed)
char *buf;
int n;
int seed;
{
	int i;

	for (i = 0; i < n; i++)
		buf[i] = (char)((i * 7 + seed) & 0xff);
}

int checkpat(buf, n, seed, tag)
char *buf;
int n;
int seed;
char *tag;
{
	int i, bad;

	bad = 0;
	for (i = 0; i < n; i++) {
		if (buf[i] != (char)((i * 7 + seed) & 0xff)) {
			if (bad < 3)
				printf("  %s: mismatch at %d: got %02x want %02x\n",
					tag, i, buf[i] & 0xff,
					(i * 7 + seed) & 0xff);
			bad++;
		}
	}
	return bad;
}

int checkzero(buf, n, tag)
char *buf;
int n;
char *tag;
{
	int i, bad;

	bad = 0;
	for (i = 0; i < n; i++) {
		if (buf[i] != 0) {
			if (bad < 3)
				printf("  %s: nonzero at %d: %02x\n",
					tag, i, buf[i] & 0xff);
			bad++;
		}
	}
	return bad;
}

/* /proc uses the file OFFSET as the virtual address.  User VAs are >= 0x80000000, which
 * is negative as a signed off_t, and one lseek() with a negative offset is rejected.
 * Reach it in two positive steps instead. */
long seekto(fd, addr)
int fd;
unsigned long addr;
{
	long r;

	if (addr < 0x40000000)
		return lseek(fd, (long)addr, 0);
	r = lseek(fd, (long)0x40000000, 0);
	if (r == -1L)
		return -1L;
	return lseek(fd, (long)(addr - 0x40000000), 1);
}

/* read WIN bytes at addr; returns bytes read or -1 */
int rdat(fd, addr, buf, n)
int fd;
unsigned long addr;
char *buf;
int n;
{
	if (seekto(fd, addr) == -1L)
		return -1;
	return read(fd, buf, n);
}

main(argc, argv)
int argc;
char **argv;
{
	int pfd[2], qfd[2];
	int fd, pid, n, bad, fails;
	char c;
	char path[64];
	char buf[2 * PGSZ];
	char *wp, *wc, *wa;

	fails = 0;
	setbuf(stdout, (char *)0);

	wp = win(a_priv);
	wc = win(a_cow);
	wa = win(a_absent);

	/* R2 filled BEFORE the fork -> the child inherits it copy-on-write. */
	fill(wc, WIN, 0x11);

	if (pipe(pfd) < 0 || pipe(qfd) < 0) {
		printf("PROCTEST-RESULT FAIL: pipe\n");
		exit(1);
	}

	pid = fork();
	if (pid < 0) {
		printf("PROCTEST-RESULT FAIL: fork\n");
		exit(1);
	}

	if (pid == 0) {
		/* ---- child: the target process ---- */
		close(pfd[0]);
		close(qfd[1]);
		fill(wp, WIN, 0x33);	/* private, resident, writable */
		/* wc: never touched here -> stays COW.  wa: never touched. */
		c = 'r';
		write(pfd[1], &c, 1);		/* "ready" */
		read(qfd[0], &c, 1);		/* block until the parent has poked us */

		bad = checkpat(wp, WIN, 0x55, "child priv");
		printf(bad ? "CHILD-PRIV-WRITE FAIL\n" : "CHILD-PRIV-WRITE PASS\n");
		n = checkpat(wc, WIN, 0x77, "child cow");
		printf(n ? "CHILD-COW-WRITE FAIL\n" : "CHILD-COW-WRITE PASS\n");
		exit((bad + n) ? 1 : 0);
	}

	/* ---- parent: the /proc client ---- */
	close(pfd[1]);
	close(qfd[0]);
	read(pfd[0], &c, 1);			/* wait for "ready" */

	sprintf(path, "/proc/%d", pid);
	fd = open(path, O_RDWR);
	if (fd < 0) {
		printf("PROCTEST-RESULT FAIL: open %s errno=%d\n", path, errno);
		kill(pid, 9);
		exit(1);
	}
	printf("proctest: child pid=%d priv=%lx cow=%lx absent=%lx\n",
		pid, (unsigned long)wp, (unsigned long)wc, (unsigned long)wa);

	/* ---- T1: READ private resident page (prfastmapin fast path) ---- */
	n = rdat(fd, (unsigned long)wp, buf, WIN);
	if (n != WIN) {
		printf("T1 FAIL: read n=%d errno=%d\n", n, errno);
		fails++;
	} else {
		bad = checkpat(buf, WIN, 0x33, "T1");
		printf("T1 %s: read private resident page (bad=%d)\n",
			bad ? "FAIL" : "PASS", bad);
		if (bad)
			fails++;
	}

	/* ---- T2: READ COW page (W set, writing==0 -> fast path) ---- */
	n = rdat(fd, (unsigned long)wc, buf, WIN);
	if (n != WIN) {
		printf("T2 FAIL: read n=%d errno=%d\n", n, errno);
		fails++;
	} else {
		bad = checkpat(buf, WIN, 0x11, "T2");
		printf("T2 %s: read COW page (bad=%d)\n", bad ? "FAIL" : "PASS", bad);
		if (bad)
			fails++;
	}

	/* ---- T3: READ never-touched page (not resident -> as_fault + prmapin) ---- */
	n = rdat(fd, (unsigned long)wa, buf, WIN);
	if (n != WIN) {
		printf("T3 FAIL: read n=%d errno=%d\n", n, errno);
		fails++;
	} else {
		bad = checkzero(buf, WIN, "T3");
		printf("T3 %s: read absent page as zeros (bad=%d)\n",
			bad ? "FAIL" : "PASS", bad);
		if (bad)
			fails++;
	}

	/* ---- T4: WRITE private page (fast path, writing==1) ---- */
	fill(buf, WIN, 0x55);
	if (seekto(fd, (unsigned long)wp) == -1L) {
		printf("T4 FAIL: seek errno=%d\n", errno);
		fails++;
	} else {
		n = write(fd, buf, WIN);
		printf("T4 %s: write private page n=%d errno=%d\n",
			(n == WIN) ? "PASS" : "FAIL", n, errno);
		if (n != WIN)
			fails++;
	}

	/* ---- T5: WRITE COW page (prfastmapin must DECLINE on W -> as_fault COW) ---- */
	fill(buf, WIN, 0x77);
	if (seekto(fd, (unsigned long)wc) == -1L) {
		printf("T5 FAIL: seek errno=%d\n", errno);
		fails++;
	} else {
		n = write(fd, buf, WIN);
		printf("T5 %s: write COW page n=%d errno=%d\n",
			(n == WIN) ? "PASS" : "FAIL", n, errno);
		if (n != WIN)
			fails++;
	}

	/* ---- T6: read-back through /proc must reflect T4/T5 ---- */
	n = rdat(fd, (unsigned long)wp, buf, WIN);
	bad = (n == WIN) ? checkpat(buf, WIN, 0x55, "T6a") : 999;
	printf("T6a %s: re-read private after write (bad=%d)\n",
		bad ? "FAIL" : "PASS", bad);
	if (bad)
		fails++;
	n = rdat(fd, (unsigned long)wc, buf, WIN);
	bad = (n == WIN) ? checkpat(buf, WIN, 0x77, "T6b") : 999;
	printf("T6b %s: re-read COW after write (bad=%d)\n",
		bad ? "FAIL" : "PASS", bad);
	if (bad)
		fails++;

	/* ---- T7: PAGE-CROSSING unaligned read -- exercises prusrio's page loop ---- */
	n = rdat(fd, (unsigned long)wp + 1024, buf, WIN);
	if (n != WIN) {
		printf("T7 FAIL: crossing read n=%d errno=%d\n", n, errno);
		fails++;
	} else {
		/* first WIN-1024 bytes are wp[1024..WIN-1] = pattern 0x55 shifted */
		bad = 0;
		for (n = 0; n < WIN - 1024; n++) {
			if (buf[n] != (char)(((n + 1024) * 7 + 0x55) & 0xff)) {
				if (bad < 3)
					printf("  T7: mismatch at %d\n", n);
				bad++;
			}
		}
		printf("T7 %s: page-crossing read, first %d bytes (bad=%d)\n",
			bad ? "FAIL" : "PASS", WIN - 1024, bad);
		if (bad)
			fails++;
	}

	close(fd);

	/* let the child verify from its own side: did the writes land in the child's
	 * ACTUAL pages, or somewhere else? */
	c = 'g';
	write(qfd[1], &c, 1);
	wait((int *)0);

	printf("PROCTEST parent fails=%d\n", fails);
	printf(fails ? "PROCTEST-RESULT FAIL\n" : "PROCTEST-RESULT PASS\n");
	exit(fails ? 1 : 0);
}
