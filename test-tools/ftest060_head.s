| ftest060_head.s -- the 128-byte call-out section of Motorola's M68060 FPSP TEST package.
|
| CONCATENATED, NOT LINKED, by build-ftest060.sh:
|     ftest060_head.s + (dist/ftest.sa converted to .long) + ftest060_tail.s
| for the same two reasons the kernel package is built that way (build-fpsp060.sh): the table
| entries are symbol DIFFERENCES, which are only link-time constants inside one assembly unit,
| and test.doc requires the call-out section to sit adjacent to the image.
|
| This is a USER-MODE program.  It does not contain the FPSP -- the FPSP is in the kernel, on
| vector 11.  ftest simply executes the instructions and checks the answers, so it measures
| exactly what F3 M2b claims, using Motorola's own expected values rather than ours.
|
| Only two of the 32 slots are defined for the test package (test.doc):
|     0x00  _print_string(char *)    0x04  _print_number(long)
| Everything else is a counted trap: a test package that calls an undefined slot would
| otherwise jump to the table itself.
|
| Entry points, from the top of the call-out section:
|     TOP+128+0x00  main fp test      unimp effective address, unsupported data types,
|                                     non-maskable overflow/underflow  (vectors 60 and 55:
|                                     M3 territory, NOT hooked on the 060 yet)
|     TOP+128+0x08  FP unimplemented  <- this is the one M2b implements
|     TOP+128+0x10  enabled snan/operr/ovfl/unfl/dz/inex.  test.doc says the test expects
|                                     _real_XXXX() to clear the exception and rte; AMIX
|                                     delivers a signal instead, so "failed" here is the
|                                     documented, acceptable outcome for a Unix host.

	.text
	.globl	ftest060_top
ftest060_top:
	.long	Lft_print_str - ftest060_top	| 0x00  _print_string
	.long	Lft_print_num - ftest060_top	| 0x04  _print_number
	.long	Lft_undef - ftest060_top	| 0x08
	.long	Lft_undef - ftest060_top	| 0x0c
	.long	Lft_undef - ftest060_top	| 0x10
	.long	Lft_undef - ftest060_top	| 0x14
	.long	Lft_undef - ftest060_top	| 0x18
	.long	Lft_undef - ftest060_top	| 0x1c
	.long	Lft_undef - ftest060_top	| 0x20
	.long	Lft_undef - ftest060_top	| 0x24
	.long	Lft_undef - ftest060_top	| 0x28
	.long	Lft_undef - ftest060_top	| 0x2c
	.long	Lft_undef - ftest060_top	| 0x30
	.long	Lft_undef - ftest060_top	| 0x34
	.long	Lft_undef - ftest060_top	| 0x38
	.long	Lft_undef - ftest060_top	| 0x3c
	.long	Lft_undef - ftest060_top	| 0x40
	.long	Lft_undef - ftest060_top	| 0x44
	.long	Lft_undef - ftest060_top	| 0x48
	.long	Lft_undef - ftest060_top	| 0x4c
	.long	Lft_undef - ftest060_top	| 0x50
	.long	Lft_undef - ftest060_top	| 0x54
	.long	Lft_undef - ftest060_top	| 0x58
	.long	Lft_undef - ftest060_top	| 0x5c
	.long	Lft_undef - ftest060_top	| 0x60
	.long	Lft_undef - ftest060_top	| 0x64
	.long	Lft_undef - ftest060_top	| 0x68
	.long	Lft_undef - ftest060_top	| 0x6c
	.long	Lft_undef - ftest060_top	| 0x70
	.long	Lft_undef - ftest060_top	| 0x74
	.long	Lft_undef - ftest060_top	| 0x78
	.long	Lft_undef - ftest060_top	| 0x7c

	.globl	ftest060_image
ftest060_image:
| ---- dist/ftest.sa (converted to .long) is concatenated here by build-ftest060.sh ----
