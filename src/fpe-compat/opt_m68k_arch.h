/* opt_m68k_arch.h -- FIRST-PARTY stub for the NetBSD/m68k FPE.
 *
 * NetBSD's config(8) generates one of these per kernel to define M68020/M68030/M68040/M68060.
 * fpu_calcea.c includes it unconditionally and is the only file that does; pass 1 of the
 * round-1 probe stopped there and nowhere else.
 *
 * DELIBERATELY EMPTY, and that is a decision rather than a placeholder.  The only use of any
 * of those macros in the extracted tree is fpu_calcea.c:116-122, which sits INSIDE the
 * "#if 0" at fpu_calcea.c:103 -- so no M68xxx definition can change a single emitted
 * instruction.  Defining one would suggest otherwise.  See docs/contracts/
 * FPE-GLUE-DESIGN.md section 4.3.
 */
