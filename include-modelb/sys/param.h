/* include-modelb/sys/param.h -- Model-B (4 KiB page) logical page geometry.
 * Companion to include-modelb/sys/immu.h; read that file's header first.
 *
 * WHY THIS ONE MATTERS AT LEAST AS MUCH AS immu.h
 *
 * The Z3660 finding was about phystopfn, i.e. <sys/immu.h>.  But the macros a
 * driver or any compiled-in C reaches for far more often are here:
 *
 *     ptob(x)  btop(x)  btopr(x)  PAGESIZE  PAGEOFFSET  PAGEMASK
 *
 * all defined in terms of PAGESHIFT == 11 in the stock header.  A buffer sized
 * with btopr() against a 2 KiB page is HALF the pages the kernel will touch;
 * an offset masked with the stock PAGEOFFSET keeps a bit that is part of the
 * page offset on this kernel.  These are the same class of defect as the PFN
 * shift and are easier to write by accident, which is why the Model-B override
 * covers both headers or neither.
 *
 * MMU_PAGE* vs PAGE*.  Stock SVR4 distinguishes the hardware mapping page from
 * the logical system page.  On this port they are the SAME 4 KiB: the 68040
 * leaf page is 4 KiB (hat040.s maps pfn << 12) and Model B made the logical
 * page 4 KiB to match -- which is what `sysconfig(_CONFIG_PAGESIZE)` reports
 * since patch_sysconfig_pagesize.py.  Both sets are therefore converted, and
 * they are converted to the same value on purpose.
 */

#ifndef _MODELB_SYS_PARAM_H
#define _MODELB_SYS_PARAM_H

#include <sys/param_stock.h>

#define MODELB_PAGE_GEOMETRY_PARAM	1

/* hardware mapping page */
#undef	MMU_PAGESIZE
#define	MMU_PAGESIZE	0x1000
#undef	MMU_PAGESHIFT
#define	MMU_PAGESHIFT	12
#undef	MMU_PAGEOFFSET
#define	MMU_PAGEOFFSET	(MMU_PAGESIZE - 1)
#undef	MMU_PAGEMASK
#define	MMU_PAGEMASK	(~MMU_PAGEOFFSET)

/* logical system page -- identical on this port, deliberately */
#undef	PAGESIZE
#define	PAGESIZE	0x1000
#undef	PAGESHIFT
#define	PAGESHIFT	12
#undef	PAGEOFFSET
#define	PAGEOFFSET	(PAGESIZE - 1)
#undef	PAGEMASK
#define	PAGEMASK	(~PAGEOFFSET)

/* The unit conversions are written in terms of the shifts above and pick up
 * the new values at each use; restated here so this file is the single place
 * that answers "what does btopr() do on this kernel". */
#undef	mmu_ptob
#define	mmu_ptob(x)	((x) << MMU_PAGESHIFT)
#undef	mmu_btop
#define	mmu_btop(x)	(((unsigned)(x)) >> MMU_PAGESHIFT)
#undef	mmu_btopr
#define	mmu_btopr(x)	((((unsigned)(x) + MMU_PAGEOFFSET) >> MMU_PAGESHIFT))

#undef	ptob
#define	ptob(x)		((x) << PAGESHIFT)
#undef	btop
#define	btop(x)		(((unsigned)(x)) >> PAGESHIFT)
#undef	btopr
#define	btopr(x)	((((unsigned)(x) + PAGEOFFSET) >> PAGESHIFT))

#endif /* _MODELB_SYS_PARAM_H */
