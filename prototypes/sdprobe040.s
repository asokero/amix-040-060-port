| sdprobe040.s -- cache-vs-partial PROBE override for sdpartition (0xd848, GLOBAL T).
|
| Goal: decide why getrdb returns ENXIO (root-mount r=6) in the current 040 layout.
| sdpart.c reads the Rigid Disk Block via DMA into the static buffer `block`, then checks
| block.rdb_ID == 'RDSK'.  On the 68040 copyback D-cache the DMA writes RAM but the CPU may
| read a STALE cached `block` -> 'RDSK' check fails.  This probe replays getrdb's read loop
| but INVALIDATES the data cache (cinva %dc = 0xf458) right after each DMA, then re-checks:
|   * 'RDSK' FOUND after cinva (found >= 0)  => pure CACHE staleness; the fix is to cinva
|     the block buffer in the read path (then root mount works regardless of layout).
|   * NOT found even after cinva (found = -1) => the data is not in RAM (PARTIAL DMA
|     transfer) or the RDB is past block 15; cinva alone won't fix it.
| Also prints block[0] PRE- vs POST-cinva: if they DIFFER, the cache really was stale.
|
| Calls the stock static read() at 0xda72 via an --add-symbol alias (it cannot be reached
| by name: the file-local `read` would collide with the global syscall `read` at 0x5dcf0).
| `block` (local b @0x3df8) -> --globalize-symbol so `lea block` resolves.  sdpartition (T)
| -> --weaken-symbol so this strong def wins.  Returns ENXIO (boot still fails, by design --
| this is a diagnostic, not the fix).

	.text
	.globl	sdpartition
sdpartition:
	linkw	%fp,&0
	moveml	%d2-%d6/%a2,%sp@-	| callee-saved: survive read()/cmn_err
	lea	block,%a2		| a2 = &block
	moveq	&0,%d4			| d4 = block index i
	moveq	&-1,%d3			| d3 = found index (-1 = none)
	moveq	&0,%d5			| d5 = last block[0] PRE-cinva
	moveq	&0,%d2			| d2 = last block[0] POST-cinva
	moveq	&0,%d6			| d6 = read() return for block 0
Lsp_loop:
	cmpil	&16,%d4
	bgew	Lsp_done
	movel	%d4,%sp@-		| bno = i
	movel	%fp@(12),%sp@-		| strat
	movel	%fp@(8),%sp@-		| dev
	jsr	sdpart_read		| stock sdpart read() -> DMA block i into `block`
	lea	%sp@(12),%sp
	tstl	%d4			| capture read() return for block 0 only
	bnew	Lsp_nocap
	movel	%d0,%d6
Lsp_nocap:
	movel	%a2@,%d5		| block[0] as seen NOW (pre-cinva, possibly stale)
	.word	0xf458			| cinva %dc (invalidate data cache -> next read = RAM)
	movel	%a2@,%d2		| block[0] from RAM (post-cinva)
	cmpil	&0x5244534b,%d2		| 'RDSK' ?
	beqw	Lsp_found
	addql	&1,%d4
	braw	Lsp_loop
Lsp_found:
	movel	%d4,%d3			| found = i
Lsp_done:
	movel	%d6,%sp@-		| read() return for block 0 (0=ok, !=0=DMA/SCSI error)
	movel	%a2@(28),%sp@-		| rdb_PartitionList (block@0x1c) post-cinva
	movel	%d5,%sp@-		| block[0] PRE-cinva
	movel	%d2,%sp@-		| block[0] POST-cinva
	movel	%d3,%sp@-		| found index (-1 = RDSK never seen, even post-cinva)
	pea	Lprobe
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	moveq	&6,%d0			| return ENXIO (diagnostic: boot still fails)
	moveal	%d0,%a0
	moveml	%fp@(-24),%d2-%d6/%a2
	unlk	%fp
	rts

	.data
	.even
Lprobe:
	.asciz	"DBG PROBE found=%x b0post=%x b0pre=%x plist=%x readret=%x"
