/* pgsztest.c -- does the kernel tell user space the TRUTH about its page size?
 *
 * The kernel runs on 4 KiB pages (Model B) but sysconfig's _CONFIG_PAGESIZE case
 * returned 2048 (patch_sysconfig_pagesize.py, site 0x44e7c).  Every program that
 * asks got the wrong answer -- and computing an alignment from 2048 is exactly how
 * a program lands at page+0x800, where the mmap/munmap/mprotect half-page defects
 * live.  So this is the discriminating test for that fix.
 *
 * DISCRIMINATING SIGNAL: pre-fix prints 2048 and FAILs; post-fix prints 4096.
 * A second, independent check derives the page size from the kernel's OWN behaviour
 * via mincore(), so the test does not rely solely on the number sysconf reports.
 *
 * K&R C for the AMIX native cc.  cc -o pgsztest pgsztest.c
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>

/* SVR4 has no MAP_ANON (that is a BSD-ism); anonymous memory comes from /dev/zero. */

extern long sysconf();

main(argc, argv)
int argc;
char **argv;
{
	long ps;
	int fails;
	char *p;
	char vec[16];
	int i, n, zfd;

	fails = 0;

	ps = sysconf(_SC_PAGESIZE);
	printf("PGSZ sysconf(_SC_PAGESIZE) = %ld\n", ps);
	if (ps != 4096L) {
		printf("PGSZ FAIL: kernel reports %ld but runs on 4096\n", ps);
		fails++;
	}

	/* Independent cross-check: mincore writes ONE byte per hardware page.
	 * Map 4 pages' worth at the reported size and count what mincore fills in.
	 * If the reported size is right, 4*ps bytes must yield exactly 4 entries. */
	zfd = open("/dev/zero", O_RDWR);
	if (zfd < 0) {
		printf("PGSZ (mincore cross-check skipped: no /dev/zero)\n");
		p = (char *)-1;
	} else
		p = (char *) mmap((caddr_t)0, (size_t)(4*ps), PROT_READ|PROT_WRITE,
				  MAP_PRIVATE, zfd, (off_t)0);
	if (p == (char *)-1) {
		if (zfd >= 0)
			printf("PGSZ (mincore cross-check skipped: mmap failed)\n");
	} else {
		for (i = 0; i < 16; i++)
			vec[i] = (char)0xAA;
		if (mincore(p, (size_t)(4*ps), vec) == 0) {
			n = 0;
			for (i = 0; i < 16; i++)
				if (vec[i] != (char)0xAA)
					n++;
			printf("PGSZ mincore over 4*%ld bytes wrote %d entries (expect 4)\n",
			       ps, n);
			if (n != 4) {
				printf("PGSZ FAIL: reported page size disagrees with mincore\n");
				fails++;
			}
		} else {
			printf("PGSZ (mincore cross-check skipped: mincore failed)\n");
		}
		(void) munmap(p, (size_t)(4*ps));
	}
	if (zfd >= 0)
		(void) close(zfd);

	printf("PGSZTEST-RESULT %s\n", fails ? "FAIL" : "PASS");
	exit(fails ? 1 : 0);
}
