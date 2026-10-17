| isp060_glue.s -- the AMIX side of the M68060 Integer Support Package (DRIVER-LINE-9, 2026-10-06;
| opt-in, relink-040-isp060.sh).  Concatenated after isp060_head.s + 060sp/isp.S by build-isp060.sh.
|
| WHAT IT ADDS.  Vector 61 (unimplemented integer instruction) on the 68060 already reaches
| isp61_vec, the measured fast path for the 64-bit multiplies the installed userland uses.  Every
| form isp61 declines used to end at nullvect, i.e. the process died.  relink-040-isp060.sh
| retargets that one decline (isp61's `jmp nullvect`) to isp060_unimp below, so the declined forms
| reach Motorola's package instead: divs.l/divu.l with a 64-bit dividend (zero divide -> vector 5,
| as on a 68030), the multiply forms isp61 does not decode, movep, cmp2/chk2, cas2 and misaligned
| cas.  isp61 stays first: it is the path measured on hardware for cc1 and wolf3d.
|
| CALL-OUT POLICY, the FPSP's (src/fpsp060_glue.s) and NetBSD's: every exception the package
| signals -- chk, divide by zero, trace, access -- arrives here with the 060 frame the CPU would
| have pushed for that exception, and goes to nullvect, which dispatches on the frame's own vector
| to the stock signal policy.  M68Kvec[5], [6] and [9] are nullvect in this kernel, so this is
| exactly where a 68030's hardware exception would have gone.  A completed emulation leaves
| through Lci_done, which rebuilds the ureturn state for a user frame as Lco_done does.
|
| CAS/CAS2.  The package emulates both itself once the OS has "locked" the operand pages; its
| locked sequence uses moves under masked interrupts and cannot take a page fault.  AMIX gives
| this glue no way to pin a user page here, so Lci_lock REFUSES: the package then terminates the
| instruction through its own access-error exit, and the process gets the access-fault signal
| instead of today's death at nullvect.  No installed binary uses cas2 or a misaligned cas
| (test-tools/scan060.py census); a real lock (as_fault F_SOFTLOCK) is follow-up work.
|
| Assembled by m68k-linux-gnu-gcc (GNU syntax, `#` immediates), like fpsp060_glue.s.

	.text

	I60_SR	=	0x4		| the package's link.w a6 frame keeps the stacked SR here (isp.s EXC_ISR)
	U_AR0	=	0x40000864	| u.u_ar0, the slot fpsp060_glue.s and isp61_060.s use

| ============================================================================
| isp061 decline entry.  Reached from isp61_vec's one `jmp nullvect`, retargeted by
| src/patch_isp060_hook.py, with the RAW frame and every register exactly as the CPU left them.
| Anything that is not a user-origin vector-61 format-0 frame on a 68060 goes where it always went.
| ============================================================================
	.globl	isp060_unimp
isp060_unimp:
	cmpil	#60,cputype		| CCR only, no register touched
	bnes	Li_stock
	btst	#5,%sp@			| supervisor origin: a kernel 64-bit op is a defect, keep
	bnes	Li_stock		| the stock outcome rather than emulate it quietly
	cmpiw	#0x00f4,%sp@(6)		| exactly a vector-61 format-0 frame?
	bnes	Li_stock
	movel	%d0,%sp@-
	movel	sup_cacr,%d0		| supervisor cache mode, as isp61 and the FPSP entries do
	.word	0x4e7b,0x0002		| movec %d0,%cacr
	movel	%sp@+,%d0
	addql	#1,i60_entry_n
	jmp	isp060_top+128+0x00	| _060_isp_unimp
Li_stock:
	addql	#1,i60_stock_n
	jmp	nullvect

| ---- exception exits: a valid 060 frame for that vector is on (sp) ----
| Motorola's skeleton (iskeletn.s) checks for a pending trace before chk and divide by zero and
| turns the frame into a trace frame; nullvect would deliver either, so only the vector differs.
Lci_chk:
	addql	#1,i60_chk_n
	movel	#0,i60_last_co
	bras	Li_tracechk
Lci_divbyzero:
	addql	#1,i60_dbz_n
	movel	#1,i60_last_co
Li_tracechk:
	tstb	%sp@			| T1 set in the stacked SR: trace pending
	bpls	Li_exc
	moveb	#0x24,%sp@(7)		| vector offset := trace
Lci_trace:
	addql	#1,i60_trace_n
Li_exc:
	addql	#1,i60_real_n
	jmp	nullvect
Lci_access:
	addql	#1,i60_access_n
	movel	#3,i60_last_co
	addql	#1,i60_real_n
	jmp	nullvect

