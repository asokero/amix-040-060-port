| dma_cache040.s -- caches Step B DMA-coherency hook group.
| B1 (2026-07-20): whole-cache FROM_DEVICE completion invalidate (stopdma wrap).
| B2 (2026-07-23): full segment-ownership protocol per
| docs/contracts/A3091-B2-PREPARE-PATCH-SPEC.md (pinned bc27d81 / base sha d3e1f80a).
|
| WHY B2 CHANGES THIS FILE: under copyback the B1 completion-time whole-cache
| `cinva dc` becomes FORBIDDEN -- DMA is asynchronous, the CPU dirties unrelated
| copyback lines while a transfer runs, and a global invalidate would DISCARD
| that data.  The B2 protocol is ownership-based:
|   prepare  (before arm):  push CPU dirty lines covering the segment so the
|                           device reads current RAM (TO_DEVICE) and so no old
|                           dirty line can be evicted over fresh device bytes
|                           mid-transfer (FROM_DEVICE).
|   complete (after stop):  range-invalidate the segment (FROM_DEVICE only)
|                           before any callback/requeue consumer reads it.
| PILOT FORM (spec "Recommended 040 pilot intermediate"): prepare = whole-cache
| `cpusha dc` (SAFE, unlike cinva: it writes dirty data instead of discarding;
| A3091 is the only host-RAM DMA owner in this machine) + complete = per-range
| `cinvl` loop.  Range metadata is recorded from day one so prepare can later
| become a per-range `cpushl` loop without touching the state machine.
|
| SCOPE: A3000-first -- only the A3091/SDMAC (the sole host-RAM DMA initiator
| on A3000 + Mercury 040; the a3000ux emulator drives exactly this controller).
| A2090/A2091/native-hd remain deferred with anchors in the census.
|
| MECHANISM: startdma/stopdma are file-LOCAL and same-named x3 (A2090/A2091/
| A3091) -> patch_a3091_dma.py retargets ONLY the A3091 relocations:
|   stop  x4: 0xd170/0xd1c8/0xd2ce/0xd34a -> dma_a3091_stopdma   (B1, kept)
|   start x2: 0xd0b2 (initial arm)        -> dma_a3091_startdma  (B2, new)
|             0xd21a (reconnect re-arm)   -> dma_a3091_startdma_reconn
| Real bodies stay reachable via relink --add-symbol aliases
| a3091_stopdma_orig (=0xd4cc) and a3091_startdma_orig (=0xd40a).
|
| Driver facts (byte-identical amix-src a3091.c:321..355 + sd.h:35..46,
| re-verified from the pinned binary):
|   unit:  +0x04 comhead, +0x0c tc0, +0x0d tc1, +0x0e tc2
|   sdcom: +0x04 reading (byte), +0x14 addr, +0x18 nbyte
|   startdma: n = tc0<<16|tc1<<8|tc2; n==0 -> no arm; pa = addr + nbyte - n
|   (on reconnect the Save-Data-Pointers path updated tc0..2, so pa/len name
|   exactly the remaining suffix -- the reconnect entry re-prepares that range)
|   dma_on: one global byte -> at most ONE armed segment ever exists, so a
|   single metadata record is sufficient and the interrupt DFA serializes it.
|
| State machine (dma_seg_state): 0=EMPTY, 1=PREPARING, 2=PREPARED.  PREPARED is
| set BEFORE the original arm (the device can interrupt and complete before the
| wrapper returns).  Mismatches never panic the base build -- they land in
| dedicated counters (dma_prep_owned / dma_cmpl_noprep) and skip the unbounded
| cache op; the acceptance run requires those counters to stay 0.
|
| 040 ops as .word: cpusha dc = 0xf478, cinvl dc,(a0) = 0xf448.
| (68060 note: CPUSH invalidation depends on CACR.DPI; current CACR 0x80008000
| has DPI clear.  Real-060 B2 acceptance is a separate milestone.)
|
| Assemble:  m68k-cbm-sysv4-gcc -m68040 -c dma_cache040.s -o build/dma_cache040.o

	.text

| ============================================================================
| dma_a3091_startdma[_reconn] -- prepare wrapper for the two A3091 arm sites.
| Same C signature as the original: startdma(up), arg at sp@(4).
| Preserves d2-d5/a2-a3 (movem 24 bytes -> arg at sp@(28)); ends with a
| relocated `jmp a3091_startdma_orig` tail-call (stack transparent).
| ============================================================================
	.globl	dma_a3091_startdma_reconn
