/*
 * monswtest.c -- exercise SVGAIOCSetMonitorSwitch on /dev/va2000, one step per run.
 *
 * WHY ONE STEP PER RUN.  The only instrument for this test is the screen, and a human has to
 * look at it between steps.  A program that did all three in sequence would leave nothing to
 * see.  So: run it, look, run the next one.
 *
 *   monswtest get      read the switch back
 *   monswtest amiga    Set = 1: expect the native Amiga picture
 *   monswtest svga     Set = 2: expect the RTG picture the last mode set put there
 *   monswtest bad      Set = 3: expect EINVAL and NO change on screen
 *
 * It does not mmap and it does not read the framebuffer -- see ISSUE-70 in the port, where a
 * whole-framebuffer read wedged the machine twice out of two.  Registers only.
 *
 * K&R C for the guest's 1991 cc:  cc -o monswtest monswtest.c
 */

#include <stdio.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>

#define SVGAIOC                 (0xe300)
#define SVGAIOCGetMonitorSwitch (SVGAIOC|0x06)
#define SVGAIOCSetMonitorSwitch (SVGAIOC|0x08)

#define SVGAMONITORSWITCH_Amiga 1
#define SVGAMONITORSWITCH_SVGA  2

main(argc, argv)
int argc;
char **argv;
{
    int fd;
    int rc;
    unsigned short sw;
    char *what;

    if (argc != 2) {
        printf("usage: monswtest get|amiga|svga|bad\n");
        exit(2);
    }
    what = argv[1];

    fd = open("/dev/va2000", O_RDWR);
    if (fd < 0) {
        perror("open /dev/va2000");
        exit(1);
    }

    if (strcmp(what, "get") == 0) {
        sw = 0;
        rc = ioctl(fd, SVGAIOCGetMonitorSwitch, &sw);
        if (rc < 0) {
            perror("MONSW-GET");
            printf("MONSW-RESULT GET FAIL\n");
            exit(1);
        }
        printf("MONSW-RESULT GET %d   (1 = Amiga, 2 = SVGA)\n", (int)sw);
        exit(0);
    }

    if (strcmp(what, "amiga") == 0)      sw = SVGAMONITORSWITCH_Amiga;
    else if (strcmp(what, "svga") == 0)  sw = SVGAMONITORSWITCH_SVGA;
    else if (strcmp(what, "bad") == 0)   sw = 3;
    else {
        printf("usage: monswtest get|amiga|svga|bad\n");
        exit(2);
    }

    errno = 0;
    rc = ioctl(fd, SVGAIOCSetMonitorSwitch, &sw);

    /* `bad` is the one case where a failure is the pass: an unknown value must be refused
     * rather than stored.  Reported as its own line so the battery cannot read it as an error. */
    if (strcmp(what, "bad") == 0) {
        if (rc < 0 && errno == EINVAL)
            printf("MONSW-RESULT BAD PASS (EINVAL, as it should be)\n");
        else if (rc < 0)
            printf("MONSW-RESULT BAD FAIL (refused, but errno %d not EINVAL)\n", errno);
        else
            printf("MONSW-RESULT BAD FAIL (accepted value 3)\n");
        exit(0);
    }

    if (rc < 0) {
        perror("MONSW-SET");
        printf("MONSW-RESULT %s FAIL\n", what);
        exit(1);
    }
    printf("MONSW-RESULT %s SET-OK -- now look at the screen\n", what);
    exit(0);
}
