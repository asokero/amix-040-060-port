# STATUS — AMIX SVR4 68040/68060 port

**This is the canonical status document. When another document in this tree disagrees with it,
this one is right and the other one is history.**

Last reviewed: **2026-08-12**. Kernel commit at review: `99e2ae5`.

## How to read this file, and how to keep it true

Two rules, both learned the expensive way in this project:

1. **The volatile facts are generated, not typed.** Build ids, hashes, text sizes and every
   counter address change on every build — and a stale counter address does not fail loudly, it
   returns a plausible number from whatever now lives at that address. Run:

   ```sh
   export PATH=/home/asokero/opt/amix-cross/bin:$PATH
   sh tools/status-facts.sh            # or: sh tools/status-facts.sh build/unix-040-rtg
   ```

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
| **`68060-260812-06`** | `955a5be7` | **68060 hardware, 2026-08-12** | **Current baseline.** ISSUE-43 re-confirmed 6/6; ISSUE-42 unit proven INERT on 060 silicon (every `wbf_*` counter 0); `ftest060` main+unimp, `fp060probe`, `isp61ea` all pass. 68040 acceptance owed | `REALHW-260812-06-ACCEPTANCE.md` |
| `68060-260812-02` | `bb906e2a` | 68060 hardware, 2026-08-12 | ISSUE-43 + ISSUE-44 closed; six enabled IEEE classes bit-exact | `REALHW-ISSUE43-ACCEPTANCE-260812.md` |
| `68060-260807-11` | `4962361b` | 68060 hardware, 2026-08-09 | 68060 FPSP (F3 M5) on silicon; `ftest060 unimp` passes; xv/wolf3d SIGSYS attributed | `REALHW-260807-11-ACCEPTANCE.md` |
| `68060-260806-06` | — | 68060 hardware, 2026-08-07 | ISSUE-41 closed; XPAGE + protfault + power-cut | `REALHW-260806-06-ACCEPTANCE.md` |
| `68040-260802-01` | `3727e5b4` | **68040 hardware, 2026-08-02** | **Last 68040 hardware run.** ISSUE-40 closed | `REALHW-ISSUE40-ACCEPTANCE-260802.md` |
| `68040-260731-10` | on NAS | 68040 hardware, 2026-07-31 | Copyback default re-accepted; 9/9 + battery | `REALHW-ACCEPTANCE-260731.md` |
| `68040-260727-01` | — | 68040 hardware, 2026-07-27 | First full delta acceptance + power-cut 8/8 | `test-tools/realhw-verify-260727.txt` |

**One image boots both CPUs.** `cputype` is poked by `unix_boot040` from `AttnFlags`; every
CPU-specific path is gated on it. The build id says `68040-` because it is stamped at build
time; the banner and `uname -m` say `68060-` when a 68060 is running it.

**The current baseline is tagged and archived** (2026-08-12), because an accepted binary has
already been lost once here — `-06` is gone from the build host and cannot be rebuilt, the base
having moved underneath it.

| | |
|---|---|
| git tag | `hw-68060-260812-02` (annotated, on `99627b1`) |
| archive | NAS `amix/baseline-68060-260812-02/` — binary, `SHA256SUMS.txt`, `status-facts.txt`, the acceptance document and this file |
| reproducibility | **verified, not assumed**: rebuilding from the tag yields an image differing in exactly **one byte** — offset `0x10AF83`, the last digit of the build-id stamp, which is a per-build counter |

⚠ **The current image has never run on 68040 hardware.** The machine has carried the 68060
since 2026-08-05; re-verifying the 040 needs a physical A3640 card swap. The 040 hardware column
below therefore reads as of `68040-260802-01`, and the pending run-list is
`NEXT-040-SESSION-RUNLIST.md`.

---

## 2. Platform matrix

Four platforms in one table on purpose: the interesting information is where a row is green in
one column and blank in another.

Legend: **HW** = measured on that silicon · **EMU** = measured under Amiberry only ·
**—** = not applicable · **?** = not measured on that platform.

