# ISSUE-42 68040 Write-Back Replay Protection Contract

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The user-write-back propagation contract
> specified here has landed and ISSUE-42 is closed on 68040 silicon. On an
> A3640, `protfault` passed all three cases; the in-boot control reproduced the
> silent denial with propagation disabled and removed it when enabled. The
> measured denied access was WB3 with user-data TM 1. WB1 and the
> supervisor/table-search/push dispositions remain coverage gaps rather than
> accepted runtime paths. See `docs/REALHW-A3640-260813-ACCEPTANCE.md`.

## Status and scope

This document answers the five static questions in
`ISSUE42-WBREPLAY-CODEX-TASK.md`. It specifies the architecture and VM
contract. It did not itself change kernel code or claim real-68040 acceptance;
the current-state note above records the later implementation and acceptance.

Pinned input:

- kernel repository commit:
  `0d3b6689fdce273341bd58c9dce4da78f453c53b`;
- `build/unix-040` SHA-256:
  `c187b86887dd855c46ac725aed2bc90dfcfc1b243d655ea4ee314301d31f94d2`;
- linked `.text`: file offset `0x34`, size `0x000e4bb8`, SHA-256
  `0e6e119849e9211838265bdc1c9d7f895999513088534f692e313447a1ee8985`;
- vanilla `stand/unix` SHA-256:
  `7d26cb6f04991be5776d9e5361259b20b413d97e3da33bf88e6f312e7be2ec23`;
- local FS-UAE `fs-uae/src/cpummu.cpp` SHA-256:
  `e38099c524e6a4462044a97ac636f2e6384056deab34bdad0a9a1680d9b21bba`.

The seven measured facts in the task are accepted as facts. In particular,
case C reaches the instruction after the crossing store on emulated 68040,
while cases A and B terminate with `SIGSEGV` and the real 68060 passes all
three cases.

## Executive verdict

| Question | Verdict |
|---|---|
| Q1: reference contract | Motorola, NetBSD, and Linux all treat each valid write-back as an access that must either complete or report its own fault. WB1, WB2, and WB3 are ordered. A successful near-page resolution does not authorize a different WB address. SVR4 has no 68040 frame code, but its `as_fault`/`segvn_faultpage` contract independently enforces `S_WRITE` on every page in the requested range. |
| Q2: check or discard | Validate every valid WB independently. Do not discard one merely because its address differs from the original fault address: WB2/WB3 can represent older pipeline stores. If a user WB is denied, stop the ordered replay and propagate the denied WB address as a protection fault. Silently dropping it and returning success is invalid. |
| Q3: live PTE | Page 2 is hardware write-protected. `segvn_setprot -> hat_chgprot040` sets live PTE bit 2 and publishes it with `cpusha bc; pflusha`. Case B could not trap at all if the PTE remained writable. ISSUE-41 repaired the software verdict after that hardware fault; it did not create the hardware protection. |
| Q4: DFC privilege | A supervisor function code does not override an encountered 68040 W bit. W protects against writes of any kind, including supervisor writes. FC can select a different root or transparent mapping, however, so a wrong FC can avoid the user PTE rather than override it. The emulated case C is generated with user-data FC 1, so supervisor DFC is not its cause. |
| Q5: static vs silicon | The emulated failure mechanism is statically decidable and is not a demonstrated PTE protection bypass: the far byte faults, `Lwb_fail` swallows that failure, and the wrapper returns the near resolver's zero. Real silicon is needed only to establish the exact WB slot/status combination and runtime reachability on a physical 68040. The required error-propagation contract does not depend on that result. |

## Headline correction: survival is not proof that page 2 changed

The current test and issue title overstate what was measured.

`protfault` case C performs one store and exits with status 42 if execution
reaches the following instruction. It never reads page 2 back. Therefore the
observation proves:

```text
the 68040 path retired/resumed past the denied store without delivering SIGSEGV
```

It does not prove:

```text
the bytes in the PROT_READ page were modified
```

The current source predicts the opposite for the emulated case. The emulator
decomposes the unaligned long write, raises a user-data write fault at the far
page, and constructs a valid WB3 for the original access. `Lwb_do` replays
the access byte by byte under DFC 1. Its first byte in page 2 faults again.
The nested user resolver now has ISSUE-41's permission check and rejects the
write. `k_trap` redirects execution to `Lwb_fail`, which skips the remaining
bytes and returns no error to `wb040_replay`.

