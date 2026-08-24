# Symbolizing a Z3660 interpreter-profiler capture

`tools/prof-symbolize.py` turns the serial output of the Z3660 accelerator firmware's
profiling build (`BOOT-prof.BIN`) into a symbolized profile of the guest — which AMIX kernel
functions the 68k interpreter is spending its time in, which opcodes it is dispatching, and
where inside the interpreter that time goes.

The firmware emits raw records and nothing else; symbolization belongs here because this is
where the kernel artifact and its symbol table live. The wire format is versioned;
**versions 1 and 2 are both implemented**, and the tool **refuses a version it does not
know** rather than guessing — the record layout, the flag bits and the ASCII dump grammar
are all versioned by that one number, so a guess would silently relabel a whole profile.

The contract lives on the firmware side, in `Z3660_emu/src/uae/z3660_prof.h` and
`docs/profiler.md` of the Z3660 firmware tree. This tool is written against it and does not
have to be rebuilt in step with the firmware. **The authoritative v1 → v2 migration table is
the "v1 → v2: what moved, and why" section of that `docs/profiler.md`**; what follows here
is only what the *symbolizer* does about it.

Every version-dependent decision in the tool reads one table — `WIRE_VERSIONS` in
`tools/prof-symbolize.py`, under "THE VERSION SEAM". Nothing else in the file tests the
version number directly.

**The two versions do not merely differ in what they carry — they differ in what three of
their numbers mean.** That is why a v2 capture read under v1 rules produces a full report
and a wrong one, and why the tool refuses a capture that disagrees with itself about which
version it is:

| | v1 | v2 |
|---|---|---|
| `probe_cyc` | prices an enter/exit **pair** | prices **one transition** |
| counter id 12 | called `ATC_HIT`, counts translate *successes* | called `XLATE_OK` — the same count, the right name |
| a real ATC hit counter | does not exist | **id 19**, `ATC_HIT` |
| bucket id 8 | `TAIL` — the **whole** run-loop tail | `TAILADV` — the tail **residue** only |
| the rest of the tail | not separately visible | ids 11/12/13 (`TAILSAMP`/`TAILPOLL`/`TAILSPEC`) |
| `cpu_hz` / `wall_hz` | a compile-time BSP constant | the **runtime** clock, with `clk=cfg\|bsp` saying which |
| `cyc_span` vs `wall_ticks` | end at different moments | both stamped **at the dump** |

The **sample record and every flag bit are byte-for-byte identical** in the two versions, so
the `S`-line decoding did not change at all. Only the header and the `PROFD` block moved.

