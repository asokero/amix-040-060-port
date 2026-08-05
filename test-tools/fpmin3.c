/* fpmin3: double-returning function with a loop -- the nsqrt shape */
#include <stdio.h>
double nsqrt(x)
double x;
{
	double r; int i;
	if (x <= 0.0) return (0.0);
	r = x;
	for (i = 0; i < 40; i++) r = (r + x / r) * 0.5;
	return (r);
}
main()
{
	printf("FPMIN3 %ld (expect 1414213)\n", (long)(nsqrt(2.0) * 1000000.0));
	exit(0);
}
