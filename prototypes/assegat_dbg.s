| assegat_dbg.s -- diagnostic WRAPPER around as_segat (0xadefc, GLOBAL T).
|
| Purpose: decide why init's dynamic interpreter (libc.so.1 @ 0x80800000) faults
| its 2nd page (0x80801000) -> SIGSEGV.  as_fault page-aligns the fault addr and
| calls as_segat(as, addr) to find the containing segment; a NULL return -> as_fault
| returns FC_NOMAP (3) -> SIGSEGV.  This wrapper prints the segment as_segat finds
| (or NULL) + its [base, base+size) bounds for user faults (addr >= 0x80800000).
|   * seg != NULL with base<=0x80801000<base+size  -> the segment COVERS page 1, so
|     the failure is INSIDE segvn_fault (vnode/file demand-paging) -- an fs-getpage gap.
|   * seg == NULL, or base+size == 0x80801000       -> the interpreter segment is too
|     small (only ~1 page) -- an exec interpreter-mapping / sizing bug.
|
| Mechanism (preserves the EXACT original logic -- no reimplementation):
|   objcopy --add-symbol as_segat_orig=.text:0xadefc,function,global  (alias the original)
|   objcopy --weaken-symbol as_segat                                  (so this strong def wins)
|   this file's strong `as_segat` calls `as_segat_orig` (= the unchanged original code).
| as_segat(as@8, addr@12) returns the seg in BOTH d0 and a0 (NULL = 0).  cmn_err
| preserves d2-d7/a2-a6, so a2 (saved seg) and d2 (print counter) survive the call.

	.text
	.globl	as_segat
as_segat:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
| --- call the original as_segat (unchanged code at 0xadefc) ---
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| as
	jsr	as_segat_orig
	addqw	&8,%sp
	moveal	%a0,%a2			| a2 = returned seg (preserved across cmn_err)
| --- gated trace for user faults (addr >= 0x80800000), max 16 ---
	movel	%fp@(12),%d0
	cmpil	&0x80800000,%d0
	bcsw	Lsg_done
	movel	Lsg_n,%d2
	cmpil	&16,%d2
	bccw	Lsg_done
	addql	&1,%d2
	movel	%d2,Lsg_n
	tstl	%a2
	beqw	Lsg_null
	movel	%a2@(8),%sp@-		| seg size
	movel	%a2@(4),%sp@-		| seg base
	movel	%a2,%sp@-		| seg
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| as (which address space is searched)
	pea	Lsg_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
	braw	Lsg_done
Lsg_null:
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| as
	pea	Lsg_nullmsg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
Lsg_done:
	moveal	%a2,%a0			| restore return value (seg) in a0 and d0
	movel	%a2,%d0
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts

| ===========================================================================
| execmap WRAPPER (orig 0x57a4c, GLOBAL T) -- print the args exec passes when it
| maps each ELF LOAD segment, to localize the 1-page interpreter-segment bug.
| execmap(ctx@8, vaddr@12, filesz@16, zfodsz@20, offset@24, prot@28).  If filesz
| here = 0x2d7f4 (libc.so.1's PT_LOAD) the size reaching execmap is CORRECT -> the
| bug is in execmap's own segment installer (VOP_MAP / as_map_reliably / segvn);
| if filesz is small the ELF program-header read (blkatoff / Model B) is wrong.
| Same --add-symbol/--weaken wrapper mechanism as as_segat.
	.globl	execmap
execmap:
	linkw	%fp,&0
	movel	%d2,%sp@-
	movel	Lem_n,%d2
	cmpil	&12,%d2
	bccw	Lem_call
	addql	&1,%d2
	movel	%d2,Lem_n
	movel	%fp@(28),%sp@-		| prot
	movel	%fp@(24),%sp@-		| offset
	movel	%fp@(16),%sp@-		| filesz
	movel	%fp@(12),%sp@-		| vaddr
	pea	Lem_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lem_call:
	movel	%fp@(28),%sp@-		| forward all 6 args unchanged
	movel	%fp@(24),%sp@-
	movel	%fp@(20),%sp@-
	movel	%fp@(16),%sp@-
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	execmap_orig
	lea	%sp@(24),%sp		| d0/a0 = execmap_orig's return (untouched below)
	movel	%sp@+,%d2
	unlk	%fp
	rts

| ===========================================================================
| copyout WRAPPER (orig 0x576, GLOBAL T) -- print src/dst/len/RETVAL for kernel->user
| copies to user space (dst >= 0x80000000).  Critical case: main()'s
| copyout(icode, 0x80800000, szicode) installs proc 1's bootstrap.  If this returns
| NON-ZERO the user-space `moves` faulted and sf_fault recovery fired -> the 040
| fault-during-moves restart is broken (icode never lands -> proc 1 runs a zero page
| -> SIGSEGV).  If it returns 0 but the page is still zero, copyout wrote into the
| wrong MMU context (URP not proc 1's).  copyout reads its args sp-relatively (no
| frame), so the wrapper re-pushes them for copyout_orig.
	.globl	copyout
copyout:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| dst
	movel	%fp@(8),%sp@-		| src  (top -> copyout_orig's sp@(4))
	jsr	copyout_orig
	lea	%sp@(12),%sp
	movel	%d0,%d3			| save retval
| --- capture the URP active during copyout; compare to proc 1's runtime URP (ptload
|     prints urp=7A6C000).  If they DIFFER, copyout wrote into a DIFFERENT address space
|     than proc 1 runs in -> the icode lands in the wrong context (a 040 newproc/context
|     bug), NOT a write-back-replay problem (no supervisor fault fired -- kt7 silent). ---
	.word	0x4e7a			| movec %urp,%d0  (68040 URP = ctrl reg 0x806)
	.word	0x0806
	movel	%d0,Lco_urp
	movel	%fp@(12),%d2		| dst
	cmpil	&0x80000000,%d2
	bcsw	Lco_done
| --- NOTE: the old cpusha + user-space readback `moves` probe was REMOVED.  After the
|     DTT1 fix (S=supervisor-only) user VA 0x80800000 is no longer transparently
|     translated, so an UNPROTECTED supervisor `moves` to it now faults (the page is
|     demand-zero, unmapped at copyout time, and this probe has no onfault recovery) ->
|     kernel bus-error PANIC at copyout+0x44.  The real question (did copyout's own
|     `moves` land the icode?) is answered downstream: whether proc 1 execs init or
|     SIGSEGVs, plus the kt7 hook dumping copyout_orig's (recoverable) fault frame. ---
| --- read copyout's path selector: a0 = *(u+0x730); flag = a0@(140).  Nonzero ->
|     copyout took rcopyout (RFS remote), not lcopyout (local moves) -> misroute. ---
	moveal	u+0x730,%a0
	clrl	%d1
	movew	%a0@(140),%d1
	movel	%d1,Lco_flag
	movel	Lco_n,%d0
	cmpil	&10,%d0
	bccw	Lco_done
	addql	&1,%d0
	movel	%d0,Lco_n
	movel	%fp@(4),%sp@-		| caller return addr (which code calls this copyout)
	movel	Lco_urp,%sp@-		| URP active during copyout (vs proc 1's 70EB000)
	movel	%d3,%sp@-		| retval
	movel	%fp@(12),%sp@-		| dst
	pea	Lco_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lco_done:
	movel	%d3,%d0			| restore retval
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts

| ===========================================================================
| as_map WRAPPER (orig 0xae4f8, GLOBAL T) -- main() does
|   as_map(as=proc->p_as, 0x80800000, szicode, segvn_create, zfod_argsp)
| to install the icode segment, then copyout()s into it -- but NEVER checks as_map's
| return.  If as_map FAILED (segvn_create error / anon), the segment is absent and the
| copyout `moves` faults with as_segat -> NULL (what we now see).  This prints as_map's
| `as`, addr and RETURN for the icode mapping, to tell a silent as_map failure (ret!=0)
| apart from a context/URP mismatch (ret==0 but copyout still faults a different `as`).
	.globl	as_map
as_map:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(24),%sp@-		| argsp
	movel	%fp@(20),%sp@-		| crfp (segvn_create)
	movel	%fp@(16),%sp@-		| size
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| as
	jsr	as_map_orig
	lea	%sp@(20),%sp
	movel	%d0,%d3			| ret
	movel	%fp@(12),%d2		| addr
	cmpil	&0x80800000,%d2
	bnew	Lam_done
	movel	%d3,%sp@-		| ret (0 = success)
	movel	%fp@(16),%sp@-		| size
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| as (== proc->p_as the segment goes into)
	pea	Lam_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lam_done:
	movel	%d3,%d0			| restore as_map's return
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts
	nop				| pad appended .text to keep text/data contiguous

	.data
	.even
Lsg_msg:
	.asciz	"DBG as_segat as=%x addr=%x -> seg=%x base=%x size=%x"
	.even
Lsg_nullmsg:
	.asciz	"DBG as_segat as=%x addr=%x -> seg=NULL (FC_NOMAP)"
	.even
Lsg_n:
	.long	0
	.even
Lem_msg:
	.asciz	"DBG execmap vaddr=%x filesz=%x off=%x prot=%x"
	.even
Lem_n:
	.long	0
	.even
Lco_msg:
	.asciz	"DBG copyout dst=%x ret=%x urp=%x caller=%x"
	.even
Lco_n:
	.long	0
Lco_rb:
	.long	0
Lco_flag:
	.long	0
Lco_urp:
	.long	0
	.even
Lam_msg:
	.asciz	"DBG as_map as=%x addr=%x size=%x ret=%x"
