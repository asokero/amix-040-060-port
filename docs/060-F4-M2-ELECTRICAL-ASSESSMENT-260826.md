# F4-M2: an electrical/timing-marginality vs software assessment, weighed across the campaign

2026-08-26.  The BLIZZARD F4-M2 campaign set out to explain why `init`'s `ucontext` is corrupted
into a `SIGKILL` on a real 68LC060, and it has spent attempts 3–8 refuting **software** mechanisms
one by one.  This document does what no single attempt was allowed to: it **weighs the whole
campaign's evidence** on the one question the per-round pre-registrations kept deferring — is the
residual defect an electrical/timing marginality, or a software fault these probes have not yet
cornered — and it says, cheap experiment first, what would decide it.

**This is an assessment, not a verdict.**  `…ATT6-PREREG…` §5.2 registered that these instruments
*cannot* make the cut and that "a null result on all of §5.1 is not evidence for software"; that
rule is not repealed here.  What has changed since it was written is that the leading *software*
hypotheses are now individually refuted (attempt 7, attempt 8), so the balance of evidence has
moved even though a decisive experiment has not yet been run.  §6 states plainly where it cannot be
called and what one experiment calls it.

**LICENSING.**  This document refers to the *structure* of the stock `savecontext` /
`restorecontext` / `sendsig` / `setcontext` `ucontext` round trip (the `copyout`/`copyin` path,
the checksum, the dead field).  Descriptions and offsets only, **no disassembly listing**, but it
inherits the flag of the documents it rests on: **not for the `z3660` branch.**

---

## 1. Why weigh it now: every software mechanism the campaign advanced is refuted

The campaign has proposed, and killed, a software mechanism per round.  The list is the reason a
weighed assessment is now honest rather than premature.

| software mechanism | proposed | refuted by |
|---|---|---|
| a lost register file (a `ucontext` round trip dropped a register) | attempts 3–6 premise | **att7 §7** — the register file is at `ucp+0x24`, *outside* the checksummed region; the corruption is in `mc_state`, which never holds a register |
| the leaked bytes changed by themselves; the checksum is the whole bug | att7 reading (a) | **att7 §8.1** — the restore-time bytes were `copyin`'d from user memory that was `copyout`'d from a *different* kernel buffer a signal earlier; nothing the kernel does to its own stack can reach them, and the object is inconsistent with its **own** stamp |
| the format-nibble bridge (`prsetstate` sizes a `bcopy` to 0 on a corrupted nibble) | att8 §2, "strongest result available" | **att8 R5** — `ucp_fmt_bad_n = 0` over 100k+ restores; every flip is in the dead field, never on `mc_state[1]`; the bits-12–15 confinement is a bit-*position* fact, not a frame-*format* fact |
| an invisible even-parity population the XOR fold cannot see (the checksum misses most events) | att7 §8.3 open question | **att8 R1** — the rotating fold caught 0 over 145,675 restores while the plain fold caught 4; the scored events are the whole population |
| disclosure-zeroing removes the fault (C1 as a cure) | att8 Arm II candidate | **att8 R14** — all four Arm II boots zeroed cleanly and none reached multiuser; `00000000 → 00002000` still breaks the fold |
| a lost `.data` store / non-atomic increment / cache lying to the checksum | att6 §5.1 signatures | **att6 §4** — all six "software cannot produce this" probes read negative on frozen boxes; `kvd_n == kvfar_n` **exactly** on three separately frozen machines, no lost store |

What is left after all of them is a single, stubborn **residual signature**, described next.  The
assessment is a reading of that residue.

---

## 2. The platform's electrical surface, and the clock the campaign actually ran at

The class list is `docs/PLATFORM-LC060-Z3660.md`; this is the subset that bears on marginality,
with the numbers read back on the attempt-8 boots (`…ATT8-RESULTS…` §2).

