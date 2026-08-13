/* nfstail.c -- ISSUE-36 acceptance: mmap the tail of NFS files and prove the bytes, not just
 * the absence of a crash.
 *
 * THE DEFECT (Codex, vm-map/NFS-READSIDE-ISSUE36-SITE.md; hardware evidence 2026-07-27)
 * nfs_getpage's EOF allowance still added the 2 KiB PAGEOFFSET, so with r = file_size mod 4096
 * the OLD kernel refused the final page for r in 1..2048 -- EFAULT, which segvn turns into
 * FC_MAKE_ERR(14) = 0xE05, which the user sees as SIGBUS.  r == 0 and r >= 2049 were accepted.
 * The fix is four atomic sites (src/patch_nfs_getpage.py).
 *
 * THIS TEST CHECKS THREE THINGS, AND THE SECOND IS THE ONE A NAIVE TEST MISSES
 *
 * 1. NO SIGBUS on the tail page.  That is the visible failure.
 *
 * 2. THE BYTES PAST EOF IN THE FINAL PAGE MUST BE ZERO.  This is not pedantry -- it is the
 *    second half of the defect.  Relaxing the EOF gate WITHOUT the io_len round-up pair admits
 *    the page while the I/O still describes only 2048 bytes, so bytes 2048..4095 of the tail page
 *    are never initialized by that read.  They are readable and wrong, and no test that only
 *    touches p[size-1] can see it.  ISSUE-35 taught this exact lesson the expensive way: a size
 *    check passed a kernel that was losing half of every page.
 *
 * 3. EVERY BYTE IN THE FILE MATCHES THE HOST-WRITTEN PATTERN.  The corpus is written by the host
 *    over SMB and only ever read here, so a mismatch is the kernel's, not the test's.  The
 *    pattern ((o ^ (o>>8) ^ (o>>16)) & 0xfe) + 1 is NEVER ZERO, which is what makes checks 2
 *    and 3 separable: a zero inside the file is lost data, and a nonzero past EOF is a stale
 *    page.  Without that property the two failures are indistinguishable.
 *
 * TAIL FIRST, ON PURPOSE.  Each file's LAST byte is touched before anything else, so the tail
 * page is the first fault against a cold file.  Codex's acceptance item 3 asks for exactly this
 * on a file whose last 8 KiB block holds two 4 KiB pages (size 8192*N + 4096 + 123): faulting the
 * tail first makes pvn_kluster scan BACKWARD and return both pages, which is the input shape that
 * exposes the pl[] return-list defect the EOF repair could otherwise newly unmask.
 *
 * SIGBUS IS CAUGHT AND THE RUN CONTINUES.  A SIGBUS would otherwise kill the process on the first
 * failing file and we would learn one bit instead of the whole table.  With the handler, one run
 * on the OLD kernel prints the complete predicate -- which is what confirms or refutes Codex's
 * model -- and one run on the NEW kernel prints all PASS.
 *
 * EXPECTED, OLD kernel:  r=1, r=123, r=2048 -> SIGBUS;  r=0, r=2049, r=4095 -> pass
 * EXPECTED, NEW kernel:  every case passes, every byte matches, every post-EOF byte zero
 * If r=2049 fails on the old kernel, Codex's boundary model is WRONG and the patch must not be
 * trusted until the analysis is redone.  Report that rather than explaining it away.
 *
 * COLD FILES ARE THE EXPERIMENT.  The corpus carries a run tag so a re-run never reads pages the
 * client cached earlier.  Generate a fresh tag rather than re-reading an old corpus.
 *
 * usage: nfstail <dir> <manifest>          both under the NFS mount
 *        e.g. ./nfstail /mnt/nasu/amix/issue36 tail_r1_manifest
 *
 * 68060 (ISSUE-34a): no `%` and no division by a constant -- masks and shifts only.
 * K&R C for the AMIX native cc.  cc -o nfstail nfstail.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <signal.h>
#include <setjmp.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <errno.h>

jmp_buf jb;
int	 caught;
int	 caughtsig;

void
onbus(sig)
int sig;
{
	caught = 1;
	caughtsig = sig;
	longjmp(jb, 1);
}

/* never zero -- see the header: that is what separates "lost data" from "stale page" */
int
pat(o)
long o;
{
	return (int) ((((o ^ (o >> 8) ^ (o >> 16)) & 0xfeL) + 1L) & 0xffL);
}

