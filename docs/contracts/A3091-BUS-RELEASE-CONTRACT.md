# A3091 WD33C93A Bus-Release Contract

> **PARTIALLY SUPERSEDED 2026-08-29.** This contract's acceptance test — `CIP`, `BSY`, `LCI`
> and `INT` clear after `COM=0x04` — was implemented exactly and **passed on silicon while
> leaving the SCSI bus unusable**, so the next command died. `AS.BSY` proves the WD's internal
> command ended, not that the bus was released. See
> [`A3091-BUS-FREE-FOLLOWUP-AUDIT.md`](A3091-BUS-FREE-FOLLOWUP-AUDIT.md) and
> `docs/REALHW-ISSUE54-FIX-260829-09.md`. The `0x49` handling in this document stands; its
> proof-of-release does not.

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/A3091-BUS-RELEASE-CONTRACT.md` (private workspace, imported
> 2026-08-29). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** Answers `private/A3091-BUS-RELEASE-CODEX-TASK.md`. Nothing
> is implemented yet. It **corrects this line's own reading** in
> `docs/ISSUE54-BUS-RELEASE-MY-READING-260829.md` on two points — Abort is unnecessary and
> hazardous here, and a host-issued Disconnect raises no completion interrupt — and confirms and
> extends its third, that ending at `istate = IDLE; startany()` is unsafe regardless of queue
> occupancy.

This document answers
`private/A3091-BUS-RELEASE-CODEX-TASK.md` from the port repository. It
specifies how the reproducible ISSUE-54 `MIS_1|DATA_IN` failure can release
the SCSI bus before reporting the request failed, whether the stock DFA can
survive a disconnect event after software enters `IDLE`, and how all hardware
waits must be bounded.

The result is a static specification, not a kernel change or runtime
acceptance result.

## Pinned inputs

| Input | Identity |
|---|---|
| Stock kernel SHA-256 | `not used: no address or byte claim was taken from stand/unix` |
| AMIX object SHA-256 | A3091 `3ea9e3dd37725c3d1717b85683ecf9974f99f00596cccdaec70cc282ec2f5a8a`; A2091 `30fc152c52c504092288f6bbeb3554b944750ad3c59459cbba64e31e302930f5a8` |
| Port commit | `5291aba500b85636fea0f96869f3e62e95fcbda9` |
| Port image SHA-256 | `build/unix-040` `ba1160c44a557591124af04618eb30433c0dd3e40207b7b77a4c8f0a0a488795`; debug comparison image `2adf32096b04c83a07c88ff373a8af2e2d9fb66c823b00a536b657e5cbbf7394` |
| Reference source identity | AMIX `sys/amiga/alien/a3091.c` SHA-256 `145a313b20364d1acd32cff2d15ccfe13f87c0eade5ff3246b2d031e1a4df53a`, `a2091.c` `c7f2bdd40a072da84807abdad7fbcbf81a8f953ed352b8a325a1c336d19cbe7d`, and `sys/amiga/kernel/support.c` `cbbaf343f7878a0a113233f837079efc9e76f151ceb97e0b90020dccefa71a5a` from `vanilla/amix-sources.tar`; Western Digital WD33C93A data sheet WD2088S 9/88 PDF SHA-256 `0fa1ca954dd9f7efa9c9c9e8946aa95ac7f99ce8272d15bbffdf4e38b9e65566`; NetBSD 10.1 `sys/arch/amiga/dev/sbic.c` `1cf7ae87ed9c7d90ca753529c504b54e2ce22c1e9b3ebc7652ee52332bf0e6d8` and `sbicreg.h` `a6d52acd2e1eebcff4a8dffe86e895192df4211b1c8a5c32e83875870299764d` |
| Address domains | Linked port-image ELF section-relative symbol values; AMIX source line numbers; WD33C93A register values; reported runtime VAs only where explicitly labelled |
| Evidence commands | `sha256sum`; `tar -xOf`; `nl -ba`; `m68k-linux-gnu-readelf -sW/-rW`; `m68k-linux-gnu-objdump -dr/-s`; `pdftotext -layout`; manual control-flow and register-contract comparison |

### Additional provenance

| Item | Identity |
|---|---|
| Task brief | SHA-256 `67184727c5ae801ebf6b39fcb30bdf973335be7c9cb702b82b08bf513ea3403d` |
| Existing DFA contract | `docs/contracts/A3091-PHASE-MISMATCH-DFA-CONTRACT.md`, SHA-256 `454647a8c8e541a86daa05fdb7ccd2012db830ac70312725aa00b08d2d33c6f5` |
| Reported hardware capture | `docs/REALHW-ISSUE54-CLASSIFY-260829-07.md`, SHA-256 `f6068d970aa982e7ac0578bb3f4ac1c0fd8ab901257bc45e13bf4d90e2e74bd6` |
| Current classifier source | `src/a3091dbg040.s`, SHA-256 `c6ca1a7694548f4096682d8fd8803f803662f2d48d05e5ecb92030ab93eac383` |
| Manufacturer document | [Western Digital WD33C93A data sheet](https://bitsavers.trailing-edge.com/components/westernDigital/_dataSheets/WD33C93A.pdf), sections 6.2.1, 6.2.19, 6.2.20, 7.2, 7.4.2, 7.4.3, 7.5.5, and 9.2.16 |

The runtime lines quoted by the task are reported runtime evidence from the
named report. They were not reproduced during this static analysis.

## Executive verdict

1. **`Disconnect` (`COM=0x04`) is the command that releases a connected
   initiator.** It releases the SCSI bus signals and transitions the WD to the
   disconnected state. `Abort` (`COM=0x01`) is not the release operation: in
   the connected-initiator case it terminates an active transfer but leaves
   the WD connected for a possible resume.
2. **The measured tuple does not require `Abort`.** `SS=0x49` has already
   terminated the Level II combination command; `CP=0x46`, `TC=0`, and
   `AS=0` show no remaining command, transfer count, WD data request, or
   pending interrupt. After the external SDMAC is quiesced, a guarded direct
   `Disconnect` is the minimum operation. NetBSD's `Abort`-then-`Disconnect`
   sequence is a generic unknown-state recovery routine, not the minimum
   contract for this classified state.
3. **A host-issued `Disconnect` does not produce a completion interrupt.** It
   is a Level I command, and the manufacturer says Level I commands other than
   Abort and Reset do not interrupt on completion. The Transfer Info section
   says the same specifically for Disconnect. Waiting for a new `0x85` after
   issuing `0x04` can therefore hang by construction.
4. **The observed `0x85` is nevertheless load-bearing evidence.** It is the
   target's independent bus-free event, not proof that the host Disconnect
   command interrupts. Any such event already pending or racing with the
   command must be consumed while the failed request still owns a cleanup
   state. It must not be allowed to arrive after `istate=IDLE; startany()`.
5. **Neither an empty nor a non-empty start queue makes the stock action-5
   ending safe.** With an empty queue, `0x85` reaches `IDLE` and drives the DFA
   to `DEAD`. With queued work, `startany()` can move to `STARTING`, after
   which the stale `0x85` invokes action 7 against the newly started request.
   That can stop the wrong DMA and strand the new request as if its target had
   disconnected.
6. **Use an explicit two-part time contract.** Wait at least 7 microseconds
   after the `SS` read before writing `COM`, then allow at most about 2 ms for
   command acceptance and `CIP` clearance. The linked raster-based
   `delayus(8)` is a conservative building block; 16 such bounded checks are
   about 32 scan lines. Expiry is fail-closed: do not enter `IDLE`, do not call
   the request callback, and do not start another request.
7. **The WD bus-release primitive can be shared, but the whole failure path
   cannot yet cover `0x48`, `0x49`, and `0x4a` as one implementation unit.**
   Data-in, data-out, and command-phase mismatches have different FIFO and DMA
   ownership consequences. Only the measured data-in/count-exhausted tuple is
   ready for the narrow fast path specified here.

## Q1: what releases the bus?

### The two commands have different postconditions

The WD33C93A defines these Level I commands:

| Command | Value | Connected-initiator postcondition | Completion interrupt |
|---|---:|---|---|
| Abort | `0x01` | active command stops; WD remains connected and resumable | yes |
| Disconnect | `0x04` | bus signals released; WD becomes disconnected | no |
| Reset | `0x00` | WD is reset and disconnected; configuration/state is destroyed | yes |

Abort has an additional direction-sensitive FIFO contract. During an
initiator receive, the host must continue servicing WD data requests until the
Abort interrupt so that incoming FIFO data reaches its destination. Thus
`stopdma(); Abort` is not a generally valid replacement for a release helper.
Reset is a recovery escalation, not a local release primitive: continuing
after it requires controller reinitialization and queue reconciliation that
the current AMIX driver does not provide.

Disconnect is valid while connected as an initiator. If a Level II command is
still active, it terminates that command as part of the disconnect. In the
measured event the Level II command has already terminated, so Disconnect has
only the bus-release job left.

### Command-register guards

The relevant Auxiliary Status bits are:

| Bit | Mask | Meaning for this path |
|---|---:|---|
| `INT` | `0x80` | read `SS` before issuing any command |
| `LCI` | `0x40` | the last command lost a race with an interrupt and was ignored |
| `BSY` | `0x20` | a Level II command is active |
| `CIP` | `0x10` | the command register is unavailable |
| `DBR` | `0x01` | a WD FIFO byte requires direction-correct service |

The manufacturer imposes three command-write rules:

- read `SS` to clear a pending `INT` before issuing another command;
- do not write `COM` while `INT` or `CIP` is set; and
- leave at least 7 microseconds between the last `SS` read and the `COM`
  write, or the command can be ignored and `LCI` set.

The reported classifier saw `AS=0`, so the exact captured event satisfies the
register-state half of this contract. A future implementation must still
recheck it immediately before writing `COM`, because the target can disconnect
during the cleanup delay.

`DR` (`0x19`) is not accessed on this fast path because `DBR=0`. If `DBR`
appears, the handler has left the classified state: reads and writes of `DR`
have opposite FIFO meanings, and the Abort contract is direction sensitive.
A blind read-then-write probe such as a generic recovery driver uses is not an
acceptable first behavior change in the AMIX disk path.

### Minimum sequence for the measured tuple

This sequence is intentionally limited to:

```text
ss = 0x49, cp = 0x46, tc = 0,
request direction = DATA_IN, AS initially has INT/CIP/BSY/DBR/LCI clear
```

1. Keep the software state at `STARTING` or a new internal cleanup state. Do
   not publish `IDLE` yet.
2. Call the current `dma_a3091_stopdma`, not the retired stock entry. The
   reported SDMAC cursor is 16 bytes short because data is still in the SDMAC
   FIFO; this step flushes it to RAM and completes the port's FROM_DEVICE
   cache-ownership contract before the request callback can run. Its inherited
   stock body still has a separate unbounded SDMAC-FIFO wait; the WD bound in
   this document does not silently claim to close that older behavior.
3. Enforce the WD command guard with `delayus(8)`. In this AMIX source the
   helper waits on raster-line transitions; for an argument below one line it
   still waits two lines, so this is intentionally much longer than 7
   microseconds and independent of 040/060 instruction speed.
4. Read `AS` once more.
   - If `INT` is set, read `SS` immediately. `0x41` or `0x85` proves that the
     target has already made the bus free; skip the host Disconnect command.
     Any other status leaves this narrow path and fails closed.
   - If `CIP`, `BSY`, `DBR`, or `LCI` is set without an accepted bus-free
     status, the classified preconditions no longer hold. Do not guess a FIFO
     direction or issue a command through a pending interrupt.
5. Write `COM=0x04`.
6. Run the bounded post-command check described below. Success is either:
   - a synchronously consumed `0x41`/`0x85` race proving the target already
     disconnected; or
   - `CIP=0`, `LCI=0`, `INT=0`, and `BSY=0` after a valid Disconnect write.
     There is no completion interrupt to await; successful command acceptance
     plus the manufacturer's immediate-disconnect postcondition is the proof.
7. Only after hardware release is established, execute action-5-equivalent
   software completion: retain `cp->okay == FALSE`, remove the request, invoke
   its callback, set `IDLE`, and then call `startany()`.

`0x40` (invalid command) is not success. NetBSD uses it as a loop terminator in
its generic abort routine, but its own following comment admits that routine
does not establish the result. Here it means the assumed connected state or
command sequencing was wrong and must take the fail-closed path.

### Why NetBSD is not copied literally

NetBSD's `sbicabort()` is useful comparative evidence. It drains an unknown
DBR direction, issues Abort, checks `BSY|LCI`, then issues Disconnect. It is
appropriate to a driver-wide recovery entry that does not begin with this
project's measured `CP/TC/AS` tuple.

It is not a safe AMIX implementation template as written:

- its waits include unbounded `WAIT_CIP` loops and a default one-second
  interrupt wait;
- it waits for status after Disconnect even though the manufacturer says the
  command itself does not interrupt; and
- its selected-state flag is cleared without a positive final proof beyond
  the status loop.

The manufacturer contract wins where this maintained driver and the data
sheet differ. The useful lesson from NetBSD is the distinction between a
generic unknown-state abort and a classified direct-disconnect path, not its
spin-loop policy.

## Q2: can `IDLE` survive the resulting event?

### The host command and the observed event must not be conflated

`COM=0x04` has no own completion interrupt. The reported second line,
`SS=0x85` while `istate=DEAD`, is a service event generated when the target
disconnected on its own. The captured `CON=0x8c` includes the driver's `IDI`
policy, which asks the WD to interrupt when a target disconnects; it does not
turn a host-issued Level I Disconnect into an interrupting command. The WD
data sheet defines both relevant bus-free statuses as transitions to the
disconnected state:

| Status | Meaning | New WD state |
|---:|---|---|
| `0x41` | unexpected target bus free terminated a command | disconnected |
| `0x85` | disconnect service event | disconnected |

Both can be accepted as proof that the release is already complete when they
are consumed inside the cleanup helper. Neither may be replayed later through
the stock DFA as if it belonged to a new command.

### Empty queue

The pinned image has `itab[0x85]=3` and `atab[IDLE][3]=1`. If action 5 sets
`IDLE` and `startany()` finds no work, a delayed `0x85` dispatches to
`badhardware()` and the driver enters the absorbing `DEAD` state. This is not
survivable.

### Non-empty queue

A non-empty queue does not repair the contract. `startany()` removes a unit
from the start queue, arms its DMA, sets `STARTING`, and issues the combination
command. If the old target's delayed `0x85` arrives then,
`atab[STARTING][3]=7`:

- action 7 stops the DMA belonging to the newly current request;
- it treats that request as temporarily disconnected even though the event
  belonged to the old target; and
- it returns to `IDLE/startany` without completing or correctly requeueing the
  new request.

The result may look less immediately fatal than the empty-queue case, but its
event ownership is wrong and it can strand or corrupt unrelated I/O. The
answer therefore does not depend on queue occupancy in any useful sense:
**both outcomes are invalid, in different ways.**

### Required ordering invariant

```text
acknowledge mismatch
    -> quiesce its SDMAC/cache ownership
    -> consume any already-pending target bus-free event
    -> issue and verify Disconnect if still connected
    -> prove no release event remains pending
    -> complete the failed request
    -> publish IDLE
    -> start another request