dma_a3091_startdma_reconn:
	addql	&1,dma_reconn_arm	| reconnect/re-arm entry (0xd21a) -- count,
					| then identical handling (suffix re-prepare)
	.globl	dma_a3091_startdma
dma_a3091_startdma:
	moveml	%d2-%d5/%a2-%a3,%sp@-
	moveal	%sp@(28),%a2		| a2 = up
	clrl	%d2
	moveb	%a2@(12),%d2		| n = tc0<<16 | tc1<<8 | tc2
	lsll	&8,%d2
	moveb	%a2@(13),%d2
	lsll	&8,%d2
	moveb	%a2@(14),%d2
	tstl	%d2
	bnew	Lst_arm
	addql	&1,dma_zero_arm		| zero-length: original no-arm path,
	braw	Lst_call		| no ownership state is created
Lst_arm:
	moveal	%a2@(4),%a3		| a3 = cp = up->comhead
	moveq	&0,%d3			| direction: 0 = TO_DEVICE
	tstb	%a3@(4)			| cp->reading?
	beqw	Lst_dirok
	moveq	&1,%d3			| 1 = FROM_DEVICE
Lst_dirok:
	movel	%a3@(20),%d4		| cp->addr
	addl	%a3@(24),%d4		| + cp->nbyte = end
	bcsw	Lst_ovf			| address arithmetic wrapped
	cmpl	%d2,%d4
	bcsw	Lst_ovf			| end < n -> underflow
	subl	%d2,%d4			| d4 = pa = end - n; len = d2 = n
	tstb	dma_seg_state
	beqw	Lst_stateok
	addql	&1,dma_prep_owned	| prepare while a segment is still owned:
	braw	Lst_call		| diagnostic; never overwrite live metadata
Lst_stateok:
	moveb	&1,dma_seg_state	| PREPARING (record before cache op)
	movel	%d4,dma_seg_pa
	movel	%d2,dma_seg_len
	moveb	%d3,dma_seg_dir
	addql	&1,dma_seg_seq
	tstb	%d3
	beqw	Lst_cntto
	addql	&1,dma_prep_from
	braw	Lst_push
Lst_cntto:
	addql	&1,dma_prep_to
Lst_push:
	.word	0xf478			| cpusha dc -- PILOT prepare: push every dirty
					| line to RAM (+invalidate).  Correct for both
					| directions; per-range cpushl is the later
					| production optimization (same state machine).
	addql	&1,dma_prep_whole
	moveb	&2,dma_seg_state	| PREPARED -- visible before hardware arm
Lst_call:
	moveml	%sp@+,%d2-%d5/%a2-%a3
	jmp	a3091_startdma_orig	| tail-call the real arm (relocated ref)
Lst_ovf:
	addql	&1,dma_range_ovf	| impossible-range diagnostic; arm without
	braw	Lst_call		| ownership (counter must stay 0)

| ============================================================================
| dma_a3091_stopdma -- completion wrapper (all four stop sites; B1 retargets
| kept).  Quiesce FIRST (real stopdma: fdma/poll/cint/srst, clears dma_on),
| then consume the ownership record: FROM_DEVICE -> range cinvl over the
| programmed segment (conservative on error/partial: device may have written a
| prefix; CPU was forbidden to touch the owned rounded range), TO_DEVICE -> no
| cache op.  Complete runs before the caller's callback/requeue/re-arm.
| dma_on is read BEFORE the real stop (it clears it); dma_on==0 = stock
| spurious-stop no-op.  Preserves d2-d5/a2.
| ============================================================================
	.globl	dma_a3091_stopdma
dma_a3091_stopdma:
	moveml	%d2-%d5/%a2,%sp@-
	clrl	%d2
	moveb	a3091_dma_on,%d2	| was a transfer armed?
	beqw	Lds_stop		| no -> just run the stock no-op stop
	moveq	&0,%d3			| d3 = have-metadata flag
	cmpib	&2,dma_seg_state	| PREPARED?
	bnew	Lds_noprep
	moveq	&1,%d3
	movel	dma_seg_pa,%d4		| snapshot the programmed segment
	movel	dma_seg_len,%d5
	clrl	%d0
	moveb	dma_seg_dir,%d0
	moveal	%d0,%a2			| a2 = direction (0/1)
	braw	Lds_stop
