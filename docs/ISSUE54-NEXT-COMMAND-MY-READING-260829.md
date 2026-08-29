# My reading of the `0x41` that follows the release — written before the task was sent

Recorded **before** `private/A3091-BUS-FREE-CODEX-TASK.md` was written, and the task contains
none of it. Last time this protocol was used, two of my three conclusions were wrong and would
have shipped as a new defect; that is the reason for keeping it.

## What I am confident about

**`0x41` and `0x85` are different categories in the WD's own encoding.** `sbicreg.h` groups
`0x41 DISC` under *Terminated Interrupts* — a command was ended — and `0x85 DISC_1` under
*Service Required Interrupts* — the bus is free. a3091 handles the second (`itab[0x85] = 3`,
`atab[STARTING][3] = 7`) and classes the first illegal.

**NetBSD folds them together, and can afford to.** `sbicnextstate()` takes both in one case arm:
clear the in-DMA and selected flags, push the request onto `nexus_list`, drop the nexus, and
schedule another target. It has a *list of disconnected requests* to put it on, and a
reselection path that will find it there. a3091 has no such list — a disconnected request stays
at its unit's `comhead`.

**So reclassifying `0x41` to input 3 would be the wrong fix, and worse than the wedge.** Action 7
leaves the request at `comhead`, sets `IDLE`, and calls `startany()`. The capture shows
`head=0`: the start queue was empty. Nothing else would run, and the root-disk request would
wait for a reselection that is never coming. That converts a visible wedge into a silently
stranded root filesystem — the ISSUE-51 class this project treats as worse than a crash.

**And the driver cannot send a message to a target at all.** `startcom` is `0x09`, which is
`SBIC_CMD_SEL_XFER`: Select **without** ATN and Transfer. `0x08` is the with-ATN variant and the
driver uses it only as a fallback assignment. Without ATN there is no message-out phase, so
there is no way to send an `ABORT` message. The DFA has a `MESSAGING` state that only *reads*
(action 8 handshakes a message in). Any fix whose shape is "tell the target to let go" needs
machinery that does not exist in this driver.

## What I think is happening, marked as inference

The release passed its acceptance test — `CIP`, `BSY`, `LCI`, `INT` all clear — and the next
command still terminated with an unexpected bus free. `ASR.BSY` is the WD's own state. A
CD-ROM interrupted mid-`DATA_IN` with 1536 bytes it never got to send has no reason to have
released the bus, and a WD `Disconnect` releases *our* signals rather than telling the target
anything.

`0x42 SEL_TIMEO` would have meant the selection never took. `0x41` means the command got past
selection and then the bus went free under it. That is more consistent with the old target
letting go late, during the new command, than with the new target misbehaving.

## What I would do next, and it is not code

One more measurement, because the cheap experiment is available: trigger the CD read, then
**wait** — seconds, doing nothing — before touching any disk. If the bus recovers on its own,
the fix is a settle-and-verify after the Disconnect and the current bound is simply too short at
one raster line. If it does not recover, the target has to be told, and that is a much larger
change than ISSUE-54 has earned so far.

I am not confident enough to pick between those from one capture, and the last time I was this
confident about a WD sequence I was wrong twice.

## Where the comparison is not blind, stated rather than hidden

The task carries one constraint that overlaps my conclusion: *"do not propose anything that can
strand a request silently."* My first conclusion is that reclassifying `0x41` would do exactly
that, so the constraint may steer the answer away from an option I have already rejected.

It stays in, because it is this project's standing standard and belongs in any task about this
driver whether or not I had reached that conclusion — but the overlap is real and the comparison
is weaker for it than the last one was.

The task also gives them two facts I found: that `sbicreg.h` puts `0x41` and `0x85` in different
interrupt categories, and that `sbicnextstate()` handles both in one case arm. Those are source
material rather than conclusions, and withholding them to keep the experiment tidy would only
cost time. What is withheld is what I make of them.

---

# Scored against the independent answer, 2026-08-29

`docs/contracts/A3091-BUS-FREE-FOLLOWUP-AUDIT.md`. **Three of four right, and the miss is a
class of error this project had already named — one I had even quoted.**

## Right

- **`AS.BSY = 0` proves only that the WD's internal command ended, not that the physical bus was
  released.** Same conclusion, same reasoning.
- **Neither a longer poll nor `0x41 → action 7` is safe.** Both rejected there too, and the
  stranding argument is the one I gave.
- **The protocol-correct fix needs ATN and a Message Out `ABORT` (0x06).** I identified that the
  driver cannot do this today, and why: `startcom` is `0x09`, `SEL_XFER`, select without ATN.

## Wrong, and it matters

I read `unit=8113A44` as identifying whose event the `0x41` was, and concluded the root disk's
command had terminated. **The capture does not prove that.**

`startany()` programs `DI`, copies the CDB, arms the DMA, writes `curunitp` and sets `STARTING`
**before** it writes the combination command. So every field I used as identity describes target
6 while its selection is still *pending*. `head=0` only says the unit was taken off the start
queue. The `0x41` may well have been the CD letting go late, arriving while the root disk's
command had not yet begun.

That is exactly the event-ownership error the previous audit described for action 7 — attributing
one target's event to another target's request — and I had quoted that passage into this
project's own ledger two days ago. I then made the same mistake in my own reading of a capture.

## Also better than my framing

I called the missing ATN a structural blocker: machinery the driver does not have. The audit
scopes it correctly — ATN is needed on the *cleanup* path only, and the ordinary
`startcom = 0x09` selection does not change. That turns a "much larger change than ISSUE-54 has
earned" into a bounded addition.

## And my recommendation was the right shape but the wrong experiment

I proposed triggering and then waiting, to see whether the bus recovers on its own. The audit's
next build is sharper and cheaper: **capture `CP`, `TC` and `DI` at the `0x41` itself.** `CP=0`
would mean no new selection completed, which is the strong result for a late CD event; `CP>=0x10`
would mean target 6 really had been selected. It answers the ownership question directly instead
of inferring it from timing, and the classifier already has the register-access pattern.

Note the audit's own caution, which is the same trap again: capture `DI` but **do not use it as
event identity** — it is a host-programmed destination register.