The outer wrapper still has `d4=0` from the successfully resolved near page,
so it returns success and user execution continues after the store. This is a
silent write-back abort, lost/partial-store behavior, and missing signal. It
is a serious correctness defect, but the supplied evidence does not establish
a write through the protected PTE.

The source comment at `wb040.s:659-660` is consequently false for this case:

```text
the process re-faults on its own if the address matters
```

The 68040 does not rerun the ordinary faulting write once software takes
ownership of its pending write-backs. Returning after dropping one is exactly
why `protfault` reaches `_exit(BYPASS)`.

## Current linked anchors

| Symbol / operation | Linked address | Relevance |
|---|---:|---|
| `k_trap` | `0x0005a0e8` | Routes guarded nested MOVES fault |
| `u_trap` | `0x0005a47e` | User signal consumer |
| `fault_to_info` | `0x0005adf2` | SVR4 `faultcode_t` to `k_siginfo_t` translator |
| `usrxmemflt_orig` | `0x0005aede` | Resolves/classifies the CPU-named page |
| `segvn_faultpage_orig` | `0x000ac01a` | Stock fault body |
| `segvn_setprot` | `0x000ac9aa` | Stores partial-mapping `vpage` policy |
| `as_fault` | `0x000ae108` | Page-rounded SVR4 fault dispatcher |
| `hat_chgprot` | `0x000d8710` | Live 040 PTE permission writer |
| public `usrxmemflt` | `0x000d9598` | Near resolver plus 040/060 completion wrapper |
| `wb040_replay` | `0x000d98ee` | WB1/WB2/WB3 dispatcher |
| `Lwb_do` | `0x000d99aa` | Byte-wise `MOVES`, DFC, and nofault arm |
| `Lwb_fail` | `0x000d9a1a` | Current unresolved-WB sink |
| public `segvn_faultpage` | `0x000d9b44` | ISSUE-41 per-vpage permission wrapper |
| public `ptest` | `0x000d9a54` | Live URP permission probe |
| `Lwbf_n` | `.data+0x00018570` | Capped-at-eight failure/log counter |
| `wb_replay_n` | `.data+0x00018588` | Replay attempts |
| `wb_replay_odd` | `.data+0x0001858c` | WB transfer modes other than FC 1 |
| `segvn_prot_n` | `.data+0x000185e4` | Per-vpage denials |

`Lwbf_n` stops incrementing at eight. Its lack of new console output is not
evidence that case C avoided `Lwb_fail` if earlier activity saturated it.

## Q1: reference write-back contract

### Motorola M68040 architecture

