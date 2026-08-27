/* sys/types.h -- FIRST-PARTY stub for the host-side FPE frame harness.
 * The emulator includes this in fifteen files and takes exactly one thing from it: NULL,
 * which AMIX's own <sys/types.h> also defines and which fpu_calcea.c:382 needs.  Every other
 * type it uses (uint32_t, u_short, ...) comes from src/fpe-compat/sys/cdefs.h, which is on the
 * include path ahead of the extracted tree exactly as in the kernel build.  Anything a future
 * vendor import adds to this dependency fails loudly here rather than silently elsewhere.
 */
#ifndef _AMIX_FPEH_SYS_TYPES_H_
#define _AMIX_FPEH_SYS_TYPES_H_
#ifndef NULL
#define NULL	0
#endif
#endif
