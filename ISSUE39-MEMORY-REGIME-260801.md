# ISSUE-39 characterisation — the memory regime, and a negative result that narrows it

Instruments: `prototypes/issue39_040.s` (kernel), `test-tools/memwatch.c` (userland).
Measured 2026-08-01 in the emulator on `unix-040` build id 68040-260801-04.

## The obstacle that had blocked this, and how it is gone

`freemem`, `availrmem`, `availsmem`, `deficit`, `physmem`, `maxmem` and `nscan` are **COMMON**
symbols in the ET_REL kernel image — `nm` reports their *size* (`00000004 C freemem`), and the
AMIX loader is what finally places them in `.bss`. There was no address to compute the way
counter addresses are computed, which is why every earlier session could count `hat_sdtalloc`
failures but never say what memory looked like when they happened.

The fix is one line of assembler per global:

```asm
i39_freemem_p:  .long   freemem     | a RELOCATION -- the loader writes the runtime address here
```

`kpeek` reads the pointer at a computable `.data` address and follows it. It generalises to any
COMMON global this port ever needs to watch. Verified on the guest: the table reads back
`i39_magic = 0x49333921` and seven pointers all inside the kernel window (`0x08117db0` …), and
`physmem` × 4 KiB = **32764 KiB**, which is the machine's actual RAM — so the pointer resolution
*and* the 4 KiB page assumption are both confirmed by one reading.

## What was also added

`hat_sdtfail_count` (moved from `kdbg040.s` into `issue39_040.s`) now latches
`freemem`/`availrmem`/`deficit` at the **first** failure and `freemem`/`availrmem` at the **last**
one. First and last, not a ring buffer: putting a buffer index on a path that runs while memory
is already short is not worth it, and two samples plus the free-running counter answer the
question.

## Measurement 1 — the machine reaches freemem = 0 routinely

Plain sequential file IO (4 × 4 MiB write + read back), nothing exotic:

```text
t(s)  freemem  availrmem  availsmem  nscan
   0     5171       6828      30888      0
   6      214       6740      30803      0
   7        0       6735      30795     50     <- pageout scanner engaged
  13       24       6723      30783     50
  14     3365       6719      30783      0
```

`freemem` hits **exactly 0** and stays there ~6 s, while `availrmem` barely moves
(6828 → 6719). The free page list is the constraint; resident-memory accounting is not.

## Measurement 2 — the negative result, and it is the useful one

Free-list depletion **plus** a fork/exec storm (8 × 4 MiB IO concurrent with six shells each
exec'ing 60 times), 45 s:

```text
freemem   min 0   max 5259   mean 2194 pages     18 s cumulative at freemem = 0
availrmem min 5919 max 6685
hat_sdtfail_n = 0        i39_fail_n = 0        <- two independent counters, agreeing
```

**18 seconds at freemem = 0 with a fork storm running did not produce a single
`hat_sdtalloc` failure.**

That kills the standing assumption. `hat_sdtalloc` needs **contiguous** memory for segment
tables, and this says the failure is not driven by depletion — the machine sits at freemem = 0
regularly and survives it. So ISSUE-39 is a **fragmentation** phenomenon, and the axis to chase
is whatever the burst suite does that a fork storm does not: large contiguous kernel-map
allocations, or long-lived fragmentation accumulated across rounds.

The two counters reading 0 together is also the instrument cross-check — `hat_sdtfail_n`
(kdbg040) and `i39_fail_n` (issue39_040) are incremented independently in the same wrapper.

## Measurement 3 — the same negative result on real silicon

Repeated on the A3000 + Mercury 040 (`68040-260801-04`) later the same day, 90 s, load scaled up
(8 × 8 MiB IO concurrent with six shells × 80 execs):

```text
freemem   min 0   max 4631   mean 2781 pages
availrmem min 5414 max 6482
hat_sdtfail_n = 0        i39_fail_n = 0
```

Real hardware reaches `freemem = 0` too, and again produces **no** `hat_sdtalloc` failure. The
emulator and the machine agree, so the negative result is not an artefact of emulation. The
pointer table resolved to the same addresses on both.

## What is still owed

The burst suite specifically — that is where the ~1 failure/run was measured, and no other
workload has reproduced it. Everything needed is now on the machine.

The burst suite is where the ~1 failure/run was measured, and it needs the hardware (the A3000
was powered off for this whole session). The run is now one command longer:

```sh
./memwatch <i39_magic addr> 900 500 > /memwatch.log 2>&1 &
sh burstloop.sh 4
kpeek <i39_fail_n addr> 6        # the latch: freemem/availrmem at first and last failure
```

If the latch shows a *high* `freemem` at the failure, fragmentation is confirmed outright and
this becomes a kernel-map question rather than a memory-pressure one.

Runtime addresses for build 68040-260801-04 (`0x08000000 + textsize 0xe4588 + .data offset`) —
**recompute after every relink**, and read the `hat_cm_ram` anchor at `0x080FC888` (must be
`0x20`) before trusting any of them:

```text
i39_magic     0x080FCF9C   (anchor, must read 0x49333921 "I39!")
i39_freemem_p 0x080FCFA0   i39_availrmem_p 0x080FCFA4   i39_availsmem_p 0x080FCFA8
i39_deficit_p 0x080FCFAC   i39_physmem_p   0x080FCFB0   i39_maxmem_p    0x080FCFB4
i39_nscan_p   0x080FCFB8
i39_fail_n    0x080FCFBC   i39_fail_freemem 0x080FCFC0  i39_fail_availrmem 0x080FCFC4
i39_fail_deficit 0x080FCFC8  ..._freemem_last 0x080FCFCC  ..._availrmem_last 0x080FCFD0
hat_sdtfail_n 0x080FCF74
```
