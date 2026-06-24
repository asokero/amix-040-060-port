| serdbg_mark.s -- STANDALONE direct-serial marker (serdbg_mark / serdbg_hex), extracted from
| mainmarks.s so the 030 BASELINE build (relink-030-dbg.sh) can use the exec/lookup markers
| WITHOUT pulling in mainmarks.s's 040-specific scheduler overrides (resume040/sched/idle).
| The 040 dbg build keeps getting these symbols from mainmarks.o; the 030 build links THIS .o
| instead.  Identical code -- emit ONE char/8 hex digits DIRECTLY on the Amiga serial port,
| bypassing the STREAMS console drain.  Fully register-preserving.

	.text
	.globl	serdbg_mark
serdbg_mark:
	linkw	%fp,&0
	moveml	%d0-%d1/%a0-%a1,%sp@-
	movel	%fp@(8),%d0		| d0 = ch
	movel	&0x00dff000,%a0		| custom-chip base
	tstw	Lmk_init
	bnew	Lmk_go
	movew	&1,Lmk_init
	movew	&0x0174,%a0@(0x32)	| serper = 9600 baud divisor
Lmk_go:
	andiw	&0x00ff,%d0
	oriw	&0x0100,%d0		| STOPBIT | ch
	movew	%d0,%a0@(0x30)		| serdat <- byte (write FIRST, unconditional)
	movel	&0x00010000,%d1		| bounded TBE wait
Lmk_wait:
	movew	%a0@(0x18),%d0		| serdatr
	andiw	&0x2000,%d0		| TBE (transmit-buffer-empty)
	bnew	Lmk_done
	subql	&1,%d1
	bnew	Lmk_wait
Lmk_done:
	moveml	%sp@+,%d0-%d1/%a0-%a1
	unlk	%fp
	rts

	.globl	serdbg_hex
serdbg_hex:
	linkw	%fp,&0
	moveml	%d0-%d3/%a0-%a1,%sp@-
	movel	%fp@(8),%d2		| d2 = val
	movel	&0x00dff000,%a1		| custom-chip base
	tstw	Lmk_init
	bnew	Lhx_start
	movew	&1,Lmk_init
	movew	&0x0174,%a1@(0x32)	| serper = 9600
Lhx_start:
	moveq	&7,%d3			| 8 nibbles
Lhx_next:
	roll	&4,%d2			| rotate MSB nibble into the low 4 bits
	movel	%d2,%d0
	andiw	&0x000f,%d0
	cmpiw	&9,%d0
	bhiw	Lhx_alpha
	addiw	&0x30,%d0		| '0'..'9'
	braw	Lhx_emit
Lhx_alpha:
	addiw	&0x37,%d0		| 'A'..'F'
Lhx_emit:
	andiw	&0x00ff,%d0
	oriw	&0x0100,%d0		| STOPBIT | digit
	movew	%d0,%a1@(0x30)		| serdat <- digit
	movel	&0x00008000,%d1		| bounded TBE wait
Lhx_wait:
	movew	%a1@(0x18),%d0
	andiw	&0x2000,%d0
	bnew	Lhx_after
	subql	&1,%d1
	bnew	Lhx_wait
Lhx_after:
	dbra	%d3,Lhx_next
	moveml	%sp@+,%d0-%d3/%a0-%a1
	unlk	%fp
	rts

	.data
	.even
Lmk_init:
	.word	0
	.even
