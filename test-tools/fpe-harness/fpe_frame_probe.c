/*
 * fpe_frame_probe.c -- drive the NetBSD/m68k FPE over synthesized exception frames on a
 * big-endian m68k host, so that "what does the emulator do with a vector-60 frame" is a
 * measurement instead of a reading.  (2026-08-27, round 10)
 *
 * FIRST-PARTY.  Nothing here is derived from the emulator under build/fpe-src/; this is the
 * same kind of seam src/fpe_glue.c is, minus the kernel.  It links the extracted tree
 * unmodified and supplies the four things the kernel supplies: ufetch_short, copyin, copyout
 * and panic.
 *
 * WHY IT EXISTS.  The Amiberry bed cannot raise vector 60 at all -- its Exception(60) site is
 * guarded on `currprefs.fpu_model` being non-zero, so on every LC060 rig this lane benches on
 * the two 12-byte immediate forms arrive as ordinary vector-11 frames
 * (docs/contracts/FPE-R10-VEC60.md 8.1).  The routing half of the round-10 fix is therefore
 * metal-only.  The EMULATION half is not: the emulator is portable C, the frame is a struct,
 * and the question "given this frame and these instruction bytes, what comes out" can be asked
 * directly.  That is what this does.
 *
 * WHAT IT PROVES AND WHAT IT DOES NOT.
 *   proves    the emulator accepts a format-0 frame whose PC is the faulting instruction;
 *             the extended immediate is fetched, converted and used arithmetically;
 *             is_advance comes out 16, i.e. the resume PC is right for a 16-byte instruction;
 *             packed decimal is refused, and how;
 *             fmovem.l to 2 or 3 control registers is MIS-emulated, which is why the arm
 *             refuses that class rather than passing it through;
 *             the vector-11 double-immediate case is unchanged.
 *   does NOT  say anything about src/fpe040.s, the vector table, the frame the 68060 actually
 *             stacks, or AMIX's signal path.  Those are static analysis plus metal.
 *
 * Build and run:  sh test-tools/fpe-harness/run.sh
 * Host:           m68k-linux-gnu-gcc (big-endian, ILP32) under qemu-m68k user mode.
 */

#include <sys/cdefs.h>
#include <sys/types.h>
#include <sys/signal.h>
#include <sys/siginfo.h>
#include <sys/signalvar.h>
#include <machine/frame.h>
#include "fpu_emulate.h"


extern void exit();
extern int setjmp();
extern void longjmp();

/*
 * The redirected CPU type.  src/fpe-compat/m68k/m68k.h renames the emulator's `cputype` to
 * this and carries NetBSD's encoding, where CPU_68060 is 3.  Set to 3 so the harness asks the
 * same questions the LC060 kernel does; the only reader in the tree is inside a "#if 0".
 */
int fpe_cputype = 3;

/* ------------------------------------------------------------------ the user-memory model */
/*
 * "User" memory is two plain arrays and their real host addresses are the user addresses.
 * Everything outside them faults, which is what makes ufetch_short's failure arm reachable and
 * keeps a decode bug from walking off into the harness's own data.
 */
#define UMEM_SZ		256
#define DMEM_SZ		64

static unsigned char umem[UMEM_SZ];	/* the instruction stream */
static unsigned char dmem[DMEM_SZ];	/* an operand area for the register-indirect cases */

static long nfetch, nfetchfail, ncopyin, ncopyout, ncopyfail;

static int
uvalid(a, n)
	unsigned long a;
	int n;
{
	unsigned long b;

	b = (unsigned long)(void *)umem;
	if (a >= b && (a + n) <= (b + UMEM_SZ))
		return 1;
	b = (unsigned long)(void *)dmem;
	if (a >= b && (a + n) <= (b + DMEM_SZ))
		return 1;
	return 0;
}

int
ufetch_short(uaddr, valp)
	const void *uaddr;
	u_short *valp;
{
	nfetch++;
	if (!uvalid((unsigned long)uaddr, 2)) {
		nfetchfail++;
		return 14;			/* EFAULT */
	}
	*valp = *(const u_short *)uaddr;
	return 0;
}

int
copyin(from, to, n)
	char *from;
	char *to;
	int n;
{
	int i;

	ncopyin++;
	if (!uvalid((unsigned long)from, n)) {
		ncopyfail++;
		return 14;
	}
	for (i = 0; i < n; i++)
		to[i] = from[i];
	return 0;
}

int
copyout(from, to, n)
	char *from;
	char *to;
	int n;
{
	int i;

	ncopyout++;
	if (!uvalid((unsigned long)to, n)) {
		ncopyfail++;
		return 14;
	}
	for (i = 0; i < n; i++)
		to[i] = from[i];
	return 0;
}

