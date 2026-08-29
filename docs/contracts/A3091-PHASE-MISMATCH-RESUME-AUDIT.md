# A3091 WD33C93A Phase-Mismatch Resume Audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/A3091-PHASE-MISMATCH-RESUME-AUDIT.md` (private workspace,
> imported 2026-08-29). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** Answers the question posed by
> `private/A3091-PHASE-MISMATCH-CODEX-TASK.md` for ISSUE-54. It **rejects** this line's
> proposed `itab[0x48..0x4A] = 2` table change as too broad, and specifies a
> *classification build* as the next step instead — no behaviour change, one deterministic
> capture of the Command Phase / transfer count / direction / SDMAC-cursor tuple at the
> reproducible `0x49` event. `docs/contracts/A3091-PHASE-MISMATCH-DFA-CONTRACT.md` is this
> line's own measurement of the same driver and is superseded where the two disagree.

This document answers `private/A3091-PHASE-MISMATCH-CODEX-TASK.md` from the
port repository. It reviews whether AMIX action 6 can recover from
`MIS_1|DATA_IN`, what must bound that recovery, whether `DATA_OUT` and
`COMMAND` can share it, and how the decision interacts with the installed
A3091 copyback-DMA ownership wrapper.

The result is a specification, not a kernel change.

## Pinned inputs

| Input | Identity |
|---|---|
| Stock kernel SHA-256 | `not used: no addresses were taken from stand/unix` |
| AMIX object SHA-256 | A3091 `3ea9e3dd37725c3d1717b85683ecf9974f99f00596cccdaec70cc282ec2f5a8a`; A2091 `30fc152c52c504092288f6bbeb3554b944750ad3c59459cbba64e31e302930f5a8` |
| Port commit | `f769022054b03aa06d0d33413eaf7ce7dce6c113` |
| Port image SHA-256 | `build/unix-040` `f53ab2d349105fc39ac1e3e9301f7cf70b03a43ab307f79016ac890904afae9e`; debug image `2adf32096b04c83a07c88ff373a8af2e2d9fb66c823b00a536b657e5cbbf7394` |
| Reference source identity | AMIX `a3091.c` `145a313b20364d1acd32cff2d15ccfe13f87c0eade5ff3246b2d031e1a4df53a`, `a2091.c` `c7f2bdd40a072da84807abdad7fbcbf81a8f953ed352b8a325a1c336d19cbe7d`; WD33C93A WD2088S 9/88 PDF `0fa1ca954dd9f7efa9c9c9e8946aa95ac7f99ce8272d15bbffdf4e38b9e65566`; NetBSD 10.1 `sbic.c` `1cf7ae87ed9c7d90ca753529c504b54e2ce22c1e9b3ebc7652ee52332bf0e6d8`; Linux `wd33c93.c` `5036bc56261bfe374d4a9d855010079fef337c32cf272648c5410cfcc6d22e96` |
| Address domains | Linked port-image ELF section-relative values, AMIX object section offsets, and A3000 SDMAC register offsets; none are runtime VAs |
| Evidence commands | `sha256sum`; `tar -xOf`; `m68k-linux-gnu-readelf -sW/-rW/-SW`; `m68k-linux-gnu-objdump -dr/-s`; source line inspection with `nl` and `sed` |

### Additional provenance

