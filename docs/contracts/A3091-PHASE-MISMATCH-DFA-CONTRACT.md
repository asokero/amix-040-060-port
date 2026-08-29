# ISSUE-54 contract — an unrecognised WD status must not be permanent death

Written 2026-08-29, before any fix, from `build/unix-040` (`68040-260829-05`). Every address
and table value below was read out of the image; the "inferred" and "unknown" sections say
plainly which claims were not.

This is a contract, not a patch. ISSUE-43 cost two failed fix attempts on this same driver
family, and both failed for the same reason: *the meaning was inferred from the shape of the
code.* So the deliverable here is the measurement plus the questions that must be answered
before a byte moves.

> **SUPERSEDED IN PART, 2026-08-29.** An external audit answered §8's load-bearing question and
> **rejected this document's candidate fix.** The WD does preserve Command Phase across the
> termination and does treat a reissued `0x09` as a resume — but only for a *compatible* saved
> phase, so `itab[0x48..0x4A] = 2` is too broad: it validates neither the phase, the direction,
> the DMA cursor, nor any retry bound. And §7's fallback is unsafe too — action 5 reports the
> request failed but never releases a bus the WD is still connected to. See
> [`A3091-PHASE-MISMATCH-RESUME-AUDIT.md`](A3091-PHASE-MISMATCH-RESUME-AUDIT.md), which
> supersedes this one wherever they disagree. What survives here is the measurement: §1–§6, and
> §4's retraction. The next build is that audit's classification instrument, not a fix.

> **Read `sys/amiga/alien/a3091.c` first — it is in `vanilla/amix-sources.tar`.** This document
> was drafted from disassembly and then rewritten against the source, which changed three of its
> conclusions and killed one of its own arguments outright (§4). The private Codex task for
> ISSUE-53 already said the source was there. Sections 1–2 are kept because a byte patch needs
> pinned-image addresses that the source cannot give; everything after them is from the C.

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

## 3. The states and actions, described

The source names six states — `IDLE` 0, `STARTING` 1, `RESUMING` 2, `DEAD` 3, `MESSAGING` 4,
`ENDING` 5 — and ten actions. Described rather than quoted (the comment block is AMIX source
text and this document is published):

| action | leaves the DFA in | what it is for |
|---|---|---|
| 0 | IDLE, then possibly STARTING | finish the request and pick up the next |
| 1 | DEAD | announce that the driver has given up |
| 2 | RESUMING, or DEAD | put the request back on the queue and carry on with another |
| 3 | RESUMING, or DEAD | pick a request back up after the target reconnects |
| 4 | RESUMING | carry on after a `0x20` |
| 5 | IDLE, then possibly STARTING | give up on this request and pick up the next |
| 6 | RESUMING | stash the pointers, then carry on |
| 7 | IDLE, then possibly STARTING | let the target drop the connection, pick up the next |
| 8 | MESSAGING, or DEAD | read what may be a Restore Pointers message |
| 9 | ENDING | carry on and expect the request to finish |

`itab`'s own documentation describes input 1 as covering statuses that are not legal or not
supported. `0x49` appears nowhere in the file: a data-phase mismatch was never considered,
rather than considered and rejected.

## 4. The argument this document made against action 5 was wrong

The disassembly showed action 0 writing `request+5` and `request+6` where action 5 writes
neither, and this document concluded that action 5 completes a request "with no error
indication" — silent data loss. **That is wrong, and the source settles it in one line.**

The two fields are `cp->okay` and `cp->status`. Action 0 sets `okay` true and copies the target
status **only when the command-phase register reads `0x60`**; action 5 sets neither. But
`a3091queue()` clears `okay` on every request as it is enqueued, so the field is false until a
completion earns it. Action 5 leaving it alone therefore *is* the failure report.

Action 5 is a clean abort that reports failure, not a silent success.

