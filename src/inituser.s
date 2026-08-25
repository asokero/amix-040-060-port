| inituser.s -- ISSUE-106 round 5: catch the ONE user-transition RTE, gated on the
| frame actually dropping to user.  (2026-08-21)
|
| ROUND 4 CAUGHT THE WRONG RTE, and the miss named the mechanism.  Round 4 latched
| the FIRST firing of this island and read: n=2, f_sr=0x2000 (supervisor),
| pc=f_pc=0x080DA84C (kernel text -- `sched`), a7=0x40001FC0 (_start's SSP).  Not
| the user drop.
|
| WHY THE ISLAND FIRES TWICE.  `main` has two return paths, both reaching its `rts`:
|   0x599d2:  movel #0x80800000,%d0   ; the icode entry
|   0x59c0e:  movel #sched,%d0        ; the address of sched()  (0x080DA84C)
| That is the SVR4 boot fork: `main` sets up proc 1 with `newproc`, then "returns
| twice".  proc 0 returns &sched; proc 1 (resumed later by swtch) returns
| 0x80800000.  Both returns pass through `ini_main` (round 3) and fall into _start
| 0x4a, so this island -- which replaced _start's frame-build + RTE -- is the
| trampoline for BOTH:
|
|   firing 1 (proc 0): d0 = &sched, POSITIVE -> supervisor arm -> RTE into sched.
|                      sched (0xda84c) calls swtch (0xda852) and loops.
|   firing 2 (proc 1): swtch context-switches to proc 1, which returns 0x80800000
|                      from main -> d0 NEGATIVE -> user arm -> the REAL user drop.
|
| Round 4's `have`-gate latched firing 1.  ini_ret = 0x80800000 (round 3) is proc
| 1's return, written last, which is why it read correct.
|
| THE FIX, exactly as the mechanism demands: latch ONLY the user arm (the pushed SR
| has S clear), and only once.  Every non-user firing still builds its frame and
| RTEs, so proc 0 still reaches sched and proc 1 still drops to user -- the boot is
| unchanged.  The user arm is entered only by proc 1's drop, so "user arm + once"
| is the unambiguous gate.
|
| One deliberate refinement over "S-clear AND pc in range": the S-clear arm ALONE
| isolates the drop (only proc 1 goes there), so latching there UNCONDITIONALLY
| captures the drop even if the delivered PC is wildly corrupt -- a pc-range gate
| could miss exactly the failure being hunted.  The pc-in-range test is kept as a
| recorded FLAG (iur_pc_inrange), not as the gate.
|
| THE DECISIVE TRIPLE, one boot:
|   ini_ret   (round 3)  what proc 1's main returned  = 0x80800000 (already known)
|   iur_pc                d0 at proc 1's frame build (this island, user arm)
|   iur_f_pc              the PC longword actually in the frame the RTE reads
|
|   all three 0x80800000  -> the frame is correct and the RTE delivered 0x80000000
|      (bit 23 dropped).  iur_a7 is the exact frame address the RTE reads from
|      (proc 1's kstack, a page-table-translated u-area VA ~0x40001Fxx), and the
|      dropped bit is in the VALUE read, not the address -- the concrete
|      table-walked-frame case the core's exoneration did not cover.  Firmware.
|   iur_pc 0x80000000     -> d0 lost bit 23 between proc 1's main-return and here.
|      Kernel-side, ISSUE-103 family.
|   iur_f_pc 0x80000000 while iur_pc 0x80800000
|                         -> the `movel %d0,%sp@-` push truncated the store.
|
| PREDICTIONS, registered before the run:
|   iur_n >= 2, iur_super_n >= 1, iur_user_n == 1.
|   iur_first_pc == 0x080DA84C (&sched) -- confirms proc 0 fired first.
|   iur_stamp1 == "IUR!", iur_stamp2 == "FRM!", iur_f_sr == 0x0000, iur_f_fmt == 0.
|   iur_pc_inrange == 1.
|   iur_a7 ~ 0x40001Fxx (proc 1 kstack in the fixed u VA), iur_usp = proc 1's saved
|   USP (the garbage that becomes a7 after the drop).
|   the fork is open; prior is iur_pc == iur_f_pc == 0x80800000 (frame right, RTE
|   drops bit 23) OR a clean bit-23 drop at exactly one of the three points.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c inituser.s -o build/inituser.o
| Wire:     patch_inituser.py (replaces _start's frame-build + user RTE at 0x4a).
| ============================================================================

	.text
	.globl	ini_user_rte
ini_user_rte:
	| d0 = the PC main returned (0x80800000 for proc 1, &sched for proc 0)
	addql	&1,iur_n
	movew	&0,%sp@-		| format/vector word 0x0000 (4-word frame)
	movel	%d0,%sp@-		| PC
	tstl	iur_seen
	bnew	Liur_arm
	movel	&1,iur_seen
	movel	%d0,iur_first_pc	| the very first firing's d0, any arm

Liur_arm:
	tstl	%d0
	bmis	Liur_user		| d0 negative -> user drop
	movew	&0x2000,%sp@-		| supervisor arm (proc 0 -> sched): no latch
	addql	&1,iur_super_n
	braw	Liur_rte

Liur_user:
	movew	&0,%sp@-		| SR = 0x0000 -- the user drop (proc 1)
	addql	&1,iur_user_n
	tstl	iur_have
	bnew	Liur_rte
	movel	&1,iur_have
	movel	&0x49555221,iur_stamp1	| "IUR!"
	movel	%d0,iur_pc		| PC main handed the frame
	movel	%sp,iur_a7		| SSP the RTE pops from (proc 1's kstack)
	movel	%usp,%a0
	movel	%a0,iur_usp		| proc 1's saved USP -> its a7 after the drop
| pc-in-user-range is a recorded FLAG, not the gate: latch even a corrupt PC.
	movel	%d0,%d1
	andil	&0xff000000,%d1
	cmpil	&0x80000000,%d1
	bnew	Liur_read
	movel	&1,iur_pc_inrange
Liur_read:
	movel	&0x46524d21,iur_stamp2	| "FRM!" -- the frame was read back
	moveq	&0,%d1
	movew	%sp@,%d1		| SR word (expect 0x0000)
	movel	%d1,iur_f_sr
	movel	%sp@(2),iur_f_pc	| PC longword -- the one the RTE delivers
	moveq	&0,%d1
	movew	%sp@(6),%d1		| format/vector word
	movel	%d1,iur_f_fmt

Liur_rte:
	rte
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	iur_magic
iur_magic:
	.long	0x49555221		| "IUR!"
| "IUR!" once the user drop was latched, "FRM!" once its frame was read back.
	.globl	iur_stamp1
iur_stamp1:
	.long	0
	.globl	iur_stamp2
iur_stamp2:
	.long	0
| Total firings; the two arms counted apart.  Expect n>=2, super>=1, user==1.
	.globl	iur_n
iur_n:
	.long	0
	.globl	iur_super_n
iur_super_n:
	.long	0
	.globl	iur_user_n
iur_user_n:
	.long	0
	.globl	iur_have
iur_have:
	.long	0
	.globl	iur_seen
iur_seen:
	.long	0
| The first firing's d0 (any arm) -- expect &sched = 0x080DA84C.
	.globl	iur_first_pc
iur_first_pc:
	.long	0
| 1 if the latched user-drop PC was in 0x80000000..0x80FFFFFF.
	.globl	iur_pc_inrange
iur_pc_inrange:
	.long	0
| d0 at the user-drop frame build -- the PC main handed _start.
	.globl	iur_pc
iur_pc:
	.long	0
| the SSP the RTE pops from (proc 1's kstack, a translated u-area VA).
	.globl	iur_a7
iur_a7:
	.long	0
| USP at the drop -- becomes PID 1's a7 before its own lea runs.
	.globl	iur_usp
iur_usp:
	.long	0
| the three frame words read straight back off the stack -- what the RTE reads.
	.globl	iur_f_sr
iur_f_sr:
	.long	0
	.globl	iur_f_pc
iur_f_pc:
	.long	0
	.globl	iur_f_fmt
iur_f_fmt:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
