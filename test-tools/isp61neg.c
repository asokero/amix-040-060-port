/* isp61neg.c -- the negative half of the vector-61 acceptance (F2, 2026-08-06).
 *
 * Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md, "negative test".
 *
 * isp61test.c proves the handler emulates what it claims.  This proves it declines
 * everything else -- which is the half that keeps a partial implementation from
 * silently producing wrong arithmetic.  The instruction is a register-source 64-bit
 * MULU.L (see isp61neg_asm.s for the encoding and why it is legal but unimplemented).
 *
 * EXPECTED, real 68060:
 *     the process is KILLED (signal 9) before printing SURVIVED
 *     isp61_entry_n        +1
 *     isp61_unsupported_n  +1
 *     isp61_ok_n           +0, every other failure counter +0
 *     console: "SIGKILL sent to pid N (.../isp61neg) because of vector 0xF4"
 *
 * EXPECTED, 68040: hardware executes it, prints SURVIVED with 00000001:fffffffe,
 * exits 0, every isp61_* delta ZERO.
 *
 * So "it printed SURVIVED" is a PASS on the 040 and a FAILURE on the 060.  Read the
 * counters either way: a decline that does not increment isp61_unsupported_n would
 * mean the handler declined for the wrong reason (bad frame, non-user, trace).
 *
 * usage: isp61neg
 */

#include <stdio.h>

extern void isp61_neg();

main(argc, argv)
int argc;
char **argv;
{
	unsigned long r[2];

	r[0] = 0xdeadbeefL;
	r[1] = 0xdeadbeefL;

	printf("isp61neg: register-source 64-bit MULU.L (.word 0x4c01,0x0402)\n");
	printf("  060 expects: SIGKILL here, entry_n +1, unsupported_n +1, ok_n +0\n");
	printf("  040 expects: SURVIVED 00000001:fffffffe, every isp61_* delta 0\n");
	printf("about to execute...\n");
	fflush(stdout);

	isp61_neg(r);

	printf("ISP61NEG SURVIVED  Dh:Dl = %08lx:%08lx\n", r[0], r[1]);
	printf("ISP61NEG-RESULT SURVIVED (correct on a 68040, FAILURE on a 68060)\n");
	fflush(stdout);
	exit(0);
}
