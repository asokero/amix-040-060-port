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
| WHY IT DOES NOT TOUCH THE DEVICE.  reg() would give the phase and status registers, and
| reading them is deliberately omitted: this code runs at the moment of a hardware
| anomaly, in an interrupt handler, and reading SS is what acknowledges the interrupt in
| the first place.  An instrument that perturbs the thing it is measuring is worse than a
| smaller instrument.  If the fields below turn out not to be enough, adding register
| reads is a later decision made with evidence rather than a guess made now.
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
	.balign	4
