/* machine/endian.h -- FIRST-PARTY stub for the NetBSD/m68k FPE.
 * Reached from <sys/ieee754.h>.  AMIX has no <machine/endian.h>; the m68k is big-endian and
 * that is the whole content NetBSD's version contributes here.
 */
#ifndef _AMIX_FPE_MACHINE_ENDIAN_H_
#define _AMIX_FPE_MACHINE_ENDIAN_H_
#define _LITTLE_ENDIAN	1234
#define _BIG_ENDIAN	4321
#define _PDP_ENDIAN	3412
#define _BYTE_ORDER	_BIG_ENDIAN
#define LITTLE_ENDIAN	_LITTLE_ENDIAN
#define BIG_ENDIAN	_BIG_ENDIAN
#define PDP_ENDIAN	_PDP_ENDIAN
#define BYTE_ORDER	_BYTE_ORDER
#endif
