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
	lea	%sp@(24),%sp		| d0/a0 = execmap_orig's return
| --- DBG (do_reloc 0x66000030 frontier): after loading libc.so.1's DATA segment (vaddr
|     C102E000), dump the GOT slots the runtime linker derefs: C102FE68 (a5+0xdc) and C102FE6C.
|     File values are 0x0002e050 / 0x0002e580 (R_68K_RELATIVE).  The linker hasn't run yet, so a
|     correct COW load reads those file values; if it reads 0x66000030 (the faulting addr) the DATA
|     segment is MISLOADED (page-cache/COW Model B bug) -- otherwise the runtime linker corrupts it
|     (bias/reloc).  Marker 'G' then the two values.  lfuword reads curproc (proc 1) user space.
|     d0/a0 = execmap's return value, saved across the dump (lfuword/serdbg clobber d0/d1/a0/a1). ---
	moveml	%d0/%a0,%sp@-		| save execmap_orig return (errno + seg)
	movel	%fp@(12),%d2
	cmpil	&0xc102e000,%d2
	bnew	Lem_nogot
	pea	0x47			| 'G'
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0xc102fe68,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	&0xc102fe6c,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
Lem_nogot:
	moveml	%sp@+,%d0/%a0		| restore execmap_orig return
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
	.word	0xf4f8			| cpusha bc -- push copyout's (copyback) icode write to RAM so the
					|   DTT0-identity PTE walk + RAM scan below read COHERENT memory, not
					|   stale RAM that misses a still-cached write.
| --- capture the URP active during copyout; compare to proc 1's runtime URP (ptload
|     prints urp=7A6C000).  If they DIFFER, copyout wrote into a DIFFERENT address space
|     than proc 1 runs in -> the icode lands in the wrong context (a 040 newproc/context
|     bug), NOT a write-back-replay problem (no supervisor fault fired -- kt7 silent). ---
	.word	0x4e7a			| movec %urp,%d0  (68040 URP = ctrl reg 0x806)
	.word	0x0806
	movel	%d0,Lco_urp
| --- POST-COPYOUT PTE walk for dst=0x80800000: dump URP + leaf PTE RIGHT AFTER copyout wrote the
|     icode.  Compare to the exece-time leaf PTE (0x07A5D019 -> zero page).  SAME -> copyout wrote
|     to a phys that the PTE never named (stale-ATC / pfn mismatch at fault time); DIFFERENT ->
|     the PTE was remapped (P1 -> fresh zero page) between copyout and exec.  Marker 'p'. ---
	movel	%fp@(12),%d2
	cmpil	&0x80800000,%d2
	bnew	Lco_nopte
	pea	0x70			| 'p' -- post-copyout PTE walk follows
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0x4e7a,0x1806		| movec %urp,%d1
	movel	%d1,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%d1,%a0
	movel	%a0@(0x100),%d2		| root[Aidx 0x40]
	movel	%d2,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	andil	&0xffffff00,%d2
	moveal	%d2,%a0
	movel	%a0@(0x80),%d2		| ptr[Bidx 0x20]
	movel	%d2,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	andil	&0xffffff00,%d2
	moveal	%d2,%a0
	movel	%a0@,%d2		| leaf PTE (Cidx 0)
	movel	%d2,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
| --- read user[0x80800000] via lfuword RIGHT AFTER copyout = the CPU's live ATC view.  If this is
|     0x4FFB0170 (icode) but the exece-time read is 0 -> copyout's fault loaded the ATC with the
|     phys it wrote (P1) while the RAM leaf descriptor named 07A5D000 -> ATC vs RAM-PTE mismatch at
|     fault time, exposed once the ATC is flushed.  Marker 'f'. ---
	pea	0x66			| 'f' -- copyout-time lfuword(0x80800000) follows
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0x80800000,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
| --- SCAN fast RAM (phys 0x07000000..0x08000000, via DTT0 identity, 4KB step) for the icode
|     signature 0x4FFB0170 = where copyout ACTUALLY wrote the icode.  's' + the phys (or FFFFFFFF).
|     == 0x0752E800 (half) -> factor-of-2 (pfn doubled); == 0x07A5D000 -> the walk/read is wrong;
|     elsewhere -> a different mapping bug.  (One-shot via Lco_n cap; copyout dst==0x80800000.) ---
	pea	0x73			| 's' -- icode-phys scan result follows
	jsr	serdbg_mark
	addqw	&4,%sp