The reasoning failed in a way worth naming: it read *"writes fewer fields"* as *"reports less"*,
without checking what the unwritten field's default was. The default was the whole answer, and
it was one grep away in a file this project already knew it had.

## 5. What the statuses actually are

Decoded against NetBSD's Amiga WD33C93 driver (`sbicreg.h`, `sbicvar.h`) from the pinned
tarball — `SBIC_CSR_MIS_1 = 0x48`, `DATA_OUT=0 DATA_IN=1 CMD=2 STATUS=3 MESG_IN=7`:

| status | input | decode | a3091's response |
|---|---|---|---|
| `0x16` | 8 | `S_XFERRED` | complete |
| `0x20` | 6 | `CMD_STOPPED` | resume (action 4, via MESSAGING) |
| `0x21` | 2 | `SDP` | save pointers and resume (action 6) |
| `0x42` | 0 | `SEL_TIMEO` | abort (action 5) |
| `0x48` | **1** | `MIS_1 \| DATA_OUT_PHASE` | **DEAD** |
| `0x49` | **1** | `MIS_1 \| DATA_IN_PHASE` | **DEAD — this issue** |
| `0x4A` | **1** | `MIS_1 \| CMD_PHASE` | **DEAD** |
| `0x4B` | 7 | `MIS_1 \| STATUS_PHASE` | finish (action 9) |
| `0x4F` | 5 | `MIS_1 \| MESG_IN_PHASE` | message in (action 8) |
| `0x81` | 4 | `RSLT_IFY` | reconnect (action 3) |
| `0x85` | 3 | `DISC_1` | disconnect (action 7) |

**The driver handles a phase mismatch when the new phase is `STATUS` or `MESG_IN` — when the
command is effectively over — and dies when it is `DATA_OUT`, `DATA_IN` or `CMD`, the phases
that mean there is more transfer to do.** That is why ordinary disk I/O never trips it: a
transfer that completes reports `S_XFERRED` and moves to `STATUS`. The capture's `segdir=1`
agrees with `DATA_IN` independently.

## 6. The driver already resumes partial transfers, on two paths

Described, not quoted:

- **Action 6**, taken on `0x21` (Save Data Pointers), copies the WD's **current** transfer-count
  registers into the unit's three saved count bytes, rewrites the control register with the
  usual DMA-plus-disconnect-interrupt configuration, moves to `RESUMING`, and re-issues
  `startcom`. It writes **no** command-phase value.
- **Action 4**, taken on `0x20` by way of `MESSAGING`, writes command phase `0x45`, loads the
  **saved** count bytes back into the WD's count registers, moves to `RESUMING`, and re-issues
  `startcom`.

The command-phase register is a progress ladder: `0x44` on reconnection (action 3, before the
data phase), `0x45` to resume into a data phase (action 4), `0x46` to resume past it (action 9 —
and NetBSD's `sbicxfdone` writes the same value under its comment about having the chip complete
the command on its own). `startcom` is `0x09`, the same command `startany()` uses to begin a
request; re-issuing it mid-connection resumes instead of re-selecting **because the command-phase
register tells the chip where in the sequence it already is.**

**And the saved count bytes are not a residual by default.** `startany()` initialises them from
the request's byte count — the whole transfer length. They hold a residual only after an action 6
has run. So action 4 at `STARTING` would restore the original length and re-run the entire
transfer.

## 7. Two candidates refuted, one standing