The primary architecture reference is the
[M68040 User's Manual](https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf),
sections 8.4.6.3 through 8.4.6.7.

The relevant rules are:

1. A format-7 frame contains up to three pending write-backs.
2. After correcting the fault, software completes valid write-backs in the
   order WB1, WB2, WB3.
3. WB1 corresponds to the corrected fault and should not fault again.
4. WB2 and WB3 can raise another access error and may be checked before the
   write if the OS needs to avoid nested exceptions.
5. WB addresses are independent pipeline state. They are not required to
   equal the frame's FA.

The manual therefore rules out both unsafe extremes:

- replaying every WB while ignoring a new fault is wrong;
- deleting every WB whose address differs from FA is also wrong.

The architecture requires ordered completion with independent fault handling.

### NetBSD

The local NetBSD source bundle contains two useful forms of the contract.

Modern common `m68040_writeback`:

Source-bundle path: `sys/arch/m68k/m68k/m68k_trap.c` (`m68k_trap.c`,
revision 1.3 dated 2021-03-06 in the inspected bundle).

For each non-kernel-data WB it calls a fault-safe `ustore_char`,
`ustore_short`, or `ustore_long`. It attempts WB2 and WB3 only while the
previous write returned no error. A failed user write returns `SIGSEGV`.
The hp300 `userret` path delivers that signal and permits one post-signal
retry rather than silently treating the WB as complete.

The retained Amiga-specific `_write_back` is even more explicit:

Source-bundle path: `sys/arch/amiga/amiga/trap.c` (`trap.c`, revision
1.139.20.1 dated 2024-09-12 in the inspected bundle).

It probes the WB address and any crossed endpoint, invokes
`uvm_fault(..., VM_PROT_READ | VM_PROT_WRITE)` for missing/nonwritable pages,
and returns the failure before issuing `MOVES`. Its comment states the exact
problem: WB2/WB3 can span a second page, so both ends must be checked.

Neither implementation discards a WB because it targets a different page.
Both give that page its own write-permission verdict.

### Linux m68k

Current Linux implements the same policy in
[`arch/m68k/kernel/traps.c`](https://github.com/torvalds/linux/blob/master/arch/m68k/kernel/traps.c).

`do_040writeback1` sets the frame-provided FC and uses `put_user` for byte,
word, or long writes. On failure, `do_040writebacks`:

1. rewrites the retained format-7 fault address/status to the failed WB;
2. leaves that WB pending instead of clearing it;
3. stops normal ordered progress; and
4. sends the resulting memory-fault signal.

If the original user page fault was not resolved, Linux delays write-back
completion until after signal delivery. On `sigreturn`, `berr_040cleanup`
clears the supervisor bit from WB2/WB3 before replay so a user-supplied frame
cannot manufacture a supervisor access.

This supplies two contracts relevant to AMIX:

- a failed WB is a fault outcome, not a successful skipped store;
- a frame that passes through user signal state must not be trusted to retain
  supervisor FC authority.

### SVR4 3B2

The 3B2 has no 68040 format-7 frame, so it cannot define WB slot mechanics.
It does define the VM policy that a replay must preserve:

```text
svr4-src-3b2/usr/src/uts/3b2/vm/vm_as.c:194-277
svr4-src-3b2/usr/src/uts/3b2/vm/seg_vn.c:1070-1095
svr4-src-3b2/usr/src/uts/3b2/vm/seg_vn.c:1738-1757
```

`as_fault(as, addr, size, type, rw)` rounds and dispatches the complete
requested interval. `segvn_faultpage` rejects any per-page access for which
`vp_prot & PROT_WRITE` is zero. `segvn_setprot(PROT_READ)` changes existing
translations through `hat_chgprot`.

Therefore a successful `as_fault` for the near page says nothing about a WB
whose range touches another page. That WB must receive its own `S_WRITE`
verdict.

### Difference in current AMIX

| Contract edge | Motorola / NetBSD / Linux | Current AMIX |
|---|---|---|
| Original fault succeeds | Process WBs in order | Processes WBs in order |
| WB address differs from FA | Still a valid pending store | Still attempted |
| User WB touches absent but permitted page | Resolve and complete | Nested byte fault can resolve and complete |
| User WB hits protection/no-map | Return/retain fault and stop ordered progress | `Lwb_fail` logs at most eight times, skips remainder, then returns success |
| Later WB after an earlier failure | Normally stopped/deferred | Still attempted because no failure state exists |
| Original user fault fails | Preserve/defer WBs across signal handling as needed | Wrapper skips all WBs; no later 040-specific completion path was identified |

The last row is adjacent to ISSUE-42 rather than its observed cause. It can
lose an older pending WB if a handled user signal returns. It does not affect
the no-handler `protfault` result, where process death makes pending stores
irrelevant.

## Q2: validate each WB independently

### Verdict

The correct contract is:

```text
for WB1, WB2, WB3 in architectural order:
    if invalid: continue
    classify the WB's own FC, address, size, and transfer type
    attempt/resolve the exact WB range under that address space's policy
    if completion fails:
        stop normal ordered replay
        propagate that WB address and fault class
```

Address inequality is not a rejection criterion. WB2/WB3 can represent a
pending store from a previous pipeline instruction. The real-hardware
ISSUE-7 history is a direct local example: a WB target can be a page the
near resolver never touched and still be state that must be completed.

### What counts as validation

An implementation may preflight with a PTE/policy query, or it may use a
fault-safe store as NetBSD and Linux do. In both cases the actual write is the
final authority because mappings can change between a software query and the
store.

For a user WB, validation must preserve all of these:

- use the process address space / user translation semantics;
- check the exact transfer width, including a crossed endpoint;
- resolve an absent but permitted page and retry;
- return `FC_PROT`/`SIGSEGV` for a denied page;
- return the proper no-map or hardware error for those failures;
- attribute the signal to the first failing WB byte, not the already-resolved
  near FA.

The current byte-wise `MOVES` loop already supplies exact per-byte fault
addresses and convergence for absent pages. Its missing piece is not another
unconditional pre-check. Its missing piece is a failure return channel from
`Lwb_fail` through `Lwb_do` and `wb040_replay` to the user resolver's complete
`k_siginfo_t` contract.

If AMIX supports returning from a handler that repairs the mapping, pending
WB state must be retained or reconstructed until completion, as in the
reference implementations. If the process will terminate, stopping and
discarding the remaining process-local WBs is safe only after the fatal
outcome has been committed. Returning success after discarding them is not.

## Q3: the live PTE is write-protected

The linked path is:

```text
mprotect 0x000dad5c
  -> as_setprot 0x000ae2ea
  -> segvn_setprot 0x000ac9aa
  -> hat_chgprot 0x000d8710
```

For a private mapping changed to nonzero protection without `PROT_WRITE`,
the SVR4 source calls `hat_chgprot`. The current 040 override implements the
same operation on the live URP tree:

```text
read-only:  PTE |= 0x00000004       /* 68040 W bit */
tail:       cpusha bc; pflusha
```

The PTE remains resident (`PDT=1`) and becomes write-protected (`W=1`). The
cache push publishes the descriptor write and the ATC flush forces a fresh
translation.

There is also a behavior proof. Case B is an aligned CPU store wholly inside
page 2. If page 2's live PTE remained writable, the CPU store would complete
without entering `usrxmemflt`, and ISSUE-41's `segvn_faultpage` wrapper could
not possibly turn it into `SIGSEGV`. Case B passes, so a hardware write fault
is occurring.

ISSUE-41 repaired what happens after that hardware fault. Before the repair,
the stock body reinstalled/retained a read-only mapping and incorrectly
returned zero, causing recurrence. It did not show that the PTE was writable.

Q3 therefore does not move the fix to `mprotect` or HAT. The permission is
present in both the segment policy and live PTE.

## Q4: DFC selects an address space; it does not override W

Section 3.2.6.3 of the Motorola manual is explicit: descriptor W bits protect
against writes of any kind, including supervisor writes. A `MOVES` using
DFC 5 cannot write through a W bit encountered in the selected translation.

Function code still matters because it selects translation context:

- FC 1 is user data and uses user translation semantics / URP;
- FC 5 is supervisor data and uses supervisor translation semantics / SRP;
- a matching DTT can bypass table lookup entirely.

Thus a supervisor FC can avoid the user's protected descriptor by selecting
a different writable mapping. That is not a privilege override of W; it is a
different translation.

This port has a concrete version of that hazard. DTT1 is a supervisor-only
high-address identity window. A replay of a user VA under FC 5 can therefore
miss the per-process URP mapping and use the identity path, which is the same
wrong-address-space family exposed by ISSUE-22. Depending on the physical
target, that can bus-fault or access something unrelated. It still does not
make the user's `W=1` PTE writable.

It is not the mechanism of the measured emulated case C:

1. FS-UAE computes a normal user data access as FC 1.
2. `mmu_bus_error` copies that FC into the 040 SSW/WB3 status.
3. `Lwb_do` therefore sets DFC 1.
4. The replay traverses the URP and encounters page 2's W bit.

`wb_replay_odd` remains important for real pending stores and untrusted
signal frames. Linux's explicit clearing of TM2 on `sigreturn` is a useful
policy precedent. But an odd/supervisor FC is not needed to explain the
current emulator result.

## The exact emulated case-C flow

The following chain is derivable from the pinned source and linked image:

```text
user long store at page_end-2, FC=1
  emulator writes the near half, faults on page 2's W bit
  emulator reports format 7 with a valid WB3, FC=1

outer usrxmemflt
  resolves/classifies the CPU-named near page
  returns 0
  calls wb040_replay

Lwb_do(WB3)
  DFC=1
  writes bytes from the original start address
  near-page byte(s) complete
  first page-2 byte faults on W=1

nested k_trap with u_nofault armed
  routes FC=1 to usrxmemflt
  segvn_prot040 sees page-2 vp_prot lacks PROT_WRITE
  returns FC_PROT / nonzero
  k_trap changes saved PC to Lwb_fail

Lwb_fail
  restores outer u_nofault
  optionally logs and increments capped Lwbf_n
  returns with no error status

outer wb040_replay / usrxmemflt
  continue as if WB3 completed
  return original d4=0

user process
  resumes after the store
  exits with BYPASS=42
```

Two current implementation properties make the result unavoidable:

- `Lwb_do` and `wb040_replay` have no return value or sticky failure flag;
- `Lwb_fail` uses `rts`, so later WBs are still eligible even after a denied
  earlier one.

The exact already-written near-page bytes are an emulator/model detail and
are not needed for the contract verdict. The protected far page should remain
unchanged under FC 1 because both the model and architecture enforce W.

## Q5: emulator boundary versus real silicon

### Statically decidable now

The local FS-UAE source proves its 040 frame model for this class:

- ordinary write faults set WB3 valid and clear WB2;
- WB1 address/status is emitted as zero;
- WB3 TM is copied from the faulting access FC;
- an unaligned access that faults after its first subaccess marks MA and
  reconstructs the original access address/data for WB3;
- `MOVES` with DFC 1 uses user translation and rejects a W descriptor.

Together with the linked AMIX code, this proves the emulator-visible
no-signal outcome is caused by swallowed replay failure. It is not necessary
to speculate about a writable PTE or supervisor privilege.

The architecture and OS contract is also decidable without hardware:

- valid WBs are ordered and independently faultable;
- W applies to supervisor writes too;
- a denied WB must not be reported as completed;
- a different WB address is not grounds for dropping it.

### Requires real 68040 silicon

The Motorola manual describes legal frame combinations, but pipeline timing
determines the exact frame for a particular instruction. A real 040 run is
needed to establish:

- whether this exact crossing `mprotect` case produces WB1, WB2, WB3, or a
  combination on the available board;
- each valid slot's TM, size, address, and data;
- whether the current AMIX replay reaches `Lwb_fail` in that exact case;
- the final user-visible result and partial-write footprint on silicon.

The difference is material: the emulator models ordinary faults primarily as
WB3, while the manual's page-fault examples include WB2 and an optional WB3.
That prevents claiming runtime reproduction on real 040. It does not weaken
the static defect: any permanently failing WB reaches a sink that cannot
propagate failure.

## Required behavioral contract for a later implementation

This is not an assembly design, but a reviewable implementation must satisfy
these invariants:

1. Preserve the ISSUE-7 byte-granular convergence behavior for absent but
   permitted pages.
2. Preserve the ISSUE-22 caller DFC/SFC restoration.
3. Process valid WBs in WB1, WB2, WB3 order, with current MOVE16 exclusions.
4. Treat each WB address/range and FC as independent state.
5. Stop normal replay on the first permanently denied user WB.
6. Convert the failure into complete `k_siginfo_t` state using the failing WB
   address; do not return the near resolver's zero.
7. Do not process a later user WB as though an earlier failed WB completed.
8. If a signal frame can return, sanitize any user-restored supervisor FC and
   retain enough WB state to complete after a handler repairs the mapping.
9. Keep kernel-WB failure semantics separate from the user signal ABI.
10. Do not call a store successful merely because the handler resumed past
    it; verify memory effects when characterizing runtime behavior.

## Final answers for Claude

1. **Reference contract:** replay follows successful resolution, but every
   valid WB remains independently faultable. NetBSD and Linux propagate a
   failed user WB; AMIX currently swallows it. SVR4 independently requires
   per-page `S_WRITE` permission.
2. **Check, not address-based discard:** validate each WB under its own
   address space and range. On denial, stop and signal. Do not discard merely
   because the near resolver did not inspect that address.
3. **PTE state:** page 2 is resident and hardware write-protected. The fix
   does not belong in `mprotect`/`hat_chgprot040` on the supplied evidence.
4. **DFC:** supervisor FC does not override W. It can select a different
   root/TTR mapping, which is a separate hazard. Emulated case C uses FC 1.
5. **Artifact boundary:** the exact WB slots are emulator-specific and need
   real 040 for runtime acceptance. The silent-failure contract bug and the
   required correction are statically established now.

The issue should be described as **missing protection-fault propagation and a
silent write-back abort** until a memory readback proves that protected bytes
actually changed. The existing `protfault` result alone proves survival, not
write-through.

## Sources

- Motorola/Freescale, `M68040 User's Manual`, sections 3.2.6.3 and
  8.4.6.3-8.4.6.7:
  <https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf>
- Linux m68k, `arch/m68k/kernel/traps.c`, `do_040writeback1`,
  `do_040writebacks`, `berr_040cleanup`, and `access_error040`:
  <https://github.com/torvalds/linux/blob/master/arch/m68k/kernel/traps.c>
- local NetBSD bundle:
  `netbsd/syssrc.tgz`, common `m68k_trap.c`, hp300 `trap.c`, and Amiga
  `trap.c` paths listed above;
- 3B2 SVR4:
  `svr4-src-3b2/usr/src/uts/3b2/vm/vm_as.c` and `vm/seg_vn.c`;
- current port:
  `prototypes/wb040.s`, `prototypes/hat_chgprot040.s`,
  `prototypes/segvn_prot040.s`, `test-tools/protfault.c`;
- emulator model:
  `fs-uae/src/cpummu.cpp`, `fs-uae/src/include/cpummu.h`, and
  `fs-uae/src/newcpu.cpp`.
