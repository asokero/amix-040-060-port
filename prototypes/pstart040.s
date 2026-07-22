| pstart040.s -- Draft 2: 68040 bootstrap paging replacement for the AMIX kernel
| `pstart`.  Linked over the kernel via relink-pstart.sh (renames the kernel's
| pstart -> pstart_030, links this in as the new pstart).
|
| Strategy (see prototypes/pstart-040-design.md):
|   * Transcribe the original pstart VERBATIM through the 030 table build, so
|     every downstream global (cpuroot/userroot/st_top1/kuptr/ublksde) keeps the
|     exact value the kernel expects.  The 030 long-format tables become inert.
|   * Replace ONLY the 030 MMU-enable (pmove srp/pflusha/pmove tc_on,
|     original 0xfcc..0xfe6) with a 68040 enable: build a tiny 040 page tree for
|     the u-area (VA 0x40000000) reusing the physical page kuptr[0] points at,
|     load SRP/URP + ITT0/DTT0/DTT1 via movec, pflusha (f518), movec &0x8000,tc.
|   * Fall through to the verbatim tail (jsr vstart / mlsetup / svirtophys ...).
|
| 040 privileged ops are emitted as .word (movec=4e7b, pflusha=f518, cpusha=f4f8)
| so the file assembles even where gas lacks the 040 control-register names.
| Assemble with: m68k-cbm-sysv4-gcc -m68040 -c pstart040.s -o build/pstart040.o
| (bfins/bfclr in the verbatim 030 build need 68020+.)

	.text
	.globl	pstart
pstart:
| ---- 0xd44: prologue (frame + saved regs, verbatim) ----
	linkw	%fp,&-40
	moveml	%d2-%d6/%a2-%a3,%sp@-
	pea	0x41			| btrace 'A' -- kernel entry reached (SP valid post-prologue)
	jsr	btrace_mark
	addqw	&4,%sp
| CACHE-STATE DUMP (ISSUE-21 diagnostic 2026-07-22): emit the INHERITED CACR +
| RAMSEY control byte right at kernel entry, so a cpu-nocache boot (works) and a
| stock-AmigaOS boot (faults) can be compared -- reveals what cache state the
| kernel inherits (CACR IC=bit15 / DC=bit31) before pstart040 sets its own regime,
| and exactly what `cpu nocache` changes.  Output: "C<cacr> R<ramsey>".  Reached on
| OK boots and on ADDRERR boots (fault after 'A'); ILLEGAL boots fault in config()
| before 'A' so they are not captured.  CACR via movec (supervisor, valid 040);
| RAMSEY A3000 control @0x00DE0003.  d0/a0 scratch here (pre-table-build).
	pea	0x43			| 'C' = CACR follows
	jsr	btrace_mark
	addqw	&4,%sp
	.word	0x4e7a,0x0002		| movec %cacr,%d0
	movel	%d0,%sp@-
	jsr	btrace_hex
	addqw	&4,%sp
	pea	0x52			| 'R' = RAMSEY control byte follows
	jsr	btrace_mark
	addqw	&4,%sp
	moveal	&0x00de0003,%a0
	moveq	&0,%d0
	moveb	%a0@,%d0
	movel	%d0,%sp@-
	jsr	btrace_hex
	addqw	&4,%sp
| NOTE: the original pstart's crash-dump prologue (0xd4c..0xd86) is OMITTED here.
| It tests/sets `crashsw` and `crash_sync`, which are FILE-LOCAL symbols in the
| kernel -- a relink (ld -r) cannot bind our GLOBAL UND references to them, so
| including it leaves them undefined and rel.c aborts (RELA / 0xD2454C41).  On a
| normal (non-crash-recovery) boot crashsw==0, so that block only set crashsw=1;
| skipping it is harmless for 040 bring-up.  (Restore via a .data-offset ref if
| crash-dump support is ever needed.)

