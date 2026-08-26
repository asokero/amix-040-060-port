# The A3091 wedge, captured — 2026-08-26

The interposer built this morning fired on its second burst run. This is what it caught, and
what that removes from the list.

## The capture

    a3091dbg ss=16 istate=0 unit=8112DE4 head=0 dmaon=0
    a3091dbg segstate=0 segseq=168807 segpa=9E9E800 seglen=800 segdir=0
    a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=168807
    a3091: 0x16 0 0x8112DE4

Image `68060-260826-04`. Console only — the base kernel is silent on serial, so this exists
because it was photographed.

`unit=8112DE4` resolves the same way as the first occurrence: `.bss` base `0810F09C`, `units` at
`08112D84`, `sizeof(struct unit)` 16, so `0x8112DE4 - 0x8112D84 = 0x60 = 6 x 16` → **`units[6]`,
the root disk**. Same unit as 2026-08-25, on a different build with a different `.bss` layout.

## What the state says

| field | value | meaning |
|---|---|---|
| `ss` | `0x16` | `itab` input 8 — *"request has completed"* |
| `istate` | `0` | IDLE |
| **`head`** | **`0`** | **the start queue was empty** |
| **`dmaon`** | **`0`** | **the driver had no transfer armed** |
| **`segstate`** | **`0`** | **this port held no DMA ownership** |
| `segseq` / `whole` | `168807` | equal — every arm got its cache push |
| `segpa/seglen/segdir` | `9E9E800` / `0x800` / `0` | last transfer: 2048 bytes **to** the device |
| `zarm rarm owned noprep ovf` | all `0` | every must-stay-zero diagnostic still zero |

**The driver was completely quiescent and a completion interrupt arrived anyway.**

## What that rules out — including my own hypothesis

`docs/A3091-WEDGE-PRESTUDY-260826.md` listed three ways this port's DMA hook could plausibly
have contributed, and said they were hypotheses to be tested rather than argued about. The
measurement tests them:

| hypothesis | verdict | on what evidence |
|---|---|---|
| a late completion of something still in flight | **out** | `dmaon=0` — nothing was in flight |
| a race with `startany()` mid-setup | **out** | `head=0` — the queue was empty, there was nothing to start |
| **the prepare hook's `cpusha dc` widening a window** | **out** | `segstate=0` — not between prepare and complete at all |
| a dropped or mispaired prepare/complete | **out** | `owned=0`, `noprep=0`, `whole == segseq` |

The third was the one worth worrying about, because a whole-cache push is slow and the wrapper
raises no interrupt level. It is not what happened: there was no window, because no DMA was being
armed when the interrupt arrived.

That is the value of building the instrument rather than reasoning further. Three plausible
mechanisms, all mine, all wrong, and the state at the moment of death says so in one line each.

## Where it points instead

At the controller's interrupt and status path, not at this port's cache work.

The handler's entry is

    unless ((device) and (device->istr & 1<<4))  return;
    cipwait();
    ss = reg(SS);

If `istr` bit 4 is set without a new event, the handler reads `SS` — and `SS` holds the **last**
status. After a heavy run that value is `0x16`. That accounts for both the value and the timing.

`stopdma()` writes `device->cint = TRUE` (clear interrupt) immediately before clearing `dma_on`.
A latch that survives that clear would be delivered later — after the queue has drained, which is
exactly where both occurrences happened.

**This is a hypothesis, and it is stated as one.** What is established is the state at death, not
the cause of the interrupt.

## The operator's datum, which is the strongest correlation available

Twice, **both at the end of a burst run**, and not before. "At the end" fits a trailing interrupt
from the last transaction of a heavy run: the last DMA recorded here is the burst's final 2 KiB
write to the device.

Against that: the earlier sightings (roughly three, all after 2026-07-20) were not tied to
bursts. Whether those are the same fault is unknown; nothing was captured then.

## What would settle the mechanism

1. **Read `istr` and `SS` at death.** The interposer deliberately does not touch the device,
   because reading `SS` is what acknowledges the interrupt and this runs at the moment of a
   hardware anomaly. That reasoning still holds for `SS` — but `istr` is a status register and
   reading it is harmless, and it would say whether bit 4 was genuinely set. That is a small,
   defensible addition now that the safe fields have been read and found insufficient.
2. **Rate against load.** Two occurrences, both post-burst. A third with the same
   `head=0 dmaon=0 segstate=0` signature would make the pattern rather than the anecdote.
3. **Whether it is survivable.** The driver dies because `atab`'s DEAD row absorbs everything and
   `startany()` requires IDLE. A completion with nothing outstanding is arguably *ignorable* —
   but changing a 1991 driver's DFA on a hypothesis is not something to do before the mechanism
   is known.

## Filed alongside

ISSUE-51 — a burst read returned wrong bytes silently, same run, file intact afterwards. The two
may or may not be related; nothing links them yet beyond both appearing under burst load.

## fsck after this wedge — the first one captured

    ** Phase 1 - Check Blocks and Sizes
    ** Phase 2 - Check Pathnames
    ** Phase 3 - Check Connectivity
    ** Phase 4 - Check Reference Counts
    ** Phase 5 - Check Cyl groups
    SUMMARY INFORMATION BAD
    SALVAGE?  yes
    28845 files, 448513 used, 368100 free (4172 frags, 45491 blocks, 0.5% fragmentation)
    /dev/rdsk/c6d0s1 FILE SYSTEM STATE SET TO OKAY

    ***** FILE SYSTEM WAS MODIFIED *****

**The filesystem was modified**, which settles the caveat recorded earlier the same day: two
previous dirty boots ran `fsck` and "asked nothing", and that was noted as *not* meaning nothing
was repaired. It did repair something, and `SALVAGE? yes` is preen mode answering itself rather
than a question anyone was asked — so the earlier boots almost certainly did the same silently.

**What was repaired is the benign class.** `SUMMARY INFORMATION BAD` is the cylinder-group free
block and inode summary being stale, which is the textbook consequence of an unclean shutdown.
Phases 1 through 5 found nothing else: no unreferenced inodes, no bad blocks, no connectivity
errors, no reference-count errors. A driver that died mid-operation with the root disk as its
current unit did not damage the filesystem's structure.

That is worth knowing in both directions. The repair is real and the earlier "clean" readings
were overstated; and the damage is confined to accounting the kernel rebuilds anyway.

