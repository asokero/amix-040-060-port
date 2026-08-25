| kvecdisp040.s -- BLIZZARD F4 round 6: decide the arithmetic contradiction attempt 5 left
| behind, by reading the vector table from the side of it that ran.  (2026-08-25)
|
| Registered in docs/060-F4-M2-ATT6-PREREG-260825.md 2.1-2.5, 3.1-3.2 and Table K, BEFORE
| this file existed.  Read that document first; this comment does not restate its tables.
|
| THE CONTRADICTION.  Every vector in this kernel that has no dedicated handler -- 237 of
| the 256 entries in M68Kvec, INCLUDING vector 2 (access fault) and vector 32 (TRAP #0, the
| syscall gate) -- points at `nullvect`.  `nullvect` is not a SIGSYS catch-all: it is the
| shared trap entry stub, and its only route onward for a user-mode exception is
|
|     M68Kvec[v] -> nullvect (the kvecprobe wrapper) -> nullvect_orig -> utraps
|                -> srg_utraps -> u_trap
|
| with `u_trap`, `srg_utraps` and `k_trap` each having EXACTLY ONE reference in the whole
| image.  The wrapper increments kvp_n BEFORE jumping on, so `kvp_n >= srg_ut_n` is an
| invariant of the link, not an expectation.
|
| Attempt 5 boot 1 measured kvp_on = 1, kvp_n = 3 at 12:58:02 against srg_ut_n = 360 read
| FIVE SECONDS EARLIER, rising to 1270 by 13:04:15.  A function reachable only by passing a
| counter ran at least 1267 times more than the counter says it was passed.  Boot 3b, same
| artifact, same disk, obeyed the invariant exactly (42,400 >= 42,392).
|
| WHERE THIS HOOKS, AND WHY NOT ONE STEP EARLIER.  The obvious place is in front of
| `nullvect`.  It is also the one hook in this campaign whose failure costs the whole
| 15-minute window, because every exception in the machine goes through it before anything
| else does.  Everything the contradiction needs is visible one step further in, at
| `srg_utraps` -- WHICH IS THE SIDE THAT RAN 1270 TIMES.  So the R_68K_32 at .text 0x11f0 is
| retargeted from `srg_utraps` to `kvd_utraps` (src/patch_kvecdisp.py), and this unit
| tail-jumps to `srg_utraps` with the stack byte-identical.
|
| THE FRAME, RE-DERIVED FROM THE BINARY rather than inherited.  src/srgtrap.s:98-102
| documents these offsets 60 bytes too low and its srt_vec / srt_pc / srt_d0 slots therefore
| do not hold what their names say (no result in this campaign rests on them).  The count
| comes from `nullvect_orig`'s own prologue: `moveml %d0-%fp,%sp@-` with mask 0xfffe is
| d0-d7/a0-a6 = 15 registers = 60 bytes, and its own `btst #5,%sp@(60)` confirms it.  Then
| `utraps` pushes the USP and the `jsr` pushes a return address.  So at entry here:
|
|     %sp@(0)             jsr return address (0x11f4)
|     %sp@(4)             the USP utraps pushed
|     %sp@(8) .. %sp@(67) nullvect_orig's 60 saved registers, d0-d7 then a0-a6
|     %sp@(68)            frame SR (word)
|     %sp@(70)            frame PC (long)
|     %sp@(74)            frame format/vector (word)
|
| and every offset below is that plus the 28 bytes this unit saves.
|
| THREE SELF-CHECKS, because a wrong offset returns a plausible number instead of failing:
|   kvd_f_sr & 0x2000 == 0    utraps is the USER arm by construction; S must be clear.
|   kvd_f_usp == kvd_f_nowusp the USP utraps pushed must equal %usp read now.
|   kvd_f_vbr == kvd_f_tabaddr VBR must be &M68Kvec.  If it is not, the CPU is dispatching
|                             through a table this kernel does not maintain, which is a
|                             larger finding than anything else in the round.
| If any fails, this block's readings are VOID, not negative.
|
| THE TWIN COUNTER, and why it is 8 KiB away.  kvd_n and kvfar_n are incremented by ADJACENT
| INSTRUCTIONS and live in different 4 KiB pages of .data by construction.  No ordering of
| instructions can make one store land and the other not.  DTT0 = 0x003FC060 maps logical
| 0-1 GB cache-inhibited (src/pstart040.s:326) and the kernel is loaded at 0x08000000, so
| BOTH stores bypass the data cache and go to the bus: a divergence cannot be a stale line,
| a lost writeback or an eviction.  That is the control for "kvp_n's store stopped landing".
|
| WHAT THE cinvl PAIRS ARE AND ARE NOT.  Because of that same DTT0 window, M68Kvec is read
| cache-inhibited, so `cinvl dc` before a re-read CANNOT change the answer.  kvd_a_e2c and
| kvd_a_e32c are therefore NOT a coherency test -- they are a check of the DTT0 premise
| itself, registered as such in the pre-registration 2.5.  A difference means the MMU is not
| doing what pstart040.s says it does.
|
| NOTHING HERE DEREFERENCES A USER ADDRESS.  Every read is kernel memory: this trap's own
| frame, M68Kvec, and three counters in the base link.
|
| EVERYTHING IS HEX.  A kvd_* slot reading ffffffff means NOT APPLICABLE, not zero.
| kvd_f_vec holding ffffffff is also what says the first-entry body has not run yet, and
| kvd_a_i holding ffffffff is what says no differing entry has been recorded -- a vector
| number and a table index can never legitimately read ffffffff.
|
| 040/060 ops as .word, the house idiom: movec %vbr,%d2 = 0x4e7a,0x2801;
| cinvl dc,(a0) = 0xf448 (the a0 form: bits 2-0 select the address register).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c kvecdisp040.s -o build/kvecdisp040.o
| Wire:     src/patch_kvecdisp.py (relocation retarget).  Externals: srg_utraps, M68Kvec,
|           nullvect, kvp_n, kvp_on, srg_ut_n.
| ============================================================================

	FRM_USP	=	32		| after the 28-byte save: the USP utraps pushed
	FRM_SR	=	96		|                        frame SR (word)
	FRM_PC	=	98		|                        frame PC (long)
	FRM_FV	=	102		|                        frame format/vector (word)
	NVEC	=	256		| M68Kvec entries -- the whole CPU-defined table

	.text
	.globl	kvd_utraps
