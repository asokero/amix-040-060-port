| fpe040.s -- the machine half of the AMIX soft-FPU lane: the vector-11 arm, the FP-state
| presentation, and the non-local exit the emulator's panic sites need.  (2026-08-26)
|
| FIRST-PARTY.  Nothing in this file is derived from the NetBSD FPE under build/fpe-src/;
| it is the AMIX side of the seam that docs/contracts/FPE-INTEGRATION-CONTRACT.md measured, and
| every decision it implements is argued in docs/contracts/FPE-GLUE-DESIGN.md, as amended by
| docs/contracts/FPE-R4-DELTA.md.  Read those first: this header states what the code does, not
| why it is shaped this way.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/fpe040.s -o build/fpe040.o
| Link:     LAST of every object in the FPE link -- see the .balign note at the end of .text.
| Externals: nullvect, ureturn, sup_cacr, u, cputype, fpu_present, fpu_ptr, reset_fregs, printf,
|            and the six *_fpe_orig aliases relink-040-fpe.sh mints with objcopy.
|
| ============================ THE EIGHT THINGS IN HERE ============================
|
| 1. fpe_vec11 -- the vector-11 arm.  M68Kvec[11] is retargeted to it by
|    src/patch_fpe_vec11.py, so it runs BEFORE fpsp_vec11's first instruction, which is
|    where frozen decision 10 puts it and where the emulator's own format-4 arm
|    expects to be entered (contract 6.3).  It declines by jumping to whatever M68Kvec[11]
|    named before -- the patcher retargets fpe_decline's own relocation to it -- so a
|    declined exception takes the pre-FPE path instruction for instruction.
|
| 2. fpe_setjmp / fpe_longjmp -- a 13-longword non-local exit.  The extracted tree calls
|    panic() at eleven sites and copyin/copyout at six, and it assumes panic does not return
|    and never checks a copy for failure.  Both are answered by an abort that unwinds to
|    fpe_trap's own frame; this is the mechanism.  Written here rather than borrowed from the
|    kernel because the kernel exports no setjmp and because a private one cannot be perturbed
|    by anything else in the system.
|
| 3. prhasfp -- frozen decision 9.  fpu_present keeps meaning "real silicon" and is not
|    touched; prhasfp answers for the pair.
|
| 4. fpu_save / fpu_restore / fpu_setup -- the emulated FP state presentation.  Under
|    emulation the programmer's model in the u-area IS the live state (the emulator reads and
|    writes it in place), so there is nothing to save and nothing to publish; what these arms
|    owe the rest of the kernel is a COHERENT FSAVE frame in fpu_info.fsave[0], because
|    savecontext reads it directly and prgetfpstate copies all 216 bytes of it to userland.
|
| 5. fpuinit -- arms the lane.  Runs the accepted probe first, byte for byte, and only if it
|    comes back saying "no FPU" does the emulator arm.  This is the one place fpu_emul is set.
|
| 6. fpu_setup_gated / setregs -- the two call sites that gate fpu_setup on fpu_present alone
|    and therefore skip it under emulation, so a freshly exec'd image and a signal handler
|    inherit the previous programmer's model, FPCR included.  Round 3 measured OVFL and DZ
|    traps surviving an exec on the LC bed and being reset on a real FPU.  Both are answered
|    for the pair here; overriding rather than editing keeps the base kernel byte-identical.
|
| 7. fpe_sigpend -- u_trap's own three-condition signal gate, so the SUCCESSFUL-emulation path
|    can reach issig/psig without paying for a call on every emulated instruction.  Without it
|    a process in a pure-FP loop could not be signalled at all, SIGKILL included.
|
| 8. fpe_vec60 -- the vector-60 arm (round 10, 2026-08-27).  On a 68060 the twelve-byte
|    immediate operand formats are an addressing mode the INTEGER unit does not implement, so
|    they raise "FP unimplemented effective address" BEFORE any F-line path runs, and the lane
|    never saw them: round 10 measured three of them dying SIGSYS on metal with every fpe_*
|    counter still at zero.  Same mechanism as item 1 one vector over -- M68Kvec[60] retargeted
|    by src/patch_fpe_vec60.py, fpe_decline60 given back the handler it displaced -- and the
|    same body, because fpe_trap reads the format and vector out of the frame it is handed.
|    docs/contracts/FPE-R10-VEC60.md is the whole argument, including why routing the 68060
|    package's own FPU-disabled call-out here instead would have been a loop.
|
| ============================ REGISTER DISCIPLINE ============================
| fpe_vec11 runs on the RAW exception frame with every user register still live in the CPU, so
| every test before Lfpe_user is memory-to-memory or memory-immediate: CCR is the only thing
| any of them changes, and both nullvect and rte reload SR from the frame.  This is the same
| rule fpsp060_glue.s records at length after M2a broke it by writing a slot id into %d0.

	.text

	U_AR0	=	0x40000864	| u.u_ar0 -- the slot fpsp_glue040.s, fpsp060_glue.s and
					| isp61_060.s already use, and the one u_trap writes
	FP_USTATE =	0		| fpu_info, from the pointer in fpu_ptr (= u + 0x9c);
	FP_REGS	=	4		| public in sys/fpu.h, and asserted in fpe_glue.c
	FP_FSAVE =	112

| An idle 68881 state frame, as the rest of the kernel reads one:
|   byte 0 = version, non-zero, which is what stock fpu_save/fpu_restore test to decide
|            "this process has live FP state" (they do tstb on frame byte 0);
|   byte 1 = the format byte, which is what savecontext masks with FRMTMASK 0xff0000.
| FIDLE881 is 0x180000 and FIDLE882 is 0x380000 (sys/fpu.h:72-73).  The 881 shape is frozen
| decision 9's and it is also the only one that avoids stock savecontext's BIU poke at
| u+324, which is written for real 68882 silicon (contract 4.3).
	FIDLE881_V =	0x1f180000

| ============================================================================
| fpe_vec11 -- vector 11, before anything else.
|
| Three frame shapes arrive here and the format nibble is the only thing that tells them
| apart (contract 6.2).  Only format 4 -- the eight-word 68060 FP-disabled frame, which on a
| 68LC060 is every single event -- is ours.
|
| FORMAT 0 MUST FALL THROUGH UNCHANGED.  A four-word frame at vector 11 is a genuinely
| illegal F-line word, and its outcome is SIGSYS.  Handing it to the emulator would work --
| the emulator would fetch the opword from the stacked PC, which is correct for a format-0
| frame, and abort with SIGILL/ILL_ILLOPC -- and would thereby convert SIGSYS to SIGILL for
| every bad F-line word in the system.  That is a user-visible ABI change and it is refused
| here rather than merely avoided.
| ============================================================================
	.globl	fpe_vec11
