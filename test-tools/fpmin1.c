/* fpmin1: plain double arithmetic, no volatile */
#include <stdio.h>
double a, b, c;
main()
{
	a = 3.0; b = 7.0; c = a + b;
	printf("FPMIN1 %ld (expect 10000)\n", (long)(c * 1000.0));
	exit(0);
}
