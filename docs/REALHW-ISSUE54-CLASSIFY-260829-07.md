# ISSUE-54 classification capture — `68060-260829-07`, 2026-08-29

The audit's classification build, run once on silicon. Amiga 3000, Mercury 68060.
Trigger `sync; sync; dd if=/dev/rdsk/c3d0s0 of=/dev/null bs=512 count=1`, sent over telnet.
Predictions were committed **before** the run in
`test-tools/issue54-classify-predictions-260829.md`.

## The capture

```
a3p ss=49 cp=46 tc=0 di=43 con=8C as=0
a3p req=8113214 op=28 rd=1 addr=971C000 len=200
a3p sac=971C1F0 cntr=C verdict=2 retry=0
a3091dbg ss=49 istate=1 unit=8113774 head=0 dmaon=1
a3091dbg segstate=2 segseq=5108 segpa=971C000 seglen=200 segdir=1
a3091dbg dev=DD0000 istr=0 entry=D0
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=5108
a3091: 0x49 1 0x8113774
a3091dbg ss=85 istate=3 unit=8113774 head=81137A4 dmaon=1
a3091dbg segstate=2 segseq=5108 segpa=971C000 seglen=200 segdir=1
a3091dbg dev=DD0000 istr=F800 entry=F8D0
a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=5108
a3091: 0x85 3 0x8113774
```

Read from a photograph of the console: this is the base kernel, which does not mirror to
serial, and the wedge takes the root disk so kernel memory is unreachable afterwards. The
serial-mirror twin `build/unix-040-quiet` is now built for the next one.

## Ten predictions, ten held

| # | predicted | measured | |
|---|---|---|---|
| H1 | three `a3p` lines ahead of the stock line | three, in order | ✓ |
| H2 | only `0x49` arrives | `ss=49`, one occurrence | ✓ |
| H3 | `rd = 1` | `rd=1` | ✓ |
| H4 | `op` = `0x28` READ(10) or `0x08` READ(6) | `op=28` | ✓ |
| H5 | `nbyte = 0x200` | `len=200` | ✓ |
| H6 | `di` bit 6 set, agreeing with `rd` | `di=43` → DPD set, **and target id 3** | ✓ |
| H7 | `retry = 0` | `retry=0` | ✓ |
| H8 | verdict ∈ {1, 2, 5}, **not 4** | `verdict=2` | ✓ |
| H9 | `cp` neither 0 nor 0xff | `cp=46` | ✓ |
| H10 | `sac` inside `[segpa, segpa+seglen]` | `971C1F0` in `971C000..971C200` | ✓ |

`di=43` is worth its own line: bit 6 is the data-in direction and the low bits are the target
id, so the register independently names **target 3** — the target `c3d0s0` addresses. The
capture identifies the command that caused it, field by field, without being told.

## The verdict is 2, and the data phase was finished

`cp=0x46` and `tc=0`. By the audit's interpretation table that is *"target overrun / unexpected
extra data; do not resume data."*

**This overturns the reasoning that made action 9 look wrong.** That refutation rested on
`0x49` meaning *mid-data-phase, with more to transfer*. It does not, at least not here: the
count is exhausted and the command phase already reads `0x46`, which is precisely the value
action 9 writes to resume **past** the data phase. The chip is in the state action 9 exists for.
So the earlier reasoning was sound and its premise was wrong, which is why this build was a
measurement rather than a fix.

The DMA cursor supports the same reading. `sac` is 496 bytes past `segpa` of a 512-byte segment
— 16 short, one SDMAC FIFO's worth in flight. The transfer had reached its end, not its middle.

## The hypothesis, confirmed the same day

**Target 3 is a ZuluSCSI-emulated CD-ROM — a Civilization II disc — and a CD-ROM data block is
2048 bytes.** The driver assumes 512. Confirmed from the ZuluSCSI configuration, not inferred.

Every number follows. The driver asked for 512; `tc` reached 0 with the target still in
`DATA_IN` holding 1536 more; `cp` read `0x46` because the count it had been given was complete;
the mismatch is `MIS_1|DATA_IN`. `sac` is 16 bytes short of the segment end, which is the SDMAC
FIFO.

**ID 4 is a tape drive**, so `/dev/rdsk/c4d0s0` is a second trigger and equally destructive.

This settles the fix, and it is neither candidate this line proposed. Resuming is wrong because
the driver's LBA arithmetic is in 512-byte units: for this target it addresses the wrong place,
not merely the wrong length, so a completion reported as good would be wrong data. Keeping the
first 512 bytes of a 2048-byte block is wrong for the same reason. The request must **fail** —
`cp->okay` is already FALSE and action 5 leaves it so — and the bus must be **released**, which
the audit establishes action 5 does not do after `MIS_1`.

## The hypothesis as it was written, before the confirmation

If the count is exhausted and the target is still in `DATA_IN`, the target has more to send than
was asked for. `dd bs=512` issues READ(10) for one 512-byte block; a target whose native block
is larger answers with its own block size. The ledger already describes target 3 as a device
that does not hold a normal disk.

That would make ISSUE-54 not a protocol hiccup but a missing case: **the driver has no handling
for a target that returns more data than requested.** It is consistent with every number here
and it is not established — nothing in this capture reads the target's block size, and the
16-byte gap is attributed to the FIFO by inference rather than measurement.

## What was not obtained

`a3p_seen`, `a3p_n48/n49/n4a` and `a3p_prevreq` were never read: the wedge removes the root
disk, so the counter block is unreachable and only the printed lines survive. Both facts were
known before the run and are the reason the classifier prints as well as latches. The counters
would still be worth having on a machine where the dying unit is not the root disk.

The second capture (`ss=85 istate=3`) is `DISC_1` arriving at `DEAD`, mapping to action 1 by
construction. It is a consequence, not a second fault. `head=81137A4` is non-zero there where it
was zero in the first: the request is still queued, unfinished, as the DEAD state leaves it.

## Machine state

Wedged as designed: ping answers, telnet accepts a connection, no shell — login needs the disk.
Power cycle and `fsck` required.
