| serdbg.s -- mirror ALL kernel console output to the Amiga serial port (full boot-log capture).
|
| CORRECTED HOOK POINT (2026-06-23): the FIRST attempt hooked `putchar`, but that captured ONLY
| the idle marker.  Reason: printf/cmn_err output reaches the screen via the `conputc` function
| pointer -> `coputc` (the real console-screen routine, c0.c); `putchar` (support.c) is only ONE
| caller of (*conputc) and most output (banner + buffered markers) bypasses putchar.  So we hook
| `conputc` instead -- it is a STATICALLY-initialized pointer (`conputc = coputc`, reloc at
| 0x99c4).  We provide a strong `conputc = serdbg_putc` (--weaken the kernel's), so from boot
| EVERY (*conputc)(c) -- putchar AND the message-buffer drain -- calls serdbg_putc, which emits
| the char on serial and then calls the real `coputc` (global T @0x5174) so the screen still works.
| => the serial log mirrors EXACTLY what reaches the console.  fs-uae serial_port captures it.
|
| Amiga custom regs (base 0xDFF000): serdatr @+0x18 (TBE=0x2000), serdat @+0x30 (STOPBIT|ch),
| serper @+0x32 (9600 = DATA8(0)|0x174).  Serial write is unconditional (write-first), then a
| bounded TBE wait paces the next char without hanging if TBE never sets.

	.text
	.globl	serdbg_putc
serdbg_putc:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-		| callee-saved scratch
	movel	%fp@(8),%d2		| d2 = ch
	movel	&0x00dff000,%a2		| a2 = Amiga custom-chip base
	tstw	Lser_init		| one-shot: set serper (baud) so fs-uae emits
	bnew	Lsd_go
	movew	&1,Lser_init
	movew	&0x0174,%a2@(0x32)	| serper = DATA8(0) | (373-1) = 9600 baud
Lsd_go:
	movew	%d2,%d1
	andiw	&0x00ff,%d1
	oriw	&0x0100,%d1		| STOPBIT | ch
	movew	%d1,%a2@(0x30)		| serdat <- byte (write first, unconditional)
	movel	&0x00010000,%d0		| bounded wait for TBE (transmit complete), ~64K spins max
Lsd_wait:
	movew	%a2@(0x18),%d1		| serdatr
	andiw	&0x2000,%d1		| TBE set => ready for next
	bnew	Lsd_scr
	subql	&1,%d0
	bnew	Lsd_wait
Lsd_scr:
	movel	%d2,%sp@-		| original screen output: coputc(ch)
	jsr	coputc			| the real console-screen routine (global T @0x5174)
	addqw	&4,%sp
	moveml	%sp@+,%d2/%a2
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.data
	.globl	conputc
conputc:
	.long	serdbg_putc		| override the kernel's `conputc = coputc` (--weaken kernel conputc)
Lser_init:
	.word	0
	.even
