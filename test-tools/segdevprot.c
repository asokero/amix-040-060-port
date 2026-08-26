/* segdevprot.c -- exercise segdev_setprot and segdev_unmap on a device mapping.
 *
 * WHY THIS EXISTS.  ISSUE-49's paired-vpage bridge (src/patch_segdev_bridge.py) makes
 * segdev step one 4 KiB hardware page while the software vpage array keeps two entries
 * per page.  The fault loop reads the FIRST entry of each pair, so the bridge is correct
 * only while both members stay equal -- which holds because the generic as_* boundaries
 * round to 4 KiB before segdev is reached.
 *
 * src/segdevchk040.s counts any segdev operation arriving on a sub-page address or length,
 * and those counters must read zero.  But a zero means nothing until the path has been
 * taken: after devmaptest, sdc_unmap_n was 4 and sdc_setprot_n was 0, so one of those two
 * zeros was evidence and the other was silence.  This program supplies the missing
 * denominator by doing what the review's acceptance item 5 asks for:
 *
 *   1. map several pages of a device
 *   2. mprotect the MIDDLE page only            -> segdev_setprot with a 4 KiB sub-range
 *   3. touch every page, before and after       -> segdev_fault across a protection edge
 *   4. unmap low, middle and high separately    -> segdev_unmap splitting the segment
 *   5. fork while the mapping is live           -> segdev_dup
 *
 * It does NOT try to judge the counters itself: it prints what it did, and the caller
 * reads sdc_setprot_n / sdc_setprot_bad / sdc_unmap_n / sdc_unmap_bad from the kernel.
 * A test that reported on its own instrument would be the third self-matching check this
 * project has found in two days.
 *
 * K&R C for the AMIX SVR4 cc: no ANSI prototypes, vars at the top of each block, (char *)
 * where ANSI would use void *.
 */

#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define PGSZ    4096
#define NPAGES  5

int
main(argc, argv)
int argc;
char **argv;
{
	int fd, i, st;
	long sum;
	char *p;
	volatile char *q;

	fd = open("/dev/mem", O_RDWR);
	if (fd < 0) {
		printf("SEGDEVPROT ERR open /dev/mem errno=%d\n", errno);
		exit(1);
	}

	/* Map from physical 0: the low pages are always present, and this program only
	 * READS them.  The point is the segment operations, not the contents. */
	p = (char *) mmap((caddr_t) 0, (size_t) (NPAGES * PGSZ),
			  PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t) 0);
	if (p == (char *) -1) {
		printf("SEGDEVPROT ERR mmap errno=%d\n", errno);
		(void) close(fd);
		exit(1);
	}
	printf("SEGDEVPROT mapped %d pages at %lx\n", NPAGES, (long) p);

	/* 1. fault every page before any protection change */
	sum = 0;
	for (i = 0; i < NPAGES; i++) {
		q = (volatile char *) (p + i * PGSZ);
		sum += *q;
	}
	printf("SEGDEVPROT faulted %d pages (sum %ld)\n", NPAGES, sum);

	/* 2. protect the MIDDLE page only -- one 4 KiB sub-range inside the segment.
	 *    This is the operation that reaches segdev_setprot. */
	if (mprotect((caddr_t) (p + 2 * PGSZ), (size_t) PGSZ, PROT_READ) < 0)
		printf("SEGDEVPROT mprotect(middle,R) failed errno=%d\n", errno);
	else
		printf("SEGDEVPROT mprotect(middle,R) ok\n");

	/* 3. fault across the protection edge in both directions */
	sum = 0;
	for (i = 0; i < NPAGES; i++) {
		q = (volatile char *) (p + i * PGSZ);
		sum += *q;
	}
	printf("SEGDEVPROT re-faulted %d pages (sum %ld)\n", NPAGES, sum);

	/* widen it again, so setprot is reached with a different protection too */
	if (mprotect((caddr_t) (p + 2 * PGSZ), (size_t) PGSZ,
		     PROT_READ | PROT_WRITE) < 0)
		printf("SEGDEVPROT mprotect(middle,RW) failed errno=%d\n", errno);
	else
		printf("SEGDEVPROT mprotect(middle,RW) ok\n");

	/* 4. fork with the mapping live -- segdev_dup */
	i = fork();
	if (i == 0) {
		q = (volatile char *) (p + 2 * PGSZ);
		sum = *q;
		_exit(0);
	} else if (i > 0) {
		(void) wait(&st);
		printf("SEGDEVPROT child exited %d\n", (st >> 8) & 0xff);
	} else {
		printf("SEGDEVPROT fork failed errno=%d\n", errno);
	}

	/* 5. unmap in three pieces: low, middle, high.  Each is a separate
	 *    segdev_unmap, and the middle one splits the segment in two. */
	if (munmap((caddr_t) p, (size_t) PGSZ) < 0)
		printf("SEGDEVPROT munmap(low) failed errno=%d\n", errno);
	else
		printf("SEGDEVPROT munmap(low) ok\n");

	if (munmap((caddr_t) (p + 2 * PGSZ), (size_t) PGSZ) < 0)
		printf("SEGDEVPROT munmap(middle) failed errno=%d\n", errno);
	else
		printf("SEGDEVPROT munmap(middle) ok\n");

	if (munmap((caddr_t) (p + 4 * PGSZ), (size_t) PGSZ) < 0)
		printf("SEGDEVPROT munmap(high) failed errno=%d\n", errno);
	else
		printf("SEGDEVPROT munmap(high) ok\n");

	/* whatever is left */
	(void) munmap((caddr_t) (p + PGSZ), (size_t) PGSZ);
	(void) munmap((caddr_t) (p + 3 * PGSZ), (size_t) PGSZ);

	(void) close(fd);
	printf("SEGDEVPROT-DONE  now read sdc_setprot_n/bad and sdc_unmap_n/bad\n");
	exit(0);
}