/*
 * panic -- the eleven emulator sites.  The kernel unwinds through fpe_longjmp and delivers
 * SIGILL (frozen decision 8); the harness unwinds the same way and reports it, so a case that
 * reaches one is visible as a distinct outcome rather than as a dead process.
 */
static long panicjb[256];
static int panicked;
static char *panicmsg;

void
panic(fmt, a1, a2, a3, a4)
	char *fmt;
	long a1, a2, a3, a4;
{

	panicked = 1;
	panicmsg = fmt;
	longjmp(panicjb, 1);
}

/*
 * printf is NOT defined here: DEBUG_FPE is not defined, so the emulator's 64 printf sites are
 * all preprocessed away and the only caller left is the harness itself.  It uses the host's.
 */

/* ------------------------------------------------------------------------- the test driver */

#define V11_VOFF	44		/* 11 * 4 -- F-line */
#define V60_VOFF	240		/* 60 * 4 -- unimplemented effective address */

struct testcase {
	char	*name;
	int	format;			/* exception frame format nibble */
	int	voff;			/* vector offset */
	int	ilen;			/* bytes of instruction to place at umem */
	unsigned char ibytes[24];
	int	nextpc_off;		/* what to put in the frame's PC field, for format 4 */
	int	fp0_preload;		/* 1 = preload fp0 with 1.0 */
	int	d1;			/* seed for d1 (dynamic fmovem register list) */
	int	a0_dmem;		/* 1 = point a0 at dmem */
	int	dmem_ext;		/* 1 = put 1.0 extended at dmem */
	int	exp_ret;		/* expected fpu_emulate() return: 0, or -1 for an abort */
	int	exp_signo;		/* ... and the ksi_signo it aborted with, 0 if none */
	int	exp_adv;		/* expected f_pc - faulting pc */
	unsigned int exp_fp0[3];	/* expected fp0, or all-ones for "not checked" */
	unsigned int exp_fpcr;		/* expected FPCR, or all-ones for "not checked" */
	unsigned int exp_fpsr;		/* expected FPSR, or all-ones for "not checked" */
};

#define NOCHK	0xffffffff

static unsigned int one_ext[3]  = { 0x3fff0000, 0x80000000, 0x00000000 };	/* 1.0 */
static unsigned int two_ext[3]  = { 0x40000000, 0x80000000, 0x00000000 };	/* 2.0 */
static unsigned int thr_ext[3]  = { 0x40000000, 0xc0000000, 0x00000000 };	/* 3.0 */
static unsigned int pi_ext[3]   = { 0x40000000, 0xc90fdaa2, 0x2168c235 };	/* pi */
static unsigned int hlf_ext[3]  = { 0x40000000, 0xe0000000, 0x00000000 };	/* 3.5 */

