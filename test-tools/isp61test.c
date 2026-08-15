/* isp61test.c -- pre-registered acceptance test for the 68060 vector-61 multiply unit.
 *
 * Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md §Q6.  Implementation:
 * amix-040-060-port/src/isp61_060.s.  The five cases and their expected products and
 * CCR values come from that spec and were recomputed independently before this was written.
 *
 * WHY RAW ENCODINGS.  Every instruction is emitted as `.word 0x4c3c,<ext>` + `.long <imm>`
 * so no assembler or compiler decision can change the requested form.  The whole point is
 * to present the exact encoding the 68060 does not implement.
 *
 * WHY THE CCR PRECONDITION.  X is preset to 1 before each multiply and read back after.
 * A handler that rebuilds the whole CCR instead of preserving X would show 0x00/0x08
 * instead of 0x10/0x18, and nothing else in the suite would catch that.
 *
 * WHY THE CANARY.  It is incremented by the instruction immediately following the
 * multiply.  It must read exactly 1 per case:
 *     0  -> the handler did not resume (or the process died)
 *     >1 -> the handler restarted the instruction, i.e. a retry loop
 * and if the handler advanced PC by 4 instead of 8 the machine would execute the immediate
 * as opcodes, which the canary would also expose (it would not reach 1 cleanly).
 *
 * CASE S2 IS THE LOAD-BEARING ONE: signed 0x80000000 * -1 = 0x00000000:0x80000000.  Its N
 * bit must be CLEAR, because N comes from bit 63 of the product, not bit 31.  A handler that
 * takes N from the low longword passes every other case and fails this one.
 *
 * EXPECTED, real 68060, one clean run (all five cases):
 *     isp61_entry_n        +5
 *     isp61_ok_n           +5
 *     isp61_mulu_n         +3
 *     isp61_muls_n         +2
 *     every failure counter +0
 * On a 68040 all five cases must PASS by hardware execution with every isp61_* delta ZERO --
 * the vector is installed but ordinary 040 execution never enters it.  That is the strongest
 * check that the cputype gate holds.
 *
 * Cross-compiled: raw encodings need the gcc inline assembler, and the guest's gcc is dead on
 * the 060 anyway (vector 61 -- that is what this unit fixes).
 *
 * usage: isp61test
 */

#include <stdio.h>

static unsigned long canary[5];

/* The five multiplies live in isp61test_asm.s: gcc 2.7.2.3's inline assembler runs a
 * template with operands through its opcode translator and mangles the mnemonics, so the
 * raw encodings are assembled verbatim from a standalone .s instead.
 *   fn(out, canary):  out[0] = Dh, out[1] = Dl, out[2] = CCR  */
extern void isp61_u1();
extern void isp61_u2();
extern void isp61_uz();
extern void isp61_s1();
extern void isp61_s2();

static char *names[5] = { "U1", "U2", "UZ", "S1", "S2" };
static unsigned long exp_hi[5] = { 0x00000001L, 0xfffffffeL, 0x00000000L, 0xffffffffL, 0x00000000L };
static unsigned long exp_lo[5] = { 0xfffffffeL, 0x00000001L, 0x00000000L, 0xffffffebL, 0x80000000L };
static unsigned long exp_cc[5] = { 0x10L,       0x18L,       0x14L,       0x18L,       0x10L };

main(argc, argv)
int argc;
char **argv;
{
	unsigned long r[5][3];
	int i, fails;

	printf("isp61test: five raw 64-bit immediate multiplies (vector 61 on the 68060)\n");
	printf("  060 expects isp61_entry_n +5, isp61_ok_n +5, mulu +3, muls +2, failures +0\n");
	printf("  040 expects every isp61_* delta to be ZERO (hardware executes them)\n\n");
	fflush(stdout);

	isp61_u1(r[0], &canary[0]);
	isp61_u2(r[1], &canary[1]);
	isp61_uz(r[2], &canary[2]);
	isp61_s1(r[3], &canary[3]);
	isp61_s2(r[4], &canary[4]);

	fails = 0;
	for (i = 0; i < 5; i++) {
		printf("%s  Dh:Dl = %08lx:%08lx  ccr = %02lx  canary = %lu",
		       names[i], r[i][0], r[i][1], r[i][2] & 0xff, canary[i]);
		if (r[i][0] != exp_hi[i] || r[i][1] != exp_lo[i]) {
			printf("   FAIL product (want %08lx:%08lx)", exp_hi[i], exp_lo[i]);
			fails++;
		} else if ((r[i][2] & 0xff) != exp_cc[i]) {
			printf("   FAIL ccr (want %02lx)", exp_cc[i]);
			fails++;
		} else if (canary[i] != 1L) {
			printf("   FAIL canary (want 1: 0 = no resume, >1 = retry loop)");
			fails++;
		} else {
			printf("   OK");
		}
		printf("\n");
	}

	printf("\nISP61TEST fails=%d\n", fails);
	printf("ISP61TEST-RESULT %s\n", fails == 0 ? "PASS" : "FAIL");
	exit(fails == 0 ? 0 : 1);
}
