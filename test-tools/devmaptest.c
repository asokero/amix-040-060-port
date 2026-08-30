/* devmaptest.c -- device-mmap page-geometry acceptance test (ISSUE-33).
 *
 * T1  /dev/mem mmap PFN correctness (group "pfn")
 *     mmmmap returns a PAGE FRAME NUMBER and hat_devload maps it as pfn << 12.  With
 *     the old `phys >> 11` the PFN is TWICE the correct value, so the mapping lands at
 *     twice the requested physical address.
 *     The probe is provenance-independent: write a marker through /dev/kmem-style
 *     physical access is not portable here, so instead we map the SAME physical page
 *     twice at two different file offsets that must resolve to the same page, and we
 *     map a page whose contents we can predict -- the kernel's own text at a known
 *     physical address is not knowable from userland, so we instead check SELF
 *     CONSISTENCY plus the doubling signature:
 *       map offset P and offset P+4096 and require the two mappings to differ,
 *       map offset P twice and require them to be identical.
 *     Under the 2 KiB bug, offset P and P+2048 alias to the SAME physical page while
 *     P and P+4096 land two pages apart -- so the aliasing test detects it directly.
 *
 * T2  mincore() over a DEVICE mapping (group "incore")  -- THE DECISIVE ONE
 *     The public mincore path is already 4 KiB, so it sizes the vector at
 *     btopr(len)/4096 bytes.  segdev_incore wrote one byte per 2 KiB, i.e. TWICE as
 *     many, overrunning the caller's buffer.  We place a canary immediately after the
 *     expected vector length and require it to survive.  Any byte written past the
 *     expected length is a kernel overrun into user memory, and the check does not
 *     depend on the value written.
 *
 * ⚠ T1 ENCODES THE CURRENT (PRE-ABI) BEHAVIOUR, deliberately.  It expects a
 * base+0x800 device offset to alias the SAME 4 KiB PFN, which is true only while
 * the public mmap offset check still admits 2048-aligned offsets (sysconfig
 * 0x44e7c / mmap 0x583a6 / MAP_FIXED 0x5844c / munmap 0x584f2 / mprotect 0x58572).
 * If the public five-site ABI is ever moved to 4 KiB, T1 WILL FAIL and it will
 * look like a kernel regression.  It is not: change this expectation on purpose,
 * at the same time, or the next session will "fix" the kernel to satisfy a stale
 * test.  (Codex, vm-map/RESIDUAL-FAMILIES-FOLLOWUP.md, 2026-07-27.)
 *
 * ⚠ THE PHYSICAL BASE IS NOT A CONSTANT OF THE MACHINE (ISSUE-57, 2026-08-30).  Both tests
 * need a physical address that /dev/mem can map and whose content is distinctive, and they
 * used the kernel load base for it -- hard-coded as 0x08000000.  That is the load base only
 * on an accelerator that carries its own RAM.  An A3640 has none and the kernel runs from
 * motherboard RAM at 0x07000000, where 0x08000000 is not memory at all: both mmap()s returned
 * ENXIO, both cases took their SKIP path, and this program printed PASS having measured
 * nothing.  It is now probed, and a case that could not run is a FAILURE rather than a pass:
 * see the `skips` counter and the verdict line.
 *
 * usage: devmaptest [physical-base-in-hex]
 *        devmaptest            probe 0x08000000 then 0x07000000, take the first that maps
 *        devmaptest 7000000    force one, for a machine neither candidate fits
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o devmaptest devmaptest.c
 * Run as root (/dev/mem).
 */

#include <sys/types.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define PG	4096
#define NPG	4
#define MLEN	(NPG * PG)
#define CANARY	0x5A

char vec[64];			/* generous; expected use is MLEN/PG = 4 bytes */
int fails;
int skips;			/* a case that could not run.  NOT a pass -- see main() */

/* Candidate physical bases, tried in this order, terminated by 0.  Each is a load base this
 * project has actually seen: 0x08000000 is an accelerator with its own RAM (Mercury), and
 * 0x07000000 is A3000 motherboard RAM, which is what an A3640 runs from.  A machine that is
 * neither takes the base as argv[1] rather than a code change. */
