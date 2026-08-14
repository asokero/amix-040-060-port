| hat_exec040.s -- 040 no-op override of hat_exec (stock orig 0xb6f20, GLOBAL T).
|
| STATUS (2026-07-15, build 260715-20): this is a SAFETY HARDENING, *not* the ISSUE-10 fix.
| It was built to test Audit #1's hypothesis (hat_exec flag-0 steal -> orphaned 040 PTEs =
| ISSUE-10 chain II).  The 4-burst issue10-pressure.sh repro reproduced the corruption
| IDENTICALLY with this no-op in place (same crash page pp=400AA2C0, same 4AFC005F, same
| \x7fELF disk-read reuse -- test-tools/issue10-noexec-negative-260715.txt), REFUTING that
| hypothesis.  Kept anyway: it removes an unported-030 stack-PT-move optimization and its
| NULL->CE_PANIC branch, and boots clean.  Surviving ISSUE-10 suspects + the recommended
| free-time invariant probe are in docs/ISSUE-10-CHAIN-II-030-MAP.md.
|
| WHY: stock hat_exec is an exec-time OPTIMIZATION that tries to MOVE the exec'ing
| process's stack page tables from the old AS to the new AS instead of faulting
| them back in.  On the 040 its body is UNPORTED (only an 8-byte root-load patch;
| "all section/segment/page/SDE/PTE/ptdat arithmetic is still 030" -- Codex
| docs/contracts/HAT-EXEC-AUDIT.md).  Critically it calls `hat_ptalloc` with flag 0 (steal ALLOWED;
| verified @0xb7232 clrl %sp@-), and under memory pressure the stock allocator falls
| into its UNPATCHED-030 STEAL path (8-byte SDE math 0xb6b52/72, 21-bit PFN 0xb6bb2,
| 2 KiB VA step 0xb6c62).  That steal grabs an unlocked page table from ANY address
| space in active_pts (not just the stack) and 030-unlinks it -- which does NOT clear
| the LIVE 040 PTEs of the stolen table's mapped pages.  Those pages (e.g. a cp/sh
| heap table) are then left with live 040 PTEs orphaned from pp->p_mapping -> freed
| and reused by a concurrent segmap/exec disk-read -> the owner reads freshly disk-read
| ELF content (ISSUE-10 chain II; needs heavy exec + memory pressure, exactly the repro).
| Blocking the steal is NOT an option: on hat_ptalloc==NULL hat_exec cmn_err(CE_PANIC)s
| (0xb7250), so steal is how it dodges the panic under pressure.
|
| FIX (policy recorded in docs/contracts/HAT-EXEC-AUDIT.md): make hat_exec a NO-OP returning 0.  The move
| is a pure optimization -- as_exec already moves the stack SEG object (data ownership is
| on the seg, not the PTEs), relvm tears down the old AS, and the moved stack's
| translations rebuild via 040 faults through the ported hat_pteload.  A no-op never
| calls hat_ptalloc -> no steal path, no NULL panic.  Strictly safer than today (removes
| both the corruption vector and the panic).  Cost: a few extra stack faults per exec.
| Args (ignored): oas, ostka, stksz, nas, nstka, hatflag.  Returns 0.
| --weaken-symbol hat_exec.

	.text
	.globl	hat_exec
hat_exec:
	clrl	%d0			| return 0 (no error); skip the unsafe 030 stack-PT transfer
	rts
	.balign	4			| pad section to a 4-byte multiple (bss placement guard)
