# 68060 Port Pre-Study

**Status: Phase 060-B IMPLEMENTED on this branch (2026-07-10) — statically validated,
AWAITING BOOT TEST.** See §7 for what was built and how to test it. The pre-study
below (2026-07-09) is the plan it implements.

This document maps what adding 68060 support to the AMIX kernel would take,
**building on the completed 68040 port** (interactive login works, cold boot
deterministic, quiet/dbg twins boot-verified on Amiberry). It supersedes the
060 sections of `68040-68060-support-analysis.md`, which was written *before*
the 040 port existed — most of the mountain described there (page-size change,
PMOVE→MOVEC, HAT rework, exception-frame plumbing) **has already been climbed**
and carries over to the 060 unchanged.

All census numbers below were measured this session against the vanilla kernel
disassembly and the **built `build/unix-040`** (all patches + overrides baked in).

---

## 1. Executive summary

The 060 delta on top of the finished 040 port is **small and precisely bounded**:

| Area | 040 → 060 delta | Size |
|------|-----------------|------|
| MMU programming | identical (URP/SRP/TC/ITTx/DTTx via MOVEC, 4KB pages, PFLUSHA, CPUSH/CINV all valid) | **zero** |
| PTEST | removed on 060 → our `ptest040.s` (1 `ptestr` + 1 `movec %mmusr`, the only 060-illegal sites in the whole built kernel) needs a software table walk | small |
| Access-error frame | 060 has **no format 7** — `wb040.s` write-back replay (the ISSUE-7 pain) is simply never invoked. Instead 060 pushes a **format 4** frame (16 bytes, FA + FSLW) and *restarts* the faulted instruction in hardware | medium |
| Unimplemented integer instrs | kernel-wide census: **only `lmul`** (3 × 64-bit `muls.l`; callers `hrt_alarm`, `hrt_newres`) — rewrite one 30-byte helper, no 060SP needed kernel-side | tiny |
| FPU | same open state as the 040 (`fpu_present` runtime flag, FPU-disabled bring-up); full FP = 060SP, shared with the deferred 040-FPSP phase | deferred |
| Caches | stock 030-format CACR values land as caches-off on 060 exactly as on the 040 — safe; branch cache stays off (EBC clear) | zero (for bring-up) |
| Loader | `unix_boot040` already reads AttnFlags, prints the 060 bit, and takes the movec path for 040 **and** 060 | **zero** |

**Verdict:** an emulator-bootable 060 test kernel is a realistic ~3–6 session
project, *easier than the remaining 040 hardening was*, because the single
hardest 040 mechanism (format-7 write-back replay) does not exist on the 060.
A **single dual-040/060 binary is feasible** (§5) and is the recommended shape.

---

## 2. What carries over from the 040 port (no work)

* **Model B VM** — 4KB clicks/pages everywhere, `patch_modelb.py`, kvm_init
  ctob/btoc fixes, `segu_ubptbl040`, `hat_dup040`, the whole HAT rework.
  The 060 MMU uses the *identical* 3-level table format and 4KB page size.
* **MMU register programming** — every `movec` we emit (`urp`, `srp`, `tc`
  `0x8000`, `itt0/1`, `dtt0/1`) and `pflusha` (`0xf518`) is bit-identical on
  the 060. `pstart040.s`, `hat040.s`, `prumap040.s`, `haltsys040.s`,
  `hat_chgprot040.s`, `copyit.s` need **no changes** (audited: instruction-level
  census of all 40 override objects found zero 060-illegal instructions outside
  `ptest040.s`).
* **CPUSH/CINV** — same opcodes and semantics on the 060.
* **Loader** — `unix_boot.c` already decodes `AFB_68060` from AttnFlags and the
  040/060 path in `copyit.s` is shared. Checksum guard, MEMF_REVERSE buffer and
  the `.data%4` alignment rule are CPU-independent.
* **Infra** — relink scripts, `--weaken-symbol` override mechanism, serial
  debug (`serdbg`), build-id stamp, `check_relink_relocs.py`.

Stock `pstart`'s leftover `pmove` bytes (0xfd6/0xfde) are dead code — the
`pstart` symbol resolves to our override; verified in `build/unix-040`.

---

## 3. The actual 060 deltas (the work)

### 3.1 Access-error path: format 7 → format 4  *(the main task)*

The 040 pushes a 30-word **format 7** frame on access error and expects software
to replay pending write-backs (`wb040.s` — source of ISSUE-7). The 060 removed
all of that: it pushes an 8-word **format 4** frame and uses an **instruction
restart** model — after the handler fixes the page and RTEs, the CPU re-executes
the faulted instruction itself. No write-back replay, ever.

