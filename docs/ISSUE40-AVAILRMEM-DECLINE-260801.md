# ISSUE-40 (candidate) — `availrmem` declines monotonically under sustained load

Found 2026-08-01 on the A3000 + Mercury 040, base `68040-260801-04`, during the ISSUE-39 rate
experiment. **Not a diagnosis — a measurement plus the one check that would settle it.**

## What was measured

Four consecutive 16-burst suites, no reboot in between, `memwatch` sampling every 2 s.
Ten-minute buckets over the first 100 minutes:

```text
t(s)            availrmem (pages)        freemem
                mean    min    max       mean
   0- 599       3981   3831   4153        630
 600-1199       3698   3515   3867        508
1200-1799       3405   3240   3555        518
1800-2399       3128   2980   3270        381
2400-2999       2891   2721   3004        286
3000-3599       2690   2564   2743        170
3600-4199       2450   2307   2596        254
4200-4799       2235   2125   2339        100
4800-5399       2035   1935   2138        124
5400-5999       1847   1745   1977        102
```

Ten buckets, every one lower than the last, **both min and max falling** — about **21 pages/min
(86 KiB/min), essentially linear, with no recovery anywhere in 100 minutes**. Across the whole
day the same variable read ~6828 pages in the morning.

The suite durations track it:

```text
suite 1   24 min 37 s
suite 2   27 min 03 s
suite 3   34 min 56 s
suite 4   45 min 56 s      <- 87 % slower than suite 1, same work each time
```

All four suites still produced **96/96 correct sums**. Whatever this is, it is not corrupting
data — it is consuming something and making the machine slower.

## Why nobody saw it before

`availrmem` is a COMMON symbol placed in `.bss` by the loader; until the pointer table landed
this morning (`src/issue39_040.s`) there was no way to read it from userland at all. This
port has been running burst suites since July. The first long run with the instrument attached
found this in 100 minutes.

## What this was not yet, when first written

* Not proven to be leaked pages rather than lost accounting — **now answered below: accounting.**
* Not proven to be unbounded — **still open**, though two clean per-load steps make a saturating
  cache hard to sustain as an explanation.
* **Not proven to be new.** Nothing in `codepub040` or `issue39_040` allocates memory, so it is
  very unlikely to have been introduced today, but "unlikely" is not measured. The instrument is
  new; the behaviour probably is not. Dating it needs one run on `unix-040-260731-33`.

## ANSWERED — it does not recover, and it is an ACCOUNTING leak, not a page leak

Run on a **fresh boot** of the same base, 15:03–15:32: baseline idle → load → 10 min idle →
load → 10 min idle, reading both variables at every boundary (`issue40.sh`).

```text
phase             freemem  availrmem   d(availrmem)
boot+0s              4880       6878
baseline idle        4873       6872          -6      <- 2 min idle: flat
after load 1         5606       5750       -1122
idle+5min            5369       5721         -29
idle+10min           5293       5687         -34      <- no recovery, still drifting DOWN
after load 2         4222       4643       -1044
idle+5min            4262       4636          -7
idle+10min           4231       4607         -29      <- no recovery again
```

**Two loads, two near-identical permanent steps: −1122 and −1044 pages** (~4.3 MiB each). Ten
minutes of idle returns nothing; it keeps drifting slowly downward. That is answer (b): something
is lost per unit of work, and the step is reproducible enough to be a per-load constant.

**And the shape names the class of bug.** `freemem` behaves *correctly* throughout — after load 1
it stood at 5606, **higher** than the 4873 baseline, because deleting the test files returned
their cached pages to the free list. Real pages are being freed and re-listed exactly as they
should be. It is only `availrmem` — the *accounting* of available resident memory — that
ratchets down and never gets credited back.

> ~~ISSUE-40 is an `availrmem` accounting leak: a path that decrements it on the way in without a
> matching increment on the way out. Pages are not being lost; the kernel's belief about them is.~~

**⚠ THAT INFERENCE WAS WRONG — see "Codex's prediction, and my error" below.** A real 4 KiB page
is retained per `exec`. `freemem` looked healthy because it includes reclaimable cache traffic
that can return more pages than the leak holds; it is not the ownership counter.

That also supplies the mechanism for the slowdown: as `availrmem` falls, every consumer that
sizes itself against available resident memory becomes more conservative, and the pageout
scanner runs more. Identical suites got 87 % slower over the same period.

It matches this port's known bug class — ISSUE-20 (`hat_swapout` mine) and the `segu` u-page
keepcnt hold that was ISSUE-7 are both of exactly this shape.

Baseline is per-boot: a fresh boot reads 6878 again, so nothing is being lost across reboots.

## Bisected: it is `exec`, and it is exactly one page

First halving (`issue40b.sh`, alternating so each step is read against its own neighbours):

```text
file IO alone      -46, -53 pages
fork/exec alone   -988, -982 pages
```

