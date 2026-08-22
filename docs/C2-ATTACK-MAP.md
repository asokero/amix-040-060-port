# C2 attack map — where the interpreter's time actually goes

Measured on A4000 + Z3660 metal, 2026-08-22 (the "C1" profiling session). This document
turns the C1 captures into a ranked list of optimisation rungs with a measured ceiling on
each, so that C2 spends its effort where the cycles are rather than where they are assumed
to be.

Everything below is derived with `tools/prof-symbolize.py` (commit `e4c4974`) from the
lossless C1 captures, symbolized against the kernel that was actually running:

    build/unix-040-i46-i48-i49-i50-i51-i52f-hg-z3660-target-CARD1-ced0s1
    ET_REL, --load-base 0x08000000, 5475 .text symbols, 1875 assembler-locals filtered

**The headline is that the raw bucket ranking is wrong, and inverted at the top.** The
stage that looks largest before probe subtraction (LOOP, 26.35 %) is the one with the least
recoverable time in it, and the two stages that look middling (HANDLER, TAIL) are the two
that dominate. The whole point of the subtraction is that it moves the ranking; a
correction that could not change an order would not be worth applying.

---

## 0. Two corrections applied before any number in this document

### 0.1 The ×1.65 clock label (from `CLOCK-CORRECTION.txt`)

The firmware's `cpu_hz` is a compile-time BSP constant frozen at the 666.67 MHz default
while the part actually runs at 1100 MHz, so every Hz and seconds label in every capture
header is low by exactly 1.65. Applied wherever this document prints a rate or a duration:

| labelled | true |
|---|---|
| `cpu_hz` 666 667 585 Hz | 1 100 000 000 Hz |
| `wall_hz` 333 333 343 Hz | 550 000 000 Hz |
| sampler "40 Hz" | 66 Hz |
| sampler "4000 Hz" | 6600 Hz |

**Unaffected, and used as-is:** every bucket `cyc=` total, `cyc_span`, the 91-cycle probe
figure, every `[PROF] c` counter, and — decisively for this document — **every percentage
share**, because the erroneous constant cancels out of a ratio.

### 0.2 The captures needed a documented repair before the grammar would accept them

`prof-symbolize.py` refuses a capture it cannot prove intact, and it refused all seven C1
files. Both defects are in the capture path, not in the records:

* **The `profd` dumps** carry a `HH:MM:SS ` prefix on every line from the KVM logger.
* **Each ring dump's first `ring hdr` line lost its literal `[PROF] ` prefix**, because the
  console echo of `PROF RING (full) requested: …` and the firmware's first header line
  collide in the one UART. All `key=value` payload survives intact, `magic=Z3P1` included.

The repair is mechanical and was audited by count — one line changed per ring capture, and
the S-record count is identical before and after in every file:

| capture | lines | S recs before/after | ts stripped | hdr repaired |
|---|---|---|---|---|
| `15-BOOT3-ring-full.txt` | 24767 | 12378 / 12378 | 0 | 1 (line 3) |
| `10-DHRY-ring-full.txt` | 131080 | 65535 / 65535 | 0 | 1 (line 2) |
| `13-IO-ring-full.txt` | 131081 | 65535 / 65535 | 0 | 1 (line 3) |
| `11-STAGE-profd.txt` | 85 | 0 / 0 | 43 | 0 |

    line 3, before: 'F] ring hdr magic=Z3P1 version=1 rec_size=8 rec_count=12378 …'
    line 3, after : '[PROF] ring hdr magic=Z3P1 version=1 rec_size=8 rec_count=12378 …'

No sample line is in scope for either rule, and the integrity triple the manifest defines
(`rec_count` == `ring end n=` == S-records present) is still checked by the tool afterwards
and still holds. **Follow-up for the tool, not done here:** it should tolerate a line
prefix and should repair-with-a-warning a header line whose payload is complete and whose
magic is present, rather than refusing a capture that is provably intact.

---

## 1. Per-capture symbolized reports

### 1.1 Coverage verdicts — read these before any share below

