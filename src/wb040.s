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
|
| PROVEN BY INJECTION 2026-07-29 (68040-260729-03, two seconds, same boot, one .data long apart):
| with wb_dfc_on = 0 an injected DFC=5 aborted a 1 MiB read at ZERO bytes with errno 14 and printed
| the exact ISSUE-22 signature (`FAILEXIT w=2 va=80003228 rw=2 depth=1`, ssw 0x85 = TM 101 + write);
| with wb_dfc_on = 1 the same injection was absorbed 40 times inside one read that completed
| byte-complete.  See test-tools/issue22-misroute-260728.txt.
|
| 2026-07-29: the contract now covers SFC as well, on Codex's audit -- not because a victim exists
| (none does today) but because "this register happens to be harmless to clobber" is precisely the
| reasoning that hid ISSUE-22 for a month.  The memory-fault machinery returns BOTH function-code
| registers unchanged.
| ===========================================================================================

	.text
	.globl	usrxmemflt
usrxmemflt:
	linkw	%fp,&-8			| fp@(-4) = caller's DFC, fp@(-8) = caller's SFC
	moveml	%d2-%d5/%a2-%a3,%sp@-
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%fp@(-4)
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%d0,%fp@(-8)
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
	tstl	%d0			| ISSUE-42: 0 = every valid WB completed;
	bnew	Lu_wbdenied		| nonzero = one was permanently DENIED
| --- ISSUE-10 write-watch (2026-08-19, src/i10rev040.s).  The store this fault
|     completed has now landed; i10w_hook watches the poisoned longword and, when
|     it appears, latches THIS frame -- the writer's PC, privilege and registers.
|     Dormant (one tstl) until i10w_on; preserves d4/d5 and every other register. ---
	movel	&1,%sp@-		| ctx = 1: a USER store
	movel	%fp@(8),%sp@-		| the frame
	jsr	i10w_hook
	addqw	&8,%sp
	moveal	u+0x730,%a0		| 060-B: fmt-4 page-crossing completion
	moveal	%a0@(124),%a1		| a1 = as = curproc->p_as
	bsrw	wb060_xpage
	tstl	%d0			| item 4: a PERMANENT far-page failure must reach the
	beqw	Lu_done			| caller instead of being masked by the near page's
	bsrw	Lu_siginfo		| success -- otherwise the restart loops forever
	movel	%d0,%d4			| F4: d4 = si_signo, per the stock return contract
	braw	Lu_done
| ISSUE-42 (2026-08-12): a write-back was permanently denied and the ordered replay stopped
| there.  d0 = 1 the denied WB carried a USER function code -> the process must be told;
| d0 = 2 it carried a supervisor code -> the replay still stops, but the user signal ABI is not
| the place to report that.  Lwb_fail classifies by the WB's OWN FC rather than by which
| wrapper is running, because that is what the architecture makes authoritative.
Lu_wbdenied:
	cmpil	&1,%d0
	bnew	Lu_done			| supervisor-FC WB: stopped and counted, no signal
	bsrw	Lu_wbsiginfo		| k_siginfo_t built from the DENIED BYTE's own address
	movel	%d0,%d4			| d4 = si_signo, the same contract as the F4 path above
Lu_done:
	tstl	%d4			| ISSUE-42: remember the verdict of a FAILED user
	beqs	Lu_norec		| resolution.  When this call is the NESTED one taken by
	movel	%d4,wbf_signo		| a replay byte, k_trap gives up immediately after it and
	moveal	%fp@(12),%a0		| lands on Lwb_fail -- which then attributes the denial
	movel	%a0@(4),wbf_code	| from these instead of guessing a class.
	moveal	%fp@(8),%a0		| ...and from the CPU's own fault address, because the
	moveq	&0,%d0			| replay loop's a3 has already POST-INCREMENTED past the
	moveb	%a0@(70),%d0		| failing byte by the time the trap is taken -- measured
	lsrb	&4,%d0			| 2026-08-12: a3 read page_base+1 for a denial at
	cmpiw	&7,%d0			| page_base+0.  Format 7 only: that is the only frame
	bnes	Lu_norec		| carrying an FA at +84, and the only CPU that makes one.
	movel	%a0@(84),wbf_fa
| --- ISSUE-10 capture (2026-08-19, src/i10rev040.s).  This is the moment the wall
|     is real: the resolver gave up (d4 != 0), so the process is about to be told
|     about a fault it cannot survive -- and the word it tripped over is still
|     sitting in its own memory, in its own context, unwritten-over.  Nowhere
|     later is that true.  i10p_probe gates itself on the fault address being in
|     the kernel VA band, and stops walking for good once it finds something;
|     every other unresolved user fault pays one masked compare.  a0 and d0/d1 are dead here -- Lu_norec's
|     first act is bsrw Lwb_dfcinject, which writes d0 before it reads it -- and
|     the probe preserves everything else, d4 (the return value) included. ---
	movel	%a0@(84),%sp@-		| the fault address, as the CPU reported it
	jsr	i10p_probe
	addqw	&4,%sp
Lu_norec:
	bsrw	Lwb_dfcinject		| ISSUE-22 fault injection (see Lwb_dfcinject)
	bsrw	Lwb_dfccheck		| count DFC corruption whether or not the fix is on
	tstl	wb_dfc_on		| ISSUE-22: give the interrupted code its DFC back
	beqs	Lu_nodfc
	movel	%fp@(-4),%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%fp@(-8),%d0
	.word	0x4e7b,0x0000		| movec %d0,%sfc  -- same contract for the source side
	addql	&1,wb_dfc_n
