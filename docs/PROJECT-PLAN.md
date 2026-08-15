# Project Plan — AMIX 68040/68060 Port

> **Canonical status: [`STATUS.md`](../STATUS.md).** Where this file and STATUS.md disagree,
> STATUS.md is right and this file is history.

## ★ CURRENT STATUS (2026-07-09) — ISSUE-7 AND ISSUE-8 RESOLVED; 040 boots to login, survives workload + reboots
**Milestone (2026-07-09):** the 040 kernel now **boots to login on fs-uae, runs `ls -alR`, and
survives 7 reboot cycles with ZERO panics** — the weeks-long ISSUE-7 is fixed. Verified from
serial (no `PANIC`/`Bus Error`, no `kstack`/`KSTKCHAIN`/`PREEMPT1 uprocp=0` recursion signature,
clean `haltsys`).

**Fix chain this session (all committed to master, all boot-tested):**
- **ISSUE-8 RESOLVED** (commit `ef3eb90`) — `kvm_init` leaf-table `ctob`/`btoc` left at 2 KB in the
  Model-B conversion → halved `word2` leaf phys (0x038A7000, a real-HW hole). 6-patch source-backed
  fix. The earlier "click<<11 DISPROVEN" verdict was itself wrong (fs-uae masked the halved read;
  only 2 of 6 sites had been patched). Emulators now behave identically.
- **ubptbl wrappers** (commit `0cc9fb4`) — `segu_get`/`swapinub` rebuild `p_ubptbl` from the live
  kptr040 tree (same halved-leaf exposure, closed for the fork path).
- **ISSUE-7 RESOLVED** (commit `c0a3cd8`) — ROOT was `wb040`: its write-back replay re-issued the
  faulted store with one wide `moves`, so an UNALIGNED PAGE-CROSSING store (KSTKWB: long "xres"
  @0x40736FFE) had only its near page resolved → infinite re-cross/re-fault → the recursion ate the
  u-area kernel stack → `u_procp=0`. Fix = replay BYTE-WISE. **Never a HAT bug** — which is why the
  10 HAT hypotheses all missed. Diagnostic probes: commit `3aeeb7c`.

- **Cold-boot flakiness RESOLVED** (commit `55b211b`, 2026-07-09 PM) — the `ed`/`more` warm-up
  requirement was a LOADER bug, not kernel or uninitialized memory: `AllocMem(MEMF_FAST)` placed
  the ELF buffer where the ~0.96 MB image OVERLAPPED it by ~25 KB, and `copyit`'s inverted
  copy-direction choice corrupted the first 25 KB of the copied kernel (incl. `_start`) → wild
  execution at handoff. Proven live with a copyit checksum verify (white/red flash on mismatch).
  Fixes: overlap-safe copy directions + `MEMF_REVERSE` top-of-RAM buffer + the checksum verify
  kept as a permanent guard. Verified: repeated cold Amiberry boots, zero warm-up. The real-A3000
  "1st boot → guru" pattern is very likely the same bug.

**Next-session frontier (see archive/RESUME-HERE-260727.md + archive/RESUME-HERE-040-HARDWARE.md):** (1) **real-HW retest**
on the Mercury-040 with the fixed kernel AND the fixed loader (expected: past the p0init panic and
no first-boot guru; untested on silicon). Deferred: **ISSUE-9** idle-time Bus Error loop.

<details><summary>Prior status (2026-07-07) — Phase 2 usable, ISSUE-7 hunt paused (historical)</summary>

`unix-040-quiet` (serial-capable quiet build) boots and runs **NetHack** — the first real
fork/exec/terminal/timer-heavy workload beyond ls/uname smoke tests. patch_modelb.py = **237
sites**. Everything through login + `ls -alR` + reboot + fsck works on a clean disk image.

**Merged + boot-tested (no regression) this session (all on master):**
- **ISSUE-4 (hat_dup) CLOSED** — the real `hat_dup040` fork/COW port is merged into the base
  (commit 17b6081), single strong override in both `unix-040` and `unix-040-dbg`. Boot-tested:
  no regression. (Direct fork-without-exec COW *stress* validation still pending — the
  `amix-kernel-analysis/runtime-tests/hat_dup_cow` acceptance test is built but not yet run; see below.)
