| vtop040.s -- override vtop (0xb7568, GLOBAL T) for the 68040 DTT0 identity region.
|
| vtop(va, proc) returns the PHYSICAL address used to program disk DMA
| (alien/dd.c:240  dp->com.addr = vtop(bp->b_un.b_addr, bp->b_proc)).  For a kernel buffer
| (proc==0) stock vtop calls svirtophys(va), which WALKS the kptr040 page tables.  But the
| low kernel region (va < 0x40000000) is covered by the DTT0 transparent-translation
| register as an IDENTITY map (phys == va, cache-inhibited) -- the CPU itself reaches that
| RAM as va==phys, and the page tables may not even contain entries for it.  When svirtophys
| returns a wrong/zero phys for such a buffer, the SCSI DMA writes the disk block to the
| WRONG RAM -> the static `block` in sdpart.c stays 0 -> getrdb 'RDSK' check fails ->
| sdpartition ENXIO -> "s5mountroot VOP_OPEN error 6".  This is LAYOUT-SENSITIVE because
| whether a given `block` address happens to have a correct kptr040 entry depends on where
| BSS lands.
|
| FIX: for va < 0x40000000 (the DTT0 identity region) return va directly -- which is the
| GROUND TRUTH phys there (DTT0 makes va==phys regardless of the page tables), so it is a
| no-op where svirtophys already agrees and a correction where it does not.  For va >=
| 0x40000000 (kvseg / per-proc user) defer to stock vtop unchanged.  This benefits ALL disk
| DMA (dd/scsi/ram/hd/flop all call vtop), not just sdpart.
|
| vtop(va, proc): va @ sp@(4), proc @ sp@(8); returns paddr in d0 (and a0).  No frame is
| needed for the identity path; the stock path is a tail-jmp to the aliased original
| (--add-symbol vtop_orig=.text:0xb7568; --weaken-symbol vtop so this strong def wins).

	.text
	.globl	vtop
vtop:
	movel	%sp@(4),%d0		| d0 = va
	cmpil	&0x40000000,%d0		| DTT0 identity region is va < 0x40000000
	bccw	Lvt_stock
	moveal	%d0,%a0			| identity: phys == va (return in d0 and a0)
	rts
Lvt_stock:
	jmp	vtop_orig		| va >= 0x40000000: stock vtop (svirtophys / user walk)
