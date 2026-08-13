# Real-hardware acceptance: ISSUE-42 on a 68040 — and the first dual-silicon image

**Machine:** Amiga 3000 + **A3640** (68040, 25 MHz), AMIX SVR4 2.1c, `solon` / 10.0.10.10
**Date:** 2026-08-13
**Image:** `build/unix-040`, build id `68040-260812-06` — the same image accepted on the 68060 the
day before (`REALHW-260812-06-ACCEPTANCE.md`)
**Loader:** `unix_boot040`

## 0. A hardware configuration this project had never run

Every previous 68040 acceptance in this project (2026-07-27, -07-31, -08-02) was on a **Mercury
68040**, which carries its own RAM at `0x08000000`. The A3640 has **no local memory** and runs
entirely from the A3000 motherboard fast RAM. Two consequences were predicted before the boot and
both held:

| Prediction | Measured |
|---|---|
| the loader binds the kernel into the motherboard region, not `0x08000000` | load base **`0x07000000`**; `/dev/mem` at `0x0810B128` returns `READFAIL errno=6` — there is no memory there at all |
| every counter address moves by −16 MiB | `wbf_magic` reads `57424621` at `0710B128` |
| `cputype` must be 40 on a real 040 | `0x28` |

`tools/status-facts.sh` was given a load-base parameter before the boot for exactly this reason
(`4736a80`). A pre-flight grep also confirmed that no override in this project hardcodes the load
base — `hat040.s` uses `&_start` with runtime `pages_base`/`pages_end`, and its comment already
anticipated both bank cases.

## 1. ISSUE-42 — closed on silicon

```
---- case a: one page, whole mapping protected            case a PASS: SIGSEGV
---- case b: two pages, aligned write INSIDE page 2        case b PASS: SIGSEGV
---- case c: two pages, write CROSSING into page 2         case c PASS: SIGSEGV
PROTFAULT fails=0
```

### The measurement that mattered most: the defect itself, on real hardware

`NEXT-040-SESSION-RUNLIST.md` recorded the open risk plainly: *"there is no real-68040 datapoint …
so an emulator artifact is a live hypothesis."* ISSUE-42 had only ever been observed under
Amiberry. One `.data` long settles it, in the same boot:

```
wbf_prop_on = 0   case c FAIL: "no signal, but the protected bytes are INTACT --
                                the store was denied and the denial was discarded"
                  wbf_fail_n 1 -> 2, wbf_swallow_n 0 -> 1
wbf_prop_on = 1   case c PASS: child terminated by SIGSEGV
```

**The silently torn store is a real 68040 defect, not an emulator artifact**, and the fix is what
removes it. This is the first time the original bug has been demonstrated on silicon.

### Attribution

```
  wbf_slot        3      the denial was in WB3
  wbf_fc          1      TM 1 = user data -> a user signal is the correct disposition
  wbf_user_n      2      wbf_sup_n 0     wbf_krn_n 0
  wbf_signal_n    2      wbf_nosig_n 0   -- the class came from the nested resolver
  wbf_afb_n       0      -- si_addr came from the CPU's own fault address, never the fallback
  wbf_alien_n     0      -- the landing pad never saw a stack it did not own
  si_signo 11 (SIGSEGV)  si_code 2 (SEGV_ACCERR)  si_addr c1034000 (page 2's first byte)
```

## 2. A genuine hardware/emulator divergence, and why it cost nothing

```
  wbf_addr (the replay pointer at the denial)
      emulated 68040   c1034001
      A3640 silicon    c1034000
```

The replay loop is `moves.b %d1,%a3@+`. Under Amiberry the post-increment has been applied by the
time the trap is taken; on real 68040 silicon it has not. Either value would have produced an
`si_addr` on the right page, so no test would have caught the difference — which is exactly the
shape of error that survives for years.

It cost nothing because the follow-up audit's correction was already in: `si_addr` is taken from
the **CPU's own fault address** in the format-7 frame, with the replay pointer kept only as a
**counted** fallback. `wbf_afb_n = 0` on both platforms says the fallback was never used, and
`si_addr` was `c1034000` on both.