| capture | records | samples taken | drops | verdict |
|---|---|---|---|---|
| **BOOT** `15-BOOT3-ring-full` | 12378 | 12378 | **0** | **LOSSLESS, whole-run, wrap check −0.003 %, zero warnings** |
| DHRY `10-DHRY-ring-full` | 65535 | 470 606 | 405 070 | tail only — 86.07 % of samples overwritten |
| IO `13-IO-ring-full` | 65535 | 890 258 | 824 722 | tail only — 92.64 % of samples overwritten |

**The single most important finding in this section: neither workload ring contains its
workload.** Both wrapped, and the retained tail landed *after* the benchmark finished, on
the scheduler idle loop:

| capture | `swtch` | `idle` | idle total | `STOP` opcode |
|---|---|---|---|---|
| BOOT | 14.10 % | 3.32 % | **17.43 %** | 1.90 % |
| DHRY | 52.04 % | 10.45 % | **62.49 %** | 5.54 % |
| IO | 59.66 % | 12.10 % | **71.76 %** | 6.41 % |

The `MANIFEST.txt` note on the dhry capture — *"dhry is a uniform loop so the tail is
representative"* — is refuted by its own data. The tail is not the loop; it is the machine
idling after the loop. Corroborating evidence, all three independent:

* the hot-PC table is a ten-instruction window inside `swtch` (`+0xa4` … `+0xe8`) plus
  `idle`, in both workload captures;
* the `STOP` opcode appears at 5.5–6.4 % of weighted time (the 68k idle instruction, which
  the interpreter re-executes on every pass) and is *absent* from the top 25 in any
  busy-dominated window;
* the wrap cross-check reports the gap between the last sample and the dump: **91.1 s**
  true for DHRY and **30.3 s** true for IO (the tool prints 150.345 s and 49.949 s at the
  uncorrected clock; ÷1.65). The rings hold only 9.9 s each at the true 6600 Hz, so the
  workload was overwritten long before the dump was taken.

`NOTES.txt` predicted exactly this failure mode for the 4096-sample `PROFR` slice and
worked around it by dumping the full ring — but the full ring is still only 9.9 s at the
true rate, and the workload had already ended. **The mitigation was correct in form and
insufficient in size.**

What survives from those two runs is the `PROFD` counter block, which is cumulative and
exact over the whole run. Those are used below; the workload rings' *shares* are not.

### 1.2 BOOT — the one trustworthy ring profile

Complete single boot: emulator start 18:40:50, MMU enable 18:41:33, login 18:43:15. 12393
weight-periods at the true 66 Hz = **187.8 s** observed.

**Mode split (weighted).** Four modes, and the pre-AMIX ones are the AmigaOS bootstrap
phase, correctly *not* symbolized against the kernel:

| mode | weight % |
|---|---|
| SUPER · MMU · AMIX · 68040 | 66.23 % |
| user · 68040 (pre-AMIX) | 15.42 % |
| user · MMU · AMIX · 68040 | 10.81 % |
| SUPER · 68040 (pre-AMIX) | 7.54 % |
| **supervisor total** | **73.77 %** |
| user total | 26.23 % |

**Top supervisor symbols (weighted, % of all observed time).**

| rank | wt % | symbol |
|---|---|---|
| 1 | **17.53 %** | `bzero` |
| 2 | 14.10 % | `swtch` |
| 3 | 5.96 % | `Lcb_loop` |
| 4 | 3.37 % | `rom/amigaos:00f81000` |
| 5 | 3.32 % | `idle` |
| 6 | 2.69 % | `rom/amigaos:00008000` |
| 7 | 1.37 % | `mcpy` |
| 8 | 1.36 % | `z3660_rw` |
| 9 | 0.65 % | `systrap` |
| 10 | 0.65 % | `u_trap` |

**`bzero` is 17.53 % of the entire boot, and 21.23 % of non-idle boot time — and a single
PC carries almost all of it:** `bzero+0x2a` at `0800032c` is **17.32 % of all observed
time** on its own. The opcode histogram names the loop outright: `20c9` = `MOVE.L A1,(A0)+`
at 9.45 % and `51c9` = `DBRA` at 10.73 %, i.e. **20.18 % of all boot weight is two
instructions of a longword zero-fill loop.** See §3.7 — this is the largest single
identified target in the whole map and it sits outside the mirrored ladder.