Format 4 layout (16 bytes): SR(+0), PC(+2), fmt/vec(+6), **FA(+8)**, **FSLW(+12)**.
FSLW encodes R/W, size, TM/TT, MA (misaligned), and error causes — it replaces
both the 040 SSW and MMUSR-after-PTEST as the fault-classification source.

Work items:

1. **`framesz[4] = 16`** — one byte. Measured: the table (`.data+0x72ac`,
   entries `8 8 12 0 [0] 0 0 60 0 20 32 92 ...`) has format 4 = 0 today;
   interestingly format 7 = 60 was in the vanilla table all along.
2. **`getfault060`** — decode FA/FSLW from the fmt-4 frame instead of the 040
   fmt-7 SSW@+76/FA@+84 offsets; feed the same `as_fault` resolution path.
   `wb040`'s replay entry is simply never reached (fmt dispatch).
3. **`userspace060` variant** — user-fault signal decode reads fmt-4 offsets.
4. `stkclear`/`stkrestore` (ttrap): confirm fmt-4 frames are converted/rebuilt
   correctly on signal delivery (same class of check the 040 port already did
   for fmt 7).

### 3.2 PTEST replacement  *(small)*

The 060 dropped `PTEST` and `MMUSR` (it has only `PLPA`, which yields a physical
address but not protection bits). Our `ptest040.s` is the **only** consumer —
the definitive census of built `unix-040` found exactly one `ptestr` (0xd9106)
and one `movec %mmusr` (0xd9108) in executable code.

Replacement: a ~40-instruction **software walk of the live kptr040 tree**
(URP → root → pointer → page descriptor), translating the descriptor bits to
the same 030-style PSR result the wrapper already fabricates. Precedent exists:
`segu_ubptbl040.s` already walks the same tree in `segu_get`. Option: use the
software walk on *both* CPUs and delete the 040 `ptestr` — one code path,
negligible speed cost (ptest is only on the fault path).

### 3.3 Unimplemented integer instructions  *(tiny)*

060 removed: `MOVEP`, 64-bit `MUL/DIV` forms, `CAS2`, misaligned `CAS`,
`CHK2/CMP2` → they trap to vector 61 (Unimplemented Integer).

Census of the full vanilla disassembly, with the 64-bit flag decoded from the
extension word (bit 10) and data/table false positives eliminated:

* **64-bit `muls.l`: 3 sites, all inside the `lmul` helper**, called from
  exactly 2 places (`hrt_alarm`, `hrt_newres` — high-res timer math, via
  `.rela.text`). 64-bit `div`: **zero**.
* All apparent `movep`/`cas2`/`chk2` hits are **misdecoded switch-offset tables
  and literal pools** (verified: e.g. the `qlsrvioc` "movep" run sits directly
  after `jmp %pc@(...,%d2:w)`; the `cas2` is inside `tabf9`). Neither the CDS
  cc nor gcc ever emits these; real count in executed code: **0**.

Fix: override `lmul` with a shift/add 32×32→64 routine (portable, runs on both
CPUs). **No 060SP integer package needed in the kernel.** Userland binaries
could in principle contain 64-bit mul/div too — if one ever traps, vector 61
gets a minimal emulation stub then (defer until observed).

### 3.4 CPU detection + identity  *(small; answers the practical questions, §5)*

No `cputype` global exists in the kernel (checked). Add one:

* **Loader-poke (recommended):** `unix_boot` already resolves every kernel
  symbol during relocation (rel.c) and already reads AttnFlags — after
  relocation it writes the CPU type into a new kernel global `cputype`
  (e.g. 40/60). Zero kernel-side probing code.
* Alternative: kernel self-probe via `movec %pcr` (0x808; exists only on the
  060, traps as illegal on the 040) with a temporary vector catch — more code,
  only useful if we ever boot without our loader. PCR also yields the 060
  revision ID (upper bits `0x0430xx`) and holds the superscalar-enable (ESS)
  and FPU-disable bits; we leave ESS=0 (reset default) during bring-up.

Consumers:
* `inituname040.s`: pick the machine-tag prefix from `cputype` → `uname -m`
  and the boot banner show ` 68060-YYMMDD-NN` automatically. (Banner already
  verified working for the 040 tag.)
* A userland **`cpuinfo`** tool: reads `cputype` (plus e.g. PCR revision,
  CACR state) via `/dev/kmem`, exactly the lszorro bootinfo pattern. Trivial.

### 3.5 Caches and branch cache  *(bring-up: nothing; later: small)*

Stock per-vector `mov.l sup_cacr,%cacr` writes 030-format values whose bits are
no-ops on 040/060 enables → caches stay **off** on the 060 just as they do on
the real-HW 040 today (CACR 0x800 observation). Safe and consistent.

