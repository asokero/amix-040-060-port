| asfault_probe.s -- standalone as_fault tracer for the 68030 GOLDEN reference build.
|
| The 040 build (assegat_dbg.s) already wraps as_fault and showed, for libc.so.1's GOT page,
| C102FE68 faulting with rw=1 (READ) while a known-good write got rw=2 -- i.e. do_reloc's GOT
| writes appear to either not fault (page writable, write lost = read/write split) or be
| misclassified.  This probe drops the SAME wrapper into the 030 kernel (which boots to login,
| so its GOT relocation WORKS) to capture the CORRECT classification: what (addr, type, rw, ret)
| does as_fault see for the same C102Fxxx GOT writes on 030?  Compare to the 040 trace to find
| the divergence.
|
| Wired via relink-030-dbg.sh: --add-symbol as_fault_orig=.text:0xae108 + --weaken as_fault.
| cmn_err preserves d2-d7/a2-a6, so d2 (ret) and a2 survive.  Gated to the GOT data segment
| [C102E000, C1031000) and capped at 32.
	.text
	.globl	as_fault
as_fault:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	movel	%fp@(24),%sp@-		| rw
	movel	%fp@(20),%sp@-		| type
	movel	%fp@(16),%sp@-		| len
	movel	%fp@(12),%sp@-		| addr
	movel	%fp@(8),%sp@-		| as
	jsr	as_fault_orig
	lea	%sp@(20),%sp
	movel	%d0,%d2			| ret
	movel	%fp@(12),%d0		| addr
	cmpil	&0xc102e000,%d0
	bcsw	Lap_done
	cmpil	&0xc1031000,%d0
	bccw	Lap_done
	movel	Lap_n,%d0
	cmpil	&32,%d0
	bccw	Lap_done
	addql	&1,%d0
	movel	%d0,Lap_n
	movel	%d2,%sp@-		| ret
	movel	%fp@(24),%sp@-		| rw
	movel	%fp@(20),%sp@-		| type
	movel	%fp@(12),%sp@-		| addr
	pea	Lap_msg
	pea	2
	jsr	cmn_err
	lea	%sp@(24),%sp
Lap_done:
	movel	%d2,%d0
	moveml	%fp@(-8),%d2/%a2
	unlk	%fp
	rts
	nop				| pad .text to keep text/data contiguous

	.data
	.even
Lap_msg:
	.asciz	"DBG as_fault addr=%x type=%x rw=%x ret=%x"
	.even
Lap_n:
	.long	0
