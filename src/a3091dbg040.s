| a3091dbg040.s -- capture the driver's state at the moment it shuts itself down.
|
| WHAT THIS IS FOR.  On 2026-08-25 the machine wedged after a burst run with one console
| line and nothing else:
|
|     a3091: 0x16 0 0x8112B84
|
| From the driver's own source (sys/amiga/alien/a3091.c, which IS in
| vanilla/amix-sources.tar and is not binary-only as this project long assumed) that
| decodes exactly: ss 0x16 is itab input 8, "request has completed"; istate 0 is IDLE;
| atab[IDLE][8] is action 1, "report that driver has shut down".  A completion interrupt
| arrived while the driver believed nothing was outstanding.  curunitp 0x8112B84 is
| &units[6], and SCSI ID 6 is this machine's root disk.
|
| The driver then never recovers: atab's DEAD row is all ones, so every later input maps
| back to DEAD, and startany() refuses to start anything unless the state is IDLE.  One
| line, then permanent silence, with every disk-backed operation queued forever.  See
| docs/A3091-WEDGE-PRESTUDY-260826.md.
|
| WHY THIS PRINTS RATHER THAN ONLY LATCHING.  Latching is the habit everywhere else in
| this port, and here it is nearly useless on its own: when the dying unit is the root
| disk the machine wedges, telnet never gets past accept(), and even a console login needs
| /bin/login and /etc/passwd off that same disk.  A latched block would be perfect and
| unreachable.  printf reaches the screen in that instant -- proven, since the stock line
| did -- and now the serial cable is attached, so it reaches a log too.  We do both: the
| latch costs nothing and pays off in the case where the dying unit is NOT the root disk
| and the machine stays up.
|
| WHY IT DOES NOT TOUCH THE DEVICE -- WITH ONE EXCEPTION ADDED 2026-08-27.  reg() would
| give the phase and status registers, and reading them stays deliberately omitted: this
| code runs at the moment of a hardware anomaly, in an interrupt handler, and reading SS is
| what ACKNOWLEDGES the interrupt.  An instrument that perturbs what it measures is worse
| than a smaller instrument.
|
| `istr` is the exception, and it is not a new kind of access: a3091intr's own first line is
| `unless ((device) and (device->istr & 1<<4)) return`, so the driver reads this register on
| every interrupt already.  Reading it here adds nothing the hardware does not see anyway.
|
| ENTRY istr ADDED 2026-08-27, and the reason is a mistake worth keeping visible.  The demux
| wrapper (src/a3091demux040.s) latches the entry snapshot in a3w_dead_istr precisely so the
| interrupt that kills the driver can be classified.  But this file's own header, above, explains
| why a latch is nearly useless here: when the dying unit is the root disk the machine wedges and
| nothing can read kernel memory afterwards.  That is exactly what happened on the first wedge
| after the wrapper landed -- a3w_dead_istr was written and unreachable.  So the entry snapshot is
| now printed beside the post-SS one, on the line that does reach the screen.
|
| It was added after the FOURTH occurrence, once the safe fields had been read four times and
| found to say the same thing every time -- three kernels, both directions, both transfer
| sizes, positions from 7300 to 168807 in the DMA sequence, with and without a preceding
| burst, and always head=0 dmaon=0 segstate=0 on units[6].  Every variable this port controls
| had been varied without effect, which is what makes touching the device worth the small
| risk rather than a guess made early.  The open question is whether istr bit 4 was genuinely
| set -- a real pending interrupt with a stale SS -- or whether the handler was entered
| without one.
|
| HOW IT IS REACHED.  NOT by weakening a symbol: `badhardware` is a file-LOCAL static and
| the image holds two of them -- one in a3091.c at 0xd666 and one in `service` at 0xcf46 --
| so a strong global override would capture both call sites and print A3091 state for the
| other driver's faults.  Instead src/patch_a3091_badhardware.py retargets the SINGLE
| relocation in a3091intr (0xd3a6) to this entry, exactly as patch_a3091_dma.py does for
| startdma/stopdma and for the same reason.  `service` is untouched.
|
| The three source-level `istate = badhardware(ss)` calls (a3091.c cases 1, 3 and 8) share
| one compiled tail at 0xd3a2, which is why one relocation covers all three.
|
| CONTRACT.  Entered with ss at %sp@(4), exactly as the stock body is.  Preserves every
| callee-saved register, leaves the stack as it found it, and tail-jumps to
| a3091_badhardware_orig -- so the stock line still prints, in its usual place, and DEAD
| is still what the caller receives.  Nothing about the driver's behaviour changes.

	.text
	.globl	a3091_badhardware_dbg
a3091_badhardware_dbg:
	link	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-

	addql	&1,a3d_n
	movel	&0x41334452,a3d_ran	| "A3DR" -- the BODY ran.  a3d_magic is static and
					| says only that the block is where it is said to
					| be; without that split an all-zero read cannot
					| tell "never fired" from "wrong address", and this
					| block is expected to read zero for its whole life.

| --- latch: the driver's own state, then ours ---
	movel	%fp@(8),%d2		| d2 = ss (kept for the prints below)
	movel	%d2,a3d_ss
	movel	a3091_istate,%d3
	movel	%d3,a3d_istate
	movel	a3091_curunitp,%d3
	movel	%d3,a3d_unit
	movel	a3091_starthead,%d3	| 0 = the start queue was EMPTY, which is what
	movel	%d3,a3d_head		| distinguishes "idle with no work" for certain
	clrl	%d3
	moveb	a3091_dma_on,%d3	| the driver's own flag: was a transfer armed?
	movel	%d3,a3d_dmaon
	clrl	%d3
	moveb	dma_seg_state,%d3	| OUR ownership state: 0 none, 1 preparing, 2 prepared
	movel	%d3,a3d_segstate
	movel	dma_seg_seq,a3d_segseq
	movel	dma_seg_pa,a3d_segpa
	movel	dma_seg_len,a3d_seglen
	clrl	%d3
	moveb	dma_seg_dir,%d3
	movel	%d3,a3d_segdir
	movel	dma_zero_arm,a3d_zarm
	movel	dma_reconn_arm,a3d_rarm
	movel	dma_prep_owned,a3d_owned	| must-stay-zero diagnostic
	movel	dma_cmpl_noprep,a3d_noprep	| must-stay-zero diagnostic
	movel	dma_range_ovf,a3d_ovf
	movel	dma_prep_whole,a3d_whole
