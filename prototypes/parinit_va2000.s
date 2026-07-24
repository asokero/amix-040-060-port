| parinit_va2000.s -- call va2000init() from the kernel's parallel-port init
| hook, so the MNT VA2000 driver's board probe runs at boot (2026-07-24).
|
| Rationale (see relink-040-va2000.sh / VA2000-KERNEL task notes): io_init[] =
| { parinit, 0 } has no spare NULL-terminator relocation to retarget to
| va2000init (unlike the cdevsw[] retargeting used for the driver's syscall
| entry points), so va2000init is invoked from a `parinit` WRAPPER instead:
| this override runs va2000init() first (harmless if no board is present --
| it prints "va2000: no board found" and returns), then falls through to the
| ORIGINAL parinit so the real parallel-port driver still initializes exactly
| as before.  parinit takes no arguments and its return value is unused by the
| kernel's io_init[] walker, so we don't need to preserve/relay one.
|
| Wired by relink-040-va2000.sh:
|   --weaken-symbol parinit  --add-symbol parinit_orig=.text:0xfe6c,function,global
| and parinit_va2000.o added to the ld -r object list.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c prototypes/parinit_va2000.s -o build/parinit_va2000.o
|
| Durable-relink convention (memory/CLAUDE.md): every section ends with
| .balign 4 -- a .bss/.data misalignment causes SDMAC DMA breakage (root-mount
| ENXIO), so this is enforced even though this file has no .data/.bss of its
| own.

	.text
	.globl	parinit
parinit:
	jsr	va2000init		| MNT VA2000 board probe (autocon + firmware check)
	jmp	parinit_orig		| tail-call the stock parallel-port init
	.balign 4			| pad .text to a 4-byte multiple
