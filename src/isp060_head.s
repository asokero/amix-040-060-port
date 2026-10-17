| isp060_head.s -- the 128-byte call-out section of the M68060 ISP (DRIVER-LINE-9, 2026-10-06; opt-in).
|
| LICENCE.  A MODIFIED VERSION under the Motorola M68060 Software Package licence, identified as
| such as that licence requires: the table's shape and its 32 four-byte fields are the package's
| contract, the contents are this port's.  Full notice, unaltered:
| THIRD_PARTY_NOTICES/MOTOROLA-M68060-SP.txt.
|
| THIS FILE IS CONCATENATED, NOT LINKED, for the reasons src/fpsp060_head.s gives (no .incbin in the
| SysV4 assembler; every entry is a difference of two symbols in one unit).  build-isp060.sh emits
|     isp060_head.s + 060sp/isp.S + isp060_glue.s
| into one source and assembles it as a single unit.  Exactly 128 bytes: 32 fields of 4 bytes, each
| the handler's address RELATIVE to the start of this section; reserved slots point at a stub that
| panics rather than at 0.  The slot map is isp.doc's ("68060ISP call-outs"); 0x40..0x68 are the
| same memory call-outs as the FPSP's table.
|
| Entry points then sit at isp060_top + 128 + offset: 0x00 _060_isp_unimp, 0x08 _060_isp_cas,
| 0x10 _060_isp_cas2, 0x18/0x20 the cas/cas2 finish entries.  Decoded from the linked .text by
| build-isp060.sh, every build.

	.text
	.globl	isp060_top
isp060_top:
	.long	Lci_chk          - isp060_top	| 0x00  _060_real_chk
	.long	Lci_divbyzero    - isp060_top	| 0x04  _060_real_divbyzero
	.long	Lci_trace        - isp060_top	| 0x08  _060_real_trace
	.long	Lci_access       - isp060_top	| 0x0c  _060_real_access
	.long	Lci_done         - isp060_top	| 0x10  _060_isp_done
	.long	Lci_cas          - isp060_top	| 0x14  _060_real_cas
	.long	Lci_cas2         - isp060_top	| 0x18  _060_real_cas2
	.long	Lci_lock         - isp060_top	| 0x1c  _060_real_lock_page
	.long	Lci_unlock       - isp060_top	| 0x20  _060_real_unlock_page
	.long	Lci_reserved     - isp060_top	| 0x24  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x28  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x2c  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x30  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x34  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x38  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x3c  (Motorola reserved)
	.long	Lci_imem_read    - isp060_top	| 0x40
	.long	Lci_dmem_read    - isp060_top	| 0x44
	.long	Lci_dmem_write   - isp060_top	| 0x48
	.long	Lci_imem_rw      - isp060_top	| 0x4c  imem_read_word
	.long	Lci_imem_rl      - isp060_top	| 0x50  imem_read_long
	.long	Lci_dmem_rb      - isp060_top	| 0x54  dmem_read_byte
	.long	Lci_dmem_rw      - isp060_top	| 0x58  dmem_read_word
	.long	Lci_dmem_rl      - isp060_top	| 0x5c  dmem_read_long
	.long	Lci_dmem_wb      - isp060_top	| 0x60  dmem_write_byte
	.long	Lci_dmem_ww      - isp060_top	| 0x64  dmem_write_word
	.long	Lci_dmem_wl      - isp060_top	| 0x68  dmem_write_long
	.long	Lci_reserved     - isp060_top	| 0x6c  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x70  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x74  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x78  (Motorola reserved)
	.long	Lci_reserved     - isp060_top	| 0x7c  (Motorola reserved)

	.globl	isp060_image
isp060_image:
| ---- 060sp/isp.S is concatenated here by build-isp060.sh ----
