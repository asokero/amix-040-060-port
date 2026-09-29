# The `dma_prepare` / `dma_complete` service, and the layout of `struct dma_rec`

**Status:** contract, layout version 2. Agreed between the two development lines on 2026-09-28
(`amix-mail`, thread `2026-09-27-kickoff-questions`, letters 03-jussi and 04-antti, with the
call-shape note `attachments/D42-CALL-SHAPE.md`), and reconciled on 2026-09-29 against the driver
line's `attachments/D42-CONTRACT-v2.md` and their letters 05 and 06. The service is implemented in
`src/dma_cache040.s`; the record lives in each controller's own object.

**Why this document exists rather than the source alone.** `tools/status-facts.sh` locates counter
blocks by `*_magic` **symbols** and enumerates their members by symbol prefix, which is how every
other counter block in this port is read and kept honest. This record is a C structure inside an
array in a driver object, so only the array base is a symbol and no field is. The tooling cannot
enumerate it, and **the offsets below are therefore the only contract there is.** A table that
lives only in a letter is a table that will be lost.

## The call

```c
int  dma_prepare (struct dma_rec *r, ulong pa, ulong len, int dir);
void dma_complete(struct dma_rec *r, ulong pa, ulong len, int dir);

#define DMA_TO_DEVICE    0   /* device reads RAM  (SCSI write) */
#define DMA_FROM_DEVICE  1   /* device writes RAM (SCSI read)  */
```

Plain C convention, arguments on the stack right to left. `d0`, `d1`, `a0` and `a1` are scratch;
every other register is preserved. Both are callable at any IPL the driver runs at, and neither
sleeps, panics, or touches the device.

`pa` is **physical**. The service works by physical line, so one operation covers every virtual
alias of the page, including a raw-I/O buffer's copyback user mapping.

**`prepare`** is called after the driver has built everything the device will read and before the
write that arms it. It takes ownership of `[pa, pa+len)` and pushes the CPU's dirty lines over it.
It returns 0 when the record is `PREPARED` and nonzero when it is not — the seam is off, a segment
is still owned, or the range is bad. **The driver arms either way** and keeps no state of its own
about the result. For `FROM_DEVICE` only, it counts `edge_shared` when `pa` or `pa+len` is not on
a 16-byte line.

**`complete`** is called after the device has stopped touching the segment and before the driver's
completion callback. For `FROM_DEVICE` it invalidates the owned lines; for `TO_DEVICE` it does no
cache operation. It consumes the record: the state returns to `EMPTY`.

The `(pa, len, dir)` passed to `complete` are the same values passed to `prepare`. That lets the
service count a mismatch without trusting either side — and where they disagree **the owned
segment is used**, never the argument.

## `struct dma_rec` — 0x60 bytes, every field a longword

In the "who" column, **D** means the driver writes the field and the service only reads it; **S**
means the service writes it and the driver only reads it, for diagnostics.

