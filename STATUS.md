# STATUS — AMIX 68040/68060 Port

*(The repository was called `kernelsupport` until 2026-08-15 — a working name that said nothing
about what is in it. Same project, same history; only the directory and the references to it
changed.)*

**This is the canonical status document. When another document in this tree disagrees with it,
this one is right and the other one is history.**

Last reviewed: **2026-09-11**. The exact commit is not typed here — `sh tools/status-facts.sh`
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
| `68040-260908-03` | `8a14754c` | 68040 hardware (Mercury), 2026-09-08 | ISSUE-66 accepted: a 2 KiB-aligned `shmat` address is an ordinary `EINVAL` where it panicked, and `SHM_RND` rounds down. The most recent image accepted on hardware | `KNOWN-ISSUES.md` ISSUE-66 |
| `68040-260907-17` | not recorded | 68040 hardware (Mercury), 2026-09-07 | ISSUE-62 accepted: every `shmget` size that panicked now survives, and no other panic replaced it | `KNOWN-ISSUES.md` ISSUE-62 |
| `68040-260907-04` | not recorded | 68040 hardware (Mercury), 2026-09-07 | **Xrtg runs on a 68040 over Zorro III** (ISSUE-65), and a full X session — twm, xclock, xeyes, a scrolling xterm — stays quiet on serial | `docs/REALHW-Z3-040-260906.md` |
| `68040-260906-12` | not recorded | 68040 hardware (Mercury), 2026-09-06 | ISSUE-47's `hardbus` guard: six predictions, six results | `KNOWN-ISSUES.md` ISSUE-47 |
| `68040-260906-06` | not recorded | 68040 hardware (Mercury), 2026-09-06 | **First Zorro III kernel on a 68040**, after ISSUE-64: battery 12/12, 38/38 magics, load base `0x08000000` | `docs/REALHW-Z3-040-260906.md` |
| `68060-260830-06` | not recorded | 68060 hardware (Mercury), 2026-08-30 | ISSUE-54 contained: a CD returns `EIO`, the root disk keeps working, no `a3091:` line | `docs/REALHW-ISSUE54-STAGED-260830-06.md` |
| `68060-260826-06` | `20eb470b` | 68060 hardware (Mercury), 2026-08-26 | The tree after the merges of 2026-08-25/26: 32/32 magics, battery 11/12 (ISSUE-49), the LC060 merge's FPU gates measured inert (`*_nofpu_n` = 0), burst 96/96, power cut 6/6 | `docs/REALHW-LC060-MERGE-260826.md` |
| `68060-260819-13` | `8131fc30` | 68060 hardware (Mercury), 2026-08-19 | **Zorro III works**: the VA2000 at 7.66 MB/s against 3.12 on Zorro II, 32-bit datapath shown by a width test; battery 11/12 (ISSUE-49), burst 96/96, power cut 6/6 | `docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md` |
| `68040-260830-10` | `457a406d` | 68040 hardware (A3640), 2026-08-30 | **`kvp_on` defaults to 0**, accepted the same evening: battery 12/12, 38/38 magics at the same addresses as `-06`, `devmaptest fails=0 skips=0`, `fp060probe` 7/7 with `f60` untouched. The syscall probe's 8.09% is now measured across two boots rather than within one | `docs/REALHW-BATTERY-68040-260830.md` |
| `68040-260830-06` | `e1fb866e` | 68040 hardware (A3640), 2026-08-30 | **First 12/12 battery on a 68040**, 38/38 magics at load base `0x07000000`, every must-stay-zero counter 0, `fp060probe` 7/7 bit-exact with the `f60` block untouched. The driver is generated (`tools/gen-battery.sh`) rather than hand-edited. Found ISSUE-57: `devmaptest` was printing PASS having measured nothing on this card | `docs/REALHW-BATTERY-68040-260830.md` |
| `68060-260827-06` | `c2fb10fc` | 68060 hardware, 2026-08-27 | **First 12/12 battery in this project** (`devmaptest` passes: ISSUE-49's fault path). Burst 96/96. ISSUE-53 wrapper wired and correct, but its own subject event never occurred | `docs/REALHW-ISSUE53-260827-06.md` |
| `68060-260828-02` | `3de029c0` | 68060 hardware, 2026-08-28 | The collaborating line's FPE branch built here and run on three beds. Never-engage bar **proved declined rather than unreached** on silicon: 12 vector-11 events, all format 2, `fpe_entry_n` 0. Oracle passes. Merged the same day, `132bbd6` | `docs/FPE-BRANCH-REVIEW-260828.md` |
| `68060-260827-13` | `aa65776c` | 68060 hardware, 2026-08-27 | The working base until the September 68040 run. `-11` plus the entry-ISTR print; 35/35 magics, battery 12/12, every must-stay-zero counter 0. The print change is inert to everything else, and it is what makes a wedge classifiable on a machine that is otherwise dead | `KNOWN-ISSUES.md` ISSUE-54 |
| `68060-260827-11` | `52ec2b02` | 68060 hardware, 2026-08-27 | ISSUE-49 `/dev/screen` planes 4 KiB aligned + page-rounded. Battery 12/12, `scrfix` accounting exact and identical to the emulator's | `docs/REALHW-ISSUE49-260827-11.md` |
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
| git tag | `hw-68060-260812-06` (annotated, on `8ced913`) | `hw-68060-260812-02` (annotated, on `98bc478`) |
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

**Two platform classes from the second development line have no column here.** Jussi's A4000 with a
Z3660 contributes the card's emulated 68040 (`Z3660`, `docs/PLATFORM-Z3660.md`) and a real 68LC060
in its socket (`LC060-Z3660`, `docs/PLATFORM-LC060-Z3660.md`). Neither is `HW` as this file uses
the word; a result from either is cited per row, with its class named.

**Which CPU is in the machine changes between sessions, so read it from the banner, never from
here.** The dated readings: the Mercury with its 68040 for the Zorro III work of 2026-09-06 to -08
(the `68040-2609*` rows above), and a 68060 banner again on 2026-09-10 (`KNOWN-ISSUES.md` ISSUE-67).
`68060/68040-260812-06` was the first image accepted on both silicon, on an A3640 on 2026-08-13.
This paragraph is dated deliberately: an earlier version was read as current on 2026-08-19 and was
wrong by six days, which cost an argument.

The 040 run-list `docs/archive/NEXT-040-SESSION-RUNLIST.md` is **partly** discharged by that
session: items 1 and 2 (ISSUE-42, and a 040 hardware baseline) are done, and the battery, burst
suite, RTG kernel and Dhrystone were added on top. Items 3 and 4 were **not run** in that session. Two of their
measurements were made on the A3640 on 2026-08-30 (the `68040-260830-*` rows): what the probe costs
per syscall — after which `kvp_on` defaults to 0 — and the `f60` block untouched after a full 040
battery. Whether `kvp_vec[11]` stays 0 with the 040 as control, and the `isp61_*` half of the
assertion, are not recorded here.

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
| SysV shared memory (`shmget` / `shmat`) | ? | HW | ? | ? | ISSUE-62, ISSUE-66 — accepted on 68040 silicon only |
| exec (ELF) | EMU | HW | EMU | HW | ISSUE-32, ISSUE-38 |
| exec (COFF) | ? | ? | ? | ? | **deferred, not tested** — see §9 and `docs/contracts/EXEC-BOUNDARY-CENSUS.md` |
| XPAGE / `mprotect` per-page | EMU | HW | EMU | HW | ISSUE-41, `docs/XPAGE-FPROT-FINDING-260806.md` |
| Denied write-back propagation | EMU | **HW** | — | **HW: inert, proven** | ISSUE-42 **closed on an A3640 2026-08-13**, and the defect itself reproduced on silicon; `docs/REALHW-A3640-260813-ACCEPTANCE.md` |
| ISP: vector 61 integer emulation | EMU | ? | EMU | HW | `docs/ISP-VECTOR61-LANDED-260806.md`, `isp61ea` 7/7 |
| FPU: 68040 FPSP | EMU | HW | — | — | `fputest` Test A on hardware 2026-07-27 |
| FPU: 68060 FPSP, unimplemented | — | — | EMU | HW | `ftest060 unimp` passed |
| FPU: 68060 FPSP, `main` group | — | — | ✗ (see note) | HW | `ftest060 main` 4/4 passed |
| FPU: 68060 enabled IEEE exceptions | — | — | ✗ (see note) | **HW 6/6** | `docs/REALHW-ISSUE43-ACCEPTANCE-260812.md` |
| FPU: 68060 context save/restore | — | — | EMU | HW | ISSUE-43; `fpc_*` counters |
| Graphics: Piccolo / Xsvga (Z2) | — | — | — | HW | `docs/REALHW-ACCEPTANCE-260731.md` §Xsvga, `docs/REALHW-ACCEPTANCE-260801.md` |
| Graphics: VA2000 RTG | — | HW | — | HW | `docs/REALHW-ACCEPTANCE-260801.md` |
| RAM above 32 MB | — | — | — | **not implemented** | §3; private analysis retained outside this repository |
| Graphics: VA2000 RTG over Zorro III | — | HW | — | HW | `docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md` (060), `docs/REALHW-Z3-040-260906.md` (040) |
| 68LC060 | — | — | — | — | not in these columns: boots to multiuser on `LC060-Z3660` (reported at the merge, `7a99fe9`); floating point through the FPE lane is not accepted — §3 FPU |

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

**What the kernel is now known to carry.** A parallel line building OpenTTD 1.0.5 with a GCC 14
cross toolchain reports it running on this kernel on a 68060: it prints its help and exits
cleanly, with a hosted `libstdc++`, a working exception unwinder and C++ static constructors.
No display **on this kernel** yet: an X11 video driver exists on that line and draws the
game, but so far only on a development host under a nested server, not on this hardware.
That is a broader statement of what the port carries than any test in this tree
makes, and it is cited rather than claimed — the measurement is theirs, on image
`68040-260903-04` running on a 68060. Two limits found on the way are ours and are open:
ISSUE-59 (the 68060 `ptest` walk) and ISSUE-60 (static constructors need a modern `crt`), and a
third is the ISP's missing divide, recorded under §4.

**DMA.** A3091/SDMAC coherence hooks landed and hardware-verified. `bp_map`/`bp_mapout` are
native 040 ports (ISSUE-13).

**Filesystems.** UFS and NFS are hardware-clean, including the two NFS integrity defects
(ISSUE-35 write path, ISSUE-36 mmap tail) that were proved byte-for-byte from the server side.
`segmap`, `segvn` and `spec` paths are converted.

**SysV shared memory.** Two 2 KiB residuals, both kernel panics reachable by an unprivileged
process, are fixed and accepted on 68040 silicon: `shmget` sizes (ISSUE-62, six sites as one unit)
and 2 KiB-aligned `shmat` addresses (ISSUE-66).

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
**68LC060, from the second development line.** `fpuinit` now probes for the FPU instead of
assuming one, and each 060 arm of the FP context path is gated on the answer (`fpu_present`); the
gates are measured inert on the Mercury's 68060 (`*_nofpu_n` = 0,
`docs/REALHW-LC060-MERGE-260826.md`). Without an FPU every FP instruction ends in `SIGSYS`, which is
why `fsck` cannot repair a dirty root on that part (`docs/PLATFORM-LC060-Z3660.md` §2.1). The
software FPU — NetBSD's m68k FPE, linked by `relink-040-fpe.sh`, with `FPE=0` reproducing the base
byte for byte — was merged on 2026-08-28. Its bring-up on real silicon is in `docs/contracts/FPE-*.md`,
and it is not accepted.

