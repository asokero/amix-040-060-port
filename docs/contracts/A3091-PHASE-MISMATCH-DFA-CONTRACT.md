# ISSUE-54 contract — an unrecognised WD status must not be permanent death

Written 2026-08-29, before any fix, from `build/unix-040` (`68040-260829-05`). Every address
and table value below was read out of the image; the "inferred" and "unknown" sections say
plainly which claims were not.

This is a contract, not a patch. ISSUE-43 cost two failed fix attempts on this same driver
family, and both failed for the same reason: *the meaning was inferred from the shape of the
code.* So the deliverable here is the measurement plus the questions that must be answered
before a byte moves.

## 1. The dispatch, read out of the image

`a3091intr` at `.text+0xd0e0`. Relocations name the tables; symbol indices resolve them (there
are **two** `itab`/`atab` pairs in the image — the other belongs to `a2091`):

| what | where | size |
|---|---|---|
| `itab` (status → input class) | `.data+0x3890`, reloc at `.text+0xd124`, symbol 460 | 144 bytes |
| `atab` (state × input → action) | `.data+0x3920`, reloc at `.text+0xd134`, symbol 461 | 54 bytes = **6 states × 9 inputs** |

```
d104  jsr cipwait
d10e  jsr reg(0x17)                 ; 0x17 = SCSI Status; d2 = ss
d118  moveal istate,%a0
d11e  lea %a0@(0,%a0:l:8),%a0       ; a0 = istate * 9        <- row stride 9
d122  lea itab,%a1
d12c  moveb %a1@(0,%d2:l),%fp@(-1)  ; input = itab[ss]
d132  addal #atab,%a0
d13e  moveb %a0@(0,%d3:l),%d0       ; action = atab[9*istate + input]
d144  cmpl #9,%d0
d146  bhiw d3fe                     ; action > 9 -> RETURN, doing nothing
d152  jmp pc@(table,%d3:w)
```

Note `bhiw`: an action value of 10 or more makes the handler return without touching anything.
A silent do-nothing path already exists in the stock dispatcher. Section 4 says why that is not
the fix.

## 2. `atab`, and the one cell this issue is about

```
             in0  in1  in2  in3  in4  in5  in6  in7  in8
  0 IDLE       1    1    1    1    3    1    1    1    1
  1 STARTING   5    1    6    7    2    8    1    9    0
  2 st2        1    1    6    7    1    8    1    9    0
  3 DEAD       1    1    1    1    1    1    1    1    1
  4 st4        1    1    1    1    1    1    4    1    1
  5 st5        1    1    1    1    1    1    1    1    0
```

**`DEAD` is state 3, not the last row.** `badhardware()` (`.text+0xd666`) prints
`a3091: 0x%x %d 0x%x` and returns the literal **3**; row 3 maps every input to action 1, which
calls `badhardware()` again. That is the absorbing state, and it matches the field capture:
`istate=1` at the kill, `istate=3` on the next interrupt.

`itab` is a default table. **136 of its 144 entries are input class 1.** Exactly eight statuses
are recognised:

| status | input | |
|---|---|---|
| `0x16` | 8 | completed |
| `0x20` | 6 | |
| `0x21` | 2 | |
| `0x42` | 0 | no such target |
| `0x4B` | 7 | |
| `0x4F` | 5 | |
| `0x81` | 4 | |
| `0x85` | 3 | disconnect |

`0x49` — the phase mismatch of ISSUE-54 — is not among them, so `itab[0x49] = 1`, and
`atab[STARTING][1] = 1` → `badhardware()` → `DEAD`.

## 3. The driver already owns a graceful path, and it is one cell away

`atab[STARTING][0] = 5`, taken for `0x42` (absent target). Action 5 at `.text+0xd2cc`:

```
jsr dma_a3091_stopdma          ; stop DMA
moveal curunitp,%a3
moveal %a3@(4),%a2             ; a2 = curunitp->comhead
movel  %a2@,%d0
movel  %d0,%a3@(4)             ; dequeue the head request
beq    +                       ; if more remain,
  jsr  uqueue                  ;   requeue the unit
+ movel %a2,%sp@-
moveal %a2@(36),%a0
jsr    %a0@                    ; call the request's completion callback
braw   d34e
```

and the common exit `d34e` is `istate = 0 (IDLE); startany()`.

So the sequence DMA-stop → dequeue → complete → IDLE → start-next exists, is reached today for
an absent target, and is one table byte away from the phase-mismatch path. That is why this
issue looks trivially fixable, and section 4 is why it is not.

## 4. Why the obvious change is wrong, measured rather than argued

**Action 5 completes the request without reporting anything.** Compare action 0, the normal
completion at `.text+0xd16e`:

```
jsr reg(0x10)                  ; CMD_PHASE
cmpl #0x60,%d0
bne  +
  moveb #1,%a2@(5)             ; request+5  = 1
  jsr  reg(0x0f)               ; TLUN
  moveb %d0,%a2@(6)            ; request+6  = SCSI status byte
+ ...dequeue, complete, IDLE, startany
```

