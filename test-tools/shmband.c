/* shmband.c - does SysV shared memory inherit a 2 KiB anon-map geometry?
 * (2026-08-19)
 *
 * K&R C for the AMIX SVR4 native cc, per AGENTS.md.  Also cross-buildable with
 * m68k-cbm-sysv4-gcc when the target has no compiler (an install miniroot).
 *
 * WHAT THIS DECIDES.  The Model-B 2 KiB -> 4 KiB page conversion moved every
 * anon-map CONSUMER (seg_alloc, as_map, segvn_create, segvn_free) to 4 KiB and
 * left the SysV shm PRODUCER (shmget) computing its page count and its
 * amp->size with the old 11-bit shift.  If that is true of the running kernel,
 * then for a request whose ceil(bytes/2048) is odd, shmget hands segvn_create
 * an anon map whose size is 2048 short of the segment seg_alloc rounded up --
 * and segvn_create's `amp->size >= seg->s_size` check fires
 * CE_PANIC "segvn_create anon_map size".
 *
 * The predicted failing set is a BAND, not a threshold: sizes whose remainder
 * mod 4096 falls in [1, 2048].  So 1..2048 panic, 2049..4096 survive,
 * 4097..6144 panic, 6145..8192 survive, and so on.  Every other size merely
 * over-allocates two anon slots per live page, which is invisible from here.
 *
 * HOW TO READ A RUN.  Each size prints its progress BEFORE the call that can
 * kill the machine, and flushes, so the last line on the console names the size
 * that did it:
 *
 *     SHMBAND size=4096 mod4096=0 id=N segsz=4096 ATTACH... at=... SURVIVE
 *     SHMBAND size=4097 mod4096=1 id=N segsz=4097 ATTACH...        <- panicked here
 *
 * A panic is a REBOOT, so a run covers sizes up to the first fatal one and no
 * further.  Give the survivors first and one candidate last, then restart after
 * it; the argument list is deliberately caller-supplied for that reason.
 *
 *   usage:  shmband <size> [size ...]
 *           shmband -n <size> ...     get + IPC_STAT only, never attach
 *                                     (safe: the panic is on the attach path)
 *
 * The -n mode is the non-destructive half.  It cannot see amp->size -- that is
 * kernel-private -- but it does prove shmget accepted the size and that
 * IPC_STAT reports the ORIGINAL byte count rather than a rounded one, which is
 * the contract a fixed producer must still keep.
 *
 * Compile on AMIX:  cc -o shmband shmband.c
 */

#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <errno.h>
#include <stdio.h>

main(argc, argv)
int argc;
char **argv;
{
	struct shmid_ds ds;
	char *p;
	int i;
	int id;
	int sz;
	int attach;
	int first;

	attach = 1;
	first = 1;
	if (argc > 1 && argv[1][0] == '-' && argv[1][1] == 'n') {
		attach = 0;
		first = 2;
	}
	if (argc <= first) {
		fprintf(stderr, "usage: shmband [-n] <size> [size ...]\n");
		exit(2);
	}

	for (i = first; i < argc; i++) {
		sz = atoi(argv[i]);
		if (sz <= 0) {
			printf("SHMBAND size=%s SKIPPED (not a positive size)\n", argv[i]);
			fflush(stdout);
			continue;
		}
		printf("SHMBAND size=%d mod4096=%d ", sz, sz % 4096);
		fflush(stdout);

		id = shmget(IPC_PRIVATE, sz, 0600 | IPC_CREAT);
		if (id < 0) {
			printf("GET-FAIL errno=%d\n", errno);
			fflush(stdout);
			continue;
		}
		printf("id=%d ", id);
		fflush(stdout);

		if (shmctl(id, IPC_STAT, &ds) == 0)
			printf("segsz=%ld ", (long)ds.shm_segsz);
		else
			printf("STAT-FAIL errno=%d ", errno);
		fflush(stdout);

		if (!attach) {
			shmctl(id, IPC_RMID, (struct shmid_ds *)0);
			printf("NO-ATTACH\n");
			fflush(stdout);
			continue;
		}

		/* Everything above this line is safe.  The attach is the one that
		 * reaches segvn_create, so this is the last thing the console will
		 * show if the geometry is wrong.  Flush before, not after. */
		printf("ATTACH... ");
		fflush(stdout);

		p = (char *)shmat(id, (char *)0, 0);
		if (p == (char *)-1) {
			printf("AT-FAIL errno=%d\n", errno);
			fflush(stdout);
			shmctl(id, IPC_RMID, (struct shmid_ds *)0);
			continue;
		}
		printf("at=%lx ", (unsigned long)p);
		fflush(stdout);

		/* First and last byte: an attach that succeeded on a short anon map
		 * would still fault here, which is worth separating from the panic. */
		p[0] = 'A';
		p[sz - 1] = 'Z';
		/* At sz == 1 both writes land on the SAME byte, so 'A' is legitimately gone
		 * and checking for it fails by construction rather than by defect.  That
		 * false positive was invisible until 2026-09-07, because size 1 has
		 * `1 mod 4096 = 1`, i.e. inside ISSUE-62's band -- it panicked the kernel
		 * before it could ever reach this line. */
		if ((sz > 1 && p[0] != 'A') || p[sz - 1] != 'Z')
			printf("RW-BAD ");
		if (((unsigned long)p & 0xfff) != 0)
			printf("UNALIGNED ");

		shmdt(p);
		shmctl(id, IPC_RMID, (struct shmid_ds *)0);
		printf("SURVIVE\n");
		fflush(stdout);
	}

	printf("SHMBAND-DONE\n");
	fflush(stdout);
	exit(0);
}