kvd_utraps:
	tstl	kvd_on
	beqw	Lkvd_pass		| census off: nothing touched but CCR
	moveml	%d0-%d3/%a0-%a2,%sp@-	| 28 bytes -- the only stack change

| ---------------------------------------------------------------- the twin counters
| These two instructions are the whole of the lost-write control.  Keep them adjacent.
	addql	&1,kvd_n
	addql	&1,kvfar_n		| same increment, >= 8 KiB away, different page

| ---------------------------------------------------------------- every entry: the LAST block
	moveq	&0,%d0
	movew	%sp@(FRM_FV),%d0
	movel	%d0,kvd_l_fv
	andiw	&0x0fff,%d0		| format/vector word -> vector offset
	lsrw	&2,%d0			| d0 = vector NUMBER
	movel	%d0,kvd_l_vec
	movel	%sp@(FRM_PC),kvd_l_pc
	moveq	&0,%d1
	movew	%sp@(FRM_SR),%d1
	movel	%d1,kvd_l_sr

| ---------------------------------------------------------------- the FIRST entry, once
| kvd_f_vec is its own have-flag: a vector number cannot legitimately read ffffffff.
	moveq	&-1,%d2
	cmpl	kvd_f_vec,%d2
	bnew	Lkvd_audq
	movel	%d1,kvd_f_sr		| self-check 1: S (bit 13) must be CLEAR
	movel	%sp@(FRM_PC),kvd_f_pc
	movel	kvd_l_fv,kvd_f_fv
	movel	%d0,kvd_f_vec
	movel	%sp@(FRM_USP),kvd_f_usp	| self-check 2: must equal the next slot
	movel	%usp,%a0
	movel	%a0,kvd_f_nowusp
	.word	0x4e7a,0x2801		| movec %vbr,%d2
	movel	%d2,kvd_f_vbr		| self-check 3: must equal the next slot
	lea	M68Kvec,%a0
	movel	%a0,kvd_f_tabaddr
	lea	nullvect,%a1
	movel	%a1,kvd_f_nullvect
| the table entry for the arriving vector, and the same entry forced from RAM
	movel	%d0,%d1
	cmpil	&NVEC,%d1
	bccw	Lkvd_audq		| >= 256: no slot in the table to read
	lsll	&2,%d1
	addal	%d1,%a0			| a0 = &M68Kvec[vec]
	movel	%a0@,kvd_f_e_vec
	.word	0xf448			| cinvl dc,(a0)
	nop
	movel	%a0@,kvd_f_e_vec_c

| ---------------------------------------------------------------- should we audit?
| Every 256th entry, and ALWAYS on an entry where the twin counters have diverged.
Lkvd_audq:
	movel	kvd_n,%d0
	cmpl	kvfar_n,%d0
	bnew	Lkvd_split
	movel	%d0,%d1
	andil	&0xff,%d1
	cmpil	&1,%d1
	beqw	Lkvd_audit
	braw	Lkvd_out