**RAM > 32 MB.** The machine offers 48 MB in two regions (32 MB @`0x08000000` + 16 MB
@`0x07000000`, the second *below* the first) and AMIX counts only the one the kernel was loaded
into. Codex's analysis found **no technical ceiling**; the blocker is that the boot-time
algorithm does not recognise A and B as one pool. Bounded boot/startup work, not a counter bump.

**Zorro III.** Works, with the VA2000 on its Zorro III firmware, on both CPUs. Accepted on the
68060 on 2026-08-19 at **7.66 MB/s** against 3.12 MB/s for the same card on Zorro II, with a width
test showing a genuine 32-bit datapath (`docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md`); and on the
68040 on 2026-09-06/07, after two more defects were fixed — ISSUE-64 in the build and ISSUE-65 in
the 68040 write-back replay (`docs/REALHW-Z3-040-260906.md`). The driver reaches the board through
a kernel mapping (`dev_kvmap`) instead of dereferencing its AutoConfig address, takes the aperture
size from `autocon()`, and registers its framebuffer for the noncacheable class `Lcm_fb`;
ISSUE-47's guard stops `hardbus` trusting a probe that cannot reach the Zorro III band. Only this
one card is proven.

Why stock AMIX cannot do it, which is still true of every stock driver: DTT0 covers 0–1 GB,
`0x40000000` is the fixed u-area, and the rest of region 1 is live kernel virtual space --
**not** a "fill-on-fault kvseg", which this repository believed for months and which
`docs/AMIGA-PHYSICAL-MEMORY-MAP.md` refutes from `segkmem_fault`. **The pattern is Commodore's own**:
their TIGA driver dereferences the `autocon()` board address directly as a kernel pointer
(`amix-src` `sys/amiga/driver/tiga.c:45`, in its read/write path) and returns
`phystopfn(board + offset)` from `timmap` (`:104`). AMIX ships **no source at all** for the layer
that had to change — `sys/vm/` and `sys/ml/` contain only `exp` objects — which is why the work
there was disassembly-led by necessity.

