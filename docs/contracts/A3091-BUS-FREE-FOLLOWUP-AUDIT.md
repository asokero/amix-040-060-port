# A3091 post-Disconnect bus-free and event-ownership audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/A3091-BUS-FREE-FOLLOWUP-AUDIT.md` (private workspace, imported 2026-08-30).
> This copy is the implementation-facing reference used by `src/`.

This document answers `private/A3091-BUS-FREE-CODEX-TASK.md` from the port
repository. It reviews the hardware result from build `68060-260829-09`,
corrects the acceptance boundary in `A3091-BUS-RELEASE-CONTRACT.md`, and
specifies what must be established before the failed CD request may give the
A3091 controller to another request.

The result is a static contract and a measurement plan. It is not a kernel
change or a hardware acceptance result.

> **Hardware follow-up correction (builds `68060-260829-11` and
> `68060-260829-15`).** The discriminator later captured
> `SS=0x41, CP=0x3a, TC=0x800`: target 6 had been selected and had accepted
> CDB bytes, so the event did terminate the newly started root-disk command.
> The attribution uncertainty in Executive verdict item 3 and Q1 is closed.
> The ATN experiment then reached `SS=0x89` (`DATA IN`) immediately rather
> than Message Out. Finally, Western Digital application notes E062-B and
> E025-A explicitly delete both Transfer Pad and initiator-mode WD Abort from
> the WD33C93A. Consequently the direct Message Out sequence below is not a
> complete implementation plan, and `XFER_PAD` must not be substituted for
> its missing intermediate data service. Preserve this document's ownership,
> physical-bus-free, and publish-`IDLE`-last rules, but use
> `A3091-DATA-IN-DRAIN-DESIGN.md` for the current recovery design and its
> falsification gates.

> **Correction to the earlier contract.** `COM=0x04` acceptance plus clear
> WD33C93A `AS.CIP/BSY/LCI/INT/DBR` does **not** prove that the physical SCSI
> bus is free. It proves that the WD accepted the command, ended its own Level
> II activity, and released the signals driven by the initiator. A target may
> still own the bus by asserting SCSI `BSY`. The previous document's direct
> release sequence and approximately 2 ms success criterion are superseded by
> this audit. Its DMA-quiesce, 7 microsecond command guard, fail-before-reuse,
> and publish-`IDLE`-last findings remain valid.

## Pinned inputs

| Input | Identity |
|---|---|
| Stock kernel SHA-256 | `not used: this follow-up inspects the current linked port image and AMIX-shipped driver source` |
| AMIX object SHA-256 | `not used: no byte-identity claim is made against an AMIX exp object` |
| Port commit | `1d9ffb23fc94e494662433cc74cb9334da0acb02` (`main` eight commits ahead of `origin/main` when inspected) |
| Port image SHA-256 | `build/unix-040` `485301b935f911e5151111a1cf96399bfe800760dde0cf49b5cc8e7c4ecb852b`; `build/unix-040-dbg` `2adf32096b04c83a07c88ff373a8af2e2d9fb66c823b00a536b657e5cbbf7394`; `build/a3091dbg040.o` `512fae1f367f309989ff5958f17b9dec9a52d38324939cf8fa3564e96915412a` |
| Reference source identity | AMIX `sys/amiga/alien/a3091.c` SHA-256 `145a313b20364d1acd32cff2d15ccfe13f87c0eade5ff3246b2d031e1a4df53a` and `a2091.c` `c7f2bdd40a072da84807abdad7fbcbf81a8f953ed352b8a325a1c336d19cbe7d` from `vanilla/amix-sources.tar` SHA-256 `fbfa00f445cedcda6b3ae4a8679de592e60ced7fa51c43ebcec3cbe943c2ff5b`; Western Digital WD33C93A data sheet WD2088S 9/88 PDF SHA-256 `0fa1ca954dd9f7efa9c9c9e8946aa95ac7f99ce8272d15bbffdf4e38b9e65566`; ANSI X3.131-1986 SCSI PDF SHA-256 `238424c04b8542f6d93de63f19661efa3144be68c50dee60c61ffb039e54cb75`; NetBSD `sys/dev/ic/wd33c93.c` at commit `d27af545f7ad03d8344118917abe3036781d3192`, downloaded file SHA-256 `0b875798631bdb69329092cf113d58fbd39a50b035383a4ccca22c0be0899e4e` |
| Address domains | Linked port-image ELF section-relative symbol values; source line numbers; WD/SCSI register, command, phase, and message values; runtime values only where explicitly labelled as reported evidence |
| Evidence commands | GNU binutils 2.44 `nm`, `readelf`, and `m68k-linux-gnu-objdump`; `sha256sum`; `tar -xOf`; `nl -ba`; `pdftotext -layout`; manual state-machine and protocol comparison |

