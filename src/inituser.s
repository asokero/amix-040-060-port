| inituser.s -- ISSUE-52 round 4: catch the ONE user-transition RTE and read the
| frame it is built from.  (2026-08-21)
|
| WHAT ROUND 3 + the firmware RTE probe settled.
|
|   * `main` returns 0x80800000 (the icode entry) -- round 3's `ini_ret` latched it.
|   * the firmware's first 8 u-block-window RTEs after MMU-on all return to
|     SUPERVISOR kernel text (pc 0x0800xxxx / 0x080Dxxxx, SR S-set, fmt 0068/006C).
|     Every one is interrupt/fault churn INSIDE main().  None is the user drop:
|     no SR=0x0000, no pc=0x80800000, no fmt=0.  The one user RTE is later than
|     the 8-cap.
|   * observed fault: PC 0x80000012.  icode is mapped at 0x80800000, so 0x80800012
|     would be icode+0x12 -- but the fault is 0x80000012, i.e. icode base with
|     **bit 23 (0x00800000) cleared** plus 0x12.  PID 1 ran a couple of
|     instructions from the wrong page (0x80000000) and faulted.
|
| So the user transition DID happen (round 3: exactly one user trap, the fault),
| and it delivered the wrong PC.  The question collapses to: is the frame `_start`
| builds already wrong, or does the RTE read it wrong?
|
| THE HANDOFF, from `_start` (SP = u+0x1FC0 = 0x40001FC0, set at 0x3c -- so the
| frame lives in the u-block, which is why the firmware window is right):
|
|     44:  jsr   main         ; -> ini_main (round 3), returns d0 = user PC
|     4a:  movew #0,%d1
|     4e:  movew %d1,%sp@-    ; format word 0x0000
|     50:  movel %d0,%sp@-    ; PC   (sets N from d0)
|     52:  bmis  5c           ; d0 negative -> user arm
|     54:  movew #0x2000,%d1  ; supervisor SR (non-user arm)
|     58:  movew %d1,%sp@-
|     5a:  rte
|     5c:  movew %d1,%sp@-    ; SR = 0x0000  (d1 still 0) -- USER
|     5e:  rte
|
| patch_inituser.py replaces 0x4a..0x5f with `bra.l ini_user_rte` + NOPs.  This
| island rebuilds the SAME frame from d0 -- byte-identical to stock, so a good
| kernel still launches PID 1 correctly -- and, on the first firing, latches d0,
| the SSP, USP, and the three frame words READ BACK from the stack.  `bra.l`
| (not `bsr.l`) pushes no return address, so the reported SSP is the true one the
| RTE will pop from.
|
| THE DECISIVE TRIPLE, one boot:
|   ini_ret   (round 3)  what main returned
|   iur_pc                d0 at the frame build (this island)
|   iur_f_pc              the PC longword actually in the frame the RTE reads
|
| Whichever transition drops bit 23 is named:
|   ini_ret 0x80800000, iur_pc 0x80800000, iur_f_pc 0x80800000
|       -> the frame is correct and the RTE itself delivered 0x80000000.  Back to
|          the CPU core, but now with the EXACT failing frame address (iur_a7,
|          ~0x40001FB8, a u-block/table-walked address) and the exact bit -- the
|          concrete case the harness's "exact delivery on table-walked frames"
|          exoneration did not cover.
|   iur_pc 0x80000000 while ini_ret 0x80800000
|       -> d0 lost bit 23 between ini_main's rts and here (the `movel %d0` chain),
|          an ISSUE-49-family data-path bit-drop -- and the fix is kernel-side.
|   iur_f_pc 0x80000000 while iur_pc 0x80800000
|       -> the `movel %d0,%sp@-` push truncated the store (a store bit-drop, the
|          nearest cousin of ISSUE-49's BFINS finding).  A third story, named.
|
| PREDICTIONS, registered before the run:
|   iur_stamp1 == "IUR!", iur_stamp2 == "FRM!", iur_n == 1.
|   iur_f_sr == 0x0000 (user), iur_f_fmt == 0x0000, iur_a7 in 0x4000xxxx.
|   the fork above is genuinely open; my prior is iur_pc == iur_f_pc == 0x80800000
|   (frame correct, RTE delivers wrong) OR a clean bit-23 drop at exactly one of
|   the three points.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c inituser.s -o build/inituser.o
| Wire:     patch_inituser.py (replaces _start's frame-build + user RTE).
| ============================================================================

	.text
	.globl	ini_user_rte
ini_user_rte:
	| d0 = user PC main computed; %sp = SSP (u-block), frame not yet built
	movel	&0x49555221,iur_stamp1	| "IUR!"
	addql	&1,iur_n
	tstl	iur_have
	bnew	Liur_build
	movel	&1,iur_have
	movel	%d0,iur_pc		| the PC main computed
	movel	%sp,iur_a7		| the true SSP the RTE will pop from
	movel	%usp,%a0
	movel	%a0,iur_usp		| USP -> becomes PID 1's a7 after the drop

Liur_build:
	| rebuild the exact stock frame: format 0x0000, PC, SR-by-arm
	movew	&0,%sp@-		| format/vector word 0x0000 (4-word frame)
	movel	%d0,%sp@-		| PC
	tstl	%d0
	bmis	Liur_user
	movew	&0x2000,%sp@-		| non-user arm: supervisor SR
	braw	Liur_read
Liur_user:
	movew	&0,%sp@-		| user arm: SR = 0x0000

Liur_read:
	tstl	iur_done
	bnew	Liur_rte
	movel	&1,iur_done
	movel	&0x46524d21,iur_stamp2	| "FRM!" -- the frame was read back
	moveq	&0,%d1
	movew	%sp@,%d1		| SR word
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
| "IUR!" once the island ran, "FRM!" once the frame was read back.  A zero stamp
| means the path was never taken -- a different fact from a zero value.
	.globl	iur_stamp1
iur_stamp1:
	.long	0
	.globl	iur_stamp2
iur_stamp2:
	.long	0
	.globl	iur_n
iur_n:
	.long	0
	.globl	iur_have
iur_have:
	.long	0
	.globl	iur_done
iur_done:
	.long	0
| d0 at the frame build -- the PC main handed _start.
	.globl	iur_pc
iur_pc:
	.long	0
| the SSP the frame sits on and the RTE pops from (expect ~0x40001Fxx).
	.globl	iur_a7
iur_a7:
	.long	0
| USP at the transition (becomes PID 1's a7 before its own lea runs).
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
