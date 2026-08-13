/* include-modelb/sys/immu.h -- Model-B (4 KiB page frame) page geometry for
 * EVERYTHING compiled into this 68040 kernel (2026-08-01).
 *
 * WHY THIS FILE EXISTS
 *
 * The AMIX kernel this port targets has a 4 KiB page frame (Model B); the
 * shipped SVR4 headers describe the stock 68030 kernel's 2 KiB one.  Nothing
 * warns you.  A driver compiled against the stock headers gets
 *
 *     phystopfn(pa) == pa >> 11
 *
 * and the kernel maps the returned value at pfn << 12 -- i.e. it maps the
 * physical page at 2*pa.  A DIFFERENT PAGE, silently, with no error anywhere.
 * This is the same defect already fixed kernel-side for scrmmap / ammmap /
 * timmap / svgammap, and it was found again in the wild on 2026-07-31 in the
 * Z3660 drivers, whose compiled objects contained `moveq #11,%d1; lsrl %d1,%d0`
 * twice.  Until now the fix was a per-driver source rewrite
 * (va2000_modelb.py, z3660_modelb.py): correct-by-patcher, one patcher per
 * driver, and nothing at all for the next one.  This header makes it
 * correct-by-default.
 *
 * HOW IT IS REACHED.  The cross toolchain's gcc wrapper injects
 * `-I$AMIX_SYSROOT/usr/include` BEFORE every user -I, so a plain -I cannot
 * override a system header -- that is why the -I flags in AMIX_KERNEL_CFLAGS
 * pointing at vanilla/usr/include have in fact never been consulted for any
 * header the sysroot also provides.  The override is therefore installed by
 * building a sysroot MIRROR (src/mk_modelb_sysroot.sh -> AMIX_SYSROOT),
 * in which this file replaces <sys/immu.h> and the stock file remains reachable
 * as <sys/immu_stock.h>.
 *
 * WHAT IS AND IS NOT CONVERTED
 *
 * Converted: the page-FRAME facts a driver or any compiled-in C actually uses.
 * NOT converted, but POISONED so that any use is a COMPILE ERROR naming the
 * macro: the 68030 three-level table-geometry macros.  Their Model-B values
 * depend on the 040 table shape that hat040.s implements in assembler, they
 * have no audited C consumer today, and a plausible-looking wrong value here
 * would be far worse than a build failure.  If you hit one of those errors,
 * that is this file asking you to audit the site -- not to delete the poison.
 *
 * Verified by src/modelb_geom_probe.c, which fails to COMPILE unless
 * every constant below has the Model-B value, and at the object level by
 * src/check_page_geometry.py.
 */

#ifndef _MODELB_SYS_IMMU_H
#define _MODELB_SYS_IMMU_H

/* The stock header, reachable under its own name inside the mirror sysroot.
 * It brings the pte union, the ptbl_t, the PG_* bit names and the prototypes;
 * only its geometry constants are wrong here. */
#include <sys/immu_stock.h>

/* Marker: compiled-in C can #ifdef on this to prove it saw the Model-B set. */
#define MODELB_PAGE_GEOMETRY	1

/* --------------------------------------------------------------- converted */

#undef	NBPP
#define	NBPP		4096		/* bytes per page frame (Model B) */

#undef	PNUMSHFT
#define	PNUMSHFT	12		/* LOG2(NBPP): addr -> page number */

#undef	POFFMASK
#define	POFFMASK	0xFFF		/* offset within a page frame */

#undef	PG_ADDR
#define	PG_ADDR		0xFFFFF000	/* physical page address in a leaf PTE */

/* phystopfn / pfntophys / kvtopfn / pfntokv are defined in the stock header in
 * terms of PNUMSHFT, but the C preprocessor expanded nothing at definition
 * time -- they pick up the PNUMSHFT above at each USE.  Redefined here anyway,
 * identically, so that reading this file tells you what they are without a
 * second lookup, and so a stock-header revision cannot quietly change them. */
#undef	phystopfn
#define	phystopfn(paddr)	((u_int)(paddr) >> PNUMSHFT)
#undef	pfntophys
#define	pfntophys(pfn)		((pfn) << PNUMSHFT)
#undef	kvtopfn
#define	kvtopfn(vaddr)		(kvtophys(vaddr) >> PNUMSHFT)
#undef	pfntokv
#define	pfntokv(pfn)		((pfn) << PNUMSHFT)

/* ---------------------------------------------------------------- poisoned */
/* Each expands to sizeof() an undeclared struct: a compile error that names the
 * macro and the line, instead of a silently wrong 68030 table constant.
 * (`char x[-1]`-style asserts are proven to error on this gcc; so does this.) */

#undef	PNUMMASK
#define	PNUMMASK	(sizeof(struct modelb_unaudited_PNUMMASK))
#undef	PNDXMASK
#define	PNDXMASK	(sizeof(struct modelb_unaudited_PNDXMASK))
#undef	PGFNMASK
#define	PGFNMASK	(sizeof(struct modelb_unaudited_PGFNMASK))
#undef	pgndx
#define	pgndx(x)	(sizeof(struct modelb_unaudited_pgndx))
#undef	PAGNUM
#define	PAGNUM(x)	(sizeof(struct modelb_unaudited_PAGNUM))
#undef	mkpte
#define	mkpte(mode,pfn)	(sizeof(struct modelb_unaudited_mkpte))
#undef	svtop
#define	svtop(x)	(sizeof(struct modelb_unaudited_svtop))
#undef	ptosv
#define	ptosv(x)	(sizeof(struct modelb_unaudited_ptosv))

/* PAGOFF is just POFFMASK applied and is therefore correct above; kept
 * explicit because it is the one member of the PAGNUM/PAGOFF pair that
 * survives. */
#undef	PAGOFF
#define	PAGOFF(x)	(((uint)(x)) & POFFMASK)

#endif /* _MODELB_SYS_IMMU_H */
