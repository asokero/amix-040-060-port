| segdevchk040.s -- ISSUE-49: measure the assumption the paired-vpage bridge rests on.
|
| WHAT THE BRIDGE ASSUMES.  src/patch_segdev_bridge.py makes segdev_fault and spec_segmap
| step one 4 KiB hardware page at a time while the software vpage array KEEPS its 2 KiB
| representation -- two entries per hardware page.  The fault path then reads the FIRST
| entry of each pair and skips both.  That is only correct while the two members of every
| pair are equal, and they are equal only because the generic as_fault / as_setprot /
| as_checkprot / as_unmap boundaries round addresses and extents to 4 KiB before segdev
| ever sees them.
|
| So the bridge depends on a property of code it does not touch, in a different file, with
| nothing connecting the two.  Change an as_* boundary back to 2 KiB and the bridge starts
| silently ignoring the second half of every protection change.  Nothing would fail loudly.
|
| WHY THIS IS A COUNTER AND NOT A COMMENT.  The review that proposed the bridge asks for the
| pair equality to be "confirmed in a debug build", which is a check that happens once and
| then stops happening.  This project has been bitten twice in a single day by exactly that:
| kvp_super_n read zero for its whole life because it tested SR bit 5 instead of 13, and the
| burst suite's anomaly line matched its own header so it could never print clean.  A
| coupling that is not measured decays quietly.
|
| WHAT IS MEASURED, AND WHY HERE RATHER THAN AT THE PAIR.  Comparing the two vpage entries
| after the fact would mean surgery inside a stock loop.  The cause is cheaper to watch than
| the symptom: an unequal pair can only be created by a segdev operation arriving on a
| 2 KiB-aligned address or length.  These two wrappers check exactly that, at the only two
| entry points that write or split the array -- segdev_setprot and segdev_unmap -- and both
| are reached through segdev_ops, so src/patch_segdev_ops.py retargets the table rather than
| weakening a symbol (every segdev op is a file-LOCAL 't', as with the a3091 DMA hooks).
|
| EXPECTED READING: sdc_setprot_bad and sdc_unmap_bad are 0 forever.  A non-zero value is
| not a curiosity -- it means the bridge's premise has stopped holding and the second half of
| some page's protection is being ignored.  The _n counters are the denominators, so that a
| zero can be told apart from a path that was never taken.
|
| CONTRACT.  Entered with the caller's frame untouched: sp@(0) return address, sp@(4) seg,
| sp@(8) addr, sp@(12) len -- verified against both prologues, which read %fp@(8/12/16)
| after their own link.  Saves and restores %d0, touches nothing else, and tail-jumps to the
| stock body, so both functions behave exactly as before.

	.text
	.globl	segdev_setprot_chk
segdev_setprot_chk:
	movel	%d0,%sp@-
	addql	&1,sdc_setprot_n
	movel	%sp@(12),%d0		| addr  (frame shifted 4 by the push above)
	orl	%sp@(16),%d0		| | len -- one test covers both
	andil	&0xfff,%d0
	beqs	Lsp_ok
	addql	&1,sdc_setprot_bad	| MUST STAY 0: a sub-page boundary reached segdev
	movel	%sp@(12),sdc_setprot_addr
	movel	%sp@(16),sdc_setprot_len
Lsp_ok:
	movel	%sp@+,%d0
	jmp	segdev_setprot_orig
	.balign	4

	.globl	segdev_unmap_chk
segdev_unmap_chk:
	movel	%d0,%sp@-
	addql	&1,sdc_unmap_n
	movel	%sp@(12),%d0
	orl	%sp@(16),%d0
	andil	&0xfff,%d0
	beqs	Lsu_ok
	addql	&1,sdc_unmap_bad	| MUST STAY 0: a split that could break a pair
	movel	%sp@(12),sdc_unmap_addr
	movel	%sp@(16),sdc_unmap_len
Lsu_ok:
	movel	%sp@+,%d0
	jmp	segdev_unmap_orig
	.balign	4

	.data
	.even
| --- counters, in reading order.  Magic first, and STATIC: this block is expected to read
|     zero for its whole life, and an all-zero block cannot otherwise be told apart from a
|     wrong address. ---
	.globl	sdc_magic
sdc_magic:
	.long	0x53444321		| "SDC!"
	.globl	sdc_setprot_n
sdc_setprot_n:
	.long	0			| denominator: segdev_setprot calls seen
	.globl	sdc_setprot_bad
sdc_setprot_bad:
	.long	0			| MUST STAY 0
	.globl	sdc_setprot_addr
sdc_setprot_addr:
	.long	0
	.globl	sdc_setprot_len
sdc_setprot_len:
	.long	0
	.globl	sdc_unmap_n
sdc_unmap_n:
	.long	0			| denominator: segdev_unmap calls seen
	.globl	sdc_unmap_bad
sdc_unmap_bad:
	.long	0			| MUST STAY 0
	.globl	sdc_unmap_addr
sdc_unmap_addr:
	.long	0
	.globl	sdc_unmap_len
sdc_unmap_len:
	.long	0
	.balign	4
