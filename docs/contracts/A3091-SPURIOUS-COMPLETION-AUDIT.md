# A3091 Spurious-Completion and Interrupt-Source Audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/A3091-SPURIOUS-COMPLETION-AUDIT.md` (private workspace,
> imported 2026-08-27). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/a3091demux040.s` and
> `src/patch_a3091_intr.py` implement the "Atomic source-demultiplex wrapper" section
> and the measurement contract below, as ISSUE-53. Built into
> `68040/68060-260827-05`; **not yet run on either platform.** The unit ships in the
> contract configuration (`a3w_consume = 1`, pure `E_INT` consumed); the audit's
> classification build is the same image with that longword poked to 0.

Date: 2026-08-27

## Scope

This review answers `private/A3091-SPURIOUS-COMPLETION-CODEX-TASK.md` from the
port repository. It audits the WD33C93A and SDMAC interrupt contract, compares
the AMIX A2090, A2091, and A3091 drivers, tests whether `atab[IDLE][8]` can be
made harmless, and specifies a measurable change that fits the port's
relocation-retarget model.

No kernel code is changed here. The four hardware captures are **reported
runtime evidence** from the task brief and its cited records, not runs made
during this review.

## Pinned inputs

| Input | Identity |
|---|---|
| Stock kernel SHA-256 | not used: this audit concerns the currently linked port image and the AMIX-shipped driver objects |
| AMIX object SHA-256 | `a2090.o` `2f6aa5c50499a35d82130727f7407db23532127fc3d737d389c55c5501591af5`; `a2091.o` `30fc152c52c504092288f6bbeb3554b944750ad3c59459cbba64e31e302930f5`; `a3091.o` `3ea9e3dd37725c3d1717b85683ecf9974f99f00596cccdaec70cc282ec2f5a8a` |
| Port commit | `081be0700430936a4e3a28752eddde6e2df95c25` |
| Port image SHA-256 | `build/unix-040` `4b487305a3da04b3ed244dd44bc69c87fe6709f3bd00badb30319de7f1fb9285`; diagnostic companion `build/unix-040-dbg` `c050e9afb967555d0e67432c6f76c940d83b4d37dcf1ba830a3ec3fc5b8283ea` |
| Reference source identity | task brief `7d5809b526771c88d6cfd29fd5c2ad8a483d0517fb24b7d820eac174808427d6`; AMIX `a2090.c` `21ccb31cbf8153f70279c0b602a6db447398b879fd5944fccceac724664f316f`, `a2091.c` `c7f2bdd40a072da84807abdad7fbcbf81a8f953ed352b8a325a1c336d19cbe7d`, `a3091.c` `145a313b20364d1acd32cff2d15ccfe13f87c0eade5ff3246b2d031e1a4df53a`; Western Digital WD33C93A data sheet, WD2088S 9/88; NetBSD trunk `ahsc.c` `babfa83afbf5ea4800266ffe1e6f65c2604af870e230765a3be4ba10cd19068e`, `ahscreg.h` `455c660d272ad71acc791b19803ab7b8a050be44187f93ee2ba863dfb918fc33`, `sbic.c` `1cf7ae87ed9c7d90ca753529c504b54e2ce22c1e9b3ebc7652ee52332bf0e6d8`; Linux master `a3000.c` `4a92544a5c231b4c0bc79291b3bfddda71b0e07866feffd684bb75d334cef370`, `wd33c93.c` `5036bc56261bfe374d4a9d855010079fef337c32cf272648c5410cfcc6d22e96`, all retrieved 2026-08-27 |
| Address domains | All code and data addresses below are linked ELF section-relative symbol values in `build/unix-040`; `.text` and `.data` each have ELF address zero. They are not runtime VAs. Relocation offsets name the target section's offset. Device offsets are byte offsets from the A3000 SDMAC register base. |
| Evidence commands | `sha256sum`; `readelf -sW/-rW`; `m68k-linux-gnu-objdump -dr/-s`; source line inspection with `nl` and `grep` |

The current linked image was checked separately from the shipped source. This
document does not claim that equal source structure alone proves byte
identity. The relevant branch, register offsets, calls, and relocations were
confirmed in the linked image.

## Executive verdict

1. **The A3091 interrupt gate is too broad.** At `0xd0f8..0xd100` it reads
   SDMAC `ISTR`, tests bit 4 (`INT_P`), and then unconditionally reads the
   WD33C93A SCSI Status register at `0xd10e`. `INT_P` is an aggregate pending
   bit: it can be caused by the WD SCSI interrupt (`INTS`), SDMAC end-of-process
   (`E_INT`), FIFO errors, or another enabled source. It does not mean that WD
   status is valid.
2. **The strongest static root-cause candidate is an `E_INT`-only SDMAC
   interrupt admitted as a WD interrupt.** A FLUSH completion can assert
   `E_INT`, hence `INT_P`, even when no DMA is currently owned. The handler then
   reads and dispatches WD `SS` without first proving WD `ASR.INT` or SDMAC
   `ISTR.INTS`.
3. **`0x16` is consistent with stale or otherwise non-current WD status, but
   the data sheet does not define the post-acknowledgement value.** It guarantees
   that SCSI Status is stable until it is read or the chip is reset. It does
   not promise that a later read without `ASR.INT` returns either zero or the
   old value. Therefore the four captures do not prove that a new Select-And-
   Transfer completion occurred.
4. **The existing `a3d_istr` sample is taken too late to classify the source.**
   `a3091intr` has already read `SS`, which clears WD `INTRQ`, before the
   `badhardware` interposer reads `ISTR`. A surviving `E_INT` bit would be
   decisive evidence for the candidate; absence of `INTS` would not be.
5. **Do not change `atab[IDLE][8]` to a no-op.** `starthead == 0` and
   `dma_on == 0` do not prove that the SCSI request set is empty. A temporarily
   disconnected request remains on a unit's `comhead` while the driver returns
   to `IDLE` and waits for reselection. A genuine WD `0x16` in that state is an
   invariant violation, and silently ignoring it can strand a request.
6. **The minimum safe unit is interrupt-source demultiplexing before `SS` is
   read.** Retarget the `int2_tbl` relocation at `.data+0x9998` from stock
   `a3091intr` to a small wrapper. Consume a pure `E_INT` with SDMAC `CINT` and
   delegate actual `INTS` events to the stock handler. Preserve fail-loud
   behavior for error or unclassified combinations.
7. **There is no AMIX recovery path from `DEAD`.** A real reset/recovery path
   is a much larger unit: it must reset and reprogram the controller and settle
   every active, queued, and disconnected request. It is not a safe one-byte
   DFA edit.

## Q1: chip contract

### WD33C93A acknowledgement and status lifetime

The WD33C93A contract is unambiguous up to the first status read:

- Auxiliary Status `INT` means the chip's `INTRQ` pin is asserted.
- Reading SCSI Status (`SS`, register `0x17`) clears `INTRQ`; the data sheet
  specifically requires this acknowledgement before issuing another command.
- SCSI Status describes the cause of the most recent WD interrupt and remains
  unchanged only until status is read or the WD is reset.
- `SS=0x16` is a successful Select-And-Transfer completion and is valid in the
  documented disconnected or initiator states.

The data sheet does **not** specify a defined value for a subsequent `SS` read
when `ASR.INT` is clear. Consequently:

| Observation | Static interpretation |
|---|---|
| entry `ISTR.INTS=1`, WD `ASR.INT=1`, then `SS=0x16` | genuine WD completion |
| entry `ISTR.INTS=0`, `ISTR.E_INT=1`, then `SS=0x16` | status was read without a current WD interrupt; its value is not an event |
| post-`SS` `ISTR.INTS=0` | ambiguous, because the `SS` read itself deasserts WD `INTRQ` |

Thus `SS` is the WD acknowledgement. SDMAC `CINT` cannot substitute for
reading `SS` while the external WD source remains asserted.

### SDMAC source bits

The SDMAC register definitions used independently by NetBSD and Linux classify
`ISTR` as follows:

| Bit | Name | Meaning relevant here |
|---:|---|---|
| 6 | `INTS` | external SCSI peripheral, the WD33C93A |
| 5 | `E_INT` | end of process: terminal count or FLUSH completion |
| 4 | `INT_P` | aggregate pending indication when interrupts are enabled |
| 3 | `UE_INT` | FIFO underrun |
| 2 | `OE_INT` | FIFO overrun |
| 0 | `FE_FLG` | FIFO empty status; not an interrupt-source identity |

The reproduced SDMAC specification says that `CINT` clears the SDMAC's
latched interrupt conditions and its internally generated system interrupt,
but does not cancel an external peripheral source that is still asserted.
`SP_DMA` at register offset `0x3c` stops DMA without changing register contents
and does not generate an interrupt. AMIX calls this field `srst`, but its source
comment and linked offset `0x3e` identify the word-lane strobe as **stop DMA**,
not SCSI reset.

This corrects the standing hypothesis in one important way: current code
already proves bit 4 was set at handler entry. The linked path cannot reach
`badhardware` otherwise. What remains unknown is **which source made aggregate
bit 4 true**.

### Can `INT_P` occur with no host command armed?

Yes. `E_INT`, underrun, and overrun are SDMAC sources independent of WD command
ownership and can assert aggregate `INT_P`. The WD can also interrupt for reset,
bus phase, error, and reselection conditions rather than only normal command
completion. Moreover, an AMIX request may be disconnected and awaiting
reselection while `dma_on == 0`.

In this A3091 configuration `startdma` writes SDMAC control values `0x0c` or
`0x0e` at `0xd486`/`0xd496`. Both leave terminal-count enable (bit 5) clear.
An `E_INT` observed here should therefore be classified as FLUSH completion,
not normal terminal-count completion, unless some other writer changes the
control register.

The exact four-capture mechanism remains a hypothesis until entry `ISTR` is
recorded. The evidence supports this ranking:

1. **Most likely:** pure SDMAC `E_INT`; current code mistakes it for WD status.
2. **Possible:** genuine WD interrupt whose DFA state no longer represents the
   outstanding disconnected command.
3. **Possible but less specific:** SDMAC FIFO error or another aggregate source.
4. **Refuted by linked control flow:** entry without SDMAC `INT_P` bit 4.

### `stopdma` ordering

The current linked A3091 sequence is:

| Address | Operation |
|---:|---|
| `0xd4e0` | FLUSH strobe at device offset `0x16` |
| `0xd4ec..0xd4f4` | wait for `ISTR.FE_FLG` bit 0 |
| `0xd4fe` | `CINT` strobe at offset `0x1a` |
| `0xd504` | `SP_DMA` strobe at offset `0x3e` |
| `0xd50a` | clear software `dma_on` |

NetBSD's A3000 driver uses the same FLUSH, FIFO-empty wait, CINT, SP_DMA order.
Linux also uses that order and temporarily disables SCSI interrupts around the
stop operation before restoring the control word. This is enough to reject a
claim that AMIX's order is plainly reversed.

There is still a reviewable window: FLUSH completion is represented by
`E_INT`, while AMIX waits only for the FIFO-empty flag and leaves interrupt
enable active. A late or unconsumed `E_INT` is plausible. The safer conclusion
is not to redesign `stopdma` first, but to demultiplex sources as the maintained
drivers do. Entry-source counters will then say whether a stop-order change is
needed at all.

## Q2: sibling-driver comparison

| Property | A2090 | A2091 | A3091 |
|---|---|---|---|
| DMA/controller family | older, different DMA interface | WD33C93 + board DMAC | WD33C93A + A3000 SDMAC |
| Entry source test | none comparable; reads WD status | tests aggregate DMAC bit 4 | tests aggregate SDMAC bit 4 at `0xd0fc` |
| `itab`/`atab` DFA | no | same tables as A3091 | yes |
| `IDLE + input 8` | not applicable | action 1 -> `DEAD` | action 1 -> `DEAD` |
| Empty request queue after status read | returns | not a separately tolerated path | not a separately tolerated path |
| `0x16` handling | explicit no-op | DFA completion or `DEAD`, depending on state | DFA completion or `DEAD`, depending on state |
| Stop sequence | controller-specific | FLUSH, wait empty, clear interrupt, stop DMA | FLUSH, wait empty, CINT, stop DMA |
| `badhardware` recovery | no permanent `DEAD` state | prints and returns `DEAD` | prints and returns `DEAD` |

The A2091 is not a recovery precedent. It has the same aggregate-bit gate, the
same DFA, and the same permanent shutdown behavior. It therefore appears to
carry the same source-demultiplexing defect.

The A2090 is useful only as evidence that Commodore once chose to tolerate a
completion after its own queue was empty. It is not proof that this is safe on
the later disconnect/reselect DFA: it uses different DMA hardware and has no
equivalent persistent disconnected-command state.

Maintained A3000 implementations provide the stronger comparison:

- NetBSD reads SDMAC `ISTR`, clears `E_INT` with `CINT`, and calls the WD/SBIC
  handler only when `ISTR.INTS` is set. The SBIC handler then checks WD
  Auxiliary Status `INT` before reading SCSI status.
- Linux admits the shared interrupt on `INT_P`, but calls `wd33c93_intr` only
  when `INTS` is present. Its WD handler also verifies `ASR.INT` before reading
  status.

Both independently place the missing boundary between SDMAC source
classification and WD status consumption.

## Q3: why a DFA no-op is unsafe

The task brief's measured fields prove that no request was in the **start
queue**, no DMA transfer was armed, and the port owned no cache/DMA segment at
the capture. They do not prove that the driver's SCSI request set was empty.

On A3091 action 7, a target's temporary disconnect does this:

1. stops DMA;
2. leaves the request at the unit's `comhead`;
3. changes `istate` to `IDLE`; and
4. calls `startany` so another target can run.

The disconnected request is expected to return through input 4 (reselection),
which `atab[IDLE][4]` handles. `starthead` tracks units ready to start, not all
unit `comhead` requests. `curunitp` is retained and is not an ownership token.

If a genuine WD `0x16` reaches `IDLE`, action 0 would dereference
`curunitp->comhead`, update queue links, and call a completion callback. With
the wrong current unit this can corrupt or complete the wrong request. Action
1 is therefore a fail-stop guard against a state/status mismatch. Replacing it
with a no-op avoids the wedge but can leave a genuine completed request
permanently stranded and hide the controller-state loss.

**Verdict:** ignore only a source proven not to be WD, such as pure SDMAC
`E_INT`. Do not ignore `SS=0x16` after it has already been read.

## Q4: recovery reachability

AMIX has no path from `DEAD` back to `IDLE`. `initialize()` is one-shot boot
setup, `badhardware()` only prints and returns `DEAD`, the `DEAD` DFA row maps
every input back to action 1, and `startany()` requires `IDLE`.

A complete recovery path would need to:

1. stop DMA and mask/acknowledge each identified SDMAC and WD source;
2. reset the WD and consume its reset interrupt;
3. restore own ID, timeout, control, synchronous-transfer and reselection
   configuration;
4. determine the fate of the connected, selecting, queued, and disconnected
   requests across all units;
5. complete or retry each request exactly once; and
6. return the DFA and DMA ownership state to one coherent `IDLE` state.

Linux exposes a host-reset error-handler for this reason. Calling AMIX
`initialize()` again or writing `istate=IDLE` would perform only a fraction of
the contract and is unsafe. Source demultiplexing avoids invoking such a reset
for a harmless SDMAC-only event; full recovery can remain a separate later
milestone.

## Implementation specification

### Rejected minimal patches

- **Do not patch `atab[IDLE][8]` from 1 to a no-op.** The status has already
  been consumed and may represent a genuine outstanding request.
- **Do not change `btst #4` to `btst #6`.** That would stop the WD handler from
  misreading SDMAC events, but it would leave pure `E_INT` unacknowledged and
  can produce a level-2 interrupt storm.
