# STATUS — AMIX SVR4 68040/68060 port

**This is the canonical status document. When another document in this tree disagrees with it,
this one is right and the other one is history.**

Last reviewed: **2026-08-14**. The exact commit is not typed here — `sh tools/status-facts.sh`
prints it, along with everything else in this file that changes on every build. Rule 1 below is
the reason.

## How to read this file, and how to keep it true

Two rules, both learned the expensive way in this project:

1. **The volatile facts are generated, not typed.** Build ids, hashes, text sizes and every
   counter address change on every build — and a stale counter address does not fail loudly, it
   returns a plausible number from whatever now lives at that address. Run:

   ```sh
   sh tools/status-facts.sh            # or: sh tools/status-facts.sh build/unix-040-rtg
   ```

   (It picks the toolchain up from `config.sh` like everything else — see `BUILDING.md`.)

   That prints the current artifact's identity, every `*_magic` block with its runtime address
   and the magic word read out of the artifact itself, and a both-directions check of the
   override bindings. This file carries the judgement; the script carries the facts.

2. **Every claim names the platform it was measured on and the document that holds the
   evidence.** "PASS" without a platform is the row that gets trusted later and should not have
   been. The emulator is not a proxy for hardware, and 2026-08-12 produced two fresh reminders:
   the FPSP arithmetic call-out body never executes under Amiberry at all (no enabled IEEE
   exceptions exist there), and the 060 null/idle frame ratio is 8048:17 on silicon against
   9229:855 in the emulator.

There are no percentages in this document. A percentage of "how complete" is not falsifiable;
a named test on a named platform is.

---

## 1. Baseline images

| Build id | sha256 (prefix) | Platform accepted on | What it established | Evidence |
|---|---|---|---|---|
| **`68060-260812-06`** | `955a5be7` | **68060 hardware (Mercury), 2026-08-12** | **Current baseline.** ISSUE-43 re-confirmed 6/6; ISSUE-42 unit proven INERT on 060 silicon; `ftest060` main+unimp, `fp060probe`, `isp61ea` all pass. **Also accepted on a 68040 (A3640) 2026-08-13 — the first dual-silicon image in this project** | `docs/REALHW-260812-06-ACCEPTANCE.md` |
| `68060-260812-02` | `bb906e2a` | 68060 hardware (Mercury), 2026-08-12 | ISSUE-43 + ISSUE-44 closed; six enabled IEEE classes bit-exact | `docs/REALHW-ISSUE43-ACCEPTANCE-260812.md` |
| `68060-260807-11` | `4962361b` | 68060 hardware (Mercury), 2026-08-09 | 68060 FPSP (F3 M5) on silicon; `ftest060 unimp` passes; xv/wolf3d SIGSYS attributed | `docs/REALHW-260807-11-ACCEPTANCE.md` |
| `68060-260806-06` | — | 68060 hardware (Mercury), 2026-08-07 | ISSUE-41 closed; XPAGE + protfault + power-cut | `docs/REALHW-260806-06-ACCEPTANCE.md` |
| `68040-260802-01` | `3727e5b4` | 68040 hardware (Mercury), 2026-08-02 | Last 68040-*only* baseline, superseded on 040 silicon by `-260812-06` on 2026-08-13. ISSUE-40 closed | `docs/REALHW-ISSUE40-ACCEPTANCE-260802.md` |
| `68040-260731-10` | on NAS | 68040 hardware (Mercury), 2026-07-31 | Copyback default re-accepted; 9/9 + battery | `docs/REALHW-ACCEPTANCE-260731.md` |
| `68040-260727-01` | — | 68040 hardware (Mercury), 2026-07-27 | First full delta acceptance + power-cut 8/8 | `test-tools/realhw-verify-260727.txt` |

**One image boots both CPUs.** `cputype` is poked by `unix_boot040` from `AttnFlags`; every
CPU-specific path is gated on it. The build id says `68040-` because it is stamped at build
time; the banner and `uname -m` say `68060-` when a 68060 is running it.

