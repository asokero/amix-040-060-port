/* sys/systm.h -- FIRST-PARTY stub for the host-side FPE frame harness.
 * AMIX's own systm.h declares `cputype` here, which is the collision src/fpe-compat/m68k/m68k.h
 * exists to resolve; the harness supplies the redirected `fpe_cputype` itself and this header
 * declares only the kernel primitives the emulator calls.  Full prototypes, because three of
 * these are compiler builtins and a K&R declaration of one is a warning on every file.
 */
#ifndef _AMIX_FPEH_SYS_SYSTM_H_
#define _AMIX_FPEH_SYS_SYSTM_H_
extern void panic(const char *, ...);
extern int printf(const char *, ...);
extern void *memcpy(void *, const void *, unsigned long);
extern int copyin(char *, char *, int);
extern int copyout(char *, char *, int);
#endif
