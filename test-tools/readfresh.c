/* readfresh.c -- ISSUE-37 sweep 5: read a large file into an UNTOUCHED buffer, the way
 * wolf3d's SignonScreen does.  This is the first sweep aimed at a property the previous four
 * did not have, rather than at another variation of one they did.
 *
 * WHAT THE PREVIOUS FOUR SWEEPS PROVED, AND WHERE THEY WERE ALL BLIND
 * segmaprep (12 single-byte reads at every within-slot offset), segspan (14 straddling reads at
 * every misalignment), pmrep (wolf3d's own 663-read PM_Startup loader) and segwrite (10 sparse
 * writes, byte-verified) ALL PASSED on hardware.  62 cases, no wedge.  But every one of them read
 * into a buffer that was ALREADY RESIDENT -- a .bss array or a malloc'd block touched by an
 * earlier iteration -- and none of them had a device mapping live at the same time.
 *
 * WHAT THE LOOP ACTUALLY IS, now that the user PC is resolved
 * The wedged process sits at upc=0xC1013088 on BOTH observed runs.  libc.so.1 maps at 0xC1000000
 * and is not stripped, and its text has vaddr == file offset, so that is libc.so.1 + 0x13088 =
 * `read` + 4 -- the syscall stub.  So ISSUE-37 is a read(2) that never returns, while the kernel
 * loops in as_fault on a segmap window address (0x408F4FFF on 27.7., 0x40A80FFF on 28.7.: a
 * different slot each time, always the last byte of a page, always type=0 ret=0).
 *
 * AND THAT NARROWS IT TO ONE CALL SITE.  wl_main.c's SignonScreen is the first thing InitGame
 * runs (line 1379, before PM_Startup at 1399 -- which is why the screen goes black and the game
 * never reaches its menu), and it does exactly this:
 *
 *     VL_SetVGAPlaneMode();                  // open /dev/va2000, mmap 4 MB, set the mode
 *     signon = (byte *) calloc(320*200, 1);  // 64000 bytes of FRESH anon memory
 *     fread(signon, 320*200, 1, file);       // ONE 64000-byte read into it
 *
 * A large read into untouched anon pages makes uiomove fault the SOURCE (segmap) and the
 * DESTINATION (anon) alternately, page by page, with a segdev mapping live in the same address
 * space.  Nothing in sweeps 1-4 produced that interleaving.
 *
 * THE CASES, and what each one distinguishes
 *   1  fresh buffer, 64000, no device mapping    the read shape alone
 *   2  PRE-TOUCHED buffer, 64000                 CONTROL: if 1 wedges and 2 does not, the trigger
 *                                                is destination-page faulting, not size
 *   3  fresh buffer, 64000, /dev/va2000 mapped   the full wolf3d shape
 *   4  fresh buffer, 4096 / 8192 / 32768         bisect the size at which it starts
 *   5  fresh mmap'd (not malloc'd) destination   distinguishes brk-anon from mmap-anon
 *
 * Each case gets a FRESH destination via a fresh mmap of /dev/zero, so "untouched" is guaranteed
 * rather than hoped for -- malloc can hand back a block whose pages an earlier free() already
 * faulted in, which would silently turn every case into case 2.
 *
 * IT WILL WEDGE THE MACHINE if the hypothesis holds, and the loop is inside the kernel, so unlike
 * ISSUE-9's user-space flood it CANNOT be killed -- it needs the reset switch.  Progress is
 * therefore printed before each attempt and also written to a synced state file on `/` (never
 * /tmp, which every AMIX boot clears).
 *
 * COLD FILE REQUIRED: pass a file nothing has read since boot, at least 256 KB.
 *
 * usage: readfresh <file> [statefile]
 *
 * 68060 (ISSUE-34a): no `%`, no division by a constant.  K&R C for the AMIX native cc.
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <errno.h>

#define VA2000_SIZE 0x00400000L

long  c_len[]  = { 64000L, 64000L, 64000L,  4096L,  8192L, 32768L, 64000L };
int   c_touch[]= {      0,      1,      0,      0,      0,      0,      0 };
int   c_dev[]  = {      0,      0,      1,      0,      0,      0,      0 };
int   c_mmapd[]= {      1,      1,      1,      1,      1,      1,      0 };
char *c_why[]  = {
	"fresh untouched dest, 64000 -- the SignonScreen shape",
	"CONTROL: same size, dest PRE-TOUCHED first",
	"fresh dest + /dev/va2000 mapped 4 MB -- the FULL wolf3d shape",
	"fresh dest, 4096 -- size bisect",
	"fresh dest, 8192 -- size bisect",
	"fresh dest, 32768 -- size bisect",
	"fresh dest from malloc instead of mmap -- brk-anon vs mmap-anon"
};
#define NCASES 7

char *
fresh_dest(len, usemmap)
long len;
int usemmap;
{
	int zfd;
	char *p;

	if (!usemmap)
		return ((char *) malloc((unsigned) len));
	/* MAP_ANON does not exist on this SVR4, so /dev/zero is the portable fresh-anon route */
	zfd = open("/dev/zero", O_RDWR);
	if (zfd < 0)
		return ((char *) 0);
	p = (char *) mmap((caddr_t) 0, (size_t) len, PROT_READ | PROT_WRITE,
			  MAP_PRIVATE, zfd, (off_t) 0);
	(void) close(zfd);
	if (p == (char *) -1)
		return ((char *) 0);
	return (p);
}

