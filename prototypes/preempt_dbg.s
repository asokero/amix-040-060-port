| preempt_dbg.s -- DIAGNOSTIC + TOURNIQUET wrapper around preempt (0xb9008, GLOBAL T).
| ISSUE-7: the recurring PANIC pc=0x4000001E is preempt's class-indirect call gone wild:
|   preempt: moveal u+0x730,%a0        <- u.u_procp read VIA THE FIXED u-area VA
|            moveal %a0@(236),%a1      <- p_clfuncs
|            jsr ([44,%a1])            <- cl_preempt -> jumped to 0x4000001E
| ktrap_latch proved the chain (stack: preempt+0x18 / u_trap+0x104; A1=0x00F80C1E ROM at
| fault = consistent with u_procp==0: *(0+236)=*(0xEC)=page-0 leftover ROM ptr, then
| *(ROM+44)=0x4000001E).  I.e. the fixed VA maps a freed/zeroed page at that moment.
| The remaining question is WHICH link is broken: stale uarea_pt (mapping wrong) vs
| unloaded kvsegu leaf (expected PTEs empty) vs content corruption (mapping right,
| u_procp wrong).  This wrapper answers it AND keeps the machine alive:
|
| FAST PATH: read u_procp via the fixed VA and the curproc GLOBAL (the two views ttrap
| keeps consistent-by-design).  If equal and nonzero -> tail-jmp preempt_orig (2 loads +
| compare overhead on a not-hot path).
|
| DIVERGENCE: dump (cmn_err CE_WARN, latched, cap 4):
|   PREEMPT1 uprocp / curproc / curproc->p_segu(+252) / caller
|   PREEMPT2 live uarea_pt[0],[1] (kptr040[0]&~0xFF) vs the kptr040-walked EXPECTED leaf
|            PTEs for p_segu (path-V idiom) + the raw pointer-table entry (Aent)
|   PREEMPT3 u-area fingerprint: longs at u+0, u+4, u+0x318, u+0x31C (zeros => zfod page;
|            regsave/ctx junk => a real-but-wrong u-area)
|   PREEMPT4 curproc's p_clfuncs + its cl_preempt slot (the CORRECT call target)
| then TOURNIQUET: re-execute the original preempt body using the CURPROC GLOBAL instead
| of the fixed-VA read (validated: clfuncs in kernel data range, target in text range),
| so the system survives where it used to panic -- surviving IS the diagnosis check.
| Any validation failure -> tail-jmp preempt_orig (old behaviour, ktrap_latch still there).
|
| ROBUSTNESS: every deref guarded (null/odd/range).  Only memory written: Lpd_n.
| --weaken-symbol preempt + --add-symbol preempt_orig=.text:0x000b9008 (relink-040-dbg.sh);
| 29 caller reloc sites all rebind to this wrapper.

	.text
	.globl	preempt
