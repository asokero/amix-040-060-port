# RESUME HERE — end of 2026-08-01: all three 040 tails are built, none is hardware-accepted

Read this and `RESUME-HERE-260731.md` (still the standing record of where the port is).
Everything below is measured unless it says otherwise.

## 0. The one thing that shaped this session

**The A3000 was powered off from first contact to last** — `No route to host` on every attempt,
`ping 10.0.10.10` never answered. So all three §7 tails were built and verified *in the
emulator*, which settles wiring and cannot settle cache. Nothing here is a hardware verdict.

Base kernel now: `build/unix-040`, build id **68040-260801-04**, textsize `0xe4588`.

## 1. What landed

| unit | what it does | verified by |
|---|---|---|
| `codepub040` (USER-CODE-PUBLISH) | `mprotect(..., PROT_EXEC)` is the user-code publication barrier | counter deltas **exactly** 8/5/5 as predicted; A/B flag proven |
| `include-modelb/` + mirror sysroot | 4 KiB page geometry for everything compiled in | same unmodified z3660 source now emits `moveq #12` instead of `#11` |
| `issue39_040` + `memwatch.c` | the kernel's COMMON memory globals are readable at last | `physmem` × 4 KiB = the machine's actual RAM |

Records: `USER-CODE-PUBLISH-260801.md`, `MODELB-HEADERS-260801.md`,
`ISSUE39-MEMORY-REGIME-260801.md`.

## 2. Findings worth carrying forward

* **The publication ABI is already on a live path.** `codepub_exec` reads ~102 by the time a boot
  reaches a shell and `calls == exec` exactly — every `mprotect` this system makes requests
  `PROT_EXEC`. That is the runtime linker. Ordinary command execution (`date`, `ls`, `expr`,
  `kpeek`) makes **zero** `mprotect` calls, so the whole-cache push is not on a hot path — ~4 per
  login session and nothing else. Still to be confirmed against Dhrystone on hardware.

* **The `-I` in `AMIX_KERNEL_CFLAGS` has never worked.** The toolchain's gcc wrapper prepends
  `-I$sysroot/usr/include` *before* every user `-I`, so the vanilla headers listed in the CFLAGS
  have never supplied `<sys/immu.h>` or `<sys/param.h>`. That is the 2 KiB header trap, located
  exactly. The override goes through `AMIX_SYSROOT` and a mirror sysroot.

* **`<sys/param.h>` was the bigger half of the trap** and the Z3660 analysis missed it:
  `ptob`/`btop`/`btopr`/`PAGESIZE` are reached for far more often than `phystopfn`.

* **The existing z3660 shift check had a hole.** It matched only `lsrl`; a *signed* `>> 11`
  compiles to `asrl`, which is exactly what `va2000.c` emits — the old check called that object
  clean. `prototypes/check_page_geometry.sh` matches both and is now shared.

* **ISSUE-39 is not a depletion problem.** 18 s cumulative at `freemem = 0` with a fork/exec storm
  produced **zero** `hat_sdtalloc` failures, on two independent counters agreeing. The machine
  reaches `freemem = 0` on plain sequential file IO and survives it routinely. Since
  `hat_sdtalloc` needs *contiguous* memory, the axis is **fragmentation**, not pressure.

## 3. What is owed on hardware, in priority order

Everything below needs the A3000 powered on. Read `hat_cm_ram` at `0x080FC888` (must be `0x20`)
before trusting any address, and **recompute every address after any relink**.

1. **The decisive `codepub` A/B.** `./codepub` with `codepub_on = 1` (`0x080FCF8C`) → T1 step 4
   must return 22. Then poke `codepub_on = 0`, re-run: T1 step 3 is expected to report
   **STALE (11)**, and step 4 is then allowed to fail. *That failure is the result* — it is what
   proves cache ownership rather than accidental context-switch invalidation. Both runs pass in
   the emulator, which is precisely why the emulator cannot settle this.
2. **Regression + cost.** `exectest 20`, one burst suite, and Dhrystone against the accepted
   30037/s.
3. **ISSUE-39 burst run.** `./memwatch 080FCF9C 900 500 &` alongside `burstloop.sh 4`, then read
   the latch (`i39_fail_freemem` at `0x080FCFC0`). A *high* `freemem` at the failure confirms
   fragmentation outright and turns ISSUE-39 into a kernel-map question.

Counter addresses for build 68040-260801-04 are listed in full in the three record files.

## 4. Then the 060

Unchanged from `RESUME-HERE-260731.md` §7: measurement boot on the existing dual-CPU kernel →
Codex's crossing-page runtime acceptance (FSLW.MA on a real format-4 frame) → 060SP integer half
→ 060-D caches. The CPU swap is one-way per session, so items 1–3 above should close first.