main(argc, argv)
int argc;
char **argv;
{
	char *path, *statepath, *dst, *board;
	int fd, sfd, vfd, i;
	long off, len, got, fsize;
	char line[256];

	if (argc < 2) {
		printf("usage: readfresh <file> [statefile]\n");
		exit(2);
	}
	path = argv[1];
	statepath = (argc > 2) ? argv[2] : "/readfresh.state";

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("READFRESH ERR cannot open %s\n", path);
		exit(1);
	}
	fsize = lseek(fd, 0L, 2);
	if (fsize < 262144L) {
		printf("READFRESH ERR %s is %ld bytes; want >= 262144 and COLD\n", path, fsize);
		exit(1);
	}
	sfd = open(statepath, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	printf("READFRESH file=%s size=%ld state=%s\n", path, fsize, statepath);
	printf("READFRESH sweeps 1-4 all read into an ALREADY-RESIDENT buffer; this one does not.\n");
	printf("READFRESH the wedged process was at libc read+4, so the loop is inside a read(2).\n");
	fflush(stdout);

	off = 0L;
	for (i = 0; i < NCASES; i++) {
		len = c_len[i];

		sprintf(line, "READFRESH TRY case=%d len=%ld touch=%d dev=%d mmap=%d off=%ld  %s\n",
			i, len, c_touch[i], c_dev[i], c_mmapd[i], off, c_why[i]);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
			sleep(1);
			sync();
		}

		board = (char *) 0;
		vfd = -1;
		if (c_dev[i]) {
			vfd = open("/dev/va2000", O_RDWR);
			if (vfd >= 0) {
				board = (char *) mmap((caddr_t) 0, (size_t) VA2000_SIZE,
						      PROT_READ | PROT_WRITE, MAP_SHARED,
						      vfd, (off_t) 0);
				if (board == (char *) -1)
					board = (char *) 0;
			}
			printf("READFRESH   /dev/va2000 mapped at %lx\n",
			       (long) board);
			fflush(stdout);
		}

		dst = fresh_dest(len, c_mmapd[i]);
		if (dst == (char *) 0) {
			printf("READFRESH ERR case=%d cannot get a destination buffer\n", i);
			break;
		}
		if (c_touch[i]) {
			/* the control: fault every destination page IN ADVANCE, so the read cannot
			 * fault the destination at all and only the source side is exercised */
			for (got = 0L; got < len; got += 4096L)
				dst[got] = 0;
			dst[len - 1] = 0;
		}

		if (lseek(fd, off, 0) != off) {
			printf("READFRESH ERR lseek %ld\n", off);
			break;
		}
		got = (long) read(fd, dst, (unsigned) len);

		sprintf(line, "READFRESH OK  case=%d got=%ld first=%02x last=%02x\n",
			i, got, dst[0] & 0xff, (got > 0) ? (dst[got - 1] & 0xff) : 0);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
		}

		if (c_mmapd[i])
			(void) munmap((caddr_t) dst, (size_t) len);
		if (board != (char *) 0)
			(void) munmap((caddr_t) board, (size_t) VA2000_SIZE);
		if (vfd >= 0)
			(void) close(vfd);

		/* advance well past what this case read, so the next case is cold too */
		off = off + len + 65536L;
		if (off + 65536L > fsize)
			off = 0L;
	}

	printf("READFRESH-DONE all %d cases returned.  Untouched-destination reads are NOT the\n", NCASES);
	printf("READFRESH      trigger either.  What is still untested from SignonScreen: the mode\n");
	printf("READFRESH      REGISTER WRITES that precede it (VL_SetVGAPlaneMode writes the VA2000\n");
	printf("READFRESH      timing registers through the mapping before any read happens), and\n");
	printf("READFRESH      stdio's own buffering rather than a bare read(2).\n");
	fflush(stdout);
	if (sfd >= 0)
		(void) close(sfd);
	(void) close(fd);
	exit(0);
}
