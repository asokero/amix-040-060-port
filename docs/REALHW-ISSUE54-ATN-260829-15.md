# The ATN path, measured: the target answers with `DATA_IN`, not `MESSAGE OUT`

`68060-260829-15`, 2026-08-29. The proof the bus-free audit said was still owed —
*"the status used to enter Message Out still requires a small instrumented proof before assembly
is written"* — is now in hand, and it says the target does not enter Message Out.

## The capture

```
a3p ss=49 cp=46 tc=0 di=43 con=8C as=0
a3p req=81137D8 op=28 rd=1 addr=970F000 len=200
a3p sac=970F1F0 cntr=C verdict=2 retry=0
a3091dbg ss=49 istate=1 unit=8113D38 head=0 dmaon=1
a3091dbg segstate=2 segseq=4622 segpa=970F000 seglen=200 segdir=1
a3091dbg dev=DD0000 istr=0 entry=D0
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=4622
a3p ATN-FAILED stage=5 as=80 ss=89 polls=1
a3p RELEASE-FAILED try=1 as=0 ss=0 polls=0
a3091: 0x49 1 0x8113D38
a3091dbg ss=85 istate=3 unit=8113D38 head=0 dmaon=0
...
a3091: 0x85 3 0x8113D38
```

## What it says

`stage = 5` — the path got past `SET_ATN` **and** past the `LCI` check **and** issued `CLR_ACK`.
So ATN was asserted and accepted. `as = 0x80` is a clean interrupt: no `LCI`, no `CIP`, no `DBR`.
`polls = 1` — the answer came on the very first check, without delay.

And the answer was **`ss = 0x89`**, which is `SBIC_CSR_MIS_2 | DATA_IN_PHASE`.

**The target re-presented the data phase.** It still has 1536 bytes of its 2048-byte block to
send, and asserting ATN did not make it stop and listen. My gate required the low three bits to
read 6 for MESSAGE OUT; they read 1.

So H4 failed, and it failed for a reason rather than a fault: the code did exactly what it was
written to do, and what it was written to expect is not what the device does.

## The bound was not the problem

`polls = 1`. The bound of sixteen `delayus(8)` was never approached, and the deliberate decision
to change only the instrumentation in this build — leaving the bound alone — is what makes that
statement possible. Had both moved, this run would have proved nothing about either.

## What it means for the design

SCSI requires a target to enter MESSAGE OUT after ATN "at its earliest convenience", and this
target's earliest convenience is evidently not immediate. NetBSD anticipates exactly this: its
parity-error path loops *until* a message-out phase appears and calls `sbicnextstate()` for the
phases that arrive in between, rather than failing on the first one. Its own comment says that
code does not work, so it is a pointer rather than a template.

The WD has the primitive that the in-between phase needs: `SBIC_CMD_XFER_PAD` (`0x19`), a
transfer that consumes a data phase with no buffer. Draining the target's remaining bytes and
discarding them would let it reach a phase boundary where ATN can be honoured.

That is a design step, not an edit, and it is the third time on this issue that the obvious next
move has turned out to be wrong when measured. It belongs in a contract first.

## Where ISSUE-54 stands

- The **`0x49` classification** is solid and unchanged across five kernels.
- The **`0x49` handling** worked in `-09` and `-11`: `dd` returned `RC=2` and the machine survived
  the trigger. That behaviour is currently traded away, because the ATN path fails closed.
- The **release** does not work. `-11` proved chip-level acceptance is not bus-free; `-15` proves
  ATN alone does not make this target let go.
- The target does go bus free eventually — the follow-up `0x85` on the CD's own unit, in both
  `-13` and `-15` — but after `badhardware()` has already run.