```

Do not expose `IDLE`, invoke the request callback, or let `startany()` alter
`curunitp` before the release event is owned and drained. An interrupt arriving
during the handler can remain pending at the same IPL; it must be detected
synchronously through `AS.INT` before returning to the stock interrupt path.

### Integration consequence

Returning `IDLE` from `a3091_badhardware_dbg` is insufficient. Its caller only
stores the return value to `istate`; it does not run action 5. A complete
handled branch must perform both the hardware cleanup and the action-5
software body, then return the actual final state after `startany()` (either
`IDLE` or `STARTING`). The existing relocation at linked `.text+0xd3a6` is a
narrow interposition point, but the implementation unit needs callable aliases
or equivalent code for the local queue/start helpers as well as the WD
register accesses.

## Q3: bounded wait

### Recommended bound

Use two explicit limits:

| Stage | Bound | Reason |
|---|---|---|
| after the acknowledged `SS` read, before `COM` | at least one `delayus(8)` | satisfies the manufacturer's 7 microsecond command guard with a raster-based margin |
| after `COM=0x04` | at most 16 checks separated by `delayus(8)` | about 32 video scan lines, roughly 2 ms on PAL or NTSC timing |

The WD's electrical connected-initiator-to-bus-free timing is on the order of
one microsecond at the slow end of its clock range, and Disconnect does not
wait for a target response. A roughly 2 ms software budget is therefore
already orders of magnitude more conservative than the hardware operation.
It is small enough that a broken controller does not turn an interrupt handler
into the old unbounded `cipwait()` wedge.

The linked image provides two tempting delay helpers:

- `delayus` at linked `.text+0x192f6` follows the AMIX source implementation
  at `support.c:348-359` and measures raster transitions;
- `drv_usecwait` at linked `.text+0x53268` implements a fixed
  `argument << 5` instruction loop with no visible 040/060 calibration.

Use `delayus` for this contract. Its sub-scanline precision is poor but its
minimum and total bounds do not shrink when the CPU changes from 040 to 060.
The first implementation should count the number of post-command checks and
record the observed high-water mark; normal hardware should usually need no
meaningful polling after the conservative pre-command delay.

### What each check does

Each post-command iteration reads `AS` and applies this order:

1. If `INT` is set, read `SS` and classify it. Accept only a status that proves
   bus free (`0x41` or `0x85`) in this narrow handler.
2. If `LCI` is set without accepted bus-free status, the Disconnect was
   ignored. Fail closed.
3. If `CIP` is clear, require `BSY` and `DBR` clear. With no pending interrupt,
   this is successful completion under the no-interrupt Disconnect contract.
4. Otherwise delay once and retry until the fixed count is exhausted.

The code must never poll `SS` directly. `SS` is read only when `AS.INT` says a
new interrupt is pending; otherwise it is stale status from a prior event.

### Expiry policy

On expiry:

- latch and print at least `AS`, `CP`, `TC`, SDMAC `ISTR/CNTR/SAC`, request
  identity, direction, and cleanup-loop count;
- leave the request marked failed but **do not call its callback yet**;
- do not publish `IDLE` and do not call `startany()`; and
- enter the existing fail-stop state unless a separate, reviewed controller
  reset-and-requeue contract has been implemented.

A bare `COM=Reset` followed by normal queue processing is not an acceptable
timeout fallback. Reset releases the bus, but it also resets controller state;
without reinitialization and ownership reconciliation it converts an obvious
wedge into silent I/O misassociation.

## Scope across the three phase mismatches

The chip-level command-write and pending-event rules apply to all three
statuses, but their surrounding DMA cleanup does not yet form one safe unit:

| Status | Phase | What prevents immediate inclusion |
|---:|---|---|
| `0x49` | DATA_IN | the measured `CP=0x46, TC=0, AS=0` fast path is specified; SDMAC must flush the final receive FIFO bytes to RAM |
| `0x48` | DATA_OUT | flushing or discarding pending outbound SDMAC/WD FIFO data has different media-corruption consequences; no runtime tuple exists |
| `0x4a` | COMMAND | CDB progress and WD internal FIFO ownership differ from host data DMA; no runtime tuple exists |

Direct Disconnect is still the bus-release primitive for a connected WD, but
the pre-release quiesce operation is direction and phase specific. The first
implementation should handle only the exact `0x49/0x46/0/AS=0` tuple and keep
`0x48` and `0x4a` on the existing loud fail-stop path. A2091 has the same WD
tables and inherits the chip contract, but it has per-card state and a
different DMA/bounce-buffer teardown; it is a separate implementation and
acceptance unit.

## Minimum implementation unit

For A3091, the minimum safe behavior change is not a table byte. It is one
atomic handled branch that:

1. recognizes the exact measured tuple and validates request direction;
2. quiesces SDMAC through the current cache-aware stop wrapper;
3. performs the guarded, timed Disconnect sequence;
4. consumes a racing `0x41`/`0x85` before changing request ownership;
5. executes action-5-equivalent failed completion; and
6. returns the state left by `startany()` without falling through to the stock
   `badhardware()` body.

All other tuples continue to the current classifier and stock fail-stop. This
keeps an unsupported device from killing unrelated disks without pretending
that general block-size support has been added. The CD-ROM and tape remain
unusable until their geometry and command semantics are implemented; their
requests merely fail locally instead of wedging the controller.

## Acceptance criteria

Static acceptance:

- every `COM` write is preceded by an explicit 7 microsecond guard and an
  `INT|CIP` check;
- no path waits for a Disconnect completion interrupt;
- every newly added WD cleanup loop is bounded, and the existing unbounded
  SDMAC flush wait remains visible rather than being attributed to this bound;
- action-5-equivalent completion cannot run before bus release is established;
- the handled branch calls `dma_a3091_stopdma`, preserving the installed cache
  ownership contract; and
- `0x48`, `0x4a`, A2091, and reset recovery remain explicit non-goals.

Runtime acceptance on the exact affected hardware:

1. Run the target-3 512-byte read repeatedly. Every request must fail to the
   caller; none may report data success.
2. Prove the controller remains usable by reading known data from the root
   disk after every failed request, with both an otherwise empty queue and a
   deliberately non-empty queue.
3. Exercise both race outcomes: host Disconnect wins with no WD interrupt,
   and target bus-free wins with a consumed `0x41` or `0x85`.
4. Require cleanup-entry count = failed-request count, cleanup-success count =
   failed-request count, timeout/LCI/unexpected-status counts = 0, and a
   nonzero denominator for both queue-occupancy classes.
5. Record the loop high-water mark; any value near the bound is a failure to
   investigate, not a reason to increase the bound.
6. Run the normal disk/copyback battery afterwards and verify all existing DMA
   prepare/complete invariants remain balanced.

The reported spontaneous `0x85` proves only one race arm today. Hardware
acceptance needs an instrument that distinguishes target-already-free from
host-Disconnect-with-no-interrupt; otherwise a clean run can still leave the
manufacturer-defined no-interrupt path unexercised.

## Confidence and residual risk

**High confidence:** command meanings, command-register guards, Disconnect's
no-interrupt completion, the current DFA cells, the empty/non-empty queue
failure modes, linked helper addresses, and the exact reported tuple.

**Moderate confidence:** the approximately 2 ms engineering bound. It is far
above the manufacturer hardware timing and uses a CPU-independent local delay,
but its normal iteration distribution has not yet been measured on the A3091.

**Open:** behavior of `0x48`, `0x4a`, original non-A WD33C93 revisions, A2091
DMA/bounce teardown, and a recoverable full-controller reset after cleanup
timeout. The stock SDMAC `fdma` completion wait used inside
`dma_a3091_stopdma` is also still unbounded and deserves a separate cap if the
goal is that no anomalous hardware path can spin forever. None of these open
items changes which WD command releases the measured connection.
