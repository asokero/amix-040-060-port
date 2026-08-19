/* cmfcensus.c -- prove what the kernel actually put in a device leaf PTE.
 *
 * Zorro III change D gives a REGISTERED framebuffer page CM=0x60 (noncacheable,
 * not serialised) and leaves every other unmanaged page at CM=0x40 (noncacheable
 * SERIALISED).  This program checks that claim against the live page table
 * rather than against what the selector intended.
 *
 * HOW IT WORKS, and why it is shaped this way (audited 2026-08-19):
 *
 *   The kernel latches, for each class, the ADDRESS of the leaf PTE it just
 *   classified.  We map exactly ONE page of the device, touch it to force the
 *   fault, then read the latch and finally the live descriptor AT that address.
 *   So the evidence is the page table itself.
 *
 *   One page at a time, with everything else quiescent, because the latch is a
 *   SAMPLER: it holds the most recent leaf, and X11 faulting the same device
 *   would make it somebody else's.  STOP X BEFORE RUNNING THIS.
 *
 *   The counter delta must be POSITIVE, not exactly one: the retained 2 KiB
 *   segdev stepping can classify the same 4 KiB leaf twice (offsets 0 and 0x800
 *   resolve to the same page frame).  Requiring exactly one would fail correctly
 *   working code.
 *
 *   The census reads /dev/mem with lseek + read, NEVER mmap.  Mapping /dev/mem
 *   would itself create an unmanaged device mapping, bump the very counter being
 *   read and overwrite the very latch being read.  The instrument would perturb
 *   its own measurement.
 *
 *   One latched leaf describes 64 pages -- 256 KiB -- and nothing more.  It
 *   cannot be used to walk a whole aperture, and minimum/maximum leaf addresses
 *   do not repair that because page tables are not allocated in VA order.  Hence
 *   selected boundary pages, which is what the acceptance list actually asks for.
 *
 * usage: cmfcensus <cmf_magic-hex-addr> <device> <byte-offset> [more offsets...]
 *   e.g. cmfcensus 810aeac /dev/va2000 10000 200000 3ff000 0
 *   Get the address from `sh tools/status-facts.sh` on the build host.
 *
 * K&R C for the AMIX SVR4 native cc.  cc -o cmfcensus cmfcensus.c
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define CMF_MAGIC   0x434d4642L         /* "CMFB" */
#define PAGESZ      4096

/* block layout, longs: magic, fb_n, fb_leaf, ncs_n, ncs_leaf */
#define O_MAGIC     0
#define O_FB_N      1
#define O_FB_LEAF   2
#define O_NCS_N     3
#define O_NCS_LEAF  4

static int memfd = -1;

static unsigned long
peek(addr)
unsigned long addr;
{
    unsigned long v;

    if (lseek(memfd, (long)addr, 0) == -1L) {
        printf("CMF SEEKFAIL at %08lx errno=%d\n", addr, errno);
        return 0xFFFFFFFFL;
    }
    if (read(memfd, (char *)&v, 4) != 4) {
        printf("CMF READFAIL at %08lx errno=%d\n", addr, errno);
        return 0xFFFFFFFFL;
    }
    return v;
}

/* Decode the 040 cache mode from a leaf PTE: bits 6:5. */
static char *
cmname(pte)
unsigned long pte;
{
    switch (pte & 0x60L) {
    case 0x00L: return "WT  cacheable writethrough";
    case 0x20L: return "CB  cacheable copyback";
    case 0x40L: return "NCS noncacheable SERIALISED";
    default:    return "NC  noncacheable, not serialised";
    }
}

/* Fault one page of dev at offset and report which class its leaf got.
 * Returns 1 on a clean, decodable result, 0 otherwise. */
