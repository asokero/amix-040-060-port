# A3091 DATA IN drain and failed-command retirement design

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/A3091-DATA-IN-DRAIN-DESIGN.md` (private workspace, imported 2026-08-30).
> This copy is the implementation-facing reference used by `src/`.

This document answers `private/A3091-DRAIN-CODEX-TASK.md`. It reviews the
three measured ISSUE-54 recovery failures and specifies a fourth experiment
whose assumptions are tested before it is allowed to retire a request.

The result is a static design and a falsification contract. It is not a port
implementation or a hardware acceptance result.

## Pinned inputs

| Input | Identity |
|---|---|
| Stock kernel SHA-256 | `not used: no address or byte claim was taken from stand/unix` |
| AMIX object SHA-256 | A3091 `3ea9e3dd37725c3d1717b85683ecf9974f99f00596cccdaec70cc282ec2f5a8a`; A2091 `30fc152c52c504092288f6bbeb3554b944750ad3c59459cbba64e31e302930f5a8` |
| Port commit | `8d18ed0bb8fe13378d19eb3f0ae925995a75d3ea` |
| Port image SHA-256 | `build/unix-040` `44e581bb51d0f746277186b2beab702f426399edffc0d9a21571a6c7bf110616` |
| Reference source identity | AMIX `sys/amiga/alien/a3091.c` SHA-256 `145a313b20364d1acd32cff2d15ccfe13f87c0eade5ff3246b2d031e1a4df53a`, `a2091.c` `c7f2bdd40a072da84807abdad7fbcbf81a8f953ed352b8a325a1c336d19cbe7d`, from `vanilla/amix-sources.tar` SHA-256 `fbfa00f445cedcda6b3ae4a8679de592e60ced7fa51c43ebcec3cbe943c2ff5b`; WD33C93A Nov. 1990 data sheet/application notes SHA-256 `1513852c994336439ecca41c7111d7ea18e9fb5241a9d571d87f7489b0edda18`; ANSI X3.131-1986 SCSI PDF SHA-256 `238424c04b8542f6d93de63f19661efa3144be68c50dee60c61ffb039e54cb75`; NetBSD 10.1 `sbic.c` SHA-256 `1cf7ae87ed9c7d90ca753529c504b54e2ce22c1e9b3ebc7652ee52332bf0e6d8` and `sbicreg.h` `a6d52acd2e1eebcff4a8dffe86e895192df4211b1c8a5c32e83875870299764d` |
| Address domains | Linked port-image ELF section-relative symbol values; AMIX source line numbers; WD/SCSI command, phase, message, and register values; reported runtime values only where explicitly labelled |
| Evidence commands | GNU binutils 2.44 `nm`, `readelf`, and `m68k-linux-gnu-objdump`; `sha256sum`; `tar -xOf`; `nl -ba`; `pdftotext -layout`; manual state-machine and protocol comparison |

### Additional provenance

| Item | Identity |
|---|---|
| Current override source | `src/a3091dbg040.s`, SHA-256 `62097385aa928867ffa7792e107b9a758f3f00cc10ddc94abd00b85d84560254` |
| Task brief | `private/A3091-DRAIN-CODEX-TASK.md`, SHA-256 `158bef795f98712599f6843ab7516efd52eec6a0f67f861142a937af1609f9b1` |
| `-11` discriminator report | `docs/REALHW-ISSUE54-DISCRIMINATOR-260829-11.md`, SHA-256 `c9c7211d48adc24ffabb9e8db2bb2af9b7bd21b8c239af29cad2a953a0098c50` |
| `-15` ATN report | `docs/REALHW-ISSUE54-ATN-260829-15.md`, SHA-256 `7ff047c3f119ebb09b1dc34c523276f937a084d62a58b923a4bfb808b40a12ba` |
| Independent pre-brief reading | `docs/ISSUE54-DRAIN-MY-READING-260829.md`, SHA-256 `195c6d1c4b56d49fcae1ce66ced378a5e0d8866e68a62a272914d85836d42e47` |

Addresses below are linked-image ELF section-relative values. Source line
numbers refer to the pinned AMIX source. Hardware transcripts are reported
runtime evidence; this static review did not reproduce them.

## Hardware findings that change the design

The fourth design must start from these measured facts:

1. The original CD request reaches `SS=0x49, CP=0x46` after only 512 bytes of
   a 2048-byte target block. Its SDMAC transfer is stopped and the request is
   already known to be unsalvageable.
2. Treating accepted WD `COM=0x04` as bus release lets the next root command
   start. The later `SS=0x41, CP=0x3a, TC=0x800` proves the root target was
   selected and accepted CDB bytes before the bus went free under it.
3. ATN is accepted, but the first resulting status is `0x89`, DATA IN. The
   target still has 1536 bytes to present and is not yet ready for Message Out.
4. A later `0x85` from the CD shows that this target eventually releases the
   bus. It arrives too late for the current driver ownership transition.

The earlier target-attribution ambiguity and the assumption of an immediate
Message Out phase are therefore both closed by hardware.

## Executive verdict

1. **The current command cannot succeed.** `dd.c` uses 512-byte `BSIZE`
   arithmetic for both LBA and transfer length. The 512 bytes already received
   from a 2048-byte-block device are not merely an incomplete version of the
   requested logical block; the command addressed the wrong target block.
2. **WD33C93A Transfer Pad is not available.** Western Digital compatibility
   notes explicitly remove Transfer Pad from the A revision. A header constant
   without a call site is not a hardware contract, and the value `0x19` must
   not be tested on the assumption that the A chip implements it.
3. **Use ordinary PIO Transfer Information (`COM=0x20`) as the candidate
   discard primitive.** It has a documented Transfer Count, phase-change
   termination, DBR service rule, and two comparative implementations. First
   prove one byte; only then build a bounded phase drain around it.
4. **Recovery owns the controller until bus free is consumed.** It must not
   call the request callback, publish `IDLE`, or call `startany()` while the
   original target can still generate events.
5. **Natural target completion never changes the failed verdict.** The
   recovery path bypasses stock action 9 and action 0, leaves `cp->okay` false,
   and retires the request as an error only after positive bus-free evidence.
6. **This is bounded containment for the measured tuple, not universal reset.**
   A target that stops producing DBR, phase, or bus-free events cannot be made
   safe by a finite PIO loop. Without a proven SCSI bus-reset primitive the
   only bounded fallback is controller quarantine/fail-stop.

## Q1: how this command can end cleanly

"Cleanly" has two separate meanings here:

- the SCSI transaction reaches a defined ending and releases the bus; and
- the AMIX request reports failure, because its addressing and data are wrong.

The initiator should keep ATN asserted, consume the unwanted DATA IN bytes
without writing them to the caller's buffer, and inspect every phase change.
The preferred ending is:

```text
DATA IN discard
  -> target honors ATN with MESSAGE OUT
  -> initiator sends SCSI ABORT message 0x06
  -> consume SS=0x41 or SS=0x85 bus-free event
  -> retire original request with okay == FALSE
