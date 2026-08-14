# ISSUE-42 Write-Back Replay Follow-Up Audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/ISSUE42-WBREPLAY-FOLLOWUP-AUDIT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The landing-pad ownership check, the
> transfer-modifier classification, and user-fault propagation described by
> this follow-up are present in `src/wb040.s`. Real 68040 acceptance observed
> `wbf_alien_n = 0`, user-data TM 1, and correct `SIGSEGV` delivery. The
> supervisor branch remains unexercised (`wbf_sup_n = 0`), and returning-handler
> preservation of partially replayed write-backs remains a documented limit.
> The initial pre-silicon boundary below is retained as provenance.

## Status and scope

This is the static follow-up to
`ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md` after the first propagation unit
landed. It answers three questions raised by that implementation:

1. what an unresolved supervisor-function-code write-back may do;
2. how pending format-7 write-backs can survive a returning signal handler;
3. whether `Lwb_fail` may always assume the stack shape created by
   `bsrw Lwb_do`.

It did not itself change kernel code or claim 68040-silicon acceptance.

Pinned input:

- kernel repository commit:
  `10096a0270112fd0b7ebfa0346609ca5fdd4afc8`;
- commit subject: `ISSUE-42: propagate a denied write-back instead of swallowing it`;
- `build/unix-040` SHA-256:
  `80d5943591104e69c3e38bf0c712b0f3a898dd145d6ab8bd8d9e08a782d444dc`;
- current measured boundary: the user-FC path passes on emulated 68040,
  the supervisor-FC counter `wbf_sup_n` has remained zero, and no real 68040
  has accepted this unit.

The earlier protection-contract conclusions remain in force: valid
write-backs are independent ordered accesses, a denied write-back cannot be
reported as completed, and the write-back's own FC/address/size is the
authoritative access description.

## Executive verdict

| Question | Verdict |
|---|---|
| Q1: unresolved supervisor WB | The current `stop + count + return success` disposition is unsafe. It silently loses a kernel/CPU-space write while allowing execution to continue. Resolve and complete it; otherwise transfer failure to a demonstrably matching outer nofault owner, or fail fast. Do not use the user-signal ABI and do not return the near resolver's zero. |
| Q2: state across signal return | AMIX already has raw storage: `uc_mcontext.mc_state` receives the complete hardware frame, and `prsetstate` stages it in `u.u_sigsave` before `stkrestore`. No new slot is needed merely to retain a format-7 frame. What is missing is a trusted sigreturn cleanup that sanitizes user-controlled WB FCs and completes only still-pending WBs before `rte`. |
| Q3: `addql #4,%sp; rts` | It is correct for the intended fault at `Lwb_loop` because `k_trap -> stkclear -> rte` restores the pre-`MOVES` SP. It is not guaranteed for every fault that can observe the scalar `u_nofault=Lwb_fail`: no owner/cookie/PC check prevents an asynchronous or otherwise unrelated kernel fault from landing there with a different stack and different `d2`. The current claim is conditional, not universal. |

Two implementation comments need recalibration:

- `wb040.s:774-775` says returning-handler support needs somewhere to keep
  per-process WB state. The stock context ABI already keeps the complete
  format-7 frame. A separate continuation record may still be required for
  byte-granular partial progress, but raw frame storage is not missing.
- `wb040.s:760-763` describes the intended stack correctly, but it does not
  prove that every use of the process-wide nofault pad was caused by the
  intended `MOVES.B` instruction.

## Current linked anchors

| Symbol / operation | Address | Relevance |
|---|---:|---|
| `ktraps` | `0x000011ce` | Calls `k_trap`, then selects normal return or `stkclear` |
| `stkclear` | `0x0000129e` | Converts a long fault frame to format 0 and performs `rte` |
| `stkrestore` | `0x000012d8` | Reconstructs the frame held in `u.u_sigsave` before `rte` |
| `sigsave` | `.data+0x000072a4` | Relocated initializer `u+0x1e4` |
| `sigflag` | `.data+0x000072a8` | Relocated initializer `u+0x5c4` |
| `framesz` | `.data+0x000072ac` | Format 7 entry is `0x3c` (60 bytes) |
| `restorecontext` | `0x00058d76` | Restores CPU/FPU/signal/stack context |
| `savecontext` | `0x00058f10` | Saves CPU/FPU/signal/stack context |
| `sendsig` | `0x00059022` | Copies the 1024-byte context to user space and requests `stkclear` |
| `k_trap` | `0x0005a0e8` | Owns the scalar `u_nofault` redirection contract |
| `prgetstate` | `0x000637be` | Copies the complete live hardware frame by `framesz[format]` |
| `prsetstate` | `0x000637f4` | Stages a supplied hardware frame and requests `stkrestore` |
| `usrxmemflt` | `0x000d9598` | User-side resolver/replay wrapper |
| `krnxmemflt` | `0x000d9670` | Kernel-side resolver/replay wrapper |
| `wb040_replay` | `0x000d99a4` | Ordered WB1/WB2/WB3 dispatcher |
| `Lwb_do` | `0x000d9a74` | Byte-wise write-back attempt and nofault arm |
| `Lwb_loop` / `MOVES.B` | `0x000d9ad0` / `0x000d9ad2` | The only intended source of `Lwb_fail` landings |
| `Lwb_fail` | `0x000d9ae4` | Nofault landing pad and replay-abort stack surgery |

