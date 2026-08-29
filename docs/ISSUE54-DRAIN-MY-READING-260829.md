# My reading of what to do about a target that will not stop talking

Committed **before** `private/A3091-DRAIN-CODEX-TASK.md` was written; the task contains none of
it. Twice before on this issue that protocol caught conclusions of mine that would have shipped
as defects, and once it scored 3 of 4. This is the third round.

## The situation, stated plainly

The driver asked a 2048-byte-block device for 512 bytes. The target will send 2048. **There is
no way to make this command succeed**, and the only question is how to end it without losing the
controller. Three attempts have now failed for three different measured reasons.

## What I checked first

`SBIC_CMD_XFER_PAD` (`0x19`) — a transfer that consumes a phase with no buffer — is defined in
`sbicreg.h` **and used nowhere**: not in the Amiga `sbic.c`, not in the generic
`dev/ic/wd33c93.c`. There is no reference implementation of it in NetBSD to follow. Anything
built on it is built without a template, which is the situation that has gone wrong three times
here already.

## What I think the answer is

**Stop fighting the target and let it finish.** It is not misbehaving: it is mid-command with
1536 bytes left, and every attempt so far has been an attempt to interrupt it. `0x89` was the
target saying so directly — `MIS_2 | DATA_IN_PHASE`, on the first poll, with a clean `AS`.

So: consume the remainder, let the command reach its natural end, and *then* fail the request.

**And it needs no new primitive.** Action 8 already reads one byte in a phase: set the command
register to a single-byte transfer, wait for `DBR`, read `DR`. Repeating that with the byte
discarded is a drain, built only from what this driver is already proven to do. `XFER_PAD` would
be tidier and is untested everywhere; the byte loop is slower and is not.

## The trap I would fall into if I were not careful

Draining and then letting the **stock** path complete the request would be the worst outcome
available. The target's data reaches STATUS phase normally, `0x4B` goes to action 9, `S_XFERRED`
goes to action 0, and action 0 sets `cp->okay = TRUE` with a real SCSI status. The caller would
then receive 512 bytes that are the wrong 512 bytes — the driver's LBA arithmetic is in 512-byte
units and addresses the wrong place on a 2048-byte-block device — reported as a successful read.

So the drain must end in **our** completion with `okay` left FALSE, not the driver's.

## What I am least sure about

- How much to drain. The residual is not known to the driver; the loop has to be bounded by
  something and end on a phase change rather than a count.
- Whether `STATUS` and `MESSAGE IN` phases follow and also need consuming before the bus frees.
- Whether 1536 PIO byte transfers inside an interrupt handler is acceptable. It is milliseconds
  on an error path, which I think is fine, but I have not measured it.

## One option nobody has raised, including me until now

**Refuse the request before issuing it.** Once a unit has failed this way once, the driver could
mark it and fail subsequent requests immediately, without touching the bus. That does not save
the first one, and it is not a fix for the protocol problem — but it would contain a CD-ROM or a
tape to exactly one wedge per boot instead of one per access, which is a different and cheaper
kind of safety than anything tried so far.

## Where the comparison is not blind, stated rather than hidden

Q3 of the task asks how the path must guarantee the request still fails *"if the command is
allowed to finish"*. That phrasing presupposes the route I have chosen, so it steers. It stays
in because the hazard it names — a completion reported as good carrying the wrong 512 bytes — is
the worst outcome available here and would be negligent to leave out of a task about ending this
command. But the overlap is real, and this comparison is weaker for it than the first was.

Q2 hands over the fact that `XFER_PAD` is used nowhere in any NetBSD driver. That is source
material rather than a conclusion; withholding it would only cost time.
