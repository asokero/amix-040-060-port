/* fpmin2: same but volatile, as fputest.c has it */
#include <stdio.h>
volatile double a, b, c;
main()
{
	a = 3.0; b = 7.0; c = a + b;
	printf("FPMIN2 %ld (expect 10000)\n", (long)(c * 1000.0));
	exit(0);
}
