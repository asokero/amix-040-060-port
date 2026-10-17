/*
 * test-rth1.c -- drive the real build/rth1-host.o (src/rth1.c, cross-compiled exactly as the pass
 * compiles it) through every rule of docs/contracts/RTH1-ROOT-HINT.md, on qemu-m68k.
 * The harness provides what the kernel would: bootinfo, rootdev, swapfile, sdcardbase(),
 * vfs_mountroot() and printf().  Run by tools/test-rth1.sh.
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

/* what rth1.o imports */
unsigned char bootinfo[0x780] __attribute__((aligned(4)));
unsigned long rootdev;
char swapfile[160];
static unsigned long cardbase[2];
static int sd_inited;		/* sd registers its controllers lazily, in sdopen() */
static int mounted, applied_before_mount;
static char line[256];

unsigned long sdcardbase(int c) { return (sd_inited && c >= 0 && c < 2) ? cardbase[c] : 0; }

int sdopen(int c) { sd_inited = 1; return (c >= 0 && c < 2 && cardbase[c]) ? 0 : 6; }

int printf(const char *spec, ...)
{
	va_list rest;

	va_start(rest, spec);
	vsnprintf(line, sizeof line, spec, rest);
	va_end(rest);
	return 0;
}

/* what rth1.o exports */
extern void rth1_apply(void);
extern int rth1_mountroot(void);
extern unsigned long rth1_used, rth1_why;

int vfs_mountroot(void)
{
	mounted++;
	applied_before_mount = rth1_why != 0xFFFFFFFF;
	return 0;
}

#define RTH1 ((unsigned long *) (bootinfo + 0x678))
#define RTO1 (RTH1 + 7)

static void reset(void)
{
	memset(bootinfo, 0, sizeof bootinfo);
	memset(swapfile, 0, sizeof swapfile);
	strcpy(swapfile + 0x10, "/dev/dsk/c6d0s2");
	rootdev = 0x00480016;			/* c6d0s1, as stamped */
	cardbase[0] = cardbase[1] = 0;
	sd_inited = 0;
	rth1_used = rth1_why = 0xFFFFFFFF;
	line[0] = 0;
	mounted = 0;
}

static void configdev(int i, unsigned long base, unsigned short mfr, unsigned char prod)
{
	unsigned char *cd = bootinfo + i * 0x44;

	*(unsigned long *) (cd + 0x20) = base;
	*(unsigned short *) (cd + 0x14) = mfr;
	cd[0x11] = prod;
}

static void seal(unsigned long *p, int n)	/* the last long makes the n longs sum to 0 */
{
	unsigned long s = 0;
	int i;

	for (i = 0; i < n - 1; i++)
		s += p[i];
	p[n - 1] = -s;
}

static void boot(unsigned long flags, unsigned long unit, unsigned long base, unsigned long id)
{
	RTH1[0] = 0x52544831;
	RTH1[1] = 0x00010038;
	RTH1[2] = flags;
	RTH1[3] = unit;
	RTH1[4] = base;
	RTH1[5] = id;
	seal(RTH1, 7);
}

static void rootrec(unsigned long unit, unsigned long base, unsigned long id, unsigned long flags)
{
	RTO1[0] = 0x52544F31;
	RTO1[1] = 0x0001001c;
	RTO1[2] = unit;
	RTO1[3] = base;
	RTO1[4] = id;
	RTO1[5] = flags;
	seal(RTO1, 7);
	RTH1[2] |= 8;
	seal(RTH1, 7);
}

/* the machine of most cases: Z3660 card 0, A4092 card 1, both AutoConfig boards */
static void two_cards(void)
{
	configdev(0, 0x40000000, 0x144b, 1);
	configdev(1, 0x48000000, 0xc0de, 1);
	cardbase[0] = 0x40000000;
	cardbase[1] = 0x48000000;
}

static int fails;

static void expect(const char *name, unsigned long dev, const char *swap, unsigned long used,
		   unsigned long why, const char *text)
{
	int ok = rootdev == dev && strcmp(swapfile + 0x10, swap) == 0 && rth1_used == used
		 && rth1_why == why && strstr(line, text) != NULL;

	fprintf(stdout, "%s %-34s rootdev %08lx %-16s used %lu why %lu\n", ok ? "PASS" : "FAIL", name,
		rootdev, swapfile + 0x10, rth1_used, rth1_why);
	if (!ok) {
		fprintf(stdout, "     want rootdev %08lx %s used %lu why %lu text '%s'\n",
			dev, swap, used, why, text);
		fails++;
	}
}

#define CASE(name, setup, dev, swap, used, why, text) \
	do { reset(); setup; rth1_apply(); expect(name, dev, swap, used, why, text); \
	     fprintf(stdout, "     console: %s", line); } while (0)

