/* va2000probe.c - probe the MNT VA2000 kernel driver: open /dev/va2000 and
 * report errno.  On the emulator (no VA2000 board -- Zorro board is not
 * emulatable in Amiberry) the driver's autocon() lookup fails and
 * va2000open() returns ENXIO; a clean ENXIO (not a hang/panic) proves the
 * driver is registered (cdevsw major 68) and wired to the real autocon()
 * kernel routine without crashing.  On the real A3000 + VA2000 board this
 * same probe should open successfully (errno 0) and read VA2IOC_GETFW.
 *
 * K&R C for the AMIX SVR4 native cc.  Compile:  cc -o va2000probe va2000probe.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define VA2IOC		('V' << 8)
#define VA2IOC_GETFW	(VA2IOC | 1)

main()
{
	int fd;
	int fw;

	errno = 0;
	fd = open("/dev/va2000", O_RDWR, 0);
	if (fd < 0) {
		printf("open(/dev/va2000) failed: errno=%d\n", errno);
		if (errno == ENXIO)
			printf("ENXIO -- clean 'no board' result (expected on emulator)\n");
		exit(errno == ENXIO ? 0 : 1);
	}

	printf("open(/dev/va2000) OK, fd=%d\n", fd);
	if (ioctl(fd, VA2IOC_GETFW, &fw) < 0) {
		printf("ioctl VA2IOC_GETFW failed: errno=%d\n", errno);
		close(fd);
		exit(1);
	}
	printf("VA2000 firmware version = %d\n", fw);
	close(fd);
	exit(0);
}