| Item | Pinned identity |
|---|---|
| Port repository | `f769022054b03aa06d0d33413eaf7ce7dce6c113` |
| Task brief | SHA-256 `87975050301a7249647c67229e4aef03df59fd88b808b6882584c491a6e99f37` |
| Existing DFA contract | SHA-256 `1adffac1a02df22999c376600415e0d3bdd79966b94bdf2970c435bdf897bdaf` |
| Current normal image | `build/unix-040`, SHA-256 `f53ab2d349105fc39ac1e3e9301f7cf70b03a43ab307f79016ac890904afae9e` |
| Current debug image | `build/unix-040-dbg`, SHA-256 `2adf32096b04c83a07c88ff373a8af2e2d9fb66c823b00a536b657e5cbbf7394` |
| AMIX A3091 object | `vanilla/usr/sys/amiga/alien/a3091.o`, SHA-256 `3ea9e3dd37725c3d1717b85683ecf9974f99f00596cccdaec70cc282ec2f5a8a` |
| AMIX A3091 source | `sys/amiga/alien/a3091.c` from `vanilla/amix-sources.tar`, SHA-256 `145a313b20364d1acd32cff2d15ccfe13f87c0eade5ff3246b2d031e1a4df53a` |
| AMIX A2091 object/source | object `30fc152c52c504092288f6bbeb3554b944750ad3c59459cbba64e31e302930f5a8`; source `c7f2bdd40a072da84807abdad7fbcbf81a8f953ed352b8a325a1c336d19cbe7d` |
| WD reference | Western Digital WD33C93A data sheet, WD2088S 9/88; downloaded PDF SHA-256 `0fa1ca954dd9f7efa9c9c9e8946aa95ac7f99ce8272d15bbffdf4e38b9e65566` |
| NetBSD reference | NetBSD 10.1 source tar SHA-256 `76a600e703d2e964753323e264d3ec07d0c6cbe134648fc8f0f13ed9faaa1be4`; `sys/arch/amiga/dev/sbic.c` SHA-256 `1cf7ae87ed9c7d90ca753529c504b54e2ce22c1e9b3ebc7652ee52332bf0e6d8` |
| Linux reference | `drivers/scsi/wd33c93.c` SHA-256 `5036bc56261bfe374d4a9d855010079fef337c32cf272648c5410cfcc6d22e96` |

Addresses below are ELF section offsets in the pinned ET_REL image, not
runtime virtual addresses. The AMIX source establishes field and algorithm
meaning. The shipped A3091 object establishes the exact compiled body: its
`a3091intr+0x170`, `itab+0`, and `atab+0x90` map respectively to linked
`.text+0xd0e0`, `.data+0x3890`, and `.data+0x3920`. The linked image was also
checked independently because the port retargets selected relocations.

The runtime reproduction and captured values in the task brief are reported
runtime evidence. They were not rerun during this static review.

## Executive verdict

1. **The WD preserves useful Command Phase state across this termination.**
   Command Phase is specifically the progress register to inspect after an
   abnormal combination-command termination. A normal Select-and-Transfer
   issued while the WD remains Connected-as-Initiator is defined as a Resume,
   and the chip uses the existing Command Phase value to choose the restart
   point. Reissuing `0x09` is therefore neither a fresh selection nor
   undefined.
2. **That does not validate the proposed three-byte table patch.** The saved
   Command Phase must be compatible with the newly requested phase. For a
   `DATA_IN` request, values `0x41` and `0x45` permit data continuation;
   `0x46` says the data count already completed, while `0x20`/`0x30` say the
   command phase is not complete. Reissuing the same command for an
   incompatible tuple reproduces the mismatch.
3. **Do not write `CP=0x45` unconditionally.** It can skip an incomplete CDB,
   convert extra target data into accepted data, or discard exact progress
   represented by another valid Command Phase value.
4. **`DATA_IN`, `DATA_OUT`, and `COMMAND` are not one recovery class.** The two
   data directions can share validation machinery but have different damage
   consequences. `COMMAND` requires a CDB-transfer contract and is handled
   separately by both maintained reference drivers.
5. **A table-only change cannot enforce a retry bound, validate CP/direction,
   or reconcile DMA progress.** The current `a3091_badhardware_dbg`
   relocation is the narrowest existing interposition point for a conditional
   experiment: it receives `ss`, can inspect the exact tuple, and can return
   `RESUMING` only for an accepted case while delegating all others to the
   stock fail-stop.
6. **Action 5 is not by itself a clean hardware abort for `MIS_1`.** It reports
   the request as failed, but the data sheet says a combination command
   terminated during an information phase leaves the WD connected as an
   initiator. Action 5 neither issues WD Abort nor Disconnect. Reusing it
   safely requires a separate bus-release state transition first.
7. **Do not shrink `dma_seg_len` after a partial transfer.** That record is the
   CPU/device ownership envelope for cache completion, not the WD's current
   cursor. If the same SDMAC arm continues, retain the full range. If recovery
   stops and re-arms a suffix, complete the old ownership first and let the
   existing start wrapper create a new suffix record.