int main(void)
{
	/* built in */
	CASE("no record", two_cards(),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 1, "root c6d0s1 built in (no record)");
	CASE("wrong magic", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100), RTH1[0] = 0x52544832),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 2, "built in (bad record)");
	CASE("wrong version", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100), RTH1[1] = 0x00020038, seal(RTH1, 7)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 2, "built in (bad record)");
	CASE("bad checksum", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100), RTH1[3] ^= 1),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 2, "built in (bad record)");
	/* length bounds the read: a record shorter than 0x38 is refused before root[] at 0x1c is looked at,
	 * even when root[] holds a valid root record; a longer one (a later version's) is still read. */
	CASE("length 0x34: root[] never read", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100),
	     rootrec(1, 0x48000000, 0xc0de0100, 0), RTH1[1] = 0x00010034, seal(RTH1, 7)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 2, "built in (bad record)");
	CASE("length 0x40: still read", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100),
	     rootrec(1, 0x48000000, 0xc0de0100, 0), RTH1[1] = 0x00010040, seal(RTH1, 7)),
	     0x00480019, "/dev/dsk/c9d0s2", 2, 0, "root c9d0s1 from the root record");
	CASE("ambiguous boot node", (two_cards(), boot(0x10, 3, 0, 0)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 4, "built in (no boot node)");
	CASE("unit 13 (LUN 1)", (two_cards(), boot(3, 13, 0x40000000, 0x144b0100)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 5, "built in (unit out of range)");
	CASE("controller not present", (configdev(0, 0x40000000, 0x144b, 1), cardbase[0] = 0x40000000,
	     boot(3, 1, 0x48000000, 0xc0de0100)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 6, "built in (controller not present)");
	CASE("two cards one id, base 0", (configdev(0, 0x40000000, 0x0202, 0x54), configdev(1, 0x48000000, 0x0202, 0x54),
	     cardbase[0] = 0x40000000, cardbase[1] = 0x48000000, boot(0, 0, 0, 0), rootrec(2, 0, 0x02025400, 0)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 6, "built in (controller not present)");
	CASE("damaged root record, no fallback", (two_cards(), boot(3, 6, 0x40000000, 0x144b0100),
	     rootrec(1, 0x48000000, 0xc0de0100, 0), RTO1[2] = 2),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 3, "built in (bad root record)");
	CASE("floppy-rooted kernel", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100), rootdev = 0x00400008,
	     strcpy(swapfile + 0x10, "/dev/fakeswap")),
	     0x00400008, "/dev/fakeswap", 0, 7, "built in (not disk-rooted)");

	/* used */
	CASE("boot disk Z3660 unit 3", (two_cards(), boot(3, 3, 0x40000000, 0x144b0100)),
	     0x00480013, "/dev/dsk/c3d0s2", 1, 0, "root c3d0s1 from the boot disk (board 40000000 id 144b01 unit 3 = card 0)");
	CASE("boot disk Z3660 unit 0", (two_cards(), boot(3, 0, 0x40000000, 0x144b0100)),
	     0x00480010, "/dev/dsk/c0d0s2", 1, 0, "root c0d0s1 from the boot disk");
	CASE("boot disk A4092 unit 7 -> f", (two_cards(), boot(3, 7, 0x48000000, 0xc0de0100)),
	     0x0048001f, "/dev/dsk/cfd0s2", 1, 0, "root cfd0s1 from the boot disk");
	CASE("root record A4092 unit 1", (two_cards(), boot(3, 6, 0x40000000, 0x144b0100),
	     rootrec(1, 0x48000000, 0xc0de0100, 0)),
	     0x00480019, "/dev/dsk/c9d0s2", 2, 0, "root c9d0s1 from the root record (board 48000000 id c0de01 unit 1 = card 1)");
	CASE("root record by id only", (two_cards(), boot(3, 6, 0x40000000, 0x144b0100),
	     rootrec(4, 0, 0xc0de0100, 0)),
	     0x0048001c, "/dev/dsk/ccd0s2", 2, 0, "root ccd0s1 from the root record");
	CASE("root record without boot node", (two_cards(), boot(0x10, 0, 0, 0), rootrec(5, 0x40000000, 0x144b0100, 0)),
	     0x00480015, "/dev/dsk/c5d0s2", 2, 0, "root c5d0s1 from the root record");
	CASE("motherboard boot (A3000 SCSI)", (configdev(0, 0x40000000, 0x144b, 1), cardbase[0] = 0x00dd0000,
	     cardbase[1] = 0x40000000, boot(1 | 4, 2, 0, 0)),
	     0x00480012, "/dev/dsk/c2d0s2", 1, 0, "root c2d0s1 from the boot disk (board dd0000");
	CASE("motherboard root record (IDE key)", (two_cards(), cardbase[1] = 0xfffffff0, boot(3, 6, 0x40000000, 0x144b0100),
	     rootrec(0, 0, 0, 1)),
	     0x00480018, "/dev/dsk/c8d0s2", 2, 0, "root c8d0s1 from the root record");
	CASE("two motherboard rows", (cardbase[0] = 0x00dd0000, cardbase[1] = 0xfffffff0, boot(1 | 4, 2, 0, 0)),
	     0x00480016, "/dev/dsk/c6d0s2", 0, 6, "built in (controller not present)");
	CASE("rootdev upper bits kept", (two_cards(), rootdev = 0x00480026, boot(3, 3, 0x40000000, 0x144b0100)),
	     0x00480013, "/dev/dsk/c3d0s2", 1, 0, "root c3d0s1");

	/* the wrapper */
	reset();
	two_cards();
	boot(3, 3, 0x40000000, 0x144b0100);
	rth1_mountroot();
	if (mounted == 1 && applied_before_mount && rootdev == 0x00480013)
		fprintf(stdout, "PASS rth1_mountroot: applies, then mounts once\n");
	else {
		fprintf(stdout, "FAIL rth1_mountroot: mounted %d, applied first %d\n", mounted, applied_before_mount);
		fails++;
	}

	fprintf(stdout, "%s: %d failing\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