- **hat_map phantom-PTE bug FIXED** (commit 178364a) — retained stock hat_map was writing
  legacy `pfn<<11` phantom PTEs into `pp->p_mapping` chains, mixing formats with the live
  `pfn<<12` entries. A 1-byte preload-disable removes the phantom producer (chains are now
  single-format from every producer); boot-tested, no regression. Plan:
  `src/hat-map-040-fix-plan.md`.
- **hat_sdtfree Model-B pfn fix** (commit 05d7c99) — its 2 free-side shifts were missed by the
  2KB→4KB conversion (alloc side was done); could corrupt an unrelated page's offset-32
  metadata. Real bug, fixed. (Was tested as an ISSUE-7 candidate — ruled out, see below.)
- Two hat_ptalloc CANWAIT→CANWAIT|NOSTEAL hardening sites (no effect on tested workloads).

**ISSUE-7 — OPEN, active hunting PAUSED by user decision.** The second-dirty-boot `u_procp=0`
login-prompt crash is now **10 hypotheses ruled out** (incl. this session: hat_unload missing
cpusha, setuctxt kmem_alloc sleep window, hat_sdtfree pfn — all boot-tested negative). New
diagnostic **PREEMPT6** confirmed across multiple crashes that the corruption is **isolated to
exactly one proc** (not systemic). Three well-motivated leads ruled out in one week → user
paused the one-hypothesis-at-a-time hunt. System stays fully usable from a pristine image.
Best remaining idea when resumed: a generic offset-32 (`p_mapping`/`p_sdtbits`/`p_ptdats`
union) write-guard. Full detail: KNOWN-ISSUES.md ISSUE-7.

</details>

**Remaining HAT items — all now audited + DEPRIORITIZED (none is an active bug):**
- **hat_pagesync** — lacks the 040 `cpusha bc` after clearing ref/mod bits, BUT **latent**:
  the 040 data cache is currently OFF (verified: live path pstart040 never enables CACR), so
  it only bites once D-cache is enabled. `hat_pagesync040` plan noted; coding → Fable.
- **hat_exec** — RE'd this session (`src/hat-exec-040-fix-plan.md`): currently **inert +
  defanged**, not "neutered by guards" as previously thought. Its fast path (the observed
  hatflag=1 case) moves no live mapping; its false root descriptors are already rejected by
  every ported walker's kernel-base guard. Cleanup value only; deprioritized.
- **hat_ptfree** doesn't retire its `ptdat` from `active_pts`/`free_pts` (offset-32 suspect,
  no observed bug); **hat_chgprot ×6 caller sites** (routine itself confirmed correct);
  **uvirtophys/uvatosde**; **vm_swap 2KB units**.