preempt:
	linkw	%fp,&0
	moveml	%d2-%d5/%a2-%a4,%sp@-	| 7 regs = 28 bytes at fp@(-28)
	moveal	u+0x730,%a2		| a2 = u.u_procp via the FIXED u-area VA (orig's read)
	moveal	curproc,%a3		| a3 = curproc global (ttrap trap_ret3's view)
	cmpal	%a2,%a3
	bnew	Lpd_div
	movel	%a2,%d0
	beqw	Lpd_div			| both NULL: pathological too
	moveml	%fp@(-28),%d2-%d5/%a2-%a4
	unlk	%fp
	jmp	preempt_orig
| ===================== divergence: dump (latched), then tourniquet =====================
Lpd_div:
	movel	Lpd_n,%d0
	cmpil	&4,%d0
	bccw	Lpd_fix			| dumped enough already; still fix up & survive
	addql	&1,%d0
	movel	%d0,Lpd_n
| --- PREEMPT1: uprocp / curproc / p_segu / caller ---
	moveq	&0,%d2			| d2 = p_segu (0 if curproc unusable)
	movel	%a3,%d0
	beqw	Lpd_m1
	btst	&0,%d0
	bnew	Lpd_m1
	movel	%a3@(252),%d2
Lpd_m1:
	movel	%fp@(4),%sp@-		| caller
	movel	%d2,%sp@-		| p_segu
	movel	%a3,%sp@-		| curproc
	movel	%a2,%sp@-		| uprocp (fixed-VA read)
	pea	Lpd_s1
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- PREEMPT2: live uarea_pt[0..1] vs expected kvsegu leaf PTEs for p_segu ---
	moveq	&0,%d3			| d3 = Aent
	moveq	&0,%d4			| d4 = exp0
	moveq	&0,%d5			| d5 = exp1
	tstl	%d2
	beqw	Lpd_gotexp		| no p_segu -> no expectation to compute
	movel	%d2,%d0			| kptr040 walk for p_segu (resume040 path-V idiom)
	moveq	&18,%d1
	lsrl	%d1,%d0
	subil	&4096,%d0
	asll	&2,%d0
	addl	kptr040,%d0
	moveal	%d0,%a0
	movel	%a0@,%d3		| d3 = pointer-table entry (Aent)
	movel	%d3,%d0
	andil	&3,%d0
	cmpil	&2,%d0
	bcsw	Lpd_gotexp		| invalid desc -> leave exp0/exp1 = 0
	movel	%d3,%d0
	andil	&0xffffff00,%d0
	moveal	%d0,%a0			| a0 = leaf table base
	movel	%d2,%d0
	lsrl	&8,%d0
	lsrl	&4,%d0
	andil	&0x3f,%d0
	asll	&2,%d0
	moveal	%a0,%a1
	addal	%d0,%a1
	movel	%a1@,%d4		| exp0 = leaf PTE for p_segu
	movel	%a1@(4),%d5		| exp1 = leaf PTE for p_segu+0x1000 (next slot)
Lpd_gotexp:
	moveal	kptr040,%a0		| live uarea_pt = kptr040[0] & ~0xFF
	movel	%a0@,%d0
	andil	&0xffffff00,%d0
	moveal	%d0,%a0
	movel	%d5,%sp@-		| exp1
	movel	%d4,%sp@-		| exp0
	movel	%d3,%sp@-		| Aent
	movel	%a0@(4),%sp@-		| apt1
	movel	%a0@,%sp@-		| apt0
	pea	Lpd_s2
	pea	2
	jsr	cmn_err
	lea	%sp@(28),%sp
| --- PREEMPT3: u-area fingerprint through the (suspect) fixed VA ---
	movel	u+0x31c,%sp@-
	movel	u+0x318,%sp@-
	movel	u+4,%sp@-
	movel	u+0,%sp@-
	pea	Lpd_s3
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- PREEMPT4: the CORRECT class pointers from the curproc global ---
	movel	%a3,%d0
	beqw	Lpd_fix
	btst	&0,%d0
	bnew	Lpd_fix
	moveal	%a3@(236),%a0		| clf = p_clfuncs
	movel	%a0,%d0
	btst	&0,%d0
	bnew	Lpd_m4z
	cmpil	&0x07000000,%d0
	bcsw	Lpd_m4z
	cmpil	&0x07400000,%d0
	bccw	Lpd_m4z
	movel	%a0@(44),%sp@-		| clpre = cl_preempt slot
	movel	%a0,%sp@-
	braw	Lpd_m4p
Lpd_m4z:
	clrl	%sp@-			| clfuncs implausible: print it raw, target 0
	movel	%a0,%sp@-
Lpd_m4p:
	pea	Lpd_s4
	pea	2
	jsr	cmn_err
	lea	%sp@(16),%sp
| ===================== tourniquet: original body via the curproc GLOBAL =====================
Lpd_fix:
	moveml	%fp@(-28),%d2-%d5/%a2-%a4
	moveal	curproc,%a1
	movel	%a1,%d0
	beqw	Lpd_orig		| curproc gone too: nothing to fix with, old behaviour
	btst	&0,%d0
	bnew	Lpd_orig
	moveal	%a1@(236),%a0		| clfuncs (must be kernel text/data/bss)
	movel	%a0,%d0
	btst	&0,%d0
	bnew	Lpd_orig
	cmpil	&0x07000000,%d0
	bcsw	Lpd_orig
	cmpil	&0x07400000,%d0
	bccw	Lpd_orig
	movel	%a1@(232),%sp@-		| push p_clproc (orig leaves it; unlk cleans)
	moveal	%a0@(44),%a0		| cl_preempt
	movel	%a0,%d0
	btst	&0,%d0
	bnew	Lpd_pop
	cmpil	&0x07000000,%d0
	bcsw	Lpd_pop
	cmpil	&0x07100000,%d0		| must be TEXT
	bccw	Lpd_pop
	jsr	%a0@			| cl_preempt(clproc)
	jsr	swtch
	moveal	%d0,%a0			| orig's return convention
	unlk	%fp			| also discards the pushed arg
	rts
Lpd_pop:
	addqw	&4,%sp
Lpd_orig:
	unlk	%fp
	jmp	preempt_orig
	nop				| pad .text to a multiple of 4 (relink contiguity)
	nop

	.data
	.even
Lpd_s1:
	.asciz	"DBG PREEMPT1 uprocp=%x curproc=%x psegu=%x caller=%x"
	.even
Lpd_s2:
	.asciz	"DBG PREEMPT2 apt0=%x apt1=%x Aent=%x exp0=%x exp1=%x"
	.even
Lpd_s3:
	.asciz	"DBG PREEMPT3 u0=%x u4=%x u318=%x u31C=%x"
	.even
Lpd_s4:
	.asciz	"DBG PREEMPT4 clf=%x clpre=%x"
	.even
Lpd_n:
	.long	0
