/* segspan.c -- ISSUE-37 sweep 2: does a read that STRADDLES a page boundary wedge the kernel?
 *
 * WHY THERE IS A SWEEP 2 -- sweep 1 came back negative, and that is the useful part
 * segmaprep.c probed one single-byte read per fresh 8 KiB segmap slot at within-slot offsets
 * 0,1,2047,2048,2049,4094,4095,4096,4097,6143,8190,8191.  On real hardware, kernel 260727-02:
 * ALL TWELVE RESOLVED.  Including 4095, which is exactly the within-slot offset of the hardware
 * fault (0x408F4FFF - 0x40440000 = 0x4B4FFF; slot 602 base = 0x408F4000; so the faulting byte is
 * at within-slot offset 0xFFF = 4095).
 *
 * So "first touch at a page-tail offset" is REFUTED.  The faulting byte is reachable.  What
 * differs must be HOW it is reached, and a single-byte access has one property no wolf3d read
 * has: it can never straddle a page boundary.
 *
 * THE REFINED HYPOTHESIS
 * The kernel copies segmap window -> user buffer with bcopy.  bcopy can only use long moves when
 * source and destination share an alignment; when they DIFFER, one side is misaligned on every
 * transfer.  A misaligned long read whose first byte is at page offset 4093..4095 spans into the
 * NEXT page.  If that next page is absent, the 68040 reports the access error and -- this is the
 * whole question -- if the reported fault address is the START of the access rather than the
 * faulting bus cycle, then as_fault rounds 0x...4FFF down to 0x...4000, faults in a page that is
 * ALREADY PRESENT, reports success, and the instruction retries and straddles again.  Forever,
 * with ret=0.  That matches the log exactly, including why ret is 0 rather than an error.
 *
 * And it matches wolf3d specifically: id_pm_amiga.c's PML_ReadFromFile(addr, offset, length)
 * takes `offset` from the VSWAP chunk table -- arbitrary, so arbitrary mod 4 -- and `addr` from
 * malloc, which is aligned.  Different alignments on the two sides is its NORMAL case, not its
 * unusual one.  Sequential readers start at offset 0 into an aligned buffer and match.
 *
 * WHAT THIS SWEEP VARIES, and why each row earns its place
 * Every case runs in its OWN fresh slot so every read is that slot's first touch, and the slot
 * cursor advances past whatever the case spans so cases never warm each other.
 *   * within=4092 len=8 dalign=0   CONTROL: 4-aligned source that still crosses the boundary.
 *                                  If this wedges too, the straddle hypothesis is wrong and the
 *                                  problem is simply "crossing a page boundary".
 *   * within=4093/4094/4095        the straddling long read, one per misalignment.
 *   * dalign 1/2/3                 makes the destination misaligned BY THE SAME amount, which
 *                                  lets bcopy align both sides and use aligned long moves.  If
 *                                  the matched cases pass while the mismatched ones wedge, the
 *                                  mechanism is proven to be alignment mismatch, not length.
 *   * within=8189..8191            crosses the SLOT boundary rather than a page boundary -- a
 *                                  different segmap path (a second getmap), same straddle.
 *   * long lengths                 multi-page and multi-slot spans, in case a single boundary is
 *                                  not enough and it takes a run of them.
 *
 * IT WILL WEDGE THE MACHINE if the hypothesis holds.  Progress is written to stdout AND to a
 * synced state file BEFORE each attempt, so the answer survives the hard reset.  Default state
 * path is on / because /tmp is cleared on every AMIX boot.
 *
 * COLD FILE REQUIRED: the loop needs absent pages.  Fresh boot, and a file nothing has read yet.
 * segmaprep.c already warmed the first ~100 KB of whatever file it was given -- so use a
 * DIFFERENT file (simplest), or pass a firstslot past what it touched.  The sweep needs about
 * 53 slots plus the tail of its longest case, i.e. roughly 2.2 MB from firstslot onward.
 *
 * usage: segspan <file> [statefile] [firstslot]     file on UFS, COLD from firstslot on
 *
 * 68060 (ISSUE-34a): no `%` and no division by a constant anywhere -- shifts and adds only.
 * K&R C for the AMIX native cc.  cc -o segspan segspan.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>

#define SLOTSHIFT 13
#define SLOTSIZE  8192L
#define DFLTFIRST 1               /* with a DIFFERENT file than sweep 1 used, slot 1 is cold */
#define MAXLEN    65536