| ---- 0xd86: build cpuroot / userroot (8-byte 030 root descriptors) ----
Lpbuild:
	movew	&32767,cpuroot
	bfclr	cpuroot+2{&0:&6}
	bfclr	cpuroot+2{&6:&8}
	moveq	&3,%d1
	bfins	%d1,cpuroot+3{&6:&2}
	clrl	cpuroot+4
	movel	cpuroot,userroot
	movel	cpuroot+4,userroot+4

| ---- 0xdc2: allocate + zero the 4-entry root table (tbl), set kuptr ----
	movel	&end,%d0
	addil	&2047,%d0
	moveq	&11,%d1
	lsrl	%d1,%d0
	movel	%d0,%d6
	lsll	%d1,%d6
	movel	%d6,%fp@(-28)
	pea	0x30
	movel	%fp@(-28),%sp@-
	jsr	bzero
	movel	%fp@(-28),cpuroot+4
	movel	%fp@(-28),%fp@(-36)
	moveq	&32,%d1
	addl	%fp@(-28),%d1
	movel	%d1,kuptr
	moveq	&48,%d1
	addl	%d1,%fp@(-28)

| ---- 0xe08: tbl[0] identity cacheable, addr 0 (VA 0x00000000) ----
	moveal	%fp@(-36),%a0
	clrl	%a0@(4)
	moveal	%fp@(-36),%a0
	movew	&32767,%a0@
	moveal	%fp@(-36),%a0
	bfclr	%a0@(2){&0:&6}
	moveal	%fp@(-36),%a0
	movel	&192,%d1
	bfins	%d1,%a0@(2){&6:&8}
	moveal	%fp@(-36),%a0
	moveq	&1,%d1
	bfins	%d1,%a0@(3){&6:&2}

| ---- 0xe3e: tbl[1] paged (VA 0x40000000) -> st_top1 ----
	movel	%fp@(-28),st_top1
	moveal	%fp@(-36),%a0
	addqw	&8,%a0
	movel	st_top1,%a0@(4)
	moveal	%fp@(-36),%a0
	addqw	&8,%a0
	movew	&1279,%a0@
	moveal	%fp@(-36),%a0
	addqw	&8,%a0
	bfclr	%a0@(2){&0:&6}
	moveal	%fp@(-36),%a0
	addqw	&8,%a0
	movel	&192,%d1
	bfins	%d1,%a0@(2){&6:&8}
	moveal	%fp@(-36),%a0
	addqw	&8,%a0
	moveq	&3,%d1
	bfins	%d1,%a0@(3){&6:&2}

| ---- 0xe8a: tbl[2] identity cache-inhibited (VA 0x80000000) ----
	moveq	&16,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	movel	&0x80000000,%a0@(4)
	moveq	&16,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	movew	&32767,%a0@
	moveq	&16,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	bfclr	%a0@(2){&0:&6}
	moveq	&16,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	movel	&208,%d1
	bfins	%d1,%a0@(2){&6:&8}
	moveq	&16,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	moveq	&1,%d1
	bfins	%d1,%a0@(3){&6:&2}

| ---- 0xed8: tbl[3] identity cache-inhibited (VA 0xC0000000) ----
	moveq	&24,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	movel	&0xc0000000,%a0@(4)
	moveq	&24,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	movew	&32767,%a0@
	moveq	&24,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	bfclr	%a0@(2){&0:&6}
	moveq	&24,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	movel	&208,%d1
	bfins	%d1,%a0@(2){&6:&8}
	moveq	&24,%d1
	addl	%fp@(-36),%d1
	moveal	%d1,%a0
	moveq	&1,%d1
	bfins	%d1,%a0@(3){&6:&2}

| ---- 0xf26: allocate + zero st_top1 segment table, then the u-area pages ----
	pea	0x2800
	movel	st_top1,%sp@-
	jsr	bzero
	movel	st_top1,%d2
	addil	&12287,%d2
	moveq	&11,%d1
	lsrl	%d1,%d2
	movel	%d2,%d3
	asll	%d1,%d3
	pea	0x2000
	movel	%d3,%sp@-
	jsr	bzero
	moveal	kuptr,%a2
	clrl	%d5
	addaw	&24,%sp

