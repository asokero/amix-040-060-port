/* sys/signalvar.h -- FIRST-PARTY compatibility header for the NetBSD/m68k FPE.
 *
 * NetBSD's kernel signal structure is ksiginfo_t; AMIX's is k_siginfo_t (sys/siginfo.h:150),
 * and the two are not the same shape.  The emulator writes only four members of it -- see
 * fpu_emulate.c:54-59 -- so this declares exactly those four, and the glue translates from
 * this staging structure into AMIX's k_siginfo_t at fpe_glue.c's deliver path.
 *
 * The translation is not a formality: the emulator emits ksi_code 0 for every arithmetic
 * signal, so the SVR4 si_code has to be DERIVED from the FPSR the emulation left behind.
 * docs/contracts/FPE-INTEGRATION-CONTRACT.md 3.3 has the table; fpe_glue.c implements it.
 *
 * The <m68k/cpuframe.h> include is load-bearing and is here rather than in the .c files:
 * fpu_trig.c reaches `struct fpframe` ONLY through NetBSD's <sys/signalvar.h> chain
 * (contract 7.2 class A).  On AMIX that chain does not exist, so it terminates here.
 */

#ifndef _SYS_SIGNALVAR_H_
#define _SYS_SIGNALVAR_H_

#include <m68k/cpuframe.h>

typedef struct ksiginfo {
	int	ksi_signo;	/* SIGFPE / SIGILL / SIGSEGV */
	int	ksi_code;	/* 0 for every arithmetic signal -- see above */
	int	ksi_errno;
	void	*ksi_addr;	/* the emulator sets this to frame->f_pc */
	int	ksi_trap;
} ksiginfo_t;

#endif /* _SYS_SIGNALVAR_H_ */
