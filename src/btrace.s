| btrace.s -- early-boot serial PHASE TRACE, flag-gated (2026-07-20).
|
| WHY: an intermittent real-HW boot failure (A3000+Mercury 040) dies in the
| kernel BEFORE the first cmn_err/console output, so the only serial evidence is
| the stock kernel-fault recursion ("kstack 0x...!" -> a stream of 'k').  To
| localize WHERE in the pre-console window it dies, btrace_mark emits ONE
| character per boot milestone directly on the Amiga serial port.  A good boot
| prints the whole sequence; a failing boot stops at the last milestone reached.
| If failing boots stop at VARYING milestones -> random/marginal (hardware); if
| always the SAME one -> a specific code/state point.  Kept as a standing debug
| feature (not throwaway): the same class of early failure can recur on other
| hardware/conditions.
|
| MILESTONE ALPHABET (see the call sites):
|   A pstart entry     B tables built     C MMU paging on    D IC enabled
|   E pre-vstart       F post-vstart      G post-mlsetup     H post-svirtophys
|   S sysseginit in    s sysseginit out   P first hat_pteload
|
| FLAG GATE: btrace_mark does nothing unless the `btrace_on` long is nonzero.
| It ships 0 (silent) so the BASE and QUIET kernels are byte-for-byte behaviour-
| identical -- the call sites compile to a cheap pea/jsr/addq around an immediate
| rts.  The DBG build flips btrace_on to 1 (patch_btrace_on.py in
| relink-040-dbg.sh).  The flag can also be poked live via /dev/kmem to turn the
| trace on in a base/quiet kernel on some other machine, without a rebuild.
|
| SAFETY (why this is a no-risk standing addition):
|   * Fully register- AND condition-code-preserving: SR is saved first and
|     restored last on BOTH the on and off paths, so a marker may sit anywhere,
|     even between a compare and its branch.  Only d0/d1/a0 are used, all saved.
|     pstart's live registers (d2 = mlsetup high-water mark, a1/d3/d6 = MMU
|     pointers) are untouched.  fp is preserved via link/unlk.
|   * Serial hardware base 0xdff000 is reachable throughout: MMU off at entry
|     (physical), and after MMU-on it is in DTT0's 0-1GB cache-inhibited identity
|     window.  btrace_on and this code live at kernel addresses < 0x40000000
|     (loaded at 0x08000000), reachable the same way.
|   * Bounded TBE wait (ISSUE-23 pattern): a dead/absent serial drops the char
|     rather than hanging the boot.  IPL7 masks the wait+write window so an
|     interrupt-context putc cannot corrupt SERDAT mid-transfer.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c btrace.s -o build/btrace.o
| Linked into ALL variants; only the DBG build sets btrace_on=1.

	.text
| ---------------------------------------------------------------------------
| btrace_mark(ch) -- arg fp@(8) low byte = character.  Emits it on serial iff
| btrace_on != 0.  Preserves every register and the condition codes.
	.globl	btrace_mark
btrace_mark:
	linkw	%fp,&0
	movew	%sr,%sp@-		| save SR/CCR FIRST (flag-transparent on both paths)
	moveml	%d0-%d1/%a0,%sp@-
	tstl	btrace_on
	beqw	Lbt_off			| flag clear -> silent (base/quiet); regs+CCR restored below
	oriw	&0x0700,%sr		| IPL7: TBE-wait + write must be atomic (ISSUE-23)
	moveal	&0x00dff000,%a0		| custom-chip base
	tstw	Lbt_init
	bnew	Lbt_go
	movew	&1,Lbt_init
	movew	&0x0174,%a0@(0x32)	| serper = 9600 (loader already set it; belt-and-braces)
Lbt_go:
	movel	%fp@(8),%d0		| ch
	andiw	&0x00ff,%d0
	oriw	&0x0100,%d0		| STOPBIT | ch
	movel	&0x00010000,%d1		| bounded TBE wait (fail-safe: never hang)
Lbt_wait:
	btst	&5,%a0@(0x18)		| TBE = serdatr high byte bit5 = word bit13
	bnew	Lbt_send
	subql	&1,%d1
	bnew	Lbt_wait
Lbt_send:
	movew	%d0,%a0@(0x30)		| serdat <- STOPBIT|ch
Lbt_off:
	moveml	%sp@+,%d0-%d1/%a0
	movew	%sp@+,%sr		| restore SR/CCR (flags intact for the caller)
	unlk	%fp
	rts

| ---------------------------------------------------------------------------
| btrace_hex(val) -- arg fp@(8) = longword; emit it as 8 uppercase hex digits
| (MSB first) on serial iff btrace_on != 0.  Register- and CCR-preserving, same
| flag gate + bounded TBE wait as btrace_mark.  Used for the ISSUE-21 CACR/RAMSEY
| cache-state dump at kernel entry.
	.globl	btrace_hex
btrace_hex:
	linkw	%fp,&0
	movew	%sr,%sp@-
	moveml	%d0-%d3/%a0,%sp@-
	tstl	btrace_on
	beqw	Lbh_off
	oriw	&0x0700,%sr
	moveal	&0x00dff000,%a0
	tstw	Lbt_init
	bnew	Lbh_go
	movew	&1,Lbt_init
	movew	&0x0174,%a0@(0x32)	| serper = 9600 (shared init flag with btrace_mark)
Lbh_go:
	movel	%fp@(8),%d2		| value
	moveq	&7,%d3			| 8 nibbles
Lbh_loop:
	roll	&4,%d2			| next nibble (MSB first) into low 4 bits
	movel	%d2,%d0
	andiw	&0x000f,%d0
	cmpiw	&9,%d0
	bhiw	Lbh_alpha
	addiw	&0x30,%d0		| '0'..'9'
	braw	Lbh_emit
Lbh_alpha:
	addiw	&0x37,%d0		| 'A'..'F'
Lbh_emit:
	andiw	&0x00ff,%d0
	oriw	&0x0100,%d0		| STOPBIT | digit
	movel	&0x00010000,%d1		| bounded TBE wait (fail-safe)
Lbh_wait:
	btst	&5,%a0@(0x18)
	bnew	Lbh_send
	subql	&1,%d1
	bnew	Lbh_wait
Lbh_send:
	movew	%d0,%a0@(0x30)
	dbra	%d3,Lbh_loop
Lbh_off:
	moveml	%sp@+,%d0-%d3/%a0
	movew	%sp@+,%sr
	unlk	%fp
	rts

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.balign 4
| btrace_on: 0 = silent (base/quiet default), nonzero = emit (DBG build patches
| this to 1).  A long so patch_btrace_on.py / a /dev/kmem poke can flip it with a
| single aligned store; tstl reads the whole long.
	.globl	btrace_on
btrace_on:
	.long	0
Lbt_init:
	.long	0
	.balign 4			| pad section to a 4-byte multiple
