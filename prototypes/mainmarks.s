| mainmarks.s -- SWITCH BUILD with DIRECT-SERIAL trace markers (2026-06-23).
|
| GOAL: see, as plain text on the serial line, EXACTLY how far the 040 context-switch
| build gets and where it diverges.  cmn_err/printf are useless for this: they buffer into
| the SVR4 STREAMS console-log and only surface once the log queue is serviced -- in an
| unhealthy boot that drain may never run, so a cmn_err "marker" can be silently lost.
| Therefore every key point ALSO drops a single character STRAIGHT to serdat (serdbg_mark),
| synchronously, the instant its code runs.  The proven serdbg conputc hook still mirrors the
| normal console (banner etc.) to serial, so one serial log shows BOTH streams:
|   - banner / cmn_err TEXT  = the STREAMS-drained console path (proves drain happened)
|   - single chars P S W R J I r = direct markers (prove raw code execution reached that point)
|
| Marker legend (direct, synchronous -- always appear if the code runs):
|   P = schedpaging entered  (swapconf returned -> proc-1 setup; this is AFTER the banner)
|   S = sched entered        (proc 0 swapper; all 4 daemons created)
|   W = about to jsr swtch    (first real 040 context switch)
|   R = resume entered        (swtch picked a proc to dispatch)
|   J = resume about to jmp    (context restored; jumping to the proc's resume PC)
|   I = idle entered          (swtch found maxrunpri==-1; nothing runnable)
|   r = swtch RETURNED to sched (switched back to proc 0, or no transfer)
|
| Reading the log:
|   banner TEXT present            -> boot healthy to the banner (STREAMS drains pre-sched).
|   P present                      -> reached proc-1 setup (post-banner) synchronously.
|   S then W then R then J ...      -> the switch chain runs; J + forward progress = transfer.
|   J present but nothing after     -> child's saved 040 context is bad (resume jmp'd to junk).
|   I present                      -> swtch idled (maxrunpri==-1: no child visible to swtch).
|   r present                      -> swtch returned without transferring.
| The FIRST marker that the baseline shows but this build does NOT pins the divergence point.

	.text
| ---------------------------------------------------------------------------
| serdbg_mark(ch) -- emit ONE char DIRECTLY on the Amiga serial port, bypassing coputc AND
| the STREAMS console-log drain.  Fully register-preserving (saves d0-d1/a0-a1).  serper is
| set once (idempotent with serdbg_putc).  Bounded TBE wait so it never hangs.
	.globl	serdbg_mark
serdbg_mark:
	linkw	%fp,&0
	moveml	%d0-%d1/%a0-%a1,%sp@-
	movel	%fp@(8),%d0		| d0 = ch
	movel	&0x00dff000,%a0		| custom-chip base
	tstw	Lmk_init
	bnew	Lmk_go
	movew	&1,Lmk_init
	movew	&0x0174,%a0@(0x32)	| serper = 9600 baud divisor
Lmk_go:
	andiw	&0x00ff,%d0
	oriw	&0x0100,%d0		| STOPBIT | ch
	movew	%d0,%a0@(0x30)		| serdat <- byte (write FIRST, unconditional)
	movel	&0x00010000,%d1		| bounded TBE wait
Lmk_wait:
	movew	%a0@(0x18),%d0		| serdatr
	andiw	&0x2000,%d0		| TBE (transmit-buffer-empty)
	bnew	Lmk_done
	subql	&1,%d1
	bnew	Lmk_wait
Lmk_done:
	moveml	%sp@+,%d0-%d1/%a0-%a1
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| serdbg_hex(val) -- emit val as 8 hex digits (MSB first) DIRECTLY on serial, bypassing the
| STREAMS drain.  Fully register-preserving.  Used to dump curproc@252 (u_va) at resume entry
| so we can see WHY the remap path was (or wasn't) taken.
	.globl	serdbg_hex
serdbg_hex:
	linkw	%fp,&0
	moveml	%d0-%d3/%a0-%a1,%sp@-
	movel	%fp@(8),%d2		| d2 = val
	movel	&0x00dff000,%a1		| custom-chip base
	tstw	Lmk_init
	bnew	Lhx_start
	movew	&1,Lmk_init
	movew	&0x0174,%a1@(0x32)	| serper = 9600
Lhx_start:
	moveq	&7,%d3			| 8 nibbles
Lhx_next:
	roll	&4,%d2			| rotate MSB nibble into the low 4 bits
	movel	%d2,%d0
	andiw	&0x000f,%d0
	cmpiw	&9,%d0
	bhiw	Lhx_alpha
	addiw	&0x30,%d0		| '0'..'9'
	braw	Lhx_emit
Lhx_alpha:
	addiw	&0x37,%d0		| 'A'..'F'
Lhx_emit:
	andiw	&0x00ff,%d0
	oriw	&0x0100,%d0		| STOPBIT | digit
	movew	%d0,%a1@(0x30)		| serdat <- digit
	movel	&0x00008000,%d1		| bounded TBE wait
Lhx_wait:
	movew	%a1@(0x18),%d0
	andiw	&0x2000,%d0
	bnew	Lhx_after
	subql	&1,%d1
	bnew	Lhx_wait
Lhx_after:
	dbra	%d3,Lhx_next
	moveml	%sp@+,%d0-%d3/%a0-%a1
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| sched OVERRIDE -- the swapper loop entry (proc 0, called once by main() AFTER all 4
| daemons are created).  THIS BUILD performs the real first context switch.
| Mechanism: --weaken-symbol sched makes main's `jsr sched` resolve here (detour-jmp entry
| into relinked code Line-F-crashes on this 040; jsr-override entry works -- see git log).
| Drops 'S' (entered) + 'W' (about to switch) directly to serial, calls the stock 040 swtch
| (binary, pmove crp->movec urp already patched), then 'r' if swtch ever returns, then halts.
	.globl	sched