**The second development line.** Four kernel defects found on Jussi's line are fixed in the base
and reach every image on both CPUs: `sync()` walking a NULL vfs switch on the panic path
(ISSUE-100), a page-frame database nothing zeroes (ISSUE-102), a one-frame panic backtrace
(ISSUE-104), and `xpanic`'s uninitialised sync decision (ISSUE-105). Only ISSUE-100 has been
confirmed on hardware, on the Z3660. The ISSUE-10 cure
(`src/hgfault040.s`, `hg_on` = 1) has also been in the base since the merge of 2026-08-25, proven
in the emulator only — §5. So have the ISSUE-10 audit instruments (`src/i10rev040.s`): dormant,
but present.

**Known panics from ordinary use.** Two are recorded and not fixed: `pollwakeup` calling through a
freed `polldat` at X session shutdown (ISSUE-63, 68060 hardware, two sightings), and closing
`/dev/noise` with sound still queued — a stock driver defect that any `SIGTERM` to a player
triggers (ISSUE-68, not investigated here, by the owner's request).

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
| 10 | stale PTE reuse / `amixadm` trigger | **OPEN** | 040 HW + emu | ⚠ July's "retired" was a dbg-instrument artifact; **intermittent, so a single-boot bisect is invalid**. A cure from the second line (`src/hgfault040.s`) is in the base since 2026-08-25, **proven in the emulator only** |
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
| 46 | `/dev/mem` mmap lands one page high | **OPEN** | 060 HW | a six-byte fix is identified and not applied |
| 47 | a user-mode bus error is mishandled, two different ways | **PARTLY FIXED** | 040 HW | the retry-forever case is guarded and accepted on `68040-260906-12`; `SIGKILL` rather than `SIGBUS` is not addressed by the guard |
| 48 | `va2_restore_passthrough()` does not restore passthrough on Zorro III firmware | **OPEN** | HW | a live machine looks crashed after X exits |
| 49 | 2 KiB `segdev` stepping under a 4 KiB MMU, and `/dev/screen` planes neither 4 KiB aligned nor page-rounded | **OPEN** | 060 HW (fault path) + 060 emu (driver half) | Fault path accepted on silicon 2026-08-27: battery **12/12**, `devmaptest` passes for the first time. Driver half written the same day — plane base was measured at `0x13800` on silicon and now allocates at `0x14000`; accounting closes to the byte in the emulator. Driver half accepted on silicon the same day in `-11`: 35/35 magics, battery 12/12, `scrfix_misalign_n` 0, accounting exact. **DPaint itself still not driven** |
| 50 | the burst step depends on a binary no clone can build | **OPEN** | — | test tooling |
| 51 | a burst read returned wrong bytes, silently, and the file was fine | **OPEN** | 060 HW | rare |
| 52 | the load average freezes on garbage after FP-heavy graphics | **OPEN** | 060 HW | no baseline to say whether it is new |
| 53 | `a3091intr` reads WD status for interrupts the SCSI controller never raised | **OPEN** | 060 HW captured ×4+ | stock-driver defect, shared with `a2091intr`: `ISTR` bit 4 is an aggregate, so a pure SDMAC event is dispatched on WD `SS` and the DFA goes `DEAD` with no way back. Source-demux wrapper accepted on 060 silicon 2026-08-27 (battery 12/12, burst 96/96, all invariants) — but **`a3w_eint_only = 0`**: `E_INT` was not set at the entry of any of 598 868 interrupts, so the wrapper changed nothing and the run is **not** evidence the fix works. Closing needs `a3w_eint_only > 0` |
| 54 | a WD phase mismatch on a device whose block size is not 512 killed the A3091 driver permanently | CONTAINED | 060 HW | a CD now returns `EIO` and the root disk keeps working (`68060-260830-06`). Same family as 53, different instance |
| 55 | the cross compiler existed only as an uncommitted working-tree change | CLOSED | build host | committed and offered upstream; the reconciled wrapper is installed and measured byte-neutral |
| 56 | `relink-040-dbg.sh` could not build at all | FIXED | build host | no gate runs the dbg script, which is how it went unnoticed |
| 57 | `devmaptest` printed PASS having measured nothing | FIXED | 040 HW (A3640) | a SKIP is no longer reported as a PASS |
| 58 | the A3091 demux reads `ISTR` as all ones, once in 726 interrupts | **OPEN** | 060 HW | unmeasured on the 040 |
| 59 | the 68060 `ptest` walk dereferences an unvalidated page-table descriptor | FIXED, **not yet run** | — | gated on `cputype == 60`; the Doom timedemo that found it waits for acceptance on a 68060 |
| 60 | C++ static constructors never run (1991 `crt1.o`) | OPEN — symptom record | — | not a defect of this port |
| 61 | AMIX's 1991 X11 archives carry a self-referential `sh_link`, and a modern GNU ld drops their relocations | RECORDED — symptom record | — | this port is not exposed |
| 62 | a `shmget` size whose remainder mod 4096 is 1–2048 panicked the kernel | FIXED | 040 HW | reachable by any unprivileged process; six sites as one unit, after two reverted attempts |
| 63 | `pollwakeup` calls through a freed `polldat` at X session shutdown | **OPEN** | 060 HW, two sightings | |
| 64 | the combined RTG kernel never got the Zorro III define | FIXED | 040 HW | the relink scripts now gate the driver's imports |
| 65 | the 68040 write-back replay split an aligned register write into bytes, and the Zorro III register window refuses the odd one | FIXED | 040 HW | the cause of the Xrtg `kstack` cascade on the 68040 |
| 66 | `shmat` accepted a 2 KiB-aligned attach address on a 4 KiB kernel | FIXED | 040 HW | `EINVAL` where it panicked; `SHM_RND` rounds down |
| 67 | every `/dev/kmem` tool reads symbols from a kernel that is not running | RECORDED | — | a tooling trap, not a kernel defect |
| 68 | closing `/dev/noise` with audio still pending panics the kernel | **OPEN** — stock defect | HW | any `SIGTERM` to a player triggers it; not investigated here, by request |
| 100 | the panic path walks the vfs switch through NULL in `sync()` | FIXED | Z3660 | second line; reaches every image |
| 101 | `config()`'s memory-sizing fallback is wrong at load base `0x08000000` | RECORDED, not fixed | — | second line |
| 102 | the page-frame database is never zeroed | FIXED, **not confirmed on hardware** | — | second line; fatal only on DRAM that is not zero-filled |
| 103 | `PANIC: segmap_unlock` at first root-mount I/O | CLOSED — symptom record | Z3660 | a defect of the card's emulation, not of this port |
| 104 | the panic backtrace stopped after one frame | FIXED, **not yet exercised on hardware** | — | second line |
| 105 | `xpanic` decided whether to `sync()` from uninitialised bits | FIXED, **not yet exercised on hardware** | — | second line |
| 106 | PID 1 dies at exec with a kernel-shaped user stack pointer | CLOSED — symptom record | Z3660 | a defect of the card's emulation, not of this port |

---

## 5. Release blockers

1. **ISSUE-10 and ISSUE-9** — two intermittent 68040 faults, captured but not attributed. Neither
   blocks normal use; both block a confident release claim. ISSUE-10 additionally carries a
   methodological trap: it is **intermittent**, so a single-boot bisect proves nothing, and July's
   "retired" verdict turned out to be a debug-instrument artifact. A cure for ISSUE-10 from the
   second line has been in the base since 2026-08-25; it is proven in the emulator, and a release
   claim needs it proven on silicon.
2. **Coverage, not correctness** — paths that have never executed anywhere:
   * the **WB1** write-back slot and its ISSUE-11 bus-lane realignment (the emulators never set
     WB1S valid; the A3640 run reached WB3 only);
   * ISSUE-43's two `UFPRWRT` branches — nothing in this repo writes FP registers through old
     `ptrace`, which is also audit gate 6;
   * ~~the **M0 vector probe**'s cost per syscall~~ — **measured 2026-08-30** on the A3640, and the
     probe now defaults off (`kvp_on = 0`); see §1.
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
3. ~~Decide the 68LC060 question~~ — answered by the second line: AMIX boots on one; floating
   point there is the FPE lane, not yet accepted.
4. ~~**Zorro III**~~ — done: the VA2000 on the 68060 on 2026-08-19 and on the 68040 on
   2026-09-07. Other Zorro III boards are untested.
5. The unexercised paths in §5.2, whenever their area is next opened.
6. **060-D, the two CACR knobs** (`docs/060-D-CACHE-KNOBS-PLAN.md`) — store buffer and branch cache,
   both still off. Motivated by the corrected clock: a superscalar 68060 is only 7.1 % faster per
   clock than the 68040, which is low. Needs the 060 back in the machine, so it is a batched
   session of its own, and the branch cache needs an instruction-cache-invalidation audit first.
7. **ISSUE-59 on a 68060**, before the Doom timedemo that found it is run again.

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
| `devmaptest` T1 passing means device mmap PFNs are correct | acceptance records up to 2026-08-13 | It was green because two defects cancelled: `d_mmap`'s round-up made both the `base` and `base+2048` mappings land on the same wrong page. Removing the round-up (ISSUE-46) exposed ISSUE-49 — a 2048-aligned device mmap offset yields the NEXT page, because the retained 2 KiB `segdev` stepping's second `d_mmap` call overwrites the first |
| `kvseg` is fill-on-fault, so an access to a Zorro III address lands on a zero page | `KNOWN-ISSUES.md`, `docs/archive/RESUME-HERE-260727.md`, `test-tools/b1-dcwt-verify-260723.txt` | `segkmem_fault` (`0xa83d6`) returns 0 only for `F_SOFTLOCK`/`F_SOFTUNLOCK` and **-1** for an ordinary `F_INVAL`; the 3B2 reference returns -1 unconditionally. Nothing there allocates a zero page. The symptom was real but the mechanism was wrong: **`0x40000000` is the fixed u-area**, so the read was serviced by a live kernel mapping. `docs/AMIGA-PHYSICAL-MEMORY-MAP.md` |
| A null FSAVE frame means "no live FP state" on the 68060 | ISSUE-43 rounds 1–3 | Byte zero is the **source operand's exponent**; the discriminator is byte two |
| DZ proved a null frame | ISSUE-43 round 1 | It proved its own operand was zero |
| "7100 null saves per boot" | ISSUE-43 round 3 | Collected through the wrong predicate. Remeasured: 8048 null / 17 idle per boot on hardware |
| Bit 0 of the u-area FP flags is a lazy-FPU owner bit | reverted attempt, `f00a9d2` | It is `UFPRWRT`, "software wrote the programmer model". Setting it turned 5-of-6 into 0-of-6 |
| ISSUE-10 was retired in July | `docs/archive/RESUME-HERE-260727.md` | It is back on probeless kernels and reproduces in the emulator; the "retirement" was a dbg-instrument artifact |
| `cc1`'s SIGSYS was something other than the missing FPSP | ISSUE-34b | It was the FPSP (F3 M5 §8) |
| `fpc_excp_n` would be non-zero on hardware | `docs/REALHW-RUNLIST-ISSUE43-260812.md` | Our own call-out converts the frame to idle before the OS sees it, so `0xe0` never reaches `fpu_save` |
| The ExecBase → `expansion.library` route can enumerate Zorro cards | early `lszorro` notes | AMIX overwrites the AmigaOS library list nodes |
| The Mercury 68040 runs at 33 MHz | every document before 2026-08-13 | **35 MHz** — 70 MHz oscillator at half clock. The 68060 runs at 66 MHz, full clock |
| The 68060's Dhrystone is "almost exactly the clock ratio", so scalar dispatch explains it | `docs/060-F0-MEASUREMENT-260805.md` §9 | The ratio is 1.886, the measurement 2.019 → **+7.1 % per clock**, measured with **ESS=1** (superscalar). A low surplus that points at the branch cache and store buffer, both off |
| The A3640 costs 6.5 % on Dhrystone versus the Mercury | an earlier draft of `docs/REALHW-A3640-260813-ACCEPTANCE.md` §9 | 0.8 %, i.e. nothing this benchmark can see. The 6.5 % was the 33 MHz artifact |
| ISSUE-64 caused the Xrtg `kstack` crash on the 68040 | `KNOWN-ISSUES.md` ISSUE-64, kept labelled | Fixing it left Xrtg crashing exactly as before. The cause was ISSUE-65, the write-back replay splitting an aligned register write into bytes |
| ISSUE-62's panic is `shmget`'s own 2 KiB constants | two reverted fixes, 2026-09-07 | Both passed the first half of the acceptance and failed the second with `PANIC: swap_xlate`. Three consumers held the 2 KiB assumption; the fix is six sites as one unit |

`docs/archive/RESUME-HERE-260727.md` is a snapshot of 2026-07-27 and has not been maintained since. Read it as
history; read this file for status.

---

## 8. Evidence index

| Area | Document |
|---|---|
| Issue detail and history | `KNOWN-ISSUES.md` (chronological, corrections in place) |
| 060 FP acceptance | `docs/REALHW-ISSUE43-ACCEPTANCE-260812.md`, `test-tools/issue43-emu-verify-260812.txt` |
| 060 FPSP acceptance | `docs/REALHW-260807-11-ACCEPTANCE.md` |
| 060 baseline before FPSP | `docs/REALHW-260806-06-ACCEPTANCE.md`, `docs/REALHW-F2-ACCEPTANCE-260806.md` |
| 040 acceptance | `docs/REALHW-ACCEPTANCE-260731.md`, `docs/REALHW-ACCEPTANCE-260801.md`, `test-tools/realhw-verify-260727.txt` |
| Pending 040 hardware work | `docs/archive/NEXT-040-SESSION-RUNLIST.md` |
| Static implementation contracts | `docs/contracts/INDEX.md` (34 normative records imported from the private analysis diary) |
| FP contract | `docs/contracts/FPU-LAZY-CONTRACT-AUDIT.md`, `docs/contracts/FPU-TIER1-ENABLE-SPEC.md` |
| RAM expansion | §3; the declined private analysis is not an implementation dependency |
| Zorro III | `docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md` (060), `docs/REALHW-Z3-040-260906.md` (040), `docs/Z3-BUSBENCH-Z2-MEASUREMENT-260810.md` (the Zorro II baseline) |
| Build and toolchain | `BUILDING.md`, `relink-040.sh`, `tools/check-env.sh` |
| Test tooling | `test-tools/README.md` |
| Acceptance procedure | `docs/ACCEPTANCE.md` |
| The second line's platforms | `docs/PLATFORM-Z3660.md`, `docs/PLATFORM-LC060-Z3660.md` |
| Software FPU (68LC060) | `docs/FPE-BRANCH-REVIEW-260828.md`, `docs/contracts/FPE-*.md` |
| Agreements between the lines | `CONTRACTS.md` |

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
| Redistribution hygiene | 463 tracked files after the contract import, no AT&T or Commodore source among them | `.gitignore` excludes `amix-src/`, `svr4-src-3b2/`, `usl-svr42/`, `ghindra-unix/`, kernel binaries, the distribution archives |
| Root password | **gone from the working tree and from every commit** | `git log --all -S` finds no commit containing it |
| Hard-coded home paths | 59 → **10, in 8 files, all prose** — none in any build script | `git grep /home/asokero` |
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
2. **Phase 7 — the push**, plus a publication tag. ~~A repository slug~~ — decided 2026-08-15,
   `kernelsupport` → `amix-040-060-port`. What remains can only be done once the repositories
   exist:

   * ~~**the repository URLs**~~ — `amix-unix-boot` is public and `README.md` links it; this
     repository has a private remote.
   * **the GitHub description**, which for most readers is the only text they will see before
     deciding whether to click. Use the README's subtitle verbatim, because it carries the one
     fact a reader must not miss:

     > Binary patch and override layer that runs Amiga UNIX (AMIX SVR4) on 68040 and 68060
     > processors — applied to the kernel binary from your own installation.

   * **topics**, which are what the search this project refutes will actually match. The Amiga
     Unix wiki lists the 68040 and 68060 as *incompatible* with AMIX, so someone checking that
     is the reader to be found by:

     `amiga` `amiga-unix` `amix` `68040` `68060` `m68k` `svr4` `unix` `amiga3000`
     `reverse-engineering` `binary-patching` `retrocomputing`

   The loader repository takes the same treatment: description *"Patches that make Markus Wild's
   unix_boot load an Amiga UNIX kernel on a 68040 or 68060 — patches only, you supply the
   archive"*, topics `amiga` `amiga-unix` `amix` `68040` `68060` `m68k` `bootloader`
   `retrocomputing`.
3. **`10.0.10.10` appears in 20 documents.** A private RFC1918 address, not a secret; a decision
   about tidiness rather than a blocker.
4. **ISSUE-9 and ISSUE-10 are open**, and honestly recorded. They argue for publishing as a
   technical preview rather than as a finished port — not for waiting.