**PC concentration** (the decoded-op-cache viability input), 3011 distinct PCs:

| | all samples | busy only (idle excluded, 2989 PCs) |
|---|---|---|
| top 10 | 38.25 % | 41.23 % |
| top 50 | 64.92 % | 58.78 % |
| top 200 | 71.66 % | 66.05 % |
| top 500 | — | 73.14 % |
| top 1000 | — | 80.56 % |
| top 2000 | — | 90.34 % |

Busy-only, 50 % of the time needs the top **18** PCs (0.6 % of distinct — that is `bzero`),
80 % needs the top **943**, 90 % needs **1966**.

**Opcode line-major rollup** (busy-only in brackets): line 2 `MOVE.L/MOVEA.L` 24.30 %
[27.42 %], line 4 `misc (LEA/JSR/MOVEM/TST/CLR)` 23.42 % [15.32 %], line 5
`ADDQ/SUBQ/Scc/DBcc` 18.32 % [20.43 %], line 6 `Bcc/BSR/BRA` 12.21 % [12.66 %], line 1
`MOVE.B` 6.69 % [8.10 %], line F `FPU/MMU/cache` 1.82 %. 1015 distinct opcode words; the
top 20 carry 58.94 % of busy time.

**WEIGHT histogram — what the sampler could not see.** 12371 of 12378 samples have weight
1. Seven samples exceed it (0.06 % of samples, **0.18 % of observed time**), the largest a
single sample of weight 10. Nothing saturated at 255.

### 1.3 DHRY and IO — usable only as counter blocks

Their ring *shares* describe an idle machine and are not used in the map. Their weight
histograms and their whole-run counters are used.

**WEIGHT.** DHRY: 65522/65535 at weight 1; 13 samples above (0.17 % of time), largest bin
9–16. IO: 65523/65535 at weight 1; 12 samples above (**0.05 % of time**), largest bin 2–4.
Nothing saturated anywhere.

**Whole-run counters (`PROFD`, exact, cumulative over the entire run).**

| counter | BOOT | DHRY | IO |
|---|---|---|---|
| INSNS | 276 144 549 | 144 852 666 | 262 632 506 |
| supervisor share | **80.09 %** | 61.23 % | 76.50 % |
| FETCH / insn | 1.5788 | 1.6377 | 1.6377 |
| READ / insn | 0.2374 | 0.3670 | 0.3399 |
| WRITE / insn | 0.2956 | 0.2882 | 0.2459 |
| ipagecache hit | 98.20 % | 98.18 % | **96.64 %** |
| dpagecache read hit | 98.76 % | 99.44 % | 99.04 % |
| dpagecache write hit | 99.02 % | 99.54 % | 99.27 % |
| translates (XLATE) | 1 838 545 | 1 884 252 | 4 228 920 |
| table-walk rate | **29.40 %** | 12.75 % | 16.46 % |
| misaligned accesses | 9.34 % | 13.72 % | **15.90 %** |
| FAULTS | 7467 | 3629 | 8939 |

---

## 2. The corrected bucket shares, with the arithmetic shown

### 2.1 The probe-landing model reproduces the firmware's own transition count

The firmware reports one *global* transition count, so a per-bucket subtraction has to be
modelled. The model is mechanism-derived — each bucket pays for its own `enter()`s plus one
`exit()` for every entry of every bucket nested inside it — and it is checked against the
firmware's exact count before anything derived from it is printed:

    enters modelled from the counters      483 046 085
    transitions modelled  (= 2 x enters)   966 092 170
    transitions measured  (firmware)       966 080 190
    residual                                   -11 980   =  0.0012 %

**The 25 % residual gate does not bite. It is not close to biting.** The model predicts the
measured count to 12 parts per million of a 966-million-event total, over four levels of
nesting. That is the strongest single piece of evidence in this document that the bucket
attribution is understood rather than guessed at.

