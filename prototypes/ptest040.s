| ptest040.s -- 68040 port of the kernel's `ptest` (the GOT-relocation / COW-fault fix).
|
| The stock `ptest` (0x3a8) is the 030 `ptestr #1,(a0),7` + `pmove psr` sequence: it returns the
| 030 MMU status (PSR) for a user (FC=1) logical address.  On the 68040 those are illegal F-line
| instructions, so patch_pmmu_040.py STUBS ptest to a constant 0x400 (030 bit10 = I = invalid).
| That constant makes usrxmemflt's classifier (`andil #0x4400` @5afb2) ALWAYS take the F_INVAL
| demand path -- so a write to libc.so.1's read-only GOT page is treated as "not present" and
| demand-re-read instead of copied-on-write (F_PROT).  do_reloc's relocation store is then lost,
| the GOT stays raw, and the dynamic linker jsr's a raw GOT slot and _exit(0)s before init runs.
|
| This is a REAL 040 ptest: it runs the genuine 040 `ptestr` and reads MMUSR, then TRANSLATES the
| 040 status to the 030-form PSR that the rest of usrxmemflt (and krnxmemflt) already understand:
|   040 MMUSR (cpummu.h): R=bit0 resident, W=bit2 write-protected, B=bit11 bus error/invalid.
|   030-form PSR wanted:  I=bit10(0x400) invalid, W=bit11(0x800) write-protected, B=bit15(0x8000).
| Mapping:
|   R==0            -> 0x400 (030 I)  -> usrxmemflt F_INVAL demand path (faults the page in)
|   R==1 && W==1    -> 0x800 (030 W)  -> usrxmemflt F_PROT / COW path (copies the page writable)
|   R==1 && W==0    -> 0              -> present & writable (no fault bits; shouldn't have faulted)
| We deliberately map "not present" to 030 I (demand) not 030 B (which would SIGSEGV).
|
| 040 function code: the 68040 PTEST takes its FC from the DFC register (verified in fs-uae
| cpummu.cpp mmu_op_real: super=dfc&4, data=(dfc&3)!=2).  We set DFC (and SFC, harmless) = 1
| (user data), matching the stock ptest's hardcoded FC=1.  During a user fault URP already points
| at the faulting process, so ptestr tests exactly the page we care about.  DFC/SFC are caller-
| set-as-needed in this kernel (wb040.s sets DFC before its replay moves), so clobbering is safe.
|
| The assembler does not know the 040 PMMU mnemonics, so ptestr / movec MMUSR are emitted as .word
| (same technique as wb040.s's pflusha).  Wired via relink-040.sh: --weaken-symbol ptest (it is a
| GLOBAL 'T' symbol -> a plain weaken lets this strong def win for every caller).

	.text
	.globl	ptest
ptest:
	moveq	&1,%d0
	movec	%d0,%dfc			| FC = 1 (user data) -- 040 PTEST reads DFC
	movec	%d0,%sfc			| harmless; in case of DFC/SFC ambiguity on real HW
	moveal	%sp@(4),%a0			| a0 = fault VA (the one arg)
	.word	0xf568				| ptestr (%a0)  -- walk current URP, fill MMUSR
	.word	0x4e7a,0x0805			| movec %mmusr,%d0
	moveq	&0,%d1
	btst	&0,%d0				| R (resident / present)?
	beqw	Lpt_np				|   R==0 -> not present
	btst	&2,%d0				| W (write-protected)?
	beqw	Lpt_ret				|   R==1 && W==0 -> present+writable -> 030 = 0
	movew	&0x0800,%d1			|   R==1 && W==1 -> 030 W (write-protect) -> COW
	braw	Lpt_ret
Lpt_np:
	movew	&0x0400,%d1			| 030 I (invalid / not present) -> F_INVAL demand
Lpt_ret:
	movel	%d1,%d0				| return 030-form PSR in d0 (stock calling convention)
	rts
	nop					| pad .text to keep text/data contiguous