| off | field | who | meaning |
|---|---|---|---|
| 0x00 | `magic` | D | `0x444D4152` `"DMAR"`. Static; proves the address to a `/dev/kmem` reader |
| 0x04 | `version` | D | layout version, **2**. 1 was the 0x5c proposal, without `edge_shared` |
| 0x08 | `ctlid` | D | driver family: the AutoConfig id |
| 0x0c | `unit` | D | controller instance |
| 0x10 | `off` | D | nonzero means the seam is **off**: the service counts the call, does no cache operation and takes no ownership |
| 0x14 | `state` | S | 0 `EMPTY`, 1 `PREPARING`, 2 `PREPARED` |
| 0x18 | `dir` | S | direction of the owned segment |
| 0x1c | `pa` | S | owned segment: physical base |
| 0x20 | `len` | S | owned segment: length |
| 0x24 | `seq` | S | prepares that took ownership |
| 0x28 | `prep_to` | S | prepares, `TO_DEVICE` |
| 0x2c | `prep_from` | S | prepares, `FROM_DEVICE` |
| 0x30 | `cmpl_to` | S | completes consumed, `TO_DEVICE` |
| 0x34 | `cmpl_from` | S | completes consumed, `FROM_DEVICE` |
| 0x38 | `prep_owned` | S | prepare while a segment is still owned: the call fails, the live record is **not** overwritten |
| 0x3c | `cmpl_noprep` | S | complete with no `PREPARED` record: no cache operation |
| 0x40 | `cmpl_mismatch` | S | complete whose `(pa,len,dir)` differs from the owned segment: the **owned** one is used |
| 0x44 | `range_ovf` | S | `pa + len` wrapped: refused, no ownership |
| 0x48 | `edge_shared` | S | **`FROM_DEVICE`** prepares whose `pa` or `pa+len` is not on a 16-byte line: counted, **not** refused. See below |
| 0x4c | `off_n` | S | calls seen while `off != 0` |
| 0x50 | `drv_prep` | D | prepare calls the driver made |
| 0x54 | `drv_cmpl` | D | complete calls the driver made |
| 0x58 | `drv_zero` | D | zero-length transfers: the driver made no call |
| 0x5c | `drv_quiesce` | D | completes that followed a forced quiesce |

**The S fields are contiguous from 0x14 to 0x4c and the D fields from 0x50 to 0x5c**, deliberately:
one `kpeek` reads the whole service state in order. `status-facts.sh` makes the same distinction
for the blocks it can enumerate, printing "reads it in one call, in this order" for a contiguous
block and "NOT contiguous, so read the addresses individually" otherwise.

**The driver owns the record.** It fills the identity fields — magic, version, ctlid, unit, off —
at attach, before the first transfer, and never removes them. The service never allocates or frees
a record. That is the same registration contract `hat_cm_fb_add` has: register before first use,
never remove.

## Acceptance invariants

Read by `kpeek`. None of them panics; every one of them is a counter.

* `drv_prep == drv_cmpl` — every prepare is paired.
* With `off == 0` throughout:
  `prep_to + prep_from + prep_owned + range_ovf == drv_prep`, and
  `cmpl_to + cmpl_from + cmpl_noprep == drv_cmpl`.
* When idle: `seq == cmpl_to + cmpl_from`.
* `prep_owned == cmpl_noprep == cmpl_mismatch == range_ovf == edge_shared == 0`.
* `edge_shared <= prep_from` — only `FROM_DEVICE` prepares are counted.
* With `off != 0`: `off_n` grows by one per call and nothing else in the S fields moves.

**The `edge_shared == 0` line is an obligation on the driver, not a property of the service.**
The service counts and continues; nothing makes the counter stay at zero except the ranges the
driver hands it. A driver meets it either by issuing only 16-byte-aligned `FROM_DEVICE` ranges or
by bouncing the ones that are not. Stated that way the invariant keeps naming violations; scoped
to "paths whose buffers are block-aligned" — the wording this document carried until 2026-09-29 —
it would instead excuse them, which is the opposite of what a counter is for. A nonzero value means a
driver bug or a caller that has not bounced.

**Read `magic` first.** A stale address does not fail; it returns a plausible number from whatever
now lives there. That rule is not specific to this block — it is why every counter block in this
port starts with one.

## Three decisions, and the reasoning that is not obvious from the code

### Per-range `cpushl`, not whole-cache `cpusha`

The B2 pilot for the A3091 pushes the whole cache, justified in `src/dma_cache040.s` by *"the
A3091 is the only host-RAM DMA owner in this machine"*. A second bus master removes that premise:
the justification is refuted rather than outgrown.

Worth stating so the pilot is not read as broken: **whole-cache `cpusha` is imprecise, not
unsafe.** It writes dirty lines back rather than discarding them — unlike `cinva`, which that file
records as forbidden under copyback. With several owners it makes the ownership bookkeeping
decorative on the push side and costs the whole cache per arm.

### Every `cpushl` is paired with a `cinvl`

