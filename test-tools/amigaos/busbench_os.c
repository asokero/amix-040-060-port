/* busbench_os.c -- the AmigaOS twin of test-tools/busbench.c.
 *
 * WHY THIS EXISTS
 * On 2026-08-19 we measured the VA2000's Zorro III aperture under AMIX at 7.66 MB/s
 * write32, against a 25.91 MB/s local-RAM reference, and attributed the ceiling to the
 * CARD (16-bit SDRAM path, an arbiter round-trip per transaction, display scanout
 * priority, no MTC burst).  That attribution is READ OUT OF THE VERILOG, not measured.
 * It has one obvious control we never ran: the same card, in the same machine, driven
 * by an operating system we did not write.
 *
 *   If AmigaOS also lands near 7.7 MB/s   -> the card is the ceiling, AMIX is clean.
 *   If AmigaOS reaches materially more    -> the cost is on our side, and it is findable.
 *
 * Either answer is worth having and neither can be obtained any other way.
 *
 * *** THE COMPARISON IS ONLY VALID IF THE MEASUREMENT IS THE SAME ***
 *
 * 1. THE LOOPS ARE COPIED, NOT REWRITTEN.  Same 4x unroll, same access widths, same
 *    repeat-until-MINTICKS shape, same report arithmetic and output columns as
 *    test-tools/busbench.c.  Do not "improve" one without the other; the instant they
 *    differ, the two numbers stop being comparable and the whole point is gone.
 *
 * 2. EVERY ACCESS IS volatile.  The AMIX compiler is a 1991 AT&T cc that optimises
 *    almost nothing; gcc 6.5 at -O2 will happily turn the write loop into a memset()
 *    call and delete the read loop outright.  volatile is not decoration here -- it is
 *    the only reason the two programs execute the same instructions.  Measured 2026-08-22:
 *    gcc 6.5/m68k does not in fact perform that merge even without volatile, so this is a
 *    guard against a future toolchain rather than a fix for an observed defect.  The build
 *    script checks the emitted instructions either way, and that check is proven to bite.
 *
 * 3. THE CACHE MODE OF THE APERTURE IS NOT KNOWN TO THIS PROGRAM.  Under AMIX we know
 *    it exactly (leaf PTE, CM=0x40 NCS, or 0x60 NC for the framebuffer class since
 *    change D).  Under AmigaOS it is whatever the running system left in the MMU
 *    tables -- mntgfx.card, Picasso96, MuFastROM/MMULib, or nothing at all.  This
 *    program therefore runs the local-RAM reference AUTOMATICALLY and flags the case
 *    where the aperture comes back suspiciously close to it, because that is the
 *    signature of a CACHED mapping, i.e. of not measuring the bus at all.
 *    A flagged run is not a fast bus.  It is a void measurement.
 *
 * 4. OFFSET 0 IS THE REGISTER WINDOW, AND HERE NOTHING WILL STOP YOU.  A graphics
 *    board's aperture starts with its registers; on the VA2000 the space between the
 *    registers and the framebuffer at +0x10000 is decoded by nothing.  Under AMIX the
 *    kernel answered that with SIGKILL (ISSUE-47).  AmigaOS has no such backstop: you
 *    will write benchmark garbage straight into the display controller's registers.
 *    So board mode REFUSES offset 0 unless you pass -f and mean it.
 *
 * 5. Writing to a framebuffer puts garbage on the screen.  Harmless, expected, and on
 *    this side it lands on whatever screen the board is currently showing.
 *
 * TIMING: timer.device UNIT_ECLOCK, ~709 kHz on PAL -- far finer than AMIX's 100 Hz
 * times(), so the same 3-second measurement is more precise here, not less.  ev_lo is
 * 32 bits and wraps about every 100 minutes; unsigned subtraction survives one wrap.
 * We do NOT Forbid(): DateStamp/DOS calls can break it, and a 9-second Forbid on a
 * machine that may be driving a display is a worse bargain than a little task noise.
 *
 * usage:
 *   busbench_os -l                              list every ConfigDev board and exit
 *   busbench_os -r [bytes]                      local fast-RAM reference only
 *   busbench_os <manuf>:<prod> [bytes] [hexoff] find the board, then measure it
 *   busbench_os @<hexaddr>     [bytes] [hexoff] measure an absolute address (careful)
 *
 *   VA2000 is 6d6e:1 and its framebuffer offset is 10000, so the run that answers the
 *   question above is:   busbench_os 6d6e:1 1048576 10000
 *
 * build: sh test-tools/amigaos/mkbusbench_os.sh
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <libraries/configvars.h>
#include <libraries/expansionbase.h>
#include <devices/timer.h>

#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/expansion.h>
#include <proto/timer.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DFLTSZ    1048576UL      /* same default as busbench.c */
#define MINSECS   3UL            /* == MINTICKS 300 @ HZ=100 on the AMIX side */