static struct testcase tests[] = {

/* ---- T1: the round-10 death, form 1.  fmove.x #1.0,fp0 on the four-word vector-60 frame. */
{ "T1 v60 fmove.x #1.0,fp0", 0, V60_VOFF, 16,
  { 0xf2,0x3c, 0x48,0x00,  0x3f,0xff,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00 },
  0, 0, 0, 0, 0,
  0, 0, 16, { 0x3fff0000, 0x80000000, 0x00000000 }, 0x00000000, 0x00000000 },

/* ---- T2: the operand is really USED, not merely copied.  fadd.x #2.0,fp0 with fp0 = 1.0. */
{ "T2 v60 fadd.x #2.0,fp0 (fp0=1.0)", 0, V60_VOFF, 16,
  { 0xf2,0x3c, 0x48,0x22,  0x40,0x00,0x00,0x00, 0x80,0x00,0x00,0x00, 0x00,0x00,0x00,0x00 },
  0, 1, 0, 0, 0,
  0, 0, 16, { 0x40000000, 0xc0000000, 0x00000000 }, 0x00000000, 0x00000000 },

/* ---- T3: full mantissa, so a wrong operand offset cannot pass.  fmove.x #pi,fp0. */
{ "T3 v60 fmove.x #pi,fp0", 0, V60_VOFF, 16,
  { 0xf2,0x3c, 0x48,0x00,  0x40,0x00,0x00,0x00, 0xc9,0x0f,0xda,0xa2, 0x21,0x68,0xc2,0x35 },
  0, 0, 0, 0, 0,
  0, 0, 16, { 0x40000000, 0xc90fdaa2, 0x2168c235 }, 0x00000000, 0x00000000 },

/* ---- T4: the round-10 death, form 2.  fmove.p #<packed>,fp0 -- the unsupported format.
 *      REGISTERED: fpu_emul_arith's else-arm returns SIGFPE before any effective address is
 *      decoded, so the abort carries signo 8 with NOTHING enabled-and-raised -- which is the
 *      undecodable class frozen decision 8 turns into SIGILL -- and is_advance is still 4 on a
 *      16-byte instruction.  That mis-advance is what FPE-R10-VEC60.md 5.4's rewind exists for. */
{ "T4 v60 fmove.p #<packed>,fp0", 0, V60_VOFF, 16,
  { 0xf2,0x3c, 0x4c,0x00,  0x00,0x01,0x00,0x00, 0x31,0x41,0x59,0x26, 0x53,0x58,0x97,0x93 },
  0, 0, 0, 0, 0,
  -1, SIGFPE, 4, { NOCHK, NOCHK, NOCHK }, 0x00000000, 0x00000000 },

/* ---- T5: fmovem.x (a0)+,<dynamic list in d1> -- the third vector-60 class, and supported:
 *      fpu_emul_fmovm reads the list out of frame->f_regs when word1 bit 11 is set. */
{ "T5 v60 fmovem.x (a0)+,dyn(d1)", 0, V60_VOFF, 4,
  { 0xf2,0x18, 0xd8,0x10 },
  0, 0, 0x80, 1, 1,
  0, 0, 4, { 0x3fff0000, 0x80000000, 0x00000000 }, NOCHK, NOCHK },

/* ---- T6: fmovem.l #imm,fpcr/fpsr -- the fourth class, and the one the arm REFUSES.
 *      REGISTERED, and this is the evidence for the refusal: the emulator reports SUCCESS,
 *      advances 8 where the instruction is 12 bytes, loads FPCR from the FIRST longword and
 *      never delivers the second one to FPSR at all.  A silently wrong result and a resume
 *      address four bytes inside the operand. */
{ "T6 v60 fmovem.l #imm,fpcr/fpsr", 0, V60_VOFF, 12,
  { 0xf2,0x3c, 0x98,0x00,  0x00,0x00,0x10,0x00, 0x00,0x00,0x20,0x00 },
  0, 0, 0, 0, 0,
  0, 0, 8, { NOCHK, NOCHK, NOCHK }, 0x00001000, 0x00000000 },

/* ---- T7: THE REGRESSION ROW.  fmove.d #3.5,fp0 on the eight-word format-4 vector-11 frame,
 *      which is round 8's witness case and the one form that already worked. */
{ "T7 v11 fmove.d #3.5,fp0 (fmt4)", 4, V11_VOFF, 12,
  { 0xf2,0x3c, 0x54,0x00,  0x40,0x0c,0x00,0x00, 0x00,0x00,0x00,0x00 },
  12, 0, 0, 0, 0,
  0, 0, 12, { 0x40000000, 0xe0000000, 0x00000000 }, 0x00000000, 0x00000000 },

/* ---- T8: what the AMIBERRY BED will deliver for the extended immediate -- the same
 *      instruction on a format-4 vector-11 frame.  Predicts the bench reading. */
{ "T8 v11 fmove.x #pi,fp0 (fmt4)", 4, V11_VOFF, 16,
  { 0xf2,0x3c, 0x48,0x00,  0x40,0x00,0x00,0x00, 0xc9,0x0f,0xda,0xa2, 0x21,0x68,0xc2,0x35 },
  16, 0, 0, 0, 0,
  0, 0, 16, { 0x40000000, 0xc90fdaa2, 0x2168c235 }, 0x00000000, 0x00000000 },

/* ---- T9: one of the four immediates that already work, on the frame the 68060 really gives
 *      them.  Control: these never reach vector 60 and nothing here may change them. */
{ "T9 v11 fmove.l #1234567,fp0 (fmt4)", 4, V11_VOFF, 8,
  { 0xf2,0x3c, 0x40,0x00,  0x00,0x12,0xd6,0x87 },
  8, 0, 0, 0, 0,
  0, 0, 8, { 0x40130000, 0x96b43800, 0x00000000 }, 0x00000000, 0x00000000 },
};

#define NTESTS	((int)(sizeof(tests) / sizeof(tests[0])))

static int failures;

static void
runone(t)
	struct testcase *t;
{
	struct frame f;
	struct fpframe fpf;
	ksiginfo_t ksi;
	unsigned int fault_pc, adv;
	int i, r;
	char *verdict;

	for (i = 0; i < UMEM_SZ; i++)
		umem[i] = 0;
	for (i = 0; i < DMEM_SZ; i++)
		dmem[i] = 0;
	for (i = 0; i < t->ilen; i++)
		umem[i] = t->ibytes[i];
	if (t->dmem_ext) {
		dmem[0] = 0x3f; dmem[1] = 0xff; dmem[2] = 0x00; dmem[3] = 0x00;
		dmem[4] = 0x80; dmem[5] = 0x00; dmem[6] = 0x00; dmem[7] = 0x00;
	}

	for (i = 0; i < (int)sizeof(fpf); i++)
		((char *)&fpf)[i] = 0;
	for (i = 0; i < 16; i++)
		f.f_regs[i] = 0;
	f.F_t.tf_pad = 0;
	f.f_stackadj = 0;
	f.f_sr = 0x0000;			/* user mode */
	f.f_format = t->format;
	f.f_vector = t->voff;

