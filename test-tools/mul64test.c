/* mul64test -- isolate the 68060 unimplemented-integer-instruction path.
 * Division by a constant makes gcc emit muls.l <ea>,Dh:Dl (64-bit result),
 * which the 68040 implements in hardware and the 68060 does NOT.
 * K&R C for the AMIX cc; also cross-compiles.
 */
#include <stdio.h>

long v = 1234567L;

main(argc, argv)
int argc;
char **argv;
{
	long q;

	printf("MUL64 before\n");
	fflush(stdout);
	q = v / 100L;			/* magic-multiply -> muls.l Dh:Dl */
	printf("MUL64 after  q=%ld (expect 12345)\n", q);
	fflush(stdout);
	printf("MUL64-RESULT %s\n", q == 12345L ? "PASS" : "WRONG");
	exit(0);
}