## Q1: unresolved supervisor write-back

### What the current implementation does

`Lwb_fail` classifies the low three WB status bits at `0x000d9b36`:

```text
TM 0..2  -> d0 = 1, wbf_user_n++
TM 3..7  -> d0 = 2, wbf_sup_n++
```

It then drops the `Lwb_do` return address and returns directly to the wrapper.
For `d0 == 2`:

- `usrxmemflt` skips signal construction, leaves its saved `d4 == 0`, and
  returns success;
- `krnxmemflt` increments `wbf_krn_n`, leaves its saved `d4 == 0`, and also
  returns success unless the separate 060 crossing helper fails.

Thus `stop` currently means only "do not attempt later WB slots". It does not
mean "the interrupted operation failed". A permanently denied supervisor WB
is silently omitted while kernel execution continues.

That is more dangerous than the old user-store loss. A supervisor WB may be
publishing a pointer, reference count, queue link, PTE, or other kernel
invariant. Returning success permits consumers to observe the before-state
after the producer logically passed the store.

`wbf_sup_n == 0` establishes only that this branch has not been exercised by
the measured workloads. It does not validate its disposition.

### Motorola contract

The M68040 User's Manual, sections 8.4.6.3-8.4.6.7, states that the exception
handler must complete pending write-backs and must process them in WB1, WB2,
WB3 order. WB2 and WB3 may themselves raise an access error. The frame is the
information from which software completes those writes; `rte` is not a
substitute for software completion.

The architecture does not define a Unix error policy for a permanently
unresolvable supervisor write. It does rule out calling that write completed.

### NetBSD contract

The common NetBSD implementation in the local
`netbsd/syssrc.tgz` member
`sys/arch/m68k/m68k/m68k_trap.c:178-411` separates kernel-data WBs with
`KDFAULT`:

- user WBs use fault-safe `ustore_*` helpers and return `SIGSEGV` on failure;
- kernel-data WBs use direct kernel stores.

An unresolved direct store therefore enters the ordinary kernel-fault
contract. A matching `pcb_onfault` recovery may consume it; without one, the
kernel fault is fatal. It is never converted into success merely because the
near fault was resolved.

The retained NetBSD/Amiga path makes the address-space choice explicit in
`arch/amiga/amiga/trap.c:429-439`: a supervisor-data WB3 uses `kernel_map`.
Failure goes to `nogo`; a kernel MMU fault with no matching onfault handler
panics rather than continuing with a lost store.

### Linux contract

Current Linux `arch/m68k/kernel/traps.c:238-275` also preserves failure:

- a failed WB is retained/reframed and passed to `send_fault_sig`;
- if an earlier user WB failed, a later WB3 carrying a kernel FC is still
  attempted (`!res || wb3s & 4`) instead of being silently discarded;
- in kernel mode, `send_fault_sig` uses an exception-table fixup when one
  exists and otherwise terminates the kernel path (`fault.c:24-56`).

Linux's later-kernel-WB exception is important. Strictly stopping every later
slot after a denied user WB can itself lose a pending kernel write. AMIX must
either complete such supervisor state before exposing a signal frame or keep
it in trusted kernel-owned state. It must not export supervisor authority to
a user-modifiable context and hope to replay it later unchanged.

### Required AMIX disposition

The numeric split is conservative but not a complete architectural decode.
For a normal 040 transfer, TM 1/2 are user data/code, TM 5/6 are supervisor
data/code, TM 0 is a data-cache push, TM 3/4 are MMU table-search data/code,
and TM 7 is reserved. Alternate-FC transfers use the same three bits under a
different TT interpretation. `WBS & 7` is therefore a transfer modifier, not
universally a logical function code. Push/table-search/alternate transfers
need their own policy rather than an ordinary `MOVES` replay.

For a normal TM 5/6 supervisor WB:

1. Resolve the exact WB address/range in the supervisor address space and
   retry completion.