The prediction that produced this design was wrong in its detail — the first version of the unit
assumed `a3` was the failing byte, and the emulator disproved that — and the fix chosen in
response happened to be the one that also survives the opposite hardware behaviour. Worth
recording: the robustness came from distrusting the register, not from predicting the CPU.

## 3. WB1 remains unexercised

`wb040.s`'s own verified comment says the emulators never set WB1S valid, so the WB1 path and its
ISSUE-11 bus-lane realignment could only ever be reached on silicon. **This run did not reach it
either**: `wbf_slot` = 3 on hardware as on the emulator. WB1 is still untested code, now on both
platforms, and that is a statement about coverage rather than about correctness.

## 4. Regressions taken in the same session

| Test | Result |
|---|---|
| `fp060probe` | `bad=0`, 7/7 bit-exact, 0 ulp — the 68040 FPSP works on this card |
| `cputype` | `0x28` (40) |
| memory | `availrmem` 3103 pages ≈ **12.7 MiB**, `freemem` 1176 pages ≈ 4.6 MiB |

The memory figure is consistent with the A3000 motherboard's 16 MiB window minus the kernel and
its metadata. Incidentally, this is the configuration in which the "AMIX 16 MB limit" is literally
true *of the machine* — and it is a property of the A3640 having no RAM of its own, not of AMIX.

## 5. Status after this run

`68040/68060-260812-06` is the **first image in this project accepted on both silicon**: on the
68060 (2026-08-12) and on a 68040 (2026-08-13, this document).

**Owed, and not attempted in this session:** the battery and the burst suite on the A3640. Neither
bears on ISSUE-42, but both are regression coverage for a card that has never run this kernel —
and copyback and burst were accepted on the *Mercury*, whose memory topology is different. That is
the first item of the next 68040 session.

---

## 6. Battery on the A3640 — added the same session

Driver: `test-tools/batteryrun10.sh`, **generated** for this image at load base `0x07000000` rather
than substituted from an earlier run — the reason being that on this card every counter address
sits 16 MiB lower than on every machine before it. It aborts on any magic mismatch before reading
a single counter; it did not abort, so all **nine** blocks were addressed correctly.

```
  proctest      PROCTEST-RESULT PASS   (T1-T7, both child cases: 10 sub-tests, bad=0)
  fputest       Test A PASS -- 040 hardware FP arithmetic correct
  msynctst      MSYNC-OK path=/msync_test.dat sz=65536
  bigargv       PASS 45 args 4500 bytes
  ptracepoke    PTRACEPOKE-RESULT PASS
  mul64test     MUL64-RESULT PASS
  bmaptest      BMAPTEST-RESULT PASS
  exectest 20   EXECTEST-RESULT PASS (data+bss verified across every generation)
  leaktest 50 1 fork_failures=0, 50 fork+exec pairs completed
```

No `FAIL` anywhere in the log. `leaktest` was initially invoked without its arguments by the
generated driver — a defect in the driver, not a result — and was re-run by hand.

### What moved, and what did not

Counter blocks diffed before and after the run:

| Block | Moved? | Reading |
|---|---|---|
| `wbf` | **no** | no write-back denial during the whole battery — the ISSUE-42 path is not something ordinary work reaches |
| `segvn_prot` | **no** | no per-page permission denial outside `protfault` |
| `i39` | **no** | no `hat_sdtalloc` contiguity failure under this load |
| `isp61` | **no** | vector 61 never fired — correct on a 68040, which implements 64-bit multiply in hardware |
| `f60` | **no** | the 68060 package is untouched on this CPU |
| `kvp` | yes | `kvp_n` +3865, `kvp_user_n` +3865 — ordinary trap traffic, all user-origin |
| `i40` | yes | `i40_pgfreed_n` +1, `i40_held_n` +108 — page-table reclaim during exec/exit |
| `ptd` | yes | `ptd_calls` +380, `ptd_retired_n` +380, `ptd_pgfreed_n` +3, `ptd_tblfreed_n` +380 |

`ptd_calls == ptd_retired_n == ptd_tblfreed_n` across 380 teardowns is the ISSUE-40 invariant
holding on this card. ⚠ `ptd_wake_n` is still 0: the `pt_waiting` branch remains unexercised, as on
every other machine.

