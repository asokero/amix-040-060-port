| cputype060.s -- the kernel's CPU-class global (060-B, 2026-07-10).
|
| The stock kernel has NO cpu-type variable (verified: no cputype/mmutype/fputype symbol in
| vanilla).  This defines one:
|     cputype = 40  (68040, the DEFAULT -- an older unix_boot that does not know about the
|                    symbol leaves it untouched and the kernel behaves exactly as before)
|             = 60  (68060, POKED by unix_boot after relocation from SysBase->AttnFlags
|                    AFB_68060; see unix_boot.c pokesymlong("cputype", ...))
|
| Consumers (all runtime-dispatch, same binary boots on both CPUs):
|   ptest040.s      -- 040: real ptestr+MMUSR; 060: software URP table walk (no PTEST on 060)
|   inituname040.s  -- banner/uname machine tag shows " 68040-..." or " 68060-..."
| The 040/060 access-error paths need NO cputype check: the trap code dispatches on the
| exception-frame format nibble (7 vs 4), which only the generating CPU produces.
|
| Data-only object: no .text.  Placed with the other overrides by relink-040.sh's ld -r.

	.data
	.globl	cputype
cputype:
	.long	40			| 40 = 68040 (default), 60 = 68060 (loader-poked)
| pcr_boot (F1, 2026-08-05): the 68060 Processor Configuration Register as it stood at boot,
| captured once in pstart040.s behind a cputype==60 gate (movec %pcr is 060-only and traps as
| illegal on the 040).  The kernel has NEVER read or written PCR -- verified by disassembly on
| 2026-08-05 -- so its content is whatever AmigaOS/SetPatch left, and that includes:
|     bits 31-16  revision / ID  (0x0430xx on the 68060)
|     bit 1       EDEBUG
|     bit 0       ESS -- superscalar dispatch enable
| CORRECTION (F1-M0, 2026-08-24): the "bit 1 EDEBUG" line above is WRONG.  It is kept rather
| than edited away because the record should show what was believed while pcr_boot was being
| read.  The MC68060 PCR is:
|     bits 31-16  processor ID (0x0430 = full 68060)
|     bits 15-8   mask revision number
|     bit 6       EDEBUG -- internal state on the bus pins while the bus is idle
|     bit 1       DFP -- DISABLE FLOATING-POINT UNIT.  Set => every FP instruction, FSAVE and
|                 FRESTORE included, takes a line-F exception (vector 11).
|     bit 0       ESS -- superscalar dispatch enable
| EDEBUG is real; it is bit 6.  Evidence chain, incl. Motorola's own 060SP sample handler:
| docs/060-PCR-BIT1-VERDICT-260824.md.  So the measured 0x04300601 below decodes completely:
| ID 0x0430, revision 6, EDEBUG 0, DFP 0 (the FPU is on), ESS 1 -- and bit 1 is the bit that
| separates the three FPU regimes fpuinit060.s probes for.
| WHY THIS MATTERS: F0 measured Dhrystone at exactly 2.0x the 68040, i.e. precisely the clock
| ratio (66/33).  With ESS=0 a superscalar 060 dispatches one instruction per clock and that
| ratio is the whole expected result; with ESS=1 it is not, and something else is the limit.
| docs/68060-prestudy.md §3.4 says "we leave ESS=0 (reset default) during bring-up", but SetPatch --
| now known to be MANDATORY before unix_boot -- loads 68060.library, which normally enables it.
| No performance claim on this machine survives until this word is read.  060-D waits for it.
| SENTINEL: 0xFFFFFFFF means the read never executed (040 boot, or the gate misfired), which is
| what distinguishes "not measured" from "measured as zero".
	.globl	pcr_boot
pcr_boot:
	.long	0xffffffff
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
