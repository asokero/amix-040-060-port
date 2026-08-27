/* sys/signal.h -- FIRST-PARTY stub for the host-side FPE frame harness.
 * The three signal numbers the emulator names, at their SVR4/AMIX values.  The harness
 * reports them by number, so a wrong value here would be visible in its output rather than
 * silent.
 */
#ifndef _AMIX_FPEH_SYS_SIGNAL_H_
#define _AMIX_FPEH_SYS_SIGNAL_H_
#define SIGILL		4
#define SIGFPE		8
#define SIGSEGV		11
#endif