| ---- _060_isp_done: the emulation completed and the frame's PC is advanced ----
| As src/fpsp060_glue.s Lco_done: a bare rte would skip qrun, the class trap return, signals and
| the user CACR restore, so rebuild the state nullvect->u_trap leaves at ureturn without calling
| u_trap.  Supervisor origin cannot reach the package (isp060_unimp declines it) and is rte'd.
Lci_done:
	addql	#1,i60_done_n
	movel	#4,i60_last_co
	btst	#5,%sp@
	bnes	Lid_super
	moveml	%d0-%fp,%sp@-
	movel	sup_cacr,%d0
	.word	0x4e7b,0x0002
	movel	%usp,%a0
	movel	%a0,%sp@-
	movel	%sp,U_AR0
	moveal	%sp@+,%a0
	movel	%a0,%usp
	jmp	ureturn
Lid_super:
	addql	#1,i60_superdone_n
	rte

| ---- cas/cas2: the package's own emulation, reached only after Lci_lock succeeds ----
Lci_cas:
	addql	#1,i60_cas_n
	bral	isp060_top+128+0x08	| _060_isp_cas
Lci_cas2:
	addql	#1,i60_cas2_n
	bral	isp060_top+128+0x10	| _060_isp_cas2

| ---- page lock/unlock: refused, see the header ----
Lci_lock:
	addql	#1,i60_lockref_n
	moveq	#-1,%d0			| nonzero = failure: the package terminates the instruction
	rts
Lci_unlock:
	moveq	#0,%d0
	rts

| ---- Motorola-reserved slots: an invariant failure, as in the FPSP glue ----
Lci_reserved:
	addql	#1,i60_reserved_n
	pea	Liresmsg
	jsr	panic
Liresmsg:
	.asciz	"68060 ISP called a reserved call-out slot"
	.balign	4

| ============================================================================
| MEMORY CALL-OUTS -- the same code as src/fpsp060_glue.s's, with its own counters.  The ISP's
| frame keeps the stacked SR at the same a6 offset as the FPSP's (Motorola's os.s serves both).
| ============================================================================

| ---- block read: a0 = user src, a1 = supervisor dst, d0 = count -------------------------
Lci_imem_read:
Lci_dmem_read:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Limr_super
	movel	%d0,%sp@-		| count
	movel	%a1,%sp@-		| kernel dst
	movel	%a0,%sp@-		| user src
	jsr	copyin
	lea	%sp@(12),%sp
	movel	%d0,%d1			| copyin: 0 = success, and that is d1's contract too
	beqs	Limr_out
	addql	#1,i60_memfail_n
Limr_out:
	rts
Limr_super:
	tstl	%d0			| a zero count would wrap the do-while below
	beqs	Limr_sdone
Limr_sloop:
	moveb	%a0@+,%a1@+
	subql	#1,%d0
	bnes	Limr_sloop
Limr_sdone:
	moveq	#0,%d1
	rts

| ---- block write: a0 = supervisor src, a1 = user dst, d0 = count ------------------------
Lci_dmem_write:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Limw_super
	movel	%d0,%sp@-		| count
	movel	%a1,%sp@-		| user dst
	movel	%a0,%sp@-		| kernel src
	jsr	copyout
	lea	%sp@(12),%sp
	movel	%d0,%d1
	beqs	Limw_out
	addql	#1,i60_memfail_n
Limw_out:
	rts
Limw_super:
	tstl	%d0
	beqs	Limw_sdone
Limw_sloop:
	moveb	%a0@+,%a1@+
	subql	#1,%d0
	bnes	Limw_sloop
Limw_sdone:
	moveq	#0,%d1
	rts

| ---- scalar reads: a0 = user src -> d0 = right-justified data ---------------------------
| The user side stages into a four-byte supervisor landing area on the stack and copies into it,
| so the read is subject to the same address validation and fault handling as any other copyin.
| On failure d0 is left ZERO rather than partially filled: a package site that does check d1 gets
| its failure, and one that does not gets a defined value instead of a stale register.

Lci_imem_rw:
Lci_dmem_rw:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Lirw_super
	subql	#4,%sp			| landing area
	pea	2			| count
	pea	%sp@(4)			| kernel dst = landing area
	movel	%a0,%sp@-		| user src
	jsr	copyin
	lea	%sp@(12),%sp		| sp -> landing area
	movel	%d0,%d1
	moveq	#0,%d0
	tstl	%d1
	bnes	Lirw_bad
	movew	%sp@,%d0		| zero-extended word
	addql	#4,%sp
	rts
Lirw_bad:
	addql	#1,i60_memfail_n
	addql	#4,%sp
	rts
Lirw_super:
	moveq	#0,%d1
	moveq	#0,%d0
	movew	%a0@,%d0
	rts

Lci_imem_rl:
Lci_dmem_rl:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Lirl_super
	subql	#4,%sp
	pea	4
	pea	%sp@(4)
	movel	%a0,%sp@-
	jsr	copyin
	lea	%sp@(12),%sp
	movel	%d0,%d1
	moveq	#0,%d0
	tstl	%d1
	bnes	Lirl_bad
	movel	%sp@,%d0
	addql	#4,%sp
	rts
