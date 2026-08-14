# Per-process kernel fault-depth implementation specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/KRNXMEMFLT-PER-PROC-DEPTH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/krnxmemflt040.s` implements this
> per-process `p_slot` gate. Real-hardware acceptance observed
> `Lkx_maxdepth = 1`, `Lkx_maxactive = 2`, and zero bad-slot, no-process, and
> underflow events across the recorded pressure and graphics workloads. That
> validates the live implementation and shows concurrent resolvers no longer
> share the decision counter; the specific historical false-positive condition
> `Lkx_maxactive > 4` remains unforced coverage.

## Scope

This note specifies replacing the machine-global recursion gate in
`krnxmemflt040.s` with a per-process gate. In the pinned pre-fix image, the
global decision counter was a real latent concurrency defect even though it
was refuted as the cause of ISSUE-22.

No kernel code is changed here.

## Pinned input

```text
kernel repository HEAD       9c8fd38
build/unix-040 build id      68040-260731-02
build/unix-040 SHA-256       572d8a0b58215d11bbed96dafb8b6aa56091486bd09faa4b9fc4e6ea6feffeca
krnxmemflt_orig              0xda1d0
build/krnxmemflt040.o SHA    817e702df51e0de24785ffb2944bd02d6bc0398c445cc15c1783a61baad23d2e
v.v_proc                     v+8 @0x9354 = 200
proc->p_pidp                 proc+264
pid->pid_prslot              24-bit field at pid+1, bits 0..23
```

## Current defect

The current entry sequence at `0xda1d8..0xda1ec` increments one
`Lkx_depth` long and rejects depth greater than four. The common exit at
`0xda3be..0xda3ca` decrements it.

`as_fault` may sleep while the counter is elevated. Five unrelated processes
at depth one can therefore look like one process recursively faulting at
depth five. The fifth returns unresolved without trying `as_fault`, causing a
false EFAULT under `u_nofault` or a kernel-fault panic without it.

The counter is useful as aggregate instrumentation but is not a recursion
identity.

## Stronger storage result

The earlier DFC audit recommended a 200-entry `proc *`-keyed table because no
safe u-area field existed. Current binary provenance supports a simpler and
stronger design: index directly by `p_slot`.

AMIX does not have a contiguous static `proc[]`. `pid_assign 0x44316`
dynamically allocates each 296-byte proc and stores it in `procdir[slot]`.
It then installs the pid pointer at `proc+264`.

The slot provenance is byte-explicit:

```text
pid_assign 0x44468..0x44476:
    slot = (procent - procdir) >> 2
    bfins slot,pid@(1){0:24}

pid_exit 0x4454a..0x44564:
    pidp = proc@(264)
    bfextu pidp@(1){0:24},d0
    procdir[d0] = procentfree
```

The same slot is stable for the entire process lifetime. A process cannot
complete `pid_exit` and recycle its slot while its own kernel stack is asleep
inside `as_fault`. Therefore a direct table has no owner-staleness race.

## Decision

Add a private, zero-filled table to `krnxmemflt040.o`:

```text
Lkx_proc_depth[200]   200 x uint32_t = 800 bytes
Lkx_fallback_depth    uint32_t
```

Use `Lkx_proc_depth[p_slot]` as the recursion gate. Preserve the existing
`Lkx_depth` symbol only as **aggregate active-resolver instrumentation**; it
must no longer decide failure.

The relink or patch check must assert `v.v_proc == 200`. If the tunable grows,
the table size must grow in the same source change. An out-of-range or absent
`p_pidp` uses the separately counted fallback slot and fails visibly; it must
never index past the table.

## Entry algorithm

The resolver should preserve `a3` for the selected depth-cell pointer across
calls and sleeps. Change its save set from `d2-d4/a2` to `d2-d4/a2-a3`, and
change the common restore offset from `fp-16` to `fp-20`.

Pseudocode:

```text
d2 = 0                         # sane FA in an early depth-failure log
d3 = 0                         # sane rw in an early depth-failure log

disable interrupts briefly
p = *(u + 0x730)
if p != NULL and p->p_pidp != NULL:
    slot = bfextu(p->p_pidp + 1, 0, 24)
    if slot < 200:
        a3 = &Lkx_proc_depth[slot]
    else:
        Lkx_badslot++
        a3 = &Lkx_fallback_depth
else:
    Lkx_noproc++
    a3 = &Lkx_fallback_depth

depth = ++*a3
active = ++Lkx_depth           # instrumentation only
Lkx_maxdepth  = max(Lkx_maxdepth, depth)
Lkx_maxactive = max(Lkx_maxactive, active)
restore interrupt level

if depth > 4:
    failure exit 1
```

Use a full short `spl7` critical section (`SR IPL=7`) and restore the saved SR
before any branch or call. The section consists only of resident u/proc/pid
loads and private data accesses. No function call or page fault is permitted
while interrupts are masked.

`spl7`, rather than the stock `0x2400` list-lock idiom, prevents a higher-level
device interrupt from re-entering the resolver between load and store of the
same process's depth. The interval is only a few dozen instructions.

## Exit algorithm

Every current return funnels through `Lkx_nox`; retain that invariant.