```

SCSI allows the target to respond to ATN at its convenience, so the measured
intermediate DATA IN phase is not itself an error. The SCSI ABORT message is
the target-facing termination request. It is not WD command `COM=0x01`;
Western Digital's A-revision note also says that chip Abort is unsupported in
initiator mode.

A defensive second ending is required in case the target reaches STATUS before
Message Out is observed. The recovery may consume one status byte, then accept
only the ordinary one-byte Command Complete message (`0x00`), clear ACK, and
require bus free. This still retires the AMIX request as failed. A Disconnect
message (`0x04`) is not equivalent: it promises possible reselection, so the
driver cannot free the request unless it also implements cleanup ownership
across reselection. The narrow recovery should fail closed on that message.

## Q2: the discard primitive

### Why `XFER_PAD` is rejected

NetBSD's Amiga header defines `SBIC_CMD_XFER_PAD` as `0x19`, but its driver
does not use it. Linux headers have historically exposed a different Transfer
Pad opcode. Neither declaration establishes WD33C93A behavior.

Western Digital application notes E062-B and E025-A are decisive for the chip
named by this driver: Transfer Pad is deleted in the WD33C93A. The A-revision
command table also skips from the `0x18` group to Transfer Information at
`0x20`. If an actual board can contain an original WD33C93, its exact chip
revision must be identified before using an original-chip-only command; it is
not a portable A3091 recovery mechanism.

### Documented PIO sequence

Use Transfer Information in programmed-I/O mode:

1. Keep SDMAC stopped and its host buffer/cursor unowned by this transfer.
2. Preserve the WD direction as SCSI-to-host for DATA IN, clear the WD DMA-mode
   selection, and retain the interrupt-enable policy. In the current register
   vocabulary this is the PIO `CON` value corresponding to `EDI|IDI` rather
   than the observed DMA value `0x8c`.
3. Load Transfer Count explicitly. This is mandatory after every single-byte
   transfer on WD33C93A because the A revision does not preserve the old count
   as the original chip did.
4. Respect the existing seven-microsecond guard after reading `SS` before
   writing another WD command.
5. Write `COM=0x20` (`TRANSFER INFO`). For DATA IN, wait for either DBR or INT.
   On DBR, read one byte from `DR` and discard it. On INT, read and classify
   `SS`; a phase change ends the current transfer and leaves the residual count
   available for diagnosis.

NetBSD 10.1 `sbicxfin()` uses this same command/DBR/read shape for PIO input,
and `sbicxfout()` uses command/DBR/write for output. Their polling limits are
comparative evidence only; this port must retain its own explicit bounds.

For a one-byte Message Out, select SCSI-to-host false, load TC=1, issue
single-byte Transfer Information (`0xa0`, the existing `COM=0x20` plus SBT),
wait for DBR, and write message byte `0x06` to `DR`. The WD contract negates
ATN before the final Message Out byte. This sequence is a separate primitive
proof after the input proof; do not infer it merely from action 8, which is a
Message In read.

## Stage P: prove one discarded byte before recovery exists

The first kernel should be an instrumented primitive test, not a fourth full
recovery attempt. Enter only for the exact measured tuple after ATN:

```text
SS == 0x89
phase == DATA IN
CP == 0x46
original request already marked failed
SDMAC stopped
```

Load `TC=1`, issue PIO `COM=0x20`, consume exactly one DBR byte, then capture:

- AS and any resulting SS;
- TC, CP, DI, and CON;
- SDMAC `sac`, `cntr`, and `istr`;
- `dma_on` and the discarded-byte count; and
- caller-buffer canaries around the original 512-byte transfer.

After capture, deliberately quarantine/fail-stop. Do not callback, publish
`IDLE`, or start the root command. This makes a failed primitive experiment
cost one controlled boot instead of another damaged command.

### Stage P acceptance

The primitive is accepted only if all are true:

- exactly one byte is read from `DR`;
- TC changes from one to zero;
- no SDMAC cursor, count, or caller-buffer byte changes;
- no invalid-command or lost-command indication appears; and
- the WD remains connected in DATA IN or reports a coherent next phase.

It is falsified, and the complete drain must not be written, if any of these
occur:

- invalid command (`SS=0x40`) or LCI;
- no DBR or INT within the predeclared poll bound;
- TC does not decrement exactly once;
- SDMAC or caller memory moves despite PIO mode;
- an unexplained DATA OUT/COMMAND phase, parity error, or connection loss; or
- any callback, `action 0`, `IDLE`, or `startany()` is reached.

## Stage D: bounded phase drain after Stage P passes

Stage D keeps the failed request as the sole owner. It may use `0x800` as a
cleanup ceiling because that is the maximum transfer implicated by this
specific trigger, not because the driver has derived the exact 1536-byte
residual from target geometry.

The state machine is:

```text
DATA IN:
  PIO TRANSFER INFO, TC <= 0x800
  discard each DBR byte
  stop on phase interrupt or byte ceiling