**Not run:** the burst suite, deliberately deferred — it is long, and it is the one test whose
timing behaviour is most likely to differ on a card with no local RAM.

---

## 7. RTG kernel: X11 and wolf3d on the A3640 — same evening

Kernel B: `build/unix-040-rtg`, build id **`68040-260813-01`**, built from the accepted base by
explicit argument rather than from `relink-040-rtg.sh`'s default input, which is the emulator's
staging slot. Identity confirmed three ways before anything was measured: `uname -m`, and the
`wbf`/`fpc`/`isp61` magics reading correctly at addresses that are unique to *this* image's text
size (`07114154`, `071142C8`, `0711428C`). A stale graphics kernel could not have produced them.

```
  /dev/svga   c 67 0        both nodes already present, no mknod needed
  /dev/va2000 c 68 0
  va2000probe   open(/dev/va2000) OK, fd=3     the board is present and the driver works
                firmware version = 0           consistent with the VA2000 driver address fix
                                               still pending in the va2000-amix repository
  X11           Xrtg + startxrtg: works
  wolf3d        works
```

X11 and wolf3d were exercised by the owner at the console; the counter baseline had been taken
before they started, so the run is attributable after the fact:

| Block | Delta across X11 + wolf3d | Reading |
|---|---|---|
| `isp61` | **none at all** | vector 61 never fired — exactly as a 68040 requires, since it executes `muls.l` in hardware. wolf3d's 68060 failure mode is not reachable on this CPU |
| `segvn_prot` | `pp_n` 205 → 302, `segvn_prot_n` **0** | ISSUE-41's per-page permission check ran 97 more times and denied nothing: active and silent, which is the correct behaviour |
| `wbf` | **none** | no write-back denial during graphics or the game — ISSUE-42's path is not one that ordinary work, even this, reaches |

**Method note worth keeping.** The owner ran the two programs without taking readings, which would
normally lose the measurement. It did not, because the counters are cumulative and the baseline
had been written to files on the machine beforehand. Taking a baseline early costs one command and
converts "we forgot to measure" into a subtraction.

---

## 8. Burst suite on the A3640 — and a branch that had never executed anywhere

Driver: `test-tools/burstloop11.sh` (the AMIX-grep-safe replacement), 3 rounds × 4 bursts ×
(6 concurrent 4 MiB copies + `hat_dup_cow 64`).

```
  good sums     72   = 24 per round × 3, exactly the expected count
  wrong sums    none
  anomalies     bad address 0 · read error 0 · cannot open 0 · No space 0
                BUS ERROR 0 · PANIC 0 · Segmentation 0 · Killed 0
```

Every previous burst acceptance ran on a Mercury card with **32 MiB**. This one ran with
**12.7 MiB** of `availrmem` — less than half — and copyback held.

### The pre-registered expectation that did NOT happen

`NEXT-EVENING-RUNLIST-260813.md` predicted that **ISSUE-39** (`hat_sdtalloc` out of contiguous
memory) might fire here for the first time, since the suite had never run at half the RAM, and
said in advance that this would be a finding rather than a regression.

**It did not fire.** The `i39` block shows no change at all across the whole run: `i39_fail_n` = 0.
That is a clean negative and it sharpens the earlier characterisation — ISSUE-39 is fragmentation,
not pressure, and halving the memory did not reproduce it.

### The branch that did

```
  ptd_wake_n    0 -> 7
```

`ptd_wake_n` counts ISSUE-40's `pt_waiting` wake path. It has been **zero on every machine, every
emulator and every run since the unit landed**, and `STATUS.md` §5.2 listed it as one of three
paths that had never executed anywhere. Twelve megabytes of RAM and six concurrent 4 MiB copies
put processes into the state the branch exists for, and it ran seven times.

What that does and does not establish: the code executes and the system stayed correct through it
(72/72 sums, no anomaly, no panic). It is not a proof that the branch is *right* — nothing here
tests its outcome specifically — but it is no longer untested code, and the way it was reached is
now known: **memory pressure, not workload type**. Anyone wanting to exercise it can reproduce the
condition.

### The rest of the block

```
  ptd_calls 2760 -> 13902     ptd_retired_n 2760 -> 13902     ptd_tblfreed_n 2760 -> 13902
  ptd_pgfreed_n 132 -> 225
```

