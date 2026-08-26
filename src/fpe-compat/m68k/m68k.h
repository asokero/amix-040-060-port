/* m68k/m68k.h -- FIRST-PARTY header that SHADOWS NetBSD's m68k/m68k.h for the NetBSD FPE.
 *
 * NOT the NetBSD file, and deliberately not a copy of it.  NetBSD's m68k/m68k.h declares
 *
 *	extern int cputype;
 *
 * while AMIX <sys/systm.h>:18 declares
 *
 *	extern short cputype;		[ commented there with a list of CPU model codes ]
 *
 * and fpu_calcea.c includes both -- systm.h at :40, m68k.h at :42.  That is the only hard
 * compile failure in the whole package (contract 7.2 class C): same name, different type,
 * different encoding (NetBSD CPU_68060 == 3 against AMIX's 60).
 *
 * The fix has to live outside the extracted tree, so this header is placed EARLIER on the
 * include path than build/fpe-src/include and supplies exactly the two things fpu_calcea.c
 * takes from that file:
 * the CPU_* values, and a name for the CPU-type variable.  The name is redirected to a
 * glue-owned `int` carrying NetBSD's encoding, so if the read is ever reached it reads the
 * right number rather than 60.
 *
 * WHY A MACRO AND NOT -Dcputype=fpe_cputype ON THE COMMAND LINE.  A command-line -D rewrites
 * the token in EVERY translation unit, AMIX's own <sys/systm.h> declaration included, which
 * would turn the collision into `extern short fpe_cputype` versus `extern int fpe_cputype`
 * and merely move the failure.  Confining it to this header confines it to the one file that
 * includes it, and to the point AFTER systm.h has already been parsed.
 *
 * TODAY THE READ IS DEAD CODE, and that is measured rather than assumed: the only use of
 * cputype in the extracted tree is fpu_calcea.c:118, inside the "#if 0" block opened at :103.
 * fpe_cputype is maintained anyway -- fpuinit sets it and fpe_glue.c refreshes it per entry --
 * because "the compiler cannot reach it today" is not a property to build on.
 */

#ifndef _M68K_M68K_H_
#define _M68K_M68K_H_

extern int fpe_cputype;
#define cputype fpe_cputype

/* values for cputype, as NetBSD numbers them (m68k/m68k.h:66-71) */
#define CPU_68010	-1
#define CPU_68020	0
#define CPU_68030	1
#define CPU_68040	2
#define CPU_68060	3

#endif /* _M68K_M68K_H_ */