| ---- 0xf62: fill kuptr[0..3] with 2KB page descriptors at d3 ----
Lploop:
	moveq	&3,%d1
	cmpl	%d5,%d1
	blt.w	Lpuarea
	movel	%d5,%d0
	moveq	&11,%d1
	asll	%d1,%d0
	addl	%d3,%d0
	addil	&2047,%d0
	lsrl	%d1,%d0
	lsll	%d1,%d0
	moveq	&1,%d1
	orl	%d0,%d1
	movel	%d1,%a2@
	addql	&1,%d5
	addqw	&4,%a2
	bra.w	Lploop

| ---- 0xf8a: st_top1[ (u>>17)&0x1fff ] -> kuptr (DT=2), set ublksde ----
Lpuarea:
	addql	&4,%d2
	movel	&u,%d0
	moveq	&17,%d1
	lsrl	%d1,%d0
	andil	&8191,%d0
	asll	&3,%d0
	moveal	%d0,%a3
	addal	st_top1,%a3
	moveq	&64,%d1
	bfins	%d1,%a3@(2){&6:&8}
	movew	&3,%a3@
	moveq	&2,%d1
	bfins	%d1,%a3@(3){&6:&2}
	movel	kuptr,%a3@(4)
	movel	%a3,%d1
	addql	&4,%d1
	movel	%d1,ublksde
	pea	0x42			| btrace 'B' -- 030 shadow tables built (pre-MMU-enable)
	jsr	btrace_mark
	addqw	&4,%sp

| ================= 68040 MMU enable (replaces 0xfcc..0xfe6) =================
| Build the 040 translation tree, NOW EXTENDED to cover the whole kvseg VA range
| (0x40000000-0x7FFFFFFF, the old 030 A-entry-1 1GB) so the kernel VM (kvm_init ->
| segkmem_mapin, once ported to 040) can fill in the kvseg/kvsegmap/kvsegu maps.
|
| Structure (all in mmu040_buf, .data => loader-zeroed => unused entries invalid):
|   root040   128 x 4 = 512 B, 512-aligned.  root040[32..63] -> kptr040[k] tables.
|   kptr040   32 pointer tables x (128 x 4 = 512 B) = 16 KB, 512-aligned.  A FLAT
|             040 pointer-table array for root entries 32..63, addressed by
|             (va>>18)-4096.  EXPORTED as global `kptr040`; the ported kvm_init
|             writes 040 pointer descriptors here (NOT into st_top1: st_top1 is the
|             030 B-table still read by sysseginit/p0init/bp_map/swapinub/segu_get,
|             so it must stay 030-format until those are ported).
|   uarea_pt  64 x 4 = 256 B leaf page table for the u-area (VA 0x40000000), entries
|             0,1 -> the two u-area 4KB pages.  Hung off kptr040[0] (root32/ptr0).
| Registers: d0=uarea040(phys), a1=root040, d3=kptr040, d6=uarea_pt; d1/a0 scratch.
| d3-d6/a2-a3 are saved/restored by the prologue; d2 MUST be preserved (mlsetup).
	movel	&mmu040_buf,%d0
	addil	&4095,%d0
	andil	&0xfffff000,%d0		| d0 = u_phys = uarea040 (4KB-aligned, 8KB)
	movel	%d0,%d1
	addil	&8192,%d1
	addil	&511,%d1
	andil	&0xfffffe00,%d1
	movel	%d1,%a1			| a1 = root040 = uarea040+8KB (512-aligned)
	movel	%d1,kroot040		| export the 040 kernel root for kvm_init (kas@0x14)
	movel	%d1,%d3
	addil	&512,%d3		| d3 = kptr040 = root040 + 512  (512-aligned)
	movel	%d3,kptr040		| export the pointer-table base for kvm_init
	movel	%d3,%d6
	addil	&16384,%d6		| d6 = uarea_pt = kptr040 + 16KB (512 => 256-aligned)

	| uarea_pt[0] = u_phys | S(0x80)|nocache(0x60)|PDT(0x01) = | 0xE1
	moveal	%d6,%a0
	movel	%d0,%d1
	oril	&0xe1,%d1
	movel	%d1,%a0@
	| uarea_pt[1] = (u_phys+0x1000) | 0xE1
	movel	%d0,%d1
	addil	&0x1000,%d1
	oril	&0xe1,%d1
	movel	%d1,%a0@(4)

	| kptr040[0] = uarea_pt | UDT(0x02)   (root32/ptr0 -> the u-area page table)
	moveal	%d3,%a0
	movel	%d6,%d1
	oril	&0x02,%d1
	movel	%d1,%a0@

	| root040[32..63] = kptr040[k] | UDT(0x02)   (k=0..31; VA 0x40000000>>25 = 32)
	lea	%a1@(128),%a0		| a0 = &root040[32]  (32 * 4)
	movel	%d3,%d4			| d4 = running pointer-table addr
	moveq	&31,%d5			| 32 entries (k=0..31)
