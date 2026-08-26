| fpuinit060.s -- the 68060 boot FPU probe, and the gate at the one caller that never had one
| (F1-M1/M2, 2026-08-24).  Spec: docs/contracts/FPU-TIER1-ENABLE-SPEC.md:212-243, ten steps,
| each marked below.  Pre-registration: docs/060-F1-FPUINIT-PREREG-260824.md.
|
| WHAT WAS MISSING.  The override surface is four strong symbols -- fpu_save, fpu_restore,
| fpu_setup, fpuinit.  src/fpu060.s implemented three; this is the fourth, and it is the one
| that decides what the other three are allowed to do.  Until now the 68060 ran the stock probe,
| which asks an 040 question (is byte ZERO of the FSAVE frame null?) and issues its FSAVE into
| the inherited 8-byte COMMON reset_fsave -- four bytes short of a 68060 frame.
|
| THE THREE REGIMES this has to be correct in, all measured:
|
|   1  FPU present and ENABLED.  Probe passes, fpu_present = 1, eager save/restore.  This is
|      Antti's Mercury (fpc_save_n 8059 / fpc_rest_n 7647) and it must not change.
|   2  FPU present but DISABLED by PCR bit 1.  The stock probe fails HONESTLY -- fpu_present = 0
|      -- and then userland runs live FP anyway, because the FPSP's disabled call-out re-enables
|      the unit and re-executes.  Result: FP context nobody saves across a context switch.  Our
|      own 060 bench rig is in this state (Amiberry forces regs.pcr |= 2 at reset with no config
|      lever), which is why it can print "no fpu detected" and `awk 3.75` in the same boot.
|      Step 4 below moves this regime into regime 1, which is the fix for both problems.
|   3  NO FPU AT ALL (68LC060 / EC).  The disabled call-out clears PCR bit 1 and re-executes; on
|      a part with no FPU the clear does not stick, so it re-executes forever.  This is the
|      early-boot hang on amix-060-lc.uae, and src/fpsp060_glue.s now has an arm for it.
|
| WHY THE PROBE AND NOT THE PCR WRITE IS THE DECIDER.  The spec pre-refutes the shortcut in its
| own words (:238-240): "Do not simply clear PCR bit 1 and declare success.  A 68LC060 or EC
| variant can lack usable hardware FP, and vector 11 remains the authoritative negative probe."
| The readback at step 4 is a DIAGNOSTIC, not a test: on the LC rig Amiberry re-sets the bit
| (newcpu_common.cpp:172-178) and real LC silicon has nothing to enable, so bit 1 reading back
| set is the part telling the truth rather than our write failing.
|
| PCR BIT 1 IS DFP -- the tree used to say EDEBUG in one place and FPU-disable in two others.
| Settled from Motorola's own 060SP sample handler before this file was written; the evidence
| chain is docs/060-PCR-BIT1-VERDICT-260824.md and the wrong comment is corrected in place in
| src/cputype060.s.  EDEBUG is bit 6.
|
| THE 68040 PATH IS A TAIL JUMP TO THE UNTOUCHED STOCK BODY, as in src/fpu060.s: every entry
| gates on `cputype == 60` with a memory-immediate compare (CCR only, no register touched) and
| jumps to the byte-asserted original otherwise.  Every counter in this file must read 0 on an
| 040 boot, and `FPUINIT060=0 sh relink-040.sh` omits the unit entirely and reproduces the
| baseline image -- the spec's own rollback switch (:460-462).
|
| REGISTERS.  Only %d0 and %a0, both caller-saved in this ABI and both already clobbered by the
| stock body.  fpuinit takes no arguments.
|
| WHY THE SAVED VECTOR LIVES IN .data AND NOT ON THE STACK.  Stock chk_fpu pushes the previous
| M68Kvec[11] and relies on it still being there after its landing pad rte's.  That works, but
| it makes the fault path depend on the stack layout of the path that faulted.  fpuinit runs
| once, single-threaded, before any process exists, so a static costs nothing and the fault and
| no-fault paths can then share one continuation with no stack contract between them.

	.text