**Both accepted 2026-08-12 images are tagged**, because an accepted binary has already been lost
once here: `68060-260806-06` is gone from the build host and cannot be rebuilt, the base having
moved underneath it. Note that two different builds in this table end in `-06`; they are always
written with their date here for that reason.

| | current baseline | previous |
|---|---|---|
| build id | `68060-260812-06` | `68060-260812-02` |
| git tag | `hw-68060-260812-06` (annotated, on `e23e322`) | `hw-68060-260812-02` (annotated, on `b95bcd2`) |
| archive | tag only — **not yet copied to the NAS** | NAS `amix/baseline-68060-260812-02/` — binary, `SHA256SUMS.txt`, `status-facts.txt`, the acceptance document and this file |
| reproducibility | — | **verified, not assumed**: rebuilding from the tag yields an image differing in exactly **one byte**, the build-id stamp's per-build counter |

⚠ **Archiving the current baseline is outstanding**, and it is the one step whose omission has
already cost this project a binary once. The NAS is not currently reachable; a second copy of
kernel images also exists on the Amiga's own hard disk, whose contents are not inventoried here.
Neither substitutes for the other — the point of the archive is a copy that does not depend on
the machine under test.

**The 68040 hardware column is two different cards.** Every 040 acceptance up to 2026-08-02 was on
a **Mercury with a 68040 at 35 MHz**, which carries its own RAM at `0x08000000`; the 2026-08-13
run was on an **A3640 at 25 MHz**, which has none and binds the kernel into motherboard memory at
`0x07000000`. The 68060 is the **same Mercury card** with the CPU swapped through an adapter, at
66 MHz. Three configurations, and the load-base difference is not cosmetic: it moves every counter
address by −16 MiB, which is why `tools/status-facts.sh` takes a load base.

**The current image has run on 68040 hardware.** `68060/68040-260812-06` was accepted on an
A3640 on 2026-08-13 — the first dual-silicon image here — which is what closed ISSUE-42. The
machine carries whichever CPU card is physically installed; as of 2026-08-13 that is the A3640.

The 040 run-list `docs/archive/NEXT-040-SESSION-RUNLIST.md` is **partly** discharged by that
session: items 1 and 2 (ISSUE-42, and a 040 hardware baseline) are done, and the battery, burst
suite, RTG kernel and Dhrystone were added on top. Items 3 and 4 were **not run** and are still
owed — the M0 vector probe with the 040 as its control (`kvp_vec[11]` must stay 0 there), the
Dhrystone A/B across `kvp_on` that would say what the probe costs per syscall, and the assertion
that every `f60_*` and `isp61_*` counter still reads 0 after a full 040 battery.

---

## 2. Platform matrix

Four platforms in one table on purpose: the interesting information is where a row is green in
one column and blank in another.

Legend, per cell, describing **that column's platform only**: **HW** = measured on that silicon ·
**EMU** = measured under Amiberry · **✗** = cannot be exercised there, see the note below the
table · **—** = not applicable · **?** = not measured on that platform.

(Until 2026-08-14 the two emulator columns carried `HW`, which the legend does not permit an
emulator column to say. The cells now describe their own platform, which is the only reading
under which a row that is green in one column and blank in another means anything.)