**Version 2 then grew twice more without moving**, and the tool reads all three firmwares
under the one version entry: counter ids **20–38** and the per-bucket **`[PROF] s` span
block** were *appended* rather than bumped. See
[What version 2 grew after it shipped](#what-version-2-grew-after-it-shipped) — the spans in
particular turn a corrected bucket share from an upper bound into a number, and retire the
`2 × IFETCH_CALLS` estimate that preceded them.

**And then one meaning *did* move while the version stayed at 2.** The firmware's rung 1d
brackets three stages out of the dispatch loop into ids 14–16, so **bucket id 0 stops being
the loop and becomes its residue** — and the firmware moves the printed *name* with the
meaning (`LOOP` → `LOOPRES`) instead of bumping, exactly as v1's `TAIL` became v2's
`TAILADV`. The version field therefore cannot tell you which shape you have and **the dump's
own id-0 name is the only thing that can**. See
[The LOOP split](#the-loop-split-rung-1d-and-the-ten-points-it-puts-within-reach); it is the
one place in this format where reading the version number is not enough.

```
python3 tools/prof-symbolize.py CAPTURE [--kernel build/unix-040] [--load-base 0x08000000]
                                        [--user BIN] [--probe-cost N] [--top N]
```

Standard library only, and no cross toolchain: the kernel ELF is parsed directly, so a
capture can be read on a machine that has the log but not the build environment. `--symbols
FILE --text-size N` accepts a saved `nm` dump instead, for the case where only that was
kept.

---

## Taking a capture this tool can read

Capture the whole serial console to a file, from before the first dump to after the last.
The tool finds every `[PROF]` dump in it and reports each; a session that takes `PROFD` then
`PROFR` then more of both is normal and is what `--dump N` selects between.

Five things are worth getting right at capture time, because none of them can be repaired
afterwards:

* **Size the ring to contain the workload.** The wrap-free window is `65536 / hz` seconds
  and `PROF <hz>` prints it when you arm. A wrapped ring is the tail of the run, not the run,
  and `drops=0` is the only thing that says otherwise — check it before believing any share.
* **Do not lose lines.** `PROF RING` is about 1.4 MB and two minutes at 115200. A terminal
  that scrolls, truncates or drops bytes produces a capture the tool refuses outright — the
  dump grammar is fixed-width precisely so that a lost line is *detectable* rather than
  quietly mis-parsed. Prefer `PROFR` (the newest 4096 samples, ~8 s) unless the whole ring
  is genuinely needed.
* **Keep the boot line, and read its `clk=`.** Under v2 it is `[PROF] profiling build v2:
  ARM clock … Hz (clk=cfg, PMU:wall 2.00), probe … cyc/transition`. It is the calibration
  every later number depends on and the only proof that core1 is the profiling image at all;
  it is printed once, at init. **If it says `clk=bsp`, stop and find out why** before
  trusting any rate below it.
* **Stop with `PROF OFF`, not with a bare `PROF`.** Every rung of the `PROF` ladder *arms*,
  and arming zeroes the buckets, counters and ring. v2 adds `PROF OFF` (short form `PROFO`)
  as a direct lossless stop from any armed state, and makes a bare `PROF` at an off-ladder
  rate stop rather than step up — which is what a boot profile armed from `z3660cfg.txt`
  needs, since it can only be retaken by cold-booting the board.
* **Note the load base.** Counter and symbol addresses are `load base + section offset`, and
  the base is *not* a constant. Every accelerator with its own RAM binds at `0x08000000`,
  but an A3640 running from A3000 motherboard RAM binds at `0x07000000` and every address
  would be off by 16 MiB. Read `tvaddr` from the loader's own boot output and pass
  `--load-base`; `tools/status-facts.sh` takes the same argument for the same reason.

### Dirty is not the same as damaged

A capture can be *intact* and still not be what the firmware wrote, and the two ways that
happens in practice are both repaired here rather than refused. Each repair is announced in
the warnings, and the record-count checks that actually prove a dump whole still have to
pass afterwards:

* **A logger's line prefix.** A console captured through a logger carries `HH:MM:SS ` ahead
  of every line. Only a *timestamp-shaped* prefix is stripped, and only from a line that is
  firmware output without it — so a line with arbitrary bytes in front of it is still not a
  line this tool will parse.
* **A `ring hdr` line that lost its literal `[PROF] `.** The console echo of the command
  that asked for the dump and the firmware's first header line collide in the one UART, and
  what arrives is the header run together with the echo, or with its prefix partly eaten
  (`…~2 min of seri[lROF] ring hdr magic=Z3P1 …`). The line is repaired **only when its
  payload is complete** — the recovered `key=value` set has to be exactly one of the two
  header lines the format defines. A payload that is *missing a field* is not repaired; it
  is refused, naming what is gone.
* **A stats dump whose `=== stage attribution ===` banner was eaten.** The same collision on
  a different line, arriving as
  `PROF DUMP requested (stage buckets + count[PeROrF]s =)== s` / `tage attribution ===`.
  **Five of the 2026-08-22/23 captures were refused for this with every byte of their payload
  present** — the rung 0, rung 1 and rung 1b boot and workload `PROFD`s among them. The
  banner carries nothing; the `[PROF] ver=` line beneath it carries the version, build flags,
  clock, clock source, sampler rate and probe price, in a fixed-width grammar that is
  version-checked. So the dump is opened from *that* line, and a capture that lost the `ver=`
  line as well is **still refused** — that is the line whose absence actually costs something.
  Because the repair keys on `[PROF] ver=` and **never on the banner**, it cannot care what
  shape of dump follows it: the self-test applies the same damage to a rung-1d capture and
  asserts the repaired report is byte-identical to the clean one there too.

These three together are why the tool refused all seven captures of the first metal profiling
session, and five of the campaign's, while every one of them was provably intact. Nothing
about the repair weakens the truncation checks: a repair that could absorb a real loss would
be worse than a refusal, because it turns a hard error into a plausible profile.

---

## Reading the report

The report is plain text with fixed columns, so two profiles can be diffed. Symbol
resolution is deterministic — where several symbols share an address, a real function wins
over an untyped one, global over local, then the shortest name — so a rerun over one capture
is byte-identical.

### The four ways to get a wrong answer, and where the report addresses each

**1. Ignoring `WEIGHT`.** A sample is not one tick. When core1 leaves the run loop — a `STOP`
spin, an exception, a mailbox round trip to core0 through an emulated device — the sampler
structurally cannot fire, and the first sample after re-entry carries a `WEIGHT` saying how
many tick periods it stands for. **Everything in this report is weighted**, the raw sample
count is printed beside the weight so the difference is visible, and the *WEIGHT histogram*
is its own section because it is the honest measure of how much of the run the sampler could
not observe. A `WEIGHT` of 255 is saturated: the true weight is *at least* 255, so weighted
totals containing one are a lower bound. Treating each sample as 1 deletes exactly the
stalls the profiler exists to find — the self-test's `capture-weighted` fixture is built so
that a sample-counting symbolizer ranks the wrong function first, by twentyfold.

**2. Reading a tail as a run.** Two different losses hide here and only one of them is
`drops`. `drops` counts samples the ring itself overwrote; `samples - rec_count` counts what
*this dump* left behind even when the ring never wrapped, which is the ordinary case for
`PROFR`. The *coverage* section reports both, and says plainly what fraction of the run is
in front of you. **`drops=0` alone does not mean whole-run coverage.**

**3. A missed `PMCCNTR` wrap.** (The bias described here is **version 1 only** — v2 stamps
both spans at the dump. See the version-2 section for what a v2 divergence means, and for why
this check cannot detect a wrong *clock* in either version.) The 64-bit cycle base is
extended at each sample, so if core1
leaves the run loop for longer than one 32-bit wrap the base loses 2³² cycles silently. The
header carries an independent ARM global-timer span for the cross-check, and a divergence
over 1% is flagged. Note the systematic bias in that check, which is a property of the
instrument and not a fault: `cyc_span` stops accumulating at the **last sample** while
`wall_ticks` runs to the **dump**, so stopping the sampler before dumping — `PROF` to off,
then `PROF RING`, which is the recommended order — leaves a shortfall that is *not* a missed
wrap. The report separates the two: a shortfall near a multiple of 2³² is reported as a
wrap, one that is not is reported as seconds of un-sampled wall time. Either way the PC map,
the mode split and the weight totals are unaffected — only cycle-denominated figures are.

**4. A truncated capture.** Handled by refusal, above.

### The stage buckets and the probe-cost subtraction

The stage buckets charge every ARM cycle to exactly one interpreter stage, exclusively — a
translate inside a data read appears in `XLATE` and not also in `READ`, so the buckets sum to
the total by construction. **Their shares are the answer; their rate is not.** The
instrumented instruction rate is far below the lean build's, and the two must never be
compared.

The buckets also charge the probe's own cost to the buckets. The firmware measures one
enter/exit pair at arm time and reports it as `probe_cyc` alongside an exact `TRANSITIONS`
count, so the inflation is computable — but it reports **one global** transition count, so a
*per-bucket* subtraction has to be modelled. This tool models it from the mechanism rather
than by apportionment.

*(A firmware that emits the `[PROF] s` span block reports the per-bucket counts directly, and
then the model is not used at all — see
[the per-bucket spans](#the-per-bucket-spans-a-corrected-share-stops-being-an-upper-bound).
Everything in this section is what happens when it does not, which is every version-1 capture
and every version-2 capture taken before the append.)*

#### Version 1's unit: `probe_cyc` prices a *pair*, `TRANSITIONS` counts *each half*

*(This whole subsection is about **version 1**, which is frozen — old captures cannot be
re-taken, so the tool still reads them exactly as written. Version 2 fixed the unit at the
source; see the version-2 section above.)*

`probe_cyc` is calibrated over 256 iterations of `enter()` **followed by** `exit()`, divided
by 256 — so it is the cost of a **pair**. `TRANSITIONS` is incremented **once by `enter()`
and once by `exit()`** — so it counts each half separately. `TRANSITIONS × probe_cyc`,
which is what the firmware itself prints, therefore prices every pair twice:

```
probe total  =  TRANSITIONS / 2  ×  probe_cyc          per transition: probe_cyc / 2
```

The report prints the division, the pair count and the per-transition cost explicitly, and
prints the firmware's doubled figure beside it and labelled, because that is the number a
reader coming from the console has in front of them. On the first metal session's stage
dump this is the difference between 41.33 % and 82.65 % of the run — and 82.65 % is not
merely wrong, it is **impossible**: it demands 43.80 G cycles of probe out of a `LOOP`
bucket that contains 28.03 G, so the subtraction clamps at zero and silently absorbs the
excess. The corrected figure leaves every bucket positive and the adjusted column summing
to `total − probe`. Two independent measurements agree with it: the A/B table prices the
whole bucket-arming step at 38.22 %, and the ~3 % remainder is the call-and-test overhead
paid even when the buckets are off.

**`docs/C2-ATTACK-MAP.md` was written against this corrected arithmetic, derived
independently while the tool still had the defect. The shipped tool now reproduces that
document's §2.1 and §2.3 tables cell for cell** — every raw cycle, every probe column, every
corrected share, and the 966 092 170 vs 966 080 190 model residual.

The `--probe-cost` override is in the same unit the firmware calibrates and prints **for
that dump's version** — one pair under v1, one transition under v2. The report always states
the unit it applied, and the tool will **not** carry a probe figure across a version
boundary: a v1 boot line above a v2 dump (one capture spanning a reflash) leaves the
subtraction *unavailable* rather than feeding a per-pair price to a per-transition rule.
When no price is available at all the report says the overhead is **unpriceable**, not that
it is zero.

A bucket whose modelled probe cost exceeds the cycles measured in it is clamped at zero, and
the report now **says so and how much it absorbed**. That clamp is not a rounding detail: it
is how an over-priced probe announces itself, and while it was silent the impossible 82.65 %
subtraction looked like an ordinary result. A clamp means the *price* is too high, not that
the stage is empty, and when one fires the adjusted column no longer sums to `total −
probe`.

* `enter()` and `exit()` both stamp `last = now` *before* the rest of the probe body runs, so
  the probe's own cycles elapse after the stamp and are charged at the next transition to
  whichever bucket is current by then. `enter(b)` therefore lands its cost in `b`; `exit()`
  lands its cost in `b`'s parent. A bucket pays for its own entries plus one exit for each
  entry of every bucket nested inside it — which is why `LOOP` carries a large share despite
  never being entered.
* The number of entries per bucket is derived from the exact counters (`FETCHOP` from
  `INSNS`, `READ` from `READ`, `WALK` from `ATC_MISS`, and so on), and the model's predicted
  transition total is **checked against the firmware's measured `TRANSITIONS`**. The report
  prints both and the residual. If they disagree by more than 25%, the adjusted columns are
  **withheld** rather than printed from a model that does not hold; the raw cycles and shares
  are unaffected either way.

A distribution proportional to each bucket's *cycle* share is worth naming because it looks
reasonable and is useless: it subtracts the same fraction everywhere and leaves every share
exactly where it was. Shares are the answer this instrument gives, so a correction that
cannot move one is not a correction.

---

## Wire version 2

### The probe is priced per transition, and an impossible one is reported rather than clamped

Under v2 the firmware calibrates `enter()` and `exit()` as **out-of-line calls** and reports
the cost of **one transition**, so the whole probe cost is `TRANSITIONS × probe_cyc` with
nothing halved. The tool's arithmetic and the console's now agree, and the report says so
where the v1 report printed the firmware's doubled figure beside its own.

The consequence is a change of responsibility worth stating plainly. Under v1 the tool was
*correcting a price it knew to be doubled*, so a bucket whose modelled probe exceeded its
own cycles was clamped at zero and disclosed — that clamp meant "your price is too high",
and it is how the 2× over-pricing announced itself. Under v2 the price is the firmware's
own, so **if the modelled probe exceeds `total_cyc` the instrument is wrong, not the
arithmetic**: the subtraction is *withheld entirely* and reported, never clamped. A clamp
there would hide an instrument fault behind a plausible table, which is precisely the
failure v2 exists to end. The firmware prints a warning of its own at the same threshold.

The report also keeps the three reasons a subtraction can be withheld apart — the landing
model is out of tolerance, the probe exceeds the total, or there is no price at all —
because a reader told "the model is out of tolerance" will go and re-derive a model that is
already right.

### The tail is four ids, and one of them is the instrument

v1's `TAIL` is v2's `TAILADV + TAILSAMP + TAILPOLL + TAILSPEC`. **Id 8 alone is not the
tail**, and a reader who lays v2's `TAILADV` beside a v1 capture's `TAIL` is comparing a
part with a whole and will report a saving that never happened. The report therefore leads
with the rollup and prints the raw rows beneath it.

`TAILSAMP` is the profiler's own sampler hook plus the `INSNS` counters. It is **instrument
cost, not interpreter cost** — subtract it, do not rank it. In v1 it was charged to `LOOP`,
so no v1 capture could see it at all and the C2 map's 110.8 cycles per guest instruction
never included it. The report prints the tail three ways: whole, without the instrument, and
without the instrument or the probe.

The firmware prints its own `[PROF] t` rollup, computed on the board from the same
accumulators the `b` lines come from. The tool does not need it to add four numbers — it
**cross-checks against it**, because the two cannot disagree over one span, and if they do
the capture's `b` lines and its `t` line were taken from different states.

The same move was made again one bucket over, against a bucket that had grown larger than the
tail ever was — see
[The LOOP split](#the-loop-split-rung-1d-and-the-ten-points-it-puts-within-reach). The report
prints a rollup for that one too, and for the same reason.

The landing model gains two entries for v2: `TAILSAMP` and `TAILPOLL` are each entered once
per instruction (their probe brackets sit *outside* the cadence gate, so the gate skips the
work and not the transition), which is exactly the four extra transitions per instruction
the firmware prices the split at. `TAILSPEC` is `spcflags`-gated, has no counter, and is
modelled at **zero** — a stated gap, and the residual check is what would catch a run where
it is not rare.

### The ATC hit rate comes from id 19, and never from id 12

```
ATC hit rate = ATC_HIT / XLATE        [id 19]        walk rate = ATC_MISS / XLATE
```

`XLATE_OK` (id 12) gets **its own line**, labelled as *not* an ATC rate and tied back to the
name v1 gave it. The two are genuinely different numbers — on the self-test fixture the ATC
hit rate is 90.00 % and `XLATE_OK / XLATE` is 99.96 % — so a tool reading id 12 as an ATC
rate does not fail, it answers a different question.

Three identities are checked:

```
IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS  ==  XLATE
XLATE_OK + FAULTS                       ==  XLATE     (v1 states this over `ATC_HIT`)
ATC_HIT + ATC_MISS                      ==  XLATE     when no translate faulted
```

The third is **not an equality in general**: a translate that faulted before the walk
decision is counted by neither, so the sum falls short by exactly those. A shortfall is
therefore reported as satisfied-with-a-remainder and is **bounded by `FAULTS`** — every one
of them threw and every throw reached the run loop's `CATCH` — which is a check the firmware
does not make. Only an *overshoot*, a partition summing to more than the set it partitions,
is impossible.

On the **68030** there are now *two* absences, not one: no tier-0 counters, and no
`XLATE_OK` site either (the 030 translate is a bare ATC probe called from fourteen accessors
with no single success point). Both read zero and **zero means absent** — a printed
"0.00 % returned an address" would claim every translate faulted, which is worse than no
answer. `ATC_HIT` on the 030 was always genuine, so that rate is real there.

### `clk=` is the only thing in a capture that can tell you the clock is wrong

v2's `cpu_hz`/`wall_hz` are the **runtime** clock — the rate core0 publishes after retuning
the PLL — and the header carries `clk=cfg` or `clk=bsp` to say where it came from. `clk=bsp`
means the figure is the **compile-time BSP constant**, and if the board retuned its PLL every
Hz, every duration and every cycle-denominated rate is wrong by that ratio; on the rig that
produced this defect, by 1.65×.

**The wrap cross-check cannot stand in for this and the report says so next to the clean
result, not only in the warnings.** CPU-to-global-timer is a fixed 2:1 in silicon, so
`cyc_span` and `wall_ticks` scale *together* and any error in the absolute rate cancels out
of their ratio: the check passes to three decimal places while the clock is 65 % wrong. It
is a wrap check, not a clock check. `clk=bsp` therefore gets a hard warning on every dump
that carries it.

Two smaller v2 consequences follow from the header: `cyc_span` and `wall_ticks` now **both
end at the dump**, so the v1 stop-to-dump shortfall no longer exists — a v2 divergence that
is not a multiple of 2³² is *not* explained away as operator latency, because that bias was
removed rather than documented.

### A capture that disagrees with itself is refused

The magic encodes the version (`Z3P` + digit), and the `ver=` line's *grammar* encodes it
again (v2 spells the probe field `probe_cyc_per_transition=` and adds `clk=`). Those
redundancies are only worth having if they are checked, so three contradictions are hard
refusals rather than something to resolve in favour of one field:

* a header declaring `version=2` while carrying `magic=Z3P1`, or the reverse;
* a `ver=` line declaring version 2 written in the version-1 grammar;
* the same the other way round.

None of these is *corrupt* — every field is present and well formed. They are what a
hand-edited capture, a mixed-firmware paste, or a generator that bumped a number without
bumping a format actually looks like, and because the two versions price `probe_cyc` in
different units and disagree about two ids, picking a side does not raise an error further
down. It produces a plausible wrong number.

A dump whose `ver=` line did not survive the capture at all is read as version 1 by
assumption, and **the assumption is announced** in both the report and the warnings.

---

## What version 2 grew after it shipped

Counter ids **20–38** and the per-bucket **`[PROF] s` span block** were appended to wire
version 2 rather than bumped into a version 3. That is the right call under the firmware's
own rule — a bump is for a *meaning* that moves under a reader's feet, and a pure append
moves nothing — and it means the tool reads both firmwares under one version entry.

The cost of that choice lands in one place, and it is worth stating before anything else.

### Absent is not zero, and which of the two it is depends on the id

| a missing counter row | means |
|---|---|
| id **< 20** | the capture **lost a line**. Every version-2 firmware emits these. |
| id **≥ 20** | the **firmware predates** that counter. Nothing was lost. |

The report prints `absent` rather than `0` for a row that did not arrive, names which of the
two cases it is, and **warns** only for the first. Every derived row is gated on the counters
it needs being *present* rather than being non-zero.

This is load-bearing rather than pedantic, because of the `DOPC_` block: those four counters
read **exactly zero when the decoded-op cache is switched off** — the lookup returns before
it can count — and that is a measurement. Printing `0` for a firmware that never had them
would put a non-measurement in a column of measurements, which is the `ATC_HIT` defect
wearing a different name. The `IV_*` counters beside them still move with the cache off, by
design: they count what the *guest* asked for, and the guest issues `CPUSHL` and `PFLUSH`
whatever the switch says.

### The per-bucket spans: a corrected share stops being an upper bound

Before the `s` block there was no per-bucket transition count at all, so the "subtract per
bucket by its share of transitions" instruction the dump has always printed could only be
followed by *modelling* the shares. `LOOP` — the bucket the entire probe-pricing argument
turns on — could therefore only be reported as *at most* X, and the two ends of the price
bracket gave two different at-mosts 5.8 points apart.

A **span** is a cycle-span *charged to* a bucket, counted at exactly the two sites that
charge it. It is **not** "calls into the bucket": entering a nested stage closes a span just
as exiting does, so a `FETCHOP` with a translate inside it is charged twice. Two identities
follow and both are checked:

```
sum(spans)              ==  TRANSITIONS
corrected cyc for b     ==  acc[b] − spans[b] × probe_cyc
```

The second is the point — it makes the global correction decompose *exactly*, so no bucket's
corrected share can disagree with the total's. Where the block is present and passes its
gates, the report's probe column is headed `probe(spans)` and the **landing model is demoted
to a cross-check**; its residual becomes a remark about the model rather than a gate on the
report. Three gates, each a way the block could be present and wrong:

* **the version gate** — spans count transitions, so a dump whose semantics price a *pair*
  would be over-charged 2×, the exact defect v2 exists to fix;
* **the identity gate** — `sum(spans) == TRANSITIONS` holds by construction, so a mismatch
  means the `s` lines and the `c` lines did not come off one state;
* **the completeness gate** — a block with rows missing is not a conservative error. The
  missing rows read as buckets that pay *no* probe, which **inflates** exactly the buckets
  whose evidence is gone.

`FAULT` is reported **uncorrected**, deliberately: an unwind charges it cycles and counts no
span (it is not a probe transition and has never been in `TRANSITIONS`), so it is
over-reported rather than under-reported — the safe direction, at the ~0.06 % it measures.

> **A corrected `LOOP` share quoted from before rung 1d is the WHOLE dispatch loop.** The
> metal figure this block produced — 24.80 % @39 .. 25.11 % @50 — is `LOOPRES + DOPCFIND +
> DOPCFILL + BLKREC` on any capture that names id 0 `LOOPRES`. Read
> [The LOOP split](#the-loop-split-rung-1d-and-the-ten-points-it-puts-within-reach) before
> laying a new capture's id 0 beside it.

#### The `2 × IFETCH_CALLS` method is retired here, and it was refuted rather than bettered

Before the spans, the fetch buckets' transition count was estimated as two per
`IFETCH_CALLS`. Metal 2026-08-23 measured both quantities on one capture:

| | transitions charged to the ifetch buckets | of all transitions |
|---|---|---|
| assumed, `2 × IFETCH_CALLS` | 99 049 270 | 12.37 % |
| **measured spans** | **50 194 621** | **6.27 %** |

**The assumption over-charges by 1.97×**, so every corrected share derived from it was biased
**low**. The mechanism is the decoded-op cache itself: with the cache on, **a hit never
enters `FETCHOP` at all** — the bucket is entered once per *miss*, not once per fetch
(`FETCHOP` spans 15 547 429 against `DOPC_MISS` 15 436 987, 0.72 % apart). `IFETCH_CALLS ==
FETCH` is still exactly true; what is false is that `FETCH` predicts bucket *entries* once
something upstream answers fetches without entering the bucket. The report states both, and
says which one may be used for what.

### The price is a range, and the report sweeps it

The boot line's three-pass calibration brackets the probe price, and the tool now parses it:

```
[PROF] probe calibration: armed N cyc, unarmed N cyc, empty N cyc, 1024 pairs -> M cyc/transition marginal, K in-bucket
[PROF] price bracket: M (bodies only, what PROFB gates) .. K (bodies + the call scaffolding …) -- sweep it, do not pick
```

| quantity | arithmetic | what it names |
|---|---|---|
| **marginal** | `(armed − unarmed) / 2N` | the probe **bodies** — what `PROFB` gates off. What the firmware subtracts. |
| call scaffolding | `(unarmed − empty) / 2N` | the `bl`, prologue, predicate, epilogue and `bx lr` — inside the buckets, and still there when the bodies are gone |
| **in-bucket** | `(armed − empty) / 2N` | bodies **plus** scaffolding: the price if the instrumentation calls go away entirely |

The report **checks the firmware's arithmetic** against the three spans rather than repeating
its quotients, and carries **both ends into the span table** as two corrected columns.
Neither end is a correction of the other — the marginal figure is right for "the prof build
with the bodies gated off", the in-bucket figure for "the prof build without the
instrumentation calls", and a map's readers usually want the second while the firmware
subtracts the first. A capture priced at one and read as though it were the other is how a
"floor" gets invented. **Do not compare either against 45.5**: that is v1's 91 cyc/pair
halved, measured with the probes *inlined* over the whole loop — a whole-cost inlined
quantity neither of these is a bound on.

The **two-pass** calibration is the older firmware: no `empty` span, so no in-bucket figure
and no bracket line. That capture supports **one price**, and the report says so rather than
presenting a range of width zero as a range. The bracket is version-guarded exactly as the
boot-line probe fallback is: it is measured by one boot in one version's unit, and a capture
can span a reflash.

### The rung counters, and the identities that scope them

| ids | what | the identity the report asserts |
|---|---|---|
| 20 | `IFETCH_CALLS` | `IFETCH_CALLS == FETCH`, identically — all five `ENTER_IFETCH` sites increment `FETCH` exactly once |
| 21–23 | `BLK_*` — the block-idiom fast path | the guest stream is `(INSNS − BLK_HIT) + BLK_INSNS` |
| 24–27 | `DOPC_*` — the decoded-op cache | `DOPC_HIT + DOPC_MISS == INSNS + FAULTS` |
| 28–37 | `IV_*` — invalidation cause | `sum(IV_*) == DOPC_INVAL` with the cache on; `< ` is impossible |
| 38 | `IV_CACR_SKIP` | **not** a cause; the guest's true request rate is `sum(IV_*) + IV_CACR_SKIP` |
| 39–42 | `DOPC_WAY0`–`3` — the decoded-op way histogram | named only |
| 43 | `MISALIGN_I` — the instruction-stream half of `MISALIGN_R` | named only |
| 44–45 | `DFAST_HIT`, `DFAST_XPAR` — the accessor fast path's coverage | named only |
| 46 | permanently retired — see below | **never a live counter** |
| 47–60 | `WARP_*` — the WARP engine block | named only |

**"Named only" means the row is in the table and nothing above it reads it.** Ids 39–60
arrived after the tool's counter list was last synced, so until now they took the append
seam's designed path — reported in a *"beyond the … version 2 defines"* warning and absent
from the counter table itself. They are now named from the firmware's own
`z3660_prof_counter_names[]`, which is the only source a name may come from: a name inferred
from a capture is a name the tool would then check that capture against. The firmware states
`WAY0+WAY1+WAY2+WAY3 == DOPC_HIT` and `MISALIGN_R − MISALIGN_I` as the genuine misaligned
*data* reads; this tool asserts neither, and a derived row for either is a separate change.

**Id 46 is permanently retired, and the report never prints a number for it.** It held
`SPEC_HIT` in an experiment whose revert took the id with it — the reason 46 used to sit
*outside* this table entirely — and then the withdrawn `f`-measurement build (`IVSUP`) reused
it for `IV_SUPPRESSED`, whose non-zero value means "this capture is not a profile of a
correct machine." The firmware retired the id for good rather than risk a third reuse:
`z3660_prof_counter_names[46]` is the literal string `"(retired)"`, so a shipping firmware's
own dump carries that name and a value of 0, always. The report renders the row as
`(retired)` in the value column regardless of what arrives — present-and-zero, present-and-
non-zero, or absent (a firmware that predates the WARP block, where it falls to the same
*did not arrive* path as ids 47–60) — and only a non-zero reading gets a word beyond that: a
warning naming the capture unsound, because a live number there would be the `ATC_HIT` defect
under a new id.

**`BLK_INSNS` is not a subset of `INSNS`.** `INSNS` counts instructions retired through the
run-loop *tail*, and the fast path retires a whole chunk per pass of that loop — so a chunk
contributes 1 to `INSNS` and 2 × chunk to `BLK_INSNS`. The literal ratio is a share of
nothing, and it does not merely inflate: on the 2026-08-22 metal boot it reads 59.28 %
against a true 37.25 %, which is *outside* the range in which the map's 31.80 % prediction
could be judged at all. The report prints both, calls only the reconstruction the share, and
shows the literal one so it is not reached for by accident. It also reports the **mean chunk
length** and warns below ~8: the recognizer test is paid once per chunk, so a mean near 2
means it is paid per iteration and the whole saving is gone — and the thing to check then is
the *trigger*, not the host operation.

**A dispatch is not a guest instruction.** `DOPC_HIT + DOPC_MISS` counts run-loop passes, so
where the fast path is live the hit rate is per pass and anything per-instruction must divide
by the reconstructed stream. The identity itself is worth a note: the firmware's
`docs/profiler.md` states it as `== INSNS`, and **twelve metal captures across three sessions
and three firmware builds put the sum above `INSNS` by exactly `FAULTS`, every time, to the
unit**. The mechanism is plain once stated — a faulting instruction consults the cache (so it
is a dispatch) and then throws before retiring through the tail (so `INSNS` never counts it).
A difference that reproduces another counter in the same dump exactly, twelve times, is a
mechanism and not the dump skew it was first read as. The tool asserts the `+ FAULTS` form.

**`DOPC_INVAL / DOPC_MISS` is not a ratio worth forming** and the report refuses to print
one: a single whole-cache invalidation can cost a full cache of refills, so the two are not
commensurable. The figure that means something is *misses per invalidation*, read against the
workload's code footprint — one that does not track the footprint is re-warm, not capacity,
and the fix for re-warm is a narrower invalidation rather than a bigger cache.

**`IV_CACR_SKIP` is outside the cause block, and the report is emphatic about why.** Every
entry in the block means "this request reached the invalidator". A narrowing implemented at
its *call site* decides before that and increments nothing at all — it is not a skipped
request, it is an uncounted one — so defining a narrowing's yield as `sum(IV_*) − DOPC_INVAL`
is **false for exactly the class of narrowing most worth doing**. On a firmware that has no
such counter the report says the narrowing is *invisible here* and refuses to score one from
those rows. A gap of `sum(IV_*) > DOPC_INVAL` is legal and has **two causes these rows cannot
tell apart** — the cache off for part of the window, or a narrowing *inside* the invalidator
refusing a request whose cause was already counted — so the report names both and points at
the switch log.

---

## The LOOP split (rung 1d), and the ten points it puts within reach

Everything above this heading is a version that grew. This one is a **version that stayed
still while a meaning moved**, and it is the only place in the format where reading the
version number is not enough.

The firmware's rung 1d brackets three stages out of the dispatch loop:

| id | name | what it is |
|---|---|---|
| 14 | `DOPCFIND` | the decoded-op cache **lookup** — set index, generation compare, tag compares, and the extension-window arm/disarm. **Every dispatch.** |
| 15 | `DOPCFILL` | the decoded-op cache **fill**. The miss path only. |
| 16 | `BLKREC` | `z3660_blk_run()`, the block-idiom recognizer — the residual test, and the whole serviced chunk when it fires |
| 0 | `LOOPRES` | what is left: the flag snapshot, `mmu_restart`, `m68k_getpc()`, `do_cycles()`, the handler selection, the back edge |

**The version is still 2, and deliberately so.** The ids are append-only, the header and the
sample record are untouched, every id 0–13 sits where it did, and a tool that does not know
about 14–16 reports them uninterpreted rather than mis-labelled — so a bump would make every
existing tool refuse a capture it can read correctly. What moved is what **id 0** means, and
the firmware handles that the way v2 handled `TAIL`: **by moving the name with the meaning.**

> A dump that says `LOOP` at id 0 holds the whole dispatch loop.
> A dump that says `LOOPRES` holds the residue.

That name is the **only** signal. The magic is `Z3P2` either way, the `ver=` line says 2
either way, and the `s` block, the counters and every other row are identical in shape. So
the tool keys on the dump's own id-0 name (`BUCKET_SHAPES` in the seam), resolves the whole
bucket-name table from it, and reports what follows against *that*.

### Why this is worth a section: the mistake is ten points wide and looks like a saving

The C2 attack map ranks `LOOP` first at **26.38–26.54 %** of the interpreter — the
best-measured share on the page, and the only one with a sub-point bracket. Rung 1d then took
three stages out of that bucket. On the self-test fixture, sized against exactly that figure:

| | share of the measured total |
|---|---|
| the **rollup** `LOOPRES + DOPCFIND + DOPCFILL + BLKREC` | **26.53 %** — the quantity the map measured |
| **id 0 alone** (`LOOPRES`) | **15.92 %** |

Laying id 0 beside the map's number reports a **10.61-point fall that no code change
produced**, and *nothing else in the report objects*: the arithmetic balances, the share is
real, the identities hold. Only the name says the two numbers are about different things.
So the report **leads with the rollup, prints the four parts beneath it, and prints the guard
next to both** — and on a pre-rung-1d dump it says so explicitly, that id 0 *is* the whole
loop there and can be laid beside the map's figures directly. (On a **version 1** dump it
says something different again: id 0 is the whole loop *and* the sampler hook, so it is not
the map's quantity either, and the excess is instrument rather than interpreter.)

### The split's own cost, so two captures can be compared at all

A share measured under rung 1d is measured on a run loop that pays **two more transitions per
dispatch** than every earlier capture was taken on. The firmware prints that cost on its own
`[PROF] l` line, computed from the three buckets' **own spans** rather than from a
per-instruction estimate, and the report carries it beside the rollup:

```
added transitions            4000054   23.05% of all transitions
  two per span of DOPCFIND (1000025), DOPCFILL (100002) and BLKREC (900000)
re-priced without the split 13354050   TRANSITIONS - the cost above
```

Subtracting it re-prices the capture **as though the decomposition had not been taken**,
which is the only honest way to lay a share here beside a share from an older capture. On the
fixtures that subtraction reproduces the pre-split fixture's `TRANSITIONS` exactly.

**The buckets are not re-priced and must not be.** The three new ones did not exist on the
older run loop; moving their cycles back into id 0 would invent a measurement rather than
recover one. The rollup is the comparable *quantity*; the re-priced count is the comparable
*denominator*.

### Four identities, stated over spans and not over counters

```
tcnt[DOPCFIND] == DOPC_HIT + DOPC_MISS      cache ON: one lookup per dispatch
tcnt[DOPCFIND] == INSNS + FAULTS            every dispatch enters the bracket
tcnt[DOPCFILL] == DOPC_MISS                 cache ON: one fill per miss
tcnt[BLKREC]   <= tcnt[DOPCFIND]            at most one recognizer call per dispatch
```

`tcnt` is the bucket's **own span count from the `[PROF] s` block**, and nothing else will
do — an entry count taken from a counter that merely correlates with it is the method the
spans retired, by 1.97×. Without a usable `s` block the report says these are **unavailable**
rather than assuming they hold.

The first three are *exact*: neither the lookup nor the fill touches guest memory, so neither
span can be abandoned by an unwind. That is why the firmware **warns** rather than notes when
they fail, and why the report treats a mismatch as a defect claim. The second of them is also
the one that **survives the cache switch in both arms** — a dispatch enters the lookup bracket
whichever way the switch is set — so it is what scopes the bucket when the counters cannot.

**The fourth is the one whose bracket is not pure.** On a *decline* — the common case — the
bucket holds three masked compares and a return; on a *fire* it holds the whole serviced
chunk, which can nest bracketed accessors and charge the bucket more spans than there were
calls. The identity is over **calls**, so the report scopes any excess by `BLK_HIT`: with
`BLK_HIT == 0` the bucket *is* the residual test, its spans are exactly its calls, and an
excess is a real defect — which is the only case that warns.

### A cache-off arm is a measurement, not a defect

With the decoded-op cache **off**, two of the four legitimately diverge and the firmware says
so on a `[PROF] l note:` line rather than a `WARNING`:

* the lookup returns before it counts, so `DOPC_HIT + DOPC_MISS` is **0** while `DOPCFIND`
  goes on being entered every pass;
* `DOPCFILL`'s bracket sits on the now-universal miss arm, so it prices the fill's own
  **switch test** per dispatch instead of per miss.

Those two buckets then read as the price of the two switch tests — a real number, and not the
one a cache-on capture reports. The report marks both identities **n/a**, explains the
mechanism, and **warns about nothing**: warning there would send a reader to fix a switch
setting they chose on purpose. `tcnt[DOPCFIND] == INSNS + FAULTS` survives the switch in both
arms, because a dispatch enters the bracket whichever way it is set, and it is what scopes
the bucket when the counters cannot.

### What the firmware said, quoted rather than paraphrased

The board checks these identities too, and it is the one party that saw the state they were
taken from. Its `[PROF] l WARNING:` and `l note:` lines are printed **verbatim** (wrapped,
never reflowed) with the capture line they came from, and a `WARNING` is repeated into the
warnings block so it cannot be lost in a long report. A `note` is not: it is the cache-off
arm stating a fact about the switch.

### One modelling gap, named where a reader would look for it

The probe-landing model gains `DOPCFIND` (once per dispatch) and `DOPCFILL` (once per miss)
from the `DOPC_` counters — and from the *dispatch count* instead when the cache is off,
where those counters read a true zero while both brackets are still entered. `BLKREC` has
**no counter for calls** (`BLK_HIT` counts the recognizer *firing*), so it is modelled at
**zero**, which under-predicts a rung-1d dump by two transitions per call. The report names
that next to the residual and sizes it from the spans, because a reader told only "residual
10.4 %" will go looking for a cause that is not there.

---

### Counters and rates

The counters are exact regardless of what the timing instruments are doing — they are not
switchable in a profiling build — so **take them from the cheap sampler-only run as well**.
`STACK_OVF` must be zero; a dump showing anything else has dropped phase transitions and
every bucket total in it is understated by an unknown amount, which the report says out loud.

Three tiers of address translation are separately visible: the tier-0 page caches
(`IPAGE_*`/`DPAGE_*`, where a hit means `mmu_translate` is never called), the tier-1 4-way
ATC, and the tier-2 descriptor table walk. On the **68030** path the tier-0 counters do not
exist upstream at all, so the report prints `n/a` with the reason rather than `0.00%` — the
row is *absent*, not zero-valued by accident.

#### Version 1's `ATC_HIT` does not count ATC hits

In version 1 the counter named `ATC_HIT` counts **translates that succeeded**. It carries no
ATC information whatsoever. Two identities hold exactly on an intact dump — measured on four
independent metal spans, at seven digits, with no slack:

```
IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS  ==  XLATE
ATC_HIT + FAULTS                        ==  XLATE
```

So `XLATE` is exactly the tier-0 miss count — the calls into `mmu_translate` — and
`ATC_HIT + ATC_MISS` is a sum of two unrelated quantities. The report therefore derives both
tier-1 and tier-2 rates **without `ATC_HIT`**:

```
ATC hit rate = (XLATE - ATC_MISS) / XLATE        walk rate = ATC_MISS / XLATE
```

and cross-checks the two identities above instead, naming which one failed when one does.
The check this replaced compared `ATC_HIT + ATC_MISS` against `XLATE` and reported "the two
tiers disagree" — which fired on **every** intact dump, because that sum has no meaning
here, and named a cause that was not the cause. The underlying defect is real and is the
firmware's: fixing the counter is a rename, and a rename of an append-only id is a version
bump, which is why the corrected reading is recorded per-version in the seam. **Version 2
made exactly that rename** — id 12 is now `XLATE_OK` and a real `ATC_HIT` was appended at
id 19 — so a v2 capture is read with the direct counter and needs none of this derivation.

`build=0x04` is the shipped profiling combination: the lean hot loop plus the profiler. A
`build=0x07` dump is a profiling build of the *diagnostic* loop, and its stage map describes
a binary nobody runs; the report warns loudly.

### Symbol-table hygiene

The assembler this kernel is built with names its internal labels with a `%` — `L%done`,
`LC%17`, and the per-object `gcc_compiled%` marker. **1875 of the 7462 `.text` symbols in a
current `build/unix-040` are such labels**, and they sit *inside* functions: a PC sampled in
the middle of a loop would resolve to `L%done+0x4` instead of to the function containing it,
and one hot function would split across a dozen label-named rows. A C identifier cannot
contain `%`, so a LOCAL symbol that does is never a function name, and these are filtered by
default. The count filtered is always reported; `--all-symbols` turns it off.

Supervisor samples are symbolized against the kernel **only when the `AMIX` flag is set**.
`SUPER` without `AMIX` is AmigaOS/ROM supervisor code — a real and expected part of a boot
profile — and is left as an address bucket, because attaching kernel function names to ROM
addresses would produce names that look plausible.

---

## What this tool deliberately does not do

It does not rank, recommend or interpret. It reports what the firmware measured and what
that is a measurement *of*. Turning a stage map into an optimisation ordering is a separate
judgement made by somebody who can also weigh implementation cost, and burying it inside the
instrument would make the ranking look like a measurement.

---

## Self-test

```sh
sh tools/test-prof-symbolize.sh          # exit 0
```

341 checks. No board, no kernel image and no cross toolchain required.
`tools/prof-fixtures.py` builds the synthetic captures into a temporary directory — valid,
truncated, wrapped, weighted, and one per refusal — together with a small hand-assembled
m68k ELF and the equivalent `nm` dump, so **both** symbol paths are executed and asserted to
produce the same profile. Each fixture encodes one property, named in the generator next to
the numbers that produce it.

Three of the version-1 fixtures exist because the tool got these wrong against real
captures, and each wrong answer looked like a right one:

* `capture-dirty` is `capture-valid`'s own bytes with a logger timestamp on every line *and*
  a header line run together with the console echo. Nothing is missing, so the assertion is
  that the report is **byte-identical** to the clean one — not a spot check. `capture-hdrgone`
  is the same damage with a field genuinely lost, and must still be refused.
* the probe arithmetic is pinned end to end on `capture-valid`: `9354050 / 2 = 4677025` pairs
  × 11 cyc = `51447275`, the firmware's doubled `102894550` printed and labelled beside it,
  and the adjusted column summing to `total − probe`.
* `capture-atcbroken` and `capture-tier0broken` break one translation identity each, and the
  suite asserts that the *other* one still passes and that the warning names the right cause.
  It also asserts that the old text ("the two tiers disagree") appears nowhere.

**The version-2 fixtures are a different kind of case, and it is worth saying why.** The v1
cases above are regression locks on a frozen format. The v2 cases exist because v2
*corrected* three numbers v1 mislabelled — and a mislabelled number is worse than a wrong
one, because arithmetic built on it still balances. So each v2 assertion pins a figure that
a tool still applying v1's rules would get **differently** rather than fail to produce:

* the probe at `13354050 × 46 = 614286300`, with the halved v1 answer (`307143150`) asserted
  to appear nowhere;
* the tail rolled up to `400000000` = 20.00 %, with id 8 alone at 7.50 % — the gap a reader
  would otherwise report as a saving — and cross-checked against the firmware's `[PROF] t`;
* an ATC hit rate of 90.00 % from id 19, beside `XLATE_OK` at 99.96 % from id 12, which is
  the number a v1-rules reader would print instead;
* `capture-v2probeover`, where the probe exceeds the total: the suite asserts the subtraction
  is **withheld** and that the word `CLAMPED` appears nowhere.

Three further v2 fixtures are captures that are **not corrupt** but disagree with themselves
about their version — a v1 magic under `version=2`, and a `ver=` line in each version's
grammar declaring the other. All three must be refused rather than resolved in favour of one
field, and the suite asserts that each names what contradicts what.

**The post-append fixtures are a third kind again**, because the thing being tested is that
two *legal version-2 captures* carrying different numbers of rows are read differently:

* `capture-v2spans` carries 39 of the 61 counters and the `s` block; `capture-v2valid`
  carries 20 and no block. The suite pins `LOOP`'s probe at the **measured** `5043850 × 46 =
  232017100`, and asserts that the modelled figure for the same bucket in the same buckets
  (`211601150`) appears **nowhere** — the model was never wrong about the *total*, only about
  the shape, so a tool still using it produces a full and different table rather than an error.
* `capture-v2noskip` is the 38-counter firmware: id 38 must read `absent`, be named as an
  *append* rather than a loss, and the report must refuse to score a call-site narrowing from
  rows that structurally cannot see one.
* `capture-v2rung2` is the 46-counter, **pre-WARP** firmware — every id rung 2 defines is
  named, and ids 46–60 (the retired placeholder and the whole WARP block) must read `did not
  arrive`, because that firmware predates them rather than having lost the lines. It is a
  fixture in its own right, not a stepping stone: a tool synced to WARP still has to read an
  un-WARPed capture correctly.
* `capture-v2warp` is the full **61**-counter firmware — every id named, nothing absent and
  nothing uninterpreted, including id 46 reading `(retired)` with no warning (its ordinary,
  always-zero case). `capture-v2retired` is the same capture with id 46 forced non-zero: the
  value column must still read `(retired)`, never the number, and a warning must name the
  capture unsound. `capture-v2beyond` is `capture-v2warp`'s own bytes plus **one counter past
  the table** — id 61 — which is what a capture from a firmware newer than its reader looks
  like: the row is reported under the name the *dump* carries, marked uninterpreted, no table
  row is invented for it, and the assertion is that the rest of the report is
  **byte-identical** to `capture-v2warp`'s. An id the tool has never heard of must cost the
  reader nothing.
* three ways an `s` block can be present and unusable — spans that miss `TRANSITIONS`, a
  block with rows lost, and a per-pair version — each must fall back to the model and say so.
* `capture-v2cal2` is the two-pass calibration: one price, no bracket, and the suite asserts
  the swept column appears nowhere. `capture-v2calbad` states a marginal figure its own three
  spans do not give.
* `capture-v2blkstall` is the fast path's pre-registered failure mode arriving — it fires,
  with a mean chunk length of 2. `capture-v2dopcoff` is the cache switched off, where the four
  `DOPC_` counters read exactly zero and the `IV_*` counters do not.
* `capture-v2bannergone` is `capture-v2spans`'s own bytes with the `=== stage attribution ===`
  banner eaten by the console echo, and the assertion is again an **identity**: the repaired
  report body must equal the clean one. `capture-v2bannerident` loses the `ver=` line too and
  must still be refused.

**The rung-1d fixtures are a fourth kind, and the only one where the wrong answer is
available without the capture being unusual at all.** Every one of them is a perfectly
ordinary version-2 dump; the only thing that says id 0 stopped meaning the dispatch loop is
that it is now printed `LOOPRES`. They are built so that a tool keying on anything else —
the version, the magic, the row count — produces a clean, complete, wrong report:

* `capture-v21d` is sized against the figure the mistake would be scored against: its rollup
  is **26.53 %**, inside the C2 map's 26.38–26.54 %, while id 0 alone is **15.92 %**. The
  suite pins the rollup, the four parts, the guard text, and the split cost — `4000054` =
  2 × (1000025 + 100002 + 900000) — and asserts that `17354104 − 4000054 = 13354050` is
  exactly `capture-v2spans`'s `TRANSITIONS`, i.e. the count this run would have had before
  the split. It also asserts the capture warns about **nothing**.
* `capture-v21doff` is the same shape with the cache off, where two identities legitimately
  diverge. The suite asserts both read `n/a`, that the mechanism is explained, that the
  firmware's own `note:` is quoted — and, most importantly, that the report warns about
  **nothing**.
* `capture-v21dskew` breaks the lookup bracket against the dispatch counters with the cache
  on. Both this tool's `MISMATCH` and the **board's own** `[PROF] l WARNING` must appear, the
  second attributed to the board.
* `capture-v21dloopmismatch` disagrees with its own `[PROF] l` rollup; `capture-v21dspanslost`
  loses the `DOPCFIND` span row, so the identities must read **unavailable** rather than being
  derived from a correlate, while the rollup and the guard survive.
* `capture-v21dnameclash` answers the shape question twice — `LOOP` at id 0, `DOPCFIND` at
  id 14. No firmware writes that. Neither answer may win: the id-0 name stands, ids 14–16 stay
  uninterpreted, and the contradiction is named on both the bucket rows and the `l` line.
* `capture-v21dbanner` applies the console-echo damage to the rung-1d bytes, because the
  repair keys on `[PROF] ver=` and must not care which shape follows the banner. The assertion
  is the same **identity** as the pre-split one.

If `build/unix-040` happens to be present the test additionally runs the ELF parser against
the real artifact. That case reports **SKIP**, not a pass, when the image is absent: it is
the only one that exercises the parser at the size and symbol-table shape the tool exists
for.
