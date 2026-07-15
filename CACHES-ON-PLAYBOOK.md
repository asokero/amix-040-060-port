# Caches-on playbook (68040/68060) — grounded state + graduated enablement

**Written 2026-07-15 from a direct read of `pstart040.s` + `hat040.s`. This is the
HW-session playbook and the spec for the CM-bit path.** Real HW is out for a few days;
this records exactly where the code is so enablement + validation is fast when it returns.

## Precise current state (measured, not remembered)

| Control | Value | Meaning |
|---|---|---|
| **CACR** | never set → `0x00000000` | **both IC and DC globally DISABLED at the cache controller.** This is the master OFF switch. |
| ITT0 | `0x003fc000` | E=1, 0–1GB, code, CM=00 (WT-cacheable) — **dormant while CACR IC-disable** |
| DTT0 | `0x003fc060` | E=1, 0–1GB, data, CM=11 (cache-INHIBITED) — forces data 0–1GB inhibited, **masks per-page data CM even if DC enabled** |
| DTT1 | `0x807fa060` | I/O ≥0x80000000, cache-inhibited, S=01 supervisor-only |
| per-page CM | uarea leaf `0x60` (nocache); `hat_pteload` writes status {0,1,5}, **does NOT set CM** | dormant while CACR off / DTT0 forcing inhibit |
| 040 CM field | PTE bits [6:5] | 00=WT-cacheable, 01=copyback (`0x20`), 10=noncachable-serialized (`0x40`), 11=noncachable (`0x60`) |

**Consequence:** turning caches on is fundamentally ONE `movec → CACR`. Everything else
(TTR CM, per-page CM) is dormant scaffolding that only takes effect once CACR enables the
respective cache.

## Why the emulator can't finish this job

Codex `HAT-FLUSH-COHERENCY-AUDIT.md:42`: *"[the emulator] does not model 68040 copyback
data-cache."* So **DC-copyback coherency (the DMA-vs-cache races that are the whole risk)
is UNVALIDATABLE on Amiberry** — enabling DC there "works" trivially and gives false
confidence. IC is modelled well enough that gross coherency errors (stale loaded code)
DO surface.

## Graduated enablement plan

### Step A — Instruction cache only (the emulator-validatable, real-win increment)  ✅ IMPLEMENTED + EMU-VALIDATED (2026-07-15, build 260715-16)
Implemented as: `pstart040.s` sets CACR=`0x00008000` (bit15 IC-enable) via `cinva ic` +
`movec d0,cacr`, AND writes the same `0x8000` into the `cacr`/`sup_cacr` data globals
(the interrupt handlers p1int–p6int reload CACR from those globals on every entry, so a
bare `movec` alone would be clobbered by the first interrupt). `runtime040.s` adds
`cinva ic` at the resume `Lrt_rest` tail so every context switch flushes the physically-
tagged IC (covers cross-process code-page reuse + demand-paged text; blunt but correct).
Precondition audit outcome: the whole-IC invalidate on every resume subsumes the
per-path exec/hat_memload cinv requirement, so no per-site invalidate was needed for
correctness (a per-page `cinvl` at code pagein is the future perf optimization).
**Validation (emu, dbg kernel):** emu-040 AND emu-060 both boot→login clean (build
`68040-260715-16` / `68060-260715-16`), interactive login (getty→login→sh exec chain
through shared `libc.so.1`), and a `for i in 1..5; do ls -alR / done` fork/exec+recursive-
libc churn → `LOOPDONE-RC0`, no panic, no stale-IC crash. DC still OFF (Step B, HW-gated).


- Flip CACR IC-enable (bit 15, `0x00008000`) after the MMU is up (end of `pstart040`, or
  early `runtime040`). DC stays off.
- **Precondition audit (do FIRST):** every path that WRITES then EXECUTES code must
  `cinva ic` (or `cpusha`) the affected lines — exec/`gexec`/`elfexec` code-page load,
  `hat_memload` of text pages, any trampoline/relocation. With CACR=0 today these are
  latent; IC-enable EXPOSES any missing invalidate as "executes stale cache → crash",
  which Amiberry WILL catch.
- Validation: boot→login + a fork/exec-heavy workload (NetHack, hat_dup_cow, repeated
  amixadm) on emu-040 AND emu-060. Clean run = IC coherency handled.
- Risk: moderate (a missing cinv crashes, but is caught + localizable on emu).

### Step B — Data cache (HW-GATED; do NOT validate on emulator)
1. `hat_pteload` CM-bit path (this pilot's core): set the leaf CM field per map —
   `0x20` (copyback) for normal RAM, `0x60` (noncachable) for device maps (`prot & 8`,
   the existing DEFERRED TODO in `hat040.s`). Mirrors `pstart040`'s static-table pattern
   (uarea `0x60`, tbl[0] cacheable). **Dormant until DTT0 narrowed + CACR DC-enable.**
2. Narrow/disable DTT0 so per-page data CM becomes authoritative for RAM (keep DTT1 for
   I/O). Otherwise DTT0's blanket inhibit masks the copyback bits.
3. DMA coherency audit: `cpusha`/`cinva` around every SCSI (a3091/sdmac) DMA buffer —
   push before write-DMA, invalidate before read-DMA. Codex `HAT-FLUSH-COHERENCY-AUDIT`
   + `HAT-UNLOAD-COHERENCY-AUDIT` are the starting maps; `hat_pagesync040` cpusha gap is
   a known latent item.
4. CACR DC-enable.
5. **Validate on real HW only** (emulator doesn't model copyback DC). Test: heavy SCSI
   I/O + big file integrity (`sum`) + sustained pressure.

## The CM-bit path (this pilot) — scope decision

The CM-bit path is Step-B scaffolding: correct and needed, but **dormant on the current
emulator** (CACR=0 + DTT0 masks data CM + Amiberry doesn't model DC), so implementing it
now yields UNEXERCISED infrastructure — validatable only as "still boots, no regression".

Three honest options for "now, no HW":
- **(i) Step A (IC enable)** — the genuinely emulator-validatable caches increment; real
  perf win; needs the cinv-after-load audit; moderate, emu-catchable risk.
- **(ii) Dormant CM-bit path** — implement the `hat_pteload` CM logic (copyback RAM /
  noncachable device); safe, zero behaviour change, but unexercised (weak validation).
- **(iii) Spec-only** — keep this playbook as the HW-session plan; implement nothing until
  HW/Z3 can exercise it.

Related: `RESUME-HERE-040-HARDWARE.md` (open real-HW hypotheses, incl. a p0init deferred
-write bus error where CM 0x60→0x40 serialization was tried and did NOT help — the faulting
store is page-table-mapped so its CM comes from the leaf PTE, reinforcing that the
`hat_pteload` CM path is the real lever for that region).
