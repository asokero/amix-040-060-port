# C2 attack map — where the interpreter's time actually goes

**How to read this file.** It has two parts, newest first.

* **Part I — v2 (§§6–12)**, below, is the current map. It is derived from the *clean*
  metal captures of 2026-08-22 evening (`C1v2`), through the v2-capable symbolizer.
  Every ranked number in this document is a v2 number.
* **Part II — v1 (§§0–5)**, further down, is the first map, written the same day from
  the morning's captures. It is **superseded but kept**, per `docs/METHOD.md` §8: a
  refuted conclusion is evidence about the instrument, and deleting it would delete the
  reason the v2 numbers are believable. §6.2 lists what moved and why, item by item.
  Where the two disagree, **v2 wins**, and §6.2 says which of v1's inputs was wrong.

---

# PART I — v2, 2026-08-22 evening

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
  ×1.65 correction applies to any number in Part I.** (§0.1 applied one to every rate and
  duration in Part II; it never touched a share, because a wrong constant cancels out of a
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
| 5 | **Clock label** | ×1.65 correction applied to every rate and duration | none needed | `clk=cfg`. No share in Part II was ever affected. |
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

# PART II — v1, 2026-08-22 morning (SUPERSEDED)

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