| scan CHIP RAM first (0x00000000..0x00200000), then FAST RAM (0x07000000..0x08000000), for the
| icode first long; check every long (step 4) to catch any alignment, report the first match phys.
	movel	&0x00000000,%d2		| chip RAM start
Lsc_c:
	cmpil	&0x00200000,%d2
	bccw	Lsc_fast
	moveal	%d2,%a0
	cmpil	&0x4ffb0170,%a0@
	beqw	Lsc_found
	addil	&0x1000,%d2
	braw	Lsc_c
Lsc_fast:
	movel	&0x07000000,%d2		| fast RAM start (kernel + page tables region .. main fast RAM)
Lsc_f:
	cmpil	&0x09000000,%d2		| extend through 0x08000000.. (AmigaOS ExecBase @0x0800089c)
	bccw	Lsc_none
	moveal	%d2,%a0
	cmpil	&0x4ffb0170,%a0@
	beqw	Lsc_found
	addil	&0x1000,%d2
	braw	Lsc_f
Lsc_found:
	movel	%d2,%sp@-		| phys where the icode was found
	jsr	serdbg_hex
	addqw	&4,%sp
	braw	Lsc_sdone
Lsc_none:
	movel	&0xffffffff,%sp@-	| not found in chip or fast RAM
	jsr	serdbg_hex
	addqw	&4,%sp