### 2.2 The firmware over-prices the probe by exactly 2×

`prof-symbolize.py` inherits the firmware's convention, `probe = TRANSITIONS × PROBE_CYC`,
and that convention is wrong. Read out of the firmware source:

* `z3660_prof.h:378` — `z3660_prof_enter()` does `z3660_prof_cnt[…TRANSITIONS]++`
* `z3660_prof.h:395` — `z3660_prof_exit()` does `z3660_prof_cnt[…TRANSITIONS]++`
* `z3660_prof.cpp:203-221` — `z3660_prof_calibrate_probe()` times **256 iterations of
  `enter()` *followed by* `exit()`** and divides the total by 256.

So `PROBE_CYC` is the cost of a **pair**, i.e. of **two** transitions, while `TRANSITIONS`
counts each enter and each exit separately. Multiplying one by the other double-counts.
The per-transition cost is `PROBE_CYC / 2 = 45.5` cycles, and the probe overhead is

    966 080 190 x 45.5 = 43 956 648 645 cyc = 41.33 % of total_cyc

not the 82.65 % the firmware prints (and `docs/profiler.md` and the `z3660_prof.h:84`
comment repeat). **Three independent lines confirm the corrected reading:**

1. **Feasibility.** At 82.65 % the model demands 43.80 G cycles of probe from LOOP, a
   bucket that contains only 28.03 G. The subtraction is arithmetically impossible and the
   tool clamps, silently absorbing 15.77 G cycles of over-subtraction. At 41.33 % every
   bucket stays positive and the adjusted totals sum to `total − probe` exactly (to 7
   cycles of integer-division rounding).
2. **The A/B table.** `AB-TABLE.txt` measures the *incremental* cost of arming the buckets
   as 3409 → 2106 dhry/s, i.e. 38.22 % of the bucket-armed run's time. 41.33 % agrees;
   82.65 % would require the armed machine to be 5.76× slower than unarmed, where it is
   measured at 1.62×.
3. **The residual is the right size.** 41.33 % (whole probe body) − 38.22 % (the part that
   goes away when disarmed) ≈ 3.1 %, which is the call-and-test overhead paid even when the
   buckets are off — exactly bias note 2b in `z3660_prof.h`.

### 2.3 The corrected table

Probe distributed by the modelled landing shape at 45.5 cyc/transition:

| bucket | raw cycles | raw share | probe cyc | adjusted | **corrected share** |
|---|---|---|---|---|---|
| HANDLER | 20 646 592 712 | 19.41 % | 5 127 339 789 | 15 519 252 923 | **24.87 %** |
| TAIL | 17 616 115 985 | 16.56 % | 5 127 339 789 | 12 488 776 196 | **20.01 %** |
| FETCHOP | 14 613 725 861 | 13.74 % | 5 157 538 811 | 9 456 187 050 | **15.15 %** |
| FETCHEX | 10 033 313 289 | 9.43 % | 3 189 156 462 | 6 844 156 827 | **10.97 %** |
| LOOP | 28 029 264 727 | **26.35 %** | 21 898 319 297 | 6 130 945 430 | **9.82 %** ▼ |
| WRITE | 7 094 064 853 | 6.67 % | 1 450 879 501 | 5 643 185 352 | **9.04 %** |
| READ | 7 382 929 948 | 6.94 % | 1 914 475 300 | 5 468 454 648 | **8.76 %** |
| WALK | 546 404 658 | 0.51 % | 11 427 228 | 534 977 430 | **0.86 %** |
| XLATE | 342 038 330 | 0.32 % | 80 005 024 | 262 033 306 | **0.42 %** |
| FAULT | 58 381 469 | 0.05 % | 167 437 | 58 214 032 | **0.09 %** |
| **TOTAL** | **106 362 831 832** | 100 % | **43 956 648 645** | **62 406 183 194** | **100 %** |

