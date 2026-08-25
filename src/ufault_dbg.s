| ufault_dbg.s -- BLIZZARD F4 round 5: a census of the fatal user-fault NOTICE, so the
| userland wall can be told apart from the things that look like it.  (2026-08-25)
|
| THE WALL.  Attempt 4's arm-B boot got past swapconf, forked, exec'd, and then PID 1
| looped ~182,741 times on ONE line, identical every time:
|
|     NOTICE: User BUS ERROR at 4AFC0008, PC:C1027EAA FAULT:6 PID:1 CMD:/sbin/init
|
| and ended at the stock guard `Bad ucontext checksum (0xFFFFCFFF)in process: init`.
| No kernel panic anywhere (bt_walks = 0).  FAULT:6 = FLTBOUNDS (sys/fault.h).
|
| WHAT IS ALREADY KNOWN WITHOUT A BOOT, and what is therefore NOT worth a counter:
|
|   * PC 0xC1027EAA is not in /sbin/init at all.  init is ET_EXEC at 0x80000034 and is
|     dynamically linked against /usr/lib/libc.so.1, which this port maps at
|     UVSHM = 0xC1000000 (docs/contracts/AVAILRMEM-ACCOUNTING-AUDIT.md, src/sigkill_dbg.s:70).
|     0xC1027EAA - 0xC1000000 = 0x27EAA, which lands inside libc's `hsearch`, and the
|     instruction there is
|
|         tstl %a0@(0,%d2:l:8)        | a 4-byte READ, EA = %a0 + %d2*8
|
|     so 0x4AFC0008 = %a0 + %d2*8.  It is a DATA read, not an instruction fetch, and TST
|     never writes.
|   * 0x4AFC0000 is not a new number.  docs/ISSUE10-SETUPSH-WALL-260819.md:119 records the
|     identical value as a fabricated free-list link in /bin/sh, faulting at 4AFC0003 with
|     the same FAULT:6.  0x4AFC is the m68k ILLEGAL opcode word, and `4AFC 00nn` is the
|     exact byte pattern this compiler emits ahead of a switch dispatch -- i.e. the value
|     is TEXT BYTES sitting in a place a pointer should be.
|   * Nothing in init imports hsearch and nothing in libc calls it, so control flow was
|     ALREADY wrong before the data fault.  Which means the static reading stops here: the
|     one thing that separates "a corrupt pointer read by correct code" from "garbage
|     registers in code entered wild" is THE REGISTER SET AT THE FAULT, and no amount of
|     disassembly produces it.
|
| So this unit exists to read exactly that, plus the four other things attempt 4 could have
| had for free and did not take.
|
| WHERE IT HOOKS, AND WHY THAT SITE IS SAFE.  u_trap (0x5a47e) reports a fatal user fault
| with
|
|     cmn_err(CE_NOTE, "User BUS ERROR at %x, PC:%x FAULT:%x PID:%d CMD:%s\n",
|             fa, pc, fault, pid, u_comm)
|
| from the call at 0x5a63e, relocation at 0x5a640.  src/patch_usptrap.py already retargets
| that relocation to unt_latch (ISSUE-52); src/patch_ufault.py retargets it one step further
| to uft_latch, and uft_latch tail-jumps into unt_latch, which tail-jumps into cmn_err.  The
| ISSUE-52 latch keeps working unchanged and the NOTICE prints unchanged.  The only path
| that reaches any of this is one already reporting a fatal user fault, so a healthy kernel
| executes none of it.
|
| NOTHING HERE DEREFERENCES A USER ADDRESS.  Every read is of kernel memory: the argument
| frame cmn_err was about to consume, the u-area, curproc, the trap frame u_trap itself
| built, and rootdir.  A probe that faulted while reporting a fault would turn a NOTICE into
| a panic and cost the boot, so the user pages at PC and at the fault address are read
| host-side from the on-disk binaries instead, which is where they were read from above.
|
| THE FRAME LAYOUT, verified against this image rather than inherited:
|
|     u_trap+0x12  movel %d4,u+0x864     with %d4 = %fp+8   -- u.u_ar0 IS this fault's frame,
|                                          set at u_trap+0x12 and read here at u_trap+0x1c0
|     u_ar0+0            the USP `utraps` pushed -- i.e. the user A7
|     u_ar0+4   .. +63   nullvect_orig's 60 saved registers, d0-d7 then a0-a6
|     u_ar0+64  SR word      +66  PC long   (setregs writes the new PC at u_ar0+66)
|     u_ar0+70  format/vector word, high nibble = frame format
|     u_ar0+72  fault address    +76  FSLW      -- 68060 FORMAT 4 ONLY (framesz[4] = 16)
|
| THE REGISTER SLOTS ARE NAMED ONE LONGWORD LOW, and the correction is documented here
| rather than applied, because the VALUES are right and only the NAMES are wrong -- renaming
| the slots would silently re-interpret every register file attempts 4, 5 and 6 recorded.
| This file's first version modelled the frame as `u_ar0+0 .. +63 = d0-d7 then a0-a7`.  It is
| not: `u_ar0` points at the slot `utraps` pushed the USP into, and nullvect_orig's own 60
| bytes (d0-d7 then a0-a6 -- `moveml %d0-%fp,%sp@-`, 15 registers) begin one longword later.
| The self-checks below do not catch it because they are all at u_ar0+64 and above, which the
| wrong model and the right one agree on; what they DO prove is the base, because a long read
| at u_ar0+66 returns the PC only if u_ar0 is the USP slot (from the d0 slot it would return
| the format/vector word joined to the fault address).  So the 16-longword copy below stores:
|
|     uft_f_d0            <- the USP (user A7)
|     uft_f_d1 .. uft_f_a0   <- d0 .. d7
|     uft_f_a1 .. uft_f_a7   <- a0 .. a6
|
| Three independent confirmations from the attempt-6 metal capture, all on the same fault:
| `uft_f_d0` equalled `uft_f_usp` to the digit (and `uft_f_usp` is read from %usp by its own
| instruction, so under the old names that identity is an unexplained coincidence); the
| faulting EA composed exactly -- true a0 + true d2 * 8 = the recorded fault address, where
| the old names give a number 0x4AFC0006 away from it; and true a6 came out at USP+0x10, a
| frame pointer, where the old names put an odd value from another segment there.  The
| "uft_f_a7 != uft_f_usp" mismatch previously written off as a known-bad bench check is this
| off-by-one, and it was the instrument saying so.
|
| The 68040 stacks format 7 and puts a 16-bit SSW at +76 instead, so +72/+76 are read only
| when the format nibble is 4 and carry the sentinel 0xffffffff otherwise.  Never guessed:
| src/getfault040.s:39 and src/userspace040.s:91 read the same two offsets the same way.
|
| proc offsets p_brkbase@52, p_brksize@56, p_as@124 and curproc = *(u+0x730) are the ones
| src/hgfault040.s already uses, and u+0x730 -> curproc is visible in u_trap's own prologue.
|
| u_comm is taken from the pointer the NOTICE ITSELF was handed rather than from a
| hardcoded u-area offset -- src/usptrap.s says u+0x3b0 and src/sigkill_dbg.s says u+0x1c0,
| they cannot both be right for one kernel, and the argument frame cannot be wrong.
|
| WHAT EACH FIELD BUYS, and why each is worth a longword:
|
|   uft_n            the size of the loop, counted by the kernel rather than inferred from
|                    a screen.  Independent of fpi_ss_skip_n, which counts sendsig.
|   uft_same_fa/pc   how many faults REPEATED the first one's address and PC.  "identical
|                    every time" was an eyeball reading of a scrolling screen; this measures
|                    it.  same_pc far below n would mean the loop wanders.
|   uft_usp_min/max  THE DECIDER for the loop's shape.  If signal frames are stacking --
|                    delivery without a completed return -- the user stack marches DOWN
|                    monotonically and (uft_f_usp - uft_usp_min) / uft_n is one frame.  If
|                    the loop is stable, min == max == the first USP and nothing is stacking.
|                    These two longwords separate "runaway" from "steady state" outright.
|   uft_f_d0..a7     the register set the static analysis could not produce.  READ THESE
|                    THROUGH THE ONE-LONGWORD CORRECTION at the head of this file: the
|                    architectural %a0 and %d2 -- the two that compose the faulting EA --
|                    are in the slots named uft_f_a1 and uft_f_d3, and the architectural
|                    %a5, libc's GOT base, is in uft_f_a6.
|   uft_f_fslw       RW (bit 24, 1 = read) and TM (bits 18-16, 001 = user data,
|                    010 = user code).  TM says whether this was a data access or an
|                    instruction fetch, i.e. whether an I-cache reading is even admissible.
|   uft_f_brkbase/size  whether the fault address is anywhere near the break.  The ISSUE-10
|                    cure (src/hgfault040.s) grows the break for a user WRITE just past it;
|                    a read a gigabyte away from the break is not that bug, and this pair
|                    plus the FSLW settles it without argument.
|   uft_f_fpc/ffa    self-checks, not data: they must equal uft_f_pc and uft_f_fa.  If they
|                    do not, u_ar0 was not this fault's frame and every register below it is
|                    noise -- exactly the trap ISSUE-52 round 2 fell into (right value,
|                    wrong moment).  Same for uft_f_a7 against uft_f_usp.
|   uft_f_rootdir/   the open finding from attempt 4's DBG boot: rootdir->v_type read 0
|   _rd_vop/_rd_vt   (VNON) where the bench read 2 (VDIR), with v_op 16 bytes away correct.
|                    Read here under arm B, where swapconf SUCCEEDED.  VDIR here means the
|                    VNON belonged to the unarmed driver and collapses into the same
|                    write-back class; VNON here means a mounted-root defect that owes its
|                    own investigation.
|
| EVERYTHING IS HEX.  0x14 = ENOTDIR, FAULT 6 = FLTBOUNDS, v_type VNON 0 / VDIR 2.
| A uft_* slot reading ffffffff means that field was not applicable, not that it read zero.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c ufault_dbg.s -o build/ufault_dbg.o
| Wire:     src/patch_ufault.py (relocation retarget).  Externals: unt_latch, rootdir, and
|           the absolute symbol u.
| ============================================================================

	.text
	.globl	uft_latch
