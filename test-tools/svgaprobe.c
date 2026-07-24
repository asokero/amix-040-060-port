/* svgaprobe.c - probe the Xsvga kernel driver: open /dev/svgaN and read the
 * board data via SVGAIOCGetBoardData.  Confirms our ld -r'd exp driver is
 * registered (cdevsw major 67) AND detects the emulated Piccolo Zorro-II.
 *
 * K&R C for the AMIX SVR4 native cc.  Compile:  cc -o svgaprobe svgaprobe.c
 *
 * Expected on the Piccolo Z2 Amiberry config: CardID = 3 (SVGACARDID_Piccolo).
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define SVGAIOCGetBoardData	0xe302

struct SVGABoardData {
	long  CardID;
	long  FrameBufSize;
	short MaxPixClk;
	short HasBlitter;
	short HasPanning;
	short Colors;
	short HasHWCursor;
	short reserved1;
	long  reserved2[4];
};

char *cardname(id)
long id;
{
	switch (id) {
	case 1:  return "PicassoII";
	case 2:  return "PicassoII_Seg";
	case 3:  return "Piccolo";
	case 4:  return "Piccolo_Z3";
	case 5:  return "Spectrum";
	case 9:  return "Domino32K";
	case 11: return "OmniBus";
	case 12: return "Merlin";
	default: return "?";
	}
}

main(argc, argv)
int argc;
char **argv;
{
	int fd;
	char *dev;
	struct SVGABoardData bd;

	dev = (argc > 1) ? argv[1] : "/dev/svga0";

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		printf("SVGAPROBE open %s FAILED errno=%d\n", dev, errno);
		exit(1);
	}
	printf("SVGAPROBE open %s OK fd=%d\n", dev, fd);

	bd.CardID = -1;
	if (ioctl(fd, SVGAIOCGetBoardData, &bd) < 0) {
		printf("SVGAPROBE ioctl GetBoardData FAILED errno=%d\n", errno);
		close(fd);
		exit(2);
	}
	printf("SVGAPROBE CardID=%ld (%s) FrameBufSize=%ld MaxPixClk=%d Blitter=%d Panning=%d\n",
	    bd.CardID, cardname(bd.CardID), bd.FrameBufSize,
	    bd.MaxPixClk, bd.HasBlitter, bd.HasPanning);
	close(fd);
	exit(0);
}