| --- the device's own interrupt status.  NULL-guarded even though a3091intr has already
|     dereferenced `device` to get here: this runs on a machine that has just done something
|     unexplained, and a diagnostic that can itself fault is not a diagnostic. ---
	movel	a3091_device,%d3
	movel	%d3,a3d_devp
	beqs	Lad_noistr
	moveal	%d3,%a2
	clrl	%d3
	movew	%a2@(30),%d3		| device->istr -- offset 30, the same word the
	movel	%d3,a3d_istr		| handler's own entry test reads on every interrupt
Lad_noistr:

| --- ISSUE-54 classification (2026-08-29).  Gated to the three phase-mismatch statuses,
|     because it touches the device and every other status reaching this handler already has
|     four captures that say the same thing.  Specified by
|     docs/contracts/A3091-PHASE-MISMATCH-RESUME-AUDIT.md, which rejected the three-byte table
|     change this line proposed and asked for this measurement instead.
|
|     Reading here is safe in a way reading SS would not be: a3091intr has already done
|     `ss = reg(SS)` before it ever calls badhardware, so the interrupt is acknowledged and
|     these are status reads that acknowledge nothing further.  The file header's caution above
|     is about SS specifically and still stands.
| 0x41 was added to this gate on 2026-08-29 and it is a CAPTURE ONLY -- the status still falls
| through to the stock fail-stop, nothing about the driver's behaviour changes.  It is here to
| answer one question that the 68060-260829-09 capture could not: whose event the 0x41 after a
| release actually was.  This line read `unit=8113A44` as identity and concluded the root disk's
| command had terminated; docs/contracts/A3091-BUS-FREE-FOLLOWUP-AUDIT.md shows that startany()
| writes DI, the CDB, the DMA arm, curunitp and STARTING all BEFORE it writes the command, so
| every one of those fields describes the new target while its selection is still pending.  CP is
| the field that does not lie: it records how far a command actually got.
	cmpil	&0x41,%d2
	beqs	Lad_pm_in
	moveq	&0x48,%d3
	cmpl	%d3,%d2
	bcsw	Lad_nopm		| ss < 0x48
	moveq	&0x4a,%d3
	cmpl	%d3,%d2
	bhiw	Lad_nopm		| ss > 0x4a
Lad_pm_in:
	movel	&0x41335052,a3p_ran	| "A3PR" -- this body ran
	addql	&1,a3p_seen
	cmpil	&0x41,%d2
	bnes	Lad_pm_mis
	addql	&1,a3p_n41		| unexpected target bus free
	braw	Lad_pmdev
Lad_pm_mis:
	moveq	&0x48,%d3
	cmpl	%d3,%d2
	bnes	Lad_pm49
	addql	&1,a3p_n48		| DATA_OUT: never yet observed
	bras	Lad_pmdev
Lad_pm49:
	moveq	&0x49,%d3
	cmpl	%d3,%d2
	bnes	Lad_pm4a
	addql	&1,a3p_n49		| DATA_IN: the reproducible one
	bras	Lad_pmdev
Lad_pm4a:
	addql	&1,a3p_n4a		| CMD: never yet observed
Lad_pmdev:
	movel	a3091_device,%d3
	beqw	Lad_pmreq
	moveal	%d3,%a2
| reg(n), inlined: write the register number to scsi_a (+65), read it back from scsi_n (+67).
| Offsets confirmed against the driver's own reg() at .text+0xd5f2, not assumed from the struct.
| Deliberately NO cipwait: this runs in an interrupt handler on a machine that is already in
| trouble, and a spin loop waiting on hardware is how a diagnostic becomes the hang it was
| written to explain.  AS is latched instead, so the CIP bit gets reported rather than obeyed.
	moveb	&0x1f,%a2@(65)		| AS  -- auxiliary status: CIP, DBR, connected state
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_as
	moveb	&0x10,%a2@(65)		| CP  -- command phase: this is what selects the valid
	clrl	%d3			|        resume set, and it is the whole reason for
	moveb	%a2@(67),%d3		|        this capture existing
	movel	%d3,a3p_cp
	clrl	%d0			| TC -- three bytes, most significant first
	moveb	&0x12,%a2@(65)
	moveb	%a2@(67),%d0
	andil	&0xff,%d0
	lsll	&8,%d0
	moveb	&0x13,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	orl	%d3,%d0
	lsll	&8,%d0
	moveb	&0x14,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	orl	%d3,%d0
	movel	%d0,a3p_tc		| the SCSI-bus residual, as the chip sees it
	moveb	&0x15,%a2@(65)		| DI  -- destination ID; bit 6 (DPD) is the phase direction
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_di
	moveb	&0x01,%a2@(65)		| CON -- control: DMA mode and the disconnect interrupts
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_con
	clrl	%d3			| and the SDMAC's own side, straight from the struct
	movew	%a2@(10),%d3		| cntr
	movel	%d3,a3p_cntr
	movel	%a2@(12),a3p_sac	| sac -- the address the DMA engine has reached
Lad_pmreq:
	movel	a3091_curunitp,%d3
	beqs	Lad_pmv
	moveal	%d3,%a2
	movel	%a2@(4),%d3		| unit->comhead
	movel	%d3,a3p_req
	beqs	Lad_pmv
	moveal	%d3,%a2
	clrl	%d3
	moveb	%a2@(4),%d3		| sdcom->reading
	movel	%d3,a3p_rd
	clrl	%d3
	moveb	%a2@(7),%d3		| sdcom->cdb[0] -- the SCSI opcode
	movel	%d3,a3p_op
	movel	%a2@(20),a3p_addr	| sdcom->addr
	movel	%a2@(24),a3p_nbyte	| sdcom->nbyte -- what was asked for
Lad_pmv:
| Recurrence: the same request arriving here twice is the audit's no-progress case, and it is
| what any future resume has to be bounded by.  Counted now so the bound can be chosen from a
| measurement rather than from a guess.
	movel	a3p_req,%d0
	cmpl	a3p_prevreq,%d0
	bnes	Lad_pmnew
	addql	&1,a3p_retry
	bras	Lad_pmcls
Lad_pmnew:
	movel	%d0,a3p_prevreq
	clrl	a3p_retry
