/* sys/siginfo.h -- FIRST-PARTY stub for the host-side FPE frame harness.
 * The two si_code values the emulator names, at their SVR4/AMIX values (sys/siginfo.h).
 * The whole k_siginfo_t machinery is the kernel glue's business and is not exercised here.
 */
#ifndef _AMIX_FPEH_SYS_SIGINFO_H_
#define _AMIX_FPEH_SYS_SIGINFO_H_
#define ILL_ILLOPC	1
#define SEGV_ACCERR	2
#endif
