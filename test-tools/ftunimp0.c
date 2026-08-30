/* ftunimp0.c -- name the field that makes Motorola's ftest unimp_0 print "failed".
 *
 * See ftunimp0_asm.s for the why and for the out[] layout.  Everything is printed as hex
 * longs and compared field by field; the parent never touches a double, because a kernel
 * whose FP emulation is under suspicion is a bad place to run printf("%f").
 *
 * The comparison is Motorola's own, made explicit:
 *   - fp0 must equal 0xbfbf0000 80000000 00000000
 *   - FPSR must equal 0x08000208, FPCR 0, FPIAR the fsin's own address, CCR 0
 *   - every other FP register and every integer register must be unchanged
 * ftest checks all of these and prints one word.  This prints which one.
 *
 * CROSS-BUILD ONLY -- this tool does NOT build with the box's native K&R `cc`.  Its other half,
 * ftunimp0_asm.s, is GNU assembler syntax (`#` immediates); the guest's own /usr/ccs/bin/as
 * rejects it ("invalid instruction name").  That is a TOOLCHAIN mismatch, not a measurement -- do
 * not read the native assembler error as a result.  Build only with the m68k-cbm-sysv4 cross
 * toolchain on the host and transfer the binary:
 *     m68k-cbm-sysv4-gcc -m68040 -o ftunimp0 ftunimp0.c ftunimp0_asm.s
 *
 * usage: ftunimp0
 */

#include <stdio.h>

#define I_DATA	0
#define I_IREGS	4
#define I_SREGS	19
#define I_IFP	34
#define I_SFP	58
#define I_IFPC	82
#define I_SFPC	85
#define I_ICCR	88
#define I_SCCR	89
#define I_PCV	91
#define NLONG	92

extern void ftunimp0_run();

static char *regname[15] = {
	"d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7",
	"a0", "a1", "a2", "a3", "a4", "a5", "a6"
};

static int
show(name, got, want)
char *name;
unsigned long got, want;
{
	printf("  %-8s got %08lX  want %08lX  %s\n", name, got, want,
	       got == want ? "OK" : "<-- MISMATCH");
	return (got == want ? 0 : 1);
}

main()
{
	unsigned long o[NLONG];
	int i, bad, fp0grp, nanbad;

	for (i = 0; i < NLONG; i++)
		o[i] = 0xdeadbeefL;

	ftunimp0_run(o);
	bad = 0;
	nanbad = 0;

	printf("ftest unimp_0 replicated: fsin.x (extended pi) -> fp0, fsin at %08lX\n",
	       o[I_PCV]);

	/* FIRST: is the machine even able to hold Motorola's DEF_FPREGS?  Every ftest sub-test
	   starts by loading the extended NaN 0x7fff0000 ffffffff ffffffff into all eight FP
	   registers and ends by requiring fp1-fp7 to be unchanged.  The BEFORE snapshot below
	   is taken between that load and the fsin, so nothing of the kernel's has run yet: if
	   it does not read back the value that was loaded, the FPU cannot represent it and
	   ftest cannot pass here for reasons that have nothing to do with the FPSP.  This check
	   exists because that is exactly what happens under Amiberry, and a bare "failed" from
	   Motorola's harness would otherwise have been charged to our glue. */
	for (i = 0; i < 8; i++)
		if (o[I_IFP + i * 3 + 0] != 0x7FFF0000L ||
		    o[I_IFP + i * 3 + 1] != 0xFFFFFFFFL ||
		    o[I_IFP + i * 3 + 2] != 0xFFFFFFFFL) {
			printf("  FPU CANNOT HOLD DEF_FPREGS: group %d loaded 7FFF0000 FFFFFFFF FFFFFFFF,\n",
			       i);
			printf("                              read back %08lX %08lX %08lX before any trap\n",
			       o[I_IFP + i * 3], o[I_IFP + i * 3 + 1], o[I_IFP + i * 3 + 2]);
			nanbad++;
		}
	if (nanbad)
		printf("  -> %d of 8 FP registers mangled by the LOAD alone; every ftest sub-test\n"
		       "     begins with this load, so ftest's \"failed\" is not about the FPSP.\n",
		       nanbad);

	/* Which of the eight 12-byte groups the FMOVEM block puts fp0 in is an encoding
	   detail, so find it by content instead of assuming: fp0 is the only group that
	   changed across the trap. */
	fp0grp = -1;
	for (i = 0; i < 8; i++) {
		if (o[I_SFP + i * 3 + 0] != o[I_IFP + i * 3 + 0] ||
		    o[I_SFP + i * 3 + 1] != o[I_IFP + i * 3 + 1] ||
		    o[I_SFP + i * 3 + 2] != o[I_IFP + i * 3 + 2]) {
			if (fp0grp < 0)
				fp0grp = i;
			else {
				printf("  FP group %d ALSO changed: %08lX %08lX %08lX -> %08lX %08lX %08lX  <-- MISMATCH\n",
				       i,
				       o[I_IFP + i * 3], o[I_IFP + i * 3 + 1], o[I_IFP + i * 3 + 2],
				       o[I_SFP + i * 3], o[I_SFP + i * 3 + 1], o[I_SFP + i * 3 + 2]);
				bad++;
			}
		}
	}
	if (fp0grp < 0) {
		printf("  no FP register changed at all -- the fsin did nothing  <-- MISMATCH\n");
		bad++;
	} else {
		printf("  (the changed FP group is index %d of 8)\n", fp0grp);
		bad += show("fp0[0]", o[I_SFP + fp0grp * 3 + 0], 0xbfbf0000L);
		bad += show("fp0[1]", o[I_SFP + fp0grp * 3 + 1], 0x80000000L);
		bad += show("fp0[2]", o[I_SFP + fp0grp * 3 + 2], 0x00000000L);
	}

	bad += show("fpcr",  o[I_SFPC + 0], 0x00000000L);
	bad += show("fpsr",  o[I_SFPC + 1], 0x08000208L);
	bad += show("fpiar", o[I_SFPC + 2], o[I_PCV]);
	bad += show("ccr",   o[I_SCCR],     o[I_ICCR]);

	for (i = 0; i < 15; i++)
		if (o[I_SREGS + i] != o[I_IREGS + i]) {
			printf("  %-8s got %08lX  want %08lX  <-- MISMATCH (clobbered across the trap)\n",
			       regname[i], o[I_SREGS + i], o[I_IREGS + i]);
			bad++;
		}

	printf("\nFTUNIMP0 bad=%d nanbad=%d\n", bad, nanbad);
	printf("FTUNIMP0-DONE\n");
	exit(0);
}
