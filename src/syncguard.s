| syncguard.s -- sync() must not walk an uninitialised vfs switch.  The panic path
| runs through it, so without this guard ANY panic before vfsinit() turns into a
| second, unrelated fault that replaces the first panic's diagnosis with
| `DOUBLE PANIC`.  (2026-08-20)
|
| WHY THIS EXISTS -- the mechanism, end to end.  Every address below is from the
| stock 2.1c image this port patches, and each one is quoted from its own
| disassembly or relocation record, not inferred.
|
|   1. panic() (.text+0x3eb58) is a two-line wrapper on xcmn_err(CE_PANIC, ...).
|      xcmn_err prints the message and calls xpanic (.text+0x3e668, LOCAL 't').
|   2. xpanic runs, in order: backtrace, clkreld, panicstr = the message,
|      sysdump, then -- reloc `0x3e6a2 R_68K_32 sync` -- jsr sync, then mtcrchk,
|      call_demon and rtnfirm (the orderly return to firmware).  So sync() sits
|      in the middle of the panic path, ahead of everything that ends the panic
|      tidily.
|   3. sync() (.text+0x5d21a) is:
|
|          for (i = 1; i < nfstype; i++)
|                  (*vfssw[i].vsw_vfsops->vfs_sync)(0, 0, u.u_procp->p_cred);
|
|      compiled as `moveal %a2@(8,%d0:l),%a0` (vsw_vfsops, +8 in a 16-byte
|      struct vfssw) followed by `moveal %a0@(16),%a0` (vfs_sync, the fifth
|      pointer in struct vfsops) and `jsr %a0@`.  Field offsets confirmed against
|      <sys/vfs.h>: vsw_name 0, vsw_init 4, vsw_vfsops 8, vsw_flag 12;
|      vfs_mount 0, vfs_unmount 4, vfs_root 8, vfs_statvfs 12, vfs_sync 16.
|      There is NO null check on either pointer.
|   4. `vsw_vfsops` is filled in at RUNTIME, by vfsinit() (.text+0x5dab2) calling
|      each row's vsw_init.  The .data relocations of `vfssw` (.data+0x913c, 12
|      rows x 16 bytes) prove that only row 0 has a link-time vsw_vfsops
|      (`0x9144 R_68K_32 vfs_strayops`); rows 1..11 carry vsw_name and vsw_init
|      relocations and nothing at +8.  sync()'s loop starts at i = 1.
|      **Therefore, before vfsinit() has run, sync() dereferences NULL, always.**
|   5. What NULL+16 actually is on this machine: absolute address 0x10 is CPU
|      exception vector 4 in the vector table AmigaOS left in low memory, so the
|      "vfs_sync" the kernel calls is an exec ROM trap stub.  That stub walks
|      ExecBase (absolute 4, which AMIX has repointed at its own pseudo-ExecBase)
|      to ThisTask->tc_TrapCode, finds a "no trap code" sentinel, and returns to
|      an odd address -- an address error, vector 3, into the kernel's own
|      handler, which panics again.  The first panic's diagnosis is gone.
|
| Measured on a 68040 boot on real hardware (an accelerator card with its own
| RAM at 0x08000000), 2026-08-19/20: `PANIC: page_free` followed by
| `DOUBLE PANIC ... vector=0x3`, with a firmware bus trace putting the transfer
| at sync+0x34 -- i.e. the `jsr %a0@` above.  Steps 2-5 are pure kernel code plus
| the Kickstart ROM: nothing there depends on the accelerator, the emulator or the
| memory map, so the same cascade is available to any early panic on any machine.
|
| WHAT THIS UNIT DOES.  It replaces sync() with the same loop plus two null
| checks, and counts what they catch.  The loop body is otherwise
| instruction-for-instruction the stock one, including the three pushed arguments
| and the `addaw &12,%sp` cleanup, so the syscall path (syssync, .text+0x5d26c,
| the only other caller -- there are exactly two R_68K_32 references to `sync` in
| the whole image) keeps its behaviour and its ABI.
|
| One deliberate reordering: the stock code pushes the three arguments and THEN
| loads vfs_sync.  Here vfs_sync is loaded first, so that a null one can be
| skipped without having to unwind three pushes.  The loads and the pushes do not
| alias (the arguments come from the u-area and the stack, vfs_sync from the
| vfsops table), so the order between them is not observable.
|
| WHAT IT DOES NOT DO.  It does not fix whatever panicked; it makes the panic
| survivable enough to say what did.  Skipping a filesystem whose switch row is
| not initialised is not a loss: that filesystem has nothing to flush, because it
| has not been initialised.
|
| THE COUNTER BLOCK is how a healthy kernel proves this override is behaving like
| stock: on a machine that reaches multiuser, `syncg_calls` climbs (fsflush calls
| sync(2) continuously) while `syncg_skip_ops` and `syncg_skip_fn` stay at zero --
| an invariant that a passing boot alone would not demonstrate.  A nonzero skip
| count on a running system means a vfs switch row that vfsinit left empty, which
| is a finding in its own right.  Read the magic word FIRST: the block sits in
| .data and its address moves on every build (tools/status-facts.sh prints it).
|
| Assemble: m68k-cbm-sysv4-gcc -m68040 -c syncguard.s -o build/syncguard.o
| Wire:     --weaken-symbol sync (relink-040.sh).  Externals: nfstype, vfssw
|           (both global D in the stock image) and the absolute symbol u.
| ============================================================================

	.text
	.globl	sync