2. If it still fails and a pre-existing outer `u_nofault` owner can be proven
   to own this exact access, transfer a failure to that owner's normal error
   contract.
3. Otherwise fail fast with the WB slot, FC, address, data, original frame PC,
   and outer-nofault value. Continuing after dropping the write is unsafe.

TM 3/4 table-search writes are also kernel-critical and must not be lost;
TM 0 push and TM 7 reserved state require special/fatal handling. Treating
every `TM >= 3` as one failure-class bucket is conservative, but issuing all
of them through `MOVES` as though TM were always DFC is not a complete replay
contract.

The immediate static verdict is therefore:

```text
current supervisor branch: REJECT
safe pilot policy:          resolve or fail fast
future recoverable policy:  typed outer-nofault propagation, only with an
                            explicit owner proof
```

## Q2: preserving WB state across a returning signal

### AMIX already preserves the raw hardware frame

The mounted AMIX header defines:

```c
typedef struct {
        gregset_t gregs;       /* 18 longs */
        fpregset_t fpregs;     /* 108 bytes */
        long mc_state[202];    /* internal state */
} mcontext_t;
```

The linked code gives `mc_state` a concrete machine-dependent layout:

| `ucontext_t` offset | Size | Producer / consumer | Meaning |
|---:|---:|---|---|
| `+36` | 72 | `prgetregs` / `prsetregs` | D0-D7, A0-A7, PC, PS |
| `+108` | 108 | `prgetfpregs` / `prsetfpregs` | Visible FP registers/control |
| `+216` | up to 92 | `prgetstate` / `prsetstate` | Complete CPU hardware exception frame |
| `+308` | 216 | `prgetfpstate` / `prsetfpstate` | Internal FPU state |

For CPU state, the chain is byte-concrete:

```text
signal delivery
  savecontext(uc)
    prgetstate(proc, uc + 216)
      format = live_uvpcb[70] >> 4
      len = framesz[format]
      bcopy(live_uvpcb + 64, uc + 216, len)
  sendsig copies 1024 bytes to the user signal frame
  sendsig sets USTKCLEAR (bit 7 at u+0x5c4)

signal return / setcontext
  setcontext copyin(user_uc, kernel_stack_uc, 1024)
  restorecontext(kernel_stack_uc)
    prsetstate(proc, kernel_stack_uc + 216)
      len = framesz[supplied_format]
      bcopy(supplied_frame, u.u_sigsave, len)
      set USTKRESTORE (bit 6 at u+0x5c4)
  stkrestore reconstructs that frame and executes rte
```

`framesz[7]` is `0x3c`, so all 60 bytes of the 68040 format-7 frame, including
WB1/WB2/WB3 status, address, and data, fit in this existing path. `sigsave`
is a relocated pointer to `u+0x1e4`.

Therefore item 8 does not need a new field merely to retain the original raw
write-back slots.

### Why raw preservation alone is not enough

Motorola requires software to complete the pending writes. Stock AMIX
`stkrestore` only reconstructs the frame and executes `rte`; it has no 040
write-back cleanup. Restoring valid WB bits to the hardware frame does not
cause the 68040 to perform them.

Linux solves this at sigreturn in `mangle_kernel_stack` by calling
`berr_040cleanup` after copying the long frame back into kernel memory and
before return. It also clears the supervisor bit from restored WB2/WB3 status
so a user cannot manufacture a privileged write through a signal frame.

AMIX needs the equivalent policy before `stkrestore` reaches `rte`.

### The restored frame is untrusted

The 1024-byte context is copied to user space and copied back. `restorecontext`
checks a `stampsum`, but this is an integrity checksum stored in the same user
object, not a kernel-secret authority boundary. `prsetstate` masks the
supervisor and interrupt-priority SR bits in the first frame long, but it does
not sanitize format-7 WB function codes, addresses, sizes, or valid bits.

Adding a cleanup without sanitization would create a new privilege bug: a
handler could submit a valid WB with supervisor FC and ask the kernel to
perform it.

A sigreturn cleanup must at minimum:

1. accept only a valid format-7/vector combination and valid WB sizes/types;
2. force deferred ordinary user WBs to user translation semantics (Linux
   clears TM2, preserving the data/code low bits);
3. reject CPU-space/reserved FCs and supervisor addresses supplied by user;
4. process WBs in order and preserve failure as a fault, not success;
5. clear each slot's V bit after successful completion;
6. leave a denied slot and all still-unprocessed later slots pending, or
   terminate the process if the ABI cannot safely retain them again.

Supervisor WBs should be completed or failed in kernel context before signal
delivery. They must not cross a user-controlled context boundary with their
privilege intact.

