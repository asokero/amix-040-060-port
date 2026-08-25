| swapadd_dbg.s -- BLIZZARD F4 round 6: the one operand of swapconf's swapadd call that is
| not a compile-time constant, latched on both sides of the call.  (2026-08-25)
|
| Registered in docs/060-F4-M2-ATT6-PREREG-260825.md 3.1-3.2 and Table M, BEFORE this file
| existed.  Read that document first; this comment does not restate its tables.
|
| THE STOP THIS IS ABOUT.  Attempt 5 boot 2, and never before in this campaign:
|
|     PANIC: swapconf - swapadd (/dev/dsk/ced0s2,0,61440) failed - errno 22
|
| from swapconf+0xa0.  Attempts 3 and 4's control died one step EARLIER, at swapconf+0x42
| with error 20 (ENOTDIR) out of lookupname.  Here the lookup SUCCEEDED and the device was
| then rejected on its parameters -- and boots 1 and 3b of the same artifact, from the same
| byte-identical disk, got past the same call without failing and without printing anything.
|
| WHY THIS IS THE ROUND'S ANCHOR.  swapconf runs exactly once, from main+0x154, BEFORE
| userland.  So this block produces a reading on EVERY boot -- including the ones that panic
| in swapconf and never reach a user trap, where every other instrument in the round is silent
| by construction.  On a 15-minute clock against a machine that draws a different outcome
| every time, one guaranteed measurement per boot is worth more than four conditional ones.
|
| WHAT THE DISASSEMBLY GIVES FOR FREE.  swapconf builds the call out of the `swapfile`
| bootobj at .data 0xfe34, whose layout is pinned by the code's own relocations
| (swapfile+0x9c for &bo_vp, swapfile+0x90 for the flags word) and is the classic SVR4
| struct bootobj: bo_fstype[16] at +0, bo_name[128] at +0x10, bo_flags at +0x90,
| bo_offset at +0x94, bo_size at +0x98, bo_vp at +0x9c.  So
|
|     swapadd(bo_vp, bo_offset, bo_size, bo_name)
|
| and the panic's format string -- `swapconf - swapadd (%s,%d,%d) failed - errno %d`, read
| out of the image at .text 0xb3fee -- prints (bo_name, bo_offset, bo_size, errno).  ALL
| THREE PRINTED OPERANDS ARE STATIC .data LONGWORDS: bo_offset = 0x00000000 and
| bo_size = 0x0000F000, read directly out of the artifact before the boot.  The FOURTH
| argument, bo_vp, is the vnode lookupname just filled in and is not printed.
|
| Inside swapadd (0xb3138) the sequence is VOP_OPEN -> common_specvp -> VOP_GETATTR with
| va_mask = AT_SIZE (0x80), and the device size in BYTES lands in a local -- proved by the
| code's own warning string, which prints that local >> 9 as `partition size (%d)`.  Four
| branches reach `moveq #22,%d6`, and NONE of them prints anything:
|
|     E1  b31c0   va_size == 0
|     E2  b31c8   bo_offset*512 >= va_size (unsigned)  -- unreachable while bo_offset = 0
|     E3  b31e4   (bo_offset+bo_size)*512 > va_size  AND  swapinfo != 0
|     E4  b322e   after page rounding, end <= start, i.e. va_size < 0x1000
|
| while the one branch that does NOT fail -- the same over-run with swapinfo == 0 -- prints
| two lines and clamps.  Those two lines appear on NO boot of attempt 5, which is what pins
| the reading: with three static operands and no clamp warning anywhere,
| THE ONLY THING THAT CAN HAVE VARIED BETWEEN TWO BYTE-IDENTICAL BOOTS IS va_size.
|
| WHAT THIS LATCH GETS THAT THE PANIC LINE DOES NOT.
|   swa_si_pre    swapinfo BEFORE the call.  If it is 0 then E3 is excluded, so an EINVAL
|                 must be E1 or E4 -- which pins va_size below 0x1000 without ever reading
|                 va_size, a swapadd local this probe has no business reaching.
|   swa_si_start / swa_si_npgs   read AFTER a call that SUCCEEDED.  swapadd stores the area's
|                 start byte offset at si+8 and its length in pages at si+40 (its own
|                 comparisons at b3266 and b326e are what name those offsets), and both are
|                 derived from va_size by page rounding.  So a SUCCESSFUL boot measures
|                 va_size to 4 KiB -- the varying operand, read on the boots that work.
|   the three static operands   read at runtime and compared against their known file values.
|                 DTT0 maps the kernel image cache-inhibited (pre-reg 2.5), so a mismatch was
|                 read from RAM, not from a stale cache line, and it is a bigger finding than
|                 the stop.
|
| HOW IT IS BOUND.  `swapadd` is a FILE-LOCAL symbol, so it cannot be weakened and overridden.
| Instead the single R_68K_32 at .text 0xb409e -- swapconf's one `jsr swapadd` -- is
| retargeted here (src/patch_swapadd.py), and the real body is reached through a
| `swapadd_real` global objcopy adds at .text 0xb3138.  One call site, one relocation, and
| the rest of the kernel's view of swapadd is untouched.
|
| NOTHING HERE DEREFERENCES A USER ADDRESS.  The arguments are on the kernel stack, swapinfo
| is a kernel global, and the swapinfo entry it names is kernel arena -- read only after a
| null test.
|
| EVERYTHING IS HEX.  swa_ret 00000000 = success, 00000016 = EINVAL.  A swa_* slot reading
| ffffffff means NOT APPLICABLE, not zero.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c swapadd_dbg.s -o build/swapadd_dbg.o
| Wire:     src/patch_swapadd.py (relocation retarget).  Externals: swapadd_real, swapinfo
|           (nswapfiles is file-local and deliberately not referenced -- see below).
| ============================================================================

	SI_START =	8		| swapinfo entry: the area's start BYTE offset
	SI_FLAGS =	36		|                 the flags word swapadd masks at b3298
	SI_NPGS	 =	40		|                 its length in 4 KiB pages

	.text
	.globl	swa_latch