Lad_pmcls:
| Verdict, from the audit's interpretation table.  Computed here rather than on the host so the
| console line carries the answer even when the machine takes kernel memory with it.
|   1 resume candidate   2 no data left    3 command sequencing
|   4 direction disagreement                5 other command phase
|   6 0x41 with CP=0   -- NO new selection completed: the strong result for a late event
|                         belonging to the previous target's cleanup rather than to this request
|   7 0x41 with CP>=10 -- a new selection really did progress, so the event is this request's
| DI is captured beside CP but is NOT used here.  It is a host-programmed destination register,
| so it says who the driver MEANT to talk to, never who the event came from -- the same trap
| that produced the wrong reading of the 260829-09 capture.
	cmpil	&0x41,%d2
	bnes	Lad_pmmis2
	moveq	&6,%d1
	tstl	a3p_cp
	beqw	Lad_pmset
	moveq	&7,%d1
	braw	Lad_pmset
Lad_pmmis2:
	moveq	&4,%d1
	movel	a3p_rd,%d3
	beqs	Lad_pmrd0
	moveq	&1,%d3
Lad_pmrd0:
	movel	a3p_di,%d0
	andil	&0x40,%d0		| DPD
	beqs	Lad_pmdp0
	moveq	&1,%d0
Lad_pmdp0:
	cmpl	%d0,%d3
	bnew	Lad_pmset		| chip direction disagrees with the request
	movel	a3d_segdir,%d0
	cmpl	%d0,%d3
	bnew	Lad_pmset		| our own DMA ownership disagrees with the request
	movel	a3p_cp,%d0
	moveq	&0x41,%d3
	cmpl	%d3,%d0
	beqs	Lad_pmdata
	moveq	&0x45,%d3
	cmpl	%d3,%d0
	beqs	Lad_pmdata
	moveq	&0x46,%d3
	cmpl	%d3,%d0
	beqs	Lad_pmv2		| data count already complete
	moveq	&0x40,%d3
	cmpl	%d3,%d0
	bcss	Lad_pmv3		| below the data-phase range: command sequencing
	moveq	&5,%d1
	bras	Lad_pmset
Lad_pmdata:
	movel	a3p_tc,%d0
	beqs	Lad_pmv2		| phase permits data, but nothing is left to move
	moveq	&1,%d1
	bras	Lad_pmset
Lad_pmv2:
	moveq	&2,%d1
	bras	Lad_pmset
Lad_pmv3:
	moveq	&3,%d1
Lad_pmset:
	movel	%d1,a3p_verdict

	movel	a3p_as,%sp@-
	movel	a3p_con,%sp@-
	movel	a3p_di,%sp@-
	movel	a3p_tc,%sp@-
	movel	a3p_cp,%sp@-
	movel	%d2,%sp@-
	pea	La3p_m1
	jsr	printf
	lea	%sp@(28),%sp

	movel	a3p_nbyte,%sp@-
	movel	a3p_addr,%sp@-
	movel	a3p_rd,%sp@-
	movel	a3p_op,%sp@-
	movel	a3p_req,%sp@-
	pea	La3p_m2
	jsr	printf
	lea	%sp@(24),%sp

	movel	a3p_retry,%sp@-
	movel	a3p_verdict,%sp@-
	movel	a3p_cntr,%sp@-
	movel	a3p_sac,%sp@-
	pea	La3p_m3
	jsr	printf
	lea	%sp@(20),%sp
Lad_nopm:

| --- print.  Three bounded lines, not a dump: this runs in an interrupt handler on a
|     machine that is about to stop, and the output has to get out before it does. ---
	movel	a3d_dmaon,%sp@-
	movel	a3d_head,%sp@-
	movel	a3d_unit,%sp@-
	movel	a3d_istate,%sp@-
	movel	%d2,%sp@-
	pea	La3d_m1
	jsr	printf
	lea	%sp@(24),%sp

	movel	a3d_segdir,%sp@-
	movel	a3d_seglen,%sp@-
	movel	a3d_segpa,%sp@-
	movel	a3d_segseq,%sp@-
	movel	a3d_segstate,%sp@-
	pea	La3d_m2
	jsr	printf
	lea	%sp@(24),%sp

	movel	a3w_last_istr,%sp@-	| the ENTRY snapshot, from the demux wrapper: the ISTR
					| as it was BEFORE a3091intr read SS.  a3d_istr below
					| is read after that, so it can only show what survived
					| the acknowledgement -- which is why the two are
					| printed side by side rather than one of them.
	movel	a3d_istr,%sp@-
	movel	a3d_devp,%sp@-
	pea	La3d_m4
	jsr	printf
	lea	%sp@(16),%sp

	movel	a3d_whole,%sp@-
	movel	a3d_ovf,%sp@-
	movel	a3d_noprep,%sp@-
	movel	a3d_owned,%sp@-
	movel	a3d_rarm,%sp@-
	movel	a3d_zarm,%sp@-
	pea	La3d_m3
	jsr	printf
	lea	%sp@(28),%sp

| ============================================================================================
| ISSUE-54 FIX: release the bus and fail the request, for ONE measured tuple only.
|
| Specified by docs/contracts/A3091-BUS-RELEASE-CONTRACT.md.  Root cause: SCSI target 3 is a
| CD-ROM (2048-byte blocks) against a driver whose LBA arithmetic is in 512-byte units.  There
| is no correct data to deliver -- the driver addresses the wrong place, not merely the wrong
| length -- so the request must FAIL, and the bus, which the WD still holds as an initiator,
| must be released.  This does not add block-size support: the CD and the tape stay unusable.
| They stop taking the root disk down with them.
|
| WHY THE TUPLE IS SO NARROW.  Everything below is valid only for the state that was actually
| measured on 68060-260829-07: ss=0x49, cp=0x46, tc=0, a data-in request, and an Auxiliary
| Status with INT/LCI/BSY/CIP/DBR all clear.  Any other combination -- including 0x48 DATA_OUT
| and 0x4A CMD, which have never been observed -- falls through to the stock fail-stop.  Those
| need their own FIFO and DMA contracts and do not share this one.
|
| WHY NOT ABORT.  This line's first reading of NetBSD's sbicabort() said Abort then Disconnect.
| That is a driver-wide unknown-state recovery entry and it is wrong here twice over: with AS=0
| nothing is jammed and the Level II command has already ended, so Abort has nothing to do; and
| Abort carries a direction-sensitive FIFO contract that requires servicing WD data requests
| until its interrupt -- on an initiator receive, which is exactly this path.  Disconnect alone
| is the release, and it raises no completion interrupt.  See
| docs/ISSUE54-BUS-RELEASE-MY-READING-260829.md for that mistake scored in full.
|
| WHY IDLE IS PUBLISHED LAST.  itab[0x85] is input 3, atab[IDLE][3] is action 1 -- badhardware.
| Ending at `istate = IDLE; startany()` before the bus event is consumed is fatal on an empty
| queue and, worse, on a non-empty one attributes the old target's disconnect to a newly started
| request and stops ITS dma.  So the release completes first, then ownership changes.
| ============================================================================================
	cmpil	&0x49,%d2
	bnew	Lad_stock
	cmpil	&0x46,a3p_cp
	bnew	Lad_stock
	tstl	a3p_tc
	bnew	Lad_stock
	tstl	a3p_rd			| DATA_IN only
	beqw	Lad_stock
	tstl	a3p_req
	beqw	Lad_stock
	movel	a3p_as,%d3
	andil	&0xf1,%d3		| INT|LCI|BSY|CIP|DBR must all be clear
	bnew	Lad_stock
	addql	&1,a3p_rel_try
	moveq	&16,%d2			| the post-command budget; ss is no longer needed
					| (the stock body reads its own argument off the
					| stack, so the fail-closed path stays correct)

