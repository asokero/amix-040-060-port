| z3660_glue040.s -- register the two Z3660 drivers in a relinked 68040 kernel
| (2026-07-31).  Their own build hub rebuilds a SOURCE kernel and edits generated
| tables; we relink a binary, so the same three registrations are done here with
| the mechanisms this tree already uses.  Full map + evidence:
| Z3660-KERNEL-FEASIBILITY-260731.md.
|
| 1. SCSI -- a fourth scsicard[] row.
|    The stock table lives at .data 0x395c as three 12-byte rows
|    {product, queue, name} and is consumed by the local `init` at 0xd736:
|      lea scsicard,%a3   (reloc @0xd74c)      loop bound  moveq #2,%d1  @0xd79e
|      insert(queue, unit, base, name)         (insert @0xd7cc)
|    Extending the table in place is impossible (the bytes after it belong to
|    something else), and `init` cannot be overridden because there are TWO local
|    symbols named `init` in this image (0xb01e and 0xd736) -- an ambiguous
|    globalize+weaken is exactly the packaging hazard this port has been bitten by
|    before.  So: a FOUR-row copy lives here, patch_z3660.py retargets the `lea`
|    relocation to it and bumps the loop bound to 3.  Rows 0-2 re-declare the
|    stock queue functions, which the linker binds to the same bodies the original
|    table pointed at (a3091queue 0xcf70, a2090queue 0xc200, a2091queue 0xc714 --
|    asserted by the patcher).
|
| 2. Ethernet -- cdevsw[48].d_str = &z3660ethinfo.
|    cdevsw is a global at .data 0x9dd4, entry 52 bytes, d_str at +44, so slot 48's
|    d_str is 0x9dd4 + 48*52 + 44.  Unlike the VA2000/Xsvga entry points, that field
|    carries NO relocation to retarget (it is a plain NULL), so the pointer is
|    stored at RUNTIME from the parinit hook below -- one store, no ELF surgery.
|
| 3. dd.c completion ordering -- their src/kernel-patches/dd.c.patch.
|    In dd.c's completion tail, `iodone(bp)` must run AFTER `startio(FIRST, dp)`:
|    iodone's callback re-enters ddstrategy synchronously and the stock order
|    double-issued the same &dp->com (self-linked sdcom, lost completions).  We
|    have dd.c only as a binary, and an in-place swap is NOT safe: another path
|    branches straight into the `jsr startio` (braw @0xc094 -> 0xc0b6), so swapping
|    the two calls would send that path into iodone.  Instead the `iodone`
|    relocation @0xc0ae is retargeted to the island below, which performs the
|    startio first and then tail-jumps into the real iodone.  Register discipline:
|    at that point bp is already on the stack and dp is in %a4, and %a4 is
|    callee-saved under this ABI, so it survives the startio call.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c z3660_glue040.s -o build/z3660_glue040.o

	.text

| ---------------------------------------------------------------------------
| parinit override -- the io_init[] hook the VA2000 driver already uses for the
| same reason (io_init[] = { parinit, 0 } has no spare terminator relocation).
| Runs before falling through to the stock parallel-port init, which is
| unchanged.  parinit takes no arguments and its return value is unused.
	.globl	parinit
parinit:
	movel	&z3660ethinfo,cdevsw+2540	| cdevsw[48].d_str  (48*52 + 44)
	jmp	parinit_orig			| stock parallel-port init, untouched

| ---------------------------------------------------------------------------
| dd.c ordering island (see 3. above).  Entry: sp@(4) = bp (pushed by dd.c),
| %a4 = dp.  Exit: tail-jump to iodone with the stack exactly as dd.c built it.
	.globl	dd_startio_first
dd_startio_first:
	movel	%a4,%sp@-		| dp
	clrl	%sp@-			| FIRST
	jsr	startio
	addql	&8,%sp
	jmp	iodone			| bp is still at sp@(4), as dd.c left it
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.balign	4
| ---------------------------------------------------------------------------
| The four-row scsicard[] replacement.  Row order preserved so unit numbering of
| the existing controllers does not change; the Z3660 is appended.
	.globl	z3660_scsicard
z3660_scsicard:
	.long	0x0202f003
	.long	a3091queue
	.long	Lz3660_n0
	.long	0x02020001
	.long	a2090queue
	.long	Lz3660_n1
	.long	0x02020003
	.long	a2091queue
	.long	Lz3660_n2
	.long	0x144b0001
	.long	z3660queue
	.long	Lz3660_n3
Lz3660_n0:
	.asciz	"A3091 SCSI"
Lz3660_n1:
	.asciz	"A2090 SCSI"
Lz3660_n2:
	.asciz	"A2091 SCSI"
Lz3660_n3:
	.asciz	"Z3660 SCSI"
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