sched:
	linkw	%fp,&0
	pea	0x53			| 'S' -- sched entered (direct serial)
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	maxrunpri,%sp@-		| maxrunpri via cmn_err (STREAMS -- may or may not surface)
	pea	Lsch_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(12),%sp
	pea	0x57			| 'W' -- about to jsr swtch (first real 040 switch)
	jsr	serdbg_mark
	addqw	&4,%sp
	jsr	swtch			| REAL 040 context switch (was: spin in the baseline)
	pea	0x72			| 'r' -- swtch RETURNED (no transfer, or switched back)
	jsr	serdbg_mark
	addqw	&4,%sp
Lsch_spin:
	bra.w	Lsch_spin		| halt -- one switch is enough to localize the divergence
	nop

| ---------------------------------------------------------------------------
| schedpaging (GLOBAL T) -- FIRST call after swapconf returns.  Override: one-shot 'P' marker
| (direct) + return (skip paging-daemon tuning; harmless with free memory).  Proves we got
| past the banner + swapconf synchronously.  --weaken-symbol schedpaging.
	.globl	schedpaging
schedpaging:
	linkw	%fp,&0
	movel	Lsp_n,%d0
	bnew	Lsp_ret			| one-shot
	moveq	&1,%d0
	movel	%d0,Lsp_n
	pea	0x50			| 'P' -- schedpaging entered (direct serial)
	jsr	serdbg_mark
	addqw	&4,%sp
	pea	Lsp_msg
	pea	2
	jsr	cmn_err
	addqw	&8,%sp
Lsp_ret:
	unlk	%fp
	rts
	nop

| ---------------------------------------------------------------------------
| idle (GLOBAL T) -- swtch idles here only when maxrunpri==-1.  One-shot 'I' marker (direct)
| so we can tell "swtch chose to idle" from "swtch transferred to a child".  --weaken-symbol idle.
	.globl	idle
idle:
	movel	Lidle_n,%d0
	bnew	Lidle_stop		| already marked once -> just stop
	moveq	&1,%d0
	movel	%d0,Lidle_n
	pea	0x49			| 'I' -- idle entered (direct serial)
	jsr	serdbg_mark
	addqw	&4,%sp
Lidle_stop:
	stop	&0x2000			| stock idle wait -- let the boot run naturally
	rts
	nop

| ---------------------------------------------------------------------------
| resume (0x9c, GLOBAL T) -- 040 context-switch core, RELIABILITY-FIXED (2026-06-23) +
| direct markers R (entered) / J (about to jmp).
| The child's saved context is VALID (measured: a1=0x070418F8 procdup-save, sp=0x40001F40
| u-area stack).  The earlier instability was NOT a bad context but resume reading it from the
| FIXED u-area VA (0x40000318) AFTER the remap -- an 040 cache/timing-fragile access that
| intermittently read stale memory -> garbage a1 -> wild jmp -> guru.
| FIX: read the saved context from the STABLE kvsegu VA (curproc@252 + 0x318), always live in
| kptr040.  The uarea_pt remap (+cpusha) is still done so the CHILD's stack (fixed VA
| 0x40000000) works after transfer, but the jmp target no longer depends on the remap's timing.
| u_va==0 (proc 0 / early): no remap, read from the fixed VA (arg1) as stock resume did.
| Both serial markers fire on the SAFE (caller / proc 0) stack -- BEFORE the context-restoring
| movem -- so serdbg_mark never touches the (suspect) new stack.
| --weaken-symbol resume.  globals: curproc (C), kptr040 (D).
	.globl	resume