main(argc, argv)
int argc;
char **argv;
{
	FILE *mf;
	char *dir, *mpath;
	char line[256], path[512], name[128];
	char *p;
	int fd, files, failed, i;
	long size, r, o, pgbase, pgend, firstbad, nzero;
	int v;

	if (argc < 3) {
		printf("usage: nfstail <dir> <manifest>\n");
		exit(2);
	}
	dir = argv[1];
	sprintf(path, "%s/%s", dir, argv[2]);
	mpath = path;
	mf = fopen(mpath, "r");
	if (mf == (FILE *) 0) {
		printf("NFSTAIL ERR cannot read manifest %s\n", mpath);
		exit(1);
	}

	printf("NFSTAIL dir=%s manifest=%s\n", dir, argv[2]);
	printf("NFSTAIL r = size mod 4096.  OLD kernel refuses r in 1..2048; r=0/2049/4095 pass.\n");
	printf("NFSTAIL checks: (a) no SIGBUS  (b) bytes past EOF in the tail page are ZERO\n");
	printf("NFSTAIL         (c) every in-file byte matches the host-written pattern\n");
	fflush(stdout);

	files = 0;
	failed = 0;
	while (fgets(line, sizeof(line), mf) != (char *) 0) {
		if (line[0] == '#' || line[0] == '\n')
			continue;
		name[0] = 0;
		size = 0L;
		r = 0L;
		if (sscanf(line, "%s %ld %ld", name, &size, &r) != 3)
			continue;
		files++;

		sprintf(path, "%s/%s", dir, name);
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			printf("NFSTAIL FAIL %-34s cannot open (errno=%d)\n", name, errno);
			failed++;
			continue;
		}
		p = (char *) mmap((caddr_t) 0, (size_t) size, PROT_READ, MAP_PRIVATE, fd, (off_t) 0);
		if (p == (char *) -1) {
			printf("NFSTAIL FAIL %-34s mmap failed (errno=%d)\n", name, errno);
			failed++;
			(void) close(fd);
			continue;
		}

		caught = 0;
		caughtsig = 0;
		(void) signal(SIGBUS, onbus);
		(void) signal(SIGSEGV, onbus);

		if (setjmp(jb) != 0) {
			/* came back from the handler: this file faulted */
			printf("NFSTAIL FAIL %-34s size=%-6ld r=%-4ld *** SIG%d on the tail page ***\n",
			       name, size, r, caughtsig);
			failed++;
			(void) signal(SIGBUS, SIG_DFL);
			(void) signal(SIGSEGV, SIG_DFL);
			(void) munmap((caddr_t) p, (size_t) size);
			(void) close(fd);
			continue;
		}

		/* (1) TAIL FIRST -- before any earlier page, so this is the cold file's first fault */
		v = p[size - 1] & 0xff;

		/* (3) every byte in the file */
		firstbad = -1L;
		for (o = 0L; o < size; o++) {
			if ((p[o] & 0xff) != pat(o)) {
				firstbad = o;
				break;
			}
		}

		/* (2) the remainder of the final page must be zero.  Only meaningful when the file
		 * does not end exactly on a page boundary; when r == 0 there is no remainder. */
		nzero = 0L;
		if (r != 0L) {
			pgbase = size & ~0xfffL;
			pgend = pgbase + 4096L;
			for (o = size; o < pgend; o++)
				if ((p[o] & 0xff) != 0)
					nzero++;
		}

		(void) signal(SIGBUS, SIG_DFL);
		(void) signal(SIGSEGV, SIG_DFL);

		if (firstbad >= 0L) {
			printf("NFSTAIL FAIL %-34s size=%-6ld r=%-4ld DATA mismatch at %ld (got %02x want %02x)\n",
			       name, size, r, firstbad, p[firstbad] & 0xff, pat(firstbad));
			failed++;
		} else if (nzero > 0L) {
			printf("NFSTAIL FAIL %-34s size=%-6ld r=%-4ld %ld NONZERO bytes past EOF in the tail page\n",
			       name, size, r, nzero);
			printf("NFSTAIL      ^ the page was admitted but not fully initialized -- this is the\n");
			printf("NFSTAIL        io_len half of the defect, invisible to a p[size-1] touch alone\n");
			failed++;
		} else {
			printf("NFSTAIL PASS %-34s size=%-6ld r=%-4ld tail=%02x, all bytes match, past-EOF zero\n",
			       name, size, r, v);
		}

		(void) munmap((caddr_t) p, (size_t) size);
		(void) close(fd);
		fflush(stdout);
	}
	(void) fclose(mf);

	printf("NFSTAIL-RESULT %s  (%d files, %d failed)\n",
	       (failed == 0) ? "PASS" : "FAIL", files, failed);
	printf("NFSTAIL note: on the OLD kernel a FAIL list of exactly r=1,123,2048 CONFIRMS the\n");
	printf("NFSTAIL       model; r=2049 failing too would REFUTE it -- report that, do not\n");
	printf("NFSTAIL       explain it away, and do not trust the patch until it is understood.\n");
	exit((failed == 0) ? 0 : 1);
}