- **Do not reinterpret `srst` as reset.** It is the `SP_DMA` stop strobe and
  cannot recover WD protocol state.

### Atomic source-demultiplex wrapper

Retarget the existing interrupt-vector relocation rather than modifying the
stock C body:

| Assertion | Pinned value |
|---|---|
| table symbol | `int2_tbl`, `.data+0x998c`, size 24 |
| relocation slot | `.rela.data` `r_offset=0x9998` |
| relocation type | `R_68K_32` |
| current target | `a3091intr`, `.text+0xd0e0` |
| raw relocated word in ET_REL | `00 00 00 00`; identity is the relocation, not these placeholder bytes |

The patcher should assert all five properties and retarget only that relocation
to a new wrapper symbol. The stock `a3091intr` remains callable by name; no
global weakening or body replacement is required.

Wrapper policy, based on its **single entry snapshot** of device `ISTR`:

1. If `INT_P` is clear, count `not_ours` and return exactly as stock does.
2. If `INTS` is set, call stock `a3091intr`. Afterwards re-read `ISTR` and issue
   `CINT` if a residual `E_INT` remains. This handles simultaneous WD and DMA
   sources without acknowledging WD by accident.
3. If `INTS` is clear and the only interrupt source is `E_INT`, issue SDMAC
   `CINT`, count it, and return without reading WD `SS` or changing the DFA.
