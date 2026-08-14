| fpsp060_head.s -- the 128-byte call-out section of the M68060 FPSP (F3 M2a, 2026-08-07).
|
| LICENCE.  A MODIFIED VERSION under the Motorola M68060 Software Package licence, identified as
| such as that licence requires: the table's shape and its 32 four-byte fields are the package's
| contract, the contents are this port's.  Full notice, unaltered:
| THIRD_PARTY_NOTICES/MOTOROLA-M68060-SP.txt.
|
| THIS FILE IS CONCATENATED, NOT LINKED.  build-fpsp060.sh emits
|     fpsp060_head.s + 060sp/fpsp.S + fpsp060_glue.s
| into one source and assembles it as a single unit.  That is not a style choice:
|   * the SysV4 assembler has no .incbin (measured: "Unknown pseudo-op: .incbin"), so the
|     package image cannot be pulled into a hand-written file;
|   * every entry below is a DIFFERENCE of two symbols, and a difference is only a link-time
|     constant when both symbols are in the same assembly unit.
| Concatenation satisfies both, and it also makes the adjacency the package contract demands
| ("the Call-out section must sit adjacent to the fpsp.sa image in memory") true by
| construction rather than by linker input order.
|
| The section MUST be exactly 128 bytes: 32 fields of 4 bytes.  Each field holds the address
| of the handler RELATIVE to the start of this section.  Reserved slots point at a counted
| stub rather than at 0, so a package that ever calls one lands somewhere we can see instead
| of at address 0.
|
| Entry points then sit at fpsp060_top + 128 + offset:  0x30 fline, 0x38 unsupp, 0x40 effadd,
| 0x00..0x28 the six IEEE exceptions.  Verified by decoding the linked .text, see M1.

	.text
	.globl	fpsp060_top
fpsp060_top:
	.long	Lco_bsun         - fpsp060_top	| 0x00
	.long	Lco_snan         - fpsp060_top	| 0x04
	.long	Lco_operr        - fpsp060_top	| 0x08
	.long	Lco_ovfl         - fpsp060_top	| 0x0c
	.long	Lco_unfl         - fpsp060_top	| 0x10
	.long	Lco_dz           - fpsp060_top	| 0x14
	.long	Lco_inex         - fpsp060_top	| 0x18
	.long	Lco_fline        - fpsp060_top	| 0x1c
	.long	Lco_fpu_disabled - fpsp060_top	| 0x20
	.long	Lco_trap         - fpsp060_top	| 0x24
	.long	Lco_trace        - fpsp060_top	| 0x28
	.long	Lco_access       - fpsp060_top	| 0x2c
	.long	Lco_done         - fpsp060_top	| 0x30  _060_fpsp_done
	.long	Lco_reserved     - fpsp060_top	| 0x34  (Motorola reserved)
	.long	Lco_reserved     - fpsp060_top	| 0x38  (Motorola reserved)
	.long	Lco_reserved     - fpsp060_top	| 0x3c  (Motorola reserved)
	.long	Lco_imem_read    - fpsp060_top	| 0x40
	.long	Lco_dmem_read    - fpsp060_top	| 0x44
	.long	Lco_dmem_write   - fpsp060_top	| 0x48
	.long	Lco_imem_rw      - fpsp060_top	| 0x4c  imem_read_word
	.long	Lco_imem_rl      - fpsp060_top	| 0x50  imem_read_long
	.long	Lco_dmem_rb      - fpsp060_top	| 0x54  dmem_read_byte
	.long	Lco_dmem_rw      - fpsp060_top	| 0x58  dmem_read_word
	.long	Lco_dmem_rl      - fpsp060_top	| 0x5c  dmem_read_long
	.long	Lco_dmem_wb      - fpsp060_top	| 0x60  dmem_write_byte
	.long	Lco_dmem_ww      - fpsp060_top	| 0x64  dmem_write_word
	.long	Lco_dmem_wl      - fpsp060_top	| 0x68  dmem_write_long
	.long	Lco_reserved     - fpsp060_top	| 0x6c  (Motorola reserved)
	.long	Lco_reserved     - fpsp060_top	| 0x70  (Motorola reserved)
	.long	Lco_reserved     - fpsp060_top	| 0x74  (Motorola reserved)
	.long	Lco_reserved     - fpsp060_top	| 0x78  (Motorola reserved)
	.long	Lco_reserved     - fpsp060_top	| 0x7c  (Motorola reserved)

	.globl	fpsp060_image
fpsp060_image:
| ---- 060sp/fpsp.S is concatenated here by build-fpsp060.sh ----