The immediate next build should therefore be a **classification build**, not
the three-byte behavior change. The missing measured tuple is Command Phase,
WD residual count, direction/control, and SDMAC address at the reproducible
`0x49` event.

## Q1: what survives `MIS_1`, and what does `0x09` do?

### Manufacturer contract

The WD data sheet gives four directly relevant rules:

- Command Phase records which phases of a combination command have completed.
  Following abnormal termination, software reads it to identify where the
  operation stopped.
- Command Phase is also the resume control. Software may load a desired next
  phase and reissue the combination command.
- A normal Select-and-Transfer issued while Connected-as-Initiator is assumed
  to be a Resume. The WD examines Command Phase to determine where to continue.
- An unexpected information phase terminates the current combination command.
  If termination occurred during an information phase, the WD remains
  Connected-as-Initiator. Transfer Count contains bytes not successfully
  transferred on the SCSI bus.

Consequently, reading SCSI Status to acknowledge `0x49` does not erase the
progress state needed for diagnosis. The exact Command Phase value is
event-dependent, but it survives as the WD's statement of progress.

### Phase-by-phase interpretation

The resume table in the data sheet gives these relevant meanings:

| Command Phase | State represented | Is a requested `DATA_IN` compatible? |
|---:|---|---|
| `0x10` | target selected | no; identify/command work remains |
| `0x20` | identify sent | no; command phase is expected |
| `0x30` / `0x3x` | command phase begun / CDB progress | no; accepting data can skip CDB bytes |
| `0x41` | command complete or Save Data Pointers received | yes; data, status, or message-in may follow |
| `0x44` | target reselected | no; identify-in is still expected |
| `0x45` | identify-in after reselection complete | yes; more data, status, or message-in may follow |
| `0x46` | programmed data count completed | no; status or save/disconnect message is expected |
| `0x50` / `0x60` | status / command complete progress | no; the data phase is over |

This gives a conditional answer to the brief's load-bearing question:

- **CP survives, and `0x09` is a defined resume without rewriting CP.**
- **Action 6 is chip-valid for the data case only when the observed CP is a
  data-permitting resume point, the residual is nonzero, and direction agrees.**
- **The three-byte `itab` patch is not proven by CP survival.** It has no way
  to distinguish the valid and invalid rows above.

The measured status is especially important because `MIS_1|DATA_IN` can mean
either an unexpected phase sequence or a phase change before Transfer Count
reached zero. Those are not the same recovery situation. For example,
`CP=0x46, TC=0` would mean the target is offering extra data after the
programmed transfer; action 6 would resume expecting status, receive data
again, and return immediately to `0x49`.

### Why an unconditional `0x45` write is worse

`0x45` is a valid explicit restart point only after the reselect/identify path
or when deliberately asking the WD to transfer more data. It is not a generic
"data mismatch" value:

- with `CP=0x20` or `0x3x`, it skips command progress;
- with `CP=0x46`, it turns target overrun into accepted data;
- with `CP=0x41`, it replaces a valid, more exact state for no gain; and
- with a direction mismatch, it does not repair Destination ID `DPD`.

The current CP should be preserved for a conditional resume. It should be
overwritten only by a phase-specific recovery whose preconditions prove that
the chosen value is the desired next phase.

## Q2: retry bound and fallback

### Why the table edit cannot be bounded

The current bytes are:

| Driver | Table entries | Current bytes |
|---|---|---|
| A3091 | `.data+0x38d8..0x38da` = `itab[0x48..0x4a]` | `01 01 01` |
| A2091 | `.data+0x3810..0x3812` = `itab[0x48..0x4a]` | `01 01 01` |

Changing the A3091 bytes to `02 02 02` can only select inline action 6. It
cannot remember a request identity, previous CP/TC tuple, attempt count, or
whether progress occurred. A repeatedly mismatching target can therefore
spin forever between `STARTING/RESUMING`, status read, and action 6.

### Recommended first bound

For the first behavior experiment, allow **one conditional resume per command**
and only for the measured `0x49` class. One attempt is deliberately
conservative: it proves whether the WD's hardware resume handles the target
without introducing a protocol engine into the patch.

