| fpu060.s -- the 68060 FP context path: fpu_save, fpu_restore and fpu_setup, CPU-gated
| (ISSUE-43, 2026-08-12).
|
| WHAT IS WRONG WITH THE INHERITED CODE.  The stock routines decide whether a process has
| live FP state by testing the FIRST BYTE of its FSAVE frame:
|
|     fpu_save    0x144:  tstb %a0@(112) ; beq -> do NOT save fp0-7 / fpcr / fpsr / fpiar
|     fpu_restore 0x15e:  tstb %a0@(112) ; beq -> null_state -> frestore = RESET, restore nothing
|
| That is correct for a 68881/68882/68040 frame, where byte zero IS the format byte.  It is
| NOT correct on a 68060: there the frame discriminator lives at frame + 2, and word zero
| belongs to the extended SOURCE OPERAND and carries its exponent.  So on the 060 the stock
| test asks "was the source operand's exponent zero?" and answers a completely different
| question with it.
|
| MEASURED CONSEQUENCE (real hardware, 68060-260810-03 and -05, test-tools/fpenab060).  Of the
| six enabled IEEE exception classes, five returned Motorola's post-state bit for bit and
| divide-by-zero came back with FP0 = an all-ones NaN, FPSR = 0, FPIAR = 0 -- the FPU RESET
| state.  DZ is precisely the class whose source operand is ZERO, so byte zero read as zero,
| fpu_save concluded "no live FP state", dropped fp0-7, and fpu_restore's null path then
| frestore'd a frame it should never have classified as null.  The five that passed passed
| only because their operand exponents happened to be non-zero (-Inf 0x7fff, +2 0x4000, ...),
| which is not a property anything should depend on.
|
| SPECIFICATION.  docs/contracts/FPU-LAZY-CONTRACT-AUDIT.md (Codex, 64b55cf)
| section "D. Contract-derived CPU-specific state implementation", with the 060 sequences and
| the 12-byte reset frame from docs/contracts/FPU-TIER1-ENABLE-SPEC.md.  Independent confirmation of
| the discriminator: NetBSD switch_subr.s tests `2(%a2)` after fsave on the 060 and `(%a2)`
| otherwise (usr/src/sys/arch/m68k/m68k/switch_subr.s:123-129, 234-243), and frame.h:162-165
| defines FPF6_FMT_NULL 0x00 / FPF6_FMT_IDLE 0x60 / FPF6_FMT_EXCP 0xe0.
|
| WHAT THIS UNIT DOES *NOT* CHANGE, deliberately:
|
|   * UFPRWRT (bit 0 of u.u_fpu.ustate) keeps its inherited meaning and its inherited branch
|     ordering.  It is NOT a lazy-FPU ownership bit: it means software wrote the programmer
|     model in the u-vector and that image must be published to the FPU before normal context
|     switch processing (vanilla/usr/include/sys/fpu.h:49-56).  Its one originating setter is
|     procxmt / old ptrace at 0x47fac.  A previous attempt here SET this bit whenever the
|     frame looked null and turned 5-of-6 into 0-of-6 on hardware, because in fpu_save "set"
|     means SKIP SAVING.  Nothing below sets or clears it outside the paths that already did.
|
|   * The 68040 path.  Every entry gates on `cputype == 60` with a memory-immediate compare
|     (CCR only, no register touched) and tail-jumps to the untouched stock body otherwise.
|     This is the path every context switch and every signal takes on both CPUs; the 040 side
|     must be byte-identical, and the counters below must stay at zero on an 040 boot.
|
| WHY SEPARATE CONTROL-REGISTER MOVES on the 060 (fmovel %fpcr / %fpsr / %fpiar rather than
| stock's one fmoveml %fpiar/%fpsr/%fpcr): it is what the 060 context reference does, and what
| docs/contracts/FPU-TIER1-ENABLE-SPEC.md specifies.  Measurement says the multi-register form does execute
| in 060 hardware here -- an f60_entry_n delta of exactly +6 over a six-child fpenab060 run
| would be far larger if each save trapped into the package -- so this is not a bug fix, it is
| staying on the documented 060 sequence.
|
| WHY THE REGISTER ORDER IS STOCK'S AND NOT NetBSD's.  NetBSD's 060 branch restores the control
| registers before fp0-fp7; the inherited AMIX code does fp0-fp7 first and the control registers
| last, in both directions.  This unit keeps AMIX's order, for a reason worth writing down:
| test-tools/fpenab060_asm.s records that `fmovem.x %fp0,mem` overwrites FPIAR, and if that is
| true then loading FPIAR before an fmovem.x would discard the value just restored, while the
| inherited order is immune to the question either way.  Against that, five of six enabled
| classes returned their exact user-space FPIAR through stock fpu_save on silicon, which says
| the opposite.  The evidence is contradictory, the inherited order is the one that measured
| correct on hardware, and the audit's own instruction is to retain the inherited ordering.  So
| the ONLY change to the register traffic here is splitting one multi-control fmoveml into
| three fmovels -- neither form touches FPIAR.
|
| REGISTERS.  Only %a0, %a1 and %d0 are touched, all caller-saved in this ABI, and stock
| fpu_save/fpu_restore already clobber %a0.  swtch (the hot caller) reloads %d0 immediately
| after the call.  Counter bumps are memory-to-memory so no classification below costs a
| register.
|
| ADDED F1-M2 (2026-08-24): each 060 arm now also gates on `fpu_present`.  When this unit was
| written the 68060 always had an FPU, so `cputype == 60` was the whole question; on a 68LC060
| it is not, and every body below issues FSAVE or FRESTORE, which on a part with no FPU is an
| F-line exception taken in SUPERVISOR mode.  A relocation census of the pinned image says the
| callers cannot be relied on to ask first: savecontext and restorecontext contain no reference
| to fpu_present at all, so four of the eleven call sites reach these bodies ungated (the fifth
| is sendsig, and src/fpuinit060.s puts a counted wrapper there because F1-M2's acceptance gate
| wants a counter and not the absence of a crash).  The gate therefore belongs HERE, where every
| caller must pass through it.  The new fpc_*_nofpu_n counters are appended at the END of the
| block so that every address already published for it keeps its offset.
|
| CORRECTION to the paragraph above (2026-08-24, after F1-M3 and the F2-M0 trap census).  The
| claim "four of the eleven call sites reach these bodies ungated" is WRONG and is left above
| with this beside it.  Ten of the eleven are gated in stock; savecontext and restorecontext
| reach fpu_present through `jsr prhasfp`, whose whole body is `movel fpu_present,%d0` -- a
| CALL, not a relocation, which is exactly what a relocation-predicated census cannot see.
| sendsig was the one genuinely ungated site, which is the one the landscape names.
|
| So these gates are DEFENSE IN DEPTH, not the first line, and on an LC part nothing reaches
| them: fpc_save_nofpu_n / fpc_rest_nofpu_n / fpc_setup_nofpu_n all read 0 over kvp_n = 703492
| with kvp_super_n = 0 -- and nullvect, which is what kvp counts, is where both FP call-out arms
| land, so a supervisor FP trap would have shown.  They stay: a body gate cannot be bypassed by
| a caller, and sendsig is the standing proof that stock has a caller that forgets.  But their
| expected value is 0, and a NON-ZERO reading is a finding -- a caller outside the pinned eleven,
| or fpu_present set on a part that has no FPU.
| Per-site evidence: docs/060-F1-M2-GATE-CENSUS-260824.md.

	.text

| ---- offsets inside fpu_info, from the pointer stored in fpu_ptr (= u + 0x9c) ------------
| The layout is public in sys/fpu.h and confirmed by fpu_ptr's own relocation:
	FP_USTATE =	0		| long  ustate       -- bit 0 = UFPRWRT
	FP_REGS	=	4		| fpu_t regs         -- fp0-fp7, 8 x 12 bytes
	FP_FPCR	=	100		| long  fpu_control
	FP_FPSR	=	104		| long  fpu_status
	FP_FPIAR =	108		| long  fpu_iaddr
	FP_FSAVE =	112		| int   fsave[54]    -- raw FSAVE state, 216 bytes
	FP_FMT60 =	114		| FP_FSAVE + 2: the 68060 frame format byte
	F6_IDLE	=	0x60		| FPF6_FMT_IDLE
	F6_EXCP	=	0xe0		| FPF6_FMT_EXCP   (0x00 = FPF6_FMT_NULL)

| ============================================================================
| fpu_save -- called from swtch, setuctxt, savecontext, restorecontext and coffcore (5 sites).
| Contract, unchanged from stock except for the discriminator:
|   UFPRWRT set  -> return at once, do not overwrite the software-supplied image
|   otherwise    -> FSAVE the raw state; if the frame is not null, also save the programmer
|                   model.  Never set and never clear UFPRWRT here.
| ============================================================================
	.globl	fpu_save
fpu_save:
	cmpil	&60,cputype		| CPU gate: CCR only, no register touched
	bnew	Lfs_stock
	tstl	fpu_present		| no FPU on this part -> no FSAVE, whoever asked
	beqs	Lfs_nofpu
	addql	&1,fpc_save_n
	moveal	fpu_ptr,%a0
	btst	&0,%a0@(3)		| UFPRWRT -- low byte of the ustate long (big-endian)
	bnes	Lfs_wrt			| software image is newer: leave both components alone
	fsave	%a0@(FP_FSAVE)		| 12-byte 68060 frame
	movel	%a0@(FP_FSAVE),fpc_last_frame
					| diagnostic: word 0 = source exponent, word 1 = fmt
	tstb	%a0@(FP_FMT60)		| THE 68060 discriminator -- byte TWO, not byte zero
	beqs	Lfs_null
	cmpib	&F6_IDLE,%a0@(FP_FMT60)
	beqs	Lfs_idle
	cmpib	&F6_EXCP,%a0@(FP_FMT60)
	beqs	Lfs_excp
	addql	&1,fpc_odd_n		| neither null, idle nor exception: an invariant failure.
	bras	Lfs_live		| Counted loudly; the state is still saved faithfully.
Lfs_idle:
	addql	&1,fpc_idle_n
	bras	Lfs_live
Lfs_excp:
	addql	&1,fpc_excp_n
Lfs_live:
	fmovemx	%fp0-%fp7,%a0@(FP_REGS)
	fmovel	%fpcr,%a0@(FP_FPCR)	| separate moves: the documented 060 sequence
	fmovel	%fpsr,%a0@(FP_FPSR)
	fmovel	%fpiar,%a0@(FP_FPIAR)
	rts
Lfs_null:
	addql	&1,fpc_null_n		| genuinely no internal state -- the common case, and the
	rts				| only one in which dropping the registers is correct
Lfs_wrt:
	addql	&1,fpc_save_wrt_n
	rts
Lfs_nofpu:
	addql	&1,fpc_save_nofpu_n	| fpuinit's probe said there is nothing to save
	rts
Lfs_stock:
	jmp	fpu_save_orig		| 68040: the accepted body, byte for byte

| ============================================================================
| fpu_restore -- called from swtch, restorecontext and savecontext (3 sites).
| The inherited branch ORDER is load-bearing and is preserved exactly:
|   non-null frame -> publish the programmer model, FRESTORE, consume UFPRWRT
|   null frame     -> FRESTORE FIRST (a null frestore RESETS the FPU and would wipe anything
|                     loaded before it), then publish the software image only if UFPRWRT says
|                     one exists.  That branch is what makes ptrace/proc register writes stick
|                     for a process with no live raw state.
| ============================================================================
	.globl	fpu_restore
fpu_restore:
	cmpil	&60,cputype
	bnew	Lfr_stock
	tstl	fpu_present		| no FPU on this part -> no FRESTORE, whoever asked
	beqs	Lfr_nofpu
	addql	&1,fpc_rest_n
	moveal	fpu_ptr,%a0
	tstb	%a0@(FP_FMT60)		| byte TWO again -- same fix, same reason
	beqs	Lfr_null
	addql	&1,fpc_rest_live_n
	fmovemx	%a0@(FP_REGS),%fp0-%fp7	| stock's order: data registers first, controls last
	fmovel	%a0@(FP_FPCR),%fpcr
	fmovel	%a0@(FP_FPSR),%fpsr
	fmovel	%a0@(FP_FPIAR),%fpiar
	frestore %a0@(FP_FSAVE)
	andil	&-2,%a0@		| clear UFPRWRT (FP_USTATE = 0): image published
	rts
Lfr_null:
	addql	&1,fpc_rest_null_n
	frestore %a0@(FP_FSAVE)		| null frame: this resets the FPU, by design
	btst	&0,%a0@(3)		| did software supply a programmer model anyway?
	beqs	Lfr_out
	addql	&1,fpc_rest_wrt_n
	fmovemx	%a0@(FP_REGS),%fp0-%fp7
	fmovel	%a0@(FP_FPCR),%fpcr
	fmovel	%a0@(FP_FPSR),%fpsr
	fmovel	%a0@(FP_FPIAR),%fpiar
	andil	&-2,%a0@
Lfr_out:
	rts
Lfr_nofpu:
	addql	&1,fpc_rest_nofpu_n	| fpuinit's probe said there is nothing to restore
	rts
Lfr_stock:
	jmp	fpu_restore_orig

| ============================================================================
| fpu_setup -- called at boot (fpuinit), on exec (setregs) and on signal delivery (sendsig).
| Stock copies the inherited 8-byte COMMON reset_fsave into the raw slot, frestores it, copies
| the 108-byte reset_fregs image over the programmer model and clears ustate.  Eight bytes is
| an 040 frame; a 68060 frame is 12.  This body installs a complete 12-byte null frame so the
| slot the next FSAVE/FRESTORE sees is fully determined, and so that byte FP_FMT60 -- which
| the two routines above now read -- is written by us rather than left over from whatever the
| previous owner of that u-area stored there.
|
| The remaining 204 bytes of the 216-byte raw slot are left alone, exactly as stock leaves
| them: nothing reads past the frame, and zeroing them would add a per-signal cost for
| hygiene alone.  If a core-dump reader ever wants them deterministic, that is a separate
| change with its own measurement.
| ============================================================================
	.globl	fpu_setup
fpu_setup:
	cmpil	&60,cputype
	bnew	Lst_stock
	tstl	fpu_present		| no FPU on this part -> no FRESTORE in supervisor mode
	beqs	Lst_nofpu
	addql	&1,fpc_setup_n
	moveal	fpu_ptr,%a0
	clrl	%a0@(FP_FSAVE)		| 12 zero bytes = a null 68060 frame; byte 2 = 0x00
	clrl	%a0@(FP_FSAVE+4)
	clrl	%a0@(FP_FSAVE+8)
	frestore %a0@(FP_FSAVE)		| null frestore = FPU reset, same as stock's intent
	lea	reset_fregs,%a1		| the inherited 108-byte reset programmer model
	addql	&FP_REGS,%a0		| a0 = &fp->regs
	movel	&26,%d0			| 27 longs = 108 bytes = sizeof(fpu_t)
Lst_copy:
	movel	%a1@+,%a0@+
	dbf	%d0,Lst_copy
	moveal	fpu_ptr,%a0		| reload: the copy consumed a0
	clrl	%a0@			| ustate = 0 (FP_USTATE), dropping UFPRWRT -- stock does
	rts				| exactly this, and exec/signal setup is where it belongs
Lst_nofpu:
	addql	&1,fpc_setup_nofpu_n	| exec or signal delivery on a part with no FPU: the
	rts				| u-area's FP slot is left as it is, and nothing traps
Lst_stock:
	jmp	fpu_setup_orig

| ============================================================================
| Counters.  Every one of them is a 68060-only path, so an 040 boot must show all zeros --
| that is acceptance gate 1 of the audit, and it is checkable without a second kernel.
| Read fpc_magic FIRST: if it is not "FPC!" the addresses below are stale and every other
| number here is noise.
| ============================================================================
	.data
	.globl	fpc_magic
fpc_magic:
	.long	0x46504321		| "FPC!"
	.globl	fpc_save_n
fpc_save_n:
	.long	0			| 060 fpu_save entries
	.globl	fpc_save_wrt_n
fpc_save_wrt_n:
	.long	0			| ... that returned early because UFPRWRT was set.  Its
					| only originating setter is old ptrace, so this stays 0
					| unless something is debugging FP registers.
	.globl	fpc_null_n
fpc_null_n:
	.long	0			| post-FSAVE format byte 0x00 -- no live internal state.
					| The old byte-zero counter said 7100 per boot; that
					| number was collected with the wrong predicate and this
					| is its honest replacement.
	.globl	fpc_idle_n
fpc_idle_n:
	.long	0			| 0x60 idle
	.globl	fpc_excp_n
fpc_excp_n:
	.long	0			| 0xe0 exception
	.globl	fpc_odd_n
fpc_odd_n:
	.long	0			| anything else -- must stay 0; non-zero means the frame
					| is not what the 060 manual says it is
	.globl	fpc_last_frame
fpc_last_frame:
	.long	0			| the frame's first LONG as fpu_save saw it: high word
					| = source exponent, low word = format/status.  This is
					| the pair whose confusion caused ISSUE-43.
	.globl	fpc_rest_n
fpc_rest_n:
	.long	0			| 060 fpu_restore entries
	.globl	fpc_rest_live_n
fpc_rest_live_n:
	.long	0			| ... on a non-null frame (registers republished)
	.globl	fpc_rest_null_n
fpc_rest_null_n:
	.long	0			| ... on a null frame (FPU reset)
	.globl	fpc_rest_wrt_n
fpc_rest_wrt_n:
	.long	0			| ... null frame WITH UFPRWRT: the ptrace/proc case
	.globl	fpc_setup_n
fpc_setup_n:
	.long	0			| 060 fpu_setup entries (boot, exec, signal delivery)
| F1-M2 (2026-08-24) appended at the END so every address already published for this block keeps
| its offset.  These three count the calls the fpu_present gate REFUSED -- on a 68LC060 they are
| the ones that would otherwise have executed FSAVE or FRESTORE with no unit to execute them on,
| and each is attributable to its own routine rather than to one shared "we said no".
	.globl	fpc_save_nofpu_n
fpc_save_nofpu_n:
	.long	0			| fpu_save refused: fpu_present = 0
	.globl	fpc_rest_nofpu_n
fpc_rest_nofpu_n:
	.long	0			| fpu_restore refused
	.globl	fpc_setup_nofpu_n
fpc_setup_nofpu_n:
	.long	0			| fpu_setup refused (this is the sendsig/setregs path)
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