Lu_nodfc:
	movel	%d4,%d0			| restore usrxmemflt's return value
	moveml	%fp@(-32),%d2-%d5/%a2-%a3
	unlk	%fp
	rts

	.globl	krnxmemflt
krnxmemflt:
	linkw	%fp,&-8			| fp@(-4) = caller's DFC, fp@(-8) = caller's SFC
	moveml	%d2-%d5/%a2-%a3,%sp@-
	.word	0x4e7a,0x0001		| movec %dfc,%d0
	movel	%d0,%fp@(-4)
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%d0,%fp@(-8)
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
	tstl	%d0			| ISSUE-42 item 9: the kernel path stops the replay for
	beqs	Lk_wbok			| the same reason the user path does -- a later WB must
	addql	&1,wbf_krn_n		| not run as though a failed earlier one completed --
Lk_wbok:				| but it has no infop and must NOT enter the signal ABI.
| --- ISSUE-10 write-watch: a KERNEL store into the write-protected user page --
|     copyout / bcopy / uiomove -- faults here.  i10w_hook names its exact PC. ---
	movel	&2,%sp@-		| ctx = 2: a KERNEL store
	movel	%fp@(8),%sp@-		| the frame
	jsr	i10w_hook
	addqw	&8,%sp
	lea	kas,%a1			| 060-B: fmt-4 page-crossing completion, as = &kas
	bsrw	wb060_xpage
	tstl	%d0			| item 4: propagate a permanent far-page failure
	beqw	Lk_done
	movel	%d0,%d4
Lk_done:
	bsrw	Lwb_dfcinject		| ISSUE-22 fault injection (see Lwb_dfcinject)
	bsrw	Lwb_dfccheck		| count DFC corruption whether or not the fix is on
	tstl	wb_dfc_on		| ISSUE-22: give the interrupted code its DFC back
	beqs	Lk_nodfc
	movel	%fp@(-4),%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc
	movel	%fp@(-8),%d0
	.word	0x4e7b,0x0000		| movec %d0,%sfc  -- same contract for the source side
	addql	&1,wb_dfc_n
Lk_nodfc:
	movel	%d4,%d0			| restore krnxmemflt's return value
	moveml	%fp@(-32),%d2-%d5/%a2-%a3
	unlk	%fp
	rts

| --- Lwb_dfccheck (ISSUE-22, 2026-07-28): does this fault return with a DIFFERENT DFC than it
|     arrived with?  That is the whole mechanism, measured directly instead of waiting for its
|     rare downstream symptom: one control run produced 7686 copy-path faults and no misroute, so
|     "a fault during a copy" is not the trigger -- "a fault that eats DFC" is.  Counts on BOTH
|     sides of the wb_dfc_on A/B, because the corruption happens regardless of whether we then
|     repair it; with the fix on, this counter is the amount of damage the fix is undoing.
|     Called with the wrapper's frame live (fp@(-4) = the DFC saved on entry).  d0/d1 scratch. ---
| --- Lwb_dfcinject (ISSUE-22, 2026-07-29): make the rare race deterministic.
|     The natural corruption happens ~218 times per boot but only matters when it lands inside a
|     copy loop that still has bytes to write, which is why it surfaces about once per 40 minutes
|     and why a 12-burst control run proved nothing.  This injects the SAME corruption on demand:
|     leave wb_dfc_force in DFC for the next wb_dfc_force_n faults, at exactly the point in the
|     epilogue where a leaking replay would have left it.
|
|     PLACED BEFORE THE RESTORE ON PURPOSE.  That is what makes it an A/B of the FIX and not just
|     of the mechanism:
|         wb_dfc_on = 0  -> the injected value survives    -> the interrupted copy must break
|         wb_dfc_on = 1  -> the wrapper repairs it         -> the interrupted copy must be fine
|     Self-limiting: the budget counts down, so an injection cannot leave the machine unusable
|     even if the harness dies between arming and disarming.  Arm it from the test program itself
|     (test-tools/dfcinject.c), microseconds before the read it is meant to hit -- a shell pipeline
|     spends its budget on the faults of its own exec. ---
Lwb_dfcinject:
	tstl	wb_dfc_force
	beqs	Lwb_noinject
	movel	wb_dfc_force_n,%d0
	beqs	Lwb_noinject		| budget spent: leave DFC alone
	subql	&1,%d0
	movel	%d0,wb_dfc_force_n
	addql	&1,wb_dfc_forced
	movel	wb_dfc_force,%d0
	.word	0x4e7b,0x0001		| movec %d0,%dfc  -- the leak, on demand
Lwb_noinject:
	rts

Lwb_dfccheck:
	.word	0x4e7a,0x0001		| movec %dfc,%d0  -- what the replay left behind
	movel	%fp@(-4),%d1		| what the interrupted code had
	cmpl	%d1,%d0
	beqs	Lwb_dfcsame
	addql	&1,wb_dfc_changed
	movel	%d0,wb_dfc_lastnew
	movel	%d1,wb_dfc_lastold
Lwb_dfcsame:
| --- SFC, the sibling Codex found (ISSUE22-DFC-ARCH-STATE-AUDIT.md, 7c314b2): ptest040.s:52 writes
|     SFC and never restores it, defended in its own comment by the exact assumption ISSUE-22
|     disproved for DFC.  There is no victim today -- every MOVES consumer sets its own function
|     code -- so this counter exists to keep that claim measured rather than assumed.  The write
|     itself is deliberately LEFT IN PLACE: it was added as insurance against DFC/SFC ambiguity on
|     real silicon, and the case for removing it rests on an emulator source reading.  Making the
|     leak harmless costs nothing; removing working hardware insurance on a manual's word does. ---
	.word	0x4e7a,0x0000		| movec %sfc,%d0
	movel	%fp@(-8),%d1
	cmpl	%d1,%d0
	beqs	Lwb_sfcsame
	addql	&1,wb_sfc_changed