| 2. Quiesce the SDMAC through OUR cache-aware wrapper.  The captured cursor was 16 bytes short
|    of the segment end because that much was still in the SDMAC FIFO; this flushes it and
|    completes the FROM_DEVICE ownership contract before any callback can look at the buffer.
|    Its inherited stock body still contains an unbounded SDMAC wait -- recorded as a separate
|    residual risk, not closed here.
	jsr	dma_a3091_stopdma

| 3. The manufacturer's command guard: at least 7 us between the acknowledged SS read and the
|    COM write.  delayus() waits on raster transitions, so its floor does not shrink when the
|    CPU changes from 040 to 060 -- which drv_usecwait's instruction loop would.
	pea	8
	jsr	delayus
	addql	&4,%sp

	movel	a3091_device,%d3
	beqw	Lad_relfail
	moveal	%d3,%a2

| 4. Re-read AS.  The target can disconnect during the delay above, so the classified state has
|    to be re-established rather than assumed.
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_rel_as
	btst	&7,%d3			| INT pending?
	bnes	Lad_rel_int
	movel	%d3,%d0
	andil	&0x71,%d0		| LCI|BSY|CIP|DBR without a bus-free status
	bnew	Lad_relfail
	braw	Lad_rel_cmd
Lad_rel_int:
| SS is read ONLY because AS.INT says a new interrupt is pending.  Read at any other time it is
| stale status from a previous event.
	moveb	&0x17,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_rel_ss
	cmpil	&0x41,%d3		| unexpected bus free ended the command
	beqw	Lad_rel_raced
	cmpil	&0x85,%d3		| disconnect service event
	beqw	Lad_rel_raced
	braw	Lad_relfail		| any other status is outside this path

| 5. ADDRESS THE TARGET.  A WD Disconnect drops the initiator's own signals and tells the target
|    nothing, which 68060-260829-11 measured directly: after a release that passed every
|    chip-level acceptance test, the very next selection reached CP=0x3A -- target 6 had accepted
|    CDB bytes -- and then the bus went free under it.  So the release must be a SCSI operation
|    addressed to the target, not a chip operation addressed to ourselves.
|
|    SET_ATN (0x02) then CLR_ACK (0x03) so the target can change phase, wait for a Message Out
|    phase status, then one PIO byte: SCSI ABORT, 0x06.  The primitives are proven in this
|    driver already -- action 8 issues a single-byte transfer the same way, only inbound.
|
|    Everything here is bounded and fails closed.  A Message Reject, a wrong phase, an ignored
|    command or a timeout is a fail-stop, not a success: the contract is explicit that this path
|    must not pretend.  That deliberately gives up the partial behaviour of -09 on the failure
|    branch, where dd at least got an error before the machine died.  It costs nothing real --
|    that branch wedged one command later anyway -- and pretending is the more expensive habit.
Lad_rel_cmd:
	addql	&1,a3p_atn_try
	moveq	&2,%d0
	movel	%d0,a3p_atn_stage	| 2 = about to SET_ATN
	moveb	&0x18,%a2@(65)		| COM
	moveb	&0x02,%a2@(67)		| SET_ATN, Level I, valid while connected
	pea	8
	jsr	delayus
	addql	&4,%sp
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_atn_as
	btst	&6,%d3			| LCI: the ATN write lost a race and was ignored
	beqs	Lad_atn_ack
	addql	&1,a3p_atn_lci
	braw	Lad_relfail
Lad_atn_ack:
	moveq	&4,%d0
	movel	%d0,a3p_atn_stage	| 4 = ATN taken, about to CLR_ACK
	moveb	&0x18,%a2@(65)
	moveb	&0x03,%a2@(67)		| CLR_ACK -- release ACK so the target may change phase

| 6a. Bounded wait for the target to ask for Message Out.  Accept the transferred and mismatch
|     variants, which are the low three bits reading 6.  A bus-free status here means the target
|     let go on its own before we could speak, which is the outcome we wanted anyway.
	moveq	&16,%d2
Lad_atn_wait:
	pea	8
	jsr	delayus
	addql	&4,%sp
	addql	&1,a3p_atn_polls
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_atn_as
	btst	&7,%d3			| INT: a status is pending
	beqs	Lad_atn_next
	moveb	&0x17,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_atn_ss
	moveq	&5,%d0
	movel	%d0,a3p_atn_stage	| 5 = classifying a status in the wait
	cmpil	&0x41,%d3
	beqw	Lad_atn_free		| target already went bus free
	cmpil	&0x85,%d3
	beqw	Lad_atn_free
	movel	%d3,%d0
	andil	&0x07,%d0
	cmpil	&0x06,%d0		| MESSAGE OUT phase?
	beqs	Lad_atn_ph_ok
	cmpil	&0x89,%d3		| the measured DATA IN answer -> Stage P probe
	beqw	Lad_p_probe
	braw	Lad_relfail
Lad_atn_ph_ok:
	movel	%d3,%d0
	andil	&0xf8,%d0		| and one of XFERRED/MIS/MIS_1/MIS_2
	cmpil	&0x18,%d0
	beqs	Lad_atn_mout
	cmpil	&0x28,%d0
	beqs	Lad_atn_mout
	cmpil	&0x48,%d0
	beqs	Lad_atn_mout
	cmpil	&0x88,%d0
	beqs	Lad_atn_mout
	braw	Lad_relfail
