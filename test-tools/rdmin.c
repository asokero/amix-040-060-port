/* rdmin -- minimal isolation: mmap an NFS file of NON-page-multiple length, touch 3 bytes. */
#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/mman.h>
main(argc, argv)
int argc; char **argv;
{
	int fd; char *p; long sz;
	sz = atol(argv[2]);
	printf("RDMIN open %s sz=%ld\n", argv[1], sz);
	fflush(stdout);
	fd = open(argv[1], O_RDONLY);
	if (fd < 0) { printf("RDMIN open failed\n"); exit(1); }
	p = (char *) mmap((caddr_t)0, (size_t)sz, PROT_READ, MAP_PRIVATE, fd, (off_t)0);
	printf("RDMIN mmap p=%x\n", (int)p);
	fflush(stdout);
	if (p == (char *)-1) { printf("RDMIN mmap failed\n"); exit(1); }
	printf("RDMIN p[0]=%d\n", (int)(unsigned char)p[0]);
	fflush(stdout);
	printf("RDMIN p[4096]=%d\n", (int)(unsigned char)p[4096]);
	fflush(stdout);
	printf("RDMIN p[sz-1]=%d\n", (int)(unsigned char)p[sz-1]);
	fflush(stdout);
	printf("RDMIN-DONE\n");
	exit(0);
}