Lkvd_split:
	addql	&1,kvd_split_n
	moveq	&-1,%d2
	cmpl	kvd_split_first,%d2
	bnew	Lkvd_audit		| the first split is already recorded
	movel	%d0,kvd_split_first

| ---------------------------------------------------------------- the audit
Lkvd_audit:
	addql	&1,kvd_aud_n
	movel	kvd_n,kvd_a_at
	.word	0x4e7a,0x2801		| movec %vbr,%d2
	movel	%d2,kvd_a_vbr

	lea	M68Kvec,%a1
	lea	%a1@(8),%a0		| vector 2 -- ACCESS FAULT
	movel	%a0@,kvd_a_e2
	.word	0xf448			| cinvl dc,(a0)
	nop
	movel	%a0@,kvd_a_e2c
	lea	%a1@(128),%a0		| vector 32 -- TRAP #0, the syscall gate
	movel	%a0@,kvd_a_e32
	.word	0xf448			| cinvl dc,(a0)
	nop
	movel	%a0@,kvd_a_e32c
	movel	%a1@(44),kvd_a_e11	| vector 11 -- fpsp_vec11, a NON-nullvect control

| fold all 256 entries and count the ones that still name &nullvect (static value: 237)
	lea	nullvect,%a2
	moveal	%a1,%a0
	moveq	&0,%d0			| the fold
	moveq	&0,%d1			| entries equal to &nullvect
	movel	&NVEC,%d2
Lkvd_fold:
	movel	%a0@+,%d3
	eorl	%d3,%d0
	cmpal	%d3,%a2
	bnes	Lkvd_foldn
	addql	&1,%d1
Lkvd_foldn:
	subql	&1,%d2
	bnes	Lkvd_fold
	movel	%d0,kvd_a_sum
	movel	%d1,kvd_a_nvcnt

| the FIRST audit takes the reference fold and the snapshot; later audits compare
	tstl	kvd_stamp
	bnew	Lkvd_cmp
	movel	%d0,kvd_a_sum0
	movel	&0x41554421,kvd_stamp	| "AUD!" -- silence must not look like a null result
	moveal	%a1,%a0
	lea	kvd_snap,%a1
	movel	&NVEC,%d2
Lkvd_snap:
	movel	%a0@+,%a1@+
	subql	&1,%d2
	bnes	Lkvd_snap
	braw	Lkvd_smpl

Lkvd_cmp:
	cmpl	kvd_a_sum0,%d0
	beqw	Lkvd_smpl
	addql	&1,kvd_a_chg_n
	moveq	&-1,%d3
	cmpl	kvd_a_i,%d3
	bnew	Lkvd_smpl		| the first differing entry is already recorded
	moveal	%a1,%a0
	lea	kvd_snap,%a1
	moveq	&0,%d1			| index
Lkvd_scan:
	movel	%a0@+,%d3
	cmpl	%a1@+,%d3
	bnes	Lkvd_found
	addql	&1,%d1
	cmpil	&NVEC,%d1
	bnes	Lkvd_scan
	braw	Lkvd_smpl		| the fold moved but no entry did: report it as such
Lkvd_found:
	movel	%d1,kvd_a_i
	movel	%a1@(-4),kvd_a_was	| the compare already advanced a1 past it
	movel	%d3,kvd_a_now

| the two counters the invariant is about, sampled by ONE instruction stream at ONE instant
| rather than by two console reads five seconds apart
Lkvd_smpl:
	movel	kvp_n,kvd_a_kvpn
	movel	kvp_on,kvd_a_kvpon
	movel	srg_ut_n,kvd_a_srgn

Lkvd_out:
	moveml	%sp@+,%d0-%d3/%a0-%a2
| The stack is exactly as utraps left it, so srg_utraps' own offsets and u_trap's %fp+8 are
| unchanged and its rts still returns to 0x11f4.
Lkvd_pass:
	jmp	srg_utraps
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it returns a
| plausible number from whatever now lives there.  Every address for this block comes from
| tools/status-facts.sh against the artifact actually booted, at the load base actually
| observed; NEVER from an on-box nlist of /stand/unix, which is a different kernel because
| the one under test is installed into the BOOT SLICE.
	.globl	kvd_magic
kvd_magic:
	.long	0x4b564421		| "KVD!"
	.globl	kvd_on
kvd_on:
	.long	1			| 0 = census out of the path, for a single-boot A/B
	.globl	kvd_n
kvd_n:
	.long	0			| entries to this edge -- the twin of srg_ut_n
	.globl	kvd_split_n
kvd_split_n:
	.long	0			| audits at which kvd_n != kvfar_n
	.globl	kvd_split_first
kvd_split_first:
	.long	0xffffffff		| kvd_n at the first split
	.globl	kvd_aud_n
kvd_aud_n:
	.long	0
	.globl	kvd_stamp
