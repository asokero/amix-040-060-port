# C2 attack map — where the interpreter's time actually goes

**How to read this file.** It has three parts, newest first.

* **Part I — v3.3 (§§35–40), v3.2 (§§27–34), v3.1 (§§20–26) and v3 (§§13–19)**, below, is the
  current map, newest first inside the part. v1 and v2 ranked a machine nobody had changed yet.
  **v3 is the first version written after the top of the ladder was actually built**, and it is a
  different kind of document for that reason: four of its numbers are outcomes rather than
  predictions, one rung was built and taken back, and the instrument that produced the
  earlier rankings was itself corrected mid-campaign. **v3.1 is v3's own §19 list, taken.**
  It does not replace v3 — §§13–14 stand unedited — it *opens* v3's largest bucket, prices
  v3's own bar, and re-ranks the ladder around what was inside. **v3.2 is v3.1's own
  recommendation, taken twice with opposite outcomes**: rung 2 paid +25.17 %, rung 3 paid
  nothing, and the mechanism that separates them (§30) re-prices every remaining row.
  **v3.3 is v3.2's ladder #1, sent to metal and taken off the board** — struck as a rung by a
  static count without the bucket ever being classified (§36) — **and v3.2's own stale input,
  re-measured and re-scored** (§38). Every ranked number in Part I is measured on the
  2026-08-22/23 metal sessions.
* **Part II — v2 (§§6–12)** is the map the campaign was dispatched from. It is
  **superseded in part**: its ordering held, its rung 1 estimate was vindicated, and one of
  its conclusions — "`LOOP` is empty" — is **refuted by measurement** (§15). Kept whole.
* **Part III — v1 (§§0–5)** is the first map, written the same day as v2 from the morning's
  captures. **Superseded but kept**, per `docs/METHOD.md` §8: a refuted conclusion is
  evidence about the instrument, and deleting it would delete the reason the later numbers
  are believable.

Where they disagree, **the later part wins**, and each says which input moved. §18.4 is the
running ledger of every claim in this file that measurement has since refuted, v3's own
included.

---

# PART I — v3.3 (§§35–40), v3.2 (§§27–34), v3.1 (§§20–26) and v3 (§§13–19), 2026-08-23

**v3.3 first, then the v3.2 it amends, then the v3.1 that v3.2 amends, then v3.** §§13–14 — the
four rungs as built — are unedited and still current, and so is everything each version
*measured*. What v3.2 touched is what v3.1 *projected*: the ladder (§24.2), its reclaim
rationales (§24.3), the bar (§24.4) and the recommendation (§25). **What v3.3 touches is what
v3.2 projected**: ladder row #1 (§33.3), the `HANDLER` row of the pricing-law pass (§33.2), the
recommendation (§33.4) and the input it flagged as stale (§22.3). Each amended section carries a
banner and stays otherwise unedited.

---

## 35. What v3.3 is

**v3.2's ladder #1 was sent to metal, and it came back with an answer to a different question
than the one it was asked.** §33.2 made `HANDLER`'s classification the prerequisite for funding
it and §33.3 note 1 said *"its first move is not a design; it is the §30.3 discriminator on one
handler family"*. That discriminator was built and run. It returned **−7.55 %** — off the bottom
of its own pre-registered scale — at **21.12 %** coverage, dead centre of the band. It engaged,
it worked as plumbing, and it made the machine slower.

**That splits the verdict in two, and the two halves must not be collapsed** (§36). The
*bucket* is exactly as unclassified as it was before the session: an experiment whose premise
was *"the body removes work"* measured a body that **added** work, so every band downstream of
that premise was measuring an implementation. The *rung*, however, comes off the board anyway —
not from the metal row but from a static count taken afterwards, which shows that a body meeting
the experiment's own gate cannot beat the generated handlers it replaces.

**And v3.3 pays the debt §33.4 opened.** The fill-path price the physical-index study is sized
against was measured while the rig was up: **75.9 – 81.9 cyc/miss at calibration band
`[54, 60]`**, against the **62–64** the design carries. §38 re-runs §22.3's and §24.4's
arithmetic against it, on one band, on this session's own capture — both the prize side and the
bar side — and returns a funding recommendation.

Nothing here comes from a new instrument. §37 adds two things the instrument cannot do that
this session found out the hard way, and one of them (§37.2) is a *tool*, not a caveat.

### 35.1 Provenance

| | |
|---|---|
| session | 2026-08-23, 14:29 → 15:34 EEST, A4000 + Z3660 metal |
| evidence | `2026-08-23-spec-verdict/` — `MATRIX.md` (scorecard), `NOTES.txt` (F1–F9), `expectations.md` (pre-registration, written before power-on, unedited) |
| rig | preset 7 (`amix_ram 128`, `service_cadence 4`, `arm_frequency 1100`), AMIX on piscsi card 1, the preset *file* never written |
| design doc | `Z3660/docs/handler-discriminator.md` — now carrying the scored table, the static autopsy, the gate and the **PARKED** verdict |
| console switch | `SPEC` (unset = ON) |
| firmware | pre-registration `d7f5470`, code `87d3f49`; lean `6ADABE4A`, prof `8B5DC5C3`; reference lean `DEC21748` |
| **verdict** | **OFF-SCALE MISS — REVERTED** (`Z3660 363a508`) |

Continuity, and it is the strongest this lane has had: the as-found row reproduced the r3
session's measurement of the **same image** with a mean of **8188.7 against 8188.7 — identical
to the digit** — and the reference row reproduced r3's `DEC21748` median of **8197 exactly**.
The serial capture opened at r3's close-out offset and is byte-exact end to end (270 505 B
requested, 270 505 B received, zero drops).

### 35.2 The standing posture — unchanged, and now cryptographically pinned

| row | dhry c4, lean, `service_cadence 4`, `amix_ram 128` |
|---|---|
| **`DEC21748` — the reference, and the standing build** | **8197** (8197 / 8141 / 8197 / 8197 / 8174; mean 8181.2, spread 0.68 %) |
| `86C0BC18` — the rung-3 lean image, as found | 8185 (8219 / 8162 / 8185; mean 8188.7) |
| `6ADABE4A` — `SPEC` armed (*the row*) | **7578** — **−7.55 %** |
| `6ADABE4A` — `SPEC` disarmed, same boot | 8109 — **−1.07 %**, the machinery's standing cost |
| `6ADABE4A` — `SPEC` armed, return leg | 7573 (reproduces the first armed arm to −0.07 %) |

**The standing posture is 8185-class and has not moved.** §27.2's figure stands; this session
simply re-took it on the true rung-2 binary. Read every share and every projection in §§38–39
against **8185**, as v3.2 did.

> **§34.1 is CLOSED, and closed cryptographically.** v3.2 had to record that the card held
> `86C0BC18` while the repo held a rung-3 tree, with **no copy of `DEC21748` in existence**, so
> *"the standing build"* and *"the rung-2 build"* were two binaries that merely measured the
> same. Both halves are now discharged: the image was rebuilt and archived, the card was flashed
> with it and **CRC-gated on the card twice** (14:39 as the reference arm, 15:32 as the
> close-out, `0:/Z3660.bin` = `DEC21748`), and the **reverted firmware tree rebuilds
> `BOOT-lean.BIN` byte-for-byte to `DEC21748`**. Card and repo are the same binary, by CRC, not
> by inference. The parked card also holds `FAILSAFE.bin 7E03DA03` intact, zero staged
> leftovers, and a config byte-identical to the r3 close-out snapshots.

---

## 36. The `HANDLER` discriminator — OFF-SCALE MISS, and the verdict has two halves

### 36.1 The row, and where all of it went

Cross-build lean cadence-4 dhrystone, `SPEC` build armed against `DEC21748`, same session:

```
cross-build   SPEC ON  vs DEC21748 : 7578/8197 = 0.92448  ->  -7.55 %   <- THE VERDICT NUMBER
disarm        SPEC OFF vs DEC21748 : 8109/8197 = 0.98926  ->  -1.07 %
same-boot     SPEC ON  vs SPEC OFF : 7578/8109 = 0.93452  ->  -6.55 %
identity      0.98926 x 0.93452    = 0.92448  ==  0.92448   CLOSES TO FIVE DIGITS
```

The pre-registration has exactly three cells — NULL (±0.68 %), PAY (≥ +0.90 %), UNRESOLVED
between — and **all three assume the armed arm is at worst flat**. −7.55 % is **6.87 pp below
the NULL floor**. No cell applies. This is not the *"null with zero coverage = build failure"*
case the doc warns about either: `SPEC_HIT / INSNS` is **21.12 %**, dead centre of the
pre-registered 18–27 % band, and pinned at **0.00 %** in both off-arms.

**The loss is entirely inside `HANDLER`, and nothing got cheaper.** Same-boot switch, prof image
`8B5DC5C3`, stage buckets armed, corrected cycles **per guest instruction**, band `[54, 60]`:

| bucket | SPEC ON | SPEC OFF | @54 | @60 |
|---|---|---|---|---|
| **`HANDLER`** | **105.07** | **91.97** | **+14.25 %** | **+16.25 %** |
| `DOPCFILL` | 19.79 | 17.84 | +10.90 % | +11.69 % |
| `TAILSPEC` | 2.07 | 1.89 | +9.16 % | +9.33 % |
| `FETCH` pair | 79.38 | 77.62 | +2.27 % | +2.35 % |
| `WRITE` | 34.35 | 33.71 | +1.90 % | +2.00 % |
| `DOPCFIND` | 77.83 | 76.75 | +1.40 % | +1.52 % |
| `READ` | 43.77 | 43.75 | +0.04 % | +0.03 % |
| `LOOPRES` | 56.64 | 56.86 | −0.38 % | −0.78 % |
| **corrected TOTAL** (instrument excluded) | **496.52** | **477.05** | **+4.08 %** | **+4.83 %** |

**Not one bucket moved down by more than the 0.4–0.8 % `LOOPRES` residue**, and the counters say
the *work* is identical: `READ`/INSN 0.4215 vs 0.4219, `WRITE`/INSN 0.3007 vs 0.3010,
`XLATE`/INSN 0.01700 vs 0.01683, faults 3630 vs 3629, `dpagecache` read 99.44/99.45. **Same work,
more cycles, all of it in one bucket.** Per served instruction, two independent derivations:
**+33.2 % slower** (lean wall clock, ≈ +24 cyc at 71.8 cyc/INSN) and **+65 cyc inside the
`HANDLER` bracket alone** (bucket capture, 13.10 cyc/INSN over 20.15 % coverage). The two
instruments disagree in size — the bucket figure sits inside a bracket that also carries probe
scaffolding — and **agree completely in sign and location**. The doc predicted the served
dispatch would get **7–11 % cheaper**.

### 36.2 Half one — the `HANDLER` BUCKET remains UNCLASSIFIED

> **The experiment measured an implementation, not the bucket.**

§33.2 asked one question of this bucket: *is the work it contains dependency-chained, or does
it sit beside a latency something else is already hiding?* The discriminator was built to read
that off **the sign of a removal**. What rode through it was not a removal:

* The pre-registered failure mode was *"the path serves 20 %, the handler bodies get measurably
  **shorter**, and dhrystone does not move"*. The path served 21.12 % and the handler bodies got
  measurably **LONGER** — +14–16 % — and dhrystone moved, downward. **A third outcome the
  pre-registration did not enumerate.**
* You cannot read *"`HANDLER` is dependency-chained"* out of a regression. You cannot read
  *"`HANDLER` is latency-hidden"* out of one either — **a null was the reading that would have
  said that**, and this is not a null.

So §33.2's `HANDLER` row is unchanged, word for word: **UNCLASSIFIED, and the classification is
still the prerequisite.** What changed is its price. §33.3 note 1 said the classification cost
one discriminator; it now costs a design round, because the only body that could carry a clean
removal is the design the discriminator existed to decide whether to fund (§36.4).

### 36.3 Half two — the handler-specialisation RUNG is STRUCK BY IMPLEMENTATION ARITHMETIC

> **The rung comes off the ladder without the bucket ever being classified. That sentence is
> not a contradiction and the map should not tidy it into one.**

The strike does **not** come from the −7.55 %. It comes from a static count taken on the shipped
lean ELF afterwards, which prices the *best case for a body that meets the experiment's own
gate*. The gate was written before the flash, with reverting mandatory if it could not be met:
**(a)** zero fetch-accessor calls reachable from the served body; **(b)** the served body's
instruction count **less than** the generated handler path it replaces; **(c)** sp-relative
accesses counted and stated.

**(b) failed by 2.2 – 3.1×**, counted per shape through the inlined body against the run loop's
dispatch triple plus the generated handler plus the result move:

| shape | served `SPEC` body | generated-handler path replaced | ratio |
|---|---|---|---|
| `MOVE.L Dn,Dn` (`op_2000`) | **65** | 4 dispatch + 15 handler + 2 join = **21** | **3.1×** |
| `MOVE.L d16(An),Dn` (`op_2028`) | **85** | 4 + 24 + **9 window** + 2 = **39** | **2.2×** |
| `MOVEA.L d16(An),An` (`op_2068`) | **77** | 4 + 19 + **9 window** + 2 = **34** | **2.3×** |
| `MOVE.L (An)+,(An)+` (`op_20d8`) | **118** | 4 + 37 + 2 = **43** | **2.7×** |

On a dispatch of ~180 ARM instructions that is **+24 % to +40 % of the whole served dispatch**,
which is exactly where the measured +33 % comes from. **(a) failed 2, not 0** —
`z3660_spec_iword()` takes its offset as a *runtime* value, so the `have_ext0` test cannot fold
and both arms survive into the binary. **(c) is stated**: of 108 sp-relative accesses in the
879-instruction loop, **65 were already there**; the body's own contribution is **+43**.

**Why, in one line: `gencpu`'s per-opcode handlers ARE the specialisation, and a body that takes
the opcode word at *runtime* is a DE-specialisation.** `op_2000_31_ff` is **15 instructions of
straight-line code with no call frame at all** — gcc made it a leaf ending in `bx lr`, so
§30.3's largest priced removal, the handler's `push`/`pop`, is worth **exactly zero on the
commonest shape**. The inlined body spends **27 instructions on its prologue alone** — five field
extractions, a size ladder, the `srcmem`/`dstmem` tests, the length computation — before it
touches a byte of guest state, and then walks a six-way source ladder and a six-way destination
ladder that `gencpu` resolved at compile time.

**And a gate-compliant body's own arithmetic still loses.** Getting under the generated handler
requires compile-time per-shape bodies — 36 of them — and selecting among 36 inlined bodies is a
jump table, i.e. an indirect branch with 36 targets on a Cortex-A9 BTB that holds one target per
site. **That is §30.3's site A**: removing the handler's indirect call by adding your own nets
zero. Counted from this binary, what is left to remove is:

```
   handler call frame           0 on op_2000 (a LEAF), 2 elsewhere
   the loop's dispatch triple   3   -- but the jump table needs ~3 of its own
   site B, field re-extraction  2-3
   site C, the window hit       9   -- on the ~45 % of served shapes with a displacement

   weighted  0.45x(9+2+3) + 0.55x(0+3)  =  ~8 removed, ~3 added back  =  ~5 net
   on a dispatch of ~180 instructions                     ->  R ~= 2.8 %   (was 7-11 %)
   x 21.12 % MEASURED coverage, constant IPC              ->  +0.59 %
   pre-registered PAY floor                                   +0.90 %
   the machinery's own MEASURED cost                          -1.07 %
   ---------------------------------------------------------------------
   best case for a gate-compliant body                    ->  about -0.5 %
```

**+0.59 % is below the +0.90 % PAY floor before the −1.07 % is charged**, and the −1.07 % is not
a projection — it is this session's measured disarm row, a property of inlining *anything* into
this run loop (register pressure → a spilled meta byte → three instructions to get it back).
Note also that **the count model has just been demonstrated optimistic by 3–4× in the other
direction**, and that 36 inlined bodies would raise the very pressure that produced the −1.07 %.

**So: ladder #1 is STRUCK — by implementation arithmetic, not by a classification.** The bucket
is still 19.28 – 20.13 % of the corrected profile (§39.1) and still unclassified. What has been
retired is the *technique*: **do not fund a handler-specialisation rung that inlines bodies into
`m68k_run_mmu040()`**, on this compiler, with this entry geometry. That is a narrower strike than
"`HANDLER` is hopeless", and the narrowness is the point.

### 36.4 What a future attempt would have to bring

Recorded so it is not re-derived, and it is **not** a recommendation. A classification attempt
needs a body that **provably removes work**, and this round collected three compiler strikes
saying the generated handlers are better than they look: gcc left the accessors out of line
(site D), it did not fold the extension-word test (site C), and it had already turned the
commonest handler into a frameless 15-instruction leaf (site A, worth zero there).

A body that could meet gate (b) needs **compile-time per-shape bodies *and* a dispatch that is
not an indirect branch** — which on this loop means the pre-decoded EA in the entry plus a
threaded dispatch. **That is the design this experiment existed to decide whether to fund, so it
cannot be the discriminator for it.** And the entry cannot simply be widened to help: the
decoded-op set is *exactly* 64 bytes behind a compile-time tripwire, because one set is one pair
of Cortex-A9 cache lines and that is the property the hit path is built around — a second
extension word costs 8 bytes and 4 are spare.

**The cheap classification of `HANDLER` is not available.** That is the finding.

---

## 37. Two more things the instrument cannot do

§31's three caveats stand unchanged. Two are added. The first is a mistake this campaign made
and must not repeat; the second is a **tool**, and it retires an inspection §31.3 could only do
by eye.

### 37.1 A pre-registered counter direction must be checked against the counter's position in the call topology

The discriminator declared, twice and emphatically, that `FETCH` / `IFETCH_CALLS` **would fall**
by the number of served `d16(An)` instructions — listed as *declared* behaviour, "the one place
this rung is deliberately not like-for-like". It was scored a **MISS**: `FETCH` per guest
instruction **rose**, 0.5109 → 0.5233, **+2.44 %**.

**The declaration was arithmetically impossible when it was written.** Site C removes a *window
hit*, and `uae_mmu040_get_iword()` answers a window hit **above** the `FETCH` counter:

```c
if (addr == (uaecptr)z3660_dopc_ext_pc) {
        Z3660_PROF_CNT(Z3660_PROF_C_DOPC_EXT);      /* counted here ... */
        return (uae_u16)z3660_dopc_ext_val;
}
Z3660_PROF_ENTER_IFETCH();                          /* ... never reaching FETCH */
Z3660_PROF_CNT(Z3660_PROF_C_FETCH);
```

A served window hit **never incremented `FETCH` in either arm**, so removing the call could only
ever move `DOPC_EXT` — and `DOPC_EXT` was deliberately re-counted inside the body to keep it
comparable, which is why it reads **0.3385 vs 0.3391, unchanged, exactly as designed.** The
declaration confused *"the accessor is not called"* with *"the fetch is not paid"*; the decoded-op
cache had already stopped paying it.

**What actually moved `FETCH` reconciles the two findings into one.** The armed arm takes
**3.2 % more decoded-op misses per dispatch** (0.15439 vs 0.14963 — the −0.47 pp of check 4a,
which passed at the very edge of its ±0.5 pp band), and a miss costs two real instruction fetches
a hit does not: the loop's own `x_prefetch(0)` and the extension lookahead.
`+0.00476 × 2 = +0.0095` fetches per guest instruction against a measured **+0.0124** — right
size, right sign — and it carries `IPAGE` (check 4d, 88.51 % vs 88.66 %, −0.150 pp against a
±0.1 pp band) with it for the same reason.

> **The caveat, for §31: before a pre-registration declares which way a counter will move, trace
> where that counter sits in the call topology relative to the code being removed.** A counter
> that is only reached *after* the branch you are deleting cannot fall when you delete it. Checks
> 4c and 4d are **one finding and it is a bookkeeping error in the design document, not a defect
> in the build** — but it was scored as two misses against the firmware, and that is the cost of
> not doing this check.

### 37.2 Which shares are real and which are price artefacts — the probe-density test

§31.3 retired *"the in-bucket end is always impossible"* and showed `TAILADV`'s share to be a
price artefact, but it could only demonstrate that by watching one bucket collapse between two
bands. **The whole vector is recoverable, exactly, from any two price columns of one capture**,
and it needs no new instrument.

The correction is linear: `corrected(p) = acc − spans × p`. Two columns therefore give the
bucket's **spans per guest instruction** and its own **zero-crossing price** `p0 = acc/spans` —
the price at which the bucket is entirely probe. **The firmware's ceiling line already prints the
minimum of that vector** (§31.3: `min_b(acc/spans)`); this just reads the rest of it. At price
`p`, `p/p0` is the fraction of the bucket's raw accumulator that is **bracket cost**.

Arm B2 (`SPEC` OFF, the reference posture), band `[54, 60]`, ceiling **60 bound by `TAILADV`**:

| bucket | spans/INSN | zero-crossing `p0` | bracket cost at the ceiling price 60 | reading |
|---|---|---|---|---|
| `TAILADV` | 3.007 | **60.4** | **99 %** | binds the ceiling — essentially all probe (§31.3, confirmed) |
| `LOOPRES` | 3.872 | 68.7 | **87 %** | **mostly probe** — 15 % above the ceiling |
| `BLKREC` | 0.325 | 70.7 | 85 % | mostly probe |
| *`TAILSAMP` (instrument)* | 1.000 | 76.4 | 79 % | — |
| `TAILPOLL` | 1.000 | 93.0 | 65 % | real, and banked at cadence 4 |
| `HANDLER` | **1.902** | 102.4 | 59 % | real |
| `DOPCFIND` | **1.000** | 130.8 | 46 % | real |
| `DOPCFILL` | **0.2167** | 136.3 | 44 % | real |
| `FETCHOP` | 0.220 | 149.8 | 40 % | real *(plus §31.1's unsubtracted counter calls)* |
| `READ` | 0.450 | 151.2 | 40 % | real |
| `WRITE` | 0.320 | 159.3 | 38 % | real |
| `FETCHEX` | 0.472 | 173.9 | 35 % | real *(plus §31.1)* |
| **`XLATE` + `WALK`** | **0.0217** | **623** | **10 %** | **the least probe-contaminated bucket on the page** |

**Four independent validations, none of them circular:**

| check | derived here | independently known | agreement |
|---|---|---|---|
| `TAILADV` zero-crossing | **60.4** | the firmware printed **ceiling 60, bound by `TAILADV`** | the line reproduces |
| `HANDLER` spans/INSN | **1.902** | `handler-discriminator.md`: **1.906** | 0.2 % |
| `DOPCFILL` spans/INSN | **0.2167** | fills per guest instruction **0.2178** | 0.5 % |
| `DOPCFIND` spans/INSN | **1.000** | `profiler.md`: `tcnt[DOPCFIND] == DOPC_HIT + DOPC_MISS`, one lookup per dispatch | exact |

**Three consequences, and all three are load-bearing below.**

* **`LOOPRES` is 87 % bracket cost at the ceiling price.** §33.3 withheld its reclaim because the
  bucket is unenumerated; it is now withheld for a **second, independent** reason. Its share is
  also the most band-sensitive on the page — 11.92 % at 54 against 8.40 % at 60 — so *"the
  largest thing in the dispatch loop"* is a statement about a price band, and §33.1's
  18.52 – 15.37 % at `[39, 50]` is the same bucket read at a cheaper one.
* **`XLATE` + `WALK` is 10 % bracket cost.** §33.2 already classified it *dependency-chained by
  construction — the cleanest case on the page*; it is now also the share on this page closest to
  a wall-clock share. **The ATC rung is the best-conditioned row on the ladder**, and that is new.
* **What the test does NOT measure.** It separates the bucket from its own **bracket pair**,
  which is the only thing the correction subtracts. §31.1's *counter* calls — three per fetch,
  landing inside `FETCHOP`/`FETCHEX` — are **not** subtracted by anything and are not visible
  here. **Row H's ~3× inflation is untouched by this table**, and §34.4 still governs its size.

---

## 38. THE PHYSICAL-INDEX RE-SCORE — §22.3's input was refuted, and §24.4 is re-run against the measurement

§33.4 closed by saying one input the design needs is stale and must be **re-measured at one
band before scoring a design against it**. It was, while the rig was up. This section is the
re-scoring, on **one capture at one band**, with the band quoted beside every price.

### 38.1 The measured fill-path price — the stale input is refuted UPWARD

```
DOPCFILL corrected cyc/miss = (acc[15] - spans[15] x price) / DOPC_MISS

  reference posture (SPEC OFF, prof 8B5DC5C3)   75.9 .. 81.9 cyc/miss
                                                at calibration band [54, 60] cyc/transition
  armed arm     (SPEC ON)                       84.0 .. 90.0 cyc/miss, same band
  the input §22.3 supplied and §24.4 scored     62 .. 64 cyc/miss   (pinned 57, s19, cadence 1)
```

**Even 75.9 — the cheapest end, taken at the ceiling price, the most aggressive correction this
capture permits — sits above the expensive end of 62–64.** The fill path is **19 – 32 % dearer**
than the design has been sized against. Fills run **0.218 per guest instruction** and are
**4.13 %** of the corrected profile at price 60.

**The band is part of the number.** This capture's printed ceiling is **60, bound by `TAILADV`**,
and the firmware itself **refuses the boot line's in-bucket end of 66 as arithmetically
impossible here** — §31.3's line working in the arm §31.3 predicted it could work in. Quoting a
price outside `[54, 60]` off this capture would be quoting a price it did not measure.

**Provenance, so it is not carried further than it was earned**: measured on the `SPEC` **prof**
build `8B5DC5C3` with the switch **disarmed** — with `SPEC` off, `z3660_dopc_fill()` does not set
the `M_SPEC` bit, so the fill path is the pre-rung fill path **plus one not-taken branch**. It is
**not** measured on `DEC21748` itself. The armed arm's 84.0 – 90.0 is one more place that arm
paid rather than saved, and is not the number to carry.

### 38.2 The prize side — each removed miss is worth 6 – 15 % more than §24.4 assumed

§24.4's saving per removed miss is the fill **plus** the opcode fetch a miss forces and a hit
does not: `DOPCFILL` cyc/miss + `FETCHOP` cyc/miss. Re-derived **identically**, on this session's
own arm B2 at its own band (`INSNS` 71 590 065, `DOPC_MISS` 15 593 227 ⇒ **0.21781 misses per
guest instruction**):

| | @54 | @60 | §24.4 (pinned 57) |
|---|---|---|---|
| `DOPCFILL` per miss | 81.9 | 75.9 | 61.8 – 63.9 |
| `FETCHOP` per miss | 96.8 | 90.7 | **93.0** |
| **saving per removed miss `S`** | **178.7** | **166.6** | **154.8 – 156.9** |

> **`S` = 166.6 – 178.7 cycles at band `[54, 60]`, against 154.8 – 156.9 at pinned 57 — richer by
> +6.2 % to +15.4 %.**

**The fetch half reproduces and the fill half is what moved.** `FETCHOP` per miss comes in at
90.7 – 96.8 on this capture's band, **bracketing §24.4's 93.0** derived on a different session at
a different price — so the quantity is stable and the re-derivation is doing the same arithmetic
§24.4 did. §24.4's assumption that a decoded-op hit pays **no** opcode fetch, so that all of
`FETCHOP` is chargeable to misses, is **inherited unchanged and remains untested**; if it is
wrong, both the old figure and the new one shrink together and the *comparison* survives.

**Pricing-law status, unchanged from §33.2 and still favourable**: the prize is *whole misses,
not scaffolding* — and a miss's fetch is **the one fetch the decoded-op cache is not hiding**, so
it is not latency-hidden and prices at full value. **State the strength honestly**: that is an
inference *from* rung 3's measurement (the cache hides the served fetch, therefore not the missed
one), not a direct measurement of the miss path. §34.2 applies — the law's own consequence is that
a classification is bought, not reasoned, and this one has not been bought. It is the one place
§38.6's experiment also happens to settle the question, because a wall-clock response to removing
misses **is** the measurement.

### 38.3 The bar side — the translation, and the break-even budget it has

§17.3's bar and §30's law together: *a physical index costs a translation on the fill path*, and
**a translation prepended to a fill is a dependency in front of the fill, so it arrives in full.**
There is no stall-recovery discount on the cost side. Two things follow, and only the second
decides anything.

**The fractional framing — the same translation is a smaller burden on a dearer fill.** §24.4's
worked example charged **15 cycles**:

| a 15-cycle translation, as a fraction of the fill it precedes | |
|---|---|
| against §22.3's **62 – 64** cyc/miss | **23.4 – 24.2 %** |
| against the measured **75.9 – 81.9** cyc/miss at `[54, 60]` | **18.3 – 19.8 %** |

**That is a plausibility check, not a wall-clock number.** §30's law is about absolute cycles: the
15 arrive whole either way, and the fill getting dearer does not make them cheaper. What the
fractional view is good for is judging whether a proposed cost site is *credible* — and a site
that adds a fifth of a fill to every fill is a very different proposition from one that adds a
quarter.

**The decisive framing — the break-even budget, which needs no denominator at all.** The design
pays `T` on every fill that **survives** and collects `S` on every fill it **removes**. With `f`
the fraction of misses removed, net is `M[f·S − (1−f)T]`, so break-even is:

```
   T* = f/(1-f) x S
```

**This is the most robust number in the whole re-score**: it is independent of the profile total,
of the window's miss rate, and of every instrument correction except the two per-miss prices.

| removal fraction `f` | **`T*` at `S` = 166.6 – 178.7** (`[54, 60]`) | `T*` under §24.4's stale `S` |
|---|---|---|
| **0.5096** — §24.4's headline (`IV_FLUSH`'s share of invalidation traffic) | **173 – 186 cyc** | 161 – 163 cyc |
| **0.40** — §24.4's conservative row | **111 – 119 cyc** | 103 – 105 cyc |
| **0.357** — the calibrated figure (§38.4) | **93 – 99 cyc** | 86 – 87 cyc |

> **The cost side is not where this design fails.** At the headline `f` the break-even
> translation budget is **more than twice the entire fill it would be prepended to** (173–186
> against a 75.9–81.9 cyc fill). Even at the calibrated `f` it is **93–99 cycles, still above the
> whole fill**. §22.3 called the margin *"thin"* and §17.3 named the cost site as the thing that
> killed rung 1b twice — **on the measured price, the cost site has an order of magnitude more
> headroom than a 15-cycle translation needs.** What is thin is `f`.

**And there is a design reason to expect `T` at the low end, which the design round must confirm
rather than assume**: on the fill path the machine has **already translated the fetch PC** — it
just fetched the opcode through it. If the physical address can be threaded out of the fetch that
already happened, the cost site pays **only on a miss that was going to walk anyway**, which is
verbatim §17.3's "starts above the bar" clause. *This is an observation about where to look, not
a measurement, and §33.4's pre-registration item 2 still binds.*

### 38.4 The removal fraction — §24.4's own calibration point says 0.70, not 1.0

**This is the correction that moves the answer, and it comes from §24.4's own evidence.** §24.4
assumed that removing `IV_FLUSH`-driven invalidations removes the same **fraction of misses**:
50.96 % of invalidation traffic ⇒ 50.96 % of misses. It justified the proportionality by pointing
at a measured response — and that response does not have slope 1:

```
rung 1c removed 49.68 % of dhrystone's invalidation requests at a call site
        and moved the hit rate 77.48 % -> 85.32 %   (§24.4's own numbers)

   miss rate     22.52 %  ->  14.68 %      =  misses fell 34.81 %
   invalidations                              fell 49.68 %
   ---------------------------------------------------------------
   response      34.81 / 49.68           =  0.70 misses removed per invalidation removed
```

Applying that response to `IV_FLUSH`'s 50.96 % gives **`f` = 0.357**, not 0.5096 — which lands
almost exactly on §24.4's own *conservative* row. **§24.4's headline row silently used slope 1.0
while its justification measured 0.70.**

