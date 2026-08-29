# ISSUE-54 fix on silicon — the release works, and the next command dies

`68060-260829-09`, 2026-08-29. One trigger. Predictions in
`test-tools/issue54-fix-predictions-260829.md`, committed before the run.

**Seven of ten held, one failed, and the failure is the one that matters. My stated hypothesis
for what would fail was also wrong.**

## The console, in full

```
a3p ss=49 cp=46 tc=0 di=43 con=8C as=0
a3p req=81134B4 op=28 rd=1 addr=970F000 len=200
a3p sac=970F1F0 cntr=C verdict=2 retry=0
a3091dbg ss=49 istate=1 unit=8113A14 head=0 dmaon=1
a3091dbg segstate=2 segseq=4757 segpa=970F000 seglen=200 segdir=1
a3091dbg dev=DD0000 istr=0 entry=D0
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=4757
a3p RELEASED req=81134B4 as=0 ss=0 polls=1
a3091dbg ss=41 istate=1 unit=8113A44 head=0 dmaon=1
a3091dbg segstate=2 segseq=4758 segpa=9DEF000 seglen=800 segdir=1
a3091dbg dev=DD0000 istr=FE01 entry=FED1
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=4758
a3091: 0x41 1 0x8113A44
```

and over telnet, before the machine went:

```
dd: read error: I/O error
0+0 records in
0+0 records out
RC=2

rel_try 1   rel_ok 1   rel_raced 0   rel_fail 0   rel_exp 0   polls 1   maxpoll 0
```

## What held

| # | | |
|---|---|---|
| H1 | `dd` returned an **error** and the shell came back; the machine survived the trigger | ✓ |
| H2 | `a3p_rel_try = 1` | ✓ |
| H3 | `a3p_rel_ok = 1`, `raced = 0` | ✓ |
| H4 | `fail = 0`, **`exp = 0`** — the bounded wait never expired | ✓ |
| H5 | `maxpoll = 0`, one poll | ✓ |
| H6 | `a3p RELEASED ...` printed | ✓ |
| H7 | **no `a3091: 0x49` line.** The fatal cell was not taken for the mismatch | ✓ |

The `0x49` half of ISSUE-54 is fixed. `dd` on the CD now fails cleanly instead of killing the
controller, and `cp->okay` staying FALSE is what carried the error to userland — `RC=2`, not a
silent short read.

## What failed, and it is not what I predicted

**H9.** A read of the root disk afterwards was supposed to prove the bus was left usable. The
machine wedged instead: ping answers, telnet accepts and prints the banner from memory, and
`login` never appears because it needs the disk.

I predicted the follow-up would be `0x85` arriving at `IDLE`, through `atab[IDLE][3] = 1`. **It
was not.** The second event is:

- status **`0x41`**, not `0x85` — *unexpected target bus free terminated a command*;
- at `istate = 1` (**STARTING**), not `IDLE`;
- on `unit = 8113A44`, which is `0x30` — three units of sixteen bytes — past the CD's
  `8113A14`, so **target 6, the root disk**;
- with `seglen = 800`, a 2048-byte filesystem block rather than the raw 512.

So `startany()` did its job and started the next queued request on the root disk, and *that*
command terminated with an unexpected bus free. `itab[0x41] = 1` and `atab[STARTING][1] = 1`,
so it took `badhardware()` like any unrecognised status.

## What that means

The release satisfied the contract's acceptance test — `CIP`, `BSY`, `LCI` and `INT` all clear
after the Disconnect — and the very next selection still found the bus unusable.

**Chip-level acceptance is not proof that the SCSI bus is free.** `ASR.BSY` reports the WD's own
state, not whether a target is still asserting BSY on the cable. A CD-ROM that was interrupted
mid-`DATA_IN` with 1536 bytes still to send has every reason not to have let go yet.

Whether the root disk's `0x41` is caused by our Disconnect or is independent cannot be settled
from one run. The timing is not subtle, though: it is the first command after the release, and
this machine has run for months without a `0x41`.

## Where this leaves the fix

Landed and worth keeping as it stands: the CD no longer takes the controller down at the moment
it is read, and the request fails properly. That was the whole of the `0x49` contract.

Not finished: the controller is still lost on the *following* command. Two candidates, neither
guessed at here —

1. the release needs to wait for, or verify, actual bus-free at the SCSI level rather than
   chip-command acceptance; or
2. `0x41` at `STARTING` needs handling of its own, since it is a legitimate status meaning the
   target went away, and the driver treats it as illegal.

`0x41` is one of the two statuses the bus-release contract itself accepts as proof that the bus
is free. The driver's own `itab` calls it illegal. That contradiction is the next thing to
resolve, and it belongs in a contract before it belongs in code.
