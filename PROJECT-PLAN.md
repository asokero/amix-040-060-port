# Project Plan — 68040 (then 68060) support for Amiga Unix

## ★ CURRENT STATUS (2026-06-22 night) — Phase 1 DONE, Phase 2 (single-user) in progress
The 040 kernel boots through ALL of Phase 1 (MMU-on) AND the whole VM/HAT format port AND
swap config: pstart040 → early init → segmap → svirtophys → hat_* → **root fs MOUNTS →
banner → init → swapconf configures → main creates all 4 daemons → proc 0 enters sched()**.
swapconf/namei (the old blocker) is SOLVED (gen_strategy PFN<<11→<<12).  **MEASURED
`maxrunpri=0x4F` at sched entry → the fork/enqueue path WORKS; the run queue is non-empty.**
**Current blocker = the 040 CONTEXT SWITCH** (swtch dispatch + resume@0x9c/save@0x84 + the
child context from setuctxt + the 040 trap/exception frames) — proc 0 never transfers to a
child.  Remaining for Phase 2: that context-switch chunk, then first user fork/exec (hat_dup/
hat_growsdt), then 040 trap frames.  **Canonical detail: RESUME-HERE.md (SOURCE MAP + BATCH
PLAN).**  Source map in memory kernel-source-vs-binary.md (traps = SOURCE ttrap.s/vec.s;
save/resume/swtch = binary RE).  Real-HW line PAUSED (RESUME-HERE-040-HARDWARE.md).

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
       boots 030 normally. See `prototypes/README.md`.
2. [ ] **`_start` `pflusha`** (0x38/0xb2, encoded `f000 2400`) → 040 encoding. NOTE:
       did **not** trap on the 040 boot (path apparently not executed before pstart) —
       fold into the pstart work, low priority.
3a. [x] **`pstart` Draft 1 — no-paging probe.** `prototypes/patch_pstart_040.py`
       patches the stock `unix` → `build/unix-040`: replaces the 030 MMU-enable at
       0xfd6 with `pflusha(040); bra.w 0xfe6` (skip enable; 040 stays flat 1:1 as
       copyit left it). Branches over the tc_on reloc so no ELF surgery. Lets AMIX boot
       flat and expose the next blocker. See `prototypes/README-pstart-040.md`. Awaiting
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
ALSO DONE: Phase 1.1 prototype `prototypes/copyit.s` (040/060 MMU-disable, validated).
Next, pick one:
1. **`_start` + `pstart` 040 patch** (Phase 1.2–1.3) — the in-kernel counterpart to the
   copyit fix: re-encode `_start`'s `pflusha`, then rewrite `pstart`'s MMU-enable
   (4-byte descriptors, 7/7/6, 4 KB, `movec %tc/%srp`). The next crash after copyit.
2. **Toolchain validation** (Phase 0) — once the user builds `gcc-cross-amix`, recompile
   `alien/scsi.c` and diff against the shipped `scsi.o` to prove ABI-compatible relink.
3. **Map the remaining MD surface** — disassemble `resume`/`swtch` cache+MMU reload and
   the FPU detect (`chk_fpu`/`fpuinit`) to complete the Phase 2/3 RE inventory.

User-side TODO before code can be tested: build `unix_boot` (with `prototypes/copyit.s`)
and confirm the Phase 0 loop on fs-uae 030, then switch to 040.