A later progress-aware policy may permit another resume only when all of these
are true:

1. the same request is still current;
2. the new residual is strictly smaller than the previous residual;
3. CP remains in the allowed set;
4. the phase and direction still agree; and
5. an independent hard cap is not exceeded.

Strict progress alone is not a bound. A target could reduce TC one byte at a
time. A hard cap is still required. No source-backed value exists for that
cap; `1` is the safest initial engineering choice, while any larger value is
a policy choice to validate with the target population.

### Fallback is not ordinary action 5

Action 5 (`a3091.c:276-285`, linked `.text+0xd2cc..0xd35a`) correctly leaves
`cp->okay == FALSE`; it does not report false success. But it was designed for
a status such as selection timeout, where
the WD is disconnected. After an information-phase `MIS_1`, the WD is still
Connected-as-Initiator. Action 5 only stops host DMA, dequeues/completes the
software request, sets `IDLE`, and starts another request. It sends no WD bus
command.

Therefore the fallback ranking is:

1. **Until a bus-release path exists, retain the existing fail-stop on a
   rejected tuple or exhausted retry.** It is operationally bad but does not
   claim that connected hardware is idle.
2. **For recoverable failure, first implement a WD cleanup state, then invoke
   action-5-equivalent software completion.** The cleanup must stop host DMA,
   release the connected SCSI bus, acknowledge the resulting WD status, and
   prove the WD is disconnected before `startany` runs.
3. **Do not simply map `0x49` to input 0.** That reaches action 5 only from
   `STARTING`, and can start a new command while the chip remains connected.
   From `RESUMING`, input 0 still reaches `badhardware`.

The WD Abort command alone also does not finish the cleanup: in initiator
state it terminates the active transfer but leaves the WD connected so that
the command could be resumed. The manufacturer additionally requires the host
to continue servicing WD data requests until Abort reports completion so that
the FIFO can drain. Calling the existing SDMAC `stopdma` first and then issuing
Abort is therefore not automatically valid. A complete direction-aware
failure path must drain/quiesce in the required order, release the bus,
acknowledge the resulting event, and only then complete the request. This is
larger than a table patch.

### Narrowest existing interposition point

The linked image already retargets the shared badhardware tail. The source
body is `a3091.c:411-415`; its three callers compile to one shared call site:

```text
.text+0xd3a4: jsr, operand relocation at .text+0xd3a6
.text+0xd3a6: R_68K_32 a3091_badhardware_dbg
a3091_badhardware_dbg = .text+0xdb2f8
a3091_badhardware_orig = .text+0xd666
```

Extending that existing wrapper is narrower than replacing `a3091intr` and
more capable than editing `itab`. It receives `ss`, and it can:

- inspect CP, TC, DI, CON, request direction, SDMAC state, and retry state;
- execute action-6-equivalent work only for an accepted tuple;
- set `a3091_istate=RESUMING` **before** issuing the command, preserving the
  stock ordering against an immediate interrupt;
- return `RESUMING` so the caller stores the same state again; and
- tail-call the original badhardware body for every rejected or exhausted
  case.

The wrapper must use the current `startcom` data value rather than bake in
`0x09`; `initialize()` can change it to `0x08` for an older controller. The
current `startcom` object is local at `.data+0x3958`, so a relink alias or a
byte-asserted direct reference is required.

## Q3: `DATA_OUT` and `COMMAND`

### Data out

At the WD level, a data-out mismatch has the same resume-state set as data in:
CP `0x41` or `0x45`, nonzero residual, matching `DPD=0`, and coherent host-DMA
progress. It does **not** have the same risk profile. A duplicate or shifted
data-in segment corrupts memory; a duplicate or shifted data-out segment can
silently corrupt media.

Do not enable `0x48` merely because a read target passes. It needs its own
scratch-target acceptance with known source data, read-back verification, and
power-cycle disk truth. The first implementation should leave `0x48` fatal.

### Command

`MIS_1|COMMAND` is not a data resume. CP can be `0x20`, `0x30`, or a `0x3x`
CDB-progress value. Correct handling must decide which CDB bytes the target
still expects. Both maintained references classify command phase separately:

- NetBSD saves protocol pointers and transfers the CDB through its command
  transfer helper.
- Linux sends the CDB through its PIO command path.

Neither treats unexpected COMMAND as ordinary data continuation. AMIX action
6 only saves TC, restores control, and reissues the combination command; it
has no CDB-progress validation. Leave `0x4a` fatal until a dedicated CDB
replay contract exists.

### Phase verdict matrix

| Status | First implementation | Later eligibility |
|---|---|---|
| `0x49 MIS_1|DATA_IN` | classify, then one conditional resume for a proven-safe tuple | progress-aware resume after DMA proof |
| `0x48 MIS_1|DATA_OUT` | retain fail-stop | separate scratch-device write/read-back proof |
| `0x4a MIS_1|COMMAND` | retain fail-stop | dedicated CDB phase/progress handler, not action 6 |

This directly rejects `itab[0x48..0x4a] = 2` as one atomic unit.

## Q4: DMA ownership and transfer progress

### What the port metadata means

The source arm and stop contracts are `a3091.c:321-355`; the current port wraps
the linked start calls at `.text+0xd0b2` and `.text+0xd21a`, and all four stop
calls at `.text+0xd170`, `0xd1c8`, `0xd2ce`, and `0xd34a`.
`dma_a3091_startdma` records:

```text
pa  = cp->addr + cp->nbyte - WD_TC
len = WD_TC
dir = cp->reading
state = PREPARED
```

The record denotes the full physical interval whose ownership was handed to
the device. `dma_a3091_stopdma` first quiesces the real SDMAC, then invalidates
the **whole original FROM_DEVICE interval**, deliberately conservative for
partial/error completion. It clears ownership only afterwards.

This gives two rules:

1. **If action 6 continues the same still-armed SDMAC transfer, do not alter
   `dma_seg_pa` or `dma_seg_len`.** A smaller residual does not shrink the
   range the device may already have modified, and shrinking it could leave an
   already-written prefix cached and stale.
2. **If recovery stops and re-arms a suffix, do not mutate the live record.**
   Call the existing stop wrapper to complete and clear the old ownership,
   save the WD residual in `unit.tc0..2`, and enter through the existing start
   wrapper so it publishes a new suffix `(end-residual, residual)` record
   before the hardware arm.

### The remaining hardware-pointer question

The manufacturer's warning matters here: after a phase change, WD Transfer
Count is SCSI-bus progress and can differ from the host DMA controller's count
because FIFO contents are drained/cleared. Action 6 leaves SDMAC running and
does not compare the SDMAC address register with WD progress. The cache record
being self-consistent therefore does not prove the transfer cursor is
self-consistent.

Maintained drivers are more explicit:

- Linux stops host DMA on the WD interrupt, updates the software pointer from
  WD residual, and then services the reported phase.
- NetBSD's data-phase path saves/loads protocol pointers, advances/re-arms DMA,
  programs a new transfer count, and issues Transfer Info.

AMIX cannot copy either sequence blindly because its DFA and wrapper ABI are
different, but both are evidence against assuming that unchanged open-ended
SDMAC state is automatically correct after every phase mismatch.

Before enabling resume, capture and compare:

```text
segment start = dma_seg_pa
segment end   = dma_seg_pa + dma_seg_len
bus progress  = dma_seg_len - WD_TC
host cursor   = device->sac                    (SDMAC offset 0x0c)
```

The host cursor must lie within the recorded interval. Record
`host_cursor - (segment_start + bus_progress)` as a signed delta. A nonzero
delta may represent FIFO skew rather than immediate corruption, but it proves
that a table-only action 6 lacks enough state to justify the continuation.

For the measured read, the minimum accepted tuple is:

- `istate` is `STARTING` or `RESUMING`;
- `curunitp` and `curunitp->comhead` are non-null;
- request `reading != 0`;
- WD `DI.DPD == 1` and the target ID still matches the request;
- CP is `0x41` or `0x45`;
- `0 < WD_TC <= dma_seg_len`;
- `dma_on == 1`, `dma_seg_state == PREPARED`, and `dma_seg_dir == FROM_DEVICE`;
- SDMAC `sac` is inside the owned interval; and
- this request has not consumed its one resume allowance.

