/* isp61xf.c -- page-crossing instruction fetch, vector-61 unit (F2, 2026-08-06).
 *
 * Spec: amix-kernel-analysis/vm-map/ISP-VECTOR61-UNIT-SPEC.md, "page-crossing fetch".
 * The multiply is placed at page offset 0xffc so its 32-bit immediate lives in the
 * FOLLOWING page -- see isp61xf_asm.s for how the placement is forced and why it
 * matters (the handler uses a single 8-byte copyin).
 *
 * The arithmetic is deliberately case U1 from isp61test, whose product and CCR are
 * already pre-registered and confirmed on both CPUs:
 *     0xffffffff * 2 = 00000001:fffffffe, CCR 0x10 (X preserved, NZVC clear)
 * so any difference here is about the FETCH, not about the arithmetic.
 *
 * EXPECTED, real 68060:  PASS, isp61_entry_n +1, ok_n +1, mulu_n +1,
 *                        isp61_ifetch_fail_n +0 (the crossing copyin succeeded)
 * EXPECTED, 68040:       PASS by hardware execution, every isp61_* delta ZERO.
 *
 * If the multiply did not land at offset 0xffc the program prints SKIP, not PASS.
 *
 * usage: isp61xf
 */

#include <stdio.h>

static unsigned long canary;

extern void isp61_xf();
extern unsigned long isp61_xf_addr();

main(argc, argv)
int argc;
char **argv;
{
	unsigned long r[3], addr;
	int fails;

	addr = isp61_xf_addr();
	printf("isp61xf: multiply at 0x%08lx (page offset 0x%03lx)\n",
	       addr, addr & 0xfffL);

	if ((addr & 0xfffL) != 0xffcL) {
		printf("  the immediate does NOT cross a page boundary here\n");
		printf("ISP61XF-RESULT SKIP (placement not honoured: nothing was tested)\n");
		exit(2);
	}
	printf("  opword+ext end this page, the immediate starts the next one\n");
	printf("  060 expects entry_n +1, ok_n +1, mulu_n +1, ifetch_fail_n +0\n");
	fflush(stdout);

	isp61_xf(r, &canary);

	fails = 0;
	printf("Dh:Dl = %08lx:%08lx  ccr = %02lx  canary = %lu",
	       r[0], r[1], r[2] & 0xffL, canary);
	if (r[0] != 0x00000001L || r[1] != 0xfffffffeL) {
		printf("   FAIL product (want 00000001:fffffffe)");
		fails++;
	} else if ((r[2] & 0xffL) != 0x10L) {
		printf("   FAIL ccr (want 10)");
		fails++;
	} else if (canary != 1L) {
		printf("   FAIL canary (want 1: 0 = no resume, >1 = retry loop)");
		fails++;
	} else {
		printf("   OK");
	}
	printf("\n");

	printf("ISP61XF-RESULT %s\n", fails == 0 ? "PASS" : "FAIL");
	exit(fails == 0 ? 0 : 1);
}