kvd_stamp:
	.long	0			| "AUD!" once the first audit ran

| ---- the FIRST entry, latched once ------------------------------------------------------
	.globl	kvd_f_sr
kvd_f_sr:
	.long	0xffffffff
	.globl	kvd_f_pc
kvd_f_pc:
	.long	0xffffffff
	.globl	kvd_f_fv
kvd_f_fv:
	.long	0xffffffff
	.globl	kvd_f_vec
kvd_f_vec:
	.long	0xffffffff		| also the have-flag: a vector number is never ffffffff
	.globl	kvd_f_usp
kvd_f_usp:
	.long	0xffffffff
	.globl	kvd_f_nowusp
kvd_f_nowusp:
	.long	0xffffffff
	.globl	kvd_f_vbr
kvd_f_vbr:
	.long	0xffffffff
	.globl	kvd_f_tabaddr
kvd_f_tabaddr:
	.long	0xffffffff
	.globl	kvd_f_nullvect
kvd_f_nullvect:
	.long	0xffffffff
	.globl	kvd_f_e_vec
kvd_f_e_vec:
	.long	0xffffffff
	.globl	kvd_f_e_vec_c
kvd_f_e_vec_c:
	.long	0xffffffff

| ---- the LAST entry, rewritten every time -----------------------------------------------
	.globl	kvd_l_vec
kvd_l_vec:
	.long	0xffffffff
	.globl	kvd_l_pc
kvd_l_pc:
	.long	0xffffffff
	.globl	kvd_l_fv
kvd_l_fv:
	.long	0xffffffff
	.globl	kvd_l_sr
kvd_l_sr:
	.long	0xffffffff

| ---- the AUDIT, rewritten every 256th entry and forced on any split ----------------------
	.globl	kvd_a_at
kvd_a_at:
	.long	0xffffffff		| kvd_n at the last audit -- how fresh the rest is
	.globl	kvd_a_vbr
kvd_a_vbr:
	.long	0xffffffff
	.globl	kvd_a_e2
kvd_a_e2:
	.long	0xffffffff		| M68Kvec[2]  -- access fault
	.globl	kvd_a_e2c
kvd_a_e2c:
	.long	0xffffffff		| the same after cinvl dc -- the DTT0 premise check
	.globl	kvd_a_e32
kvd_a_e32:
	.long	0xffffffff		| M68Kvec[32] -- TRAP #0, the syscall gate
	.globl	kvd_a_e32c
kvd_a_e32c:
	.long	0xffffffff
	.globl	kvd_a_e11
kvd_a_e11:
	.long	0xffffffff		| M68Kvec[11] -- fpsp_vec11, a NON-nullvect control
	.globl	kvd_a_nvcnt
kvd_a_nvcnt:
	.long	0xffffffff		| entries equal to &nullvect -- static value 237
	.globl	kvd_a_sum
kvd_a_sum:
	.long	0xffffffff		| XOR fold of all 256 entries
	.globl	kvd_a_sum0
kvd_a_sum0:
	.long	0xffffffff		| the same fold at the FIRST audit
	.globl	kvd_a_chg_n
kvd_a_chg_n:
	.long	0			| audits whose fold differs from kvd_a_sum0
	.globl	kvd_a_i
kvd_a_i:
	.long	0xffffffff		| index of the first entry differing from the snapshot
	.globl	kvd_a_was
kvd_a_was:
	.long	0xffffffff
	.globl	kvd_a_now
kvd_a_now:
	.long	0xffffffff
	.globl	kvd_a_kvpn
kvd_a_kvpn:
	.long	0xffffffff		| kvp_n     sampled in the same breath
	.globl	kvd_a_kvpon
kvd_a_kvpon:
	.long	0xffffffff		| kvp_on    sampled in the same breath
	.globl	kvd_a_srgn
kvd_a_srgn:
	.long	0xffffffff		| srg_ut_n  sampled in the same breath

| ---- the table as it read at the FIRST audit --------------------------------------------
| Last member of the block on purpose: the named counters above stay contiguous, so
| status-facts.sh still offers them as one kpeek.
	.globl	kvd_snap
kvd_snap:
	.space	NVEC*4,0

| ---- the gap, and the twin counter on the far side of it --------------------------------
| Unnamed by design: a labelled pad would be picked up as a member of one of these blocks by
| tools/status-facts.sh and would break the contiguity report for no benefit.  8192 bytes
| guarantees at least two 4 KiB page boundaries between kvd_n and kvfar_n whatever the
| link-time alignment turns out to be.
	.space	8192,0

	.globl	kvfar_magic
kvfar_magic:
	.long	0x4b564621		| "KVF!"
	.globl	kvfar_n
kvfar_n:
	.long	0			| incremented by the instruction after kvd_n's increment
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