Any failed precondition must remain fail-loud in the first implementation.

## Q5: A2091 sibling

The WD protocol diagnosis applies to A2091: its source action 6 is
`a2091.c:307-314`, start/stop are `a2091.c:340-393`, and its linked image has
the same 144-byte `itab`, the same 6x9 `atab`, the same status classification,
and the same action-6 concept. Its current mismatch bytes are also `01 01 01`.

The implementation and DMA proof do **not** transfer unchanged:

- A2091 state is per-card rather than A3091's single global controller state.
- Its DMAC control and stop registers differ.
- Transfers above 16 MiB use a separately allocated chip-RAM bounce buffer.
- `card.tc` retains the armed length and `stopdma` uses it to copy/free the
  bounce buffer; action 6 updates the unit residual but not `card.tc`.
- A2091 action 6 does not rewrite the WD Control register as A3091 does.
- The 040 port's current `dma_seg_*` ownership wrapper covers A3091 only.

Therefore use one shared **WD phase policy** but separate controller-specific
implementations and acceptance. Do not apply an A3091 interposer or three-byte
patch mechanically to A2091. A2091 needs its own bounce-buffer and DMAC cursor
proof first.

## Decisive classification instrument

The current event is deterministic, so one additional fatal capture can close
the largest unknowns. Read the WD registers only after `SS` has already been
acknowledged and before issuing any new command. Latch first, then print a
bounded line because loss of the root controller can make the latch
unreachable.

Required fields:

| Field | Why it is needed |
|---|---|
| `ss`, entry `ISTR`, `istate` | identify event and current DFA state |
| WD `CP` | selects the valid resume set |
| WD `TC[0..2]` | actual SCSI-bus residual |
| WD `DI`, `CON`, `AS` | direction/target, DMA mode, connected/chip state |
| `curunitp`, `comhead`, request `reading`, `addr`, `nbyte`, CDB opcode | request identity and expected transfer |
| SDMAC `sac`, `cntr`, `dma_on` | host DMA direction and current cursor |
| `dma_seg_pa`, `len`, `dir`, `state`, `seq` | port ownership envelope |
| previous request/CP/TC and retry count | detect no-progress recurrence |

Suggested compact output shape:

```text
a3p ss=49 st=1 cp=%x tc=%x di=%x con=%x as=%x
a3p req=%x op=%x rd=%d addr=%x len=%x sac=%x
a3p seg=%x+%x dir=%d state=%d seq=%d delta=%d retry=%d
```

Expected interpretation:

| Capture | Verdict |
|---|---|
| CP `41/45`, TC nonzero, directions agree, cursor plausible | one conditional action-6 experiment is justified |
| CP `46`, TC zero | target overrun / unexpected extra data; do not resume data |
| CP `20/30/3x` | command sequencing problem; do not skip to data |
| DPD/request/segment direction disagree | driver setup corruption or stale nexus; fail-stop |
| cursor outside ownership or large unexplained delta | stop/reconcile/re-arm required before resume |

The classifier should count every `0x48/0x49/0x4a` occurrence even though the
first behavior change handles only `0x49`. That determines whether the other
two are real on this hardware without silently enabling them.

## Conditional behavior specification

Only after the classification tuple passes:

1. Intercept `ss==0x49` at the already-retargeted badhardware wrapper.
2. Assert the complete minimum tuple above.
3. Match/reset retry state by current request pointer and command identity.
4. If this request already resumed once, delegate to stock badhardware.
5. Save current WD TC into `curunitp->tc0..2`.
6. Preserve CP; do not force `0x45`.
7. Program WD Control as stock action 6 does.
8. Store `a3091_istate=RESUMING` before starting hardware.
9. Issue the current `startcom` value.
10. Increment a handled counter and return `RESUMING` to the stock caller.

The first version leaves the same SDMAC arm and full ownership record intact.
If the cursor capture does not justify that, do not implement this version;
design the larger stop/reconcile/re-arm path instead.

Required counters are mutually reconcilable:

```text
pm_seen = pm_resumed + pm_rejected + pm_exhausted
pm_resumed <= one per request in the first implementation
```

