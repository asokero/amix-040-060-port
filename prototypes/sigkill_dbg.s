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
Lsk_msg:
	.asciz	"DBG SIG sig=%d pid=%d stat=%x psargs=%s uret=%x uarg2=%x kcaller=%x fu=%x"
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
	beqw	Lsk_cap9
| v4 (2026-07-03 NIGHT, the date loop): trapsig fires EVERY loop cycle -> also log the other
| FATAL signals 4..11 (ILL/TRAP/ABRT/EMT/FPE/KILL/BUS/SEGV) so the loop's signal + target are
| named.  Rate-limited: first 8 occurrences + every 256th after (the loop repeats forever).
	moveq	&4,%d1
	cmpl	%d0,%d1
	bgtw	Lsk_done		| sig < 4 -> ignore
	moveq	&11,%d1
	cmpl	%d0,%d1
	bltw	Lsk_done		| sig > 11 -> ignore
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

	.data
	.even
	.globl	clock_hook
clock_hook:
	.long	clock_sampler
Lcs_tick:
	.long	0
Lcs_n:
	.long	0

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

	.data
	.even
Lhb_n:
	.long	0
Lhb_msg:
	.asciz	"DBG hardbus pid=%d addr=%x pte=%x ret=%x upc=%x n=%x"
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

	.text
	.globl	hardbus
hardbus:
	linkw	%fp,&0
	moveml	%d2-%d3,%sp@-
	addql	&1,Lhb_n
	movel	%fp@(8),%d0		| addr
	cmpil	&0x80000000,%d0
	bcsw	Lhb_norm		| kernel/low address -> normal hardbus
	movel	%d0,%d1
	andil	&0xfff,%d1
	cmpil	&0xff8,%d1
	bcsw	Lhb_norm		| not within 8 bytes of page end -> normal hardbus
	andil	&0xfffff000,%d0
	movel	%d0,%d3			| d3 = current page base
| -- resolve the CURRENT page (usually already valid -> cheap no-op) --
	pea	1			| rw = read
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d3,%sp@-
	moveal	u+0x730,%a0
	movel	%a0@(124),%sp@-		| as = curproc->p_as
	jsr	as_fault
	lea	%sp@(20),%sp
	movel	%d0,%d2			| remember current-page result
| -- resolve the NEXT page (the actual crossing target) --
	addil	&0x1000,%d3
	pea	1			| rw = read
	clrl	%sp@-			| type = F_INVAL
	pea	4			| len
	movel	%d3,%sp@-
	moveal	u+0x730,%a0
	movel	%a0@(124),%sp@-
	jsr	as_fault
	lea	%sp@(20),%sp
	tstl	%d0
	beqw	Lhb_fixed		| next page mapped -> retry
	tstl	%d2
	beqw	Lhb_fixed		| current page (re)resolved -> retry
	braw	Lhb_norm		| both failed -> genuine hard-error path
Lhb_fixed:
	movel	Lhbx_n,%d0
	addql	&1,%d0
	movel	%d0,Lhbx_n
	cmpil	&16,%d0
	blsw	Lhbx_log		| first 16 -> log
	andil	&0x3ff,%d0
	beqw	Lhbx_log		| every 1024th -> log (loop visibility)
	braw	Lhbx_q
Lhbx_log:
	movel	Lhbx_n,%sp@-		| n
	movel	%d3,%sp@-		| next page va
	movel	%fp@(8),%sp@-		| original fault addr
	pea	Lhbx_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lhbx_q:
	clrl	%d2			| return 0 = not a hard error, retry
	braw	Lhb_out
Lhb_norm:
	movel	%fp@(12),%sp@-		| ptep
	movel	%fp@(8),%sp@-		| addr
	jsr	hardbus_orig
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
	lea	%sp@(32),%sp
Lhb_out:
	movel	%d2,%d0
	moveml	%fp@(-8),%d2-%d3
	unlk	%fp
	rts
	nop				| pad: keep the relinked .text a multiple of 4 (text/data contiguity)
