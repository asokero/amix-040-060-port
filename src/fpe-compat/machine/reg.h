/* machine/reg.h -- FIRST-PARTY stub for the NetBSD/m68k FPE.
 *
 * Eight emulator files include this (fpu_add.c, fpu_div.c, fpu_explode.c, fpu_implode.c,
 * fpu_int.c, fpu_mul.c, fpu_sqrt.c, fpu_subr.c) and not one of them uses anything from it:
 * NetBSD's version declares `struct reg`, `struct fpreg`, the D0..A7/PS/PC index macros and
 * two process_read_* prototypes, and a grep over the extracted tree finds no reference to any
 * of them.  It is an inherited include, not a dependency.
 *
 * So this is empty on purpose rather than a transcription of NetBSD's header.  If a future
 * vendor import does start using one of those names the compile fails here, loudly, which is
 * the outcome to want.
 */
#ifndef _AMIX_FPE_MACHINE_REG_H_
#define _AMIX_FPE_MACHINE_REG_H_
#endif
