| fpsp060_glue.s -- AMIX side of the M68060 FPSP (F3 M2b, 2026-08-08).
|
| Concatenated AFTER the package image by build-fpsp060.sh; see fpsp060_head.s for why the
| three pieces are one assembly unit.  Only the 128-byte table may precede the image, so
| every stub below lives past it.
|
| ============================ M2a -> M2b, AND WHY ============================
| M2a proved the WIRING: vector 11 on a 68060 reaches Motorola's package instead of falling
| through to nullvect.  It then panicked, because every call-out in it was a counted DECLINE:
| the memory family returned failure unconditionally and the twelve _060_real_* exits all did
| `jmp nullvect`.
|
| The panic's cause was NOT the exits.  Codex's static analysis of the pinned package object
| (amix-kernel-analysis vm-map/F3-FPSP060-CALLOUT-CONTRACT.md, 1868bdf) located it byte-exactly:
|
|     _fpsp_unimp fetches the faulting opword with `bsr _imem_read_long` and DOES NOT TEST d1.
|     M2a's decline stub returned d0 = 0, d1 = 1; the package decoded the zero opword, indexed
|     tbl_trans with a zero displacement and jsr'ed into the table itself.  Measured panic PC
|     fpsp060_image+0x1fb6 = tbl_trans+0x24, to the byte.
|
| So "fail every memory call-out" was never a supported package mode -- the package's own
| precondition is that the faulting instruction is readable, which the CPU already guaranteed by
| raising the exception.  M2b therefore implements the memory family for real, and the exits per
| class rather than uniformly.
|
| ============================ THE CALL-OUT ABI ============================
| The package does not link to OS symbols.  Each of its internal stubs loads a table-relative
| target and executes `pea target / rtd #4`, which preserves d0 and transfers control.  That has
| two consequences, and they are opposite:
|
|   * MEMORY call-outs are reached through `bsr`, so the package's return address is still at
|     (sp) and they are ordinary subroutines that end in `rts`.
|   * TERMINAL call-outs (_060_real_* and _060_fpsp_done) are reached through `bra`.  There is NO
|     return address.  They start with exactly the exception frame the package left at (sp), and
|     must end in `rte` or a tail jump into an OS exception handler.  `rts` would return into
|     whatever longword happens to be on the stack.
|
| A terminal exit must therefore hand nullvect the machine state the CPU would have handed it:
| every integer register as the package restored it, and the exact entry SP.  M2a violated that
| with `moveq #slot,%d0` before `jmp nullvect` -- it overwrote the restored USER d0 with a slot
| number.  Here the slot id is written to memory with an immediate instead, which touches no
| register at all.  CCR is the one thing a counted exit does change, and that is safe: the raw
| frame carries the user SR, and both nullvect and rte reload it from there.
|
| ============================ MEMORY FAMILY ============================
|     block   _060_imem_read / _060_dmem_read   a0 = user src,  a1 = super dst, d0 = count
|             _060_dmem_write                   a0 = super src, a1 = user dst,  d0 = count
|     scalar  _060_{i,d}mem_read_{byte,word,long}   a0 = user src  -> d0 = data
|             _060_dmem_write_{byte,word,long}      a0 = user dst, d0 = data
|     all     a6@(0x4) bit 5: 1 = supervisor, 0 = user;  OUT d1 = 0 success, non-zero failure
|
| a6 is the package's OWN frame -- it does `link.w %a6,#-192` on entry, which puts the raw
| stacked SR at a6@(4).  The vector wrapper must not build an a6 frame of its own.
|
| The user side goes through copyin/copyout rather than `moves` under a u_nofault pad.  Both are
| available here (wb040.s's Lwb_do is the moves shape), and copyin/copyout wins for three
| reasons: it is the primitive isp61_060.s already fetches user instruction words with and that
| is hardware-accepted; it owns function codes, address validation and the nofault landing pad
| itself, so this file cannot get SFC/DFC wrong the way ISSUE-22 did; and NetBSD's own comment
| records that the package's buffers are guaranteed to be on the stack precisely so a copy may
| sleep on a page fault.  Cost is one call per instruction word, against an emulation that is
| already thousands of cycles.
|
| a0/a1 are scratch across these (NetBSD's implementation clobbers both, and the package saves
| a0 itself where it needs it).  d2-d7/a2-a6 are preserved by the SysV ABI copyin/copyout obey.
| d0 is an OUTPUT for the reads and an INPUT for the writes, so the writes save and restore it.
|
| ============================ PRE-REGISTERED FOR M2b ============================
| One fp060probe run on the emulated 060:
|     f60_entry_n    +4        one package entry per trapping instruction
|     f60_mem_n      > 0       real instruction fetches, not declines
|     f60_done_n     +4        four normal completions
|     f60_real_n      0        no exception exit at all
|     f60_access_n    0        in particular no access-error exit
|     f60_memfail_n   0        no copy failed
|     kvp_vec[11]     0        vector 11 no longer reaches nullvect
| and fmovecr must return the CORRECT CONSTANT, not merely survive.  Survival is not
| correctness -- that is protfault's lesson and it is pre-registered here on purpose.

	.text

	F60_SR	=	0x4		| EXC_SR: package's link.w a6 puts the raw stacked SR here
	U_AR0	=	0x40000864	| u.u_ar0, same slot fpsp_glue040.s and isp61_060.s use

| ============================================================================
| vector-11 entry: jump into the package's F-line dispatcher.
|
| Reached from fpsp_vec11 when cputype == 60, with the RAW exception frame on (sp) -- which is
| exactly what the package expects, so nothing may be left pushed.
|
| The sup_cacr write is M2b's addition and it is not cosmetic.  The 040 wrapper installs the
| supervisor cache mode before entering its package, and every stock exception does the same in
| nullvect's first three instructions.  The 060 branch bypasses nullvect entirely, so without
| this the package -- and every copyin it calls -- would run under the USER cache mode.  It is
| also the other half of the _060_fpsp_done rule below: once supervisor CACR is installed, a
| user-origin exit may not be a bare rte, or user code resumes with the kernel's cache policy.
| ============================================================================
	.globl	fpsp060_vec11
fpsp060_vec11:
	movel	%d0,%sp@-		| temp save d0 (plan: touch nothing else)
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr  (kernel cache mode)
	addql	#1,f60_entry_n
	movel	%sp@+,%d0		| restore d0; SP now exactly as the CPU left it
	jmp	fpsp060_top+128+0x30	| _060_fpsp_fline

| ============================================================================
| M3 (2026-08-10): the other two package entries.  Identical shape to vector 11 -- the raw
| frame stays untouched on (sp), supervisor CACR goes in first, and the package leaves through
| the SAME call-outs M2b already provides (_060_fpsp_done, the _060_real_* family).  So this
| milestone is wiring, not new mechanism, which is why it could be deferred until something
| measured needed it.
|
| WHAT NEEDED IT.  Motorola's own suite named vector 60 on hardware: `ftest060 main` died with
| `Unimplemented <ea>` and the console printed `vector 0xF0, pc=0x80000CAC` (the kernel prints
| the vector OFFSET, 60 x 4).  Disassembled, that PC is
|     fmulx #-2.0,%fp0      -- a 64-bit multiply of an extended-precision IMMEDIATE
| i.e. an addressing mode the 68060 does not implement.  REALHW-260807-11-ACCEPTANCE.md 4b.
|
| Vector 55 is unimplemented DATA TYPE: denormals and packed decimal.  The 68040 side has been
| hooked since 2026-07-24, when the Xsvga X server was seen dying of SIGILL on exactly this
| (fpsp_glue040.s).  The 060 fell through to nullvect until now.
|
| Both bump f60_entry_n as well as their own counter, so the invariant that has been the most
| useful thing in this unit -- entry == done + the real_* exits -- keeps holding across all
| three entry points, while the per-vector counters still say WHICH one ran.
| ============================================================================
	.globl	fpsp060_vec55
fpsp060_vec55:
	movel	%d0,%sp@-		| temp save d0 (as vector 11: touch nothing else)
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr  (kernel cache mode)
	addql	#1,f60_entry_n
	addql	#1,f60_unsupp_n
	movel	%sp@+,%d0		| restore d0; SP exactly as the CPU left it
	jmp	fpsp060_top+128+0x38	| _060_fpsp_unsupp

	.globl	fpsp060_vec60
fpsp060_vec60:
	movel	%d0,%sp@-
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002		| movec %d0,%cacr
	addql	#1,f60_entry_n
	addql	#1,f60_effadd_n
	movel	%sp@+,%d0
	jmp	fpsp060_top+128+0x40	| _060_fpsp_effadd

| ============================================================================
| M4 (2026-08-10): the six IEEE arithmetic vectors.
|
| THE MAP IS A PERMUTATION AND THAT IS THE WHOLE RISK HERE.  The package's entry slots run in
| Motorola's order -- snan, operr, ovfl, unfl, dz, inex -- while the CPU's vectors run
| 48 bsun, 49 inex, 50 dz, 51 unfl, 52 operr, 53 ovfl, 54 snan.  Neither sequence is ascending
| in the other, so a slid-by-one mistake routes an overflow into the underflow handler: it does
| not crash, it returns a plausible wrong number.  The table below is therefore written out
| vector by vector, and every line is PROVED at run time by its own counter (see Lco_snan..).
|
| Cross-checked two ways before wiring: the call-out table in fpsp060_head.s runs
| bsun, snan, operr, ovfl, unfl, dz, inex -- the same order minus bsun -- and M1 decoded the
| entry slots from the linked .text.  The nine slots were re-decoded for M4 and every one holds
| a real bra.l to a distinct target, so none of the six is a reserved stub.
|
| VECTOR 48 (BSUN) IS DELIBERATELY NOT HERE.  The package exports a call-out for it
| (_060_real_bsun, and Lco_bsun implements it) but NO entry: the OS never dispatches vector 48
| into the package on the 68060.  That is the mirror image of the 68040, which hooks 48 and
| leaves 49/50 alone -- and the 040's stated reason, "the package exports no entry for them",
| is exactly the reason applied here, just landing on different vectors.  Neither map was
| copied from the other; the same rule was applied to each package separately.
| ============================================================================
| TWO counters per class, and they are not redundant.  The ENTRY counter below says "this
| vector reached the package"; the EXIT counter (f60_snan_n .. f60_inex_n, bumped in Lco_*)
| says "the package signalled this class".  They can legitimately differ: if the package FIXES
| an exception up and completes through _060_fpsp_done, an entry counter moves and no exit
| counter does -- and with only exit counters that run would look like nothing happened at all.
| Since M4 is the first time any of this code has ever executed, the pair is the difference
| between knowing and assuming.
#define F60VEC(name, off, vctr)		\
	.globl	name			;\
name:					;\
	movel	%d0,%sp@-		;\
	movel	sup_cacr,%d0		;\
	.word	0x4e7b,0x0002		;\
	addql	#1,f60_entry_n		;\
	addql	#1,vctr			;\
	movel	%sp@+,%d0		;\
	jmp	fpsp060_top+128+off

	F60VEC(fpsp060_vec49, 0x28, f60_vec49_n)	| 49 inexact       -> _060_fpsp_inex
	F60VEC(fpsp060_vec50, 0x20, f60_vec50_n)	| 50 divide-by-0   -> _060_fpsp_dz
	F60VEC(fpsp060_vec51, 0x18, f60_vec51_n)	| 51 underflow     -> _060_fpsp_unfl
	F60VEC(fpsp060_vec52, 0x08, f60_vec52_n)	| 52 operand error -> _060_fpsp_operr
	F60VEC(fpsp060_vec53, 0x10, f60_vec53_n)	| 53 overflow      -> _060_fpsp_ovfl
	F60VEC(fpsp060_vec54, 0x00, f60_vec54_n)	| 54 signaling NaN -> _060_fpsp_snan

| ============================================================================
| _060_fpsp_done -- the package emulated the instruction, advanced the PC in the frame and
| restored the user register and FP state.  This is NOT an exception: entering nullvect here
| would call u_trap for an event that no longer exists.
|
| A bare rte is what Motorola's skeleton does and it is wrong on AMIX for a user-origin frame:
| it would skip the STREAMS qrun, the scheduling-class trap return, pending signals, the stack
| frame adjustment and -- see the entry comment -- the user CACR restore.  So rebuild exactly
| the state nullvect->utraps->u_trap leaves at ureturn, WITHOUT calling u_trap.  This is the
| shape fpsp_glue040.s's fpsp_done and isp61_060.s's commit path already use, both accepted on
| hardware.  Supervisor origin has no ureturn to make and simply returns.
| ============================================================================
Lco_done:
	addql	#1,f60_done_n
	movel	#12,f60_last_co
	btst	#5,%sp@			| stacked SR high byte bit 5 = S bit
	bnes	Lcd_super
Lcd_user:
	moveml	%d0-%fp,%sp@-		| 60-byte D0-D7/A0-A6 block (== nullvect)
	movel	sup_cacr,%d0		| redundant with the entry in the straight-line case, and
	.word	0x4e7b,0x0002		| kept anyway: an emulation that slept in copyin came back
					| through resume, and matching fpsp_glue040.s exactly costs
					| two instructions and removes the question
	movel	%usp,%a0
	movel	%a0,%sp@-		| push USP as the pseudo-register
	movel	%sp,U_AR0		| u.u_ar0 = &pseudo-register (current sp)
	moveal	%sp@+,%a0		| pop USP slot; sp now at the reg block
	movel	%a0,%usp		| reload USP
	jmp	ureturn			| AMIX user-exception exit
Lcd_super:
	addql	#1,f60_superdone_n	| kernel-mode FP is not an intended AMIX workload
	rte

| ============================================================================
| The six IEEE arithmetic exits.  Reached only when the user has ENABLED that exception in the
| FPCR, with a valid arithmetic exception frame at (sp) and the exceptional/source operand still
| represented in the FP state.
|
| The three-instruction prelude is Motorola's (fskeletn.s) and NetBSD's (fnetbsd.S), identically:
| save the FP state frame, write 0x6000 into its status word, restore it.  It is not decoration.
| Without it the pending FP condition survives into the OS signal path, and the rte at the end of
| that path re-raises the same exception -- a retrap loop instead of a signal.  NetBSD then jumps
| to fpfault; our equivalent is nullvect, which dispatches on the frame's own vector (48-54) and
| reaches the stock SIGFPE policy.  No signal policy is introduced here.
|
| The 68060 FP state frame is 12 bytes -- read off the package's own local frame, where FP_SRC
| (LV+44) and FP_DST (LV+56) are 12 apart -- which is what makes Motorola's `addl #0xc,%sp` in
| the BSUN sequence below balance.
| ============================================================================
| M4 (2026-08-10) gives each class its OWN counter as well as f60_last_co.  f60_last_co keeps
| only the LAST class, and `ftest060 enabled` runs all six sub-tests in one process -- so with
| last_co alone a vector wired to the WRONG entry would still move f60_arith_n, still leave a
| plausible last_co, and look correct.  The six counters are what make the vector -> entry map
| provable in a single run instead of merely asserted from a table.
Lco_snan:
	movel	#1,f60_last_co
	addql	#1,f60_snan_n
	braw	Lco_fparith
Lco_operr:
	movel	#2,f60_last_co
	addql	#1,f60_operr_n
	braw	Lco_fparith
Lco_ovfl:
	movel	#3,f60_last_co
	addql	#1,f60_ovfl_n
	braw	Lco_fparith
Lco_unfl:
	movel	#4,f60_last_co
	addql	#1,f60_unfl_n
	braw	Lco_fparith
Lco_dz:
	movel	#5,f60_last_co
	addql	#1,f60_dz_n
	braw	Lco_fparith
Lco_inex:
	movel	#6,f60_last_co
	addql	#1,f60_inex_n
Lco_fparith:
	addql	#1,f60_real_n
	addql	#1,f60_arith_n
	fsave	%sp@-			| 12-byte 68060 FP state frame
| DIAGNOSTIC (2026-08-11): record the frame's FORMAT WORD before we touch it.  DZ came back
| from a returning SIGFPE handler with FP0 = an all-ones NaN and FPSR = FPIAR = 0 -- the FPU
| RESET state -- while the other five classes returned Motorola's exact post-state through this
| same body.  `frestore` of a NULL frame is precisely what resets the FPU, so the question is
| whether DZ's fsave yields a different frame here.  One word answers it.
|
| Memory-to-memory ON PURPOSE: this runs before nullvect saves the user's registers, so
| touching a data register here would corrupt what the signal handler and the resumed user code
| see.  That would have been a real bug introduced by a diagnostic.
| Motorola's three-instruction prelude, restored verbatim 2026-08-11 after a guard added here
| turned out to be a bug of its own.  Between 2026-08-10 and -11 this read
|
|     tstw %sp@ ; beq -> discard the frame without restoring it
|
| on the theory that DZ's fsave produced a NULL frame.  It does not.  Codex's audit
| (vm-map/FPU-LAZY-CONTRACT-AUDIT.md, 64b55cf) showed the discriminator on a 68060 is at
| frame+2, not at word zero: word zero is the extended SOURCE OPERAND's exponent.  The three
| words measured here -- OPERR 0x7fff, INEX 0x4000, DZ 0x0000 -- are exactly the exponents of
| -Inf, +2 and 0, i.e. of this test's own operands.  So the guard classified a ZERO SOURCE
| OPERAND as a null frame and threw the state away, which is a second bug rather than a fix.
|
| The correct sequence for all six IEEE exits, DZ included, is Motorola's: FSAVE, write the
| idle status 0x6000 at offset TWO, FRESTORE.  A word-zero null guard has no place in it.
	movew	%sp@,f60_last_fsave+2	| diagnostic only: word zero = the source exponent
	movew	#0x6000,%sp@(0x2)	| idle status at offset TWO -- the real discriminator
	frestore %sp@+			| balanced: sp is the raw frame again
| *** THIS JMP IS LOAD-BEARING AND IT WAS MISSING FOR ONE DAY ***  (2026-08-12)
| c13d3b8 removed the null-frame guard from this body -- correctly -- but the guard block
| ended in this jmp, so removing it left the arithmetic exit FALLING THROUGH into Lco_bsun.
| Measured on hardware the first time that build ran: per enabled exception, f60_arith_n +1
| AND f60_bsun_n +1, f60_real_n +2 against f60_entry_n +1, i.e. the unit's own
| "entry == done + real_* exits" invariant broken by exactly the amount of the fall-through.
| The user-visible damage was Lco_bsun's `andib #0xfe` clearing the FPSR NaN CONDITION bit on
| every arithmetic exit: OPERR came back 0x00002080 where Motorola's fixture says 0x01002080.
| Nothing crashed, because the BSUN prelude's stack arithmetic happens to balance -- which is
| exactly why an invariant counter found this and a passing test did not.
	jmp	nullvect		| vector 48-54 -> u_trap -> stock SIGFPE policy

| ---- BSUN (vector 48 via an FP conditional on an unordered compare) ----------------------
| Its prelude differs: clear the NaN condition in the FPSR and DISCARD the saved state rather
| than restoring it.  Verbatim from fskeletn.s/fnetbsd.S; the only change is the destination.
Lco_bsun:
	addql	#1,f60_real_n
	addql	#1,f60_bsun_n
	movel	#0,f60_last_co
	fsave	%sp@-
	fmovel	%fpsr,%sp@-
	andib	#0xfe,%sp@		| clear the FPSR NaN condition bit
	fmovel	%sp@+,%fpsr
	addl	#0xc,%sp		| discard the 12-byte saved state
	jmp	nullvect

| ============================================================================
| The non-arithmetic exits.  Each carries a frame the package built or preserved for exactly
| the OS event it names, so each is a plain tail transfer with no FP-state prelude:
|
|   fline   the original four-word vector-11 frame: a genuinely illegal F-line instruction.
|           This is the pre-F3 behaviour restored -- nullvect -> u_trap -> SIGSYS -- and it
|           cannot loop, because the package jumps here directly rather than through M68Kvec[11].
|   trap    six-word format-2 vector-7 frame, synthesized from an emulated ftrapcc whose
|           condition was true.
|   trace   six-word format-2 vector-9 frame.  Motorola's sample rte's and thereby DISCARDS the
|           trace event; NetBSD jumps to its trace handler.  nullvect is ours.
|   access  eight-word format-4 vector-2 frame with the failing EA and a synthesized 68060 FSLW.
|           AMIX must NOT build a second frame: nullvect's dispatch already sees vector 2, and
|           usrxmemflt/krnxmemflt -- via wb060_sswsynth, which exists for exactly this frame
|           format -- consume the FSLW and EA and pick the fault/signal outcome.  Supervisor
|           origin takes the same entry and lands on k_trap through the S-bit dispatch, which is
|           what it should do: it must not be relabelled a user SIGSEGV here.
| ============================================================================
Lco_fline:
	addql	#1,f60_real_n
	addql	#1,f60_fline_n
	movel	#7,f60_last_co
	jmp	nullvect
Lco_trap:
	addql	#1,f60_real_n
	addql	#1,f60_trap_n
	movel	#9,f60_last_co
	jmp	nullvect
Lco_trace:
	addql	#1,f60_real_n
	addql	#1,f60_trace_n
	movel	#10,f60_last_co
	jmp	nullvect
Lco_access:
	addql	#1,f60_real_n
	addql	#1,f60_access_n
	movel	#11,f60_last_co
	jmp	nullvect

| ---- FPU disabled ------------------------------------------------------------------------
| An eight-word format-4 vector-11 frame saying an implemented FP instruction was attempted with
| PCR bit 1 set.  AMIX enables the FPU eagerly -- fadd/fsqrt/fintrz were measured retiring in
| hardware on this machine (060-FPU-STATE-260807.md) -- so this is an INVARIANT path, not an
| expected one.  Motorola's policy (clear the disable, point the frame at the current PC, rte)
| is self-healing and is what is implemented, but f60_fpudis_n exists so that "self-healing"
| never becomes "silent": a nonzero count means something turned the FPU off behind our back and
| is to be investigated, not tolerated.
Lco_fpu_disabled:
	addql	#1,f60_real_n
	addql	#1,f60_fpudis_n
	movel	#8,f60_last_co
	movel	%d0,%sp@-
	.word	0x4e7a,0x0808		| movec %pcr,%d0
	bclr	#0x1,%d0		| clear the FPU-disable bit
	.word	0x4e7b,0x0808		| movec %d0,%pcr
	movel	%sp@+,%d0
	movel	%sp@(0xc),%sp@(0x2)	| stacked PC := "current PC" -> re-execute the instruction
	rte

| ---- Motorola-reserved slots -------------------------------------------------------------
| NetBSD leaves these as 0 in its table; ours point here so that a package which ever calls one
| lands somewhere visible.  There is no documented frame for a reserved slot, so there is nothing
| safe to do with it: routing an unknown frame into nullvect would dispatch a made-up vector and
| deliver a made-up signal.  This is an invariant failure and is treated as one, the same way
| fpsp_glue040.s treats an unclassifiable 040 frame.
Lco_reserved:
	addql	#1,f60_reserved_n
	movel	#31,f60_last_co
	pea	Lresmsg
	jsr	panic
	| panic never returns
Lresmsg:
	.asciz	"68060 FPSP called a reserved call-out slot"
	.balign	4

| ============================================================================
| MEMORY CALL-OUTS.  Ordinary subroutines: the package's return address is at (sp).
| ============================================================================

| ---- block read: a0 = user src, a1 = supervisor dst, d0 = count -------------------------
Lco_imem_read:
Lco_dmem_read:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lmr_super
	movel	%d0,%sp@-		| count
	movel	%a1,%sp@-		| kernel dst
	movel	%a0,%sp@-		| user src
	jsr	copyin
	lea	%sp@(12),%sp
	movel	%d0,%d1			| copyin: 0 = success, and that is d1's contract too
	beqs	Lmr_out
	addql	#1,f60_memfail_n
Lmr_out:
	rts
Lmr_super:
	tstl	%d0			| a zero count would wrap the do-while below
	beqs	Lmr_sdone
Lmr_sloop:
	moveb	%a0@+,%a1@+
	subql	#1,%d0
	bnes	Lmr_sloop
Lmr_sdone:
	moveq	#0,%d1
	rts

| ---- block write: a0 = supervisor src, a1 = user dst, d0 = count ------------------------
Lco_dmem_write:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lmw_super
	movel	%d0,%sp@-		| count
	movel	%a1,%sp@-		| user dst
	movel	%a0,%sp@-		| kernel src
	jsr	copyout
	lea	%sp@(12),%sp
	movel	%d0,%d1
	beqs	Lmw_out
	addql	#1,f60_memfail_n
Lmw_out:
	rts
Lmw_super:
	tstl	%d0
	beqs	Lmw_sdone
Lmw_sloop:
	moveb	%a0@+,%a1@+
	subql	#1,%d0
	bnes	Lmw_sloop
Lmw_sdone:
	moveq	#0,%d1
	rts

| ---- scalar reads: a0 = user src -> d0 = right-justified data ---------------------------
| The user side stages into a four-byte supervisor landing area on the stack and copies into it,
| so the read is subject to the same address validation and fault handling as any other copyin.
| On failure d0 is left ZERO rather than partially filled: a package site that does check d1 gets
| its failure, and one that does not gets a defined value instead of a stale register.

Lco_imem_rw:
Lco_dmem_rw:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lrw_super
	subql	#4,%sp			| landing area
	pea	2			| count
	pea	%sp@(4)			| kernel dst = landing area
	movel	%a0,%sp@-		| user src
	jsr	copyin
	lea	%sp@(12),%sp		| sp -> landing area
	movel	%d0,%d1
	moveq	#0,%d0
	tstl	%d1
	bnes	Lrw_bad
	movew	%sp@,%d0		| zero-extended word
	addql	#4,%sp
	rts
Lrw_bad:
	addql	#1,f60_memfail_n
	addql	#4,%sp
	rts
Lrw_super:
	moveq	#0,%d1
	moveq	#0,%d0
	movew	%a0@,%d0
	rts

Lco_imem_rl:
Lco_dmem_rl:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lrl_super
	subql	#4,%sp
	pea	4
	pea	%sp@(4)
	movel	%a0,%sp@-
	jsr	copyin
	lea	%sp@(12),%sp
	movel	%d0,%d1
	moveq	#0,%d0
	tstl	%d1
	bnes	Lrl_bad
	movel	%sp@,%d0
	addql	#4,%sp
	rts
Lrl_bad:
	addql	#1,f60_memfail_n
	addql	#4,%sp
	rts
Lrl_super:
	moveq	#0,%d1
	movel	%a0@,%d0
	rts

Lco_dmem_rb:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lrb_super
	subql	#4,%sp
	pea	1
	pea	%sp@(4)
	movel	%a0,%sp@-
	jsr	copyin
	lea	%sp@(12),%sp
	movel	%d0,%d1
	moveq	#0,%d0
	tstl	%d1
	bnes	Lrb_bad
	moveb	%sp@,%d0		| zero-extended byte
	addql	#4,%sp
	rts
Lrb_bad:
	addql	#1,f60_memfail_n
	addql	#4,%sp
	rts
Lrb_super:
	moveq	#0,%d1
	moveq	#0,%d0
	moveb	%a0@,%d0
	rts

| ---- scalar writes: a0 = user dst, d0 = data --------------------------------------------
| d0 is an INPUT here, and the package's trampoline preserves d0 across the transfer, so it must
| survive the call-out too.  Pushing d0 does double duty: it is both the saved copy and the
| staging buffer, and because the 68060 is big-endian the byte to write is the pushed longword's
| LAST byte and the word is its last two -- hence the +11 / +10 / +8 source addresses below.

Lco_dmem_wb:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lwb_super
	movel	%d0,%sp@-		| saved d0 AND the staging buffer
	pea	1			| count
	movel	%a0,%sp@-		| user dst
	pea	%sp@(11)		| kernel src = low byte of the saved d0
	jsr	copyout
	lea	%sp@(12),%sp		| sp -> saved d0
	movel	%d0,%d1
	beqs	Lwb_out
	addql	#1,f60_memfail_n
Lwb_out:
	movel	%sp@+,%d0		| give the package its data register back
	rts
Lwb_super:
	moveq	#0,%d1
	moveb	%d0,%a0@
	rts

Lco_dmem_ww:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lww_super
	movel	%d0,%sp@-
	pea	2
	movel	%a0,%sp@-
	pea	%sp@(10)		| kernel src = low word of the saved d0
	jsr	copyout
	lea	%sp@(12),%sp
	movel	%d0,%d1
	beqs	Lww_out
	addql	#1,f60_memfail_n
Lww_out:
	movel	%sp@+,%d0
	rts
Lww_super:
	moveq	#0,%d1
	movew	%d0,%a0@
	rts

Lco_dmem_wl:
	addql	#1,f60_mem_n
	btst	#5,%a6@(F60_SR)
	bnes	Lwl_super
	movel	%d0,%sp@-
	pea	4
	movel	%a0,%sp@-
	pea	%sp@(8)			| kernel src = the saved d0 itself
	jsr	copyout
	lea	%sp@(12),%sp
	movel	%d0,%d1
	beqs	Lwl_out
	addql	#1,f60_memfail_n
Lwl_out:
	movel	%sp@+,%d0
	rts
Lwl_super:
	moveq	#0,%d1
	movel	%d0,%a0@
	rts

	.balign	4			| pad .text to a multiple of 4 (text/data must stay contiguous)

	.data
| Counters, in the isp61_* / wb_dfc_* convention: .data longs, read with /kpeek at
| 0x08000000 + textsize + nm(.data offset).  Recompute per image; check the magic FIRST.
| The first eight are the documented M2a block and keep their order and meaning, with one
| deliberate change: f60_real_n now counts EVERY terminal exception exit including access, so a
| single read answers "did the package give up at all"; f60_access_n remains its subset.
	.globl	f60_magic
f60_magic:
	.long	0x46503630		| "FP60" -- read before trusting any address here
	.globl	f60_entry_n
f60_entry_n:
	.long	0			| vector-11 entries handed to the package
	.globl	f60_mem_n
f60_mem_n:
	.long	0			| memory call-outs taken
	.globl	f60_real_n
f60_real_n:
	.long	0			| _060_real_* exception exits taken, ALL classes
	.globl	f60_access_n
f60_access_n:
	.long	0			| _060_real_access: a user/kernel memory fault
	.globl	f60_done_n
f60_done_n:
	.long	0			| _060_fpsp_done: a completed emulation
	.globl	f60_reserved_n
f60_reserved_n:
	.long	0			| a Motorola-reserved slot was called: panics
	.globl	f60_last_co
f60_last_co:
	.long	0			| table slot id of the last call-out taken
| ---- M2b additions ----
	.globl	f60_memfail_n
f60_memfail_n:
	.long	0			| copyin/copyout failures inside the memory family
	.globl	f60_arith_n
f60_arith_n:
	.long	0			| snan/operr/ovfl/unfl/dz/inex exits (enabled FP traps)
	.globl	f60_bsun_n
f60_bsun_n:
	.long	0			| _060_real_bsun exits
	.globl	f60_fline_n
f60_fline_n:
	.long	0			| genuinely illegal F-line: the pre-F3 SIGSYS path
	.globl	f60_trap_n
f60_trap_n:
	.long	0			| emulated ftrapcc with a true condition (vector 7)
	.globl	f60_trace_n
f60_trace_n:
	.long	0			| trace exits (vector 9)
	.globl	f60_fpudis_n
f60_fpudis_n:
	.long	0			| FPU found disabled -- an invariant failure, see above
	.globl	f60_superdone_n
f60_superdone_n:
	.long	0			| completions whose origin was supervisor mode
| M3 (2026-08-10) appended at the END so every address already published for this block --
| batteryrun6/7/8.sh read "f60_magic .. f60_superdone_n, 16 longs" -- keeps its offset.
	.globl	f60_unsupp_n
f60_unsupp_n:
	.long	0			| vector 55 entries: unimplemented DATA TYPE
	.globl	f60_effadd_n
f60_effadd_n:
	.long	0			| vector 60 entries: unimplemented EFFECTIVE ADDRESS
| M4 (2026-08-10): one counter per IEEE class, so `ftest060 enabled` can prove that each
| vector reached the entry it was wired to.  Appended at the end for the same reason as M3's.
	.globl	f60_snan_n
f60_snan_n:
	.long	0			| _060_real_snan   (vector 54)
	.globl	f60_operr_n
f60_operr_n:
	.long	0			| _060_real_operr  (vector 52)
	.globl	f60_ovfl_n
f60_ovfl_n:
	.long	0			| _060_real_ovfl   (vector 53)
	.globl	f60_unfl_n
f60_unfl_n:
	.long	0			| _060_real_unfl   (vector 51)
	.globl	f60_dz_n
f60_dz_n:
	.long	0			| _060_real_dz     (vector 50)
	.globl	f60_inex_n
f60_inex_n:
	.long	0			| _060_real_inex   (vector 49)
| Per-VECTOR entry counters.  See the F60VEC comment: these say the vector reached the package,
| the six above say the package signalled that class, and an exception the package repairs
| silently moves only these.
	.globl	f60_vec49_n
f60_vec49_n:
	.long	0
	.globl	f60_vec50_n
f60_vec50_n:
	.long	0
	.globl	f60_vec51_n
f60_vec51_n:
	.long	0
	.globl	f60_vec52_n
f60_vec52_n:
	.long	0
	.globl	f60_vec53_n
f60_vec53_n:
	.long	0
	.globl	f60_vec54_n
f60_vec54_n:
	.long	0
	.globl	f60_last_fsave
f60_last_fsave:
	.long	0			| format word of the fsave frame Lco_fparith saw, in the
					| low half.  Diagnostic for the DZ reset (2026-08-11).
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