| Capability | 040 emu | 040 HW | 060 emu | 060 HW | Evidence |
|---|:--:|:--:|:--:|:--:|---|
| Boot to multiuser, native userland | HW | HW | HW | HW | `REALHW-ACCEPTANCE-260731.md`, `REALHW-260806-06-ACCEPTANCE.md` |
| MMU / HAT, page-table lifecycle | HW | HW | HW | HW | `amix-kernel-analysis/vm-map/`, battery |
| fork / COW (`hat_dup`) | HW | HW | HW | HW | `hat_dup_cow` 1/32/256 PASS |
| Context switch (native `resume`) | HW | HW | HW | HW | ISSUE-19 record, battery |
| Instruction cache | HW | HW | HW | HW | `config040.s`, ISSUE-21 |
| Data cache — copyback (default) | HW | HW | HW | HW | `REALHW-COPYBACK-ACCEPTANCE-260730.md`, power-cut 8/8 |
| DMA coherence (A3091 / SDMAC) | HW | HW | HW | HW | `dma_cache040.s`, disk-truth runs |
| Swap / pageout | HW | HW | HW | HW | pressure suites, ISSUE-40 |
| UFS | HW | HW | HW | HW | disk-truth, power-cut |
| NFS (read + write + mmap tail) | HW | HW | HW | HW | ISSUE-35 / ISSUE-36, `REALHW-ISSUE36-260728.md` |
| exec (ELF + COFF path) | HW | HW | HW | HW | ISSUE-32, ISSUE-38 |
| XPAGE / `mprotect` per-page | HW | HW | HW | HW | ISSUE-41, `XPAGE-FPROT-FINDING-260806.md` |
| Denied write-back propagation | **EMU** | **OWED** | — | **HW: inert, proven** | **ISSUE-42 — implemented 2026-08-12, still a release blocker until 040 silicon**; `test-tools/issue42-emu-verify-260812.txt` |
| ISP: vector 61 integer emulation | EMU | ? | EMU | HW | `ISP-VECTOR61-LANDED-260806.md`, `isp61ea` 7/7 |
| FPU: 68040 FPSP | HW | HW | — | — | `fputest` Test A on hardware 2026-07-27 |
| FPU: 68060 FPSP, unimplemented | — | — | EMU | HW | `ftest060 unimp` passed |
| FPU: 68060 FPSP, `main` group | — | — | ✗ (see note) | HW | `ftest060 main` 4/4 passed |
| FPU: 68060 enabled IEEE exceptions | — | — | ✗ (see note) | **HW 6/6** | `REALHW-ISSUE43-ACCEPTANCE-260812.md` |
| FPU: 68060 context save/restore | — | — | EMU | HW | ISSUE-43; `fpc_*` counters |
| Graphics: Piccolo / Xsvga (Z2) | — | — | — | HW | `amix-xsvga-driver-feasibility` |
| Graphics: VA2000 RTG | — | HW | — | HW | `REALHW-ACCEPTANCE-260801.md` |
| RAM above 32 MB | — | — | — | **not implemented** | `vm-map/RAM-BEYOND-16MB-ANALYSIS.md` |
| Zorro III device aperture | — | — | — | **documented limitation** | `Z3-BUSBENCH-Z2-MEASUREMENT-260810.md` |
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
`vm-map/FPU-TIER1-ENABLE-SPEC.md` (PCR bit 1 + vector-11 negative probe) was never implemented,
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
| 42 | denied write-back replay is swallowed → silent lost store | **IMPLEMENTED, HW OWED — BLOCKER** | emulated 68040 | fix in `wb040.s`; `protfault` case c PASS, proved by an in-boot A/B. No 68040 silicon has run it |
| 43 | 68060 zero-source-operand FP exception lost fp0-7 | FIXED | **060 HW 6/6** | frame discriminator is at `frame+2` |
| 44 | FPSP arithmetic exit fell through into the BSUN body | FIXED | **060 HW** | one day old; found by an invariant counter, not by a failing test |

---

## 5. Release blockers

1. **ISSUE-42** — implemented 2026-08-12 and verified on the emulated 68040 (`protfault` case c
   now dies of SIGSEGV instead of silently tearing the store), but **no 68040 silicon has run
   it**, and the emulator cannot exercise the WB1 path at all — it never sets WB1S valid. Stays a
   blocker until the A3640 card swap. **Blocks calling the 040 port "done".**
2. **ISSUE-10 / ISSUE-9** — two intermittent 040 faults that are captured but not attributed.
   Neither blocks normal use; both block a confident release claim.
3. **The current image has no 040 hardware run.** `68060-260812-02` is 060-accepted only.

Nothing on the 68060 side is currently blocking.

---

## 6. Recommended order

