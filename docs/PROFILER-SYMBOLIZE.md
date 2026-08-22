# Symbolizing a Z3660 interpreter-profiler capture

`tools/prof-symbolize.py` turns the serial output of the Z3660 accelerator firmware's
profiling build (`BOOT-prof.BIN`) into a symbolized profile of the guest — which AMIX kernel
functions the 68k interpreter is spending its time in, which opcodes it is dispatching, and
where inside the interpreter that time goes.

The firmware emits raw records and nothing else; symbolization belongs here because this is
where the kernel artifact and its symbol table live. The wire format is versioned; **version
1 is what this tool implements**, and it **refuses a version it does not know** rather than
guessing — the record layout, the flag bits and the ASCII dump grammar are all versioned by
that one number, so a guess would silently relabel a whole profile.

The contract lives on the firmware side, in `Z3660_emu/src/uae/z3660_prof.h` and
`docs/profiler.md` of the Z3660 firmware tree. This tool is written against it and does not
have to be rebuilt in step with the firmware.

**Version 1 has two defects that this tool corrects for, and both change numbers you would
otherwise read straight off the console.** The firmware over-prices the probe by exactly 2×,
and its `ATC_HIT` counter does not count what its name says. Both are described below, and
both live behind one table — `WIRE_VERSIONS` in `tools/prof-symbolize.py`, "THE VERSION
SEAM" — so that the firmware's own fix, which is a version bump, is one table entry here
rather than a rewrite. Until that entry exists a version-2 capture is **refused with the
reason**, because reading it under version-1 rules would halve an already-corrected probe
figure and read renamed counters under their old ids: a full report, and a wrong one.

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

Three things are worth getting right at capture time, because none of them can be repaired
afterwards:

* **Do not lose lines.** `PROF RING` is about 1.4 MB and two minutes at 115200. A terminal
  that scrolls, truncates or drops bytes produces a capture the tool refuses outright — the
  dump grammar is fixed-width precisely so that a lost line is *detectable* rather than
  quietly mis-parsed. Prefer `PROFR` (the newest 4096 samples, ~8 s) unless the whole ring
  is genuinely needed.
* **Keep the boot line.** `[PROF] profiling build: ARM clock … Hz (measured), enter/exit pair
  … cyc` is the calibration every later number depends on, and it is the only proof that
  core1 is running the profiling image at all. It is printed once, at init.
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

**3. A missed `PMCCNTR` wrap.** The 64-bit cycle base is extended at each sample, so if core1
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

#### The unit: `probe_cyc` prices a *pair*, `TRANSITIONS` counts *each half*

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

The `--probe-cost` override is in the same unit the firmware calibrates and prints: **the
cost of one pair**, not of one transition.

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

#### `ATC_HIT` does not count ATC hits

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
bump, which is why the corrected reading is recorded per-version in the seam.

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

113 checks. No board, no kernel image and no cross toolchain required.
`tools/prof-fixtures.py` builds the synthetic captures into a temporary directory — valid,
truncated, wrapped, weighted, and one per refusal — together with a small hand-assembled
m68k ELF and the equivalent `nm` dump, so **both** symbol paths are executed and asserted to
produce the same profile. Each fixture encodes one property, named in the generator next to
the numbers that produce it.

Three of the fixtures exist because the tool got these wrong against real captures, and each
wrong answer looked like a right one:

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

If `build/unix-040` happens to be present the test additionally runs the ELF parser against
the real artifact. That case reports **SKIP**, not a pass, when the image is absent: it is
the only one that exercises the parser at the size and symbol-table shape the tool exists
for.
