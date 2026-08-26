/* sys/cdefs.h -- FIRST-PARTY compatibility header for the NetBSD/m68k FPE.
 *
 * NOT third-party material.  Nothing under build/fpe-src/ may be edited, so everything the emulator
 * needs and AMIX does not provide is supplied from this directory instead, and the include
 * order in relink-040-fpe.sh puts it ahead of build/fpe-src/include (see docs/contracts/
 * FPE-GLUE-DESIGN.md 3).
 *
 * WHY THIS FILE IS THE INJECTION POINT.  Every one of the twenty extracted .c files includes
 * <sys/cdefs.h> before anything else, and AMIX SVR4 has no such header at all -- measured:
 * pass 1 of the round-1 compile probe stopped nineteen of the twenty here.  So this is the
 * single place a type or macro can be introduced without touching an extracted byte.
 *
 * THE TYPE GAP IS REAL AND UNAVOIDABLE.  AMIX <sys/types.h> spells the unsigned integers
 * uchar_t / ushort_t / uint_t / ulong_t and has neither the C99 uint32_t family nor the BSD
 * u_char family.  uint32_t alone appears throughout the package (fpu_emulate.h:84 is where
 * every file stopped in the probe).
 *
 * -traditional REJECTS `signed char`, so int8_t is a plain `char` below.  That is correct on
 * m68k, where plain char is signed, and it is the only spelling this compiler accepts.
 */

#ifndef _SYS_CDEFS_H_
#define _SYS_CDEFS_H_

#define __KERNEL_RCSID(n, s)
#define __RCSID(s)
#define __BEGIN_DECLS
#define __END_DECLS
#define __P(x)			x
#define __unused
#define __dead
#define __predict_true(x)	(x)
#define __predict_false(x)	(x)
#define __CTASSERT(x)
#define __arraycount(a)		(sizeof(a) / sizeof((a)[0]))
#ifndef __inline
#define __inline		__inline__
#endif

#include <sys/types.h>

/* BSD short names.  AMIX has the *_t spellings only. */
typedef unsigned char	u_char;
typedef unsigned short	u_short;
typedef unsigned int	u_int;
typedef unsigned long	u_long;

/* C99 fixed-width names.  Absent from AMIX SVR4 entirely.  m68k ILP32. */
typedef char			int8_t;		/* -traditional rejects `signed char` */
typedef unsigned char		uint8_t;
typedef short			int16_t;
typedef unsigned short		uint16_t;
typedef int			int32_t;
typedef unsigned int		uint32_t;
typedef long long		int64_t;
typedef unsigned long long	uint64_t;

#endif /* _SYS_CDEFS_H_ */
