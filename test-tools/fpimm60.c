/* fpimm60.c -- THE VECTOR-60 PROBE.  One form per invocation, named by argv[1], so a refusal
 * names itself and cannot be misattributed.  (2026-08-27, round 10)
 *
 * Successor to the round-10 `fpimm` probe, which found the defect: on a real 68LC060 the two
 * FP immediate formats whose operand is TWELVE bytes -- extended-precision real and packed
 * decimal -- died with SIGSYS while the other five worked.  The seven original forms are
 * reproduced here byte for byte so a round-11 run is directly comparable; three forms are new.
 *
 * WHY THE 68060 TREATS THEM DIFFERENTLY.  It computes FP effective addresses in the INTEGER
 * unit, and the twelve-byte immediate formats are the ones it does not implement, so it raises
 * vector 60 -- "FP unimplemented effective address" -- before any F-line path runs.  The
 * soft-FPU lane's only attach point was vector 11, so it never saw them.
 * docs/contracts/FPE-R10-VEC60.md.
 *
 * BUILD IT AT -O0.  gcc 2.7.2.3 constant-folds floating point at any optimisation level, which
 * silently replaces the thing under test.  Round 10 recorded that trap and it applies here.
 *   m68k-cbm-sysv4-gcc -O0 -o fpimm60 fpimm60.c
 * And disassemble any surprising result before believing it -- also round 10's rule.  Two
 * traps found while writing this one:
 *   * objdump MIS-SYNCS after the raw `.long` operands and renders the following bytes as
 *     nonsense instructions.  Check the BYTES against the encoding table below, not the
 *     mnemonics it prints after an immediate.
 *   * this compiler emits Motorola syntax and REWRITES opcodes on the way out, so a literal
 *     `moveq` inside an asm block comes out as a bare `mov` that GNU as 2.8.1 rejects.  Every
 *     mnemonic here goes through gcc's `%.` size marker and every immediate through an
 *     operand, so the compiler spells the dialect.
 *
 * The opwords are written RAW (.short/.long) rather than left to the assembler, so the source
 * specifier under test is exactly the one intended.  Encoding, 68881/68882 cpGEN with R/M = 1:
 *     word0 = 0xF23C                (cpid 1, mode 7 reg 4 = immediate)
 *     word1 = 0x4000 | (src << 10)  (dst = fp0, opmode = FMOVE = 0)
 *       src 000 L long int      -> 0x4000 + 4 bytes      computed by the IU  -> vector 11
 *       src 001 S single        -> 0x4400 + 4 bytes      computed            -> vector 11
 *       src 010 X extended      -> 0x4800 + 12 bytes     NOT computed        -> VECTOR 60
 *       src 011 P packed dec    -> 0x4C00 + 12 bytes     NOT computed        -> VECTOR 60
 *       src 100 W word int      -> 0x5000 + 2 bytes      computed            -> vector 11
 *       src 101 D double        -> 0x5400 + 8 bytes      computed            -> vector 11
 *       src 110 B byte int      -> 0x5800 + 2 bytes      computed            -> vector 11
 *
 * REGISTERED OUTCOMES, per docs/contracts/FPE-R10-VEC60.md 8:
 *   l s w d b   values, exit 0.  THE REGRESSION SET -- unchanged by the vector-60 arm, and
 *               'd' in particular is the 12-byte instruction with an 8-byte operand that has
 *               always worked.
 *   x X         values, exit 0.  Round 10: SIGSYS.  This is the fix.
 *   p           SIGILL (4).  The vendored emulator has no packed-decimal support at all --
 *               fpu_explode has no FTYPE_BCD case -- so this is a HONEST refusal, not a fix.
 *               Round 10: SIGSYS.  The improvement is that it is now counted (fpe_ea_pack_n,
 *               fpe_undecoded_n, fpe_rewind_n) and correctly classified.
 *   m           value, exit 0.  fmovem.x with a DYNAMIC register list, the third vector-60
 *               class; the emulator implements it.
 *   c           SIGILL (4).  fmovem.l to two control registers, the fourth class, which the
 *               arm REFUSES on purpose: the emulator would load both registers from the first
 *               longword and resume four bytes inside the operand.
 */
#include <stdio.h>
#include <signal.h>

union dbits {
	double d;
	unsigned long l[2];
};

static char *what = "?";

static void gotsig(s)
int s;
{
	printf("SIGNAL %d on form '%s' -- THIS FORM WAS REFUSED\n", s, what);
	fflush(stdout);
	_exit(20 + s);
}

static void show(tag, d)
char *tag;
double d;
{
	union dbits u;
	char b[200];
	u.d = d;
	sprintf(b, "%.17g", d);
	printf("RESULT form=%-8s value=%-26s bits=%08lx%08lx\n", tag, b, u.l[0], u.l[1]);
	fflush(stdout);
}

