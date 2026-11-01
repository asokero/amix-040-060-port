| hatmap_nosdt040.s -- ISSUE-110: no legacy 030 segment tables in a user root (2026-11-01).
|
| THE DEFECT.  The retained stock hat_map grows its address space's legacy 030 segment table on every
| segvn_create/segdev_create: hat_growsdt(&as->a_hat, section, n).  hat_growsdt writes the 8-byte 030
| section descriptor into the root page at root + section*8, and the root page is the native 68040 tree's:
| hat_alloc040 hands both the same as@(20).
|
|     section 0 (VA 0x00000000-)  root+0x00..0x07 = native root entries A0, A1
|     section 1 (VA 0x40000000-)  root+0x08..0x0f = A2, A3
|     section 2 (VA 0x80000000-)  root+0x10..0x17 = A4, A5
|     section 3 (VA 0xc0000000-)  root+0x18..0x1f = A6, A7
|
| The first long of a section descriptor (limit | DT) lands in an EVEN native entry and reads as a resident
| pointer descriptor whose table base is a few bytes above physical 0: chip RAM.  A user page in A0, A2, A4
| or A6 (VA 0x00000000-0x01ffffff, 0x04000000-, 0x08000000-, 0x0c000000-) is then looked up, loaded and freed
| through chip-RAM words.  Measured on 68060 emulation with ITT0/DTT0 supervisor-only (4c6ea89): a write to a
| read-only page at 0x00100000 or at 0 (SVR4 ld's zero page) never faults to a signal -- the software ptest
| refuses the chip-RAM table and reports "invalid", the demand path resolves nothing, the CPU retries -- and an
| mmap(MAP_FIXED) page at 0x09000000 ends in "PANIC: hat_pt2ptdat: invalid pte ptr" after hat_free walked
| A0's "pointer table" (Bdesc 4E7A2801, FF3C2C4F, ...).  The odd entries (A1, A3, A5, A7) hold the
| descriptor's table-base long, which the native code simply overwrites.  With DTT0 matching user accesses
| the overlap was invisible: no user access below 1 GiB ever walked the tables.
|
| THE FIX.  The legacy table of a user address space is coverage only: hat_map's vnode preload is disabled
| (patch_pmmu_040.py), hat_exec is a no-op, hat_dup is hat_dup040, hat_swapout is unreachable, and no live
| walker reads a user root as 030 descriptors (svirtophys/vatosde/vatopte walk kernel tables; uvirtophys
| goes through uvatosde040).  So hat_map's one call of hat_growsdt is retargeted to hat_growsdt_user
| (tools/hatmap-nosdt-retarget.py), which returns success without writing for every user address space and
| tail-calls the stock body only for the kernel's own (&kas.a_hat).  hat_map tests nothing but the return
| before it loads URP and returns, so the fork root load is unchanged.
|
| THE TEARDOWN EDGE GOES WITH IT.  legacysdt040.s (ISSUE-40) released the legacy section 2/3 objects at
| hat_free.  With no user address space owning one, that release has nothing to free, and a native A4/A6
| descriptor would reach hat_sdtfree's arguments past nothing but a shape guard.  hat_legacy_sdt_free here
| keeps the symbol hat_free040 calls and only counts; legacysdt040.o is not linked (HATMAP_NOSDT=0 restores
| both, byte for byte).  ISSUE-40's page per dynamic exec is not allocated in the first place.
|
| COUNTERS: hns_magic "HNS!" (anchor), hns_user_n (hat_map growths skipped), hns_kas_n (kernel growths passed
| to the stock body), hns_free_n (hat_free teardowns that reached the retired edge).

	.text
	.globl	hat_growsdt_user
hat_growsdt_user:
	moveal	%sp@(4),%a0		| hatp = &as->a_hat = as + 0x14
	lea	kas+20,%a1
	cmpal	%a1,%a0
	beqs	Lhn_kas
	addql	&1,hns_user_n
	moveq	&0,%d0			| success, nothing written: hat_map goes on to load URP
	rts
Lhn_kas:
	addql	&1,hns_kas_n
	jmp	hat_growsdt		| the kernel address space keeps the stock behaviour

	.globl	hat_legacy_sdt_free
hat_legacy_sdt_free:
	addql	&1,hns_free_n
	rts

	.data
	.balign	4
	.globl	hns_magic
hns_magic:
	.long	0x484e5321		| "HNS!"
	.globl	hns_user_n
hns_user_n:
	.long	0
	.globl	hns_kas_n
hns_kas_n:
	.long	0
	.globl	hns_free_n
hns_free_n:
	.long	0
	.balign	4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
	.text