When the (already-deferred, CPU-common) "caches on" phase happens, the 060 adds:
`EBC` (enable branch cache) + `CABC` (clear branch cache) on context switch /
mapping changes, and the store buffer (`ESB`) which changes write ordering for
I/O — keep both off until drivers are audited. PTE/TTR cache-mode encodings are
040-identical.

### 3.6 FPU  *(deferred — shared with the 040 FPSP phase)*

Unchanged conclusion from the 040 plan: `fpu_present` is a runtime flag
(17 consumer sites), so FPU-disabled bring-up works on the 060 exactly as on
the 040 today. Full FP support needs the Motorola **060SP** (freely
distributable; Linux `arch/m68k/ifpsp060/` is a ready-made wrapper) on top of
the same FSAVE/FRESTORE frame-size work the 040 FPSP needs. One combined
"FPU phase" covers both CPUs; not on the 060 critical path.

---

## 4. What the emulator can and cannot test

* **Amiberry/WinUAE emulate the 68060** (CPU setting 68060), including the
  fmt-4 access-error frame — the whole §3.1 path is emulator-testable.
* **Caveat (the "fs-uae masks it" class):** UAE cores in less-compatible modes
  may *execute* 060-unimplemented instructions instead of trapping them —
  which would hide the `lmul`/`ptest` issues. For 060 testing, enable the
  more-compatible/cycle-exact CPU mode and verify early with a deliberate
  64-bit `muls.l` probe that vector 61 actually fires.
* Real hardware target: an A3000/A4000 060 accelerator (CyberStorm MK-II/III
  060 class). Loader-side support (AttnFlags AFB_68060) already works. No such
  board is on hand today → emulator-first, exactly like the 040 bring-up.

---

## 5. Answers to the two practical questions

**Q1: Can 040 and 060 support live in the same kernel build?**
**Yes — recommended.** The divergence points dispatch naturally at runtime:

* Access errors: the trap handler *already* dispatches on the frame-format
  nibble. The fmt-7 path (wb040) and a new fmt-4 path coexist in one binary;
  each CPU only ever generates its own format. No flag checks needed.
* `ptest`: either branch on `cputype`, or (simpler) use the software table walk
  on both CPUs and retire the 040 `ptestr` entirely.
* `lmul`: the portable rewrite runs on both.
* Everything else (MMU init, HAT, VM, drivers) is bit-identical.

So the deliverable is one `unix-040` that grows 060 legs — a "unix-m68k04060"
rather than a forked `unix-060`. Forking would double every future relink and
regression test for no benefit.

**Q2: Can the CPU be detected at runtime / shown at boot / queried by a tool?**
**Yes, all three, cheaply** (§3.4): loader pokes `cputype` after relocation →
banner + `uname -m` show `68040-...` or `68060-...` automatically via the
existing inituname tag → a small `cpuinfo` /dev/kmem tool (lszorro pattern)
prints CPU, revision (060 PCR), MMU/cache state on demand.

---

## 6. Phased plan + effort estimate

Prereq observation: the 040 port took months because it included Model B, HAT,
write-backs, loader and debug-infra work. **All of that is sunk cost the 060
inherits for free.** The estimates below assume the current session cadence.

| Phase | Content | Estimate | Exit criterion |
|-------|---------|----------|----------------|
| **060-A** | this pre-study | done | this document |
| **060-B** | bootable 060 test build, FPU off: `framesz[4]=16`, `getfault060` fmt-4 decode, `userspace060` signal decode, `ptest` software walk, `lmul` rewrite, `cputype` loader-poke + banner tag | **~3–6 sessions** | interactive login on emulated 060 (Amiberry, compatible CPU mode), `uname -m` says 68060 |
| **060-C** | dual-CPU consolidation: same binary boot-verified on both 040 and 060 emulator configs; `cpuinfo` userland tool | ~1–2 sessions | one kernel, two CPUs, both regression-boot |
| **060-D** | caches on (CPU-common phase) + 060 branch cache/store buffer rules | later, shared with 040 | — |
| **060-E** | FPU: 040 FPSP + 060SP (one combined phase) | later, largest | user FP programs run |
| **060-F** | real 060 hardware | when a board exists | login on metal |

Test builds land **early**: the Phase 060-B kernel is precisely the "test build
somewhere in the future" wished for — it is emulator-bootable the moment §3.1
compiles, since everything else already works.

Biggest risks, in order:
1. **Emulator fidelity** for fmt-4/vector-61 behavior (mitigate: probe test
   first, compatible mode; the 040 experience says treat emulator leniency as
   the primary trap).
2. Undiscovered fmt-4 corner in signal delivery (`stkclear`/`stkrestore`) —
   bounded, same class as already-solved 040 work.
3. Userland 64-bit mul/div traps (defer; add vector-61 mini-stub only if seen).

---

## Appendix — census evidence (2026-07-09)

