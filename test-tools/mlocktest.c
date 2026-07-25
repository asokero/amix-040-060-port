/* mlocktest.c -- ISSUE-28 acceptance test: memcntl(2) / plock(2) page geometry.
 *
 * memcntl's mlock bitmap is FILLED by as_ctl / segvn_lockop, both of which were
 * converted to 4 KiB long ago (patch_modelb.py:302-307, 333-337).  memcntl itself
 * still SIZED that bitmap and mem_unlock still WALKED it with 2 KiB arithmetic --
 * the same producer/consumer asymmetry as ISSUE-27.
 *
 * T1 is the discriminating test and needs no privilege beyond root:
 *
 *   memcntl(base + 2048, 4096, MC_LOCK, ...) where base is 4096-aligned
 *     4 KiB kernel (fixed):    addr & PAGEOFFSET(4095) == 2048 != 0  ->  EINVAL
 *     2 KiB kernel (pre-fix):  addr & PAGEOFFSET(2047) == 0          ->  gate passes,
 *                              as_ctl then masks the address down to a 4 KiB boundary
 *                              and locks a DIFFERENT range than the caller asked for
 *   So: pre-fix returns success, post-fix returns EINVAL.  Opposite outcomes.
 *
 * T2/T3 are round-trip + accounting-leak checks: if the 2 KiB btoc/ctob math made
 * mem_unlock release the wrong range, pages_pp_locked/availrmem drift and repeated
 * lock/unlock cycles eventually start failing with EAGAIN/ENOMEM.
 *
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o mlocktest mlocktest.c
 * Run as root (MC_LOCK/MC_LOCKAS require suser).
 */

#include <sys/types.h>
#include <errno.h>
#include <stdio.h>

/* sys/mman.h + sys/lock.h values; defined here so the test does not depend on which
 * userland headers this AMIX install shipped. */
#define MC_SYNC		1
#define MC_LOCK		2
#define MC_UNLOCK	3
#define MC_LOCKAS	5
#define MC_UNLOCKAS	6
#define MCL_CURRENT	0x1

#define UNLOCK		0
#define PROCLOCK	1

#define PGSZ	4096
#define ASZ	(4 * PGSZ)

char arena[ASZ];

char *pgalign(a)
char *a;
{
	unsigned long v;

	v = ((unsigned long)a + PGSZ - 1) & ~((unsigned long)PGSZ - 1);
	return (char *)v;
}

main(argc, argv)
int argc;
char **argv;
{
	char *base;
	int r, i, fails, skipped;

	fails = 0;
	skipped = 0;
	setbuf(stdout, (char *)0);
	base = pgalign(arena);
	printf("mlocktest: arena=%lx base=%lx (page-aligned)\n",
		(unsigned long)arena, (unsigned long)base);

	/* touch it so the pages are resident before we ask to lock them */
	for (i = 0; i < 2 * PGSZ; i++)
		base[i] = (char)i;

	/* ---- T1: THE DISCRIMINATOR -- half-page-aligned address must be EINVAL ---- */
	errno = 0;
	r = memcntl(base + 2048, (unsigned)PGSZ, MC_LOCK, (char *)0, 0, 0);
	if (r == -1 && errno == EINVAL) {
		printf("T1 PASS: memcntl(base+2048) -> EINVAL (4 KiB PAGEOFFSET gate)\n");
	} else {
		printf("T1 FAIL: memcntl(base+2048) -> r=%d errno=%d (expected -1/EINVAL; a\n",
			r, errno);
		printf("         2 KiB gate lets this through and locks the wrong range)\n");
		fails++;
		/* if it was accepted, undo it so later tests start clean */
		if (r == 0)
			(void)memcntl(base + 2048, (unsigned)PGSZ, MC_UNLOCK,
				(char *)0, 0, 0);
	}

	/* ---- T2: aligned MC_LOCK / MC_UNLOCK round trip ---- */
	errno = 0;
	r = memcntl(base, (unsigned)(2 * PGSZ), MC_LOCK, (char *)0, 0, 0);
	if (r != 0) {
		printf("T2 FAIL: MC_LOCK r=%d errno=%d\n", r, errno);
		fails++;
	} else {
		errno = 0;
		r = memcntl(base, (unsigned)(2 * PGSZ), MC_UNLOCK, (char *)0, 0, 0);
		if (r != 0) {
			printf("T2 FAIL: MC_UNLOCK r=%d errno=%d\n", r, errno);
			fails++;
		} else
			printf("T2 PASS: MC_LOCK + MC_UNLOCK round trip on 2 pages\n");
	}

	/* ---- T3: 20 lock/unlock cycles -- accounting leak detector ---- */
	r = 0;
	for (i = 0; i < 20; i++) {
		errno = 0;
		if (memcntl(base, (unsigned)(2 * PGSZ), MC_LOCK,
				(char *)0, 0, 0) != 0) {
			printf("T3 FAIL: MC_LOCK failed on cycle %d errno=%d "
				"(accounting leak?)\n", i, errno);
			r = -1;
			break;
		}
		if (memcntl(base, (unsigned)(2 * PGSZ), MC_UNLOCK,
				(char *)0, 0, 0) != 0) {
			printf("T3 FAIL: MC_UNLOCK failed on cycle %d errno=%d\n",
				i, errno);
			r = -1;
			break;
		}
	}
	if (r == 0)
		printf("T3 PASS: 20 MC_LOCK/MC_UNLOCK cycles, no accounting drift\n");
	else
		fails++;

	/* ---- T4: plock(PROCLOCK)/plock(UNLOCK) -- the MC_LOCKAS path ---- */
	errno = 0;
	r = plock(PROCLOCK);
	if (r == -1 && (errno == ENOSYS || errno == EINVAL)) {
		printf("T4 SKIP: plock unavailable (errno=%d)\n", errno);
		skipped++;
	} else if (r != 0) {
		printf("T4 FAIL: plock(PROCLOCK) r=%d errno=%d\n", r, errno);
		fails++;
	} else {
		errno = 0;
		r = plock(UNLOCK);
		if (r != 0) {
			printf("T4 FAIL: plock(UNLOCK) r=%d errno=%d\n", r, errno);
			fails++;
		} else
			printf("T4 PASS: plock(PROCLOCK) + plock(UNLOCK)\n");
	}

	/* ---- T5: 10 plock cycles -- ublock/ubunlock availrmem accounting ---- */
	if (skipped == 0) {
		r = 0;
		for (i = 0; i < 10; i++) {
			errno = 0;
			if (plock(PROCLOCK) != 0) {
				printf("T5 FAIL: plock(PROCLOCK) cycle %d errno=%d\n",
					i, errno);
				r = -1;
				break;
			}
			if (plock(UNLOCK) != 0) {
				printf("T5 FAIL: plock(UNLOCK) cycle %d errno=%d\n",
					i, errno);
				r = -1;
				break;
			}
		}
		if (r == 0)
			printf("T5 PASS: 10 plock lock/unlock cycles\n");
		else
			fails++;
	} else
		printf("T5 SKIP: plock unavailable\n");

	printf("MLOCKTEST fails=%d skipped=%d\n", fails, skipped);
	printf(fails ? "MLOCKTEST-RESULT FAIL\n" : "MLOCKTEST-RESULT PASS\n");
	exit(fails ? 1 : 0);
}
