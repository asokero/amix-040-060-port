| scan060-selftest.s -- positive control for test-tools/scan060.py.
|
| A checker that has only ever been run on clean inputs is a checker whose
| failure path is untested.  This file contains all four instruction forms the
| 68060 removed and all four neighbouring forms it kept, so a correct scan must
| report exactly four candidates and must not report the other four.
|
| The pairs matter more than the count.  Each removed form differs from its kept
| neighbour ONLY in bit 10 of the extension word, and objdump's names do not
| separate them the way they appear to: source `divu.l` prints as `divul` and
| source `divul.l` prints as `divull`, so the extra "l" marks a remainder
| register rather than a longer dividend.  On the multiply side the name does
| not separate them at all -- both print as `mulul`.
|
| run:  test-tools/scan060-selftest.sh

	.text
	| ---- removed on the 68060: must be reported ----
	divu.l	%d1,%d2:%d3		| 64-bit dividend
	divs.l	%d1,%d2:%d3		| 64-bit dividend, signed
	mulu.l	%d1,%d2:%d3		| 32x32 -> 64
	muls.l	%d1,%d2:%d3		| 32x32 -> 64, signed

	| ---- kept on the 68060: must NOT be reported ----
	divul.l	%d1,%d2:%d3		| 32-bit dividend, remainder in d2
	divsl.l	%d1,%d2:%d3		| 32-bit dividend, signed
	divu.l	%d1,%d3			| 32/32, no remainder
	mulu.l	%d1,%d3			| 32x32 -> 32
	.balign	4