fpe_vec11:
| ---- THE CENSUS, ahead of every gate (round 4 fix 5) --------------------------------------
| fpe_fmt2_n used to sit BELOW the fpu_present decline, and every 68040 in this workspace's
| bench and metal fleet has an FPU -- so on the only kind of 040 available the lane never armed
| and the counter could never move.  FPE-GLUE-DESIGN.md 9 item 10 was therefore not merely 0,
| it was unreachable, and contract 8 item 2's standing gap (the format-2/0x202c pairing rests on
| Motorola's x_fline.sa and has never been latched from a real 68040 frame in this tree) stayed
| open through a round that booted two 040 rigs.
|
| Counting here costs three to five instructions per vector-11 event and closes it for free on
| ANY 040 boot: an FPU-present 040 takes format-2 frames at vector 11 for every unimplemented FP
| instruction the FPSP handles.
|
| THE NEVER-ENGAGE BAR IS UNCHANGED.  fpe_entry_n stays behind both gates, below.  The fpe_v11_*
| family are PRE-GATE OBSERVERS and are EXPECTED to move on FPU-present rigs -- that is their
| whole purpose -- so any reading of the bar must exclude them by name.
|
| Memory-to-memory and memory-immediate throughout: CCR is the only thing this changes, which is
| the same register discipline the rest of this arm keeps.  The decline path itself is untouched.
	addql	&1,fpe_v11_n
	cmpiw	&0x402c,%sp@(6)
	beqs	Lfpe_cen4
	cmpiw	&0x202c,%sp@(6)
	beqs	Lfpe_cen2
	cmpiw	&0x002c,%sp@(6)
	beqs	Lfpe_cen0
	addql	&1,fpe_v11_fmtx_n
	movew	%sp@(6),fpe_v11_last_fmtvec+2
	bras	Lfpe_cen_done
Lfpe_cen4:
	addql	&1,fpe_v11_fmt4_n
	bras	Lfpe_cen_done
Lfpe_cen0:
	addql	&1,fpe_v11_fmt0_n
	bras	Lfpe_cen_done
Lfpe_cen2:
	addql	&1,fpe_v11_fmt2_n
	movew	%sp@(6),fpe_v11_fmt2_word+2 | contract 8 item 2: the pairing, from a real frame
	movel	%sp@(8),fpe_v11_fmt2_ia	| a format-2 frame is 12 bytes and +8 is the OPERAND
					| EFFECTIVE ADDRESS -- the field only this shape has.
					| Round 5 measured it: 0 on all 2,007 frames from a
					| register-to-register fsin, and exactly the operand's
					| data address from an fsin.d (%a0),%fp0 probe.  The _ia
					| name predates that and is kept so the symbol stays
					| stable; contract 6.2 carries the correction
Lfpe_cen_done:

	tstl	fpu_present		| real silicon: this lane does not exist.  Uncounted on
	bnew	fpe_decline		| purpose -- fpe_entry_n == 0 is the never-engage bar
	tstl	fpu_emul
	beqw	fpe_decline		| emulation not armed (fpuinit said no, or fpe_enable=0)
	addql	&1,fpe_entry_n
	cmpiw	&0x402c,%sp@(6)		| eight-word, format 4: 68060 FP disabled
	beqs	Lfpe_fmt4
	cmpiw	&0x202c,%sp@(6)		| six-word, format 2: 68040 unimplemented FP
	beqs	Lfpe_fmt2
	cmpiw	&0x002c,%sp@(6)		| four-word, format 0: a real bad F-line word
	beqs	Lfpe_fmt0
	addql	&1,fpe_fmtx_n		| a fourth shape at vector 11 would be a finding
	movew	%sp@(6),fpe_last_fmtvec+2
	bras	fpe_decline
Lfpe_fmt0:
	addql	&1,fpe_fmt0_n		| SIGSYS, unchanged.  See the header.
	bras	fpe_decline
Lfpe_fmt2:
	addql	&1,fpe_fmt2_n		| the 68040 unimplemented-FP arm is documented and NOT
	bras	fpe_decline		| implemented this round; today it keeps its FPSP outcome
Lfpe_fmt4:
	addql	&1,fpe_fmt4_n
	btst	&5,%sp@			| stacked SR high byte bit 5 = the S bit
	beqs	Lfpe_v11user
	addql	&1,fpe_super_n		| supervisor-origin FP on a part with no FPU is a kernel
					| defect.  Frozen decision 8 keeps it LOUD: decline, and
					| the S-bit dispatch takes it to k_trap as it does today.

| The decline.  ONE instruction, and its relocation is what src/patch_fpe_vec11.py retargets
| to whatever M68Kvec[11] named before this arm was installed -- fpsp_vec11 on a normal build,
| nullvect on an FPSP=0 one.  Writing it as a jmp with a patchable relocation rather than as a
| conditional on some build-time symbol is the same choice fpsp_glue040.s makes for its 060
| branch, for the same reason: a jump to a symbol that is not there is worse than the signal it
| replaces, and here there is no symbol to guess at all.
	.globl	fpe_decline
fpe_decline:
	jmp	nullvect		| RETARGETED -- see src/patch_fpe_vec11.py

| ============================================================================
| fpe_vec60 -- vector 60, "FP unimplemented effective address", ahead of the 68060 package.
|
| WHY IT EXISTS.  On a 68060 the effective address of an FP operand is computed by the INTEGER
| unit, and the two immediate formats whose operand is TWELVE bytes -- extended-precision real
| and packed decimal -- are the ones it does not implement.  It therefore raises vector 60
| before any F-line path runs, so the lane's vector-11 arm is never entered and no fpe_* counter
| moves.  Round 10 measured exactly that on metal: three executions of `fmove.x #<ext>,FPn` and
| `fmove.p #<packed>,FPn`, three vector-60 entries, three SIGSYS deaths, and the whole fpe_*
| block still at its initialisers.  docs/contracts/FPE-R10-VEC60.md carries the trace and names
| the SIGSYS's own instruction: src/fpsp060_glue.s:Lco_fpudis_nofpu's `jmp nullvect`.
|
| THE FRAME.  Four words -- SR +0, PC +2, format/vector +6 -- i.e. format 0, vector offset
| 60 x 4 = 0xF0, so the word at +6 is 0x00F0.  Its PC field is the FAULTING instruction, not the
| next one, which is the field a format-4 frame has to carry separately as f_pcfi.  That makes
| this the easier of the two shapes for the emulator: fpu_emulate's format-4 special case exists
| precisely to reconstruct what this frame already has.  Established from Motorola's own package,
| which builds the eight-word FPU-disabled frame FROM this one and takes the instruction address
| straight out of its PC field; the arm declines anything else and latches what it saw, so being
| wrong about the shape costs today's behaviour and not a wrong resume.
|
| THE LENGTH.  16 bytes: opword 2 + command word 2 + operand 12.  It is not in the frame and
| cannot be -- round 9's finding is that #<data> is the one addressing mode whose length lives in
| the FP command word rather than the operation word.  Nothing here computes it; the emulator's
| own decode does, and the host harness measures it coming out as 16 (FPE-R10-VEC60.md 9, T1-T3).
|
| WHAT IS NOT HERE.  No form gate.  Deciding which of the four vector-60 instruction classes the
| emulator may be trusted with needs the FP command word, which is a USER fetch, which needs the
| fault-protected path -- so it lives in fpe_trap beside the rest of the decode.  This arm's job
| is the frame and the gates, in the register discipline the raw frame forces.
| ============================================================================
	.globl	fpe_vec60