4. If underrun, overrun, `INTX`, or an unclassified `INT_P` combination is
   present, count and report it loudly. Preserve current fail-stop behavior
   until that source has a specific recovery contract; do not silently swallow
   it as an ordinary `E_INT`.

Before implementation, verify whether the shared level-2 dispatcher requires
a particular return value. The stock A3091 function is C `void`; the wrapper
must preserve its calling convention and all callee-saved registers.

### Why the current diagnostic cannot replace the wrapper

The linked order is:

1. `ISTR` aggregate gate at `0xd0f8..0xd100`;
2. WD `SS` read at `0xd10e`;
3. DFA dispatch; and
4. `a3091_badhardware_dbg` through relocation `0xd3a6`.

`a3d_istr` is read in step 4. If it captures `E_INT=1`, that strongly supports
the proposed mechanism. If it captures `INTS=0`, it says nothing about entry
`INTS`, because step 2 cleared WD `INTRQ`. Entry classification must happen
before step 2.

## Measurement contract

Use mutually exclusive buckets so the denominator proves that the instrument
ran and the classifications reconcile:

| Counter/latch | Required meaning |
|---|---|
| `irq_calls` | every invocation from `int2_tbl` |
| `not_ours` | entry `INT_P=0` |
| `own_irqs` | entry `INT_P=1` |
| `ints_only` | `INTS=1`, `E_INT=0`, no error source |
| `eint_only` | `INTS=0`, `E_INT=1`, no error source |
| `ints_eint` | both source bits set, no error source |
| `other_source` | underrun, overrun, `INTX`, or otherwise unclassified |
| `eint_acked` | pure or residual `E_INT` events actually acknowledged by wrapper |
| `last_istr` | unmodified entry snapshot for the last `own_irqs` event |
| existing `a3d_n` | stock DFA still reached `DEAD` |

