| srgtrap.s -- ISSUE-106 round 2: measure the USP handoff AT setregs, which is the
| moment the last round got wrong.  (2026-08-21)
|
| WHY A SECOND INSTRUMENT.  Round 1 latched `u.u_ar0` inside the fatal-fault NOTICE
| -- inside `u_trap`, which sets `u.u_ar0 = %fp + 8` as its FIRST action (0x5a490).
| So the value read was the FAULT's frame pointer, not the one `setregs` used, and
| every conclusion drawn from it was withdrawn.  The value was real; the moment was
| wrong.  This unit measures at the two moments that actually matter.
|
| WHAT IS ALREADY ESTABLISHED, so this run does not re-ask it:
|
|   * `struct pcb` is `regsave[16]` with **USP first**, `psw` at +64, PC at +66
|     (<sys/pcb.h>) -- exactly what `setregs` writes: `u_ar0[0]` <- new SP
|     (0x58c16), `u_ar0+66` <- PC (0x58c22).  `execmark.s`'s own header states the
|     same contract: "usp = u.u_ar0[0]".
|   * `struct user` opens with `pcb_t u_pcb`, so `u + 0` IS `u.u_pcb.regsave[0]`.
|     It read `0xC0800000` = `userstack` on metal: the correct value was computed
|     and stored somewhere.
|   * the USP actually running was `0xCB7C0002` -- garbage and ODD, which is fatal
|     to any stack operation and is why the reported fault address varies per boot
|     and is derived from the garbage rather than equal to it.
|
| THE ONE QUESTION LEFT: does `setregs`' write and the trap exit's USP restore
| address the SAME memory?
|
|   `utraps` (0x11ea) pushes USP on the kernel stack and `u_trap` sets
|   `u.u_ar0 = %fp + 8`, which should BE that pushed slot; the trap exit pops it
|   (0x11f4) and loads USP (0x11f6).  `setregs` writes the new SP through `u_ar0`.
|   If those two addresses are the same word, the handoff is sound and the search
|   moves elsewhere.  If they differ, the mismatch is named and the fix follows.
|
| TWO HOOKS, because one moment cannot answer it.
|
|   1. `srg_utraps` -- the `jsr u_trap` relocation at 0x11f0 is retargeted here.
|      It records the address of the slot `utraps` just pushed and tail-jumps into
|      `u_trap` with the stack untouched, so `u_trap`'s `%fp + 8` is unchanged.
|      This fires on EVERY user trap on purpose and is NOT once-only: it must
|      track the CURRENT trap, because the exec syscall's own frame is the one
|      `setregs` will run inside.  Cost is four stores.
|
|      The slot address is computed as `%sp + 20` after this island saves four
|      registers: 16 bytes of saved registers plus the 4-byte return address `jsr`
|      pushed puts us back at the word `utraps` pushed.
|
|   2. `setregs` -- weakened, with the stock body retained as `setregs_orig`.  The
|      wrapper latches `u.u_ar0` BEFORE the stock body runs, calls it with the same
|      argument, then latches `u_ar0[0]` (what it just wrote), `u.u_ar0` again (to
|      prove it did not move under us) and `u + 0`.  The stock return value is
|      preserved in d2 across the post-latch and restored in both d0 and a0.
|
| THE VERDICT FIELD.  `srg_match` is computed here rather than left to arithmetic
| on the readout: 1 if `u.u_ar0` equals the pushed-slot address, 0 if not.  That
| single word is the fork.
|
| EXECUTION STAMPS on both capture points, per the standing rule that an instrument
| whose silence is indistinguishable from a negative result is decoration:
| `srg_ut_stamp` = "UTR!" once the trap hook has run, `srg_stamp1` = "PRE!" once the
| pre-latch has, `srg_stamp2` = "PST!" once the stock body has returned.  A missing
| stamp means the path was never taken, which is a different fact from a zero value.
|
| PRE-REGISTERED FORK, written before the run:
|
|   srg_match == 0  the write and the restore address DIFFERENT memory.  The
|                   mismatch is named; `srg_uar0_pre` vs `srg_slot_at` says by how
|                   much and in which direction, and the fix reconciles them.
|   srg_match == 1  the handoff is sound: `setregs` wrote the new SP into the exact
|                   word the trap exit will load USP from.  Then something CLOBBERS
|                   USP between `setregs` and the `rte`, and the search moves there
|                   -- `srg_ar0_0` should read 0xC0800000 in that case, and if it
|                   does not, the write itself did not land and that is a third
|                   story again.
|
| Also predicted: `srg_n` >= 1 with all three stamps set; `srg_pcb0_post` == the
| 0xC0800000 already seen; `srg_uar0_pre` == `srg_uar0_post` (nothing moves it
| across the stock body).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c srgtrap.s -o build/srgtrap.o
| Wire:     --weaken-symbol setregs + --add-symbol setregs_orig=.text:0x58b62
|           (relink-040.sh), plus patch_srgtrap.py for the u_trap retarget.
| ============================================================================

	.text