Lad_atn_next:
	subql	&1,%d2
	bnew	Lad_atn_wait
	braw	Lad_relexp

| 6b. Send one byte.  Direction to SCSI (clear DPD in DI), transfer count 1, XFER_INFO, then the
|     byte into DR when DBR says the buffer wants it.  NetBSD sends message bytes exactly this
|     way, one at a time, because sending them in one go locks the chip against some targets.
Lad_atn_mout:
	addql	&1,a3p_atn_mout
	moveq	&6,%d0
	movel	%d0,a3p_atn_stage	| 6 = target asked for MESSAGE OUT
	moveb	&0x15,%a2@(65)		| DI
	clrl	%d3
	moveb	%a2@(67),%d3
	andil	&0xbf,%d3		| clear DPD: transfer runs TO the bus
	moveb	&0x15,%a2@(65)
	moveb	%d3,%a2@(67)
	moveb	&0x12,%a2@(65)		| TC = 1
	clrb	%a2@(67)
	moveb	&0x13,%a2@(65)
	clrb	%a2@(67)
	moveb	&0x14,%a2@(65)
	moveb	&1,%a2@(67)
	moveb	&0x18,%a2@(65)
	moveb	&0x20,%a2@(67)		| XFER_INFO
	moveq	&16,%d2
	moveq	&7,%d0
	movel	%d0,a3p_atn_stage	| 7 = XFER_INFO issued, waiting for DBR
Lad_atn_dbr:
	pea	8
	jsr	delayus
	addql	&4,%sp
	addql	&1,a3p_atn_polls
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_atn_as
	btst	&0,%d3			| DBR: the buffer is ready for our byte
	bnes	Lad_atn_put
	btst	&7,%d3			| an interrupt instead means the phase changed
	bnew	Lad_relfail
	subql	&1,%d2
	bnew	Lad_atn_dbr
	braw	Lad_relexp
Lad_atn_put:
	moveq	&8,%d0
	movel	%d0,a3p_atn_stage	| 8 = data buffer ready, byte going out
	moveb	&0x19,%a2@(65)		| DR
	moveb	&0x06,%a2@(67)		| SCSI ABORT
	addql	&1,a3p_atn_sent

| 6c. The target must go BUS FREE after recognising ABORT.  That is the only proof accepted here,
|     and it is a SCSI-level fact rather than the chip-level acceptance that -09 mistook for one.
	moveq	&9,%d0
	movel	%d0,a3p_atn_stage	| 9 = ABORT sent, waiting for bus free
	moveq	&16,%d2

Lad_rel_poll:
	pea	8
	jsr	delayus
	addql	&4,%sp
	addql	&1,a3p_rel_polls
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_rel_as
	btst	&7,%d3			| INT -- a status is pending, classify it
	bnes	Lad_rel_pint
	btst	&6,%d3			| LCI: the command was ignored
	bnew	Lad_relfail
	braw	Lad_rel_next
| THE CHIP-ACCEPTANCE SHORTCUT USED TO BE HERE AND IT WAS WRONG.  Until 68060-260829-11 this
| loop also accepted "CIP clear, BSY and DBR clear" as success.  That is the WD reporting on its
| own command register; it says nothing about whether a target is still driving the cable, and
| the -11 capture showed the next selection reaching CP=0x3A before the bus went free under it.
| The only proof accepted now is a SCSI bus-free status.
Lad_rel_pint:
	moveb	&0x17,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_rel_ss
	cmpil	&0x41,%d3
	beqw	Lad_rel_ok
	cmpil	&0x85,%d3
	beqw	Lad_rel_ok
	braw	Lad_relfail		| 0x40 invalid-command included: not success
Lad_rel_next:
	subql	&1,%d2
	bnew	Lad_rel_poll
	braw	Lad_relexp

| ============================================================================================
| STAGE P -- prove ONE discarded PIO byte, then quarantine.  No recovery is attempted here.
|
| docs/contracts/A3091-DATA-IN-DRAIN-DESIGN.md.  Three designs have now been implemented to
| specification and failed on hardware for reasons the specification did not anticipate, so the
| fourth proves its primitive before it is built on.  A failed experiment costs one controlled
| boot instead of another damaged command.
|
| WHY NOT XFER_PAD.  `sbicreg.h` defines 0x19 and no NetBSD driver calls it, which is how this
| line first argued against it.  Western Digital's own compatibility notes are stronger: Transfer
| Pad was REMOVED from the A revision, along with the initiator-mode Abort command.  A header
| constant without a call site is not a hardware contract -- sbicreg.h describes the family, not
| this part.
|
| Entered only for SS=0x89 (MIS_2|DATA_IN) after ATN was asserted and accepted, with CP=0x46, the
| request already failed and the SDMAC already stopped.  Everything after the capture falls into
| the same fail-closed path as before, which IS the quarantine: badhardware returns DEAD, DEAD's
| row is all action 1, and no further command can start.
| ============================================================================================
Lad_p_probe:
	addql	&1,a3p_p_try
	movel	%a2@(12),a3p_p_sac0	| SDMAC cursor BEFORE: PIO must not move it
	moveb	&0x01,%a2@(65)		| CON -> PIO: EDI|IDI, DMA-mode bit cleared
	moveb	&0x0c,%a2@(67)
| Direction stays SCSI-to-host for DATA IN, so DI is deliberately not touched.
| Transfer Count is loaded explicitly, which is mandatory on the A revision: unlike the original
| part it does not preserve the previous count across a single-byte transfer.
	moveb	&0x12,%a2@(65)
	clrb	%a2@(67)
	moveb	&0x13,%a2@(65)
	clrb	%a2@(67)
	moveb	&0x14,%a2@(65)
	moveb	&1,%a2@(67)
	pea	8			| the 7 us guard, after the SS read above
	jsr	delayus
	addql	&4,%sp
	moveb	&0x18,%a2@(65)
	moveb	&0x20,%a2@(67)		| TRANSFER INFO, plain PIO, not the SBT variant
	moveq	&16,%d2
Lad_p_wait:
	pea	8
	jsr	delayus
	addql	&4,%sp
	addql	&1,a3p_p_polls
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_as
	btst	&0,%d3			| DBR -- a byte is waiting for us
	bnes	Lad_p_byte
	btst	&7,%d3			| INT instead -- a phase change ended it
	bnes	Lad_p_int
	subql	&1,%d2
	bnew	Lad_p_wait
	bras	Lad_p_capture		| neither: capture what we have and quarantine