Not caution. The pair is correct in all four cases — a 68040, and a 68060 with `CACR` bit 28
(`DPI`) either way — so the unit stops depending on a bit it neither owns nor can see.

That dependency is looser than it looks. `CACR` is not a constant of the machine: the exception
handlers reload it from `sup_cacr` on every entry, the FP paths rewrite it on every vector-11
event (`src/fpe040.s`, `src/fpsp060_glue.s`), and that variable's stock value is the 68030-era
`0x1019` which this port already had to change once. `src/swapconf_dbg.s` already declined to
assume the bit, recording `CACR` rather than trusting it; a second instrument should not assume
the opposite.

### Edge lines are counted, not repaired

The range is rounded outward to 16-byte lines, so a misaligned buffer shares its edge lines with
unrelated data. The driver line asked whether the edges should be pushed again at complete, before
the invalidate. **They should not**, and the reason is that it does not fix the case — it changes
whose data is lost.

A shared edge line holds two kinds of byte: transfer bytes the **device has just written to RAM**,
and unrelated bytes the CPU may have dirtied. This part writes a dirty line back **whole**; there
is no byte-granular writeback. So:

| complete does | what is lost |
|---|---|
| `cinvl` | the CPU's write to the unrelated bytes |
| `cpushl` then `cinvl` | **the device's freshly written transfer bytes**, overwritten by the stale copy in the line |

Once such a line has been dirtied mid-transfer the data is gone either way, and of the two the
device's data is the reason the transfer exists. The case is already outside the protocol's rule —
the CPU may not touch the owned rounded range until complete — and no cache operation at complete
can pull it back inside. So it is named in `edge_shared` and left to the acceptance invariant.

**Which buffers actually reach it was then measured, and this document had it wrong.** It said
block-aligned `sd` transfers never reach the case and a misaligned raw-I/O buffer is the exposure.
On the driver line's emulator, cache on, with this service linked (their letter 06, 2026-09-29),
`edge_shared` rose by exactly one per **GSIO** `FROM_DEVICE` transfer — INQUIRY, REQUEST SENSE,
READ CAPACITY, and a 512-byte READ(10) alike, because stock `scsi.c`'s `iobuf` is a `.bss` char
array with no alignment by construction and lands off a line — and by one per `dd` `getsense` on a
NOT READY unit, while ~4 200 block **and raw** prepares added none. Raw I/O was the guess; the
stock command buffer was the case. Every counted transfer was benign in fact, which is what the
"counted, not refused" policy predicts.

The driver line's answer is a driver-owned 16-aligned bounce for misaligned `FROM_DEVICE` ranges
up to 1 KB, copied out after complete, with longer ones refused; after it, the same workload shows
the counter flat. Two details from writing it are worth carrying here because they are properties
of *this* contract rather than of their driver: the bounced length must be **rounded up to a
16-byte multiple** — a 36-byte INQUIRY inside a 16-aligned buffer still ends off a line, and the
counter fires, correctly — and the bounce must be **zeroed** before the transfer, so a command with
no data phase copies out zeros rather than stale bytes.

## What is not decided here

* **The A3091 does not use this service.** Its B2 wrappers keep their own global record and stay
  hardware-proven. Moving them onto the generalized entry points is a separate step with its own
  acceptance run.
* **Nothing on this machine calls these entry points**, so they are unexercised. The counters above
  are the instrument for the run that first does.
* ~~Whether a misaligned buffer can actually reach a controller on the driver line~~ — answered
  on 2026-09-29: it can, on the stock GSIO path, on every kernel. See "Edge lines" above. The
  bounce lives in the driver and is outside this contract; what the contract gained is the
  rounding and zeroing rules and an invariant that is now unconditional.
* **The A3091 pilot has the same exposure** and does not report it, because it predates this
  record: `dp->sense` is a 16-byte `FROM_DEVICE` read into a field of an array element, four bytes
  off a line, sharing its tail line with the next unit's live fields. That is ISSUE-73, and it is
  a reason to move the pilot onto this service rather than an argument against the invariant.
