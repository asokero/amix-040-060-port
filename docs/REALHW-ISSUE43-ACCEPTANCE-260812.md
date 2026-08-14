# Real-hardware acceptance: `68060-260812-02` — ISSUE-43 closed, six of six bit-exact

**Machine:** Amiga 3000, 68060 @ 66 MHz, AMIX SVR4 2.1c, `solon` / 10.0.10.10
**Date:** 2026-08-12
**Image:** `build/unix-040`, build id `68040-260812-02`, sha256
`bb906e2a1d96c76ac15eb8da1299a9ec70db23185bcb0cde11875ad68a8dd1b3`, textsize `0xf2914`,
booted with `unix_boot040` after SetPatch
**Previous hardware baseline:** `68060-260807-11`; the machine last ran `-05` at 5-of-6
**Run-list with the pre-registered expectations:** `REALHW-RUNLIST-ISSUE43-260812.md`, written
with the machine powered down

## Headline

**All six enabled IEEE exception classes now return Motorola's post-state bit for bit, DZ
included.** ISSUE-43 is closed. Two builds were measured on silicon today, and the first one
found a second defect that no emulator could have found.

```
  OPERR v52  OK  fp0 ffff0000:00000000:00000000  fpsr 01002080  fpiar 80000628  sigs 1
  OVFL  v53  OK  fp0 7fff0000:00000000:00000000  fpsr 02001048  fpiar 8000068c  sigs 1
  UNFL  v51  OK  fp0 00000000:40000000:00000000  fpsr 00000800  fpiar 800006f0  sigs 1
  DZ    v50  OK  fp0 40000000:80000000:00000000  fpsr 02000410  fpiar 80000752  sigs 1
  INEX  v49  OK  fp0 50000000:80000000:00000000  fpsr 00000208  fpiar 800007b4  sigs 1
  SNAN  v54  OK  fp0 7fff0000:80000000:00000001  fpsr 01004080  fpiar 80000816  sigs 1

FPENAB060 bad=0
```

DZ's line is the one this work existed for. On `-03`/`-05` it read
`fp0 7fff0000:ffffffff:ffffffff  fpsr 00000000  fpiar 00000000` — the FPU reset state — because
stock `fpu_save`/`fpu_restore` tested byte ZERO of the FSAVE frame, which on a 68060 is the
source operand's exponent. Divide-by-zero is exactly the class whose operand is zero.

## 1. Identity, read before anything was believed

| Item | Value |
|---|---|
| `uname -m` | `Amiga (Unlimited) 68060-260812-02` |
| `fpc_magic` @`0810AF98` | `46504321` "FPC!" |
| `f60_magic` @`0810B5B0` | `46503630` "FP60" |

## 2. The two builds, and why there were two

### `-01` — the fix works, and a one-day-old defect surfaces

`-01` carried the ISSUE-43 unit (`src/fpu060.s`, `f65ea04`). On its first boot:

* **DZ passed bit-exactly** — the defect this session targeted was gone;
* **OPERR failed on one bit**: `fpsr 00002080` where Motorola says `01002080`. The missing bit
  is FPCC's NaN condition.

The counters named the cause without a hypothesis being needed. Per enabled exception:

```
  f60_entry_n +1     one package entry, as always
  f60_arith_n +1     the class call-out ran
  f60_bsun_n  +1     ... and then the BSUN body ran too
  f60_real_n  +2     against entry +1 -- the unit's own invariant
                     "entry == done + real_* exits" broken by exactly the fall-through
  kvp_vec[51] +1     only ONE arrival at nullvect, and it was the fall-through's
```

`b664bfd` (2026-08-11) removed the null-frame guard from `Lco_fparith` — correctly — but the
guard block **ended in the exit's own `jmp nullvect`**, so removing it left every arithmetic
call-out falling through into `Lco_bsun`. That body does `andib #0xfe,%sp@` on the saved FPSR,
which clears the NaN condition bit: right for a real BSUN, wrong for everyone else. Nothing
crashed, because the BSUN prelude's stack arithmetic happens to balance, and four of the six
classes still passed because only NaN-valued results carry the bit it clears.

