/* machine/frame.h -- FIRST-PARTY forwarder for the NetBSD/m68k FPE.
 *
 * In a NetBSD tree <machine/...> is the port's own include directory and its frame.h is a
 * one-line forwarder into the shared m68k one.  This is that forwarder, with one deliberate
 * narrowing: it forwards to <m68k/cpuframe.h> and NOT to NetBSD's <m68k/frame.h>.
 *
 * WHY THE NARROWING.  Six emulator files include <machine/frame.h>, and every one of them
 * wants only `struct frame` and `struct fpframe`, both of which live in cpuframe.h -- checked
 * by grep over the whole extracted tree: not one FMT*, SSW*, FSLW*, CFSIZE or exframesize
 * name appears in it.  NetBSD's frame.h adds to those a large "#ifdef _KERNEL" block of
 * signal-frame machinery (sigframe_siginfo, getframe, buildcontext, sendsig_sigcontext,
 * m68040_writeback) written against NetBSD's siginfo_t and ucontext_t.  AMIX kernel compiles
 * define _KERNEL, so that block WOULD be compiled, and none of it is reachable or wanted --
 * sendsig here is AMIX's.  Forwarding one level deeper takes the types and leaves the
 * machinery, without editing or carrying a file that is never used.
 */

#ifndef _AMIX_FPE_MACHINE_FRAME_H_
#define _AMIX_FPE_MACHINE_FRAME_H_
#include <m68k/cpuframe.h>
#endif