**Three reasons 0.70 is if anything still generous**, all of them unmeasured and all of them
belonging in the design's pre-registration:

1. Rung 1c removed invalidation **requests**; a physical index does not remove the request, it
   **narrows** it — the flushed line's entries still go. A by-address invalidation legitimately
   evicts whatever actually matches.
2. `IV_FLUSH`'s locality need not resemble `IV_CACR_SKIP`'s. One calibration point is one point.
3. This session's own hit rate (**85.04 %** disarmed) is level with rung 1c's post-fix 85.32 %, so
   the interpolation is being extended from the same place it was calibrated, not from a nearer
   one.

### 38.5 The re-derived ceiling

Two bases are quoted because this boot supplies two miss rates and they differ by 46 %:
arm B2's bucket capture reads **0.21781 misses/INSN** while the same boot's un-bucketed counter
arm B reads **0.14963** — consistent with time-driven invalidation sources (context-switch
`PFLUSHA` is 36.73 % of the traffic) holding steady while the probed guest executes fewer
instructions per second. **The prize is proportional to the miss rate, so this confound is the
single largest lever on the answer and both ends are shown.** Cost charged at §24.4's 15-cycle
translation on surviving fills.

| basis | `f` | gross | − translation | **net, share of the corrected profile** |
|---|---|---|---|---|
| B2's own miss rate 0.2178 | 0.5096 (naive) | 4.16 – 4.62 % | 0.34 – 0.40 % | 3.82 – 4.22 % |
| B2's own miss rate 0.2178 | **0.357 (calibrated)** | 2.91 – 3.24 % | 0.44 – 0.52 % | **2.47 – 2.71 %** |
| counter arm's 0.1496 | 0.5096 (naive) | 2.93 – 3.27 % | 0.24 – 0.28 % | 2.69 – 2.99 % |
| counter arm's 0.1496 | **0.357 (calibrated)** | 2.05 – 2.29 % | 0.31 – 0.37 % | **1.74 – 1.92 %** |

> ### **THE RE-DERIVED CEILING: 1.7 – 2.7 % of runtime, ≈ dhry 8330 – 8415 against the standing 8185.** Gross, before the translation, 2.05 – 3.24 %.

**§24.4's figure was ~2.2 % realistic and §33.3 carried ≈ 8370. The re-score brackets it.**
That is the headline, and the reason is that **two refutations of opposite sign very nearly
cancel**:

```
  the fill path is 19-32 % dearer  ->  S rises  +6.2 .. +15.4 %      the prize is RICHER
  the response slope is 0.70 not 1 ->  f falls  0.5096 -> 0.357      the prize is NARROWER
  the standing posture is cadence 4, not the cadence 1 §24.4 scored on
                                   ->  the same prize is a larger share of a machine that
                                       no longer spends ~18 % of itself polling (§22.5)
  ------------------------------------------------------------------------------------------
  net effect on the ladder position:  none.  The study stays exactly where §33.3 put it.
```

**Three things this re-score does not fix**, each named where it bites: the **miss-rate confound**
above (±30 % on the answer, and it is not a measurement error — it is two honest windows of one
boot); the fetch half of `S` sitting inside **row H**, which §31.1 puts at ~3× instrument-inflated
and §34.4 refuses to size (this deflates the *absolute* ceiling on both the old figure and the
new one equally, so the comparison survives and the level does not); and the fact that every
figure here is a share of the **distorted** machine (§10.1) whose corrected profile runs
400–477 cyc/INSN against a lean 71.8.

### 38.6 THE FUNDING RECOMMENDATION

> ## **ADJUST.** The study stays live and is now the leading classified rung on the ladder. **Do not fund the design round yet.** Fund the one-switch measurement of `f` first — it is cheaper than the round just spent, it has no implementation in it to confound the reading, and it is the only input that decides the study.

**Why not STRIKE.** Nothing about it got worse. The prize per removed miss is measured **richer**;
the pricing law classifies the prize favourably, by inference from a measurement (§38.2); and the
cost site — the thing §17.3 named as the killer and §22.3 called thin — turns out to have **more
than the whole fill's own price as break-even headroom**. At 1.7 – 2.7 % it is larger than the ATC rung and
overlaps `DOPCFIND`'s entire range. It is the only fetch-side prize §30 does not strike.

**Why not FUND the design round.** The entire remaining risk is concentrated in **one unmeasured
number**, `f`, and §38.4 has just shown that number was carried at 1.0 when its own calibration
said 0.70. **That is the same shape of error the `HANDLER` round just paid a full metal session
for**: a design funded on an unmeasured premise (*"the body removes work"*) that returned an
implementation instead of an answer. §30.3's rule — *buy the classification before funding the
rung* — generalises to: **buy the prize's size before funding the design.**

**What to fund instead, and it is a removal, which is the one thing this campaign has learned to
price correctly.** `f` can be measured to a **strict upper bound without building a physical index
at all**: a console switch that makes `IV_FLUSH` (`CPUSHL`/`CINV`) **not invalidate the decoded-op
cache**. A perfect physical index invalidates only the entries whose physical address matches; a
no-op invalidates none; the matching set is a subset, so **no-op ≥ physical index in hit rate, by
construction**. One boot reads:

1. the **hit-rate response** to removing `IV_FLUSH`'s invalidations — `f`'s upper bound, directly,
   with no interpolation from rung 1c and no slope assumption;
2. the **wall-clock response**, on a lean A/B — which folds `S`, the miss rate, the fill price and
   the fetch price into **one number that needs no band, no denominator and no instrument**, and
   so is immune to every caveat in §38.5;
3. the **cost side charged at zero**, by construction — so the reading is the study's true ceiling.

It is §30.3's four steps unchanged: name the latency (a miss's own fetch — already named and
already classified), one console switch, both arms in one boot, plus a cross-build reference row
with the outgoing lean image archived first. **`DEC21748` is archived and CRC-verified on the card
and byte-identical in the repo (§35.2), so step 4's precondition is already met** — the trap that
cost r3 its reference arm cannot fire.

**The one gate this experiment needs that the others did not**: skipping a required invalidation is
**deliberately unsound**, so it is a measurement-only build that must never ship, and the arm must
be **correctness-gated** — dhrystone's own printed result values compared between arms, and the
boot-message scan run as usual. If the guest misbehaves, that is itself informative (it bounds how
much of `IV_FLUSH` is genuinely load-bearing) and it is why this is a switch on a prof/lean pair,
not a design.

**If that measurement comes back at `f` ≥ 0.35 with a wall-clock response at or above ~1.5 %, fund
the design round**, with §33.4's pre-registration list re-ordered against the new numbers:

1. **`f`, measured — no longer item 3.** *(discharged by the experiment above, or the design does
   not proceed.)*
2. **The cost site**, as §17.3 and §33.4 already require: it must pay **only on a miss that was
   going to walk anyway**. §38.3's observation — that the fill has already translated the PC to
   fetch the opcode — is where to look first, and it must be *shown in the disassembly*, not
   argued. **A design that adds work to every fill starts below the bar** and now has a number to
   beat: `T*` = 93 – 99 cycles at the calibrated `f`, at band `[54, 60]`.
3. **Which of its removed costs are latency-hidden and which are dependency-chained** (§30.3),
   named per cost site, before any count becomes a wall-clock number. The prize side is already
   classified *not hidden*; the cost side is already classified *arrives in full*. Both are done —
   restate them, do not re-derive them.
4. **A lean A/B plus a cross-build reference row**, outgoing lean image archived first.

---

## 39. THE MAP v3.3 — the ladder after `HANDLER`

### 39.1 The shares

Arm **B2** (`SPEC` OFF on the `SPEC` prof build) — the closest capture to the standing
`DEC21748` posture this session took, differing from it by **one not-taken branch on the fill
path and the +5 disarmed-hot-path instructions** that cost the measured −1.07 %. Cadence 4,
swept this capture's own band `[54, 60]`, ceiling **60 bound by `TAILADV`**, `TAILSAMP` excluded
from the denominator (corrected total 477.05 @54 / 400.17 @60 cyc/INSN).

**§31.2 forbids comparing these against §33.1's `[39, 50]` columns or §28.2's `[54, 59]` columns
without saying so** — where a row below moves against §33.1, the band is the first thing to
suspect, and §37.2 now says which rows are band-sensitive and why.

| bucket / group | corrected share (c4, `[54, 60]`) | §37.2: bracket cost at 60 |
|---|---|---|
| **`LOOP` whole** | **32.89 – 31.09 %** | 72 % |
| ‑ **`DOPCFIND`** | **16.09 – 17.68 %** | 46 % |
| ‑ `LOOPRES` — the true residue | **11.92 – 8.40 %** | **87 %** |
| ‑ `DOPCFILL` | 3.74 – 4.13 % | 44 % |
| ‑ `BLKREC` | 1.14 – 0.87 % | 85 % |
| **`HANDLER`** | **19.28 – 20.13 %** | 59 % |
| **`FETCHOP` + `FETCHEX`** (row H) | **16.27 – 18.36 %** | 35–40 % *+ §31.1's unsubtracted counter calls* |
| **`READ` + `WRITE`** | **16.24 – 18.20 %** | 39 % |
| **`TAILPOLL`** | 8.16 – 8.23 % | 65 % |
| **`TAILADV`** | *4.00 – 0.26 % — price artefact, §31.3* | **99 %** |
| **`XLATE` + `WALK`** | **2.58 – 3.05 %** | **10 %** |
| `TAILSPEC` | 0.40 – 0.46 % | 18 % |
| `FAULT` (uncorrected) | 0.17 – 0.21 % | — |
| *`TAILSAMP` (instrument, excluded)* | *4.69 – 4.09 %* | 79 % |

§10.1 applies unchanged: these are shares of the **distorted** machine, whose corrected profile
runs 400–477 cyc/INSN against a lean **71.8** (§36.1). The right-hand column is new and says how
much of each bucket is the profiler's own bracket pair — **not** how much is instrument in total.

### 39.2 The ladder

Amdahl against the standing **8185**. Shares are B2's at `[54, 60]`; **the reclaim column is
still not measured** and §10.6 governs it exactly as before. §33.2's pricing-law column is
carried in one word, with the two rows that changed marked.

| # | rung | buckets | **share (c4, `[54, 60]`)** | pricing law | reclaim (**est.**) | time won | **dhry @8185** |
|---|---|---|---|---|---|---|---|
| **1** | **physical-index dopc** — whole misses, not scaffolding | `DOPCFILL` + `FETCHOP`, *miss path* | prize = 2.05 – 3.24 % of profile gross | **not hidden (measured); its own cost arrives in full** | §38.5 | **1.74 – 2.71 %** | **8330 – 8415** |
| **2** | **ATC fast path** | `XLATE` + `WALK` | **2.58 – 3.05 %** | **chained by construction — and only 10 % bracket cost (§37.2)** | 60 % | 1.55 – 1.83 % | **8314 – 8338** |
| **3** | `DOPCFIND` — the hit-path walk | `DOPCFIND` | **16.09 – 17.68 %** | chained, but nearly empty | 5 – 15 % | 0.80 – 2.65 % | **8251 – 8408** |
| **3b** | *`DOPCFIND` — the unexplained ≈ 9 cyc/dispatch* | `DOPCFIND` | — | **unknown — an investigation, not a rung** | — | — | *see §39.3* |
| **4** | `LOOPRES` — the true dispatch residue | `LOOPRES` | **11.92 – 8.40 %** | **unclassifiable** | **withheld — now for two reasons** | — | — |
| — | *handler specialisation* | *`HANDLER`, 19.28 – 20.13 %* | — | ***bucket UNCLASSIFIED*** | — | — | ***RUNG STRUCK — §36.3, implementation arithmetic*** |
| — | *accessor fast path* | *`READ` + `WRITE`, 16.24 – 18.20 %* | — | chained | — | — | ***BUILT — rung 2, +25.17 %*** |
| — | *instruction-fetch fast path (served)* | *row H* | — | **hidden** | — | — | ***BUILT AND REVERTED — rung 3, −0.05 %*** |
| — | *interrupt-poll cadence* | *`TAILPOLL`* | — | — | — | — | ***banked*** |
| — | *tail residue* | *`TAILADV`* | *price artefact, 99 % bracket* | — | — | — | ***RETIRED*** |
| **J** | the residual only a JIT reaches | `LOOP` + `FETCH*` + `TAILADV` + `TAILPOLL` + `TAILSPEC` | **61.7 – 58.4 %** | **partly hidden** | 90 % coverage | — | *≈ 2.11 – 2.25× at this band — an upper bound, and §33.3's instruction not to quote a dhrystone figure for it stands* |

**Four notes the table cannot carry.**

* **#1 leads by ceiling; #2 is the better-conditioned bet, and they overlap.** The physical index
  has the larger prize and one unmeasured input carrying all of its risk. The ATC rung is smaller,
  is the **only** row whose classification is already bought *and* whose share is nearly probe-free
  (§37.2), and needs no measurement before it can be designed. **If one round is funded, the
  cheapest honest pairing is §38.6's `f` measurement and the ATC rung** — neither is a design round
  and between them they either promote #1 or convert #2 into a built rung.
* **#3's rank is unchanged and its bucket is still the wrong thing to look at.** The way walk is
  worth 0.8 – 2.7 %; the anomaly sitting beside it (§39.3) is worth more and is not a rung.
* **#4 is withheld twice over.** Unenumerated contents (v3, v3.1, v3.2) **and** 87 % bracket cost at
  the ceiling price (§37.2). Its apparent shrinkage against §33.1's 18.52 – 15.37 % is the band, not
  the machine.
* **Row J fell and nothing about it changed.** 2.11 – 2.25× here against §33.3's 2.4 – 2.55× — same
  machine, different band, and `TAILADV` inside it collapses from 4.00 % to 0.26 % between this
  capture's own two prices. Read it as §33.3 says to read it.

### 39.3 `DOPCFIND`'s ≈ 9 cyc/dispatch — a fourth point, and it is the first one that is in-band

§32.2 left F6 OPEN with both candidates weakened. This session adds a point, and unlike r3's it
is taken at a price **inside its own capture's usable band** — 57 lies within `[54, 60]`, whereas
r3's `[39, 50]` did not contain it, which is what §32.2's asterisk was about:

```
   s19 (pre-rung-2, no tables)      60.83   in-band ([57, 68])
   r2  (rung 2,     2 KB)           70.26   in-band ([54, 66])      <- the +15.5 %
   r3  (rung 2+3,   3 KB)           70.53   OUT of band ([39, 50])  -- §32.2's asterisk
   this session (rung 2 + SPEC disarmed)     73.75   in-band ([54, 60])
```

**It is not a clean fourth point and must not be quoted as one.** This build carries the `SPEC`
machinery **disarmed**, which is measured to cost −1.07 % of wall clock through +5 instructions on
the hot path, and whether any of those sit inside the `DOPCFIND` bracket is a disassembly question
nobody has asked. The +4.6 % over r3 is therefore **plausibly the disarm cost itself**.

> **What is owed, and it is cheap.** The reverted tree's prof image is the first clean build since
> s19 — no third table, no `SPEC`. **The next prof capture on it takes the honest fourth point**,
> in-band, and F6 finally gets a controlled series. Until then §34.3 stands unchanged: ≈ 9
> cyc/dispatch is a reason to investigate and **must not be quoted as a projected gain.**

### 39.4 The strategic picture, stated plainly

This is the section the campaign has been earning the right to write since v3, and v3.3 is the
first version that can write it without an unclassified bucket at the top of the ladder pretending
to be a prize.

**Everything left on the interpreter ladder that is both classified and attackable sums to single
digits.** Taking #1, #2 and #3 at their pessimistic and optimistic ends and compounding them:

```
   physical-index dopc   1.74 .. 2.71 %       (§38, and its f is not yet measured)
   ATC fast path         1.55 .. 1.83 %       (est. reclaim, share is solid)
   DOPCFIND way walk     0.80 .. 2.65 %       (est. reclaim, bucket is real)
   ------------------------------------------------------------------------
   compounded            +4.2 % .. +7.6 %  ->  dhry 8530 .. 8805
```

Plus F6's unquantified ≈ 9 cyc/dispatch, which is the softest number on the page and could be
anything. **`LOOPRES` is withheld, `HANDLER`'s rung is struck, `TAILADV` is retired, `TAILPOLL` is
banked, and both fast-path rungs are built.** There is no hidden row: v3.1 opened the loop, v3.2
priced the two rungs that emptied the fetch side, and v3.3 has just taken the last unclassified
large bucket off the board as a *rung* without ever classifying it as a *bucket*.

**Row J is the only remaining step change, and it is a different kind of number.** At this band it
is an upper bound of **2.11 – 2.25×** — call it **+110 % to +125 %** — against **+4 % to +8 %** for
everything else combined. That is not a better rung; it is a different machine. It is also soft in
two named directions (§33.3: `TAILADV`'s price band inflates it, and the fetch pair inside it is
measured partly latency-hidden), and §31.1 says the profile is least fair to exactly that pair.

> **The map's recommendation stops here.** Whether to fund a JIT is a decision about how much
> engineering this lane is worth, not a decision the measurements can make — the campaign's whole
> lesson (§30, §34.2, §36) is that a design's sign cannot be read off a bucket's size, and row J is
> the largest bucket on the page with the least-measured mechanism behind it. **v3.3 records it as
> the remaining step change, prices it as an upper bound, and leaves the funding call to the
> reader.** What the map *does* recommend is §38.6: one switch, one boot, and a number that decides
> the last interpreter rung worth arguing about.

---

## 40. What v3.3 does **not** establish

§10, §18, §26 and §34 apply unchanged and are not repeated. Five things are new, and §40.6
appends the ledger.

### 40.1 The `HANDLER` bucket is unclassified and this is the second version to say so

19.28 – 20.13 % of the corrected profile has now cost two map versions and one full metal session
and remains uncharacterised. §36.3 strikes a **technique**, not the bucket. **Nobody should read
"ladder #1 struck" as "`HANDLER` is empty"** — what is established is that inlining bodies into
`m68k_run_mmu040()` on this compiler cannot beat `gencpu`'s output, and the arithmetic that says
so is a static count, not a measurement of the bucket's recoverable content.

### 40.2 The re-score's largest lever is a confound, not a measurement error

§38.5's two bases differ by 46 % in miss rate and the prize is proportional to it. The explanation
offered — time-driven invalidation sources holding steady while the probed guest runs slower — is
**mechanism-shaped and unmeasured**. The honest statement is that the ceiling is 1.7 – 2.7 % and
that the width of that range is dominated by which of one boot's two windows is believed, not by
the price band.

### 40.3 `f` is still an interpolation, and the correction to it is one calibration point

§38.4's 0.70 slope is derived from **rung 1c and nothing else**, and applied to a different
invalidation cause by a different mechanism (narrowing, not removal). It is a better reading of
§24.4's own evidence than §24.4 made — it is not a measurement of `IV_FLUSH`'s response. §38.6
exists to convert it into one.

### 40.4 The probe-density test measures brackets, not instrument

§37.2 recovers the bracket-pair cost exactly, because that is precisely what the correction
subtracts. It says **nothing** about §31.1's three per-fetch counter calls, which land inside row H
and are subtracted by nothing. A bucket reading "40 % bracket cost" is not thereby "60 % real
work". §34.4 stands.

### 40.5 What is owed to the Z3660 lane

Of §34.5's five items, **three are discharged**:

* **`docs/profiler.md`'s `tcnt[DOPCFILL] == DOPC_MISS` identity** now carries its fault term and
  the shortfall prints as a **bounded `[PROF] l note:`** rather than a warning (`Z3660 6afc8f9`;
  the prof image built after it reads `2841AD27`). The 0.0087 % gap this session logged twice
  (1350 in 15.6 M) is inside the bound and is no longer a thing to chase.
* **`tcnt[BLKREC] <= tcnt[DOPCFIND]`** is restated as what the counters actually bound — spans
  against calls, with `BLKREC`'s nesting named (`004aa6d`).
* **`docs/handler-discriminator.md`** carries its own metal verdict, the static autopsy, the gate
  and the PARKED conclusion — the correction pass rung 2's and rung 3's docs each got.

**Still standing, and two are added:**

* **`docs/ifetch-fastpath.md` should be marked MISSED** with §29.5's mechanism beside it. Unchanged
  from §34.5; not done.
* **`docs/profiler.md` should carry §31.2 and §31.3** — cross-session `cyc/dispatch` must not pin a
  price a capture never measured, and the ceiling line decides per capture. §39.3 is a worked
  example of the first and it now has a fourth data point riding on it.
* **NEW: `docs/profiler.md` should document §37.2** — that any two price columns of one capture
  recover the whole `acc/spans` vector, of which the ceiling line already prints the minimum. It
  costs no counter and it is the objective form of a judgement §31.3 could previously only make by
  inspection.
* **NEW: `docs/handler-discriminator.md`'s finding 4c/4d** should be read by whoever writes the next
  pre-registration, as the worked example behind §37.1. The fault is the document's, it is already
  recorded there, and the general rule belongs in the profiler doc beside the counter list.

**One symbolizer action that is explicitly NOT owed, recorded so nobody does it.** The experiment
added `SPEC_HIT` at counter id **46**, and the revert removed it with the rest of the machinery —
`Z3660_PROF_C_COUNT` is back to **46**. The id existed only in the three images this session
measured and **never reached a capture `tools/prof-symbolize` consumed**. It must **not** be added
to `COUNTER_NAMES_V2`: adding a name for a counter no shipping firmware emits would put a row in
the table that can only ever report `absent`, which is the inverse of the `ATC_HIT` defect the
append seam exists to prevent.

**A separate, pre-existing gap found while checking that, and it is not v3.3's to fix.**
`COUNTER_NAMES_V2` ends at id **38** (`IV_CACR_SKIP`, rung 1c) and so names **39** counters
against the firmware's **46**. Ids 39–45 — the rung-1d and rung-2 additions — fall past the table
and take the append seam's designed path: each is named in a *"beyond the 39 version 2 defines …
reported but not interpreted"* warning. **This is the seam working, not failing** — nothing is
mislabelled and no id's meaning has moved. But the counter table itself iterates the tool's own
list, so those seven rows do not appear in it, and every capture since rung 1d has been read that
way. **Whether the values reach the reader by another path, and what closing the gap costs, are
tools questions this document does not answer.** Closing it is a change to
`tools/prof-symbolize.py` driven by the firmware's counter list — never by reverse-engineering a
capture — and it is out of v3.3's scope.

### 40.6 The ledger of refuted claims — v3.3's additions

Per `docs/METHOD.md`, appended to §18.4, §26.5 and §34.6. Nothing is deleted.

| claim | where | status |
|---|---|---|
| **`HANDLER` is the ladder's #1 rung, worth 4.5 – 4.7 % at 25 % reclaim** | §33.3 row 1, and v2's estimate carried unchanged for three versions | **STRUCK — by implementation arithmetic, not by classification.** A gate-compliant body prices at `R` ≈ 2.8 % ⇒ +0.59 % at the measured 21.12 % coverage, below the +0.90 % PAY floor, before the measured −1.07 % machinery cost. Best case ≈ −0.5 %. §36.3 |
| **`HANDLER`'s classification can be bought with one discriminator** | §33.2, §33.3 note 1 | **REFUTED.** The discriminator ran, engaged at 21.12 %, and measured an implementation that *added* 2.2–3.1× the path it replaced. The bucket is **still unclassified** and now costs a design round. §36.2 |
| the pre-registered failure mode — *"serves 20 %, handler bodies get shorter, dhrystone does not move"* | `handler-discriminator.md` | **DID NOT FIRE.** The bodies got 14–16 % **longer** and dhrystone moved −7.55 %. A third outcome the pre-registration did not enumerate. §36.1 |
| **`FETCH` / `IFETCH_CALLS` will FALL when site C is removed** | `handler-discriminator.md`, declared twice | **ARITHMETICALLY IMPOSSIBLE AS WRITTEN.** A window hit is answered **above** the `FETCH` counter, so the removal could only move `DOPC_EXT`. The +2.44 % rise reconciles exactly with the −0.47 pp `DOPC_HIT` drop (2 extra fetches per extra miss: +0.0095 predicted vs +0.0124 measured), and it carries `IPAGE` (4d) with it. **4c and 4d are one bookkeeping finding, not two build defects.** §37.1 |
| **§22.3's fill-path price of 62 – 64 cyc/miss** | §22.3, §24.4, §33.4 | **REFUTED UPWARD, and now replaced by a measurement.** 75.9 – 81.9 cyc/miss at calibration band `[54, 60]`, reference posture — **19 – 32 % dearer**. Even the cheapest end at the ceiling price is above the stale expensive end. §38.1 |
| **misses removed ∝ invalidations removed (slope 1.0)** | §24.4's headline row | **REFUTED BY §24.4's OWN CALIBRATION POINT.** Rung 1c's measured response is **0.70**, so `IV_FLUSH`'s 50.96 % of traffic buys ~35.7 % of misses — landing on §24.4's *conservative* row. §38.4 |
| "the physical index's margin is thin, and the cost site is what killed rung 1b" | §17.3, §22.3, §24.4 | **RE-AIMED.** On the measured price the break-even translation budget is **93 – 186 cyc** depending on `f` — above the whole fill it precedes in every case. The thin quantity is **`f`**, not `T`. §38.3 |
| `LOOPRES` as *"the true residue"* at 18.52 – 15.37 % | §33.1, §33.3 row 4 | **BAND ARTEFACT, PARTLY.** At `[54, 60]` it reads 11.92 – 8.40 % and is **87 % bracket cost** at the ceiling price, with its own zero-crossing only 15 % above the ceiling. The withholding stands and now has a second, independent reason. §37.2 |
| "the revert is measured but not performed" — card and repo are two binaries that merely measure the same | §34.1 | **CLOSED, CRYPTOGRAPHICALLY.** The reverted tree rebuilds `BOOT-lean.BIN` byte-for-byte to `DEC21748`; the card holds `DEC21748`, CRC-gated on the card twice. §35.2 |
| `DOPCFIND` cyc/dispatch at a pinned 57 as a comparable series | §32.2's three-point table | **ONE POINT WITHDRAWN, ONE ADDED.** r3's 70.53 was quoted at a price outside its own band `[39, 50]`; this session's 73.75 is in-band — but on a build carrying the `SPEC` machinery disarmed, so it is not a clean point either. The clean series needs a prof capture on the reverted tree. §39.3 |

---
---

## 27. What v3.2 is

**v3.1's recommendation, taken twice in one day, with opposite outcomes — and the pair is worth
more than either result on its own.** §25.1 said *build the accessor fast path*. It was built,
and it returned **+25.17 %** — the largest single rung of the campaign. The same technique was
then pointed at the bucket the accessor rung left as the largest attackable group, the
instruction fetch. That rung engaged on **91.10 %** of instruction fetches, made the fetch
bucket **23–25 % cheaper per guest instruction**, and returned **−0.05 % across the build.**

**Two rungs, one technique, one week, opposite signs.** §30 is the mechanism that separates
them, and it is a *pricing law*: it says which removed instructions turn into wall clock and
which do not, and the profile cannot see the difference. Every remaining row on the ladder is
re-annotated against it in §33.2 — because bucket size has now been measured, twice and in both
directions, **not** to be a predictor of attackability.

Nothing in this version comes from a new instrument. The shares are read with the same reader,
the same brackets and the same conventions as v3.1; §31 is what changed about how they may be
*compared*.

> **A naming collision, resolved once.** "Rung 2" in §13.2 and §22.5 means **v2's ladder row —
> the interrupt-poll cadence**, which is banked by running `service_cadence 4`. From here on
> **"rung 2" and "rung 3" mean the second and third firmware builds of the C2 series**
> (rung 0, 1, 1b, 1c, 2, 3): the *accessor* fast path and the *instruction-fetch* fast path.

### 27.1 Provenance

| | **rung 2 — the accessor fast path** | **rung 3 — the instruction-fetch fast path** |
|---|---|---|
| session | 2026-08-23, 09:55 → 10:46 EEST | 2026-08-23, 11:49 → 12:46 EEST |
| evidence | `2026-08-23-r2-verdict/` | `2026-08-23-r3-verdict/` |
| firmware | HEAD `d5c3d6a`; lean `DEC21748`, prof `15DC7660` | HEAD `9c11ee0`; lean `86C0BC18`, prof `E3E9DB90` |
| design doc | `Z3660/docs/accessor-fastpath.md` | `Z3660/docs/ifetch-fastpath.md` |
| pre-registration | `EXPECTATIONS.txt`, before power-on, unedited | `expectations.md`, before power-on, unedited |
| console switch | `DFAST` (unset = ON) | `IFAST` (unset = ON) |
| **verdict** | **KEPT** | **REVERT** |

Rig unchanged across both sessions and across v3.1: preset 7 (`amix_ram 128`,
`service_cadence 4`, `arm_frequency 1100`), AMIX on piscsi `ced0s1`, the preset *file* never
written. Each session opened its serial capture at the previous session's close-out offset, so no
session's evidence overlaps another's, and rung 3's capture is byte-exact end-to-end (254 226 B
requested, 254 226 B received, zero drops).

### 27.2 The standing posture — read every number below against this