struct ExpansionBase *ExpansionBase = NULL;   /* type dictated by proto/expansion.h */
struct Device  *TimerBase     = NULL;

static struct MsgPort    *tport = NULL;
static struct timerequest *treq = NULL;
static ULONG eclock_hz = 0UL;
static ULONG minticks  = 0UL;

/* ---- timing ----------------------------------------------------------- */
static ULONG
ticks(void)
{
	struct EClockVal ev;

	ReadEClock(&ev);
	return ev.ev_lo;
}

static int
timer_open(void)
{
	struct EClockVal ev;

	if ((tport = CreateMsgPort()) == NULL)
		return 0;
	treq = (struct timerequest *)
	    CreateIORequest(tport, (ULONG) sizeof(struct timerequest));
	if (treq == NULL)
		return 0;
	if (OpenDevice((CONST_STRPTR) TIMERNAME, UNIT_ECLOCK, (struct IORequest *) treq, 0L) != 0)
		return 0;
	TimerBase = treq->tr_node.io_Device;
	eclock_hz = ReadEClock(&ev);
	if (eclock_hz == 0UL)
		return 0;
	minticks = eclock_hz * MINSECS;
	return 1;
}

static void
timer_close(void)
{
	if (TimerBase != NULL) {
		CloseDevice((struct IORequest *) treq);
		TimerBase = NULL;
	}
	if (treq  != NULL) { DeleteIORequest((struct IORequest *) treq); treq  = NULL; }
	if (tport != NULL) { DeleteMsgPort(tport);                       tport = NULL; }
}

/* ---- reporting -------------------------------------------------------- */
/* Column-for-column the same line busbench.c prints, but tagged BUSBENCH-OS so a
 * pasted log can never be mistaken for an AMIX-side run.  Confusing the two would be
 * exactly the attribution error this whole exercise exists to avoid. */
static ULONG
report(const char *what, unsigned long long bytes, ULONG dt)
{
	unsigned long long secs100, kbps;
	unsigned long whole, frac, mbps, mfrac;

	if (dt == 0UL)
		dt = 1UL;
	secs100 = ((unsigned long long) dt * 100ULL) / (unsigned long long) eclock_hz;
	if (secs100 == 0ULL)
		secs100 = 1ULL;
	kbps  = (bytes / 1024ULL) * 100ULL / secs100;
	whole = (unsigned long) (secs100 / 100ULL);
	frac  = (unsigned long) (secs100 - (unsigned long long) whole * 100ULL);
	mbps  = (unsigned long) (kbps / 1024ULL);
	mfrac = (unsigned long) (((kbps - (unsigned long long) mbps * 1024ULL) * 100ULL) / 1024ULL);

	printf("BUSBENCH-OS %-14s %8lu KB moved  %8lu ticks (%lu.%02lu s)  %7lu KB/s (%lu.%02lu MB/s)\n",
	       what, (unsigned long) (bytes / 1024ULL), (unsigned long) dt,
	       whole, frac, (unsigned long) kbps, mbps, mfrac);
	fflush(stdout);
	return (ULONG) kbps;
}

