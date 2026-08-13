/* fputest060.c - fputest.c made safe to CROSS-COMPILE for the 68060 (2026-08-05).
 *
 * Identical test, one change: `i % 20` is replaced by an explicit counter.
 * Reason, measured on hardware this session: gcc turns division/modulo by a
 * constant into a magic multiply, i.e. `mulsl #1717986919,%d0,%d1` -- the
 * 64-bit-product form (ext word bit10 = 1) that the 68060 does NOT implement.
 * It traps to vector 61 and the kernel's nullvect SIGKILLs the process.  The
 * stock fputest.c cross-compiles to exactly two such instructions.
 *
 * Still cross-compiled, like the original: the guest's own compilers cannot
 * build this file at all.  gcc's cpp dies of vector 61 itself, and the AT&T
 * /usr/ccs/bin/cc chain dies with SIGSYS (vector 11, 060 FPU) on the nsqrt
 * shape -- see docs/060-F0-MEASUREMENT-260805.md.
 *
 * Original header follows.
 *
 * fputest.c - Tier 1 68040 hardware-FPU verification (FPU-TIER1-ENABLE-SPEC.md).
 *
 * Cross-compiled on Linux (m68k-cbm-sysv4-gcc) and the BINARY pushed to the
 * guest -- the AMIX native cc1 itself crashes with SIGSYS on this FPU-less 040
 * kernel (it uses an unimplemented transcendental).  This test uses only
 * 040-implemented FP ops (add/sub/mul/div; Newton sqrt).  Results are converted
 * to scaled longs before any comparison so the old assembler never sees an
 * fcmp-with-immediate.
 *
 *   fputest        -> Test A: basic implemented FP ops + scaled-long results.
 *   fputest fork   -> Test C: parent/child FP accumulators diverge under load.
 */

#include <stdio.h>

volatile double a, b, c;

double nsqrt(x)
double x;
{
	double r;
	int i;
	if (x <= 0.0) return (0.0);
	r = x;
	for (i = 0; i < 40; i++)
		r = (r + x / r) * 0.5;
	return (r);
}

forktest()
{
	int pid, i, status;
	int k;					/* i % 20 without the magic multiply */
	double acc;

	pid = fork();
	if (pid == 0) {
		acc = 1.0;
		k = 0;
		for (i = 0; i < 200000; i++) {   /* churn under scheduler pressure */
			acc = acc * 1.5;
			if (k == 0) acc = 1.0;          /* reset by count, no FP compare */
			if (++k == 20) k = 0;
			if ((i & 1023) == 0) getpid();
		}
		acc = 1.0;
		for (i = 0; i < 12; i++) acc = acc * 1.5;    /* 1.5^12 = 129.746 */
		printf("FPUTEST fork CHILD  1.5^12*1000 = %ld  (expect 129746)\n",
		    (long)(acc * 1000.0));
		exit(0);
	}
	acc = 1.0;
	k = 0;
	for (i = 0; i < 200000; i++) {
		acc = acc / 1.25;
		if (k == 0) acc = 1.0;
		if (++k == 20) k = 0;
		if ((i & 1023) == 0) getppid();
	}
	acc = 1.0;
	for (i = 0; i < 12; i++) acc = acc / 1.25;         /* 1.25^-12 = 0.0687 */
	printf("FPUTEST fork PARENT 1.25^-12*100000 = %ld  (expect 6871)\n",
	    (long)(acc * 100000.0));
	wait(&status);
}

main(argc, argv)
int argc;
char **argv;
{
	long add, sub, mul, dvv, sq, thd;

	if (argc > 1 && strcmp(argv[1], "fork") == 0) {
		forktest();
		exit(0);
	}

	a = 3.0; b = 7.0;
	c = a + b;    add = (long)(c * 1000.0);   /* 10000 */
	c = b - a;    sub = (long)(c * 1000.0);   /* 4000  */
	c = a * b;    mul = (long)(c * 1000.0);   /* 21000 */
	c = 21.0 / a; dvv = (long)(c * 1000.0);   /* 7000  */
	a = 1.0; b = 3.0;
	c = a / b;    thd = (long)(c * 1000000.0);/* 333333 */
	c = nsqrt(2.0); sq = (long)(c * 1000000.0);/* 1414213 */

	printf("FPUTEST add=%ld sub=%ld mul=%ld div=%ld  (expect 10000 4000 21000 7000)\n",
	    add, sub, mul, dvv);
	printf("FPUTEST 1/3=%ld sqrt2=%ld  checksum=%ld (expect 333333 1414213 / 1747546)\n",
	    thd, sq, thd + sq);
	if (add==10000 && sub==4000 && mul==21000 && dvv==7000 && thd+sq==1747546)
		printf("FPUTEST Test A PASS -- 040 hardware FP arithmetic correct\n");
	else
		printf("FPUTEST Test A FAIL\n");
	exit(0);
}
