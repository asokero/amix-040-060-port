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
	moveq	&0x48,%d3
	cmpl	%d3,%d2
	bcsw	Lad_nopm		| ss < 0x48
	moveq	&0x4a,%d3
	cmpl	%d3,%d2
	bhiw	Lad_nopm		| ss > 0x4a
	movel	&0x41335052,a3p_ran	| "A3PR" -- this body ran
	addql	&1,a3p_seen
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