static int
probe(base, dev, off, want)
unsigned long base;
char *dev;
unsigned long off;
unsigned long want;      /* 0x60 expected, or 0x40 */
{
    int fd;
    char *p;
    volatile char sink;
    unsigned long fb0, ncs0, fb1, ncs1;
    unsigned long leaf, pte, pfn;
    int isfb;

    fd = open(dev, O_RDWR, 0);
    if (fd < 0) {
        printf("CMF open(%s) failed errno=%d\n", dev, errno);
        return 0;
    }

    fb0  = peek(base + O_FB_N * 4);
    ncs0 = peek(base + O_NCS_N * 4);

    p = (char *)mmap((caddr_t)0, PAGESZ, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, (off_t)off);
    if (p == (char *)-1) {
        printf("CMF mmap(%s, +%lx) failed errno=%d\n", dev, off, errno);
        close(fd);
        return 0;
    }
    sink = *(volatile char *)p;         /* force the PTE load */

    fb1  = peek(base + O_FB_N * 4);
    ncs1 = peek(base + O_NCS_N * 4);

    isfb = (fb1 != fb0);
    if (!isfb && ncs1 == ncs0) {
        printf("CMF +%08lx NO EVENT (fb %lu, ncs %lu unchanged) -- was the page already mapped?\n",
               off, fb1, ncs1);
        munmap((caddr_t)p, PAGESZ);
        close(fd);
        return 0;
    }
    if (isfb && ncs1 != ncs0) {
        printf("CMF +%08lx AMBIGUOUS: both counters moved (fb +%lu, ncs +%lu) -- not quiescent\n",
               off, fb1 - fb0, ncs1 - ncs0);
        munmap((caddr_t)p, PAGESZ);
        close(fd);
        return 0;
    }

    leaf = peek(base + (isfb ? O_FB_LEAF : O_NCS_LEAF) * 4);
    pte  = peek(leaf);                  /* the live descriptor -- the evidence */
    munmap((caddr_t)p, PAGESZ);
    close(fd);

    pfn = pte >> 12;
    printf("CMF +%08lx  %s  events +%lu  leaf %08lx  pte %08lx  pfn %05lx  %s\n",
           off, isfb ? "FB " : "DEV", isfb ? fb1 - fb0 : ncs1 - ncs0,
           leaf, pte, pfn, cmname(pte));

    if (!(pte & 1L)) {
        printf("CMF +%08lx FAIL: leaf is not resident\n", off);
        return 0;
    }
    if ((pte & 0x60L) != want) {
        printf("CMF +%08lx FAIL: expected CM %02lx, got %02lx\n",
               off, want, pte & 0x60L);
        return 0;
    }
    return 1;
}

main(argc, argv)
int argc;
char **argv;
{
    unsigned long base, magic, off, want;
    unsigned long fb_lo, fb_hi, fb_lo1, fb_hi1;
    char *dev;
    int i, ok, bad;

    if (argc < 4) {
        fprintf(stderr,
            "usage: cmfcensus <cmf_magic-hex-addr> <device> <hex-offset>...\n");
        exit(2);
    }
    base = 0;
    sscanf(argv[1], "%lx", &base);
    dev = argv[2];

    memfd = open("/dev/mem", O_RDONLY);
    if (memfd < 0) memfd = open("/dev/kmem", O_RDONLY);
    if (memfd < 0) {
        fprintf(stderr, "cmfcensus: cannot open /dev/mem or /dev/kmem: errno %d\n",
                errno);
        exit(3);
    }

    /* Read the magic FIRST.  A stale address does not fail, it returns a
     * plausible number -- which is the whole reason this word exists. */
    magic = peek(base + O_MAGIC * 4);
    if (magic != CMF_MAGIC) {
        printf("CMF MAGIC MISMATCH at %08lx: read %08lx, want %08lx\n",
               base, magic, CMF_MAGIC);
        printf("CMF every other number from this block would be noise.  Re-read\n");
        printf("CMF the address from `sh tools/status-facts.sh` for THIS image.\n");
        exit(3);
    }
    printf("CMF magic OK at %08lx  fb_n=%lu ncs_n=%lu\n",
           base, peek(base + O_FB_N * 4), peek(base + O_NCS_N * 4));

    /* The registered intervals live immediately after this block in .data;
     * print them so the reader can see what SHOULD match. */
    fb_lo  = peek(base + 20);
    fb_hi  = peek(base + 24);
    fb_lo1 = peek(base + 28);
    fb_hi1 = peek(base + 32);
    printf("CMF registered intervals: [%05lx,%05lx) [%05lx,%05lx)\n",
           fb_lo, fb_hi, fb_lo1, fb_hi1);
    if (fb_lo == 0 && fb_hi == 0)
        printf("CMF WARNING: no interval registered -- every probe will be DEV\n");

    ok = bad = 0;
    for (i = 3; i < argc; i++) {
        off = 0;
        sscanf(argv[i], "%lx", &off);
        /* Below the framebuffer offset the page is register/prefix space and
         * must keep the serialised class; at or above it, it must not. */
        want = (off >= 0x10000L) ? 0x60L : 0x40L;
        if (probe(base, dev, off, want)) ok++;
        else bad++;
    }
    printf("CMF-DONE ok=%d bad=%d\n", ok, bad);
    exit(bad ? 1 : 0);
}
