# USER-CODE-PUBLISH — the mprotect(PROT_EXEC) publication ABI (2026-08-01)

Implements Codex's `USER-CODE-CACHE-ABI-SPEC.md` (analyysirepo `vm-map/`, 6c1cb84), the last
residual ISSUE-38 left open. Kernel unit `prototypes/codepub040.s`, test `test-tools/codepub.c`.

## The rule

> A successful `mprotect(addr, len, prot)` with `PROT_EXEC` set publishes every CPU store
> completed before the call — **even if the mapping already had exactly that protection**.

Implemented as a strong `mprotect` wrapping the retained stock body
(`--weaken-symbol mprotect` + `--add-symbol mprotect_orig=.text:0x58550`). On success, when
the requested prot has `PROT_EXEC`, execute `cpusha bc` (`0xf4f8`). Error paths return the
stock errno untouched and publish nothing.

## Why the stock kernel is not enough (both holes confirmed in the disassembly)

```text
mprotect 0x58550 -> as_setprot 0xae2ea -> segvn_setprot 0xac9aa -> hat_chgprot -> cpusha bc
```

1. A **real** protection change (RW→RX) reaches `hat_chgprot`, whose PTE-coherency tail is a
   whole-cache push — so W→X publication works today **by accident**.
2. `segvn_setprot` returns success **early** when the requested protection equals the current
   one, so a legacy RWX generator (`PROC_DATA` is RWX on this port) can never publish at all.

Hole 2 is what the acceptance test exercises: `codepub.c` T1 keeps the mapping RWX throughout
and publishes with a **same-protection** `mprotect`, where nothing but the wrapper can help.

## Instruments

Four `.data` longs in `codepub040.s`:

| symbol | meaning |
|---|---|
| `codepub_on` | ships **1**; poke 0 for the one-boot A/B (events still counted, barrier skipped) |
| `codepub_calls` | every `mprotect` reaching the wrapper |
| `codepub_exec` | successful calls whose requested prot had `PROT_EXEC` — the ABI events |
| `codepub_push` | `cpusha bc` actually executed |

Invariant with the flag on: `codepub_push == codepub_exec`.

`codepub.c` predicts **exact** deltas for one run — `calls +8, exec +5, push +5` — so "the
counters moved" is not the result; those three numbers are.

## Emulator acceptance (2026-08-01, `unix-040` build id 68040-260801-02)

Wiring proven, cache **not** proven — Amiberry does not model the 040 copyback data cache, which
is the whole reason ISSUE-38 was invisible there.

```text
anchor hat_cm_ram = 0x20 (copyback)      <- addresses verified before any reading
codepub_on = 1
run 1:  calls 0x6a->0x72 (+8)   exec 0x6a->0x6f (+5)   push 0x6a->0x6f (+5)   codepub: PASS
codepub_on poked to 0
run 2:  calls 0x82->0x8a (+8)   exec 0x7c->0x81 (+5)   push 0x7c->0x7c (+0)   codepub: PASS
```

Both runs pass **functionally**, which is exactly the point the spec makes: only real copyback
silicon can tell the two apart. T1's unpublished read returned the fresh value (22) in the
emulator — i.e. no hazard is modelled there.

Error paths, measured: unaligned addr → `EINVAL` (22); unmapped 4 KiB-aligned addr → `ENOMEM`
(12); a successful `PROT_READ|PROT_WRITE` call advances `calls` but not `exec`.

## Two findings from the counters, neither of them expected

* **The ABI is already on a live path.** `codepub_exec` reads ~102 by the time a boot reaches a
  shell, and every single `mprotect` seen so far requested `PROT_EXEC` — `calls == exec` exactly.
  That is the runtime linker publishing text, i.e. the producer the spec lists as
  "runtime linker text relocation". It was doing this before the wrapper existed; the wrapper is
  what makes it a barrier rather than a coincidence.
* **Ordinary command execution costs nothing.** Ten `/bin/date` runs, ten `expr` runs, `ls`,
  `kpeek` — **zero** additional `mprotect` calls. The whole-cache push lands ~4 times per login
  session and not at all in a normal command. The performance worry about `cpusha bc` on a hot
  path does not apply here; it still has to be confirmed against Dhrystone/burst on hardware.

## Still owed: hardware

The decisive test needs the A3000 (10.0.10.10), which was **powered off for this whole session**
(`No route to host` from first contact to last). What is owed:

1. `codepub.c` on real copyback with `codepub_on = 1` → T1 step 4 must return 22.
2. Same image, `codepub_on = 0` → T1 step 3 is expected to report **STALE (11)**, and step 4 is
   then *allowed to fail*. That failure is the finding; it is what proves cache ownership rather
   than accidental context-switch invalidation.
3. `exectest 20` + one burst suite for regression, and Dhrystone against the accepted
   30037/s to confirm the barrier costs nothing measurable.

Counter addresses **for the build that ships this** (`kernel_base + textsize + .data offset`,
textsize `0xe4588`) — recompute after any relink:

```text
hat_cm_ram      0x080FC888     <- read this FIRST, must be 0x20
codepub_on      0x080FCF8C
codepub_calls   0x080FCF90
codepub_exec    0x080FCF94
codepub_push    0x080FCF98
```
