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

### Step B1 — Writethrough-pilot CM scaffolding  ✅ IMPLEMENTED AS DORMANT NO-OP PORT (2026-07-20, builds 260720-01/-02/-03)

The whole Codex B1 atomic group (analyysirepo `vm-map/CM-PTE-WRITER-MATRIX.md`,
"B1 implementation group" 1–8) is now in the tree, dormant while CACR DC stays
off and DTT0 stands.  **DTT0 is UNCHANGED by design** (narrowing = its own later
MMU milestone).  What landed:

1. **Classifier** (`hat040.s` `Lcm_sel`, shared by all three `hat_pteload` leaf
   constructors Lpfnok/Lwleaf/Lreplace): `seg==segu -> CM=0x60 NC` (highest
   priority), `pp==NULL -> 0x40 NCS` (hat_devload/MMIO), else `hat_cm_ram`
   (**new GLOBAL .data staging switch**: 0x00 WT in B1; B2 = flip to 0x20 CB).
2. **u-area/segu NC everywhere**: `prumap040.s` stops inheriting CM from the
   p0init shadow flags (mask + force 0x60, + pflusha); `resume` paths U and V
   normalize `|0x60` (`runtime040.s` AND the `mainmarks.s` dbg twin).
3. **Root/teardown publication ordering** (`hat040.s`): `hat_alloc` pushes the
   zeroed root (`cpusha dc`) BEFORE storing `as->hat_root`; `hat_free` detaches
   Bdesc + `cpusha dc` before each leaf `hat_ptfree`, clears `root[A]` +
   `cpusha dc` before the pointer-table free, and retires the root
   (clear as@(20), cpusha bc, pflusha) BEFORE `kmem_free(root)`.
4. **Explicit constructor classes**: `hat_dup040.s` private child leaf and
   `bp_map040.s` alias constructor OR in `hat_cm_ram`.
5. **Direct-`kptbl` family ported as one unit**: `segkmem040.s` overrides
   `segkmem_setprot` (2 KiB index/step -> 4 KiB, **stock cursor-advance defect
   fixed** (prot!=0 loop rewrote PTE[0] forever), publication tail) --
   vtable slot rebinds by symbol; `patch_segkmem.py` converts the READER
   companions `segkmem_checkprot`/`segkmem_getprot` (4 sites, old-byte asserts
   + stock-body canaries).
6. **Publication census closed**: `flushmmu` override = `cpusha dc` + pflusha
   (every bare-flushmmu caller = segkmem_alloc/free/mapin/mapout etc. now
   publishes); `sysseginit` (kvm040.s) publishes its kptr040 pointer stores;
   `sptfree(flag=0)` (segkmem040.s) publishes its direct clears before rmfree.
   NEW-site rule: **new B1 flushes are `cpusha dc`** (descriptor publication
   only -- never invalidates the enabled IC); pre-existing hand sites keep bc.
7. Legacy 030 writers stay unreachable (status quo: sched-override disables
   hat_swapout, hat_exec040 no-op, hat_map growsdt bounded -- no CM logic added).
8. DMA-read completion invalidation = **NOT in this group**; gate for the real
   WT/DC enable, waiting on the Codex DMA-initiator census (native hd/floppy/
   tape/audio/bitplane; aen proven PIO).

**Deliberate scope cuts (documented, not oversights):** `segkmem_alloc`/
`segkmem_mapin` constructors keep emitting CM=00, which IS the B1 WT target;
their B2 CB staging + the mapin unmanaged->NCS classification land with the
segdev/Z3 group (roadmap: "segdev-toteutusryhmään ... segkmem_mapin-MMIO").

**Emu-validated 2026-07-20 (dbg 260720-02, emu-040):** boot->login,
hat_dup_cow 1/32/64 PASS, tftp payload sum 1570 8192 byte-perfect after copy,
fork/exec churn, burst4 pressure; **runtime CM census via Amiberry IPC**:
kvsegu window leaves read `0x..61/0x..69/0x..79` (CM=11 NC -- the classifier's
positive signal), fixed-u `0x..0F9` (NC), kvseg kernel RAM `0x..019` (CM=00 WT
control).  All CM effects dormant (CACR DC off + DTT0 blanket-inhibit).

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