| ---- offsets ------------------------------------------------------------------------------
	FP_FSAVE =	112		| fpu_info.fsave, from the pointer in fpu_ptr (= u + 0x9c)
	VEC11	=	44		| M68Kvec[11] = VBR + 11*4 -- F-line, and FP-disabled on 060
	F6_NULL	=	0x00		| 68060 FSAVE frame formats, discriminator at frame + 2
	F6_IDLE	=	0x60
	RF_FPCR	=	96		| reset_fregs layout, as stock chk_fpu writes it:
	RF_FPSR	=	100		| fp0-fp7 at 0, then FPCR, FPSR, FPIAR -- 108 bytes total
	RF_FPIAR =	104

| ============================================================================
| fpuinit -- reached through init_tbl, which carries exactly one relocation to this symbol.
| ============================================================================
	.globl	fpuinit
fpuinit:
	cmpil	&60,cputype		| CPU gate: CCR only, no register touched
	bnew	Lfi_stock
	addql	&1,fpi_n

| ---- step 1: fpu_present = 0.  Nothing downstream may assume an FPU before the probe says so.
	clrl	fpu_present

| ---- step 2: install a temporary vector-11 handler, preserving the prior entry.  It is
|      installed BEFORE the first 060-only instruction, so nothing between here and step 7 can
|      reach the normal SIGSYS path.  fpi_ok is the separate result flag the spec asks for
|      (:242-243); the landing pad clears it and nothing else writes it.
	movel	&1,fpi_ok
	.word	0x4e7a,0x8801		| movec %vbr,%a0
	movel	%a0@(VEC11),fpi_savedvec
	movel	&Lfi_trap,%a0@(VEC11)

| ---- step 3: read PCR.  Legal only because of the cputype gate above -- `movec %pcr` traps as
|      illegal on the 040, and the spec is explicit that executing it there is not a detection
|      method (:235-237).
	.word	0x4e7a,0x0808		| movec %pcr,%d0
	movel	%d0,fpi_pcr_pre

| ---- step 4: clear bit 1 (DFP) and write PCR back, then read it back as a diagnostic.
	bclr	&1,%d0
	.word	0x4e7b,0x0808		| movec %d0,%pcr
	.word	0x4e7a,0x0808		| movec %pcr,%d0
	movel	%d0,fpi_pcr_post	| bit 1 still set here = a part with no FPU to enable

| ---- steps 5 and 6: a dedicated long-aligned 16-byte buffer (a 68060 frame is 12; the
|      inherited COMMON reset_fsave is 8, which is why the stock probe must not be reused), a
|      reset FRESTORE, and an FSAVE of whatever the unit then holds.  On regimes 2 and 3 the
|      FRESTORE is itself an F-line instruction and traps here -- that is the point.
	lea	fpi_reset_frame,%a0
	frestore %a0@
	lea	fpi_frame,%a0
	fsave	%a0@

Lfi_cont:
| ---- step 7: restore vector 11 on EVERY path.  The landing pad rte's to this label, so the
|      fault path and the clean path share one restore and neither can skip it.
	.word	0x4e7a,0x8801		| movec %vbr,%a0
	movel	fpi_savedvec,%a0@(VEC11)

| ---- step 8: fpu_present = 1 only if no trap occurred AND byte 2 describes a valid 060 frame.
|      After a reset FRESTORE the frame must be NULL; IDLE is tolerated and counted; anything
|      else means the frame is not what the manual says and we decline.  fpi_frame starts as
|      0xFFFFFFFF sentinels, so an FSAVE that never wrote fails closed rather than reading 0.
	tstl	fpi_ok
	beqw	Lfi_none
	tstb	fpi_frame+2
	beqs	Lfi_yes
	cmpib	&F6_IDLE,fpi_frame+2
	bnes	Lfi_badfmt
	addql	&1,fpi_idle_n
	bras	Lfi_yes
Lfi_badfmt:
	addql	&1,fpi_badfmt_n		| must stay 0.  Non-zero = no trap, but not a 060 frame
	braw	Lfi_none