Lad_p_byte:
	moveb	&0x19,%a2@(65)		| DR
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_byte		| the discarded byte, kept only as evidence
	addql	&1,a3p_p_got
	bras	Lad_p_capture
Lad_p_int:
	moveb	&0x17,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_ss
Lad_p_capture:
| BSY GATES FOUR OF THESE READS, which cost the first Stage P run its headline number.  sbicreg.h
| says it in one line -- "Busy, only cmd/data/asr readable" -- and 68060-260830-02 printed
| tc=FFFFFF cp=FF di=FF con=FF beside an as=0x21 that had BSY set.  The bit that invalidated
| those four numbers was printed next to them and not looked at.  DR and AS are readable
| throughout, so the byte and the status were never at risk; only the gated four were.
	moveq	&16,%d2
Lad_p_bsy:
	moveb	&0x1f,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_as2		| the AS the gated reads were actually taken under
	btst	&5,%d3			| BSY
	beqs	Lad_p_rdy
	pea	8
	jsr	delayus
	addql	&4,%sp
	addql	&1,a3p_p_bsyw
	subql	&1,%d2
	bnew	Lad_p_bsy
Lad_p_rdy:
	clrl	%d0			| TC after: must read exactly one less
	moveb	&0x12,%a2@(65)
	moveb	%a2@(67),%d0
	andil	&0xff,%d0
	lsll	&8,%d0
	moveb	&0x13,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	orl	%d3,%d0
	lsll	&8,%d0
	moveb	&0x14,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	orl	%d3,%d0
	movel	%d0,a3p_p_tc
	moveb	&0x10,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_cp
	moveb	&0x15,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_di
	moveb	&0x01,%a2@(65)
	clrl	%d3
	moveb	%a2@(67),%d3
	movel	%d3,a3p_p_con
	movel	%a2@(12),a3p_p_sac	| SDMAC cursor AFTER
	clrl	%d3
	movew	%a2@(10),%d3
	movel	%d3,a3p_p_cntr
	clrl	%d3
	movew	%a2@(30),%d3
	movel	%d3,a3p_p_istr
	clrl	%d3
	moveb	a3091_dma_on,%d3
	movel	%d3,a3p_p_dmaon

	movel	a3p_p_polls,%sp@-
	movel	a3p_p_byte,%sp@-
	movel	a3p_p_ss,%sp@-
	movel	a3p_p_as,%sp@-
	movel	a3p_p_tc,%sp@-
	movel	a3p_p_got,%sp@-
	pea	La3p_p1
	jsr	printf
	lea	%sp@(28),%sp
	movel	a3p_p_dmaon,%sp@-
	movel	a3p_p_istr,%sp@-
	movel	a3p_p_cntr,%sp@-
	movel	a3p_p_sac,%sp@-
	movel	a3p_p_sac0,%sp@-
	pea	La3p_p2
	jsr	printf
	lea	%sp@(24),%sp
	movel	a3p_p_bsyw,%sp@-
	movel	a3p_p_as2,%sp@-
	movel	a3p_p_con,%sp@-
	movel	a3p_p_di,%sp@-
	movel	a3p_p_cp,%sp@-
	pea	La3p_p3
	jsr	printf
	lea	%sp@(24),%sp
	braw	Lad_relfail		| quarantine: DEAD, and DEAD starts nothing

Lad_atn_free:
	addql	&1,a3p_atn_free	| the target let go before we could speak: the
				| outcome we wanted, reached without the message
Lad_rel_raced:
	addql	&1,a3p_rel_raced	| the target freed the bus before we asked
	bras	Lad_rel_hwm
Lad_rel_ok:
	addql	&1,a3p_rel_ok
Lad_rel_hwm:
	moveq	&16,%d0
	subl	%d2,%d0			| polls actually used
	cmpl	a3p_rel_maxpoll,%d0
	bles	Lad_rel_comp
	movel	%d0,a3p_rel_maxpoll

| 7. Hardware release is established.  Only now does request ownership change.  cp->okay is
|    already FALSE -- a3091queue() clears it on every request and nothing here sets it -- so
|    completing without touching it IS the failure report.
Lad_rel_comp:
	movel	a3091_curunitp,%d3
	beqw	Lad_relfail
	moveal	%d3,%a2
	movel	%a2@(4),%d3		| unit->comhead
	beqw	Lad_relfail
	movel	%d3,a3p_rel_req
	moveal	%d3,%a0
	movel	%a0@,%d0		| cp->next
	movel	%d0,%a2@(4)
	beqs	Lad_rel_noq
	movel	%a2,%sp@-
	jsr	a3091_uqueue
	addql	&4,%sp
Lad_rel_noq:
	movel	a3p_rel_req,%d3
	moveal	%d3,%a0
	moveal	%a0@(36),%a1		| cp->intr
	movel	%d3,%sp@-
	jsr	%a1@
	addql	&4,%sp
	clrl	a3091_istate		| IDLE published only here
	jsr	a3091_startany

	movel	a3p_rel_polls,%sp@-
	movel	a3p_rel_ss,%sp@-
	movel	a3p_rel_as,%sp@-
	movel	a3p_rel_req,%sp@-
	pea	La3p_r1
	jsr	printf
	lea	%sp@(20),%sp

	movel	a3091_istate,%d0	| return whatever startany() left, so the caller's
					| `istate = badhardware(ss)` writes it back unchanged
					| instead of stamping IDLE over a fresh STARTING
	moveml	%sp@+,%d2-%d3/%a2
	unlk	%fp
	rts

| Fail-closed and expiry both end at the stock body, which prints its own line and returns DEAD.
| The request is left marked failed and its callback is NOT invoked, IDLE is not published, and
| startany() is not called -- an obvious wedge beats silent I/O misassociation.
| The failure print used to carry only the a3p_rel_* fields, because it was written before the
| ATN path existed and was not extended with it.  68060-260829-13 paid for that: the run failed,
| printed `RELEASE-FAILED try=1 as=0 ss=0 polls=0`, and nothing in that line could say whether
| SET_ATN was ignored, a wrong phase arrived, or the bounded wait ran out.  The counters would
| have said, and the wedge takes them with it -- which is the exact reason this file prints.
| a3p_atn_stage records how far the path got, so one line answers it.
Lad_relexp:
	addql	&1,a3p_rel_exp
	movel	a3p_atn_polls,%sp@-
	movel	a3p_atn_ss,%sp@-
	movel	a3p_atn_as,%sp@-
	movel	a3p_atn_stage,%sp@-
	pea	La3p_r3
	jsr	printf
	lea	%sp@(20),%sp
	bras	Lad_relprt
