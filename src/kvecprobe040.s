| kvecprobe040.s -- count every exception vector that reaches nullvect (F3 M0, 2026-08-07).
|
| WHY THIS EXISTS.  We cannot currently attribute a SIGSYS to a vector.  `nullvect` is the
| catch-all that turns an unhandled exception into SIGSYS, and the kernel prints a vector
| ONLY for SIGKILL kills (u_trap's "because of vector 0x%x" is the single such message in
| the image, docs/060-F0-MEASUREMENT-260805.md).  So today:
|   * `acomp` dies with SIGSYS on FP source and we infer vector 11 from the gate in
|     fpsp_glue040.s -- inference, not measurement;
|   * wolf3d's "bad system call" and the xv/X11R5 crashes are CONSISTENT with the missing
|     060 FPSP and completely unproven, because SIGSYS also has a legitimate producer in a
|     genuinely absent system call;
|   * and every later F3 milestone would be judged by "the SIGSYS stopped", which is only
|     evidence once we know which vector was producing it.
| This unit answers all three with one hook and no policy change.
|
| WHY IT WRAPS nullvect INSTEAD OF RETARGETING A VECTOR SLOT.  patch_isp_vec61.py retargets
| M68Kvec[61] to one handler, which is right for a handler.  A probe wants the opposite:
| every vector that currently lands on nullvect, in one place, with no vector table edited.
| Wrapping the shared tail gives complete coverage for one override.
|
| CONTRACT.  nullvect is entered directly by the CPU with the RAW exception frame on (sp)
| -- verified by disassembling it at 0x11b4:
|     moveml %d0-%fp,%sp@- / movel sup_cacr,%d0 / movec %d0,%cacr / btst #5,%sp@(60)
| so it reads the frame at a fixed offset from its own entry SP.  This wrapper therefore
| must return SP byte-identical before jumping on.  It pushes 12 bytes, uses them, and pops
| them back; the only other state it touches is CCR, which the stock body's first
| instruction (moveml) does not read.
|
| NOT cputype-gated, deliberately: this measures BOTH processors and the 040 numbers are the
| control for the 060 ones.  It is gated on the kvp_on data flag instead (default 1), so the
| probe can be taken out of the path within a single boot -- the wb_dfc_on / kdbg_on pattern.
|
| Install: --weaken-symbol nullvect + --add-symbol nullvect_orig=.text:0x11b4 (address
| asserted from build/unix-stage1 and vanilla stand/unix; both read 0x000011b4).
|
| KVP_SUPER_N WAS STRUCTURALLY DEAD UNTIL 2026-08-25, and every reading of it before that
| date is void rather than zero.  The S-bit test below read `btst &5,%d1` -- the REGISTER
| form, which is a long operand with the bit number taken mod 32, so it tested SR bit 5,
| a bit the 68040 and 68060 both define as zero.  The branch was never taken and EVERY
| entry landed in kvp_user_n; "all user" was not a measurement.  Confirmed from the linked
| image before it was fixed: `0801 0005` at 0xda95a.  nullvect_orig itself gets this right
| with the memory form, `btst #5,%sp@(60)`, because there bit 5 addresses the S bit inside
| the SR's high BYTE.  The fix keeps the register form and corrects the bit number, so the
| encoding stays 4 bytes and only the extension word moves, 0005 -> 000d.

	FRM_SR	=	12		| after the 12-byte save: saved SR (word)
	FRM_PC	=	14		|                        faulting PC (long)
	FRM_FV	=	18		|                        format/vector word
	NVEC	=	64		| per-vector buckets: the CPU-defined range

	.text
	.globl	nullvect
nullvect:
	tstl	kvp_on
	beqw	Lkvp_pass		| probe off: nothing touched but CCR
	moveml	%d0-%d1/%a0,%sp@-	| 12 bytes -- the only stack change

	moveq	&0,%d0
	movew	%sp@(FRM_FV),%d0
	andiw	&0x0fff,%d0		| format/vector word -> vector offset
	lsrw	&2,%d0			| d0 = vector number
	addql	&1,kvp_n
	movel	%d0,kvp_last_vec
	movel	%sp@(FRM_PC),kvp_last_pc

	movew	%sp@(FRM_SR),%d1	| saved SR: S bit tells where it came from
	btst	&13,%d1			| S is SR bit 13.  The movew above left the SR in
					| d1's LOW WORD, and a btst on a data register is a
					| long operand with the bit number mod 32 -- so the
					| bit number here must be 13, not the 5 that reads
					| the S bit out of the SR's HIGH BYTE in memory.
	bnes	Lkvp_super
	addql	&1,kvp_user_n
	bras	Lkvp_bucket
Lkvp_super:
	addql	&1,kvp_super_n

Lkvp_bucket:
	cmpiw	&NVEC,%d0
	bccs	Lkvp_over		| >= 64: trap/user vectors, one shared bucket
	lsll	&2,%d0
	leal	kvp_vec,%a0
	addal	%d0,%a0
	addql	&1,%a0@
	bras	Lkvp_out
Lkvp_over:
	addql	&1,kvp_over_n

Lkvp_out:
	moveml	%sp@+,%d0-%d1/%a0	| SP now exactly as the CPU left it
Lkvp_pass:
	jmp	nullvect_orig

	.data
	.globl	kvp_magic
kvp_magic:
	.long	0x4b565021		| "KVP!" -- read this before trusting an address
	.globl	kvp_on
kvp_on:
	.long	1			| 0 = probe out of the path, for a single-boot A/B
	.globl	kvp_n
kvp_n:
	.long	0			| every entry to nullvect
	.globl	kvp_user_n
kvp_user_n:
	.long	0			| ... of which user-mode origin (SR S bit clear)
	.globl	kvp_super_n
kvp_super_n:
	.long	0			| ... of which supervisor origin
	.globl	kvp_over_n
kvp_over_n:
	.long	0			| vector >= 64, not bucketed individually
	.globl	kvp_last_vec
kvp_last_vec:
	.long	0			| last vector number seen
	.globl	kvp_last_pc
kvp_last_pc:
	.long	0			| last faulting PC
	.globl	kvp_vec
kvp_vec:
	.space	NVEC*4,0		| per-vector counters, index = vector number
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