0. ~~Tag and archive `68060-260812-02`~~ — **done 2026-08-12**, see §1.
1. **ISSUE-42**, bundled into one 68040 hardware session with `NEXT-040-SESSION-RUNLIST.md`,
   since both need the card swap.
2. **Re-verify the current image on 040 hardware** in that same session, closing the empty
   column in §2.
3. ISSUE-10 / ISSUE-9 attribution — slower work, needs repeat boots rather than cleverness.
4. **Decide the 68LC060 question as a product decision**, not a technical debt: "requires a full
   68060" is a legitimate answer, provided the kernel says so clearly at boot instead of failing
   strangely.
5. RAM > 32 MB, then Zorro III, as feature work with their own acceptance.

Two coverage gaps are worth closing whenever their area is next opened, neither being a
suspected defect: ISSUE-40's `ptd_wake_n` (`pt_waiting` branch never executed) and ISSUE-43's
two `UFPRWRT` branches (nothing in this repo writes FP registers through old `ptrace`).

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
| Bit 0 of the u-area FP flags is a lazy-FPU owner bit | reverted attempt, `296e490` | It is `UFPRWRT`, "software wrote the programmer model". Setting it turned 5-of-6 into 0-of-6 |
| ISSUE-10 was retired in July | `RESUME-HERE-260727.md` | It is back on probeless kernels and reproduces in the emulator; the "retirement" was a dbg-instrument artifact |
| `cc1`'s SIGSYS was something other than the missing FPSP | ISSUE-34b | It was the FPSP (F3 M5 §8) |
| `fpc_excp_n` would be non-zero on hardware | `REALHW-RUNLIST-ISSUE43-260812.md` | Our own call-out converts the frame to idle before the OS sees it, so `0xe0` never reaches `fpu_save` |
| The ExecBase → `expansion.library` route can enumerate Zorro cards | early `lszorro` notes | AMIX overwrites the AmigaOS library list nodes |

`RESUME-HERE-260727.md` is a snapshot of 2026-07-27 and has not been maintained since. Read it as
history; read this file for status.

---

## 8. Evidence index

| Area | Document |
|---|---|
| Issue detail and history | `KNOWN-ISSUES.md` (44 issues, chronological, corrections in place) |
| 060 FP acceptance | `REALHW-ISSUE43-ACCEPTANCE-260812.md`, `test-tools/issue43-emu-verify-260812.txt` |
| 060 FPSP acceptance | `REALHW-260807-11-ACCEPTANCE.md` |
| 060 baseline before FPSP | `REALHW-260806-06-ACCEPTANCE.md`, `REALHW-F2-ACCEPTANCE-260806.md` |
| 040 acceptance | `REALHW-ACCEPTANCE-260731.md`, `REALHW-ACCEPTANCE-260801.md`, `test-tools/realhw-verify-260727.txt` |
| Pending 040 hardware work | `NEXT-040-SESSION-RUNLIST.md` |
| Static contracts and audits | `../amix-kernel-analysis/vm-map/` (132 documents) |
| FP contract | `vm-map/FPU-LAZY-CONTRACT-AUDIT.md`, `vm-map/FPU-TIER1-ENABLE-SPEC.md` |
| RAM expansion | `vm-map/RAM-BEYOND-16MB-ANALYSIS.md` |
| Zorro III | `Z3-BUSBENCH-Z2-MEASUREMENT-260810.md` |
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

The goal of eventually publishing the port's own work on GitHub is realistic — the repository is
already structured for it — but it is not one commit away.

Already done: `.gitignore` deliberately excludes everything that is not ours to redistribute
(`amix-src/`, `svr4-src-3b2/`, `usl-svr42/`, `ghindra-unix/`, kernel binaries, the original
distribution archives). 421 tracked files, no AT&T source among them.

Open before anything is pushed:

1. **Credentials are in five tracked documents and in the git history** (`10.0.10.10`, the root
   password). Editing the files is not enough; this is a decision between rewriting history and
   publishing a fresh repository whose history starts at the publication point.
2. **The README's first sentence has to say what this is**: an override and patch layer over a
   proprietary kernel binary, requiring the reader's own licensed AMIX installation. Without
   that, it reads as a bootable kernel, which it is not.
3. **Motorola's 060SP/040SP and the NetBSD tree** should be fetched by a script, not vendored.
4. **Reproducibility is the real gate**: `relink-040.sh` must run clean on a machine that has
   only the documented toolchain — no scratchpad, no local paths. That is testable, and it
   should be tested before anyone else tries it.