**LOOP falls from first place to fifth.** Its apparent 26.35 % was overwhelmingly the
probe's own `exit()` cost: LOOP is the parent of eight nested stages, so it pays one exit
for every entry of all of them — 481 M of the 966 M transitions land in it.

### 2.4 The residual confidence, stated honestly

**LOOP's 9.82 % is an upper bound, and the true figure may be zero.** The calibration
*inlines* `enter`/`exit` in a 256-iteration loop, whereas the real accessors invoke them as
**out-of-line calls** (bias note 2b says every instrumented accessor makes three). The real
per-transition cost is therefore certainly above the calibrated 45.5 cycles. The cost at
which LOOP is exhausted is **58.24 cyc/transition (a 116.5-cycle pair)** — only 28 % above
the calibrated figure, which an inline-vs-call gap can easily account for.

The two endpoints bracket every share in this document:

| bucket | at 45.5 cyc/transition | at 58.24 cyc/transition (LOOP exhausted) |
|---|---|---|
| HANDLER | 24.87 % | 28.11 % |
| TAIL | 20.01 % | 22.06 % |
| FETCHOP | 15.15 % | 15.99 % |
| FETCHEX | 10.97 % | 11.88 % |
| LOOP | 9.82 % | 0.00 % |
| WRITE | 9.04 % | 10.45 % |
| READ | 8.76 % | 9.85 % |
| WALK | 0.86 % | 1.06 % |

**The ranking is stable across the whole bracket** — HANDLER > TAIL > FETCHOP > FETCHEX >
{WRITE, READ} > WALK > XLATE > FAULT, with LOOP the only bucket that moves, and it only
moves downward. Every conclusion in §3 is drawn from the conservative (45.5) endpoint,
which is the one most favourable to LOOP.

### 2.5 Corrected per-event costs

At the true 1.1 GHz, over the 112 690 184 instructions of the stage span:

| bucket | cycles per event | event | ns |
|---|---|---|---|
| HANDLER | 137.7 | per instruction | 125.2 |
| TAIL | 110.8 | per instruction | 100.7 |
| FETCHOP | 83.9 | per opcode fetch | 76.3 |
| FETCHEX | 98.2 | per extension-word fetch | 89.3 |
| READ | 130.7 | per guest read | 118.8 |
| WRITE | 178.0 | per guest write | 161.8 |
| XLATE | 173.9 | per translate | 158.0 |
| WALK | 2130.1 | per table walk | 1936.5 |
| **TOTAL** | **553.8** | **per instruction** | **503.4** |

These are the numbers that make the map actionable. **84 ARM cycles to fetch one 16-bit
opcode word, and 178 to perform one guest write, are not the cost of the operation — they
are the cost of the machinery around it.**

---

## 3. THE MAP — the mirrored-ladder rungs ranked by measured ceiling

Amdahl on the corrected shares, against the lean cadence-1 baseline of **4500 dhry/s**.
Reclaim fractions are deliberately conservative and are *estimates, not measurements* —
they are the one genuinely soft input in this document and are flagged as such in every
row. Time won = share × reclaim; speedup = 1/(1 − time won).

| # | rung | buckets | **measured share** | reclaim (conservative, **estimated**) | time won | speedup | **dhry** |
|---|---|---|---|---|---|---|---|
| **1** | **decoded-op cache** | FETCHOP + FETCHEX | **26.12 %** | 55 % | 14.37 % | 1.168× | **5255** |
| **2** | **run-loop tail** | TAIL | **20.01 %** | 45 % | 9.01 % | 1.099× | **4945** |
| **3** | **accessor inlining (dcache)** | READ + WRITE | **17.81 %** | 40 % | 7.12 % | 1.077× | **4845** |
| **4** | **handler specialisation** | HANDLER | **24.87 %** | 25 % | 6.22 % | 1.066× | **4798** |
| **5** | **dispatch (LOOP residue)** | LOOP | **≤ 9.82 %** | 40 % | ≤ 3.93 % | ≤1.041× | **≤4684** |
| **6** | **ATC fast path** | XLATE + WALK | **1.28 %** | 60 % | 0.77 % | 1.008× | **4535** |
| — | all six, independent | | | | 41.41 % | 1.707× | **7680** |
| **J** | **the residual only a JIT reaches** | FETCHOP+FETCHEX+LOOP+TAIL | **55.96 %** | 90 % hot-code coverage | 50.36 % | 2.015× | **9065** |

