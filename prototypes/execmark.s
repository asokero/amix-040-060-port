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
| --- read the icode as it sits in USER space (lfuword = moves SFC=1 user-data, the same path
|     proc 1's instruction fetch uses for mapping).  '!' then user[0x80800000] (expect 0x4FFB0170
|     = the lea encoding) + user[0x8080002C] (L%stack area, expect 0x8080000E path ptr nearby).
|     If these match the kernel icode -> user memory/mapping is CORRECT and the bug is purely USP
|     (icode's lea ran on valid code but USP was not written on 040).  If garbage -> the icode
|     page is ALIASED (execution fetched a different phys page than copyout wrote / lfuword sees). ---
	pea	0x21			| '!' -- user icode bytes follow
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0x80800000,%sp@-	| user[0x80800000] = icode[0]
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	&0x8080002c,%sp@-	| user[0x8080002C] (near L%stack path ptr)
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
| --- cache-coherency test: push+invalidate all caches (cpusha bc) then RE-READ user[0x80800000].
|     If it becomes 0x4FFB0170 -> copyout's icode write sat in the copyback D-cache (or the read
|     hit a stale line) -> a 68040 I/D cache-coherency bug (exec/copyout must cpush the user page).
|     If still 0x00000000 -> the PTE for 0x80800000 maps to a zero phys page (a hat/mapping bug:
|     the page faulted to a different phys than copyout wrote). ---
| --- 040-ONLY from here (cpusha/pflusha).  The 030 baseline is DONE (golden reference captured)
|     and must NOT be booted with this build.  cpusha bc (push+invalidate caches) then pflusha
|     (invalidate the ATC = VA->phys cache) then RE-READ user[0x80800000].
|     'C' value = post-cpusha (cache only); 'A' value = post-pflusha (cache + ATC).
|     A == 0x4FFB0170 -> the PTE was correct (icode page); a stale data-ATC entry hid it -> fix is
|       an ATC flush after copyout.  A == 0 -> the PTE itself maps 0x80800000 to a ZERO page (the
|       icode page was remapped to a fresh phys after copyout) -> a hat/anon VM remap bug. ---
	pea	0x43			| 'C' -- post-cpusha re-read follows
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0xf4f8			| cpusha bc -- push+invalidate both caches
	movel	&0x80800000,%sp@-	| re-read user[0x80800000] after cpusha (cache only)
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x41			| 'A' -- post-pflusha re-read follows
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0xf518			| pflusha -- invalidate the ATC (VA->phys)
	movel	&0x80800000,%sp@-	| re-read user[0x80800000] after pflusha (cache + ATC)
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
| --- dump proc 1's live URP + walk it to the leaf PTE for 0x80800000.  copyout ran with
|     urp=7A6C000; if the URP here differs -> proc 1's URP itself changed (a context/resume bug);
|     if same -> the tree CONTENT changed.  Walk (040 7/7/6, tables in <1GB phys -> DTT0 identity):
|       Aidx=(va>>25)&7f=0x40 -> root@(urp+0x100) ; Bidx=(va>>18)&7f=0x20 ; leaf=(B&0xffffff00)+
|       ((va>>12)&3f)*4 (== hat040 vatopte mask).  Dump URP, root desc, B desc, leaf PTE. ---
	pea	0x55			| 'U' (URP + walk follow)
	jsr	serdbg_mark
	addqw	&4,%sp
	.word	0x4e7a,0x1806		| movec %urp,%d1
	movel	%d1,%sp@-		| URP
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%d1,%a0
	movel	%a0@(0x100),%d2		| root desc (Aidx 0x40 *4 = 0x100)
	movel	%d2,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%d2,%d0
	andil	&0xffffff00,%d0		| pointer-table base
	moveal	%d0,%a0
	movel	%a0@(0x80),%d3		| B desc (Bidx 0x20 *4 = 0x80)
	movel	%d3,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%d3,%d0
	andil	&0xffffff00,%d0		| leaf-table base
	moveal	%d0,%a0
	movel	%a0@,%d4		| leaf PTE (Cidx (va>>12)&3f = 0 -> offset 0)
	movel	%d4,%sp@-
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
| --- CRASH probe (2026-06-26 PM): the FFFFFFFF fault does NOT reach as_fault (SIGBUS via
|     as_segat=NULL), but u_trap IS called.  When the saved trap PC is in sh's malloc crash region
|     [0x80002400,0x80002600], walk the URP for 0x80010000 and dump (leaf PTE = crash-time pfn) +
|     (RAM @ pfn<<12 +0xe48, DTT0 identity).  Compare to exec-time pfn 7CAB: pfn same + RAM FFFFFFFF
|     -> page stayed mapped, RAM reused = double-alloc/page-free bug; pfn changed -> silent remap.
|     Balanced moveml save/restore leaves sp unchanged before the normal u_trap logic.  Cap 4. ---
	movel	%sp@(70),%d0		| saved trap PC
	cmpil	&0x80002400,%d0
	bcsw	Lcr2_skip
	cmpil	&0x80002600,%d0
	bccw	Lcr2_skip
	movel	Lcr2_n,%d0
	cmpil	&4,%d0
	bccw	Lcr2_skip
	addql	&1,%d0
	movel	%d0,Lcr2_n
	moveml	%d0-%d3/%a0-%a2,%sp@-	| save 7 regs (28 bytes); sp restored below
	.word	0x4e7a,0x0806		| movec %urp,%d0
	moveal	%d0,%a2
	movel	&0x80010000,%d1		| va
	movel	%d1,%d0
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&1,%d0			| va>>25
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a2@(0,%d0:l),%d0	| root[Aidx]
	andil	&0xfffffe00,%d0
	moveal	%d0,%a2
	movel	%d1,%d0
	lsrl	&8,%d0
	lsrl	&8,%d0
	lsrl	&2,%d0			| va>>18
	andil	&0x7f,%d0
	asll	&2,%d0
	movel	%a2@(0,%d0:l),%d0	| ptr[Bidx]
	andil	&0xffffff00,%d0
	moveal	%d0,%a2
	movel	%d1,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0			| va>>12
	andil	&0x3f,%d0
	asll	&2,%d0
	movel	%a2@(0,%d0:l),%d3	| d3 = leaf PTE (crash-time pfn)
	movel	%d3,%d0
	andil	&0xfffff000,%d0
	oril	&0xe48,%d0
	moveal	%d0,%a2
	movel	%a2@,%d0		| RAM @ 0x80010e48
	movel	%d0,%sp@-		| RAM value
	movel	%d3,%sp@-		| leaf PTE
	pea	Lcr2_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
	moveml	%sp@+,%d0-%d3/%a0-%a2	| restore; sp back to entry value