/* ---- the three loops, transcribed from busbench.c --------------------- */
static ULONG
wlong(APTR p, ULONG sz)
{
	volatile ULONG *q, *end;
	ULONG t0, dt, i;
	unsigned long long total;
	ULONG n = sz / 4UL;

	total = 0ULL;
	t0 = ticks();
	do {
		q = (volatile ULONG *) p;
		end = q + n;
		i = 0UL;
		while (q < end) {
			*q++ = i;
			*q++ = i;
			*q++ = i;
			*q++ = i;         /* unrolled x4: loop overhead off the measurement */
			i++;
		}
		total += (unsigned long long) sz;
		dt = ticks() - t0;
	} while (dt < minticks);
	return report("write32", total, dt);
}

static ULONG
wword(APTR p, ULONG sz)
{
	volatile UWORD *q, *end;
	ULONG t0, dt;
	unsigned long long total;
	UWORD v = 0x5a5a;
	ULONG n = sz / 2UL;

	total = 0ULL;
	t0 = ticks();
	do {
		q = (volatile UWORD *) p;
		end = q + n;
		while (q < end) {
			*q++ = v;
			*q++ = v;
			*q++ = v;
			*q++ = v;
		}
		total += (unsigned long long) sz;
		dt = ticks() - t0;
	} while (dt < minticks);
	return report("write16", total, dt);
}

volatile ULONG sink;             /* global so the reads cannot be optimised away */

static ULONG
rlong(APTR p, ULONG sz)
{
	volatile ULONG *q, *end;
	ULONG t0, dt, acc;
	unsigned long long total;
	ULONG n = sz / 4UL;

	total = 0ULL;
	acc = 0UL;
	t0 = ticks();
	do {
		q = (volatile ULONG *) p;
		end = q + n;
		while (q < end) {
			acc += *q++;
			acc += *q++;
			acc += *q++;
			acc += *q++;
		}
		total += (unsigned long long) sz;
		dt = ticks() - t0;
	} while (dt < minticks);
	sink = acc;
	return report("read32", total, dt);
}

/* ---- board discovery --------------------------------------------------- */
static void
list_boards(void)
{
	struct ConfigDev *cd = NULL;
	int n = 0;

	printf("BUSBENCH-OS boards (expansion.library ConfigDev chain):\n");
	while ((cd = FindConfigDev(cd, -1L, -1L)) != NULL) {
		printf("BUSBENCH-OS   %04lx:%02lx  addr=%08lx  size=%8lu  type=%02lx  %s\n",
		       (unsigned long) cd->cd_Rom.er_Manufacturer,
		       (unsigned long) cd->cd_Rom.er_Product,
		       (unsigned long) cd->cd_BoardAddr,
		       (unsigned long) cd->cd_BoardSize,
		       (unsigned long) cd->cd_Rom.er_Type,
		       (cd->cd_Rom.er_Type & 0x80) ? "Z3-or-memlist" : "");
		n++;
	}
	printf("BUSBENCH-OS %d board(s).  er_Type bit7 set = board was added to the memory list;\n", n);
	printf("BUSBENCH-OS a Zorro III board is recognisable by its addr being >= 40000000.\n");
}