sync:
	linkw	%fp,&0
	moveml	%d2/%a2,%sp@-
	addql	&1,syncg_calls
	moveq	&1,%d2			| i = 1: row 0 is the stray-ops row, never synced
	cmpl	nfstype,%d2
	bgew	Lsgdone
	lea	vfssw,%a2

Lsgloop:
	movel	%d2,%d0
	asll	&4,%d0			| i * sizeof(struct vfssw) == 16
	moveal	%a2@(8,%d0:l),%a0	| a0 = vfssw[i].vsw_vfsops
	tstl	%a0
	beqw	Lsgnoops		| GUARD: row not initialised yet -- skip it
	moveal	%a0@(16),%a0		| a0 = vfsops->vfs_sync
	tstl	%a0
	beqw	Lsgnofn			| GUARD: no sync entry point -- skip it
	moveal	u+0x730,%a1		| a1 = u.u_procp  (curproc)
	movel	%a1@(16),%sp@-		| arg3 = p_cred   (<sys/proc.h>: p_cred is +16)
	clrl	%sp@-			| arg2 = 0
	clrl	%sp@-			| arg1 = 0
	jsr	%a0@
	addaw	&12,%sp
	braw	Lsgnext

Lsgnoops:
	addql	&1,syncg_skip_ops
	movel	%d2,syncg_last_i
	braw	Lsgnext

Lsgnofn:
	addql	&1,syncg_skip_fn
	movel	%d2,syncg_last_i

Lsgnext:
	addql	&1,%d2
	cmpl	nfstype,%d2
	bltw	Lsgloop

Lsgdone:
	moveml	%fp@(-8),%d2/%a2
	moveal	%d0,%a0
	unlk	%fp
	rts
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)

	.data
	.even
| Read this FIRST.  A counter block at a stale address does not fail -- it
| returns a plausible number from whatever now lives there.
	.globl	syncg_magic
syncg_magic:
	.long	0x53594e47		| "SYNG"
| sync() entries.  Nonzero on any kernel that reached fsflush.
	.globl	syncg_calls
syncg_calls:
	.long	0
| Iterations skipped because vfssw[i].vsw_vfsops was NULL -- the pre-vfsinit case
| this unit exists for.  Expected to stay 0 on a healthy multiuser kernel.
	.globl	syncg_skip_ops
syncg_skip_ops:
	.long	0
| Iterations skipped because vfsops->vfs_sync was NULL.  Defensive; no filesystem
| in this kernel is known to leave it empty, and stock would have called through it.
	.globl	syncg_skip_fn
syncg_skip_fn:
	.long	0
| The vfssw index of the most recent skip, so a nonzero count names a row.
	.globl	syncg_last_i
syncg_last_i:
	.long	0
	.balign 4			| pad section to a 4-byte multiple (bss placement: rel.c puts .bss at data_end UNALIGNED)
