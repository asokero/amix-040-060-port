/* msynctst.c -- exercise the segvn_sync -> ufs_putpage writeback path.
 * K&R C for the AMIX SVR4 native cc (no ANSI prototypes, vars at top).
 * mmap MAP_SHARED a file, dirty every page, msync(MS_SYNC), then read the
 * file back with regular read() and verify the dirty mmap pages made it
 * through the writeback path.  Prints MSYNC-OK / MSYNC-FAIL.
 */
#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>

#define SZ   65536
#define PAT  0xA5

main(argc, argv)
int argc;
char **argv;
{
	int fd;
	char *m;
	int i;
	int bad;
	char *path;
	static char buf[SZ];

	path = (argc > 1) ? argv[1] : "/msync_test.dat";

	fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("open"); exit(1); }

	/* grow the backing file to SZ bytes */
	if (lseek(fd, (long)(SZ - 1), 0) < 0) { perror("lseek"); exit(1); }
	if (write(fd, "", 1) != 1) { perror("write-grow"); exit(1); }

	m = (char *) mmap((char *)0, SZ, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (m == (char *)-1) { perror("mmap"); exit(1); }

	/* dirty every page of the shared mapping */
	for (i = 0; i < SZ; i++)
		m[i] = (char)((i + PAT) & 0xff);

	/* force the dirty pages out: segvn_sync -> VOP_PUTPAGE (the converted path) */
	if (msync(m, (unsigned)SZ, MS_SYNC) < 0) { perror("msync"); exit(1); }
	(void) munmap(m, SZ);

	/* verify via regular read() that the writeback reached the file */
	if (lseek(fd, 0L, 0) < 0) { perror("lseek0"); exit(1); }
	if (read(fd, buf, SZ) != SZ) { perror("read"); exit(1); }
	(void) close(fd);

	bad = 0;
	for (i = 0; i < SZ; i++)
		if ((buf[i] & 0xff) != ((i + PAT) & 0xff))
			bad++;

	if (bad == 0)
		printf("MSYNC-OK path=%s sz=%d\n", path, SZ);
	else
		printf("MSYNC-FAIL bad=%d path=%s\n", bad, path);

	exit(bad ? 1 : 0);
}
