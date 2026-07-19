/* mincoretst.c - mincore(2) Model-B acceptance (K&R, AMIX cc).
 * 1) vector length: 8 touched pages -> EXACTLY 8 vec bytes copied out
 *    (old 2K btoc copied 16: tail sentinel overwritten -> FAIL).
 * 2) alignment gate: 2K-aligned (not 4K) addr -> EINVAL under Model B
 *    (old kernel accepted it).
 * Prints MINCORE PASS / FAIL lines.
 */
#include <stdio.h>
#include <errno.h>

#define PG 4096
#define NPG 8

extern char *sbrk();
extern int mincore();

char vec[64];

main()
{
	char *raw;
	char *base;
	int i;
	int rc;
	int changed;
	int tailok;
	int fail;

	fail = 0;
	raw = sbrk((NPG + 2) * PG);
	if ((int)raw == -1) {
		printf("MINCORE FAIL sbrk\n");
		exit(1);
	}
	base = (char *)(((unsigned long)raw + PG - 1) & ~(PG - 1));
	for (i = 0; i < NPG * PG; i += 512)
		base[i] = 1;

	for (i = 0; i < 64; i++)
		vec[i] = (char)0xAA;
	rc = mincore(base, NPG * PG, vec);
	changed = 0;
	tailok = 1;
	for (i = 0; i < NPG; i++)
		if (vec[i] != (char)0xAA)
			changed++;
	for (i = NPG; i < 64; i++)
		if (vec[i] != (char)0xAA)
			tailok = 0;
	printf("MINCORE VEC rc %d changed %d tail %s\n",
	    rc, changed, tailok ? "intact" : "OVERRUN");
	if (rc != 0 || changed != NPG || !tailok) {
		printf("MINCORE FAIL vector\n");
		fail++;
	}

	rc = mincore(base + 2048, PG, vec);
	printf("MINCORE ALIGN2K rc %d errno %d\n", rc, rc ? errno : 0);
	if (rc != -1 || errno != EINVAL) {
		printf("MINCORE FAIL align2k accepted\n");
		fail++;
	}

	errno = 0;
	rc = mincore(base + 1, PG, vec);
	if (rc != -1 || errno != EINVAL) {
		printf("MINCORE FAIL align1 accepted\n");
		fail++;
	}

	if (fail == 0)
		printf("MINCORE PASS\n");
	exit(fail != 0);
}
