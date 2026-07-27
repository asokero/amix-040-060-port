/* segwrite.c -- ISSUE-37 sweep 4: the coverage gap.  Sweeps 1-3 tested READS only.
 *
 * WHAT IS ALREADY RULED OUT, on real hardware, kernel 260727-02
 *   sweep 1 (segmaprep) 12 single-byte reads, one per fresh 8 KiB slot, every within-slot
 *                       offset including 4095 -- the exact offset of the hardware fault: ALL PASS
 *   sweep 2 (segspan)   14 reads that straddle page and slot boundaries, every misalignment,
 *                       matched and mismatched source/destination alignment, spans to 64 KB: PASS
 *   sweep 3 (pmrep)     wolf3d's own PM_Startup loader, 663 seek+read pairs at the real VSWAP
 *                       chunk offsets and lengths, no game attached: ALL PASS
 *   vamap               user mmap lands at 0xc1033000, so the looping kernel address 0x408F4FFF
 *                       is genuinely kernel-side and is NOT the mapped VA2000 aperture
 *
 * WHY WRITES ARE THE RIGHT NEXT TEST, rather than a 27th read variant
 * A write through segmap is a different path, not a variant: a partial-page write must first read
 * the page in, then dirty it, then hand it to the filesystem's putpage.  ISSUE-35 was exactly a
 * putpage defect, and Codex's residual census flags `ufs_allocmap` as rounding with `+0x0fff`
 * where the 4 KiB form needs `+0x1000` -- a named, already-suspected site on the write side.
 * Writing at sparse offsets forces UFS block allocation, which is what allocmap is for.
 *
 * Writes go to a FRESH file this program creates, never to anything that matters.
 *
 * Each case: lseek to an offset (leaving a hole, so UFS must allocate), write an odd length, and
 * on the final pass read every written run back and verify its bytes.  Verification matters as
 * much as not wedging: ISSUE-35's lesson was that a write path can report success and still lose
 * half of every page, so "it did not hang" is not the same as "it worked".
 *
 * Pattern is derived from the absolute file offset (o ^ (o>>8) ^ (o>>16)) so a byte landing at the
 * wrong offset is detectable, and it involves no division -- ISSUE-34a keeps this 68060-safe.
 *
 * usage: segwrite <newfile> [statefile]
 * K&R C for the AMIX native cc.  cc -o segwrite segwrite.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>

#define MAXW 20480

long  w_off[] = {
	4095L,      /* page tail, into a hole */
	8191L,      /* slot tail */
	12288L,     /* page-aligned control */
	20477L,     /* straddles a page boundary from 3 bytes before it */
	32765L,     /* straddles a slot boundary */
	40960L,     /* aligned, one whole page */
	49151L,     /* page tail, long write spanning pages */
	65535L,     /* slot tail, long write spanning slots */
	81920L,     /* aligned, two slots */
	102401L     /* misaligned, large */
};
long  w_len[] = { 1L, 1L, 4096L, 8L, 8L, 4096L, 8192L, 16384L, 16384L, 20480L };
char *w_why[] = {
	"1 byte at a page tail, into a hole (UFS must allocate)",
	"1 byte at a slot tail, into a hole",
	"4096 aligned -- control",
	"8 bytes straddling a page boundary",
	"8 bytes straddling a slot boundary",
	"one full page, aligned",
	"8192 starting at a page tail -- partial head AND tail",
	"16384 starting at a slot tail",
	"16384 aligned, two slots",
	"20480 misaligned -- many partial pages"
};
#define NCASES 10

char buf[MAXW + 16];

long
pat(o)
long o;
{
	long v;

	v = o ^ (o >> 8) ^ (o >> 16);
	return (v & 0xffL);
}

main(argc, argv)
int argc;
char **argv;
{
	int fd, sfd, i;
	long j, off, len, got, bad, checked;
	char line[220];

	if (argc < 2) {
		printf("usage: segwrite <newfile> [statefile]\n");
		exit(2);
	}
	fd = open(argv[1], O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) {
		printf("SEGWRITE ERR cannot create %s\n", argv[1]);
		exit(1);
	}
	sfd = open((argc > 2) ? argv[2] : "/segwrite.state", O_WRONLY | O_CREAT | O_TRUNC, 0644);

	printf("SEGWRITE file=%s -- sweep 4: the WRITE path (sweeps 1-3 tested reads only)\n", argv[1]);
	printf("SEGWRITE sparse offsets force UFS block allocation (ufs_allocmap +0x0fff suspect)\n");
	fflush(stdout);

	for (i = 0; i < NCASES; i++) {
		off = w_off[i];
		len = w_len[i];
		for (j = 0L; j < len; j++)
			buf[j] = (char) pat(off + j);

		sprintf(line, "SEGWRITE TRY case=%d off=%ld len=%ld  %s\n", i, off, len, w_why[i]);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
			sleep(1);
			sync();
		}

		if (lseek(fd, off, 0) != off) {
			printf("SEGWRITE ERR lseek %ld\n", off);
			break;
		}
		got = (long) write(fd, buf, (unsigned) len);
		if (got != len) {
			printf("SEGWRITE ERR short write case=%d want=%ld got=%ld\n", i, len, got);
			break;
		}
		sprintf(line, "SEGWRITE OK  case=%d wrote=%ld\n", i, got);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
		}
	}

	/* ISSUE-35's lesson: not hanging is not the same as being correct.  Read every run back and
	 * compare bytes against the offset-derived pattern.  sync() first so the comparison has a
	 * chance to see what actually reached the filesystem rather than only the page cache. */
	sync();
	printf("SEGWRITE verifying %d runs byte by byte\n", NCASES);
	fflush(stdout);
	bad = 0L;
	checked = 0L;
	for (i = 0; i < NCASES; i++) {
		off = w_off[i];
		len = w_len[i];
		if (lseek(fd, off, 0) != off) {
			printf("SEGWRITE ERR verify lseek %ld\n", off);
			bad = bad + 1L;
			continue;
		}
		got = (long) read(fd, buf, (unsigned) len);
		if (got != len) {
			printf("SEGWRITE BAD  case=%d readback short want=%ld got=%ld\n", i, len, got);
			bad = bad + 1L;
			continue;
		}
		for (j = 0L; j < len; j++) {
			checked = checked + 1L;
			if ((buf[j] & 0xff) != (int) pat(off + j)) {
				printf("SEGWRITE BAD  case=%d first mismatch at +%ld (abs %ld) got=%02x want=%02x\n",
				       i, j, off + j, buf[j] & 0xff, (int) pat(off + j));
				bad = bad + 1L;
				break;
			}
		}
	}
	printf("SEGWRITE-RESULT %s  (%ld runs bad, %ld bytes checked)\n",
	       (bad == 0L) ? "PASS" : "FAIL", bad, checked);
	fflush(stdout);
	if (sfd >= 0)
		(void) close(sfd);
	(void) close(fd);
	exit(0);
}