Lkroot:
	movel	%d4,%d1
	oril	&0x02,%d1
	movel	%d1,%a0@+
	addil	&512,%d4
	dbf	%d5,Lkroot

	| --- u-area CONSISTENCY: point kuptr[0..3] at uarea040 too ---
	| The kernel finds the u-area's physical pages via kuptr (e.g. mlsetup /
	| proc p_addr).  Since VA 0x40000000 now maps to uarea040 (our buffer), kuptr
	| must point at the SAME memory, or writes via the physical path and reads via
	| VA (or vice versa) diverge -> the kernel reads zeros -> null pointers ->
	| jsr to 0.  kuptr[i] = (uarea040 + i*0x800) | 1  (030 2KB page descriptors).
	| d0 still = uarea040 here.
	movel	kuptr,%a0
	movel	%d0,%d1
	oril	&1,%d1
	movel	%d1,%a0@
	movel	%d0,%d1
	addil	&0x800,%d1
	oril	&1,%d1
	movel	%d1,%a0@(4)
	movel	%d0,%d1
	addil	&0x1000,%d1
	oril	&1,%d1
	movel	%d1,%a0@(8)
	movel	%d0,%d1
	addil	&0x1800,%d1
	oril	&1,%d1
	movel	%d1,%a0@(12)

	| SRP = URP = root040_phys
	movel	%a1,%d0
	.word	0x4e7b,0x0807		| movec %d0,%srp
	.word	0x4e7b,0x0806		| movec %d0,%urp

	| transparent translation registers
	movel	&0x003fc000,%d0
	.word	0x4e7b,0x0004		| movec %d0,%itt0  (0-1GB code, WT-cacheable)
	clrl	%d0
	.word	0x4e7b,0x0005		| movec %d0,%itt1  (unused)
	movel	&0x003fc060,%d0
	.word	0x4e7b,0x0006		| movec %d0,%dtt0  (0-1GB data, cache-inhibited)
	movel	&0x807fa060,%d0
	.word	0x4e7b,0x0007		| movec %d0,%dtt1  (0x80000000+ I/O, cache-inhib,
					|   S=01 SUPERVISOR-ONLY: user VAs >=0x80000000 are
					|   legitimate user space (init's text/data/stack live at
					|   0x80800000) and MUST translate via the URP page tables,
					|   not be swallowed by this identity TTR.  With the old
					|   S=10 (both) value 0x807fc060, copyout's user-FC `moves`
					|   to 0x80800000 was transparently mapped to NONEXISTENT
					|   phys 0x80800000 -> icode write lost, no fault, page stays
					|   zero -> proc 1 SIGSEGVs.  S=01 makes user accesses fault
					|   + demand-page properly.)
	| NOTE: serializing these (CM 0x60->0x40) was TRIED as a real-040 fix for the
	| p0init deferred-write bus error -- it did NOT help (the faulting STORE writes
	| proc[0] in region 1, which is page-table-mapped, so its CM comes from the leaf
	| PTE, not DTT0).  Reverted to 0x60 (no-op on emulators).  See
	| RESUME-HERE-040-HARDWARE.md for the open real-HW hypotheses.

	| push table writes to RAM, flush ATC, enable paging (4KB)
	.word	0xf4f8			| cpusha bc
	.word	0xf518			| pflusha
	movel	&0x00008000,%d0
	.word	0x4e7b,0x0003		| movec %d0,%tc  (E=1, 4KB pages)
	pea	0x43			| btrace 'C' -- paged MMU enabled (serial now via DTT0/ITT0)
	jsr	btrace_mark
	addqw	&4,%sp
	| ---- caches-on Step B1 (2026-07-23): enable INSTRUCTION + DATA cache, DATA in
	| WRITETHROUGH.  CACR = 0x80008000: bit31 DE(040)/EDC(060) + bit15 IE(040)/EIC(060)
	| -- the SAME bits on both CPUs, so no cputype gate is needed.  Spec = analyysirepo
	| vm-map/DTT0-NARROWING-SPEC.md "B1 CACR enable sequence": DTT0 (0x003fc060) is KEPT
	| -- it matches LOGICAL 0-1GB only, so high PTE-backed kvseg/segmap/user mappings
	| take CM from their leaf PTEs (hat_cm_ram=0x00 WT in B1) while the low identity
	| window keeps direct phys/page-table/MMIO access NC.  The 040 DC is physically
	| tagged and an NC access dislodges a matching cached line, so the low NC alias is
	| coherent with a high WT alias; external DMA is covered by the A3091 FROM_DEVICE
	| completion invalidate (dma_cache040.s).  Revert-to-Step-A = 0x80008000 ->
	| 0x00008000 here (git tag pre-dc-enable marks the last IC-only commit).
	|
	| cinva dc BEFORE enabling: the ISSUE-21 config wrapper (config040.s) disables the
	| caches WITHOUT flushing, so the DC can still hold valid (even dirty copyback)
	| lines inherited from AmigaOS/68040.library.  They must be DISCARDED (cinva, NOT
	| cpusha -- a push would overwrite kernel memory with stale AmigaOS data) before
	| the enable makes them visible again.
	|
	| CRITICAL: a bare `movec ...,%cacr` here would be CLOBBERED by the first interrupt.
	| The shared Amiga interrupt handlers (p1int..p6int, ttrap.s) reload CACR from the
	| data globals `sup_cacr` (supervisor) / `cacr` (user) on EVERY entry/return.  Their
	| static values are stale 030 CACR bits (sup_cacr=0x1019, cacr=0x3919) that are INERT
	| on the 040 (no bit15/31) -> that is why the 040 caches have been off.  cache_on/
	| cache_off (0x5641c/0x56406) are DEAD (0 callers), so nothing else writes these.
	| Set BOTH globals to the 040 IC-enable value so the interrupt machinery MAINTAINS
	| IC-on; then enable CACR immediately.  cinva ic first so the IC starts clean.  IC
	| coherence on code RELOAD (a reused physical page getting new code) is handled by a
	| cinva ic at every context switch in resume040 (runtime040.s).
	.word	0xf458			| cinva dc  -- discard inherited/disabled-window DC lines
	.word	0xf498			| cinva ic  -- clear IC before enabling
	movel	&0x80008000,%d0		| 040 CACR: bit31 DE/EDC = DC on (WT via leaf CM), bit15 IE/EIC = IC on
	movel	%d0,cacr		| user-mode CACR value (ttrap restores on return-to-user)
	movel	%d0,sup_cacr		| supervisor CACR value (p1int..p4int,p6int restore per
					| interrupt; p5int loads neither = harmless, values equal)
	.word	0x4e7b,0x0002		| movec %d0,%cacr  (enable IC + DC now)
