/* va2byte.c -- does the VA2000 answer a BYTE access at a given aperture offset?
 *
 * WHY THIS EXISTS.  ISSUE-65's remaining unknown is one question: the 68040's
 * write-back replay decomposes an aligned 16-bit register write into two
 * `moves.b` accesses, and on a Zorro III VA2000 the SECOND one takes a bus
 * error.  Measured 2026-09-06: the kernel's own notice says the user access was
 * `C108C070` -- even, legal, exactly what VA2000_WRITEREG emits -- while the
 * byte the replay could not write was `C108C071`.  So the board answers a byte
 * at board offset 0x70 and refuses one at 0x71, and everything else about that
 * conclusion is inference through the replay path.  This asks the board
 * directly instead.
 *
 * ONE PROBE PER PROCESS, AND THAT IS THE WHOLE DESIGN.  A user-mode bus error
 * arrives as SIGKILL here, not SIGBUS (ISSUE-47's other half, measured the same
 * day: wbf_last_signo = 9).  SIGKILL cannot be caught, so there is no
 * setjmp/longjmp harness to be had -- the process simply dies.  So each probe is
 * its own process: it prints START, flushes, touches the address, and prints OK.
 * A missing OK line IS the bus error, and the shell loop survives to run the
 * next one.  fflush before the access is not decoration: buffered output is lost
 * when the process is killed.
 *
 * READS ONLY.  Every offset probed here is read, never written, so the board's
 * state and the display are untouched.  Whether a byte WRITE behaves like a byte
 * READ is a separate question this does not answer, and the difference matters:
 * the failing access in ISSUE-65 is a write.  Read the result as "does the board
 * decode this access at all", not as "the replay would have worked".
 *
 * WRITES, added 2026-09-06 after the read pass came back clean everywhere the board
 * decodes.  A write probe READS THE LOCATION FIRST AND WRITES THE SAME VALUE BACK, so the
 * bus cycle happens and the content does not change.  That is what makes it safe to aim at
 * a live register: if the board latches the write it latches what was already there, and if
 * the register is read-only the cycle happens anyway, which is the part being tested.
 *
 * K&R C for the AMIX SVR4 native cc.  cc -o va2byte va2byte.c
 * usage: va2byte <hex-aperture-offset> [b|w] [x]
 *          b = 8-bit (default), w = 16-bit
 *          x = read, then write the same value back.  Omit for a read-only probe.
 */
#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>

main(argc, argv)
int argc;
char **argv;
{
	unsigned long off, pgoff, idx;
	unsigned int v;
	char *p;
	int fd, width, wrback;

	if (argc < 2) {
		printf("usage: va2byte <hex-offset> [b|w] [x]\n");
		exit(2);
	}
	off = 0;
	sscanf(argv[1], "%lx", &off);
	width = 1;
	if (argc > 2 && argv[2][0] == 'w')
		width = 2;
	wrback = 0;
	if (argc > 3 && argv[3][0] == 'x')
		wrback = 1;

	pgoff = off & ~0xfffL;
	idx   = off &  0xfffL;

	fd = open("/dev/va2000", O_RDWR);
	if (fd < 0) {
		printf("VA2BYTE ERR open /dev/va2000 failed\n");
		exit(1);
	}
	p = (char *) mmap((caddr_t) 0, (size_t) 4096, PROT_READ | PROT_WRITE,
			  MAP_SHARED, fd, (off_t) pgoff);
	if (p == (char *) -1) {
		printf("VA2BYTE ERR mmap pgoff=%lx failed\n", pgoff);
		exit(1);
	}

	printf("VA2BYTE START off=%lx width=%d mode=%s va=%lx\n",
	       off, width, wrback ? "rw" : "r", (unsigned long) (p + idx));
	fflush(stdout);

	if (width == 2)
		v = (unsigned int) *((volatile unsigned short *) (p + idx));
	else
		v = (unsigned int) *((volatile unsigned char *) (p + idx));

	printf("VA2BYTE READ off=%lx value=%x\n", off, v);
	fflush(stdout);

	if (wrback) {
		/* Same value back: the cycle is the experiment, not the content. */
		if (width == 2)
			*((volatile unsigned short *) (p + idx)) = (unsigned short) v;
		else
			*((volatile unsigned char *) (p + idx)) = (unsigned char) v;
		printf("VA2BYTE WROTE off=%lx value=%x\n", off, v);
		fflush(stdout);
	}

	printf("VA2BYTE OK off=%lx value=%x\n", off, v);
	fflush(stdout);
	exit(0);
}
