/* kvpcost.c -- what the kvp vector probe costs, measured on the path it is actually on.
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * WHY NOT DHRYSTONE.  The standing question is whether `kvp_on` should ship enabled, and the
 * standing plan for answering it was a Dhrystone A/B across kvp_on 1 -> 0 -> 1 in one boot.
 * Dhrystone is a userland compute loop: it makes almost no system calls and takes almost no
 * page faults, so it exercises the probe a handful of times over a run that lasts seconds.
 * Whatever it reports is the machine's noise floor, and reporting that as "no measurable cost"
 * would be an instrument failure dressed as a result.
 *
 * WHERE THE PROBE ACTUALLY IS.  `src/kvecprobe040.s` wraps `nullvect` and describes it as the
 * catch-all that turns an unhandled exception into SIGSYS.  The per-vector histogram it keeps
 * says something else: on 68040-260830-06, after 40 minutes of uptime and a full battery, the
 * only two non-empty buckets were
 *      kvp_vec[2]  =  62 432      vector 2  = access fault (page fault)
 *      kvp_vec[32] = 124 400      vector 32 = TRAP #0      (system call)
 * and every other bucket was zero.  So the probe runs on the system-call path and the
 * page-fault path -- roughly twenty instructions on each -- and nowhere else.
 *
 * WHAT THIS MEASURES.  A tight loop of one cheap system call, timed with times(2).  Run it
 * with kvp_on = 1 and again with kvp_on = 0 (`kpoke <kvp_on-addr> 1 0`) inside one boot, and
 * the difference in system time per call is the probe's cost per system call.  Read
 * kvp_vec[32] before and after: it must rise by about `n` in the kvp_on = 1 pass and not at
 * all in the kvp_on = 0 pass.  That is the check that the loop is exercising what it claims
 * to -- if the C library ever satisfies the call without trapping, the counter says so
 * instead of the timing quietly measuring nothing.
 *
 * usage: kvpcost [iterations]        default 200000
 * Compile on AMIX:  cc -o kvpcost kvpcost.c
 */

#include <sys/types.h>
#include <sys/times.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

main(argc, argv)
int argc;
char **argv;
{
	long i, n;
	long w0, w1;
	struct tms t0, t1;
	int fd;

	setbuf(stdout, (char *)0);

	n = 200000L;
	if (argc > 1 && sscanf(argv[1], "%ld", &n) != 1)
		n = 200000L;

	/* lseek on an open descriptor is the cheapest call that is unambiguously a call:
	 * it cannot be satisfied from a cached value the way getpid() can be, and it
	 * touches no data.  /dev/null is seekable and has no side effects. */
	fd = open("/dev/null", O_RDONLY, 0);
	if (fd < 0) {
		printf("KVPCOST ABORT: /dev/null open errno=%d\n", errno);
		exit(2);
	}

	w0 = times(&t0);
	for (i = 0; i < n; i++)
		(void)lseek(fd, 0L, 1);
	w1 = times(&t1);

	close(fd);

	printf("KVPCOST n=%ld wall=%ld user=%ld sys=%ld ticks\n",
		n, w1 - w0,
		(long)(t1.tms_utime - t0.tms_utime),
		(long)(t1.tms_stime - t0.tms_stime));
	printf("KVPCOST-DONE\n");
	exit(0);
}
