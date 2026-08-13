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
