/* bigargv.c - exec_initialstk / extractarg Model-B acceptance (K&R, AMIX cc).
 * Parent execs itself with ~4.5KB of argv strings (ARG_MAX=5120); the child
 * byte-verifies every arg landed intact across the exec stack build.
 * Old 2K rounding bugs would misplace/alias the upper part of the arg pages.
 * Prints "BIGARGV PASS <n> args <bytes> bytes" or FAIL details.
 */
#include <stdio.h>
#include <string.h>

#define NARGS 45
#define ALEN  99            /* +NUL = 100 bytes per arg, 4500 total */

char expect[ALEN + 1];

void
mkarg(i, buf)
int i;
char *buf;
{
	int j;

	buf[0] = 'a' + (i % 26);
	buf[1] = '0' + (i / 10);
	buf[2] = '0' + (i % 10);
	for (j = 3; j < ALEN; j++)
		buf[j] = 'A' + ((i + j) % 26);
	buf[ALEN] = '\0';
}

main(argc, argv)
int argc;
char **argv;
{
	int i;
	int bad;
	long total;
	char *nargv[NARGS + 3];
	static char space[NARGS][ALEN + 1];

	if (argc >= 2 && strcmp(argv[1], "C") == 0) {
		bad = 0;
		total = 0;
		if (argc != NARGS + 2) {
			printf("BIGARGV FAIL argc %d want %d\n",
			    argc, NARGS + 2);
			exit(1);
		}
		for (i = 0; i < NARGS; i++) {
			mkarg(i, expect);
			if (strcmp(argv[i + 2], expect) != 0) {
				printf("BIGARGV FAIL arg %d corrupt\n", i);
				bad++;
			}
			total += strlen(argv[i + 2]) + 1;
		}
		if (bad == 0)
			printf("BIGARGV PASS %d args %ld bytes\n",
			    NARGS, total);
		exit(bad != 0);
	}
	nargv[0] = argv[0];
	nargv[1] = "C";
	for (i = 0; i < NARGS; i++) {
		mkarg(i, space[i]);
		nargv[i + 2] = space[i];
	}
	nargv[NARGS + 2] = (char *)0;
	execv(argv[0], nargv);
	printf("BIGARGV FAIL exec\n");
	exit(1);
}
