/* segmaprep.c -- find the read offset that wedges the kernel in an as_fault loop.
 *
 * THE BUG THIS HUNTS (ISSUE-37, found by wolf3d on real hardware 2026-07-28)
 * Starting wolf3d wedges the machine: the VA2000 screen goes black, the network dies, virtual
 * consoles still switch but accept no input.  The serial log says it is NOT a crash -- it is an
 * infinite kernel fault loop, 8192+ iterations and counting:
 *
 *   DBG as_fault STREAM pid=186 addr=408F4FFF upc=C1013088 type=0 ret=0
 *   DBG as_fault REPEAT pid=186 addr=408F4FFF upc=C1013088 type=0 ret=0 n=2000
 *
 * Read that carefully, because every field matters:
 *   ret=0     the resolver reports SUCCESS, and the same address faults again anyway.
 *   type=0    F_INVAL -- a not-present page, not a protection violation.
 *   addr      0x408F4FFF is a KERNEL address: kvsegmap (the segmap file-I/O window) starts at
 *             0x40440000, kvseg heap is [0x40040000,0x40440000).  So this is the kernel touching
 *             its own file window on a user's behalf, i.e. inside read().
 *   ...FFF    the LAST BYTE of a 4 KiB page.  That is the fingerprint this program chases.
 *   upc       constant, in the shared-library range: the user process is stuck in libc's read().
 *
 * WHY IT MUST BE THE SEGMENT PROVIDER, not as_fault and not segkmem
 *   as_fault (0xae108) rounds correctly -- `andiw #-4096` clears the low 12 bits of a 32-bit
 *   address, a valid 4 KiB round-down -- and it returns whatever the segment's fault op returned.
 *   segkmem_fault (0xa83d6) CANNOT return 0 for type=0: it returns 0 only for F_SOFTLOCK(2) and
 *   F_SOFTUNLOCK(3) and -1 otherwise.  segmap_fault (0xa9116) CAN: it asks VOP_GETPAGE for a page
 *   list, then maps only those returned pages whose p_offset falls in [fault_off, fault_off+len),
 *   and if that set is EMPTY it maps nothing and still returns 0.  A provider whose page offsets
 *   are off by a page hands segmap_fault an empty set, and the fault loops forever with ret=0.
 *   That is the Model-B producer/consumer asymmetry again (ISSUE-27's family): provider on one
 *   page grid, consumer on the other.  wolf3d's files live on the root UFS, and Codex's census
 *   lists UFS as 12 unconverted sites.
 *
 * WHY WOLF3D AND NOT EVERYTHING ELSE
 * wolf3d is the only program on this machine that reads at ARBITRARY byte offsets:
 * id_pm_amiga.c's PML_ReadFromFile(buf, offset, length) seeks straight to a VSWAP chunk offset
 * from the file's own table, and id_ca.c does the same in a dozen places.  cc, X and the shell
 * read sequentially from zero -- and a sequential reader touches byte 0 of a slot FIRST, which
 * maps the page, so it never asks for the last byte of an unmapped page.  That is the whole
 * difference, and it is why a working system can hide this for months.
 *
 * WHAT THIS PROGRAM DOES
 * One single-byte read per 8 KiB segmap slot, so that EVERY read is the first touch of its slot,
 * at a controlled offset within it.  Sweeping the offset over the page and half-page boundaries
 * asks the kernel exactly one question: which within-slot offsets are resolvable?
 *
 * IT WILL WEDGE THE MACHINE when it finds the answer.  That is the point, and it is why the
 * progress record is written TWICE before each attempt:
 *   1. to stdout with fflush -- printed before the fatal read, so it drains normally;
 *   2. to a state file plus sync(), sleep(1), sync() -- so the answer survives the hard reset
 *      you will need.  The pause is not decoration: sync() only SCHEDULES the write-out, and a
 *      machine that wedges microseconds later can leave the record still in the buffer cache.
 * After the reset: cat the state file.  The last line names the offset that wedged it.
 * The state file defaults to `/` and NOT to /tmp, because /tmp is CLEARED ON EVERY AMIX BOOT --
 * putting the record there would delete exactly the answer the reboot was meant to preserve.
 *
 * COLD PAGES ARE THE WHOLE EXPERIMENT.  The loop needs a NOT-PRESENT segmap page, so the file
 * must not already be in the page cache.  Use a file nothing has read since boot, and prefer a
 * fresh boot.  Reading the same file twice proves nothing the second time.
 *
 * usage: segmaprep <file> [statefile]        file must be > 256 KB, on UFS, and COLD
 *        statefile defaults to /segmaprep.state (persistent; /tmp is wiped on boot)
 *
 * 68060 NOTE (ISSUE-34a): no `/` by a constant and no `%` anywhere -- gcc turns those into the
 * 64-bit muls.l/divs.l forms the 68060 does not implement, which would kill this program on the
 * CPU we may want it on most.  Offsets here are built with shifts and adds only.
 *
 * K&R C for the AMIX native cc.  cc -o segmaprep segmaprep.c
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>

#define SLOTSHIFT 13              /* MAXBSIZE 8192 = one segmap slot; segmap_fault uses >>13 */
#define SLOTSIZE  8192L

