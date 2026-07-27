/* busbench.c -- measure throughput to a mapped device aperture (or local RAM) on AMIX.
 *
 * PURPOSE
 * The Piccolo's RAM aperture autoconfigures at 0x40000000 with a 16 MB window, i.e. in
 * ZORRO III space (board 0x0893/5 "Piccolo RAM"; its register window 0x0893/6 is at
 * 0x00eb0000 in Zorro II I/O).  The VA2000 sits at 0x00200000, Zorro II MEM.  So both a
 * Z3-addressed and a Z2-addressed graphics aperture are present in the same machine, and the
 * question is whether the Z3 path is actually faster.  This program is the measurement.
 *
 * *** READ THIS BEFORE BELIEVING ANY NUMBER IT PRINTS ***
 *
 * 1. THE TWO CARDS DO NOT GET THE SAME CACHE TREATMENT, and the Z3 one gets the slower class.
 *    DTT0 = 0x003fc060 covers 0x00000000-0x3FFFFFFF with CM = 0x60 = noncacheable, NOT
 *    serialised.  The VA2000 at 0x00200000 is inside that.  The Piccolo at 0x40000000 is
 *    OUTSIDE it, so its mapping takes CM from the leaf PTE, and hat040.s's Lcm_sel gives every
 *    pp==NULL device mapping 0x40 = noncacheable-SERIALISED.  Serialisation forces each access
 *    to complete before the next starts: no write combining, no CPU-side bursts.
 *    => A raw Piccolo-vs-VA2000 comparison compares Z3-serialised against Z2-unserialised and
 *       can make the Z3 card look SLOWER for a reason that has nothing to do with the bus.
 *       If the Piccolo measures slow, the FIRST hypothesis is NCS, not Zorro III.
 *    (Serialisation exists to stop MMIO register accesses being reordered.  A framebuffer is
 *    memory-like and does not need it; Lcm_sel already has a three-way selector, so adding a
 *    framebuffer class is the same shape of change.)
 *
 * 2. The local-RAM reference run is not decoration.  On a 25-33 MHz 040 the loop itself has a
 *    ceiling, and without the reference you cannot tell "the bus is slow" from "the CPU is
 *    slow".  Always run -r first and quote it alongside.
 *
 * 3. The word/long ratio is a bus-WIDTH hint but not a clean one.  On a 16-bit Zorro II port a
 *    32-bit access costs two bus cycles but is one CPU access, so if serialisation overhead
 *    dominates you get long ~= 2x word on BOTH buses, and only if bus cycles dominate does the
 *    ratio separate them.  Report it, do not over-read it.
 *
 * 4. Writing to a framebuffer aperture puts garbage on the screen.  Harmless, expected.
 *
 * 5. The Piccolo's 16 MB window is ADDRESS SPACE, not installed VRAM.  The driver compares the
 *    board size against 2097152 in three places and svgaprobe reports FrameBufSize=2097152, so
 *    expect about 2 MB of real memory behind it.  Map less than you think you can.
 *
 * SUGGESTED RUN ORDER
 *    0.  svgaprobe on the real machine FIRST -- it has never been run there, and it tells you
 *        whether /dev/svga0 opens, whether the Z3 aperture maps, and the reported size.
 *    1.  busbench -r                              local RAM ceiling on this CPU
 *    2.  busbench /dev/svga0   1048576            Piccolo   (Z3 address, CM 0x40 NCS)
 *    3.  busbench /dev/va2000  1048576            VA2000    (Z2 address, CM 0x60 NC via DTT0)
 *    4.  only if 2 is slow: retest with the Piccolo mapping given 0x60 instead of 0x40 before
 *        concluding anything about Zorro III.
 *
 * TIMING: AMIX libc has times() and clock() but NOT gettimeofday, so resolution is one clock
 * tick.  Each measurement therefore repeats until at least MINTICKS have elapsed; do not
 * shorten that.
 *
 * usage: busbench <device> [bytes]      map a device aperture and measure
 *        busbench -r [bytes]            local malloc'd RAM reference
 *
 * K&R C for the AMIX native cc.  cc -o busbench busbench.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/times.h>
#include <sys/mman.h>
#include <errno.h>

#define DFLTSZ   1048576L        /* 1 MB -- safely inside a 2 MB Piccolo VRAM */
#define MINTICKS 300L            /* ~3 s at HZ=100; beats one-tick resolution */

long hz;

/* ISSUE-34a: the 68060 does not implement 64-bit-result muls.l/divs.l, and gcc emits exactly
 * that for division by a CONSTANT (magic-number reciprocal multiply).  A benchmark that dies
 * on the 060 is useless for the CPU we will most want it on, so every divisor here is a
 * volatile global: that forces a real 32-bit divs.l, which the 060 DOES implement.
 * AND: the C `%` operator is worse than division.  On m68k gcc emits the divide form that
 * returns BOTH quotient and remainder (objdump prints it `divsl` with the size bit set, versus
 * `divsll` for the plain 32-bit form), and that is the variant the 060 does not implement.  So
 * there is no `%` anywhere in this file -- remainders are computed as x - (x/d)*d.
 * Verified: 0 sixty-four-bit forms in the cross-compiled binary.  Do not turn these back into
 * literals and do not reintroduce `%`. */
static volatile long D100 = 100L;
static volatile long D1024 = 1024L;

long
ticks()
{
	struct tms t;

	return ((long) times(&t));
}

/* HZ: prefer sysconf, fall back to 100.  Printed so a wrong value is visible, not silent. */
long
gethz()
{
	long h;

	h = -1L;
#ifdef _SC_CLK_TCK
	h = sysconf(_SC_CLK_TCK);
#endif
	if (h <= 0L || h > 10000L)
		h = 100L;
	return (h);
}