fpe_vec60:
| ---- the census, ahead of every gate, exactly as the vector-11 arm's ---------------------
| These move on ANY 68060, FPU-present ones included -- a real FPU raises vector 60 for these
| forms too, and the package handles them.  They are observers and are outside the never-engage
| bar by name, which fpe_ea_n below is not.
	addql	&1,fpe_v60_n
	cmpiw	&0x00f0,%sp@(6)		| four-word, format 0, vector offset 60 x 4
	beqs	Lfpe60_cen0
	addql	&1,fpe_v60_fmtx_n
	movew	%sp@(6),fpe_v60_last_fmtvec+2
	bras	Lfpe60_gate
Lfpe60_cen0:
	addql	&1,fpe_v60_fmt0_n
Lfpe60_gate:
	tstl	fpu_present		| real silicon: the package's business, byte for byte
	bnes	Lfpe60_decl
	tstl	fpu_emul
	beqs	Lfpe60_decl		| emulation not armed
	cmpiw	&0x00f0,%sp@(6)		| a shape this arm has not been shown: decline and latch
	bnes	Lfpe60_decl
	btst	&5,%sp@			| stacked SR high byte bit 5 = the S bit
	bnes	Lfpe60_super
	addql	&1,fpe_ea_n
	braw	Lfpe_user		| the vector-11 arm's own body: fpe_trap tells the two
					| apart by the vector in the frame, so there is no second
					| copy of the register push / u_ar0 / ureturn sequence
Lfpe60_super:
	addql	&1,fpe_ea_super_n	| supervisor FP on a part with no FPU is a kernel defect,
					| and decision 8 keeps it loud on this vector too
Lfpe60_decl:
	addql	&1,fpe_v60_decl_n	| THE residual-death counter: on a part with no FPU these
					| are the events that still reach the package and still end
					| in SIGSYS.  Round 10's whole finding was that nothing
					| counted them.
	.globl	fpe_decline60
fpe_decline60:
	jmp	nullvect		| RETARGETED -- see src/patch_fpe_vec60.py.  fpsp_vec60 on
					| a normal build, nullvect on an FPSP=0 one; same argument
					| as fpe_decline's, one vector over.

| ============================================================================
| The user-origin path, shared by both arms.
|
| Reached from the vector-11 arm with an eight-word format-4 frame and from the vector-60 arm
| with a four-word format-0 one.  Nothing below depends on the frame's SIZE: the register block
| is pushed BELOW it, fpe_trap is handed its address, and the RTE at the end of ureturn pops
| whatever the frame's own format word says.  fpe_trap reads the format and vector out of the
| frame, so it needs no argument to tell the two arms apart.
|
| Everything below reproduces the state nullvect -> utraps -> u_trap normally establishes, and
| leaves through ureturn, WITHOUT calling u_trap: by the time this runs the exception has been
| consumed.  fpsp_glue040.s's fpsp_done and fpsp060_glue.s's Lco_done are the same shape and
| both are hardware-accepted.
|
| The stack this builds, and fpe_trap's three arguments name three parts of it:
|
|	sp@(0)		the USP pseudo-register		<- u.u_ar0 points HERE
|	sp@(4..63)	D0-D7/A0-A6, 60 bytes		== exactly what nullvect pushes
|	sp@(64..79)	the raw eight-word format-4 exception frame
|
| u_ar0 is set BEFORE the call, not after, because the emulation may sleep in a copyin and be
| context-switched: u_ar0 lives in the u-area, is per-process, and anything that looks at this
| process while it is off the CPU must find it already correct.
| ============================================================================
Lfpe_v11user:
	addql	&1,fpe_user_n		| the VECTOR-11 arm's handoff count, and only that one.
					| Round 10 kept every registered row of rounds 3-9 meaning
					| what it meant: fpe_entry_n, fpe_done_n, fpe_sig_n and this
					| are vector-11 only, and the vector-60 arm has its own
					| fpe_ea_* set.  FPE-R10-VEC60.md 6.
Lfpe_user:
	moveml	%d0-%d7/%a0-%a6,%sp@-	| the 60-byte block, register for register as nullvect
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr -- kernel cache mode, as nullvect does
					| in its first three instructions.  Without it the
					| emulation and every copyin under it run on the USER
					| cache policy (fpsp060_glue.s records the same trap).
	movel	%usp,%a0
	movel	%a0,%sp@-		| push USP as the pseudo-register
	movel	%sp,U_AR0		| u.u_ar0 = &pseudo-register
	moveal	%sp,%a0
	pea	%a0@(64)		| arg3: the raw exception frame
	pea	%a0@(4)			| arg2: the 60-byte register block
	pea	%a0@			| arg1: &USP pseudo-register
	jsr	fpe_trap
	lea	%sp@(12),%sp
	moveal	%sp@+,%a0		| pop the pseudo-register slot
	movel	%a0,%usp		| publish A7 as the emulation left it -- an FP operand
					| may legitimately be (%sp)+ or -(%sp)
	jmp	ureturn			| the AMIX user-exception exit

| ============================================================================
| fpe_setjmp / fpe_longjmp -- the abort path the emulator code's own conventions require.
|
| jmp_buf is 13 longwords: the return PC, the entry SP, then d2-d7/a2-a6.  d0/d1/a0/a1 are
| caller-saved in this ABI and are not preserved, which is exactly the setjmp contract.
| ============================================================================
	.globl	fpe_setjmp
fpe_setjmp:				| int fpe_setjmp(long *buf)
	moveal	%sp@(4),%a0
	movel	%sp@,%a0@		| return address
	movel	%sp,%a0@(4)		| SP as of entry, i.e. pointing at that return address
	moveml	%d2-%d7/%a2-%a6,%a0@(8)
	moveq	&0,%d0
	rts

	.globl	fpe_longjmp
fpe_longjmp:				| void fpe_longjmp(long *buf, int val)
	moveal	%sp@(4),%a0
	movel	%sp@(8),%d0
	bnes	Lfj_val
	moveq	&1,%d0			| setjmp must never appear to return 0 twice
Lfj_val:
	moveml	%a0@(8),%d2-%d7/%a2-%a6	| %a0 survives: moveml restores a2-a6, not a0
	moveal	%a0@(4),%sp
	movel	%a0@,%sp@		| put the return address back where rts will find it
	rts

