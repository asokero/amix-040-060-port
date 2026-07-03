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
	pea	u+0x1c0			| sender u_comm (curproc's u-area)
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
	nop				| pad: keep the relinked .text a multiple of 4 (text/data contiguity)