Lwb_sfcsame:
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
	addql	&1,x60_fmt4_n		| F1 instrumentation: every fmt-4 frame, both wrappers
	movel	%d2,x60_last_fslw	| capture FSLW HERE -- the movew below overwrites bits
					| 31-16 (MA, RW, SIZE, TT, TM) in the frame itself
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

| Lu_siginfo (F4, 2026-08-06) -- faultcode_t -> k_siginfo_t for the USER fault path.
|
| WHY THIS EXISTS.  Returning nonzero from usrxmemflt is not enough to kill the process, which
| cost a whole evening to establish: x60_far_fail_n rose 32 340 times with no signal delivered.
| The stock resolver's contract, read from the binary (vanilla 0x5b120..0x5b12e):
|
|     5b120:  moveal %fp@(12),%a0 / movel %d0,%a0@     infop->si_signo = <signal>
|     5b12a:  moveal %fp@(12),%a0 / movel %a0@,%d0     return infop->si_signo
|
| and u_trap@0x5a5a2 then selects its /proc fault class by comparing infop->si_signo against
| SIGSEGV 11 / SIGBUS 10 / SIGFPE 8, while trapsig queues NOTHING while si_signo == 0.  Our
| wrapper left infop exactly as the SUCCESSFUL near-page call had set it -- zero.  The observable
| consequence was the 060 console printing "NOTICE: User BUS ERROR ... FAULT:1" once per retry:
| FAULT:1 is u_trap's default class, i.e. the signal number never arrived.
|
| si_addr names the DENIED FAR address (x60_far_addr), not the frame's near FA.  On a crossing
| access the CPU reports where the transfer STARTED, which is the page that was fine; reporting
| that to the process would be actively misleading.
|
| Field offsets from sys/siginfo.h: si_signo +0, si_code +4, si_errno +8, _fault._addr +12.
| Codes from the same header: SEGV_MAPERR 1, SEGV_ACCERR 2, BUS_ADRERR 2.
|
| KERNEL PATH DELIBERATELY UNTOUCHED.  krnxmemflt has no siginfo argument and keeps the plain
| zero/nonzero resolver convention; the shared far helper must never hand it a signal number.
| in:  d0 = faultcode_t, fp@(12) = infop
| out: d0 = si_signo.  Clobbers d0/d1/a0, all scratch here.
Lu_siginfo:
	moveal	%fp@(12),%a0		| infop, the same slot the stock resolver writes
	movel	%d0,%d1			| d1 = faultcode_t
	moveq	&11,%d0			| SIGSEGV
	cmpil	&4,%d1			| FC_PROT?
	bnes	Lus_nomap
	moveq	&2,%d1			| SEGV_ACCERR -- invalid permissions
	bras	Lus_store
Lus_nomap:
	cmpil	&3,%d1			| FC_NOMAP?
	bnes	Lus_bus
	moveq	&1,%d1			| SEGV_MAPERR -- address not mapped
	bras	Lus_store
Lus_bus:
	moveq	&10,%d0			| SIGBUS for FC_HWERR / FC_OBJERR and anything unknown:
	moveq	&2,%d1			| BUS_ADRERR.  Deliberately not silently mapped to
					| SIGSEGV -- a hardware error is not a protection error.
Lus_store:
	movel	%d0,%a0@		| si_signo
	movel	%d1,%a0@(4)		| si_code
	clrl	%a0@(8)			| si_errno
	movel	x60_far_addr,%a0@(12)	| si_addr = the denied far address
	addql	&1,x60_siginfo_n
	rts

