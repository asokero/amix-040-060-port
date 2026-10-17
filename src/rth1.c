/*
 * rth1.c -- the kernel half of the RTH1 root hint (docs/contracts/RTH1-ROOT-HINT.md).
 *
 * The boot loader leaves a record at bootinfo+0x678 naming the disk it was booted from, and the
 * installer may add a root record naming another disk.  rth1_apply() turns that into rootdev and
 * the controller digit of swapfile.bo_name -- both or neither -- before vfs_mountroot reads them.
 * Any doubt leaves the root the kernel was linked with.  One console line says which was used.
 *
 * Reached through rth1_mountroot(): relink-040-rth1.sh retargets the one relocation of main's
 * `jsr vfs_mountroot` to it (src/patch_rth1_hook.py), so the hook runs after io_init has let sd
 * register its controllers and before anything reads rootdev or swapfile.  The same file and the
 * same hook serve the 68030 line.
 *
 * Kept free of division and of multiplication by a non-power of two: the 68060 implements neither
 * 64-bit form, and the cross compiler reaches for them (the scan060 gate in the pass checks).
 */

#define RTH1_MAGIC	0x52544831	/* "RTH1" */
#define RTO1_MAGIC	0x52544F31	/* "RTO1" */
#define RTH1_LONGS	14		/* 0x38 bytes */
#define RTH1_CHECKED	7		/* longs 0x00..0x18 sum to 0 */
#define RTO1_LONGS	7		/* 0x1c bytes, all summed */

#define BI_RTH1		0x678		/* loader reserved[0], kernel bootinfo+0x678 */
#define NAUTO		16
#define CD_SIZE		0x44		/* struct ConfigDev */
#define CD_PRODUCT	0x11		/* er_Product, a byte */
#define CD_MANUF	0x14		/* er_Manufacturer, a word */
#define CD_BOARDADDR	0x20
#define BO_NAME		0x10		/* swapfile.bo_name, after bo_fstype[16] */
#define SDCARDS		2

#define RTH_BOOT	0x01
#define RTH_BCDEV	0x02
#define RTH_BMOBO	0x04
#define RTO_MOBO	0x01

#define SD_ROOTDEV	0x00480000	/* makedevice(18, 0) */
#define DEV_MAJOR	0xFFFC0000

extern unsigned char bootinfo[];
extern unsigned long rootdev;
extern char swapfile[];
extern unsigned long sdcardbase();
extern int sdopen();
extern int vfs_mountroot();
extern int printf();

/* Initialised away from 0 so a reader can tell "the hook never ran" from "built-in root". */
unsigned long rth1_used = 0xFFFFFFFF;	/* 0 built in, 1 boot disk, 2 root record */
unsigned long rth1_why = 0xFFFFFFFF;	/* 0 used; else the reason the built-in root was kept */

static char *rth1_reason[] = {
	"",
	"no record",
	"bad record",
	"bad root record",
	"no boot node",
	"unit out of range",
	"controller not present",
	"not disk-rooted",
};

#define L(p, o)	(*(unsigned long *) ((unsigned char *) (p) + (o)))

static int
rth1_sum0(p, n)
unsigned long *p;
int n;
{
	unsigned long s = 0;

	while (n-- > 0)
		s += *p++;
	return s == 0;
}

/*
 * The Amix card whose controller matches, or -1 unless exactly one does.  By board base when
 * base is nonzero; else by manufacturer/product through the autocon entry at that controller's
 * base; or, for mobo, the controller whose base is no AutoConfig board at all.
 */
