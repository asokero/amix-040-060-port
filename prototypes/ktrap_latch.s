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
| === KSTKCHAIN (ISSUE-7, 2026-07-08): kernel-stack-depth return-address chain probe ===
| A kernel-fault RECURSION (~220 bytes/level) eats the u-area kernel stack (VA
| 0x40000000-0x40001FFF) downward until it overwrites the u struct front (u_procp=0)
| -> panic.  The native kernel's per-level "kstack 0xXXXXXXXX!" prints were seen
| descending 0x40000C54 -> 0x400002E0.  This probe fires when k_trap runs critically
| deep (fp < 0x40000C00, frames still intact), latches after 2 firings (Lks_n, no
| per-level stack pressure), and prints (a) sp / fmt-vec word (frame+70) / fault PC
| (frame+66) / 040 fault address (frame+84), then (b) up to 16 return addresses from
| the frame-pointer chain rooted at the faulting code's saved A6 (frame+60):
| RA = fp@(4), next fp = fp@(0); each fp must be long-aligned, inside
| [0x40000000, 0x40001FF8) (so fp@(4) dereference stays inside the 8KB u-area), and
| strictly GREATER than the previous fp (stack grows down: caller fp > callee fp).
| RAs collected into a static buffer FIRST (zero-padded, no extra stack), then printed
| 4 per line.  Extra register cost: d2 saved/restored (cmn_err preserves d2-d7/a2-a6).
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
	movel	%d2,%sp@-		| save d2 (KSTKCHAIN walk/line counter)
	lea	%fp@(8),%a2		| a2 = frame pointer (&USP slot)
| ======================= KSTKCHAIN probe (ISSUE-7) =======================
| trigger: this k_trap entry runs critically deep in the u-area kernel stack
	movel	%fp,%d0			| d0 = current depth (fp = entry sp - 4)
	cmpil	&0x40000000,%d0
	bcsw	Lks_skip		| below u-area -> not ours
	cmpil	&0x40000C00,%d0
	bccw	Lks_skip		| not critically deep -> skip
| latch: at most 2 firings total
	movel	Lks_n,%d1
	cmpil	&2,%d1
	bccw	Lks_skip
	addql	&1,%d1
	movel	%d1,Lks_n
| --- line 1: sp / format-vector word / fault PC / 040 fault address ---
	movel	%a2@(84),%sp@-		| 040 fault address (userspace040 convention)
	movel	%a2@(66),%sp@-		| exception-frame PC (unaligned long: legal on 040)
	moveq	&0,%d1
	movew	%a2@(70),%d1		| format/vector word
	movel	%d1,%sp@-
	movel	%d0,%sp@-		| sp (wrapper fp)
	pea	Lks_m1
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| --- zero the RA buffer (16 longs) so unwalked slots print as 0 ---
	lea	Lks_buf,%a3
	moveq	&15,%d1
Lks_z:
	clrl	%a3@+
	subql	&1,%d1
	bccw	Lks_z
| --- walk the frame-pointer chain into Lks_buf ---
	lea	Lks_buf,%a3		| a3 = store pointer
	moveal	%a2@(60),%a0		| a0 = fp0 = faulting code's saved A6 (frame+60)
	moveq	&0,%d0			| d0 = previous fp (0 = none yet)
	moveq	&0,%d2			| d2 = RA count
Lks_walk:
	movel	%a0,%d1
	btst	&0,%d1			| fp long-aligned?
	bnew	Lks_wend
	btst	&1,%d1
	bnew	Lks_wend
	cmpil	&0x40000000,%d1		| fp inside the u-area stack?
	bcsw	Lks_wend
	cmpil	&0x40001FF8,%d1		| upper bound keeps fp@(4) inside 0x40002000
	bccw	Lks_wend
	cmpl	%d0,%d1			| strictly increasing vs previous fp?
	blsw	Lks_wend		| fp <= prev -> chain broken, stop
	movel	%d1,%d0			| prev = current
	movel	%a0@(4),%a3@+		| collect return address = fp@(4)
	moveal	%a0@,%a0		| next fp = fp@(0)
	addql	&1,%d2
	cmpil	&16,%d2
	bcsw	Lks_walk
Lks_wend:
| --- print the 16 collected / zero-padded RAs, 4 per cmn_err line ---
	lea	Lks_buf,%a3
	moveq	&4,%d2			| 4 lines (cmn_err preserves d2-d7/a2-a6)
Lks_pline:
	movel	%a3@(12),%sp@-
	movel	%a3@(8),%sp@-
	movel	%a3@(4),%sp@-
	movel	%a3@,%sp@-
	pea	Lks_m2
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
	lea	%a3@(16),%a3
	subql	&1,%d2
	bnew	Lks_pline
| --- KSTKWB (ISSUE-7 wb040 diagnosis): 040 format-7 write-back frame fields ---
| Offsets per prototypes/wb040.s header (relative to a2 = frame arg):
|   SSW@+72  WB1S@+82 WB1A@+104 WB1D@+108  WB2S@+80  WB3S@+78 WB3A@+88 WB3D@+92
| line 1: ssw / WB1S / WB2S / WB3S (zero-extended words)
	moveq	&0,%d1
	movew	%a2@(78),%d1		| WB3S
	movel	%d1,%sp@-
	moveq	&0,%d1
	movew	%a2@(80),%d1		| WB2S
	movel	%d1,%sp@-
	moveq	&0,%d1
	movew	%a2@(82),%d1		| WB1S
	movel	%d1,%sp@-
	moveq	&0,%d1
	movew	%a2@(72),%d1		| SSW
	movel	%d1,%sp@-
	pea	Lks_m3
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
| line 2: WB1A / WB1D / WB3A / WB3D (WB2 addr/data usually unused; WB3 = known live slot)
	movel	%a2@(92),%sp@-		| WB3D
	movel	%a2@(88),%sp@-		| WB3A
	movel	%a2@(108),%sp@-		| WB1D
	movel	%a2@(104),%sp@-		| WB1A
	pea	Lks_m4
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lks_skip:
| ================== end KSTKCHAIN; original ISSUE-5 latch below ==================
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
	movel	%sp@+,%d2		| restore d2
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
	.even
Lks_m1:
	.asciz	"DBG KSTKCHAIN sp=%x fv=%x pc=%x fa=%x"
	.even
Lks_m2:
	.asciz	"DBG KSTKCHAIN RA %x %x %x %x"
	.even
Lks_m3:
	.asciz	"DBG KSTKWB ssw=%x w1s=%x w2s=%x w3s=%x"
	.even
Lks_m4:
	.asciz	"DBG KSTKWB w1a=%x w1d=%x w3a=%x w3d=%x"
	.even
Lks_n:
	.long	0
Lks_buf:
	.long	0,0,0,0,0,0,0,0
	.long	0,0,0,0,0,0,0,0