Lcr2_skip:
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

| setregs (0x58b62) runs LAST in the exec chain (F->V->X) -- by here the new user image's
| stack is built (execpoststack copied argc/argv/envp/auxv to the top of the user stack) and
| setregs writes the new user SP into the saved trap frame (u.u_ar0[0], == saved USP, proven
| by the icode case where u.u_ar0[0]=0x8080002A).  So AFTER setregs_orig runs, u.u_ar0[0] is
| the NEW user SP pointing at [argc][argv..][0][envp..][0][auxv pairs..].  We dump a window of
| longwords from that SP so the auxv is visible RAW (no in-asm parsing): scan the dump offline
| for AT_BASE (type 7) followed by ld.so's load base = voffset.  For init this MUST read 7 then
| C1000000 (the known-good interp base).  If a CHILD reads 7 then 0x80000000 (the program base)
| -> AT_BASE is wrong for user-initiated exec -> _rt_setup places _rt_bind at program_base+off
| -> the PLT[0] `jmp *GOT[2]` wild-jumps into the program (observed PC 0x800024FE).
| Capped at 5 execs (init + first children).  lfuword (moves SFC=user) reads user VA safely
| (faults caught by onfault -> returns -1, never crashes the kernel).
	.data
	.even
Lxf_n:
	.long	0
Lxf_msg:
	.asciz	"DBG setregs FAIL ret=%d psargs-uva=%x nc=%x -> exece sends silent SIGKILL"
	.even
	.text
	.globl	setregs
setregs:
	linkw	%fp,&0
	moveml	%d2-%d6,%sp@-
	movel	%fp@(8),%sp@-		| arg1 = struct uarg *
	jsr	setregs_orig
	addqw	&4,%sp
	movel	%d0,%d2			| save setregs return value
