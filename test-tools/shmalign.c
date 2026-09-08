/* shmalign.c -- does shmat accept an attach address the page table cannot use?
 *
 * ISSUE-62's hunt turned up a SECOND 2 KiB survivor, in shmat rather than shmget,
 * and it is about the ATTACH ADDRESS rather than the segment size:
 *
 *     5538a:  andiw #-2048,%fp@(-34)   SHM_RND: round the address down to 2048
 *     553a0:  andil #2047,%d0          otherwise: not 2048-aligned -> EINVAL
 *     553a6:  bnew  553e0
 *
 * That constant is SHMLBA, and on the 2 KiB kernel it equalled the page size.  On a
 * 4 KiB kernel it no longer does, so both paths can hand as_map an address that is
 * 2 KiB aligned and NOT page aligned: SHM_RND rounds to the wrong multiple, and the
 * check accepts what it should reject.
 *
 * WHETHER THAT IS A DEFECT IS THE QUESTION, not the premise.  The kernel may round
 * it again downstream, or refuse it, in which case the constant is cosmetic.  This
 * asks, and it reports what happened rather than asserting what should have:
 *
 *   attach at a 4 KiB-aligned address   -- the control; must succeed
 *   attach at that address + 2048       -- 2 KiB aligned, NOT page aligned
 *   the same with SHM_RND set           -- the kernel rounds, to 2048 today
 *
 * A panic is a possible outcome and is the reason this is a separate program run
 * after everything else.  If it returns instead, the address it reports back is the
 * finding: an attached address that is not page aligned means the acceptance is real.
 *
 * K&R C for the AMIX SVR4 native cc.  cc -o shmalign shmalign.c
 */
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <errno.h>
#include <stdio.h>

#define SEGSZ 8192

main(argc, argv)
int argc;
char **argv;
{
	char *base, *at;
	int id;

	id = shmget(IPC_PRIVATE, SEGSZ, IPC_CREAT | 0600);
	if (id < 0) {
		printf("SHMALIGN ERR shmget failed errno=%d\n", errno);
		exit(1);
	}

	/* control: let the kernel choose, and learn a usable region */
	base = (char *) shmat(id, (char *) 0, 0);
	if (base == (char *) -1) {
		printf("SHMALIGN ERR control shmat failed errno=%d\n", errno);
		exit(1);
	}
	printf("SHMALIGN CONTROL at=%lx pagealigned=%d\n",
	       (unsigned long) base, ((unsigned long) base & 0xfff) == 0);
	fflush(stdout);
	shmdt(base);

	/* the question: 2 KiB aligned, deliberately NOT 4 KiB aligned */
	at = base + 2048;
	printf("SHMALIGN TRY  addr=%lx (addr&2047=%lu addr&4095=%lu)\n",
	       (unsigned long) at, (unsigned long) at & 2047UL,
	       (unsigned long) at & 4095UL);
	fflush(stdout);

	base = (char *) shmat(id, at, 0);
	if (base == (char *) -1) {
		printf("SHMALIGN REJECTED errno=%d  (the check did its job)\n", errno);
	} else {
		printf("SHMALIGN ACCEPTED at=%lx pagealigned=%d\n",
		       (unsigned long) base, ((unsigned long) base & 0xfff) == 0);
		fflush(stdout);
		*base = 0x5a;			/* touch it: a bad mapping shows here */
		printf("SHMALIGN TOUCHED ok, read back %x\n", (unsigned int) *base & 0xff);
		shmdt(base);
	}
	fflush(stdout);

	/* SHM_RND: the contract says round DOWN to the boundary, not up and not
	 * unconditionally (amix-kernel-analysis ISSUE66-SHMLBA-PAGESIZE-ABI-CONTRACT.md).
	 * So the same misaligned address must be ACCEPTED here and land page aligned,
	 * at the address below it -- which is a different outcome from the plain attach
	 * above, and the reason both are probed. */
	printf("SHMALIGN RND  addr=%lx with SHM_RND\n", (unsigned long) at);
	fflush(stdout);

	base = (char *) shmat(id, at, SHM_RND);
	if (base == (char *) -1) {
		printf("SHMALIGN RND-REJECTED errno=%d\n", errno);
	} else {
		printf("SHMALIGN RND-ACCEPTED at=%lx pagealigned=%d roundeddown=%d\n",
		       (unsigned long) base, ((unsigned long) base & 0xfff) == 0,
		       (unsigned long) base <= (unsigned long) at);
		fflush(stdout);
		*base = 0x5a;
		printf("SHMALIGN RND-TOUCHED ok, read back %x\n",
		       (unsigned int) *base & 0xff);
		shmdt(base);
	}
	fflush(stdout);

	shmctl(id, IPC_RMID, (struct shmid_ds *) 0);
	printf("SHMALIGN-DONE\n");
	exit(0);
}