```text
disable interrupts briefly
if *a3 == 0:
    Lkx_underflow++            # fail-soft diagnostic; never wrap to UINT_MAX
else:
    --*a3
if Lkx_depth == 0:
    Lkx_underflow++
else:
    --Lkx_depth
restore interrupt level
restore d2-d4/a2-a3 and return original d0
```

`d0` is the resolver return and must remain untouched by accounting.
`d1` and the saved-SR scratch may be used. `a3` remains valid across
`as_fault`, `cmn_err`, and the far-page helper under the m68k SVR4 callee-save
ABI.

The depth-five rejection still passes through the same exit, so its increment
is balanced. The 040 XPAGE far call and every normal/failure return already
converge at `Lkx_nox`; no second decrement site is required.

## Logging correction

Current `Lkx_f1` branches before fault address and access kind are initialized,
then logs stale `d2` and `d3`. The implementation must initialize both to zero
before the depth gate. For exit 1, log:

```text
depth = *a3
va = 0
rw = 0
```

Exits 2 and 3 retain their decoded VA/RW. Replace the current log read of
global `Lkx_depth` with `*a3`; aggregate active count is not recursion depth.

## Data and observability

Recommended aligned private data:

| Symbol | Meaning |
|---|---|
| `Lkx_proc_depth[200]` | live per-slot recursion depths |
| `Lkx_fallback_depth` | unsupported no-proc/bad-slot context |
| `Lkx_depth` | aggregate active resolver calls; compatibility instrumentation |
| `Lkx_maxdepth` | highest single-process depth |
| `Lkx_maxactive` | highest machine-wide overlap |
| `Lkx_badslot` | `p_slot >= 200` events; must remain zero |
| `Lkx_noproc` | entries without a usable process/pid pointer |
| `Lkx_underflow` | accounting invariant failures; must remain zero |

The table belongs in `.bss`; counters may remain in aligned `.data`. The
current relinker already carries appended object `.bss`, but acceptance must
confirm section alignment and that all 200 entries begin zero.

## Why not the alternatives

### Inferred u-area offset

Rejected. The observed AMIX u-area layout differs from the readable header,
and no unused field is proven. This was the original reason for external
storage and remains true.

### Proc-pointer keyed associative table

Correct but unnecessary. It needs owner lookup, empty-slot handling, and
owner clearing. `p_slot` already supplies a kernel-maintained unique index
with proven allocation and release semantics.

### Current process pointer as hash without owner

Rejected. Hash collisions recreate the false-sharing defect.

### Disable preemption around all of `as_fault`

Rejected. `as_fault` can sleep; holding an interrupt or scheduler exclusion
across it is invalid. Only the accounting load/store is protected.

## Build assertions

1. Assert current old entry bytes:
   `0xda1d8 = 20 39 ... 52 80 23 c0 ... 0c 80 00 00 00 04`.
2. Assert current old exit bytes:
   `0xda3be = 22 39 ... 53 81 23 c1 ...`.
3. Assert `v+8` contains big-endian `00 00 00 c8`.
4. Assert `pid_exit` retains the slot extractor at `0x44552` and
   `proc->p_pidp` load at `0x4454a`.
5. Require no unresolved symbols and zero relocation-check complaints.
6. Confirm `krnxmemflt_orig` has exactly one depth increment and one common
   decrement path.

These are source-object acceptance anchors, not a request to byte-patch the
function. The resolver should be rebuilt as one source unit.

## Runtime acceptance

1. Baseline boot: every table entry and counter starts zero; after boot,
   `Lkx_badslot==0`, `Lkx_underflow==0`, and all per-slot depths return to zero.
2. Run concurrent NFS, local-disk, swap, network, and fork pressure. Require
   no `FAILEXIT w=1` when `Lkx_maxdepth<=4`, even if `Lkx_maxactive>4`.
3. A run that reaches `Lkx_maxactive>4` while all individual depths remain one
   is the decisive exercise of the old false-positive condition.
4. Reproduce a genuinely recursive resolver fault and require only that
   process's slot to reach five and take exit 1. Other processes must continue
   resolving faults.
5. Force an ordinary `as_fault` sleep, sample the sleeping process's slot as
   nonzero, and confirm a second process uses a different slot.
6. Re-run ISSUE-22 DFC injection, ISSUE-37 crossing, copyback burst, and
   `hat_dup_cow`; the return, DFC/SFC, and XPAGE contracts must be unchanged.

If deterministic overlap instrumentation is added, it should pause one test
process only after its slot increment and with interrupts restored. Never
sleep inside the accounting critical section.

## Priority and closure

This is hardening, not a blocker for the already hardware-proven DFC fix. It
becomes valuable before broad multi-process swap/NFS pressure and should land
after the debugger/user-code publication units so cache tests do not combine
unrelated resolver changes.

Static closure requires the per-slot source implementation and assertions.
Runtime closure requires at least one workload where `Lkx_maxactive>4`, or a
deterministic two-process overlap probe plus a genuine same-process recursion
probe.

## Confidence

High confidence in the global-counter defect, p-slot provenance, table size,
lifetime argument, and common-exit ownership. Medium confidence in how often
real workloads overlap more than four resolver sleeps; that is exactly what
the new high-water counters are intended to measure.
