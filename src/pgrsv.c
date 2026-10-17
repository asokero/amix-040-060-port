/*
 * pgrsv.c -- a free-page reserve in front of page_get (DRIVER-LINE-8; opt-in, relink-040-pgrsv.sh).
 *
 * THE DEADLOCK.  Stock page_get waits only while freemem < npages: every caller may take the last
 * page.  When it is a user fault that takes it, pageout can be the next to ask -- its push of a dirty
 * file page goes ufs_putpage -> ufs_bmap -> bread -> getfreeblk, and a buffer-cache buffer is a
 * kmem_zalloc -> sptalloc -> segkmem_alloc -> page_get(KM_SLEEP).  pageout then sleeps on &freemem
 * waiting for itself, and the system stops.  Observed on the 32 MB rig during an install (the I3
 * savestate, 2026-10-06).  SVR4.0 has the same loop (3B2 vm/vm_page.c, page_get's wait).
 *
 * THE FIX, SVR4.2's shape (common/uts/mem/vm_page.c, page_get's reqfree; vm_pageout.c, minpagefree):
 * ordinary callers must leave pgrsv_pages free pages behind them; kernel memory may use the reserve.
 * relink-040-pgrsv.sh retargets every page_get call site except kernel memory's (segkmem_alloc, the
 * page-table allocators hat_ptalloc/hat_sdtalloc) and page_delmem's to pgrsv_get
 * (src/patch_pgrsv_sites.py), so kernel memory -- pageout's buffer included -- still reaches
 * page_get directly.  sched is exempt the way SVR4.2 exempts it, and pageout too: its own
 * allocations are kernel memory already, so this only closes a door SVR4.2 left open.  The waiting
 * is the stock waiting: the same channel, the same priority, the same counter page_free looks at;
 * it only starts pgrsv_pages earlier.  No new sleep is introduced at a point where the stock code could not sleep.
 *
 * Kept free of division and of 64-bit multiplication (the scan060 gate in the pass checks).
 */

#define PAGESHIFT	12		/* this line's page: page_get's own btopr is +4095, >>12 */
#define PAGEOFF		0xFFF
#define P_CANWAIT	0x1		/* page_get: bit 0 clear = fail rather than wait */
#define PSWP2		2		/* PSWP+2, page_get's own sleep priority */
#define PRMPT		1		/* page_get's wakeprocs(proc_pageout, 1) */
#define SR_IMP		0x2400		/* page_get's splimp: supervisor, IPL 4 */

extern int freemem;
extern unsigned int pgrsv_fmw;		/* page_get's file-static freemem_wait, exposed by the pass */
extern unsigned int pgrsv_mpg;		/* page_get's file-static max_page_get, exposed by the pass */
extern char *bclnlist;
extern char *curproc, *proc_sched, *proc_pageout;
extern char *page_get();
extern int cleanup(), wakeprocs(), sleep();

int pgrsv_pages = 20;			/* SVR4.2 MINPAGEFREE default; 0 disables the reserve */
unsigned long pgrsv_magic = 0x70677276;	/* "pgrv": read it before believing the counters */
unsigned long pgrsv_calls = 0;		/* calls through the reserve */
unsigned long pgrsv_waits = 0;		/* sleeps the reserve added (each one is a stock-shaped sleep) */
unsigned long pgrsv_fails = 0;		/* no-wait calls refused below the reserve */

#ifndef PGRSV_HOSTTEST
static int
pgrsv_spl()
{
	register int s;

	__asm__ __volatile__("mov.w %%sr,%0;mov.w &0x2400,%%sr" : "=d" (s));
	return s;
}

static void
pgrsv_splx(s)
	int s;
{
	__asm__ __volatile__("mov.w %0,%%sr" : : "d" (s));
}
#else
/* tools/test-pgrsv.sh: qemu-m68k user mode cannot run an SR move, so its harness provides these. */
extern int pgrsv_spl();
extern void pgrsv_splx();
#endif

char *
pgrsv_get(bytes, flags)
	unsigned int bytes;
	unsigned int flags;
{
	register unsigned int npages, want;
	register int s;

	pgrsv_calls++;
	npages = (bytes + PAGEOFF) >> PAGESHIFT;
	want = npages + pgrsv_pages;
	/* page_get refuses npages >= max_page_get outright; a reserve wait there could only hang. */
	if (pgrsv_pages > 0 && curproc != proc_sched && curproc != proc_pageout
	    && npages < pgrsv_mpg) {
		s = pgrsv_spl();
		while ((unsigned int) freemem < want) {
			if (!(flags & P_CANWAIT)) {
				pgrsv_splx(s);
				pgrsv_fails++;
				return (char *) 0;
			}
			if (bclnlist != (char *) 0) {
				pgrsv_splx(s);
				cleanup();
				s = pgrsv_spl();
				continue;
			}
			wakeprocs(proc_pageout, PRMPT);
			pgrsv_fmw++;
			pgrsv_waits++;
			sleep((char *) &freemem, PSWP2);
		}
		pgrsv_splx(s);
	}
	return page_get(bytes, flags);
}
