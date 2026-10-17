| rth1_tail040.s -- the closing object of relink-040-rth1.sh: it carries the .balign 4 that ends
| both linked sections (src/README.md, "every linked override section ends with .balign 4").
| No code and no data of its own.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c src/rth1_tail040.s -o build/rth1_tail040.o

	.text
	.balign 4			| pad .text to a 4-byte multiple

	.data
	.balign 4			| pad .data likewise
