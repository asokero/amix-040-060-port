/* nfstail-mk.c -- build the ISSUE-36 corpus LOCALLY, with the same sizes and pattern as
 * nfstail-gen.py, so nfstail.c has a control that isolates NFS from mmap-in-general.
 *
 * TWO USES, both real:
 *
 * 1. LOCAL CONTROL on the acceptance run.  ISSUE-36's original isolation depended on exactly this
 *    comparison: the same length that SIGBUSes on NFS is fine on local UFS.  Running nfstail
 *    against a local corpus and an NFS corpus in the same session separates "the tail page is
 *    broken" from "the NFS provider is broken", and it does so with the same verifier rather than
 *    with two programs that could differ.
 *
 * 2. VALIDATING THE VERIFIER without NFS.  The emulator cannot reach an NFS server (Amiberry's
 *    slirp does not forward RPC/portmap outbound -- rpcinfo cannot contact the portmapper), so
 *    the NFS half can only run on real hardware.  This lets the verifier itself be debugged in
 *    the emulator first, so hardware time is spent on the kernel and not on my own test bugs.
 *
 * Note what this canNOT do: the bytes here are written by the same client that reads them, so a
 * pass proves the local path and the verifier, NOT server-side truth.  The NFS corpus must come
 * from the host (nfstail-gen.py over SMB) for the reason ISSUE-35 established -- a client that
 * writes and then reads its own page cache can pass on a kernel that never wrote the data.
 *
 * usage: nfstail-mk <dir> [tag]        writes tail_<tag>_<size>_r<r> files + tail_<tag>_manifest
 *
 * 68060 (ISSUE-34a): no `%` and no division by a constant.
 * K&R C for the AMIX native cc.  cc -o nfstail-mk nfstail-mk.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>

/* same seven sizes as nfstail-gen.py, and for the same reasons -- the 2048/2049 pair is the
 * boundary of the old gate, and 28795 = 8192*3 + 4096 + 123 is the backward-clustering case */
long sizes[] = { 24576L, 24577L, 24699L, 26624L, 26625L, 28671L, 28795L };
#define NSIZES 7

char buf[8192];

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
	char *dir, *tag;
	char path[512], name[128], line[256];
	int fd, mfd, i;
	long size, r, o, n, chunk;

	if (argc < 2) {
		printf("usage: nfstail-mk <dir> [tag]\n");
		exit(2);
	}
	dir = argv[1];
	tag = (argc > 2) ? argv[2] : "local";

	sprintf(path, "%s/tail_%s_manifest", dir, tag);
	mfd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (mfd < 0) {
		printf("NFSTAILMK ERR cannot create %s\n", path);
		exit(1);
	}
	sprintf(line, "# ISSUE-36 LOCAL corpus, tag %s -- client-written, so a control only\n", tag);
	(void) write(mfd, line, strlen(line));

	for (i = 0; i < NSIZES; i++) {
		size = sizes[i];
		r = size & 0xfffL;
		sprintf(name, "tail_%s_%ld_r%ld", tag, size, r);
		sprintf(path, "%s/%s", dir, name);
		fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) {
			printf("NFSTAILMK ERR cannot create %s\n", path);
			exit(1);
		}
		o = 0L;
		while (o < size) {
			chunk = size - o;
			if (chunk > 8192L)
				chunk = 8192L;
			for (n = 0L; n < chunk; n++)
				buf[n] = (char) pat(o + n);
			if ((long) write(fd, buf, (unsigned) chunk) != chunk) {
				printf("NFSTAILMK ERR short write on %s\n", name);
				exit(1);
			}
			o = o + chunk;
		}
		(void) close(fd);
		sprintf(line, "%s %ld %ld\n", name, size, r);
		(void) write(mfd, line, strlen(line));
		printf("NFSTAILMK %-32s %7ld bytes  r=%ld\n", name, size, r);
	}
	(void) close(mfd);
	sync();
	printf("NFSTAILMK-DONE %d files + tail_%s_manifest in %s\n", NSIZES, tag, dir);
	printf("NFSTAILMK      now: ./nfstail %s tail_%s_manifest   (expect ALL PASS on local UFS)\n",
	       dir, tag);
	exit(0);
}
