/* modelb_geom_probe.c -- compile-time proof that this compilation is seeing the
 * Model-B (4 KiB) page geometry (2026-08-01).
 *
 * Built by src/mk_modelb_sysroot.sh, twice: once through the mirror
 * sysroot, where it MUST compile, and once through the stock sysroot, where it
 * MUST FAIL.  The second half is what makes the first half evidence -- a probe
 * that passes either way tests nothing, which is the failure mode this project
 * has paid for before (a dead serial capture that looked like a clean result).
 *
 * Each assertion is a negative array size.  Verified on this gcc:
 *     "size of array `...' is negative"      -- with the line number.
 * Nothing here is executed or linked; the object exists only so the build has
 * something to fail on.
 *
 * K&R C, -traditional, no headers beyond the two under test.
 */

#include <sys/types.h>		/* uint / paddr_t: <sys/immu.h> assumes them,
				 * exactly as every driver that includes it does */
#include <sys/immu.h>
#include <sys/param.h>

/* The override was reached at all. */
#ifndef MODELB_PAGE_GEOMETRY
#include "modelb_geom_probe_ERROR_immu_h_override_not_reached"
#endif
#ifndef MODELB_PAGE_GEOMETRY_PARAM
#include "modelb_geom_probe_ERROR_param_h_override_not_reached"
#endif

/* <sys/immu.h>: the page frame. */
char modelb_assert_nbpp[(NBPP == 4096) ? 1 : -1];
char modelb_assert_pnumshft[(PNUMSHFT == 12) ? 1 : -1];
char modelb_assert_poffmask[(POFFMASK == 0xFFF) ? 1 : -1];
char modelb_assert_pg_addr[(PG_ADDR == 0xFFFFF000) ? 1 : -1];

/* The PFN conversions, checked through the macros rather than the constants,
 * because the macro is what a driver actually writes. */
char modelb_assert_phystopfn[(phystopfn(0x2000) == 2) ? 1 : -1];
char modelb_assert_pfntophys[(pfntophys(2) == 0x2000) ? 1 : -1];

/* <sys/param.h>: the logical page, and the unit conversions that are easier to
 * get wrong by accident than phystopfn ever was. */
char modelb_assert_pagesize[(PAGESIZE == 0x1000) ? 1 : -1];
char modelb_assert_pageshift[(PAGESHIFT == 12) ? 1 : -1];
char modelb_assert_pageoffset[(PAGEOFFSET == 0xFFF) ? 1 : -1];
char modelb_assert_mmu_pagesize[(MMU_PAGESIZE == 0x1000) ? 1 : -1];
char modelb_assert_ptob[(ptob(3) == 0x3000) ? 1 : -1];
char modelb_assert_btop[(btop(0x3000) == 3) ? 1 : -1];
char modelb_assert_btopr[(btopr(0x2001) == 3) ? 1 : -1];