**Assessment:** audit-driven HAT work has largely hit diminishing returns for *urgent* fixes.
Next real bugs are more likely found by DRIVING WORKLOADS (the project's proven method) than
more static auditing. Immediate next step: run the `hat_dup_cow` acceptance test (deferred —
see the network blocker note in archive/RESUME-HERE-260727.md), then heavier workloads.
Canonical blow-by-blow: archive/RESUME-HERE-260727.md; bug detail: KNOWN-ISSUES.md; memory
`amix-codex-hat-audit-findings`.

## (2026-07-06, HISTORICAL SNAPSHOT — superseded by the ★ block above; kept for the fix chain)
> The "Remaining for a clean multi-user BASE" list in this block is STALE (hat_dup is now
> merged+boot-tested; hat_exec re-characterized as inert). Use the ★ block above for current
> status; this block's value is the historical fix-chain record. "235 sites" / "7 hypotheses"
> here are the 07-06 numbers (now 237 / 10).

The 040 kernel boots to an interactive `root` login and runs `ls -alR | wc`, `uname -a`, etc.
(fs-uae, `unix_boot unix-040-dbg`).  A full **clean boot → login → `ls -alR` → reboot cycle now
succeeds cleanly.**  Everything up to and through login works: Phase 1 (MMU-on), the whole VM/HAT
format port, swap config, the 040 context switch (resume040 dual-path remap), root fs mount,
init + rc scripts, getty/ttymon respawn, login, and basic user commands.  patch_modelb.py = **235
sites** (Model-B byte patches).
**Fixed 2026-07-05/06 (all on master — see KNOWN-ISSUES.md ISSUE-5/6):** the `reboot` path
(haltsys/rtnfirm ran an illegal 030 pmove → now unconditional 040 movec MMU-disable); `fsck` on a
dirty UFS (`swap_xlate`/`swap_anon` 2KB→4KB + reverted a mislabeled PAGE_HASHFUNC byte-patch);
`hat_unload040` V2.3 (guard had made it a silent no-op for all kernel VAs); `segu_get` SEGU_LOCKED
(Model-B loop-bound patch dropped the flag).
**Prior wins (06-22..07-04, boot-verified):** context switch, first fork/exec, brk/grow 2KB
roundups, the seg_vn per-page-array +99 sweep, hat040 table freeing, the date/hardbus page-crossing
hang, the "Killed"/rtld-SIGKILL (anon_zero ZFOD half-zero), the segu /proc window (VOP lens +
prumap040), and the sptmap arena free-side.
**Known OPEN — ISSUE-7 (KNOWN-ISSUES.md):** a SECOND boot from a kernel-contaminated disk panics
at the login prompt — a process's u-area has `u_procp=0` (fresh-zero page, non-swap mechanism);
extensively narrowed (7 hypotheses ruled out by runtime probes) but ROOT not yet found.  System
stays USABLE for clean cycles.  Full diagnostic infra + resume points documented in ISSUE-7.
**Remaining for a clean multi-user BASE (unix-040, no dbg overlay):** ~~port hat_dup~~ MERGED
2026-07-07 (ISSUE-4, awaiting boot test); **hat_chgprot ×6 caller sites** (fork COW — the routine
itself is now confirmed structurally correct by audit), **hat_exec** (exec stack move, currently
neutered by guards — also confirmed unported by audit, with a sharper risk: its `hat_ptfree` call
passes an old-format table pointer that the guard can't distinguish from a real 040 table),
**uvirtophys/uvatosde** user walkers, **vm_swap 2KB units**, and a newly-audited-but-deferred item:
`hat_ptfree` doesn't retire its `ptdat` from `active_pts`/`free_pts` on free (not yet an observed
bug; full detail in `amix-kernel-analysis/vm-map/HAT-PTFREE-AUDIT.md`).  Also
pending: migrate the dbg-only genuine fixes (resume040 etc.) into the base + strip diagnostics so
`unix-040` boots standalone (a "quiet" serial-capable variant — `unix-040-quiet` — is BUILT and
boot-confirmed for real-HW testing, see archive/RESUME-HERE-260727.md).
**Canonical detail: archive/RESUME-HERE-260727.md** (milestone + fix chain + BATCH PLAN) and KNOWN-ISSUES.md.
Source map in memory kernel-source-vs-binary.md.  Real-HW line: a USB-serial adapter is incoming,
so real-HW testing is becoming feasible again (see archive/RESUME-HERE-040-HARDWARE.md + SERIAL-DEBUG.md).
A parallel Codex analysis project (now a SEPARATE sibling repo `../amix-kernel-analysis/`, moved
out of this repo 2026-07-07 to keep copyright-sensitive RE material in its own version control) is
mapping the whole kernel against the source tree.

## Goal
Make the AMIX SVR4 kernel boot and run on 68040, then 68060, on an Amiga 3000.
68040 first; 68060 as an increment on the proven 040 base.

## Hardware / environments available
- **Real Amiga 3000**, motherboard 68030 (current working AMIX).
- **PPS Mercury turbo**: default 68040 @ 33 MHz; currently a **68060 Rev6 @ 66 MHz**
  via an 040→060 adapter. CPU is swappable → both 040 and 060 testable on real iron.
- **fs-uae** with the AMIX disk image — primary fast-iteration dev target
  (accurate CPU emulation with MMU; **not** JIT).
- Host dev tools: `m68k-linux-gnu-{objdump,gcc,as,ld,readelf,nm}` installed (analysis/RE).
- **AmigaOS cross-toolchain** (bebbo amiga-gcc) at `~/kehitys/amiga-gcc-bin`
  (`m68k-amigaos-gcc`, GCC 6.5; the source tree `~/kehitys/amiga-gcc` is a failed 2020
  build — use the `-bin` one). Builds `unix_boot` (the AmigaOS-side bootstrap). Its `as`
  knows 040/060 MMU ops natively. **This is the toolchain for `unix_boot`, distinct from
  the AMIX kernel toolchain below.**
- **AMIX cross-toolchain** at `/home/asokero/kehitys/amix-playground/gcc-cross-amix`
  (acquaintance's, new): target `m68k-cbm-sysv4`, GCC 2.7.2.3 + binutils 2.8.1.
  C/as/ld work; produces `ELF MSB relocatable M68000` objects matching native AMIX
  kernel objects. **This is the relink/replacement-object toolchain for Approach A.**
  Kernel dialect: `-O -traditional -fno-builtin -Dinline=__inline__ $(CPUFLAGS)`;
  `as` CPU flag is independent (`-m68030/-m68040`). Not built yet. Caveat: gcc 2.7.2.3
  has `-m68040` codegen but likely **no `-m68060`** (use 040 codegen + hand-asm for
  060-specific bits; `as` 2.8.1 does assemble 060 mnemonics).

## Division of labour
- **Claude:** reverse engineering via `objdump` + analysis; writing asm/C patches and
  replacement objects; building/relinking; documentation. *Cannot run the kernel.*
- **User:** runs fs-uae and the real A3000; reports crashes/register state/screens;
  swaps CPUs; installs host packages (sudo).
- **Ghidra:** optional, user-side only (interactive browsing). Not on Claude's path.

## Reference implementations
NetBSD/amiga (68040 **and** 68060, same hardware family) — primary reference.
Linux/m68k `fpsp040/` + `ifpsp060/` — FPU/integer software packages.
Motorola M68040 FPSP / MC68060 SP — the originals. AmigaOS `68040.library`/`68060.library`.

---

## Phases & milestones

### Phase 0 — Establish the iteration loop + toolchain (no kernel logic changes yet)
- [x] Boot the **unmodified** `unix` via `unix_boot` in fs-uae on **030** emulation.
      Confirms: ELF load, bootinfo build, MMU handoff, multiuser — the whole loop. DONE
      (fs-uae A3000, KS 3.2). The 040-aware `unix_boot` also boots cleanly on 030.
- [x] Build `unix_boot` from `unix_boot/src` — DONE with bebbo amiga-gcc
      (`~/kehitys/amiga-gcc-bin`, m68k-amigaos GCC 6.5). Now contains the 040/060-aware
      `copyit.s`. Reproduce with `unix_boot/build.sh`. Verified the 040 opcodes
      (movec tc/itt/dtt, pflusha f518, cpusha f4f8) + the 030 pmove fallback are all in
      the final binary. Required small NDK modernizations (execname.h, Alert arity,
      proto/exec+expansion, FindConfigDev, clib2) — originals saved as `src/*.orig`.
- [x] **Build the AMIX cross-toolchain** (`gcc-cross-amix`): DONE. `make all
      AMIX_ROOT=.../vanilla AMIX_USR_LIB=/nonexistent` (skip root-only usr/lib daemons).
      Installed to `~/opt/amix-cross` (gcc 2.7.2.3, binutils 2.8.1, target m68k-cbm-sysv4).
      Env: `gcc-cross-amix/build/env.sh` (sets AMIX_KERNEL_CFLAGS).
- [x] **Validate ABI compatibility (critical): PASS.** Recompiled `alien/scsi.c` (sources
      in `amix-src/` from amix-sources.tar) and compared to shipped `scsi.o`:
      `.text` IDENTICAL (368 bytes), ELF header/flags IDENTICAL, same global (`gsioctl`) +
      same externals (copyin/copyout/sdopen/sdqueue/sleep/wakeup), relocs all `R_68K_32`.
      Only cosmetic diffs (gcc_compiled%→gcc2_compiled, static-local numbering, equivalent
      instruction selection: moveml↔movel pairs, bftst↔moveq+and). **Approach A confirmed:
      replacement objects link with the existing kernel.**
- [x] **Prove the full relink: DONE (better approach found).** The shipped `unix` is
      itself a relocatable `ld -r` object (symbols + R_68K_32 relocs intact), so we don't
      need to rebuild from the subsystem exps (several of which — amiga/exp, master.d,
      local, config/unix.o — aren't in amix-sources.tar anyway). Instead `relink-pstart.sh`
      re-links the final `unix` directly: `m68k-linux-gnu-objcopy --redefine-sym
      pstart=pstart_030` (cross objcopy 2.8.1 lacks --redefine-sym) then `m68k-cbm-sysv4-ld
      -r` with a replacement object. Verified: cross `ld -r` round-trips `unix`
      byte-faithfully (same text/data/bss 881064/65236/67600, 6888 syms, 28088 relocs).
      Validation artifact `build/unix-040-relinktest` overrides pstart with a trampoline
      (`jmp pstart_030`) → behaviour-preserving. *Awaiting boot test (030=full boot,
      040=same pstart pmove crash as stock).* This IS the Draft-2 relink pipeline.
- [x] Switch fs-uae CPU to **68040**; observe the expected early crash (the
      reproducible bring-up baseline). DONE — baseline is now bind_base+0xfd6
      (pstart's `pmove %a0@,%srp`), the first in-kernel MMU instruction.
**Exit:** one-command "edit source → recompile object → relink `unix` → `unix_boot` →
see result" cycle, validated on 030, ready on emulated 040.

### Phase 1 — 68040 boot to MMU-on (the hard core)
Order = execution order from `boot-path-map.md`:
1. [x] **`copyit.s` MMU-disable** (in `unix_boot/src`, source!): `pmove`→`movec`,
       AttnFlags-guarded (AFB_68040=bit 3). *First crash point, before kernel runs.*
       → **DONE + VALIDATED on emulated 040** (fs-uae, KS 3.2 / A3000.47.111,
       cpu=68040 mmu=68040, AttnFlags=0x804f so 040-bit set). The 040 movec path runs:
       no more chip-RAM pmove trap; MMU disabled, kernel copied, entered. Boot now dies
       at the *next* blocker — the in-kernel pmove in `pstart` (below). copyit also still
       boots 030 normally. See `src/README.md`.
2. [ ] **`_start` `pflusha`** (0x38/0xb2, encoded `f000 2400`) → 040 encoding. NOTE:
       did **not** trap on the 040 boot (path apparently not executed before pstart) —
       fold into the pstart work, low priority.
3a. [x] **`pstart` Draft 1 — no-paging probe.** `src/patch_pstart_040.py`
       patches the stock `unix` → `build/unix-040`: replaces the 030 MMU-enable at
       0xfd6 with `pflusha(040); bra.w 0xfe6` (skip enable; 040 stays flat 1:1 as
       copyit left it). Branches over the tc_on reloc so no ELF surgery. Lets AMIX boot
       flat and expose the next blocker. See `src/README-pstart-040.md`. Awaiting
       fs-uae 040 test. *Name `unix-040` deliberately distinct from `unix`.*
3. [ ] **`pstart` MMU-enable** (RE: `0xd44`–`0xfe4`): **this is now the live blocker.**
       Trap confirmed at bind_base+0xfd6 = `pmove %a0@,%srp; pflusha; pmove imm,%tc`.
       But pstart *builds the whole bootstrap root table itself* (0xd86–0xf26) in 030
       long-format (status 0xC0/0xD0, DT in byte 3, **2 KB rounding** `+2047`/`>>11`),
       so this is a **full-function rewrite**, not a 3-insn swap: 040 4-byte descriptors,
       fixed 7/7/6 tree, **4 KB pages**, `movec %srp/%tc`, `pflusha`=f518. *Hardest step.*
       Cleanest via a replacement `pstart` object relinked with the cross-toolchain.
4. [ ] **CACR / cache** (`mlsetup` + `ttrap.s`): 040 cache enable; begin `CINV`/`CPUSH`
       model (no copyback DMA yet — keep caches conservative for bring-up).
**Exit:** kernel reaches `main()` / idle loop on emulated 040, MMU on, FPU disabled.

### Phase 2 — 68040 single-user, no FPU
5. [ ] Page-size ripple: HAT layer (`hat_pteload`, `vatopte`), all `>>11`/`+2047`
       PFN math, segment/swap granularity → consistent with new page size.
6. [ ] Exception frames: `framesz` table + `stkclear`/`stkrestore` for 040 formats.
7. [ ] `resume`/`swtch` context-switch MMU+cache reload (RE + replace).
8. [ ] First user process; reach single-user shell. FP programs deferred.
**Exit:** multiuser/single-user shell on emulated 040.

### Phase 3 — 68040 FPU + cache coherency
9. [ ] FPU: 040 FSAVE/FRESTORE frame sizes + internal-FPU detection (`fpu.s`/`fpu.c`).
10. [ ] Integrate **040 FPSP** (port Linux/Motorola) on the F-line/unimplemented vector.
11. [ ] **DMA cache coherency**: `CPUSH`/`CINV` around SCSI (`a3091.c`) DMA buffers —
        required once data cache is in copyback. (Intersects the synchronous-SCSI work.)
**Exit:** FP user programs run; SCSI stable with caches on. → move to **real A3000 + 040**.

### Phase 4 — Real hardware (68040)
12. [ ] Boot on the A3000 with the Mercury in 040 mode via `unix_boot`, then as the
        installed kernel. Validate timing-sensitive paths the emulator may hide.

### Phase 5 — 68060 increment
13. [ ] 060 MMU/cache deltas (mostly shared with 040).
14. [ ] **060SP**: software emulation of unimplemented integer ops (64-bit
        mul/div, `movep`, `cas2`, …) + extra FPU; software MMU table walk (no `PTEST`).
15. [ ] Test on real 060 Rev6 @ 66 MHz.
**Exit:** AMIX multiuser on 68060.

---

## Key technical decisions to make early
- **Page size: 4 KB vs 8 KB.** Constrains the entire VM rework (Phase 1.3 / Phase 2.5).
  Prototype on paper before coding. 4 KB = less wasted memory, more PTEs; 8 KB = fewer
  PTEs, simpler tables, more internal fragmentation. (Lean 4 KB unless tables get ugly.)
- **Cache strategy for bring-up.** Start write-through / conservative; move to copyback
  only after DMA coherency (Phase 3.11) is in.
- **Replacement-object vs binary-patch.** Prefer shipping replacement `.o`s that the
  link pulls in over the binary-only originals (relocatable ELF makes this clean).
  The `gcc-cross-amix` toolchain makes this concrete: write replacements in C/asm,
  compile to `m68k-cbm-sysv4` objects, relink with the shipped `.exp` objects. Binary
  patching drops to a last resort for tiny size-neutral tweaks during bring-up only.

## Top risks
1. **Page-size change ripple** (binary-only VM, hundreds of sites) — the showstopper.
2. **Cache coherency** — silent corruption; worst on 060 copyback + DMA.
3. **Binary-only RE** for `pstart`/`resume`/`swtch`/`hat_*`/`fpu.*` — mitigated by full
   symbols+relocs and NetBSD reference, but still the slow part.
4. **Missing MD sources** — locating original `machdep.c`/`vm_machdep.c`/`fpu.s` would
   collapse much of the RE; worth a parallel search.

## Artifacts so far
- `68040-68060-support-analysis.md` — full feasibility + RE analysis.
- `boot-path-map.md` — instruction-level boot path, AmigaOS→MMU-on.
- `mmu-format-030-to-040.md` — **Phase 1.3 spec**: exact 030 page-table format
  (TC 0x82B02D60, 2/13/6 3-level, 2 KB, 8-byte long descriptors) → 040/060 format
  (4 KB, fixed 7/7/6, 4-byte PTEs, CM cache field). Page-size decision locked: **4 KB**.
- `PROJECT-PLAN.md` — this file.

## Status 2026-06-16 #2 — Draft 1 (no-paging probe) tested: KERNEL RUNS
`unix-040` (paging skipped) booted on emulated 040 **past pstart/vstart/mlsetup** into the
kernel's console + fault machinery. fs-uae log run 2: MMU stays disabled, **zero illegal/
F-line traps** — no more 030 instructions hit. The kernel then enters a recursive trap in
`krnlflt` (kernel fault handler @0x5b30c→cmn_err), kstack marching down −0x88/iter.
ROOT CAUSE = **the no-paging probe's designed limit**: the kernel's `u`-area lives at
virtual `0x40000000` (mapped via kuptr only when paging is on). Flat/paging-off ⇒ accessing
`u` (which krnlflt and ~everything does) hits a bus error ⇒ recursion. (Co-factor: krnlflt
reads the exception frame at 030 offsets; 040 frames differ — Phase 2.6.) **Conclusion: real
040 paging is now required to go further — Draft 1 has served its purpose.**
→ DRAFT 2 = real 040 bootstrap paging in pstart (see Phase 1.3). Needs a replacement pstart
object (040 table-build is larger than the 030 original ⇒ won't fit in-place) ⇒ ENABLER:
get the full kernel relink working (the deferred Phase-0 item) so we can ship a replacement
`pstart` + relink to `unix-040`.

## Status 2026-06-16 (validated on emulated 040)
copyit 040 path **proven**: AttnFlags=0x804f, 040 movec path taken, boot reaches the
kernel and dies at the in-kernel `pstart` pmove (bind_base+0xfd6). `unix_boot` diagnostic
prints AttnFlags before handoff. `fs-uae.log.txt` shows the trap progression chip→kernel.
**Next live blocker = pstart full rewrite (Phase 1.3).** Enabler needed: build the AMIX
cross-toolchain so pstart can be rewritten in C/asm and relinked (or hand-assemble +
binary-patch, but pstart's 040 form is larger than the 030 original → needs a code cave
or relink). Recommend: user builds `gcc-cross-amix`; Claude drafts the 040 `pstart`.

## Resume point (next working session)
DONE: `pstart` deep-dive + **HAT-layer format verification** — `hat_pteload`/`hat_asload`
confirmed to use the identical 030 format as `pstart` (VA decode 30/17/11, 8-byte table
descs, 4-byte leaf PTEs, 21-bit PFN). The 040 rewrite is uniform across all HAT funcs.
See `mmu-format-030-to-040.md` §1.5.
ALSO DONE: Phase 1.1 prototype `src/copyit.s` (040/060 MMU-disable, validated).
Next, pick one:
1. **`_start` + `pstart` 040 patch** (Phase 1.2–1.3) — the in-kernel counterpart to the
   copyit fix: re-encode `_start`'s `pflusha`, then rewrite `pstart`'s MMU-enable
   (4-byte descriptors, 7/7/6, 4 KB, `movec %tc/%srp`). The next crash after copyit.
2. **Toolchain validation** (Phase 0) — once the user builds `gcc-cross-amix`, recompile
   `alien/scsi.c` and diff against the shipped `scsi.o` to prove ABI-compatible relink.
3. **Map the remaining MD surface** — disassemble `resume`/`swtch` cache+MMU reload and
   the FPU detect (`chk_fpu`/`fpuinit`) to complete the Phase 2/3 RE inventory.

User-side TODO before code can be tested: build `unix_boot` (with `src/copyit.s`)
and confirm the Phase 0 loop on fs-uae 030, then switch to 040.
