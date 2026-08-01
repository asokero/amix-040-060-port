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
this morning (`prototypes/issue39_040.s`) there was no way to read it from userland at all. This
port has been running burst suites since July. The first long run with the instrument attached
found this in 100 minutes.

## What this is NOT yet

* **Not proven to be leaked pages.** `availrmem` is an accounting variable. A path that
  decrements it without a matching increment looks exactly like a real page leak from here.
  This port already has form for that class of bug — ISSUE-20 (`hat_swapout` mine), and the
  `segu` u-page keepcnt hold that was ISSUE-7.
* **Not proven to be new.** Nothing in `codepub040` or `issue39_040` allocates memory, so it is
  very unlikely to have been introduced today, but "unlikely" is not measured. The instrument is
  new; the behaviour probably is not.
* **Not proven to be unbounded.** A cache growing to a ceiling would look like this for a while
  and then flatten. Nothing flattened inside 100 minutes, but 100 minutes is what there was.

## The one measurement that settles the first question

**Does `availrmem` recover when the load stops?** Sample it idle for ten minutes after a suite.

* Recovers → it is reclaimable accounting, and the story is about reclaim latency, not a leak.
* Does not recover → pages or accounting are being lost per unit of work, and the next question
  is *which* work: `burst4.sh` is 6 concurrent 4 MiB copies plus `hat_dup_cow 64`, so bisect the
  copies against the fork/COW half.

This was not done because the machine had to be shut down. It is cheap and it is the first thing
to run next session, before anything else on this list.

Second measurement, nearly as cheap: run the same experiment on the **31.7. accepted image**
(`unix-040-260731-33`, on the NAS) with the same instrument spliced in, to date the behaviour.

## Relationship to ISSUE-39

They are not the same thing, and the run says so. ISSUE-39 fired **once**, in suite 1, when
`availrmem` was at its *highest* for the run (4003 pages) — and did **not** fire again during the
following 75 minutes while `availrmem` fell to 1847 and `freemem` averaged ~100. Whatever drives
`hat_sdtalloc` to fail, it is not "the machine has been draining for a while".

Full record of the ISSUE-39 half: `ISSUE39-MEMORY-REGIME-260801.md`. Logs:
NAS `amix/hwtest-260801/{burstrepeat.log,memwatch-repeat.log,burst-suite[1-4].log}`.
