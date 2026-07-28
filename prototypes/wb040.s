| wb040.s -- 68040 access-error WRITE-BACK replay (THE init-hang fix, 2026-06-24).
|
| The 68040 does NOT re-run a faulted WRITE on rte from an access error: the pending store's
| data/address/status sit in the format-7 frame's WB1/WB2/WB3 fields and the operating system
| must complete the write itself.  The stock (030-era) AMIX kernel has no such handler, so
| copyout(icode)'s FIRST faulting `movesl` (the lea word 0x4FFB0170 -> user 0x80800000, captured
| in WB3) was LOST while the rest of the copy landed -> init's lea never set USP -> systrap read
| the syscall args from a stale kernel USP = garbage -> empty exec path -> lookuppn busy-loops ->
| init never starts.  PROVEN: icode page = 0 / 00000028 / 700B4E40 / 60FE2F73 (only the first long
| missing); frame WB3S=0x0081 WB3A=0x80800000 WB3D=0x4FFB0170.
|
| k_trap routes a fault through userspace(frame): user faults -> usrxmemflt(frame, info), kernel
| faults -> krnxmemflt(frame).  Both run get_fault+ptest then as_fault to resolve the demand-fault.
| BOTH need the write-back replay (a supervisor store into a not-yet-present kernel page faults the
| same way), so this file wraps BOTH (same frame layout, same replay).  The replay runs ONLY after
| as_fault succeeded (orig ret == 0) so we never write into a still-unmapped page.
|
| Frame offsets (relative to the frame arg = fp@(8), == get_fault's frame, empirically dumped):
|   WB3S@+78 WB3A@+88 WB3D@+92 ; WB2S@+80 WB2A@+96 WB2D@+100 ; WB1S@+82 WB1A@+104 WB1D@+108.
| WBxS: valid = bit 7 (0x80); FC = bits 2-0; SIZE = bits 6-5 (0=long,1=byte,2=word).  Re-issue
| each valid write-back with `moves.<size> WBxD -> (WBxA)` under DFC = WBxS&7.
|
| Both are file-LOCAL ('t'): relink-040.sh globalizes+weakens them and aliases the originals
| (usrxmemflt_orig=0x5aede; krnxmemflt_orig binds to the NATIVE core in krnxmemflt040.s
| since 2026-07-13 -- the stock 0x5b140 body remains reachable as krnxmemflt_stock).

| ===========================================================================================
| 2026-07-28, ISSUE-22 -- DFC IS A CALLER'S REGISTER AND THIS FILE WAS EATING IT.
|
| Lwb_do sets DFC = WBxS&7 to re-issue a pending write-back with the faulted access's function
| code, and never restores it.  DFC is not saved by the exception mechanism, so the value
| survives the rte back into whatever the CPU was doing.  What it was doing is usually a copy:
| lcopyout sets DFC = 1 (user data) ONCE before its movesl loop, and 22% of all classifications
| on that loop's fault path are supervisor-data faults on the kernel segmap source (measured:
| us_odd_kern = 660 of us_calls = 2939 during one boot).  Any of those, if the frame carried a
| valid write-back, returns to the copy loop with DFC = 5.  The next movesl then looks a USER
| address up in the SUPERVISOR tree, faults with TM = 5, and k_trap's userspace() -- correctly
| reading the frame -- routes it to the kernel resolver, whose as_segat(&kas, userVA) cannot
| succeed.  EFAULT, with no as_fault call anywhere, which is exactly the measured signature:
|     DBG krnxflt FAILEXIT w=2 va=800C96B0 rw=2 depth=1     (b2verify's own malloc'd heap)
| It is rare because it needs a pending write-back with FC != 1 to be replayed mid-copy, and it
| is amplified by copyback because copyback is what leaves stores pending.
|
| The fix is to treat DFC the way the ABI treats every other caller register: save it on entry
| to the fault wrapper, restore it before returning.  Saving in the WRAPPER rather than in
| Lwb_do is deliberate -- it is nesting-safe (each invocation has its own frame, so a nested
| fault inside the replay restores the OUTER replay's DFC, which is the value that loop needs),
| and Lwb_do cannot use the stack at all: k_trap lands an unresolvable nested fault on Lwb_fail
| with the trap-time SP, whose rts expects the stack exactly as bsr left it.
| wb_dfc_on = 0 restores the old behaviour in one .data long, for an A/B inside a single boot.
| ===========================================================================================

	.text
	.globl	usrxmemflt
usrxmemflt:
	linkw	%fp,&-4			| fp@(-4) = the caller's DFC
	moveml	%d2-%d5/%a2-%a3,%sp@-
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%fp@(-4)
	moveal	%fp@(8),%a2		| 060-B: fmt-4 frame? synthesize an 040-style
	bsrw	wb060_sswsynth		| SSW at +76 BEFORE the stock classifier reads it
	movel	%d0,%d5			| XPAGE unit item 1: the ORIGINAL FSLW, which the
					| synthesis above has just destroyed in the frame.
					| It must live in a register wb040_replay preserves
					| (it clobbers d0-d3/a3), hence d5 rather than d3.
	movel	%fp@(12),%sp@-		| arg2 (fault info)
	movel	%fp@(8),%sp@-		| arg1 = trap frame
	jsr	usrxmemflt_orig
	addqw	&8,%sp
	movel	%d0,%d4			| save return (0 = demand-fault resolved)
	tstl	%d4
	bnew	Lu_done
	moveal	%fp@(8),%a2		| a2 = frame
	bsrw	wb040_replay
	moveal	u+0x730,%a0		| 060-B: fmt-4 page-crossing completion
	moveal	%a0@(124),%a1		| a1 = as = curproc->p_as
	bsrw	wb060_xpage
	tstl	%d0			| item 4: a PERMANENT far-page failure must reach the
	beqw	Lu_done			| caller instead of being masked by the near page's
	movel	%d0,%d4			| success -- otherwise the restart loops forever
Lu_done:
	bsrw	Lwb_dfccheck		| count DFC corruption whether or not the fix is on
	tstl	wb_dfc_on		| ISSUE-22: give the interrupted code its DFC back
	beqs	Lu_nodfc
	movel	%fp@(-4),%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	addql	&1,wb_dfc_n
Lu_nodfc:
	movel	%d4,%d0			| restore usrxmemflt's return value
	moveml	%fp@(-28),%d2-%d5/%a2-%a3
	unlk	%fp
	rts

	.globl	krnxmemflt
krnxmemflt:
	linkw	%fp,&-4			| fp@(-4) = the caller's DFC
	moveml	%d2-%d5/%a2-%a3,%sp@-
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%fp@(-4)
	moveal	%fp@(8),%a2		| 060-B: same fmt-4 SSW synthesis (uniform frame
	bsrw	wb060_sswsynth		| semantics; krnx reads other fields, harmless)
	movel	%d0,%d5			| XPAGE unit item 1: preserve the ORIGINAL FSLW
					| (see the usrxmemflt copy above for why d5)
	movel	%fp@(8),%sp@-		| arg1 = trap frame (krnxmemflt takes ONE arg)
	jsr	krnxmemflt_orig
	addqw	&4,%sp
	movel	%d0,%d4			| save return (0 = demand-fault resolved)
	tstl	%d4
	bnew	Lk_done
	moveal	%fp@(8),%a2		| a2 = frame
	bsrw	wb040_replay
	lea	kas,%a1			| 060-B: fmt-4 page-crossing completion, as = &kas
	bsrw	wb060_xpage
	tstl	%d0			| item 4: propagate a permanent far-page failure
	beqw	Lk_done
	movel	%d0,%d4
Lk_done:
	bsrw	Lwb_dfccheck		| count DFC corruption whether or not the fix is on
	tstl	wb_dfc_on		| ISSUE-22: give the interrupted code its DFC back
	beqs	Lk_nodfc
	movel	%fp@(-4),%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	addql	&1,wb_dfc_n
Lk_nodfc:
	movel	%d4,%d0			| restore krnxmemflt's return value
	moveml	%fp@(-28),%d2-%d5/%a2-%a3
	unlk	%fp
	rts

| --- Lwb_dfccheck (ISSUE-22, 2026-07-28): does this fault return with a DIFFERENT DFC than it
|     arrived with?  That is the whole mechanism, measured directly instead of waiting for its
|     rare downstream symptom: one control run produced 7686 copy-path faults and no misroute, so
|     "a fault during a copy" is not the trigger -- "a fault that eats DFC" is.  Counts on BOTH
|     sides of the wb_dfc_on A/B, because the corruption happens regardless of whether we then
|     repair it; with the fix on, this counter is the amount of damage the fix is undoing.
|     Called with the wrapper's frame live (fp@(-4) = the DFC saved on entry).  d0/d1 scratch. ---
Lwb_dfccheck:
	.word	0x4e7a,0x0001		| movec %dfc,%d0  -- what the replay left behind
	movel	%fp@(-4),%d1		| what the interrupted code had
	cmpl	%d1,%d0
	beqs	Lwb_dfcsame
	addql	&1,wb_dfc_changed
	movel	%d0,wb_dfc_lastnew
	movel	%d1,wb_dfc_lastold
Lwb_dfcsame:
	rts

| wb060_sswsynth (060-B, 2026-07-10; XPAGE unit 2026-07-28): a2 = trap frame.
| Clobbers d0/d1/d2 -- d2 was added when this began RETURNING the original FSLW in d0 (0 when
| the frame is not format 4).  Both callers save d2-d5, so that is in contract.
| The 68060 fmt-4 frame carries an FSLW (long @+76) instead of the 040 SSW (word @+76).
| The STOCK memflt classifiers read byte@+76 bit0 as the "read access" flag (040 SSW RW,
| CPU+0xC in the fmt-7 frame).  On a fmt-4 frame that bit is FSLW bit24 = RW-read, which
| the 060 sets ALSO for locked read-modify-write (TAS/CAS: RW field = 11) -- the 040 SSW
| reports those as WRITES.  Result without this: a user TAS hitting a COW page (libc's
| lock word, PTE W=1) classified as "READ of a write-protected resident page" -> routed
| to hardbus -> hardbus finds the phys present, returns 0 -> the 060 restarts the TAS ->
| same fault forever (the observed pid-5 boot hang, n>340000 iterations).
| Fix: when the frame is format 4, synthesize an 040-style SSW word IN PLACE at +76:
|     ATC (bit10) | read (bit8, ONLY for pure FSLW RW==10) | TM (bits 2-0, same encoding)
| RW==01 (write) and ==11 (RMW) both become "write" -- COW/unprotect is the correct
| resolution for both halves of a locked access.  Pure reads must STAY reads: rw=S_WRITE
| on a text-page read would fail segvn's protection check -> spurious SIGSEGV.
| FA (@+72) is NOT touched -- get_fault's fmt-4 branch reads it after this runs.
| Overwriting the FSLW upper word is safe: RTE ignores FSLW content, wb040_replay is
| fmt-7-gated, userspace()'s own fmt-4 decode runs BEFORE the memflt wrappers (k_trap),
| and u_trap reads no SSW at all.  Runs identically-harmless on 030/040 (fmt != 4).
wb060_sswsynth:
	moveq	&0,%d0
	moveb	%a2@(70),%d0		| format/vector high byte
	lsrb	&4,%d0
	cmpiw	&4,%d0			| 060 format-4 access error?
	bnew	Lws_none
	movel	%a2@(76),%d2		| d2 = the ORIGINAL FSLW, kept INTACT for the return.
					| d1 cannot serve: the RW test below masks it down to
					| bits 24-23, which is what a first cut of this change
					| returned by mistake.
	movel	%d2,%d1
	movel	%d1,%d0
	swap	%d0
	andil	&7,%d0			| TM (FSLW bits 18-16) -> bits 2-0
	oriw	&0x0400,%d0		| ATC bit (it IS an MMU fault)
	andil	&0x01800000,%d1		| FSLW RW field (bits 24-23)
	cmpil	&0x01000000,%d1		| == 10 (pure read)?
	bnew	Lws_wr
	oriw	&0x0100,%d0		| read -> 040 SSW RW bit (bit8)
Lws_wr:
	movew	%d0,%a2@(76)		| replace FSLW upper word with the synthetic SSW
	movel	%d2,%d0			| item 1: RETURN the original FSLW to the wrapper.
					| Deliberately not stashed in the frame: +88 is WB3A in
					| the 040 fmt-7 layout and a fmt-4 frame is shorter, so
					| writing there would clobber a write-back slot or the
					| stack past the frame.  Nor a static: a nested fault
					| would overwrite it.  The wrapper's moveml saves d5 per
					| invocation, which makes the register copy nest-safe.
	rts
Lws_none:
	clrl	%d0			| not a fmt-4 frame: no FSLW to preserve
Lws_ret:
	rts

| wb060_xpage (060-B, 2026-07-10): the 060 fmt-4 counterpart of wb040_replay's byte-wise
| page-crossing handling (the ISSUE-7 class).  The 060 has no write-backs -- it RESTARTS
| the faulted instruction -- but for a misaligned access that CROSSES a page boundary it
| reports FA = the access's START address (MA set in FSLW) even when the missing page is
| the NEXT one.  as_fault then resolves the (already-present) near page, ret=0, the
| restart re-faults identically -> infinite loop (observed boot test 2: pid=159
| addr=40734FFE, an unaligned kernel u-stack store 2 bytes before page end; Linux/m68k
| handles the same 060 property with `if (fslw & MA) addr = (addr + 7) & -8`).
| After a SUCCESSFUL *_orig (ret==0), if the frame is fmt-4 and FA lies in the LAST 8
| BYTES of its page, also resolve the NEXT page (read, F_INVAL) -- the proven hardbus-
| XPAGE recipe.  Gated on fmt-4: on the 040 the byte-wise replay already covers this.
| In: a2 = frame, a1 = as (user: curproc->p_as, kernel: &kas).  Preserves d2-d7/a2-a3
| (as_fault is ABI-conformant); the wrapper's d4 (orig ret) is untouched.
| XPAGE UNIT 2026-07-28 (Codex vm-map/XPAGE-COVERAGE-AUDIT.md, a61d2ac).  The audit found the
| last-eight-bytes heuristic above is NOT an architecture-complete 060 contract, for three reasons
| it verified against the 68060 manual and Linux/m68k:
|   * MA WAS UNREADABLE HERE.  wb060_sswsynth overwrites FSLW bits 31..16 -- which holds MA (27),
|     RW (24-23), SIZE, TT and TM -- before this helper runs, so the helper could never consult the
|     one bit that actually means "this transfer spans two pages".  Fixed at the source: sswsynth
|     now RETURNS the original FSLW and the wrapper carries it here in d5.
|   * 96-BIT OPERANDS are valid on the 060 and 4-byte aligned, so one can begin at page+0xff4 --
|     before the 0xff8 gate.  And for an instruction extension-word fault FA points at the OPWORD,
|     which can be earlier still.  Linux/m68k therefore does not use an address window on the 060:
|     when MA is set it rounds FA up to the next page.
|   * S_READ WAS HARDCODED for write and RMW faults, and the far result was DISCARDED so a
|     permanently unmappable far page could still retry forever.
|
| TWO TIERS, for the same reason as the 040 native block: MA is the architectural truth, the window
| is what has actually been exercised.  MA set -> round up, real rw, and PROPAGATE the result.  MA
| clear but within the last 8 bytes -> exactly the old behaviour, result discarded.  So this is a
| strict superset of what shipped, not a replacement of it.
|     IO (FSLW lower half, preserved) distinguishes the instruction-extension case from the operand
| case.  It is deliberately NOT acted on separately: MA-rounding already covers both, and inventing
| a second rule from an unverifiable reading of IO is the kind of guess this unit exists to remove.
|
| In: a2 = frame, a1 = as, d5 = ORIGINAL FSLW (0 if the frame is not format 4).
| Out: d0 = 0 normally; nonzero = a permanent far-page failure the caller must propagate.
| Preserves d2-d4/a2-a3 (as_fault is ABI-conformant).
| NOTE: no 060 hardware exists in this project, so the MA tier is verified statically and by
| both-CPU boot regression only.  Amiberry's 060 is not assumed to model MA faithfully.
wb060_xpage:
	moveq	&0,%d0
	moveb	%a2@(70),%d0		| format/vector high byte
	lsrb	&4,%d0
	cmpiw	&4,%d0			| 060 format-4 frame?
	bnew	Lwx_none
	movel	%d5,%d1
	andil	&0x08000000,%d1		| FSLW MA (bit 27): the transfer spans two pages
	bnew	Lwx_ma
| --- tier 2: no MA -> the shipped last-eight-bytes behaviour, result discarded ---
	movel	%a2@(72),%d0		| FA
	movel	%d0,%d1
	andil	&0xfff,%d1
	cmpil	&0xff8,%d1
	bcsw	Lwx_none		| neither MA nor the window -> nothing to do
	andil	&0xfffff000,%d0
	addil	&0x1000,%d0		| next page base
	moveq	&1,%d1			| rw = S_READ (unchanged in this tier)
	bsrw	Lwx_call
	clrl	%d0			| discard: without MA we cannot tell a real crossing
	rts				| from a byte access that merely sits at 0xFFF, and
					| failing that access would be a NEW bug
| --- tier 1: MA set -> Linux/m68k's rule, real rw, and the result KEPT ---
Lwx_ma:
	movel	%a2@(72),%d0		| FA
	addil	&0xfff,%d0
	andil	&0xfffff000,%d0		| round_page(FA + PAGE_SIZE - 1): the page the transfer
					| actually needs, regardless of how far before the
					| boundary the operand or opword started
	movel	%d5,%d1
	andil	&0x01800000,%d1		| FSLW RW field (bits 24-23)
	cmpil	&0x01000000,%d1		| == 10 = pure read?
	bnew	Lwx_wr
	moveq	&1,%d1			| S_READ
	braw	Lwx_go
Lwx_wr:
	moveq	&2,%d1			| S_WRITE -- covers write AND locked RMW, the same
					| classification sswsynth applies to the near page
Lwx_go:
	bsrw	Lwx_call
	rts				| d0 = as_fault's result, PROPAGATED to the wrapper
Lwx_call:
	movel	%d1,%sp@-		| rw
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d0,%sp@-		| addr = the far page
	movel	%a1,%sp@-		| as
	jsr	as_fault
	lea	%sp@(20),%sp
	rts
Lwx_none:
	clrl	%d0			| nothing attempted -> nothing to propagate
Lwx_ret:
	rts

| wb040_replay: a2 = trap frame.  If it is an 040 format-7 access-error frame, re-issue every
| valid write-back (WB1, then WB2, then WB3).  Clobbers d0-d3/a3; preserves d4 (the orig return)
| and a2 (the frame) for the calling wrapper.  No stack frame (leaf-ish; only bsr to Lwb_do).
wb040_replay:
	moveq	&0,%d0
	moveb	%a2@(70),%d0		| format/vector high byte
	lsrb	&4,%d0
	cmpiw	&7,%d0			| 040 access-error (format 7) frame?
	bnew	Lwr_ret
	clrl	%d3
	movew	%a2@(82),%d3		| WB1S
	btst	&7,%d3
	beqw	Lwr_2
	moveal	%a2@(104),%a3		| WB1A
	movel	%a2@(108),%d2		| WB1D
| ISSUE-11 fix (2026-07-10): WB1D is BUS-LANE ALIGNED on real hardware -- unlike WB2D/
| WB3D, which are plain right-justified values.  NetBSD m68040_writeback realigns it:
|   off = (wb1a & 3) * 8;  LONG: rotate left by off;  WORD: rotate left by (off+16)%32;
|   BYTE: shift right by (24-off).  Without this, replaying a valid WB1 with WB2/3
| semantics writes the WRONG BYTES on a real 68040 (e.g. an aligned word store's data
| sits in WB1D bits 31-16 -- the old code wrote the low word = zeros).  EMULATOR-INERT:
| WinUAE/Amiberry never set WB1S valid (verified from source), so this path only ever
| runs on real silicon.  After realignment d2 is right-justified and Lwb_do applies.
	movel	%a3,%d0
	andil	&3,%d0
	lsll	&3,%d0			| d0 = off = (wb1a & 3) * 8
	movel	%d3,%d1
	lsrl	&5,%d1
	andil	&3,%d1			| SIZE: 0=long 1=byte 2=word
	beqw	Lw1_rot			| long: rotate by off
	cmpil	&1,%d1
	beqw	Lw1_byt
	addil	&16,%d0			| word: rotate by (off+16)%32
	andil	&31,%d0
Lw1_rot:
	tstl	%d0
	beqw	Lw1_ok
	roll	%d0,%d2
	braw	Lw1_ok
Lw1_byt:
	negl	%d0
	addil	&24,%d0			| byte: >> (24-off)
	beqw	Lw1_ok
	lsrl	%d0,%d2
Lw1_ok:
	bsrw	Lwb_do
Lwr_2:
	clrl	%d3
	movew	%a2@(80),%d3		| WB2S
	btst	&7,%d3
	beqw	Lwr_3
	movel	%d3,%d0			| ISSUE-11: skip SIZE=LINE WB2 (MOVE16 residue --
	lsrl	&5,%d0			| Linux does the same; the old code mis-replayed
	andil	&3,%d0			| a 16-byte line writeback as a 2-byte word write)
	cmpil	&3,%d0
	beqw	Lwr_3
	moveal	%a2@(96),%a3		| WB2A
	movel	%a2@(100),%d2		| WB2D
	bsrw	Lwb_do
Lwr_3:
	clrl	%d3
	movew	%a2@(78),%d3		| WB3S
	btst	&7,%d3
	beqw	Lwr_ret
	moveal	%a2@(88),%a3		| WB3A
	movel	%a2@(92),%d2		| WB3D
	bsrw	Lwb_do
Lwr_ret:
	rts

| Lwb_do: d3 = WBxS, a3 = target address, d2 = data.  Set DFC = WBxS&7, then replay the store
| BYTE-WISE (most-significant byte first), NOT with one wide moves.  A single wide moves on an
| UNALIGNED store that crosses a page boundary re-faults with FA = the NEAR address; as_fault
| resolves only the near (already-present) page, the far page never resolves, and the replay
| re-crosses forever -> infinite kernel-fault recursion eating the u-area stack (ISSUE-7,
| measured: WB3 FC=5 SIZE=long addr=0x40736FFE).  Per-byte moves.b gives each byte its OWN
| access: a byte in a not-yet-resident page faults with the CORRECT per-byte FA, as_fault
| resolves exactly that page, and the nested fault+replay converges (<=1 nested fault per page
| spanned).  Same bytes at the same addresses as the old wide moves for the aligned case.
| pflusha FIRST: when the faulting write was a write-PROTECT fault on a PRESENT page (do_reloc
| relocating libc.so.1's GOT, which it had just READ -> the page was resident read-only), as_fault
| COW'd it to a fresh writable page, but the 68040 ATC still holds the OLD read-only translation
| for this VA.  Without flushing, this moves re-issues the store through the stale read-only ATC
| entry and the write is lost -> the GOT stayed unrelocated.  (A not-present demand-fault write,
| e.g. suword, has no stale entry, which is why those persisted.)  Flush the whole ATC so the
| moves re-walks the page table and picks up the new writable PTE.
Lwb_do:
	.word	0xf518			| pflusha -- drop stale ATC entries before re-issuing the store
	addql	&1,wb_replay_n		| ISSUE-22 instrumentation: how often a replay runs at all
	moveq	&7,%d0
	andl	%d3,%d0			| FC = WBxS & 7
	cmpil	&1,%d0			| ...and how often it aims DFC somewhere other than user
	beqs	Lwb_fcok		| data, which is the hazard: the interrupted copy loop
	addql	&1,wb_replay_odd	| set DFC=1 ONCE and never reloads it (lcopyout 0x5a2)
Lwb_fcok:
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%d2,%d1			| d1 = data, to be left-justified -- BEFORE the size decode: movel
					| sets the CCs, and it must not clobber the Z flag between the
					| andil (Z = size==0) and the beqw that tests it
| --- u_nofault guard (2026-07-11, real-HW pid-12 sed panic): a moves fault here enters
|     k_trap in SUPERVISOR mode.  Stock k_trap resolves a supervisor fault on a USER
|     address ONLY when u+0x374 (the u_nofault landing pad, copyin/copyout convention)
|     is armed: armed -> userspace() -> usrxmemflt -> as_fault(p_as) -> ret 0 -> rte
|     re-executes the moves (converges); NOT armed -> krnxmemflt -> as_segat(&kas,
|     userVA) = NULL -> ret 1 -> krnlflt -> PANIC "KERNEL FAULT".  The emulators never
|     hit this (after as_fault+pflusha the WB target was always resident); real silicon
|     fills WB2/WB3 with the PREVIOUS instruction's pending store, which can aim at a
|     page as_fault never touched (first real-HW hit: pid 12 sed, WB target page just
|     hat_unload-FREELEAFed, pc=Lwb_loop movesb, fmt=7 vec=2, build -28 2026-07-10).
|     Arm the pad around the loop; on an UNRESOLVABLE fault k_trap restores u+0x374 and
|     rte's to Lwb_fail (frame PC := the armed value) with the trap-time registers.
|     d2 is free here (its data is already copied to d1); it survives the nested trap.
	movel	u+0x374,%d2		| save the outer u_nofault value
	movel	&Lwb_fail,u+0x374	| arm: unresolved nested fault lands at Lwb_fail
	movel	%d3,%d0
	lsrl	&5,%d0
	andil	&3,%d0			| SIZE: 0=long, 1=byte, 2=word; Z = (size==0), tested by the next insn
	beqw	Lwb_long
	cmpil	&1,%d0
	beqw	Lwb_byte
	swap	%d1			| word: d1 = d2<<16
	moveq	&2,%d0			| 2 bytes
	braw	Lwb_loop
Lwb_byte:
	swap	%d1
	lsll	&8,%d1			| byte: d1 = d2<<24
	moveq	&1,%d0			| 1 byte
	braw	Lwb_loop
Lwb_long:
	moveq	&4,%d0			| long: d1 = d2 as-is, 4 bytes
Lwb_loop:
	roll	&8,%d1			| rotate next MSB down into bits 7..0
	.word	0x0e1b,0x1800		| moves.b %d1,%a3@+  (per-byte access -> correct per-byte FA on fault)
	subql	&1,%d0
	bnew	Lwb_loop
	movel	%d2,u+0x374		| disarm: restore the outer u_nofault value
	rts
| Lwb_fail: u_nofault landing pad -- k_trap could NOT resolve a fault taken by the moves
| loop above (as_fault failed for the WB target: e.g. a WB aimed at a range a racing
| hat_unload just removed, or a garbage WB address).  Registers are the trap-time loop
| registers (a3 = the failing byte address, d3 = WBxS untouched by Lwb_do).  Restore
| u_nofault, log it (capped), SKIP the rest of this write-back and continue with the
| next one -- a lost user store beats a kernel panic; the process re-faults on its own
| if the address matters.
Lwb_fail:
	movel	%d2,u+0x374		| restore the outer u_nofault value FIRST
	movel	Lwbf_n,%d0
	cmpil	&8,%d0
	bccw	Lwbf_q			| capped -> skip silently
	addql	&1,%d0
	movel	%d0,Lwbf_n
	movel	%d3,%sp@-		| WBxS (identifies which WB + its FC/size)
	movel	%a3,%sp@-		| failing byte address
	pea	Lwbf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lwbf_q:
	rts
	nop				| pad .text to a multiple of 4 to keep text/data contiguous
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lwbf_msg:
	.asciz	"DBG wb040 replay UNRESOLVED addr=%x wbs=%x (wb skipped)"
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
Lwbf_n:
	.long	0
	.balign 4
| --- ISSUE-22 (2026-07-28): DFC restore, and the one .data long that turns it off ---
	.globl	wb_dfc_on
wb_dfc_on:
	.long	1			| 1 = restore the caller's DFC (the fix); 0 = A/B control
	.globl	wb_dfc_n
wb_dfc_n:
	.long	0			| restores performed -- the denominator for the A/B
	.globl	wb_dfc_changed
wb_dfc_changed:
	.long	0			| faults that returned with a DFC the caller did not set
	.globl	wb_dfc_lastold
wb_dfc_lastold:
	.long	0			| the caller's DFC in the most recent such fault
	.globl	wb_dfc_lastnew
wb_dfc_lastnew:
	.long	0			| what the replay left in DFC instead
	.globl	wb_replay_n
wb_replay_n:
	.long	0			| write-back replays performed (Lwb_do entries)
	.globl	wb_replay_odd
wb_replay_odd:
	.long	0			| ...of those, replays that set DFC to something != user data
	.balign 4
