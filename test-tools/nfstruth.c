/* nfstruth.c -- ISSUE-35 acceptance: does NFS write every BYTE, not just the right size?
 *
 * WHY THIS EXISTS AND WHY THE SIZE SWEEP WAS NOT ENOUGH
 * The 2026-07-27 hardware run characterised ISSUE-35 by file SIZE: lengths that are exact
 * multiples of 8192 came out 2048 bytes short.  Codex's follow-up
 * (vm-map/NFS-REALHW-ISSUE35-FOLLOWUP.md) points out that this is insufficient as an
 * acceptance test: a file whose reported size is right can still have UNWRITTEN UPPER HALVES
 * in its earlier full 8 KiB slots.  st_size passes.  A same-client read also passes, because
 * it can be served from the client's own page cache -- the same masking that defeated three
 * ISSUE-27 probe designs.
 *
 * So the observable here is BYTES AS THE SERVER STORED THEM.  This program only WRITES and
 * states its expectation; test-tools/nfstruth-verify.py does the checking from a different
 * client over a different protocol.
 *
 * PATTERN: every byte at absolute offset o gets ((o >> 9) % 251) + 1 -- derived from the
 * absolute offset, distinct per 512-byte region, and NEVER ZERO.  Non-zero matters: an
 * unwritten region reads back as either zeros (freshly allocated server block) or stale
 * data, and both differ from the expected value.  Provenance-independent, which is the
 * lesson ISSUE-27 taught: make the failure signal "the expected byte is not there" rather
 * than "the byte looks odd".
 *
 * usage: nfstruth <dir> [sizes...]      default sizes exercise the known boundaries
 *   e.g. nfstruth /mnt/nasu/amix/hwtest 8192 12288 16384 24576 32768
 *
 * K&R C for the AMIX native cc.  cc -o nfstruth nfstruth.c
 */
#include <stdio.h>
#include <fcntl.h>

#define BUFSZ 8192

char buf[BUFSZ];

/* the expected byte for absolute file offset o -- keep identical to nfstruth-verify.py */
int
patbyte(o)
long o;
{
	return (int)(((o >> 9) % 251L) + 1L);
}

int
writeone(dir, sz)
char *dir;
long sz;
{
	char path[256];
	int fd, i, n;
	long off, chunk;

	sprintf(path, "%s/truth%ld.bin", dir, sz);
	(void) unlink(path);
	fd = open(path, O_WRONLY|O_CREAT|O_TRUNC, 0666);
	if (fd < 0) {
		printf("NFSTRUTH ERR open %s failed\n", path);
		return (1);
	}
	off = 0L;
	while (off < sz) {
		chunk = sz - off;
		if (chunk > (long)BUFSZ)
			chunk = (long)BUFSZ;
		for (i = 0; i < (int)chunk; i++)
			buf[i] = (char) patbyte(off + (long)i);
		n = write(fd, buf, (unsigned)chunk);
		if (n != (int)chunk) {
			printf("NFSTRUTH ERR short write at off=%ld n=%d\n", off, n);
			(void) close(fd);
			return (1);
		}
		off += chunk;
	}
	if (close(fd) < 0) {
		printf("NFSTRUTH ERR close failed for %s\n", path);
		return (1);
	}
	printf("NFSTRUTH wrote %s expect=%ld\n", path, sz);
	return (0);
}

main(argc, argv)
int argc;
char **argv;
{
	static long deflt[] = { 4096L, 8192L, 12288L, 16384L, 24576L, 32768L, 0L };
	char *dir;
	int i, errs;
	long sz;

	if (argc < 2) {
		printf("usage: nfstruth <dir> [sizes...]\n");
		exit(2);
	}
	dir = argv[1];
	errs = 0;

	if (argc > 2) {
		for (i = 2; i < argc; i++) {
			sz = atol(argv[i]);
			errs += writeone(dir, sz);
		}
	} else {
		for (i = 0; deflt[i] != 0L; i++)
			errs += writeone(dir, deflt[i]);
	}

	sync();
	sync();
	printf("NFSTRUTH-WRITE-DONE errs=%d\n", errs);
	printf("NFSTRUTH now verify FROM THE SERVER SIDE:\n");
	printf("        python3 test-tools/nfstruth-verify.py <server-side-dir>\n");
	exit(errs ? 1 : 0);
}
