# Stage D works — ISSUE-54's trigger no longer kills the controller

`68060-260830-06`, 2026-08-30. Reported against the design's eight falsification conditions
individually, as it asks, rather than summarised as "the machine survived".

## The line, with the number predicted before the run

```
a3p ss=49 cp=46 tc=0 di=43 con=8C as=0
a3p req=8113F74 op=28 rd=1 addr=96D9800 len=200
a3p sac=96D99F0 cntr=C verdict=2 retry=0
a3p D RETIRED busfree=1 sent=1 ss=41 bytes=1536
```

**`bytes=1536`.** 2048 − 512, the exact residual of the CD's block after the 512 the driver
asked for. That number was written into the predictions before the run as the one that would
confirm the block-size root cause independently, and it came back exact.

**There is no `a3091:` line.** `badhardware()` never ran. The driver did not die.

## Against the eight conditions

| # | condition | result |
|---|---|---|
| F1 | `COM=0x20` rejected or its accounting inexact | did not happen — 1536 bytes discarded exactly |
| F2 | still in DATA IN after `0x800` discarded | `d_exp_bytes = 0`; the phase changed at 1536 |
| F3 | no recognised phase or bus-free within bounds | `d_exp_poll = d_exp_dbr = d_exp_ss = d_exp_phase = 0` |
| F4 | SDMAC or host buffer changes during discard | `dma_on = 0` throughout |
| F5 | action 9, action 0, or a success callback reached | no `0x19`, no `0x4B`, no `a3091:` line at all |
| F6 | `startany()` before bus free is consumed | `d_busfree = 1` first; `d_notowner = 0` |
| F7 | a late `0x85` after a root command starts | none |
| F8 | the root request fails after cleanup | **`8+0 records in`, `ROOT=0`** |

## Twice, which is the difference between luck and a mechanism

```
CD:   dd: read error: I/O error    0+0 records    CD=2
ROOT: 8+0 records in / 8+0 out                    ROOT=0

d_try 2   d_sent 2   d_busfree 2   d_failed 2
d_quar 0  d_badphase 0  d_badstat 0  d_notowner 0
```

Two phase transitions used of the four allowed: `DATA IN` → `MESSAGE OUT` → bus free. The ABORT
byte went out both times and the target answered `0x41` both times.

## What is fixed and what is not

**Fixed.** Reading a device whose block size is not 512 no longer takes the controller down. The
request fails with `EIO`, `dd` reports it, and every other disk on the bus keeps working.

**Not fixed, and not claimed.** The CD is still unreadable — this adds no block-size support, and
`docs/contracts/A3091-DATA-IN-DRAIN-DESIGN.md` is explicit that it is bounded containment for the
measured tuple rather than a general recovery. `0x48` `DATA_OUT` and `0x4A` `CMD` remain
unobserved and unhandled. Target 4 is a tape drive and has never been touched. `a2091.c` has the
identical tables and the identical defect.

## What it took

Six hardware runs, six power cycles, six `fsck`s, and four designs. The first three were
implemented to specification and failed on silicon for reasons the specification did not
anticipate: chip-level acceptance is not bus-free; the `0x41` belonged to the root disk, not to a
late CD event; and ATN alone does not make a target mid-transfer stop and listen. The fourth
worked, and the thing that made it different was proving its primitive in a separate build that
attempted no recovery at all.

## The repeat without load, after the panic

The first run of this kernel ended in a kernel panic during `burst4.sh`. The machine had been
unusually unstable all day — one unexplained boot hang that did not reproduce, and several power
cycles — so the connectors were cleaned and the trigger repeated on a clean boot **with no other
load at all**:

```
CD1=2  dd: read error: I/O error   0+0 records
R1=0   8+0 records in / 8+0 out
CD2=2  dd: read error: I/O error   0+0 records
R2=0   8+0 records in / 8+0 out

a3p D RETIRED busfree=1 sent=1 ss=41 bytes=1536
a3p D RETIRED busfree=2 sent=2 ss=41 bytes=1536

d_try 2  d_sent 2  d_busfree 2  d_failed 2
d_quar 0  d_badphase 0  d_badstat 0  d_notowner 0
dma: prep_to 2464 + prep_from 2983 == cmpl_to + cmpl_from,  all must-stay-zero at 0
```

No panic, no `a3091:` line, no warning.

## The panic, recorded without a conclusion

```
WARNING: DBG wb040 replay UNRESOLVED addr=80D96C0 wbs=6
TRAP
proc = 40254E00 (pid 536, mail) psw = 2004
pc = C
PANIC: KERNEL FAULT psw=0x2004, pc=0xC, fmt=0x0, vector=0x3D (Reserved)
```

Facts, and only facts. Both Stage D retirements completed and are separated from this by a blank
line. `wb040 replay UNRESOLVED` is **this port's own diagnostic**, installed by ISSUE-42's fix to
name a dropped store rather than swallow it, and ISSUE-42 has been closed on hardware since
2026-08-13 — so the warning is designed behaviour, not a new defect. `pc=0xC` is a wild jump and
is the panic's proximate cause. It is the only occurrence of `UNRESOLVED` in the entire serial
log. The process is `mail`, not the burst's `cp` or `hat_dup_cow`.

This is **not** attributed to Stage D and **not** cleared of it. What can be said is that the
repeat without load was clean twice, so if Stage D contributes it needs the burst's load to do
so, and the day's independent instability makes hardware the first hypothesis.

The burst regression is therefore **not yet run to completion on this kernel** and this record
does not claim it.

## A measurement artifact worth naming

`dma_cmpl_count` first read 16 higher than `cmpl_to + cmpl_from`, which looked like a broken
invariant. It is not: the four pairing counters come back in one `kpeek` while `cmpl_count` comes
back in a second one, and ordinary disk I/O continued between the two calls. A later read with
the machine quiet had them exactly equal. The snapshot was not atomic — the same class of error
as reading a counter block at a remembered address, which cost this project four separate
mistakes in two days.