Action 0 writes `request+5` and `request+6`. **Action 5 writes neither.** The caller therefore
sees a completion carrying no status and no error. This is consistent with the field
observation that reading an absent target "returned zero records" rather than an error.

For an absent target, a short read is defensible. For a phase mismatch **mid-transfer, with
`segstate=2` and 512 bytes genuinely armed**, completing the request with no error is silent
data loss dressed as success — the exact failure class as ISSUE-51, which this project already
treats as more serious than a crash. Trading a visible wedge for a silent wrong answer is not
an improvement, and this contract does not propose it.

**And the change would not be narrow.** Input class 1 is the default for 136 statuses, so
editing `atab[STARTING][1]` changes behaviour for **every** unrecognised status at `STARTING`,
including ones where stopping really is right. Editing `itab[0x49]` instead is narrower —
one status — but it changes that status's class in all six states, not only `STARTING`.

**The do-nothing path is worse.** Setting an action ≥ 10 makes `bhiw` return with DMA still
running, the request still on `comhead`, and `istate` still `STARTING`, so the transfer never
completes and never fails. A hang instead of a wedge.

## 5. What the statuses actually are — decoded against NetBSD's own Amiga driver

`usr/src/sys/arch/amiga/dev/sbicreg.h` and `sbicvar.h` from the pinned NetBSD 10.1 tarball
(`DATA_OUT=0`, `DATA_IN=1`, `CMD=2`, `STATUS=3`, `MESG_IN=7`; `SBIC_CSR_MIS_1 = 0x48`). All
eight statuses `a3091.c` recognises, and the neighbours it does not:

| status | input | decode | |
|---|---|---|---|
| `0x16` | 8 | `S_XFERRED` | select-and-transfer complete |
| `0x20` | 6 | `CMD_STOPPED` | |
| `0x21` | 2 | `SDP` | save data pointers |
| `0x42` | 0 | `SEL_TIMEO` | selection timeout — the graceful abort |
| `0x48` | **1** | `MIS_1 \| DATA_OUT_PHASE` | **DEAD** |
| `0x49` | **1** | `MIS_1 \| DATA_IN_PHASE` | **DEAD — this issue** |
| `0x4A` | **1** | `MIS_1 \| CMD_PHASE` | **DEAD** |
| `0x4B` | 7 | `MIS_1 \| STATUS_PHASE` | handled, action 9 |
| `0x4F` | 5 | `MIS_1 \| MESG_IN_PHASE` | handled, action 8 |
| `0x81` | 4 | `RSLT_IFY` | |
| `0x85` | 3 | `DISC_1` | disconnect |

**The shape of the defect is now exact.** `a3091.c` handles a phase mismatch when the new phase
is `STATUS` or `MESG_IN` — that is, when the command is effectively over — and kills the driver
when the new phase is `DATA_OUT`, `DATA_IN` or `CMD`, which are the phases that mean *there is
more transfer to do*. It is not that the driver has no phase-mismatch handling. It has handling
for exactly the mismatches that need none.

This also explains why ordinary disk I/O never trips it: a transfer that completes normally
reports `S_XFERRED` and moves to `STATUS`, so the fatal statuses only appear when a target
interrupts a data phase — which is what target 3 does and what `dd` on `c3d0s0` provokes.

The ledger's decode of `0x49` as "a phase mismatch" was right but incomplete: the phase is
`DATA_IN`, and the capture's `segdir=1` (from device) agrees with it independently.

## 6. Two unknowns are now answered, and they change the fix

**Is a reset or message-out needed first? No.** NetBSD's `sbicnextstate` puts
`SBIC_CSR_MIS_1|DATA_IN_PHASE` in the *same case arm* as `SBIC_CSR_XFERRED|DATA_IN_PHASE`, a
successful transfer, and its response is to continue the data transfer for the residual count.
The bus is not in trouble; the target is still connected and expects the transfer to go on.
`0x49` is not an error status.

**What is action 9?** NetBSD writes the identical register sequence under the comment *"have
the sbic complete on its own"*: transfer count zero, `CMD_PHASE = 0x46`, then
`SBIC_CMD_SEL_ATN_XFER`. Action 9 does exactly that — `setreg(0x12/0x13/0x14, 0)`,
`setreg(0x10, 0x46)`, `setreg(0x01, 0x8c)` (`CTL_DMA|CTL_EDI|CTL_IDI`, an ordinary operating
configuration, not a reset), `setreg(0x18, cmd)` — and then sets `istate = 5`. It is a
**hand-the-rest-to-the-chip** sequence, which is why `0x4B` (mismatch into `STATUS`) uses it.

So the fix candidate is no longer action 5. **Route the fatal MIS_1 phases to action 9.**

Its merit over action 5 is that it reaches a *real completion*. Action 9 leaves `istate = 5`;
`atab[5][8] = 0`, and input 8 is `S_XFERRED`, so when the chip finishes the command the driver
takes **action 0** — the normal completion, the one that writes `request+5` and `request+6`
with a genuine SCSI status byte. Action 5 could never do that.