Lad_relfail:
	addql	&1,a3p_rel_fail
	movel	a3p_atn_polls,%sp@-
	movel	a3p_atn_ss,%sp@-
	movel	a3p_atn_as,%sp@-
	movel	a3p_atn_stage,%sp@-
	pea	La3p_r4
	jsr	printf
	lea	%sp@(20),%sp
Lad_relprt:
	movel	a3p_rel_polls,%sp@-
	movel	a3p_rel_ss,%sp@-
	movel	a3p_rel_as,%sp@-
	movel	a3p_rel_try,%sp@-
	pea	La3p_r2
	jsr	printf
	lea	%sp@(20),%sp

Lad_stock:
	moveml	%sp@+,%d2-%d3/%a2
	unlk	%fp
	jmp	a3091_badhardware_orig	| stock body: prints its own line, returns DEAD
	.balign	4

	.data
	.even
La3d_m1:
	.asciz	"a3091dbg ss=%x istate=%d unit=%x head=%x dmaon=%d\n"
	.even
La3d_m2:
	.asciz	"a3091dbg segstate=%d segseq=%d segpa=%x seglen=%x segdir=%d\n"
	.even
La3d_m3:
	.asciz	"a3091dbg zarm=%d rarm=%d owned=%d noprep=%d ovf=%d whole=%d\n"
	.even
La3d_m4:
	.asciz	"a3091dbg dev=%x istr=%x entry=%x\n"
	.even
La3p_m1:
	.asciz	"a3p ss=%x cp=%x tc=%x di=%x con=%x as=%x\n"
	.even
La3p_m2:
	.asciz	"a3p req=%x op=%x rd=%d addr=%x len=%x\n"
	.even
La3p_m3:
	.asciz	"a3p sac=%x cntr=%x verdict=%d retry=%d\n"
	.even
La3p_r1:
	.asciz	"a3p RELEASED req=%x as=%x ss=%x polls=%d\n"
	.even
La3p_r2:
	.asciz	"a3p RELEASE-FAILED try=%d as=%x ss=%x polls=%d\n"
	.even
La3p_r3:
	.asciz	"a3p ATN-EXPIRED stage=%d as=%x ss=%x polls=%d\n"
	.even
La3p_r4:
	.asciz	"a3p ATN-FAILED stage=%d as=%x ss=%x polls=%d\n"
	.even
La3p_p1:
	.asciz	"a3p P got=%d tc=%x as=%x ss=%x byte=%x polls=%d\n"
	.even
La3p_p2:
	.asciz	"a3p P sac0=%x sac=%x cntr=%x istr=%x dmaon=%d\n"
	.even
La3p_p3:
	.asciz	"a3p P cp=%x di=%x con=%x as2=%x bsyw=%d\n"
	.even
	.balign	4			| the .asciz blocks above are only .even, so without this
					| the counter block can land 2 mod 4 -- it did, the moment
					| La3d_m4 was added (2026-08-27).  Longword counters at an
					| odd-word address still work on an 040/060, but every tool
					| that computes offsets into this block deserves better than
					| accidental alignment.
| --- counters, in reading order.  Magic first, as everywhere in this port. ---
	.globl	a3d_magic
a3d_magic:
	.long	0x41334421		| "A3D!" -- STATIC: proves the address, always readable
	.globl	a3d_ran
a3d_ran:
	.long	0			| "A3DR" once the body has run; 0 = it never has
	.globl	a3d_n
a3d_n:
	.long	0			| times the driver shut itself down this uptime
	.globl	a3d_ss
a3d_ss:
	.long	0
	.globl	a3d_istate
a3d_istate:
	.long	0
	.globl	a3d_unit
a3d_unit:
	.long	0
	.globl	a3d_head
a3d_head:
	.long	0
	.globl	a3d_dmaon
a3d_dmaon:
	.long	0
	.globl	a3d_segstate
a3d_segstate:
	.long	0
	.globl	a3d_segseq
a3d_segseq:
	.long	0
	.globl	a3d_segpa
a3d_segpa:
	.long	0
	.globl	a3d_seglen
a3d_seglen:
	.long	0
	.globl	a3d_segdir
a3d_segdir:
	.long	0
	.globl	a3d_zarm
a3d_zarm:
	.long	0
	.globl	a3d_rarm
a3d_rarm:
	.long	0
	.globl	a3d_owned
a3d_owned:
	.long	0
	.globl	a3d_noprep
a3d_noprep:
	.long	0
	.globl	a3d_ovf
a3d_ovf:
	.long	0
	.globl	a3d_whole
a3d_whole:
	.long	0
| --- appended 2026-08-27, at the END so every address already published for this block
|     keeps its offset.  Same reasoning as the LC060 merge's fpc_*_nofpu_n. ---
	.globl	a3d_devp
a3d_devp:
	.long	0			| the driver's `device` pointer, 0 if it was NULL
	.globl	a3d_istr
a3d_istr:
	.long	0			| device->istr at death; bit 4 is the handler's own gate
	.balign	4

	.balign	4
| --- ISSUE-54 classification block.  Magic first, as everywhere in this port.  This block is
|     expected to read all zeros for its whole life on a healthy machine, which is exactly why
|     it needs a magic: an all-zero read from a wrong address is indistinguishable from an
|     all-zero read from the right one.
	.globl	a3p_magic
a3p_magic:
	.long	0x41335021		| "A3P!" -- STATIC: proves the address
	.globl	a3p_ran
a3p_ran:
	.long	0		| "A3PR" once the classification body has run
	.globl	a3p_seen
a3p_seen:
	.long	0		| every 0x48/0x49/0x4a arrival: the denominator
	.globl	a3p_n48
a3p_n48:
	.long	0		| MIS_1|DATA_OUT -- never yet observed
	.globl	a3p_n49
a3p_n49:
	.long	0		| MIS_1|DATA_IN  -- the reproducible one
	.globl	a3p_n4a
a3p_n4a:
	.long	0		| MIS_1|CMD      -- never yet observed
	.globl	a3p_n41
a3p_n41:
	.long	0		| 0x41 unexpected target bus free -- capture only
	.globl	a3p_cp
a3p_cp:
	.long	0		| WD command phase: selects the valid resume set
	.globl	a3p_tc