void
report(what, bytes, dt)
char *what;
long bytes, dt;
{
	long kbps, secs100, whole, frac, mbps, mfrac;

	if (dt <= 0L)
		dt = 1L;
	/* integer arithmetic only -- no FP, so no dependency on FPSP for a benchmark */
	secs100 = (dt * D100) / hz;                   /* hundredths of a second */
	if (secs100 <= 0L)
		secs100 = 1L;
	kbps = (bytes / D1024) * D100 / secs100;      /* KB per second */
	whole = secs100 / D100;
	frac  = secs100 - whole * D100;               /* no `%` -- see the note above */
	mbps  = kbps / D1024;
	mfrac = ((kbps - mbps * D1024) * D100) / D1024;
	printf("BUSBENCH %-14s %8ld KB moved  %5ld ticks (%ld.%02ld s)  %7ld KB/s (%ld.%02ld MB/s)\n",
	       what, bytes / D1024, dt, whole, frac, kbps, mbps, mfrac);
}

/* ---- 32-bit writes ---------------------------------------------------- */
long
wlong(p, sz)
char *p;
long sz;
{
	long *q, *end, t0, dt, total, i, n;

	n = sz / 4L;
	total = 0L;
	t0 = ticks();
	do {
		q = (long *) p;
		end = q + n;
		i = 0L;
		while (q < end) {
			*q++ = i;
			*q++ = i;
			*q++ = i;
			*q++ = i;         /* unrolled x4: loop overhead off the measurement */
			i++;
		}
		total += sz;
		dt = ticks() - t0;
	} while (dt < MINTICKS);
	report("write32", total, dt);
	return (dt);
}

/* ---- 16-bit writes --------------------------------------------------- */
long
wword(p, sz)
char *p;
long sz;
{
	short *q, *end;
	long t0, dt, total, n;
	short v;

	n = sz / 2L;
	total = 0L;
	v = 0x5a5a;
	t0 = ticks();
	do {
		q = (short *) p;
		end = q + n;
		while (q < end) {
			*q++ = v;
			*q++ = v;
			*q++ = v;
			*q++ = v;
		}
		total += sz;
		dt = ticks() - t0;
	} while (dt < MINTICKS);
	report("write16", total, dt);
	return (dt);
}

/* ---- 32-bit reads ---------------------------------------------------- */
long sink;                       /* global so the reads cannot be optimised away */

long
rlong(p, sz)
char *p;
long sz;
{
	long *q, *end, t0, dt, total, n, acc;

	n = sz / 4L;
	total = 0L;
	acc = 0L;
	t0 = ticks();
	do {
		q = (long *) p;
		end = q + n;
		while (q < end) {
			acc += *q++;
			acc += *q++;
			acc += *q++;
			acc += *q++;
		}
		total += sz;
		dt = ticks() - t0;
	} while (dt < MINTICKS);
	sink = acc;
	report("read32", total, dt);
	return (dt);
}

main(argc, argv)
int argc;
char **argv;
{
	char *p;
	long sz;
	int fd, isram;

	hz = gethz();
	isram = 0;
	sz = DFLTSZ;
	fd = -1;

	if (argc < 2) {
		printf("usage: busbench <device> [bytes] | busbench -r [bytes]\n");
		exit(2);
	}
	if (argv[1][0] == '-' && argv[1][1] == 'r') {
		isram = 1;
		if (argc > 2)
			sz = atol(argv[2]);
	} else {
		if (argc > 2)
			sz = atol(argv[2]);
	}
	if (sz < 65536L)
		sz = 65536L;

	printf("BUSBENCH hz=%ld size=%ld bytes target=%s\n",
	       hz, sz, isram ? "local RAM (cached, reference ceiling)" : argv[1]);

	if (isram) {
		p = (char *) malloc((unsigned) sz);
		if (p == (char *) 0) {
			printf("BUSBENCH ERR malloc %ld failed\n", sz);
			exit(1);
		}
	} else {
		fd = open(argv[1], O_RDWR);
		if (fd < 0) {
			printf("BUSBENCH ERR open %s failed (errno=%d)\n", argv[1], errno);
			printf("BUSBENCH   run svgaprobe/va2000probe first -- the node may need mknod\n");
			exit(1);
		}
		p = (char *) mmap((caddr_t) 0, (size_t) sz, PROT_READ | PROT_WRITE,
				  MAP_SHARED, fd, (off_t) 0);
		if (p == (char *) -1) {
			printf("BUSBENCH ERR mmap %s (%ld bytes) failed (errno=%d)\n",
			       argv[1], sz, errno);
			printf("BUSBENCH   a device that maps less than requested will fail here;\n");
			printf("BUSBENCH   try a smaller size (the Piccolo has ~2 MB of real VRAM)\n");
			(void) close(fd);
			exit(1);
		}
		printf("BUSBENCH mapped at %lx\n", (long) p);
	}

	(void) wlong(p, sz);
	(void) wword(p, sz);
	(void) rlong(p, sz);

	printf("BUSBENCH-DONE %s\n", isram ? "-r" : argv[1]);
	printf("BUSBENCH note: compare against the -r reference before drawing any conclusion,\n");
	printf("BUSBENCH       and remember 0x40000000 maps CM=0x40 NCS while 0x00200000 is\n");
	printf("BUSBENCH       DTT0 CM=0x60 NC -- the Z3 target is handicapped, not the bus.\n");

	if (!isram) {
		(void) munmap(p, (size_t) sz);
		(void) close(fd);
	}
	exit(0);
}
