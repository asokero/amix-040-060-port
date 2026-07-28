/* cofault.c - targeted ISSUE-22 reproducer: copyout into non-resident user pages.
 * 2026-07-28.
 *
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top of block,
 * cast to (char *) where ANSI uses void *).
 *
 * WHY NOT b2repro-copy.sh: that workload reproduces ISSUE-22 roughly once per 40
 * minutes, because most of its work is disk copying and only its verify phase --
 * one process at a time -- does the thing that actually matters.  The measured
 * failure is a fault taken by copyout while filling a user page that is not yet
 * resident:
 *     DBG krnxflt FAILEXIT w=2 va=800C96B0 rw=2 depth=1   (b2verify's malloc'd heap)
 * So this tool does only that, from several processes at once: each child
 * repeatedly mallocs a large buffer and read(2)s a file into it, freeing it again
 * so the next iteration's pages are cold.  Every page of every read is a copyout
 * into a page the process has never touched.
 *
 * It reports EFAULT (errno 14) specifically, with the offset, and retries the read
 * once so a transient failure is distinguishable from a persistent one -- the same
 * discipline b2verify uses, for the same reason: `sum` and friends hide errno.
 *
 * Usage:  cofault <file> [MiB] [children] [seconds]
 *   e.g.  cofault /payload.bin 4 6 300
 * Compile on AMIX:  cc -o cofault cofault.c
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define CHUNK	65536

int child_loop(path, bytes, deadline, id)
char *path;
unsigned long bytes;
long deadline;
int id;
{
	char *buf;
	int fd;
	int n;
	int efaults;
	unsigned long off;
	unsigned long iters;

	efaults = 0;
	iters = 0;
	for (;;) {
		if ((long)time((long *)0) >= deadline)
			break;
		buf = (char *)malloc((unsigned)bytes);
		if (buf == (char *)0) {
			printf("COFAULT child=%d MALLOC-FAILED bytes=%lu\n", id, bytes);
			break;
		}
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			printf("COFAULT child=%d OPEN-FAILED errno=%d\n", id, errno);
			free(buf);
			break;
		}
		off = 0;
		for (;;) {
			n = read(fd, buf + off, CHUNK);
			if (n == 0)
				break;
			if (n < 0) {
				if (errno == EFAULT) {
					efaults++;
					printf("COFAULT child=%d iter=%lu EFAULT off=%lu buf=%lx\n",
					       id, iters, off, (unsigned long)(buf + off));
					fflush(stdout);
					/* transient or persistent?  retry the same read once */
					n = read(fd, buf + off, CHUNK);
					printf("COFAULT child=%d RETRY %s (n=%d errno=%d)\n", id,
					       (n > 0) ? "SUCCEEDED-transient" : "FAILED-persistent",
					       n, errno);
					fflush(stdout);
					if (n <= 0)
						break;
				} else {
					printf("COFAULT child=%d iter=%lu errno=%d off=%lu\n",
					       id, iters, errno, off);
					fflush(stdout);
					break;
				}
			}
			off += n;
			if (off + CHUNK > bytes)
				break;
		}
		close(fd);
		free(buf);
		iters++;
	}
	printf("COFAULT child=%d DONE iters=%lu efaults=%d\n", id, iters, efaults);
	fflush(stdout);
	return (efaults);
}

main(argc, argv)
int argc;
char **argv;
{
	char *path;
	unsigned long bytes;
	int nkids;
	int secs;
	long deadline;
	int i;
	int pid;
	int status;
	int total;

	if (argc < 2) {
		fprintf(stderr, "usage: cofault <file> [MiB] [children] [seconds]\n");
		exit(2);
	}
	path = argv[1];
	bytes = (unsigned long)((argc > 2) ? atoi(argv[2]) : 4) * 1024L * 1024L;
	nkids = (argc > 3) ? atoi(argv[3]) : 6;
	secs = (argc > 4) ? atoi(argv[4]) : 300;
	deadline = (long)time((long *)0) + secs;

	printf("COFAULT START file=%s bytes=%lu children=%d seconds=%d\n",
	       path, bytes, nkids, secs);
	fflush(stdout);

	for (i = 0; i < nkids; i++) {
		pid = fork();
		if (pid == 0)
			exit(child_loop(path, bytes, deadline, i));
		if (pid < 0) {
			printf("COFAULT FORK-FAILED at %d errno=%d\n", i, errno);
			break;
		}
	}

	total = 0;
	for (;;) {
		pid = wait(&status);
		if (pid < 0)
			break;
		total += (status >> 8) & 0xff;
	}
	printf("COFAULT END efaults_total=%d\n", total);
	exit(total ? 1 : 0);
}
