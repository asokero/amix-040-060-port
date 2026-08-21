| usptrap.s -- ISSUE-52: latch the user stack pointer, u.u_ar0 and u_comm at the
| NOTICE that kills PID 1.  (2026-08-21)
|
| THE FAULT.  With the 68040 emulation core fixed (ISSUE-49) the kernel boots and
| runs, and PID 1 dies at exec:
|
|     NOTICE: User BUS ERROR at 40001FC0, PC:80000012 FAULT:6 PID:1 CMD:
|
| Three things are already established from the image, without a boot:
|
|   * **`0x40001FC0` is `u + 0x1FC0`** -- the exact constant `_start` loads into
|     `%sp` (`0x3e R_68K_32 u+0x00001fc0`), i.e. the kernel stack top inside the
|     u-area.  It is not a random address and it is not a user address.
|   * **`PC 0x80000012` is init's own text**, so the icode's `trap #0` exec
|     SUCCEEDED and /bin/init is mapped and running.  The icode's own
|     `lea %pc@(L%stack),%sp` (icode+0, 0x4FFB0170) is fine.
|   * **The user stack lives at `userstack` = 0xC0800000** (per
|     `patch_execstk.py` / EXEC-INITIALSTK-PATCH-SPEC).  A correct USP would be
|     near there.
|
| So init is running with a **kernel-shaped stack pointer**, and its first stack
| access faults on the supervisor-only u-area.  FAULT:6 = FLTBOUNDS.
|
| WHY THIS IS NOT THE OLD init-hang.  `wb040.s` -- "THE init-hang fix" -- describes
| this exact class ("init's lea never set USP -> systrap read the syscall args from
| a stale kernel USP = garbage").  That fix IS present: `wb040.o` is in the base
| link list of both the shipped 260818-02 lineage and this one.  So the write-back
| replay is in, and this is a second instance of the class from a different cause.
|
| THE STATIC LEAD, and it is what this unit is here to test.  The saved-register
| pointer `u.u_ar0` (the absolute symbol `U_AR0` = `u + 0x864`) is written by ONE
| routine and read by several:
|
|     u_trap  0x5a490:  movel %d4,u+0x864        ; d4 = %fp + 8   -- SETS it
|     systrap 0x5a940:  moveal u+0x864,%a5       -- only READS it
|
| `setregs` (0x58b62), which exec calls to install the new user context, writes the
| new stack pointer through that pointer (`u_ar0[60]`, 0x58c12) and the new PC at
| `u_ar0+66` (0x58c22).  The **syscall** path does not set `u_ar0`; it consumes
| whatever is already there.  PID 1's first ever entry into the kernel is a syscall
| -- the icode's `trap #0` -- so if nothing established `u_ar0` for PID 1 before
| it, `setregs` writes the new SP through an inherited or stale pointer, the real
| saved-USP slot never receives it, and the trap exit restores the old value.  That
| is precisely the ISSUE-48 shape: a field consumed but not written, benign where
| memory happens to be favourable and fatal where it is not.
|
| It is a LEAD, not a conclusion.  What has not been established statically is
| whether some caller of `systrap` sets `u_ar0` first, and what value PID 1
| actually carries.  Both are runtime facts, and this unit reads them.
|
| HOW IT HOOKS.  patch_usptrap.py retargets the single `cmn_err` relocation at
| 0x5a640 -- the NOTICE call itself -- to this island, which latches, then
| tail-jumps into the real `cmn_err` so the NOTICE prints unchanged.  The same
| one-relocation idiom as patch_sdtfail.py and the ISSUE-49 latch.  **Blast radius
| on a healthy kernel is zero**: the only path here is one already reporting a
| fatal user fault.
|
| WHAT IT LATCHES, and why each one is worth a longword:
|
|   unt_usp    the ACTUAL user stack pointer at the fault.  If this equals the
|              reported fault address, init is dereferencing its own SP and the
|              stale-USP reading is confirmed outright.
|   unt_uar0   u.u_ar0 as systrap/setregs saw it.  A kernel-stack address near
|              u+0x1FC0 means PID 1 inherited proc0's pointer; a wild or zero
|              value means it was never established at all.  These are different
|              bugs with different fixes.
|   unt_comm0/1  the first eight bytes of u_comm (u + 0x3b0), which is the very
|              argument the NOTICE prints as CMD and which came out EMPTY.  This
|              separates the two readings of that emptiness: a genuine zero means
|              exec's u_comm store never landed -- itself evidence that exec wrote
|              through the wrong pointer -- whereas garbage means the string is
|              there but unprintable and the report path is what failed.
|   unt_u0/u1  the first two longwords of the u-area itself, as a cheap check on
|              whether the u-area page is coherent at all.
|
| PREDICTIONS, registered before the run:
|   * unt_usp == 0x40001FC0, matching the reported fault address exactly.
|   * unt_comm0 == 0 -- CMD is empty because u_comm was never written, not because
|     it could not be read.  If it comes back as ASCII ("/bin" = 0x2F62696E) then
|     exec DID write u_comm, the emptiness is a reporting artefact, and the
|     u_ar0 story is weakened badly.
|   * unt_uar0 in 0x4000xxxx.  A value outside the u-block refutes the inheritance
|     reading.
|   * unt_n == 1 -- this fires once; PID 1 dies and the system stops.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c usptrap.s -o build/usptrap.o
| Wire:     patch_usptrap.py (relocation retarget).  Externals: cmn_err, and the
|           absolute symbol u.
| ============================================================================

	.text
	.globl	unt_latch
unt_latch:
	moveml	%d0-%d1/%a0-%a1,%sp@-
	addql	&1,unt_n
	tstl	unt_have
	bnew	Lunt_go
	movel	&1,unt_have
	movel	&0x55535021,unt_magic2	| "USP!" -- this block executed at all
| --- the smoking gun: the user stack pointer the fault was taken against ---
	movel	%usp,%a0
	movel	%a0,unt_usp
| --- the saved-register pointer exec's setregs writes through ---
	movel	u+0x864,unt_uar0
| --- u_comm, the argument the NOTICE printed as an empty CMD ---
	movel	u+0x3b0,unt_comm0
	movel	u+0x3b4,unt_comm1
| --- and the head of the u-area itself, as a coherence check ---
	movel	u,unt_u0
	movel	u+4,unt_u1
Lunt_go:
	moveml	%sp@+,%d0-%d1/%a0-%a1
| The stack still holds cmn_err's return address and its seven arguments exactly as
| u_trap pushed them, so the NOTICE prints unchanged.
	jmp	cmn_err
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	unt_magic
unt_magic:
	.long	0x554e5421		| "UNT!"
| Times the user-fault NOTICE was reached.  1 on the PID 1 death.
	.globl	unt_n
unt_n:
	.long	0
	.globl	unt_have
unt_have:
	.long	0
| "USP!" once the latch body ran -- silence must not look like a negative result.
	.globl	unt_magic2
unt_magic2:
	.long	0
| The user stack pointer at the fault.  Compare against the reported fault address.
	.globl	unt_usp
unt_usp:
	.long	0
| u.u_ar0 -- the pointer setregs writes the new user SP through.
	.globl	unt_uar0
unt_uar0:
	.long	0
| The first eight bytes of u_comm (u + 0x3b0).
	.globl	unt_comm0
unt_comm0:
	.long	0
	.globl	unt_comm1
unt_comm1:
	.long	0
| The head of the u-area, as a coherence check.
	.globl	unt_u0
unt_u0:
	.long	0
	.globl	unt_u1
unt_u1:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