### 3.1 Rung 1 — decoded-op cache (FETCHOP + FETCHEX, 26.12 %)

**The largest rung, and the one with the best evidence behind it.** Fetch costs 83.9 cyc
per opcode word and 98.2 per extension word, at 1.6377 fetches per instruction. A decoded-op
cache removes *both* the fetch and the decode for any PC it holds.

*Viability from the measured PC distribution* (busy-only, boot — the only trustworthy ring):
80.56 % of busy time is covered by the top **1000** PCs and 90.34 % by the top **2000**, out
of 2989 distinct. A 2048-entry cache is ~32 KB at 16 B/entry — comfortably resident. The
workload captures agree in shape despite their idle contamination (80 % of busy time needs
1781–2014 PCs).

*What would raise confidence:* a re-taken dhry/IO ring that actually contains its workload
(§5), giving a concentration curve for compute-bound and I/O-bound code rather than boot;
and a direct measurement of the tier-0 `ipagecache` hit path cost, since at 96.6–98.2 % hit
rate the 84-cycle fetch is *dominated by the hit path*, not by misses.

*Caveat:* the 55 % reclaim assumes a cache hit removes essentially all of fetch+decode. It
does not remove the guest-PC bounds and mode checks; if those are the bulk of the 84 cycles,
reclaim is lower. This is the estimate most worth replacing with a measurement.

### 3.2 Rung 2 — run-loop tail (TAIL, 20.01 %)

**110.8 ARM cycles per guest instruction, spent after the handler has finished.** That is
the most disproportionate number in the table: the tail should be a PC advance and a cheap
event test. 110 cycles says it is doing per-instruction work that belongs at block
boundaries — interrupt polling, trace/single-step checks, the sampler hook, cycle
accounting.

*What would raise confidence:* a bucket split of TAIL into its constituent checks. This is
a firmware change (new bucket ids are append-only) and is the single highest-value
instrument improvement C2 could make, because a 20 % bucket with no internal breakdown is a
20 % bucket nobody can attack safely.

### 3.3 Rung 3 — accessor inlining (READ + WRITE, 17.81 %)

130.7 cyc per guest read and **178.0 per guest write**, against tier-0 page-cache hit rates
of 98.8–99.5 %. Almost every one of those accesses *hits*, so the cost is the call-and-test
machinery around a hit, not the miss path. Note the asymmetry: writes cost 36 % more than
reads while having a *higher* hit rate — worth understanding before optimising.

*Caveat, and it is the important one:* this rung's share is the most inflated by the prof
build. The instrumented accessors make three out-of-line calls each and the lean build does
not (see §4), so part of the 17.81 % is instrumentation that lean does not pay.

### 3.4 Rung 4 — handler specialisation (HANDLER, 24.87 %)

The largest *single* bucket, at 137.7 cyc per instruction — the actual emulated semantics.
It is ranked below rungs 1–3 despite its size because it is the hardest to reclaim: this is
irreducible work plus per-handler overhead, and 25 % is a deliberately modest estimate.

*The specialisation targets are named by the opcode histogram.* Busy-only boot: line 2
(MOVE.L/MOVEA.L) 27.42 %, line 5 (ADDQ/SUBQ/Scc/DBcc) 20.43 %, line 4 (misc) 15.32 %,
line 6 (Bcc/BSR/BRA) 12.66 %. **Four line-groups carry 75.8 % of busy time**, and the top 20
individual opcode words carry 58.94 %. A specialisation pass covering ~20 opcodes reaches
most of the traffic.

### 3.5 Rung 5 — dispatch / LOOP residue (≤ 9.82 %)