/* Within-slot offsets to probe, in the order that makes the result readable.
 * The two page-tail entries (4095, 8191) are the primary suspects: they are the last byte of
 * their 4 KiB page, which is what the hardware log showed.  2047/2048 are the OLD page geometry's
 * boundary and are here to tell a 2 KiB-grid provider apart from something else entirely.
 * 0 must always pass -- if it does not, the fault is not offset-dependent and this whole model
 * is wrong, which is worth knowing in the first second of the run. */
long probes[] = { 0L, 1L, 2047L, 2048L, 2049L, 4094L, 4095L, 4096L, 4097L, 6143L, 8190L, 8191L };
#define NPROBES 12

char *names[] = {
	"slot base (MUST pass -- control)",
	"slot base + 1",
	"2 KiB - 1   (old page tail)",
	"2 KiB       (old page base)",
	"2 KiB + 1",
	"4 KiB - 2",
	"4 KiB - 1   *** page tail -- matches addr=...FFF from the hardware log ***",
	"4 KiB       (second page base)",
	"4 KiB + 1",
	"6 KiB - 1   (old grid tail inside page 2)",
	"8 KiB - 2",
	"8 KiB - 1   *** page tail of page 2 ***"
};

main(argc, argv)
int argc;
char **argv;
{
	char *path, *statepath;
	int fd, sfd, i;
	long off, slot, fsize;
	char buf[8];
	char line[256];

	if (argc < 2) {
		printf("usage: segmaprep <file> [statefile]\n");
		printf("  file must be >256 KB, on UFS, and NOT read since boot (COLD)\n");
		exit(2);
	}
	path = argv[1];
	statepath = (argc > 2) ? argv[2] : "/segmaprep.state";  /* NOT /tmp: wiped every boot */

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("SEGMAPREP ERR cannot open %s\n", path);
		exit(1);
	}
	fsize = lseek(fd, 0L, 2);            /* SEEK_END */
	if (fsize < (SLOTSIZE * (long) (NPROBES + 2))) {
		printf("SEGMAPREP ERR %s is only %ld bytes; need > %ld\n",
		       path, fsize, SLOTSIZE * (long) (NPROBES + 2));
		exit(1);
	}

	/* The state file is opened and written before any probe read, so its own pages are already
	 * resident and writing it cannot itself be the thing that wedges. */
	sfd = open(statepath, O_WRONLY | O_CREAT | O_TRUNC, 0644);

	printf("SEGMAPREP file=%s size=%ld state=%s\n", path, fsize, statepath);
	printf("SEGMAPREP one 1-byte read per 8 KiB slot, each read the FIRST touch of its slot\n");
	printf("SEGMAPREP if the machine wedges, the LAST line below is the offset that did it\n");
	fflush(stdout);

	for (i = 0; i < NPROBES; i++) {
		/* slot i+1, not slot 0: slot 0 holds the file header that anything opening this file
		 * may already have paged in, which would make the first probe warm and useless. */
		slot = (long) (i + 1) << SLOTSHIFT;
		off = slot + probes[i];

		sprintf(line, "SEGMAPREP TRY slot=%ld within=%ld off=%ld  %s\n",
			slot, probes[i], off, names[i]);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();                  /* survive the hard reset this may require */
			sleep(1);                /* sync() only SCHEDULES the write-out */
			sync();
		}

		if (lseek(fd, off, 0) != off) {   /* SEEK_SET */
			printf("SEGMAPREP ERR lseek to %ld failed\n", off);
			break;
		}
		buf[0] = 0;
		if (read(fd, buf, 1) != 1) {
			printf("SEGMAPREP ERR read at %ld failed\n", off);
			break;
		}

		sprintf(line, "SEGMAPREP OK  off=%ld byte=%02x\n", off, buf[0] & 0xff);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			sync();
		}
	}

	printf("SEGMAPREP-DONE all %d probes resolved -- the fault is NOT a plain\n", NPROBES);
	printf("SEGMAPREP      first-touch-at-offset case.  Next: the read LENGTH, not the offset\n");
	printf("SEGMAPREP      (wolf3d reads arbitrary lengths too), or a multi-page read that\n");
	printf("SEGMAPREP      spans slots.  Re-run with a bigger sweep before doubting the model.\n");
	fflush(stdout);
	if (sfd >= 0)
		(void) close(sfd);
	(void) close(fd);
	exit(0);
}
