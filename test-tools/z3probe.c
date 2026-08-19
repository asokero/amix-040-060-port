/* z3probe.c -- is a Zorro III aperture reachable from a CPU mapping at all?
 *
 * THE QUESTION.  Every Zorro III driver problem this project has had could be
 * one of three things: the kernel mapping mechanism, the address space itself,
 * or the card's own Zorro III firmware.  Swapping the VA2000's firmware opens
 * all three at once, and a failure then cannot be attributed to any one of them.
 *
 * This machine happens to make that unnecessary.  It carries a Piccolo whose RAM
 * board is jumpered into ZORRO III space -- the loader's board dump reports
 * 0893:05 at 0x40000000, 16 MB -- at the same time as the VA2000 sits in Zorro
 * II.  So the address space can be tested with a card that is already there.
 *
 * WHY /dev/mem AND NOT A DRIVER.  Nothing can open the Piccolo under AMIX while
 * it is in Zorro III mode: its driver dereferences the board address directly,
 * which is the whole defect.  /dev/mem's mmap entry point returns a 4 KiB PFN on
 * this kernel (converted by patch_devmmap2.py, sites 0x20688/0x2068e -- checked,
 * not assumed), so mapping offset X lands on physical X.
 *
 * WHY USERSPACE.  A kernel probe that touched an unresponsive aperture would
 * bus-error in supervisor mode and panic.  Here it kills one process, and this
 * program catches the fault so that "no response" is a RESULT rather than a
 * crash.
 *
 * IT CATCHES BOTH SIGBUS AND SIGSEGV, and its output is UNBUFFERED.  Both were
 * learned the hard way on 2026-08-19: the first version caught only SIGBUS and
 * buffered its output, so a fatal access produced an empty log and no core --
 * an instrument that dies without saying what it was doing tells you nothing.
 * Unbuffered output means the line naming the access survives the access.
 *
 * SELF-VERIFYING.  It never trusts the mapping without checking it first: it
 * maps a physical address whose contents it can obtain independently (through
 * lseek + read on the same /dev/mem) and requires the two to agree.  If they do
 * not, the mapping is not landing where asked and nothing below it means
 * anything.
 *
 * usage: z3probe [hex-phys-addr]        default 40000000
 *
 * K&R C for the AMIX SVR4 native cc.  cc -o z3probe z3probe.c
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <setjmp.h>
#include <stdio.h>

#define PAGESZ     4096
#define KNOWNPHYS  0x08000000L      /* kernel load base -- readable, and stable */

static jmp_buf busjmp;
static int     bushit;
static int     bussig;

static void
onbus(sig)
int sig;
{
    bushit = 1;
    bussig = sig;
    longjmp(busjmp, 1);
}

static void
armfault()
{
    signal(SIGBUS, onbus);
    signal(SIGSEGV, onbus);
}

/* Read one long from physical addr the OTHER way: lseek + read, no mapping. */
static unsigned long
peek(fd, addr)
int fd;
unsigned long addr;
{
    unsigned long v;

    if (lseek(fd, (long)addr, 0) == -1L) return 0xDEAD0001L;
    if (read(fd, (char *)&v, 4) != 4)    return 0xDEAD0002L;
    return v;
}

main(argc, argv)
int argc;
char **argv;
{
    int fd;
    unsigned long phys;
    unsigned long viaread, viamap, wrote, back;
    volatile unsigned long *p;
    char *m;

    setbuf(stdout, (char *)0);          /* every line must survive a fatal access */
    phys = 0x40000000L;
    if (argc > 1) sscanf(argv[1], "%lx", &phys);

    fd = open("/dev/mem", O_RDWR);
    if (fd < 0) {
        printf("Z3 cannot open /dev/mem: errno=%d\n", errno);
        exit(3);
    }

    /* ---- step 1: prove the mapping lands where we ask -------------------- */
    m = (char *)mmap((caddr_t)0, PAGESZ, PROT_READ, MAP_SHARED,
                     fd, (off_t)KNOWNPHYS);
    if (m == (char *)-1) {
        printf("Z3 SELFTEST mmap(%08lx) failed errno=%d -- cannot verify the instrument\n",
               KNOWNPHYS, errno);
        exit(3);
    }
    viaread = peek(fd, KNOWNPHYS);
    armfault();
    bushit = 0;
    viamap = 0;
    if (setjmp(busjmp) == 0)
        viamap = *(volatile unsigned long *)m;
    munmap((caddr_t)m, PAGESZ);
    if (bushit) {
        printf("Z3 SELFTEST FAULT sig=%d reading mapped %08lx -- instrument unusable\n",
               bussig, KNOWNPHYS);
        exit(3);
    }
    printf("Z3 selftest phys %08lx: lseek=%08lx mmap=%08lx  %s\n",
           KNOWNPHYS, viaread, viamap,
           (viaread == viamap) ? "AGREE" : "DISAGREE");
    if (viaread != viamap) {
        printf("Z3 the mapping is not landing where asked; nothing below is meaningful\n");
        exit(3);
    }

    /* ---- step 2: the Zorro III aperture ---------------------------------- */
    m = (char *)mmap((caddr_t)0, PAGESZ, PROT_READ | PROT_WRITE, MAP_SHARED,
                     fd, (off_t)phys);
    if (m == (char *)-1) {
        printf("Z3 mmap(%08lx) FAILED errno=%d\n", phys, errno);
        exit(1);
    }
    printf("Z3 mapped phys %08lx at %08lx\n", phys, (unsigned long)m);

    p = (volatile unsigned long *)m;
    printf("Z3 READ  %08lx  attempting...\n", phys);
    armfault();
    bushit = 0;
    back = 0;
    if (setjmp(busjmp) == 0)
        back = *p;
    if (bushit) {
        printf("Z3 READ  %08lx -> FAULT sig=%d (aperture does not respond)\n",
               phys, bussig);
        munmap((caddr_t)m, PAGESZ);
        exit(1);
    }
    printf("Z3 READ  %08lx -> %08lx\n", phys, back);

    wrote = 0x5A3C96E7L;
    printf("Z3 WRITE %08lx  attempting...\n", phys);
    armfault();
    bushit = 0;
    if (setjmp(busjmp) == 0) {
        *p = wrote;
        back = *p;
    }
    if (bushit) {
        printf("Z3 WRITE %08lx -> FAULT sig=%d\n", phys, bussig);
        munmap((caddr_t)m, PAGESZ);
        exit(1);
    }
    printf("Z3 WRITE %08lx = %08lx, readback %08lx  %s\n",
           phys, wrote, back, (back == wrote) ? "MATCH" : "MISMATCH");

    /* A second, different pattern: one match could be a coincidence if the
     * aperture happened to already hold that value. */
    wrote = 0xA5C36918L;
    armfault();
    bushit = 0;
    if (setjmp(busjmp) == 0) {
        *p = wrote;
        back = *p;
    }
    if (!bushit)
        printf("Z3 WRITE %08lx = %08lx, readback %08lx  %s\n",
               phys, wrote, back, (back == wrote) ? "MATCH" : "MISMATCH");

    munmap((caddr_t)m, PAGESZ);
    close(fd);
    printf("Z3-DONE\n");
    exit(back == wrote ? 0 : 1);
}