| ---------------------------------------------------------------------------
| Hook 1: the utraps -> u_trap edge.  Records the pushed-USP slot address for the
| CURRENT trap, then hands off.  Deliberately not once-only.
	.globl	srg_utraps
srg_utraps:
	moveml	%d0-%d1/%a0-%a1,%sp@-
	addql	&1,srg_ut_n
	movel	&0x55545221,srg_ut_stamp	| "UTR!"
	movel	%sp,%d0
	addil	&20,%d0			| 16 saved regs + 4 return address = the pushed slot
	movel	%d0,srg_pushslot
| --- ISSUE-106 round 6 ring: the first 4 user traps, so the SEQUENCE is visible.
|     Round 2 proved every user trap (syscall AND fault) routes through this edge
|     (srg_ut_n = 1 was the fault).  With bit 23 fixed, PID 1 may now reach its
|     trap #0 before faulting, and the ring shows exactly what happens in order.
|     Stack from here (after our 16-byte moveml):
|       %sp+16 jsr retaddr   %sp+20 pushed USP (== A7 at the trap)
|       %sp+24 frame SR.w    %sp+26 frame PC.l   %sp+30 frame fmt+vec.w
|     (SR/PC/fmt sit at the same low offsets for a format-0 trap frame and a
|      format-7 access-error frame alike.)  User d0 is our lowest saved reg (%sp@).
	movel	srt_i,%d0
	cmpil	&4,%d0
	bccw	Lsrg_ut_done
	movel	%d0,%d1
	asll	&2,%d1			| d1 = index * 4
	moveq	&0,%d0
	movew	%sp@(30),%d0		| frame fmt+vec word -> vector*4 in low bits
	lea	srt_vec,%a0
	movel	%d0,%a0@(0,%d1:l)
	movel	%sp@(26),%d0		| frame user PC
	lea	srt_pc,%a0
	movel	%d0,%a0@(0,%d1:l)
	movel	%sp@(20),%d0		| pushed USP = A7 at the trap
	lea	srt_usp,%a0
	movel	%d0,%a0@(0,%d1:l)
	movel	%sp@,%d0		| user d0 (syscall number on a trap #0)
	lea	srt_d0,%a0
	movel	%d0,%a0@(0,%d1:l)
	addql	&1,srt_i
	movel	&0x53525421,srt_stamp	| "SRT!"
Lsrg_ut_done:
	moveml	%sp@+,%d0-%d1/%a0-%a1
| The stack is exactly as utraps left it, so u_trap's %fp+8 still names the pushed
| USP slot and its rts still returns to 0x11f4.
	jmp	u_trap

| ---------------------------------------------------------------------------
| Hook 2: setregs, wrapped so both sides of its write can be read.
	.globl	setregs
setregs:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	addql	&1,srg_n
	tstl	srg_have
	bnew	Lsrg_call
	movel	&1,srg_have
	movel	&0x50524521,srg_stamp1	| "PRE!"
	movel	u+0x864,srg_uar0_pre	| u.u_ar0 as SETREGS sees it -- the right moment
	movel	srg_pushslot,srg_slot_at	| the slot utraps pushed for THIS trap
	movel	u,srg_pcb0_pre		| u.u_pcb.regsave[0] before
| --- the verdict, computed here so the readout needs no arithmetic ---
	movel	u+0x864,%d0
	cmpl	srg_slot_at,%d0
	bnew	Lsrg_call
	movel	&1,srg_match

Lsrg_call:
	movel	%fp@(8),%sp@-
	jsr	setregs_orig
	addqw	&4,%sp
	movel	%d0,%d2			| preserve the stock return value

	tstl	srg_done
	bnew	Lsrg_ret
	movel	&1,srg_done
	movel	&0x50535421,srg_stamp2	| "PST!"
	movel	u+0x864,srg_uar0_post	| did it move under us?
	moveal	u+0x864,%a0
	movel	%a0@,srg_ar0_0		| u_ar0[0] -- the word setregs just wrote
	movel	%a0@(60),srg_ar0_60
	movel	u,srg_pcb0_post		| u.u_pcb.regsave[0] after

Lsrg_ret:
	movel	%d2,%d0
	moveml	%sp@+,%d2/%a2
	moveal	%d0,%a0			| SGS returns pointers in a0 as well
	unlk	%fp
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	srg_magic
srg_magic:
	.long	0x53524721		| "SRG!"
| ---- THE VERDICT: 1 = u.u_ar0 IS the pushed USP slot, 0 = it is not ----
	.globl	srg_match
srg_match:
	.long	0
| Execution stamps.  A zero stamp means the path never ran, which is not the same
| fact as a zero value.
	.globl	srg_ut_stamp
srg_ut_stamp:
	.long	0
	.globl	srg_stamp1
srg_stamp1:
	.long	0
	.globl	srg_stamp2
srg_stamp2:
	.long	0
| Counters: user traps seen, and setregs calls.
	.globl	srg_ut_n
srg_ut_n:
	.long	0
	.globl	srg_n
srg_n:
	.long	0
	.globl	srg_have
srg_have:
	.long	0
	.globl	srg_done
srg_done:
	.long	0
| The address utraps pushed the USP to, for the CURRENT trap (tracked, not latched).
	.globl	srg_pushslot
srg_pushslot:
	.long	0
| The same address, frozen at the setregs call that matters.
	.globl	srg_slot_at
srg_slot_at:
	.long	0
| u.u_ar0 either side of the stock body.
	.globl	srg_uar0_pre
srg_uar0_pre:
	.long	0
	.globl	srg_uar0_post
srg_uar0_post:
	.long	0
| u_ar0[0] -- the saved-USP word setregs writes -- and u_ar0[60].
	.globl	srg_ar0_0
srg_ar0_0:
	.long	0
	.globl	srg_ar0_60
srg_ar0_60:
	.long	0
| u.u_pcb.regsave[0] before and after.
	.globl	srg_pcb0_pre
srg_pcb0_pre:
	.long	0
	.globl	srg_pcb0_post
srg_pcb0_post:
	.long	0
| ---- ISSUE-106 round 6: ring of the first 4 user traps (syscall + fault), in order.
| srt_vec[i] = frame fmt+vec word (vector*4 in the low 12 bits: trap #0 -> 0x0080,
| access-error -> 0x7008); srt_pc[i] = user PC; srt_usp[i] = A7 at the trap (the SP
| the icode's lea should have set to ~0x8080002A -- if it reads 0x40001FC0 or
| 0x08003118, PID 1 is on the SSP / an unswitched USP); srt_d0[i] = user d0.
	.globl	srt_stamp
srt_stamp:
	.long	0			| "SRT!" once the ring captured anything
	.globl	srt_i
srt_i:
	.long	0
	.globl	srt_vec
srt_vec:
	.long	0,0,0,0
	.globl	srt_pc
srt_pc:
	.long	0,0,0,0
	.globl	srt_usp
srt_usp:
	.long	0,0,0,0
	.globl	srt_d0
srt_d0:
	.long	0,0,0,0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