swa_latch:
| Stack at entry: %sp@(0) return address, then swapadd's four arguments --
|   %sp@(4) vp   %sp@(8) lowblk   %sp@(12) nblks   %sp@(16) swapname
| Every store below is memory-to-memory, so NO register is touched before the call and the
| argument frame the caller built is left exactly as it is.
	addql	&1,swa_n
	movel	%sp@(4),swa_vp
	movel	%sp@(8),swa_lowblk
	movel	%sp@(12),swa_nblks
	movel	%sp@(16),swa_name
	movel	swapinfo,swa_si_pre
| swa_nsf_pre / swa_nsf_post are registered in the pre-registration's block layout and are
| deliberately LEFT UNBOUND: `nswapfiles` is a FILE-LOCAL bss symbol (nm: `b nswapfiles`), so
| a reference from this unit cannot resolve to it, and reaching it would mean adding a global
| alias into .bss -- a pattern this tree has never used and would be introducing on a boot
| that has one 15-minute window.  The slots keep their ffffffff initialisers, which is exactly
| what this tree's convention means by NOT APPLICABLE.  `swapinfo` is a COMMON and therefore
| global, and it is the operand Table M actually decides on.

| Re-push the four arguments.  Four IDENTICAL instructions on purpose: each push moves the
| next argument into the very slot the previous one was read from.
	movel	%sp@(16),%sp@-		| swapname
	movel	%sp@(16),%sp@-		| nblks
	movel	%sp@(16),%sp@-		| lowblk
	movel	%sp@(16),%sp@-		| vp
	jsr	swapadd_real
	lea	%sp@(16),%sp		| drop our copy; the caller's frame is untouched

| %d0 is swapadd's return and swapconf tests it three instructions later, so it is preserved
| through everything below.  Only %a0 is used, and it is scratch under this ABI.
	movel	%d0,swa_ret
	movel	swapinfo,swa_si_post
	tstl	swapinfo
	beqs	Lswa_out
	moveal	swapinfo,%a0
	movel	%a0@(SI_START),swa_si_start
	movel	%a0@(SI_NPGS),swa_si_npgs
	movel	%a0@(SI_FLAGS),swa_si_flags
Lswa_out:
	movel	&0x53574221,swa_stamp	| "SWB!" -- the post-call body ran
	moveal	%d0,%a0			| stock swapadd's own epilogue hands the result back in
	rts				| both %d0 and %a0; match it rather than assume

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it returns a
| plausible number from whatever now lives there.  Every address for this block comes from
| tools/status-facts.sh against the artifact actually booted, at the load base actually
| observed; NEVER from an on-box nlist of /stand/unix, which is a different kernel because
| the one under test is installed into the BOOT SLICE.
	.globl	swa_magic
swa_magic:
	.long	0x53574121		| "SWA!"
	.globl	swa_n
swa_n:
	.long	0			| calls -- self-check: must read 1
	.globl	swa_vp
swa_vp:
	.long	0xffffffff		| arg1 = swapfile.bo_vp, the vnode lookupname filled in
	.globl	swa_lowblk
swa_lowblk:
	.long	0xffffffff		| arg2 = bo_offset -- static, must read 00000000
	.globl	swa_nblks
swa_nblks:
	.long	0xffffffff		| arg3 = bo_size   -- static, must read 0000F000
	.globl	swa_name
swa_name:
	.long	0xffffffff		| arg4 = &bo_name  -- static, must read &swapfile+0x10
	.globl	swa_si_pre
swa_si_pre:
	.long	0xffffffff		| swapinfo   before the call -- 0 excludes E3
	.globl	swa_nsf_pre
swa_nsf_pre:
	.long	0xffffffff		| REGISTERED BUT UNBOUND -- nswapfiles is file-local
	.globl	swa_ret
swa_ret:
	.long	0xffffffff		| 00000000 = success, 00000016 = EINVAL
	.globl	swa_si_post
swa_si_post:
	.long	0xffffffff
	.globl	swa_nsf_post
swa_nsf_post:
	.long	0xffffffff		| REGISTERED BUT UNBOUND -- see swa_nsf_pre
	.globl	swa_si_start
swa_si_start:
	.long	0xffffffff		| the area's start byte offset, if one was added
	.globl	swa_si_npgs
swa_si_npgs:
	.long	0xffffffff		| its length in 4 KiB pages -- va_size, to a page
	.globl	swa_si_flags
swa_si_flags:
	.long	0xffffffff
	.globl	swa_stamp
swa_stamp:
	.long	0			| "SWB!" once the post-call body ran
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