| setregs's ONLY failure exit is copyin(uap@(56)-uap@(12) -> u_psargs) = EFAULT, and exece
| answers a nonzero setregs return with a SILENT psignal(p,9) (0x566b6) -- the prime "Killed"
| suspect.  Log every failure (uncapped by the Lx_n dump cap -- kills happen way past 5 execs):
| ret + the user VA the copyin read (a xxx800-tail = 2KB-parity smoking gun, execstk_addr).
	tstl	%d2
	beqw	Lxf_ok
	movel	Lxf_n,%d0
	cmpil	&16,%d0
	bccw	Lxf_ok
	addql	&1,%d0
	movel	%d0,Lxf_n
	moveal	%fp@(8),%a0
	movel	%a0@(16),%sp@-		| nc (copyin len = min(nc,79))
	movel	%a0@(56),%d0
	subl	%a0@(12),%d0
	movel	%d0,%sp@-		| user VA of the arg strings copyin reads back
	movel	%d2,%sp@-		| setregs ret (14=EFAULT)
	pea	Lxf_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(20),%sp
Lxf_ok:
| v2 (2026-07-03, the auxv-missing-AT_BASE kills): dump the auxv AS RTLD WILL SEE IT.
| Every SIGKILL victim dies at _rt_setup+0xE2 = "auxv has no AT_BASE (type 7)" -- but elfexec
| ALWAYS writes AT_BASE when the interp mapped (and rtld running proves it did).  So the vector
| the process READS differs from what the kernel BUILT.  setregs runs LAST in exec (after the
| old-as -> new-as stack-block move through stock-030 hat_exec), so an lfuword walk from the
| final USP shows the block in its final state.  Walk exactly like crt/rtld:
| [argc][argv 0..argc-1][0][envp ...][0][auxv].  Output: X<pid> <usp> a<auxvaddr> <20 longs>.
| Dying pids (match DBG SIGKILL lines): zeros at auxv = move lost the tail page; a correct
| auxv +-2KB away = layout parity bug; FFFFFFFF = stock hat_exec stray-SDE garbage.
	movel	Lx_n,%d3
	cmpil	&40,%d3
	bccw	Lx_done			| past cap -> just return
	addql	&1,%d3
	movel	%d3,Lx_n
	pea	0x58			| 'X' -- setregs done; pid + usp + auxv dump follow
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	u+0x730,%a0		| curproc
	moveal	%a0@(264),%a0		| p_pidp
	movel	%a0@(4),%sp@-		| pid (correlate with DBG SIGKILL pid=)
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x20
	jsr	serdbg_mark
	addqw	&4,%sp
	moveal	u+0x864,%a0		| a0 = u.u_ar0 (saved register frame)
	movel	%a0@,%d4		| d4 = u.u_ar0[0] = new user SP (top of arg/auxv block)
	movel	%d4,%sp@-		| dump the SP itself
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%d4,%sp@-
	jsr	lfuword			| d0 = argc
	addqw	&4,%sp
	lsll	&2,%d0
	addl	%d0,%d4
	addql	&8,%d4			| skip argc + argv[0..argc-1] + NULL
	movel	&255,%d5		| envp walk bound (env can be large)
Lx_env:
	movel	%d4,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	addql	&4,%d4
	tstl	%d0
	beqw	Lx_aux			| envp NULL hit -> d4 = auxv start
	dbra	%d5,Lx_env
Lx_aux:
	pea	0x61			| 'a' -- auxv start address (as rtld computes it)
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%d4,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%d4,%d6			| d6 = running user address
	moveq	&19,%d5			| 20 longwords = 10 auxv pairs (8 real + NULL + slack)
Lx_dmp:
	pea	0x20
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%d6,%sp@-
	jsr	lfuword			| d0 = *(user d6) (or -1 on fault)
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	addql	&4,%d6
	dbra	%d5,Lx_dmp
	pea	0x0a			| newline terminates the X record
	jsr	serdbg_mark
	addqw	&4,%sp