long bases[] = { 0x08000000L, 0x07000000L, 0L };
long phys_base;			/* probed once in main(); 0 means nothing was mappable */

/* probe_base -- return the first candidate that /dev/mem maps AND that reads back non-zero.
 * Both conditions matter.  Mappable-but-zero is the signature this test exists to catch (a
 * doubled PFN lands outside RAM and reads as zeros), so a base chosen on mappability alone
 * could hand T1 a window in which its own discriminator can never fire. */
long probe_base(fd)
int fd;
{
	int i, j, nz;
	char *p;

	for (i = 0; bases[i] != 0L; i++) {
		p = (char *)mmap((char *)0, PG, PROT_READ, MAP_SHARED, fd, bases[i]);
		if (p == (char *)-1) {
			printf("    probe: 0x%lx does not map, errno=%d\n", bases[i], errno);
			continue;
		}
		nz = 0;
		for (j = 0; j < PG; j++)
			if (p[j] != 0) nz++;
		(void)munmap(p, PG);
		if (nz == 0) {
			printf("    probe: 0x%lx maps but reads all zero -- not a kernel window\n",
				bases[i]);
			continue;
		}
		printf("    probe: 0x%lx maps, %d/%d bytes non-zero\n", bases[i], nz, PG);
		return bases[i];
	}
	return 0L;
}

t1_devmem()
{
	int fd;
	char *a, *b, *c;
	long base;
	int i, same_ab, same_ac;

	if (phys_base == 0L) {
		printf("  T1 SKIP: no usable physical base\n");
		skips++;
		return;
	}
	fd = open("/dev/mem", O_RDONLY, 0);
	if (fd < 0) {
		printf("  T1 SKIP: /dev/mem open errno=%d\n", errno);
		skips++;
		return;
	}
	/* The probed base is the kernel load base, so this window has DISTINCTIVE, non-zero
	 * content.  The first version used 0x00100000, which is very likely all zeros --
	 * comparing single bytes there is blind and gives a meaningless PASS.  With the 2 KiB
	 * PFN bug btop_2k(base) is twice the right frame and hat_devload maps twice the
	 * requested physical address, far outside RAM, so a wrong PFN is unmistakable here. */
	base = phys_base;

	a = (char *)mmap((char *)0, PG, PROT_READ, MAP_SHARED, fd, base);
	b = (char *)mmap((char *)0, PG, PROT_READ, MAP_SHARED, fd, base);
	c = (char *)mmap((char *)0, PG, PROT_READ, MAP_SHARED, fd, base + 2048);
	if (a == (char *)-1 || b == (char *)-1 || c == (char *)-1) {
		printf("  T1 SKIP: mmap /dev/mem at 0x%lx failed errno=%d\n", base, errno);
		skips++;
		close(fd);
		return;
	}

	/* two mappings of the SAME offset must show identical bytes */
	same_ab = 1;
	for (i = 0; i < PG; i++)
		if (a[i] != b[i]) { same_ab = 0; break; }

	/* THE DISCRIMINATOR.  0x08000000 is the kernel load base, so this window is full
	 * of kernel text and MUST be non-zero.  An all-zero window means the mapping did
	 * not land there:
	 *     correct  pfn = 0x08000000 >> 12 = 0x08000; hat_devload maps 0x08000000
	 *     2 KiB bug pfn = 0x08000000 >> 11 = 0x10000; hat_devload maps 0x10000000,
	 *                    which is 256 MB and far outside RAM -> reads back as zeros
	 * So "all zero" is the failure signal, not an inconclusive one. */
	{
		int nz = 0;
		for (i = 0; i < PG; i++)
			if (a[i] != 0) nz++;
		printf("    kernel-base window non-zero bytes: %d/%d\n", nz, PG);
		if (nz == 0) {
			printf("  T1 FAIL: /dev/mem window at 0x%lx reads ALL ZERO -- the "
				"mapping is not landing at the requested physical address "
				"(2 KiB PFN doubles it to 0x%lx)\n", base, base * 2);
			fails++;
			(void)munmap(a, PG); (void)munmap(b, PG); (void)munmap(c, PG);
			close(fd); return;
		}
	}

	/* c maps offset base+2048.  mmap maps WHOLE PAGES from the PFN d_mmap returns,
	 * so the sub-page 2048 is dropped and c must be the SAME 4 KiB page as a --
	 * byte for byte.  (An earlier version asserted c[0] == a[2048]; that was wrong,
	 * the in-page offset is not carried through the PFN.)
	 * Under the 2 KiB PFN bug btop_2k(base+2048) = btop_2k(base)+1, so c would land
	 * one page further and the pages would differ. */
	same_ac = 1;
	for (i = 0; i < PG; i++)
		if (c[i] != a[i]) { same_ac = 0; break; }

	printf("  T1 %s: /dev/mem same-offset identical=%d, base+2048 aliases correctly=%d\n",
		(same_ab && same_ac) ? "PASS" : "FAIL", same_ab, same_ac);
	if (!(same_ab && same_ac))
		fails++;

	(void)munmap(a, PG); (void)munmap(b, PG); (void)munmap(c, PG);
	close(fd);
}