long  c_within[] = { 4092L, 4093L, 4094L, 4095L, 4093L, 4094L, 4095L, 4093L,  8188L,  8189L,  8191L,    1L,    3L, 4093L };
long  c_len[]    = {    8L,    8L,    8L,    8L,    8L,    8L,    8L, 4096L,     8L,     8L,     8L, 8192L,16384L,65536L };
int   c_dalign[] = {    0,     0,     0,     0,     1,     2,     3,     0,      0,      0,      0,     0,     0,     0  };
char *c_why[]    = {
	"CONTROL 4-aligned src, still crosses the page boundary",
	"straddle: src misaligned by 1 across the page boundary",
	"straddle: src misaligned by 2 across the page boundary",
	"straddle: src misaligned by 3 across the page boundary  *** prime suspect ***",
	"MATCHED alignment (src+1, dst+1) -- bcopy can align both",
	"MATCHED alignment (src+2, dst+2)",
	"MATCHED alignment (src+3, dst+3)",
	"straddle + multi-page: misaligned src, 4096 bytes",
	"CONTROL 4-aligned src across the SLOT boundary",
	"straddle across the SLOT boundary (src misaligned by 1)",
	"straddle across the SLOT boundary (src misaligned by 3)",
	"misaligned start, one whole slot",
	"misaligned start, two slots",
	"misaligned src, 64 KB -- many page and slot boundaries"
};
#define NCASES 14

char bigbuf[MAXLEN + 8];

main(argc, argv)
int argc;
char **argv;
{
	char *path, *statepath, *dst;
	int fd, sfd, i;
	long off, slot, fsize, need, got, slotcur, span, firstslot;
	char line[256];

	if (argc < 2) {
		printf("usage: segspan <file> [statefile]\n");
		exit(2);
	}
	path = argv[1];
	statepath = (argc > 2) ? argv[2] : "/segspan.state";
	firstslot = (argc > 3) ? atol(argv[3]) : (long) DFLTFIRST;
	if (firstslot < 1L)
		firstslot = 1L;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("SEGSPAN ERR cannot open %s\n", path);
		exit(1);
	}
	fsize = lseek(fd, 0L, 2);
	need = (firstslot << SLOTSHIFT) + (long) (MAXLEN * 3) + (53L << SLOTSHIFT);
	if (fsize < need) {
		printf("SEGSPAN ERR %s is %ld bytes; need >= %ld\n", path, fsize, need);
		exit(1);
	}

	sfd = open(statepath, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	printf("SEGSPAN file=%s size=%ld state=%s firstslot=%ld\n",
	       path, fsize, statepath, firstslot);
	printf("SEGSPAN sweep 2: does a read STRADDLING a page boundary wedge the kernel?\n");
	printf("SEGSPAN sweep 1 (single-byte, all offsets incl. 4095) PASSED -- so length/alignment\n");
	printf("SEGSPAN each case gets a fresh cold slot; last line printed = the case that wedged\n");
	fflush(stdout);

	slotcur = firstslot;
	for (i = 0; i < NCASES; i++) {
		slot = slotcur << SLOTSHIFT;
		off = slot + c_within[i];
		dst = bigbuf + c_dalign[i];

		sprintf(line,
		 "SEGSPAN TRY case=%d slot=%ld within=%ld len=%ld dalign=%d off=%ld  %s\n",
		 i, slot, c_within[i], c_len[i], c_dalign[i], off, c_why[i]);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
			sleep(1);          /* sync() only schedules; give the disk time before the risk */
			sync();
		}

		if (lseek(fd, off, 0) != off) {
			printf("SEGSPAN ERR lseek %ld failed\n", off);
			break;
		}
		got = (long) read(fd, dst, (unsigned) c_len[i]);

		sprintf(line, "SEGSPAN OK  case=%d got=%ld first=%02x last=%02x\n",
			i, got, dst[0] & 0xff, (got > 0) ? (dst[got - 1] & 0xff) : 0);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
		}

		/* advance past everything this case touched, +2 slots of margin, so the next case
		 * is guaranteed cold rather than accidentally warmed by this one */
		span = (c_len[i] >> SLOTSHIFT) + 3L;
		slotcur = slotcur + span;
	}

	printf("SEGSPAN-DONE all %d cases resolved.  Straddling is NOT the trigger either.\n", NCASES);
	printf("SEGSPAN      Next candidates, in order: (1) the fault is on the WRITE side or in\n");
	printf("SEGSPAN      mmap rather than read; (2) it needs memory pressure so that segmap\n");
	printf("SEGSPAN      slots are being RECYCLED under it; (3) it is not segmap file I/O at\n");
	printf("SEGSPAN      all and the 0x408Fxxxx address belongs to something else -- settle\n");
	printf("SEGSPAN      that by printing seg->s_ops at the loop instead of guessing again.\n");
	fflush(stdout);
	if (sfd >= 0)
		(void) close(sfd);
	(void) close(fd);
	exit(0);
}
