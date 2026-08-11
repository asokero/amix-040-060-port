/* fpenab060.c -- do the five unmeasured ENABLED IEEE exception classes reach the right 68060
 * FPSP entry, and leave through the right call-out?  (2026-08-11)
 *
 * WHY.  F3 M4 wired vectors 49-54 into Motorola's FPSP.  The map is a permutation
 * (entry +0x00 = snan = vector 54 ... +0x28 = inex = vector 49) and it was verified statically
 * 9 of 9 from the built object's relocations -- but on hardware only SNAN has actually been
 * exercised.  Motorola's own suite cannot close the gap: its `enabled` group runs all six
 * sub-tests in one process and the first SIGFPE kills it (test.doc, quoted in ftest060.c).
 *
 * So this is the same shape fp060probe / ftunimp0 / isp61ea already use: ONE CHILD PER CLASS.
 * Required for two reasons, both from the audit: an accidental default-signal death must not
 * hide the classes after it, and sticky/accrued FPSR state from one case must not contaminate
 * the next.
 *
 * VALUES ARE MOTOROLA'S.  Every FPCR enable, input operand, instruction and expected
 * FP0/FPSR/FPIAR comes from dist/ftest.s via
 * amix-kernel-analysis/vm-map/F3-M4-UNMEASURED-CLASSES-AUDIT.md.  Nothing here was chosen to
 * make the test pass.
 *
 * SURVIVAL IS NOT CORRECTNESS, and neither is dying.  Each child must (a) take exactly one
 * SIGFPE, (b) come back with FP0/FPSR/FPIAR equal to Motorola's post-state.  The parent never
 * executes an FP instruction: the results travel as raw longs through a pipe, because the
 * thing under test is the FP path itself.
 *
 * READING A MISMATCH -- the audit gives the three-way split, and the kernel counters make it
 * immediate:
 *   wrong f60_vecNN_n moved      -> wrong vector reached the package: the MAP is wrong
 *   right vector, wrong class    -> right entry, wrong package destination
 *   counters right, state wrong  -> the package was right and the SIGNAL path changed it
 * Read isp61-style: counters around each child, not just at the end.
 *
 * usage: fpenab060            run all six (five unmeasured + SNAN as the control)
 */

#include <stdio.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

extern void fpe_operr();
extern void fpe_ovfl();
extern void fpe_unfl();
extern void fpe_dz();
extern void fpe_inex();
extern void fpe_snan();

/* The instruction's own address, exported by the assembly, so FPIAR is compared against the
   real label rather than against a constant typed in a second time. */
extern char fpe_operr_insn[], fpe_ovfl_insn[], fpe_unfl_insn[];
extern char fpe_dz_insn[], fpe_inex_insn[], fpe_snan_insn[];

/* Integer only.  No printf, no allocation, no FP -- the audit is explicit: the handler runs
   with clean FP state (sendsig saves the interrupted context first), so it must not look at
   FP0/FPSR/FPIAR, and it must RETURN so the snapshot in the assembly can run. */
static int sigs;

static void
onfpe(sig)
int sig;
{
	sigs++;
}

struct ecase {
	char *name;
	void (*fn)();
	char **insn;
	unsigned long fp0hi, fp0mid, fp0lo;
	unsigned long fpsr;
	int vec;			/* which f60_vecNN_n must move */
	char *cls;			/* which f60_<class>_n must move */
};

static char *op_i[1], *ov_i[1], *un_i[1], *dz_i[1], *in_i[1], *sn_i[1];

static struct ecase cases[] = {
  { "OPERR v52", fpe_operr, op_i, 0xffff0000,0x00000000,0x00000000, 0x01002080, 52, "operr" },
  { "OVFL  v53", fpe_ovfl,  ov_i, 0x7fff0000,0x00000000,0x00000000, 0x02001048, 53, "ovfl"  },
  { "UNFL  v51", fpe_unfl,  un_i, 0x00000000,0x40000000,0x00000000, 0x00000800, 51, "unfl"  },
  { "DZ    v50", fpe_dz,    dz_i, 0x40000000,0x80000000,0x00000000, 0x02000410, 50, "dz"    },
  { "INEX  v49", fpe_inex,  in_i, 0x50000000,0x80000000,0x00000000, 0x00000208, 49, "inex"  },
  { "SNAN  v54", fpe_snan,  sn_i, 0, 0, 0,                          0,          54, "snan"  },
  { (char *)0 }
};