| =========================================================================
	pea	0x44			| btrace 'D' -- caches enabled (B1: IC + WT-DC)
	jsr	btrace_mark
	addqw	&4,%sp
	.word	0x4e7a,0x0002		| movec %cacr,%d0 -- read back for the dbg serial evidence
	movel	%d0,%sp@-		| (btrace is flag-gated: base/quiet stay silent; dbg prints
	jsr	btrace_hex		|  'D' + 80008000, the HW-session acceptance line)
	addqw	&4,%sp

| ---- 0xfe6: tail (verbatim, except the Model B v-halving below) ----
	pea	0x45			| btrace 'E' -- about to jsr vstart
	jsr	btrace_mark
	addqw	&4,%sp
	jsr	vstart
	pea	0x46			| btrace 'F' -- vstart returned
	jsr	btrace_mark
	addqw	&4,%sp
	| MODEL B: d2 is the bootstrap high-water mark in 2KB clicks (the 030 table
	| build computes it with `lsrl #11`).  Under Model B every downstream click
	| consumer is 4KB (maxclick = memsize>>12, sysseginit does v<<12, kvm_init's
	| smsegs = maxclick>>6 - (v+63)>>6).  Convert v to 4KB clicks (round up) so it
	| matches maxclick; otherwise v is ~2x too big and smsegs collapses to <=0
	| -> panic "No space for mapping files".  d2 is dead after this (Lpepi restores
	| it from the saved-reg frame), so clobber it in place.
	addql	&1,%d2
	lsrl	&1,%d2
	movel	%d2,%sp@-
	jsr	mlsetup
	pea	0x47			| btrace 'G' -- mlsetup returned (kvm_init/sysseginit done)
	jsr	btrace_mark
	addqw	&4,%sp
	| 040 kernel-hat root: kvm_init set kas@(0x14) = cpuroot+4 (the INERT 030 root).
	| hat_pteload walks a kernel seg's root via seg@(12)@(20) = kas@(20) = kas@(0x14)
	| (seg_attach sets seg@(12)=as; offset 0x14 == 20).  Re-point it at the LIVE 040
	| root so kernel-seg maps (segu u-area, segvn...) land in root040->kptr040 = what
	| the 040 MMU walks (SRP=root040).  Done after mlsetup, before main()'s first
	| hat_pteload (fork1->procdup->segu_get).
	movel	kroot040,%d0
	movel	%d0,kas+0x14
	moveq	&95,%d0
	addl	proc_sched,%d0
	moveq	&-16,%d1
	andl	%d1,%d0
	movel	%d0,%sp@-
	jsr	svirtophys
	pea	0x48			| btrace 'H' -- svirtophys done (pstart tail; d0/a0 = ret, preserved)
	jsr	btrace_mark
	addqw	&4,%sp
	bra.w	Lpepi
