| serdbg.s -- mirror kernel console output to the Amiga serial port (conputc hook).
| ISOLATION TEST: added to the PURE banner-visible baseline (5598c7c), nothing else changed.
| Override conputc (-> serdbg_putc): emit each char on serial, then call the real coputc (screen).
| serper @0xDFF032 (9600=0x174), serdat @0xDFF030 (STOPBIT|ch), serdatr @0xDFF018 (TBE=0x2000).
|
| ISSUE-23 fix (2026-07-19): the original body wrote SERDAT FIRST and waited for
| TBE after, with no interrupt protection. conputc runs in both process and
| interrupt context (dbg clock_sampler!), so an interrupt-context putc landing
| inside the TBE window (~1 ms/char @9600) overwrote the buffered char before it
| moved to the shift register -- silent char loss on real HW (emulator serial-TCP
| has no baud timing, window=0, never reproduces). Now: IPL7-mask the whole
| wait+write and wait for TBE BEFORE writing. The bounded wait (0x10000 spins
| >> 1 char time) stays as a fail-safe: absent/wedged serial degrades to a
| dropped char instead of a hung kernel, as before.

	.text
	.globl	serdbg_putc
serdbg_putc:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	%fp@(8),%d2		| d2 = ch
	movel	&0x00dff000,%a2		| custom-chip base
	tstw	Lser_init
	bnew	Lsd_go
	movew	&1,Lser_init
	movew	&0x0174,%a2@(0x32)	| serper = 9600
Lsd_go:
	movew	%sr,%sp@-		| save IPL (supervisor ctx always)
	oriw	&0x0700,%sr		| mask ints: wait+write must be atomic
	movel	&0x00010000,%d0		| bounded TBE wait BEFORE write
Lsd_wait:
	movew	%a2@(0x18),%d1
	andiw	&0x2000,%d1
	bnew	Lsd_send
	subql	&1,%d0
	bnew	Lsd_wait
Lsd_send:
	movew	%d2,%d1
	andiw	&0x00ff,%d1
	oriw	&0x0100,%d1		| STOPBIT | ch
	movew	%d1,%a2@(0x30)		| serdat <- byte (buffer known empty)
	movew	%sp@+,%sr		| restore IPL
Lsd_scr:
	movel	%d2,%sp@-		| coputc(ch) -- real screen output
	jsr	coputc
	addqw	&4,%sp
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	rts
	nop

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.globl	conputc
conputc:
	.long	serdbg_putc
Lser_init:
	.word	0
	.even
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