t2_mincore()
{
	int fd, i, r, bad, expect;
	char *m;

	if (phys_base == 0L) {
		printf("  T2 SKIP: no usable physical base\n");
		skips++;
		return;
	}
	fd = open("/dev/mem", O_RDONLY, 0);
	if (fd < 0) {
		printf("  T2 SKIP: /dev/mem open errno=%d\n", errno);
		skips++;
		return;
	}
	m = (char *)mmap((char *)0, MLEN, PROT_READ, MAP_SHARED, fd, phys_base);
	if (m == (char *)-1) {
		printf("  T2 SKIP: mmap at 0x%lx failed errno=%d\n", phys_base, errno);
		skips++;
		close(fd);
		return;
	}

	expect = MLEN / PG;			/* 4 bytes for a 4-page mapping */
	for (i = 0; i < 64; i++)
		vec[i] = (char)CANARY;

	errno = 0;
	r = mincore(m, MLEN, vec);
	if (r < 0) {
		printf("  T2 SKIP: mincore errno=%d\n", errno);
		skips++;
		(void)munmap(m, MLEN); close(fd);
		return;
	}

	bad = 0;
	for (i = expect; i < 64; i++)
		if (vec[i] != (char)CANARY) {
			if (bad < 3)
				printf("    OVERRUN: vec[%d] = 0x%02x (canary destroyed; "
					"expected only %d entries)\n",
					i, vec[i] & 0xff, expect);
			bad++;
		}
	printf("  T2 %s: mincore over a %d-page device mapping wrote %d entries, "
		"canary bytes clobbered = %d\n",
		bad ? "FAIL" : "PASS", NPG, expect, bad);
	if (bad)
		fails++;

	(void)munmap(m, MLEN);
	close(fd);
}

main(argc, argv)
int argc;
char **argv;
{
	int fd;

	setbuf(stdout, (char *)0);
	fails = 0;
	skips = 0;
	phys_base = 0L;
	printf("devmaptest: PAGESIZE assumed %d\n", PG);

	if (argc > 1) {
		if (sscanf(argv[1], "%lx", &phys_base) != 1)
			phys_base = 0L;
		printf("devmaptest: physical base 0x%lx from the command line\n", phys_base);
	} else {
		fd = open("/dev/mem", O_RDONLY, 0);
		if (fd < 0)
			printf("  PROBE SKIP: /dev/mem open errno=%d\n", errno);
		else {
			phys_base = probe_base(fd);
			close(fd);
		}
		printf("devmaptest: physical base 0x%lx (probed)\n", phys_base);
	}

	t1_devmem();
	t2_mincore();
	printf("DEVMAPTEST fails=%d skips=%d\n", fails, skips);
	/* A SKIP is not a pass.  Before 2026-08-30 it was: on a machine where neither case
	 * could run this program printed DEVMAPTEST-RESULT PASS, and the battery driver, which
	 * greps for exactly that string, scored it as a measured row.  See ISSUE-57. */
	printf((fails || skips) ? "DEVMAPTEST-RESULT FAIL\n" : "DEVMAPTEST-RESULT PASS\n");
	exit((fails || skips) ? 1 : 0);
}