Required invariants:

```text
irq_calls = not_ours + own_irqs
own_irqs  = ints_only + eint_only + ints_eint + other_source
eint_acked >= eint_only
```

`dma_seg_seq` or the existing A3091 prepare/complete denominator must also
advance during the workload. Otherwise `eint_only == 0` is an unexercised
result, not evidence of absence.

### Two useful runtime stages

1. **Classification build:** snapshot entry `ISTR`, update buckets, then
   delegate all `INT_P` events unchanged. One wedge classifies the source
   without changing behavior. This is the strictest attribution test but costs
   another power cycle if the event recurs.
2. **Contract build:** consume only pure `E_INT`, delegate WD and unknown/error
   sources, and retain the same counters. This tests the maintained-driver
   contract and can survive the candidate event.

The contract build closes the candidate mechanism only if all of these hold:

- magic/address checks pass and both interrupt and DMA denominators advance;
- `eint_only > 0` and `eint_acked == eint_only`;
- `a3d_n == 0`, `other_source == 0`, and no interrupt storm occurs;
- ordinary `ints_only` traffic remains nonzero and disk operations progress;
- the project's A3091 disk-truth checks remain byte-exact; and
- a clean shutdown or power-cut protocol finds no new filesystem damage.

If the next wedge has entry `INTS=1` and no `E_INT`, the SDMAC-only hypothesis
is refuted for that occurrence. The next instrument must then snapshot WD
`ASR`, DFA state, and per-unit `comhead` ownership **before** reading `SS`.

