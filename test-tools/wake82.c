/* wake82.c -- ISSUE-82 controlled wakeup test: an oversize KM_SLEEP request that only a pool
 * retirement (kmem_freepool) can satisfy.
 *   wake82 fill P M   open P pipes, queue M 1000-byte messages in each (big-pool chunks), print
 *                     "FILLED", then wait for SIGUSR1; on it close everything and exit
 *   wake82 touch      mmap 8 MB of /dev/zero privately, print "MAPPED", touch one byte: the first
 *                     fault allocates the 8192-byte anon array with KM_SLEEP; print "WOKE" and the
 *                     seconds slept
 * The arena is hidden between the two steps with kpoke, so only clicks a retired pool returns can
 * satisfy the touch.  Newlines are printed with %c,10. */
#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>

#define MAXP 64
#define MSZ 1000
#define MAPSZ 0x800000L

int fds[MAXP][2];
int np;
char buf[MSZ];

void release(s) int s;
{
	int i;

	for (i = 0; i < np; i++) {
		close(fds[i][0]);
		close(fds[i][1]);
	}
	printf("RELEASED %d pipes%c", np, 10);
	fflush(stdout);
	_exit(0);
}

int fill(p, m) int p, m;
{
	int i, j, w = 0;

	if (p > MAXP)
		p = MAXP;
	for (i = 0; i < p; i++) {
		if (pipe(fds[i]) < 0) {
			printf("pipe failed at %d%c", i, 10);
			break;
		}
		np++;
		fcntl(fds[i][1], F_SETFL, O_NDELAY);
		for (j = 0; j < m; j++) {
			if (write(fds[i][1], buf, MSZ) != MSZ)
				break;
			w++;
		}
	}
	signal(SIGUSR1, release);
	printf("FILLED %d pipes %d messages pid %d%c", np, w, getpid(), 10);
	fflush(stdout);
	for (;;)
		pause();
}

int touch()
{
	int fd;
	long t0, t1;
	char *a;

	if ((fd = open("/dev/zero", O_RDWR)) < 0) {
		printf("ABORT: /dev/zero%c", 10);
		return 1;
	}
	a = (char *)mmap((caddr_t)0, MAPSZ, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
	if (a == (char *)-1) {
		printf("ABORT: mmap%c", 10);
		return 1;
	}
	printf("MAPPED %08lx pid %d%c", (long)a, getpid(), 10);
	fflush(stdout);
	time(&t0);
	a[0] = 1;
	time(&t1);
	printf("WOKE after %ld s%c", t1 - t0, 10);
	return 0;
}

int main(argc, argv) int argc; char **argv;
{
	if (argc >= 4 && argv[1][0] == 'f')
		return fill(atoi(argv[2]), atoi(argv[3]));
	if (argc >= 2 && argv[1][0] == 't')
		return touch();
	printf("usage: wake82 fill P M | wake82 touch%c", 10);
	return 2;
}
