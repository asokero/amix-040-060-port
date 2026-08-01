# ISSUE-39 characterisation — the memory regime, and a negative result that narrows it

Instruments: `prototypes/issue39_040.s` (kernel), `test-tools/memwatch.c` (userland).
Measured 2026-08-01 on build id 68040-260801-04, first in the emulator (measurements 1–2) and
then on the A3000 + Mercury 040 (measurements 3–4). Both agree.

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

## Measurement 4 — the burst suite itself, and the regime is now a number

The accepted battery re-run on this base (A3000 + Mercury 040, `68040-260801-04`):
`burstloop.sh 4` = 4 rounds × 4 bursts × (6 × 4 MiB concurrent copies + `hat_dup_cow 64`),
with `memwatch` sampling once a second across the whole thing. 11:02:53 → 11:24:43, ~22 minutes.

```text
burst result            96/96 correct sums, zero anomalies
memwatch, 1213 samples  freemem  min 0   max 4470   mean 883 pages (3.4 MiB)
                        45 % of samples below 50 pages (200 KiB free)
                        60 % of samples with the pageout scanner running
                        availrmem 4573..5200 -- barely moves, again
hat_sdtfail_n = 0       i39_fail_n = 0
```

The machine enters the regime within **five seconds** of the first burst and stays in it for
twenty minutes. This is the workload that produced ~1 failure per 16-burst suite on 2026-07-31 —
and this time it produced **none**.

Two honest readings, and the difference matters:

* A single zero against a rate of ~1/suite is **not** evidence of a fix — for a Poisson process
  with mean 1, P(0) ≈ 37 %. Nothing in this session should have changed `hat_sdtalloc`, and
  nothing here claims it did.
* What the run *does* establish is the **regime, as a number instead of a guess**: sustained
  depletion is where ISSUE-39 lives (45 % of a 22-minute run under 200 KiB free, scanner active
  60 % of the time), and yet depletion alone does not fire it — a full suite spent almost
  entirely inside that regime produced zero failures. Necessary, not sufficient. The remaining
  variable is contiguity.

Also from this run: `hat_pfnmiss_n` read **10** before and **10** after 96 bursts. The
2026-07-31 calibration ("~10 at boot, then exactly +2 per `devmaptest` and nothing from any other
workload, including two 16-burst suites") now holds across a third suite.

## What is still owed

The failure itself. When it next fires, the latch answers the question in one reading: a **high**
`freemem` at `i39_fail_freemem` confirms fragmentation outright and turns ISSUE-39 into a
kernel-map question. Everything needed is on the machine (`/payload.bin`, `/tmp/hat_dup_cow`,
`/tmp/burstrun.sh`), so repeat runs cost one command. Logs from this run:
NAS `amix/hwtest-260801/{memwatch-burst.log,burstloop.log}`.

Repeat the run with:

```sh
nohup sh /tmp/burstrun.sh > /tmp/burstrun.out 2>&1 &     # ~22 min, detached
```

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