Then with an **exact denominator** — `test-tools/leaktest.c` does exactly N forks, or exactly N
fork+exec pairs, because the shell loops used until then were themselves forking and exec'ing
(`k=\`expr $k + 1\``) and a ratio over a guessed denominator is not a measurement:

```text
                            availrmem      delta / 300
settled                          2299
300 x fork + exit                2300           +1     <- fork loses NOTHING
300 x fork + exit                2284          -16
300 x fork + exec + exit         1980         -304     <- -1.013 per pair
300 x fork + exec + exit         1665         -315     <- -1.050 per pair
```

> **Exactly one page of `availrmem` per `exec`. Zero per `fork`.**

The file-IO half's ~50 pages is consistent with its own process count (8 `dd` + 8 `cat` per
round, plus shell overhead) rather than with the IO.

## A hypothesis, eliminated by measurement before it reached the record

Our own `hat_ptfree` (`hat040.s` V2.1) credits `availrmem` **only** on the path that reaches
`page_free`; its `Lpf_leak` exit is even commented "leak (V1 behavior)" and its print is capped
at 8 — the exact shape of a defect that hides, and the shape this project has been bitten by
before. It fit the symptom perfectly.

**It is not that.** `Lpf_n` (`.data+0x17f26`, runtime `0x080FC4AE`) reads **0** after thousands
of execs, so that exit is never taken. Checked before writing it down, which is the only reason
it is a footnote here instead of a correction later.

## Codex's prediction, and my error

`AVAILRMEM-ACCOUNTING-AUDIT.md` (analyysirepo, commit d27a303) answered the task, and it
anticipated my reasoning in order to refute it:

> "The observation that `freemem` recovers after deleting test files does not refute this physical
> leak. `freemem` includes reclaimable/cache-page traffic; the workload can return more cached
> file pages than the SDT allocator holds. `pages_pp_kernel` is the direct ownership counter."

It named a counter I had not been reading and a pre-registered, falsifiable prediction: across
300 fork+exec, `availrmem −300`, `availsmem −300`, `pages_pp_kernel +300`, with
`availrmem + pages_pp_kernel` invariant. Measured on hardware (`issue40c.sh`), with
`pages_pp_kernel` at `.data+0xb528` = `0x080EFAB0` recomputed independently before trusting it:

```text
phase          availrmem  availsmem  pages_pp_kernel |  d_ar    d_as   d_ppk | d_ar+d_ppk
baseline            1252      25300             6481 |
300 x fork          1260      25423             6473 |    +8    +123      -8 |    +0
300 x fork+exec      941      25104             6792 |  -319    -319    +319 |    +0
300 x fork+exec      633      24796             7100 |  -308    -308    +308 |    +0
300 x fork           625      24788             7108 |    -8      -8      +8 |    +0
```

**All three counters move by the same magnitude with the predicted signs, and
`availrmem + pages_pp_kernel` is conserved exactly in every phase.** The fork control does not
move. So it is **not** a pure accounting bug: one real 4 KiB page is genuinely retained by the
SDT allocator per dynamic `exec`, and a naked `availrmem++` would make the counters offer a page
that is not there.

Root cause, from the audit: a dynamic `exec` creates a **17-unit** legacy SDT allocation for
libc through `segvn_create → hat_map → hat_growsdt → hat_sdtalloc`. Two 17-unit allocations
cannot share a 32-unit SDT page, so every exec address space gets its own 4 KiB backing page —
and the port's own `hat_free040` (`0x000d82bc`) tears down only the live 040 A/B/C tree, never
calling `hat_growsdt(..., 0)` / `hat_sdtfree`. Debit in retained stock code, missing lifetime
edge in the port's override.

That is the third time in one day that a measurement corrected me on this issue, and the first
time the correction was predicted in advance by the analysis rather than found afterwards.

## Handed to Codex

`archive/ISSUE40-AVAILRMEM-TASK.md` carries the fact, a complete census of every `availrmem` writer in
the image mapped to its function, the 3b2 source contract for each, and the eliminated
hypothesis. The acceptance criterion is stated so a wrong answer is refutable: the site must
predict **−1 per exec and 0 per fork**.

Still worth doing here, and cheap: run the same experiment on the **31.7. accepted image**
(`unix-040-260731-33`, on the NAS) to date the behaviour, since nothing in today's units
allocates memory and this is very unlikely to be new.

## Relationship to ISSUE-39

They are not the same thing, and the run says so. ISSUE-39 fired **once**, in suite 1, when
`availrmem` was at its *highest* for the run (4003 pages) — and did **not** fire again during the
following 75 minutes while `availrmem` fell to 1847 and `freemem` averaged ~100. Whatever drives
`hat_sdtalloc` to fail, it is not "the machine has been draining for a while".

Full record of the ISSUE-39 half: `ISSUE39-MEMORY-REGIME-260801.md`. Logs:
NAS `amix/hwtest-260801/{burstrepeat.log,memwatch-repeat.log,burst-suite[1-4].log}`.
