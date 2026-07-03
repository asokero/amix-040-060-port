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
Lsk_msg:
	.asciz	"DBG SIGKILL pid=%d stat=%x psargs=%s uret=%x uarg2=%x kcaller=%x fu=%x"
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

	.text
	.globl	sigtoproc
sigtoproc:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	%fp@(12),%d0		| sig
	moveq	&9,%d1
	cmpl	%d0,%d1
	bnew	Lsk_done
	movel	Lsk_n,%d0
	cmpil	&64,%d0
	bccw	Lsk_done
	addql	&1,%d0
	movel	%d0,Lsk_n
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
	pea	Lsk_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(36),%sp
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
	nop				| pad: keep the relinked .text a multiple of 4 (text/data contiguity)