uft_latch:
	moveml	%d0-%d1/%a0-%a1,%sp@-
| Stack from here: sp@(16) return address, then cmn_err's seven arguments --
|   sp@(20) CE_NOTE   sp@(24) fmt   sp@(28) fa   sp@(32) pc
|   sp@(36) fault     sp@(40) pid   sp@(44) u_comm
	addql	&1,uft_n

| ---------------------------------------------------------------- every fault: the LAST block
	movel	%sp@(28),uft_l_fa
	movel	%sp@(32),uft_l_pc
	movel	%sp@(36),uft_l_fault
	movel	%usp,%a0
	movel	%a0,uft_l_usp
	movel	%a0,%d0

| The user stack watermarks.  Unsigned throughout: a user SP is an address, not a number.
	movel	uft_usp_min,%d1
	cmpl	%d1,%d0
	bccw	Luft_nomin
	movel	%d0,uft_usp_min
Luft_nomin:
	movel	uft_usp_max,%d1
	cmpl	%d1,%d0
	blsw	Luft_nomax
	movel	%d0,uft_usp_max
Luft_nomax:

| The trap frame, for the LAST block's format and FSLW.  u_trap set u.u_ar0 to this fault's
| own frame 430 bytes before it called the NOTICE, so this is current, not inherited.
	moveq	&-1,%d1
	movel	%d1,uft_l_fslw
	movel	u+0x864,%d0
	beqw	Luft_ncnt		| defensive: no frame, no reading
	moveal	%d0,%a0
	moveq	&0,%d0
	movew	%a0@(70),%d0
	movel	%d0,uft_l_fmt
	moveq	&12,%d1
	lsrl	%d1,%d0			| shift counts above 8 need a register on m68k
	cmpil	&4,%d0
	bnew	Luft_ncnt
	movel	%a0@(76),uft_l_fslw	| 68060 format-4 access-error frame only