| Capability | 040 emu | 040 HW | 060 emu | 060 HW | Evidence |
|---|:--:|:--:|:--:|:--:|---|
| Boot to multiuser, native userland | EMU | HW | EMU | HW | `docs/REALHW-ACCEPTANCE-260731.md`, `docs/REALHW-260806-06-ACCEPTANCE.md` |
| MMU / HAT, page-table lifecycle | EMU | HW | EMU | HW | `docs/contracts/INDEX.md`, battery |
| fork / COW (`hat_dup`) | EMU | HW | EMU | HW | `hat_dup_cow` 1/32/256 PASS |
| Context switch (native `resume`) | EMU | HW | EMU | HW | ISSUE-19 record, battery |
| Instruction cache | EMU | HW | EMU | HW | `config040.s`, ISSUE-21 |
| Data cache — copyback (default) | EMU | HW | EMU | HW | `docs/REALHW-COPYBACK-ACCEPTANCE-260730.md`, power-cut 8/8 |
| DMA coherence (A3091 / SDMAC) | EMU | HW | EMU | HW | `dma_cache040.s`, disk-truth runs |
| Swap / pageout | EMU | HW | EMU | HW | pressure suites, ISSUE-40 |
| UFS | EMU | HW | EMU | HW | disk-truth, power-cut |
| NFS (read + write + mmap tail) | EMU | HW | EMU | HW | ISSUE-35 / ISSUE-36, `docs/REALHW-ISSUE36-260728.md` |
| exec (ELF + COFF path) | EMU | HW | EMU | HW | ISSUE-32, ISSUE-38 |
| XPAGE / `mprotect` per-page | EMU | HW | EMU | HW | ISSUE-41, `docs/XPAGE-FPROT-FINDING-260806.md` |
| Denied write-back propagation | EMU | **HW** | — | **HW: inert, proven** | ISSUE-42 **closed on an A3640 2026-08-13**, and the defect itself reproduced on silicon; `docs/REALHW-A3640-260813-ACCEPTANCE.md` |
| ISP: vector 61 integer emulation | EMU | ? | EMU | HW | `docs/ISP-VECTOR61-LANDED-260806.md`, `isp61ea` 7/7 |
| FPU: 68040 FPSP | EMU | HW | — | — | `fputest` Test A on hardware 2026-07-27 |
| FPU: 68060 FPSP, unimplemented | — | — | EMU | HW | `ftest060 unimp` passed |
| FPU: 68060 FPSP, `main` group | — | — | ✗ (see note) | HW | `ftest060 main` 4/4 passed |
| FPU: 68060 enabled IEEE exceptions | — | — | ✗ (see note) | **HW 6/6** | `docs/REALHW-ISSUE43-ACCEPTANCE-260812.md` |
| FPU: 68060 context save/restore | — | — | EMU | HW | ISSUE-43; `fpc_*` counters |
| Graphics: Piccolo / Xsvga (Z2) | — | — | — | HW | `amix-xsvga-driver-feasibility` |
| Graphics: VA2000 RTG | — | HW | — | HW | `docs/REALHW-ACCEPTANCE-260801.md` |
| RAM above 32 MB | — | — | — | **not implemented** | §3; private analysis retained outside this repository |
| Zorro III device aperture | — | — | — | **documented limitation** | `docs/Z3-BUSBENCH-Z2-MEASUREMENT-260810.md` |
| 68LC060 / EC variants | — | — | — | **untested, unknown** | see §3 FPU |

**Note on the ✗ cells.** Those are not failures. Amiberry raises no enabled IEEE FP exceptions
and its FPU does not preserve the extended NaN Motorola's fixtures need, so those groups are
*unexercised* there. Reading them as "failed" has misled this project before — see
`amix-060-ftest-emulator-nan-limit`.

---

## 3. Subsystem status

**MMU / HAT / page tables.** Ported natively for the 040/060 (4 KiB, `hat040.s` and family).
Model-B 2→4 KiB conversion is complete for the paths the port reaches; residual families are
censused in `amix-modelb-residual-families-census`. S5 has a structural blocker and RFS is
broken upstream; neither is on the port's critical path.

**Caches.** Instruction cache on since CACHES STEP A; data cache in **copyback** since
2026-07-30, hardware-accepted including power-cut disk truth. Measured gain: Dhrystone +59 %
when the data cache was first enabled write-through, more with copyback.

**DMA.** A3091/SDMAC coherence hooks landed and hardware-verified. `bp_map`/`bp_mapout` are
native 040 ports (ISSUE-13).

**Filesystems.** UFS and NFS are hardware-clean, including the two NFS integrity defects
(ISSUE-35 write path, ISSUE-36 mmap tail) that were proved byte-for-byte from the server side.
`segmap`, `segvn` and `spec` paths are converted.