Fixed in `592b7ed`, one instruction.

### `-02` — six of six

Same unit plus the restored `jmp`. Counters after the passing run:

```
  f60_entry_n 6   f60_real_n 6   f60_arith_n 6   f60_bsun_n 0   f60_done_n 0
  f60_fpudis_n 0  f60_unsupp_n 0 f60_effadd_n 0  f60_last_co 1 (snan, the last class run)
```

`entry == real == arith` — the invariant holds again, and `f60_bsun_n` staying at 0 is what says
the fall-through is gone rather than merely quiet.

## 3. The new FP-context counters on silicon

```
  fpc_magic       46504321
  fpc_save_n         8059      the 060 fpu_save body runs on every context switch
  fpc_rest_n         7647
  fpc_setup_n         256      boot + exec + every signal delivery
  fpc_null_n         8048  0x00 null
  fpc_idle_n           17  0x60 idle
  fpc_excp_n            0  0xe0 exception
  fpc_odd_n             0      no frame carried any other format byte  <- audit gate 2
  fpc_save_wrt_n        0      UFPRWRT's only setter is old ptrace
  fpc_rest_wrt_n        0
```

**A pre-registered prediction that was WRONG, recorded as wrong.** The run-list expected
`fpc_excp_n` to be non-zero on hardware, reasoning that an enabled exception would leave an
`0xe0` frame for `fpu_save`. It stayed 0, and the reason is in our own call-out: `Lco_fparith`
writes the idle status `0x6000` at offset two and FRESTOREs it *before* jumping to `nullvect`,
so by the time the OS saves anything the frame is idle by construction. The verdict (`bad=0`)
did not depend on that prediction, but the mechanism behind it was mine and it was wrong.

The null/idle split on real silicon is much sharper than the emulator's: 8048 null vs 17 idle
here, against 9229 vs 855 under Amiberry. Same conclusion either way — the null case dominates,
so "always save on the 060" would have been a permanent per-switch cost — but the emulator is
not a proxy for the *rate*.

## 4. Regressions, same boot

| Test | Result |
|---|---|
| `fp060probe` | `bad=0`, 7/7 bit-exact, 0 ulp (fadd fsqrt fintrz fsin fetox flogn fmovecr) |
| `ftest060 unimp` | `Unimplemented FP instructions...passed`, `died=0` |
| `ftest060 main` | four sub-tests **passed** (unimplemented `<ea>`, data type/format, non-maskable overflow, non-maskable underflow), `died=0` |
| `fputest060 fork` | CHILD 129746, PARENT 6871 — both correct |
| `isp61ea` | `bad=0`, 7/7 (`imm_u imm_s d16pos d16neg d16u an dn`) |
| `f60_fpudis_n` | 0 — audit gate 9 holds |

## 5. What was NOT run, and why

* **The battery.** It is a regression net for the generic kernel paths, and this change cannot
  reach them on the 040 (the path is byte-identical and provably not entered) while on the 060
  it is exercised 8059 times per boot by ordinary scheduling. The battery would have added no
  information about this unit. Stated as a decision, not an omission.
* **Audit gate 6 — old-ptrace FP-register writes.** No instrument exists. `fpc_save_wrt_n` and
  `fpc_rest_wrt_n` therefore read 0 by construction, and two branches of the new 060 code are
  unexercised on both CPUs. Their instructions are the inherited ones; this is a coverage gap.
* **Audit gate 7 — `/proc prsetfpregs` against a true-null target.** Separate latent gap: the
  audit found `prsetfpregs` never sets `UFPRWRT` where `procxmt` does.

## 6. What this run says about the tooling

The emulator raises no enabled IEEE FP exceptions, so `Lco_fparith` **never executes there** —
`f60_arith_n` is 0 on both emulator CPUs. That body has exactly one instrument in existence,
`fpenab060` on hardware, and the previous hardware run predates the commit that broke it. The
fall-through therefore had no way of being caught before today, and what caught it was an
invariant counter rather than a failing test: four classes were green while `real == 2 × entry`
said two exits per entry.
