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

## 5. What is not known, and must be before implementing

1. **Does the WD need a reset or a message-out before the bus is usable again?** After a phase
   mismatch the controller may still be connected to the target. Action 5 stops DMA and returns
   to `IDLE`, but touches no WD register. Whether `startany()` can then select a new target is
   **unknown**; nothing measured here answers it.
2. **What is action 9?** It writes transfer count `0x12/0x13/0x14 = 0`, `CMD_PHASE(0x10) = 0x46`,
   `CONTROL(0x01) = 0x8c`, sets `istate = 5`, and issues a command through register `0x18`.
   Register numbering is from NetBSD `sbicreg.h`; the *purpose* of this sequence is
   **inferred, not established**, and it is reached today only from input 7 (`status 0x4B`).
   If it is a resume-after-phase sequence it may be a better target for `0x49` than action 5.
   This is the single most valuable unknown here.
3. **Which `request+N` fields signal an error to the caller.** `+5` and `+6` are written by
   action 0; that they are "status valid" and "SCSI status" is inferred from position and from
   `reg(0x0f)` being TLUN. The struct is not in the tree. Until this is settled, no wrapper can
   correctly mark a request failed.
4. **Whether `0x49` can also arrive in states other than `STARTING`.** Only `STARTING` has been
   observed. `st2` maps input 1 to action 1 as well, so the same death exists there.

## 6. Shape of the fix, once 5.1–5.3 are answered

A table byte cannot set an error field, so this needs code, in the same shape as
`src/a3091demux040.s`: retarget a relocation, leave the stock C body untouched, and do the work
in an interposer that

1. recognises the status/state pair it is written for, and passes everything else straight
   through to the stock handler;
2. marks the in-flight request failed using the fields settled in 5.3;
3. performs whatever WD sequence 5.1 and 5.2 establish is required; and
4. reaches the existing `istate = IDLE; startany()` exit rather than inventing a new one.

Anything that cannot do step 2 correctly should do nothing and let the driver die visibly.

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
2. `a3p_handled ≥ 1` and `a3p_calls > a3p_handled` — the interposer both fired and delegated.
3. `a3p_nounit == a3p_badstate == 0`.
4. `dd` returns an **error**, not zero records. A silent short read fails this acceptance.
5. The machine survives, and a second `dd` against a *good* target succeeds afterwards — this
   is what proves the bus was left usable, and it is the criterion 5.1 exists for.
6. Battery 12/12 and burst 96/96 on the same boot, so the fix is not paid for elsewhere.
7. `a3w_*` from the ISSUE-53 wrapper unchanged in character: this must not disturb it.

## 9. Explicitly out of scope

Full controller recovery from `DEAD`. The ISSUE-53 audit §Q4 lists the six things a real reset
path owes and concludes that calling `initialize()` again or writing `istate = IDLE` performs a
fraction of the contract. Nothing here changes that. This issue is about **not reaching `DEAD`
for a status that is not a hardware failure** — it is not a recovery mechanism.
