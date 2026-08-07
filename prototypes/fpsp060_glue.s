| fpsp060_glue.s -- AMIX side of the M68060 FPSP (F3 M2a, 2026-08-07).
|
| Concatenated AFTER the package image by build-fpsp060.sh; see fpsp060_head.s for why the
| three pieces are one assembly unit.  Only the 128-byte table may precede the image, so
| every stub below lives past it.
|
| ============================ WHAT M2a IS, AND IS NOT ============================
| M2a proves the WIRING and nothing else.  M1's stated risk is that a wrong entry offset does
| not fail to link -- it jumps into the middle of a 54 KiB binary blob.  So this stage hooks
| vector 11 to the package, counts what the package does, and has every call-out DECLINE in a
| counted, state-preserving way.  No FP instruction is emulated yet.
|
| The memory call-outs therefore return FAILURE (d1 != 0) rather than plausible data.  That is
| deliberate: a stub that returned zeroes would let the package emulate an instruction from
| garbage and produce a wrong answer silently, which is the one outcome this project treats as
| worse than a crash.  Failing closed makes the package take its own access-error path, which
| we count and route to the stock signal path.
|
| M2b replaces the memory family with real ones -- the contract, which fpsp.doc does not
| document and which had to be read out of NetBSD's netbsd060sp.S, is:
|     INPUTS   a0 = user address;  a6@(0x4) bit 5: 1 = supervisor, 0 = user
|     OUTPUTS  d0 = data;  d1 = 0 success, non-zero failure
| and the user side is a `moves` under a fault landing pad, i.e. the u_nofault convention
| Lwb_do in wb040.s already uses here.
|
| PRE-REGISTERED for M2a on the emulated 060, across one fp060probe run:
|     kvp_vec[11]   stops moving        vector 11 no longer reaches nullvect directly
|     f60_entry_n   +4                  the package is entered once per trapping instruction
|     f60_mem_n     > 0                 it got as far as fetching the instruction
| The children may still die of SIGSYS -- via a different route.  The counters are the
| discriminator, not the signal.

	.text

| ---- vector-11 entry: jump into the package's F-line handler ----------------------------
| Reached from fpsp_vec11 when cputype == 60, with the RAW exception frame on (sp), which is
| exactly what the package expects.  Nothing may be pushed here.
	.globl	fpsp060_vec11
fpsp060_vec11:
	addql	#1,f60_entry_n
	jmp	fpsp060_top+128+0x30		| _060_fpsp_fline

| ---- call-outs: every one counted, then the stock path -----------------------------------
| The _060_real_* slots are exception EXIT points: reached with a frame on the stack, normally
| ending in rte.  Handing them to nullvect gives AMIX's ordinary signal path, so this unit
| introduces no signal policy of its own.

Lco_bsun:
	addql	#1,f60_real_n
	moveq	#0,%d0
	bra	Lco_stock
Lco_snan:
	addql	#1,f60_real_n
	moveq	#1,%d0
	bra	Lco_stock
Lco_operr:
	addql	#1,f60_real_n
	moveq	#2,%d0
	bra	Lco_stock
Lco_ovfl:
	addql	#1,f60_real_n
	moveq	#3,%d0
	bra	Lco_stock
Lco_unfl:
	addql	#1,f60_real_n
	moveq	#4,%d0
	bra	Lco_stock
Lco_dz:
	addql	#1,f60_real_n
	moveq	#5,%d0
	bra	Lco_stock
Lco_inex:
	addql	#1,f60_real_n
	moveq	#6,%d0
	bra	Lco_stock
Lco_fline:
	addql	#1,f60_real_n
	moveq	#7,%d0
	bra	Lco_stock
Lco_fpu_disabled:
	addql	#1,f60_real_n
	moveq	#8,%d0
	bra	Lco_stock
Lco_trap:
	addql	#1,f60_real_n
	moveq	#9,%d0
	bra	Lco_stock
Lco_trace:
	addql	#1,f60_real_n
	moveq	#10,%d0
	bra	Lco_stock
Lco_access:
	addql	#1,f60_access_n
	moveq	#11,%d0
	bra	Lco_stock
Lco_reserved:
	addql	#1,f60_reserved_n
	moveq	#31,%d0
	bra	Lco_stock

| A Motorola-reserved slot or an exit we do not implement: record which one, then let the
| stock catch-all decide the signal.  d0 carries the slot id purely for f60_last_co.
Lco_stock:
	movel	%d0,f60_last_co
	jmp	nullvect

| _060_fpsp_done: the package's normal exit.  Motorola's own skeleton is a bare rte, and that
| is right here too -- we entered straight from the vector, so no register save is outstanding.
Lco_done:
	addql	#1,f60_done_n
	rte

| ---- memory family: M2a fails closed ----------------------------------------------------
| d1 != 0 is "failure" in the package's contract.  d0 is left zero so nothing downstream can
| mistake a stale register for data.
Lco_imem_read:
Lco_dmem_read:
Lco_dmem_write:
Lco_imem_rw:
Lco_imem_rl:
Lco_dmem_rb:
Lco_dmem_rw:
Lco_dmem_rl:
Lco_dmem_wb:
Lco_dmem_ww:
Lco_dmem_wl:
	addql	#1,f60_mem_n
	moveq	#0,%d0
	moveq	#1,%d1				| non-zero = failure, per the call-out contract
	rts

	.data
	.globl	f60_magic
f60_magic:
	.long	0x46503630			| "FP60" -- read before trusting any address here
	.globl	f60_entry_n
f60_entry_n:
	.long	0				| vector-11 entries handed to the package
	.globl	f60_mem_n
f60_mem_n:
	.long	0				| memory call-outs taken (M2a: all decline)
	.globl	f60_real_n
f60_real_n:
	.long	0				| _060_real_* exception exits taken
	.globl	f60_access_n
f60_access_n:
	.long	0				| _060_real_access -- the expected M2a landing spot
	.globl	f60_done_n
f60_done_n:
	.long	0				| _060_fpsp_done: a completed emulation
	.globl	f60_reserved_n
f60_reserved_n:
	.long	0				| a Motorola-reserved slot was called: investigate
	.globl	f60_last_co
f60_last_co:
	.long	0				| slot id of the last call-out taken
	.balign	4				| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
