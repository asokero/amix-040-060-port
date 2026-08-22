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

These two together are why the tool refused all seven captures of the first metal profiling
session while every one of them was provably intact. Nothing about the repair weakens the
truncation checks: a repair that could absorb a real loss would be worse than a refusal,
because it turns a hard error into a plausible profile.

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
than by apportionment:

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

190 checks. No board, no kernel image and no cross toolchain required.
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

If `build/unix-040` happens to be present the test additionally runs the ELF parser against
the real artifact. That case reports **SKIP**, not a pass, when the image is absent: it is
the only one that exercises the parser at the size and symbol-table shape the tool exists
for.
