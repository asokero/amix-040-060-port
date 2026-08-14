| haltsys040.s -- override haltsys (orig 0x18eb8, GLOBAL T) AND rtnfirm (orig 0x18eb0,
| GLOBAL T) for the 68040/68060 reboot/halt path.  See KNOWN-ISSUES.md ISSUE-5 for the
| full RE writeup this file implements.
|
| WHY rtnfirm TOO (ISSUE-5 fix v2): disassembly of mdboot (0x5637a) proves it calls
| haltsys(0) ONLY for fcn==0 (halt).  For fcn>=1 -- i.e. every actual `reboot` -- mdboot
| calls rtnfirm instead.  rtnfirm is a second entry point 8 bytes BEFORE haltsys in the
| same object: `movel #1,%sp@(4)` (forces msg=1) and FALLS THROUGH into the haltsys body.
| So a haltsys-only override never executes on the reboot path: rtnfirm still entered the
| OLD cluster, whose three 030 pmoves are NOP'd by the byte-patch scripts in the patched
| binary -- meaning the old rtnfirm path left the MMU ENABLED when it jumped to the ROM
| reboot vector, and the ROM then ran with kernel translation still live -> recursive
| trap cascade -> "PANIC: KERNEL FAULT pc=0x4000001E vector=0x4".  That was the actual
| observed panic mechanism.  Overriding rtnfirm here (falling through into our haltsys,
| replicating the original layout byte-for-byte) fixes all 4 caller reloc sites at once.
|
| BUG: the stock haltsys falls into the file-LOCAL label `nomsg`, which disables the MMU with
| three UNGUARDED 68030 `pmove` instructions (tc/crp/srp) before halting or resetting the
| machine.  `pmove` is illegal on 68040/68060 (F-line, vector 4) -> running `reboot`/`uadmin`
| on the 040 kernel panics instead of shutting down cleanly.  Exact same bug class as
| copyit.s's original unguarded pmove triplet (the very first 040 bring-up blocker this
| project fixed) -- this is the third, never-audited site of it, this time in the kernel's own
| shutdown path rather than the Amiga-side loader.
|
| FIX (v3, UNCONDITIONAL): disable the MMU with the 68040/68060 sequence only -- `movec` to
| clear TC + ITT0/1 + DTT0/1 and `pflusha` to flush the ATC (crp/srp have no 040 equivalent
| load -- clearing TC's enable bit alone turns off translation, so nothing else is needed).
|
| WHY NO AttnFlags GUARD (fix v2 had one; it FAILED on the real 040 with an F-line trap,
| vector 0xB, at the 030 `pmove %a0@,%tc`):
|   (a) This is an 040/060-ONLY kernel binary: pstart040, hat040, kvm040 etc. all emit
|       movec/pflusha unconditionally, so it fundamentally cannot run on an 030.  Runtime
|       CPU detection in the shutdown path is therefore unnecessary.
|   (b) It is also FRAGILE here: the guard read `moveal 4,%a1` (AmigaOS SysBase pointer)
|       and `btst #3/#7,%a1@(0x129)` (AFB_68040/AFB_68060) -- but at Unix reboot time,
|       under the LIVE Unix MMU, low-memory address 4 / SysBase+0x129 no longer yield the
|       AmigaOS AttnFlags byte.  Both btsts read 0 and control fell through to the 68030
|       pmove path, an illegal F-line instruction on the 040 = the observed reboot panic.
|   copyit.s uses the SAME guard successfully only because it runs PRE-MMU during the
|   loader handoff, when AmigaOS SysBase is still directly accessible; that reasoning does
|   NOT transfer to this in-kernel shutdown path.  The 030 pmove block is deleted outright,
|   removing the only pmove bytes from the function.
|
| WHY THE WHOLE FUNCTION IS TRANSCRIBED (not just the 3 pmove instructions patched in place):
| haltsys is the ONLY global symbol in its source cluster -- `nm` shows nomsg/halt/reboot/
| new_funky_reboot as file-LOCAL 't' in the same object as haltsys, so they cannot be
| individually overridden by symbol name from another object file.  A --weaken-symbol haltsys
| override must therefore reimplement the entire original control flow (conditional haltmsg
| printf -> MMU disable -> cacr clear -> hardware bset -> halt-spin-loop or reboot-jump
| dispatch) inline, under our own local labels.
|
| LOCAL DATA (haltmsg): duplicated here rather than globalizing another local symbol from
| vanilla/stand/unix -- a byte-identical local copy carries far less relink-mechanism risk
| than a globalize-then-weaken chain for data no other file needs.  Verified byte-for-byte
| against `objdump -s vanilla/stand/unix`:
|     haltmsg = "The system is halted; you may reboot or turn off power.\0"  (56 bytes incl NUL)
| (The original's nullrp/zero pmove descriptors were only consumed by the deleted 030 path
| and are gone with it.)
|
| boot_arg0: checked via `nm vanilla/stand/unix` -- GLOBAL 'D' at 0x4780 already, so it is
| referenced directly by name below; no globalize/weaken needed for it.
|
| Calling convention: haltsys(msg) takes its single arg off the caller's stack at sp@(4) with
| NO linkw/unlk -- verified against the original, which has no stack-frame prologue either
| (mdboot's caller stack is simply abandoned once we reach halt: or a reboot jump, so this
| matches original behavior exactly).
|
| 040/060 privileged ops are emitted as `.word` (validated with the project's m68k-cbm-sysv4
| cross-assembler under -m68040, same convention as copyit.s / pstart040.s / hat_chgprot040.s):
| movec=0x4e7b, pflusha=0xf518.  `movec %d0,%cacr` and the exotic `jmp %za0@(0xf80028)@(0)`
| memory-indirect ROM-vector jump both assemble via plain mnemonics with this toolchain
| (empirically verified byte-identical to the original's 4e7b 0002 / 4ef0 01f1 00f8 0028).

	.text
	.globl	rtnfirm
rtnfirm:
	movel	&1,%sp@(4)		| force msg=1, fall through into haltsys (verbatim orig 0x18eb0)

	.globl	haltsys
haltsys:
	movel	%sp@(4),%d2		| d2 = msg arg (sets flags on the moved value)
	bnew	Lhs_nomsg		| msg != 0 -> skip the printf (verbatim original test)
	pea	Lhs_haltmsg
	jsr	printf			| printf(haltmsg); no stack cleanup (never returns normally)

Lhs_nomsg:
	movew	&0x2700,%sr		| interrupts off, supervisor (verbatim original)
	| ---- caches-on Step B1 (2026-07-23): push+invalidate the DATA cache BEFORE the
	| MMU/cache teardown below (docs/contracts/DTT0-NARROWING-SPEC.md "Shutdown ordering").  In B1
	| writethrough there are no dirty lines, so this is a pure invalidate (harmless);
	| in a future B2 copyback build the push is MANDATORY -- invalidating dirty lines
	| at shutdown would lose the last writes.  cpusha dc covers both stages.
	.word	0xf478			| cpusha dc -- push+invalidate DC before teardown
	| falls straight into the 040/060 MMU disable -- no CPU guard (see header)

| ---- 68040 / 68060: MOVEC-based MMU disable, UNCONDITIONAL (mirrors copyit.s's 040 leg) ----
Lhs_mmu040:
	moveq	&0,%d0
	.word	0x4e7b,0x0003		| movec %d0,%tc    -> paged MMU off (clears TCR E)
	.word	0x4e7b,0x0004		| movec %d0,%itt0  -> no transparent translation
	.word	0x4e7b,0x0005		| movec %d0,%itt1
	.word	0x4e7b,0x0006		| movec %d0,%dtt0
	.word	0x4e7b,0x0007		| movec %d0,%dtt1
	.word	0xf518			| pflusha          -> flush the ATC
	| fall through to Lhs_mmudone

Lhs_mmudone:
	moveq	&0,%d0
	movec	%d0,%cacr		| unchanged from the original -- already CPU-agnostic
	bset	&7,0xde0002		| unchanged hardware register poke -- CPU-agnostic

	tstl	%d2
	bnew	Lhs_reboot

| ---- halt: spin forever with the CIAs disabled (original local label `halt`) ----
Lhs_halt:
	bclr	&6,0xbfee01
	braw	Lhs_halt

| ---- reboot: dispatch to the ROM reboot vector or the reset+jmp fallback (original local
| labels `reboot` / `new_funky_reboot`) ----
Lhs_reboot:
	cmpil	&1,boot_arg0		| boot_arg0: GLOBAL 'D' in the original -- referenced directly
	bnew	Lhs_newfunky
	jmp	%za0@(0xf80028)@(0)	| ROM ktrap jump (memory-indirect through the ROM vector)
	nop
Lhs_newfunky:
	moveaw	&2,%a0
	nop
	nop
	reset
	jmp	%a0@

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
Lhs_haltmsg:
	.ascii	"The system is halted; you may reboot or turn off power.\0"
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