- **Action 9** — refuted. NetBSD's `sbicxfdone()`, the function this sequence is copied from,
  says in its own header that it runs *"after the completion interrupt from a read/write
  operation"* and *"skip[s] (and don't allow) the select, cmd out and data in/out phases."*
  `0x4B` is the case it was written for; `0x49` is the case it excludes.
- **Action 4** — refuted by §6: it restores `curunitp->tc*`, which at `STARTING` is the full
  length, not what is left.
- **Action 6 — standing.** It reads the residual out of the WD's own count registers, which is
  where a mismatch leaves it, re-issues `startcom`, and goes to `RESUMING`. It writes no `CP`,
  relying on the chip's own progress value.

`itab` is the narrow place to make the change, because the coverage falls out of the row:

```
            in0  in1  in2  in3  in4  in5  in6  in7  in8
  STARTING    5    1    6    7    2    8    1    9    0
  RESUMING    1    1    6    7    1    8    1    9    0
```

Input 2 is action 6 in **both** live states; input 0 is action 5 at `STARTING` and action 1 —
death — at `RESUMING`. So `itab[0x48] = itab[0x49] = itab[0x4A] = 2` covers both states with the
resume path, and moves three named statuses rather than the default class shared by 136.

The fallback, if resume cannot be made safe, is input 0: a clean abort at `STARTING` with
`okay = FALSE`, which §4 establishes is a real failure report. It leaves `RESUMING` fatal.

## 8. What still blocks it

1. **What is `CP` after a `MIS_1|DATA_IN`, and does resuming need `0x45` written?** Action 6
   writes no `CP` because after an `SDP` the chip's own value is right. Whether that holds after
   a phase mismatch is **the load-bearing unknown**. If it does not, the fix is action 6's body
   plus `setreg(CP, 0x45)` — which is no existing action, so an interposer rather than a table
   byte.
2. **Bound the retry.** If the target mismatches repeatedly, action 6 resumes forever and the
   wedge becomes a livelock. Any resume needs a counter and a fall-through to the abort path.
   The stock driver has no such bound because no stock path can loop this way.
3. **`0x48` and `0x4A` have never been observed.** They are the same defect and belong in the
   same change, but nothing here proves the resume is right for `DATA_OUT` or `CMD`.
4. **DMA.** Actions 4 and 6 never touch it, because on their paths it was never stopped. The
   capture shows `dmaon=1` and `segstate=2` at the mismatch, so the same holds here — but our
   own `dma_seg_*` record then describes a segment whose length no longer matches what the WD
   will ask for. Whether that matters is unknown; acceptance §11.9 is the check for it.

## 9. Shape of the fix

If 8.1 says the chip's `CP` survives a mismatch, this is three bytes in `itab` plus an
instrument. If it does not, it is an interposer in the shape of `src/a3091demux040.s` —
retarget a relocation, leave the stock C body alone, and do action 6's work with `CP` set and
the §8.2 bound applied.

Either way the instrument is built and read, because a table change nobody can attribute is not
evidence.

## 10. Instrument, written before the fix

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

## 11. Acceptance

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
   acceptance outright — §4 measures why that risk is real, and it is the one outcome worse
   than the present wedge.
5. `a3091: 0x49 ...` no longer appears and `istate` never reaches 3. The absence of
   `badhardware()` output is the direct evidence the fatal cell was not taken.
6. The machine survives, and a second `dd` against a *good* target succeeds afterwards — this
   is what proves the bus was left usable. §6 argues from NetBSD that no reset is needed;
   this is the run that would show that argument wrong.
7. Battery 12/12 and burst 96/96 on the same boot, so the fix is not paid for elsewhere.
8. `a3w_*` from the ISSUE-53 wrapper unchanged in character: this must not disturb it.
9. `dma_*` self-consistent after the run — `prep_to + prep_from == cmpl_to + cmpl_from`, and
   `owned`/`noprep`/`ovf` still zero. This is the check that would catch 8.2 going wrong,
   since a transfer left armed across the chip's own completion shows up there.

## 12. Explicitly out of scope

Full controller recovery from `DEAD`. The ISSUE-53 audit §Q4 lists the six things a real reset
path owes and concludes that calling `initialize()` again or writing `istate = IDLE` performs a
fraction of the contract. Nothing here changes that. This issue is about **not reaching `DEAD`
for a status that is not a hardware failure** — it is not a recovery mechanism.
