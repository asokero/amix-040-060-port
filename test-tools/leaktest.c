/* leaktest.c -- ISSUE-40: turn "about a page per process" into a number
 * (2026-08-01).
 *
 * WHY THIS EXISTS.  The bisect showed the availrmem loss lives in the
 * fork/exec half of the load, not the file-IO half (-985 pages vs -50, twice
 * each).  Dividing that by a process count is the obvious next step -- but the
 * shell load's process count is a GUESS: `k=\`expr $k + 1\`` forks and execs
 * too, so "80 iterations" is 160 processes, or 161, depending on how the shell
 * implements the loop.  A ratio computed from a guessed denominator is not a
 * measurement.
 *
 * This program's denominator is exact: N is on the command line, and one
 * iteration is exactly one fork (mode 0) or one fork plus one exec (mode 1).
 *
 * SEPARATING FORK FROM EXEC is the point of the two modes.  If mode 0 leaks and
 * mode 1 leaks the same, the loss is in process creation/teardown; if only
 * mode 1 leaks, it is in exec's address-space replacement.  Those are different
 * code paths and the answer says which one to read.
 *
 * The exec target is THIS BINARY with a single argument "x", so there is no
 * dependency on which small programs the root disk happens to carry, and the
 * child's work is one exit(0).
 *
 * Usage, with the counters read either side:
 *     kpeek <availrmem addr> 1
 *     ./leaktest 500 0        # 500 fork + exit
 *     kpeek <availrmem addr> 1
 *     ./leaktest 500 1        # 500 fork + exec + exit
 *     kpeek <availrmem addr> 1
 *
 * Follow the pointer first: availrmem's runtime address is i39_availrmem_p's
 * CONTENT, not a computable .data offset (it is a COMMON symbol).
 *
 * K&R C for the AMIX SVR4 native cc.  Compile on AMIX:  cc -o leaktest leaktest.c
 */

#include <sys/types.h>
#include <stdio.h>

main(argc, argv)
int argc;
char **argv;
{
	int n, mode, i, st;
	int pid;
	int failed;

	/* The exec target: one argument "x" and nothing else to do. */
	if (argc == 2 && argv[1][0] == 'x' && argv[1][1] == '\0')
		exit(0);

	if (argc < 3) {
		fprintf(stderr, "usage: leaktest <count> <0=fork|1=fork+exec>\n");
		exit(2);
	}
	n = atoi(argv[1]);
	mode = atoi(argv[2]);
	failed = 0;

	for (i = 0; i < n; i++) {
		pid = fork();
		if (pid == 0) {
			if (mode)
				execl(argv[0], argv[0], "x", (char *) 0);
			_exit(0);		/* mode 0, or exec failed */
		}
		if (pid < 0) {
			failed++;
			continue;
		}
		(void) wait(&st);
	}

	printf("LEAKTEST mode=%d requested=%d fork_failures=%d\n", mode, n, failed);
	printf("  -> %d %s completed\n", n - failed,
	       mode ? "fork+exec pairs" : "forks");
	return (0);
}
