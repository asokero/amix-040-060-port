/*
 * test-pgrsv.c -- drive the real build/pgrsv-host.o (src/pgrsv.c, cross-compiled exactly as
 * relink-040-pgrsv.sh compiles it) through the reserve's rules, on qemu-m68k.  Run by
 * tools/test-pgrsv.sh.
 *
 * The harness provides what the kernel would: freemem, page_get's two file-statics, bclnlist,
 * curproc/proc_sched/proc_pageout, page_get(), cleanup(), wakeprocs() and sleep().  sleep() plays
 * pageout: each call frees a few pages, as page_free would before waking &freemem.
 *
 * The object's two SR helpers are privileged and qemu-m68k user mode aborts on them, so the host
 * object is built -DPGRSV_HOSTTEST, which leaves only those two helpers to this harness (against a
 * simulated SR); every other line is the shipped C.  The pass gates that the shipped object holds
 * both SR writes.  The test checks that every return leaves the SR as it found it and that the
 * reserve loop sleeps at IPL 4.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* what pgrsv.o imports */
int freemem;
unsigned int pgrsv_fmw, pgrsv_mpg;
char *bclnlist;
char *curproc, *proc_sched, *proc_pageout;
static char p_sched, p_pageout, p_user;

static int pg_calls, pg_bytes, pg_flags, sleeps, sleep_chan_ok, sleep_pri, wakes, wake_ok, cleans;
static int free_per_sleep, ipl_in_sleep;
static unsigned short sim_sr = 0x2000;	/* supervisor, IPL 0 */

char *page_get_c(unsigned int bytes, unsigned int flags)
{
	pg_calls++;
	pg_bytes = bytes;
	pg_flags = flags;
	return (char *) 0x1234000;
}

/* page_get returns its pointer in %a0 and %d0, as the AMIX compiler's callers expect. */
__asm__(".globl page_get\n"
	"page_get:\n"
	"	move.l 8(%sp),-(%sp)\n"
	"	move.l 8(%sp),-(%sp)\n"
	"	jsr page_get_c\n"
	"	addq.l #8,%sp\n"
	"	move.l %d0,%a0\n"
	"	rts\n");

int cleanup(void) { cleans++; bclnlist = 0; freemem += 1; return 0; }

int wakeprocs(char *chan, int how) { wakes++; wake_ok = chan == proc_pageout && how == 1; return 0; }

int sleep(char *chan, int pri)
{
	sleeps++;
	sleep_chan_ok = chan == (char *) &freemem;
	sleep_pri = pri;
	ipl_in_sleep = (sim_sr >> 8) & 7;
	freemem += free_per_sleep;
	return 0;
}

/* what pgrsv.o exports */
extern char *pgrsv_get(unsigned int bytes, unsigned int flags);
extern int pgrsv_pages;
extern unsigned long pgrsv_magic, pgrsv_calls, pgrsv_waits, pgrsv_fails;

/* src/pgrsv.c's two SR helpers, against a simulated SR (built -DPGRSV_HOSTTEST: qemu-m68k user
 * mode aborts on a privileged SR move instead of raising a signal). */
int pgrsv_spl(void) { int s = sim_sr; sim_sr = 0x2400; return s; }
void pgrsv_splx(int s) { sim_sr = s; }

static int fails;

static void check(const char *name, int ok)
{
	printf("  [%s] %s\n", ok ? "ok" : "FAIL", name);
	fails += !ok;
}

static void reset(int fm)
{
	freemem = fm;
	pgrsv_fmw = 0;
	pgrsv_mpg = 3845;			/* max_page_get as the r6 image initialises it */
	bclnlist = 0;
	curproc = &p_user;
	pgrsv_pages = 20;
	pg_calls = pg_bytes = pg_flags = sleeps = sleep_chan_ok = sleep_pri = wakes = wake_ok = 0;
	cleans = 0;
	free_per_sleep = 4;
	ipl_in_sleep = -1;
	sim_sr = 0x2000;
	pgrsv_calls = pgrsv_waits = pgrsv_fails = 0;
}

int main(void)
{
	char *r;

	proc_sched = &p_sched;
	proc_pageout = &p_pageout;

	printf("pgrsv_get against the page-out reserve rules:\n");
	reset(30);
	check("initial image: magic \"pgrv\", pgrsv_pages 20", pgrsv_magic == 0x70677276 && pgrsv_pages == 20);

	reset(100);
	r = pgrsv_get(8192, 1);
	check("plenty of memory: page_get once, same arguments, its result returned, no sleep",
	      pg_calls == 1 && pg_bytes == 8192 && pg_flags == 1 && r == (char *) 0x1234000 && sleeps == 0);
	check("SR restored after the fast path", sim_sr == 0x2000);

	reset(2 + 20 - 1);			/* 8 KiB = 2 pages: one short of the reserve */
	r = pgrsv_get(8192, 1);
	check("below the reserve, can wait: sleeps until npages+reserve would remain",
	      sleeps == 1 && freemem >= 22 && pg_calls == 1 && r == (char *) 0x1234000);
	check("the sleep is the stock one: &freemem, PSWP+2, at IPL 4", sleep_chan_ok && sleep_pri == 2
	      && ipl_in_sleep == 4);
	check("pageout woken with PRMPT, freemem_wait bumped, counted", wakes == 1 && wake_ok
	      && pgrsv_fmw == 1 && pgrsv_waits == 1);
	check("SR restored after the wait", sim_sr == 0x2000);

	reset(0);
	free_per_sleep = 1;
	r = pgrsv_get(4096, 1);
	check("from zero: loops until 21 pages are free (21 sleeps), then page_get", sleeps == 21
	      && freemem == 21 && pg_calls == 1);

	reset(10);
	r = pgrsv_get(4096, 0);
	check("below the reserve, may not wait: 0 returned, page_get not called, counted",
	      r == 0 && pg_calls == 0 && sleeps == 0 && pgrsv_fails == 1);
	check("SR restored after the refusal", sim_sr == 0x2000);

	reset(5);
	curproc = &p_sched;
	r = pgrsv_get(4096, 1);
	check("sched is exempt: straight to page_get", pg_calls == 1 && sleeps == 0);

	reset(5);
	curproc = &p_pageout;
	r = pgrsv_get(8192, 1);
	check("pageout is exempt: straight to page_get", pg_calls == 1 && sleeps == 0);

	reset(5);
	r = pgrsv_get(3845 * 4096, 1);
	check("npages >= max_page_get: no reserve wait (page_get refuses it itself)", pg_calls == 1 && sleeps == 0);

	reset(5);
	pgrsv_pages = 0;
	r = pgrsv_get(4096, 1);
	check("pgrsv_pages 0 disables the reserve", pg_calls == 1 && sleeps == 0);

	reset(20);
	bclnlist = (char *) 1;
	free_per_sleep = 0;
	freemem = 20;
	r = pgrsv_get(4096, 1);				/* cleanup frees one page: 21 = want */
	check("pending i/o completions: cleanup() first, no sleep when that suffices", cleans == 1
	      && sleeps == 0 && pg_calls == 1);

	reset(21);
	r = pgrsv_get(4096, 1);
	check("exactly npages+reserve free: no wait (boundary)", sleeps == 0 && pg_calls == 1);
	reset(20);
	r = pgrsv_get(1, 0);
	check("one page short: refused (boundary, 1 byte = 1 page)", r == 0 && pg_calls == 0);

	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return fails != 0;
}