static int
rth1_card(base, id, mobo)
unsigned long base, id;
int mobo;
{
	int c, i, n = 0, found = -1;

	if (!mobo && base == 0 && id == 0)
		return -1;
	/*
	 * sd registers its controllers lazily: its static init() runs from sdopen(), on the first open
	 * of any disk, which is the root's own open inside vfs_mountroot.  Until then every record is
	 * empty.  sdopen(0) runs that init now (it is guarded, so the root's open finds it done) and
	 * opens nothing else.
	 */
	(void) sdopen(0);
	for (c = 0; c < SDCARDS; c++) {
		unsigned long b = sdcardbase(c);
		unsigned char *cd = bootinfo, *hit = 0;
		int match;

		if (b == 0)
			continue;
		for (i = 0; i < NAUTO; i++, cd += CD_SIZE)
			if (L(cd, CD_BOARDADDR) == b) {
				hit = cd;
				break;
			}
		if (mobo)
			match = hit == 0;
		else if (base != 0)
			match = b == base;
		else
			match = hit != 0 && (((unsigned long) *(unsigned short *) (hit + CD_MANUF) << 16)
					     | ((unsigned long) hit[CD_PRODUCT] << 8)) == id;
		if (match) {
			found = c;
			n++;
		}
	}
	return n == 1 ? found : -1;
}

/*
 * The image must hold "/dev/dsk/c" exactly once, at swapfile.bo_name: check_root_family.py and the
 * 68030 line's stamper find the swap name by that anchor.  So the prefix is compared without the
 * 'c', and the 'c' as a constant in code.
 */
static int
rth1_disk_rooted()
{
	char *nm = swapfile + BO_NAME;
	static char head[] = "/dev/dsk/", tail[] = "d0s2";
	int i;

	if ((rootdev & DEV_MAJOR) != SD_ROOTDEV)
		return 0;
	for (i = 0; i < 9; i++)
		if (nm[i] != head[i])
			return 0;
	if (nm[9] != 'c')
		return 0;
	for (i = 0; i < 5; i++)		/* "d0s2" and its NUL */
		if (nm[11 + i] != tail[i])
			return 0;
	return 1;
}

void
rth1_apply()
{
	unsigned long *r = (unsigned long *) (bootinfo + BI_RTH1);
	unsigned long unit = 0, base = 0, id = 0, v;
	int mobo = 0, used = 0, why = 0, card = -1;

	if (!rth1_disk_rooted())
		why = 7;
	else if (r[0] == 0)
		why = 1;
	else if (r[0] != RTH1_MAGIC || (r[1] >> 16) != 1 || (r[1] & 0xFFFF) < RTH1_LONGS * 4
		 || !rth1_sum0(r, RTH1_CHECKED))
		why = 2;
	else if (r[7] != 0) {
		unsigned long *o = r + 7;

		if (o[0] != RTO1_MAGIC || (o[1] >> 16) != 1 || (o[1] & 0xFFFF) < RTO1_LONGS * 4
		    || !rth1_sum0(o, RTO1_LONGS))
			why = 3;
		else {
			unit = o[2];
			base = o[3];
			id = o[4];
			mobo = (o[5] & RTO_MOBO) != 0;
			used = 2;
		}
	} else if (!(r[2] & RTH_BOOT))
		why = 4;
	else {
		unit = r[3];
		if (r[2] & RTH_BCDEV) {
			base = r[4];
			id = r[5];
		} else
			mobo = (r[2] & RTH_BMOBO) != 0;
		used = 1;
	}
	if (why == 0 && unit > 7)
		why = 5;
	if (why == 0 && (card = rth1_card(base, id, mobo)) < 0)
		why = 6;

	if (why == 0) {
		v = (unsigned long) card << 3 | unit;
		rootdev = (rootdev & ~0xFFUL) | 0x10 | v;	/* slice 1 */
		swapfile[BO_NAME + 10] = v < 10 ? '0' + v : 'a' + v - 10;	/* slice 2 */
		printf("RTH1: root c%xd0s1 from the %s (board %x id %x unit %d = card %d)\n",
		       (int) v, used == 2 ? "root record" : "boot disk",
		       sdcardbase(card), id >> 8, (int) unit, card);
	} else if (why == 7)
		printf("RTH1: root %x built in (%s)\n", rootdev, rth1_reason[why]);
	else
		printf("RTH1: root c%xd0s%d built in (%s)\n", (int) (rootdev & 0xF),
		       (int) (rootdev >> 4 & 0xF), rth1_reason[why]);
	rth1_used = why == 0 ? used : 0;
	rth1_why = why;
}

int
rth1_mountroot()
{
	rth1_apply();
	return vfs_mountroot();
}
