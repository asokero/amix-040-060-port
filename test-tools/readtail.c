/* readtail.c -- ISSUE-37 sweep 6: read a UFS file to its EXACT EOF in one large read into a
 * fresh buffer.  The local analogue of ISSUE-36, and the one shape 69 passing cases all missed.
 *
 * WHY THIS SHAPE, AFTER FIVE NEGATIVE SWEEPS
 * The wedged process is at libc `read`+4, so the loop is inside a read(2), and the call site is
 * wl_main.c's SignonScreen:  fread(signon, 320*200, 1, file) -- which reads signon.wl6 in its
 * ENTIRETY, so the request ends exactly at EOF.  Every earlier sweep read from the middle of a
 * file: segmaprep single bytes at slot offsets, segspan mid-file straddles, pmrep the VSWAP chunk
 * table (all mid-file), readfresh offsets 0..630272 of a 1.5 MB file.  **None of them ever asked
 * for a file's last partial page in a large read.**
 *
 * And that is exactly the class ISSUE-36 turned out to be, one filesystem over: a stale 2 KiB
 * EOF allowance in the provider.  Codex's residual census counts **UFS at 12 unconverted sites**,
 * including the note that `ufs_allocmap` rounds with `+0x0fff` where a 4 KiB page needs `+0x1000`.
 * If UFS has the same shape of tail defect as NFS did, this is how a read(2) would meet it.
 *
 * The corpus is the same seven sizes nfstail-mk builds, so the remainders straddle the boundary
 * that mattered for NFS (r = size mod 4096, with 2048 and 2049 adjacent) -- and if the UFS
 * boundary sits elsewhere, the spread still brackets it.
 *
 * Reads the WHOLE file in ONE read() into a FRESH /dev/zero mapping, then verifies every byte
 * against the offset-derived pattern, because a read that returns without wedging can still return
 * wrong bytes -- ISSUE-35's lesson, and cheap to check here.
 *
 * usage: readtail <dir> <manifest>        e.g. ./readtail /root/c36 tail_loc_manifest
 * 68060 (ISSUE-34a): no `%`, no division by a constant.  K&R C for the native cc.
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <errno.h>

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
	char line[256], path[512], name[128];
	char *dst;
	int fd, zfd, files, bad;
	long size, r, got, o, firstbad;

	if (argc < 3) {
		printf("usage: readtail <dir> <manifest>\n");
		exit(2);
	}
	sprintf(path, "%s/%s", argv[1], argv[2]);
	mf = fopen(path, "r");
	if (mf == (FILE *) 0) {
		printf("READTAIL ERR cannot read %s\n", path);
		exit(1);
	}
	printf("READTAIL one large read of the WHOLE file (ending exactly at EOF) into a fresh dest\n");
	printf("READTAIL 69 earlier cases all read MID-file; none ever asked for a file's last page\n");
	fflush(stdout);

	files = 0;
	bad = 0;
	while (fgets(line, sizeof(line), mf) != (char *) 0) {
		if (line[0] == '#' || line[0] == '\n')
			continue;
		if (sscanf(line, "%s %ld %ld", name, &size, &r) != 3)
			continue;
		files++;
		printf("READTAIL TRY %-30s size=%-6ld r=%ld\n", name, size, r);
		fflush(stdout);

		sprintf(path, "%s/%s", argv[1], name);
		fd = open(path, O_RDONLY);
		if (fd < 0) {
			printf("READTAIL FAIL %-28s cannot open (errno=%d)\n", name, errno);
			bad++;
			continue;
		}
		zfd = open("/dev/zero", O_RDWR);
		dst = (char *) mmap((caddr_t) 0, (size_t) (size + 4096L),
				    PROT_READ | PROT_WRITE, MAP_PRIVATE, zfd, (off_t) 0);
		(void) close(zfd);
		if (dst == (char *) -1) {
			printf("READTAIL FAIL %-28s fresh dest mmap failed\n", name);
			bad++;
			(void) close(fd);
			continue;
		}

		got = (long) read(fd, dst, (unsigned) size);   /* the whole file, one call, to EOF */

		firstbad = -1L;
		if (got == size)
			for (o = 0L; o < size; o++)
				if ((dst[o] & 0xff) != pat(o)) { firstbad = o; break; }

		if (got != size)
			printf("READTAIL FAIL %-28s short read want=%ld got=%ld\n", name, size, got), bad++;
		else if (firstbad >= 0L)
			printf("READTAIL FAIL %-28s DATA mismatch at %ld (got %02x want %02x)\n",
			       name, firstbad, dst[firstbad] & 0xff, pat(firstbad)), bad++;
		else
			printf("READTAIL PASS %-28s size=%-6ld r=%-4ld all %ld bytes correct\n",
			       name, size, r, got);
		fflush(stdout);
		(void) munmap((caddr_t) dst, (size_t) (size + 4096L));
		(void) close(fd);
	}
	(void) fclose(mf);
	printf("READTAIL-RESULT %s (%d files, %d bad)\n", (bad == 0) ? "PASS" : "FAIL", files, bad);
	exit((bad == 0) ? 0 : 1);
}