resume:
	pea	0x52			| 'R' -- resume entered (direct serial, safe caller stack)
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	curproc,%a1
	movel	%a1@(252),%d1		| d1 = u_va (new proc's u-area kvsegu VA; 0 for proc 0)
	movel	%d1,%sp@-		| DUMP u_va (hex) -- tells us if/why remap is taken
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%sp@(4),%a0		| a0 = arg1 = u+0x318 (fixed VA) -- default read source
	movew	%sr,%d0			| d0 = sr (preserved to the end; serdbg_mark keeps d0)
	movew	&0x2700,%sr		| mask interrupts for the remap
	tstl	%d1
	beqw	Lr_rest			| u_va==0 -> no remap, read from fixed VA (stock behaviour)
|	--- DUMP the proc's saved context (kvsegu, ATC-mapped, pre-pflusha = stack-safe) ---
|	saved a1 = u_va+0x318+24 (the jmp target / resume PC); saved sp = u_va+0x318+48.
|	Valid procdup context measured earlier: a1=0x070418F8, sp=0x40001F40.  Garbage here = the
|	procdup/setuctxt 040 child context is wrong (then the freeze is the jmp, not the kvsegu read).
	moveal	%d1,%a2
	movel	%a2@(0x330),%sp@-	| saved a1 (jmp target)
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%a2@(0x348),%sp@-	| saved sp
	jsr	serdbg_hex
	addqw	&4,%sp
|	--- remap uarea_pt[0],[1] = the child's 2 u-area leaf PTEs (for the child's stack) ---
	moveal	kptr040,%a2
	movel	%a2@,%d2
	andil	&0xffffff00,%d2		| d2 = uarea_pt base = kptr040[0] & ~0xFF
	moveal	%d2,%a2			| a2 = uarea_pt
	movel	%d1,%d4			| page 0: walk kptr040 for u_va
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4
	movel	%d1,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@		| uarea_pt[0] = child page-0 PTE
	pea	0x61			| 'a' -- uarea_pt[0] written OK
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%d1,%d3			| page 1: walk kptr040 for u_va+0x1000
	addil	&0x1000,%d3
	movel	%d3,%d4
	moveq	&18,%d5
	lsrl	%d5,%d4
	subil	&4096,%d4
	asll	&2,%d4
	addl	kptr040,%d4
	moveal	%d4,%a3
	movel	%a3@,%d4
	andil	&0xffffff00,%d4
	movel	%d3,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5
	andil	&0x3f,%d5
	asll	&2,%d5
	addl	%d5,%d4
	moveal	%d4,%a3
	movel	%a3@,%a2@(4)		| uarea_pt[1] = child page-1 PTE
	pea	0x62			| 'b' -- uarea_pt[1] written OK
	jsr	serdbg_mark
	addqw	&4,%sp
	pea	0x63			| 'c' -- about to cpusha (stack still valid: ATC unchanged)
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0xf4f8			| cpusha bc -- push uarea_pt writes to RAM for the HW tablewalk
	pea	0x64			| 'd' -- cpusha done (stack still valid: pflusha not yet run)
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0xf518			| pflusha -- invalidate the ATC (fixed-VA stack now remaps away!)
	moveal	%d1,%a0			| a0 = u_va + 0x318 = the STABLE kvsegu read source
	addal	&0x318,%a0
Lr_rest:
|	STACKLESS 'J' marker -- after the remap+pflusha the fixed-VA (0x40000000) kernel stack
|	points at the NEW proc's physical u-area, so we must NOT touch the stack here (no jsr/push;
|	that is exactly why the stock resume goes straight to moveml/jmp).  Emit using registers
|	only: a1 = custom base (reloaded by the moveml below); d1/d2 = scratch (d1 not part of the
|	restored context d2-d7/a1-sp; d2 IS reloaded by the moveml).  d0 (sr) and a0 (src) untouched.
	movel	&0x00dff000,%a1
	movew	&0x014a,%a1@(0x30)	| serdat <- STOPBIT | 'J' (0x4a)
	movel	&0x00004000,%d1		| bounded TBE pacing
LrJ_wait:
	movew	%a1@(0x18),%d2
	andiw	&0x2000,%d2
	bnew	LrJ_done
	subql	&1,%d1
	bnew	LrJ_wait
LrJ_done:
|	TEST read of the kvsegu context source (a0 = u_va+0x318 = 0x48440318) AFTER pflusha.
|	If kvsegu is NOT walkable by the HW tablewalk post-ATC-flush, THIS read faults -> freeze
|	with no 'K'.  If 'K' prints, the read works and any freeze is at the jmp (bad target/ctx).
	movel	%a0@,%d1		| faulting candidate
	movel	&0x00dff000,%a1
	movew	&0x014b,%a1@(0x30)	| 'K' -- post-pflusha kvsegu read SUCCEEDED
	movel	&0x00004000,%d1
LrK_wait:
	movew	%a1@(0x18),%d2
	andiw	&0x2000,%d2
	bnew	LrK_done
	subql	&1,%d1
	bnew	LrK_wait
LrK_done:
	moveml	%a0@,%d2-%d7/%a1-%sp	| restore the new proc's context (reliable: stable VA)
	movew	%d0,%sr
	moveq	&1,%d0
	jmp	%a1@

	.data
Lsch_msg:
	.asciz	"DBG sched ENTRY maxrunpri=%x"
	.even
Lsp_msg:
	.asciz	"DBG MARK: schedpaging (swapconf returned) -- entering proc-1 setup"
	.even
Lsp_n:
	.long	0
Lidle_n:
	.long	0
Lmk_init:
	.word	0
	.even
