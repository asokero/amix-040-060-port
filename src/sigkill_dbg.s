| sigkill_dbg.s -- sigtoproc wrapper: name the SIGKILL sender ("Killed" frontier, 2026-07-03).
|
| Commands die instantly with 'Killed' (uname/ls; rc processes; getty respawn storms).  The
| kernel has ~9 static psignal(p,9) sites; the SILENT ones (no cmn_err) are the suspects:
|   exece 0x566b6      -- setregs ret!=0 after point-of-no-return -> silent SIGKILL
|   restorecontext+66  -- bad sigcontext on signal return -> silent SIGKILL
|   exit/newproc/uadmin-- housekeeping paths
|   rm_outofanon       -- NOT silent ("Sorry, pid %d ... lack of swap space") -- absent from logs
| One boot with this wrapper names the killer: log every sig==9 with target pid/stat/flag,
| sender pid + u_comm, caller + grandcaller return addrs, and the 3rd (fromuser) arg.
|
| sigtoproc(p, sig, fromuser) is GLOBAL T 0x4750e -> --weaken-symbol sigtoproc +
| --add-symbol sigtoproc_orig=.text:0x4750e (relink-040-dbg.sh).  psignal (0x474f4) tail-calls
| sigtoproc, so this catches BOTH entry points.  Offsets (verified against sigtoproc/rm_outofanon
| disasm + vanilla proc.h): p_stat@0, p_flag@4, p_pidp@264 (pid_id@+4), curproc=*(u+0x730),
| sender comm = u+0x1C0 (u_comm, the string rm_outofanon itself prints).
| Cap 24 prints (kills at login time arrive minutes after boot; boot itself sends none).

	.data
	.even
Lsk_n:
	.long	0
Lsf_n:
	.long	0
Lsg_bn:					| chain-II probe: separate cap for walk-BAIL SIGSEGVs (non-resident)
	.long	0
Lsk_msg:
	.asciz	"DBG SIG sig=%d pid=%d stat=%x psargs=%s uret=%x uarg2=%x kcaller=%x fu=%x"
	.even
Lsk9_msg:
	.asciz	"DBG SIG9 GOT fde4=%x fe68=%x e000=%x ec00=%x f000=%x"
	.even
Lsg_n:
	.long	0
Lsg_msg:
	.asciz	"DBG SEGVCTX a0=%x a1=%x pte=%x cell=%x uva=%x"
	.even
Lsg_msg2:
	.asciz	"DBG SEGVDMP p0=%x p4=%x cm4=%x c0=%x c4=%x c8=%x"
	.even
Lsg_ptev:
	.long	0
Lsg_cellv:
	.long	0
Lsg_pteaddr:				| victim leaf PTE ADDRESS (phys, &leaf) from the URP walk
	.long	0
Lsg_ppv:				| stashed pp (page_numtouserpp result) for the chain walk
	.long	0
Lsg_headv:				| stashed pp->p_mapping chain head
	.long	0
Lsg_msg3:
	.asciz	"DBG SEGVPP pp=%x flg=%x vn=%x off=%x map=%x uown=%x"
	.even
Lsg_cw_msg:
	.asciz	"DBG SEGVCHAIN cnt=%x in=%x head=%x vpte=%x hpte=%x"
	.even
| chain-II v2 (2026-07-16, file-vs-swap + wrong-VA discriminators):
Lsg_a0v:				| saved user a0 (the faulting heap cell VA) across cmn_errs
	.long	0
Lsg_nd:					| first 3 chain nodes: {addr, PTE value} pairs
	.long	0,0,0,0,0,0
Lsg_nd_msg:
	.asciz	"DBG SEGVND a0=%x n1=%x p1=%x n2=%x p2=%x n3=%x p3=%x"
	.even
Lsg_vn_msg:
	.asciz	"DBG SEGVVN vn=%x vflg=%x vop=%x vtyp=%x vpgs=%x"
	.even

