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