Latch CP, TC, cursor delta, request pointer, and rejection reason. A plain
`handled` count is insufficient because it cannot distinguish a validated
resume from a permissive one.

## Acceptance

### Classification gate

1. Verify build ID and all magic words before reading counters.
2. Reproduce with the exact one-block `dd` from the task.
3. Obtain one complete CP/TC/direction/cursor tuple on the console.
4. Check the ownership invariants remain valid; a zero denominator is not a
   pass.
5. Commit the predicted interpretation before enabling behavior.

### Conditional DATA_IN resume

1. `pm_seen >= 1`, `pm_resumed == 1`, and all rejected-precondition counters
   are zero for the intended run.
2. The exact `dd` returns the correct 512 bytes, verified against a known-good
   image or an independent read. Mere success status is not enough.
3. No `a3091: 0x49`, no `DEAD`, and no repeated no-progress mismatch.
4. A subsequent read from a known-good target succeeds on the same boot.
5. DMA prepare/complete counts pair, `owned/noprep/ovf` remain zero, and
   `dma_seg_state` returns to EMPTY.
6. Battery 12/12 and burst 96/96 pass on the same boot.
7. Disk-truth and clean-shutdown/power-cycle checks pass.
8. Run an explicit negative classification test if feasible: an invalid CP or
   exhausted retry must delegate to fail-stop, never report success.

### Deferred classes

- `DATA_OUT` requires scratch-media write, full read-back comparison, and
  filesystem/disk truth before it can be enabled.
- `COMMAND` requires a CDB-progress specification and a dedicated test target.
- A2091 requires separate high-memory bounce and card-local DMA acceptance.

## Answers to the brief

| Question | Static answer |
|---|---|
| What does CP hold after `MIS_1|DATA_IN`? | The WD's last combination-command progress value; it survives for diagnosis. The exact value must be measured for this target. |
| What does reissuing `0x09` do? | While still Connected-as-Initiator, it is a defined Resume and uses CP. It is safe only if CP/TC/direction describe a phase the target is allowed to request. |
| Is `CP=0x45` required? | No, not generally. Preserve a valid `0x41/0x45`; reject incompatible CP rather than forcing `0x45`. |
| Is the three-byte `itab` change sufficient? | No. It cannot validate the tuple, bound retries, distinguish COMMAND, or prove DMA cursor coherence. |
| What retry bound? | One conditional resume per request for the first implementation; any later policy needs strict progress plus a hard cap. |
| Fallback to action 5 or badhardware? | Retain badhardware until a real WD bus-release cleanup exists. Action 5 reports failure but does not disconnect hardware after this `MIS_1`. |
| Should `DATA_OUT` use action 6? | Potentially under the same CP rules, but not without separate media-integrity and DMA proof. Defer it initially. |
| Should `COMMAND` use action 6? | No current proof. It needs CDB phase/progress handling like the maintained references. |
| Adjust `dma_seg_len`? | No. Preserve the full live ownership envelope. Stop/complete it and create a new suffix record if re-arming. |
| Does A2091 get the same fix? | Same WD policy, separate implementation. Its DMAC, card state, and high-memory bounce lifecycle make mechanical reuse unsafe. |

## External references

- Western Digital, *WD33C93A SCSI Bus Interface Controller*, WD2088S 9/88,
  sections 6.2.14, 6.2.16, 6.2.17, 7.4.2, and 7.6.1:
  <https://bitsavers.trailing-edge.com/components/westernDigital/_dataSheets/WD33C93A.pdf>
- NetBSD WD/SBIC driver, especially `sbicnextstate` command/data handling:
  <https://github.com/NetBSD/src/blob/trunk/sys/arch/amiga/dev/sbic.c>
- Linux WD33C93 core, especially `transfer_bytes` and unexpected phase cases:
  <https://github.com/torvalds/linux/blob/master/drivers/scsi/wd33c93.c>

The manufacturer document is authoritative for CP, TC, command-state, and
resume semantics. NetBSD and Linux are implementation references: they do not
define the chip, but their independent choice to stop/reconcile DMA and handle
COMMAND separately is relevant evidence against the unconditional table edit.
