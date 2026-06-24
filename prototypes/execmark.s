| execmark.s -- one-shot 'E' marker at exece (0x56444, GLOBAL T) entry.
|
| GOAL (2026-06-24): localize the init-startup HANG that follows main's icode copyout.
| proc 1 (newproc child) runs main's proc-1 branch: as_map(icode) -> copyout(icode) ->
| as_map(stack@0xC07FF800) -> main returns 0x80800000 -> _start@0x5e rte's to USER mode at
| 0x80800000 -> icode runs `moveq #11,d0; trap#0` = exec("/sbin/init") -> systrap -> exece.
| If 'E' fires, proc 1 reached USER mode, the icode page ran, the trap dispatched, and we are
| INSIDE exec -- so the hang is in exec (heavy: namei, ELF read, as_alloc, user-VM hat_dup).
| If 'M' (as_map stack, assegat_dbg.s) fires but 'E' does NOT, the hang is in the return-to-user
| rte / first user instruction fetch / trap dispatch -- BEFORE exec.
|
| exece is invoked through the sysent[] table (a .data pointer relocated against `exece`); the
| --weaken-symbol exece + this strong def makes that table entry re-resolve here.  exece reads
| its args from the u-area (u.u_ap), NOT from its own stack, and returns d0 -- so a register-
| transparent TAIL-JMP to the aliased original (exece_orig=.text:0x56444) is exact.
| Mechanism: objcopy --add-symbol exece_orig=.text:0x56444,function,global --weaken-symbol exece.

	.text
	.globl	exece