Lpepi:
	moveml	%fp@(-68),%d2-%d6/%a2-%a3
	moveal	%d0,%a0
	unlk	%fp
	rts
	nop
	nop
	nop
	nop			| pad .text to a 4-byte multiple (loader copies text+data as one block)

	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.data
	.even
| kptr040: the 040 pointer-table region base (root entries 32..63, the kvseg 1GB),
| set at runtime in the MMU-enable block above.  GLOBAL so the ported kvm_init can
| write 040 pointer descriptors into it: slot for VA = kptr040 + ((va>>18)-4096)*4.
	.globl	kptr040
kptr040:
	.long	0
| kroot040: the 040 kernel root table base (root040), set at runtime.  GLOBAL so the
| ported kvm_init can set kas@(0x14) = kroot040 (the kernel root pointer used on
| context switch), replacing the 030 `kas@(0x14) = cpuroot+4`.
	.globl	kroot040
kroot040:
	.long	0

| Static, zero-initialized storage for the 040 tables.  In .data so it is copied
| (zeroed) by the loader; lives in the identity-mapped low region so its kernel
| address == physical address (what the table descriptors / SRP need).  Carved at
| runtime into: a 4KB-aligned 8KB u-area, a 512 B root040, a 16 KB kptr040 region
| (32 pointer tables for root 32..63), and a 256 B uarea_pt leaf table.  Zero-filled
| so every descriptor kvm_init/segkmem have not yet written stays invalid.
| Size: 4KB align slack + 8KB uarea + 512 root + 16KB kptr + 256 uarea_pt ~= 30 KB.
mmu040_buf:
	.space	32768
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