Lfi_yes:
	movel	&1,fpu_present

| ---- step 9: populate the reset programmer-model image from the hardware we just reset, in
|      the layout stock chk_fpu publishes (fp0-fp7, then the three control registers).  Separate
|      control-register moves, for the reason src/fpu060.s gives at length: it is the documented
|      060 sequence.  The complete 12-byte reset frame is fpi_reset_frame itself; fpu_setup
|      builds an identical null frame inline (fpu060.s Lst_*), so the slot the next FSAVE sees is
|      fully determined either way.
	lea	reset_fregs,%a0
	fmovemx	%fp0-%fp7,%a0@
	fmovel	%fpcr,%a0@(RF_FPCR)
	fmovel	%fpsr,%a0@(RF_FPSR)
	fmovel	%fpiar,%a0@(RF_FPIAR)

| ---- step 10: call the 060 setup body, and only now.
	jsr	fpu_setup
	rts

| ---- the negative outcome.  Stock's own tail, kept observable: proc 0's raw FP slot is left a
|      null frame and the boot log keeps the line every no-FPU boot has always printed.
Lfi_none:
	addql	&1,fpi_nofpu_n
	moveal	fpu_ptr,%a0
	clrl	%a0@(FP_FSAVE)
	pea	Lfi_msg
	jsr	printf
	addql	&4,%sp
	rts

Lfi_stock:
	jmp	fpuinit_orig		| 68040: the accepted body at 0x19bac, byte for byte

| ---- the temporary vector-11 landing pad.  Separate result flag, no SIGSYS path, and the
|      stacked PC is rewritten at frame + 2 -- which is the PC field of a format-0 F-line frame
|      and of the format-4 frame a 68060 builds for FP-disabled alike, so one landing pad covers
|      both.  Registers are untouched: every operand here is memory.
Lfi_trap:
	clrl	fpi_ok
	addql	&1,fpi_trap_n
	movel	&Lfi_cont,%sp@(2)
	rte

