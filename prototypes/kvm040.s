| kvm040.s -- 68040 port of the STATIC kernel-VM mapping path (the page_init
| milestone): segkmem_mapin (leaf-PTE writer) and kvm_init (kvseg pointer-table
| builder).  Separate from hat040.s (the dynamic HAT / user-AS path).
|
| PAGE-SIZE MODEL A (see worklist "CENTRAL DESIGN DECISION"): the kernel keeps its
| 2 KB "click"; two adjacent clicks share one 4 KB 040 MMU page.  So the leaf PTE
| VALUE stays `click<<11 | flags` -- an even (4KB-aligned) click already places the
| physical address in bits 31:12, a valid 040 page descriptor with no shift change.
| Only the loop GRANULARITY changes: index va>>12, step 4 KB, advance phys 4 KB,
| page-base mask 0xF001.  REQUIRES the mapped base click to be EVEN (kvm_init rounds
| the kvseg phys base; kvseg VA 0x40440000 is already 4KB-aligned).
|
| Override mechanism: segkmem_mapin is GLOBAL -> --weaken-symbol.  kvm_init is
| file-LOCAL -> --globalize-symbol then --weaken-symbol (see relink-kvm.sh).
|
| Assemble:  m68k-cbm-sysv4-gcc -m68040 -c kvm040.s -o build/kvm040.o

	.text

| ============================================================================
| segkmem_mapin  (orig 0xa8904, ~430 B) -- map a physical range into a kernel seg
| by writing leaf PTEs straight into seg->s_ptbl (seg@(28)).  Called by sptalloc
| etc.  Args: fp@8=seg, fp@12=addr(VA), fp@16=len(bytes), fp@20=(prot key, !=0),
| fp@24=phys-base byte addr (click<<11, MUST be 4KB-aligned under Model A),
| fp@28=flags(bit1=no-release).  Local fp@(-8)=running PTE value (phys|flags).
|
| Model A edits vs the 030 original: leaf index >>11->>>12 (a892e); page-base mask
| -2047->-4095 (a89ba/a89c0); per-page phys advance +1 click -> +4096 bytes (was
| bfextu/addql/bfins at a8a3c); VA/len step +-2048 -> +-4096 (a8a4e/a8a54).  PTE
| value, {0:21} pfn extracts, and all bookkeeping are UNCHANGED.
| ============================================================================
	.globl	segkmem_mapin
segkmem_mapin:
	linkw	%fp,&-8
	moveml	%d2-%d6/%a2-%a4,%sp@-
	moveal	%fp@(8),%a0		| seg
	movel	%fp@(12),%d2		| addr (VA)
	movel	%fp@(16),%d3		| len (bytes)
	movel	%fp@(20),%d4		| prot key
	movel	%fp@(28),%d5		| flags
	tstl	%a0@(28)		| seg->s_ptbl
	bne	Lsm_have
	pea	Lsmsg0
	pea	3
	jsr	cmn_err
	addqw	&8,%sp
Lsm_have:
	movel	%d2,%d0
	subl	%a0@(4),%d0		| d0 = addr - seg->s_base
	moveq	&12,%d6			| Model A: 4KB page index (030: #11)
	lsrl	%d6,%d0
	asll	&2,%d0			| *4 (PTE stride)
	moveal	%a0@(28),%a3		| s_ptbl
	addal	%d0,%a3			| a3 = &PTE[4k-index]
	movel	%fp@(24),%fp@(-8)	| PTE base = phys byte addr (click<<11), 4KB-aligned
	tstl	%d4
	bne	Lsm_prot
	pea	Lsmsg1
	pea	3
	jsr	cmn_err
	addqw	&8,%sp
Lsm_prot:
	movel	%d4,%sp@-
	jsr	hat_vtokp_prot
	bfins	%d0,%fp@(-5){&5:&1}	| W (PTE bit2) -- same position on 040
	orib	&1,%fp@(-5)		| PDT = 1 (resident)
	addqw	&4,%sp
	tstl	%d3
	beq	Lsm_done
Lsm_loop:
	bfextu	%fp@(-8){&0:&21},%d6	| pfn = click (bits 31:11; 4KB-aligned -> even)
	movel	%d6,%sp@-
	jsr	page_numtookpp
	moveal	%a0,%a4
	addqw	&4,%sp
	btst	&1,%d5			| no-release flag?
	bne	Lsm_write
	btst	&0,%a3@(3)		| existing PTE valid (PDT bit0)?
	beq	Lsm_write
	bfextu	%a3@{&0:&21},%d6	| old PTE pfn (click)
	movel	%d6,%sp@-
	jsr	page_numtookpp
	moveal	%a0,%a2
	movel	%a3@,%d0
	andiw	&-4095,%d0		| Model A: 4KB page-base mask (030: -2047)
	movel	%fp@(-8),%d1
	andiw	&-4095,%d1
	addqw	&4,%sp
	cmpl	%d0,%d1
	beq	Lsm_adv			| same 4KB page -> skip write, advance VA only
	tstl	%a2
	beq	Lsm_write
	subqw	&1,%a2@(2)
	bne	Lsm_chk
Lsm_rel:
	btst	&6,%a2@
	beq	Lsm_chk
	pea	1
	movel	%a2,%sp@-
	jsr	wakeprocs
	andib	&-65,%a2@
	addqw	&8,%sp
	btst	&6,%a2@
	bne	Lsm_rel
Lsm_chk:
	tstw	%a2@(2)
	bne	Lsm_write
	btst	&3,%a2@
	bne	Lsm_abort
	tstl	%a2@(4)
	bne	Lsm_write
Lsm_abort:
	movel	%a2,%sp@-
	jsr	page_abort
	addqw	&4,%sp
Lsm_write:
	tstl	%a4
	beq	Lsm_pte
	addqw	&1,%a4@(2)		| bump page use count
Lsm_pte:
	movel	%fp@(-8),%a3@		| *PTE = phys | flags
	pea	1
	movel	%d2,%sp@-
	jsr	flushmmu		| flushmmu(addr, 1)
	addil	&4096,%fp@(-8)		| Model A: advance phys one 4KB page (030: pfn++ = +2KB)
	addqw	&8,%sp
Lsm_adv:
	addqw	&4,%a3			| next PTE (4-byte)
	addil	&4096,%d2		| Model A: addr += 4KB (030: #2048)
	addil	&-4096,%d3		| Model A: len -= 4KB (030: #-2048)
	bne	Lsm_loop
Lsm_done:
	moveml	%fp@(-40),%d2-%d6/%a2-%a4
	moveal	%d0,%a0
	unlk	%fp
	rts

	.data
	.even
Lsmsg0:
	.asciz	"segkmem_mapin: seg has no s_ptbl"
Lsmsg1:
	.asciz	"segkmem_mapin: null prot key"
