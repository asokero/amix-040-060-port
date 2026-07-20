| dma_cache040.s -- caches Step B / B1 DMA-coherency hook group (2026-07-20).
|
| Spec: analyysirepo amix-kernel-analysis/vm-map/DMA-INITIATOR-CENSUS.md +
| DMA-PREPARE-COMPLETE-CONTRACT.md (commit 58f1cda) against kernel 8c0772a
| (build/unix-040 sha256 ef63f751...).
|
| WHY: the census closed CM-B1 matrix item 8 -- before the data cache can be
| enabled (even in writethrough), every FROM_DEVICE host-RAM DMA (device writes
| memory) can leave stale-but-valid CPU data-cache lines over the transfer
| buffer.  The CPU would then read the cache instead of the freshly DMA'd bytes
| -> silent filesystem corruption.  The fix is a data-cache invalidate after the
| controller has quiesced and BEFORE any callback consumes the buffer.
|
| SCOPE (A3000-first, per the 2026-07-20 direction decision): this file wires
| ONLY the A3000-internal A3091/SDMAC SCSI controller -- the sole host-RAM DMA
| initiator that actually fires on an A3000 + Mercury 040 (and on the a3000ux
| emulator config).  The census documents A2090, A2091 (+chip bounce), and the
| native A2090 ST-506 hd path identically; those cards are NOT in this machine
| (Zorro SCSI / ST-506) so their hooks are DEFERRED, not designed out.  Adding
| A2091 later = one more wrapper calling the SAME shared primitive below at the
| anchors the census already recorded -- no redesign, no lock-out.
|
| DORMANT NO-OP until the real-HW Step-B session flips CACR DC-enable: with the
| data cache OFF the cache is empty, so `cinva dc` is a harmless no-op.  This
| lets the a3091 wrapper's transcription be validated structurally on the
| emulator (a3000ux drives exactly this controller: boot/burst4/fsck exercise
| every retargeted call site) even though Amiberry cannot model DC coherency.
|
| MECHANISM: startdma/stopdma are file-LOCAL 't' symbols and there are THREE
| same-named copies (A2090/A2091/A3091), so the globalize+weaken override used
| elsewhere is ambiguous.  Instead patch_a3091_dma.py retargets ONLY the four
| a3091 `jsr stopdma` relocations (.rela.text r_offsets 0xd170/0xd1c8/0xd2ce/
| 0xd34a) to `dma_a3091_stopdma` below; the real body stays reachable via the
| relink --add-symbol alias `a3091_stopdma_orig` (= .text 0xd4cc).  A2090/A2091
| relocations are untouched.
|
| B1 completion is intentionally a whole-cache `cinva dc` on EVERY armed a3091
| completion, regardless of direction.  This is correct: in writethrough all RAM
| lines are clean, so invalidating on a TO_DEVICE completion merely discards
| clean copies (a refetch, never data loss), while FROM_DEVICE gets the required
| invalidate.  Per-range / per-direction precision + a pre-arm prepare hook are a
| B2 concern (copyback needs push-before-arm and cannot use a global invalidate);
| the contract explicitly blesses the whole-cache invalidate for the B1 pilot.
|
| Assemble:  m68k-cbm-sysv4-gcc -m68040 -c dma_cache040.s -o build/dma_cache040.o
| Externals: dma_on (a3091 driver global byte), a3091_stopdma_orig (relink alias).
| 040 privileged op as .word: cinva dc = 0xf458.

	.text

| ============================================================================
| dma_cache_fromdev_complete -- the shared B1 FROM_DEVICE completion primitive.
| Whole-data-cache invalidate + a pairing counter.  Fully register-transparent
| (cinva dc affects no registers; the counter increment is a memory op), so a
| controller wrapper may call it without saving scratch registers.  A2091 (and
| any future host-RAM initiator) calls THIS same primitive at its own stop site.
| ============================================================================
	.globl	dma_cache_fromdev_complete
dma_cache_fromdev_complete:
	.word	0xf458			| cinva dc -- invalidate the whole data cache
					|   (dormant no-op while CACR DC is disabled)
	addql	&1,dma_cmpl_count	| pairing/instrumentation counter (memory op)
	rts

| ============================================================================
| dma_a3091_stopdma -- wrapper installed (by relocation retarget) in place of
| every a3091 `jsr stopdma`.  Contract: call the real stopdma (quiesce the SDMAC
| + clear dma_on), then -- if a transfer was actually armed -- invalidate the
| data cache before the caller runs the sdcom.intr callback (d1c0 / d2f6) or
| re-arms on disconnect (d21a).  Register-transparent apart from the return
| value, which is passed through from the real stopdma (callers ignore it).
|
| Gate: read dma_on BEFORE the real stop (real stopdma clears it, and no-ops if
| it was already 0).  dma_on == 1 exactly when startdma armed a non-zero-length
| transfer, so this fires once per real hardware completion/disconnect and never
| on a spurious stop.  Single-slot state is correct: dma_on is one global => at
| most one a3091 DMA segment is ever active.
| ============================================================================
	.globl	dma_a3091_stopdma
dma_a3091_stopdma:
	clrl	%d0
	moveb	a3091_dma_on,%d0	| d0 = was a transfer armed? (before real stop clears it)
					|   a3091_dma_on = relink --add-symbol alias for the
					|   a3091 driver's file-LOCAL `dma_on` byte (.bss 0x3cc0)
	movel	%d0,%sp@-		| save was-active across the real call
	jsr	a3091_stopdma_orig	| real stopdma: quiesce SDMAC, clear dma_on (d0/a0 = ret)
	tstl	%sp@+			| pop + test was-active (does not touch d0/a0)
	beqw	Lds_done		| nothing was armed -> no completion to publish
	jsr	dma_cache_fromdev_complete | invalidate DC before callback (register-transparent)
Lds_done:
	rts
	nop				| pad .text to a 4-byte multiple (loader copies text+data as one block)

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.balign 4
| completion count (host-RAM FROM_DEVICE-class invalidates issued); readable via
| /dev/kmem or Amiberry IPC to confirm the hook fires under disk load on the emu.
	.globl	dma_cmpl_count
dma_cmpl_count:
	.long	0
	.balign 4			| pad section to a 4-byte multiple