Lirl_bad:
	addql	#1,i60_memfail_n
	addql	#4,%sp
	rts
Lirl_super:
	moveq	#0,%d1
	movel	%a0@,%d0
	rts

Lci_dmem_rb:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Lirb_super
	subql	#4,%sp
	pea	1
	pea	%sp@(4)
	movel	%a0,%sp@-
	jsr	copyin
	lea	%sp@(12),%sp
	movel	%d0,%d1
	moveq	#0,%d0
	tstl	%d1
	bnes	Lirb_bad
	moveb	%sp@,%d0		| zero-extended byte
	addql	#4,%sp
	rts
Lirb_bad:
	addql	#1,i60_memfail_n
	addql	#4,%sp
	rts
Lirb_super:
	moveq	#0,%d1
	moveq	#0,%d0
	moveb	%a0@,%d0
	rts

| ---- scalar writes: a0 = user dst, d0 = data --------------------------------------------
| d0 is an INPUT here, and the package's trampoline preserves d0 across the transfer, so it must
| survive the call-out too.  Pushing d0 does double duty: it is both the saved copy and the
| staging buffer, and because the 68060 is big-endian the byte to write is the pushed longword's
| LAST byte and the word is its last two -- hence the +11 / +10 / +8 source addresses below.

Lci_dmem_wb:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Liwb_super
	movel	%d0,%sp@-		| saved d0 AND the staging buffer
	pea	1			| count
	movel	%a0,%sp@-		| user dst
	pea	%sp@(11)		| kernel src = low byte of the saved d0
	jsr	copyout
	lea	%sp@(12),%sp		| sp -> saved d0
	movel	%d0,%d1
	beqs	Liwb_out
	addql	#1,i60_memfail_n
Liwb_out:
	movel	%sp@+,%d0		| give the package its data register back
	rts
Liwb_super:
	moveq	#0,%d1
	moveb	%d0,%a0@
	rts

Lci_dmem_ww:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Liww_super
	movel	%d0,%sp@-
	pea	2
	movel	%a0,%sp@-
	pea	%sp@(10)		| kernel src = low word of the saved d0
	jsr	copyout
	lea	%sp@(12),%sp
	movel	%d0,%d1
	beqs	Liww_out
	addql	#1,i60_memfail_n
Liww_out:
	movel	%sp@+,%d0
	rts
Liww_super:
	moveq	#0,%d1
	movew	%d0,%a0@
	rts

Lci_dmem_wl:
	addql	#1,i60_mem_n
	btst	#5,%a6@(I60_SR)
	bnes	Liwl_super
	movel	%d0,%sp@-
	pea	4
	movel	%a0,%sp@-
	pea	%sp@(8)			| kernel src = the saved d0 itself
	jsr	copyout
	lea	%sp@(12),%sp
	movel	%d0,%d1
	beqs	Liwl_out
	addql	#1,i60_memfail_n
Liwl_out:
	movel	%sp@+,%d0
	rts
Liwl_super:
	moveq	#0,%d1
	movel	%d0,%a0@
	rts

	.balign	4			| pad .text to a multiple of 4 (text/data must stay contiguous)

	.data
| Counters: .data longs, read with /kpeek; check the magic FIRST.
	.globl	i60_magic
i60_magic:
	.long	0x49533630		| "IS60"
	.globl	i60_entry_n
i60_entry_n:
	.long	0			| isp61 declines handed to the package
	.globl	i60_stock_n
i60_stock_n:
	.long	0			| declines that went to nullvect (not 060 / supervisor / bad frame)
	.globl	i60_done_n
i60_done_n:
	.long	0			| completed emulations
	.globl	i60_real_n
i60_real_n:
	.long	0			| exception exits taken, all classes
	.globl	i60_chk_n
i60_chk_n:
	.long	0			| _060_real_chk (vector 6)
	.globl	i60_dbz_n
i60_dbz_n:
	.long	0			| _060_real_divbyzero (vector 5)
	.globl	i60_trace_n
i60_trace_n:
	.long	0			| _060_real_trace (vector 9), including pending-trace conversions
	.globl	i60_access_n
i60_access_n:
	.long	0			| _060_real_access
	.globl	i60_cas_n
i60_cas_n:
	.long	0
	.globl	i60_cas2_n
i60_cas2_n:
	.long	0
	.globl	i60_lockref_n
i60_lockref_n:
	.long	0			| page locks refused (cas/cas2 terminated)
	.globl	i60_mem_n
i60_mem_n:
	.long	0			| memory call-outs taken
	.globl	i60_memfail_n
i60_memfail_n:
	.long	0			| copyin/copyout failures inside the memory family
	.globl	i60_superdone_n
i60_superdone_n:
	.long	0
	.globl	i60_reserved_n
i60_reserved_n:
	.long	0
	.globl	i60_last_co
i60_last_co:
	.long	0			| table slot id of the last exception/done call-out
	.balign	4
