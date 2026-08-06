# Real-hardware acceptance: `68060-260806-06`

**Machine:** Amiga 3000, 68060 @ 66 MHz, AMIX SVR4 2.1c, `solon` / 10.0.10.10
**Date:** 2026-08-06 → 07
**Image:** `build/unix-040`, textsize `0xe4bb8`, booted with `unix_boot040` after SetPatch
**Previous hardware baseline:** `68060-260806-02` (F2, `REALHW-F2-ACCEPTANCE-260806.md`)

`260806-06` replaces `260806-02` as the hardware baseline. Every item on the run list in
`NEXT-SESSION-PROMPT-260807.md` was executed, including the power-cut disk truth, which had
never been run for this line.

## What is in `-06` over `-02`

1. `prototypes/segvn_prot040.s` — SVR4's per-page permission check restored to
   `segvn_faultpage`. Not cputype-gated: the defect affects both processors. ISSUE-41.
2. `wb040.s` `Lu_siginfo` — far-page `faultcode_t` → `u_trap`'s `k_siginfo_t`. User path only.

## 1. Identity

| Item | Value |
|---|---|
| `uname -m` | `Amiga (Unlimited) 68060-260806-06` |
| `cputype` | `0x0000003c` (60) |
| `pcr_boot` | `0x04300601` (ESS=1) |
| `segvn_prot_magic` | `53564e21` |
| `isp61_magic` | `49363121` |
| `hat_cm_ram` | `0x20` (copyback) |

Counter addresses were recomputed from `nm` for this image and each magic word was read
before it was trusted. The banner reads `68060-` here and `68040-` on the 040 emulator for
the *same image*: `inituname040.s:32` flips `buildid+4` when `cputype` is 60, so the prefix
is a readout of the running CPU, not an identifier of the image.

## 2. `protfault` a / b / c — the session's decisive measurement

All three cases PASS (child terminated by SIGSEGV). Case **c passed on real silicon for the
first time**; it is simultaneously the missing test 3 of `M68060-XPAGE-ACCEPTANCE.md`.

Run standalone and supervised, not inside the battery, because on the 060 case c used to
print a `NOTICE: User BUS ERROR ... FAULT:1` per iteration and once wedged a process.

Counters, read in three stages so attribution is unambiguous:

| Counter | baseline | after a+b | after c | pre-registered |
|---|---|---|---|---|
| `x60_far_fail_n` | 0 | 0 | 1 | — |
| `x60_fprot_n` | 0 | 0 | **1** | path runs |
| `x60_fprot_ok_n` | 0 | 0 | 0 | — |
| **`x60_fprot_fail_n`** | 0 | 0 | **0** | **stays 0** ✅ |
| `x60_last_afret` | 0 | 0 | **4** | **4** ✅ |
| `x60_siginfo_n` | 0 | 0 | **1** | +1 ✅ |
| `x60_far_addr` | `c1016000` | `c1016000` | `c1016000` | protected page ✅ |
| `x60_last_fa` | `c1015ffe` | — | `c1015ffe` | 2 bytes before the boundary |
| `segvn_prot_n` | 0 | 1 | 2 | +1, or +2 if c takes the same path ✅ |

Two things this pins down:

* **a and b never touch the 060 far-page path** — every x60 counter is still zero after them.
  Only c exercises the F4 translation. Clean attribution, not inference.
* `fprot_fail_n = 0` **together with** `fprot_ok_n = 0` and `afret = 4` means the
  verify-then-fail fallback was never entered: `as_fault` returns FC_PROT itself on hardware
  exactly as in the emulator. The workaround from 2026-08-05 is dead weight on real silicon
  too — the signature of a root-cause fix rather than a patch over symptoms.

`segvn_prot_n` = 1 after a+b (not 2) is expected and is the test's own stated prediction:
case a dies via the segment-wide path, which never needed the restored check; case b is the
one the per-page check denies.

## 3. Battery — 11/11

Compiled **with gcc 2.7.2.3 on the 060**: 13/13 binaries, 0 errors. That the compiler runs at
all is F2 working; ISSUE-34 killed any `muls.l` before it.