**exec / signals / context.** Native `resume`, `setuctxt`, `savecontext`/`restorecontext` paths
in use; ISSUE-38 (copyback vs. icode) closed; signal delivery resets FP state through
`fpu_setup`, now with a full 12-byte frame on the 060.

**ISP (68060 integer).** `isp61_060.s` emulates a **measured subset** of the 64-bit multiply
forms the installed userland actually contains — `#imm32`, `(d16,An)`, `(An)`, `Dn` — and
declines everything else through a counted fallback. Motorola's full ISP remains the general
answer and is not integrated. `isp61ea` is 7/7 on hardware.

**FPU / FPSP.** 68040: Motorola's 040 package, hardware-accepted. 68060: Motorola's full
`fpsp.sa`, default on (`FPSP060=1`), with `ftest060 unimp` and `main` both passing on silicon
and all six enabled IEEE classes bit-exact since `-260812-02`. The 060 FP context path
(`fpu_save`/`fpu_restore`/`fpu_setup`) is CPU-gated and tests the frame discriminator at
`frame+2`; the 040 bodies are byte-identical to stock and provably not entered.
⚠ **68LC060 is not supported and not tested**: the 060 `fpuinit` branch specified in
`docs/contracts/FPU-TIER1-ENABLE-SPEC.md` (PCR bit 1 + vector-11 negative probe) was never implemented,
so a CPU without a usable FPU would take an untested path.

**RAM > 32 MB.** The machine offers 48 MB in two regions (32 MB @`0x08000000` + 16 MB
@`0x07000000`, the second *below* the first) and AMIX counts only the one the kernel was loaded
into. Codex's analysis found **no technical ceiling**; the blocker is that the boot-time
algorithm does not recognise A and B as one pool. Bounded boot/startup work, not a counter bump.

**Zorro III.** The Z3 device aperture is not reachable by a driver (DTT0 covers 0–1 GB;
`0x40000000` is a fill-on-fault kvseg). Measured 2026-08-10: the Z2 aperture sustains
3.09 MB/s against 28.66 MB/s local, and a width test says the **bus is saturated**, not
serialised. Order if resumed: VA2000 driver address fix → test in Z2 mode → `Lcm_sel`
framebuffer class → firmware.

---

## 4. Issue ledger

`FIXED` means fixed **and** verified; the platform column says where. `OPEN` means live.
`DEFERRED` means understood and consciously not being worked. `SUPERSEDED` means the entry
survives as history but its conclusion has been replaced.