| Lu_wbsiginfo (ISSUE-42, 2026-08-12) -- the same translation for a permanently DENIED write-back.
| Separate from Lu_siginfo on purpose: that one starts from a faultcode_t this wrapper produced,
| while here the verdict was reached by the NESTED resolution of the failing replay byte and is
| already a signal number plus an si_code.  Inventing a faultcode to feed the other helper would
| be a round trip through a lossy mapping, for no gain.
|
| si_addr is the failing write-back BYTE (contract item 6: "attribute the signal to the first
| failing WB byte, not the already-resolved near FA").  Reporting the frame's FA would name the
| page that was fine -- the near page whose resolution is precisely what made this replay run.
| in:  fp@(12) = infop; wbf_addr / wbf_signo / wbf_code recorded by Lwb_fail and Lu_done
| out: d0 = si_signo.  Clobbers d0/a0, both scratch here.
Lu_wbsiginfo:
	moveal	%fp@(12),%a0		| infop, the same slot the stock resolver writes
	movel	wbf_signo,%d0
	bnes	Lwbs_have
	moveq	&10,%d0			| nothing recorded -- SIGBUS/BUS_ADRERR rather than a
	movel	&2,wbf_code		| guessed SIGSEGV, and counted so the guess is visible
	addql	&1,wbf_nosig_n
Lwbs_have:
	movel	%d0,%a0@		| si_signo
	movel	wbf_code,%a0@(4)	| si_code -- the nested resolver's own verdict
	clrl	%a0@(8)			| si_errno
	movel	wbf_fa,%d1		| si_addr: the CPU's own fault address for the denied
	bnes	Lwbs_addr		| byte.  a3 is one PAST it (post-increment), so it is
	movel	wbf_addr,%d1		| only the fallback -- and a counted one, because using
	addql	&1,wbf_afb_n		| an address that is off by one would be a quiet lie.
Lwbs_addr:
	movel	%d1,%a0@(12)
	movel	%d0,wbf_last_signo	| what was ACTUALLY reported, kept for the next reader:
	movel	wbf_code,wbf_last_code	| the three inputs above are cleared by the next replay,
	movel	%d1,wbf_last_addr	| which on a running system is milliseconds away
	addql	&1,wbf_signal_n
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
| XPAGE UNIT 2026-07-28 (Codex docs/contracts/XPAGE-COVERAGE-AUDIT.md, a61d2ac).  The audit found the
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
	addql	&1,x60_compat_n		| F1: compat tier taken.  compat > 0 with ma == 0 for a
					| KNOWN crossing is new evidence and reopens the XPAGE
					| acceptance -- that is why this counter is separate
	movel	%d0,x60_last_fa		| d0 still holds the UNMASKED FA here (the window test
					| above masked d1, not d0)
	andil	&0xfffff000,%d0
	addil	&0x1000,%d0		| next page base
	moveq	&1,%d1			| rw = S_READ (unchanged in this tier)
	bsrw	Lwx_call
	clrl	%d0			| discard: without MA we cannot tell a real crossing
	rts				| from a byte access that merely sits at 0xFFF, and
					| failing that access would be a NEW bug
| --- tier 1: MA set -> Linux/m68k's rule, real rw, and the result KEPT ---
Lwx_ma:
	addql	&1,x60_ma_n		| F1: MA tier -- the architecture contract, and reading
					| 1 is the hardware answer M68060-XPAGE-ACCEPTANCE.md
					| has been waiting for
	movel	%a2@(72),%d0		| FA
	movel	%d0,x60_last_fa		| F1: capture BEFORE the round-up below rewrites d0
	addil	&0xfff,%d0
	andil	&0xfffff000,%d0		| round_page(FA + PAGE_SIZE - 1): the page the transfer
	movel	%d0,x60_far_addr	| F4: si_addr must name the DENIED far page, not the
					| near FA the CPU put in the frame
					| actually needs, regardless of how far before the
					| boundary the operand or opword started
	movel	%d5,%d1
	andil	&0x01800000,%d1		| FSLW RW field (bits 24-23)
	cmpil	&0x01000000,%d1		| == 10 = pure read?
	bnew	Lwx_wr
	moveq	&1,%d1			| S_READ
	addql	&1,x60_rw_read_n	| F1
	braw	Lwx_go
Lwx_wr:
	moveq	&2,%d1			| S_WRITE -- covers write AND locked RMW, the same
					| classification sswsynth applies to the near page
	addql	&1,x60_rw_write_n	| F1
Lwx_go:
	bsrw	Lwx_callp
	tstl	%d0			| F1: count ONLY the MA tier's failures -- the compat
	beqs	Lwx_maok		| tier discards its result by design, so counting it
	addql	&1,x60_far_fail_n	| here would misreport the retry-loop condition
Lwx_maok:
	rts				| d0 = as_fault's result, PROPAGATED to the wrapper
| Lwx_callp -- the MA tier's resolve, with the far page CLASSIFIED first (F3, 2026-08-06).
|
| WHY.  Lwx_call below asks as_fault the question "this page is not present" (F_INVAL).  For a
| far page that IS present but write-protected that question has no answer: as_fault finds the
| page mapped, has nothing to demand-fault, returns 0, and the 060 restarts the instruction into
| the same protection violation.  Measured, not deduced: xpagetest T3 span 397 213 successful
| resolves with x60_far_fail_n == 0 (docs/XPAGE-FPROT-FINDING-260806.md).
|
| The near page has always been classified -- usrxmemflt picks F_INVAL vs F_PROT from ptest's
| 030-form PSR.  This asks the same question about the far page, through the same routine, and
| only in the one case where the answer can differ: a WRITE.  For a read, a write-protected page
| is not a fault at all, so F_INVAL remains exactly right and the old path is taken unchanged.
|
| The shape is deliberately the one krnxmemflt040.s already uses and this port has proven:
| resident-and-writable or absent -> F_INVAL (the graceful revalidation path), write into a
| write-protected resident page -> F_PROT.  A kernel far page is safe here too: ptest's 060 walk
| covers only the live URP, so a VA outside it returns 030 I and we fall through to F_INVAL --
| i.e. today's behaviour, not a new one.
|
| ptest is C-ABI and its 060 walk clobbers d0/d1/a0/a1 -- a1 is our `as`, so all three are saved.
| It costs one software table walk per MA-tier crossing WRITE, which x60_ma_n says is rare
| (13 in a whole boot); x60_fprot_n exists so the cost and the path are both countable.
| in:  d0 = far page base, d1 = rw (S_READ 1 / S_WRITE 2), a1 = as
| out: d0 = as_fault result.  Preserves d2-d4/a2-a3 exactly like Lwx_call.
Lwx_callp:
	cmpil	&2,%d1
	bnew	Lwx_call		| not a write -> F_INVAL is the right question, as before
	moveml	%d0-%d1/%a1,%sp@-	| ptest clobbers d0,d1,a0,a1
	movel	%d0,%sp@-		| ptest(far page base)
	jsr	ptest
	addqw	&4,%sp
	btst	&11,%d0			| 030-form PSR W = resident and write-protected?
	bnew	Lwx_prot
	moveml	%sp@+,%d0-%d1/%a1
	braw	Lwx_call		| absent, or resident+writable -> F_INVAL, unchanged
| Lwx_prot -- resolve, then VERIFY, then give up permanently.
|
| MEASURED, 2026-08-06, emulated 060, kernel 68040-260806-03: classifying the far page and
| asking F_PROT was necessary but NOT sufficient.  xpagetest T3 still live-locked, and the
| counters said exactly where: x60_fprot_n 590 422 (the branch fires), x60_far_fail_n 0
| (as_fault returns success), and the instruction restarts into the same violation forever.
|
| So this branch does not trust as_fault's return value alone.  It re-runs ptest afterwards and
| treats "still resident and write-protected" as a PERMANENT failure, which the MA tier then
| propagates and the wrapper turns into a signal.  That is the only formulation that cannot
| live-lock regardless of WHY the resolve did nothing -- and a retry loop is a far worse outcome
| than a signal, because it wedges the CPU with no diagnosis.
|
| The legitimate COW case is unaffected: there the second ptest shows the page writable and the
| instruction restarts once, successfully.  x60_fprot_ok_n and x60_fprot_fail_n separate the two,
| and x60_last_afret keeps as_fault's own answer so a future reader does not have to re-derive
| what it claimed.
Lwx_prot:
	moveml	%sp@+,%d0-%d1/%a1
	addql	&1,x60_fprot_n		| F3: the branch that did not exist before
	moveml	%d0-%d1/%a1,%sp@-	| keep far base / rw / as across as_fault
	movel	%d1,%sp@-		| rw = S_WRITE
	pea	1			| type = F_PROT
	pea	4			| len
	movel	%d0,%sp@-		| addr = the far page
	movel	%a1,%sp@-		| as
	jsr	as_fault
	lea	%sp@(20),%sp
	movel	%d0,x60_last_afret	| what as_fault actually claimed
	tstl	%d0
	bnew	Lwx_protout		| as_fault reported failure -> propagate it unchanged
	movel	%sp@,%sp@-		| ptest(far page base) again -- did anything change?
	jsr	ptest
	addqw	&4,%sp
	movel	%d0,x60_last_psr2	| the verdict, kept for the same reason
	btst	&11,%d0
	bnew	Lwx_protfail		| STILL write-protected: the resolve changed nothing
	moveml	%sp@+,%d0-%d1/%a1
	addql	&1,x60_fprot_ok_n	| genuinely resolved (the COW case)
	clrl	%d0
	rts
Lwx_protfail:
	moveml	%sp@+,%d0-%d1/%a1
	addql	&1,x60_fprot_fail_n	| permanent: turn the retry loop into a signal
	moveq	&4,%d0			| FC_PROT -- a real faultcode_t, because the user wrapper
					| now TRANSLATES this into a k_siginfo_t.  krnxmemflt still
					| only tests it against zero, so its contract is unchanged.
	rts
Lwx_protout:
	lea	%sp@(12),%sp		| drop the saved copies; d0 = as_fault's own result
	rts
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
|
| ISSUE-42 (2026-08-12) -- RETURN VALUE.  d0 = 0 means every valid write-back completed.  Nonzero
| means one was permanently denied, the ordered replay STOPPED at it, and the wrapper must not
| report the near page's success as the outcome of the whole access.  1 = the denied WB carried a
| user function code, 2 = a supervisor one.  The abort does not come back through here: Lwb_fail
| is entered by k_trap's rte with the trap-time stack, so it drops Lwb_do's return address and
| returns straight to the wrapper.  That is what "stop the replay" means mechanically.
wb040_replay:
	moveq	&0,%d0
	moveb	%a2@(70),%d0		| format/vector high byte
	lsrb	&4,%d0
	cmpiw	&7,%d0			| 040 access-error (format 7) frame?
	bnew	Lwr_ret
	clrl	wbf_signo		| ISSUE-42: any verdict still recorded here is from an
	clrl	wbf_code		| EARLIER fault; only what this replay's own nested
	clrl	wbf_fa			| resolution records may attribute its denial.  These
					| three are INPUTS with a one-replay lifetime -- read
					| wbf_last_* for what was actually reported.
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
	movel	&1,wbf_slot		| which write-back, for the fail-fast diagnostics
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
	movel	&2,wbf_slot
	bsrw	Lwb_do
Lwr_3:
	clrl	%d3
	movew	%a2@(78),%d3		| WB3S
	btst	&7,%d3
	beqw	Lwr_ret
	moveal	%a2@(88),%a3		| WB3A
	movel	%a2@(92),%d2		| WB3D
	movel	&3,wbf_slot
	bsrw	Lwb_do
Lwr_ret:
	clrl	%d0			| ISSUE-42: reached only when nothing was denied.  The
	rts				| denied path never comes through here (see Lwb_fail).

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
| ISSUE-42 Q3 (2026-08-12, Codex docs/contracts/ISSUE42-WBREPLAY-FOLLOWUP-AUDIT.md): u_nofault is ONE
| scalar in the u-area and k_trap only tests it for non-zero.  It does not check the faulting PC,
| the SP, or any notion of who armed the pad.  Interrupts are not masked here, so an unrelated
| kernel fault taken while this is armed lands on Lwb_fail too -- with a foreign stack and a
| foreign d2.  The old code would then write that d2 into u_nofault and rts through someone
| else's stack; this unit's abort would additionally drop a long from it.  Fail-open corruption
| either way, and the audit's finding is that the static code never established otherwise.
| So: record WHO armed it and at WHICH stack, and let the pad refuse anything else.  a0/a1 carry
| the OUTER owner across the loop -- they are trap-time registers at the pad, which is how both
| the normal disarm and the abort restore a nested arm's parent.
	moveal	wbf_own_cookie,%a0
	moveal	wbf_own_sp,%a1
	movel	&0x57424f21,wbf_own_cookie	| "WBO!"
	movel	%sp,wbf_own_sp		| set BEFORE arming: never armed without an owner
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
	movel	%a0,wbf_own_cookie	| ...and the landing pad's outer owner, so a nested
	movel	%a1,wbf_own_sp		| replay hands the parent's arm back intact
	rts
| Lwb_fail: u_nofault landing pad -- k_trap could NOT resolve a fault taken by the moves
| loop above (as_fault failed for the WB target: e.g. a WB aimed at a range a racing
| hat_unload just removed, or a garbage WB address).  Registers are the trap-time loop
| registers (a3 = the failing byte address, d3 = WBxS untouched by Lwb_do).  Restore
| u_nofault, log it (capped), SKIP the rest of this write-back and continue with the
| next one -- a lost user store beats a kernel panic; the process re-faults on its own
| if the address matters.
|
| ISSUE-42 (2026-08-12): IT NO LONGER SKIPS AND CONTINUES.  The paragraph above was the whole
| defect.  "A lost user store beats a kernel panic" is true, but the third option -- tell the
| process -- was never on the table, and skipping silently made the kernel report success for an
| access half of which never happened.  Measured on the emulated 040 (protfault case c): the
| unprotected half of a crossing store landed, the protected half was denied, the denial was
| discarded here, and the process resumed holding half a store it believed complete.  A silently
| torn store, which is worse than a lost one.
|
| The contract is Codex's docs/contracts/ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md (8fd31fd), which read
| Motorola, NetBSD and Linux/m68k against this code: every valid write-back is an access that
| must either complete or report its OWN fault, in WB1/WB2/WB3 order, and a denial stops the
| replay rather than being dropped.  Item 6 of its behavioural contract is the part that lands
| here -- convert the failure into complete k_siginfo_t state using the FAILING write-back's
| address, not the near resolver's zero.
|
| WHY THE WB'S OWN FC DECIDES, and not which wrapper is running: a user write-back can be pending
| when a supervisor access faults and vice versa (that is exactly the ISSUE-22 shape).  The
| architecture makes each write-back's function code the authority on which address space it
| belongs to, so a user-FC denial is a user protection fault whichever wrapper is on the stack --
| and a supervisor-FC one must never enter the user signal ABI (contract item 9).
|
| HOW THE REPLAY ACTUALLY STOPS.  k_trap rte's here with the TRAP-TIME stack, so sp points at the
| return address `bsrw Lwb_do` pushed and sp@(4) at the one the wrapper pushed for wb040_replay.
| Dropping four bytes and returning therefore leaves the remaining write-backs unprocessed and
| hands d0 to the wrapper -- which is the mechanical meaning of "stop the ordered replay".
|
| wbf_prop_on = 0 restores the old swallow-and-continue behaviour in one .data long, for an A/B
| inside a single boot.  This is the hottest path in the kernel that this project touches --
| wb_replay_n reaches five figures per boot -- so it gets the same escape hatch ISSUE-22 has.
|
| KNOWN LIMIT, stated rather than hidden.  Contract item 8 also asks that pending write-back state
| be RETAINED across a signal whose handler repairs the mapping and returns.  This does not do
| that: the denied write-back and any after it are dropped once the fatal outcome is committed.
| For a process that dies -- the case ISSUE-42 is about -- that is exactly item 5.  For a handler
| that repairs and returns, those stores stay lost, as they were before this change, except that
| now the process was told.  Retaining them needs somewhere to keep per-process WB state, which is
| a bigger unit than this one and has no measured victim yet.
Lwb_fail:
| --- Q3: is this landing OURS?  Checked before a single byte of state is touched. ---
	movel	%sp,%d0
	cmpil	&0x57424f21,wbf_own_cookie
	bnew	Lwbf_alien
	cmpl	wbf_own_sp,%d0
	bnew	Lwbf_alien
	movel	%d2,u+0x374		| restore the outer u_nofault value FIRST
	movel	%a0,wbf_own_cookie	| and the outer owner, BEFORE anything below can fault
	movel	%a1,wbf_own_sp		| (audit item 5: clear ownership before logging)
	addql	&1,wbf_fail_n
	movel	%a3,wbf_addr		| the DENIED BYTE's own address: exact, because the
	movel	%d3,wbf_wbs		| replay loop goes byte by byte (the ISSUE-7 shape)
	movel	Lwbf_n,%d0
	cmpil	&8,%d0
	bccw	Lwbf_q			| print cap -- it caps the MESSAGE, not the propagation
	addql	&1,%d0
	movel	%d0,Lwbf_n
	movel	%d3,%sp@-		| WBxS (identifies which WB + its FC/size)
	movel	%a3,%sp@-		| failing byte address
	pea	Lwbf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lwbf_q:
	tstl	wbf_prop_on
	beqw	Lwbf_swallow		| A/B control: 0 = the pre-2026-08-12 behaviour
| --- classify the TRANSFER MODIFIER.  The follow-up audit corrected this: WBS & 7 is a TM, not
|     universally a logical function code.  TM 1/2 are user data/code, 5/6 supervisor data/code,
|     3/4 MMU TABLE SEARCH, 0 a data-cache PUSH and 7 reserved.  The first version of this code
|     bucketed 0..2 as "user", which would have delivered SIGSEGV to a process for a failed cache
|     push -- an event that is not its fault and not even its access. ---
	moveq	&7,%d0
	andl	%d3,%d0
	movel	%d0,wbf_fc
	cmpil	&1,%d0			| TM 1 = user data
	beqw	Lwbf_user
	cmpil	&2,%d0			| TM 2 = user code
	beqw	Lwbf_user
| --- everything else is kernel-critical state that cannot simply be dropped: a supervisor store,
|     an MMU table-search write, a dirty-line push, or a reserved encoding nobody has seen.  The
|     audit's verdict on the first version's "stop, count, return success" was REJECT, because
|     stopping only meant "attempt no further slots" while the interrupted kernel operation still
|     returned success.  The safe pilot policy is resolve-or-fail-fast, and this implements the
|     fail-fast half: the resolve half needs an as_fault into the supervisor space from a landing
|     pad running on the trap-time stack, which is its own unit.
|     wbf_sup_fatal = 0 restores the old silent behaviour for one boot, for the same reason every
|     other switch in this file exists -- so a machine that panics here can still be booted. ---
	addql	&1,wbf_sup_n
	tstl	wbf_sup_fatal
	beqw	Lwbf_supquiet
	movel	%d2,%sp@-		| the outer u_nofault owner, if any
	movel	%a3,%sp@-		| replay pointer (the denied byte + 1)
	movel	%d3,%sp@-		| WBxS: slot status, TM and size
	movel	wbf_slot,%sp@-		| which write-back: 1, 2 or 3
	pea	Lwbs_msg
	pea	3			| CE_PANIC -- continuing would drop kernel state silently
	jsr	cmn_err
	lea	%sp@(24),%sp		| not reached; balanced in case CE_PANIC ever returns
Lwbf_supquiet:
	moveq	&2,%d0			| stop and count, no user signal
	braw	Lwbf_stop
Lwbf_user:
	addql	&1,wbf_user_n
	moveq	&1,%d0			| user: the wrapper turns this into a signal
Lwbf_stop:
	addql	&4,%sp			| drop Lwb_do's return address -- the replay ENDS here
	rts				| and returns to the wrapper with d0 set
Lwbf_swallow:
	addql	&1,wbf_swallow_n	| the old behaviour, kept only as the A/B control
	moveq	&0,%d0
	rts
| --- Q3: a landing this pad does not own.  The stack below us belongs to code we cannot name,
|     so the one thing not to do is modify it: no u_nofault write from a foreign d2, no addql,
|     no rts.  Fail fast and say what was seen.  No such landing has ever been observed -- the
|     finding is that nothing in the static code excluded one. ---
Lwbf_alien:
	addql	&1,wbf_alien_n
	movel	%d0,wbf_alien_sp	| the stack we were handed
	movel	wbf_own_sp,%sp@-	| the stack the armed replay is actually on
	movel	%d0,%sp@-
	pea	Lwba_msg
	pea	3			| CE_PANIC
	jsr	cmn_err
	lea	%sp@(16),%sp		| not reached; balanced in case CE_PANIC ever returns
	rts
	nop				| pad .text to a multiple of 4 to keep text/data contiguous
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lwbf_msg:
	.asciz	"DBG wb040 replay UNRESOLVED addr=%x wbs=%x"
	.balign	4
Lwbs_msg:
	.asciz	"wb040: KERNEL write-back WB%d unresolvable, wbs=%x addr=%x nofault=%x -- kernel state would be lost silently"
	.balign	4
Lwba_msg:
	.asciz	"wb040: u_nofault landing pad entered with a FOREIGN stack sp=%x (armed replay sp=%x)"
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
Lwbf_n:
	.long	0
	.balign 4
| --- ISSUE-42 (2026-08-12): write-back denial propagation.  Read wbf_magic FIRST; if it is not
|     "WBF!" every address below is stale and every value here means nothing.
|     On a 68060 all of these must stay 0: the replay runs only on a format-7 frame, which only a
|     68040 produces.  That frame check IS this unit's CPU gate -- there is no cputype test. ---
	.globl	wbf_magic
wbf_magic:
	.long	0x57424621		| "WBF!"
	.globl	wbf_prop_on
wbf_prop_on:
	.long	1			| 1 = propagate a denied write-back (the fix)
					| 0 = the pre-2026-08-12 swallow-and-continue, for an A/B
	.globl	wbf_sup_fatal
wbf_sup_fatal:
	.long	1			| 1 = a denied KERNEL write-back panics with diagnostics
					| 0 = the old silent skip.  The audit rejected returning
					| success there; this is the escape hatch, not the policy.
	.globl	wbf_own_cookie
wbf_own_cookie:
	.long	0			| "WBO!" while a replay owns the u_nofault landing pad
	.globl	wbf_own_sp
wbf_own_sp:
	.long	0			| the stack that replay is on -- the pad's identity check
	.globl	wbf_alien_n
wbf_alien_n:
	.long	0			| landings on the pad that did NOT belong to a replay.
					| Must stay 0.  Non-zero means an unrelated kernel fault
					| reached it, which is the hazard Q3 named and which no
					| measurement has yet shown.
	.globl	wbf_alien_sp
wbf_alien_sp:
	.long	0			| the foreign stack, for the panic message
	.globl	wbf_slot
wbf_slot:
	.long	0			| write-back being replayed: 1, 2 or 3
	.globl	wbf_fail_n
wbf_fail_n:
	.long	0			| write-backs that could not be completed at all
	.globl	wbf_user_n
wbf_user_n:
	.long	0			| ... of which carried a USER function code -> signalled
	.globl	wbf_sup_n
wbf_sup_n:
	.long	0			| ... a supervisor one -> replay stopped, no signal
	.globl	wbf_signal_n
wbf_signal_n:
	.long	0			| k_siginfo_t records built for a denied write-back
	.globl	wbf_nosig_n
wbf_nosig_n:
	.long	0			| ... of which had NO recorded class and fell back to
					| SIGBUS.  Non-zero means the attribution chain broke:
					| the denial did not come through our nested resolver.
	.globl	wbf_krn_n
wbf_krn_n:
	.long	0			| denials seen by the KERNEL wrapper (no signal ABI there)
	.globl	wbf_swallow_n
wbf_swallow_n:
	.long	0			| denials dropped because wbf_prop_on was 0.  In a shipping
					| boot this must be 0, or the fix is switched off.
	.globl	wbf_afb_n
wbf_afb_n:
	.long	0			| si_addr taken from the replay pointer because the CPU's
					| own fault address was not recorded.  That address is one
					| byte PAST the denial, so non-zero here means si_addr was
					| approximate and the attribution chain has a hole.
| --- sticky: written when a denial happens, never cleared ---
	.globl	wbf_addr
wbf_addr:
	.long	0			| replay pointer at the denial (= failing byte + 1)
	.globl	wbf_wbs
wbf_wbs:
	.long	0			| last denied WBxS (which write-back, its FC and size)
	.globl	wbf_fc
wbf_fc:
	.long	0			| last denied write-back's function code
	.globl	wbf_last_signo
wbf_last_signo:
	.long	0			| what was actually reported to the process, and
	.globl	wbf_last_code
wbf_last_code:
	.long	0			| ... its si_code, and
	.globl	wbf_last_addr
wbf_last_addr:
	.long	0			| ... its si_addr.  These three survive; the three below
					| do not, which cost one wrong prediction to learn.
| --- transient: inputs with a ONE-REPLAY lifetime, cleared at every wb040_replay entry ---
	.globl	wbf_signo
wbf_signo:
	.long	0			| signal number the nested resolution decided on
	.globl	wbf_code
wbf_code:
	.long	0			| its si_code
	.globl	wbf_fa
wbf_fa:
	.long	0			| the CPU's fault address for the denied byte (frame+84)
	.balign	4

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
| --- fault injection (Lwb_dfcinject): arm with kpoke or from dfcinject.c ---
	.globl	wb_dfc_force
wb_dfc_force:
	.long	0			| 0 = off; else the FC value to leave in DFC
	.globl	wb_dfc_force_n
wb_dfc_force_n:
	.long	0			| remaining budget, counts down (self-limiting)
	.globl	wb_dfc_forced
wb_dfc_forced:
	.long	0			| injections actually performed
	.globl	wb_sfc_changed
wb_sfc_changed:
	.long	0			| faults returning with an SFC the caller did not set
| --- 060 fault-path instrumentation (F1, 2026-08-05; docs/060-COUNTERS-UNIT-SPEC-260805.md) ---
| M68060-XPAGE-ACCEPTANCE.md is a STATIC pass whose runtime verdict is blocked on one thing:
| nothing counted format-4 frames, so a booting 060 proved the paths were SURVIVED, not
| EXERCISED.  These are pure instrumentation -- no control flow, no policy, no register use
| (addql/movel to absolute addresses only).  Every one of them sits inside a branch that only a
| fmt-4 frame reaches, so the 040 executes none of them.
	.globl	x60_fmt4_n
x60_fmt4_n:
	.long	0			| format-4 frames seen by the wrappers (user AND kernel)
	.globl	x60_ma_n
x60_ma_n:
	.long	0			| MA tier taken -- the architecture contract
	.globl	x60_compat_n
x60_compat_n:
	.long	0			| compat tier taken (MA clear, FA & 0xfff >= 0xff8)
	.globl	x60_rw_read_n
x60_rw_read_n:
	.long	0			| MA tier: far as_fault got S_READ
	.globl	x60_rw_write_n
x60_rw_write_n:
	.long	0			| MA tier: far as_fault got S_WRITE (write AND locked RMW)
	.globl	x60_far_fail_n
x60_far_fail_n:
	.long	0			| MA tier: far-page resolve failed and was PROPAGATED.
					| NOT incremented for the compat tier, which discards its
					| result by design -- counting that as a failure would
					| misreport the one thing this counter exists to catch.
	.globl	x60_last_fa
x60_last_fa:
	.long	0			| last faulting FA (frame+72), unmodified
	.globl	x60_last_fslw
x60_last_fslw:
	.long	0			| last FSLW, captured in sswsynth BEFORE it overwrites
					| bits 31-16 in place -- after that the only copy is d5
	.globl	x60_fprot_n
x60_fprot_n:
	.long	0			| F3: MA-tier crossing WRITE into a resident, write-
					| protected far page -> as_fault(F_PROT).  Zero on every
					| boot so far, which is exactly why the defect it fixes
					| stayed invisible until xpagetest T3 went looking.
	.globl	x60_fprot_ok_n
x60_fprot_ok_n:
	.long	0			| F_PROT resolved AND verified writable afterwards
					| (the legitimate COW case)
	.globl	x60_fprot_fail_n
x60_fprot_fail_n:
	.long	0			| F_PROT "succeeded" but the page is still protected ->
					| declared permanent.  This is the counter that turns a
					| live-lock into a diagnosable signal; if it moves, a
					| process died for a reason we can name.
	.globl	x60_last_afret
x60_last_afret:
	.long	0			| as_fault's own return value on the last F_PROT attempt
	.globl	x60_last_psr2
x60_last_psr2:
	.long	0			| the 030-form PSR from the VERIFY ptest.  0x800 here with
					| afret 0 is the whole finding in two numbers.
	.globl	x60_far_addr
x60_far_addr:
	.long	0			| F4: the rounded far page of the last MA-tier crossing.
					| This is what si_addr reports -- the frame's FA points at
					| the NEAR page, which is precisely the page that was fine.
	.globl	x60_siginfo_n
x60_siginfo_n:
	.long	0			| F4: far-page failures translated into a k_siginfo_t.
					| If this moves and the process still does not die, the
					| defect is downstream of us, not in the translation.
	.balign 4
