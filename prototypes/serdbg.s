| serdbg.s -- mirror kernel console output to the Amiga serial port (conputc hook).
| ISOLATION TEST: added to the PURE banner-visible baseline (5598c7c), nothing else changed.
| Override conputc (-> serdbg_putc): emit each char on serial, then call the real coputc (screen).
| serper @0xDFF032 (9600=0x174), serdat @0xDFF030 (STOPBIT|ch), serdatr @0xDFF018 (TBE=0x2000).

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
	movew	%d2,%d1
	andiw	&0x00ff,%d1
	oriw	&0x0100,%d1		| STOPBIT | ch
	movew	%d1,%a2@(0x30)		| serdat <- byte (write first)
	movel	&0x00010000,%d0		| bounded TBE wait
Lsd_wait:
	movew	%a2@(0x18),%d1
	andiw	&0x2000,%d1
	bnew	Lsd_scr
	subql	&1,%d0
	bnew	Lsd_wait
Lsd_scr:
	movel	%d2,%sp@-		| coputc(ch) -- real screen output
	jsr	coputc
	addqw	&4,%sp
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	rts
	nop

	.data
	.globl	conputc
conputc:
	.long	serdbg_putc
Lser_init:
	.word	0
	.even