| # | Subject | Status | Proved on | Notes |
|---|---|---|---|---|
| 1 | rebuilt `unix_boot` → 030 MMU Config Error | DEFERRED | — | `unix_boot040` is the supported loader |
| 2 | debug markers / serial spam in dbg build | OPEN | — | cosmetic, dbg build only |
| 3 | `hat_unload` reverse-map bounded skip | DEFERRED | — | defensive; correct for the known callers |
| 4 | base kernel had stock-030 `hat_dup` | FIXED | 040+060 HW | `hat_dup040.s` |
| 5 | `haltsys` ran unguarded 030 `pmove` | FIXED | 040 HW | |
| 6 | `fsck` on dirty UFS panicked `segvn_softunlock` | FIXED | 040 HW | two Model-B conversion errors |
| 7 | u-area corruption after reboot (`u_procp=0`) | FIXED | 040 HW | |
| 8 | `p0init` bus error (kvm_init `ctob`/`btoc`) | FIXED | 040 HW | |
| 9 | idle-time bus-error loop | **OPEN** | 040 HW captured | captured 2026-07-28, not attributed |
| 10 | stale PTE reuse / `amixadm` trigger | **OPEN** | 040 HW + emu | ⚠ July's "retired" was a dbg-instrument artifact; **intermittent, so a single-boot bisect is invalid** |
| 11 | `wb040` WB1 replay alignment | FIXED | 040 HW | byte-wise replay |
| 12 | A2065 ethernet dead | FIXED | 040 HW | it works; the interface is `aen0` |
| 13 | kvseg fault robustness | FIXED | 040 HW | native fault resolver |
| 14 | emulator root-fs s5 inconsistency | DEFERRED | — | emulator environment, not the port |
| 15 | KMA pools double-map their backing | FIXED | 040+060 emu | |
| 16 | RFS client cache 2 KiB geometry | DEFERRED | — | 72 sites; RFS is broken upstream anyway |
| 17 | procfs `prfastmapin`/`out` (kernel panic) | FIXED | 040 HW | |
| 18 | `vtop` user-VA walker | FIXED | 040+060 emu | |
| 19 | context-switch residual edges | OPEN | — | statically possible, never reproduced |
| 20 | stock `hat_swapout` is a mine if reinstated | DEFERRED | — | process swapout is disabled |
| 21 | intermittent black screen at boot | FIXED | 040 HW 9/9 | inherited IC state at handoff |
| 22 | stale PTE / `wb040.s` did not restore DFC | FIXED | 040 HW 16/16 | proved by fault injection |
| 23 | serial character loss at 9600 | FIXED | 040 HW | |
| 24 | `init 6` runlevel-6 limbo | NOT A KERNEL BUG | 040 HW | rc6 userland |
| 25 | native boot partition path is 030-only | DEFERRED | — | documented: boot via `unix_boot040` |
| 26 | `shutdown -i0` bus-error loop in the shutdown process | **OPEN** | 040 emu, good repro | system survives; halt path only |
| 27 | `segmap_pagecreate` family tail zeroing | FIXED | 040 HW | `PGCOLD-E PRESERVED` 24/24 |
| 28 | `memcntl` / mlock bitmap geometry | FIXED | 040+060 emu | |
| 29 | one-off KMA 128-byte freelist alarm | OPEN | — | attribution unproven, single occurrence |
| 30 | `pvn_vptrunc` tail zeroing was 2 KiB | CONVERTED | — | reachability unproven |
| 31 | `ufs_bmap` page geometry | FIXED | 040+060 emu | |
| 32 | ELF exec mapping interface | FIXED | 040+060 emu | |
| 33 | `/dev/mem` mmap PFN was 2 KiB | FIXED | 040+060 emu | |
| 34a | 68060 kills any constant division (vector 61) | FIXED | 060 HW | F2 unit; gcc works again |
| 34b | `cc1` SIGSYS was assumed not to be 34a | SUPERSEDED | 060 HW | it was the missing FPSP — settled by F3 M5 §8 |
| 35 | NFS write lost half of every page | FIXED | 040 HW | byte-verified from the server |
| 36 | NFS mmap SIGBUS on the last partial page | FIXED | 040 HW | A/B on hardware |
| 37 | wolf3d infinite `as_fault` loop | FIXED | 040 HW | 040 reports the START address of a misaligned access |
| 38 | copyback hid the boot icode from the ifetch | FIXED | 040 HW | `copyout` + `cpusha bc` |
| 39 | `hat_sdtalloc` out of contiguous memory in bursts | OPEN | 040 HW | characterised: fragmentation, not pressure |
| 40 | `availrmem` decline | FIXED | 040 HW | ⚠ `ptd_wake_n` = 0: the `pt_waiting` branch is unexercised |
| 41 | `segvn_faultpage` had no per-page permission check | FIXED | 040+060 HW | partial `mprotect` + denied write panicked **stock** |
| 42 | denied write-back replay is swallowed → silent lost store | **FIXED** | **68040 hardware (A3640)** | `protfault` 3/3; the defect itself reproduced on silicon with the fix switched off, killing the emulator-artifact hypothesis. WB1 still unexercised on both platforms |
| 43 | 68060 zero-source-operand FP exception lost fp0-7 | FIXED | **060 HW 6/6** | frame discriminator is at `frame+2` |
| 44 | FPSP arithmetic exit fell through into the BSUN body | FIXED | **060 HW** | one day old; found by an invariant counter, not by a failing test |
| 45 | every byte-patch assertion was disarmed by `\| tail` | FIXED | build host | build tooling, not the kernel. A deliberately broken patch site: old script exit 0, `[OK] built`, 25 further patch steps; fixed script stops. `check_relink_relocs.py` also ignored `argv`, so four variant scripts validated a different kernel |

