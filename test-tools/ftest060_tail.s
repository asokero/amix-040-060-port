| ftest060_tail.s -- the AMIX side of Motorola's M68060 FPSP test package.
|
| Concatenated AFTER the image by build-ftest060.sh; see ftest060_head.s for why.
|
| CALLING CONVENTION.  The package reaches these through the same table trampoline the FPSP
| uses (`pea target / rtd #4`), but from a `bsr`, so on entry the stack is an ordinary
| subroutine frame:  (sp) = the package's return address, 4(sp) = the argument.  The caller
| pops the argument.  d0/d1/a0/a1 are scratch -- Motorola's test saves d2-d7/a2-a5 itself at
| the top of each entry point, which is what makes that safe.

	.text

| ---- _print_string(char *s) ----------------------------------------------------------
| Written as two instructions rather than `movel %sp@(4),%sp@-` on purpose: for a move with
| a -(sp) destination and a (d,sp) source the displacement's meaning depends on when the
| predecrement is applied, which is exactly the kind of detail that is right on one assembler
| and wrong on the next.
Lft_print_str:
	movel	%sp@(4),%d0
	movel	%d0,%sp@-
	pea	Lft_fmt_s
	jsr	printf
	addql	#8,%sp
	rts

| ---- _print_number(long n) -----------------------------------------------------------
Lft_print_num:
	movel	%sp@(4),%d0
	movel	%d0,%sp@-
	pea	Lft_fmt_d
	jsr	printf
	addql	#8,%sp
	rts

| ---- any other slot ------------------------------------------------------------------
| test.doc defines exactly two call-outs for the test package.  A call to any other slot
| means the image is not what we think it is, so say so and stop rather than continue with a
| result that cannot be trusted.
Lft_undef:
	pea	Lft_undef_msg
	jsr	printf
	addql	#4,%sp
	movel	#3,%sp@-
	jsr	exit
	| exit never returns

| ---- int ftest060_run(int entry_offset) ----------------------------------------------
| entry_offset is 0x00, 0x08 or 0x10.  Calls TOP+128+offset as a subroutine.  The package
| entry points are `link a6 / movm.l &0x3f3c,-(sp) / fmovm.x &0xff,-(sp)` and unwind the same
| way, so a plain jsr/rts is the whole contract; the extra saves here are belt and braces
| because the image is opaque.
	.globl	ftest060_run
ftest060_run:
	link	%a6,#0
	moveml	%d2-%d7/%a2-%a5,%sp@-
	movel	%a6@(8),%d0
	lea	ftest060_top+128,%a0
	addal	%d0,%a0
	jsr	%a0@
	moveml	%sp@+,%d2-%d7/%a2-%a5
	unlk	%a6
	rts

	.data
Lft_fmt_s:
	.asciz	"%s"
Lft_fmt_d:
	.asciz	"%ld"
Lft_undef_msg:
	.asciz	"\nFTEST060: package called an UNDEFINED call-out slot -- aborting\n"
	.balign	4