### Additional provenance

| Item | Identity |
|---|---|
| Task brief | SHA-256 `a41256b82ab334ea1294e170beb5b72df39a89fd467cd88f582aaf341f2d0c26` |
| Reported hardware result | `docs/REALHW-ISSUE54-FIX-260829-09.md`, SHA-256 `a06ee5b6c81a8b0b76904b82eb99a0b9f0dc80ed9e35d52cd345a59fcffad19a` |
| Superseded implementation contract | `docs/contracts/A3091-BUS-RELEASE-CONTRACT.md`, SHA-256 `e4182ab371e52a26f8f1ef97b5a96f088331ba23960035b5e659df026f4b39a9` |
| Current override source | `src/a3091dbg040.s`, SHA-256 `aec6b278cef3bf8ab52c431190418e8a786c21adcd7faffe1d908ad930d3bc98` |
| Independently recorded peer reading | `docs/ISSUE54-NEXT-COMMAND-MY-READING-260829.md`, SHA-256 `2672a7e97492ab4fe2750371446b837b921db019862462b3aae46bd350f519a8` |
| Manufacturer document | [Western Digital WD33C93A data sheet](https://bitsavers.trailing-edge.com/components/westernDigital/_dataSheets/WD33C93A.pdf), sections 6.2.1, 6.2.19, 6.2.20, 7.4.2 through 7.4.5, and 7.5.5 |
| Protocol standard | [ANSI X3.131-1986 SCSI](https://www.govinfo.gov/content/pkg/GOVPUB-C13-b974db668ca7572fe23cab4c248ef62b/pdf/GOVPUB-C13-b974db668ca7572fe23cab4c248ef62b.pdf), section 5.5.2, especially the `ABORT` message |
| Comparative implementation | [NetBSD `wd33c93.c`](https://github.com/NetBSD/src/blob/d27af545f7ad03d8344118917abe3036781d3192/sys/dev/ic/wd33c93.c), especially `wd33c93_abort`, `wd33c93_sched_msgout`, `wd33c93_msgout`, and `wd33c93_nextstate` |

The hardware transcript is reported runtime evidence. It was not reproduced
during this static analysis.

## Executive verdict

1. **The old success predicate was wrong.** WD `AS.BSY` means a Level II WD
   command is executing. It is not the physical SCSI `BSY` signal. Clear
   `AS` after `COM=0x04` therefore proves controller-command acceptance, not
   target release.
2. **`SS=0x41` is real bus-free evidence, but not a normal temporary
   disconnect.** It means an unexpected target bus free terminated the active
   WD command and left the WD disconnected. Selection timeout is `0x42`.
   Protocol-correct temporary disconnect is `0x85` after the target's
   Disconnect-message sequence.
3. **The reported `0x41` cannot yet be attributed to target 6.** `curunitp`,
   `DI`, the armed root DMA segment, and `STARTING` identify the software
   command installed before `COM=0x09`; they do not prove that target 6 was
   selected. `CP` is the missing discriminator. `CP=0` means the new selection
   did not complete and strongly identifies the event as the old target's late
   release. `CP>=0x10` means the new target was selected; the exact value says
   how far that command progressed before bus free.
4. **Do not reclassify every `0x41` as `0x85`.** AMIX action 7 leaves the
   request at `comhead` awaiting a reselection. A command ended by unexpected
   bus free has no promise of reselection. Blindly taking action 7 can strand
   the root request silently.
5. **Waiting longer for clear `AS` cannot fix this.** There is no remaining
   physical-bus signal in `AS` to wait for, and neither the WD register map nor
   the A3091 SDMAC status exposes the cable's `BSY` line directly. The driver
   can positively observe bus free through a pending interrupt followed by
   `SS=0x41` or `0x85`; normal target disconnect additionally advances `CP`
   through `0x42` to `0x43`.
6. **The protocol-correct local recovery needs Message Out.** While the WD is
   still connected to the offending target, assert ATN, send the SCSI `ABORT`
   message byte `0x06`, and retain cleanup ownership until the target's
   bus-free status is consumed. WD command `ABORT` (`COM=0x01`) and SCSI
   message `ABORT` (`0x06`) are different operations; only the latter tells
   the target to clear the operation and go bus free.
7. **Do not globally change `startcom=0x09`.** Initial selection without ATN
   remains the normal command path. The WD can assert ATN later while connected.
   The current driver has only Message In machinery, so recovery requires new,
   narrow Message Out states rather than a global selection-policy change.
8. **There is no defensible production microsecond bound for unilateral
   `COM=0x04` cleanup.** A target was never asked to terminate, so the protocol
   promises no release latency. A one-second poll is useful only as a debug
   discriminator and must not become a one-second interrupt-level busy wait.
9. **The WD/SCSI ownership rule is shared; phase quiesce is not.** A3091 and
   A2091 use the same DFA tables and WD protocol, but `0x48`, `0x49`, and
   `0x4a` have different FIFO/data-direction obligations, and A2091 has a
   different DMA implementation. They are one bus-free contract with separate
   entry contracts and separate hardware hooks.

## The exact failure timeline

The current linked image contains:

| Item | Linked value | Role |
|---|---:|---|
| A3091 `itab` | `.data+0x3890` | maps `0x41 -> 1`, `0x85 -> 3` |
| A3091 `atab` | `.data+0x3920` | maps `STARTING,input 1 -> action 1`; `STARTING,input 3 -> action 7` |
| `a3091_startany` | `.text+0xd00c` | installs request, arms DMA, publishes `STARTING`, writes `startcom` |
| `a3091intr` | `.text+0xd0e0` | reads `SS` and dispatches the stock DFA |
| debug-wrapper call relocation | `.text+0xd3a6` | retargeted to `a3091_badhardware_dbg` |
| `a3091_badhardware_dbg` | `.text+0xdb2f8` | classifier and current narrow recovery |
| current `COM=0x04` write | `.text+0xdb77c` (`Lad_rel_cmd`) | releases WD-driven signals |
| current post-command poll | `.text+0xdb788` (`Lad_rel_poll`) | incorrectly treats clear WD state as physical bus-free proof |
| current request completion | `.text+0xdb824` (`Lad_rel_comp`) | fails old request, publishes `IDLE`, starts next |

The reported sequence is therefore:

```text
CD Select-and-Transfer
  -> SS=0x49, CP=0x46, TC=0, target still requests DATA IN
  -> quiesce SDMAC
  -> WD COM=0x04
  -> AS=0 on first poll
  -> old request callback reports EIO
  -> IDLE; startany(root)
  -> root DMA armed; STARTING; COM=0x09
  -> SS=0x41 terminates whichever command WD then owns
  -> stock badhardware -> DEAD
```

The error callback is correct in isolation. The ownership handoff before
positive target bus-free evidence is not.

## Q1: what does `0x41` at fresh `STARTING` mean?

### What the status proves

The WD data sheet classifies `0x41` as a terminated interrupt: unexpected
target bus free terminated a command, and the WD's new state is disconnected.
It is not:

- a selection timeout (`0x42`);
- a Save Data Pointers event (`0x21`);
- or a protocol-correct temporary disconnect (`0x85`).

SCSI-1 treats bus free without a preceding Disconnect or Command Complete
message as a catastrophic protocol event. That is why treating `0x41` as an
ordinary reconnectable disconnect is incorrect even though both statuses
prove that the bus is free by the time the status is reported.

### What the capture does not prove

`startany()` programs `DI`, copies the CDB, arms DMA, writes `curunitp`, and
sets `STARTING` before it writes the combination command. All those fields can
therefore describe target 6 while selection is still pending. `head=0` only
means the unit was removed from the start queue.

Capture these registers at the `0x41` entry before another command write:

| `CP` | Static interpretation |
|---:|---|
| `0x00` | no new target selection completed; the strongest result for a late event from the CD cleanup |
| `0x10` | target 6 was selected, but no CDB byte is yet proven |
| `0x30..0x3c` | target 6 accepted that many CDB bytes before sudden bus free |
| `0x41..0x47` | the exact later protocol/data stage is encoded by `CP` |
| `0x50` or `0x60` | status or command-complete progress occurred before bus free |

Capture `TC` and `DI` beside `CP`, but do not use `DI` as event identity: it
is a host-programmed destination register. The current classifier already has
the required register-access pattern for `0x48..0x4a`; extending that capture
to `0x41` is the cheapest discriminating next build.

### Required handling

The corrected design makes this attribution question disappear in normal
operation: it does not call `startany()` until the cleanup owner has consumed
bus free. If a `0x41` still reaches ordinary `STARTING`:

- `CP=0` may requeue the not-yet-selected request only after proving it was
  removed exactly once from the start queue and after stopping its armed DMA;
- `CP>=0x10` must fail or explicitly retry the current request; it must not be
  left at `comhead` waiting for an unpromised reselection; and
- every path must print and count its decision before changing ownership.

That is a defensive residual. It is not a substitute for closing the cleanup
race at its producer.

## Q2: what proves physical bus free?

### What `AS` can and cannot say

The WD Auxiliary Status bits describe the chip's host-visible machinery:

| Bit | What it says | What it does not say |
|---|---|---|
| `CIP` | WD is interpreting the command register | cable is free |
| `BSY` | a WD Level II command is executing | target has negated SCSI `BSY` |
| `LCI` | a command write lost a race with an interrupt | target state |
| `INT` | `SS` contains an unacknowledged event | event identity until `SS` is read |
| `DBR` | WD FIFO needs direction-correct service | bus ownership |

The A3091 `istr` register exposes SDMAC/WD interrupt aggregation, not a raw
SCSI `BSY` input. No continuous physical bus-free bit was found in either
device's host register set.

### Positive observations available to this driver

The driver can use these event-level observations:

1. `AS.INT=1`, followed by `SS=0x41`: sudden target bus free; active command
   terminated; WD disconnected.
2. `AS.INT=1`, followed by `SS=0x85`: protocol disconnect occurred; WD
   disconnected.
3. In a normal Disconnect-message sequence, `CP=0x42` means the message was
   received but the bus is not yet free; `CP=0x43` means target bus free has
   occurred.

Only the first two are directly applicable to the current initiator-side
recovery. `CP=0x43` is useful confirmation when the target itself sent a
Disconnect message; host `COM=0x04` is not that target-role sequence.

## Q3: should the driver just wait longer?

### Production verdict

No longer `AS==0` wait is meaningful. It repeats a controller-state test that
already passed. More importantly, unilateral WD Disconnect does not send a
SCSI message to the target, so SCSI-1 supplies no target-release deadline.
Choosing 10 ms, 100 ms, or one second from this static evidence would merely
encode the current ZuluSCSI timing as an undocumented driver contract.

Maintained NetBSD WD33C93 recovery code uses a default order-of-one-second
interrupt wait around a generic chip Abort/Disconnect path. That is useful as
a comparative diagnostic ceiling, not as proof of a protocol guarantee; the
routine itself contains weaker postcondition handling than this port now
requires.

A production target-response timeout must be asynchronous or driven by the
request timeout. The AMIX A3091 source has no corresponding callout/state
machine. Busy-waiting for hundreds of milliseconds at disk interrupt level is
not acceptable.

### One-shot discriminator, if desired before Message Out is built

A debug-only experiment may retain the old request and suppress
`action 5/startany`, then observe up to one second for:

```text
AS.INT -> read SS -> require SS in {0x41, 0x85}
```

Record elapsed raster ticks, status, `CP`, and whether any `DBR/LCI` appeared.
This answers whether this Zulu target eventually releases after the unilateral
host Disconnect. It does not make that behavior portable, and the one-second
form must be labelled as an interrupt-blocking experiment rather than a patch
candidate.

If no event arrives, fail closed with a console line. Do not call the old
request callback, publish `IDLE`, or arm another request while the physical
bus state is unresolved.

## Q4: the recovery operation that addresses the target

### Two different aborts

| Operation | Value | Owner addressed | Postcondition relevant here |
|---|---:|---|---|
| WD command Abort | `COM=0x01` | WD33C93A state machine/FIFO | terminates WD transfer but leaves connected initiator; target is not instructed to stop |
| SCSI ABORT message | message `0x06` | selected SCSI target | clears the current operation and requires the target to enter BUS FREE after recognizing it |

The first may be part of chip cleanup when a Level II command is still active,
but it does not solve bus ownership. The second is the protocol operation the
current path lacks.

### Minimum state-machine shape

For the exact measured `0x49/CP=0x46/TC=0/DATA_IN` tuple:

1. Acknowledge `SS=0x49`, stop SDMAC through the cache-aware wrapper, and keep
   the failed CD request as the sole cleanup owner.
2. Obey the WD command guard: no pending `INT/CIP`, and at least 7 microseconds
   from the `SS` read before another command-register write.
3. Issue WD `Assert ATN` (`COM=0x02`) while still connected as initiator.
4. Drive the handshake until the target requests Message Out. Maintained
   NetBSD code uses `SET_ATN`, checks `LCI`, and then `CLR_ACK`; it accepts the
   transferred and mismatch variants of the Message Out phase.
5. Send one PIO message byte, SCSI `ABORT=0x06`. Do not arm SDMAC for it.
6. Retain cleanup ownership until `AS.INT` permits an `SS` read and the status
   is `0x41` or `0x85`. A Message Reject, wrong phase, command ignore, or
   timeout is an explicit fail-stop/escalation result, not success.
7. Only then remove and callback the old request with `okay==FALSE`, publish
   `IDLE`, and call `startany()`.

This is an implementation boundary, not an old-byte patch specification. The
exact ACK state at the AMIX `0x49` entry and the status used to enter Message
Out still require a small instrumented proof before assembly is written.

SCSI-1 labels ABORT optional. If the target rejects it or never changes phase,
the next escalation is a real SCSI bus reset or a visible controller
fail-stop. The AMIX A3091 `device->srst` field is the SDMAC **stop-DMA strobe**,
not a SCSI reset. WD software Reset also must not be presented as a target bus
reset. No safe local bus-reset primitive was found in `a3091.c`.

### Why `startcom=0x09` stays

The current normal path selects without ATN. That does not prevent ATN from
being asserted later while connected. SCSI-1 also defines ABORT behavior when
no logical unit was identified: the target still goes bus free.

Changing every command to Select-with-ATN would add an Identify/Message Out
contract to all healthy I/O and enlarge the blast radius far beyond ISSUE-54.
The recovery path needs Message Out; the normal selection path does not need
to be rewritten to obtain it.

## Q5: no silent request stranding

Use an explicit cleanup state and generation, not an overloaded `STARTING` or
`MESSAGING` value:

```text
CD request owns controller
  -> CLEANUP_ATN
  -> CLEANUP_MSGOUT
  -> CLEANUP_BUSFREE
  -> fail CD exactly once
  -> IDLE
  -> start next request
```

Required invariants:

- `curunitp` and `unit->comhead` remain the failed CD request throughout
  cleanup;
- `startany()` cannot run in a cleanup state;
- the callback cannot run before bus-free evidence;
- one cleanup generation consumes at most one `0x41/0x85` event;
- a late event cannot be dispatched through the next request's DFA state;
- message rejection, timeout, and unexpected status each have a console line
  and counter;
- success completes the old request exactly once with failure and then allows
  queued work; and
- failure leaves the controller visibly unusable rather than silently
  pretending a request will reselect.

The current wrapper's callback ordering remains useful: callbacks run before
`IDLE`, so a callback-enqueued request cannot start until ownership is
published. The missing condition is that target bus free must precede that
callback.

Blind table edits fail this contract:

| Edit | Failure mode |
|---|---|
| `itab[0x41]=3` | action 7 leaves a suddenly terminated request at `comhead` awaiting an unpromised reselection |
| treat clear `AS` as success | repeats the hardware-refuted race |
| callback old request, delay `startany` | userland can enqueue work and there is still no target-release proof or asynchronous wake owner |
| reset WD and continue | loses controller state without resetting/reconciling the target or queues |

## Q6: one contract or several?

### Shared WD/SCSI contract

These rules are shared by A3091 and A2091, and by `0x48`, `0x49`, and `0x4a`:

- clear WD command state is not physical bus-free proof;
- keep the current nexus until target release is observed;
- target-directed abort requires ATN, Message Out, and SCSI message `0x06`;
- consume bus-free status before exposing `IDLE` or starting another target;
- never reinterpret unexpected bus free as reconnectable disconnect without a
  request-lifetime owner; and
- all waits are bounded, classified, and visible on expiry.

The AMIX sources confirm that A2091 carries the same 144-byte `itab`, 6 by 9
`atab`, `STARTING`/`MESSAGING` states, `0x09` normal start command, and action
7 behavior (`a2091.c` lines 87-147, 195-224, and 238-336).

### Separate entry contracts

| Status | Requested phase | Separate obligation before Message Out |
|---:|---|---|
| `0x48` | DATA OUT | quiesce host-to-target DMA and account for data already accepted by WD/target |
| `0x49` | DATA IN | flush SDMAC/FIFO to RAM and complete FROM_DEVICE cache ownership before callback |
| `0x4a` | COMMAND | account for partial CDB transfer; no data-buffer assumptions |

A3091 and A2091 also have different DMA engines and stop contracts. Therefore
the state-machine policy may be shared, but each driver and phase needs its
own proven quiesce adapter. The measured fast path remains `0x49` only; zero
observations of `0x48/0x4a` are no acceptance evidence for them.

## Minimum next unit

Do not implement the full Message Out state machine before resolving the one
remaining event-attribution ambiguity. The smallest useful next unit is an
instrument-only build:

1. At every `SS=0x41`, capture `CP`, `TC`, `DI`, `CON`, `AS`, `curunitp`,
   `comhead`, request CDB opcode, DMA segment identity, and a cleanup-generation
   value before any state mutation.
2. Preserve separate counts for `CP=0`, `CP>=0x10`, and each DFA state.
3. Reproduce the exact CD read once and retain the full console image/log.

That one run chooses between late old-target release and genuine root-target
termination. It does not alter the final ordering rule: neither outcome permits
the old request to hand off ownership before target bus free.

After that capture, the minimum behavioral unit is atomic:

```text
new cleanup states
+ ATN/Message-Out/ABORT byte
+ bus-free event ownership
+ failed-request completion
+ timeout/reject fail-stop
```

Landing only the table edit, only the longer wait, or only the message byte
creates a mixed state with no safe request owner.

## Acceptance criteria

### Static and emulator wiring

- the exact `0x49/CP=0x46/TC=0/DATA_IN` gate is unchanged unless a new measured
  tuple is deliberately added;
- the cleanup branch has no path to callback, `IDLE`, or `startany()` before
  its bus-free terminal;
- WD command Abort and SCSI ABORT message counters are distinct;
- all command, phase, and target-response waits have named finite exits;
- `0x48` and `0x4a` retain explicit unhandled counters/fail-stop behavior; and
- A2091 remains byte-unchanged unless its separate hardware adapter is part of
  the reviewed unit.

### 68060 hardware discriminator and behavior

1. Before the behavioral change, one exact trigger captures `CP` on the
   following `0x41` and classifies it as pre-selection or post-selection.
2. With the behavioral unit, the CD `dd` returns an I/O error exactly once.
3. One and only one SCSI ABORT message is scheduled and sent for that request.
4. A bus-free `0x41/0x85` is consumed by the same cleanup generation before
   the callback and before any root-disk arm.
5. No `0x41 STARTING target 6`, no `badhardware`, no `DEAD`, and no cleanup
   timeout/reject counter occurs.
6. Immediate root-disk reads complete and compare byte-exactly; then run the
   normal disk-truth/burst acceptance rather than treating one successful read
   as controller recovery proof.
7. Counter identities hold, for example:

```text
cleanup_try = cleanup_prefree + abort_sent + cleanup_fail_before_message
abort_sent = busfree_after_abort + abort_timeout + abort_reject + abort_other
failed_callback = cleanup_prefree + busfree_after_abort
start_before_busfree = 0
duplicate_callback = 0
```

The exact denominator names may differ, but the ownership identities must be
readable from the accepted image. A zero path count means unexercised, not
passed.

## Confidence and residual risk

| Finding | Confidence | Remaining uncertainty |
|---|---|---|
| clear `AS` is not cable bus-free proof | high | none in the documented register semantics; hardware result confirms the practical consequence |
| `0x41` is unexpected bus free, not timeout or normal disconnect | high | event ownership remains unknown without `CP` |
| blind `0x41 -> action 7` can strand a request | high | none in the AMIX queue/DFA structure |
| target-directed local recovery requires Message Out | high | exact ACK/phase entry at this AMIX `0x49` still needs a measured implementation spec |
| initial `startcom=0x09` need not change | high | older-controller `0x08` fallback remains a separate inherited path |
| unilateral `COM=0x04` has no portable target-release bound | high | a particular Zulu target may self-release after a measurable private delay |
| same policy applies to A2091 | high at WD/DFA level | A2091 DMA quiesce and hardware acceptance are separate |

The present direct-Disconnect branch is therefore **not hardware-accepted as
an atomic fix**, despite correctly returning EIO for its original request. The
reported run refutes its release postcondition. Until Message Out recovery or
an earlier rejection of unsupported block-size targets is implemented, the
safe behavior remains visible fail-stop before another request is armed.