exece:
	movel	Lex_n,%d0
	bnew	Lex_go			| one-shot: mark only the FIRST exec (proc 1 / init)
	moveq	&1,%d0
	movel	%d0,Lex_n
	movel	%d0,g_inexec		| arm L/B/D markers (gate them to proc-1's exec only)
	pea	0x45			| 'E' -- first exec reached (proc 1 ran icode in user mode)
	jsr	serdbg_mark
	addqw	&4,%sp
| --- dump u.u_ap (exece's arg1) + uap[0..2] = path/argv/envp.  systrap calls exece(u.u_ap).
|     If uap is 0x8080xxxx -> u.u_ap points straight at the USER stack (read live); if 0x40xxxxxx
|     or a u-area addr -> the args were copied to kernel.  On 030 uap[0]=0x8080000E (path); on 040
|     it was 0x3C663C06 (garbage).  Whether uap[1]/uap[2] are ALSO wrong tells us "whole arg
|     fetch from a bad usp" vs "single value aliased". ---
	moveal	%sp@(4),%a0		| a0 = uap (arg1)
	movel	%a0,%sp@-		| uap pointer
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%sp@(4),%a0
	movel	%a0@,%sp@-		| uap[0] = path
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%sp@(4),%a0
	movel	%a0@(4),%sp@-		| uap[1] = argv
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%sp@(4),%a0
	movel	%a0@(8),%sp@-		| uap[2] = envp
	jsr	serdbg_hex
	addqw	&4,%sp
| --- dump u.u_ar0 (saved-register frame ptr) + saved usp.  systrap reads each syscall arg with
|     lfuword(usp+off) where usp = u.u_ar0[0] (a5 = *(u+0x864)).  lfuword uses moves SFC=1 (URP,
|     correct on 040).  So if the args are garbage, the SAVED USP must be wrong.  On 030 expect
|     u.u_ar0[0] = 0x8080002A (icode set sp=L%stack).  If 040 differs, the trap glue's
|     `movel %usp,%a0` capture / the saved-frame layout is wrong on 040. ---
	pea	0x55			| 'U' -- usp dump follows
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	u+0x864,%sp@-		| u.u_ar0 pointer
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	u+0x864,%a0
	movel	%a0@,%sp@-		| u.u_ar0[0] = saved usp
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	u+0x864,%a0
	movel	%a0@(4),%sp@-		| u.u_ar0[1] (next saved word -- confirm frame layout)
	jsr	serdbg_hex
	addqw	&4,%sp
| --- saved SR + PC + format/vector from the trap frame (u_trap: SR@fp@(72), PC@fp@(74),
|     fmt@fp@(78); u.u_ar0=fp+8 so SR@ar0+64).  DECISIVE: saved SR bit 13 (S) = 0 -> the trap
|     came from USER mode (so USP should be valid -> a USP-capture / context bug); = 1 -> icode
|     ran in SUPERVISOR mode (the rte-to-user never dropped to user on 040).  PC = the user EA
|     after trap#0 (icode's trap#0 is at user 0x80800008 -> expect PC 0x8080000A if icode ran). ---
	pea	0x40			| '@' separator (frame SR/PC/fmt follow)
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	u+0x864,%a0
	movel	%a0@(64),%sp@-		| [saved SR.w][PC.hi.w]
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	u+0x864,%a0
	movel	%a0@(68),%sp@-		| [PC.lo.w][fmt/vec.w]
	jsr	serdbg_hex
	addqw	&4,%sp
Lex_go:
	jmp	exece_orig		| run the stock exece unchanged (register/stack transparent)

| ---------------------------------------------------------------------------
| lookuppn / bread / biodone -- gated by g_inexec (set when proc 1 enters exece) so they
| trace ONLY the namei("/sbin/init") path, not the mount/swapconf reads that ran earlier.
|   L = lookuppn entered  -> namei started (E,no L => hang in pn_get/copyinstr from user path).
|   B = bread issued       -> a disk read was started in the exec namei path.
|   D = biodone fired       -> that read's completion (SCSI interrupt / DMA) actually arrived.
| KEY: B with NO D => the read was issued but never completed = interrupt/DMA never delivered
| (proc 1 then sleeps in biowait forever; swtch->idle->stop is silent, matching no 'r').

	.globl	lookuppn
lookuppn:
	tstl	g_inexec
	beqw	Ll_go
	movel	Ll_n,%d0
	bnew	Ll_go			| one-shot
	moveq	&1,%d0
	movel	%d0,Ll_n
	pea	0x4c			| 'L'
	jsr	serdbg_mark
	addqw	&4,%sp
| --- dump the pathname the 040 lookuppn got (pn struct arg1 -> pn_path @+4) ---
|     pn_path POINTER first (always safe: a kernel pointer value), then a 'q' marker, then the
|     first 4 path bytes (= 0x2f736269 "/sbi" if good).  If hex+q print but then it hangs/panics
|     on the byte read, the pn_path BUFFER page is unmapped on 040 (the layout-sensitive gap);
|     if the pointer/bytes are garbage, pn_get/copyinstr produced a bad path.
	moveal	%sp@(4),%a0		| a0 = pathname struct (arg1, kernel stack -- safe)
	movel	%a0@(4),%sp@-		| pn_path pointer
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x71			| 'q' -- about to deref pn_path (byte read may fault if unmapped)
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	%sp@(4),%a0
	moveal	%a0@(4),%a0		| a0 = pn_path
	movel	%a0@,%sp@-		| first 4 path bytes
	jsr	serdbg_hex
	addqw	&4,%sp
Ll_go:
	jmp	lookuppn_orig

| ---------------------------------------------------------------------------
| copyinstr (0x43ef4) -- copies the path STRING from user space into the kernel pathname buffer
| (called by pn_get, between E and L).  This is the prime suspect: a user-space READ on 040.
| Bracket it: 'y' (entry) + dump `from` (user src), then call the original, then 'z' (returned) +
| dump the return.  y with NO z  => hang INSIDE copyinstr (user read loop / fault that never
| resolves) -- exactly matching the builds that reach E but not L.  Gated by g_inexec, capped.
	.globl	copyinstr
copyinstr:
	tstl	g_inexec
	beqw	Lci_tail
	movel	Lci_n,%d0
	cmpil	&4,%d0
	bccw	Lci_tail
	addql	&1,%d0
	movel	%d0,Lci_n
	linkw	%fp,&0
	pea	0x79			| 'y' -- copyinstr entered
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%fp@(8),%sp@-		| `from` = user source address
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%fp@(20),%sp@-		| arg4 (&copied / maxlen depending on ABI)
	movel	%fp@(16),%sp@-		| arg3
	movel	%fp@(12),%sp@-		| arg2 (to)
	movel	%fp@(8),%sp@-		| arg1 (from)
	jsr	copyinstr_orig
	lea	%sp@(16),%sp
	movel	%d0,%sp@-		| save+dump return value
	pea	0x7a			| 'z' -- copyinstr returned
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%sp@,%sp@-		| dump return
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%sp@+,%d0		| restore return
	unlk	%fp
	rts
Lci_tail:
	jmp	copyinstr_orig

	.globl	bread
bread:
	tstl	g_inexec
	beqw	Lb_go
	movel	Lb_n,%d0
	cmpil	&8,%d0
	bccw	Lb_go			| cap at 8 markers
	addql	&1,%d0
	movel	%d0,Lb_n
	pea	0x42			| 'B'
	jsr	serdbg_mark
	addqw	&4,%sp
Lb_go:
	jmp	bread_orig

	.globl	biodone
biodone:
	tstl	g_inexec
	beqw	Ld_go
	movel	Ld_n,%d0
	cmpil	&8,%d0
	bccw	Ld_go			| cap at 8 markers
	addql	&1,%d0
	movel	%d0,Ld_n
	pea	0x44			| 'D'
	jsr	serdbg_mark
	addqw	&4,%sp
Ld_go:
	jmp	biodone_orig

| ---------------------------------------------------------------------------
| lookup-path sub-markers (gated by g_inexec; capped at 4 each).  s5 root lookup of "sbin"/
| "init" goes: lookuppn(L) -> pn_getcomponent(c, parse "sbin") -> s5lookup -> dnlc_lookup(n,
| name cache) -> dirlook(k, scan dir block via bread) -> iget(i, read inode via bread) -> B/D.
| The hang is BEFORE bread, so this pins it:
|   L, no c            -> hang in lookuppn before parsing the first component (rootvp/preempt).
|   c, no n            -> hang in/after pn_getcomponent (string parse of the path).
|   n, no k            -> hang in s5lookup between the name-cache miss and the dir scan.
|   k, no B            -> hang in dirlook before its first disk read.

	.globl	pn_getcomponent
pn_getcomponent:
	tstl	g_inexec
	beqw	Lc_go
	movel	Lc_n,%d0
	cmpil	&4,%d0
	bccw	Lc_go
	addql	&1,%d0
	movel	%d0,Lc_n
	pea	0x63			| 'c'
	jsr	serdbg_mark
	addqw	&4,%sp
Lc_go:
	jmp	pn_getcomponent_orig

	.globl	dnlc_lookup
dnlc_lookup:
	tstl	g_inexec
	beqw	Ln_go
	movel	Ln_n,%d0
	cmpil	&4,%d0
	bccw	Ln_go
	addql	&1,%d0
	movel	%d0,Ln_n
	pea	0x6e			| 'n'
	jsr	serdbg_mark
	addqw	&4,%sp
Ln_go:
	jmp	dnlc_lookup_orig

	.globl	dirlook
dirlook:
	tstl	g_inexec
	beqw	Lk_go
	movel	Lk_n,%d0
	cmpil	&4,%d0
	bccw	Lk_go
	addql	&1,%d0
	movel	%d0,Lk_n
	pea	0x6b			| 'k'
	jsr	serdbg_mark
	addqw	&4,%sp
Lk_go:
	jmp	dirlook_orig

	.globl	iget
iget:
	tstl	g_inexec
	beqw	Li_go
	movel	Li_n,%d0
	cmpil	&4,%d0
	bccw	Li_go
	addql	&1,%d0
	movel	%d0,Li_n
	pea	0x69			| 'i'
	jsr	serdbg_mark
	addqw	&4,%sp
Li_go:
	jmp	iget_orig

| ---------------------------------------------------------------------------
| u_trap (0x5a47e) -- dump (usp, trapPC) for EVERY user-mode trap whose PC is in user space
| (>=0x80000000), capped at 16.  u_trap's arg1 (sp@(4) at entry) = the captured usp; the saved
| trap PC is at sp@(70) (u_trap reads fp@(74); fp@(8)=arg1 so PC = arg1+66 = sp@(70) at entry).
| Trajectory of USP across proc 1's user life:  icode's first fetch may fault (PC=0x80800000,
| usp=stale) -> after the lea runs, USP should become 0x8080002A; the exec trap#0 is PC=0x8080000C.
| If usp is NEVER 0x8080002A -> icode's `lea` never set USP (or the capture is broken); if it is
| set then later lost -> a switch/return path drops it.  'T' = a user-mode trap dump follows.
	.globl	u_trap
u_trap:
	movel	%sp@(70),%d0		| saved trap PC
	cmpil	&0x80000000,%d0
	bcsw	Lut_go			| kernel-space trap -> skip
	movel	Lut_n,%d0
	cmpil	&16,%d0
	bccw	Lut_go
	addql	&1,%d0
	movel	%d0,Lut_n
	pea	0x54			| 'T'
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%sp@(4),%sp@-		| usp (u_trap arg1)
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%sp@(70),%sp@-		| saved trap PC
	jsr	serdbg_hex
	addqw	&4,%sp
Lut_go:
	jmp	u_trap_orig

| ===========================================================================
| Exec sub-step DIRECT markers (one-shot each, register/stack-transparent tail-jmps).
| Placed because the STREAMS cmn_err path (e.g. the execmap wrapper) does NOT surface in a
| hung boot -- only DIRECT serdbg_mark chars do (proven: M/E reached the serial line).
| exece path order:  exece(E) -> lookuppn(/sbin/init) -> gexec(G) -> execsw -> elfexec(F)
|                    [elfexec calls execmap to map segments] -> relvm(V, teardown old VM)
|                    -> setregs(X, set up user regs for the new image) -> rte to init's entry.
| Localization (E already fires):
|   E, no G            -> hang in pn_get/lookuppn = namei("/sbin/init") FS disk read.
|   G, no F            -> hang in gexec before the format dispatch (ELF header read / checks).
|   F, no V            -> hang in elfexec mapping the new image (execmap / user-VM hat build).
|   V, no X            -> hang/crash in relvm (old-VM teardown = hat_free family, 040 8-byte
|                         stride suspect from 2026-06-23).
|   X present          -> new image set up; hang in the final return-to-user (setregs/rte).
| --add-symbol {gexec,elfexec,relvm,setregs}_orig + --weaken-symbol each.

	.globl	gexec
gexec:
	movel	Lg_n,%d0
	bnew	Lg_go
	moveq	&1,%d0
	movel	%d0,Lg_n
	pea	0x47			| 'G' -- gexec entered (path /sbin/init resolved)
	jsr	serdbg_mark
	addqw	&4,%sp
Lg_go:
	jmp	gexec_orig

	.globl	elfexec
elfexec:
	movel	Lf_n,%d0
	bnew	Lf_go
	moveq	&1,%d0
	movel	%d0,Lf_n
	pea	0x46			| 'F' -- elfexec entered (mapping the new ELF image)
	jsr	serdbg_mark
	addqw	&4,%sp
Lf_go:
	jmp	elfexec_orig

	.globl	relvm
relvm:
	movel	Lv_n,%d0
	bnew	Lv_go
	moveq	&1,%d0
	movel	%d0,Lv_n
	pea	0x56			| 'V' -- relvm entered (tearing down the old icode VM)
	jsr	serdbg_mark
	addqw	&4,%sp
Lv_go:
	jmp	relvm_orig

	.globl	setregs
setregs:
	movel	Lx_n,%d0
	bnew	Lx_go
	moveq	&1,%d0
	movel	%d0,Lx_n
	pea	0x58			| 'X' -- setregs entered (new image OK; setting up return-to-user)
	jsr	serdbg_mark
	addqw	&4,%sp
Lx_go:
	jmp	setregs_orig
	nop				| pad .text to keep text/data contiguous (loader copies as one block)

	.data
	.even
Lex_n:
	.long	0
Lg_n:
	.long	0
Lf_n:
	.long	0
Lv_n:
	.long	0
Lx_n:
	.long	0
Ll_n:
	.long	0
Lb_n:
	.long	0
Ld_n:
	.long	0
Lc_n:
	.long	0
Ln_n:
	.long	0
Lk_n:
	.long	0
Li_n:
	.long	0
Lci_n:
	.long	0
Lut_n:
	.long	0
g_inexec:
	.long	0
