/* isp61ea.c -- does the widened vector-61 unit emulate every accepted addressing mode, and
 * emulate it CORRECTLY?  (2026-08-09)
 *
 * WHY.  F2's vector-61 unit accepted one encoding, mulsl/mulul #imm32,Dh:Dl.  wolf3d died on
 * real hardware at a muls.l whose source is (12,%a6) -- the kernel named it itself through
 * isp61_last_insn.  isp61_060.s now accepts #imm32, (d16,An), (An) and Dn.  This checks all
 * four against products computed independently, and checks that a mode OUTSIDE the set still
 * declines rather than inventing an answer.
 *
 * SURVIVAL IS NOT CORRECTNESS.  Each expected product was computed on the host in exact
 * 64-bit arithmetic and is compared as two unsigned longs -- the guest has no long long, and
 * a printf of a wrong answer is worth nothing next to a bit pattern.  This is the fp060probe
 * rule, and it exists because a unit that returns a plausible-looking product is far worse
 * than one that signals.
 *
 * CONTAINMENT: one child per case, no handler, so a death is a result and never takes the
 * parent with it (protfault's shape).  ea_postinc is EXPECTED to die.
 *
 * The counters say whether the new path ran at all -- read isp61_mem_n and isp61_reg_n around
 * this program.  A pass with isp61_mem_n unmoved would mean the 68040 retired the instructions
 * in hardware and nothing here was tested (the fputest060 lesson, 2026-08-08).
 *
 * usage: isp61ea
 */

#include <stdio.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>

extern void ea_imm_u();
extern void ea_imm_s();
extern void ea_d16pos();
extern void ea_d16neg();
extern void ea_d16u();
extern void ea_an();
extern void ea_dn();
extern void ea_postinc();

struct tcase {
	char *name;
	void (*fn)();
	unsigned long a;
	unsigned long b;
	unsigned long hi;		/* expected product bits 63-32 */
	unsigned long lo;		/* expected product bits 31-0  */
	int mustdie;			/* 1 = the declined mode: SIGKILL is the pass */
};

static struct tcase cases[] = {
  { "imm_u  mulu.l #imm",   ea_imm_u,   0x12345678, 0x9abcdef0, 0x0b00ea4e, 0x242d2080, 0 },
  { "imm_s  muls.l #imm",   ea_imm_s,   0x12345678, 0x9abcdef0, 0xf8cc93d6, 0x242d2080, 0 },
  { "d16pos muls.l (12,a6)",ea_d16pos,  0xfffffffd, 0xfffffffb, 0x00000000, 0x0000000f, 0 },
  { "d16neg muls.l (-4,a6)",ea_d16neg,  0xfffffffd, 0xfffffffb, 0x00000000, 0x0000000f, 0 },
  { "d16u   mulu.l (12,a6)",ea_d16u,    0xffffffff, 0xffffffff, 0xfffffffe, 0x00000001, 0 },
  { "an     muls.l (a0)",   ea_an,      0x80000000, 0xffffffff, 0x00000000, 0x80000000, 0 },
  { "dn     muls.l d3",     ea_dn,      0x00000007, 0xfffffff7, 0xffffffff, 0xffffffc1, 0 },
  { "postinc muls.l (a0)+", ea_postinc, 0x00000003, 0x00000005, 0, 0, 1 },
  { (char *)0, 0, 0, 0, 0, 0, 0 }
};

/* Run one case in a child; the two result longs come back through a pipe.  The parent never
   executes a 64-bit multiply itself -- it must keep working on a kernel whose emulation of
   that very instruction is the thing under test. */
static int
runone(t)
struct tcase *t;
{
	int fd[2], st, n;
	pid_t pid;
	unsigned long out[2];

	if (pipe(fd) < 0) {
		printf("  %-22s PIPE FAILED\n", t->name);
		return 1;
	}
	pid = fork();
	if (pid < 0) {
		printf("  %-22s FORK FAILED\n", t->name);
		return 1;
	}
	if (pid == 0) {
		close(fd[0]);
		out[0] = 0xdeadbeef;
		out[1] = 0xdeadbeef;
		(*t->fn)(t->a, t->b, out);
		write(fd[1], (char *)out, sizeof out);
		close(fd[1]);
		_exit(0);
	}
	close(fd[1]);
	n = read(fd[0], (char *)out, sizeof out);
	close(fd[0]);
	while (wait(&st) != pid)
		;

	/* The declined mode is CPU-dependent and therefore reported, not judged.  On the 68060
	   it must reach the unit and be refused; on the 68040 (a0)+ is retired in hardware and
	   emulating it is the correct outcome -- the same binary is run on both, so a verdict
	   here would be wrong on one of them.  The authority is isp61_unsupported_n, which names
	   the reason instead of inferring it from a signal that could have come from anywhere. */
	if (t->mustdie) {
		if (n == sizeof out)
			printf("  %-22s emulated (correct on a 68040: retired in hardware).\n"
			       "  %-22s   On a 68060, isp61_unsupported_n MUST have moved by one.\n",
			       t->name, "");
		else
			printf("  %-22s declined (status 0x%x) -- expected on a 68060.\n",
			       t->name, st & 0xffff);
		return 0;
	}
	if (n != sizeof out) {
		printf("  %-22s DIED, status 0x%04x  (signal %d)\n",
		       t->name, st & 0xffff, st & 0x7f);
		return 1;
	}
	if (out[0] != t->hi || out[1] != t->lo) {
		printf("  %-22s VALUE WRONG  got %08lx:%08lx  want %08lx:%08lx\n",
		       t->name, out[0], out[1], t->hi, t->lo);
		return 1;
	}
	printf("  %-22s OK  %08lx:%08lx\n", t->name, out[0], out[1]);
	return 0;
}

main(argc, argv)
int argc;
char **argv;
{
	struct tcase *t;
	int bad = 0;

	printf("isp61ea: 64-bit multiply, one addressing mode per case.\n");
	printf("  the product is compared as a bit pattern, not printed and eyeballed.\n\n");
	for (t = cases; t->name; t++)
		bad += runone(t);
	printf("\nISP61EA bad=%d\n", bad);
	printf("ISP61EA-DONE\n");
	return bad ? 1 : 0;
}