| ---------------------------------------------------------------- repeat counters
Luft_ncnt:
	tstl	uft_have
	beqw	Luft_first
	movel	%sp@(28),%d0
	cmpl	uft_f_fa,%d0
	bnew	Luft_npc
	addql	&1,uft_same_fa
Luft_npc:
	movel	%sp@(32),%d0
	cmpl	uft_f_pc,%d0
	bnew	Luft_go
	addql	&1,uft_same_pc
	braw	Luft_go

| ---------------------------------------------------------------- the FIRST fault, once
Luft_first:
	movel	&1,uft_have
	movel	&0x55464621,uft_magic2	| "UFF!" -- silence must not look like a null result
	movel	%sp@(28),uft_f_fa
	movel	%sp@(32),uft_f_pc
	movel	%sp@(36),uft_f_fault
	movel	%sp@(40),uft_f_pid
	movel	%usp,%a0
	movel	%a0,uft_f_usp

| u_comm, through the very pointer the NOTICE was given -- so CMD on the screen and this
| block can never disagree about which string was read.
	moveal	%sp@(44),%a0
	movel	%a0,%d0
	beqw	Luft_proc
	movel	%a0@,uft_f_comm0
	movel	%a0@(4),uft_f_comm1

| curproc and the break -- the ISSUE-10 pre-screen row
Luft_proc:
	movel	u+0x730,%d0
	movel	%d0,uft_f_proc
	beqw	Luft_root
	moveal	%d0,%a0
	movel	%a0@(52),uft_f_brkbase
	movel	%a0@(56),uft_f_brksize
	movel	%a0@(124),uft_f_as

