| sdpartition_dbg.s -- instrumented replacement for sdpartition (0xd848, GLOBAL T).
|
| getrdb already proven OK (RDB read: block[0]=="RDSK").  The real error-6 is in the
| partition-block walk.  This probe replicates the first steps and prints:
|   1. getrdb result, block[0], and rdb_PartitionList (= block@0x1c, the 8th long of the
|      RDB) -- if block[0]=="RDSK" but rdb_PartitionList is garbage => only a PREFIX of
|      the block was DMA'd (partial transfer), not the whole 512 bytes.
|   2. getpb(rdb_PartitionList) result + block[0] (== "PART"=0x50415254 on success).
| Then returns getpb's result (so we observe the real failing value).
|
| getrdb, getpb (local t) + block (local b) -> --globalize-symbol so we can call/read them
| (NOT replaced).  sdpartition (T) -> --weaken-symbol so this strong def wins.
| SVR4 gas syntax: '&' immediates, pea pushes bare constants, 'sym' = contents at sym.

	.text
	.globl	sdpartition
sdpartition:
	linkw	%fp,&0
	moveml	%d2-%d3/%a2,%sp@-	| save (callee-saved; survive getrdb/getpb/cmn_err)
	lea	block,%a2		| a2 = &block (callee-saved across calls)

	| --- r = getrdb(dev=arg@8, strategy=arg@12) ---
	movel	%fp@(12),%sp@-
	movel	%fp@(8),%sp@-
	jsr	getrdb
	addqw	&8,%sp
	movel	%d0,%d3			| d3 = getrdb result
	movel	%a2@(28),%d2		| d2 = block@0x1c = rdb_PartitionList (read NOW)

	| cmn_err(2, fmt1, getrdb_r, block[0], rdb_PartitionList)
	movel	%d2,%sp@-
	movel	%a2@,%sp@-
	movel	%d3,%sp@-
	pea	Lfmt1
	pea	2
	jsr	cmn_err
	addaw	&20,%sp

	tstl	%d3			| if getrdb failed, bail with its error
	bnew	Lret

	| --- r = getpb(dev, strategy, rdb_PartitionList) ---
	movel	%d2,%sp@-		| blockno = rdb_PartitionList
	movel	%fp@(12),%sp@-		| strategy
	movel	%fp@(8),%sp@-		| dev
	jsr	getpb
	addaw	&12,%sp
	movel	%d0,%d3			| d3 = getpb result

	| cmn_err(2, fmt2, blockno, getpb_r, block[0])
	movel	%a2@,%sp@-
	movel	%d3,%sp@-
	movel	%d2,%sp@-
	pea	Lfmt2
	pea	2
	jsr	cmn_err
	addaw	&20,%sp

Lret:
	movel	%d3,%d0			| return getrdb-or-getpb result
	moveal	%d0,%a0
	moveml	%fp@(-12),%d2-%d3/%a2
	unlk	%fp
	rts
	nop				| pad .text to a 4-byte multiple

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
Lfmt1:
	.asciz	"DBG getrdb=%x block0=%x rdb_PartitionList=%x"
Lfmt2:
	.asciz	"DBG getpb(blk=%x)=%x block0=%x (PART=0x50415254)"
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