### Current replay creates a duplicate/partial-progress problem

`wb040_replay` currently does not clear WB valid bits after a successful
software replay. That was harmless when every path returned directly from the
original trap, because `rte` ignores the slots as work items. It is not
harmless if sigreturn later invokes another software cleanup: already
completed WB1/WB2 slots would be replayed again.

Each successful slot therefore needs its V bit cleared in the live frame.

There is a second complication. `Lwb_do` deliberately replays a word/long
byte by byte. A crossing store can complete one or more leading bytes before
a later byte is denied. The original single WB slot cannot represent every
possible remainder (for example, three remaining bytes of a long write).
Replaying the full slot after a handler repairs normal RAM is value-idempotent,
but it is not generally safe for device mappings or memory with write side
effects.

This leaves two honest implementation choices:

- **restricted raw-frame retry:** clear completed whole slots, retain the
  failed whole slot, and permit returning-handler retry only for ordinary
  RAM mappings where repeating identical leading bytes is allowed; reject
  device/side-effect mappings;
- **exact continuation record:** store byte-level progress plus the failed
  and later WBs in kernel-owned per-process state, then reconstruct only the
  remaining writes on signal return.

The existing `mc_state` path solves raw-frame lifetime but not this partial
progress contract. That is the narrower reason a new continuation record may
still be justified.

### Best hook point

The cleanest design point is after `setcontext` has copied the 1024-byte
context into kernel memory and validated its checksum, but before
`prsetstate` sets `USTKRESTORE`. A helper can sanitize and complete the
kernel copy without trusting user memory during replay.

This is not a one-call insertion today because `restorecontext` is `void` and
`setcontext` assumes it succeeded. A complete unit must define how a failed
sigreturn cleanup queues/returns the new fault while leaving
`USTKRESTORE` clear.

An assembly hook in `stkrestore` could operate on kernel-owned `u.u_sigsave`,
as Linux operates on its reconstructed kernel frame, but failure handling is
later and more re-entrant there. It is a viable fallback, not the preferred
first design.

## Q3: `Lwb_fail` stack ownership

### Proof for the intended `MOVES.B` fault

The current dispatcher has exactly three direct calls to `Lwb_do`:

| WB | `bsrw Lwb_do` | Normal return PC |
|---|---:|---:|
| WB1 | `0x000d9a24` | `0x000d9a28` (`Lwr_2`) |
| WB2 | `0x000d9a52` | `0x000d9a56` (`Lwr_3`) |
| WB3 | `0x000d9a6c` | `0x000d9a70` (`Lwr_ret`) |

A `BSR.W` pushes a four-byte return address. While the intended instruction
at `0x000d9ad2` (`moves.b %d1,%a3@+`) executes, the supervisor SP is:

```text
sp@(0) = return from Lwb_do to the next WB-dispatch point
sp@(4) = return from wb040_replay to its wrapper
```

The current `k_trap` path verifies the rest of the intended proof:

1. `0x0005a19e`: detect nonzero `u+0x374`.
2. `0x0005a1b8`: save the pad in `d3`.
3. `0x0005a1be`: clear `u_nofault` while resolving the nested fault.
4. `0x0005a206`: restore the pad.
5. `0x0005a20c-0x0005a216`: on nonzero resolver result, replace the saved
   frame PC at `fp+74` with that pad.
6. `ktraps` sees the nonzero result and branches to `stkclear`.
7. `stkclear`, using `framesz[7] == 60`, collapses the long frame and performs
   `rte`; the CPU resumes at `Lwb_fail` with the pre-`MOVES` SP and register
   image.

For that exact path, `d2` still contains the saved outer nofault value,
`addql #4,%sp` drops precisely the `Lwb_do` return, and `rts` returns directly
to the wrapper. The arithmetic is correct.

### Why the proof is not universal

`u_nofault` is one scalar pointer in the current process's u-area. `k_trap`
checks only whether it is nonzero. It does not verify:

- that the faulting PC is `0x000d9ad2`;
- that SP equals the `Lwb_do` call-stack value;
- that an owner/cookie identifies the active replay;
- that trap-time `d2` is the saved outer nofault value.

`Lwb_do` does not mask interrupts while the pad is armed. An interrupt can
therefore run in the window. If an interrupt handler or another nested kernel
path takes an unresolved memory fault, it observes the same `u_nofault` and
`k_trap` can redirect it to `Lwb_fail`.

In that case the `rte` stack is the unrelated faulting code's pre-fault
stack, and `d2` is that code's trap-time `d2`. `Lwb_fail` would first write an
unrelated value back to `u+0x374`, then drop an unrelated long from the stack
and `rts` through whatever follows it. This is fail-open stack corruption,
not a controlled replay abort.