| rootdir, and the two fields attempt 4 saw disagree inside one in-core vnode
Luft_root:
	movel	rootdir,%d0
	movel	%d0,uft_f_rootdir
	beqw	Luft_frame
	moveal	%d0,%a0
	movel	%a0@(8),uft_f_rd_vop
	movel	%a0@(24),uft_f_rd_vt

| the trap frame: the CPU's own record of the fault, and the user register set
Luft_frame:
	movel	u+0x864,%d0
	movel	%d0,uft_f_ar0
	beqw	Luft_go
	moveal	%d0,%a0
	moveq	&0,%d0
	movew	%a0@(64),%d0
	movel	%d0,uft_f_sr
	movel	%a0@(66),uft_f_fpc	| must equal uft_f_pc, or u_ar0 is the wrong frame
	moveq	&0,%d0
	movew	%a0@(70),%d0
	movel	%d0,uft_f_fmt
	moveq	&12,%d1
	lsrl	%d1,%d0
	cmpil	&4,%d0
	bnew	Luft_regs		| not a 68060 format-4 frame: leave the sentinels
	movel	%a0@(72),uft_f_ffa	| must equal uft_f_fa
	movel	%a0@(76),uft_f_fslw
Luft_regs:
	lea	uft_f_d0,%a1
	moveq	&16,%d1
Luft_rl:
	movel	%a0@+,%a1@+		| the USP, then d0-d7, then a0-a6 -- so every slot
					| below is named one longword low.  See the frame
					| layout at the head of this file; the values are
					| right, the names are not, and the mapping is there
	subql	&1,%d1
	bnew	Luft_rl

Luft_go:
	moveml	%sp@+,%d0-%d1/%a0-%a1
| The stack still holds cmn_err's return address and its seven arguments exactly as u_trap
| pushed them, so the ISSUE-52 latch and then the NOTICE both run unchanged.
	jmp	unt_latch
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it returns a
| plausible number from whatever now lives there.  Every address for this block comes from
| tools/status-facts.sh against the artifact actually booted, at the load base actually
| observed; NEVER from an on-box nlist of /stand/unix, which is a different kernel because
| the one under test is installed into the BOOT SLICE.
	.globl	uft_magic
uft_magic:
	.long	0x55465421		| "UFT!"
	.globl	uft_n
uft_n:
	.long	0			| every fatal user-fault NOTICE, counted here
	.globl	uft_have
uft_have:
	.long	0
	.globl	uft_magic2
uft_magic2:
	.long	0			| "UFF!" once the first-fault body ran
	.globl	uft_same_fa
uft_same_fa:
	.long	0
	.globl	uft_same_pc