**This is the rung the raw data would have put first, and it belongs near the bottom.**
Its corrected share is an upper bound that reaches zero at a probe cost only 28 % above the
calibrated one (§2.4). Any C2 work aimed at the dispatch loop should be gated on first
re-measuring the probe cost with an out-of-line calibration, because the honest current
answer is "somewhere between nothing and 9.8 %".

### 3.6 Rung 6 — ATC fast path (1.28 %)

**Measured, and small enough to decline on performance grounds.** Even a 100 % reclaim is
worth 1.3 % (≈4558 dhry/s). Two qualifications: BOOT's table-walk rate is 29.40 % against
DHRY's 12.75 %, so translation matters more during bring-up than in steady state; and a
walk costs 2130 cycles, so it is expensive *per event* while being rare. Attack this rung
for boot latency or for correctness, not for throughput.

### 3.7 Outside the ladder — `bzero`, the largest single identified target

Not a ladder rung, and larger than most of them. **17.53 % of the whole boot profile is
`bzero`, 17.32 % of it at the single PC `bzero+0x2a`, and the loop is two opcode words
(`MOVE.L A1,(A0)+` + `DBRA`) carrying 20.18 % of all boot weight.**

Costing that loop from the §2.5 per-event table — two instructions paying HANDLER + TAIL +
FETCHOP + LOOP each, one extension-word fetch for the `DBRA` displacement, and one write:

    2 x (137.7 + 110.8 + 83.9 + 54.4)  +  98.2  +  178.0  =  1049.8 cyc per 4 bytes
                                                          =   262.4 cyc per byte
                                        at 1.1 GHz        =   ~4.2 MB/s

**Kernel zero-fill runs at roughly 4 MB/s**, and the store accounts for only 178 of those
1050 cycles — **83 % of the cost is interpreter machinery around a four-byte write.**

Recognising a longword-store loop and servicing it with a host `memset` on the translated
page — or routing it through the existing `MOVE16` path — is a narrow, self-contained change
with a large, *measured* boot-time payoff and no interpreter-architecture risk. It should be
costed before any of the ladder rungs, on effort-to-payoff grounds.

*Caveat:* this is measured on the **boot** profile. `bzero` is 2.26 % of busy dhry time and
2.20 % of busy IO time, so it is a boot/page-fault phenomenon, not a steady-state one. The
claim is "boot spends a fifth of its time here", not "the system does".

### 3.8 The JIT ceiling

The purely interpretive buckets — FETCHOP, FETCHEX, LOOP, TAIL — total **55.96 %**. A JIT
removes essentially all of that for code it has compiled, leaving HANDLER's semantics and
the memory accessors:

| hot-code coverage | time won | speedup | dhry |
|---|---|---|---|
| 80 % | 44.76 % | 1.810× | 8147 |
| 90 % | 50.36 % | 2.015× | 9065 |
| 95 % | 53.16 % | 2.135× | 9607 |

**A JIT is worth about 2×, and the six interpreter rungs together are worth about 1.7×.**
That is the decision this map exists to inform: the ladder gets most of the way to the JIT's
ceiling at a small fraction of its risk. The measured PC concentration (§3.1) is what makes
90 % hot-code coverage plausible.

---

## 4. What this does **not** establish

Per `docs/METHOD.md` §7 (*the platform is part of every claim*) and §8 (*record refuted
conclusions*):

**4.1 Every share is of the DISTORTED machine.** The bucket dump comes from a build that
measures 3457 dhry/s at idle against lean's 4500 — **−23.2 %** — and 2106 with the buckets
armed, **−53.2 %**. Probe subtraction removes the probe *bodies*. It does **not** remove the
compiled-in cost of bias note 2b: the lean build's accessors do not make the three
out-of-line calls at all. So the corrected shares describe *the prof-build interpreter with
its probe bodies removed*, which is not the lean interpreter.

**Direction of the bias is known even though its size is not.** The compiled-in overhead
lives in the instrumented accessors, so **FETCHOP, FETCHEX, READ and WRITE are inflated
relative to lean**, and HANDLER/TAIL/LOOP are correspondingly deflated. Therefore:

* Rungs **1 and 3** (fetch, accessors) have shares that are **over-stated for lean** — their
  dhry predictions are optimistic.