main(argc, argv)
int argc;
char **argv;
{
	double r;
	unsigned long cr, sr, sel;
	static unsigned long xbuf[3];
	char *f;

	signal(SIGILL, gotsig);
	signal(SIGFPE, gotsig);
	signal(SIGSEGV, gotsig);
	signal(SIGSYS, gotsig);
	signal(SIGBUS, gotsig);
	signal(SIGEMT, gotsig);

	f = (argc > 1) ? argv[1] : "long";
	what = f;
	printf("fpimm60: form '%s' -- about to execute the raw immediate opword\n", f);
	fflush(stdout);

	if (f[0] == 'l') {			/* long int immediate, value 1234567 */
		__asm__ __volatile__ (
			".short 0xf23c, 0x4000\n\t.long 0x0012d687\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("long", r);
	} else if (f[0] == 's') {		/* single immediate, value 1.5f */
		__asm__ __volatile__ (
			".short 0xf23c, 0x4400\n\t.long 0x3fc00000\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("single", r);
	} else if (f[0] == 'x') {		/* extended immediate, value 1.0 -- round 10's own */
		__asm__ __volatile__ (
			".short 0xf23c, 0x4800\n\t.long 0x3fff0000, 0x80000000, 0x00000000\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("extended", r);
	} else if (f[0] == 'X') {		/* extended immediate, pi -- ALL 64 mantissa bits,
						 * so an operand read at the wrong offset cannot
						 * accidentally produce the right answer.
						 * Expect 3.1415926535897932 */
		__asm__ __volatile__ (
			".short 0xf23c, 0x4800\n\t.long 0x40000000, 0xc90fdaa2, 0x2168c235\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("extended-pi", r);
	} else if (f[0] == 'p') {		/* PACKED DECIMAL immediate, value +2.5E+000 */
		__asm__ __volatile__ (
			".short 0xf23c, 0x4c00\n\t.long 0x00000002, 0x50000000, 0x00000000\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("packed", r);
	} else if (f[0] == 'w') {		/* word int immediate, value -1234 */
		__asm__ __volatile__ (
			".short 0xf23c, 0x5000\n\t.short 0xfb2e\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("word", r);
	} else if (f[0] == 'd') {		/* double immediate, value 3.5.  THE REGRESSION ROW:
						 * 12-byte instruction, 8-byte operand, computed by
						 * the IU, arrives on vector 11, always worked */
		__asm__ __volatile__ (
			".short 0xf23c, 0x5400\n\t.long 0x400c0000, 0x00000000\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("double", r);
	} else if (f[0] == 'b') {		/* byte int immediate, value 100 */
		__asm__ __volatile__ (
			".short 0xf23c, 0x5800\n\t.short 0x0064\n\t"
			"fmove%.d %%fp0,%0" : "=m" (r) : : "memory");
		show("byte", r);
	} else if (f[0] == 'm') {		/* fmovem.x (a0)+,<DYNAMIC list in d1>.
						 * word1 0xD810: to-FPU, dynamic post-increment,
						 * list register d1; d1 = 0x80 selects fp0 alone.
						 * The buffer holds 1.0 extended. */
		/* EVERY MNEMONIC GOES THROUGH `%.`, and that is not style.  This compiler emits
		 * Motorola syntax and rewrites opcodes on the way out -- a literal `moveq` comes
		 * out as a bare `mov` that GNU as 2.8.1 then rejects, and a literal `#0x80` is the
		 * wrong immediate prefix for the dialect.  `move%.l` and a `g` operand let the
		 * compiler spell both. */
		xbuf[0] = 0x3fff0000; xbuf[1] = 0x80000000; xbuf[2] = 0x00000000;
		sel = 0x80;			/* fp0 alone */
		__asm__ __volatile__ (
			"move%.l %1,%%a0\n\t"
			"move%.l %2,%%d1\n\t"
			".short 0xf218, 0xd810\n\t"
			"fmove%.d %%fp0,%0"
			: "=m" (r) : "g" (&xbuf[0]), "g" (sel) : "a0", "d1", "memory");
		show("fmovemx", r);
	} else if (f[0] == 'c') {		/* fmovem.l #imm,fpcr/fpsr -- word1 0x9800: to-FPU,
						 * register list 110 = FPCR + FPSR, so EIGHT bytes
						 * of immediate and a 12-byte instruction.  The
						 * values are mode/condition bits only: no exception
						 * ENABLE bit is set, so a success here cannot arm a
						 * trap for whatever runs next. */
		__asm__ __volatile__ (
			".short 0xf23c, 0x9800\n\t.long 0x00000030, 0x0f000000\n\t"
			"fmove%.l %%fpcr,%0\n\tfmove%.l %%fpsr,%1"
			: "=m" (cr), "=m" (sr) : : "memory");
		printf("RESULT form=fmovemlctl fpcr=%08lx fpsr=%08lx (wanted fpcr=00000030 fpsr=0f000000)\n",
		    cr, sr);
		fflush(stdout);
		/* leave the model as we found it, whatever happened above */
		cr = 0;
		__asm__ __volatile__ ("fmove%.l %0,%%fpcr" : : "m" (cr) : "memory");
	} else {
		printf("unknown form '%s'\n", f);
		return 2;
	}
	printf("FPIMM60_OK %s\n", f);
	fflush(stdout);
	return 0;
}