a3p_tc:
	.long	0		| WD transfer count, 24 bits: the SCSI-bus residual
	.globl	a3p_di
a3p_di:
	.long	0		| WD destination ID; bit 6 DPD = phase direction
	.globl	a3p_con
a3p_con:
	.long	0		| WD control: DMA mode, disconnect interrupts
	.globl	a3p_as
a3p_as:
	.long	0		| WD auxiliary status; reported, never waited on
	.globl	a3p_req
a3p_req:
	.long	0		| curunitp->comhead: the request identity
	.globl	a3p_op
a3p_op:
	.long	0		| cdb[0], the SCSI opcode
	.globl	a3p_rd
a3p_rd:
	.long	0		| sdcom->reading
	.globl	a3p_addr
a3p_addr:
	.long	0		| sdcom->addr
	.globl	a3p_nbyte
a3p_nbyte:
	.long	0		| sdcom->nbyte: what was asked for
	.globl	a3p_sac
a3p_sac:
	.long	0		| SDMAC DMA address -- the host-side cursor
	.globl	a3p_cntr
a3p_cntr:
	.long	0		| SDMAC control
	.globl	a3p_prevreq
a3p_prevreq:
	.long	0		| previous request, for recurrence detection
	.globl	a3p_retry
a3p_retry:
	.long	0		| same request seen again: the no-progress case
	.globl	a3p_verdict
a3p_verdict:
	.long	0		| 1 resume 2 no-data 3 cmd-seq 4 direction 5 other
	.balign	4
| --- ISSUE-54 release path.  a3p_rel_try = ok + raced + fail + exp, and that identity is
|     what makes these readable: a try that matched no outcome means the block moved.
	.globl	a3p_rel_try
a3p_rel_try:
	.long	0		| times the release path was entered: the denominator
	.globl	a3p_rel_ok
a3p_rel_ok:
	.long	0		| Disconnect issued and accepted
	.globl	a3p_rel_raced
a3p_rel_raced:
	.long	0		| target had already freed the bus; no command issued
	.globl	a3p_rel_fail
a3p_rel_fail:
	.long	0		| fail-closed: preconditions gone, stock body took over
	.globl	a3p_rel_exp
a3p_rel_exp:
	.long	0		| bounded wait expired -- MUST STAY 0 on healthy hardware
	.globl	a3p_rel_polls
a3p_rel_polls:
	.long	0		| total post-command polls across all releases
	.globl	a3p_rel_maxpoll
a3p_rel_maxpoll:
	.long	0		| high-water polls for one release
	.globl	a3p_rel_as
a3p_rel_as:
	.long	0		| last Auxiliary Status read on the release path
	.globl	a3p_rel_ss
a3p_rel_ss:
	.long	0		| last SCSI Status read, and only when AS.INT said one was pending
	.globl	a3p_rel_req
a3p_rel_req:
	.long	0		| the request that was failed
	.balign	4
| --- ISSUE-54 ATN/Message-Out path.  a3p_atn_try = mout + free + lci + (fail/exp remainder),
|     and a3p_atn_sent <= a3p_atn_mout always.
	.globl	a3p_atn_try
a3p_atn_try:
	.long	0		| ATN path entered: the denominator for everything below
	.globl	a3p_atn_lci
a3p_atn_lci:
	.long	0		| SET_ATN was ignored (LCI) -- fail-closed
	.globl	a3p_atn_mout
a3p_atn_mout:
	.long	0		| the target asked for MESSAGE OUT
	.globl	a3p_atn_sent
a3p_atn_sent:
	.long	0		| the ABORT byte was written to the data register
	.globl	a3p_atn_free
a3p_atn_free:
	.long	0		| target went bus free before we could send -- also success
	.globl	a3p_atn_polls
a3p_atn_polls:
	.long	0		| poll iterations across the whole ATN path
	.globl	a3p_atn_as
a3p_atn_as:
	.long	0		| last Auxiliary Status seen on the ATN path
	.globl	a3p_atn_stage
a3p_atn_stage:
	.long	0		| 2 SET_ATN 4 CLR_ACK 5 classify 6 MESG_OUT 7 DBR 8 sent 9 busfree
	.globl	a3p_atn_ss
a3p_atn_ss:
	.long	0		| last SCSI Status, read only when AS.INT allowed it
	.balign	4
| --- Stage P.  a3p_p_got == 1 and a3p_p_sac == a3p_p_sac0 are the two that decide it.
	.globl	a3p_p_try
a3p_p_try:
	.long	0		| Stage P entered: SS=0x89 after an accepted ATN
	.globl	a3p_p_got
a3p_p_got:
	.long	0		| bytes actually taken from DR -- must be exactly 1
	.globl	a3p_p_polls
a3p_p_polls:
	.long	0		| poll iterations inside Stage P
	.globl	a3p_p_byte
a3p_p_byte:
	.long	0		| the discarded byte, evidence only
	.globl	a3p_p_as
a3p_p_as:
	.long	0		| Auxiliary Status at the decisive poll
	.globl	a3p_p_ss
a3p_p_ss:
	.long	0		| SCSI Status, only if INT ended the transfer instead of DBR
	.globl	a3p_p_tc
a3p_p_tc:
	.long	0		| Transfer Count after -- must have gone 1 -> 0
	.globl	a3p_p_as2
a3p_p_as2:
	.long	0		| AS the gated reads were taken under; BSY must be clear
	.globl	a3p_p_bsyw
a3p_p_bsyw:
	.long	0		| delays spent waiting for BSY to clear
	.globl	a3p_p_cp
a3p_p_cp:
	.long	0		| command phase after
	.globl	a3p_p_di
a3p_p_di:
	.long	0		| destination ID after; direction must be unchanged
	.globl	a3p_p_con
a3p_p_con:
	.long	0		| control after; should still read the PIO value
	.globl	a3p_p_sac0
a3p_p_sac0:
	.long	0		| SDMAC cursor BEFORE the PIO byte
	.globl	a3p_p_sac
a3p_p_sac:
	.long	0		| SDMAC cursor AFTER -- must equal sac0
	.globl	a3p_p_cntr
a3p_p_cntr:
	.long	0		| SDMAC control after
	.globl	a3p_p_istr
a3p_p_istr:
	.long	0		| SDMAC interrupt status after
	.globl	a3p_p_dmaon
a3p_p_dmaon:
	.long	0		| the driver's own DMA flag; must still be 0
	.balign	4