## Final answers to the brief

| Question | Answer |
|---|---|
| What clears WD interrupt? | Reading WD SCSI Status. SDMAC `CINT` does not replace this while WD's external request remains asserted. |
| Can aggregate `ISTR` bit 4 be set with no DMA command armed? | Yes. It represents multiple enabled sources, including SDMAC `E_INT` and FIFO errors. |
| Is `SS=0x16` definitely stale? | No. It is plausible but the post-read/no-interrupt value is unspecified. Entry `INTS` or WD `ASR.INT` must classify it. |
| Is `CINT -> SP_DMA -> dma_on=0` reversed? | No evidence says so; NetBSD and Linux use the same basic stop order. Missing source demultiplexing is the demonstrated contract defect. |
| Do siblings recover? | A2091 has the same permanent DFA shutdown. A2090 tolerates `0x16` but is a different controller design and not a safe template. |
| Can `IDLE + empty starthead + dma_on=0` ignore completion? | Not if it is a genuine WD event; a disconnected request can still be alive. Only a proven non-WD source is safely ignorable. |
| Is there an AMIX reset/recovery helper? | No complete reachable path. Adding one is much larger than this fix. |
| Recommended minimum change | Retarget `int2_tbl` to a source-demultiplex wrapper; acknowledge pure `E_INT`, delegate `INTS`, count every mutually exclusive class. |

## External references

- Western Digital, *WD33C93A SCSI Bus Interface Controller* data sheet,
  WD2088S 9/88: <https://bitsavers.trailing-edge.com/components/westernDigital/_dataSheets/WD33C93A.pdf>
- NetBSD A3000 SDMAC driver and WD/SBIC core:
  <https://github.com/NetBSD/src/blob/trunk/sys/arch/amiga/dev/ahsc.c>,
  <https://github.com/NetBSD/src/blob/trunk/sys/arch/amiga/dev/ahscreg.h>,
  <https://github.com/NetBSD/src/blob/trunk/sys/arch/amiga/dev/sbic.c>
- Linux A3000 and WD33C93 drivers:
  <https://github.com/torvalds/linux/blob/master/drivers/scsi/a3000.c>,
  <https://github.com/torvalds/linux/blob/master/drivers/scsi/wd33c93.c>
- SDMAC register-specification transcription used only for the unavailable
  original gate-array specification wording:
  <https://github.com/mbtaylor1982/ReSDMAC/blob/main/Docs/SDMAC.md>

The maintained operating-system sources independently corroborate the source
separation on which the recommendation depends. The SDMAC transcription is
not treated as manufacturer-primary evidence by itself.