	fault_pc = (unsigned int)(unsigned long)(void *)umem;
	if (t->format == 4) {
		f.f_fmt4.f_fa = 0;
		f.f_fmt4.f_pcfi = fault_pc;
		f.f_pc = fault_pc + t->nextpc_off;
	} else {
		f.f_pc = fault_pc;
	}
	if (t->fp0_preload) {			/* 1.0, extended */
		fpf.fpf_regs[0] = 0x3fff0000;
		fpf.fpf_regs[1] = 0x80000000;
		fpf.fpf_regs[2] = 0x00000000;
	}
	f.f_regs[1] = t->d1;
	if (t->a0_dmem)
		f.f_regs[8] = (int)(unsigned long)(void *)dmem;

	ksi.ksi_signo = 0; ksi.ksi_code = 0; ksi.ksi_errno = 0;
	ksi.ksi_addr = (void *)0; ksi.ksi_trap = 0;
	panicked = 0; panicmsg = (char *)0;

	if (setjmp(panicjb) == 0)
		r = fpu_emulate(&f, &fpf, &ksi);
	else
		r = -2;

	adv = f.f_pc - fault_pc;

	verdict = "ok";
	if (panicked)
		verdict = "PANIC";
	else if (r != t->exp_ret)
		verdict = "RET MISMATCH";
	else if ((int)adv != t->exp_adv)
		verdict = "ADVANCE MISMATCH";
	else if (t->exp_signo != 0 && ksi.ksi_signo != t->exp_signo)
		verdict = "SIGNO MISMATCH";
	else if (t->exp_fp0[0] != NOCHK &&
	    (fpf.fpf_regs[0] != t->exp_fp0[0] || fpf.fpf_regs[1] != t->exp_fp0[1] ||
	     fpf.fpf_regs[2] != t->exp_fp0[2]))
		verdict = "FP0 MISMATCH";
	else if (t->exp_fpcr != NOCHK && fpf.fpf_fpcr != t->exp_fpcr)
		verdict = "FPCR MISMATCH";
	else if (t->exp_fpsr != NOCHK && fpf.fpf_fpsr != t->exp_fpsr)
		verdict = "FPSR MISMATCH";
	if (verdict[0] != 'o')
		failures++;

	printf("%-38s ret=%-3d adv=%-3d fp0=%08x %08x %08x fpcr=%08x fpsr=%08x  %s\n",
	    t->name, r, (int)adv,
	    fpf.fpf_regs[0], fpf.fpf_regs[1], fpf.fpf_regs[2],
	    fpf.fpf_fpcr, fpf.fpf_fpsr, verdict);
	if (panicked)
		printf("      panic: %s\n", panicmsg);
	if (r != 0 && !panicked)
		printf("      ksi signo=%d code=%d addr=+%d   raised&enabled=%08x\n",
		    ksi.ksi_signo, ksi.ksi_code,
		    (int)((unsigned int)(unsigned long)ksi.ksi_addr - fault_pc),
		    fpf.fpf_fpsr & fpf.fpf_fpcr & 0x0000ff00);
	if (t->a0_dmem)
		printf("      a0 advanced by %d\n",
		    (int)((unsigned int)f.f_regs[8] -
			  (unsigned int)(unsigned long)(void *)dmem));
}

int
main()
{
	int i;

	/*
	 * The layout assertions src/fpe_glue.c makes at compile time, made here at run time on
	 * the same header.  If the harness's struct frame is not the kernel's, nothing below
	 * means anything.
	 */
	printf("struct frame: tf_sr@%d tf_pc@%d F_u@%d regs[15]@%d fmt4.f_fa@%d fmt4.f_fslw@%d\n",
	    (int)(long)&(((struct frame *)0)->F_t.tf_sr),
	    (int)(long)&(((struct frame *)0)->F_t.tf_pc),
	    (int)(long)&(((struct frame *)0)->F_u),
	    (int)(long)&(((struct frame *)0)->F_t.tf_regs[15]),
	    (int)(long)&(((struct frame *)0)->F_u.F_fmt4.f_fa),
	    (int)(long)&(((struct frame *)0)->F_u.F_fmt4.f_fslw));
	printf("expected:                 68        70      76           60             76             80\n\n");

	for (i = 0; i < NTESTS; i++)
		runone(&tests[i]);

	printf("\nufetch %ld (%ld failed)  copyin %ld  copyout %ld (%ld failed)\n",
	    nfetch, nfetchfail, ncopyin, ncopyout, ncopyfail);
	printf("%d of %d cases matched their registered expectation\n",
	    NTESTS - failures, NTESTS);
	exit(failures ? 1 : 0);
	return 0;
}
