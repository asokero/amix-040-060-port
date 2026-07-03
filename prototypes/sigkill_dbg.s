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
	.asciz	"DBG SIGKILL pid=%d stat=%x flag=%x from pid=%d comm=%s caller=%x gcaller=%x fu=%x"
	.even

	.text
	.globl	sigtoproc
sigtoproc:
	linkw	%fp,&0
	moveml	%a2-%a3,%sp@-
	movel	%fp@(12),%d0		| sig
	moveq	&9,%d1
	cmpl	%d0,%d1
	bnew	Lsk_done
	movel	Lsk_n,%d0
	cmpil	&24,%d0
	bccw	Lsk_done
	addql	&1,%d0
	movel	%d0,Lsk_n
	moveal	%fp@(8),%a2		| a2 = target proc
	moveal	%fp@,%a3		| a3 = caller's frame ptr (caller is gcc code w/ linkw)
	movel	%fp@(16),%sp@-		| fromuser (3rd arg)
	movel	%a3@(4),%sp@-		| grandcaller return addr
	movel	%fp@(4),%sp@-		| caller return addr
	pea	u+0x8a0			| sender u_comm -- rm_outofanon: lea u+0x730,%a0; pea %a0@(448)
					| = u+0x730+0x1C0 = u+0x8A0 (first build used u+0x1C0 -> comm= empty)
	moveal	u+0x730,%a0		| curproc
	moveal	%a0@(264),%a0		| p_pidp
	movel	%a0@(4),%sp@-		| sender pid
	movel	%a2@(4),%sp@-		| target p_flag
	clrl	%d0
	moveb	%a2@,%d0
	movel	%d0,%sp@-		| target p_stat
	moveal	%a2@(264),%a0		| target p_pidp
	movel	%a0@(4),%sp@-		| target pid
	pea	Lsk_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(40),%sp
Lsk_done:
	moveml	%fp@(-8),%a2-%a3
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
	rts				| (no pad needed at current size -- re-add a nop if the
					|  contiguity check ever FAILs by 2 after an edit)