| v3 (2026-07-03): the killer is USERLAND self-kill (kill(2), sender==target, fu=1) -- the SVR4
| rtld convention: ld.so (inside libc.so.1 @C1000000) does _kill(_getpid(),SIGKILL) on EVERY
| fatal (rtsetup.c ~9 sites, binder.c 2 sites -- lazy PLT bind failure would explain "plain ls
| dies, ls -al lives": different first-call PLT sets).  The saved user PC is useless (always
| inside the _kill stub), but the USER STACK top holds the return address into _kill's CALLER
| = the exact rtld error site: uret - 0xC1000000 = offset in libc.so.1 -> disassemble offline.
|   uret  = lfuword(*u_ar0)   (u_ar0 = u+0x864; u_ar0[0] = saved user SP at the trap)
|   uarg2 = lfuword(usp+8)    (kill's 2nd arg -- MUST read 9; validates the stack layout)
| comm was empty at u+0x8A0 -> print u_psargs (u+0x3B0) instead: setregs itself fills it
| (we disassembled that copyin), so it is guaranteed populated for any exec'd process.
| Cap 64: the sac/listen respawn population self-kills every cycle and ate the old cap 24
| before login; their uret is equally interesting (same site as ls = one bug family).

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
	.globl	sigtoproc
sigtoproc:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
| ISSUE-10 probe (2026-07-10): on SIGSEGV dump the faulting USER context straight from
| the saved trap regs (u_ar0; fault frames: d0-d7 @0, a0-a7 @32, SR @64, PC @66 -- the
| PC@66 read is empirically proven by the hardbus logger).  For the sh malloc-walk crash
| (`moveal %a0@,%a1; btst #0,%a1@(3)`):
|   a0  = the heap CELL whose link was followed        (expect sh heap ~0x8001xxxx)
|   a1  = the bad link value                            (expect 0x4AFC0000 -- self-validating)
|   pte = leaf PTE of a0's page via a live URP walk    -> the PHYS page holding the corrupt
|         cell; cross-reference that phys against vtop/segmap/hat traces in the same log
|   uva = curproc->u_va                                (own-u-page double-use test)
| Cap 4 (the sh fault-retry flood repeats identical state).  Clobbers d0/d1/d3/a0/a1 only
| (d3 is reloaded by the Lsk_log path before use).
	movel	%fp@(12),%d0
	cmpil	&11,%d0
	bnew	Lsg_skip
| chain-II probe (2026-07-15): run the URP walk on EVERY SIGSEGV (cheap, all derefs gated),
| but DEFER the cap decision.  The diagnostic cap (Lsg_n) is consumed ONLY when the walk
| reaches a resident leaf (the sh-heap double-use morphology that carries SEGVDMP/SEGVCHAIN
| data).  Walk-BAIL faults (init PC-corruption at C0800084 etc. -- saved a0 not a resident
| heap cell) take a separate small cap (Lsg_bn) so an init crash-loop can neither drain the
| diagnostic budget nor flood the log.
	clrl	Lsg_pteaddr		| 0 until the full URP walk reaches a leaf
	clrl	Lsg_ppv			| 0 until page_numtouserpp gives a kvseg pp
	lea	Lsg_nd,%a1		| clear the 3 chain-node {addr,val} capture pairs
	clrl	%a1@+
	clrl	%a1@+
	clrl	%a1@+
	clrl	%a1@+
	clrl	%a1@+
	clrl	%a1@
| v2 (2026-07-10): CORRECT frame layout from ttrap.s source: the trap prologue does
| `movm.l &0xfffe,-(%sp)` (= d0-d7/a0-a6, 15 regs) then pushes USP, so u_ar0 points at:
| USP@0, d0-d7@4..32, a0-a6@36..60, SR@64, PC@66.  (v1 read +32/+36 = d7/a0 by mistake --
| its "+36 = 800120C0, changes per retry" output = the live malloc arena walk pointer,
| which is how the layout was confirmed.)  Also NEW: read the corrupt CELL's live content
| through the identity-mapped phys (leaf pte & ~0xFFF | a0 & 0xFFF) -- gated on a resident
| leaf with phys < 0x10000000 so an invalid walk can't fault the kernel.
	moveal	u+0x864,%a1		| u_ar0 = saved trap regs
	movel	%a1@(36),%d3		| d3 = saved a0 (heap cell address)
	movel	%d3,Lsg_a0v		| stash the faulting cell VA for the SEGVND line
	movel	%a1@(40),%d2		| d2 = saved a1 (the bad link value; expect 4AFC0000)
	.word	0x4e7a,0x0806		| movec %urp,%d0 -- live user root (phys, identity)
	moveal	%d0,%a0
	movel	%d3,%d0			| RI = VA[31:25]
	swap	%d0
	andil	&0xffff,%d0
	lsrl	&8,%d0
	lsrl	&1,%d0
	lsll	&2,%d0
	addal	%d0,%a0
	movel	%a0@,%d0		| root descriptor
	btst	&1,%d0
	beqw	Lsg_pte			| invalid -> print the raw descriptor
	andil	&0xfffffe00,%d0
	moveal	%d0,%a0
	movel	%d3,%d0			| PI = VA[24:18]
	swap	%d0
	andil	&0xffff,%d0
	lsrl	&2,%d0
	andil	&0x7f,%d0
	lsll	&2,%d0
	addal	%d0,%a0
	movel	%a0@,%d0		| pointer descriptor
	btst	&1,%d0
	beqw	Lsg_pte
	andil	&0xffffff00,%d0
	moveal	%d0,%a0
	movel	%d3,%d0			| PGI = VA[17:12]
	lsrl	&8,%d0
	lsrl	&4,%d0
	andil	&0x3f,%d0
	lsll	&2,%d0
	addal	%d0,%a0
	movel	%a0,Lsg_pteaddr		| chain-II probe: victim &leaf (phys) -- same space hat_pteload links
	movel	%a0@,%d0		| leaf PTE
Lsg_pte:
	movel	%d0,%d1			| d1 = pte (or the invalid descriptor from a bailed walk)
	andil	&0xf0000001,%d0
	cmpil	&1,%d0			| resident leaf AND phys < 0x10000000?
	bnew	Lsg_bail		| non-resident -> light bail path (separate cap, no chain data)
	movel	Lsg_n,%d0		| resident leaf = the diagnostic morphology -> consume diag cap HERE
	cmpil	&8,%d0
	bccw	Lsg_skip		| diagnostic cap reached -> silent (retries repeat identical state)
	addql	&1,%d0
	movel	%d0,Lsg_n
	movel	%d1,%d0
	andil	&0xfffff000,%d0
	moveal	%d0,%a0
	movel	%d3,%d0
	andil	&0xfff,%d0
	addal	%d0,%a0
	movel	%a0@,%d0		| live cell content via the identity-mapped phys
| v3 (2026-07-10): CONTENT SIGNATURE dump -- whose page is this?  Print longs at the
| phys page start (+0/+4: a u-area would show recognizable kernel pointers there) and
| around the cell (-4/0/+4/+8: an old malloc arena shows a chain; file content shows
| code/data).  a0 = phys of the cell.  Printed as a separate line BEFORE the main one;
| pte and cell content are stashed in .data cells across the cmn_err (it eats d0/d1/a0/a1).
	movel	%d0,Lsg_cellv
	movel	%d1,Lsg_ptev
	movel	%a0@(8),%sp@-		| c8
	movel	%a0@(4),%sp@-		| c4
	movel	%a0@,%sp@-		| c0 (= cell)
	movel	%a0@(-4),%sp@-		| cm4
	movel	%d1,%d0
	andil	&0xfffff000,%d0
	moveal	%d0,%a1			| a1 = phys page base
	movel	%a1@(4),%sp@-		| p4
	movel	%a1@,%sp@-		| p0
	pea	Lsg_msg2
	pea	2
	jsr	cmn_err
	lea	%sp@(32),%sp
| v4 (2026-07-10): WHO owns this phys page per the VM?  pfn -> page_t via the kernel's
| own page_numtouserpp, then dump identity fields (3B2 vm/page.h layout, verified against
| the binary: flags word @0, p_keepcnt @2, p_vnode @4, p_offset @8, p_mapping @32,
| p_dblist[4] @40, p_uown @56 -- 60-byte DEBUG page_t).  p_vnode!=0 + small p_offset =
| a FILE/DIR cache page (double-use with sh's anon heap!); p_uown = last u-page owner.
	movel	Lsg_ptev,%d0
	andil	&0xfffff000,%d0
	moveq	&12,%d1
	lsrl	%d1,%d0			| pfn
	movel	%d0,%sp@-
	jsr	page_numtouserpp
	addqw	&4,%sp
	movel	%d0,%d1			| pp must land in kvseg (0x4xxxxxxx) to deref
	andil	&0xf0000000,%d1
	cmpil	&0x40000000,%d1
	bnew	Lsg_nopp
	moveal	%d0,%a1
	movel	%d0,Lsg_ppv		| chain-II probe: stash pp for the reverse-map chain walk
	movel	%a1@(56),%sp@-		| p_uown
	movel	%a1@(32),%sp@-		| p_mapping
	movel	%a1@(8),%sp@-		| p_offset
	movel	%a1@(4),%sp@-		| p_vnode
	moveq	&0,%d1
	movew	%a1@,%d1
	movel	%d1,%sp@-		| flags|nio word
	movel	%d0,%sp@-		| pp
	pea	Lsg_msg3
	pea	2
	jsr	cmn_err
	lea	%sp@(32),%sp
| ISSUE-10 CHAIN-II probe (2026-07-15): is the VICTIM's OWN leaf PTE address in pp's
| p_mapping reverse-map chain?  cnt = nodes walked (capped 16; -1 = hit an out-of-range/
| misaligned node = corrupt chain, stopped).  in = 1 if the victim's &leaf (Lsg_pteaddr)
| was found in the chain, 0 = MISSING => missing-live-entry: the frame was freed/reused
| while this live PTE still mapped it, because free-time hat_pageunload cleared a chain
| that did NOT contain it.  head = pp->p_mapping; vpte = victim &leaf; hpte = *head
| (decode: pfn<<12|status = live-040 vs pfn<<11 = legacy phantom -> names the producer).
| Every deref is phys-range gated (top nibble 0 => phys < 0x10000000, 4-byte aligned) so a
| corrupt chain cannot fault the kernel.  Registers free here (Lsg_nopp/Lsg_cell reload d0/d1
| from .data).
	movel	Lsg_ppv,%d0
	beqw	Lsg_nopp		| no kvseg pp this pass -> skip the walk
	moveal	%d0,%a1
	movel	%a1@(32),%a0		| a0 = cursor = pp->p_mapping
	movel	%a0,Lsg_headv		| stash head for the emit
	movel	Lsg_pteaddr,%d3		| d3 = victim &leaf (0 if the URP walk bailed)
	moveq	&0,%d2			| d2 = found flag
	moveq	&0,%d1			| d1 = node count
Lsg_cw:
	movel	%a0,%d0
	beqw	Lsg_cwd			| NULL -> end of chain
	cmpil	&16,%d1
	bccw	Lsg_cwd			| cap 16 (corrupt/looping chain guard)
	andil	&0xf0000003,%d0		| phys < 0x10000000 AND 4-byte aligned?
	bnew	Lsg_cwbad		| out of range / misaligned -> corrupt, stop
	cmpil	&3,%d1			| capture the first 3 nodes {addr, PTE value}
	bcc	Lsg_cwnc		| (wrong-VA discriminator: addr low byte>>2 = PGI = VA[17:12])
	lea	Lsg_nd,%a1
	movel	%d1,%d0
	lsll	&3,%d0
	movel	%a0,%a1@(0,%d0:l)	| node address (phys &leaf)
	movel	%a0@,%a1@(4,%d0:l)	| node PTE value (pfn<<12 | status)
Lsg_cwnc:
	cmpal	%d3,%a0			| node == victim &leaf?
	bne	Lsg_cwn
	moveq	&1,%d2			| FOUND -> victim IS in the chain (registered; not chain-II)
Lsg_cwn:
	addql	&1,%d1
	movel	%a0@(256),%a0		| next = *(node + 256)
	braw	Lsg_cw
Lsg_cwbad:
	moveq	&-1,%d1			| corrupt-chain marker (stopped at an unsafe node)
Lsg_cwd:
	moveq	&0,%d0			| hpte default 0
	movel	Lsg_headv,%d3
	beqw	Lsg_cwe			| NULL head -> hpte 0
	movel	%d3,%d0
	andil	&0xf0000003,%d0
	bnew	Lsg_cwe0		| unsafe head -> hpte 0
	moveal	%d3,%a0
	movel	%a0@,%d0		| hpte = *head (the head leaf PTE value)
	braw	Lsg_cwe
Lsg_cwe0:
	moveq	&0,%d0
Lsg_cwe:
	movel	%d0,%sp@-		| hpte
	movel	Lsg_pteaddr,%sp@-	| vpte = victim &leaf
	movel	Lsg_headv,%sp@-		| head = pp->p_mapping
	movel	%d2,%sp@-		| in  (1 = found, 0 = MISSING)
	movel	%d1,%sp@-		| cnt (-1 = corrupt chain)
	pea	Lsg_cw_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
| chain-II v2 (2026-07-16): SEGVND -- the faulting cell VA + first 3 chain nodes {addr,val}.
| Node addr low byte >>2 = PGI = the mapping VA's bits [17:12]: tells whether the OTHER
| mappings of this frame are libc-family (C1000000: PGI 0) or heap-family VAs -> separates
| "shared file page wrongly mapped into the victim's heap VA" from "anon page clobbered".
	lea	Lsg_nd,%a1
	movel	%a1@(20),%sp@-		| p3
	movel	%a1@(16),%sp@-		| n3
	movel	%a1@(12),%sp@-		| p2
	movel	%a1@(8),%sp@-		| n2
	movel	%a1@(4),%sp@-		| p1
	movel	%a1@,%sp@-		| n1
	movel	Lsg_a0v,%sp@-		| a0 = the faulting heap cell VA
	pea	Lsg_nd_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(36),%sp
| SEGVVN -- the crash page's vnode identity: v_flag (bit 0x40 = VISSWAP -> swap device,
| else file), v_op (compare offline vs ufs_vnodeops/spec_vnodeops nm), v_type (1=VREG file,
| 3=VBLK/4=VCHR device), v_pages.  Settles file-vs-swap for the p_vnode!=0 off=0 identity.
| Gated: the vnode pointer must land in kvseg (0x4xxxxxxx) to deref.
	movel	Lsg_ppv,%d0
	beqw	Lsg_nopp
	moveal	%d0,%a1
	movel	%a1@(4),%d3		| p_vnode
	movel	%d3,%d0
	andil	&0xf0000000,%d0
	cmpil	&0x40000000,%d0
	bnew	Lsg_nopp		| vnode not a kvseg pointer -> skip
	moveal	%d3,%a1
	movel	%a1@(20),%sp@-		| v_pages
	movel	%a1@(24),%sp@-		| v_type (enum: 1=VREG, 3=VBLK, 4=VCHR)
	movel	%a1@(8),%sp@-		| v_op
	moveq	&0,%d0
	movew	%a1@,%d0
	movel	%d0,%sp@-		| v_flag (0x40 = VISSWAP)
	movel	%d3,%sp@-		| vn
	pea	Lsg_vn_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
Lsg_nopp:
	movel	Lsg_ptev,%d1
	movel	Lsg_cellv,%d0
	braw	Lsg_cell
Lsg_bail:
	movel	Lsg_bn,%d0		| walk bailed (non-resident) -> separate small cap so an init
	cmpil	&4,%d0			| PC-corruption crash-loop can't flood or drain the diag budget
	bccw	Lsg_skip		| bail cap reached -> silent
	addql	&1,%d0
	movel	%d0,Lsg_bn
Lsg_nc:
	movel	&0xdeaddead,%d0		| walk failed / phys out of range -> marker
Lsg_cell:
	moveal	u+0x730,%a0
	movel	%a0@(252),%sp@-		| uva = curproc->u_va
	movel	%d0,%sp@-		| cell content
	movel	%d1,%sp@-		| pte
	movel	%d2,%sp@-		| saved a1 (bad link)
	movel	%d3,%sp@-		| saved a0 (heap cell address)
	pea	Lsg_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
Lsg_skip:
	movel	%fp@(12),%d0		| sig
	moveq	&9,%d1
	cmpl	%d0,%d1
	beqw	Lsk_cap9
| v4 (2026-07-03 NIGHT, the date loop): trapsig fires EVERY loop cycle -> also log the other
| FATAL signals 4..11 (ILL/TRAP/ABRT/EMT/FPE/KILL/BUS/SEGV) so the loop's signal + target are
| named.  Rate-limited: first 8 occurrences + every 256th after (the loop repeats forever).
	moveq	&4,%d1
	cmpl	%d0,%d1
	bgtw	Lsk_done		| sig < 4 -> ignore
| ISSUE-34b probe (2026-07-27): raised 11 -> 12 so SIGSYS is logged.  cc1 dies with
| sig 12 on the 68060 and works on the 68040, and the whole compiler toolchain was
| verified CLEAN of 68060-unimplemented instructions -- so the ISA class is ruled out and
| the question is which kernel path delivers the signal.  This line's `kcaller` and `uret`
| answer exactly that.  dbg-overlay only; the base is untouched.
	moveq	&12,%d1
	cmpl	%d0,%d1
	bltw	Lsk_done		| sig > 12 -> ignore (was 11; SIGSYS=12 for ISSUE-34b)
	addql	&1,Lsf_n
	movel	Lsf_n,%d0
	cmpil	&8,%d0
	blsw	Lsk_log			| first 8 -> log
	andil	&0xff,%d0
	beqw	Lsk_log			| every 256th -> log
	braw	Lsk_done
Lsk_cap9:
	movel	Lsk_n,%d0
	cmpil	&64,%d0
	bccw	Lsk_done
	addql	&1,%d0
	movel	%d0,Lsk_n
Lsk_log:
	moveal	%fp@(8),%a2		| a2 = target proc
	moveal	u+0x864,%a0		| u_ar0 (sender's saved trap regs)
	movel	%a0@,%d3		| d3 = saved user SP
	movel	%d3,%sp@-
	jsr	lfuword			| d0 = *(usp) = return addr into _kill's caller
	addqw	&4,%sp
	movel	%d0,%d2			| d2 = uret
	addql	&8,%d3
	movel	%d3,%sp@-
	jsr	lfuword			| d0 = *(usp+8) = kill's sig arg (expect 9)
	addqw	&4,%sp
	movel	%d3,%d3			| (keep d3 dead-safe)
	movel	%fp@(16),%sp@-		| fu (3rd sigtoproc arg)
	movel	%fp@(4),%sp@-		| kcaller (kernel-side return addr)
	movel	%d0,%sp@-		| uarg2
	movel	%d2,%sp@-		| uret
	pea	u+0x3b0			| sender u_psargs (setregs fills it -- always populated)
	clrl	%d0
	moveb	%a2@,%d0
	movel	%d0,%sp@-		| target p_stat
	moveal	%a2@(264),%a0		| target p_pidp
	movel	%a0@(4),%sp@-		| target pid
	movel	%fp@(12),%sp@-		| sig
	pea	Lsk_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(40),%sp
| v5 (2026-07-12, load-repro run 1): sac self-killed via the rtld convention under
| fork+I/O load and EVERY later exec hung -> suspicion: the corruptor hit a SHARED
| libc.so.1 page-cache page (not per-process anon this time).  On each SELF-KILL
| (sig==9 && fu==1; curproc == the dying process, so lfuword reads ITS space) dump
| the libc probe words: GOT slots C102FDE4 (expect C101116E) / C102FE68 (expect
| C102E050), data-seg start C102E000, the ISSUE-10 signature offset C102EC00
| (page+0xC00), and C102F000.  Garbage/dirent bytes here at kill time = shared-page
| corruption confirmed, and the content names the source disk block.  Cap shared
| with the Lsk_n<=64 gate above.  lfuword clobbers d0/d1/a0/a1 only.
	movel	%fp@(12),%d0
	moveq	&9,%d1
	cmpl	%d0,%d1
	bnew	Lsk_done
	movel	%fp@(16),%d0
	subql	&1,%d0
	bnew	Lsk_done
	movel	&0xc102f000,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-		| f000
	movel	&0xc102ec00,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-		| ec00
	movel	&0xc102e000,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-		| e000
	movel	&0xc102fe68,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-		| fe68
	movel	&0xc102fde4,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-		| fde4
	pea	Lsk9_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
Lsk_done:
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	jmp	sigtoproc_orig

| ---------------------------------------------------------------------------
| getdents LOOP detector ("second ls hangs", 2026-07-03).  The hang is a foreground ls that
| never completes while job control/tty stay healthy (Ctrl+Z recovers the shell) -> prime
| suspect = ls spinning on getdents (user-mode loop on a bad EOF/offset) or repeating a
| failing call.  A legit ls does 1-3 getdents calls per directory, so: count calls by the
| SAME pid (reset when another pid calls); above 64 log every 64th with fd/errno/nbytes.
|   nb=0 repeated   -> kernel returns EOF but ls loops = dirent ABI/format mismatch
|   nb=const>0      -> uio offset never advances = s5readdir/segmap dir-read bug
|   err!=0 repeated -> failing call retried forever
| getdents(uap, rvp) GLOBAL T 0x5e520: uap@0=fd, @4=buf, @8=count; *rvp = bytes returned;
| d0 = errno.  -> --weaken-symbol getdents + getdents_orig=0x5e520 (relink-040-dbg.sh).

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lgd_lastpid:
	.long	0
Lgd_n:
	.long	0
Lgd_p:
	.long	0
Lgd_msg:
	.asciz	"DBG getdents LOOP pid=%d fd=%x err=%x nb=%x n=%x"
	.even

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
	.globl	getdents
getdents:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	getdents_orig
	addqw	&8,%sp
	movel	%d0,%d2			| errno
	moveal	u+0x730,%a0		| curproc
	moveal	%a0@(264),%a0		| p_pidp
	movel	%a0@(4),%d3		| pid
	cmpl	Lgd_lastpid,%d3
	beqw	Lgd_same
	movel	%d3,Lgd_lastpid
	clrl	Lgd_n
	braw	Lgd_out
Lgd_same:
	addql	&1,Lgd_n
	movel	Lgd_n,%d0
	cmpil	&64,%d0
	bcsw	Lgd_out			| below loop threshold
	andil	&63,%d0
	bnew	Lgd_out			| log every 64th only
	movel	Lgd_p,%d0
	cmpil	&16,%d0
	bccw	Lgd_out
	addql	&1,Lgd_p
	movel	Lgd_n,%sp@-		| n
	moveal	%fp@(12),%a0
	movel	%a0@,%sp@-		| nb = *rvp (bytes returned)
	movel	%d2,%sp@-		| errno
	moveal	%fp@(8),%a0
	movel	%a0@,%sp@-		| fd
	movel	%d3,%sp@-		| pid
	pea	Lgd_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
Lgd_out:
	movel	%d2,%d0
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| clock_hook SAMPLER (2026-07-03 EVE, the "boot stalls, no W-dumps" frontier).  Boot 6 hung
| with ZERO idle proc-table dumps -> the CPU never idles -> a process SPINS.  The keyboard
| still echoes = interrupts run = the CIA clock still ticks.  clock() (0x3db9c) calls
| (*clock_hook)(frame) FIRST if the pointer is nonzero (clock_hook is a COMMON bss long;
| our .data definition below wins over the common and installs the sampler at link time).
| frame layout (from clock's own derefs + setregs u_ar0 use): @64 = SR word (btst #5 =
| S bit; bfextu 5,3 = IPL), @66 = interrupted PC long.
| Every 16th tick (~0.3s at 50Hz), cap 1024 (~5.5 min): print "C<pid>:<PC>:<SR> " via
| DIRECT serial.  During a spin the samples repeat one PC (or a tight range) -> the loop
| is named: kernel PC -> map via nm; user PC (SR S-bit clear) -> 0x80000000=program /
| 0xC1000000=libc.so.1 offset.  Interrupt-level safe: only d0/a0 + balanced stack.

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
	.globl	clock_hook
clock_hook:
	.long	clock_sampler
Lcs_tick:
	.long	0
Lcs_n:
	.long	0

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
clock_sampler:
	addql	&1,Lcs_tick
	movel	Lcs_tick,%d0
	andil	&15,%d0			| every 16th tick
	bnew	Lcs_out
	movel	Lcs_n,%d0
	cmpil	&1024,%d0
	bccw	Lcs_out
	addql	&1,%d0
	movel	%d0,Lcs_n
	pea	0x43			| 'C' -- clock sample record
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	curproc,%a0
	movel	%a0@(264),%d0		| p_pidp (0 for a half-built proc)
	beqw	Lcs_p0
	moveal	%d0,%a0
	movel	%a0@(4),%sp@-		| pid_id
	braw	Lcs_pgo
Lcs_p0:
	clrl	%sp@-
Lcs_pgo:
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x3a			| ':'
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	%sp@(4),%a0		| frame ptr (stack balanced here)
	movel	%a0@(66),%sp@-		| interrupted PC
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x3a			| ':'
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	%sp@(4),%a0
	clrl	%d0
	movew	%a0@(64),%d0		| SR (S bit = kernel/user)
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x20
	jsr	serdbg_mark
	addqw	&4,%sp
Lcs_out:
	rts

| ---------------------------------------------------------------------------
| hardbus WRAPPER (2026-07-04, the date fault loop).  Boot-10/11 evidence: the loop calls
| NEITHER as_fault NOR sigtoproc -- usrxmemflt's tail routes the fault to hardbus (samples
| at 0x5B110-0x5B13E = the hardbus call site), and hardbus returns 0 ("phys probes OK, not
| a hard error, just retry") -> u_trap returns to user -> same fault -> forever.  Log what
| lands here: fault addr, the leaf PTE VALUE (*ptep -- 0 = software walk found INVALID =
| tree/URP mismatch; valid = CPU-vs-software tree divergence), hardbus's ret, and the user
| PC.  First 8 + every 512th (the loop repeats).  hardbus GLOBAL T 0x5b3c2 ->
| --weaken-symbol hardbus + hardbus_orig (relink-040-dbg.sh).

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lhb_n:
	.long	0
Lhb_msg:
	.asciz	"DBG hardbus pid=%d addr=%x pte=%x ret=%x upc=%x uva=%x n=%x"
	.even
Lhbx_n:
	.long	0
Lhbx_msg:
	.asciz	"DBG hardbus XPAGE addr=%x -> next page %x mapped, retrying (n=%x)"
	.even

| ★ PAGE-CROSSING FIX (2026-07-04, ROOT CAUSE of the date loop, CONFIRMED from the binary):
| date's instruction at 0x80000FFC is `jsr 0x80000c2c` (4eb9 8000 0c2c, 6 bytes) -- the
| absolute-address EXTENSION WORD starts at 0xFFE and CROSSES the page boundary: bytes
| 0xFFE-0xFFF on (mapped) page 0, bytes 0x1000-0x1001 on (unmapped) page 0x80001000.  The
| 68040 reports FA = the start of the crossing access (0xFFE, page 0) -- NOT the part that
| actually missed (0x1000).  usrxmemflt resolves page 0 (already valid, PTE 7B7F00D), the
| 030-frame-semantic tail checks misroute the fault to hardbus, hardbus probes page 0's
| phys OK -> return 0 -> retry -> same fault: observed 3.1+ MILLION iterations.  Any binary
| whose layout puts a multi-word instruction (or misaligned data operand) across a not-yet-
| resident page boundary hits this -- pure layout luck (why date; why nondeterministic-
| looking earlier under the ZFOD dirt).
| FIX at this choke point: for USER addresses within 8 bytes of a page end, as_fault BOTH
| the operand's page AND the next page (read, F_INVAL); if either resolves -> return 0 and
| let the CPU retry (now with the crossing target mapped).  Only if both fail -> genuine
| hardbus.  Faulting the CURRENT page too keeps a misrouted last-bytes-of-unmapped-page
| fault from turning into a new infinite loop (next-page-only would remap the wrong page
| forever).  The proper long-term fix = port usrxmemflt's tail dispatch to 040 frame/SSW
| semantics (MA bit) -- noted for the base-build sync.

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
	.globl	hardbus
| MEASUREMENT WRAPPER ONLY (2026-09-06).  This used to carry its own copy of the
| page-crossing fix and of the ISSUE-47 band guard.  Both now live once, in
| src/runtime040.s as hardbus040_core, and this calls that body; the dbg build weakens
| `hardbus` so this twin wins, but hardbus040_core keeps its own strong name and is
| inherited from the base image.  Requested by Codex's ISSUE-47 contract, and the reason
| is ISSUE-64: two copies of one decision, one of them updated.
|
| What is lost, said plainly rather than left to be discovered: the per-event
| "DBG hardbus XPAGE ..." line is gone with the duplicated body.  Its count survives as
| hbu_xpage_n in the core, so the quantity is still readable; the individual print is not.
| That probe existed for the 2026-07-04 date hang, which has been fixed since.
hardbus:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	addql	&1,Lhb_n
	movel	%fp@(12),%sp@-		| ptep
	movel	%fp@(8),%sp@-		| addr
	jsr	hardbus040_core
	addqw	&8,%sp
	movel	%d0,%d2			| ret
	movel	Lhb_n,%d3
	cmpil	&8,%d3
	blsw	Lhb_log			| first 8 -> log
	movel	%d3,%d0
	andil	&0x1ff,%d0
	beqw	Lhb_log			| every 512th -> log
	braw	Lhb_out
Lhb_log:
	movel	%d3,%sp@-		| n
	moveal	u+0x730,%a0		| ISSUE-10 (2026-07-10): also print curproc->u_va --
	movel	%a0@(252),%sp@-		| is the bad kvsegu-range pointer THIS proc's own u-area?
	moveal	u+0x864,%a0		| u_ar0
	movel	%a0@(66),%sp@-		| user PC
	movel	%d2,%sp@-		| ret
	moveal	%fp@(12),%a0
	movel	%a0@,%sp@-		| *ptep (leaf PTE value)
	movel	%fp@(8),%sp@-		| addr
	moveal	u+0x730,%a0
	moveal	%a0@(264),%a0
	movel	%a0@(4),%sp@-		| pid
	pea	Lhb_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(36),%sp		| 9 args now (uva added)
Lhb_out:
	movel	%d2,%d0
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts
	nop				| pad: keep the relinked .text a multiple of 4 (text/data contiguity)
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