| ============================================================================
| prhasfp -- "does this process have floating point?", frozen decision 9.
|
| The stock body is one instruction: movel fpu_present,%d0.  This weakens it and answers for
| the PAIR, so that every stock consumer -- savecontext, restorecontext and the /proc paths --
| starts saving, restoring and publishing FP state under emulation without any of them being
| edited.  fpu_present keeps meaning "real silicon" and is not written by this lane at all.
|
| Stock returns the value in BOTH %d0 and %a0 (this compiler's convention); so does this.
| ============================================================================
	.globl	prhasfp
prhasfp:
	movel	fpu_present,%d0
	bnes	Lph_out
	movel	fpu_emul,%d0
Lph_out:
	moveal	%d0,%a0
	rts

| ============================================================================
| fpu_save -- called from swtch, setuctxt, savecontext, restorecontext and coffcore.
|
| There is no hardware to save.  The programmer's model in fpu_info.regs is where the emulator
| reads and writes fp0-fp7/FPCR/FPSR/FPIAR directly (contract 3.1: fpu_info.regs is field for
| field and order for order the tail of NetBSD's struct fpframe), so it is already current the
| instant any caller asks.
|
| What this arm owes is the FRAME: fpu_info.fsave[0] must describe a non-null, idle, 68881
| state so that stock readers -- savecontext's format test, prgetfpstate's 216-byte copy, and
| stock fpu_restore's live/null test -- see something coherent instead of whatever the previous
| owner of this u-area left there.
|
| UFPRWRT keeps its inherited meaning exactly as src/fpu060.s spells it out: set means software
| wrote the model through /proc or old ptrace and it must not be overwritten here.
| ============================================================================
	.globl	fpu_save
fpu_save:
	tstl	fpu_present		| real silicon on either CPU: the accepted body, untouched
	bnew	Lfe_s_orig
	tstl	fpu_emul
	beqw	Lfe_s_orig		| emulation not armed: also unchanged
	addql	&1,fpe_save_n
	moveal	fpu_ptr,%a0
	btst	&0,%a0@(3)		| UFPRWRT, low byte of the ustate long (big-endian)
	bnes	Lfe_s_wrt
	movel	&FIDLE881_V,%a0@(FP_FSAVE)
	rts
Lfe_s_wrt:
	addql	&1,fpe_save_wrt_n
	rts
Lfe_s_orig:
	jmp	fpu_save_fpe_orig

| ============================================================================
| fpu_restore -- called from swtch, restorecontext and savecontext.
|
| The mirror, and equally empty of register traffic: publishing the software image to the FPU
| is what UFPRWRT asks for, and under emulation the image IS the FPU.  So the whole arm is to
| CONSUME the bit, which is what makes a /proc or ptrace write to the FP registers stick --
| the branch src/fpu060.s calls out as the reason the inherited ordering is load-bearing.
|
| It must NOT frestore.  There is no unit; frestore is an F-line exception taken in supervisor
| mode, and the supervisor arm of fpe_vec11 declines, so it would become a kernel trap.
| ============================================================================
	.globl	fpu_restore
fpu_restore:
	tstl	fpu_present
	bnew	Lfe_r_orig
	tstl	fpu_emul
	beqw	Lfe_r_orig
	addql	&1,fpe_rest_n
	moveal	fpu_ptr,%a0
	btst	&0,%a0@(3)
	beqs	Lfe_r_out
	addql	&1,fpe_rest_wrt_n
	andil	&-2,%a0@		| clear UFPRWRT (FP_USTATE = 0): the image is published
Lfe_r_out:
	rts
Lfe_r_orig:
	jmp	fpu_restore_fpe_orig

| ============================================================================
| fpu_setup -- boot (fpuinit), exec (setregs) and signal delivery (sendsig).
|
| Install the reset programmer's model and an idle 68881 frame.  reset_fregs is the inherited
| 108-byte image; on a part with no FPU the probe never populated it from hardware, so it is
| the all-zero COMMON it starts as -- FPCR 0 is round-to-nearest, extended precision, every
| exception masked, which is the correct reset state for an emulated unit and is stated here
| because "it happens to be zero" is not a design.
|
| The remaining 204 bytes of the 216-byte raw slot are left alone, exactly as stock and as
| src/fpu060.s leave them, and for the same reason.
| ============================================================================
	.globl	fpu_setup
fpu_setup:
	tstl	fpu_present
	bnew	Lfe_u_orig
	tstl	fpu_emul
	beqw	Lfe_u_orig
	addql	&1,fpe_setup_n
	moveal	fpu_ptr,%a0
	movel	&FIDLE881_V,%a0@(FP_FSAVE)
	lea	reset_fregs,%a1
	addql	&FP_REGS,%a0		| a0 = &fpu_info.regs
	movel	&26,%d0			| 27 longs = 108 bytes = sizeof(fpu_t)
Lfe_u_cp:
	movel	%a1@+,%a0@+
	dbf	%d0,Lfe_u_cp
	moveal	fpu_ptr,%a0		| reload: the copy consumed a0
	clrl	%a0@			| ustate = 0, dropping UFPRWRT -- stock does exactly this
	rts
Lfe_u_orig:
	jmp	fpu_setup_fpe_orig

| ============================================================================
| fpu_setup_gated -- the SENDSIG call site's gate, answered for the pair.
|
| THE GAP, and it is measured rather than argued.  Two sites gate fpu_setup on fpu_present and
| therefore skip it under emulation: this one (src/fpuinit060.s, sendsig) and the one inside the
| stock setregs body (exec, below).  Round 3's A/B: identical binaries, identical kernel one byte
| apart, only fpu_model differing -- FPCR 0x1400 (OVFL *and* DZ enabled) and fp0 = 12345.678
| SURVIVED exec on the LC bed and were RESET on the real-FPU rig.  A program that enables FP
| traps and then execs leaves the next image taking SIGFPE where it would have had a quiet
| infinity; a signal handler inherits the interrupted context's model the same way.
|
| The machinery that produces the correct reset already exists and is already this lane's own --
| fpu_setup above installs the idle 68881 frame, copies reset_fregs over the model and clears
| ustate.  Only the GATES were wrong, so only the gates are fixed.
|
| WHY AN OVERRIDE AND NOT AN EDIT TO src/fpuinit060.s.  fpu_emul is defined in THIS file, which
| is linked only into an FPE kernel; naming it from a file every 040 kernel links would leave the
| base link with an unresolved symbol.  Overriding is the mechanism this lane already uses five
| times over, it needs no new spelling of "the pair", and it keeps the base kernel byte-identical
| -- so FPE=0 still reproduces exactly the image round 3 booted.
|
| %d0/%a0 are clobbered on every arm now, including the refusal arm that used to leave them
| alone.  Safe at the one caller: sendsig+0x1f8 overwrites %d0 with `moveq #1,%d0` four
| instructions later (0x59228) and %a0 was already dead.
| ============================================================================
	.globl	fpu_setup_gated
fpu_setup_gated:
	tstl	fpu_present		| real silicon on either CPU: the accepted body, untouched
	bnew	Lfe_sg_orig
	tstl	fpu_emul
	beqw	Lfe_sg_orig		| emulation not armed: also unchanged
	addql	&1,fpe_ss_setup_n
	jmp	fpu_setup		| the handler gets a reset programmer's model
Lfe_sg_orig:
	jmp	fpu_setup_gated_fpe_orig

| ============================================================================
| setregs -- the EXEC call site's gate, which lives INSIDE the stock body.
|
| setregs_orig+0xc8 is `tstl fpu_present ; beqw ; jsr fpu_setup`, so there is no call site to
| retarget and no wrapper of ours the stock body will consult: the only way to reach it is to own
| setregs.  Calling fpu_setup AFTER the body returns is equivalent, because fpu_setup writes only
| fpu_info.regs, fpu_info.fsave[0] and fpu_info.ustate, and nothing in the rest of setregs reads
| or writes any of them.
|
| THE CALLING CONVENTION IS NOT ASSUMED.  One argument at %fp@(8), an int returned in %d0 and
| mirrored into %a0 -- the shape TWO independent in-repo wrappers already use, one of which is in
| the booting base image: src/srgtrap.s:145-186 and src/execmark.s:584-591.  setregs_fpe_orig
| therefore reaches srgtrap's wrapper, which reaches stock, chain intact.
|
| THE RETURN VALUE IS LOAD-BEARING: exece answers a non-zero setregs with a SILENT psignal(p,9)
| (0x566b6, the "Killed" case src/sigkill_dbg.s was written for), so it is preserved through %d2
| exactly as both precedents preserve it.
| ============================================================================
	.globl	setregs
setregs:
	linkw	%fp,&0
	movel	%d2,%sp@-
	movel	%fp@(8),%sp@-		| arg1 = struct uarg *
	jsr	setregs_fpe_orig
	addqw	&4,%sp
	movel	%d0,%d2			| preserve it across our own call, see above
	tstl	fpu_present
	bnew	Lfe_sr_out		| real silicon: the stock body's gate already ran fpu_setup
	tstl	fpu_emul
	beqw	Lfe_sr_out		| emulation not armed: nothing to do, as before
	addql	&1,fpe_exec_setup_n
	jsr	fpu_setup		| the reset model the stock gate skipped
Lfe_sr_out:
	movel	%d2,%d0
	movel	%sp@+,%d2
	moveal	%d0,%a0			| this compiler returns in both %d0 and %a0
	unlk	%fp
	rts

| ============================================================================
| fpuinit -- the one place the lane is armed.
|
| The accepted probe runs FIRST and unchanged: it is the authoritative answer to "does this
| part have a floating-point unit", it is the thing that measured 5,406-to-0 on real LC060
| silicon, and nothing here may pre-empt it.  Only its NEGATIVE outcome arms the emulator.
|
| fpe_enable is a one-word control in .data so that a boot can be taken with the lane off
| without a different kernel -- the campaign's usual rollback shape, and the finer half of
| relink-040-fpe.sh's FPE=0.
| ============================================================================
	.globl	fpuinit
fpuinit:
	jsr	fpuinit_fpe_orig	| the accepted probe, byte for byte
	tstl	fpu_present
	bnew	Lfe_i_out		| real silicon: the emulator stays disarmed, and every
					| counter in this file stays at 0 for the whole boot
	tstl	fpe_enable
	beqs	Lfe_i_off

| NetBSD's cputype encoding, not AMIX's.  The emulator compares against CPU_68060 == 3;
| AMIX spells the CPU 40/60.  The two are the same fact in two encodings and this is where they
| are reconciled -- see src/fpe-compat/m68k/m68k.h for why the redirection is a header and not
| a -D.
|
| READ IT AS A LONG.  <sys/systm.h>:18 declares `extern short cputype`, and round 2 took that
| declaration at face value -- but THIS PORT'S OWN DEFINITION IS `.long 40` (src/cputype060.s:21)
| and every other reader in the port agrees: inituname040.s, hgfault040.s, fpsp_glue040.s (x9),
| isp61_060.s, fpu060.s (x3), fpuinit060.s (x2), ptest040.s, pstart040.s and
| tools/kernel-cputype-stamp.py all use the 32-bit form.  The FPE lane was the only place that
| used cmpiw, so on a big-endian long it compared the HIGH half-word -- always 0x0000, never 60 --
| and fpe_cputype read 2 on a 68060.  Round 3 measured exactly that.
	movel	&2,fpe_cputype		| CPU_68040
	movel	cputype,fpe_cputype_amix | the raw AMIX value, so the width is READABLE and not
					| merely believed: 60 (0x3c) here, 0 with the old cmpiw
	cmpil	&60,cputype
	bnes	Lfe_i_arm
	movel	&3,fpe_cputype		| CPU_68060
Lfe_i_arm:
	movel	&1,fpu_emul
	movel	&1,fpe_armed
	jsr	fpu_setup		| our arm, now that fpu_emul is set: give proc 0 the
					| presented state every later process inherits
	pea	Lfe_i_msg
	jsr	printf
	addql	&4,%sp
	bras	Lfe_i_out
Lfe_i_off:
	addql	&1,fpe_disabled_n	| fpe_enable was cleared before boot: no FPU, no emulator
Lfe_i_out:
	rts

| ============================================================================
| fpe_sigpend -- u_trap's own signal gate, DECODED rather than copied blind.
|
| WHY IT EXISTS.  issig/psig used to be reached only from fpe_signal(), i.e. only when the
| emulator itself raised a signal.  The successful path returns through ureturn -> s_trap, and
| s_trap has no issig/psig loop (its whole relocation set was decoded for FPE-GLUE-DESIGN.md
| 5.3).  So a process whose only traps are SUCCESSFUL FP emulations never looked at its pending
| signals: round 3 measured alarm(2) never firing into a pure-FP loop and `kill -9` returning
| success while the process kept running.  Three of them had to be power-cut.
|
| WHY IT IS A GATE AND NOT A PLAIN CALL.  The success path is THE HOT PATH -- one entry per
| emulated FP instruction, 29.5 M of them in one round-3 session -- so an unconditional issig()
| is not affordable.  u_trap runs a cheap three-condition test first; this is that test.
|
| THE DECODE, from build/unix-040 (FPE-R4-DELTA.md 1.1 carries the evidence):
|
|     u_trap+0x18   lea <u>,%a2 ; movel %d4,%a2@(0x864)     -- u.u_ar0, this file's own U_AR0,
|                                                              which is what identifies %a2 = u
|     u_trap+0x1a   moveal %a2@(0x730),%a3                  -- %a3 = u.u_procp
|     0x5a89a       tstb  %a3@(134) ; bne  -> issig         -- p_cursig
|     0x5a8a2       tstl  %a3@(156) ; bne  -> issig         -- p_sig
|     0x5a8aa       movel %a3@(4),%d0 ; andil #0x100        -- p_flag & SPRSTOP
|     0x5a8ba       bra  -> skip issig entirely
|
| The offsets are sys/proc.h's proc_t walked with USIZE = 4 (sys/param.h:65), and the walk is
| corroborated three ways inside this repository: p_stkbase/p_stksize at +60/+64 are what
| src/hatalloc_dbg.s:641 already reads, p_sysid at +140 is what src/assegat_dbg.s:309 already
| reads off the same pointer, and k_sigset_t is ulong_t (sys/types.h:40) -- four bytes -- so a
| single tstl covers the whole pending set and there is no second word to miss.
|
| u.u_procp is read here rather than the glue's `curproc` because it is the pointer u_trap
| itself works from: the two are the same pointer, and reading this one removes the question
| instead of arguing it.
| ============================================================================
	U_PROCP	 =	0x730		| u.u_procp
	P_FLAG	 =	4		| proc_t offsets, sys/proc.h with USIZE = 4
	P_CURSIG =	134
	P_SIG	 =	156
	SPRSTOP	 =	0x100		| p_flag bit: "process is being stopped via /proc"

	.globl	fpe_sigpend
fpe_sigpend:				| int fpe_sigpend(void) -- 1 = call issig/psig
	moveal	u+U_PROCP,%a0
	moveq	&1,%d0
	tstb	%a0@(P_CURSIG)
	bnes	Lsp_out
	tstl	%a0@(P_SIG)
	bnes	Lsp_out
	movel	%a0@(P_FLAG),%d1
	andil	&SPRSTOP,%d1
	bnes	Lsp_out
	moveq	&0,%d0
Lsp_out:
	moveal	%d0,%a0			| this compiler returns in both %d0 and %a0
	rts

Lfe_i_msg:
	.asciz	"fpu emulation enabled\n"
	.balign	4			| pad .text to a multiple of 4.  The loader copies text
					| and data as ONE block and places .bss at data_end
					| UNALIGNED, so the LAST object in the link has to close
					| both sections -- and a compiled object cannot.  That is
					| why this file is linked last (BUILDING.md:249-250).

| ============================================================================
| Counters and latches.  Read fpe_magic FIRST: at a stale address every other number here is
| a plausible lie.  Addresses are load_base + textsize + nm(.data offset), recomputed per
| image and never carried over.
|
| THAT ARITHMETIC IS THE `.data` RULE AND ONLY THE `.data` RULE.  The loader places .bss at
| data_end, so a `.bss` symbol is at load_base + textsize + DATASIZE + nm(.bss offset), and
| applying the line above to one lands inside somebody else's .data and returns numbers that
| look perfectly reasonable.  That is not hypothetical: it happened to the one block in this
| lane that had no magic to catch it.  See docs/contracts/FPE-R10-VEC60.md section 10.4.
|
| THIS IS NOT THE LANE'S ONLY GATED BLOCK.  src/fpe_glue.c's abort latches carry their own
| magic, fpe_abort_magic = "FPA!", for the same reason and with the same discipline: magic
| first, then fpe_abort_signo / _code / _addr.  They are in `.data` beside their magic
| precisely so that one rule covers a block and its gate together.
|
| SENTINELS ARE 0xFFFFFFFF and mean NOT APPLICABLE, not zero.  Counters start at 0; latches
| start at the sentinel, so "nothing was latched" cannot be read as "zero was latched".
| ============================================================================
	.data
	.globl	fpe_magic
fpe_magic:
	.long	0x46504521		| "FPE!"

| ---- controls ---------------------------------------------------------------------------
	.globl	fpe_enable
fpe_enable:
	.long	1			| 0 before boot = do not arm the emulator at all
	.globl	fpe_armed
fpe_armed:
	.long	0			| 1 once fpuinit armed the lane
| .type/.size on this one symbol and no other: src/check_fpe_relocs.py asserts that fpu_emul
| is a global OBJECT exactly as fpu_present is, so that the two flags differ in meaning and in
| nothing else.  An assembler label carries no type by default, which would have made the two
| distinguishable by accident.
	.globl	fpu_emul
	.type	fpu_emul,@object
	.size	fpu_emul,4
fpu_emul:
	.long	0			| THE state flag of frozen decision 9.  Never conflate
					| with fpu_present, which keeps meaning "real silicon"
	.globl	fpe_cputype
fpe_cputype:
	.long	2			| NetBSD's encoding (CPU_68040 2, CPU_68060 3), which is
					| what the extracted tree compares against
	.globl	fpe_cputype_amix
fpe_cputype_amix:
	.long	0xffffffff		| AMIX's own cputype as THIS LANE reads it -- the round-4
					| assertion for the width defect.  60 on a 68060, 40 on a
					| 68040; 0 would mean the half-word read is back.  SENTINEL
					| 0xFFFFFFFF = the lane never armed, so nothing read it
	.globl	fpe_cputype_bad_n
fpe_cputype_bad_n:
	.long	0			| entries where cputype was neither 40 nor 60.  Must stay 0
	.globl	fpe_disabled_n
fpe_disabled_n:
	.long	0			| fpuinit found no FPU and fpe_enable was clear

| ---- the pre-gate census (round 4 fix 5) --------------------------------------------------
| Counted BEFORE fpu_present and fpu_emul, so these move on every rig including FPU-present
| ones.  They are observers, not behaviour, and they are explicitly OUTSIDE the never-engage
| bar -- which remains fpe_entry_n == 0 and fpu_emul == 0 plus every behavioural counter at its
| initialiser.
	.globl	fpe_v11_n
fpe_v11_n:
	.long	0			| every vector-11 event: armed or not, user or supervisor
	.globl	fpe_v11_fmt4_n
fpe_v11_fmt4_n:
	.long	0			| 0x402c  eight-word, 68060 FP disabled
	.globl	fpe_v11_fmt2_n
fpe_v11_fmt2_n:
	.long	0			| 0x202c  six-word, 68040 unimplemented FP.  THE counter
					| FPE-GLUE-DESIGN.md 9 item 10 wanted and could not reach
	.globl	fpe_v11_fmt0_n
fpe_v11_fmt0_n:
	.long	0			| 0x002c  four-word, a genuine bad F-line word
	.globl	fpe_v11_fmtx_n
fpe_v11_fmtx_n:
	.long	0			| any other shape.  Must stay 0
	.globl	fpe_v11_last_fmtvec
fpe_v11_last_fmtvec:
	.long	0xffffffff		| ... its format/vector word, low half
	.globl	fpe_v11_fmt2_word
fpe_v11_fmt2_word:
	.long	0xffffffff		| the last format-2 frame's own word, low half.  Motorola's
					| x_fline.sa says 0x202c; this is where the tree finally
					| latches it from real silicon rather than citing it --
					| round 5 read 0x202c off 2,057 genuine 68040 frames, which
					| closes contract 8 item 2
	.globl	fpe_v11_fmt2_ia
fpe_v11_fmt2_ia:
	.long	0xffffffff		| ... and its +8 field: the OPERAND EFFECTIVE ADDRESS, 0
					| when the operand is a register.  Named _ia before it was
					| measured; nothing consumes it.  Contract 6.2

| ---- the vector-11 arm ------------------------------------------------------------------
	.globl	fpe_entry_n
fpe_entry_n:
	.long	0			| vector-11 events that reached the arm with the lane
					| armed.  THE never-engage bar: 0 on every FPU-present rig
	.globl	fpe_fmt4_n
fpe_fmt4_n:
	.long	0			| eight-word format-4 frames -- every real LC060 event
	.globl	fpe_fmt2_n
fpe_fmt2_n:
	.long	0			| six-word format-2 (68040 unimplemented FP): declined
	.globl	fpe_fmt0_n
fpe_fmt0_n:
	.long	0			| four-word format-0: a genuine bad F-line -> SIGSYS
	.globl	fpe_fmtx_n
fpe_fmtx_n:
	.long	0			| any other shape.  Must stay 0; non-zero is a finding
	.globl	fpe_last_fmtvec
fpe_last_fmtvec:
	.long	0xffffffff		| the format/vector word of the last fmtx event, low half
	.globl	fpe_super_n
fpe_super_n:
	.long	0			| supervisor-origin FP.  Must stay 0; a kernel defect
	.globl	fpe_user_n
fpe_user_n:
	.long	0			| entries handed to the emulator

| ---- outcomes ---------------------------------------------------------------------------
	.globl	fpe_done_n
fpe_done_n:
	.long	0			| instructions emulated and resumed
	.globl	fpe_sig_n
fpe_sig_n:
	.long	0			| entries that ended in a signal, all classes
	.globl	fpe_sigfpe_n
fpe_sigfpe_n:
	.long	0			| ... SIGFPE, si_code derived from FPSR & FPCR
	.globl	fpe_sigill_n
fpe_sigill_n:
	.long	0			| ... SIGILL, including every fpe_panic
	.globl	fpe_sigsegv_n
fpe_sigsegv_n:
	.long	0			| ... SIGSEGV, including every failed copy
	.globl	fpe_sigother_n
fpe_sigother_n:
	.long	0			| ... anything else the emulator asked for
	.globl	fpe_last_signo
fpe_last_signo:
	.long	0xffffffff
	.globl	fpe_last_code
fpe_last_code:
	.long	0xffffffff		| the si_code actually delivered
	.globl	fpe_last_fpsr
fpe_last_fpsr:
	.long	0xffffffff		| fpf_fpsr as the glue read it back, for the derivation
| The si_addr pair (round 4 fix 6).  A real FPU defers an enabled arithmetic exception to the
| NEXT FP instruction and stacks that instruction's PC; the glue reports the instruction after
| the faulting one.  The two coincide whenever the next instruction is itself floating-point,
| which is why round 3's divide-by-zero row agreed exactly and its overflow row -- a loop whose
| only FP instruction is the faulting one -- did not.  Latching both ends the argument.
	.globl	fpe_last_si_addr
fpe_last_si_addr:
	.long	0xffffffff		| the si_addr actually delivered
	.globl	fpe_last_fault_pc
fpe_last_fault_pc:
	.long	0xffffffff		| ... and f_pcfi, the instruction that actually faulted
	.globl	fpe_undecoded_n
fpe_undecoded_n:
	.long	0			| SIGFPE whose enabled-and-raised set was EMPTY, so no
					| si_code could be derived -- decision 8 makes it SIGILL

| ---- asynchronous signal delivery from the SUCCESS path (round 4 fix 1) -----------------
| Round 3: a process in a pure-FP loop could not be signalled at all, SIGKILL included, because
| issig/psig were reached only when the emulator itself raised a signal.  fpe_sigpend is
| u_trap's own three-condition gate; these two count what it lets through.
	.globl	fpe_sigpend_n
fpe_sigpend_n:
	.long	0			| successful emulations where the gate said "pending work".
					| Must be VASTLY smaller than fpe_done_n -- that is the gate
	.globl	fpe_sigdeliv_n
fpe_sigdeliv_n:
	.long	0			| ... and issig(0) agreed, so psig() ran

| ---- the abort paths --------------------------------------------------------------------
	.globl	fpe_panic_n
fpe_panic_n:
	.long	0			| emulator panic() sites reached.  Must stay 0
	.globl	fpe_panic_hard_n
fpe_panic_hard_n:
	.long	0			| ... with no unwind target: the kernel's own panic ran
	.globl	fpe_copyfail_n
fpe_copyfail_n:
	.long	0			| copyin/copyout inside the emulator that failed
	.globl	fpe_ufetch_n
fpe_ufetch_n:
	.long	0			| ufetch_short calls
	.globl	fpe_ufetchfail_n
fpe_ufetchfail_n:
	.long	0			| ... that faulted
	.globl	fpe_fault_addr
fpe_fault_addr:
	.long	0xffffffff		| the user address of the last failed access

| ---- the entry lock ---------------------------------------------------------------------
| The emulator holds its per-invocation state in file-static objects -- 396 bytes of
| .bss across fpu_emulate.c, fpu_log.c and fpu_rem.c -- so exactly one process may be inside
| it at a time.  fpe_busy is that lock and fpe_lock_wait_n is how round 3 finds out whether it
| is ever actually contended.  FPE-GLUE-DESIGN.md section 4.1 is the argument.
	.globl	fpe_busy
fpe_busy:
	.long	0			| 1 = a process is inside fpu_emulate()
	.globl	fpe_lock_wait_n
fpe_lock_wait_n:
	.long	0			| entries that had to sleep for it
	.globl	fpe_jb
fpe_jb:
	.long	0,0,0,0,0,0,0,0,0,0,0,0,0	| the unwind target, valid only while fpe_busy
	.globl	fpe_jb_active
fpe_jb_active:
	.long	0			| 1 = fpe_jb names a live frame

| ---- instruction-length instrumentation -------------------------------------------------
| On a format-4 frame the CPU stacks the PC of the instruction AFTER the faulting one, while
| the emulator computes its own resume PC as f_pcfi + is_advance.  For a STRAIGHT-LINE
| instruction the two must agree.  Contract 6.3 names a wrong is_advance as the sharpest
| standing risk in the package -- it resumes the process mid-instruction.
|
| ROUND 4: the comparison alone was saturated by a benign class.  A taken FBcc/FDBcc moves the
| PC off the straight line legitimately, and round 3 read 7,909,400 "misses" that were all
| exactly that -- an fbnel in libc's _doprnt, one per printf %f.  The glue now classifies the
| disagreement with the emulator decoder's own optype (fpu_emulate.c:145) before counting it,
| so fpe_advmiss_n is finally the length check it was written to be.
| NOTHING IS ACTED ON: the emulator's PC is used either way.
	.globl	fpe_advmiss_n
fpe_advmiss_n:
	.long	0			| a STRAIGHT-LINE advance != the CPU's stacked next-PC.
					| THE finding counter.  Must read 0 over a full session
	.globl	fpe_advctl_n
fpe_advctl_n:
	.long	0			| ... the disagreement was a taken FBcc/FDBcc.  Benign,
					| and free to be large: round 3's 7.9 M lands here
	.globl	fpe_advnofetch_n
fpe_advnofetch_n:
	.long	0			| ... the opword could not be fetched, so the class is
					| unknown.  Neither counted as a miss nor cleared.  Must be 0
	.globl	fpe_b_pc
fpe_b_pc:
	.long	0xffffffff		| the first TRUE miss: faulting instruction address
	.globl	fpe_b_stacked
fpe_b_stacked:
	.long	0xffffffff		| ... the PC the CPU stacked
	.globl	fpe_b_resume
fpe_b_resume:
	.long	0xffffffff		| ... the PC the emulator computed
	.globl	fpe_b_opword
fpe_b_opword:
	.long	0xffffffff		| ... and its opword, so the class is provable from the
					| counter dump alone and not only from a disassembler
	.globl	fpe_c_pc
fpe_c_pc:
	.long	0xffffffff		| the first EXCLUDED event: proof the exclusion fires
	.globl	fpe_c_opword
fpe_c_opword:
	.long	0xffffffff		| ... its opword.  optype = opword & 0x01C0 must be
					| 0x0080/0x00C0 (FBcc) or 0x0040 with (opword & 070) == 010

| ---- the presented FP state -------------------------------------------------------------
	.globl	fpe_save_n
fpe_save_n:
	.long	0
	.globl	fpe_save_wrt_n
fpe_save_wrt_n:
	.long	0			| ... declined because UFPRWRT was set
	.globl	fpe_rest_n
fpe_rest_n:
	.long	0
	.globl	fpe_rest_wrt_n
fpe_rest_wrt_n:
	.long	0			| ... that consumed a software-written model
	.globl	fpe_setup_n
fpe_setup_n:
	.long	0
	.globl	fpe_ss_setup_n
fpe_ss_setup_n:
	.long	0			| sendsig setups the stock gate would have refused.  It
					| replaces fpi_ss_skip_n, which must now read 0
	.globl	fpe_exec_setup_n
fpe_exec_setup_n:
	.long	0			| ... and exec setups, one per exec under emulation

| ---- the vector-60 arm (round 10, 2026-08-27) -------------------------------------------
| APPENDED AT THE END, for the same reason src/fpsp060_glue.s's M3 and M4 blocks were: every
| address already published for this block -- and the round-3..10 counter dumps are full of them
| -- keeps its offset.  Nothing above this line moved.
|
| The accounting closes, and closing it is the deliverable.  Round 10's failure was not that a
| process died; it was that a process died on an FP instruction and no fpe_* counter said so:
|
|	fpe_v60_n == fpe_ea_n + fpe_v60_decl_n		every vector-60 event is accounted
|	fpe_ea_n  == fpe_ea_done_n + fpe_ea_sig_n	every accepted event has an outcome
|
| The first five are PRE-GATE OBSERVERS and move on any 68060 including FPU-present ones, the
| same standing the fpe_v11_* family has.  Everything from fpe_ea_n down is behind both gates
| and belongs to the never-engage bar: 0 on every rig that has an FPU.
	.globl	fpe_v60_n
fpe_v60_n:
	.long	0			| every vector-60 event: armed or not, user or supervisor
	.globl	fpe_v60_fmt0_n
fpe_v60_fmt0_n:
	.long	0			| 0x00f0 -- the four-word frame the 68060 stacks for it
	.globl	fpe_v60_fmtx_n
fpe_v60_fmtx_n:
	.long	0			| any other shape.  MUST STAY 0: a non-zero reading
					| refutes FPE-R10-VEC60.md 2 and the arm declined, which
					| is why being wrong about it is survivable
	.globl	fpe_v60_last_fmtvec
fpe_v60_last_fmtvec:
	.long	0xffffffff		| ... and its format/vector word, low half.  SENTINEL
	.globl	fpe_v60_decl_n
fpe_v60_decl_n:
	.long	0			| events the arm declined, all reasons.  On a part with no
					| FPU these still take the package's path and still die
					| SIGSYS -- THE counter to watch, and the one whose absence
					| made round 10's death invisible

	.globl	fpe_ea_n
fpe_ea_n:
	.long	0			| vector-60 events handed to fpe_trap
	.globl	fpe_ea_super_n
fpe_ea_super_n:
	.long	0			| ... supervisor origin: declined.  Must stay 0
	.globl	fpe_ea_imm_n
fpe_ea_imm_n:
	.long	0			| ... an immediate-source arithmetic/fmove form (command
					| word bit 15 clear): handed to the emulator
	.globl	fpe_ea_pack_n
fpe_ea_pack_n:
	.long	0			| ... of which the source specifier was PACKED DECIMAL,
					| which the extracted emulator does not implement at all.
					| Observer: no behaviour hangs off it.  FPE-R10-VEC60.md 5.3
	.globl	fpe_ea_fmovmx_n
fpe_ea_fmovmx_n:
	.long	0			| ... fmovem.x with a register list, static or dynamic:
					| handed to the emulator, which implements both
	.globl	fpe_ea_fmovml_n
fpe_ea_fmovml_n:
	.long	0			| ... fmovem.l to 2 or 3 control registers: REFUSED with
					| SIGILL.  The emulator would report success, load every
					| selected register from the FIRST longword and advance 8
					| on a 12-byte instruction -- measured, FPE-R10-VEC60.md 9 T6
	.globl	fpe_ea_fetchfail_n
fpe_ea_fetchfail_n:
	.long	0			| ... the opword/command word could not be fetched:
					| SIGSEGV, nothing emulated.  Must be 0
	.globl	fpe_ea_done_n
fpe_ea_done_n:
	.long	0			| vector-60 entries the emulator completed and resumed
	.globl	fpe_ea_sig_n
fpe_ea_sig_n:
	.long	0			| vector-60 entries that ended in a signal, all classes.
					| Watch this beside fpe_sig_n: the two arms are counted apart
	.globl	fpe_ea_last_op
fpe_ea_last_op:
	.long	0xffffffff		| the last vector-60 entry's opword and command word as one
					| longword, so its class is provable from a counter dump
					| alone.  SENTINEL
	.globl	fpe_rewind_n
fpe_rewind_n:
	.long	0			| undecodable-SIGFPE aborts whose PC was rewound to the
					| faulting instruction.  The emulator advances the PC for
					| SIGFPE, which is right for a real arithmetic exception and
					| wrong for an operand format it refused without executing
	.balign	4			| pad .data to a multiple of 4 -- rel.c puts .bss at
					| data_end UNALIGNED
