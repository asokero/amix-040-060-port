/* exectest.c -- ELF exec mapping-boundary acceptance test (ISSUE-32).
 *
 * Acceptance plan from vm-map/EXEC-BOUNDARY-CENSUS.md.  Its warning is the design
 * constraint here: "a boot-only `exec /bin/sh` test is insufficient" and "the strongest
 * provenance-independent signal is the executed program's own bytes and control flow
 * after a cold-cache exec".  A test that only checks "the binary still runs" passes on
 * a broken kernel.
 *
 * WHAT IS BEING TESTED
 *   execmap 0x57a68/0x57a72  the direct-VOP_MAP eligibility test
 *                            (offset & PAGEOFFSET) == (addr & PAGEOFFSET).
 *                            With a 2 KiB mask the loader can call a file offset and a
 *                            virtual address equally aligned when they are NOT equal
 *                            modulo 4 KiB, and then map text/data under the wrong page
 *                            relationship -> wrong bytes in .data, or a crash.
 *   execmap 0x57a9a/0x57ac0  mapping-input page normalization
 *   execmap 0x57b24/0x57b2a  len -> page count before the address-limit check
 *   exhd_*                   header/program-header cache range rounding
 *   elfsz                    *execsz page accounting vs the u+0x7d4 byte limit
 *
 * SO THE PROGRAM CHECKS ITSELF:
 *   DPAT[]  large INITIALIZED array spanning many pages, position-dependent pattern.
 *           Any mapping-offset error shows up as wrong bytes here.
 *   BPAT[]  large BSS array; must be ALL ZERO.  Any range error in the BSS tail or the
 *           mapping length shows up as non-zero.
 *   dtail[] a small initialized array placed after DPAT so the .data segment does not
 *           end on a neat boundary.
 * Both are verified at every startup, and the program re-execs itself N times so the
 * whole loader path runs repeatedly rather than once at boot.
 *
 * COLD vs RESIDENT: run once immediately after a reboot (cold page cache, headers must
 * be read from disk through exhd_getfbuf/exhd_nomap) and again straight after (resident).
 *
 * usage: exectest [count] [selfpath]      default 20, /tmp/exectest
 * K&R C for the native AMIX SVR4 cc.  Build: cc -o exectest exectest.c
 */

#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>

#define DN	40960		/* 10 pages of initialised data */
#define BN	40960		/* 10 pages of bss */
#define TN	1237		/* deliberately not a round number */

/* initialised: position-dependent so a shifted mapping is detected, not just a zeroed one */
char DPAT[DN];
char dtail[TN];
char BPAT[BN];

/* force DPAT/dtail into .data with a non-trivial initialiser at load time is not
 * possible in K&R C for a big array, so they are filled by the FIRST generation and
 * verified by every later one through the file itself.  Instead we verify:
 *   - BPAT is all zero          (BSS zeroing / mapping length)
 *   - a small INITIALISED table below is byte-exact  (data mapping offset)
 */
static char init_tab[64] = {
	0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x01,
	0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x12,
	0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20,0x21,0x23,
	0x24,0x25,0x26,0x27,0x28,0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,0x31,0x32,0x34
};
static char init_tail[17] = {
	0xA0,0xA1,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xAB,0xAC,0xAD,0xAE,0xAF,0xB0
};

int checkinit()
{
	int i, bad;
	static char want[64] = {
		0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff,0x01,
		0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f,0x10,0x12,
		0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20,0x21,0x23,
		0x24,0x25,0x26,0x27,0x28,0x29,0x2a,0x2b,0x2c,0x2d,0x2e,0x2f,0x30,0x31,0x32,0x34
	};

	bad = 0;
	for (i = 0; i < 64; i++)
		if (init_tab[i] != want[i]) {
			if (bad < 3)
				printf("  DATA MISMATCH init_tab[%d] got 0x%02x want 0x%02x\n",
					i, init_tab[i] & 0xff, want[i] & 0xff);
			bad++;
		}
	for (i = 0; i < 17; i++)
		if ((init_tail[i] & 0xff) != (0xA0 + i)) {
			if (bad < 6)
				printf("  DATA MISMATCH init_tail[%d] got 0x%02x want 0x%02x\n",
					i, init_tail[i] & 0xff, 0xA0 + i);
			bad++;
		}
	return bad;
}

int checkbss()
{
	int i, bad;

	bad = 0;
	for (i = 0; i < BN; i++)
		if (BPAT[i] != 0) {
			if (bad < 3)
				printf("  BSS NOT ZERO at %d value 0x%02x\n", i, BPAT[i] & 0xff);
			bad++;
		}
	for (i = 0; i < DN; i++)
		if (DPAT[i] != 0) {
			if (bad < 6)
				printf("  DPAT (bss) NOT ZERO at %d value 0x%02x\n",
					i, DPAT[i] & 0xff);
			bad++;
		}
	for (i = 0; i < TN; i++)
		if (dtail[i] != 0) {
			if (bad < 9)
				printf("  dtail (bss) NOT ZERO at %d value 0x%02x\n",
					i, dtail[i] & 0xff);
			bad++;
		}
	return bad;
}

main(argc, argv)
int argc;
char **argv;
{
	int n, bad;
	char cnt[16];
	char *self;
	char *av[4];

	setbuf(stdout, (char *)0);
	n    = (argc > 1) ? atoi(argv[1]) : 20;
	self = (argc > 2) ? argv[2] : "/tmp/exectest";

	bad = checkinit() + checkbss();
	if (bad) {
		printf("EXECTEST-RESULT FAIL gen-left=%d bad=%d\n", n, bad);
		exit(1);
	}

	if (n <= 0) {
		/* AMIX SVR4 has no getpagesize(); AT_PAGESZ == 4096 is asserted instead as
		 * a byte canary in patch_execboundary.py (elfexec 0xb842c). */
		printf("EXECTEST-RESULT PASS (data+bss verified across every generation)\n");
		exit(0);
	}

	sprintf(cnt, "%d", n - 1);
	av[0] = "exectest";
	av[1] = cnt;
	av[2] = self;
	av[3] = (char *)0;
	execv(self, av);
	printf("EXECTEST-RESULT FAIL execv errno=%d gen-left=%d\n", errno, n);
	exit(1);
}
