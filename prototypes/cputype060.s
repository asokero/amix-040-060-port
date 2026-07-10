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
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