```
Built kernel (build/unix-040) 060-illegal executable code — complete list:
  d9106: f568        ptestr %a0@        (our ptest override)
  d9108: 4e7a 0805   movec %mmusr,%d0   (same function)
  (pmove @0xfd6/0xfde = dead stock-pstart bytes; symbol points to override)

Vanilla kernel, 060-unimplemented integer census:
  64-bit muls.l : 3 sites, all in lmul; callers hrt_alarm@0x1aa20, hrt_newres@0x1b8d6
  64-bit div    : 0
  movep/cas2/chk2/cmp2 : 0 real (all hits = switch tables / literal pools;
                         e.g. qlsrvioc hits follow jmp %pc@(...,%d2:w))

framesz @ .data+0x72ac (identical vanilla and built):
  fmt:   0  1  2  3  4  5  6  7  8  9  a  b
  bytes: 8  8 12  0  0  0  0 60  0 20 32 92    -> patch fmt4: 0 -> 16

fpu_present consumers: 17 (runtime-optional FPU confirmed)
cputype-style global: none exists -> add one (loader-poke)
Loader: unix_boot.c:265-277 already prints AttnFlags 040/060 bits, shared movec path
```

---

## 7. Phase 060-B implementation (2026-07-10, this branch)

All six §6/060-B work items implemented overnight; every kernel remains a **single
dual-CPU binary** (unchanged 040 behavior, runtime 060 dispatch). Statically
validated; NOT yet booted.

| Item | Where | Mechanism |
|------|-------|-----------|
| fmt-4 fault address | `prototypes/getfault040.s` | new `cmpiw &4` branch: FA at frame+72 (CPU+8) |
| fmt-4 user/kernel classify | `prototypes/userspace040.s` | new branch: FSLW at frame+76, TM = bits 18-16 (same FC encoding) |
| write-back replay | `prototypes/wb040.s` | **no change needed** — replay was already format-7-gated, inert on 060 |
| ptest on 060 | `prototypes/ptest040.s` | `cputype==60` → software URP walk (RI/PI/PGI, 4KB, indirect-desc support), fabricates the same 030-form PSR; 040 path byte-identical. Also fixed a latent bug found in review: `Lpt_np` now clears all of d1 (walk entered it with VA in the high word) |
| lmul (64-bit muls.l traps on 060) | `prototypes/lmul060.s` | portable mulu.w-halves + sign-adjust rewrite, used on BOTH CPUs; algorithm validated vs a muls.l model, 202 500 cases, 0 diffs |
| cputype global | `prototypes/cputype060.s` | `.data long`, default 40 |
| CPU detect | `unix_boot/src/rel.c` `pokesymlong()` + `unix_boot.c` | loader writes 40/60 (AttnFlags AFB_68060) into the kernel image via the ELF symtab, after relocation, before the transit checksum; prints `kernel cputype set to NN` |
| banner / uname | `prototypes/inituname040.s` | `cputype==60` flips the buildid digit in place → ` 68060-YYMMDD-NN` |
| framesz[4] = 16 | `prototypes/patch_framesz060.py` (called from `relink-040.sh`) | signature-checked one-byte patch; inert on 030/040 |

Builds (all `[OK]`, 0 reloc complaints, .data 4-aligned, framesz verified in binary):
`unix-040` = **260710-04**, `unix-040-dbg` = **-05**, `unix-040-quiet` = **-06**.
New loader deployed to `build/unix_boot040` (poke simulated on Linux: symbol found
in .data @file 0xf1a44, value 40).

Static census of the final binary: the only 060-illegal instructions are the
`ptestr`+`movec %mmusr` pair, now behind the `cputype==60` gate; the three 64-bit
`muls.l` remain only in the DEAD stock lmul body (symbol re-bound to the override).

### Boot-test plan (user, next session)

1. **040 regression** (current Amiberry config): boot `unix-040` — expect identical
   behavior to yesterday, banner tag ` 68040-260710-04`, loader prints
   `kernel cputype set to 40`. Note: the portable lmul is now live on the 040 too
   (hrt timer scaling) — watch for anything odd around timers/alarms.
2. **68060 boot**: same disk/config but CPU model = 68060 (Amiberry: keep MMU
   enabled, JIT off, "More compatible" on; FPU = internal/default). Boot
   `unix_boot040 unix-040`. Expect: loader `kernel cputype set to 60` → banner
   `... 68060-260710-04` → login. `uname -m` confirms.
3. If the 060 boot fails: re-run with `unix-040-quiet` (-06) + serial capture; the
   first suspects are FPU probing (try FPU off/soft if the config allows) and
   emulator leniency (Amiberry may execute 060-unimplemented ops instead of
   trapping — then the lmul/ptest paths are NOT actually being exercised).