static int
runone(t)
struct ecase *t;
{
	int fd[2], st, n, bad;
	pid_t pid;
	unsigned long out[6];

	if (pipe(fd) < 0) {
		printf("  %-10s PIPE FAILED\n", t->name);
		return 1;
	}
	pid = fork();
	if (pid < 0) {
		printf("  %-10s FORK FAILED\n", t->name);
		return 1;
	}
	if (pid == 0) {
		close(fd[0]);
		sigs = 0;
		signal(SIGFPE, onfpe);
		out[0] = out[1] = out[2] = out[3] = out[4] = 0xdeadbeef;
		(*t->fn)(out);
		out[5] = (unsigned long)sigs;
		write(fd[1], (char *)out, sizeof out);
		close(fd[1]);
		_exit(0);
	}
	close(fd[1]);
	n = read(fd[0], (char *)out, sizeof out);
	close(fd[0]);
	while (wait(&st) != pid)
		;

	if (n != (int)sizeof out) {
		printf("  %-10s DIED, status 0x%04x (signal %d) -- no handler return\n",
		       t->name, st & 0xffff, st & 0x7f);
		printf("  %-10s   read f60_vec%d_n: if it moved the wiring is right and the\n",
		       "", t->vec);
		printf("  %-10s   signal path is what killed us.\n", "");
		return 1;
	}

	bad = 0;
	if (out[5] != 1) {
		printf("  %-10s SIGFPE count %lu, want 1\n", t->name, out[5]);
		bad = 1;
	}
	/* SNAN's post-state is not pinned by the audit's table (it is the control, already proved
	   on silicon), so for it we check only that exactly one SIGFPE arrived and report state. */
	if (t->fpsr != 0) {
		if (out[0] != t->fp0hi || out[1] != t->fp0mid || out[2] != t->fp0lo) {
			printf("  %-10s FP0  got %08lx:%08lx:%08lx  want %08lx:%08lx:%08lx\n",
			       t->name, out[0], out[1], out[2], t->fp0hi, t->fp0mid, t->fp0lo);
			bad = 1;
		}
		if (out[3] != t->fpsr) {
			printf("  %-10s FPSR got %08lx  want %08lx\n", t->name, out[3], t->fpsr);
			bad = 1;
		}
	}
	if (out[4] != (unsigned long)t->insn[0]) {
		printf("  %-10s FPIAR got %08lx  want %08lx (the instruction's own address)\n",
		       t->name, out[4], (unsigned long)t->insn[0]);
		bad = 1;
	}
	if (!bad)
		printf("  %-10s OK  fp0 %08lx:%08lx:%08lx  fpsr %08lx  fpiar %08lx  sigs 1\n",
		       t->name, out[0], out[1], out[2], out[3], out[4]);
	printf("  %-10s   expect f60_vec%d_n +1 and f60_%s_n +1, entry/real/arith +1, done +0\n",
	       "", t->vec, t->cls);
	return bad;
}

main(argc, argv)
int argc;
char **argv;
{
	struct ecase *t;
	int bad = 0;

	op_i[0] = fpe_operr_insn;  ov_i[0] = fpe_ovfl_insn;  un_i[0] = fpe_unfl_insn;
	dz_i[0] = fpe_dz_insn;     in_i[0] = fpe_inex_insn;  sn_i[0] = fpe_snan_insn;

	printf("fpenab060: one ENABLED IEEE exception per child, Motorola's own fixture values.\n");
	printf("  the post-state is compared as bit patterns; the parent runs no FP at all.\n\n");
	for (t = cases; t->name; t++)
		bad += runone(t);
	printf("\nFPENAB060 bad=%d\n", bad);
	printf("FPENAB060-DONE\n");
	return bad ? 1 : 0;
}