* Rungs **2 and 4** (TAIL, HANDLER) have shares that are **under-stated for lean** — if
  anything they rank higher on the lean machine than shown here.
* The 23.2 % idle gap is an upper bound on the total misallocation, and it cannot be
  decomposed from these captures.

This does not disturb the map's *ordering*, because the two rungs at the top move in
opposite directions and rung 1 leads rung 2 by only 6 points. **It does mean no dhry figure
in §3 is a prediction of what lean will measure.** They are ceilings on the distorted
machine, transferred by assumption.

**4.2 There is no lean bucket profile, and there cannot be one from this instrument.** The
buckets *are* the instrumentation; arming them is what costs 38 %. Closing this gap needs a
different instrument (ARM PMU event sampling, or a statistical PC profile of the lean build
correlated against the stage map), not a better dump.

**4.3 The stage span is not a pure dhrystone workload.** `11-STAGE-profd` reports 61.97 %
supervisor instructions — a mixed system-plus-benchmark span. The shares are representative
of "the machine running a compute benchmark under a live SVR4 kernel", not of dhrystone.

**4.4 The workload rings measured idle, so no workload-specific PC concentration exists
yet.** §3.1's viability argument rests on the **boot** profile. Boot is memory-and-fault
heavy and its concentration may differ from a compute loop's in either direction.

**4.5 `ATC_HIT` does not mean what its name says — corrected here.** The tool's
cross-check fired on all four dumps, and the resolution is that two exact identities hold in
every one of them (four independent spans, seven-digit numbers):

    IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS  ==  XLATE          (all four dumps)
    ATC_HIT + FAULTS                        ==  XLATE          (all four dumps)

So `XLATE` is exactly the tier-0 miss count (calls into `mmu_translate`), and **`ATC_HIT`
counts translates that *succeeded*, not ATC lookups that *hit*** — it carries no ATC
information whatsoever. `ATC_HIT + ATC_MISS` is therefore a meaningless sum and the tool's
warning text ("every translate is either an ATC hit or a walk") states a wrong reason for a
real problem. The firmware's own printed walk rate, `ATC_MISS / XLATE`, is **correct**. The
true ATC hit rate is `(XLATE − ATC_MISS) / XLATE`:

| dump | true ATC hit | walk rate |
|---|---|---|
| STAGE | 83.34 % | 16.66 % |
| DHRY | 87.25 % | 12.75 % |
| IO | 83.54 % | 16.46 % |
| BOOT | 70.60 % | 29.40 % |

Two fixes follow, neither made here: rename the firmware counter (it is append-only, so a
rename is a version bump), and correct the tool's cross-check and its warning text.

**4.6 The probe cost itself is unverified at the point of use.** 91 cyc/pair was measured
with the probes *inlined*; they are *called* in production. §2.4 shows the whole LOOP result
turns on this. An out-of-line recalibration is a small firmware change and would convert the
LOOP bracket into a number.

**4.7 Reclaim fractions are engineering estimates.** The shares are measured; the reclaim
column is not. Every dhry figure in §3 inherits that softness. They rank rungs; they do not
forecast releases.

---

## 5. What C2 should measure next

1. **Re-take dhry and IO rings that contain their workloads.** Arm at the lowest rate that
   still resolves (nominal 250 → true 412 Hz gives 159 s of wrap-free window), or dump
   immediately at workload end. This is the one gap that blocks §3.1's viability argument
   from resting on anything but boot.
2. **Split TAIL into sub-buckets** (§3.2) — the highest-value instrument change available.
3. **Recalibrate the probe out-of-line** (§4.6) — converts LOOP's `≤ 9.82 %` into a number.
4. **Fix the 2× probe over-pricing** in the firmware's reporting line, `docs/profiler.md`,
   the `z3660_prof.h:84` comment, and `prof-symbolize.py` (§2.2).
5. **Fix the `ATC_HIT` counter and the tool's translation cross-check** (§4.5).
6. **Cost the `bzero` idiom fast path** (§3.7) before any ladder rung.
