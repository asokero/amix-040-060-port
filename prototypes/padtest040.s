| padtest040.s -- ONE-VARIABLE control for the amixadm/ISSUE-10 bisect (2026-07-31).
|
| WHY: amixadm crashes at startup on the RTG kernel (both drivers, +37 KB) and does
| NOT crash on the base kernel or on the VA2000-only kernel (+2.5 KB, and that is the
| one that actually runs code at boot).  So the remaining candidates are the Xsvga
| driver itself (+34 KB) or simply the SIZE that comes with it: a bigger kernel shifts
| .data/.bss and takes RAM away from the page pool, and the July amixadm signature was
| a malloc free-list walk fault -- exactly the shape that reacts to memory pressure.
|
| This object is 0x8630 bytes of DEAD .text -- byte-for-byte the growth Xsvga causes --
| and nothing else: no driver, no registration, no code that ever runs.  Boot it and
| run amixadm:
|   crashes  -> the trigger is kernel SIZE / layout, not the Xsvga driver
|   clean    -> the trigger is the Xsvga driver itself, not the size
|
| The pad is .text (not .data/.bss) because that is what Xsvga grows, and text size is
| what shifts every later section.  Never referenced, never executed; the symbol exists
| only so nm can confirm the object is linked in.
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c padtest040.s -o build/padtest040.o

	.text
	.globl	padtest040_start
padtest040_start:
	.space	0x8630,0		| dead space: exactly Xsvga's .text growth
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.globl	padtest040_data
padtest040_data:
	.space	0x740,0			| and exactly Xsvga's .data growth, so the two images
					| have byte-identical section geometry (text size,
					| .data offset AND .data size) and the only remaining
					| difference is the driver's content + its cdevsw
					| registration
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