uft_same_pc:
	.long	0
	.globl	uft_usp_min
uft_usp_min:
	.long	0xffffffff		| starts at the top so the first fault always wins
	.globl	uft_usp_max
uft_usp_max:
	.long	0

| ---- the FIRST fault, latched once ------------------------------------------------------
	.globl	uft_f_fa
uft_f_fa:
	.long	0xffffffff
	.globl	uft_f_pc
uft_f_pc:
	.long	0xffffffff
	.globl	uft_f_fault
uft_f_fault:
	.long	0xffffffff
	.globl	uft_f_pid
uft_f_pid:
	.long	0xffffffff
	.globl	uft_f_usp
uft_f_usp:
	.long	0xffffffff
	.globl	uft_f_ar0
uft_f_ar0:
	.long	0xffffffff
	.globl	uft_f_proc
uft_f_proc:
	.long	0xffffffff
	.globl	uft_f_brkbase
uft_f_brkbase:
	.long	0xffffffff
	.globl	uft_f_brksize
uft_f_brksize:
	.long	0xffffffff
	.globl	uft_f_as
uft_f_as:
	.long	0xffffffff
	.globl	uft_f_sr
uft_f_sr:
	.long	0xffffffff
	.globl	uft_f_fpc
uft_f_fpc:
	.long	0xffffffff
	.globl	uft_f_fmt
uft_f_fmt:
	.long	0xffffffff
	.globl	uft_f_ffa
uft_f_ffa:
	.long	0xffffffff
	.globl	uft_f_fslw
uft_f_fslw:
	.long	0xffffffff
	.globl	uft_f_comm0
uft_f_comm0:
	.long	0xffffffff
	.globl	uft_f_comm1
uft_f_comm1:
	.long	0xffffffff
	.globl	uft_f_rootdir
uft_f_rootdir:
	.long	0xffffffff
	.globl	uft_f_rd_vop
uft_f_rd_vop:
	.long	0xffffffff
	.globl	uft_f_rd_vt
uft_f_rd_vt:
	.long	0xffffffff

| ---- the user register set, copied as sixteen consecutive longwords ---------------------
| The copy loop writes d0..d7 then a0..a7 into these in declaration order.  They must stay
| adjacent and in this sequence.
	.globl	uft_f_d0
uft_f_d0:
	.long	0xffffffff
	.globl	uft_f_d1
uft_f_d1:
	.long	0xffffffff
	.globl	uft_f_d2
uft_f_d2:
	.long	0xffffffff
	.globl	uft_f_d3
uft_f_d3:
	.long	0xffffffff
	.globl	uft_f_d4
uft_f_d4:
	.long	0xffffffff
	.globl	uft_f_d5
uft_f_d5:
	.long	0xffffffff
	.globl	uft_f_d6
uft_f_d6:
	.long	0xffffffff
	.globl	uft_f_d7
uft_f_d7:
	.long	0xffffffff
	.globl	uft_f_a0
uft_f_a0:
	.long	0xffffffff
	.globl	uft_f_a1
uft_f_a1:
	.long	0xffffffff
	.globl	uft_f_a2
uft_f_a2:
	.long	0xffffffff
	.globl	uft_f_a3
uft_f_a3:
	.long	0xffffffff
	.globl	uft_f_a4
uft_f_a4:
	.long	0xffffffff
	.globl	uft_f_a5
uft_f_a5:
	.long	0xffffffff
	.globl	uft_f_a6
uft_f_a6:
	.long	0xffffffff
	.globl	uft_f_a7
uft_f_a7:
	.long	0xffffffff

| ---- the LAST fault, rewritten every time -----------------------------------------------
	.globl	uft_l_fa
uft_l_fa:
	.long	0xffffffff
	.globl	uft_l_pc
uft_l_pc:
	.long	0xffffffff
	.globl	uft_l_fault
uft_l_fault:
	.long	0xffffffff
	.globl	uft_l_usp
uft_l_usp:
	.long	0xffffffff
	.globl	uft_l_fmt
uft_l_fmt:
	.long	0xffffffff
	.globl	uft_l_fslw
uft_l_fslw:
	.long	0xffffffff
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