`ptd_calls == ptd_retired_n == ptd_tblfreed_n` across **11 142** teardowns — ISSUE-40's invariant
holding under the heaviest load this machine has seen.

`wbf` unchanged: no write-back denial under that load either.

---

## 9. Dhrystone on the A3640 — the first 68040 number from a card with no local RAM

```
  21 220.2 /s   (owner's run)
  21 208.9 /s   (re-run, same binary /root/amix-bench/dhry, 1 000 000 iterations)
                spread 0.05 %
```

Two things were verified before comparing it to anything, because a benchmark compared across an
unverified configuration is worse than no benchmark:

* **cache mode**: `hat_cm_ram` reads `0x20` = CM=01 = **copyback** — the same mode as the numbers
  it is being compared against;
* **the same binary** as every earlier measurement in this project.

⚠ The run count goes on **stdin**, not in `argv`. `dhry 1000000` silently ignores the argument,
reads EOF and prints "Measured time too small"; the correct form is `echo 1000000 | dhry`.

### Against the recorded numbers

⚠ **The clock figure used by every earlier document in this project was wrong.** The Mercury's
68040 runs from a **70 MHz oscillator at half clock = 35 MHz**, not 33; the 68060 runs from a
66 MHz oscillator at **full** clock. Both established 2026-08-13 by the person who fits the
oscillators, which is better provenance than any of the documents that said 33. Everything below
is recomputed.

| configuration | Dhrystones/s | per MHz |
|---|---:|---:|
| 68040 @ **35** MHz Mercury, caches off | 11 538.5 | 329.7 |
| 68040 @ **35** MHz Mercury, write-through | 18 292.7 | 522.6 |
| 68040 @ **35** MHz Mercury, copyback | 29 950.4 | 855.7 |
| **68040 @ 25 MHz A3640, copyback** | **21 214.6** | **848.6** |
| 68060 @ 66 MHz, copyback, ESS=1 | 60 463.6 | 916.1 |

### The A3640 costs nothing measurable on this benchmark

Clock-scaling the Mercury to 25 MHz predicts **21 393/s**; the A3640 measures **21 215/s** —
**0.8 % below**, i.e. **99.2 % of the Mercury per MHz**. That is inside the band where kernel
build, compiler and clock precision differences live, so the honest statement is:

> On Dhrystone, having no local RAM costs the A3640 nothing that this benchmark can see.

Which is the same point as before, sharpened: the working set fits in the 68040's 4 KiB caches,
most of the run never reaches the bus, and the benchmark is therefore blind to exactly the property
that distinguishes these two cards. A memory-bound comparison would need a different instrument.

**An earlier draft of this section reported a 6.5 % deficit and explained it as the motherboard-bus
penalty.** That was an artifact of the 33 MHz figure. The explanation was plausible, the mechanism
is real, and the number did not exist — which is the exact failure mode of reasoning from a
plausible mechanism to a measurement.

### The correction lands on the 68060 as well, and there it changes a conclusion

`060-F0-MEASUREMENT-260805.md` §9 recorded the 060 as "+102 % over the 040 — almost exactly the
clock ratio (66/33 = 2.0)", and built on it the argument that with scalar dispatch there was
nothing to explain. With the real clocks:

```
  clock ratio    66/35 = 1.886
  measured ratio 60 463.6 / 29 950.4 = 2.019
  surplus beyond clock scaling        +7.1 %
```

So the 68060 is **7.1 % faster per clock** than the 68040, not equal to it. And the surplus is
*small* — because `pcr_boot` was later measured as `0x04300601`, **ESS = 1**, so that 060 was
running **superscalar**. A superscalar 68060 delivering only +7 % per clock over a 68040 on
Dhrystone is a low figure that now wants an explanation.

Two named candidates, both recorded as **off** in the same F0 measurement and both single-bit
knobs:

| CACR bit | | state |
|---|---|---|
| 23 | `IC60_EBC` branch cache | **off** |
| 29 | `DC60_ESB` store buffer | **off** |

That makes the 060 performance question bounded rather than mysterious, and it is the campaign's
existing F4-060-D item. Nothing here changes any correctness result; it changes what the
performance numbers mean.

