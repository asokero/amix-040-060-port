# The `0x41` discriminator — verdict **7**, `68060-260829-11`, 2026-08-29

Six of six predictions held. The question the build existed for is answered, and it is the
expensive answer.

## The capture

```
a3p ss=49 cp=46 tc=0 di=43 con=8C as=0
a3p req=8113560 op=28 rd=1 addr=971A000 len=200
a3p sac=971A1F0 cntr=C verdict=2 retry=0
a3091dbg ss=49 istate=1 unit=8113AC0 head=0 dmaon=1
a3091dbg segstate=2 segseq=4842 segpa=971A000 seglen=200 segdir=1
a3091dbg dev=DD0000 istr=0 entry=D0
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=4842
a3p RELEASED req=8113560 as=0 ss=0 polls=1
a3p ss=41 cp=3A tc=800 di=46 con=8C as=0
a3p req=811362C op=28 rd=1 addr=9E5C000 len=800
a3p sac=9E5C000 cntr=FE0C verdict=7 retry=0
a3091dbg ss=41 istate=1 unit=8113AF0 head=0 dmaon=1
a3091dbg segstate=2 segseq=4843 segpa=9E5C000 seglen=800 segdir=1
a3091dbg dev=DD0000 istr=FE01 entry=FED1
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=4843
a3091: 0x41 1 0x8113AF0
```

`dd` on the CD again returned `RC=2` and an I/O error, and the `0x49` half is unchanged.

## The answer: the event was the root disk's

`cp = 0x3A` falls in the audit's `0x30..0x3c` band — **target 6 accepted that many CDB bytes
before the sudden bus free.** Not `0x00`. A new selection did complete, and the command got as
far as sending its descriptor block.

Everything else agrees, and none of it is the field that was misused last time:

- `tc = 0x800` — the whole 2048-byte transfer still pending. Nothing moved.
- `sac = 9E5C000` equals `segpa = 9E5C000` — the DMA cursor never advanced by a single byte.
- `di = 0x46` — `DPD` set, low bits **6**. Captured, and deliberately *not* used as identity:
  it is host-programmed. It happens to agree with `CP`, which is the field that does not lie.

**So the release did not leave the bus usable for a new command.** The root disk was selected,
began its command, and the bus went free under it.

## What that decides

By the prediction written before the run:

> **7** — the root disk really was selected and its command died. Then the release genuinely left
> the bus unusable for a *new* command, and the ATN/Message-Out `ABORT` path is required rather
> than merely protocol-correct.

That is now the measured case. `docs/contracts/A3091-BUS-FREE-FOLLOWUP-AUDIT.md` Q4 stops being
the thorough option and becomes the necessary one: the target has to be *told* to release, with
ATN and a Message Out `ABORT` (0x06), rather than dropped by a WD `Disconnect` that only releases
the initiator's own signals.

It also disposes of the cheaper hypotheses. Not a late event from the CD's cleanup — `CP` says a
new selection completed. Not a case for waiting longer — `rel_exp = 0`, `polls = 1`, the bound was
never approached. Not a case for reclassifying `0x41` — the status is telling the truth about a
command that really did die.

## Cost of the answer, recorded honestly

Three power cycles, three `fsck` runs and one boot that hung short of `The system is ready`
without ever being explained. The hang did not reproduce on the next boot of the same image, so
it stands as a single unexplained event rather than a defect, and the control kernel built to
chase it (`build/unix-040-quiet-CONTROL`, `68040-260829-02`, this tree at `8ac67ac`) was never
needed. It is kept for the next time something like it happens.