---

## 5. Release blockers

1. **ISSUE-10 and ISSUE-9** — two intermittent 68040 faults, captured but not attributed. Neither
   blocks normal use; both block a confident release claim. ISSUE-10 additionally carries a
   methodological trap: it is **intermittent**, so a single-boot bisect proves nothing, and July's
   "retired" verdict turned out to be a debug-instrument artifact.
2. **Coverage, not correctness** — paths that have never executed anywhere:
   * the **WB1** write-back slot and its ISSUE-11 bus-lane realignment (the emulators never set
     WB1S valid; the A3640 run reached WB3 only);
   * ISSUE-43's two `UFPRWRT` branches — nothing in this repo writes FP registers through old
     `ptrace`, which is also audit gate 6;
   * the **M0 vector probe** (`kvp_*`) has no hardware validation on either CPU, and its cost per
     syscall has never been measured. It wraps `nullvect`, which every syscall and every page
     fault passes through, so it is the most load-bearing hook in the tree. Items 3 and 4 of
     `docs/archive/NEXT-040-SESSION-RUNLIST.md`, not run in the A3640 session.
   * ~~ISSUE-40's `ptd_wake_n` / `pt_waiting` branch~~ — **executed for the first time 2026-08-13**,
     7 times, during the burst suite on a 12.7 MiB machine. Reached by memory pressure, not by
     workload type.
3. ~~The burst suite has not run on the A3640.~~ **Run 2026-08-13**: 72/72 sums, every anomaly
   count 0, at 12.7 MiB against the 32 MiB of every previous acceptance. ISSUE-39 did **not** fire,
   which sharpens its characterisation as fragmentation rather than pressure.

~~ISSUE-42~~ closed on silicon 2026-08-13. Nothing on the 68060 side is blocking.

---

## 6. Recommended order

0. ~~Tag~~ · ~~ISSUE-42~~ · ~~re-verify the image on 040 hardware~~ · ~~burst suite on the A3640~~ ·
   ~~wolf3d and X11 on the RTG kernel~~ — all done 2026-08-12/13. `68040/68060-260812-06` is
   accepted on both silicon; both graphics applications run on the A3640.
   **Still owed from that list: copy the current baseline to the NAS archive.**
1. **Publication.** The main track since 2026-08-13; §10 and `RELEASE-PLAN.md`. Phases 1–5 and
   6a are done, 6b (a second machine) and 7 (the push) are not.
2. **ISSUE-10 / ISSUE-9 attribution** — the last two release blockers. Slow work: repeat boots,
   not cleverness, and no single-boot bisect.
3. **Decide the 68LC060 question as a product decision**, not technical debt.
4. **Zorro III** — the one substantial piece of new development still considered worth doing.
   Order, from the 2026-08-10 measurement: VA2000 driver address fix → test in Z2 mode →
   `Lcm_sel` framebuffer class → firmware. The prize is real and measured: 3.09 MB/s through the
   Z2 aperture against 28.66 MB/s local, with a width test showing the bus saturated rather than
   serialised.
5. The unexercised paths in §5.2, whenever their area is next opened.
6. **060-D, the two CACR knobs** (`docs/060-D-CACHE-KNOBS-PLAN.md`) — store buffer and branch cache,
   both still off. Motivated by the corrected clock: a superscalar 68060 is only 7.1 % faster per
   clock than the 68040, which is low. Needs the 060 back in the machine, so it is a batched
   session of its own, and the branch cache needs an instruction-cache-invalidation audit first.

### Two decisions taken 2026-08-13, recorded so they are not silently reopened