MESSAGE OUT:
  send one SCSI ABORT byte 0x06 with SBT TRANSFER INFO
  require subsequent bus-free event

STATUS:
  consume exactly one status byte
  accept only MESSAGE IN / Command Complete 0x00
  CLR_ACK and require subsequent bus-free event

BUS FREE (SS 0x41 or 0x85):
  consume the event
  unlink and callback exactly once with okay still FALSE
  publish IDLE last, then startany

anything else:
  quarantine/fail-stop without handing off ownership
```

Every wait has all of these independent bounds:

- at most `0x800` discarded DATA IN bytes for this trigger;
- a fixed no-progress poll count around each DBR/INT wait;
- a small fixed phase-transition count, such as four, sufficient for
  DATA IN -> MESSAGE OUT -> bus free or DATA IN -> STATUS -> MESSAGE IN ->
  bus free; and
- the seven-microsecond post-SS command guard at every transition.

The implementation must record which bound fired. A single aggregate timeout
would make a fourth failure no more informative than the first three.

### Stage D falsification conditions

The design is wrong or incomplete if hardware shows any of the following:

1. `COM=0x20` is rejected or its TC/DBR accounting is not exact.
2. The target remains in DATA IN after `0x800` bytes have been discarded.
3. No recognized phase or bus-free event arrives within the poll and phase
   bounds.
4. SDMAC state or the original host buffer changes during PIO discard.
5. `action 9`, `action 0`, or any success callback is reached.
6. `startany()` runs before the recovery owner consumes bus free.
7. The old CD produces another late `0x85` after a root command starts.
8. The root request fails after cleanup even though the CD request failed
   exactly once.

These are predictions written before implementation. A result must be reported
against each one rather than summarized as "the machine survived".

## Q3: preserving the failed request verdict

AMIX `queue()` initializes `cp->okay` false (`a3091.c:155`). Stock `action0()`
sets it true only for the successful command-pointer terminal (`a3091.c:230-242`).
Stock action 9 advances through the normal transfer/status path
(`a3091.c:308-315`). The recovery must not re-enter either action.

After bus free is consumed, a recovery-owned completion routine must:

1. assert that the original request remains the controller's cleanup owner;
2. leave or explicitly set `cp->okay` false;
3. unlink/dequeue it once using the same callback ownership order as an error
   completion;
4. publish `IDLE` only after all WD/SDMAC events for that request are consumed;
5. call `startany()` only after the failed callback and ownership release.

The completion should count `drained_failed`, `unexpected_success_path`, and
`handoff_before_busfree` separately. Any nonzero value for the last two is a
hard rejection even when userland receives `EIO`.

## Q4: bounded recovery versus coarse policy

The two-stage design is bounded for the observed, responsive target. It cannot
guarantee recovery from an arbitrary target that stops handshaking. No host
poll count proves physical release, and the inspected AMIX A3091 path exposes
no already-proven SCSI bus-reset/callout recovery that can force it.

Therefore the bounded fallback is fail-stop: mark the controller unusable,
retain enough ownership to prevent another command from starting, and require
a reboot. That is less functional than returning `EIO`, but it cannot corrupt
the next root request.

The long-term policy should prevent this command from being issued. The driver
needs target block geometry, for example from READ CAPACITY, and either:

- implement block-size-aware LBA and transfer arithmetic; or
- reject a device whose logical block size is incompatible with the driver's
  fixed 512-byte contract before normal I/O.

The pinned AMIX `struct unit` and `dd.c` path do not already provide that
geometry policy, so preflight is a separate driver change rather than a small
replacement for Stage D.

## A2091, tape, and the old `0x49` behavior

- A2091 has the same high-level DFA tables, so the ownership, failure-latch,
  and phase-bound rules apply. Its chip revision and DMA/PIO register hooks
  must be proven separately before sharing assembly; identical tables do not
  prove identical hardware service.
- Target 4 tape I/O may legitimately use variable block sizes. Do not reuse
  the CD-specific `0x800` ceiling or a fixed-block rejection rule for tape
  without a separate transfer contract.
- Keep the old `0x49` classification and counters. Do not keep the `-09/-11`
  production behavior that returns `EIO` and starts another request: hardware
  proves that handoff can kill the root command. As a debug fallback it may
  return the CD error only if the controller remains quarantined and never
  calls `startany()`; that is a diagnostic stop, not successful recovery.

## Linked-image anchors

| Item | Linked value | Relevance |
|---|---:|---|
| A3091 `itab` | `.data+0x3890` | maps WD status to DFA input |
| A3091 `atab` | `.data+0x3920` | includes the normal action-0/action-9 paths that recovery must bypass |
| `a3091_startany` | `.text+0xd00c` | command/ownership handoff forbidden before bus free |
| `a3091intr` | around `.text+0xd0e0` | stock event dispatcher |
| `a3091_stopdma` | `.text+0xd4cc` | SDMAC quiesce boundary |
| stock `badhardware` | `.text+0xd666` | terminal stock failure path |
| `a3091_badhardware_dbg` | `.text+0xdb2f8` | current override entry |
| current recovery gate | around `.text+0xdb6f2` | candidate site for Stage P, after exact tuple validation |
| ATN/phase classification | around `.text+0xdb7b0..0xdb89e` | measured `0x89` transition |
| current manual completion | from `.text+0xdb9fe` | must be replaced only after Stage D bus-free proof |

## References

- Western Digital, [WD33C93A Data Sheet and Application Notes, November
  1990](https://bitsavers.trailing-edge.com/components/westernDigital/WD33C93A_Data_Sheet_and_Application_Notes_Nov1990.pdf), especially application
  notes E062-B and E025-A for deleted commands and single-byte TC behavior.
- [ANSI X3.131-1986 SCSI](https://www.govinfo.gov/content/pkg/GOVPUB-C13-b974db668ca7572fe23cab4c248ef62b/pdf/GOVPUB-C13-b974db668ca7572fe23cab4c248ef62b.pdf), Message Out and ABORT-message behavior.
- NetBSD 10.1 `sys/arch/amiga/dev/sbic.c`, `sbicxfstart`, `sbicxfout`, and
  `sbicxfin`, used as comparative PIO sequencing rather than byte provenance.
- AMIX `sys/amiga/alien/a3091.c`: request initialization and action DFA at
  lines 155, 195-242, and 299-355; `dd.c` at lines 18 and 237-258 for the
  512-byte LBA/length contract.