Lds_noprep:
	addql	&1,dma_cmpl_noprep	| armed but no PREPARED record: skip the
					| unbounded cache op, expose via counter
Lds_stop:
	jsr	a3091_stopdma_orig	| quiesce hardware first; clears dma_on
	tstl	%d2
	beqw	Lds_out			| spurious stop -> done
	tstl	%d3
	beqw	Lds_out			| no metadata -> counted above, done
	movel	%a2,%d0
	tstl	%d0
	beqw	Lds_to			| TO_DEVICE: no cache op at complete
	movel	%d4,%d0
	andil	&-16,%d0		| first line (16-byte rounding)
	moveal	%d0,%a0
	movel	%d4,%d1
	addl	%d5,%d1			| pa + len (wrap guarded at prepare)
	addil	&15,%d1
	andil	&-16,%d1		| first byte past the final line
Lds_iloop:
	.word	0xf448			| cinvl dc,(a0) -- range invalidate: fresh
	addaw	&16,%a0			| device bytes become visible; unrelated
	cmpal	%d1,%a0			| dirty CB lines are NOT touched
	bnew	Lds_iloop
	addql	&1,dma_cmpl_from
	braw	Lds_paired
Lds_to:
	addql	&1,dma_cmpl_to
Lds_paired:
	addql	&1,dma_cmpl_count	| legacy pairing counter (B1 evidence continuity)
	clrb	dma_seg_state		| EMPTY (pa/len/seq retained for diagnostics)
Lds_out:
	moveml	%sp@+,%d2-%d5/%a2
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.balign 4
| --- magic first, as everywhere in this port ------------------------------------------------
| This block went without one until 2026-08-29, and it cost a hardware session.  Reading it at
| `nm value + 0x08000000` instead of `0x08000000 + textsize + nm value` lands in the middle of
| .text, and .text does not fail to be read: it returned 207c00bf and 4e5e4e75 -- two perfectly
| plausible counter values that are actually instruction words.  Nothing caught it because there
| was no magic to check.
|
| It is NOT the last block without one -- that was measured after the fact and the belief was
| wrong.  Eighteen prefixes in this port's own sources have three or more .data symbols and no
| magic (x60, wb, segvn, srt, page, hat, dbg, codepub, cb, us, fpsp and the local-label groups).
| Not all of those are counter blocks -- several are format strings and jump tables that nobody
| reads as numbers -- but nobody has been through them to say which.
	.globl	dma_magic
dma_magic:
	.long	0x444D4121		| "DMA!" -- STATIC: proves the address, never written
| --- single-segment ownership record (dma_on serializes: max one armed) ---
	.globl	dma_seg_pa
dma_seg_pa:
	.long	0
	.globl	dma_seg_len
dma_seg_len:
	.long	0
	.globl	dma_seg_seq
dma_seg_seq:
	.long	0
	.globl	dma_seg_dir
dma_seg_dir:
	.byte	0			| 0 = TO_DEVICE, 1 = FROM_DEVICE
	.globl	dma_seg_state
dma_seg_state:
	.byte	0			| 0 = EMPTY, 1 = PREPARING, 2 = PREPARED
	.balign 4
| --- instrumentation (read via /dev/kmem or Amiberry IPC) ---
| acceptance: prep_to+prep_from == cmpl_to+cmpl_from (pairing), and
| prep_owned == cmpl_noprep == range_ovf == 0.
	.globl	dma_prep_to
dma_prep_to:
	.long	0
	.globl	dma_prep_from
dma_prep_from:
	.long	0
	.globl	dma_cmpl_to
dma_cmpl_to:
	.long	0
	.globl	dma_cmpl_from
dma_cmpl_from:
	.long	0
	.globl	dma_zero_arm
dma_zero_arm:
	.long	0
	.globl	dma_reconn_arm
dma_reconn_arm:
	.long	0
	.globl	dma_prep_owned
dma_prep_owned:
	.long	0
	.globl	dma_cmpl_noprep
dma_cmpl_noprep:
	.long	0
	.globl	dma_range_ovf
dma_range_ovf:
	.long	0
	.globl	dma_prep_whole
dma_prep_whole:
	.long	0
| legacy B1 completion counter -- kept: existing evidence/acceptance tooling
| reads it; now increments once per consumed ownership record (either direction).
	.globl	dma_cmpl_count
dma_cmpl_count:
	.long	0
	.balign 4			| pad section to a 4-byte multiple