* **RAM above 32 MB: declined.** The analysis stands (no technical ceiling; the missing 16 MB is
  region representation plus a one-contiguous-span startup model), and the corrected fix is bigger
  than it first looked — coalescing the regions is not enough on its own, the kernel must also be
  bound at the bottom of the merged span, or startup taught to accept memory below the kernel.
  The owner's judgement is that this is neither important nor clearly sensible for the machines
  this port serves. It is not a blocker and not on the road map. `RAM-BEYOND-16MB-ANALYSIS.md` and
  the loader finding remain valid if anyone reopens it.
* **Publication is now the main track**, ahead of further feature work. See §10 and
  `RELEASE-PLAN.md`.

---

## 7. Conclusions that have been refuted — do not restart from these

Everything in this section exists somewhere in the older documents. It is wrong. The documents
keep it because the record of *why* a hypothesis failed has repeatedly been worth more than the
hypothesis, but nothing new should be built on any of it.

| Refuted claim | Where it still appears | What is actually true |
|---|---|---|
| A null FSAVE frame means "no live FP state" on the 68060 | ISSUE-43 rounds 1–3 | Byte zero is the **source operand's exponent**; the discriminator is byte two |
| DZ proved a null frame | ISSUE-43 round 1 | It proved its own operand was zero |
| "7100 null saves per boot" | ISSUE-43 round 3 | Collected through the wrong predicate. Remeasured: 8048 null / 17 idle per boot on hardware |
| Bit 0 of the u-area FP flags is a lazy-FPU owner bit | reverted attempt, `4bfc0f6` | It is `UFPRWRT`, "software wrote the programmer model". Setting it turned 5-of-6 into 0-of-6 |
| ISSUE-10 was retired in July | `docs/archive/RESUME-HERE-260727.md` | It is back on probeless kernels and reproduces in the emulator; the "retirement" was a dbg-instrument artifact |
| `cc1`'s SIGSYS was something other than the missing FPSP | ISSUE-34b | It was the FPSP (F3 M5 §8) |
| `fpc_excp_n` would be non-zero on hardware | `docs/REALHW-RUNLIST-ISSUE43-260812.md` | Our own call-out converts the frame to idle before the OS sees it, so `0xe0` never reaches `fpu_save` |
| The ExecBase → `expansion.library` route can enumerate Zorro cards | early `lszorro` notes | AMIX overwrites the AmigaOS library list nodes |
| The Mercury 68040 runs at 33 MHz | every document before 2026-08-13 | **35 MHz** — 70 MHz oscillator at half clock. The 68060 runs at 66 MHz, full clock |
| The 68060's Dhrystone is "almost exactly the clock ratio", so scalar dispatch explains it | `docs/060-F0-MEASUREMENT-260805.md` §9 | The ratio is 1.886, the measurement 2.019 → **+7.1 % per clock**, measured with **ESS=1** (superscalar). A low surplus that points at the branch cache and store buffer, both off |
| The A3640 costs 6.5 % on Dhrystone versus the Mercury | an earlier draft of `docs/REALHW-A3640-260813-ACCEPTANCE.md` §9 | 0.8 %, i.e. nothing this benchmark can see. The 6.5 % was the 33 MHz artifact |

`docs/archive/RESUME-HERE-260727.md` is a snapshot of 2026-07-27 and has not been maintained since. Read it as
history; read this file for status.

---

## 8. Evidence index