* 11/11 tests plus `protfault a` and `b`, **0 FAIL, 0 error, 0 panic** (247-line log, 31 PASS lines)
* `segvn_prot_pp_n` 437 → **1189**
* `segvn_prot_n` 2 → **3** (the battery's own `protfault b`; nothing else)
* `hat_pfnmiss_n` 10 → 12 = **+2 exactly**
* `i40_bad_n` = `i40_err_n` = 0; `ptd_keep0/keepn/meta/badlink` = 0

The decisive pair is `pp_n` well over a thousand *with* `prot_n` moving only for deliberate
denials. `pp_n = 0` would have made 11/11 vacuous — the check would simply not have run.

`ptd_wake_n` = 0 remains, as before: the `pt_waiting` branch is still unexercised. Known, open,
unchanged by this work.

## 4. Burst — 96/96 × 2 suites

| Suite | good sums | `bad address` |
|---|---|---|
| 1 | **96 / 96** | 0 |
| 2 | **96 / 96** | 0 |

Counted twice per suite: the script's own tally and an independent `grep -c '1570 8192'`.
`/payload.bin` sums to `1570 8192` on hardware (the emulator's regenerated copy sums to
`0 8192` — different file, not a different result).

Across ~32 minutes of load: `segvn_prot_pp_n` 1189 → **1608**, and **`segvn_prot_n` stayed at 3**.
No spurious denial under sustained pressure. `x60_fprot_fail_n` still 0.

Two suites, not four: this is a regression check on a generic-VM path and the 060 signal path,
not a re-run of ISSUE-40's four-suite teardown criterion, which passed on the 060 in F0.

## 5. Power-cut disk truth — 6/6, first time on this line

The only acceptance criterion never run for this line, and the stronger variant of the
documented clean-reboot item.

* write phase on `68060-260806-06`, 6 × 4 MiB to `/b2dt`, `sync` / `sleep` / `sync`
* **power physically cut** — not `init 6`, not `haltsys`
* rebooted on the **same** kernel (SetPatch, then `unix_boot040`)
* verify: **6/6 `V0_COMPLETE_MATCH`**, every file `size=4194304 crc=50250`

Preconditions were checked by hand, and this matters — see the harness defect below:
uptime `1:15` at write → `2 mins` after the cut, boot at 16:21 vs write at 16:16, same
`uname -m`. The reboot demonstrably happened, so the result is about the disk and not about
the page cache.

## Emulator cross-check (040), same image

Run first, as the campaign rule requires both CPU configurations to boot before a hardware boot:

* battery 11/11, 0 FAIL / 0 error / 0 panic
* `segvn_prot_pp_n` 273 → 1045, `segvn_prot_n` = 1, `hat_pfnmiss_n` +2
* **the entire 15-long x60 block stayed 0** — the cputype gate holds; the 040 path is untouched

## Defects found in the instruments, not the kernel

1. **`b2reboot-truth.sh`'s uptime guard is blind above one hour.** It extracts the writer's
   uptime with `up \([0-9]*\) min`, but `uptime` prints `up  1:15` once the machine has been
   up an hour, so `WROTE_MIN` comes out empty and the `-n` test silently skips the guard.
   It fails open, not closed — the opposite of what its own comment promises. The kernel
   mismatch guard is unaffected and did work. Compensated here by recording and comparing
   both uptimes by hand. Worth fixing before the next run.
2. **A poll that matched its own echo.** `case "$R" in *DONE*)` matched the echoed command
   line containing `MKALL5-DONE` rather than its output, so a compile appeared to finish
   instantly. Caught only because the log later "vanished". `emu.py`'s docstring warns about
   exactly this; the fix is to grep for a string the command line does not contain.
3. **The buildid prefix is not evidence about the banner.** `strings`/`nm` show `" 68040-"`
   in every image regardless of target CPU. An earlier edit to the session prompt asserted the
   banner always reads `68040-` on that basis and was reverted (`73366de` → `ebfef33`); the
   040 emulator could not distinguish the hypotheses, and the hardware falsified it at once.

## Status after this run

* `260806-06` is the hardware baseline.
* **ISSUE-41 closes on hardware.**
* `M68060-XPAGE-ACCEPTANCE.md` is fully covered — test 3 has now run on real silicon.
* Still open, deliberately out of scope: **ISSUE-42** (`wb040_replay` carries a write through
  to a protected page on the 68040 — a contract question for Codex, not a code question),
  campaign **F3** (vector 11 / 060 FPSP) and **F4-060-D** (branch cache; ESS is already on,
  so the 2.0× Dhrystone still lacks an explanation), and burst on the emulated 060.
