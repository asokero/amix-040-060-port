/* pmrep.c -- ISSUE-37 sweep 3: run wolf3d's page-manager loader WITHOUT wolf3d.
 *
 * Sweeps 1 and 2 both came back clean (26 synthetic read cases: every within-slot offset, every
 * misalignment, straddles across page and slot boundaries, spans up to 64 KB).  And vamap proved
 * user mmap lands at 0xc1033000, so the looping fault address 0x408F4FFF really is kernel-side
 * and really is not the mapped VA2000 aperture.
 *
 * So instead of inventing a 27th synthetic case, this reproduces the ACTUAL access pattern:
 * id_pm_amiga.c's PM_Startup reads VSWAP's chunk directory and then calls
 * PML_ReadFromFile(buf, offset, length) once per chunk -- roughly 1500 seeks to arbitrary byte
 * offsets with arbitrary lengths, covering the whole 1.5 MB file.  Nothing else on this machine
 * does that.  No graphics, no FPU, no fork, no malloc churn: if the loader path alone wedges the
 * kernel, this wedges it, and then ISSUE-37 has a repro with none of wolf3d attached.
 *
 * VSWAP is a DOS file, so its directory is little-endian and must be byte-swapped on m68k --
 * decoded here byte-by-byte rather than by casting, which would silently read big-endian.
 *
 * Progress goes to stdout with fflush BEFORE each read, so the last line captured names the
 * chunk that wedged.  The state file is synced every 16 chunks (a sync per chunk would dominate
 * the runtime and change the very timing we are trying to reproduce).
 *
 * usage: pmrep <vswap file> [statefile]
 * 68060 (ISSUE-34a): no `%` and no division by a constant.  K&R C for the native cc.
 */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>

#define MAXCHUNK 65536

unsigned char dirbuf[8192];
unsigned char data[MAXCHUNK + 16];
long offs[2048];
long lens[2048];

long
u16le(b)
unsigned char *b;
{
	return ((long) b[0] | ((long) b[1] << 8));
}

long
u32le(b)
unsigned char *b;
{
	return ((long) b[0] | ((long) b[1] << 8) | ((long) b[2] << 16) | ((long) b[3] << 24));
}

main(argc, argv)
int argc;
char **argv;
{
	int fd, sfd, i;
	long chunks, spritestart, soundstart, n, got, syncctr;
	char line[200];

	if (argc < 2) {
		printf("usage: pmrep <vswap.wl6> [statefile]\n");
		exit(2);
	}
	fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		printf("PMREP ERR open %s\n", argv[1]);
		exit(1);
	}
	sfd = open((argc > 2) ? argv[2] : "/pmrep.state", O_WRONLY | O_CREAT | O_TRUNC, 0644);

	if (read(fd, (char *) dirbuf, 6) != 6) {
		printf("PMREP ERR short header\n");
		exit(1);
	}
	chunks      = u16le(&dirbuf[0]);
	spritestart = u16le(&dirbuf[2]);
	soundstart  = u16le(&dirbuf[4]);
	printf("PMREP chunks=%ld spritestart=%ld soundstart=%ld\n", chunks, spritestart, soundstart);
	if (chunks < 1L || chunks > 2048L) {
		printf("PMREP ERR implausible chunk count -- byte order wrong?\n");
		exit(1);
	}

	n = chunks << 2;
	if (read(fd, (char *) dirbuf, (unsigned) n) != (int) n) {
		printf("PMREP ERR short offset table\n");
		exit(1);
	}
	for (i = 0; i < (int) chunks; i++)
		offs[i] = u32le(&dirbuf[i << 2]);

	n = chunks << 1;
	if (read(fd, (char *) dirbuf, (unsigned) n) != (int) n) {
		printf("PMREP ERR short length table\n");
		exit(1);
	}
	for (i = 0; i < (int) chunks; i++)
		lens[i] = u16le(&dirbuf[i << 1]);

	printf("PMREP directory read; now one seek+read per chunk, exactly as PML_ReadFromFile\n");
	fflush(stdout);

	syncctr = 0L;
	for (i = 0; i < (int) chunks; i++) {
		if (offs[i] == 0L)                 /* sparse chunk: the original Quit()s on these */
			continue;
		if (lens[i] <= 0L || lens[i] > (long) MAXCHUNK)
			continue;

		sprintf(line, "PMREP i=%d off=%ld len=%ld\n", i, offs[i], lens[i]);
		printf("%s", line);
		fflush(stdout);
		if (sfd >= 0) {
			(void) write(sfd, line, strlen(line));
			syncctr = syncctr + 1L;
			if (syncctr >= 16L) {          /* sync every 16, not every chunk: a sync per */
				sync();                /* chunk would dominate and alter the timing */
				syncctr = 0L;
			}
		}

		if (lseek(fd, offs[i], 0) != offs[i]) {
			printf("PMREP ERR lseek %ld failed (i=%d)\n", offs[i], i);
			break;
		}
		got = (long) read(fd, (char *) data, (unsigned) lens[i]);
		if (got != lens[i]) {
			printf("PMREP ERR short read i=%d want=%ld got=%ld\n", i, lens[i], got);
			break;
		}
	}

	printf("PMREP-DONE the whole page directory loaded without wedging.\n");
	printf("PMREP      So the loader read path is NOT the trigger either, and what remains is\n");
	printf("PMREP      what this test deliberately leaves out: the 4 MB device mapping, the\n");
	printf("PMREP      ~2 MB anon working set (memory pressure -> segmap slot recycling), and\n");
	printf("PMREP      the second process.  Next step is the kernel probe, not another guess.\n");
	fflush(stdout);
	if (sfd >= 0) {
		sync();
		(void) close(sfd);
	}
	(void) close(fd);
	exit(0);
}