The fact that `k_trap` clears `u_nofault` while calling the resolver does
reduce recursion: faults inside that resolver cannot reuse `Lwb_fail`. It
does not protect the periods before the first `MOVES`, between retried bytes,
or after pad restoration and before the retry completes.

No measured alien landing is claimed. The narrower finding is decisive:
the static code does not establish the universal SP guarantee required by
the comment and by `addql #4,%sp`.

### Required guard

A safe implementation should make landing-pad ownership explicit:

1. record an active cookie plus expected pre-fault SP in per-process/u-area
   state before arming the pad;
2. optionally require the fault PC to equal the single `MOVES.B` site;
3. at `Lwb_fail`, compare the actual SP/cookie before restoring `d2` or
   performing stack surgery;
4. on mismatch, fail fast with diagnostics rather than modify an unknown
   stack;
5. clear the owner state before logging or invoking code that can fault.

Narrowing the armed interval to one byte attempt reduces exposure but does
not replace the owner check. Raising IPL around a store that may enter VM
resolution and sleep is not a valid substitute.

A cleaner later refactor is a one-byte fault-safe leaf helper whose nofault
landing returns an error through its ordinary single call boundary. The
dispatcher can then stop normally instead of having the landing pad skip two
logical levels with `addql + rts`.

## Recommended implementation order

1. Change an unresolved supervisor/table-search/push WB from silent success to
   resolve-or-fail-fast. This is the smallest correctness closure and does
   not depend on signal ABI work.
2. Add the landing-pad owner/SP/PC assertion before relying on stack surgery
   on real silicon. A mismatch should be fatal and diagnostic.
3. For returning-handler support, first clear completed WB valid bits and
   decide the byte-partial retry policy.
4. Add a sanitized sigreturn cleanup using the existing
   `mc_state -> u.u_sigsave -> stkrestore` channel. Never replay supervisor
   authority supplied through user context.

## Final answers for Claude

1. **Supervisor denial:** stopping the ordered replay is correct, but
   returning success is not. NetBSD's safe precedent is outer-onfault or
   panic; Linux also refuses to silently lose kernel WBs and even attempts a
   later kernel WB after an earlier user failure. For AMIX now: resolve or
   fail fast, with typed nofault recovery only after its owner can be proven.
2. **Signal return:** AMIX already stores the full format-7 frame in
   `ucontext.uc_mcontext.mc_state` and stages it at `u+0x1e4`. Add a trusted,
   FC-sanitizing cleanup before `stkrestore`; raw storage is not the missing
   piece. Completed-slot clearing and byte-partial progress are the remaining
   semantic design issues.
3. **Stack surgery:** `addql #4,%sp; rts` is byte-correct for a fault at
   `Lwb_loop` and the linked `k_trap/stkclear` path. It is not guaranteed for
   every fault that can observe the scalar pad. Add an owner/cookie and
   expected-SP/PC check, or refactor to a conventional fault-safe helper.

## Sources

- Motorola/Freescale, `M68040 User's Manual`, sections 8.4.6.3-8.4.6.7:
  <https://www.nxp.com/docs/en/reference-manual/MC68040UM.pdf>
- Linux m68k, `arch/m68k/kernel/traps.c`, `do_040writebacks` and
  `berr_040cleanup`:
  <https://github.com/torvalds/linux/blob/master/arch/m68k/kernel/traps.c>
- Linux m68k, kernel/user fault disposition in `arch/m68k/mm/fault.c`:
  <https://github.com/torvalds/linux/blob/master/arch/m68k/mm/fault.c>
- Linux m68k, format-7 restoration and cleanup in
  `arch/m68k/kernel/signal.c`:
  <https://github.com/torvalds/linux/blob/master/arch/m68k/kernel/signal.c>
- local NetBSD source bundle:
  `netbsd/syssrc.tgz`, `sys/arch/m68k/m68k/m68k_trap.c`,
  `sys/arch/amiga/amiga/trap.c`, and `sys/arch/hp300/hp300/trap.c`;
- mounted AMIX headers:
  `vanilla/usr/include/sys/ucontext.h` and `sys/regset.h`;
- AMIX source-corresponding trap return:
  `amix-src/sys/amiga/ml/ttrap.s:146-272`;
- pinned linked image disassembly for `savecontext`, `restorecontext`,
  `sendsig`, `prgetstate`, `prsetstate`, `k_trap`, `ktraps`, `stkclear`, and
  `stkrestore`;
- current port implementation: `prototypes/wb040.s`.
