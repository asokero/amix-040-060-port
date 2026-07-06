| segu_swap_dbg.s -- ISSUE-7 swap-round-trip probe (dbg build only).
|
| PREEMPT5 + UTRAP bracketing proved: curproc->u_procp is OK at every user-trap ENTRY but
| 0 by the trap-return preempt call (u_trap_orig+0x104), deterministically for one proc.
| Prime hypothesis: the proc sleeps mid-trap, its u-area is swapped OUT (swapoutub ->
| segu_softunload) and back IN (swapinub -> segu_softload), and softload's restore loses
| u_procp (offset 0x730 in page 0) -- a swap-offset/page-content bug analogous to the just-
| fixed swap_xlate x2048.  These wrappers read u_procp via the STABLE p_segu kvsegu window
| (proc@252 + 0x730):
|   swapoutub ENTRY:  log (proc, p_segu, u_procp-before)   -- expect nonzero
|   swapinub  EXIT:   log (proc, p_segu, u_procp-after)    -- if 0 => softload restore bug
| If NEITHER fires for the crashing proc before the panic => the zeroing is NOT swap (some
| direct write in the trap path).  Both swapinub/swapoutub are GLOBAL T -> --weaken + _orig.
| Args: swapoutub(proc)@fp@(8), swapinub(proc)@fp@(8).  Guards: proc nonzero+even, p_segu in
| kvsegu [0x48440000,0x48480000).  cmn_err safe (process context).  Cap 16 each.  Preserve
| the callees' return (d0/a0) across the swapinub log.

	.text
| ---- swapoutub: log u_procp BEFORE the swap-out ----
	.globl	swapoutub
swapoutub:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	Lsso_n,%d0
	cmpil	&16,%d0
	bccw	Lsso_call
	moveal	%fp@(8),%a2		| proc
	movel	%a2,%d0
	beqw	Lsso_call
	btst	&0,%d0
	bnew	Lsso_call
	movel	%a2@(252),%d0		| p_segu
	beqw	Lsso_call
	andil	&3,%d0
	bnew	Lsso_call
	movel	%a2@(252),%d2
	cmpil	&0x48440000,%d2
	bcsw	Lsso_call
	cmpil	&0x48480000,%d2
	bccw	Lsso_call
	moveal	%d2,%a0
	movel	%a0@(0x730),%d1		| u_procp before swap-out
	movel	Lsso_n,%d0
	addql	&1,%d0
	movel	%d0,Lsso_n
	movel	%d1,%sp@-		| u_procp-before
	movel	%d2,%sp@-		| p_segu
	movel	%a2,%sp@-		| proc
	pea	Lsso_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lsso_call:
	movel	%fp@(8),%sp@-		| proc
	jsr	swapoutub_orig
	addqw	&4,%sp
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	rts

| ---- swapinub: log u_procp AFTER the swap-in ----
	.globl	swapinub
swapinub:
	linkw	%fp,&0
	moveml	%d2/%d3/%a2,%sp@-
	movel	%fp@(8),%sp@-		| proc
	jsr	swapinub_orig
	addqw	&4,%sp
	movel	%d0,%d3			| stash return value
	movel	Lssi_n,%d0
	cmpil	&16,%d0
	bccw	Lssi_ret
	moveal	%fp@(8),%a2		| proc
	movel	%a2,%d0
	beqw	Lssi_ret
	btst	&0,%d0
	bnew	Lssi_ret
	movel	%a2@(252),%d0		| p_segu
	beqw	Lssi_ret
	andil	&3,%d0
	bnew	Lssi_ret
	movel	%a2@(252),%d2
	cmpil	&0x48440000,%d2
	bcsw	Lssi_ret
	cmpil	&0x48480000,%d2
	bccw	Lssi_ret
	moveal	%d2,%a0
	movel	%a0@(0x730),%d1		| u_procp after swap-in
	movel	Lssi_n,%d0
	addql	&1,%d0
	movel	%d0,Lssi_n
	movel	%d1,%sp@-		| u_procp-after
	movel	%d2,%sp@-		| p_segu
	movel	%a2,%sp@-		| proc
	pea	Lssi_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lssi_ret:
	movel	%d3,%d0			| restore return value (d0 and a0)
	moveal	%d3,%a0
	moveml	%sp@+,%d2/%d3/%a2
	unlk	%fp
	rts


| ---- segu_softunload: minimal "called" marker (Codex-recommended confirmation) ----
| Codex + disasm proved segu_softunload (0xaa870) finds u-area pages via p_ubptbl and SKIPS
| the VOP_PUTPAGE when the entry is invalid; PREEMPT5 proved p_ubptbl==0 on the 040 -> it
| skips ALL pages -> the u-area is never written to swap -> segu_softload later restores
| stale/zero -> u_procp=0.  This marker confirms segu_softunload is actually EXERCISED on
| the crash path (the swapinub/swapoutub probe fired 0 times -> softunload must be reached
| via segu_fault, 0xaa314, not the swap daemon).  If DBG SOFTUNLOAD appears before the
| panic, the root cause is confirmed and the fix (page source su_swaddr->swap_xlate->
| page_find, like segu_softload/segu_get, instead of p_ubptbl) follows.  static t ->
| --globalize + _orig + --weaken.  Tail-call (args re-read from stack).  Cap 16.
	.globl	segu_softunload
segu_softunload:
	linkw	%fp,&0
	movel	Lssu_n,%d0
	cmpil	&16,%d0
	bccw	Lssu_call
	addql	&1,%d0
	movel	%d0,Lssu_n
	movel	%fp@(20),%sp@-		| slot index
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| va base
	pea	Lssu_smsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lssu_call:
	unlk	%fp
	jmp	segu_softunload_orig
	nop				| pad .text to a multiple of 4 (relink contiguity)

	.data
	.even
Lsso_n:
	.long	0
Lssi_n:
	.long	0
Lsso_msg:
	.asciz	"DBG SWAPOUTUB proc=%x psegu=%x uprocp_before=%x"
	.even
Lssi_msg:
	.asciz	"DBG SWAPINUB proc=%x psegu=%x uprocp_after=%x"
	.even
Lssu_n:
	.long	0
Lssu_smsg:
	.asciz	"DBG SOFTUNLOAD called va=%x len=%x slotidx=%x"
	.even
