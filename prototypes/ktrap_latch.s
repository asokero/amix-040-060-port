| ktrap_latch.s -- "first-fault latch" WRAPPER around k_trap (0x5a0e8, GLOBAL T): the FIRST
| time a kernel-mode fault lands with its exception-frame PC inside the u-area/kvseg VA range
| [0x40000000, 0x4C000000), dump a raw window of the frame + pre-exception stack + saved
| A0-A3 + the first longs of vbinttab / int2_tbl via cmn_err, then continue into the
| original k_trap unchanged.
|
| WHY: the recurring reboot/login panic shows pc=0x4000001E (ISSUE-5's true root cause is
| still unknown; two prior haltsys fixes addressed real-but-different issues and the panic
| persists).  Something JUMPS to 0x4000001E; by the time the panic prints, the cascade has
| destroyed the evidence.  This latch captures the very first such fault: the CPU frame
| tells us PC/format/vector, the stack longs give jsr return-address candidates (= the
| caller), saved A0-A3 expose a `jsr (%a0)`-style culprit (A0=0x4000001E), and the two
| interrupt callback tables show whether a vector slot was corrupted to point there.
|
| FRAME POINTER: ttrap.s nullvect pushes D0-D7/A0-A6 (60 bytes), ktraps pushes USP as the
| arg; at k_trap entry sp@(4)=USP slot, so after `link %fp,&0`, a2 = %fp@(8) = &USP slot.
| Saved D0-D7/A0-A6 at a2+4..a2+63 (saved A0 at a2+36 .. A3 at a2+48); the CPU exception
| frame begins at a2+64: SR word at +64, PC long at +66 (unaligned long read is legal on
| 040), format/vector word at +70, extended frame words from +72; pre-exception stack top
| from about +80 up.
|
| Latch: at most 2 firings (Lkl_n), then pass-through only.  The wrapper modifies NO memory
| other than Lkl_n; cmn_err clobbers d0/d1/a0/a1 only (fine -- k_trap is a C function and
| the frame contents are untouched).
|
| Mechanism: objcopy --add-symbol k_trap_orig=.text:0x5a0e8 + --weaken-symbol k_trap; this
| strong wrapper dumps then TAIL-JMPs to k_trap_orig with the stack restored to the original
| `jsr k_trap` state, so k_trap_orig's rts + d0 reach ktraps unchanged.

	.text
	.globl	k_trap
k_trap:
	linkw	%fp,&0
	movel	%a2,%sp@-		| save a2 (cmn_err preserves a2-a6, so frame survives)
	movel	%a3,%sp@-		| save a3 (parity with ktrap_dbg.s discipline)
	lea	%fp@(8),%a2		| a2 = frame pointer (&USP slot)
| --- gate: frame PC inside [0x40000000, 0x4C000000)? ---
	movel	%a2@(66),%d0		| exception-frame PC (unaligned long: legal on 040)
	cmpil	&0x40000000,%d0
	bcsw	Lkl_done		| pc < 0x40000000 -> not ours
	cmpil	&0x4C000000,%d0
	bccw	Lkl_done		| pc >= 0x4C000000 -> not ours
| --- latch: allow at most 2 firings ---
	movel	Lkl_n,%d1
	cmpil	&2,%d1
	bccw	Lkl_done
	addql	&1,%d1
	movel	%d1,Lkl_n
| --- LATCH1: frame+64 (SR|PChi), +68 (PClo|fmt/vec), +72, +76 ---
	movel	%a2@(76),%sp@-
	movel	%a2@(72),%sp@-
	movel	%a2@(68),%sp@-
	movel	%a2@(64),%sp@-
	pea	Lkl_m1
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- LATCH2: frame+80..+92 (pre-exception stack top: jsr return-address candidates) ---
	movel	%a2@(92),%sp@-
	movel	%a2@(88),%sp@-
	movel	%a2@(84),%sp@-
	movel	%a2@(80),%sp@-
	pea	Lkl_m2
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- LATCH3: frame+96..+108 (more stack) ---
	movel	%a2@(108),%sp@-
	movel	%a2@(104),%sp@-
	movel	%a2@(100),%sp@-
	movel	%a2@(96),%sp@-
	pea	Lkl_m3
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- LATCH4: saved A0-A3 (a jsr (%a0) culprit shows A0=0x4000001E) ---
	movel	%a2@(48),%sp@-		| saved A3
	movel	%a2@(44),%sp@-		| saved A2
	movel	%a2@(40),%sp@-		| saved A1
	movel	%a2@(36),%sp@-		| saved A0
	pea	Lkl_m4
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- LATCH5: first 4 longs of vbinttab (GLOBAL common) ---
	movel	vbinttab+12,%sp@-
	movel	vbinttab+8,%sp@-
	movel	vbinttab+4,%sp@-
	movel	vbinttab,%sp@-
	pea	Lkl_m5
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- LATCH6: first 4 longs of int2_tbl (GLOBAL data) ---
	movel	int2_tbl+12,%sp@-
	movel	int2_tbl+8,%sp@-
	movel	int2_tbl+4,%sp@-
	movel	int2_tbl,%sp@-
	pea	Lkl_m6
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lkl_done:
	moveal	%sp@+,%a3		| restore a3
	moveal	%sp@+,%a2		| restore a2
	unlk	%fp			| sp -> [retaddr][USP arg]: original jsr k_trap state
	jmp	k_trap_orig		| tail-call: k_trap_orig's rts + d0 reach ktraps

	.data
	.even
Lkl_m1:
	.asciz	"DBG LATCH1 f64=%x f68=%x f72=%x f76=%x"
	.even
Lkl_m2:
	.asciz	"DBG LATCH2 s80=%x s84=%x s88=%x s92=%x"
	.even
Lkl_m3:
	.asciz	"DBG LATCH3 s96=%x s100=%x s104=%x s108=%x"
	.even
Lkl_m4:
	.asciz	"DBG LATCH4 A0=%x A1=%x A2=%x A3=%x"
	.even
Lkl_m5:
	.asciz	"DBG LATCH5 vb0=%x vb4=%x vb8=%x vb12=%x"
	.even
Lkl_m6:
	.asciz	"DBG LATCH6 i20=%x i24=%x i28=%x i2c=%x"
	.even
Lkl_n:
	.long	0