| row | dhry c4, lean, `service_cadence 4`, `amix_ram 128` |
|---|---|
| pre-rung-2 reference (v3.1's baseline) | **6539.0** — and reproduced as **cell A of rung 3's 2×2** (both switches disarmed): 6539 / 6566 / 6566 |
| **rung 2, shipping** | **8185** (8185 / 8184 / 8185, within-arm spread 0.01 %) — **+25.17 %** |
| rung-2 build, re-measured one session later | 8197 / 8197 / 8185, **mean 8193.0**, median 8197 |
| **rung 3** (*the row*) | 8184 / 8163 / 8219, **mean 8188.7**, median 8184 — **−0.05 %** |
| rung 3, return leg (both switches cycled and restored) | 8153 / 8196, mean 8174.5 |

**The standing posture is 8185-class**, and the two builds are the same machine to within the
rig's own spread. Cell A landing on **6539** — v3.1's banked pre-rung-2 reference, to the digit,
two builds and three flashes later — is the strongest rig-stability evidence this lane has ever
had, and it is what lets the −0.05 % be read as a null rather than as drift.

**Card state and repo state differ, and the difference is recorded rather than tidied.** The card
holds `86C0BC18` — the rung-3 lean image — because the rung-3 rebuild overwrote `BOOT-lean.BIN`
in place and **no copy of the rung-2 lean image `DEC21748` exists** on host or card
(`50-REVERT-IMAGE-UNAVAILABLE.txt` lists every image checked, with CRCs). Behaviourally that
image *is* the rung-2 posture: −0.05 %, inside the rig's spread, both switches reversible and
echo-confirmed in both directions. **The substantive revert is a firmware-repo action — revert
`3087af9`, rebuild `make lean`, one flash — and it is not done at the time of writing.**

> **Process finding, worth more than the incident.** The build writes every variant to a *fixed*
> filename, so flashing a new build destroys the only copy of the reference arm it is about to be
> judged against. **A verdict session must archive the outgoing image before its first rebuild**,
> or the build must stamp the CRC into the filename.

---

## 28. Rung 2 — the accessor fast path: KEPT, and the number is **+25.17 %**

§25.1's brief, built as written: the `dpagecache` hit path resolved inline, behind a `DFAST`
console switch, with a host state-equivalence corpus as the guard. It cleared its pre-registered
bar (`dhry c4 ≥ 6900`) by 18.6 %.

### 28.1 The row, and why there are two honest numbers

```
cross-build   lean c4   8184.7  vs the pre-rung-2 build's 6539.0   = +25.17 %   <- SHIPPING
same-boot     lean c4   8184.7  vs DFAST OFF's         6294.5      = +30.03 %
cross-build   lean c1                                              = +19.43 %
same-boot     prof c1                                              = +15.77 %
```

**The disarmed arm is not the pre-rung-2 machine.** With every verdict `SLOW` an access still
loads the table, compares, and only then runs the unmodified accessor — a **−3.74 %** disarm
penalty, measured across two flashes. The design doc's claim that disarming *"costs nothing on
the hot path"* is true of the **armed** table and false of the disarmed one, and the arithmetic
closes exactly:

```
1.2517 (shipping)  x  1.0388 (disarm penalty)  =  1.3003  =  the same-boot ratio, to four digits
```

**Quote +25.17 %.** The same-boot switch overstates the shipping gain by ~4.9 pp. §30.2 shows
this is not a quirk of one rung: the switch overstates *by construction*, and rung 3 measured the
same identity again.

### 28.2 The profile moved where the wall clock did

Cadence 4, swept `[54, 59]` (that session's own band, ceiling printed by the firmware):

| group | before (v3.1, c4) | after rung 2 |
|---|---|---|
| **`READ` + `WRITE`** | 23.12 – 24.13 % | **14.58 – 15.87 %** |
| `FETCHOP` + `FETCHEX` | 16.41 – 17.06 % | **18.06 – 19.98 %** ← now the largest attackable group |
| `DOPCFIND` | 13.32 – 13.65 % | 15.06 – 16.15 % |
| `HANDLER` | 19.41 – 19.68 % | 19.19 – 19.80 % |

**Three independent signals moved together** — wall clock +25 %, `READ` + `WRITE` down 8.4 pp,
fast-path coverage **99.11 % (c1) / 99.14 % (c4)** — so the pre-registered failure mode ("the
accessors get faster and dhrystone does not move") did not occur *and could not have hidden*.
The `dpagecache` hit rates are unmoved to **≤ 0.04 pp** (read 99.19 %, write 99.33 / 99.34 %),
which is what makes the comparison like-for-like.

### 28.3 What the rung's own doc had to correct — and what the map corrects with it

Four of the design doc's statements did not survive its metal, and all four are corrections the
map inherits:

1. **The disarm is not free** (−3.74 %); the shipping number is the cross-build one. §28.1.
2. **The `XPAR` / `PAGE` weighting is not a constant.** Pre-registered at 30–33 % from the s19
   capture, measured at **22.63 % (c1) / 24.07 % (c4)** in rung 2's own — and at **19.88 %** one
   session later. It is a property of the window's supervisor/user mix, and `DFAST_XPAR` now
   makes reading it per capture free. **Do not re-pin it**, in either doc or map.
   The counter validated on its own data: the doc's original *inference* method, re-run on the
   same capture, agrees with the direct measurement **to 0.6 pp**.
3. **The disk row moves, +5.03 % (same-boot lean c4) / +7.79 % (cross-build) / +7.69 %
   (same-boot prof c1)** — pre-registered as "no, or barely". Both premises behind that
   prediction were true and the conclusion still did not follow: on this rig "device-heavy work"
   means the AMIX kernel **copying bytes in interpreted 68k code** (`uiomove`/`copyout`), and
   every one of those bytes is a guest data access through the accessors. The rung helps I/O
   throughput, which was never claimed for it.
4. **§25.1's misalignment asymmetry — CLOSED, and it was a denominator defect.** The map asked
   why one guest read in five is misaligned against one write in 800. `MISALIGN_R` counts the
   *instruction-stream* fetch site too; `MISALIGN_W` has no instruction-stream analogue.
   Subtract the instruction half (`MISALIGN_I`, 98.5 % of it) and the genuine misaligned **data**
   reads are **0.1886 % (c1) / 0.1828 % (c4)** of `READ` against a `MISALIGN_W`/`WRITE` control of
   **0.1317 / 0.1275 %** — an asymmetry of **1.43×**, not 106×. Reproduced at 0.1850 % / 1.46×
   in rung 3's session. **There is no misaligned-read sub-path to attack; there was a counter
   with two call sites.**

### 28.4 The 2×2 confirms rung 2 from the other side

Rung 3's `DFAST` × `IFAST` matrix (§29.4) measures the accessor rung again, one boot, both
`IFAST` arms, every arm echo-confirmed:

```
DFAST gain   +22.98 %  (IFAST off)      +23.07 %  (IFAST on)
```

Against the same-boot switch's own +30.03 % in rung 2's session — a *different* boot, a
*different* build and a workload one rung faster — that is the same measurement recovered
independently, and the residual gap is the disarm penalty carried by a different image. **The
accessor rung is the best-defended number on this page.**

---

## 29. Rung 3 — the instruction-fetch fast path: **REVERT**

The same technique on the instruction side: `mmu_get_iword()`'s out-of-line TTR call resolved
inline through a 256-entry verdict table, behind an `IFAST` console switch, with the same host
corpus shape as rung 2. ITT0 covers 0–1 GB at both privilege levels, so ~87 % of instruction
fetches were expected to be TTR-matched and to pay that call.

### 29.1 The verdict rule, and both of its clauses

> Pre-registered: **KEEP** if the new-lean cross-build dhry c4 exceeds **8185** *and*
> `IFAST_HIT / FETCH` coverage lands in **80–90 %**. Otherwise **REVERT**.

| | pre-registered | measured | |
|---|---|---|---|
| cross-build lean c4 | **+7.8 .. +8.7 %** → 8824–8898 | **−0.05 %** (mean 8193.0 → 8188.7); median **8184**; all five new-build runs → −0.12 % | **MISS — hard** |
| *named possibility*, not the prediction: rung 2's stall recovery repeating | +13.1 .. +14.6 % | −0.05 % | **MISS** |
| `IFAST_HIT / FETCH` coverage | 80 – 90 % | **91.10 %** (44 345 843 / 48 679 431); 91.14 % on the DFAST-off arm | **MISS — over-delivered** |
| `IFAST_XPAR / IFAST_HIT` | 85 – 90 % | **89.23 %** | **HIT** |
| `IPAGE` rates must not move | ± 0.1 pp | **91.63 % → 91.62 %** across the switch, same boot: **0.01 pp** | **HIT** |
| the same-boot switch reads high vs cross-build | 3.2 – 3.5 pp | **1.60 pp** (switch +1.55 %, cross-build −0.05 %) | **MISS** — right sign, right shape, half the size |
| `cross-build × disarm-penalty == same-boot switch` | must close | 0.99947 × 1.01604 = **1.01550**; measured switch ratio **1.01550** | **HIT — exact** |

**REVERT fires on both clauses.** The rung works; it does not pay.

### 29.2 Every premise came in at or better than assumed

This is what makes the null a finding about the *model* and not about the build:

| premise | the design doc assumed | measured |
|---|---|---|
| `FETCHOP` + `FETCHEX` share of c4 (both swept `[54, 59]`) | 18.06 – 19.98 % | **17.82 – 19.78 %** |
| fast-pathable shape (words + aligned longwords) | 86.6 % | **92.20 %** |
| longword fetches routed to the splitter | 26.9 % | **15.59 %** |
| `IFAST_HIT / FETCH` coverage | 80 – 90 % (pre-reg) | **91.10 %** |
| `IFAST_XPAR / IFAST_HIT` (the ITT0 premise, measured directly) | 85 – 90 % | **89.23 %** |
| the fetch bucket's own cut | −40.1 % | **−23.0 % per guest instruction** |

**Priced identically, the target was exactly the size the projection assumed.** The one premise
that under-delivered is the only one the doc could not measure in advance — and even it is a
23 % cut of the bucket the whole rung was aimed at.

### 29.3 The bucket really did shrink, and the machine did not notice

Same boot, prof image, cadence 4, corrected cycles **per guest instruction** (the two ~12 s
windows are not the same length, so nothing raw is compared):

| bucket | `IFAST` on | `IFAST` off | delta |
|---|---|---|---|
| `FETCHOP` | 18.33 | 26.30 | **−30.3 %** |
| `FETCHEX` | 54.19 | 67.87 | **−20.2 %** |
| **fetch pair** | **72.51** | **94.17** | **−23.0 %** (−25.0 % at price 50) |
| `HANDLER` | 118.82 | 119.41 | −0.5 % |
| `DOPCFIND` | 88.54 | 88.83 | −0.3 % |
| `READ` | 47.94 | 48.14 | −0.4 % |
| `WRITE` | 36.09 | 34.83 | +3.6 % |
| **corrected TOTAL** | **685.31** | **706.77** | **−3.04 %** |

**The saving is not reabsorbed elsewhere**: the fetch pair gives up 21.66 cyc/INSN and the whole
corrected profile gives up 21.46 — about 1 % of the saving lands in other buckets. The cycles
left the profile. They did not arrive at the wall clock.

### 29.4 The `DFAST` × `IFAST` 2×2 — one boot, every arm echo-confirmed

Means of three dhry c4 runs each, lean image `86C0BC18`:

| | **`IFAST` off** | **`IFAST` on** | `IFAST` gain |
|---|---|---|---|
| **`DFAST` off** | **A 6557.0** <br><sub>6539 / 6566 / 6566</sub> | **B 6653.7** <br><sub>6629 / 6684 / 6648</sub> | **+1.47 %** |
| **`DFAST` on** | **C 8063.7** <br><sub>8075 / 8063 / 8053</sub> | **D 8188.7** <br><sub>8184 / 8163 / 8219</sub> | **+1.55 %** |
| **`DFAST` gain** | **+22.98 %** | **+23.07 %** | |

```
multiplicative model  (B/A) x (C/A) = 1.24791
measured                      D/A   = 1.24884
INTERACTION  D*A/(B*C) = 1.00075  ->  +0.07 %      (pre-registered |x| < 1.5 %)
```

**The two rungs compose multiplicatively: there is no interaction to find.** Engagement is pinned
in both directions — `IFAST_HIT = 0` with `IFAST` off, `DFAST_HIT = 0` with `DFAST` off, and
`DFAST` coverage reads 99.10 % with `IFAST` on *and* off — so the two fast paths are genuinely
independent knobs on metal, as the host corpus asserts.

### 29.5 The null, accounted for exactly — this is the whole result

The design doc counts the `iword` `XPAR` arm — the 87 % arm — three ways, from the disassembly:

```
pre-rung-3 build        79 instructions
rung 3, IFAST armed     37          (-42)
rung 3, IFAST disarmed  98          (+19)
```

If wall clock tracked instruction count, the two measured legs would stand in the ratio 42 : 19.
Measured, same rig, same session, same posture, lean images:

```
pre-rung-3 (rung-2 build)   8193.0
rung 3, IFAST OFF           8063.7    -1.58 %    (+19 instructions)
rung 3, IFAST ON            8188.7    -0.05 %    (-42 instructions)
```

**The +19 leg delivered 1.60 % of runtime** (the same ratio the other way up: 8193.0 / 8063.7 =
1.0160). **Scaled by 42/19, the armed leg should have returned +3.54 % — i.e. 8483. It returned
zero.** The shortfall is 294 dhrystones, 3.6 % of the machine.

> **The instructions this rung ADDS arrive, and cost in proportion to their count. The
> instructions it REMOVES return nothing.** One build, one boot, one workload, one
> disassembly — which is why this asymmetry, and not the cross-build row, is the cleanest
> evidence on the page.

**One honesty note about the added leg**, because it is the calibration the ratio argument
rests on: −1.58 % is itself a **MISS** of its own pre-registration, which priced the disarmed
table from the disassembly at **−3.2 .. −3.5 %** — right sign, right shape, about **half** the
predicted size. So the added side's *magnitude* needs measuring too. What distinguishes it from
the removed side is not accuracy; it is that it **arrived at all**.

---

## 30. THE PRICING LAW — what decides a rung, and it is not the bucket's size

### 30.1 The law

> **A removed instruction pays only if it sat in a dependency chain in front of its consumer.
> Work removed from *beside* a latency that something else is already hiding returns nothing.
> Work *added* in front of the path arrives — nothing overlaps a dependency you put in front —
> which is how the two sides of one change can price at completely different rates.**

The mechanism, in rung 3's own terms: the **42 removed instructions are a call chain *around*
the fetch** — an out-of-line `mmu_match_ttr_ins`, an indirect call through `x_phys_get_iword`, an
out-of-line `memory_get_word`. Their latency overlaps the fetch's own guest-DRAM access — and
that access is precisely the thing **the decoded-op cache exists to hide**, so it is the access
this machine already has the most slack behind. The **19 added instructions are a serial
dependency prepended to the original path**: load `z3660_ifv[top byte]`, compare, branch, and
only then start the accessor that was going to run anyway.

**Its inverse is why rung 2 paid.** The data side's call chain sat in front of a *page-cache
lookup* — two dependent loads out of a 256 KB table, an indirect call, a chain that fences the
ARM's own speculation — with nothing hiding it. Rung 2 therefore beat even its own
instruction-count model (~+15 % projected at constant IPC, **+25.17 %** measured): removing the
chain also removed stalls the count never saw, and the *surviving* code got faster too.

**The lesson is not "instruction counts are optimistic".** It is that **the same instruction
count means different things in front of different latencies**, and the ladder has now measured
both signs of that within one week:

| | removed work sat… | count model | measured |
|---|---|---|---|
| **rung 2** (data side) | in front of a page-cache lookup — **dependency-chained** | ~+15 % | **+25.17 %** |
| **rung 3** (fetch side) | beside a guest-DRAM fetch the dopc already hides — **latency-hidden** | +7.8 .. +8.7 % | **−0.05 %** |

### 30.2 The corollary the switches proved twice: a same-boot switch always overstates

A console switch's OFF arm is not the pre-rung machine — it still loads the table, compares, and
falls through. So the switch A/B always reads high, by exactly the disarm penalty, and both
rungs closed the identity to the digit:

| | shipping (cross-build) | disarm penalty | same-boot switch | identity |
|---|---|---|---|---|
| rung 2 | +25.17 % | −3.74 % | +30.03 % | 1.2517 × 1.0388 = **1.3003** ✔ |
| rung 3 | −0.05 % | −1.58 % | +1.55 % | 0.99947 × 1.01604 = **1.01550** ✔ |

**Rung 3's switch alone would have reported +1.55 % and looked like a small win.** The verdict
turns on the cross-build row, which is why a verdict session must take one — and why it must not
destroy the reference image before it does (§27.2).

### 30.3 How to price a rung before funding it

Four steps, all cheap, all now mandatory for anything on §33.3's ladder:

1. **Name the latency the removed work sits next to.** Not the bucket — the *latency*.
2. **Ask what is already hiding it.** The decoded-op cache hides the instruction stream's DRAM
   access; nothing hides a page-cache lookup's dependent loads, and nothing hides a table walk's
   chain of dependent guest-memory loads.
3. **Count the added work separately and charge it — it is the side that reliably has a sign.**
   Rung 3's +19 instructions were priced from the disassembly *in advance* at −3.2 .. −3.5 % and
   measured **−1.58 %**: about half, but it arrived, and it was the only leg of that rung that
   moved the wall clock at all.
4. **Buy the answer with one lean A/B *plus* a cross-build reference row.** One session, one
   console switch, both arms in one boot, and the previous lean image archived. That is the whole
   discriminator, and it is what settled this rung.

**Consequence for the ladder: ranking by bucket size is not ranking by attackability.** The fetch
pair was the largest attackable group on the map, it was attacked with the technique that paid
25 % on the data side, with *better* coverage than projected, and it paid nothing.

---

## 31. What the instrument can and cannot price

> **⚠ EXTENDED by §37.** Two more were added by the 2026-08-23 discriminator session: **§37.1**,
> that a pre-registered counter direction must be checked against the counter's position in the
> call topology before it is declared (a counter reached only *after* the branch you are deleting
> cannot fall when you delete it); and **§37.2**, the probe-density test — any two price columns
> of one capture recover each bucket's spans/INSN and its own zero-crossing price exactly, which
> is the objective form of the judgement §31.3 below could only make by inspection.
> **Kept unedited.**

Three caveats, all new, all of which change how the shares in this file may be *compared*. None
of them changes a measured number.

### 31.1 Row H is inflated by the profiler's own per-fetch calls — by about 3×

In the profiling build **every instruction fetch pays `Z3660_PROF_ENTER_IFETCH` +
`Z3660_PROF_CNT` + `Z3660_PROF_RET` — three out-of-line calls — and all three land INSIDE
`FETCHOP`/`FETCHEX`.** The probe correction subtracts the bracket pair; it does not subtract the
counter call that lives between them. So the bucket a fetch-side rung is sized against is the
bucket the instrument inflates most.

Measured, same-boot `IFAST` switch, corrected shares at `[54, 59]`:

```
the switch removes 3.97 .. 4.52 pp of the corrected profile
  -> at constant IPC that is  +4.1 .. +4.7 %  of wall clock
the LEAN image measured                        +1.55 %          -> a ~3x over-statement
```

Order-of-magnitude check on the mechanism (arithmetic sketch, **not** a measurement — no counter
separates the instrument from the bucket): 48.6 M fetches over 71.5 M guest instructions is 0.68
fetches per instruction, against an OFF-arm fetch pair of 94.17 cyc/INSN. Three calls at 30–40
cycles together is 20–27 cyc/INSN, i.e. **21–29 % of the bucket, present in both arms and absent
from lean entirely.**

> **Print this caveat beside row H wherever row H is quoted, and beside any row whose bucket
> contains profiler self-cost.** Shares read off a `PROFB` capture are a fair ranking of buckets
> *against each other*; they are **not a wall-clock forecast**, and they are least fair to the
> fetch pair. **The honest sizing tool for a fetch-side rung is a lean A/B**, which is what
> settled rung 3.

### 31.2 The probe price recalibrates between boots — a pinned price is not like-for-like

The firmware's own boot-time measurement of what a probe pair costs, same rig, same guest, three
sessions of one morning:

| session | bracket |
|---|---|
| v3.1 (s19) 07:3x | **[57, 68]** |
| rung 2, 10:0x | **[54, 66]** |
| rung 3, 12:24 | **[39, 50]** |

**A 32 % move in the marginal price in five hours**, and it moved *down*. v3.1 §16.2 documents a
~20 % drift and rung 2's findings repeated it; this is larger than either.

**Two consequences, and both retire a comparison this file has been making.**

* **`cyc/dispatch` at a pinned price is confounded.** `DOPCFIND` cyc/dispatch is
  `(acc − spans × price) / spans`, so the price is a first-order term. Comparing rung 2's 70.26
  against v3.1's 60.83 by pinning both at 57 charges the two captures different amounts of
  instrument — 57 was v3.1's own marginal price and only 54 was rung 2's. **The within-session
  comparison is the sound one** (§32.2 is one, and its spread is 0.63 %).
* **A share swept at one band cannot be compared with a share swept at another.** The fetch pair
  on rung 3's IFAST-off arm reads **14.21 – 16.59 %** at this boot's own `[39, 50]` and
  **17.82 – 19.78 %** at the doc's `[54, 59]` — the same cycles, two bands, and only the second
  is comparable with rung 2's table. Every cross-session share comparison in this file must name
  the band on both sides.

### 31.3 The ceiling line decides per capture — the "always impossible" folklore is retired

Rung 2 predicted and got the **WARNING** form of the firmware's price-ceiling line (*"the boot
line's in-bucket end 66 is ABOVE this capture's ceiling 59 and is arithmetically impossible"*),
as had every capture this lane had ever taken. Rung 3 printed the **other** form, in all three
captures:

```
[PROF] s ceiling: min_b(acc/spans) = 59 cyc/span, bound by TAILADV
[PROF] s usable sweep: [39, 50] -- the boot line's in-bucket end fits under the ceiling
```

**The streak broke because the bracket fell, not because the ceiling rose** — the ceiling is 59
in both sessions. So the line works in both of its arms, and *"the in-bucket end is always
impossible"* was a fact about the bracket's historical range, **not a law**. Keep sweeping
`[bracket_lo, min(bracket_hi, ceiling)]` and let the line decide per capture.

**A worked example of why this matters, from this file's own ladder**: `TAILADV` was RETIRED in
§22.5 at 1.28 – 0.00 %, because it *binds* the ceiling and vanishes there. On rung 3's band it
reads **9.16 – 5.29 %** — the same bucket, the same firmware, a lower price. The retirement
stands (a bucket that is all probe cost at its own ceiling is not a target), but the number is a
price artefact in either direction, and v3's rung 5 was funded off exactly that artefact.

---

## 32. The dispatch loop — `DOPCFIND` stays at #5, and the 15 % it gained is still unexplained

### 32.1 The way histogram: instrument fixed, verdict unchanged

Rung 2 found the histogram line printing `DOPC_HIT` in place of way 0 — five `z3660_prof_u64()`
calls into a four-slot rotating buffer inside one `printf`, so the line invited *"way0 = 100 %"*,
crossed the **≥ 85 % strike threshold**, and would have **struck a live rung** against the verdict
the firmware itself computed correctly two lines later. The fix landed before rung 3's capture,
and the line now prints the number it computes:

```
[PROF] r dopc ways: 35543411 / 12880698 / 4941876 / 2697555 (way0 63.39% of 56063540 hits)
[PROF] r dopc way VERDICT: way0 between 60% and 85% -- the rung STAYS at ladder #5
```

**way0 = 63.39 %** on the shipping arm (64.08 % `IFAST` off, 64.23 % `DFAST` off), and the
identity `sum(ways) == DOPC_HIT` is **exact in all three captures** with the pre-written warning
silent. All three sit inside 60–85 %: **the strike threshold is not crossed and `DOPCFIND` stays
at ladder #5.** Consistent with rung 2's own *integer* computation (62.50 % c1 / 63.25 % c4) —
the value never moved, only its printing was broken.

### 32.2 The +15.5 %: both candidates weakened, and the finding stays OPEN

Rung 2 measured `DOPCFIND` rising **60.83 → 70.26 cyc/dispatch (+15.5 %)** and named two
candidates: **(a) workload mix**, **(b) D-cache pressure from the new always-hot verdict tables**.
Rung 3 was the cheap test. Same boot, three arms:

| arm (prof image, cadence 4) | @39 | @50 | @57\* | dopc hit |
|---|---|---|---|---|
| `DFAST` on, `IFAST` on (shipping) | 88.53 | 77.53 | 70.53 | 78.34 % |
| `DFAST` on, `IFAST` off | 88.83 | 77.83 | 70.83 | 78.25 % |
| `DFAST` off, `IFAST` on | 88.98 | 77.98 | 70.98 | 78.08 % |

**Spread across all three arms: 0.63 %. Neither console switch moves it** — which was the
*predicted* result and carries no weight either way, because `expectations.md` §6 said in advance
that a disarmed table is still loaded and still compared: the switch varies whether the table is
**believed**, not whether it is **touched**.

**What does discriminate is the build comparison rung 3 made possible.** Rung 3 adds a *third*
always-hot verdict table (+1 KB `.bss`, +944 B `.text`) to the same L1D a 64 KB decoded-op cache
is competing for. Candidate (b) predicts a further rise:

```
s19 (pre-rung-2, no tables)   60.83
r2  (rung 2,     2 KB)        70.26      <- the +15.5 %
r3  (rung 2+3,   3 KB)        70.53      <- +0.39 % against r2
```

**A mechanism that charged 15.5 % for the first 2 KB charged 0.39 % for the third. Candidate (b)
is DEMOTED.** (\*The 57 is pinned only to line up with the earlier numbers, and §31.2 says that
pin is itself confounded — so this is evidence, not proof.)

**Candidate (a) is not confirmed either.** Rung 2 read its own opposite-signed hit-rate moves
(82.91 → 79.05 % at cadence 1 but 78.17 → 79.88 % at cadence 4) as the signature of a mix change.
Rung 3 adds a third point, and it does not fit: the dopc hit rate is **78.34 %** here against
**79.87 %** in rung 2 and **78.17 %** in s19 — this session sits *below* rung 2 and level with
s19 — while `DOPCFIND` sits **level with rung 2 and 16 % above s19**. Supervisor share: 48.74 %
here, 53.24 % rung 2, 49.28 % s19 — same story. **The cost tracks neither quantity**, so if mix
is the mechanism it is not through the hit rate or the privilege split, and no other form of it
has been named.

> **F6 stays OPEN with both candidates weakened.** The honest residue: something between the s19
> and rung-2 builds changed `DOPCFIND`'s cost by ~15 %, and it is neither of the two console
> switches, nor the size of the verdict tables, nor any simple form of workload mix.
>
> **And it is the larger prize in this bucket.** +15.5 % of ~61 cyc/dispatch is **≈ 9 cycles paid
> on every dispatch** — against a named way-walk rung whose entire ceiling is 1–4 instructions of
> a ~50-instruction path (§25.2). *If* the 9 cycles are real and recoverable, they are worth more
> than the rung the map has ranked at #5 for two versions. **They are also the softest number
> here**: cross-session, at a pinned price §31.2 says is not like-for-like. **Investigation
> first, rung second** — and the investigation is a build bisection with one price band, not
> another switch.

---

## 33. THE MAP v3.2 — the ladder, re-annotated and re-ranked

### 33.1 The shares

Rung 3's **`IFAST`-off arm** — the closest thing this session took to a rung-2-only profile, and
therefore the shape the machine is in once the rung-3 revert lands. **Close, not identical**: the
arm still carries rung 3's disarmed table, i.e. §29.5's +19 instructions per served fetch, which
inflates row H by that much. Cadence 4, swept this boot's
own `[39, 50]`, `TAILSAMP` excluded from the denominator. **The band is this boot's; §31.2
forbids comparing these against the `[54, 59]` columns in §28.2 without saying so.**

| bucket / group | corrected share (c4, `[39, 50]`) | at the doc band `[54, 59]` |
|---|---|---|
| **`LOOP` whole** | **36.33 – 34.73 %** | — |
| ‑ `LOOPRES` — the true residue | **18.52 – 15.37 %** | — |
| ‑ **`DOPCFIND`** | **13.41 – 14.92 %** | — |
| ‑ `DOPCFILL` | 2.77 – 3.06 % | — |
| ‑ `BLKREC` | 1.63 – 1.39 % | — |
| **`HANDLER`** | **18.02 – 18.87 %** | — |
| **`FETCHOP` + `FETCHEX`** (row H) | **14.21 – 16.59 %** | **17.82 – 19.78 %** |
| **`READ` + `WRITE`** | **12.52 – 14.28 %** | 14.58 – 15.87 % (rung 2's session) |
| **`TAILPOLL`** | 7.45 – 7.35 % | — |
| **`TAILADV`** | *9.16 – 5.29 % — price artefact, §31.3* | *≈ 0 at the ceiling* |
| **`XLATE` + `WALK`** | 1.81 – 2.25 % | — |
| `TAILSPEC` | 0.38 – 0.47 % | — |
| `FAULT` (uncorrected) | 0.13 – 0.16 % | — |
| *`TAILSAMP` (instrument, excluded)* | *6.66 – 6.35 %* | — |

§10.1 applies unchanged: these are shares of the **distorted** machine, and §31.1 now names the
distortion's largest single site — row H's own three per-fetch profiler calls.

### 33.2 The pricing-law annotation pass

> **⚠ ONE ROW MOVED, AND NOT THE WAY THIS TABLE EXPECTED.** The `HANDLER` row said *"must buy its
> classification with one switch + lean A/B before it is funded"*. That was done on metal
> 2026-08-23 and it **did not buy the classification**: the discriminator measured an
> implementation that *added* 2.2–3.1× the path it replaced, so `HANDLER` is **still
> UNCLASSIFIED** (§36.2) — while the *rung* is **struck** on a static count (§36.3). Every other
> row stands. **Kept unedited.**

**Every remaining candidate, annotated before it is ranked.** This is the column §30 adds to the
map, and no rung may be funded from an instruction count until its row here says
*dependency-chained*.

| row | what a rung would remove | in front of a latency, or beside one? | status |
|---|---|---|---|
| **`HANDLER`** | interpreted work that computes guest state | **UNCLASSIFIED — and this is now the prerequisite.** The work feeds the guest register file, so it *looks* dependency-chained by construction; the fetch side looked chained too until it was measured. Independent datum: `HANDLER` did not move across rung 3's switch (−0.5 %), so it did not absorb the fetch saving either | **must buy its classification** with one switch + lean A/B before it is funded |
| **`FETCHOP` + `FETCHEX`** — the *served* path | the call chain around a fetch the dopc is already hiding | **LATENCY-HIDDEN — MEASURED.** This is rung 3 | **STRUCK as an inlining target.** Do not re-fund an ifetch-side rung from these counts |
| **`FETCHOP` + `FETCHEX`** — the *miss* path (the physical-index study) | whole misses, not scaffolding: a miss's fetch is the one fetch the decoded-op cache is **not** hiding | **NOT hidden** — but its own added cost (a translation on the fill path) is a **dependency prepended to the fill**, so it is charged at full price | **live, and the only fetch-side prize left**; §33.4 |
| **`DOPCFIND`** — the way walk | 1–4 instructions of a ~50-instruction path measured at **IPC ≈ 1** | **dependency-chained** — the dispatch cannot start until the lookup resolves, so removals pay at count rate | **stays #5**; there is simply little to remove |
| **`DOPCFIND`** — the unexplained +15.5 % | ≈ 9 cyc/dispatch of unknown origin | **unknown — the mechanism is unidentified**, which is exactly why it is an investigation | **OPEN**, §32.2 |
| **`LOOPRES`** | unenumerated | **UNCLASSIFIABLE** — a bucket whose contents are unknown cannot be classified, which is a second, independent reason to withhold | **reclaim withheld**, as in v3 and v3.1 |
| **`READ` + `WRITE`** | what is left after 99.10 % coverage: the decline population and the inlined path itself | dependency-chained (rung 2 proved it) — but the chain has already been removed | **taken**; no named second-pass mechanism |
| **`XLATE` + `WALK`** | a table walk = a chain of **dependent guest-memory loads** | **dependency-chained by construction** — the cleanest case on the page | **prices at full value, and the bucket is ~2 %** |
| **`TAILPOLL`** | — | — | **banked** (cadence 4) |
| **`TAILADV`** | — | — | **retired** (price artefact, §31.3) |
| **row J (a JIT)** | the whole interpretive structure | **partly hidden, by measurement**: row J counts the fetch pair *in full*, and the fetch pair is now measured to be substantially latency-hidden; a JIT still pays the guest's own memory latency | **upper bound, now with a named mechanism for why** |

### 33.3 The ladder

> **⚠ SUPERSEDED by §39.2.** Row **#1** (handler specialisation) is **struck** — §36.3. Row **#2**
> (physical-index dopc) is **re-scored** and now leads at 1.74 – 2.71 % — §38.5. Rows #3, #4 and #5
> keep their rank but are re-read at a different band, and the ATC row is promoted on evidence
> §37.2 supplies. **Kept unedited.**

Amdahl against the standing **8185** (§27.2). Shares are measured on rung 3's `IFAST`-off arm at
`[39, 50]`; **the reclaim column is not measured** and §10.6 governs it exactly as before. Rows
are ranked by expected value, and the annotation column is §33.2's verdict in one word.

| # | rung | buckets | **share (c4)** | pricing law | reclaim (**est.**) | time won | **dhry @8185** |
|---|---|---|---|---|---|---|---|
| **1** | **handler specialisation** | HANDLER | **18.02 – 18.87 %** | **unclassified** | 25 % | 4.51 – 4.72 % | **8571 – 8590** |
| **2** | physical-index dopc (miss-rate half of the fetch second pass) | FETCHOP + FETCHEX, *miss path* | 14.21 – 16.59 % of profile; the *prize* is ~2.2 – 2.5 % of runtime | not hidden; **its own cost is chained** | see §33.4 | **~2.2 %** realistic | *≈ 8370 — v3.1's §24.4 arithmetic, **not** re-derived on this build* |
| **3** | `DOPCFIND` — the hit-path walk | DOPCFIND | **13.41 – 14.92 %** | chained, but nearly empty | 5 – 15 % | 0.67 – 2.24 % | **8240 – 8372** |
| **4** | `LOOPRES` — the true dispatch residue | LOOPRES | **18.52 – 15.37 %** | **unclassifiable** | **withheld** | — | — |
| **5** | ATC fast path | XLATE + WALK | 1.81 – 2.25 % | **chained** | 60 % | 1.09 – 1.35 % | **8275 – 8297** |
| — | *accessor fast path* | *READ + WRITE* | *12.52 – 14.28 %* | — | — | — | ***BUILT — rung 2, +25.17 %*** |
| — | *instruction-fetch fast path* | *FETCHOP + FETCHEX, served path* | — | **hidden** | — | — | ***BUILT AND REVERTED — rung 3, −0.05 %*** |
| — | *interrupt-poll cadence* | *TAILPOLL* | *7.45 – 7.35 %* | — | — | — | ***banked*** |
| — | *tail residue* | *TAILADV* | *price artefact* | — | — | — | ***RETIRED*** |
| **J** | the residual only a JIT reaches | LOOP + FETCH\* + TAILADV + TAILPOLL + TAILSPEC | **64.4 – 67.5 %** | **partly hidden** | 90 % coverage | — | *≈ 2.4 – 2.55× — an upper bound soft on two named components* |

**Three notes the table cannot carry.**

* **#1 is a promotion by elimination, not by evidence.** `HANDLER` leads because the bucket above
  it was measured hidden and the buckets below it are small or empty — **not** because anything
  says its work is recoverable. The 25 % is v2's estimate, carried unchanged for three versions
  now. **Its first move is not a design; it is the §30.3 discriminator on one handler family.**
* **#3 keeps its rank, but the interesting number in its bucket is no longer the rung.** The way
  walk stays worth 0.7–2.2 %; the unexplained ≈ 9 cyc/dispatch sitting beside it (§32.2) is worth
  more, is not yet a rung, and is the softest figure on this page (§34.3).
* **Row J's number rose and its meaning did not.** Both reasons are artefacts: `TAILADV`'s price
  band inflates it (§31.3) and the fetch pair inside it is partly hidden (§30). Read it as it has
  always been read — *a JIT is worth roughly twice the leading rung* — and stop quoting a
  dhrystone figure for it.

### 33.4 The recommendation

> **⚠ TAKEN, and SUPERSEDED by §38.6.** Its closing instruction — *"re-measure the fill-path price
> at one band before scoring a design against it, and quote the band"* — was carried out
> (§38.1). The re-scoring is §38. The recommendation survives in direction and changes in
> *sequence*: the study stays the leading rung, but the next funded step is **not** the design
> round — it is a one-switch measurement of the removal fraction, which §38.4 shows was carried at
> a slope its own calibration point contradicts. **Kept unedited**; the current recommendation is
> §38.6.

> ### The next funded design is still the physical-index decoded-op cache. It is now the only fetch-side prize the pricing law does not strike — and the law applies to its own cost too.

**The bar is unchanged and is already written** (§17.3, priced in §22.3): *a physical index costs
a translation on the fill path*. §30 adds the second half of that sentence: **a translation
prepended to the fill is a dependency in front of the fill, and dependencies in front arrive** —
exactly like rung 3's +19 instructions, the only leg of that rung that moved the wall clock at
all. **There is no stall-recovery discount to hope for on the cost side**, and its size still has
to be measured rather than counted (rung 3's added leg came in at half its own count-derived
prediction). The *prize* is different
in kind from rung 3's: it removes whole misses rather than scaffolding around served fetches, and
a miss's fetch is the one fetch the decoded-op cache is not hiding.

**What the design must pre-register, in this order:**

1. **Which of its removed costs are latency-hidden and which are dependency-chained** (§30.3),
   named per cost site, before any count is converted to a wall-clock number.
2. **Its cost site**, as §17.3 already requires — and it must be a site that pays *only* on a
   miss that was going to walk anyway. A design that adds work to every fill starts below the bar.
3. **A lean A/B plus a cross-build reference row**, with the outgoing lean image archived first.

**And one input the design needs is stale.** §22.3 priced the fill path at **62–64 cyc/miss** at
price 57. Re-derived on rung 3's `IFAST`-off arm at that boot's own band, `DOPCFILL` costs
**73–84 corrected cycles per miss** — the same path, a different price band, and §31.2 says the
two are **not** comparable. **Re-measure the fill-path price at one band before scoring a design
against it**, and quote the band.

**Do not re-fund an ifetch-side inlining rung from row H's counts.** That is the one thing §30
strikes outright, and row H's share is also the one most inflated by the instrument (§31.1).

---

## 34. What v3.2 does **not** establish

§10, §18 and §26 apply unchanged and are not repeated. Five things are new, and §34.6 appends
the ledger.

### 34.1 The revert is measured but not performed

> **⚠ CLOSED, and closed cryptographically — §35.2.** `DEC21748` was rebuilt and archived, flashed
> and **CRC-gated on the card twice** (2026-08-23, 14:39 and 15:32), and the reverted firmware
> tree rebuilds `BOOT-lean.BIN` **byte-for-byte** to it. Card and repo are the same binary by CRC,
> not by inference. **Kept unedited.**

Rung 3's verdict is REVERT and the card holds the rung-3 image (§27.2). The behavioural claim —
that `86C0BC18` *is* the rung-2 posture — rests on a −0.05 % cross-build null with a 0.15–0.68 %
within-arm spread, i.e. on the two builds being indistinguishable, not on the rung being absent.
**Until the firmware commit is reverted and a lean image rebuilt, "the standing build" and "the
rung-2 build" are two different binaries that measure the same.**

### 34.2 The pricing law is a law about two measurements

Two rungs, opposite signs, one week, one rig. That is enough to refute *"instruction counts
predict wall clock"* and enough to name the mechanism, and it is **not** enough to predict a third
rung's sign from armchair reasoning. §30.3 exists because the law's own consequence is that the
classification has to be **bought** per rung, cheaply, before the rung is funded — not asserted
from the shape of the code.

### 34.3 F6 is open, and its prize is the softest number on the page

§32.2's ≈ 9 cyc/dispatch is a cross-session figure at a pinned price §31.2 says is not
like-for-like. It could be substantially smaller. **It is quoted as a reason to investigate, and
it must not be quoted as a projected gain.**

### 34.4 Row H's caveat is an arithmetic sketch, not a measurement

§31.1's 21–29 % instrument share of the fetch bucket comes from a plausible per-call cost band,
not from a counter. **No counter separates the instrument from the bucket.** The *direction* is
established (three profiler calls do land inside the bucket, and the lean A/B under-runs the
profile's forecast by ~3×); the *size* is not.

### 34.5 What is owed to the Z3660 lane

Of §26.3's three items, **one is discharged**: the price bracket now carries a ceiling, and the
line has been seen in **both** of its arms (§31.3). The two `docs/profiler.md` identity
corrections — `tcnt[DOPCFILL] == DOPC_MISS` needing a fault term, and `tcnt[BLKREC] <=
tcnt[DOPCFIND]` comparing spans about a property of calls — **still stand, unfixed**. Discharged
separately: the way-histogram print defect rung 2 found (fixed in `47bd901`, confirmed on metal,
§32.1). Three items are added:
* **`docs/ifetch-fastpath.md` should be marked MISSED**, with §29.5's mechanism recorded beside
  it, the way rung 2's doc was corrected against rung 2's metal. Its instruction-count table is
  *not* wrong — the disarm leg confirms the counts — but its conversion of counts to wall clock
  is, on this side of the machine.
* **`docs/profiler.md` should say that cross-session `cyc/dispatch` comparisons must not pin a
  price one of the captures never measured** (§31.2), and that the in-bucket end is *sometimes*
  usable — the ceiling line decides per capture (§31.3).
* **The footprint tables in both fast-path docs price no second-order cost at all.** F6 is exactly
  such a cost and is still unattributed (§32.2).

### 34.6 The ledger of refuted claims — v3.2's additions

Per `docs/METHOD.md` §8, appended to §18.4 and §26.5. Nothing is deleted.

| claim | where | status |
|---|---|---|
| **"the fetch pair is the largest attackable group and the obvious next rung"** | rung 2's own findings; §28.2 | **REFUTED BY BUILDING IT.** Attacked at 91.10 % coverage, bucket −23 %, wall clock −0.05 %. §29. |
| **an instruction-count projection predicts a rung's wall clock** | rung 3 pre-registration (+7.8 – 8.7 %), and every reclaim estimate on this page | **REFUTED in both directions** — rung 2 over-delivered 1.7×, rung 3 delivered nothing. §30. |
| "removing a call chain removes stalls an instruction count never sees" — as a *general* rule | rung 2's findings, carried forward to rung 3 | **SCOPED.** True where the chain is dependency-chained; false where it sits beside a latency already hidden. §30.1. |
| a same-boot console switch reports the shipping gain | rung 2 and rung 3 framing | **REFUTED — twice, and quantified.** It overstates by exactly the disarm penalty: +4.9 pp and +1.60 pp. §30.2. |
| row H's corrected share as a sizing tool for a fetch-side rung | this file, every version | **INFLATED ~3×** by the profiler's own three per-fetch calls. §31.1. |
| `DOPCFIND` cyc/dispatch compared across sessions at a pinned price | rung 2's F6; §22.3's fill-path price | **CONFOUNDED.** The probe bracket moved 32 % in five hours. §31.2. |
| "the boot line's in-bucket end is always arithmetically impossible" | §20.2, rung 2's findings | **REFUTED.** It fit in all three of rung 3's captures. The ceiling line decides per capture. §31.3. |
| "way0 = 100 %, the `DOPCFIND` rung is struck" — the line as printed before `47bd901` | firmware instrument | **INSTRUMENT DEFECT, FIXED.** The real value is 63.39 – 64.23 %; the rung **stays** at #5. §32.1. |
| D-cache pressure from the verdict tables as the cause of `DOPCFIND`'s +15.5 % | rung 2's F6 candidate (b) | **DEMOTED** — a third always-hot table moved it +0.39 %. Not closed; candidate (a) is not confirmed either. §32.2. |
| `TAILADV`'s retirement as a *bucket-size* fact | §22.5 | **RESTATED.** Its share is a price artefact in both directions (9.16 % at `[39,50]`, ≈ 0 at the ceiling). The retirement stands on the mechanism, not on the number. §31.3. |
| §25.1's misaligned-read sub-path ("one read in five, never explained") | v3.1 §25.1 | **CLOSED — a denominator defect.** Genuine misaligned data reads are 0.185 % of `READ`, a 1.43× asymmetry against writes. §28.3. |
| §22.3's fill-path price of 62–64 cyc/miss as a bar to score against | §22.3, §24.4 | **NOT LIKE-FOR-LIKE** with anything measured since; re-derives to 73–84 cyc/miss at rung 3's band. Re-measure at one band. §33.4. |

---
---

## 20. What v3.1 is

**v3's §19 list, taken, on one metal session.** All seven items were executed. The headline is
that **§19 item 4 — the `LOOP` breakdown, which v3 called "the highest-value instrument change
available" — was built into the firmware and fired**, and it changes who is at the top of the
ladder. Three of the items also turned out to *specify a method that cannot answer the
question they ask*, which is §23.

### 20.1 Provenance

| | |
|---|---|
| session | 2026-08-23, 07:25 → 08:18 EEST; serial 136 763 743 → 136 992 422 (228 679 B) |
| evidence | `2026-08-23-s19-captures/` — `MATRIX.md` and `NOTES.txt` first, then the captures |
| rig | A4000 + Z3660, preset 7 (`amix_ram 128`, `service_cadence 4`, `arm_frequency 1100`), AMIX on piscsi `ced0s1` |
| instrument | rung-1d prof build, Z3660 HEAD `562c721`; `BOOT-prof.BIN` `0013FF1E`, `BOOT-lean.BIN` `6D069F13`, both CRC-gated twice per hop |
| reader | `tools/prof-symbolize.py` at `02c278e`, whose LOOP-split support was built for these dumps |

**Pre-registration**: `EXPECTATIONS.txt`, written 07:26 **before power-on**, copying §19
items 1–7 verbatim and fixing P1–P5, seven stop conditions and ten method rules. Two scoring
hazards were fixed in it *from source, in advance* — that `IV_CACR_SKIP` sits outside the
`IV_*` block (summing it in would have failed a stop condition on a correct build), and that
the split-cost line is a `PROFD`-only print so its absence at boot is not a miss. Neither was
derived from anything measured afterwards.

**Baselines.** The lean rows reproduce r1c to within 0.35 % on four independent
measurements (`23-LEAN-c1-dhry.log`, `27-LEAN-c4-dhry.log`, `boot3-lean-bootwindow.txt`):
**cadence 1 = 5589.0** (5583/5601/5583, spread 0.32 %, +0.09 % on r1c's 5584.0),
**cadence 4 standing = 6539.0** (6539/6539, +0.35 % on 6516.5), cadence gain **+17.00 %**,
lean boot window **52 s — the same figure for the fourth session running**. Rung 1d's
instrument did not move the lean build, which `profiler.md` claimed from an objdump and
metal now agrees with. **Every dhry projection in §24 is against 5589.0 and 6539.0.**

### 20.2 The calibration, and a ceiling nobody was checking

`00-PROF-BOOTLINE.txt`: `clk=cfg`, ARM clock 1 100 012 299 Hz, price bracket **[57, 68]**.

| session | bracket | vs prior |
|---|---|---|
| rung 1 | [32, 43] | — |
| rung 1b | [39, 50] | +22 % |
| rung 1c | [40, 51] | +3 % |
| **v3.1** | **[57, 68]** | **+42 %** |

§16.2 documents a ~20 % drift between captures and says to price from the boot's own line.
**This is +42 %, twice that, and the top of the bracket does not fit.** `TAILADV`'s
subtraction (`acc − spans × price`) goes negative at **59.17**, so the usable sweep is
**[57, 59.17]** and the firmware's own printed in-bucket end of 68 is arithmetically
impossible.

> **This is §8.3's error arriving from the other side.** There the map *picked* 59 and 59 was
> above the possible range; here the *firmware's own calibration* advertises 68 and the top of
> that bracket is unusable. **Sweeping a capture to the printed in-bucket end is not safe
> without checking the ceiling.** Every table below is swept `[57, ceiling]` and says which
> ceiling (`20-STAGE-bracket.txt` computes it per capture and refuses to sweep past it).

---

## 21. §15.4 SUPPORTED — the loop is opened, and the ladder's #1 changes identity

`19-STAGE-c1-profd.txt`, cadence 1, swept [57, 59.17]. `TAILSAMP` excluded from the
denominator (§17.1's convention — it does not exist in the lean build), reproduced against
r1b to the decimal.

| id | bucket | raw % | **corrected share** | spans |
|---|---|---|---|---|
| — | **whole loop** (what v2 and v3 called `LOOP`) | 31.46 % | **24.59 – 23.69 %** | — |
| 0 | `LOOPRES` — the true residue | 19.80 % | **10.28 – 9.21 %** | 342 935 376 |
| 14 | **`DOPCFIND` — the cache lookup** | 8.73 % | **11.45 – 11.65 %** | 93 093 757 |
| 15 | `DOPCFILL` — the fill | 1.56 % | **2.13 – 2.17 %** | 15 900 206 |
| 16 | `BLKREC` — the recognizer | 1.37 % | **0.73 – 0.66 %** | 23 629 378 |

**The whole loop reproduces v3's 26.38–26.54 % closely (24.59–23.69 %) — the bucket did not
move, it got opened.** The residual difference is a different boot's price bracket, not a
code change.

**`DOPCFIND` alone is 11.45–11.65 % — nearly half the whole dispatch loop, and larger than
`LOOPRES`, the residue everyone assumed the bucket mostly was.** §15.4 hypothesised that
`FETCHOP`'s 8.7-point raw loss between pre-rung-0 and rung 1b had been *re-attributed* into
`LOOP` rather than saved. 11.5 points is more than enough to account for 8.7, and the
mechanism is confirmed independently in the same dump: `FETCHOP` spans **16 013 889** against
`DOPC_MISS` **15 901 555** — the fetch bucket is entered once per **miss**, so a hit's fetch
cost has to live somewhere else, and `DOPCFIND` is where.

> **Consequence for the ladder.** v3 ranked `LOOP` first *and withheld its reclaim*, on the
> grounds that a reclaim fraction for a bucket whose contents had never been enumerated would
> be a guess dressed as a number. **The withholding was right, and the enumeration now says
> why: attacking `LOOP` means attacking rung 1's own hit path.** Half of what is in there is
> the thing rung 1 added. The residue genuinely available to a general dispatch-loop
> optimisation is `LOOPRES` — **9.2–10.3 %, not 26 %.**

**Per-event, and this is the number §25 turns on**: `DOPCFIND` costs **56.7–58.8 corrected
ARM cycles per dispatch**, paid on *every* dispatch, hit or miss. That buys one set index, a
generation compare, up to four tag compares, and the extension-window arm/disarm.

### 21.1 The split's own cost, printed rather than asserted

`[PROF] l` reports **265 246 682 added transitions, 20.95 % of all 1 266 239 640** (22.34 % at
cadence 4) — two per span of each of the three new brackets. A capture taken before rung 1d
has none of them, so **a share here is compared against a share there by re-pricing the
probe at 1 000 992 958 transitions, not by moving the new buckets' cycles back into id 0**,
which would invent a measurement. The symbolizer prints both denominators and refuses to
score id 0 alone against a quoted `LOOP` figure — reporting the residue against v3's
26.38–26.54 % would claim an 11.66-point fall that no code change produced.

### 21.2 The identities were read before any share, and one is a doc defect

| identity | cadence 1 | cadence 4 | verdict |
|---|---|---|---|
| `tcnt[DOPCFIND] == DOPC_HIT+DOPC_MISS` | 93 093 757 = 93 093 757 | 71 116 727 = 71 116 727 | **HOLDS EXACTLY** |
| `tcnt[DOPCFIND] == INSNS+FAULTS` | 93 093 757 = 93 093 757 | 71 116 727 = 71 116 727 | **HOLDS EXACTLY** |
| `tcnt[DOPCFILL] == DOPC_MISS` | 15 900 206 vs 15 901 555 | 15 516 937 vs 15 518 285 | **SHORT by 1349 / 1348** |
| `sum(IV_* block, 10) == DOPC_INVAL` | 41 709 = 41 709 | 40 249 = 40 249 | **HOLDS EXACTLY** |
| `STACK_OVF == 0` | 0 | 0 | OK |

**The two identities that validate the `DOPCFIND` bracket — the ones §15.4 turns on — hold
exactly, so the payload above is unaffected.** The fill identity is **understated, not
broken**, and the mechanism is from source (`newcpu.cpp`): `z3660_dopc_find()` counts
`DOPC_MISS` at `:5703/:5706/:5713`, the `DOPCFIND` bracket **exits at `:5899` before the
fetch**, `x_prefetch(0)` at `:5901` is an MMU-translated opcode fetch that **can throw** (as
can the extension lookahead at `:5903`), and `DOPCFILL` is only reached at `:6082`. **A miss
whose opcode fetch faults is counted as a miss and never reaches the fill.** The exact
identity needs a fault term:

```
tcnt[DOPCFILL] == DOPC_MISS − (misses whose opcode fetch or extension lookahead faulted)
```

Mechanism, not skew: the shortfall is **bounded by `FAULTS` in every window** (1349 ≤ 3632,
1348 ≤ 3627), sits at a stable **37.1 % / 37.2 %** of `FAULTS`, and **reproduces to within one
count on two different cadences**. Same class as §16.3, same shape of fix, and it is **owed to
the Z3660 lane** (§26.3).

A second identity is mis-stated and the cache-off arm exposed it: `tcnt[BLKREC] <=
tcnt[DOPCFIND]` **FAILED** on `51-CACHEOFF-profd.txt` (75 914 707 against 67 689 758). Not a
data defect — **the identity compares spans while stating a property about calls**, and
`BLKREC` is the one bracket the firmware's own doc calls impure: on a fire it holds the whole
serviced chunk, whose guest stores nest through `WRITE`, and every nested entry closes a span
and opens another. Excess 8 224 949 over 41 025 chunks = **200 nested spans per chunk against
308 guest instructions per chunk** — the right order. It passes on the cache-on dumps only
because the dispatch count is 4× larger there. **Latent mis-statement, surfaced.**

---

## 22. The banked rows

Six results that are not the headline and are not estimates. Each closes something the map
had open.

### 22.1 The cache's same-boot worth: +43.05 %, and §18.3 closes for dhry

`40-AB-dopcON.log` / `41-AB-dopcOFF.log`, prof build, cadence 1, buckets off, one boot,
`PROFZ` between arms.

| arm | runs | mean | spread |
|---|---|---|---|
| DOPC **ON** | 3738, 3748 | **3743.0** | 0.27 % |
| DOPC **OFF** | 2617, 2616 | **2616.5** | 0.04 % |
| **ratio** | | **1.4305 → ON beats OFF by +43.05 %** | |

Reproducing rung 1's **+41.57 %** on a different build and a different flash. **§18.3's gap —
"the cache's worth is unmeasured for 1c" — is now closed for the dhrystone row.** (It is
*not* closed for disk; that arm was not taken.) What this arm cannot do is defend +2.80 %;
see §23.1.

### 22.2 The cache's whole-boot effect is 24.6 %, and §19.5's metric was looking at the wrong phase

Same session, same flash, prof image, cache armed off at the early console (07:57:40,
echo-confirmed, well before MMU-enable). `boot1-prof-bootwindow.txt`,
`boot2-prof-DOPCoff-bootwindow.txt`.

| arm | Emu-mode-4 → MMU-on | **MMU-on → TCP** | Emu-mode-4 → TCP |
|---|---|---|---|
| DOPC **ON** | 22 s | **67 s** | **89 s** |
| DOPC **OFF** | 46 s | **72 s** | **118 s** |
| cache saves | **52.2 %** | **6.9 %** | **24.6 %** |

**The MMU→TCP window — the metric §19.5 is framed in — understates the cache's boot effect by
3.6×.** The pre-MMU phase more than doubles with the cache off and is entirely outside the
window this file has been quoting. Any boot-window comparison here measures the post-MMU
phase only, and that is where the effect is *smallest*. §23.2 amends the metric.

### 22.3 The fill-path price: 62–64 cyc/miss — §17.3's bar is now priced

> **⚠ REFUTED UPWARD, and replaced by a measurement.** The fill path is **75.9 – 81.9 cyc/miss at
> calibration band `[54, 60]`** in the reference posture — **19–32 % dearer** than the figure
> below, which was pinned at 57 on a cadence-1 capture. §33.4 flagged this input as stale and
> not like-for-like; §38.1 is the replacement and §38 re-runs §24.4's arithmetic against it.
> **Kept unedited**; do not score a design against 62–64.

§17.3 stated the bar before anything was built: *"a physical index costs a TRANSLATION ON THE
FILL PATH … this study must pre-register its cost site and measure the fill-path price, not
assume it."* **This is that price**, and rung 1d is what supplies it.

| | cadence 1 | cadence 4 |
|---|---|---|
| `DOPCFILL` corrected share | **2.13 – 2.17 %** | 3.05 – 3.13 % |
| `DOPCFILL` corrected cyc **per miss** | **61.8 – 63.9** | 61.9 – 63.9 |
| misses | 15 901 555 | 15 518 285 |

**The whole current fill costs about 62–64 ARM cycles.** The prize is `IV_FLUSH` at ~51 % of
invalidation traffic; the cost site is 2.1 % of runtime on a ~63-cycle path. **The study is
not obviously-doomed on size, but the margin is thin and rung 1b failed twice at exactly this
cost class.** §24.4 does the arithmetic.

### 22.4 The block fast path runs at ≥ 123 MB/s — ≥ 24× the model it replaces

§19 item 6, and the number rung 0 exists to move. The **5.17 MB/s** is a *model* (§9.7:
850.5 interpreted cycles per 4 bytes at 1.1 GHz) of the interpreted `bzero` loop **while it
runs**, so the comparable quantity is the fast path's rate **while it runs** — not an average
over a window that is mostly not zero-filling. Rung 1d supplies it for the first time,
because `BLKREC` holds the whole serviced chunk on a fire.

| capture | `BLK_BYTES` | `BLK_HIT` | `BLKREC` corrected cyc @57 | seconds | **rate** |
|---|---|---|---|---|---|
| `19-STAGE-c1-profd.txt` | 39 359 700 | 41 487 | 351 019 222 | 0.319 | **≥ 123.3 MB/s** |
| `19-STAGE-c4-profd.txt` | 39 077 320 | 40 874 | 339 241 748 | 0.308 | **≥ 126.7 MB/s** |

**The bound is conservative in the right direction**: `BLKREC` also holds the residual test on
every *decline* (23.6 M calls against 41 k fires), so charging all of its cycles to the chunks
*overstates* their time and *understates* the rate. Chunk geometry at cadence 1: **948.7 bytes
and 306.3 guest instructions per chunk** (956.1 and 309.3 at cadence 4) — clearing the ~8
amortisation floor by two orders of magnitude, as §14.1 requires. The naive window average —
0.350 MB/s over 112.3 s — is **not**
the comparable figure and is recorded only so nobody recomputes it and concludes rung 0
regressed.

### 22.5 `TAILPOLL` at both cadences: rung 2 is banked, and `TAILADV` is retired

`TAILPOLL` is **17.91–18.47 % at cadence 1** against **6.87–6.81 % at cadence 4** — an
**11-point fall**, confirming §17.1's caveat that its figure is cadence-1 only and that **rung
2 is already banked in the standing posture**. Do not add it to the standing baseline.

`TAILADV` is **1.28 % at 57 and 0.00 % at the 59.17 ceiling** — it is the bucket that *binds*
the ceiling, and at this boot's calibration it is essentially all probe cost. **v3's rung 5
(tail residue, 4.2–8.1 %) is 0–1.3 % on this instrument and is RETIRED from the ladder**, worth
approximately nothing. Its v3 figure was an artefact of a lower price bracket, not a target.

### 22.6 The guest's invalidation demand is 91 k, and it is a property of the guest

`51-CACHEOFF-profd.txt`, `PROFZ`-fenced, cache off, buckets on, cadence 1. **All four `DOPC_`
counters exactly zero** — the clean confirmation the firmware doc wanted after the pre-1b bug
where `DOPC_INVAL` moved with the cache off, and the `[PROF] l note:` line printed instead of
a warning, exactly as pre-registered.

| cause | count | share of the 41 594 that reach the invalidator | §17.3's dhry column |
|---|---|---|---|
| `IV_FLUSH` (`CPUSHL`/`CINV`) | 21 198 | **50.96 %** | 51.21 % |
| `IV_PFLUSHA` | 15 279 | 36.73 % | 36.27 % |
| `IV_PFLUSH` | 3 632 | 8.73 % | 9.11 % |
| `IV_ROOT` | 1 485 | 3.57 % | 3.25 % |
| `IV_DMA`/`TABLE`/`KNOB`/`WRAP`/`MAP`/`CACR` | 0 | 0 % | — |
| **`IV_CACR_SKIP`** (narrowed at the call site) | **49 487** | — | — |

**Guest true request rate = 41 594 + 49 487 = 91 081**, of which **54.33 % is narrowed at the
call site before the invalidator is reached**. The cache-**on** cadence-1 window put the same
quantity at **91 085** (41 709 + 49 376). **91 081 vs 91 085 — 4 parts in 91 000, 0.004 %.**

> **The guest's invalidation demand is a property of the guest, not of the cache.** That is
> exactly the uncontaminated denominator §17.3's physical-index study has to be judged
> against, and §19 item 7 asked for it because no other measurement can supply it.

---

## 23. §19 amended, item by item

Three of v3's seven items need their *statement* corrected, not merely their result recorded.
Each is a case of a method that cannot answer the question it was pointed at.

### 23.1 Item 3 — a same-boot console A/B cannot defend +2.80 %

§19 item 3 asked for a five-minute same-boot `DOPC` ON/OFF pair to defend rung 1c's +2.80 %
against drift (§18.2). The pre-registered band was **1.8–3.8 %**; the measurement came in at
**+43.05 %**, missing by ~11×. **The band was mis-specified, and the reason is structural** —
checked in source *before* scoring:

* `DOPC` is a **whole-cache** toggle (`main.h:134`: `0xFFFFFFFF` = OFF, pure passthrough), and
  `debug_console.c:664-670` is the only knob;
* **there is no console control for rung 1c's narrowing arms** — they are compile-time;
* **+2.80 % is rung 1c against rung 1, a *build* difference.**

> **No same-boot switch A/B can reproduce a build difference.** §19 item 3's method cannot
> defend the number §18.2 says needs defending. **The experiment that can is a same-session
> TWO-FLASH A/B** — rung-1 image against rung-1c image, one session, same rig, `PROFZ`-fenced.

**Recorded as an optional, low-priority item.** It is two flash cycles and a warm-up for a
2.80 % figure that (a) is not quoted in any ranking on this page, and (b) has a
pre-registered bar cleared on a three-run arm with 0.125 % spread, which is a legitimate
verdict on its own terms. **§18.2 stands unresolved and is now correctly *scoped*: it needs a
two-flash A/B or it stays open.** Do not spend a session on it ahead of §25.

### 23.2 Item 5 — the boot-window metric moves to Emu-mode-4 → TCP

§19 item 5 (and every boot-window figure in this file) is framed on **MMU-on → TCP**. §22.2
shows that window excludes the phase where the cache's effect is largest and understates it by
3.6×. **The metric is amended to Emu-mode-4 → TCP**, which names the whole emulated boot.
Existing MMU→TCP figures are not withdrawn — they are correct measurements of the post-MMU
phase — but **any figure quoted as "the boot effect" from here on is Emu-4 → TCP, and any
older one must say which window it is.** The lean 52 s row is unaffected: it is a
rig-drift detector compared only against itself, and it has held for four sessions.

### 23.3 Item 1 — row H's band and bar are WITHDRAWN, and row H is FLAT

> **⚠ Read §31.1 beside every row-H share below.** The corrected fetch share is inflated by the
> profiling build's own three per-fetch calls, and a fetch-side rung sized off it is sized off the
> instrument — measured at ~3× when rung 3 finally took a lean A/B (§29, §31.1).

§19 item 1 pre-registered `FETCHOP + FETCHEX` at **10–13 %, "must not exceed rung 1's
12.64 %"**, and reasoned *"expect it low"* from the hit rate coming in above band.

| | corrected `FETCHOP + FETCHEX` |
|---|---|
| rung 1 (`2 × IFETCH_CALLS` method) | 11.27 % @32 / 10.48 % @43 |
| §19's pre-registered band | 10–13 %, ≤ 12.64 % |
| r1b, **span-measured** | 14.50 – 15.81 % |
| **v3.1, span-measured, cadence 1** | **14.96 – 15.51 %** |
| v3.1, cadence 4 | 16.41 – 17.06 % |

**The bar cannot be scored against, because it was built by a method this file has already
refuted.** §16.1 retires `2 × IFETCH_CALLS`: it over-charges the ifetch buckets by 1.97–1.98×
and biases every share derived from it **low**. The 12.64 % bar is one of those figures, and
comparing a span-measured 14.96 % against it is precisely the incommensurable comparison
§16.1 forbids. **The band and the bar are withdrawn as refuted-method artefacts** (§26.2), not
missed.

**Against the only commensurable number — r1b's span-measured 14.50–15.81 % — row H is
UNCHANGED at 14.96–15.51 %.** So §18.1's worry, that §17.1's share table describes a build
that is not shipped, **is answered for this row: it did not move.**

**And the pre-registration's *reasoning* is refuted, which is the more useful half.** It
inferred a low fetch share from a high hit rate. The hit rate here is 82.92 % and row H came
in flat. **The inference does not carry**, because a miss's fetch cost is only part of the two
buckets: `FETCHEX` (extension words, **11.85 – 12.29 %**) is nearly **four times** `FETCHOP`
(**3.12 – 3.21 %**) — a ratio of **3.80–3.83×** — and is not gated by the cache the same way:
the entry carries a **single** extension slot, and everything past it is fetched. `DOPC_EXT`
says 32.01 % of dispatches serve an extension word from the entry; the rest do not.

> **A denominator note, because this split is easy to get wrong and the capture's own summary
> did.** `MATRIX.md` §3 quotes the pair as 2.90–3.21 % and 11.03–12.29 %. Those low ends are
> shares of the total **including** `TAILSAMP`, while the high ends are ex-`TAILSAMP` — two
> different denominators inside one range. Ex-`TAILSAMP` throughout (this file's convention,
> §17.1), the figures are **3.12–3.21 %** and **11.85–12.29 %**, and they sum to row H's
> 14.96–15.51 % exactly. The `~4×` conclusion is unaffected either way; the range endpoints
> are not.

---

## 24. THE MAP v3.1 — the ladder re-ranked

> **⚠ SUPERSEDED BY §33.3.** This ladder was written before rungs 2 and 3 were built. Its row #1
> (accessors) **was built and returned +25.17 %** (§28); its row #2 (the fetch second pass) **was
> built on the served path and returned −0.05 %** (§29). The reclaim column here converts
> instruction counts to wall clock without asking whether the removed cost is latency-hidden,
> which §30 shows is the question that decides a rung. **Kept unedited** — the projections are
> what the outcomes are scored against.

### 24.1 The shares, both cadences

`19-STAGE-c1-profd.txt` and `19-STAGE-c4-profd.txt`, each swept from 57 to **its own**
ceiling (59.17 and 58.99). `TAILSAMP` excluded from the denominator.

| bucket / group | v3 @39 (r1b) | v3 @50 (r1b) | **v3.1 cadence 1** | **v3.1 cadence 4 (standing)** |
|---|---|---|---|---|
| **`LOOP` whole** | 26.38 % | 26.54 % | **24.59 – 23.69 %** | **29.55 – 28.80 %** |
| ‑ `LOOPRES` | — | — | **10.28 – 9.21 %** | 12.13 – 11.06 % |
| ‑ **`DOPCFIND`** | — | — | **11.45 – 11.65 %** | 13.32 – 13.65 % |
| ‑ `DOPCFILL` | — | — | **2.13 – 2.17 %** | 3.05 – 3.13 % |
| ‑ `BLKREC` | — | — | 0.73 – 0.66 % | 1.04 – 0.96 % |
| **`READ` + `WRITE`** | 17.01 % | 18.62 % | **19.59 – 20.35 %** | **23.12 – 24.13 %** |
| **`HANDLER`** | 16.77 % | 16.34 % | **18.06 – 18.19 %** | 19.41 – 19.68 % |
| **`FETCHOP` + `FETCHEX`** | 14.50 % | 15.81 % | **14.96 – 15.51 %** | 16.41 – 17.06 % |
| **`TAILPOLL`** | 15.14 % | 16.02 % | **17.91 – 18.47 %** | **6.87 – 6.81 %** |
| **`TAILADV`** | 8.06 % | 4.21 % | **1.28 – 0.00 %** | 1.31 – 0.00 % |
| **`XLATE` + `WALK`** | 1.58 % | 1.82 % | **1.84 – 1.94 %** | 2.66 – 2.80 % |
| `TAILSPEC` | — | — | 1.64 – 1.72 % | 0.49 – 0.52 % |
| *`TAILSAMP` (instrument)* | *5.97 %* | *5.40 %* | *7.41 – 7.38 %* | *8.06 – 8.08 %* |

**§10.1 applies unchanged**: these are shares of the *distorted* machine, and the fetch and
accessor buckets remain inflated relative to lean. **§18.1 is partly answered** — this is a
profile of the 1c-plus-1d build, so the "reverted 1b arms" caveat is gone; the profiling
build's own distortion is not.

### 24.2 The ladder

**Amdahl against 5589.0 dhry/s at cadence 1 and 6539.0 standing** (§20.1). The share column is
measured; **the reclaim column is not, and §10.6 governs it exactly as before.** Rows are
ranked by expected value at cadence 1, which is **not** the order of the share column — and
that divergence is the whole point of v3.1.

| # | rung | buckets | **measured share (c1)** | reclaim (**est.**) | time won | speedup | **dhry @5589** | **dhry @6539 (c4 share)** |
|---|---|---|---|---|---|---|---|---|
| **1** | **accessor inlining (dcache)** | READ + WRITE | **19.59 – 20.35 %** | 40 % | 7.84 – 8.14 % | 1.085 – 1.089× | **6064 – 6084** | **7205 – 7238** |
| **2** | decoded-op cache, second pass | FETCHOP + FETCHEX | **14.96 – 15.51 %** | 40 % | 5.98 – 6.20 % | 1.064 – 1.066× | **5945 – 5959** | **6998 – 7018** |
| **3** | handler specialisation | HANDLER | **18.06 – 18.19 %** | 25 % | 4.51 – 4.55 % | 1.047 – 1.048× | **5853 – 5855** | **6872 – 6877** |
| **4** | `LOOPRES` — the true dispatch residue | LOOPRES | **10.28 – 9.21 %** | **withheld** | — | — | — | — |
| **5** | **`DOPCFIND` — the hit-path walk** | DOPCFIND | **11.45 – 11.65 %** | **5 – 15 %** | 0.57 – 1.75 % | 1.006 – 1.018× | **5621 – 5688** | **6583 – 6676** |
| **6** | ATC fast path | XLATE + WALK | **1.84 – 1.94 %** | 60 % | 1.10 – 1.16 % | 1.011 – 1.012× | **5651 – 5655** | **6645 – 6651** |
| — | *interrupt-poll cadence* | *TAILPOLL* | *17.91 – 18.47 % (c1)* | — | — | — | ***banked*** — cadence 4 standing, +17.00 % measured | |
| — | *tail residue* | *TAILADV* | *1.28 – 0.00 %* | — | — | — | ***RETIRED*** — §22.5 | |
| **J** | the residual only a JIT reaches | LOOP+FETCH\*+TAILADV+TAILPOLL+TAILSPEC | **60.4 – 59.4 %** | 90 % coverage | 54.3 – 53.5 % | 2.19 – 2.15× | **12 241 – 12 007** | **12 864 – 12 544** |

### 24.3 The honest reclaim rationales, rung by rung

**This column is where a re-ranking is won or faked, so each one says what it rests on.**

* **#1 accessors, 40 %.** The share is the freshest number on the page and it **grew** —
  17.01–18.62 % in v3 to 19.59–20.35 %, and to **23.12–24.13 % in the standing posture**,
  where it is the largest attackable group by a wide margin. It grew because rung 1 removed
  fetch work from the denominator and cadence 4 removes poll work. The 40 % is v2's estimate,
  carried unchanged and *not* re-derived — but §25.1 shows it is the one reclaim on this page
  with a measured mechanism underneath it rather than an analogy.
* **#2 fetch second pass, 40 %.** Carried from v3. **This is the shakiest 40 % here**: rung 1
  already took the first pass at this bucket, and a second pass on an attacked bucket does not
  inherit the first pass's reclaim. The share is real; treat the projection as an upper
  bound. **The physical-index study lives inside this rung** — it buys miss rate, and miss
  rate is what `FETCHOP` is now gated on (§24.4).
* **#3 handler, 25 %.** Carried from v2/v3 unchanged. `HANDLER` is 92.8 corrected cyc per
  guest instruction across 184 660 027 spans — a genuinely large, genuinely diffuse bucket,
  and 25 % reflects that no single mechanism has been named for it.
* **#4 `LOOPRES`, withheld.** v3 withheld `LOOP`'s reclaim because its contents were
  unenumerated. **They are now enumerated, and the residue is still unenumerated** — `LOOPRES`
  is what is left after three brackets were carved out of it, and nothing says what it is.
  **The withholding stands, and for the same reason.** For scale only, and not as a
  projection: at a 40 % reclaim it would be 3.7–4.1 % (dhry 5803–5829). That number is
  illustration, not forecast.
* **#5 `DOPCFIND`, 5–15 %.** **This is the rung whose identity §21 changed, and the honest
  answer is that its reclaim is small.** The reasoning is in §25.2; the short form is that
  **56.7–58.8 measured cycles against 50–57 counted ARM instructions means the path already
  runs at about one instruction per cycle.** There is no stall pool to reclaim — reclaim is
  bounded by *instructions removed*, and the named candidates are worth 1–4 instructions each
  on a 50-instruction path. **#1 by share, #5 by expected value.**
* **#6 ATC, 60 %.** Carried; unchanged in kind, and still small.
* **Row J, 90 % coverage.** It **fell** — 63.1–64.5 % in v3 to 60.4–59.4 % at cadence 1 — almost
  entirely because `TAILADV` collapsed from 8.06 % to ~0. At cadence 4 it is 54.6–53.2 %. Read
  it as *unchanged in kind*: a JIT is still worth roughly twice the ladder's leading rung.

### 24.4 The physical-index study, scored against its now-priced bar

> **⚠ RE-SCORED — see §38.** Two of the inputs below moved in opposite directions and very nearly
> cancel: the fill price is refuted **upward** (§38.1), making each removed miss worth 6–15 %
> more, while this section's *own* calibration point — rung 1c's measured response — says the
> miss/invalidation slope is **0.70, not the 1.0 the headline row uses** (§38.4), cutting the
> removable fraction from 50.96 % to ~35.7 %. The re-derived ceiling is **1.7 – 2.7 %**, which
> brackets the ~2.2 % below. **Kept unedited.**

§17.3 named the prize and stated the bar; §22.3 and §22.6 supply both sides. Here is the
arithmetic, with its load-bearing assumption named.

**The prize.** `IV_FLUSH` is **50.96 %** of the 41 594 requests that reach the invalidator on
the cache-off dhry window (46.70–63.89 % across v3's three workloads) and is the one cause
carrying a namespace a physical index could match. `IV_PFLUSHA` — the other 36.73 % — carries
nothing and is unreachable by this or any tag-based narrowing.

**The assumption**: that misses are re-warm and roughly proportional to invalidations. It is
not free, but it is *calibrated* — rung 1c removed 49.68 % of dhrystone's invalidation
requests at a call site and moved the hit rate **+7.84 points** (77.48 % → 85.32 %). So a
second ~51 % removal buying another ~7–8 points is an interpolation of a measured response,
not a guess.

**The arithmetic** (`19-STAGE-c1-profd.txt`: 93 093 757 dispatches, 15 901 555 misses, hit
rate 82.92 %; `DOPCFILL` 61.8–63.9 cyc/miss; `FETCHOP` **93.0** corrected cyc/miss at 57):

| if a *free* physical index removed… | misses | hit rate | cycles saved | **of runtime** | dhry @5589 |
|---|---|---|---|---|---|
| all `IV_FLUSH`-driven misses (50.96 %) | 15.90 M → 7.80 M | 82.92 % → **91.62 %** | 1254 – 1272 M | **2.44 – 2.48 %** | **5729 – 5731** |
| a conservative 40 % | 15.90 M → 9.54 M | → 89.75 % | 985 – 998 M | **1.92 – 1.94 %** | 5698 – 5700 |

> **THE VERDICT ON THE BAR: the study's ceiling is ~2.5 % of dhrystone, and that ceiling
> assumes the index is FREE.** It is not free — §17.3's bar is that it costs a translation on
> the fill path, and §22.3 now prices that path at **62–64 cycles**. A translation costing even
> 15 cycles on the 7.8 M remaining misses gives back ~0.23 %, taking the realistic figure to
> **~2.2 %**. **So the physical index is a real but second-order win, not the top of the
> ladder** — it is worth less than handler specialisation (4.5 %) and about a quarter of the
> accessors (7.8–8.1 %). It also remains the exact cost class that failed rung 1b twice.
>
> **This does not kill it; it prices it.** It stays inside rung #2 as the miss-rate half of
> the fetch second pass, and it must still pre-register its cost site. A design that pays the
> translation only on a miss that was going to walk anyway starts above the bar; one that adds
> work to every fill is spending a measurable share of a 63-cycle path for at most 2.5 %.

---

## 25. THE RECOMMENDATION

> **⚠ TAKEN, both halves.** §25.1 was built as rung 2 and **KEPT at +25.17 %** (§28) — including
> its misaligned-read question, which closed as a denominator defect (§28.3). §25.2's counter
> change landed, its print defect was found and fixed on metal, and its verdict is **way0
> 63.39 %: the rung STAYS at #5** (§32.1). **Kept unedited**; the current recommendation is
> §33.4.

> ### Build the accessor fast path (rung #1). Take the `DOPCFIND` way-histogram as a counter change alongside it — not as a rung.

**Why this and not `DOPCFIND`**, in one line: §21 made `DOPCFIND` the largest *named* thing in
the dispatch loop, and §24.3 shows its hit path is already tight enough that the largest
honest projection is **+1.8 %** — against **+7.8 to +8.1 %** for the accessors at cadence 1 and
**+9.3 to +9.7 %** in the standing posture. **A bucket being newly visible is not the same as
it being newly attackable.**

Both briefs below are written to be dispatched as-is, in §11's shape, and both pre-register
their numbers **before** anything is built.

### 25.1 FIRST — the accessor fast path (`READ` + `WRITE`)

**The measurement that motivates it.** From `19-STAGE-c1-profd.txt`, at 57 cyc/transition:

| | value |
|---|---|
| `READ` corrected | 5 070 029 392 cyc over 39 738 605 guest reads = **127.6 cyc/read** |
| `WRITE` corrected | 4 298 529 729 cyc over 30 246 609 guest writes = **142.1 cyc/write** |
| combined | **133.9 corrected ARM cycles per guest data access** |
| `dpagecache` read hit | **99.21 %** (27 540 685 / 220 175) |
| `dpagecache` write hit | **99.35 %** (19 976 881 / 130 004) |
| misaligned **reads** | **20.71 %** of reads (8 231 131 of 39 738 605) |
| misaligned writes | 0.12 % of writes (36 675) |

> **This is the argument, and it is a measurement rather than an analogy.** At a **99.2–99.4 %**
> tier-0 page-cache hit rate, essentially every guest access is already being served without
> calling `mmu_translate` — and it still costs **~134 ARM cycles**. **The cost is therefore not
> translation; it is the scaffolding around a hit.** That is precisely what inlining removes,
> and it is why this rung's 40 % is the best-founded reclaim on the page rather than the
> carried-over guess it looks like in the table.

**And it names a second, independent target inside the same bucket: one guest read in five is
misaligned** (20.71 %), against one write in 800. A misaligned read is a split access on this
path. That asymmetry has never been explained and it is a large sub-path — the map has no
statement about it, which makes it the bucket's own §15.4.

**Where.** Firmware side, `Z3660_emu/src/uae/newcpu.cpp` and the `x_get_*` / `x_put_*`
accessor family, at the `dpagecache` hit path — the sites that today read
`Z3660_PROF_ENTER(Z3660_PROF_B_READ)` / `_B_WRITE`. **The cost site to pre-register is the hit
path**, which per §17.3's rung-1c bar is exactly the path a change here must not grow.

**Pre-registered expected gain.** Judge against these, not against whatever it produces:

| | share attacked | at 40 % reclaim | at 25 % (pessimistic) |
|---|---|---|---|
| dhry cadence 1 (5589.0) | 19.59 – 20.35 % | **6064 – 6084** | 5877 – 5889 |
| dhry cadence 4, standing (6539.0) | 23.12 – 24.13 % | **7205 – 7238** | 6940 – 6959 |

Pre-register three numbers:

* **dhry cadence 4 ≥ 6900** — a ~22 % reclaim, below the estimate and far above the rig's
  0.00–0.32 % within-arm spread;
* the stage profile re-taken afterwards must show **`READ` + `WRITE` below 17 %** at cadence 4
  — the check that the time went away from where the profile said it was, not merely that a
  wall clock moved;
* **`DOPCFIND` and the `dpagecache` hit rates must not move** — if the hit rates change, the
  change altered *what* is being cached and the speed comparison is not like-for-like.

**The expected failure mode, pre-registered**: *the accessors get faster and dhrystone does
not move, because the removed scaffolding was already overlapping with guest-DRAM latency.*
`READ`/`WRITE` are the two buckets in which a real bus access lives, and unlike the
decoded-op hit path they are **not** at one instruction per cycle. If that happens, the next
thing to read is the misaligned-read share, not the hit rate.

**Harness guard shape.** Host harness (`Z3660_emu/test/host`), driving the accessors directly:
**state equivalence, not spot checks** — for a corpus of start states, run each access
inlined and out-of-line and assert register file, affected memory, fault outcome and guest PC
are byte-identical. Mandatory cases: a misaligned access **crossing a guest page boundary**
where the *second* page is unmapped (the fault must arrive at the same guest PC with the same
fault address, because the 68040 uses full instruction restart); supervisor and user space; an
access to a destination that is **not plain RAM**, which must fall back rather than fast-path
a device write; and an access whose page is invalidated between the cache lookup and the use.

**Risk.** Fault semantics first — this is the class that corrupts a filesystem rather than
merely being slow, and this repository has paid for the general lesson once (a page-crossing
DMA that clipped an unrelated frame, invisible until it ate an ELF header). **Never fast-path
across a page boundary.** Second: I-cache footprint. Inlining an accessor at every call site
grows `m68k_run_mmu040`, which is **572 ARM instructions** today; the run loop competing with
itself for the ARM's caches is a real regression path and the reason the pre-registration
includes a profile re-take rather than only a wall clock.

### 25.2 SECOND — the `DOPCFIND` way histogram: a COUNTER CHANGE, not a rung

**Do not build a way-prediction optimisation yet. Measure the way-hit distribution first.**

**Why it is not yet a rung.** From `Z3660/docs/decoded-op-cache.md`, "The hit path, counted"
(lean `objdump`, counted rather than estimated): hit → dispatch is **50 ARM instructions** at
way 0 with an extension word served, **44** without one, and **52 / 55 / 57** at ways 1 / 2 / 3.
§21 measures the same path at **56.7–58.8 corrected ARM cycles per dispatch**. **~57 cycles
against ~50–57 instructions is about one instruction per cycle**, so:

| candidate | what it could remove | honest ceiling |
|---|---|---|
| way prediction / last-way hint | the way walk: 7 instructions end to end (50 → 57) | if hits were uniform across ways, mean 53.5 → 50 = **6.5 % of the bucket** — *before* charging the hint check (≥ 2 instructions on **every** dispatch), which gives most of it back. **If hits are already way-0-dominated it buys zero.** |
| smaller tag compare | at most one load + one compare per way probed | 1–2 instructions of 50 |
| alignment of the probe | scheduling only | ~0 — it moves cycles only if the path is *not* at IPC 1, and it measures at IPC ≈ 1 |

> **The reclaim is bounded by instructions removed, not by scheduling, and the candidates are
> worth 1–4 instructions each on a 50-instruction path. 5–15 % is the honest band, and
> 11.45–11.65 % × 5–15 % is +0.6 % to +1.8 % of dhrystone.** That is smaller than the ATC rung
> and smaller than the error bar on some of the shares above it.

**And the whole band turns on one unmeasured quantity: how hits distribute across the four
ways.** Nobody has measured it. **That is four counters** — one per way, incremented in the
existing lookup, appended to the id space (which is append-only; a reordering silently
relabels every previous capture). It is the same class of cheap instrument change as the
`LOOP` split that produced §21, and the same class as `IV_CACR_SKIP`.

**Pre-registered decision rule**, written before the histogram is taken:

* **way-0 share ≥ 85 %** → the walk is already short, way prediction is worth < 0.5 %,
  **and the rung is struck from the ladder**;
* **way-0 share ≤ 60 %** → the walk is real, the 6.5 % ceiling is live, and the rung earns a
  design round with its cost site (the hint check, on every dispatch) pre-registered;
* **in between** → it stays where §24.2 puts it, at #5, behind three rungs worth 4–8 % each.

**Cost to take it: one counter block on one prof-image boot** — the same capture that scores
§25.1 can carry it. There is no reason to spend a separate session.

---

## 26. What v3.1 does **not** establish

§10 and §18 apply unchanged and are not repeated. Five things are new.

### 26.1 The reclaim column is still estimates, and now it is load-bearing in a new way

§10.6 governs every reclaim fraction here. **v3.1 makes this sharper rather than softer**: the
re-ranking in §24.2 is driven by a *reclaim* argument (§25.2's IPC-1 reasoning), not only by
measured shares. The IPC-1 observation is an inference from two measured quantities — 56.7–58.8
cycles and 50–57 counted instructions — taken from **two different builds** (the prof build
measures the cycles; the lean `objdump` counts the instructions). That is the right direction
for the argument (the prof build is *slower*, so the true lean IPC is if anything closer to 1),
but it is not a single measurement, and **§25.2's way histogram is what would turn it into
one.**

### 26.2 Two pre-registrations were withdrawn rather than scored, and one band was mis-specified

* §19 item 1's **10–13 % band and 12.64 % bar are withdrawn** as refuted-method artefacts
  (§23.3) — they were built on `2 × IFETCH_CALLS`, which §16.1 retires. A withdrawn bar is not
  a passed bar, and row H is scored only against the span-measured series.
* §19 item 3's **1.8–3.8 % band was structurally unscoreable** (§23.1): a console switch cannot
  reproduce a build difference. Recorded as a MISS with its cause, not softened.
* §18.2 therefore **stays open**. Rung 1c's +2.80 % is not defended against drift by any
  measurement taken to date, and the experiment that would defend it has not been run.

### 26.3 What is owed to the Z3660 lane

Three items, all documentation or instrument, none a firmware bug. **They will keep firing
correctly on correct builds until the statements are fixed**, which is the failure mode worth
avoiding — a warning that is always wrong teaches operators to ignore warnings.

1. **`docs/profiler.md`: `tcnt[DOPCFILL] == DOPC_MISS` needs a fault term.** The bracketed
   functions cannot throw; the *interval the identity spans* can (`x_prefetch(0)` at
   `newcpu.cpp:5901`, between the `DOPCFIND` exit at `:5899` and the `DOPCFILL` entry at
   `:6082`). Exact form and evidence in §21.2. Same class and same shape of fix as §16.3's
   `== INSNS + FAULTS`.
2. **`docs/profiler.md`: `tcnt[BLKREC] <= tcnt[DOPCFIND]` is stated about calls but compares
   spans.** `BLKREC` is impure by the doc's own description; on a fire its spans are ~200 per
   chunk. It passes on cache-on dumps by accident of the 4× dispatch count and fails correctly
   on a cache-off arm (§21.2).
3. **The price bracket should carry a ceiling.** The firmware knows `acc[b]` and `spans[b]` and
   could refuse to advertise an in-bucket end above `min_b(acc[b] / spans[b])`, or at minimum
   print that ceiling beside the bracket. This session's bracket moved **+42 %** against the
   last and **its advertised upper end was arithmetically impossible** (§20.2). Sweeping to the
   printed end is a trap the doc's current method walks into.

### 26.4 What was not taken

Ring dumps (`PROF RING`), the **disk row** of the same-boot A/B, and an install-workload
profile — all out of scope by dispatch, all still open. The disk row is the reason §22.1
closes §18.3 *for dhrystone only*.

**And §19 item 5's original question is still open, which the §22.2 result can disguise.**
Item 5 asked for a boot-window A/B to resolve the **lean cadence-4 boot reading 52 s against
rung 0's 43 s**, confounded with the rig's ~9 % cross-session drift. §22.2 is a *cache* A/B on
the *prof* image, and the lean 52 s reproducing for a fourth session says the current build is
**stable**, not that the 43 s was drift. **Neither measurement answers the 52-vs-43 question**;
it needs a same-session lean pair across the two builds, which is the same two-flash shape
§23.1 needs and could share a session with it.

### 26.5 The ledger of refuted claims — v3.1's additions

Per `docs/METHOD.md` §8, appended to §18.4. Nothing is deleted.

| claim | where | status |
|---|---|---|
| **"`LOOP` is the largest bucket and its contents are unknown"** | **v3 §15, §17.2 rung 1** | **SUPERSEDED by enumeration.** `DOPCFIND` is 11.45–11.65 % of it; the true residue is 9.2–10.3 %. §21. |
| §15.4's re-attribution hypothesis | v3 §15.4 | **SUPPORTED.** `FETCHOP` spans track `DOPC_MISS`, so a hit's fetch cost is charged to `DOPCFIND`. §21. |
| `TAILADV` as rung 5, 4.2–8.1 % | v3 §17.2 | **RETIRED.** 0–1.3 % on this instrument; it binds the price ceiling and is essentially all probe. §22.5. |
| row H's 10–13 % band and 12.64 % bar | v3 §19 item 1 | **WITHDRAWN** — built on the `2 × IFETCH_CALLS` method §16.1 refutes. §23.3. |
| "expect row H low, because the hit rate came in above band" | v3 §19 item 1 | **REFUTED.** Hit rate 82.92 %, row H flat. `FETCHEX` is ~4× `FETCHOP` and is not gated by the cache the same way. §23.3. |
| a same-boot `DOPC` A/B defends rung 1c's +2.80 % | v3 §19 item 3 | **REFUTED — structurally.** `DOPC` is a whole-cache toggle; +2.80 % is a build difference. Needs a two-flash A/B. §23.1. |
| MMU-on → TCP as "the boot window" | v3 §19 item 5 and every boot figure | **AMENDED** to Emu-mode-4 → TCP. The old window understates the cache's effect by 3.6×. §23.2. |
| the map's **5.17 MB/s** kernel zero-fill figure | v2 §9.7 | **SCORED at last** — the fast path runs at **≥ 123–127 MB/s**, ≥ 24× the model. §22.4. |
| the printed in-bucket end of the price bracket is safe to sweep to | firmware `docs/profiler.md`; this file's own method | **REFUTED.** The advertised 68 is above the 59.17 arithmetic ceiling. §20.2. |
| `tcnt[DOPCFILL] == DOPC_MISS` | firmware `docs/profiler.md` | **UNDERSTATED** — needs a fault term. §21.2. Doc fix owed upstream. |
| `tcnt[BLKREC] <= tcnt[DOPCFIND]` | firmware `docs/profiler.md` | **MIS-STATED** — a property about calls, compared over spans. §21.2. Doc fix owed upstream. |

---
---

## 13. What v3 is

### 13.1 The arc, in one table

Four changes were built against the v2 map between 2026-08-22 evening and 2026-08-23 morning.
Three shipped and one was taken back and decomposed. **Every row here is metal.**

| rung | what | verdict | the number that decided it |
|---|---|---|---|
| **0** | block-idiom fast path (`bzero`/`mcpy`/`CPUSHL` recognizer) | **KEPT** | boot's AMIX phase **110 s → 62 s, −43.6 %**, for a dhrystone tax of **−0.83 %** |
| **1** | decoded-op cache, 4096 entries | **KEPT** | lean dhrystone **4405.3 → 5432.0, +23.3 %** ship-vs-ship |
| **1b** | invalidation narrowing, three arms | **REVERT — pre-registered, and fired** | **5306.0** against a revert line of 5432; crossed by 2.32 % |
| **1c** | 1b decomposed: two arms reverted, one kept | **KEPT** | **5584.0**, +2.80 % on rung 1 and +5.24 % on rung 1b |

Cumulatively, at cadence 1: **4405.3 → 5584.0 dhry/s, +26.8 %.** In the standing posture
(cadence 4): **5106 → 6516.5, +27.6 %.**

### 13.2 Provenance

| session | evidence directory | what it holds |
|---|---|---|
| rung 0 | `2026-08-22-c2-blk-verdict` | `MATRIX.md`, `NOTES.txt`, the boot windows, the four-arm A/B |
| rung 1 | `2026-08-23-dopc-verdict` | the four-state sweep, the last `2 × IFETCH_CALLS` stage bracket |
| rung 1b | `2026-08-23-r1b-verdict` | **the only span-measured stage profile**, and the `IV_*` cause block |
| rung 1c | `2026-08-23-r1c-verdict` | the verdict row, `IV_CACR_SKIP`, and the standing-posture pair |

Every number below cites the capture it comes from. `MANIFEST.txt` and `NOTES.txt` in each
directory come first; the firmware side is `Z3660_emu/src/uae/z3660_prof.h` plus
`docs/profiler.md`, `docs/decoded-op-cache.md` and `docs/block-idiom-fastpath.md` of the
Z3660 tree at `a1a360a`.

**Three things about the baseline, stated before any share.** The lean cadence-1 figure the
ladder is now scored against is **5584.0 dhry/s** and the standing (cadence-4) figure is
**6516.5**; v2 ranked against 4486. The 4486 → 4405.3 step between the v2 session and the
rung-0 session is **cross-session drift, not a regression** — the rig reproduces to about
±1–2 % across flashes, and rung 0's own OFF arm reproduced the pre-change boot baseline *to
the second*. And **rung 2 of the v2 ladder is already banked**: the standing posture runs
`service_cadence 4`, and 6516.5 against 5584.0 is **+16.70 %** measured on one session, one
build, two runtime settings — against v2's predicted 1.109×.

---

## 14. The four rungs, as built

### 14.1 Rung 0 — the block-idiom fast path: KEPT

**Boot −43.6 %, dhrystone −0.83 %.** The AMIX phase of boot — MMU-enable to the first guest
TCP accept — went **110 s → 62 s**, with the OFF arm reproducing the pre-change baseline
exactly (`c2-blk-verdict/MATRIX.md`; boot windows `boot1-prof-bootwindow`,
`boot2-BLKOFF-bootwindow`). Two other boot definitions from the same arms: ring span
163.2 s → 132.6 s (−18.7 %), arm-to-first-TCP 154 s → 108 s (−29.9 %). The −43.6 % is the
one that names a phase rather than an operator's stopwatch.

The tax is small and was measured three ways: lean cadence-1 ×3 **4442.0 → 4405.3
(−0.83 %)**, profiling interleaved 3152.5 → 3092.0 (−1.92 %), profiling with the sampler
3120 → 3065 (−1.76 %). Dhrystone spends 56.7 % of its time in its own hot loop, where
`bzero` is 0.52 %, `mcpy` 1.49 % and `lcolloop` 0.61 % — so the workload the tax is measured
on is the workload the fast path cannot help.

**Utilisation, with the correction the obvious arithmetic gets wrong.** `BLK_INSNS` is not a
subset of `INSNS`: a chunk is one retirement through the run-loop tail and many guest
instructions, so the guest stream is `(INSNS − BLK_HIT) + BLK_INSNS`.

| capture | `BLK_HIT` | `BLK_INSNS` | `BLK_BYTES` | reconstructed stream | **share** | literal ratio | mean chunk |
|---|---|---|---|---|---|---|---|
| boot | 239 255 | 106 638 294 | 310 303 148 (295.9 MiB) | 286 274 221 | **37.25 %** | 59.28 % | **445.7** |
| dhry | 42 263 | 12 714 482 | 39 360 484 | — | **10.42 %** | — | 300.8 |

The map predicted **31.80 %** of a boot for stages A+B+C and **10.57 %** of the dhrystone
window; measured 37.25 % and 10.42 %. The literal ratio would have read **59.28 %** — outside
the range in which the prediction could be judged at all, which is why the reconstruction is
not a refinement but the only arithmetic that answers the question. The reconstruction
cross-checks against the pre-change session's directly measured 276.65 M guest instructions,
3.5 % apart. The mean chunk length of 445.7 clears the ~8 floor by two orders of magnitude:
the recognizer test is amortised, which is the difference between firing and firing usefully.

The OFF arms are true pass-through (dhry `0 / 0 / 0`; boot `1 / 92 / 184`), so the switch is
a real A/B and not a partial one.

**What rung 0 did NOT clear, kept because a pre-registration is only worth what its misses
are worth:**

* the **dhrystone row MISSED**: the pre-registration asked +8.4 % and got −0.8 %;
* the **disk row is unscoreable, not merely missed** — its baseline was taken on the
  *profiling* build, so the pre-registration compared a prof baseline against a lean target.
  Against this session's own lean OFF arm (1106.4 kB/s) the fast path scores **−0.38 %**;
* the **`bzero` bench guard missed by 1.1 points** — 22.07 % → 4.08 % raw / 4.46 % busy, a
  **79.8 % reclaim** against the map's own 80 % model, and a `< 3 %` threshold that the same
  model makes unreachable (perfect success is 4.42 %). **The threshold was wrong, not the
  change**;
* `probe_cyc` came back at **32**, below the 45–51 band the pre-registration named.

**Still unscored:** no MB/s figure was ever computed from `BLK_BYTES`, so the map's
**5.17 MB/s** kernel zero-fill claim — the number this rung exists to move — has never been
tested. `EXPECTATIONS.txt` declined to gate it, deliberately. It is one division away and it
is on the next session's list (§19).

### 14.2 Rung 1 — the decoded-op cache: KEPT, and the tax reversed

**+23.31 %, ship against ship**: lean, cadence 1, cache and fast path both on, **5432.0**
against rung 0's **4405.3** (`dopc-verdict/31-DELTAS.txt`). The same-boot switch delta is
+41.57 % and **overstates the rung**, because its own baseline already carries rung 1's
always-paid overhead; the ship-vs-ship figure is the one that decides.

**The tax reversed, and the mechanism is legible.** A four-state sweep separated the two
changes:

| | cache OFF | cache ON |
|---|---|---|
| fast path OFF | 2532.0 | 3396.5 |
| fast path ON | 2477.0 (**−2.17 %**) | 3442.5 (**+1.35 %**) |

Without the cache the recognizer costs −2.17 %, reproducing rung 0's own −1.9 % profiling-build
tax. **With the cache on the same recognizer gains +1.35 %** — a hit that says "not an idiom"
skips it in 2 ARM instructions instead of 14. **Rung 0 is now free on workloads that never
collect from it.**

**Both hit-rate bars were missed**, and that is the row that mattered:

| workload | hit rate | pre-registered | |
|---|---|---|---|
| boot | 69.76 % | (model said 92.40 %) | |
| dhrystone | **77.48 %** | ≥ 88 % | **MISS** |
| raw disk | **67.74 %** | ≥ 85 % | **MISS** |

`DOPC_EXT` says the second half of the rung was reached: 41.5 % of fetch words on dhrystone,
26.1 % on boot and disk. And the misses are **re-warm, not capacity** — 274–292 misses per
invalidation across three unrelated workloads, against a 4096-entry cache. A figure that does
not track the workload's code footprint is not a capacity miss, and the indicated fix is a
narrower invalidation rather than a bigger cache. That reading is what dispatched rung 1b.

**`FETCHOP + FETCHEX` cleared its gate at every price**: 28.65 % → **12.64 % raw, 11.27 % at
32 cyc/transition, 10.48 % at 43**, against a pre-registered `< 18 %`. `FETCHOP` fell from
17.34 % to 4.25 % by construction on every hit; `FETCHEX` from 11.31 % to 8.39 % through the
entry's single extension slot.

Two findings that were not about the rung:

* **`DOPC_INVAL` moves with the cache OFF** (164 311 and 2 951 874 in the two off arms), which
  the firmware's own doc said it did not. A documentation defect, fixed upstream since.
* **The cache-off arm costs ~12.9 % on this build** (3837.0 against 4405.3). The switch is an
  **A/B instrument, not a safe production fallback**, and it should not be described as one.

### 14.3 Rung 1b — built, REVERT fired, decomposed

Rung 1b narrowed the cache's invalidation, in **three arms**: an empty-cache short-circuit, a
page-presence filter, and a `MOVEC`-to-CACR narrowing at the call site. The pre-registration
named the losing branch in advance, in the doc's own words — *"a result below 5432 means the
narrowing cost more than it saved and the filter should be reverted, not tuned"*:

```
>= 5550          HIT
5432 .. 5550     MISS (below band, but the narrowing did not cost anything)
<  5432          REVERT
```

**Measured 5306.0** (5309 / 5308 / 5301, spread 0.15 %). The revert line was **crossed by
2.32 %**, and it was reported as REVERT rather than softened into "roughly flat". Decomposed:
cache ON 5432.0 → 5306.0 (−2.32 %), cache OFF 3837.0 → 3776.0 (−1.59 %), leaving a
**cache-specific residue of about −0.73 %**.

And the hit rate went **up** while the speedup went down: dhrystone 77.48 % → 84.56 %, and the
ON/OFF ratio fell from +41.57 % to +40.52 %. **+7.08 points of hit rate bought −1.05 points of
speedup.**

#### 14.3.1 The namespace lesson

`IV_FLUSH` + `IV_PFLUSHA` is **91.0 % of boot, 87.5 % of dhrystone and 82.3 % of raw disk** of
all invalidation requests — and **neither can be narrowed against a logical tag at all**.
`CPUSHL`/`CINV` carry a physical address; `PFLUSHA` and a `TC` write carry nothing. The single
cause the page-presence filter was built for, `IV_PFLUSH`, is **6–9 %**.

> **A narrowing needs a namespace to narrow against, and 82–91 % of this traffic has none.**
> The filter was built for the 6–9 %, and charged the other 91–94 % for the privilege.

That is a design conclusion available *before* building, from one counter block, and it is
the reason the `IV_*` block exists at all: the rung-1 verdict measured 274–292 misses per
invalidation and could not say *which* invalidation, so a narrowing aimed at the wrong cause
was a correctness risk taken for nothing.

#### 14.3.2 The fill-path lesson

The two arms that lost put their cost **on the fill path**: two filter marks and a flag store
on every fill, plus 512 B of BSS. The arm that won put its cost at a **call site** — one
compare, on neither the hit path nor the fill path.

The controlled pair is what makes this a finding rather than an anecdote, and it needed rung
1c to complete:

| | hit rate vs rung 1 | speed vs rung 1 |
|---|---|---|
| rung 1b (fill-path cost) | **+7.08 pp** | **−2.32 %** |
| rung 1c (call-site cost only) | **+7.84 pp** | **+2.80 %** |

> **Hit rate is not what pays. The fill-path cost is.** Rung 1c is the control case: the same
> high hit rate, the fill-path cost removed, and the speedup arrives.

#### 14.3.3 And an instrument lesson, which produced a counter

Rung 1b briefly defined the narrowing's yield as `sum(IV_*) − DOPC_INVAL`. **That is false for
any narrowing implemented at a call site**: the CACR compare lives ahead of the invalidator,
so an inert write increments *nothing at all* — it is not a skipped request, it is an
uncounted one. The session measured a **54.8 % fall in invalidations that the row could
account for only 7.3 % of** (3 252 counted against ~40 995 uncounted), and reconstructed the
rest by hand across two sessions' captures.

> **A narrowing that decides before the invalidator must bring its own request counter, or it
> is invisible to its own verdict.**

That is counter id 38, `IV_CACR_SKIP`, and it is deliberately *outside* the cause block — every
entry there means "reached the invalidator", which this one does not.

### 14.4 Rung 1c — the decomposition: KEPT

Rung 1c reverted the two fill-path arms and kept the call-site one. **5584.0** (5581 / 5588 /
5583, spread 0.125 %): **+2.80 % on rung 1**, **+5.24 % on rung 1b**, +26.76 % on rung 0.
Six pre-registered rows hit, two missed *above* their bands, one not taken.

**It is up at both cadences**, which is what separates a gain from a cadence artefact: rung 1b
was down 2.32 % at cadence 1 but flat-to-up at cadence 4, so its regression was a cadence-1
phenomenon; rung 1c is up at cadence 1 (+2.80 %) *and* at cadence 4 (6516.5, +1.23 % on rung
1's 6437.5).

**Both hit-rate bands were missed from above** — boot 72.83 % (band 70–74, HIT), dhrystone
85.32 % (band 78–82), disk 75.53 % (band 69–73) — and the bands' *reasoning* is what the
session refuted. All three rested on the expectation that reverting 1b's filters would give
back 1b's hit-rate gain. **It did not come back.** Two of three workloads came in above rung
1b. So **1b's hit-rate gain was the CACR arm's, all of it** — the page filter and the
short-circuit contributed none of it, and cost 2.32 % for the privilege.

**What one compare at a call site is worth**, from the counter that was added to see it:

| workload | requests the guest made | performed | narrowed at the call site |
|---|---|---|---|
| boot | 189 018 | 116 140 | **72 878 (38.55 %)** |
| dhrystone | 79 211 | 39 858 | **39 353 (49.68 %)** |
| raw disk | 82 553 | 48 797 | **33 756 (40.89 %)** |

Rung 1b removed 44 247 invalidations with three arms; **rung 1c removes 40 861 with one —
92.3 % of 1b's win, for one compare.**

---

## 15. §8.3 CORRECTED: `LOOP` is not empty, and it is the largest bucket on the page

**This supersedes §8.3 and §9.7's rung 7.** §8.3 concluded *"`LOOP` is empty… Two spans, two
exhaustion points, one answer: it is zero."* That conclusion was reached the only way it could
be at the time — by finding the price at which `LOOP`'s apparent share is *entirely* probe —
and it is **refuted by direct measurement**.

### 15.1 Why it could not be settled before

The dump reported one **global** transition count, so a per-bucket subtraction had to be
modelled, and `LOOP` is the bucket a model is worst at: it is the parent of eight nested
stages and pays one `exit()` for every entry of all of them. Rung 1's stage bracket could
therefore only report it as an **upper bound** — `≤ 33.90 %` at 32 cyc/transition and
`≤ 39.71 %` at 43 (`dopc-verdict/20-STAGE-bracket.txt`) — with the session's own note
recording that *"`LOOP`'s own probe load [is] not derivable"*.

### 15.2 What closed it

The firmware's rung-1b build added **per-bucket transition spans** (`[PROF] s`), which count
the spans *charged to* each bucket at exactly the two sites that charge them. A corrected
share stops being an interval:

```
corrected cyc for b  ==  acc[b] − spans[b] × probe_cyc          and     sum(spans) == TRANSITIONS
```

Measured on `r1b-verdict/19-STAGE-profd.txt` — dhrystone, buckets armed, cadence 1,
`TRANSITIONS` 800 774 653, `sum(spans)` 800 774 653 exactly, `STACK_OVF` 0, price bracket
**[39, 50]** from that boot's own three-pass calibration (`armed 105342, unarmed 23707, empty
2090, 1024 pairs`):

| | corrected `LOOP` share |
|---|---|
| rung 1 (`2 × IFETCH_CALLS` era) | 33.90 – 39.71 %, and those were **upper bounds** |
| **metal 2026-08-23, measured spans** | **24.80 % @39 .. 25.11 % @50** |
| *the same, ex-instrument* (the denominator §8.4 and §9 use) | **26.38 % .. 26.54 %** |

**A 0.31-point bracket in place of a 5.8-point interval of upper bounds**, and the block
self-checks. `LOOP` is not empty, it is not small, and **it is the largest single bucket in
the interpreter.**

`FAULT` is reported uncorrected and deliberately: an unwind charges it cycles and counts no
span, so it is over-reported — the safe direction, at 0.11 %.

### 15.3 Why the price question stopped deciding it

§8.3 chose 50 cyc/transition and bracketed to 59, and the whole argument turned on where
`LOOP` exhausts. It no longer turns on anything: across the *whole* measured bracket `LOOP`
moves by **0.31 points**. The firmware's own documentation had already said the exhaustion
argument was unsupported — even the top of the price bracket and the whole armed call sit
*below* the 50.59 at which §8.3's span exhausts `LOOP` — and the spans then measured it.

### 15.4 And a hypothesis about *why* it is large, which is testable and untested

`LOOP` is "run-loop bookkeeping outside every named stage". Raw shares across the three
sessions:

| | v2 (pre-rung-0) | rung 1 | rung 1b |
|---|---|---|---|
| `LOOP` raw | 18.84 % | 23.78 % | 24.20 % |
| `FETCHOP` raw | 11.95 % | 4.24 % | 3.25 % |

`FETCHOP` lost 8.7 points of raw share and `LOOP` gained 5.4. **Some of rung 1's win is a
genuine saving and some of it is a re-attribution**: with the cache on, a hit never enters
`FETCHOP` at all, so the decoded-op cache's own hit path — which is in the run loop and is not
bracketed — is charged to `LOOP`. If that is right, `LOOP` now *contains* the thing rung 1
added, and attacking `LOOP` means attacking rung 1's hit path.

**This is a hypothesis, not a finding.** Nothing in these captures distinguishes it from the
alternatives, and the test is cheap: one more probe bracket around the lookup, or a `LOOP`
breakdown, on the next prof-image boot. It is §19's item 4 for that reason, and it is the
single largest open question on this page.

---

## 16. The instrument moved too, and one method is retired

Three changes to how a share is computed, all landed in `tools/prof-symbolize.py` and
documented in `docs/PROFILER-SYMBOLIZE.md`. Each of them changes a number in this file.

### 16.1 The `2 × IFETCH_CALLS` bracket method is REFUTED, not merely bettered

Rung 1's stage bracket assumed the two ifetch buckets carried two transitions per
`IFETCH_CALLS` — one enter and one exit per call. Metal measured both quantities on the same
capture:

| | transitions charged to the ifetch buckets | of all transitions |
|---|---|---|
| assumed, `2 × IFETCH_CALLS` | 99 049 270 | 12.37 % |
| **measured spans** | **50 194 621** | **6.27 %** |

**The assumption over-charges by 1.97×**, so every corrected share derived from it was biased
**low** — including rung 1's `FETCHOP + FETCHEX` of 11.27 % @32 and 10.48 % @43.

**The mechanism is the decoded-op cache itself.** With the cache on a hit never enters
`FETCHOP`, so the bucket is entered once per **miss**: `FETCHOP` spans 15 547 429 against
`DOPC_MISS` 15 436 987, 0.72 % apart, against `IFETCH_CALLS` 49 524 635. `IFETCH_CALLS ==
FETCH` remains exactly true — all five bracket sites increment `FETCH` once — but **`FETCH`
stopped predicting bucket entries the moment something upstream began answering fetches
without entering the bucket.** Rung 1's own instrument could not have seen this, which is
precisely why the spans exist.

**Every bracket-method figure in this document is superseded where a span-measured one
exists**, and the symbolizer now prints the retirement in the report rather than leaving it in
a doc.

### 16.2 The probe price is a range, and it is swept rather than picked

The boot's three-pass calibration brackets the price: `marginal = (armed − unarmed) / 2N` is
the probe **bodies** (what `PROFB` gates), `in-bucket = (armed − empty) / 2N` adds the call
scaffolding that sits inside the buckets too. Neither is a correction of the other. §8.3
picked 50 and bracketed to 59; **that was a picked number, and 59 was above the price at which
the subtraction is arithmetically possible.**

The two sessions' brackets are **[39, 50]** (rung 1b) and **[40, 51]** (rung 1c) — against
rung 1's **[32, 43]** on the same board, a ~20 % shift between captures. **A capture is priced
from its own boot line, never from a table.** And nothing here should be compared against
45.5: that figure is v1's 91 cyc/pair halved, measured with the probes *inlined*, and it is a
whole-cost inlined quantity that neither end of this bracket bounds.

### 16.3 A dispatch identity the firmware's own doc understates

`docs/profiler.md` states `DOPC_HIT + DOPC_MISS == INSNS` with the cache on. **Twelve metal
captures across three sessions and three firmware builds put the sum above `INSNS` by exactly
`FAULTS`, every time, to the unit** — 7522, 3629, 3328, 7258, 3629, 7496, 3628, 3326, 3630,
7556, 3630, 3328, each matching its own dump's `FAULTS` exactly. The rung-1 session read the
gap as a live-print artefact of the dump loop; it is not.

The mechanism is plain once stated: a faulting instruction **consults the cache** — so it is a
dispatch — and then **throws before retiring through the run-loop tail** — so `INSNS` never
counts it. A difference that reproduces another counter in the same dump exactly, twelve
times, is a mechanism and not skew.

```
DOPC_HIT + DOPC_MISS  ==  INSNS + FAULTS
```

The symbolizer asserts this form. It is a doc fix owed to the firmware lane, not a firmware
defect.

---

## 17. THE MAP v3 — the ladder re-ranked

### 17.1 The shares

Measured on `r1b-verdict/19-STAGE-profd.txt`, the **only span-measured stage profile that
exists**, swept across that boot's own **[39, 50]** bracket. `TAILSAMP` is instrument cost and
is excluded from the denominator, as in §8.4, because it does not exist in the lean build.

| bucket / group | v2 (§8.4, modelled) | **v3 @39** | **v3 @50** | moved because |
|---|---|---|---|---|
| **`LOOP`** | 0.51 % ▼▼ | **26.38 %** | **26.54 %** | spans measured; §15 |
| **`HANDLER`** | 26.37 % | **16.77 %** | **16.34 %** | rungs 0 and 1 removed handler work |
| **`TAILPOLL`** | 19.61 % | **15.14 %** | **16.02 %** | cadence-1 profile; see the caveat |
| **`READ` + `WRITE`** | 19.83 % | **17.01 %** | **18.62 %** | re-derived, not carried |
| **`FETCHOP` + `FETCHEX`** | 28.65 % | **14.50 %** | **15.81 %** | rung 1 built; §14.2 |
| **`TAILADV`** | 2.48 % | **8.06 %** | **4.21 %** | spans; the price question still moves this one |
| **`XLATE` + `WALK`** | 1.87 % | **1.58 %** | **1.82 %** | unchanged in kind |
| *`TAILSAMP` (instrument)* | *— excluded —* | *5.97 %* | *5.40 %* | |

**Read the caveats on this table before ranking from it**, because two of them are large:

* **The profile is of the rung-1b build, two of whose three arms were reverted by 1c.** Those
  two arms charged the *fill* path, so `LOOP` and `HANDLER` carry a cost the shipped build
  does not. The direction is known (both shares are over-stated for the shipped build); the
  size is not.
* **It is a cadence-1 profile and the standing posture is cadence 4.** `TAILPOLL`'s cycles
  fall roughly fourfold at cadence 4 while its *spans* do not — the probe bracket wraps the
  whole tail macro, gate included — so **`TAILPOLL`'s 15–16 % is a cadence-1 number and rung 2
  is largely already banked** (§13.2: +16.70 % measured). Do not add it to the standing
  baseline.
* Everything §10.1 says still applies: these are shares of the *distorted* machine, and the
  fetch and accessor buckets remain inflated relative to lean.

### 17.2 The ladder

Amdahl against the new baselines — **5584.0 dhry/s at cadence 1**, 6516.5 standing. The share
column is measured; **the reclaim column is not**, and §10.6 governs it exactly as before.

| # | rung | buckets | **measured share** | reclaim (**est.**) | time won | speedup | **dhry @5584** |
|---|---|---|---|---|---|---|---|
| **1** | **`LOOP` — the dispatch loop itself** | LOOP | **26.4 – 26.5 %** | **withheld — see below** | — | — | — |
| **2** | accessor inlining (dcache) | READ + WRITE | **17.0 – 18.6 %** | 40 % | 6.80 – 7.45 % | 1.073 – 1.080× | **5992 – 6033** |
| **3** | handler specialisation | HANDLER | **16.3 – 16.8 %** | 25 % | 4.08 – 4.19 % | 1.043 – 1.044× | **5822 – 5828** |
| **4** | decoded-op cache, second pass | FETCHOP + FETCHEX | **14.5 – 15.8 %** | 40 % | 5.80 – 6.32 % | 1.062 – 1.068× | **5928 – 5961** |
| **5** | tail residue | TAILADV | **4.2 – 8.1 %** | 50 % | 2.10 – 4.03 % | 1.022 – 1.042× | **5704 – 5818** |
| **6** | ATC fast path | XLATE + WALK | **1.6 – 1.8 %** | 60 % | 0.95 – 1.09 % | 1.010 – 1.011× | **5637 – 5646** |
| — | *interrupt-poll cadence* | *TAILPOLL* | *15.1 – 16.0 %* | — | — | — | ***already taken*** — cadence 4 is standing, +16.70 % measured |
| **J** | the residual only a JIT reaches | LOOP+FETCH\*+TAILADV+TAILPOLL+TAILSPEC | **63.1 – 64.5 %** | 90 % coverage | 56.8 – 58.1 % | 2.31 – 2.38× | **12 920 – 13 317** |

**`LOOP` is ranked first and given no dhry projection, and the asymmetry is deliberate.** Its
*share* is the best-measured number on this page — a 0.31-point bracket, self-checked. Its
*reclaim* is the worst-founded: v2 assigned 40 % when the bucket was believed to be 0.51 %, an
estimate nobody had reason to scrutinise, and the bucket has since turned out to be fifty
times larger and to contain (probably — §15.4) the hit path rung 1 just added. **A reclaim
fraction for a 26 % bucket whose contents have never been enumerated would be a guess dressed
as a number**, and this document's §10.6 exists to stop exactly that. The first move on rung 1
is not to attack it; it is to find out what is in it.

**The JIT row grew for the same reason and carries the same warning.** It went from 51.79 % to
63–65 % almost entirely because `LOOP` went from 0.51 % to 26.5 %, so its size now turns on the
same unenumerated bucket. Read it as *unchanged in kind*: a JIT is still worth roughly twice
the ladder's leading rung, and the gap between them is now less well known than v2 thought it
was, not better.

### 17.3 The physical-index study, and the bar it has to clear

The obvious next narrowing is a **physically-indexed decoded-op cache**, which would let
`CPUSHL`/`CINV` invalidate by address instead of wholesale. The prize is measured and it is
the largest single one available:

| cause | boot | dhrystone | raw disk |
|---|---|---|---|
| **`IV_FLUSH`** (`CPUSHL`/`CINV`) | **63.89 %** | **51.21 %** | **46.70 %** |
| `IV_PFLUSHA` | 26.92 % | 36.27 % | 35.60 % |
| `IV_PFLUSH` | 6.20 % | 9.11 % | 6.82 % |
| `IV_DMA` | 1.69 % | 0.16 % | 8.46 % |
| `IV_ROOT` | 1.30 % | 3.25 % | 2.41 % |

**`IV_FLUSH` is 47–64 % of every workload's invalidation traffic** and it is the one cause that
carries a namespace a physical index could match against. `IV_PFLUSHA` — the other 27–36 % —
carries nothing, and is not reachable by this or any tag-based narrowing.

> **THE BAR, stated before anything is built: a physical index costs a TRANSLATION ON THE FILL
> PATH.** That is the exact cost class that failed rung 1b, twice, and was recovered by
> removal. §14.3.2 is the controlled evidence, and it is not a soft preference — 1b had the
> higher hit rate and was slower. So this study **must pre-register its cost site and measure
> the fill-path price**, not assume it. A design that moves the cost to a call site, or that
> pays the translation only on a miss that was going to walk anyway, starts above the bar; one
> that adds work to every fill starts below it and has to earn its way back.

---

## 18. What v3 does **not** establish

§10 applies unchanged and is not repeated. Four things are new.

### 18.1 There is no stage profile of the shipped build

The only span-measured stage profile is of the **rung-1b** build, and rung 1c reverted two of
its three arms. §17.1's shares therefore describe a binary that is not shipped — the same
class of caveat §10.1 makes about the profiling build itself, one level in. The direction is
known and the size is not. **Row H — `FETCHOP + FETCHEX` post-1c — is untaken**, and it is the
cheapest thing on §19's list.

### 18.2 Rung 1c's +2.80 % is not defended against drift by the method the file mandates

**No same-boot ratio was taken in the 1c session**, for dhrystone or for disk. The rig's
cross-session drift is proven at about 9 % on the disk row, and 2.80 % is well inside it. The
lean boot window reproducing at 52 s exactly is good evidence and it is **one row**. Rung 1c's
verdict rests on a pre-registered bar cleared by 2.80 % on a three-run arm with 0.125 %
spread — which is a legitimate verdict — but **if the figure is going to be quoted in a
decision, the same-boot pair has to be taken first.**

### 18.3 The cache's worth on disk is unmeasured for 1c

Rung 1 measured +2.74 % same-boot and rung 1b +5.40 %. For rung 1c there is no such arm; the
cross-session −9.03 % is drift, refuted as a regression by rung 1's own same-boot pair, but
that says nothing about 1c.

### 18.4 The ledger of refuted claims — kept, and labelled

Per `docs/METHOD.md` §8. Nothing below is deleted from this file; each is annotated where it
stands.

| claim | where | status |
|---|---|---|
| `ATC_HIT` (id 12) counts ATC hits | v1 §1 | **REFUTED** by v1 itself; it counts translate successes. Fixed in the wire format as `XLATE_OK`. |
| `LOOP` ≤ 9.82 %, "somewhere between nothing and 9.8 %" | v1 §3.5 | **REFUTED.** §15: 24.80–25.11 %. |
| **"`LOOP` is empty… it is zero"** | **v2 §8.3, §9.7 rung 7** | **REFUTED by direct measurement.** §15. The reasoning was sound and the instrument could not support it. |
| `probe_cyc = 59` used as a bracket end | v2 §8.3, §8.5 | **SUPERSEDED.** The price is a measured range per boot; §16.2. |
| the ifetch buckets carry `2 × IFETCH_CALLS` transitions | v2 §10.3, rung 1's stage bracket | **REFUTED**, by 1.97×; §16.1. |
| recon-A (a cadence-gated tail child) | v2 §8.5, §10.3 | **REFUTED** by firmware source, in v2 itself. Retained there as the bracket's other extreme. |
| recon-B (the shared ifetch bracket) as the model's shortfall | v2 §10.3 | **REFUTED** by the source: `IFETCH_CALLS == FETCH` identically. The model's shortfall is elsewhere and is now moot — the spans replace the model. |
| `DOPC_HIT + DOPC_MISS == INSNS` | firmware `docs/profiler.md` | **UNDERSTATED.** The exact identity is `== INSNS + FAULTS`; §16.3. Doc fix owed upstream. |
| rung 0's `< 3 %` `bzero` bench threshold | rung 0 pre-registration | **UNREACHABLE BY CONSTRUCTION** — the map's own 80 % reclaim model puts perfect success at 4.42 %. The threshold was wrong, not the change. |
| the rung-0 disk row | rung 0 pre-registration | **UNSCOREABLE** — its baseline was taken on the profiling build. |
| rung 1c's hit-rate bands | 1c pre-registration | **REFUTED.** They assumed 1b's hit-rate gain would be given back; it was the CACR arm's all along. §14.4. |
| "with the cache off, none of the `DOPC_` counters move" | firmware `docs/decoded-op-cache.md` | **REFUTED** — `DOPC_INVAL` moved. Fixed upstream. |
| the decoded-op-cache switch as a production fallback | rung 1 framing | **REFUTED** — it costs ~12.9 %. It is an A/B instrument. |

---

## 19. What the next capture session must take

> **⚠ TAKEN — see §§20–26 (v3.1).** Six of the seven were executed on the 2026-08-23
> §19 capture session; item 4 (the `LOOP` breakdown) is the one that moved the map, and its
> result is §21. **Kept unedited**, because three of the items below turned out to specify a
> method that cannot answer the question they ask, and that is only visible if the original
> wording survives: **item 1**'s band and bar rest on a method §16.1 already refuted and are
> withdrawn (§23.3); **item 3**'s same-boot A/B cannot defend a *build* difference (§23.1);
> **item 5**'s window excludes the phase where the effect is largest (§23.2). Items 2, 6 and
> 7 were taken as written and are banked in §§24.1, 22.4 and 22.6. Item 4's ring dumps were
> Item 4's `LOOP` breakdown is the one that moved the map. What was *not* taken: ring dumps
> (the method item 1 suggested — row H was answered with spans instead), the disk row of item
> 3's A/B, and an install-workload profile (§26.4).

In order. The first three are the ones that defend numbers already quoted in this file.

1. **Row H — `FETCHOP + FETCHEX` on the shipped 1c build.** Band 10–13 %, and it must not
   exceed rung 1's 12.64 %. Given the hit rate came in *above* band, expect it low. It needs
   `PROFB` plus a ring on one prof-image boot and is the cheapest item here. This is the row
   §18.1 is about.
2. **A fresh span-measured stage profile of the 1c build.** §17.1's entire share table is of
   the reverted 1b build. Take it at **both cadences** if the session allows, because §17.1's
   `TAILPOLL` figure is cadence-1 and the standing posture is cadence 4 — one profile cannot
   serve both and the difference is 15 points of the largest tail bucket.
3. **The five-minute same-boot A/B defending +2.80 %.** `DOPC` ON/OFF within one boot, dhry
   and disk, at cadence 1. Rung 1c's absolute figures are not currently defended against a
   drift band wider than the effect (§18.2). Same boot, same flash, `PROFZ` between arms.
4. **A `LOOP` breakdown, or one bracket around the decoded-op lookup.** `LOOP` is now the
   largest bucket in the interpreter and nobody has enumerated its contents; §15.4's
   re-attribution hypothesis — that rung 1's hit path is charged there — is testable with one
   probe bracket and would decide whether the top of the ladder is attackable at all. **This
   is the highest-value instrument change available**, in the same sense the tail split was in
   v1.
5. **The boot-window A/B still owed from rung 1.** Lean cadence-4 boot reads 52 s against rung
   0's 43 s, confounded with the rig's ~9 % cross-session drift. Same-boot or same-session, or
   it stays unresolved.
6. **Divide `BLK_BYTES` by a wall time.** The map's **5.17 MB/s** kernel zero-fill figure —
   the number rung 0 exists to move — has never been scored. The counter has been captured
   every session since; only the time base is missing.
7. **A cache-off `PROFZ`-windowed arm for the guest's own invalidation rate.** With the cache
   off the `IV_*` counters still move and the `DOPC_` ones do not, which makes a free,
   uncontaminated measurement of what the guest actually asks for — the denominator §17.3's
   study will be judged against.

---
---

# PART II — v2, 2026-08-22 evening

## 6. What v2 is, and what moved

### 6.1 Provenance

Measured on A4000 + Z3660 metal, 2026-08-22 20:24–21:11 EEST, profiling firmware
`BOOT-prof.BIN` crc32 `33F73CCA`, wire format **version 2**. Raw captures and the
operations log are in the session's evidence directory (`MANIFEST.txt` and `NOTES.txt`
first). Everything below is derived with `tools/prof-symbolize.py` at commit `f00cd91`
(the v2-format entry), symbolized against the kernel that was actually running — the
card-1 kernel the system boots:

    build/unix-040-i46-i48-i49-i50-i51-i52f-hg-z3660-target-CARD1-ced0s1
    ET_REL, --load-base 0x08000000, 5475 .text symbols, 1875 assembler-locals filtered

Three things about this session make it the one to rank from, and each of them was a
named defect in the last one:

* **The clock is right and says so.** The boot line reads `ARM clock 1099989200 Hz
  (clk=cfg, PMU:wall 1.99), probe 59 cyc/transition`. `clk=cfg` means the figure is the
  rate core0 published after retuning the PLL, not the compile-time BSP constant. **No
  ×1.65 correction applies to any number in this part.** (§0.1 applied one to every rate and
  duration in the v1 part, Part III; it never touched a share, because a wrong constant cancels out of a
  ratio — that caveat held, and v2 confirms it.)
* **Every ring contains its workload.** `drops=0` on all three, and `rec_count` ==
  `ring end n=` == S-records present on all three. v1 lost two of its three workload rings
  to wrap and measured an idle machine in both.
* **The probe is priced per transition, by an out-of-line calibration.** That is exactly
  the firmware fix v1 asked for in §4.6 and §5.3–5.4. It changes the arithmetic
  fundamentally and it is what §8 is about.

The lean baseline this map is scored against was measured in the same session, on the same
flash, immediately after the profiling firmware came off: **4486 dhry/s** (PSTAT off). The
two distorted points of the ladder are **3183** (prof image + sampler @250 Hz) and **1716**
(prof + stage buckets).

### 6.2 What moved against v1, and why

| # | what | v1 | v2 | why it moved |
|---|---|---|---|---|
| 1 | **`LOOP` (v1's rung 5)** | ≤ 9.82 %, "somewhere between nothing and 9.8 %" | **0.00 – 2.54 %** | v1 predicted its own refutation: §2.4 computed that LOOP is exhausted at 58.24 cyc/transition. The v2 firmware's out-of-line calibration **measured 59**. Rung 5 is retired. |
| 2 | **The tail** | one opaque 20.01 % bucket, "a 20 % bucket nobody can attack safely" | four ids, and **87 % of the tail is `check_uae_int_request()`** | v2 splits id 8 into `TAILADV`/`TAILSAMP`/`TAILPOLL`/`TAILSPEC`. v1's §3.2 asked for exactly this and called it "the single highest-value instrument improvement C2 could make". It was made, and it named the mechanism. |
| 3 | **Instrument cost inside the tail** | invisible — charged to `LOOP` | `TAILSAMP`, **5.99 % raw**, broken out and subtracted | v1 could not see it in any capture. It is the sampler hook plus the `INSNS` counters: measurement, not interpretation. Every v2 share below is of a denominator with `TAILSAMP` removed. |
| 4 | **Probe price** | 45.5 cyc/transition (v1 halved a firmware figure it proved was doubled) | **59 cyc/transition**, measured; **50** used here | The 2× over-pricing v1 diagnosed is fixed at the source. But at 59 the subtraction is *arithmetically impossible* — see §8.3. |
| 5 | **Clock label** | ×1.65 correction applied to every rate and duration | none needed | `clk=cfg`. No share in the v1 part was ever affected. |
| 6 | **Ring coverage** | BOOT lossless; **DHRY and IO were 86 % and 93 % overwritten** and measured the idle loop | all three lossless, `drops=0` | v1's §5.1 asked for this. The `swtch`+`idle` contamination that dominated v1's workload rings (62.5 % and 71.8 %) is **15.99 %** in v2's DHRY and **2.40 %** in v2's IO — and **0.04 %** in v2's BOOT, which is cleaner than v1's boot ring too (17.43 %). |
| 7 | **PC concentration** (the decoded-op-cache input) | top 2000 PCs = 90.34 % of busy boot time | top 2048 PCs = **84.92 % (boot), 85.99 % (dhry), 79.55 % (IO)** | v1's curve came from a boot ring whose idle samples piled onto ~20 PCs and flattered the head of the distribution; and it had no workload curve at all. **This is the one place v2 is materially *less* optimistic than v1** — see §9.1. |
| 8 | **Opcode specialisation reach** | top 20 opcode words = 58.94 % of busy time | **59.69 % (boot) but 42.04 % (dhry), 49.19 % (IO)** | v1's figure was boot-specific and read as general. The four-line-group figure *is* general (75.9 / 76.0 / 76.6 %). |
| 9 | **`bzero`** | 17.53 % of boot (21.23 % busy) | **22.07 % of boot (22.08 % busy)** | Same physical fact, cleaner denominator: v1's ring was 17.4 % idle, v2's is 0.04 %. v1's busy-only 21.23 % and v2's 22.08 % are a cross-session reproduction to 0.85 points. **Confirmed and slightly larger.** |
| 10 | **The `bzero` finding's scope** | "a boot/page-fault phenomenon, not a steady-state one" | **the idiom *family* is 33.63 % of boot, 25.11 % of IO, 10.57 % of dhry** | v1 looked at `bzero` alone. `mcpy`, `lcolloop`/`uvbzero` (the `MOVES` cross-space copies) and `Lcb_loop` (a `CPUSHL` cache-flush loop) are the same shape and the same cost model — §9.7. |
| 11 | **`ATC_HIT`** | v1 proved id 12 counts translate *successes*, derived the real ATC rate as `(XLATE − ATC_MISS)/XLATE`, and asked for a counter | id 12 renamed `XLATE_OK`; a **real `ATC_HIT` at id 19** | v1's derivation is **confirmed by direct measurement**: DHRY 87.26 / 12.74 against v1's 87.25 / 12.75, BOOT 70.46 / 29.53 against 70.60 / 29.40. |
| 12 | **The A/B pair** | 3409 → 2106 dhry/s | 3183 → 1716 dhry/s | Not a contradiction: the v2 tail split adds phase transitions per guest instruction, so **the profiling image distorts more in v2 than in v1** — by design, and the reason the tail is legible at all. The *lean* figure reproduced across sessions and flashes: v1's 4500 against v2's **4486**, 0.3 % apart. |

**One thing that did *not* move, and should be said plainly: the C1 captures were the
68040 lane.** Their own mode flags say so (v1 §1.2: `SUPER · MMU · AMIX · 68040`, 66.23 %),
and they were symbolized against this same `unix-040-…` kernel. v1's *shares* therefore
transfer as measurements of the same machine. What did not transfer is v1's A/B pair
(row 12) — and v1 flagged that pair as its softest cross-check, not as a share.

**And the ordering of the ladder did not move.** v1 ranked fetch > tail > accessors >
handler, with dispatch and ATC at the bottom. v2 ranks fetch > tail-poll > accessors >
handler, with `TAILADV`, ATC and `LOOP` at the bottom. Two independent sessions, two
firmware wire formats, two probe-pricing conventions, and the same order.

---

## 7. Per-capture symbolized reports

### 7.1 Coverage verdicts — read these before any share below

| capture | records | samples taken | drops | wrap check | verdict |
|---|---|---|---|---|---|
| **BOOT** `03-BOOT-ring-full` | 32633 | 32633 | **0** | −0.001 % | **LOSSLESS, whole-run.** 163.805 s observed at a true 200 Hz. `swtch`+`idle` = **0.04 %** — the cleanest specimen in either session. |
| **DHRY** `05-DHRY-ring-full` | 17031 | 17031 | **0** | −0.001 % | **LOSSLESS, contains the workload.** 68.128 s at 250 Hz. Carries **15.99 %** `swtch`+`idle` — the window is dhrystone *plus* the machine waiting at a prompt, so busy-only figures are given alongside. |
| **IO** `08-IO-ring-full` | 32436 | 32436 | **0** | −0.001 % | **LOSSLESS, contains the workload.** 129.752 s at 250 Hz. **2.40 %** idle. |

The wrap cross-check is a *wrap* check and not a *clock* check — CPU-to-global-timer is a
fixed 2:1 in silicon, so both spans scale together and a wrong absolute rate cancels out of
the ratio. `clk=cfg` is the only evidence about the clock, and it is separate.

**WEIGHT — what the sampler could not see.** Nothing saturated anywhere, and the
unobservable fraction is negligible in all three: BOOT 76 samples above weight 1 (0.23 % of
samples) carrying **0.62 %** of observed time, largest bin 5–8; DHRY 1 sample, **0.01 %**;
IO 2 samples, **0.01 %**. A sample-counting symbolizer would misplace at most 0.62 % here.

Both remaining warnings on every capture are delivery damage, repaired and disclosed by the
tool: a logger timestamp prefix on every line, and one `ring hdr` line per ring that lost
its literal `[PROF] ` where the console echo and the firmware's output collide in the one
UART. The `rec_count` == `ring end n=` == records-present triple is re-checked afterwards
and holds everywhere. (v1 §0.2 had to do these repairs by hand; the tool does them now,
which is what commit `9d9b8d8` was for.)

### 7.2 BOOT — a cold boot with no idle in it

Cold boot 20:39:29, profiler armed from `z3660cfg.txt` 20:39:44, guest answering TCP on
port 23 at 20:42:18, `PROF OFF` 20:42:27. **163.805 s**, 163 s into a 327 s wrap-free
window. Gating on the network rather than on a serial `login:` string is what made it
wrap-free — AMIX never prints its login prompt to the serial console.

**Mode split (weighted).**

| mode | weight % |
|---|---|
| SUPER · MMU · AMIX · 68040 | 59.85 % |
| user · 68040 (pre-AMIX bootstrap) | 18.27 % |
| user · MMU · AMIX · 68040 | 13.16 % |
| SUPER · 68040 (pre-AMIX bootstrap) | 8.72 % |
| **supervisor total** | **68.57 %** |
| user total | 31.43 % |
| *(AMIX total)* | *73.01 %* |
| *(AmigaOS bootstrap total, correctly not symbolized against the kernel)* | *26.99 %* |

**Top supervisor symbols (weighted, % of all observed time; 678 distinct).**

| rank | wt % | symbol | | rank | wt % | symbol |
|---|---|---|---|---|---|---|
| 1 | **22.07 %** | `bzero` | | 6 | 1.51 % | `z3660_rw` |
| 2 | 7.79 % | `Lcb_loop` | | 7 | 0.86 % | `systrap` |
| 3 | 3.82 % | `rom/amigaos:00f81000` | | 8 | 0.80 % | `page_free` |
| 4 | 3.12 % | `rom/amigaos:00008000` | | 9 | 0.65 % | `nullvect` |
| 5 | 1.94 % | `mcpy` | | 10 | 0.63 % | `dnlc_search` |

`swtch` is **12 weight units — 0.04 %** — and `idle` is zero. This ring is 163 s of a
machine doing work, end to end.

**PC concentration** (the decoded-op-cache viability input), 6599 distinct PCs. Busy-only
differs from all-samples by hundredths here, because there is no idle to exclude:

| | top 10 | top 50 | top 200 | top 500 | top 1000 | top 2048 | top 4096 |
|---|---|---|---|---|---|---|---|
| all | 42.65 % | 59.60 % | 65.90 % | 71.61 % | 77.48 % | **84.88 %** | **92.37 %** |
| busy | 42.67 % | 59.62 % | 65.92 % | 71.64 % | 77.50 % | **84.92 %** | **92.40 %** |

Busy-only, 50 % of the time needs the top **17** PCs (that is `bzero`), 80 % needs
**1273**, 90 % needs **3312**, 95 % needs **4949**.

**Opcode histogram.** Top words: `51c9` `DBcc` 14.22 %, `20c9` `MOVE.L` 11.26 %, `6600`
`BNE` 4.54 %, `12d8` `MOVE.B` 3.65 %, `5380` `SUBQ` 2.89 %, `d0fc` `ADDA` 2.72 %, `f468`
`CPUSH` 2.36 %. 1527 distinct words; the top 20 carry **59.69 %** of busy time.

**Opcode line-major rollup** (busy-only): line 2 `MOVE.L/MOVEA.L` 27.16 %, line 5
`ADDQ/SUBQ/Scc/DBcc` 21.46 %, line 4 `misc (LEA/JSR/MOVEM/TST/CLR)` 15.01 %, line 6
`Bcc/BSR/BRA` 12.31 %, line 1 `MOVE.B` 8.07 %, line D `ADD/ADDA/ADDX` 5.15 %. **Four
line-groups carry 75.94 %.**

### 7.3 DHRY — the capture v1 never got

Armed 20:44:54, `PROF OFF` 20:46:02: 68.128 s of a 262 s window, `drops=0`. The window is
the dhrystone run plus the machine idling at a prompt around it — `swtch` 13.52 % + `idle`
2.48 % = **15.99 %** — so both denominators are given. (v1's DHRY ring was 62.49 % idle and
contained no dhrystone at all.)

**Mode split:** supervisor 54.10 %, user 45.90 %, all of it MMU · AMIX · 68040.

**Top symbols (all-samples %):** `user:80000000` 17.16 %, `swtch` 13.52 %, `user:c101d000`
8.66 %, `user:80002000` 5.38 %, **`mcpy` 5.23 %**, `user:c1019000` 3.45 %, `Lcb_loop`
2.86 %, `idle` 2.48 %, `bzero` 1.57 %. The hottest single PC is **`mcpy+0x24` at 5.16 %**;
the `swtch` window `+0xa4 … +0xe8` is next.

**PC concentration**, 4076 distinct PCs:

| | top 10 | top 50 | top 200 | top 500 | top 1000 | top 2048 |
|---|---|---|---|---|---|---|
| all | 22.26 % | 40.72 % | 55.75 % | 68.84 % | 78.42 % | **88.09 %** |
| busy | 18.88 % | 31.69 % | 48.27 % | 63.39 % | 74.57 % | **85.99 %** |

Busy-only, 50 % needs **224** PCs, 80 % needs **1389**, 90 % needs **2622**, 95 % needs
**3337**. Note the sampling floor: 17032 weight periods over 4052 busy PCs is ~4 samples
per PC on average, so the *tail* of this curve is under-resolved and the true distinct-PC
count is higher than 4076. The head is what the cache sizing turns on, and the head is
sound.

**Opcode line rollup (busy):** line 4 `misc` 26.71 %, line 2 `MOVE.L/MOVEA.L` 24.83 %,
line 6 `Bcc/BSR/BRA` 13.20 %, line 5 `ADDQ/SUBQ/Scc/DBcc` 11.29 %, line 1 `MOVE.B` 5.79 %,
line B `CMP/CMPA/EOR` 5.00 %. Four line-groups carry 76.03 %. **The top 20 individual
opcode words carry only 42.04 %** — against 59.69 % on boot. 1073 distinct words.

### 7.4 IO — raw disk read ×3 on `ced0s1`

Armed 20:53:48, `PROF OFF` 20:55:58: 129.752 s, `drops=0`, 2.40 % idle. The workload
measured 796.6 / 828.9 / 828.9 kB/s over an 8 MB span.

**Mode split:** supervisor 73.44 %, user 26.56 %.

**Top supervisor symbols:** **`lcolloop` 11.54 %**, **`mcpy` 7.19 %**, `z3660_rw` 4.32 %,
`Lcb_loop` 3.55 %, `bzero` 2.23 %, `swtch` 2.04 %, `systrap` 1.25 %, `u_trap` 0.84 %.
The hot PCs are `mcpy+0x24` (7.11 %) and the three-PC `lcolloop` body (5.64 + 3.15 +
2.76 %).

**PC concentration**, 7174 distinct PCs — the flattest of the three:

| | top 10 | top 50 | top 200 | top 500 | top 1000 | top 2048 | top 4096 |
|---|---|---|---|---|---|---|---|
| all | 28.51 % | 40.05 % | 51.25 % | 60.57 % | 69.08 % | **79.84 %** | **90.51 %** |
| busy | 29.21 % | 40.33 % | 50.65 % | 59.95 % | 68.56 % | **79.55 %** | **90.40 %** |

Busy-only, 80 % needs **2114** PCs, 90 % needs **3969**, 95 % needs **5552**.

**Opcode line rollup (busy):** line 2 29.06 %, line 4 21.38 %, line 6 14.47 %, line 5
11.66 %, line 0 `immediate/static bit` 7.66 % (that is the `MOVES` traffic), line B 3.92 %.
Four line-groups carry 76.57 %; the top 20 words carry 49.19 %.

### 7.5 Whole-run counters (`PROFD`, exact and cumulative)

| counter | BOOT | DHRY | IO | STAGE |
|---|---|---|---|---|
| INSNS | 276 651 690 | 134 549 859 | 235 189 754 | 92 209 835 |
| supervisor share | **80.16 %** | 59.49 % | 73.76 % | 61.57 % |
| FETCH / insn | 1.5796 | 1.6264 | 1.6129 | 1.5983 |
| READ / insn | 0.2373 | 0.3672 | 0.3380 | 0.3776 |
| WRITE / insn | 0.2960 | 0.2842 | 0.2333 | 0.2778 |
| ipagecache hit | 98.21 % | 98.15 % | **96.64 %** | 98.45 % |
| dpagecache read hit | 98.71 % | 99.42 % | 98.98 % | 99.19 % |
| dpagecache write hit | 98.99 % | 99.53 % | 99.22 % | 99.32 % |
| translates (XLATE) | 1 866 449 | 1 859 193 | 4 259 081 | 1 184 785 |
| **ATC hit** (id 19, the real one) | **70.46 %** | **87.26 %** | **83.28 %** | **78.85 %** |
| table-walk rate | **29.53 %** | 12.74 % | 16.71 % | 21.15 % |
| `XLATE_OK` (id 12 — *not* an ATC rate) | 99.60 % | 99.80 % | 99.79 % | 99.69 % |
| misaligned accesses | 9.36 % | 12.71 % | **13.87 %** | 9.30 % |
| FAULTS | 7467 | 3630 | 8939 | 3628 |
| STACK_OVF | 0 | 0 | 0 | 0 |

All three v2 identities hold on all four dumps, with the third satisfied-with-a-remainder
and the remainder bounded by `FAULTS` in every case (72 / 77 / 217 / 78 against 7467 /
3630 / 8939 / 3628):

    IPAGE_MISS + DPAGE_RMISS + DPAGE_WMISS  ==  XLATE
    XLATE_OK + FAULTS                       ==  XLATE
    ATC_HIT + ATC_MISS                      ==  XLATE   (short by the translates that faulted)

**The ATC rates reproduce v1's derivation to within 0.3 points on every comparable dump**
(§6.2 row 11). v1 could only infer them; v2 measures them, and the inference was right.

---

## 8. The corrected bucket shares, with the arithmetic shown

Source: `06-STAGE-profd.txt`. `total_cyc` **95 533 119 834**, `TRANSITIONS` **1 048 688 485**,
INSNS **92 209 835**, `STACK_OVF` 0. Run-loop residency 94.03 % (the buckets account for
that much of the 101 596 488 025 cycles of wall time; the rest is time core1 spent off the
run loop, which was never inside a stage). Read shares from this dump — never an
instruction rate.

### 8.1 The v2 arithmetic in one line, and the two things it changed

    probe total  =  TRANSITIONS  ×  probe_cyc          nothing is halved

Under v1 `probe_cyc` priced an enter/exit **pair** while `TRANSITIONS` counted each half,
so the firmware's own printed figure double-counted and v1 had to halve it by hand (v1
§2.2). Under v2 the firmware calibrates **out of line** and prices **one transition**, so
the tool and the console agree and there is nothing left to correct. Two consequences:

* **The instrument's own cost is now visible and subtractable.** `TAILSAMP` — the sampler
  hook plus the `INSNS`/`INSNS_SUPER` counters — is 5.99 % of the raw span. In v1 it was
  charged to `LOOP`, so no v1 capture could see it. **Every share in §8.4 and §9 is a
  share of a denominator with `TAILSAMP` removed**, because `TAILSAMP` does not exist in
  the lean build the map is scored against.
* **The whole tail is four ids, and one of them is not the tail.** Laying v2's `TAILADV`
  beside v1's `TAIL` compares a part with a whole. The rollup is the comparable quantity,
  and the firmware prints its own `[PROF] t` line for the cross-check — which agrees
  exactly: **31 853 146 574 == 31 853 146 574**.

### 8.2 The tail, opened

| id | bucket | raw cycles | of total | of tail |
|---|---|---|---|---|
| 8 | `TAILADV` — `adjust_cycles()`, the cadence test, the PC advance | 13 577 746 351 | 14.21 % | 42.63 % |
| 11 | `TAILSAMP` — **instrument**: sampler hook + `INSNS` counters | 5 719 250 665 | 5.99 % | 17.96 % |
| 12 | `TAILPOLL` — `check_uae_int_request()` | 12 331 589 659 | 12.91 % | 38.71 % |
| 13 | `TAILSPEC` — `do_specialties()`: trace, `STOP`, mode change | 224 559 899 | 0.24 % | 0.70 % |
| | **whole tail** (what v1 called `TAIL`) | **31 853 146 574** | **33.34 %** | 100 % |
| | tail without the instrument | 26 133 895 909 | 27.36 % | |

**This is the single most useful thing v2 added.** v1 measured the tail at 20.01 % and
wrote that it "should be a PC advance and a cheap event test", that 110.8 cycles per guest
instruction "says it is doing per-instruction work that belongs at block boundaries", and
that a 20 % bucket with no breakdown "is a 20 % bucket nobody can attack safely". The
breakdown exists now and it names the culprit: **after the instrument is removed, 87 % of
the interpreter's tail is one call, `check_uae_int_request()`**, made on every guest
instruction because `service_cadence` is 1.

### 8.3 The probe price: the firmware says 59, and 59 does not fit

> **⚠ SUPERSEDED — see §15. The conclusion this section reaches, "`LOOP` is empty", is
> REFUTED by direct measurement: `LOOP` is 24.80 % @39 .. 25.11 % @50, the largest single
> bucket in the interpreter.** The reasoning below is sound and the instrument could not
> support it — the exhaustion argument needs a per-bucket transition count, which no v2
> capture had. The firmware's rung-1b build added one (`[PROF] s`), and it settled the
> question in the other direction. The price question, which this section spends itself on,
> now moves `LOOP` by 0.31 points and decides nothing. **Kept, per `docs/METHOD.md` §8.**

The firmware's own out-of-line calibration reports **59 cyc/transition** — and at 59 the
subtraction is *arithmetically impossible*: the modelled probe cost exceeds the cycles
actually measured in `LOOP` by 2 991 351 830 and in `TAILADV` by 1 225 742 547, **4.42 %
of the whole span that cannot be placed anywhere**. The tool clamps both at zero, says so,
and states that shares derived from a clamped column are not trustworthy. That warning is
the instrument working: under v2 a clamp means *the price is wrong*, not that the stage is
empty.

Sweeping the price finds where it stops being impossible:

| probe price (cyc/transition) | probe as % of span | buckets clamped | unplaceable cycles |
|---|---|---|---|
| 45 | 49.40 % | 0 | — |
| 48 | 52.69 % | 0 | — |
| **50** | **54.89 %** | **0** | **—** |
| 51 | 55.98 % | 1 (`LOOP`) | 145 181 406 |
| 55 | 60.37 % | 2 | 1 790 382 799 |
| **59** (firmware) | **64.77 %** | **2** (`LOOP`, `TAILADV`) | **4 217 094 377** |

`LOOP` is exhausted at **50.59 cyc/transition** and `TAILADV` at **54.11**. So:

> **`LOOP` is empty.** Whatever the true price is, it is above the 50.59 at which the
> dispatch loop's apparent 18.84 % is *entirely* probe. v1 computed the same quantity on
> its own span and got 58.24 (§2.4), then hedged that "the true figure may be zero" — and
> the firmware's out-of-line calibration came back at 59, above v1's figure and well above
> this span's. **Two spans, two exhaustion points, one answer: it is zero.**

The session's own notes flag `probe_cyc = 59` as sitting just above the 45.5–58 band the
firmware's `docs/profiler.md` predicted for an out-of-line calibration. **This document
uses 50 cyc/transition** — the highest integer price at which every bucket stays positive
and the adjusted column still sums to `total − probe` — and brackets to 59 throughout. The
choice is conservative in the direction that matters: a lower price leaves *more* cycles in
the buckets, so every rung's share in §9 is the smaller of the two, and `LOOP` gets its
most favourable reading.

Whether the discrepancy is the price or the landing model is **not resolved here**, and
§10.3 says what is known about it. It does not need resolving to rank the map: across the
whole 50→59 price sweep no ranked share moves by more than **1.2 points**, and the order
never changes at all. §8.5 widens the bracket to include the landing-model question too.

### 8.4 The corrected table

Probe distributed by the modelled landing shape at **50 cyc/transition**. `TAILSAMP` is
listed but excluded from the denominator, because it is measurement rather than
interpretation. `PROF` is zero and omitted.

| bucket | raw cycles | raw share | probe cyc | adjusted | **share of interpreter** | per event |
|---|---|---|---|---|---|---|
| HANDLER | 15 139 872 791 | 15.85 % | 4 181 776 525 | 10 958 096 266 | **26.37 %** | 118.8 cyc/insn |
| TAILPOLL | 12 331 589 659 | 12.91 % | 4 181 776 525 | 8 149 813 134 | **19.61 %** | 88.4 cyc/insn |
| FETCHOP | 11 413 660 218 | 11.95 % | 4 205 616 684 | 7 208 043 534 | **17.34 %** | 78.2 cyc/opcode word |
| FETCHEX | 7 218 629 221 | 7.56 % | 2 516 379 025 | 4 702 250 196 | **11.31 %** | 85.2 cyc/extension word |
| WRITE | 5 335 515 744 | 5.58 % | 1 168 513 850 | 4 167 001 894 | **10.03 %** | 162.7 cyc/guest write |
| READ | 5 661 973 778 | 5.93 % | 1 588 068 780 | 4 073 904 998 | **9.80 %** | 117.0 cyc/guest read |
| TAILADV | 13 577 746 351 | **14.21 %** | 12 545 329 575 | 1 032 416 776 | **2.48 %** ▼ | 11.2 cyc/insn |
| WALK | 563 111 528 | 0.59 % | 11 363 151 | 551 748 377 | **1.33 %** | 2202.0 cyc/walk |
| XLATE | 291 337 726 | 0.30 % | 65 093 928 | 226 243 798 | **0.54 %** | 191.0 cyc/translate |
| TAILSPEC | 224 559 899 | 0.24 % | 0 | 224 559 899 | **0.54 %** | 2.4 cyc/insn |
| LOOP | 17 999 155 043 | **18.84 %** | 17 788 565 146 | 210 589 897 | **0.51 %** ▼▼ | 2.3 cyc/insn |
| FAULT | 56 717 211 | 0.06 % | 164 532 | 56 552 679 | **0.14 %** | 15 588 cyc/fault |
| *TAILSAMP (instrument)* | *5 719 250 665* | *5.99 %* | *4 181 776 525* | *1 537 474 140* | *— excluded —* | *16.7 cyc/insn* |
| **TOTAL** | **95 533 119 834** | 100 % | **52 434 424 250** | **43 098 695 588** | | |
| **interpreter total** (ex `TAILSAMP`) | | | | **41 561 221 448** | **100 %** | **450.7 cyc/insn** |

**The raw ranking is wrong at the top, again, and for the same reason.** `LOOP` (18.84 %
raw) and `TAILADV` (14.21 % raw) are first and third before subtraction and eleventh and
seventh after it: `LOOP` is the parent of eight nested stages and pays one `exit()` for
every entry of all of them, and `TAILADV` pays the exits of the three tail children. v1
made this point about `LOOP` alone; v2's tail split created a second bucket with the same
pathology, and it behaves the same way.

**Per-event costs at the true 1.1 GHz** — the numbers that make the map actionable:

| bucket | cyc/event | ns | | bucket | cyc/event | ns |
|---|---|---|---|---|---|---|
| HANDLER | 118.8 | 108.0 | | READ | 117.0 | 106.4 |
| TAILPOLL | 88.4 | 80.3 | | WRITE | 162.7 | 147.9 |
| FETCHOP | 78.2 | 71.1 | | XLATE | 191.0 | 173.6 |
| FETCHEX | 85.2 | 77.5 | | WALK | 2202.0 | 2001.8 |
| | | | | **TOTAL** | **450.7 / insn** | **409.7** |

**78 ARM cycles to fetch one 16-bit opcode word, 163 to perform one guest write, and 88 to
ask whether an interrupt arrived — per guest instruction — are not the cost of the
operation. They are the cost of the machinery around it.**

### 8.5 The bracket: how much of this turns on the probe price

Four defensible readings of the same dump — the shipped landing model at both ends of the
probe bracket, and the two reconciled models §10.3 describes — give:

| bucket | shipped model, p=50 | shipped model, p=59 | recon-A, p=45 | recon-B, p=50 | **bracket** |
|---|---|---|---|---|---|
| HANDLER | 26.37 % | 27.51 % | 23.50 % | 24.93 % | 23.5 – 27.5 |
| TAILPOLL | 19.61 % | 19.94 % | 22.67 % | 18.28 % | 18.1 – 23.9 |
| FETCHOP + FETCHEX | 28.65 % | 28.85 % | 25.58 % | **32.94 %**† | 25.6 – 32.9 |
| READ + WRITE | 19.83 % | 20.88 % | 17.67 % | 18.82 % | 17.7 – 20.9 |
| TAILADV | 2.48 % | 0.00 % | 7.59 % | 0.00 % | 0.0 – 7.6 |
| XLATE + WALK | 1.87 % | 2.06 % | 1.66 % | 1.82 % | 1.7 – 2.1 |
| LOOP | 0.51 % | 0.00 % | 0.74 % | 2.54 % | 0.0 – 2.5 |

The two "recon" columns are the landing-model reconciliations of §10.3 — the two ways the
model can be made to predict the firmware's exact `TRANSITIONS` count. **recon-A (a
cadence-gated tail child) is refuted by the firmware source** and is retained here only
because it is the bracket's other extreme, i.e. the reading least favourable to rung 1.
**recon-B (the shared instruction-fetch bracket) is §10.3's leading candidate.**

† and this is the point: rung 1's share moves *up* under the reconciliation the evidence
favours, by 4.3 points. **Every correction available to the top rung makes it larger**,
which is why its first place is the most robust conclusion on this page.

**The ranked order is identical in all four columns**: HANDLER ≈ TAILPOLL > FETCHOP >
FETCHEX > WRITE ≈ READ > TAILADV > WALK > {XLATE, TAILSPEC, LOOP} > FAULT. The only
buckets that move materially are `TAILADV` and `LOOP`, and both only move *downward* toward
zero. **The probe-price question, which decided v1's rung 5, no longer decides anything on
this map.**

---

## 9. THE MAP v2 — the rungs ranked by measured ceiling

> **⚠ SUPERSEDED BY §17.** This ladder was the campaign's dispatch list and its **ordering
> held**: rung 1 was built and returned +23.3 %, and rung 2 (`service_cadence`) is now the
> standing posture at a measured +16.70 %. Two rows are wrong rather than merely stale —
> **rung 7 (`LOOP`, 0.51 %) is refuted at §15**, and rung 1's 28.65 % was measured on an
> instrument since shown to bias the fetch buckets low (§16.1). Read §17 for the re-ranking
> against the new baseline; this table is kept for what it predicted and what it missed.

Amdahl on the §8.4 shares, against the lean baseline of **4486 dhry/s** measured in this
same session. Time won = share × reclaim; speedup = 1 / (1 − time won); dhry = 4486 ×
speedup. **The share column is measured. The reclaim column is not** — it is an
engineering estimate and it is the one genuinely soft input in this document, exactly as it
was in v1.

| # | rung | buckets | **measured share** | bracket | reclaim (**estimated**) | time won | speedup | **dhry** |
|---|---|---|---|---|---|---|---|---|
| **1** | **decoded-op cache** | FETCHOP + FETCHEX | **28.65 %** | 25.6 – 32.9 | 50 % | 14.33 % | 1.167× | **5236** |
| **2** | **interrupt-poll cadence** | TAILPOLL | **19.61 %** | 18.1 – 23.9 | 50 % | 9.81 % | 1.109× | **4974** |
| **3** | **accessor inlining (dcache)** | READ + WRITE | **19.83 %** | 17.7 – 20.9 | 40 % | 7.93 % | 1.086× | **4873** |
| **4** | **handler specialisation** | HANDLER | **26.37 %** | 23.5 – 27.5 | 25 % | 6.59 % | 1.071× | **4803** |
| **5** | **tail residue** | TAILADV | **2.48 %** | 0.0 – 7.6 | 50 % | 1.24 % | 1.013× | **4542** |
| **6** | **ATC fast path** | XLATE + WALK | **1.87 %** | 1.7 – 2.1 | 60 % | 1.12 % | 1.011× | **4537** |
| **7** | **dispatch (LOOP residue)** | LOOP | **0.51 %** | 0.0 – 2.5 | 40 % | 0.20 % | 1.002× | **4495** |
| — | all seven, independent | | | | | 41.22 % | **1.702×** | **7632** |
| **J** | **the residual only a JIT reaches** | FETCHOP+FETCHEX+LOOP+TAILADV+TAILPOLL+TAILSPEC | **51.79 %** | | 90 % hot-code coverage | 46.61 % | **1.873×** | **8402** |

**Cross-cutting, and deliberately not a rung — see §9.7:** the block-idiom fast path is
**33.63 % of boot**, 25.11 % of the IO workload and 10.57 % of the dhrystone window. It is
not additive with the rungs above (it saves the same HANDLER, TAIL, FETCH and WRITE cycles
those rungs save, on a *slice* of the instruction stream rather than a stage of the
pipeline), and it is the cheapest thing on this page to build.

### 9.1 Rung 1 — decoded-op cache (FETCHOP + FETCHEX, 28.65 %)

**Still the largest rung, still the best-evidenced, and the one every correction makes
bigger.** Fetch costs 78.2 cycles per opcode word and 85.2 per extension word, at 1.5983
fetches per instruction. A decoded-op cache removes both the fetch and the decode for any
PC it holds.

*Viability from the measured PC distribution* — and this is where **v2 is less optimistic
than v1**, on better data. v1 argued from a boot ring whose 17.4 % idle samples piled onto
a handful of PCs, and concluded that 2048 entries covers 90.34 % of busy time. The v2
measurement, on three lossless rings including two that contain their workloads:

| cache entries | BOOT (busy) | DHRY (busy) | IO (busy) |
|---|---|---|---|
| 1024 | 77.50 % | 74.57 % | 68.56 % |
| **2048** | **84.92 %** | **85.99 %** | **79.55 %** |
| **4096** | **92.40 %** | (4052 PCs total) | **90.40 %** |
| PCs needed for 90 % | 3312 | 2622 | 3969 |

**The sizing this data supports is 4096 entries, not 2048.** At 16 B/entry that is 64 KB
of ARM RAM rather than 32 — still comfortable, but it now competes with the tier-0 page
caches for L2, which is a design input rather than a footnote. At 2048 entries the IO
workload sits at 79.55 %, and a decoded-op cache that misses one access in five is a
materially different proposition from one that misses one in ten.

*Caveat, unchanged from v1 and still the estimate most worth replacing with a measurement:*
the 50 % reclaim assumes a hit removes essentially all of fetch-plus-decode. It does not
remove the tag check, the guest-PC bounds check or the translation-validity check. At a
96.6–98.5 % `ipagecache` hit rate the 78-cycle fetch is **dominated by the hit path**, so
what a decoded-op cache must beat is an already-fast path. §11.2 pre-registers the counter
that would settle it.

### 9.2 Rung 2 — the interrupt-poll cadence (TAILPOLL, 19.61 %)

**v1's rung 2 was "the tail, 20.01 %, mechanism unknown". v2's rung 2 is a function call
with a name, a file and a knob.** `check_uae_int_request()` costs **88.4 ARM cycles per
guest instruction** and it is called on every guest instruction because
`z3660_service_cadence` is 1. It is 38.71 % of the raw tail and **87 % of the interpreter's
tail once the instrument is removed**.

The cadence gate already exists — `Z3660_RUNLOOP_TAIL()` in the firmware's run loop counts
down `z3660_service_cadence` and only then calls the poll — and cadence 1 is described in
the firmware's own comment as "byte-for-byte the old behaviour". So this rung is not "build
a new mechanism"; it is "find out what the existing knob costs in latency and buy throughput
with it". Two things make it less free than it looks, and both must be measured before the
knob is turned:

* **Interrupt latency is the price.** The firmware's comment is explicit: throttling
  `check_uae_int_request()` to every *N* instructions gives a maximum ~*N*-instruction
  interrupt latency. `do_specialties()` stays per-instruction for `STOP`/trace/mode-change
  correctness, so the correctness floor is intact — but the A3000 SCSI interrupt-delay pump
  rides on this poll, and the serial and ethernet paths depend on its rate.
* **88.4 cycles is the *whole* bracket at cadence 1**, so a cadence of *N* does not simply
  divide it by *N* — the counter test itself stays per-instruction (and is charged to
  `TAILADV`, which is why `TAILADV` is 2.48 % and not zero). The reclaim estimate of 50 %
  is deliberately far below 1 − 1/*N* for that reason.

The measurement that converts this rung from an estimate into a number is small and
entirely on the bench: sweep `service_cadence` over 1, 2, 4, 8, 16 and record dhry, the IO
rate, and a latency proxy at each point.

### 9.3 Rung 3 — accessor inlining (READ + WRITE, 19.83 %)

117.0 cycles per guest read and **162.7 per guest write**, against tier-0 page-cache hit
rates of 98.7–99.5 %. Almost every one of those accesses *hits*, so the cost is the
call-and-test machinery around a hit, not the miss path. The asymmetry v1 flagged is still
there and still unexplained: writes cost 39 % more than reads while having a *higher* hit
rate.

*Caveat, and it is the important one, unchanged:* this rung's share is the most inflated by
the prof build. The instrumented accessors make out-of-line calls the lean build does not
make at all — see §10.1.

### 9.4 Rung 4 — handler specialisation (HANDLER, 26.37 %)

The largest *single* bucket, at 118.8 cycles per instruction — the actual emulated
semantics plus per-handler overhead. Ranked below rungs 1–3 despite its size because it is
the hardest to reclaim, and 25 % is a deliberately modest estimate.

**v2 sharpens the targeting and corrects one of v1's claims.** The line-group evidence is
robust across all three workloads — four line-groups carry **75.94 % (boot), 76.03 %
(dhry), 76.57 % (IO)**:

| line | group | boot | dhry | IO |
|---|---|---|---|---|
| 2 | `MOVE.L / MOVEA.L` | 27.16 % | 24.83 % | 29.06 % |
| 4 | `misc (LEA/JSR/MOVEM/TST/CLR)` | 15.01 % | 26.71 % | 21.38 % |
| 5 | `ADDQ/SUBQ/Scc/DBcc` | 21.46 % | 11.29 % | 11.66 % |
| 6 | `Bcc/BSR/BRA` | 12.31 % | 13.20 % | 14.47 % |

But **v1's "the top 20 individual opcode words carry 58.94 %, so ~20 opcodes reaches most
of the traffic" was a boot-specific number read as a general one.** On boot v2 measures
59.69 % and confirms it; on the compute workload it is **42.04 %** and on the I/O workload
**49.19 %**, over 1073 and 1455 distinct words. A twenty-opcode specialisation pass reaches
most of *boot's* traffic and under half of dhrystone's. Specialise by *line group and
addressing mode*, which is stable, rather than by a top-N word list, which is not.

### 9.5 Rung 5 — tail residue (TAILADV, 2.48 %)

`adjust_cycles()`, the cadence counter's own test, and the PC advance. Its bracket is
0.0–7.6 % and its upper end is entirely a question about the landing model (§10.3), not
about the interpreter. It is listed so that the tail is accounted for whole, not because
2.5 % is worth a campaign.

### 9.6 Rungs 6 and 7 — ATC fast path (1.87 %) and dispatch (0.51 %)

**Both measured, both small enough to decline on throughput grounds.** Even a 100 %
reclaim of the ATC rung is worth 1.9 %.

Two qualifications on the ATC rung survive from v1 and are strengthened by v2's direct
`ATC_HIT` counter: BOOT's walk rate is **29.53 %** against DHRY's **12.74 %**, so
translation matters more than twice as much during bring-up as in steady state; and a walk
costs **2202 cycles**, so it is expensive per event while being rare. Attack this rung for
boot latency or for correctness, never for throughput.

**Rung 7 is the rung the raw data would put first, and it is now measured at half a
percent.** v1 ranked it fifth with an explicit upper bound and predicted it might be zero;
§8.3 shows it is. No C2 work should be aimed at the dispatch loop.

### 9.7 Outside the ladder — the block-idiom family, and `bzero` inside it

**The `bzero` verdict, asked directly: it is still there, it is bigger, and the new ring
is cleaner.** 22.07 % of the whole boot window against v1's 17.53 % — and the two are the
same physical fact measured against different denominators, because v1's boot ring carried
17.43 % idle and this one carries **0.04 %**. v1's own busy-only figure was 21.23 %; v2
measures 22.08 % busy. A cross-session, cross-firmware, cross-capture-path reproduction to
0.85 points. **Yes: still 17.5 %-class, and properly 22 %-class.**

`bzero+0x2a` at `0800032c` is **21.83 % of all observed boot time on its own**, and it is a
two-instruction loop — the sampler records the `DBcc` at the branch target, so both opcodes
appear at the one PC:

    0800032c   20c9   MOVE.L A1,(A0)+       11.25 % of the whole boot
    0800032e   51c9   DBF    D1,-4          10.58 %

Costing that loop from §8.4's per-event table — two instructions each paying HANDLER +
TAILPOLL + TAILADV + TAILSPEC + LOOP + FETCHOP, one extension word for the `DBcc`
displacement, and one guest write:

    2 x 301.3  +  85.2  +  162.7  =  850.5 cyc per 4 bytes  =  212.6 cyc per byte
                                   at 1.1 GHz               =  5.17 MB/s

**Kernel zero-fill runs at about 5 MB/s, and the store accounts for 163 of those 850
cycles — 80.9 % of the cost is interpreter machinery around a four-byte write.**

**And `bzero` is not alone. It is one member of a family that v1 could not see, because
two of the three workloads it would have shown up in were overwritten:**

| symbol | what it is | BOOT | DHRY | IO |
|---|---|---|---|---|
| `bzero` | `MOVE.L A1,(A0)+` / `DBcc` longword zero-fill | **22.07 %** | 1.57 % | 2.23 % |
| `Lcb_loop` | `CPUSHL (A0)` / `ADDA.W #n,A0` / `DBcc` — a **68040 cache-flush loop** | **7.79 %** | 2.86 % | 3.55 % |
| `mcpy` | `MOVE.L (A0)+,(A1)+` / `DBcc` longword copy | 1.94 % | **5.23 %** | **7.19 %** |
| `lcolloop` | `MOVE.L (A0)+,D1` / `MOVES.L` / `SUBQ` / `BGE` — cross-space copy | 0.60 % | 0.53 % | **11.54 %** |
| `uvbzero`, `Lpgz_clr`, `Lpgz_scan`, `bcmp`, `bcopy`, `copyin`, `copyout` | the rest of the same shape | 1.23 % | 0.38 % | 0.60 % |
| **family total** | | **33.63 %** | **10.57 %** | **25.11 %** |

Costed the same way:

    mcpy      2 insns, 1 ext word, 1 read + 1 write  =  967.5 cyc / 4 B  =  4.5 MB/s
    Lcb_loop  3 insns, 2 ext words, no data access   = 1074.4 cyc / 16 B cache line
              -> a 4 KB page flush costs 275 000 ARM cycles = 250 microseconds

`Lcb_loop` deserves its own sentence. **It is a cache-maintenance loop, and there is no
cache to maintain.** Every iteration pays three full interpreter dispatches and two
extension-word fetches to execute a `CPUSHL` that, on an emulator whose "cache" is a pair
of software page caches, reduces to at most one invalidation. It is 7.79 % of boot for
zero architecturally visible work beyond that invalidation.

This family is the cheapest large target on the page: narrow, self-contained, no
interpreter-architecture risk, and a *measured* payoff on all three workloads rather than
a projected one. **It should be built before any ladder rung** — which is what §11.1 does.

### 9.8 The ceilings, restated

The purely interpretive buckets — FETCHOP, FETCHEX, LOOP, TAILADV, TAILPOLL, TAILSPEC —
total **51.79 %**. A JIT removes essentially all of that for code it has compiled, leaving
HANDLER's semantics and the memory accessors:

| hot-code coverage | time won | speedup | dhry |
|---|---|---|---|
| 80 % | 41.43 % | 1.707× | 7659 |
| 90 % | 46.61 % | 1.873× | 8402 |
| 95 % | 49.20 % | 1.969× | 8831 |

**A JIT is worth about 1.9×, and the seven interpreter rungs together are worth about
1.7×.** That is the decision this map exists to inform, and **v2 narrows the gap v1
measured**: v1 put the JIT at 2.015× against a ladder of 1.707×, a gap of 0.31×; v2 puts
them at 1.873× and 1.702×, a gap of **0.17×**. The ladder's speedup is now **91 % of the
JIT's** (80 % of its gain over 1×, against v1's 70 %) at a small fraction of its risk. The
gap narrowed for a specific reason: `LOOP` was 9.82 % of v1's JIT-only residual and turned
out to be probe cost, so a JIT was never going to reclaim it.

The measured PC concentration is what makes 90 % hot-code coverage plausible, and §9.1 is
the caveat on it: 90 % coverage needs 2622–3969 distinct PCs resident, not the ~2000 v1
assumed.

---

## 10. What this does **not** establish

Per `docs/METHOD.md` §7 (*the platform is part of every claim*) and §8 (*record refuted
conclusions*).

### 10.1 Every share is of the DISTORTED machine, and v2 distorts it more than v1 did

The bucket dump comes from a build measuring **3183 dhry/s** with the sampler armed against
lean's **4486** — −29.0 % — and **1716** with the buckets armed, −61.7 %. Probe subtraction
removes the probe *bodies*, and `TAILSAMP` subtraction removes the sampler hook and the
`INSNS` counters. Neither removes the compiled-in cost of the instrumented accessors: the
lean build does not make those out-of-line calls **at all**. So §8.4 describes *the
prof-build interpreter with its probe bodies and its sampler removed*, which is not the lean
interpreter.

**The v2 gap is larger than v1's** (−29.0 % against v1's −23.2 % at the sampler, −61.7 %
against −53.2 % armed), and that is by design: the tail split costs extra phase transitions
per guest instruction, which is the price of the §8.2 breakdown. **A wider distortion gap
is the cost of the map's second-largest finding**, and it is disclosed rather than
discounted.

**Direction of the bias is known even though its size is not.** The compiled-in overhead
lives in the instrumented accessors, so **FETCHOP, FETCHEX, READ and WRITE are inflated
relative to lean**, and HANDLER / TAILPOLL / TAILADV / LOOP are correspondingly deflated.
How each conclusion transfers to lean:

* **Rung 1 (fetch) and rung 3 (accessors)** have shares **over-stated for lean**. Their
  dhry predictions are optimistic. Rung 1 has a counter-pressure — §8.5's landing-model
  correction moves it *up* by up to 4.3 points — so its net direction is genuinely
  uncertain, and its first-place ranking survives both. Rung 3's is not: **treat 4873 as a
  ceiling, not a forecast.**
* **Rung 2 (TAILPOLL) and rung 4 (HANDLER)** have shares **under-stated for lean**. If
  anything they rank *higher* on the lean machine than shown. Rung 2's mechanism is
  compiled into both builds identically — `check_uae_int_request()` is functional, not
  diagnostic, and survives in every build variant — so **rung 2 transfers more cleanly than
  any other rung on the page.** That is a reason to prefer it when two rungs look close.
* **Rung 6 (ATC) and rung 7 (LOOP)** are small in both directions and their verdicts
  ("decline on throughput grounds") are robust to the whole bias.
* **§9.7's family shares transfer essentially unchanged**, because they are shares of
  *sampled guest PC*, not of interpreter stage. Where the guest's PC is does not depend on
  what the interpreter costs. **This is the most transferable measurement in the document**
  and it is one reason §11.1 goes first.

The 29.0 % sampler gap is an upper bound on the total misallocation and it cannot be
decomposed from these captures.

### 10.2 There is no lean bucket profile, and there cannot be one from this instrument

The buckets *are* the instrumentation; arming them is what costs 46 % of the armed run.
Closing this gap needs a different instrument — ARM PMU event sampling, or a statistical PC
profile of the lean build correlated against the stage map — not a better dump. Unchanged
from v1 §4.2, and still true.

### 10.3 `probe_cyc = 59` is above the predicted band, and the landing model no longer checks out

Two instrument questions, and they are entangled. **Neither materially moves the map**
(§8.5), and both are named here so the next reader does not re-derive them.

**(a) The price.** The firmware's out-of-line calibration reports 59 cyc/transition, which
the session notes flag as sitting above the 45.5–58 band `docs/profiler.md` predicted. At
59 the subtraction is impossible (§8.3). **Does it change any share materially? No.** The
ranked rungs move by at most 1.2 points between 50 and 59, the order is identical, and the
only buckets that move more are `LOOP` and `TAILADV` — both of which go *toward zero*,
which is the direction that removes them from consideration rather than promoting them. The
one thing 59 does change is the *verdict on `LOOP`*, from "0.51 %" to "0.00 %", and both
readings say the same thing operationally.

**(b) The landing model.** v1's model predicted the firmware's exact `TRANSITIONS` count to
**12 parts per million** — the strongest single piece of evidence in v1. The v2 model
predicts 1 156 199 902 against a measured 1 048 688 485: **+10.25 %**. That is inside the
tool's 25 % tolerance, so the subtraction is applied, but it is a four-order-of-magnitude
degradation and it deserves naming rather than passing.

The overshoot is exactly **107 511 417 transitions = 1.166 per guest instruction = 0.583
bucket visits per instruction**. Framed against the firmware's own documentation: the tail
split is documented to add **4** transitions per guest instruction, and the measurement
shows it added **2.83** (measured 11.3728 transitions/insn, against 8.5388 for the same
counters under v1's model).

Two candidate causes were tested against the firmware source, and **both are refuted**:

* *"`TAILSAMP` is cadence-gated."* No. `Z3660_PROF_RUNLOOP_SAMPLE` brackets
  `enter`/`exit` unconditionally around the sampler tick and the `INSNS` counters.
* *"`TAILPOLL` is cadence-gated."* No. `Z3660_PROF_TAIL_POLL` wraps the **whole**
  `Z3660_RUNLOOP_TAIL()` macro, cadence gate included, so the gate skips the work and not
  the transition — exactly as the symbolizer's model assumes. `HANDLER` and `TAILADV` are
  likewise unconditional, once per instruction. **The shortfall is not in the tail split.**

The remaining candidate, which reconciles the count *exactly*, is the **instruction-fetch
bracket**: `FETCHOP` and `FETCHEX` share one bracket (`Z3660_PROF_ENTER_IFETCH`, with a
hint flag choosing the bucket), entered once per accessor **call**, while the model derives
their entry counts from `FETCH`, which counts **words**. 93 626 748 calls against 147 382 456
words reconciles the transition count to within 1. It is a hypothesis, not a finding — a
longword extension fetch counting two words in one call would produce exactly this, and
nothing in the capture distinguishes it from the alternatives.

**Direction, which is what matters for the map:** if the ifetch hypothesis holds, the model
over-charges probe to `FETCHOP`, `FETCHEX` and `LOOP`, so **rung 1's share is understated
in §8.4** — by up to 4.3 points (§8.5, column recon-B). Every available correction makes
the top rung larger. **The fix is one counter**: an `IFETCH_CALLS` id incremented in
`Z3660_PROF_ENTER_IFETCH`, which would turn the model's largest term from a derivation into
a measurement and restore v1's parts-per-million check.

### 10.4 The stage span is not a pure dhrystone workload

`06-STAGE-profd` reports **61.57 %** supervisor instructions — a mixed system-plus-benchmark
span. The shares are representative of "the machine running a compute benchmark under a
live SVR4 kernel", not of dhrystone. Unchanged from v1 §4.3, and the figure barely moved
(61.97 % → 61.57 %), which is itself a small reproduction.

### 10.5 The DHRY window is not a pure dhrystone window either

15.99 % of it is `swtch` + `idle` — the machine around the benchmark, not the benchmark.
Busy-only figures are given alongside every all-samples figure in §7.3 for that reason.
This is a large improvement on v1 (62.49 % idle, and the workload itself entirely absent)
but it is not zero, and the DHRY opcode and concentration figures should be read as "a
compute benchmark under a live kernel", not "dhrystone".

### 10.6 Reclaim fractions are engineering estimates

The shares are measured; the reclaim column is not. Every dhry figure in §9 inherits that
softness. **They rank rungs; they do not forecast releases.** §11 exists precisely so that
the first two get a *pre-registered* number to be judged against, rather than being
retro-fitted to whatever the change turns out to deliver.

---

## 11. THE FIRST IMPLEMENTATION ORDER

> **⚠ BOTH ITEMS WERE BUILT.** §11.1 became rung 0 and §11.2 became rung 1; see §14.1 and
> §14.2 for what they measured against what is pre-registered here. **Kept unedited**,
> because the value of a pre-registration is entirely in not being revised after the result:
> §11.2's *"a high hit rate with a low speedup is the expected failure mode"* is the sentence
> rung 1b then demonstrated, and §11.1's *"the first thing to check is the TRIGGER, not the
> host operation"* is the check the mean-chunk-length row exists to make.

Two items, in this order. Each is written to be dispatched as-is.

### 11.1 FIRST — the block-idiom fast path, starting with `bzero`

**What to build.** A recognizer in the 68040 run loop that detects a small set of tight
kernel block loops at dispatch time and services the whole run in one host operation
instead of one guest instruction at a time. Ship it in stages, each independently
measurable:

| stage | idiom | trigger | host operation |
|---|---|---|---|
| **A** | `bzero` | opcode `20c9` (`MOVE.L An,(A0)+`) with `51c9`/`51cx` (`DBcc`) at `pc+2` whose displacement targets `pc` | bounded `memset`-equivalent |
| **B** | `mcpy` | `22d8` (`MOVE.L (A0)+,(A1)+`) with the same `DBcc` shape | bounded `memcpy`-equivalent |
| **C** | `Lcb_loop` | `f468` (`CPUSHL (A0)`) + `d0fc` (`ADDA.W #n,A0`) + `DBcc` | one page-cache invalidation for the whole range, then skip the loop |

Stage A alone is the largest single identified target in the document. Stage C is the
cheapest, because the loop's architectural effect on this platform is at most one
invalidation.

**Where.** Firmware side: `Z3660_emu/src/uae/newcpu.cpp`, in `m68k_run_mmu040`, at the
point where the opcode has been fetched and before the `cpufunctbl[regs.opcode]` dispatch —
the site that today reads `Z3660_PROF_ENTER(Z3660_PROF_B_HANDLER)`. The recognizer is keyed
on the **opcode pair**, never on a PC or a symbol: it must fire for any kernel that
generates the same loop, and it must not need to know it is looking at `bzero`.

**Pre-registered expected gain.** Judge the change against these, not against whatever it
produces:

| | share attacked | stage A only | A + B + C |
|---|---|---|---|
| boot window (163.8 s measured) | 22.07 % → 31.80 % | **135 s** | **122 s** |
| dhry (4486 measured) | 1.57 % → 9.66 % | **4543** | **4862** |
| raw disk read (829 kB/s measured) | 2.23 % → 12.97 % | **844 kB/s** | **925 kB/s** |

Derived from the §9.7 shares of `bzero` (A), `+ mcpy` (B) and `+ Lcb_loop` (C) at an
**80 % reclaim** — 80 % and not 100 % because the recognizer must still pay a per-entry
test and a per-chunk re-entry. Extending the recognizer to the whole §9.7 family (adding
the `MOVES` cross-space copies, 33.63 % of boot and 25.11 % of the IO workload) would take
boot to ~120 s and the disk read to ~1037 kB/s; that is the size of the prize, not the
pre-registration. **A result below the stage-A boot figure means the recognizer is not
firing where the profile says the time is, and the first thing to check is the trigger, not
the host operation.**

**Harness guard shape.** Host harness (`Z3660_emu/test/host`), a new test file beside
`amix_ram_test.cpp`, driving `m68k_run_mmu040` directly as the existing tests do. The
assertion is **state equivalence, not spot checks**: for each of a corpus of start states,
run the idiom once through the recognizer and once with the recognizer compiled out, and
assert the register file, the affected memory, the fault outcome and the guest PC are
byte-identical. The corpus must include, at minimum:

* `n = 0` and `n = 1` (the `DBcc` boundary conditions, where an off-by-one is invisible in
  a large fill);
* a run that **crosses a guest page boundary**, and one where the *second* page is
  unmapped — the fill must fault at the same guest PC, with the same fault address, and
  leave `A0`/`A1`/`D1` exactly where the per-instruction path would, because the 68040 uses
  full instruction restart;
* supervisor and user space — and a `MOVES`-space variant if the recognizer is extended to
  the `lcolloop`/`uvbzero` cross-space copies, whose accesses use the source-function-code
  space rather than the current one;
* a run whose destination is **not plain RAM**, which must fall back to the slow path
  rather than fast-path a device write;
* for stage C, a flush over a range that is currently in the `ipagecache`, asserting the
  invalidation actually happened.

Plus a bench guard: re-run the boot profile and assert the `bzero` share **falls below
3 %**, which is a stronger check than a wall-clock number because it says the time went
away from the place the map said it was.

**Risk.** Three, in order of severity.

1. **Fault semantics.** A fill interrupted mid-run must leave the guest exactly as the
   instruction-at-a-time path would. This is the one that can corrupt a filesystem rather
   than merely be slow, and this repository has already paid for the general lesson once —
   a page-crossing DMA that clipped an unrelated frame was invisible until it ate an ELF
   header. **Chunk at the page boundary and never fast-path across one.**
2. **Interrupt latency.** A long fill is uninterruptible. Chunk it so the run loop's poll
   still runs at its normal cadence — one page per chunk bounds the stall at ~1024
   iterations' worth of work.
3. **Coherence.** The fast path must perform the same page-cache invalidation the normal
   write path performs. A fill that bypasses the `dpagecache` write path leaves stale
   entries, and a stale entry is a wrong read with no symptom at the point of the bug.

### 11.2 SECOND — the decoded-op cache

**What to build.** A PC-indexed cache holding the result of fetch-plus-decode, consulted at
the top of the 68040 run loop before `x_prefetch`. Each entry holds the opcode word, the
resolved handler pointer, the instruction's extension words, its length, and a validity
stamp. A hit skips the instruction-stream fetch and the decode entirely.

**Where.** `Z3660_emu/src/uae/newcpu.cpp`, `m68k_run_mmu040`, around the
`Z3660_PROF_MARK_OPFETCH()` / `x_prefetch` step — the fetch this map prices at 78.2 cycles
per opcode word plus 85.2 per extension word.

**Sizing, from the measurement and not from a guess: 4096 entries, 4-way, ~64 KB.** §9.1's
table is the whole argument: 2048 entries covers 79.6–86.0 % of busy time depending on
workload, 4096 covers 90.4–92.4 %, and the IO workload is the one that decides it. Index on
`(pc >> 1)`, tag on the full guest PC **plus an address-space/generation stamp** so a
context switch cannot alias.

**Pre-registered expected gain.** Rung 1's measured share is 28.65 % (bracket 25.6–32.9).
At the estimated 50 % reclaim: **dhry 4486 → 5236**. Pre-register three numbers, because
the middle one is what distinguishes a working cache from a working *and worthwhile* cache:

* **hit rate ≥ 88 %** on a dhrystone run and **≥ 85 %** on the raw-disk-read workload;
* **dhry ≥ 5000** (a 33 % reclaim — below the estimate, above the noise);
* the stage profile re-taken afterwards must show `FETCHOP + FETCHEX` **below 18 %**.

**A high hit rate with a low speedup is the expected failure mode**, and it is the reason
the hit rate is instrumented rather than assumed: it means the hit path's tag check,
bounds check and translation-validity check cost as much as the fetch they replace. That is
the §9.1 caveat, and the counters are what turn it from a worry into a measurement. Add
`DOPC_HIT` and `DOPC_MISS` as **appended** counter ids (the id space is append-only — a
reordering silently relabels every previous capture) so the next `PROFD` reports them.

**Harness guard shape.** Host harness, driving `m68k_run_mmu040` over a corpus of
instruction streams with the cache enabled and disabled, asserting identical register,
memory and fault outcomes. Three cases are mandatory and none of them are ordinary:

* **Self-modifying code.** Write into a page that has cached entries, then execute it. The
  guest must see the *new* instruction. This is the failure that produces a working system
  that goes wrong hours later.
* **Invalidation on `CPUSHL`/`CINV`/`PFLUSH` and on any MMU root or `TC` change.** A stale
  decoded op after a context switch is the same failure with a different trigger. Note the
  interaction with §11.1 stage C: collapsing the `CPUSH` loop must still invalidate.
* **DMA into an instruction page.** The emulated devices write guest memory outside the
  interpreter's write path; whatever invalidates for them must cover the decoded-op cache
  too.

**Risk.** Coherence is the whole risk surface, and it is asymmetric: a cache that
invalidates too eagerly is merely slower, while one that invalidates too little executes
instructions the guest has already overwritten. **Start conservative — invalidate the whole
cache on any event that could plausibly matter — measure the hit rate, and only then narrow
the invalidation.** The secondary risk is that 64 KB of ARM RAM competes with the tier-0
page caches for L2; the pre-registered hit-rate figures are per-workload for that reason,
since the IO workload is the one that stresses both at once.

---

## 12. What C2 should measure next

> **⚠ SUPERSEDED BY §19**, and four of the six below are now struck. **1** (sweep
> `service_cadence`) is banked: cadence 4 is the standing posture, measured at +16.70 %.
> **2** (add `IFETCH_CALLS`) was done, and then *superseded by the per-bucket spans that
> refuted the method it was added to serve* — §16.1. **3** (re-calibrate `probe_cyc = 59`)
> was answered: the price is a measured per-boot range, and the "59 does not fit" problem was
> a picked number rather than a measurement — §16.2. **5** (cost the tier-0 `ipagecache` hit
> path) is subsumed by rung 1, which replaced that path on a hit. **4** (a pure-workload DHRY
> ring) and **6** (a lean-build statistical PC profile) are still open and still worth doing.

In priority order. **Items 1–5 of v1's §5 list were all done between the two sessions**
(re-take the workload rings; split `TAIL`; recalibrate the probe out of line; fix the 2×
over-pricing; fix `ATC_HIT` and the tool's cross-check) and are struck. Its item 6 — cost
the `bzero` idiom fast path — is §11.1 above. What follows is new.

1. **Sweep `service_cadence`** over 1, 2, 4, 8, 16, recording dhry, the raw-disk-read rate
   and an interrupt-latency proxy at each point. This converts rung 2 — 19.6 % of
   interpreter time, and the rung that transfers to lean most cleanly (§10.1) — from an
   estimate into a measured trade-off curve. It needs no code, only bench time.
2. **Add an `IFETCH_CALLS` counter** (§10.3b). One appended counter id restores the
   landing model's parts-per-million check and settles whether rung 1's share is 28.65 % or
   nearer 33 %.
3. **Re-calibrate, or explain, `probe_cyc = 59`** (§8.3). It is above the band the
   firmware's own documentation predicts and above the price at which the subtraction is
   possible. Either finding is useful; the present state — a measured number that cannot be
   used as measured — is not.
4. **Take a pure-workload DHRY ring.** 15.99 % of the current one is the machine around the
   benchmark (§10.5). Arm, run, and stop with `PROF OFF` inside the benchmark's own wall
   time rather than around it.
5. **Cost the tier-0 `ipagecache` hit path directly** (§9.1). At a 96.6–98.5 % hit rate the
   78-cycle opcode fetch is dominated by the hit path, and that single number is what makes
   rung 1's reclaim estimate soft.
6. **A lean-build statistical PC profile** to correlate against the stage map (§10.2) —
   the only route to a share that is not of the distorted machine.

---
---

# PART III — v1, 2026-08-22 morning (SUPERSEDED)

**Kept, not deleted.** Everything below was written the same day from the first metal
profiling session, before the clean re-take. §6.2 above lists what moved and why. Three of
its conclusions were refuted by better data (`LOOP`'s share, the PC-concentration curve, the
top-20-opcode reach) and two of its *predictions* were confirmed by measurement (`LOOP`
would exhaust at ~58 cyc/transition; `ATC_HIT` counts translate successes). Both kinds are
why it stays.

Its original framing follows verbatim.

---

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