| ============================================================================
| fpu_setup_gated -- the sendsig call site.
|
| M68060-SUPPORT-LANDSCAPE.md:188-214 recommendation #1: call fpu_setup only when
| fpu_present != 0.  A relocation census of the pinned image (2026-08-24) says the problem is
| wider than the one site it names -- five of the eleven call relocations reach a body with no
| gate in front of them:
|
|     fpu_save     setuctxt+0x16     gated      restorecontext+0x12e  UNGATED
|                  coffcore+0x8a     gated      savecontext+0x7a      UNGATED
|                  swtch+0x1de       gated
|     fpu_restore  swtch+0x32        gated      restorecontext+0x154  UNGATED
|                                               savecontext+0xbe      UNGATED
|     fpu_setup    fpuinit+0x22      gated      sendsig+0x1f8         UNGATED
|                  setregs+0xd0      gated
|
| savecontext and restorecontext contain no reference to fpu_present at all -- there is no
| relocation to it anywhere in either body -- so the call-site fix alone would leave four sites
| open.  The load-bearing gates are therefore the ones inside the bodies (src/fpu060.s); this
| wrapper exists because the acceptance gate for F1-M2 asks for a COUNTER proving that signal
| delivery did not execute FRESTORE, and "the machine did not hang" is not that counter.
|
| The 040 path is a plain tail jump, with no counter and no fpu_present involvement, so signal
| delivery on a 68040 executes exactly the sequence it executes today.
|
| CORRECTION to the census table above (2026-08-24, after F1-M3 and F2-M0).  The four UNGATED
| marks on savecontext and restorecontext are WRONG; the table stays as written with this beside
| it.  Both bodies DO gate, through `jsr prhasfp` -- prhasfp is `movel fpu_present,%d0 / rts`,
| one instruction, so the gate is a CALL and not a relocation, and the census predicate ("does
| this body carry a relocation to fpu_present") could not see it.  restorecontext gates twice:
| `uc_flags & UC_FPU` at 0x58e8c, then prhasfp at 0x58e96.  savecontext runs prhasfp at 0x58f78
| and, on the no-FPU arm, CLEARS UC_FPU out of the caller's uc_flags at 0x58fdc.  Ten of the
| eleven sites are gated in stock and sendsig is the one that is not -- which is precisely what
| M68060-SUPPORT-LANDSCAPE.md:174-186 already said, with prhasfp named in its own column.  This
| wrapper is therefore the WHOLE F1-M2 fix and not a token counter beside a wider hole; the body
| gates in src/fpu060.s are defense in depth.  Full per-site evidence, read out of the booted
| image: docs/060-F1-M2-GATE-CENSUS-260824.md.
|
| Reading the two counters together, since they look contradictory and are not: fpi_ss_skip_n
| and fpc_setup_nofpu_n are in SERIES.  The refusal arm below ends in `rts` and never reaches
| fpu_setup, so on an LC part the wrapper counter climbs (898 on the F2-M0 ladder) while the
| body counter stays 0, by construction.  The FPU-rig mirror is fpi_ss_pass_n 879 / fpc_setup_n
| 2449.
| ============================================================================
	.globl	fpu_setup_gated
fpu_setup_gated:
	cmpil	&60,cputype
	bnew	Lsg_go
	tstl	fpu_present
	bnes	Lsg_have
	addql	&1,fpi_ss_skip_n	| the LC060 case: no FPU, so no FRESTORE in supervisor mode
	rts
Lsg_have:
	addql	&1,fpi_ss_pass_n
Lsg_go:
	jmp	fpu_setup

Lfi_msg:
	.asciz	"no fpu detected\n"
	.balign	4			| pad .text to a multiple of 4 (text/data must stay contiguous)

| ============================================================================
| Counters and diagnostics.  All 68060-only, so an 040 boot must show every one of them at 0.
| Read fpi_magic FIRST: if it is not "FPI!" the addresses below are stale and every other number
| here is noise.
| ============================================================================
	.data
	.globl	fpi_magic
fpi_magic:
	.long	0x46504921		| "FPI!"
	.globl	fpi_n
fpi_n:
	.long	0			| fpuinit entries on the 060 arm -- must be exactly 1
	.globl	fpi_trap_n
fpi_trap_n:
	.long	0			| the landing pad fired: the authoritative negative probe
	.globl	fpi_nofpu_n
fpi_nofpu_n:
	.long	0			| probes that ended with fpu_present = 0
	.globl	fpi_idle_n
fpi_idle_n:
	.long	0			| post-reset frame was IDLE (0x60) rather than NULL
	.globl	fpi_badfmt_n
fpi_badfmt_n:
	.long	0			| ... and neither: an invariant failure.  Must stay 0
	.globl	fpi_pcr_pre
fpi_pcr_pre:
	.long	0xffffffff		| PCR as found.  SENTINEL: 0xFFFFFFFF = never read
	.globl	fpi_pcr_post
fpi_pcr_post:
	.long	0xffffffff		| PCR after our DFP clear, read back.  Bit 1 still set
					| means the part has no FPU to enable -- regime 3
	.globl	fpi_savedvec
fpi_savedvec:
	.long	0			| M68Kvec[11] as found, restored at step 7
	.globl	fpi_ok
fpi_ok:
	.long	0			| the probe's own result flag, never the SIGSYS path
	.globl	fpi_ss_skip_n
fpi_ss_skip_n:
	.long	0			| sendsig asked for FP setup and was refused
	.globl	fpi_ss_pass_n
fpi_ss_pass_n:
	.long	0			| ... and was not
	.globl	fpi_frame
fpi_frame:
	.long	0xffffffff		| the probe FSAVE's target, 16 bytes, long-aligned.
	.long	0xffffffff		| A 68060 frame is 12 bytes and its format byte is at
	.long	0xffffffff		| frame + 2.  Sentinels so "not written" fails closed.
	.long	0xffffffff
	.globl	fpi_reset_frame
fpi_reset_frame:
	.long	0			| a complete 12-byte 68060 NULL frame: FRESTOREing it
	.long	0			| resets the unit, which is what the probe wants and
	.long	0			| what fpu_setup builds inline for each process
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