/* ---- main -------------------------------------------------------------- */
int
main(int argc, char **argv)
{
	APTR ram = NULL, base = NULL, p = NULL;
	struct ConfigDev *cd = NULL;
	ULONG sz = DFLTSZ, mapoff = 0UL, absaddr = 0UL;
	ULONG manuf = 0UL, prod = 0UL;
	ULONG ref_w32 = 0UL, dev_w32 = 0UL, dev_w16 = 0UL;
	int isram = 0, isabs = 0, force = 0, argi = 1, rc = 0;

	setvbuf(stdout, NULL, _IONBF, 0);   /* survive a hang with the log intact */

	if (argc < 2) {
		printf("usage: busbench_os -l\n");
		printf("       busbench_os -r [bytes]\n");
		printf("       busbench_os <manuf>:<prod> [bytes] [hex-offset] [-f]\n");
		printf("       busbench_os @<hexaddr>     [bytes] [hex-offset] [-f]\n");
		printf("       VA2000 framebuffer:  busbench_os 6d6e:1 1048576 10000\n");
		printf("       offset 0 is the REGISTER window and is refused without -f\n");
		return 2;
	}

	if ((ExpansionBase = (struct ExpansionBase *) OpenLibrary((CONST_STRPTR) "expansion.library", 0L)) == NULL) {
		printf("BUSBENCH-OS ERR cannot open expansion.library\n");
		return 1;
	}
	if (!timer_open()) {
		printf("BUSBENCH-OS ERR cannot open timer.device UNIT_ECLOCK\n");
		timer_close();
		CloseLibrary((struct Library *) ExpansionBase);
		return 1;
	}

	if (strcmp(argv[argi], "-l") == 0) {
		list_boards();
		goto out;
	}

	if (strcmp(argv[argi], "-r") == 0) {
		isram = 1;
		argi++;
		if (argi < argc)
			sz = strtoul(argv[argi++], NULL, 10);
	} else if (argv[argi][0] == '@') {
		isabs = 1;
		absaddr = strtoul(argv[argi] + 1, NULL, 16);
		argi++;
		if (argi < argc && argv[argi][0] != '-')
			sz = strtoul(argv[argi++], NULL, 10);
		if (argi < argc && argv[argi][0] != '-')
			mapoff = strtoul(argv[argi++], NULL, 16);
	} else {
		char *colon = strchr(argv[argi], ':');
		if (colon == NULL) {
			printf("BUSBENCH-OS ERR expected <manuf>:<prod> in hex, e.g. 6d6e:1\n");
			rc = 2;
			goto out;
		}
		*colon = '\0';
		manuf = strtoul(argv[argi], NULL, 16);
		prod  = strtoul(colon + 1, NULL, 16);
		argi++;
		if (argi < argc && argv[argi][0] != '-')
			sz = strtoul(argv[argi++], NULL, 10);
		if (argi < argc && argv[argi][0] != '-')
			mapoff = strtoul(argv[argi++], NULL, 16);
	}
	for (; argi < argc; argi++)
		if (strcmp(argv[argi], "-f") == 0)
			force = 1;

	if (sz < 65536UL)
		sz = 65536UL;

	printf("BUSBENCH-OS eclock=%lu Hz  minticks=%lu (%lu s)  size=%lu bytes\n",
	       (unsigned long) eclock_hz, (unsigned long) minticks,
	       (unsigned long) MINSECS, (unsigned long) sz);

	/* ---- locate the target ------------------------------------------- */
	if (!isram) {
		if (isabs) {
			base = (APTR) absaddr;
			printf("BUSBENCH-OS target=absolute %08lx (no board lookup, no size check)\n",
			       (unsigned long) absaddr);
		} else {
			cd = FindConfigDev(NULL, (LONG) manuf, (LONG) prod);
			if (cd == NULL) {
				printf("BUSBENCH-OS ERR board %04lx:%02lx not found -- run -l to see what is here\n",
				       (unsigned long) manuf, (unsigned long) prod);
				rc = 1;
				goto out;
			}
			base = cd->cd_BoardAddr;
			printf("BUSBENCH-OS target=%04lx:%02lx addr=%08lx size=%lu (%s)\n",
			       (unsigned long) manuf, (unsigned long) prod,
			       (unsigned long) base, (unsigned long) cd->cd_BoardSize,
			       ((ULONG) base >= 0x40000000UL) ? "Zorro III address" : "Zorro II address");
			if (mapoff + sz > cd->cd_BoardSize) {
				printf("BUSBENCH-OS ERR offset %lx + size %lu exceeds the board's %lu-byte aperture\n",
				       (unsigned long) mapoff, (unsigned long) sz,
				       (unsigned long) cd->cd_BoardSize);
				rc = 1;
				goto out;
			}
		}
		if (mapoff == 0UL && !force) {
			printf("BUSBENCH-OS REFUSED offset 0 is the register window, and writing benchmark\n");
			printf("BUSBENCH-OS         garbage there can reprogram or hang the display controller.\n");
			printf("BUSBENCH-OS         VA2000 framebuffer is at 10000.  Pass -f only if you mean it.\n");
			rc = 2;
			goto out;
		}
		p = (APTR) ((UBYTE *) base + mapoff);
		printf("BUSBENCH-OS access address = %08lx (offset %lx)\n",
		       (unsigned long) p, (unsigned long) mapoff);
	}

	/* ---- the reference always runs, and it runs first ------------------ */
	/* busbench.c only ASKS you to run -r in the same session; here it is not
	 * optional, because the whole value of the number is the ratio. */
	ram = AllocMem(sz, MEMF_FAST | MEMF_ANY);
	if (ram == NULL) {
		printf("BUSBENCH-OS ERR AllocMem %lu MEMF_FAST failed -- reference cannot run,\n",
		       (unsigned long) sz);
		printf("BUSBENCH-OS     and without it the device number means nothing.  Aborting.\n");
		rc = 1;
		goto out;
	}
	printf("BUSBENCH-OS --- reference: local fast RAM at %08lx (cached; CPU/loop ceiling) ---\n",
	       (unsigned long) ram);
	ref_w32 = wlong(ram, sz);
	(void)   wword(ram, sz);
	(void)   rlong(ram, sz);

	if (!isram) {
		printf("BUSBENCH-OS --- target: the board aperture (garbage on screen is expected) ---\n");
		dev_w32 = wlong(p, sz);
		dev_w16 = wword(p, sz);
		(void)   rlong(p, sz);

		/* ---- the two things a bare number cannot tell you ------------- */
		printf("BUSBENCH-OS ratio  device/reference write32 = %lu.%02lu %%\n",
		       (unsigned long) (ref_w32 ? (dev_w32 * 100UL) / ref_w32 : 0UL),
		       (unsigned long) (ref_w32 ? ((dev_w32 * 10000UL) / ref_w32) % 100UL : 0UL));
		if (dev_w16 > 0UL)
			printf("BUSBENCH-OS ratio  write32/write16 = %lu.%02lu   (~1.1 = 16-bit path saturated,\n"
			       "BUSBENCH-OS        ~1.9 = a 32-bit path is in use.  Report it, do not over-read it.)\n",
			       (unsigned long) (dev_w32 / dev_w16),
			       (unsigned long) ((dev_w32 * 100UL / dev_w16) % 100UL));
		if (ref_w32 > 0UL && dev_w32 > (ref_w32 / 2UL)) {
			printf("BUSBENCH-OS *** SUSPECT: the aperture reached more than half the local-RAM\n");
			printf("BUSBENCH-OS *** reference.  On a Zorro bus that is not plausible, and the usual\n");
			printf("BUSBENCH-OS *** cause is a CACHEABLE mapping -- in which case this run measured\n");
			printf("BUSBENCH-OS *** the cache, not the bus.  Do NOT quote it against the AMIX number\n");
			printf("BUSBENCH-OS *** until the MMU table entry for %08lx has been read out.\n",
			       (unsigned long) p);
		}
	}

	printf("BUSBENCH-OS-DONE %s\n", isram ? "-r" : argv[1]);
	printf("BUSBENCH-OS note: the cache mode of the aperture is set by whatever this AmigaOS\n");
	printf("BUSBENCH-OS       system left in the MMU tables and is NOT known to this program.\n");
	printf("BUSBENCH-OS       Under AMIX it is known exactly (leaf PTE).  Comparing the two is\n");
	printf("BUSBENCH-OS       sound only for the SHAPE (ratios, and whether a ceiling exists);\n");
	printf("BUSBENCH-OS       a raw MB/s gap may be a cache-class difference and nothing more.\n");

out:
	if (ram != NULL)
		FreeMem(ram, sz);
	timer_close();
	if (ExpansionBase != NULL)
		CloseLibrary((struct Library *) ExpansionBase);
	return rc;
}
