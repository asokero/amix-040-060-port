# My reading of the WD bus release, from NetBSD's `sbic.c` — written before the task was sent

Recorded **before** `private/A3091-BUS-RELEASE-CODEX-TASK.md` was written, and the task
deliberately does not contain any of it, so the two answers can be compared rather than one
confirming the other. If they disagree, that is the useful outcome.

Source: `sys/arch/amiga/dev/sbic.c` and `sbicreg.h`, pinned NetBSD 10.1.

## The answer is not "Abort or Disconnect". It is both, in order, with two guards.

`sbicabort()`, on a chip that is still selected:

1. **Drain the data buffer first.** While `ASR & DBR`: read the data register; if `DBR` is
   still set afterwards, the buffer wanted the other direction, so *write* the data register
   instead. Loop until `DBR` clears. NetBSD's own comment says it does not know which direction
   is needed — it tries a read and infers from whether `DBR` cleared.
2. Wait for `CIP` to clear.
3. Issue **`ABORT` = 0x01**.
4. Wait for `CIP` to clear again.
5. **Check `ASR & (BSY|LCI)`.** If either is set the abort did not take, and NetBSD escalates to
   a full chip reset and gives up on a clean release.
6. Issue **`DISC` = 0x04**.
7. Poll until `CSR` reads `DISC` 0x41, `DISC_1` 0x85, or `CMD_INVALID` 0x40.

Values, from `sbicreg.h`: `CMD_RESET` 0x00, `CMD_ABORT` 0x01, `CMD_DISC` 0x04,
`CMD_SEL_ATN_XFER` 0x08. `ASR`: `INT` 0x80, `LCI` 0x40, `BSY` 0x20, `CIP` 0x10, `DBR` 0x01.
`a3091.c` already defines `CIP (1<<4)` and `DBR (1<<0)` identically, so the register model
carries over unchanged; `COM` is 0x18, `AS` is 0x1F, `DR` is 0x19.

## Two things I would flag about porting it

**It is built out of spin loops, and we refused those on purpose.** `WAIT_CIP` and `SBIC_WAIT`
both busy-wait on the chip. The classification instrument deliberately does not `cipwait`,
because a spin loop in an interrupt handler on a machine that is already in trouble is how a
diagnostic becomes the hang it was written to explain. A bus release has more claim to waiting
than a diagnostic does — it has to finish — but the same hazard applies and the bound has to be
explicit rather than `while (1)`.

**And I think the obvious fix dies one interrupt later.** This is the part I am least sure of
and the reason the task exists.

`DISC` completes by producing a disconnect interrupt. `itab[0x85] = 3`, and:

```
             in0  in1  in2  in3  in4  in5  in6  in7  in8
  IDLE         1    1    1    1    3    1    1    1    1
  STARTING     5    1    6    7    2    8    1    9    0
```

`atab[IDLE][3]` is **1** — `badhardware()`, `DEAD`. So if the fix is "action 5's body", which
ends at `istate = IDLE; startany()`, then the `0x85` that the release itself provokes arrives at
`IDLE` and kills the driver anyway, unless `startany()` happened to start another request first
and moved the state to `STARTING`, where input 3 is action 7 and handled.

That would make the fix depend on whether the queue was empty — which is not a property anyone
should be relying on.

**The morning's capture is consistent with this.** Its second line is `ss=85 istate=3`: a
`DISC_1` did arrive, on its own, after the mismatch. The target released the bus without being
asked. That is evidence the release may be less of a problem than the *state the driver is in
when the disconnect interrupt lands*.

So my reading is: the bus release is `ABORT` then `DISC`, and the harder half of the problem is
not issuing them but surviving the interrupt they cause.

---

# Scored against the independent answer, 2026-08-29

`docs/contracts/A3091-BUS-RELEASE-CONTRACT.md`. **One of three right, and the two wrong ones
were wrong in a way that would have caused a new defect.**

## Wrong: Abort is unnecessary here, and it is hazardous

I read NetBSD's `sbicabort()` and reported its sequence. That routine is a driver-wide
*unknown-state* recovery entry. The measured tuple is not an unknown state: `AS=0` means no
`DBR`, no `CIP`, no `BSY`, so nothing is jammed and the drain loop has nothing to drain. `CP=46`
and `TC=0` mean the Level II command has already terminated, so Abort has nothing to abort.

Worse than unnecessary: **Abort carries a direction-sensitive FIFO contract.** On an initiator
*receive* — which is exactly this case, `rd=1`, `DATA_IN` — the host must keep servicing WD data
requests until the Abort interrupt arrives, so that incoming FIFO data reaches its destination.
A fix that issued `stopdma(); Abort` would have violated that on the one path it was written
for.

## Wrong: a host-issued Disconnect raises no completion interrupt

I assumed it did, because NetBSD polls for status after issuing it. The data sheet says Abort
interrupts and Disconnect does not, and the contract notes that NetBSD waits for status after
Disconnect **even though the manufacturer says the command does not interrupt.** The
manufacturer contract wins where a maintained driver and the data sheet disagree.

So the `0x85` in the capture was never the release's own event — it is the target disconnecting
on its own, which `CON=0x8c`'s `IDI` policy asks the WD to report. I had the right observation
and the wrong owner for it.

## Right, and then extended past where I stopped

Ending at `istate = IDLE; startany()` is unsafe. I found the empty-queue case — a delayed `0x85`
dispatches through `atab[IDLE][3] = 1` into `DEAD` — and then said the non-empty case is
"handled", because `atab[STARTING][3] = 7` is the disconnect action.

It is not handled. Action 7 stops the DMA belonging to the **newly started** request, treats
that request as temporarily disconnected on the strength of an event that belonged to the old
target, and returns without completing or requeueing it. That is silent misattribution of an
interrupt across two requests, and it can strand or corrupt unrelated I/O — a worse class of
outcome than the wedge, by this project's own standard.

**Both queue states are invalid, in different ways.** My "unless the queue was non-empty" was
the reassuring half of a sentence whose other half I had not checked.

## What the method got right

Committing my answer before writing the task was worth doing. Two of my three conclusions were
wrong, and had I written the task after forming them, the two errors are exactly the kind that
survive into a prompt as background assumptions — "confirm that Abort then Disconnect is
right" would very likely have been confirmed.