Lsc_sdone:
| --- BACKED-RAM test: write 0xDEADBEEF to phys 0x07A5D000 (the PTE's phys) via DTT0 identity, read
|     back.  'b' + readback.  == DEADBEEF -> phys IS backed RAM (so the bug is ATC/translation:
|     copyout wrote a DIFFERENT phys than the PTE names).  != DEADBEEF -> phys is UNBACKED (the page
|     allocator handed out a phys not covered by RAM = a 040 physical-memory-map / maxclick bug, the
|     same root as the 8MB-vs-16MB halving). ---
| NOTE: the backed-RAM DEADBEEF write probe was REMOVED -- it wrote 0xDEADBEEF to phys 0x07A5D000
| (= user 0x80800000 offset 0), which would re-corrupt the lea word that the WB040 replay now fixes.
| --- dump the live CACR ('r').  68040: bit 31 = D-cache enable, bit 15 = I-cache enable.  sup_cacr
|     .data init is 0x00000800 (an 030-style value); if CACR here has bit31=0 the D-cache is OFF and
|     the bug is NOT cache coherency (the PTE genuinely names a phys copyout never wrote).  If bit31=1
|     the copyback D-cache is on -> the page-table coherency story holds. ---
	pea	0x72			| 'r' -- live CACR follows
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0x4e7a,0x0002		| movec %cacr,%d0
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
| --- CACR=0 (caches off) kills the coherency theory.  Dump the icode page's first 16 bytes via
|     lfuword (offsets 0/4/8/C) = 'i'.  Expected good icode: 4FFB0170 00000028 700B4E40 60FE....
|     If offset 0/4 = 0 but offset 8 = 700B4E40 -> the lea (first 8 bytes) was lost while the
|     moveq#11+trap#0 survived -> the zeros decode as ori.b and fall through to exec, AND the lea
|     never runs -> USP stays the stale kernel value (070DB958).  That explains the whole failure.
	pea	0x69			| 'i' -- icode page first 16 bytes follow
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0x80800000,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	&0x80800004,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	&0x80800008,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	&0x8080000c,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
Lco_nopte:
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
	cmpil	&0x80800000,%d2		| icode segment?
	beqw	Lam_print
	cmpil	&0xc07ff800,%d2		| proc-1 USER STACK segment (main's 2nd as_map)?
	bnew	Lam_done
| --- stack as_map RETURNED: proc 1 is past the icode copyout and about to return-to-user.
|     Drop a DIRECT 'M' marker (survives even if STREAMS never drains) BEFORE the cmn_err so
|     we can tell "hang in as_map(stack)/return-to-user" (M absent) from "hang in exec" (M+E). ---
	pea	0x4d			| 'M' -- proc-1 stack mapped; about to rte to user (icode)
	jsr	serdbg_mark
	addqw	&4,%sp
Lam_print:
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

| ===========================================================================
| rexit WRAPPER (orig 0x3f2c2, GLOBAL T) -- the dynamic linker (libc.so.1) calls exit()
| BEFORE transferring to init's _start (proven: NO 0x80000000-region code fault ever appears
| -- init's text @0x80000034 is never executed).  So the interp FAILS after do_reloc and bails.
| This dumps the exit status + a window of the user stack so we can read the RETURN ADDRESS of
| the exit() call (a C10xxxxx value = the linker function that decided to exit) and disassemble
| libc.so.1 there to find the error condition.  rexit(uap@8): *uap = the exit status.
| Direct serdbg (survives the respawn loop); capped at 2 firings.  Tail-jmps rexit_orig.
	.globl	rexit
rexit:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	Lrx_n,%d0
	cmpil	&2,%d0
	bccw	Lrx_go			| cap at 2
	addql	&1,%d0
	movel	%d0,Lrx_n
	pea	0x52			| 'R' -- rexit reached (exit syscall dispatched)
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	%fp@(8),%a0		| uap
	movel	%a0@,%sp@-		| exit status
	jsr	serdbg_hex
	addqw	&4,%sp
| --- dump user stack C07FFF60..C07FFFC0 (24 words) via lfuword; the exit() caller's return
|     address (C10xxxxx) lives here.  Each word space-separated; newline at the end. ---
	movel	&0xC07FFF60,%d2
	movel	&24,%d3
Lrx_loop:
	pea	0x20			| ' '
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%d2,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	addil	&4,%d2
	subql	&1,%d3
	bnew	Lrx_loop
	pea	0x0a			| '\n'
	jsr	serdbg_mark
	addqw	&4,%sp
| --- dump the libc.so.1 GOT (mapped @C102FD8C) starting at +0x50, 24 slots, so we can verify
|     the R_68K_RELATIVE relocations: each should be C101xxxx/C102xxxx (file value + C1000000).
|     A raw 0x000xxxxx = do_reloc never relocated it; garbage = COW page still wrong.  Marker 'G'.
|     Key slots: +0x58 (C102FDE4) should be _rtmalloc C101116E; +0xDC (C102FE68) C102E050. ---
	pea	0x47			| 'G'
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0xC102FDDC,%d2		| GOT+0x50
	movel	&40,%d3			| 40 slots -> +0x50..+0xEC (covers +0x58 _rtmalloc and +0xDC)
Lrx_got:
	pea	0x20			| ' '
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%d2,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	addil	&4,%d2
	subql	&1,%d3
	bnew	Lrx_got
	pea	0x0a			| '\n'
	jsr	serdbg_mark
	addqw	&4,%sp
| --- write-persistence test: store a sentinel to GOT+0x58 (C102FDE4) via the fault-safe suword,
|     then read it back via lfuword.  Format: 'W' <suword_ret> <readback>.
|       ret=0 & readback=AA55AA55 -> page WRITABLE (do_reloc's writes should have persisted ->
|         the bug is a read/write page split, or do_reloc never wrote);
|       ret=FFFFFFFF             -> the store FAULTED = page READ-ONLY (COW never made it writable);
|       ret=0 & readback!=sentinel -> reads and writes hit DIFFERENT phys pages (COW map split). ---
	pea	0x57			| 'W'
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0xAA55AA55,%sp@-	| value
	movel	&0xC102FDE4,%sp@-	| addr = GOT+0x58
	jsr	suword
	addqw	&8,%sp
	movel	%d0,%sp@-		| suword return (0 ok, -1 fault)
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x20			| ' '
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0xC102FDE4,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-		| read-back value
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x0a			| '\n'
	jsr	serdbg_mark
	addqw	&4,%sp
Lrx_go:
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	jmp	rexit_orig
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
Lrx_n:
	.long	0
	.even
Lam_msg:
	.asciz	"DBG as_map as=%x addr=%x size=%x ret=%x"