| Area | Document |
|---|---|
| Issue detail and history | `KNOWN-ISSUES.md` (45 issues, chronological, corrections in place) |
| 060 FP acceptance | `docs/REALHW-ISSUE43-ACCEPTANCE-260812.md`, `test-tools/issue43-emu-verify-260812.txt` |
| 060 FPSP acceptance | `docs/REALHW-260807-11-ACCEPTANCE.md` |
| 060 baseline before FPSP | `docs/REALHW-260806-06-ACCEPTANCE.md`, `docs/REALHW-F2-ACCEPTANCE-260806.md` |
| 040 acceptance | `docs/REALHW-ACCEPTANCE-260731.md`, `docs/REALHW-ACCEPTANCE-260801.md`, `test-tools/realhw-verify-260727.txt` |
| Pending 040 hardware work | `docs/archive/NEXT-040-SESSION-RUNLIST.md` |
| Static implementation contracts | `docs/contracts/INDEX.md` (34 normative records imported from the private analysis diary) |
| FP contract | `docs/contracts/FPU-LAZY-CONTRACT-AUDIT.md`, `docs/contracts/FPU-TIER1-ENABLE-SPEC.md` |
| RAM expansion | §3; the declined private analysis is not an implementation dependency |
| Zorro III | `docs/Z3-BUSBENCH-Z2-MEASUREMENT-260810.md` |
| Build and toolchain | `LOCAL-BUILD-NOTES.md`, `relink-040.sh` |
| Test tooling | `test-tools/README.md` |

---

## 9. What is NOT mapped

The static map covers the port's critical surface. It does **not** cover the whole SVR4 kernel,
and no claim here should be read that way. Not reconstructed: STREAMS, the network stack, IPC,
the driver set beyond the ones this port touches, and the legacy S5 / RFS / COFF paths. Those
are out of scope rather than pending.

---

## 10. Publishing readiness

**As of 2026-08-13 this is the main track.** The full plan is `RELEASE-PLAN.md`; what follows is
the summary that belongs in the canonical status.

The goal of eventually publishing the port's own work on GitHub is realistic — the repository is
already structured for it — but it is not one commit away.

Decided 2026-08-13: **MIT licence · history rewritten rather than truncated · two repositories**
(this one, and `amix-unix-boot` for the loader patches).

### Done, and how it was checked

| | State | Check |
|---|---|---|
| Licence | MIT + `NOTICE` bounding what is *not* ours | `LICENSE`, `NOTICE` |
| Redistribution hygiene | 462 tracked files after the contract import, no AT&T or Commodore source among them | `.gitignore` excludes `amix-src/`, `svr4-src-3b2/`, `usl-svr42/`, `ghindra-unix/`, kernel binaries, the distribution archives |
| Root password | **gone from the working tree and from every commit** | `git log --all -S` finds no commit containing it |
| Hard-coded home paths | 59 → **11, in 8 files, all prose** — none in any build script | `git grep /home/asokero` |
| One configuration point | `config.sh` (gitignored) from `config.sh.example`; `tools/check-env.sh` verifies every dependency and exits non-zero | phase 2 |
| Stock-kernel gate | `tools/verify-stock.sh`, positive and negative tested | phase 3 |
| Build fails loudly | ISSUE-45: a broken patch site now stops the build, measured against the old behaviour | phase 3 |
| Documentation | `README.md` opens by saying this is not a kernel; `BUILDING.md`; `docs/METHOD.md` | phases 4, 5 |
| Static evidence chain | 34 implementation-facing contracts imported; all `src/` specification references resolve locally | `docs/contracts/INDEX.md`; `python3 tools/check-verbatim.py` exits 0 |
| Third-party material | Motorola's 040SP/060SP and NetBSD are **not vendored** — a path in `config.sh`, documented | phase 1 |
| Clone test, this machine | a clean clone builds to within the build-id stamp, and found three files the working tree was hiding — but `config.sh` was copied and the toolchains already existed, so it does not test the dependency instructions | phase 6a |

### Open

1. **Phase 6b — a second machine.** Clone, build the cross toolchain from its own upstream,
   follow `BUILDING.md` and nothing else, then boot the clone-built kernel on the Amiga. This is
   the gate that decides whether the instructions are true; everything above is this machine
   testifying about itself.
2. **Phase 7 — the push**, plus a publication tag.
3. **`10.0.10.10` appears in 20 documents.** A private RFC1918 address, not a secret; a decision
   about tidiness rather than a blocker.
4. **ISSUE-9 and ISSUE-10 are open**, and honestly recorded. They argue for publishing as a
   technical preview rather than as a finished port — not for waiting.
