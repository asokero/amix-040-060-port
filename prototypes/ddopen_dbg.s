| ddopen_dbg.s -- instrumented replacement for ddopen (0xbcb8, GLOBAL T).
|
| State: getrdb + getpb proven to read the disk correctly on 040 (RDSK/PART found).
| This build REVERTS to the STOCK sdpartition (which correctly fills its file-local
| `partab` -- our override couldn't, due to a local/global `partab` symbol clash).
| It just prints dev/ctrl/slice and the stock sdpartition return value:
|   "both OK" / sdpartition r=0  -> partab filled -> root should mount (watch for next stage)
|   sdpartition r=6              -> stock reliably fails the partition walk (dig into slice)
|
| ddopen GLOBAL T -> --weaken-symbol.  Calls only GLOBAL fns (sdopen, sdpartition,
| ddstrategy, cmn_err).  Called at vfs_mountroot -> curproc set -> cmn_err safe.
| SVR4 gas syntax: '&' immediates, pea pushes bare constants.

	.text
	.globl	ddopen
ddopen:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-
	moveal	%fp@(8),%a2
	movel	%a2@,%d2		| d2 = dev (callee-saved across calls)

	| cmn_err(2, fmt0, dev, ctrl=(dev>>3)&1, slice=(dev>>4)&7)
	movel	%d2,%d0
	lsrl	&4,%d0
	andl	&7,%d0
	movel	%d0,%sp@-		| slice
	movel	%d2,%d0
	lsrl	&3,%d0
	andl	&1,%d0
	movel	%d0,%sp@-		| ctrl
	movel	%d2,%sp@-		| dev
	pea	Lfmt0
	pea	2
	jsr	cmn_err
	addaw	&20,%sp

	| r1 = sdopen(ctrl)
	movel	%d2,%d0
	lsrl	&3,%d0
	andl	&1,%d0
	movel	%d0,%sp@-
	jsr	sdopen
	addqw	&4,%sp
	movel	%d0,%d3			| r1
	tstl	%d3
	beqw	Lpart

	| sdopen failed
	movel	%d3,%sp@-
	pea	Lmsg_sdopen
	pea	2
	jsr	cmn_err
	addaw	&12,%sp
	movel	%d3,%d0
	braw	Lret

Lpart:
	| r2 = sdpartition(dev, ddstrategy)   [STOCK sdpartition]
	pea	ddstrategy
	movel	%d2,%sp@-
	jsr	sdpartition
	addqw	&8,%sp
	movel	%d0,%d3			| r2

	movel	%d3,%sp@-
	pea	Lmsg_part
	pea	2
	jsr	cmn_err
	addaw	&12,%sp
	movel	%d3,%d0

Lret:
	moveal	%d0,%a0
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.data
Lfmt0:
	.asciz	"DBG ddopen dev=%x ctrl=%x slice=%x"
Lmsg_sdopen:
	.asciz	"DBG ddopen: sdopen FAILED r=%x"
Lmsg_part:
	.asciz	"DBG ddopen: stock sdpartition returned r=%x"
