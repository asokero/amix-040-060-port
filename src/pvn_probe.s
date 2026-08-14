| pvn_probe.s -- the pl[] return-list contract detector Codex asked for (ISSUE-36 follow-on).
|
| WHAT CONTRACT, AND WHY A PROBE RATHER THAN A USER-SPACE TEST
| Codex (docs/contracts/NFS-READSIDE-ISSUE36-SITE.md): the loop in nfs_getapage that fills the caller's
| page-list array is bounded ONLY by a byte countdown, and SVR4 page_t cluster lists are CIRCULAR,
| so with a stale 2 KiB countdown an 8 KiB cluster of two 4 KiB pages emits
|
|     old:      A, B, A, B, NULL              correct:  A, B, NULL
|
| Duplicate pointers, duplicate holds, entries overwritten on a later iteration and unbalanced
| release ownership all follow.  And Codex is explicit that user space cannot be trusted to see it:
| the RPC may fill every physical page correctly, and the reviewed segvn and segmap local arrays
| have enough slots to hide a small over-return.  "A black-box checksum alone cannot replace it."
| So the requirement is measured here, in the kernel, as
|
|     count <= ceil(plsz / 4096)      and      every returned pointer distinct
|
| WHY pvn_getpages AND NOT nfs_getapage -- this is a hard constraint, not a preference
| nfs_getapage (0x8b14c) and nfs_getpage (0x8b5d4) are LOCAL symbols (nm shows `t`), so a
| --weaken-symbol override cannot intercept them: references to a local symbol are resolved inside
| the object and a new global definition never wins.  And detour-jmp instrumentation Line-F crashes
| on the 040 ([[040-detour-jmp-crashes]]).  pvn_getpages (0xb25da) IS global (`T`) and it is the
| function that owns the caller's array, so it is both wrappable and the right observation point.
|
| Consequence to keep in mind when reading the output: the single-page DIRECT dispatch path
| (nfs_getpage's 0x8b72c branch calls the provider without pvn_getpages) is NOT observed here.
| This probe sees the clustered path, which is the one Codex says carries the violation.
|
| ARGUMENT LAYOUT, verified in the disassembly rather than assumed from the 3b2 source:
|     fp@(8)  getapage fn   (moveal %fp@(8),%a1 ; jsr %a1@ at 0xb263c)
|     fp@(12) vp            fp@(16) off      fp@(20) len     fp@(24) protp
|     fp@(28) pl            <- d6/a2, the array cursor
|     fp@(32) plsz          <- read at 0xb261e for the last page's remaining capacity
|     fp@(36) seg           fp@(40) addr     fp@(44) rw      fp@(48) cred
| The per-iteration provider capacity starts at 4096 (0xb25f8) and becomes
| caller_plsz - bytes_already_returned on the last requested page (0xb261a..0xb2622).
|
| OUTPUT, and how to read it
|     DBG pvn n=%d cap=%d plsz=%x off=%x  p0=%x p1=%x p2=%x p3=%x
|     DBG pvn   poff0=%x poff1=%x poff2=%x poff3=%x
| A violation is EITHER n > cap OR two equal non-NULL pointers among the counted entries.  Both
| are tested (the duplicate test was missing until 2026-07-28 -- see the block comment below; its
| absence is why a hardware run reported "no violation" while saying nothing about duplicates).
| The pointers are printed rather than a boolean because the p_offsets say whether duplicates are
| the same page or merely adjacent ones, which a boolean could not.
|
| GATING.  Violations always print (capped, so a storm cannot wedge the console the way ISSUE-37
| does).  Beyond that the first few normal calls print as a baseline, because "no violations" is
| only meaningful if we can also see that the probe fires at all -- a silent probe and a clean
| kernel look identical otherwise.  That distinction cost us a boot on the ISSUE-37 hunt.
|
| Wired by relink-040-dbg.sh:
|     --add-symbol pvn_getpages_orig=.text:0xb25da,function,global --weaken-symbol pvn_getpages
| cmn_err preserves d2-d7/a2-a6, so the saved state survives the printing.
| Every section ends .balign 4 -- an unaligned .bss lands as SDMAC DMA corruption at root mount.

	.text
	.globl	pvn_getpages
pvn_getpages:
	linkw	%fp,&0
	moveml	%d2-%d7/%a2-%a3/%a5,%sp@-

| --- forward all eleven arguments unchanged, right to left ---
	movel	%fp@(48),%sp@-		| cred
	movel	%fp@(44),%sp@-		| rw
	movel	%fp@(40),%sp@-		| addr
	movel	%fp@(36),%sp@-		| seg
	movel	%fp@(32),%sp@-		| plsz
	movel	%fp@(28),%sp@-		| pl
	movel	%fp@(24),%sp@-		| protp
	movel	%fp@(20),%sp@-		| len
	movel	%fp@(16),%sp@-		| off
	movel	%fp@(12),%sp@-		| vp
	movel	%fp@(8),%sp@-		| getapage
	jsr	pvn_getpages_orig
	lea	%sp@(44),%sp
	movel	%d0,%d2			| d2 = return value, preserved across cmn_err

| --- count the returned entries, hard-capped so a smashed list cannot run away ---
|     The cap is the safety property: if the over-return walked off the caller's array we must
|     stop at a fixed bound rather than follow whatever is on their stack.
	movel	%fp@(28),%d0
	beqw	Lpv_ret			| pl == NULL: nothing to inspect (valid for some callers)
	moveal	%d0,%a2
	moveal	%a2,%a3
	clrl	%d4			| d4 = count
Lpv_cnt:
	cmpil	&16,%d4
	bccw	Lpv_cnt_done
	movel	%a3@,%d0
	beqw	Lpv_cnt_done
	addql	&1,%d4
	addql	&4,%a3
	braw	Lpv_cnt
Lpv_cnt_done:

| --- capacity = ceil(plsz / 4096), by shifts: (plsz + 4095) >> 12 ---
	movel	%fp@(32),%d5
	addil	&4095,%d5
	lsrl	&8,%d5
	lsrl	&4,%d5			| d5 = cap

| --- decide whether to print: violation always (capped), otherwise the first few ---
	cmpl	%d5,%d4
	bhiw	Lpv_viol		| count > cap -> contract violation
| --- DUPLICATE-POINTER TEST (added 2026-07-28 on Codex's XPAGE-COVERAGE-AUDIT finding).
|     This file documented TWO invariants -- count <= cap AND all pointers distinct -- but only
|     the count was ever tested.  The predicted old-provider shape A,B,A,B in a 16 KiB caller
|     array has count 4 and cap 4, so it passed the count test silently, and the duplicate would
|     only have shown in a normal SAMPLE line -- which boot had already consumed.  That is exactly
|     why the hardware run reported "no violation" without saying anything about duplicates.
|     O(n^2) over a hard-capped 16 entries: any equal non-NULL pair is a violation by itself. ---
	moveal	%a2,%a3			| a3 = &pl[i]
	clrl	%d6			| d6 = i
Lpv_di:
	cmpl	%d4,%d6
	bccw	Lpv_dz			| i >= count -> no duplicate found
	movel	%a3@,%d1		| pl[i]
	beqw	Lpv_dz
	movel	%d6,%d0
	addql	&1,%d0			| j = i + 1
Lpv_dj:
	cmpl	%d4,%d0
	bccw	Lpv_dinext
	movel	%d0,%d7
	asll	&2,%d7
	moveal	%a2,%a5
	addal	%d7,%a5
	cmpl	%a5@,%d1		| pl[j] == pl[i] ?
	beqw	Lpv_viol		| duplicate pointer -> report it
	addql	&1,%d0
	braw	Lpv_dj
Lpv_dinext:
	addql	&1,%d6
	addql	&4,%a3
	braw	Lpv_di
Lpv_dz:
	movel	Lpv_nsamp,%d0
	cmpil	&6,%d0
	bccw	Lpv_ret
	addql	&1,%d0
	movel	%d0,Lpv_nsamp
	braw	Lpv_print
Lpv_viol:
	movel	Lpv_nviol,%d0
	cmpil	&24,%d0			| cap violation prints too: never trade one storm for another
	bccw	Lpv_ret
	addql	&1,%d0
	movel	%d0,Lpv_nviol

Lpv_print:
| --- snapshot up to four entries and their p_offsets into scratch, zero-filled.
|     Only entries below the counted length are touched, so nothing past the NULL is read. ---
	clrl	Lpv_s
	clrl	Lpv_s+4
	clrl	Lpv_s+8
	clrl	Lpv_s+12
	clrl	Lpv_s+16
	clrl	Lpv_s+20
	clrl	Lpv_s+24
	clrl	Lpv_s+28
	clrl	%d6			| d6 = i
Lpv_snap:
	cmpil	&4,%d6
	bccw	Lpv_snap_done
	cmpl	%d4,%d6
	bccw	Lpv_snap_done
	movel	%d6,%d0
	asll	&2,%d0
	moveal	%a2,%a3
	addal	%d0,%a3
	movel	%a3@,%d1		| pl[i]
	lea	Lpv_s,%a3
	addal	%d0,%a3
	movel	%d1,%a3@		| scratch pointer slot
	moveal	%d1,%a3
	movel	%a3@(8),%d1		| pp->p_offset  (offset 8, same field segmap_fault reads)
	movel	%d6,%d0
	asll	&2,%d0
	lea	Lpv_s+16,%a3
	addal	%d0,%a3
	movel	%d1,%a3@		| scratch p_offset slot
	addql	&1,%d6
	braw	Lpv_snap
Lpv_snap_done:

	movel	Lpv_s+12,%sp@-
	movel	Lpv_s+8,%sp@-
	movel	Lpv_s+4,%sp@-
	movel	Lpv_s,%sp@-
	movel	%fp@(16),%sp@-		| off
	movel	%fp@(32),%sp@-		| plsz
	movel	%d5,%sp@-		| cap
	movel	%d4,%sp@-		| n
	pea	Lpv_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(40),%sp

	movel	Lpv_s+28,%sp@-
	movel	Lpv_s+24,%sp@-
	movel	Lpv_s+20,%sp@-
	movel	Lpv_s+16,%sp@-
	pea	Lpv_msg2
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp

Lpv_ret:
	movel	%d2,%d0			| restore pvn_getpages_orig's return value
	moveal	%d2,%a0
	moveml	%fp@(-36),%d2-%d7/%a2-%a3/%a5
	unlk	%fp
	rts
	nop				| keep text/data contiguous

	.balign 4			| pad section to a 4-byte multiple (.bss placement)
	.data
	.even
Lpv_msg:
	.asciz	"DBG pvn n=%d cap=%d plsz=%x off=%x p0=%x p1=%x p2=%x p3=%x"
	.even
Lpv_msg2:
	.asciz	"DBG pvn   poff0=%x poff1=%x poff2=%x poff3=%x"
	.even
Lpv_nsamp:
	.long	0
Lpv_nviol:
	.long	0
Lpv_s:
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.long	0
	.balign 4			| pad section to a 4-byte multiple (.bss placement)