## 6a. What is still unknown, and blocks implementation

1. **Zeroing the transfer count discards the residual.** The chip completes the *command*, not
   the data. Whether the caller then sees a short read or an error depends on the status byte
   the target returns and on how `request+5`/`+6` are consumed. If a target can return GOOD
   here, this trades a wedge for a silent short read — the ISSUE-51 class this project treats
   as worse than a crash. **This must be settled before the change is made.**
2. **Action 9 never stops DMA.** It contains no `dma_a3091_stopdma` call, so on this path a
   transfer armed by our own hook (`segstate=2`, `dmaon=1` in the capture) stays armed while the
   chip completes on its own. For `0x4B` the data phase is already over, so nothing is in
   flight; for `0x49` it is not. Whether the SDMAC engine must be stopped first is unknown and
   is the difference between the case action 9 was written for and the case we would give it.
3. **Which `request+N` fields signal failure.** `+5` and `+6` are written by action 0; that they
   are "status valid" and "SCSI status" is inferred from position and from `reg(0x0f)` being
   `TLUN`. The struct is not in the tree.
4. **`0x48` and `0x4A` are the same defect** and should be fixed in the same change, but neither
   has been observed. Fixing only the status we have seen leaves two known-fatal cells.

## 6b. Shape of the fix

If 6a.1 and 6a.2 come out clean, this may genuinely be a table change: `itab[0x48]`, `itab[0x49]`
and `itab[0x4A]` from 1 to 7. That is narrower than touching `atab`, because it moves three
named statuses rather than the default class shared by 136.

If either comes out dirty it needs an interposer in the shape of `src/a3091demux040.s`: retarget
a relocation, leave the stock C body alone, stop DMA if 6a.2 requires it, mark the request short
or failed per 6a.3, and reach the existing `istate = IDLE; startany()` exit rather than inventing
one. Anything that cannot mark the request correctly should do nothing and let the driver die
visibly.

## 7. Instrument, written before the fix

A counter block `a3p` with magic `"A3P!"`, in `.data`, magic first:

| counter | meaning |
|---|---|
| `a3p_magic` | `"A3P!"`, static |
| `a3p_calls` | every entry — the denominator |
| `a3p_passthru` | status/state pair not ours; delegated |
| `a3p_handled` | the phase-mismatch path taken |
| `a3p_err_set` | request marked failed |
| `a3p_nounit` | `curunitp` or `comhead` NULL — **must stay 0** |
| `a3p_badstate` | our status seen in an unexpected state — **must stay 0** |
| `a3p_dead_istr` | printed, not latched: the wedge takes the root disk with it |

`a3p_dead_istr` is printed rather than latched deliberately. Latching the most valuable datum
of the ISSUE-53 wrapper cost a capture, because the wedge removes the root disk and kernel
memory cannot be read afterwards — `a3091dbg040.s`'s own header had said so before the wrapper
was written.

## 8. Acceptance

Unlike ISSUE-53, this one is **orderable**, which is the whole reason to prefer it:
`dd if=/dev/rdsk/c3d0s0 of=/dev/null bs=512 count=1` reproduces it every time. So the fix can
be *proved*, not merely shipped.

1. Predictions written and committed **before** the run.
2. If the fix is the table change, the instrument is still built and read: `a3p_handled ≥ 1`
   and `a3p_calls > a3p_handled`, so it is known the new path fired and the old one still
   delegates. A table change with no counter is a change nobody can attribute.
3. `a3p_nounit == a3p_badstate == 0`.
4. **`dd` must not report success it did not have.** Either an error, or a byte count the caller
   can see is short. A completion reporting GOOD for data that was never transferred fails this
   acceptance outright — that is 6a.1, and it is the one outcome worse than the present wedge.
5. `a3091: 0x49 ...` no longer appears and `istate` never reaches 3. The absence of
   `badhardware()` output is the direct evidence the fatal cell was not taken.
6. The machine survives, and a second `dd` against a *good* target succeeds afterwards — this
   is what proves the bus was left usable, and it is the criterion 6.1 exists for.
7. Battery 12/12 and burst 96/96 on the same boot, so the fix is not paid for elsewhere.
8. `a3w_*` from the ISSUE-53 wrapper unchanged in character: this must not disturb it.
9. `dma_*` self-consistent after the run — `prep_to + prep_from == cmpl_to + cmpl_from`, and
   `owned`/`noprep`/`ovf` still zero. This is the check that would catch 6a.2 going wrong,
   since a transfer left armed across the chip's own completion shows up there.

## 9. Explicitly out of scope

Full controller recovery from `DEAD`. The ISSUE-53 audit §Q4 lists the six things a real reset
path owes and concludes that calling `initialize()` again or writing `istate = IDLE` performs a
fraction of the contract. Nothing here changes that. This issue is about **not reaching `DEAD`
for a status that is not a hardware failure** — it is not a recovery mechanism.