| --- sh partial data/bss page dump (2026-06-26 PM): meaningful only for /sbin/sh execs (identify
|     via the auxv string above).  sh's data page 0x80010000 = file data [0x80010000,0x800106e8)
|     + bss tail that execmap zeroes via bzeroba(end, roundup(end,4096)-end).  The crash reads
|     0xFFFFFFFF at 0x80010e48 (upper 2KB of this page) -- but bzeroba's range covers it, so dump
|     ACROSS the 2KB boundary 0x80010800 to see EXACTLY where the zeros stop: if [..0x800107fc]=0
|     and [0x80010800..]=FFFFFFFF -> a 2KB straggler in the partial-page tail zero-fill (the bug).
|     At setregs time the page is present (faulted during elfexec/execmap, earlier in the chain),
|     so lfuword reads the real RAM.  'P'<sentinel @0x80010000> 'B'<24 longs @0x800107c0> 'g'<@0x80010e48>.
	pea	0x50			| 'P' -- sentinel: 0x80010000 (file data start; expect file content, not -1)
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0x80010000,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	pea	0x42			| 'B' -- 24 longs spanning the 2KB boundary 0x80010800
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0x800107c0,%d6		| 0x40 below the 2KB boundary
	moveq	&23,%d5			| 24 longs -> 0x800107c0 .. 0x80010820
Lx_pp:
	movel	%d6,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	addql	&4,%d6
	dbra	%d5,Lx_pp
	pea	0x67			| 'g' -- the malloc bss global @0x80010e48 (what the crash dereferences)
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	&0x80010e48,%sp@-
	jsr	lfuword
	addqw	&4,%sp
	movel	%d0,%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
Lx_done:
	movel	%d2,%d0			| restore setregs return value
	moveml	%fp@(-20),%d2-%d6
	unlk	%fp
	rts

| exhd_getmap(a1,a2,a3,a4,&out): gexec maps the ELF exec header here (segmap-backed), and
| the `hat_pteload pfn mismatch va=40448800` fires during this map.  If segmap delivers the
| WRONG physical page, *out points at garbage -> gexec reads a bad magic -> no execsw entry
| matches -> ENOEXEC -> elfexec(F) is never reached (exactly the observed G-but-no-F).  This
| wrapper dumps the result so we can SEE the header: 'H' ret out-VA magic [+0x4 +0x8].
| ELF magic must read 7F454C46.  Single-call save/restore (exhd_getmap is NOT idempotent --
| it refcounts the segmap slot).  --add-symbol exhd_getmap_orig=0x5704e + --weaken exhd_getmap.
	.globl	exhd_getmap
exhd_getmap:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	movel	%fp@(24),%sp@-		| arg5 = &out (mapped header ptr written here)
	movel	%fp@(20),%sp@-		| arg4
	movel	%fp@(16),%sp@-		| arg3
	movel	%fp@(12),%sp@-		| arg2
	movel	%fp@(8),%sp@-		| arg1
	jsr	exhd_getmap_orig
	lea	%sp@(20),%sp		| pop 5 args
	movel	%d0,%d2			| save return value
	movel	Lh_n,%d3
	cmpil	&4,%d3
	bccw	Lh_go			| gate: only the first 4 calls
	addql	&1,%d3
	movel	%d3,Lh_n
	pea	0x48			| 'H' -- exhd_getmap (exec header map) result follows
	jsr	serdbg_mark
	addqw	&4,%sp
	movel	%d2,%sp@-		| ret (0 = header mapped OK)
	jsr	serdbg_hex
	addqw	&4,%sp
	moveal	%fp@(24),%a0		| a0 = &out
	moveal	%a0@,%a2		| a2 = mapped header VA
	movel	%a2,%sp@-		| header VA (expect a segmap addr ~0x40448xxx)
	jsr	serdbg_hex
	addqw	&4,%sp
	tstl	%d2
	bnew	Lh_go			| getmap failed -> ptr invalid, skip the byte dump
	movel	%a2@,%sp@-		| magic (ELF = 7F454C46)
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%a2@(4),%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
	movel	%a2@(8),%sp@-
	jsr	serdbg_hex
	addqw	&4,%sp
Lh_go:
	movel	%d2,%d0			| restore return value
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	rts
	nop				| pad .text to keep text/data contiguous (loader copies as one block)
	nop
	nop
	nop
	nop
	nop
	nop

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
Lh_n:
	.long	0
Lcr2_n:
	.long	0
	.even
Lcr2_msg:
	.asciz	"DBG uCRASH PC-malloc 80010000 leafPTE=%x RAM@e48=%x (exec-pfn=7CAB)"
	.even
g_inexec:
	.long	0