* **Real socketed 68LC060, 50 MHz-rated, running at its rated PCLK 50 MHz.**  Not overclocked this
  session (an SD `env/cpufreq` overrides the config's 100 down to 50; `PCLK 050.00 MHz` read back).
* **Motherboard clock correct at 25 MHz.**  `BCLK/CPUCLK/CLK90 025.00 MHz` — the index-0
  12.5 MHz motherboard-half-speed defect (the campaign's one *found* timings bug,
  `…PLATFORM-LC060-Z3660…` §2.4) is **not** in force on these boots.  So the wall is not that bug.
* **RAM is Zynq DDR behind an FPGA, not a local 68k bus.**  This is the electrical surface no `HW`
  row in the project has.  The 68LC060's memory cycles cross **four clock domains** on the way to
  and from DRAM: `PCLK 50` (the CPU), `CLKEN 25` / `BCLK 25` (the motherboard interface),
  **`AXICLK 100`** (the FPGA fabric), and **`DDR 533`** (the memory).  Every domain crossing is a
  place a single data line can lose a setup/hold margin.
* **Real copyback data cache, for the first time.**  Neither emulated class models the 68040/68060
  copyback cache; this is the only class in which it, and the drivers' cache maintenance, actually
  execute (`…PLATFORM-LC060-Z3660…` §2.2, §3).
* **`AXICLK` is 2× `PCLK` and rises with the clock index.**  At Clock index 0 the fabric is
  100 MHz; a higher index raises it (toward 200 at the 100 MHz PCLK index), coupled to `PCLK` —
  which is the confound §5's clock experiments must handle.

The corruption is only ever *observed* in the `ucontext` dead field because that is the only
kernel object that is checksummed **and** round-tripped through user memory at ~190,000 times a
boot — the one place a rare transfer-time flip both accumulates exposure and is caught.  Observed
locus is not the same as mechanism locus; §4 separates them.

---

## 3. The weighed evidence table

Each row: the observation, which way it points, and how much weight it can honestly bear.

| # | observation (all measured on metal unless noted) | points | weight, and the caveat |
|---|---|---|---|
| E1 | **The wall is silicon-only.** The whole F4-M2 wall has never reproduced on either emulated class; att8 boot 2 records the *same* `ucz` image reaching multiuser on Amiberry Rig A while metal walls | **electrical** | **high, but not single-variable** — the emulator differs from metal in the cache, the FPGA bus and DDR all at once. It says "not a portable software logic bug"; it does not say which physical element |
| E2 | **Every flip is a single bit, always SET (0→1), never cleared** — 10/10 in att7, 4/4 in att8 | **electrical** | **high** — a software logic bug has no reason to be monotone; a stuck/leaky line or a one-sided coupling does |
| E3 | **Confined to bit positions 12–15**, indifferent to the longword's meaning (att7 samples were `sigtoproc+0x2A`, `clock+0x3F4`, a COMMON pointer, a non-address, `usrxmemflt+0xF6` — unrelated content, same bit field) | **electrical** | **high** — this is exactly `…ATT6-PREREG…`'s registered "bit-position / electrical" signature: unrelated content, the same bit positions recur. Software keyed to *content* would not confine to a bit index |
| E4 | **The format-nibble software consumer is refuted** (att8 R5): the 12–15 confinement is a bit-*index* fact, not a frame-*format* fact — there is no software semantics on those bits | **electrical** | **high** — removes the one software reading that explained the 12–15 confinement |
| E5 | **Address/position-keyed, not value-keyed** (att8 §7): within one frame, identical values at different positions flipped or not | **electrical** | **medium** — inferred from frame periodicity, not a measured save-side; round 9's first job is to make it decisive |
| E6 | **Variable occurrence, deterministic content** on byte-identical inputs: wall count 837/191/0 (att6), 4/8 (att7), 1/8 (att8), always bit-12–15, always set | **electrical** | **high** — a deterministic software bug on identical inputs gives identical results; software *non*determinism (interrupt timing) can vary the rate but does not explain the fixed bit-field/direction. Variable rate + fixed content = a marginal physical element exercised a variable number of times |
| E7 | **Survives a full software round trip** (`copyout → user → copyin`, two 1 KB `bcopy`s through the FPGA bus): the flip appears between a kernel save buffer and a *different* kernel restore buffer (att7 §4) | **electrical (transit)** | **high** — no in-kernel software step touches the bytes between the two buffers; the only actors on that path are the bus, DRAM and the cache |
| E8 | **All six att6 software-signature probes negative on frozen boxes** — no lost `.data` store, twin counters equal to the digit, fold-stability, `cinvl`, static `swa` operands | **electrical (by exclusion)** | **medium** — `…ATT6-PREREG…` §5.2: a null on these is *not* evidence for software; it is the absence of the software fingerprints |
| E9 | **Thermal is flat and weak** — 51–55 °C across att8, Δ ≤ +4 °C, and warm/cold latch asymmetry was an exposure artefact (att7 §10) | neutral / mild electrical | **medium** — temperature is not the modulating variable; if it were purely thermal the flat trace would predict a flat rate. Does not distinguish bus-marginal from software |
| S1 | **The flip is always in the leaked/dead field** — a real defect surface, kernel pointers | *appears* software | **low** — this is an **observability bias** (E2 note in §2), not a mechanism clue: the dead field is simply the only checksummed, round-tripped object |
| S2 | **`init`-specific / one process** | *appears* software | **low** — `init` is the first and heaviest signal user; exposure, not specificity. A canary (§5) tests whether other memory is affected |
| S3 | **The early deterministic boot phase is not visibly corrupted** — Table-N slots identical across boots | *appears* software | **medium** — the real open question. A purely address-random DRAM fault should sometimes hit the deterministic structures too, and we do not see that. Counters: early boot does not checksum-and-round-trip data, so a flip there either crashes hard (varied crashes, not seen) or passes unnoticed; and the `ucontext` path has orders of magnitude more transfer exposure. Weakened but not eliminated — this is precisely what the canary settles |

**The balance.**  Seven observations of real weight point electrical (E1–E8), one is neutral (E9),
and the three that *look* software (S1–S3) are two observability biases and one genuinely open
question (S3).  **The evidence leans electrical, and specifically toward a transfer-time (bus/FPGA
path) marginality on a small group of adjacent data lines** — but "leans" is the honest word, and
§6 says why it is not "called."

---

## 4. The specific physical questions, answered as far as the evidence allows

### 4.1 Does bit 13 correspond to a physical line — DRAM/address, cache index, or data bus?

* **Not an address line.**  An address-line fault fetches a *whole wrong longword* from a wrong
  location, not a single-bit delta of the correct value.  Every event is the correct value with
  one bit set — so the fault is on the **data** path, not the address path.
* **Not a cache *index* bit.**  The 68060 data cache is 8 KB, 4-way, 16-byte lines → 128 sets, so
  the set index is address bits `[10:4]` and the tag is `[31:11]`.  Bit 13 of a *value* is neither;
  a cache-index fault would again mis-associate whole lines, not set one data bit.  (A cache *tag*
  comparator fault is not excluded by this argument, but it too would return wrong lines, not a
  1-bit data delta.)
* **A data-bus / DQ line, in byte lane 1.**  Bit 13 of a 32-bit longword is `DQ13`, in the upper
  nibble of byte lane 1 (bits 8–15).  The attempt-7 cluster {12, 13, 15} — with 14 shown to be an
  n=1 artefact (att7 §8.2 S3) — is **the four adjacent lines `DQ12–DQ15`**, i.e. the whole upper
  nibble of one byte lane.  A marginal setup/hold, or a one-directional coupling, on that adjacent
  DQ group at one of the domain crossings (§2) produces exactly a single-bit, always-set,
  content-indifferent flip in that field.  **This is a hypothesis with a test** (§5, the data-line
  walk), not a conclusion: the exact DQ↔bit mapping through the AXI→DDR data path is not documented
  and must be measured, not assumed.

### 4.2 Is the corruption at the storage location, or in the copyout/copyin transit?

This is the sharpest open sub-question and round 9's multi-point read is built for it.  The frame
lives at, and moves through:

```text
  A  savecontext buffer K_send   (kernel DRAM)      <- built here
  B  user copyout destination U  (user DRAM)        <- after copyout: A -> bus -> B
     ... user handler runs; U sits at rest ...
  B' user source U just before copyin               <- rest-dwell test: does U change untouched?
  C  restorecontext buffer K_set (kernel DRAM)      <- after copyin: B' -> bus -> C
```

* If the value is clean at A and B but corrupt at C → the flip is in the **copyin transit**
  (bus/FPGA read of user DRAM → kernel write).
* If clean at A, corrupt at B → the **copyout transit**.
* If B == B' but a transit segment flips → **transit-marginal (bus/FPGA)** — the resting DRAM is
  fine, the *transfer* is not.  This is the reading E7 already leans toward.
* If B != B' with U untouched by any code → **storage-marginal (DRAM cell retention)** at that
  physical address.
* If A, B, B', C are all clean yet the fold still fails → the residue is back in software/checksum
  territory, and the electrical lean is wrong.

Attempt 8 read only A and C and could not split them.  Round 9 reads all four (`…ATT9-PREREG…`
§4.2).  **This is cheap** — instrument code that rides the same boots — and it is the single most
informative non-gated experiment on the table.

### 4.3 The coherency class: bit 13 of a value vs bit 13 of an address

The distinction matters because the FPGA-mediated bus has a **snoop gap** (`…PLATFORM-LC060-Z3660…`
§2.3): `/SNOOP` does not cover ARM-side DMA and may be a no-connect on this board revision.  The
corruption we see is bit 13 of a *value* (§4.1), which is a data-transfer phenomenon, not an
address-decode one — so the snoop gap is not the direct cause of *this* flip.  But the snoop gap
and a transfer-time DQ marginality are the same family (an FPGA/bus path the campaign has already
found to be under-specified and under-covered), and a coherency A/B is a legitimate secondary probe
if §5's transfer test points at the cache rather than the raw bus.

---

## 5. The decisive experiments, cheapest first

Ordered by cost.  The first three are pure instrument work that rides existing boots and needs no
card change and no user gate; the fourth is the gold-standard marginality test and is user-gated.

1. **Multi-point read + content-triggered freeze (round 9, no gate, cheapest).**  Reads the frame
   at A/B/B'/C (§4.2) and freezes the true save-side of the *failing* frame keyed on a durable
   identity.  Settles value-vs-address decisively (E5 → measured) and localizes the flip to a
   transit segment or to resting DRAM.  **Does not by itself separate electrical from software** —
   but it converts "leans transit" into "the flip is provably in the copyin bus segment" (or
   wherever it lands), which is nearly dispositive when combined with (2).

2. **A resident memory canary, cached and cache-inhibited (round 9 option, no gate, cheap-ish).**
   A kernel-resident block written once with a known pattern and re-verified periodically, in
   **both** a cached and a cache-inhibited mapping.  This is the cleanest non-gated electrical
   probe there is:
   * a bit flip in a region **nothing writes** cannot be a software logic bug — software cannot
     corrupt memory it never touches;
   * the cached/uncached pair separates "the RAM cell changed" (both flip) from "the cache lied"
     (only the cached copy flips);
   * a canary that is **clean** over the same exposure that produces `ucontext` flips is itself a
     strong result — it says the fault is specific to the *transferred* object, i.e. transit-marginal
     rather than a universal DRAM retention fault, and it answers S3 (does the deterministic,
     never-rewritten region get hit?).
   Its one cost is a periodic hook (a clock-tick driver), which is a base change; that is why it is
   an *option* for round 9 rather than the primary, but it is the strongest cheap decider.

3. **The N-boot outcome distribution (no gate, cheap in code, costs boots).**  ≥10 boots of one
   image from one gated disk, scoring only the outcome class and the per-*restore* rate (not per
   boot — att7 §10's exposure fix).  A software race gives proportions stable across sessions; a
   marginality gives proportions that move with a physical parameter.  This is the prerequisite for
   (4) because (4) is a comparison of two such distributions.

4. **The physical-parameter sweep — the gold standard, USER-GATED, the experiment that *calls*
   it.**  Vary one physical parameter, keep the software byte-identical, and watch the rate:
   * **de-rated `default_timings` A/B** — relax the DDR/interface setup-hold margins at the
     standing clock index and re-run the N-boot protocol on each arm.  A card-side file change; a
     **user gate, not an agent decision**.  If the corruption rate moves with the timing, the cause
     is timing-marginal — full stop.
   * **clock / AXICLK sweep** — the N-boot protocol at the standing PCLK 50 (AXICLK 100) and at a
     step that changes the fabric margin.  Note the confound: raising the clock index raises AXICLK
     *and* PCLK together, so a clean AXICLK-only sweep needs the timing table's divider fields
     edited independently, whose firmware semantics must be confirmed first.  Also user-gated.

   **This is the single experiment that converts "leans electrical" into "is electrical."**  A
   monotone rate response to a de-rated bus timing, with the software fixed, is the definition of a
   marginality and cannot be produced by any software mechanism.  It is designed in full in
   `…ATT9-PREREG…` §8 and is **not run and not enabled** here — the timings file is a standing user
   gate.

---

## 6. The honest verdict

**It cannot yet be called, and here is the exact state.**

* The **software** side has been reduced to a residue by refutation, not by a null: every specific
  software mechanism the campaign named is dead (§1), and the software-fingerprint probes are all
  negative (E8).  What is left of "software" is only the two things a null cannot exclude —
  ordinary software nondeterminism that these probes do not cover, and a software fault in a path
  not yet instrumented — and `…ATT6-PREREG…` §5.2 forbids reading that absence as a positive.
* The **electrical** side has seven observations of real weight (E1–E8), a coherent physical
  hypothesis (a transfer-time marginality on the `DQ12–DQ15` group across the FPGA/DDR domain
  crossings, §4.1), and a locus lean (transit over storage, E7/§4.2).  But it has **no experiment
  that has varied a physical parameter and shown the rate move** — and that experiment is the only
  thing that turns this constellation of signatures into a called result.

**The current best estimate, stated as an estimate:** the residual defect is most likely an
electrical/timing marginality in the FPGA-mediated memory transfer path, biased toward a small
group of adjacent data lines.  The campaign should stop proposing software mechanisms — the
refutation list is complete enough — and instead spend the next boots on **localizing** the flip
(round 9, cheap) and then, on the user's go, on the **one experiment that decides it**: a de-rated
`default_timings` A/B under the N-boot protocol (§5.4).  If that A/B moves the rate, the question is
answered electrical; if a clean canary flips uncached bits while the timing A/B does nothing, the
answer is still electrical but *storage* rather than transit; and if neither moves and the multi-point
read finds the frame clean at every point, the electrical lean is wrong and the residue is back in
software — which is the outcome this document is most careful to leave reachable.

---

## 7. What this assessment does NOT claim

* **It does not declare the bug electrical.**  It weighs the evidence and names the deciding
  experiment; it does not pre-run it.
* **It does not repeal `…ATT6-PREREG…` §5.2.**  A null on the software probes is still not evidence
  for software; the weight here comes from *refutations* plus *positive* electrical signatures, not
  from the nulls alone.
* **It asserts no exact `DQ`↔bit mapping.**  §4.1 is a hypothesis with a test, not a measured pin
  map; the AXI→DDR data-path ordering is undocumented.
* **It enables no card-side change.**  The `default_timings` A/B and the clock sweep are designed
  (`…ATT9-PREREG…` §8) and remain a user gate.
* **It says nothing about a cure.**  A marginality, if confirmed, is cured on the *card* (timing,
  clock, board), which is outside this repository; a software mitigation (fold only the written
  region) trades detection for survival and is a separate decision (`…ATT8-PREREG…` §6).

---

## 8. Files

```text
docs/060-F4-M2-ATT8-RESULTS-260826.md    the readings weighed here (R1/R5/R14, §7, §9)
docs/060-F4-M2-ATT9-PREREG-260826.md     the localizer (§4.2) and the designed timings A/B (§5.4)
docs/060-F4-M2-ATT6-PREREG-260825.md     §5.2 the standing "cannot separate", §5.3 the four separators
docs/060-F4-M2-ATT7-RESULTS-260825.md    §4 the round-trip path (E7), §8 the signature (E2/E3), §10 warm/cold (E9)
docs/PLATFORM-LC060-Z3660.md             §2.2 real cache, §2.3 the bus + snoop gap, §2.4 the clock domains
```
