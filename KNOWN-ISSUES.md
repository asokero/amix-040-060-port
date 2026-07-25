# Known issues — deferred, with enough context to resume

## ISSUE-1: our rebuilt `unix_boot` causes a 68030 MMU Configuration Error at the kernel's `pstart` (clib2/bebbo build)

**Status:** DEFERRED (2026-06-17). Does NOT block the 68040 line — see "Why deferred".
We continue 040 work using the toolchain split in "Workaround" below.

### Symptom
Booting **our** rebuilt `unix_boot` (`build/unix_boot040`, bebbo amiga-gcc 6.5 +
`-mcrt=clib2`) on a **68030** with *any* kernel (stock `unix`, `unix-piccolo`,
`unix-040-relinktest`) → AmigaOS "Software Failure" guru **`8000 0038`** right
after the loader hands off. Reproduced on real A3000, fs-uae, and WinUAE.
The stock/upstream `unix_boot` (`unix_boot/bin/unix_boot`, original gcc2 build)
boots the same kernels fine on 030.

### What `8000 0038` decodes to
`0x80000038` = `AT_DeadEnd | 56`. AmigaOS CPU-trap alerts use the convention
`0x80000000 | <vector number>` (cross-check: `ACPU_Format = 0x8000000E` = vector
14, from NDK `exec/alerts.h`). **Vector 56 = 68030 MMU Configuration Error** — a
PMMU fault. So the crash is in the **MMU-enable path**, i.e. the kernel's
`pstart` executing its `pmove` sequence (TC/CRP/SRP), NOT in bootinfo or the copy.

Because it surfaces as an AmigaOS guru (not the kernel's own
`PANIC: KERNEL FAULT`), it happens **before** the kernel installs its trap
handlers — i.e. very early, at `pstart`'s MMU enable (≈ kernel offset 0xFD6).

### Unifies with the 68040 observation
Our loader **hands off correctly** — the kernel runs to `pstart` on both CPUs:
- **040:** kernel reaches `pstart`, `pmove` → B-Trap F010 (F-line; pmove is
  illegal on 040). Expected — that's the whole 040 problem (Draft 2 fixes it).
- **030:** kernel reaches `pstart`, `pmove` executes but raises MMU Config Error.
- Draft 1 (MMU-disabled probe) ran with our loader on 040 **deep** into the
  kernel (`vstart`/`mlsetup`/`krnlflt`). So the handoff + kernel image are sound.

### Verified CLEAN (ruled out)
- **bootinfo content** — on-screen dump shows correct boards (e.g. A2065
  `0202:70` @ 0xE90000), correct mem regions, and contiguous kernel offsets
  (tvaddr+tsize=dvaddr, toffset+tsize=doffset).
- **bootinfo struct layout** — bebbo compiles AmigaOS structs at the right
  2-byte ABI: `Node`=14, `ConfigDev`=68, `MemHeader`=32, `ln_Name`@10,
  `cd_Rom`@16 (measured).
- **copyit** — the 030 path is byte-identical in operation to upstream
  (`pmove tc/crp/srp/tt0/tt1`, all gated 040 ops behind AttnFlags btst branches a
  030 never takes); `_copyit` resolves correctly; copyit.o = 188 B (fits the
  512 B `memcpy`), no relocations (position-independent).
- **rel.c relocation logic** — unchanged from upstream; ELF structs are all
  4-byte members → packing-independent; image executes to `pstart` so it is not
  corrupt.

### Leading hypothesis
A subtle **runtime-state difference introduced by the clib2/bebbo rebuild** (vs
the original gcc2 minimal startup) that makes the kernel's 030 `pmove` config-
error. Not a source-logic bug (everything above is verified). Candidate: clib2's
heavier crt0 leaves the CPU/MMU/cache or some register state different at handoff.
Note: our copyit leaves the 030 MMU bit-for-bit as upstream does, yet the kernel's
own `pmove` still faults — so the trigger is non-obvious.

### Cheapest experiment to resume with
Rebuild the loader with a **lighter C runtime** to test the clib2-startup theory:
try `-mcrt=libnix` (or another `-mcrt=` flavor) instead of `-mcrt=clib2` in
`unix_boot/src/Makefile`. If libnix provides `open/read/close/stat` and the
lighter startup boots cleanly on 030 → root cause confirmed as clib2 startup.
If that fails, the fallback is hunk surgery to relocate a 040-aware copyit into
the **upstream** binary (blocked by size: our copyit ~140+ B vs the upstream
104 B slot at 0x148, with `rel.c`'s `_symvaddr` immediately after at 0x1b0 —
can't overwrite in place; would need to relocate + repoint the `memcpy(copyit)`
reference).

### Why deferred (does not block 040)
The kernel image is sound and our loader's handoff works on 040 (proven by Draft 1
reaching `krnlflt`). The 030 MMU Config Error is specific to the 030 `pmove`
path, which the 040 work replaces with `movec` (Draft 2). So:

### Workaround (current toolchain split)
- **030 baseline / regression:** boot with the **upstream** loader
  `unix_boot/bin/unix_boot` (works).
- **040 development (Draft 2):** boot with **our** loader `build/unix_boot040`
  (proven to reach `pstart` and beyond on 040).

---

## ISSUE-2: temporary debug markers / serial spam in the dbg build (cleanup TODO)
**Status:** OPEN (updated 2026-07-04), low priority — cleanup gated on hat_dup (see below).
The instrumented kernel `build/unix-040-dbg` (relink-040-dbg.sh) prints a lot of debug output;
all of it is HARMLESS but noisy.  Notable at the interactive-login stage:
- **`C<pid>:<PC>:<SR>` forever** — `prototypes/sigkill_dbg.s` clock_sampler (every 16th tick,
  cap 1024 ≈ 5.5 min).  `pid=0 PC=0x070D8EC2 SR=0x2000` = proc 0 idling in the kernel (healthy).
- **`W <pid>:<stat>:<wchan>`** — mainmarks.s idle proc-table dump (cap 8/boot).
- **`DBG hardbus XPAGE …`** — the hardbus page-crossing wrapper firing normally (a real fix, but
  the log line is diagnostic).
- Plus `DBG ddopen …`, `DBG hat_* …`, `G…`/`C…` exec markers, sigkill/setregs/as_fault probes.

**Cleanup path:** these live in the *dbg* overlay (mainmarks.s, sigkill_dbg.s, execmark.s,
hatalloc_dbg.s, assegat_dbg.s, ddopen_dbg.s …) layered by relink-040-dbg.sh — the genuine 040
runtime fixes already moved to the BASE build (relink-040.sh).  A clean quiet boot needs the BASE
`unix-040` to be self-sufficient, which is currently blocked by ISSUE-4 (stock-030 hat_dup in the
base).  Once hat_dup is ported into the base, boot `unix-040` directly for a quiet console, or
make a "quiet-dbg" overlay that keeps only the serial `conputc` hook.  ALWAYS read the serial log
with `grep -a` — it contains NUL bytes and plain grep silently matches nothing.

## ISSUE-4: BASE unix-040 still has stock-030 hat_dup (fork not yet safe in the base build)
**Status:** MERGED into master 2026-07-07, AWAITING BOOT TEST (was OPEN since 2026-07-04).
`hat_dup040.s` (branch `040-hat-dup-port`, already boot-verified there including the
fork-without-exec COW subshell test — see memory `amix-040-hat-dup-port`) is now merged into
`prototypes/` and wired into `relink-040.sh` on top of ALL newer master fixes (haltsys/fsck/
hat_unload V2.3/segu_lockfix/quiet040). `build/unix-040` and `build/unix-040-dbg` both now link
the real port at the same address (`hat_dup` is a single strong override in both, confirmed via
`nm` — no re-stubbing). `forkdbg.s`'s old no-op stub is no longer linked into any build.

**Two additional hardening fixes went in alongside the merge**, both from Codex's parallel
`amix-kernel-analysis/vm-map/` audits (see memory `amix-codex-hat-audit-findings`):
1. **HAT_CANWAIT/HAT_NOSTEAL** (`HAT-PTALLOC-AUDIT.md`): `hat_ptalloc`'s root-table-allocation
   call sites (`hat_pteload`'s root+leaf allocations in `hat040.s`, and `hat_dup040`'s root
   allocation) were passing bare `HAT_CANWAIT` (1), which does NOT disable `hat_ptalloc_orig`'s
   steal path on allocation failure — and that path is unported 030-format tree code (8-byte
   descriptors, 21-bit PFNs), active memory corruption if it ever fires under real memory
   pressure. Changed to `HAT_CANWAIT|HAT_NOSTEAL` (3) at all three sites; no test workload so
   far has exercised the failure path, so this has zero effect on current behavior and is a
   pure hardening fix. `hat_dup040`'s leaf allocation already correctly used `HAT_NOSTEAL` (2)
   (mirrors the original 030 give-up-on-failure semantics) and was left unchanged.
2. **hat_unload missing post-clear flush** (`HAT-UNLOAD-COHERENCY-AUDIT.md`): every other 040
   HAT writer (hat_pteload/hat_chgprot/hat_pageunload/resume) ends with `cpusha bc; pflusha`
   before returning; `hat_unload` cleared PTEs but returned with no post-clear cache push, so a
   cleared PTE could sit in copyback cache while the hardware table walker still saw the old
   valid descriptor. Added unconditionally on `hat_unload`'s normal (non-rootnull) exit. This is
   a **plausible new lead for ISSUE-7** below (not on its prior "ruled out" list) — NOT a
   confirmed fix for it, since `hat_unload` is also called from plenty of paths unrelated to
   ISSUE-7's u_procp corruption.

**Not yet done:** none of this has been boot-tested. Related pending 040 ports (unchanged):
hat_chgprot ×6 caller sites (the routine itself is confirmed structurally correct — audited),
hat_exec (exec stack move — still fully unported, and per `HAT-PTFREE-AUDIT.md` its
`hat_ptfree` call passes an old-format table pointer that `hat_ptfree`'s guard cannot
distinguish from a real 040 table), uvirtophys/uvatosde (user SW page-table walkers).
Full batch list: RESUME-HERE.md.

**Also flagged but NOT fixed this session** (deferred, needs more RE + can't be verified
without a boot): `hat_ptfree` frees the physical table page but never retires its `ptdat`
record from `active_pts`/`free_pts`, calls `hat_sdtfree`, or wakes `pt_waiting` — the stale
`active_pts` record can be reused by `hat_ptalloc_orig`'s (already-hardened-against, but not
eliminated for `hat_exec_orig`) steal path. Not an observed bug yet (steal path currently
unreachable from the CANWAIT sites above); full detail in `HAT-PTFREE-AUDIT.md`.

**hat_map phantom-preload — FIXED + boot-tested 2026-07-07 (commit 9b7f00c).** Codex's
`P-MAPPING-MATRIX.md`/`HAT-MAP-AUDIT.md` found retained `hat_map` writes legacy `pfn<<11`
phantom PTEs into `pp->p_mapping` chains (mixing with live `pfn<<12` entries → breaks the
one-format invariant). Fixed with a 1-byte preload-disable (0xb58d2 beqw→braw); investigation
+ why-Option-A in `prototypes/hat-map-040-fix-plan.md`. **User boot-tested (3 boots): login/
fsck/basic ops all fine, no regression** — the demand-fault path (which now does 100% of the
mapping work) is exercised constantly, so this is well-covered. `p_mapping` chains are now
single-format from every producer.

**hat_pagesync — LATENT ref/mod bug, deferred (Codex `REFMOD-PAGEOUT-CONTRACT.md` +
`HAT-PAGESYNC-AUDIT.md`, 2026-07-07).** hat_pagesync (0xb4be8) is the periodic ref/mod
sampler used by pageout `checkpage`, `fsflush`, `pvn_getdirty`, `pvn_done`. Confirmed via
disasm: it copies+clears PTE U/M bits and calls `flushmmu` (global pflusha) but has **no
`cpusha bc`** — so on 040 a cleared PTE U/M bit could linger in copyback cache while the
table walker reloads stale state. **HOWEVER: this is LATENT, not a current bug — the 040
DATA CACHE IS CURRENTLY OFF.** Verified: the live boot path is `_start → config → pstart040`
(pstart @0xd71a8 = the appended override); pstart040 never writes a nonzero CACR, and the
only nonzero-CACR-loading code (0x1038–0x1294) is the DEAD original pstart (weakened,
unreferenced). Matches the prior real-HW observation (CACR 0x800 = caches off,
`amix-040-phase4-hw-analysis`). So hat_pagesync's missing cpusha only bites once the D-cache
is enabled (a future performance milestone), and is NOT an ISSUE-7 lead (ISSUE-7 reproduces
with caches off). The mixed-format half of the hat_pagesync concern is already resolved by
the hat_map fix above (chains are single-format now). **When implemented: a `hat_pagesync040`
that walks the chain, harvests+clears live-040 U/M bits, and ends with `cpusha bc; pflusha` —
delegate the coding to Fable** (Codex has a design sketch in `REFMOD-PAGEOUT-CONTRACT.md`
step "Practical next step"). Low urgency until D-cache work begins.

## ISSUE-5: `haltsys` (reboot/halt path) ran unguarded 030 `pmove` — KERNEL PANIC on `reboot`
**Status: RESOLVED (2026-07-05, fix v3, boot-confirmed).** Final fix = `haltsys040.s`
makes the reboot/halt MMU-disable UNCONDITIONALLY use the 040 `movec`+`pflusha` path
(commit ded2e58), after v1 (guarded `haltsys`) and v2 (`rtnfirm` override, commit 23a3532)
turned out necessary but insufficient. Reboot now completes: a dirty-disk boot ran
`fsck` → rebooted → reached login cleanly.

**IMPORTANT CORRECTION — `pc=0x4000001E` was MISATTRIBUTED to this issue.** The recurring
`PANIC: KERNEL FAULT pc=0x4000001E vector=0x4` is a SEPARATE, still-open bug (an IPL-3
wild jump into the u-area during the ctx-switch/interrupt path — see **ISSUE-7** below),
NOT the reboot pmove. The three fixes below (v1/v2/v3) were all REAL reboot-path bugs, but
none of them was the 0x4000001E crash. v3 fixed the actual reboot symptom (an F-line
trap, vector 0xB, at the 030 `pmove` in the shutdown MMU-disable — see the v3 detail).

**FIX v3 (2026-07-05, the real fix):** with v1+v2 in place, `reboot` still panicked — but
now with an F-line trap (vector 0xB) at `pmove %a0@,%tc` inside our OWN haltsys040 030
branch (`Lhs_mmu030`). Cause: the AttnFlags CPU-detection guard (`moveal 4,%a1` = AmigaOS
SysBase, `btst #3/#7,%a1@(0x129)`) misfires at Unix reboot time — under the live Unix MMU,
low-mem addr 4 / SysBase+0x129 no longer yield the AmigaOS AttnFlags, so both btsts read 0
and control fell through to the illegal 030 `pmove`. (copyit.s uses the same guard safely
only because it runs PRE-MMU during loader handoff.) Since this is an 040/060-ONLY binary,
v3 removes the guard entirely and always takes the 040 path. Verified: 0 `pmove` in the
haltsys/rtnfirm region of both binaries; `Lhs_nomsg` falls straight into `movec` tc/itt0/
itt1/dtt0/dtt1 + `pflusha`.

---
(historical detail from the v1→v2 investigation follows)

**FIX v1 was insufficient (2026-07-05):** the `haltsys` override alone NEVER EXECUTED on the
reboot path. Disassembly of `mdboot` (0x5637a) proves it calls `haltsys(0)` ONLY for fcn==0
(halt); for fcn>=1 — i.e. every actual `reboot` — it calls **`rtnfirm`** (0x18eb0, GLOBAL T)
instead. `rtnfirm` is a second entry point 8 bytes BEFORE `haltsys` in the same object: it does
`movel #1,%sp@(4)` (forces msg=1) and FALLS THROUGH into the `haltsys` body → `nomsg` → the old
MMU-disable block. In the patched binary that block's three 030 `pmove`s are already NOP'd by the
byte-patch scripts, so the old `rtnfirm` path left the MMU ENABLED when it jumped to the ROM
reboot vector — the ROM then ran/trampled memory with kernel translation still live → recursive
trap cascade → the observed `PANIC: KERNEL FAULT pc=0x4000001E vector=0x4`. FIX v2: haltsys040.s
now also defines a global `rtnfirm` immediately before its `haltsys:` (byte-identical layout,
`2f7c 0000 0001 0004`, falls through), and `relink-040.sh` adds `--weaken-symbol rtnfirm`.
`rtnfirm` has 5 caller reloc sites (0xd60, 0x3e6b4, 0x3e886, 0x3e898, 0x563ca=mdboot) — the
symbol override fixes all of them at once. Verified: both builds clean, `check_relink_relocs.py`
0 complaints each, single strong `T rtnfirm` at 0xd89bc / `T haltsys` at 0xd89c4 in both
binaries, new rtnfirm encodes `2f7c 0000 0001 0004` and falls through into the AttnFlags-guarded
haltsys, old cluster at 0x18eb0 no longer owns the symbol (remains as unreachable bytes).

**FIX v1 (superseded, retained below for the RE details):** `prototypes/haltsys040.s` reimplements the
whole `haltsys` function (it's the only GLOBAL symbol in its cluster) with an AttnFlags-guarded
MMU disable mirroring `copyit.s`'s proven pattern: 68030 keeps the verbatim original `pmove
tc/crp/srp`; 68040/68060 use `movec` (tc/itt0/itt1/dtt0/dtt1) + `pflusha` instead. `haltmsg`/
`nullrp`/`zero` are DUPLICATED locally (byte-identical, verified via `objdump -s` against the
original) rather than globalizing three more local symbols — lower relink risk for such trivial
content. `boot_arg0` is GLOBAL `D` already (0x4780) so it's referenced directly, no globalize
needed. Wired into `relink-040.sh` (assemble + `--weaken-symbol haltsys` + link + nm-report);
`relink-040-dbg.sh` needs no changes since it inherits `haltsys` as a strong def from
`build/unix-040` (same pattern as `hat_chgprot040.o`). Verified: standalone assemble clean; both
`relink-040.sh` and `relink-040-dbg.sh` build clean; `check_relink_relocs.py` reports 0 complaints
for both; `nm` shows a single strong `T haltsys` at the same address (0xd89bc) in both binaries;
disassembly of the final linked `haltsys` in both binaries confirms the 040/060 branch skips the
`Lhs_mmu030` block entirely — no `pmove` reachable on the 68040 path (the 030 `pmove` bytes remain
as correct dead code for an eventual 030 boot of the same binary). NOT boot-tested on fs-uae/HW —
that remains for a human.
**Symptom:** running `reboot` on `unix-040`/`unix-040-dbg` (fs-uae, boot-verified 2026-07-04/05)
reliably panics: native kernel strings (confirmed in `vanilla/stand/unix`'s own string table, not
our instrumentation) `"kstack 0x%x!"` print a recursive-trap unwind, ending in
`PANIC: KERNEL FAULT psw=0x2311, pc=0x4000001E, fmt=0x0, vector=0x4 (Illegal Instruction)`. Happens
either right after issuing `reboot` or, once, at the next boot's login prompt (same signature).
Serial-log correlation (2026-07-05 capture): system goes fully IDLE (proc 0, healthy repeating
`C00000000:070D96FA:00002000` idle-PC samples, hundreds of them — NOT a spin on a changing PC) for
a long stretch before the panic, and the last `hat_dup040 ENTER` markers logged are far earlier
(getty/login forks) — this is NOT a fork-in-flight crash, it's unrelated to the `hat_dup040` port
on branch `040-hat-dup-port`. `getdents LOOP` markers (pid 172, likely the shutdown sequence
scanning `/proc` to signal remaining processes) precede the idle stretch — consistent with a normal
`reboot`/`uadmin` shutdown sequence, not a hang.

**Root cause (RE'd from `vanilla/stand/unix`, 2026-07-05):** `uadmin` (0x467d6) → `mdboot` (0x5637a)
→ `haltsys` (0x18eb8, **GLOBAL T**) → falls straight into the local label `nomsg` (0x18ece, always
reached regardless of the message argument):
```
18ece: movew  #9984,%sr        ; interrupts off
18ed2: lea    zero,%a0
18ed8: pmove  %a0@,%tc         ; *** 68030-ONLY, illegal on 68040 (vector 4) ***
18edc: lea    nullrp,%a0
18ee2: pmove  %a0@,%crp        ; *** same ***
18ee6: pmove  %a0@,%srp        ; *** same ***
18eea: moveq  #0,%d0
18eec: movec  %d0,%cacr        ; already CPU-agnostic, no change needed
18ef0: bset   #7,0xde0002      ; hardware bit, CPU-agnostic, no change needed
18ef8: tstl   %d2
18efa: bnel   reboot           ; -> new_funky_reboot (reset+jmp) or a ROM ktrap jmp
```
This is the **exact same bug class** as the very first issue this project ever fixed
(`prototypes/copyit.s`'s original unguarded `pmove tc/crp/srp` in the Amiga-side MMU-disable code,
see that file's header comment) — just a third, never-audited site: the kernel's own shutdown path.
`copyit.s` already has a proven, boot-verified fix for the identical instructions (AttnFlags bit
`AFB_68040` check, `movec` substitutes for `tc`/`itt0`/`itt1`/`dtt0`/`dtt1`, `pflusha` to flush the
ATC — `crp`/`srp` have no 040 equivalent load needed since clearing `tc`'s enable bit alone turns
off translation). `haltsys` is the only GLOBAL symbol in this cluster (`nomsg`/`halt`/`reboot`/
`new_funky_reboot` are all local `t` symbols in the same object) — so the fix is a `--weaken-symbol
haltsys` override that transcribes the WHOLE function (conditional `haltmsg` printf, AttnFlags-
guarded MMU-disable, the hardware `bset`, then the halt-spin-loop or reboot-jump dispatch depending
on the original message-arg), following the identical AttnFlags/movec pattern `copyit.s` already
proved. Low complexity, high confidence — unlike the HAT layer, this is ~20 instructions with a
direct working reference to crib from.

**Plan:** branch `040-haltsys-reboot-fix` (off master, independent of `040-hat-dup-port` — this bug
predates and is unrelated to the hat_dup work). Implementation delegated to a Fable subagent per
this project's Sonnet-plans/Fable-executes workflow.

## ISSUE-3: hat_unload reverse-map findmap is a bounded skip (verify later)
**Status:** OPEN (2026-06-22), defensive — works, but confirm correctness under memory
pressure.  hat_unload's `Lhl_findmap` walks pages[pfn]'s reverse-map list (head @(32),
next @ pte+256) to unlink the pte; the 040 port BOUNDS it (256 iters) and SKIPS the
unlink if the pte isn't found.  This is correct for kvsegmap pages mapped by segmap setup
(no reverse-map entry — verified by a sane *pte).  BUT if it ever skips a pte that SHOULD
be in the list (a real bug in hat_pteload's Lwleaf insert, or a corrupted list), it would
silently leave a stale reverse-map entry → trouble during page reclamation (which needs
the reverse-map, and only kicks in under memory pressure — not yet exercised at boot).
If page-reclaim bugs appear later, re-audit hat_pteload's reverse-map insert + this skip.

## ISSUE-6: `fsck` on a dirty UFS panicked `segvn_softunlock` (raw-device physio softlock)
**Status: RESOLVED (2026-07-05, two commits).** Booting a corrupt/dirty filesystem ran
boot-`fsck` (`/sbin/fsck -F ufs -y /dev/rdsk/…`), which raw-reads the device into an anon
buffer; the kernel F_SOFTLOCKs the buffer pages for the physio transfer and `segvn_softunlock`
panicked. Root-caused with the `segvn_softunlock_dbg` diagnostic wrapper (dbg build) which
replicated the per-page page_hash find and dumped the failing page's state. TWO distinct
bugs, both leftover 2KB/4KB Model-B conversion errors in the VM layer:

1. **`swap_xlate`/`swap_anon` used a 2KB pagesize shift** (commit faa1ace). They translate
   anon-slot-index ↔ swap-vnode byte-offset with `<<11`/`>>11` (×2048) — byte-identical to
   the 2KB vanilla, missed in the Model-B pass even though the anon/swap ACCOUNTING was
   already 4KB. Result: anon `p_offset` came out 2KB-aligned (e.g. 0x1F800 = 63×2048), not
   4KB-aligned — a swap-slot-overlap corruption and mishandled by 4KB-aligning code. Fix:
   `moveq #11→#12` at both sites (patch_modelb.py). This was real but NOT the panic trigger.

2. **`segvn_softunlock`'s inlined PAGE_HASHFUNC was patched to `>>12` while the other 7
   inlined hash sites stayed `>>11`** (commit 61dd64e — the actual fix). patch_modelb.py had
   a tuple at 0xabdae mislabeled "page idx >>11"; that shift is the `off>>PGSHIFT` term of
   the hash, not a page index. `page_hashin` (the ENTER side), `page_find`, `page_exists`,
   `page_hashout`, `xpage_find`, `findpage`, `segmap_unlock` all kept stock `>>11`. A hash
   only needs CONSISTENCY, so patching one site made softunlock search a different bucket
   than the page was filed into → `pp==NULL` → panic. Proven by the dbg dump: the "missing"
   page was alive, `keepcnt=1`, correct (vp,off), `p_hash=0` (alone in its bucket). Only
   fsck hit it because the FAULT path finds anon pages via the `an_page` hint (no hash walk);
   only multi-page raw-physio softunlock walks the hash with anon pages. Fix: REMOVE the
   0xabdae tuple (revert to stock `>>11`). **Lesson: before patching a `>>11` near page code,
   determine if it's a PAGE INDEX (→`>>12`) or an inlined PAGE_HASHFUNC term (stays `>>11`
   for consistency across all 8 sites — enumerate them via the `page_hashsz` relocs).**

Boot-confirmed: dirty FS now runs fsck to completion and the next boot reaches login.
Diagnostic wrappers (`segvn_softunlock_dbg`, `kmem_validate`, `ktrap_latch`) remain wired
into `relink-040-dbg.sh` only (base build unaffected); useful for ISSUE-7.

## ISSUE-7: u-area corruption at login-after-reboot — `u_procp=0` → wild jump / bus-error (✅ RESOLVED 2026-07-09)
**Status: RESOLVED (2026-07-09), commit `51cdbc7`. Verified: fs-uae boots to login, runs
`ls -alR`, survives 7 reboot cycles with ZERO panics and ZERO recursion signatures
(`kstack`/`KSTKCHAIN`/`PREEMPT1 uprocp=0` all absent), clean `haltsys`.**

**ROOT CAUSE (finally): `wb040` write-back replay could not handle an UNALIGNED PAGE-CROSSING
store.** The 040 access-error handler re-issues the faulted store from the write-back frame with
one wide `moves`. Measured via the new KSTKWB probe (commit `24a54cf`): a supervisor long store
of "xres" to `0x40736FFE` (offset 0xFFE) crosses into the next page; the 040 reported FA = the
NEAR address, `as_fault` resolved only that (already-present) page, and the single wide `moves`
re-crossed the boundary and re-faulted **forever**. The infinite kernel-fault recursion ate the
u-area kernel stack down over the u struct front, zeroing `u_procp` → the `pc=0x4000001E` /
`rcopyout` bus-error symptoms below. **Fix: replay BYTE-WISE** (MSB-first `rol.l #8` +
`moves.b (a3)+` for `size` bytes) so each byte is an independent access that faults with its own
correct FA and converges. This is why every HAT hypothesis in this file missed — the bug was in
write-back replay, never in HAT. (First cut also had a 68k CC-clobber: `movel %d2,%d1` between
`andil` and `beqw Lwb_long` made the long-branch test data-zero not size-long → corrupt icode →
init exec failed; fixed by reordering.) The adjacent bugs found while hunting (below) were all
real and stay fixed. Historical characterization retained below for reference.

<details><summary>Historical (pre-resolution) characterization — OPEN status, kept for reference</summary>

### Symptom
`PANIC: KERNEL FAULT pc=0x4000001E vector=0x4 (Illegal Instruction)` OR
`pc=0x7096226 (rcopyout+0x28) fmt=0x7 vector=0x2 (Bus Error)`, preceded by a recursive
`kstack 0x40000Cxx!` unwind. Both are the SAME bug: a process's u-area (mapped at the
fixed VA 0x40000000 and via its kvsegu `p_segu` window) has **`u_procp` (u+0x730) == 0**
while the saved-context area `u_rsav` (u+0x318) is live. `copyout` reads `p_sysid` off the
null `u_procp` → wrong RFS path → `rcopyout` deref → bus error; OR preempt's
`jsr ([44,p_clfuncs])` with a null u_procp jumps wild → 0x4000001E. The recursive cascade
is because the kernel stack lives IN the corrupt u-area, so every nested trap re-faults.

### Reproduction (DETERMINISTIC — keep a contaminated image for testing)
Pristine disk image A boots + logs in + reboots cleanly. Take a copy B, boot it once with
the 040 kernel and reboot → the NEXT boot of B panics at the login prompt, every time.
Restore A over B → clean again. NO fsck needed; ordinary boot+shutdown disk writes change
the login-time process/I-O pattern enough to hit it. Fixed-ish values every crash:
`u+0x318=0x4073X000` (kvsegmap addr), `u+0x31C=0x40000378` (= &u+0x378, a u_qsav-style
self-pointer → the crashing proc is in a sleep/longjmp context), `p_segu`≈0x48466000/
0x48468000 (kvsegu slot ~19/20), curproc varies (0x4011AC00/0x40248400/0x40256400).

### RULED OUT by runtime measurement (do NOT re-chase these)
1. **kmem free-list corruption** — `kmem_validate` (9-bin integrity check on every
   kmem_alloc) NEVER fired across a full run.
2. **Interrupt dispatch tables** — `ktrap_latch` dumped `vbinttab`/`int2_tbl` INTACT.
3. **Fixed-VA remap reads wrong page** — `PREEMPT5` reads u_procp via BOTH the fixed VA
   AND the stable p_segu window; both == 0, `wctx==u318`, `apt==exp` (uarea_pt leaf ==
   kptr040-walked p_segu leaf). Mapping is CORRECT; the page genuinely has u_procp=0.
4. **u_procp 0 at trap entry** — the `UTRAP` probe (reads u_procp via p_segu window at
   every user-trap ENTRY) NEVER fired → u_procp is FINE at entry, zeroed mid-trap.
5. **Swap daemon (swapinub/swapoutub)** — `SWAPOUTUB`/`SWAPINUB` markers NEVER fired.
6. **segu_softunload skipping VOP_PUTPAGE** (Codex's strong theory: it finds pages via
   p_ubptbl, which is 0 on 040, so it skips the swap-out → softload restores stale) —
   the `SOFTUNLOAD` marker NEVER fired; segu_softunload is not even called on this path.
7. **segu slot free-list double-alloc** — Codex verified usd_free pop/push (0xaa47c/
   0xaa7b8) is a clean LIFO; a slot only reaches a new proc after a real segu_release.

### 8. hat_unload missing post-clear cpusha bc/pflusha (2026-07-07, RULED OUT — fix landed, bug still reproduces)
Codex's `HAT-UNLOAD-COHERENCY-AUDIT.md` found that `hat_unload`'s normal exit was missing a
post-clear `cpusha bc; pflusha` — every OTHER 040 HAT writer (hat_pteload/hat_chgprot/
hat_pageunload/resume) ends with that pair, but hat_unload clears PTEs and returns with only
a *pre*-clear pflusha. Fix applied in `hat040.s` (unconditional cpusha bc/pflusha on the
non-rootnull exit) alongside the ISSUE-4 hat_dup040 merge (commit 302b588). **User boot-tested
2026-07-07: bug reproduces identically** — same PREEMPT1-5 signature (`uprocp=0
curproc=4011AC00 psegu=48466000`, `u318=40736000` matching the established `0x4073X000`
pattern, `wproc=0` via the PERMANENT p_segu window confirming the page genuinely lacks
u_procp, not a mapping bug), same kstack recursion cascade, same terminal
`PANIC pc=0x7096226 (rcopyout+0x28) fmt=0x7 vector=0x2`. The fix is harmless (a coherency
correctness improvement, keep it) but is CONFIRMED NOT the ISSUE-7 root cause. Do not re-chase
this mechanism.

### FIXED ALONG THE WAY (real adjacent bugs found while hunting ISSUE-7, all on master)
- ISSUE-5 reboot pmove (haltsys/rtnfirm v1/v2/v3 → unconditional 040 movec).
- ISSUE-6 fsck (swap_xlate/swap_anon 2KB→4KB + revert mislabeled 0xabdae hash patch).
- hat_unload040 V2.3 (guard rejected kernel-image static kptr040 tables → hat_unload was a
  silent no-op for ALL kernel VAs; lower bound now `_start>>12`).
- segu_get SEGU_LOCKED (Model-B loop-bound patch `moveq #3→#1` also dropped the flag stored
  from the same reg d5 → segu_release passed hat_unload flags=0 → keepcnt never released;
  restored via the `segu_lockfix` wrapper).

### CURRENT BEST THEORY (unproven)
The u-area page mapped at `p_segu` is a FRESH ZERO page (all zero except the save-area at
+0x318, which a later `save()` wrote), i.e. the proc's real u-area was replaced/reused by
a NON-swap mechanism. u_procp is correct at creation (setuctxt @0x41954 writes
`childproc → p_segu+0x730`, then kmem_alloc(KM_SLEEP) @0x41978 — a sleep window) and at
trap entry, but 0 by the trap-return preempt (`u_trap_orig+0x104`). Codex's remaining
angle: a slot is `segu_release`d before the old u-area mapping/page is truly detached
(040 HAT/keepcnt path), so the next `segu_get` hands the same slot+a fresh page to a new
proc while the old page-state still lives → double-use. But the narrowed `LIVEABORT`
tripwire (fires only on page_abort of a keepcnt!=0 page) has been SILENT in recent runs,
which argues AGAINST "freed while held". So the exact zeroing mechanism is still open.

### DIAGNOSTIC INFRASTRUCTURE IN PLACE (dbg build only, relink-040-dbg.sh)
`ktrap_latch` (first-fault frame dump), `preempt_dbg` (u_procp check + PREEMPT1-5 dump +
a TOURNIQUET that re-runs preempt via the curproc global so the machine survives),
`kmem_validate`, `segvn_softunlock_dbg`, `segu_swap_dbg` (swapinub/swapoutub/segu_softunload
markers), `hatalloc_dbg` LIVEABORT (narrowed to keepcnt!=0), and the `UTRAP` u_procp-at-
entry probe in execmark.s. Serial capture via serdbg (SERIAL-DEBUG.md).

### 9. setuctxt kmem_alloc(KM_SLEEP) window (2026-07-07, RULED OUT — probe never fired)
Codex timing hypothesis #1 (`prototypes/setuctxt_dbg.s`, commit `c0b78c5`): does `u_procp`
survive `setuctxt`'s own internal `kmem_alloc(KM_SLEEP)` loop? **User boot-tested 2026-07-07:
`grep -a "DBG setuctxt POST-RETURN" /tmp/amix-boot.log` printed nothing** — the wrapper is
confirmed correctly wired (verified via disassembly pre-test: `setuctxt` was file-local,
needed `--globalize-symbol` before `--weaken-symbol`, `procdup`'s call now binds to the
wrapper) and it simply never observed a mismatch. **This means the corruption does NOT
happen inside setuctxt's own execution window.** Bug still reproduces, this time terminating
in a WORSE cascade than before: `PANIC: KERNEL FAULT psw=0x2100, pc=0x0, fmt=0x0, vector=0x0
(Reset: Stack Pointer)` (previously `pc=0x7096226 rcopyout+0x28 vector=0x2 Bus Error`) —
consistent with "recursive kstack unwind, exact terminal PC/vector varies" already documented,
not a new mechanism. Also newly observed this run: `curproc=40258400` (a 4th distinct value
alongside `4011AC00`/`40248400`/`40256400`), `caller=0` in PREEMPT1 (vs. a real return address
before), and an `as_fault STREAM pid=162 ...` sampler line moments before the cascade — the
STREAM sampler is a periodic (every-128th-call) `as_fault` address sampler unrelated to any
specific proc, its proximity to the crash is very likely coincidental timing, not causal;
do not chase it without independent corroboration.

**Narrowing takeaway (2026-07-07): both a proc-creation-time hypothesis (setuctxt) and a
coherency-omission hypothesis (hat_unload cpusha) are now ruled out. The corruption mechanism
is neither of those.** Given `u+0x318` (survives) is written by `save()` on ordinary context
switch-out, the victim proc most likely reaches this state as an ALREADY-RUNNING (not
freshly-created) proc — so the next probe should watch procs across repeated dispatches, not
proc creation.

### PREEMPT6 result (2026-07-07, DONE — boot-tested): isolated to one proc
`prototypes/preempt_dbg.s`'s multi-proc watermark scan (commit `959194f`) fired on the
2026-07-07 crash: `scanned=16 zerocount=1 pid1=9F`. **Confirms the corruption is ISOLATED to
exactly one proc**, not systemic — of 16 live procs checked, only 1 (pid `0x9F`=159) had
`u_procp==0`. This supports a per-allocation/per-proc race (e.g. in HAT table or page
lifecycle) over a shared/global structure being clobbered, and rules out the "whole class of
procs corrupted at once" alternative. (Separately, an `as_fault STREAM` sampler line showed
`pid=162` moments before the cascade — a different, close-but-not-matching pid; that sampler
fires on an unrelated periodic schedule and its proximity to the crash is very likely
coincidental, not causal — do not chase it without independent corroboration.)

### 10. hat_sdtfree Model-B pfn fix (2026-07-07, RULED OUT for ISSUE-7 — fix stays, real bug, just not this one)
Codex's `amix-kernel-analysis/vm-map/HAT-GROWSDT-AUDIT.md` found (independently verified via disassembly)
that `hat_sdtalloc`'s 3 Model-B pfn-shift patches (`<<11`→`<<12`) were not mirrored on the
free side: `hat_sdtfree`'s 2 sites (`table>>11`→ pfn, to find the backing `page_t`) were still
2KB-shifted, computing a pfn ~2x too large. If that wrong pfn lands in a live page's range —
plausible given typical memory sizes — `hat_sdtfree` does `andl %d0,%a2@(32)`, corrupting an
UNRELATED page's `p_sdtbits`/`p_mapping` (offset-32 union alias) reverse-map head. This is the
exact "stale metadata → physical double-use" failure class already fixed once for ISSUE-5/6
and for `hat_ptfree`'s own analogous bug, and is reachable from **live, non-swap paths**:
`hat_swapout`'s shrink call, `hat_map`'s segment-growth boundary crossing, and
`hat_exec_orig`'s table-replace-during-growth — i.e. ordinary exec()/mmap-growth activity, not
an edge case. This is a genuine bug worth having fixed regardless of ISSUE-7, and it corrupts
*page metadata* rather than directly a u-area's content, so an extra step (the corrupted page
later freed/reused while still mapped elsewhere) would be needed to actually reach a zeroed
`u_procp`. Fixed in `patch_modelb.py` (2 new entries, mirrors the existing `hat_sdtalloc`
pattern); all three kernels rebuilt clean. **User boot-tested 2026-07-07: ISSUE-7 still
reproduces** — same PREEMPT1-5 signature (`u318=40734000` matching the established
`0x4073X000` pattern), `PREEMPT6 scanned=C zerocount=1 pid1=B0` (still isolated to exactly
one proc — consistent with all prior runs, just a different pid/count since fewer procs were
live at this point), terminal cascade this time `PANIC: Unknown bootmethod 0x600FBFE/
0x20000000` → `DOUBLE PANIC: Unknown bootmethod 0x600FBFE/0x40` (yet another distinct
terminal signature — 4th one observed across sessions — confirming once more that the
*terminal* PC/vector/message is just wherever the recursive kstack unwind happens to land,
not diagnostic of the mechanism). **The fix itself stays** (it is a real, independently-
disassembly-verified bug, worth having fixed on its own merits — see the description above)
**but is confirmed NOT the ISSUE-7 root cause.**

**Three hypotheses now ruled out this week alone** (hat_unload cpusha, setuctxt sleep
window, hat_sdtfree pfn), all independently well-motivated and each requiring real RE work
to test — none turned out to be it. User decision 2026-07-07: **pause active ISSUE-7 hunting
for now** rather than continue speculative single-hypothesis probing; system remains fully
usable from a pristine disk image in the meantime.

### RESUME POINTS (next measurements to try, when resumed)
- Codex's own suggested probe for hat_sdtfree (now moot, ruled out) — skip.
- A targeted, DIRECT pfn-corruption detector might still be worth building generically (not
  hat_sdtfree-specific): log every write to any `page_t`'s offset-32 field (`p_mapping`/
  `p_sdtbits`/`p_ptdats` union) that doesn't originate from an expected caller, since this
  offset has now caused THREE separate confirmed/plausible corruption classes in this
  project (hat_ptfree's original bug, hat_sdtfree's bug just ruled out, and HAT-MAP-AUDIT's
  documented "phantom PTE" double-entry risk — the last now FIXED, see below) — even though
  none has been proven to BE ISSUE-7, the offset itself is clearly fragile and worth watching
  generically rather than chasing one caller at a time.
  NOTE (2026-07-07): the HAT-MAP phantom-PTE producer is now disabled (commit 9b7f00c,
  hat_map preload skip) — so `pp->p_mapping` chains are single-format (live 040 only) from
  every producer again. This is a correctness cleanup, NOT confirmed as ISSUE-7's cause, but
  it does eliminate one of the three offset-32 corruption classes above; if ISSUE-7 is
  resumed, that leaves hat_ptfree's active_pts/free_pts retirement gap as the main remaining
  offset-32 suspect worth a generic write-guard.
- Add a `segu_softload` marker (only softunload was instrumented) + a `segu_get` per-proc
  (cp→p_segu→page pfn) marker to trace the u-area PAGE lifecycle and catch when p_segu's
  backing page becomes a fresh-zero page. LOWER PRIORITY than it once was: ruled-out items
  5 and 6 above establish the swap daemon AND segu_softunload are not even reached on the
  crash path, so a swap-lifecycle probe is chasing a subsystem already shown to be
  uninvolved.
- Let Codex continue mapping the kernel — its audits have a good hit rate this week (one
  genuine bug found and fixed, even though not this one) and cost nothing to keep running in
  parallel while ISSUE-7 hunting is paused.
- Codex to statically analyze the segu/u-area page lifecycle + a whole-kernel-vs-source
  audit (the `../amix-kernel-analysis/` sibling repo) — likely the fastest path given how
  resistant this is to probing.

</details>

## ISSUE-8: REAL-HW (Mercury 040) boot panics in p0init — kvm_init leaf-table `ctob`/`btoc` left at 2 KB in Model-B (✅ RESOLVED 2026-07-09)

> **✅ RESOLVED (2026-07-09), commit `998737f`.** The `click<<11` intuition was RIGHT after all —
> the 2026-07-07 "DISPROVEN" verdict was itself wrong, for two reasons: (1) fs-uae SILENTLY MASKS
> the halved read (so "`<<11` boots" proved nothing — the 2026-07-08 Amiberry.log compare later
> showed `Gary timeout 038a78XX R` at segu_get, confirming the halved address IS wrong on an
> accurate emulator), and (2) the earlier attempt patched only 2 of 6 sites (the ptptr `ctob` at
> 0x48d28/0x48ddc), leaving `ksegmappt`/`nextfree` (the shared `moveq #11` at 0x48d54/0x48e08)
> and the `+2047` roundings at `<<11` — an INCONSISTENT mix that corrupted downstream. **Root
> cause: `kvm_init`'s leaf-table `ctob(nextfree)`/`btoc(ptptr)` were never converted to Model-B
> (4 KB), so `word2` (the leaf-table phys) was HALVED** (0x714E-click → 0x038A7000, real RAM on
> the emulator's low memory but an unmapped hole on the real A3000). 3B2 `startup.c` proved the
> shape (`sptr->wd2.address = ptptr`, `ptptr = ctob(nextfree)`, `ksegmappt = ctob(nextfree)`,
> `nextfree = btoc(ptptr)`). **Fix = convert ALL 6 `ctob`/`btoc` sites together** (`<<11`→`<<12`,
> `+2047`→`+4095`); the `#512` SDE strides are Model-B-invariant and untouched. The `segu_get`/
> `swapinub` ubptbl wrappers (commit `df82ef8`) rebuild `p_ubptbl` from the live kptr040 tree,
> closing the same halved-leaf exposure on the fork path. Emulators now behave identically.
>
> **Real-HW status: UNTESTED with this fix.** The real-A3000 p0init bus error was this halved
> address (segu_get read 0x038A7xxx in the RAM hole); the fix should clear it, but it has NOT been
> retested on silicon. That is next-session goal #1 — see `RESUME-HERE-040-HARDWARE.md`. The
> historical writeup below (STORE A/B, cache-coherency hypotheses) predates the fix; hypothesis #1
> (STORE A / stale page-table lines) may still be a real-HW frontier if p0init still faults after
> the leaf address is corrected.

**Status (historical, pre-fix):** the faulting store and boot pattern below are correct facts. Photo evidence: user booted
`unix-040-dbg` (the ~07-05 build) on the real A3000 + PPS Mercury 68040 — first real-HW
attempt with a current-generation kernel. Photo: `testimages/040-boot-a3000-mercury.jpg`
(untracked comms dir).

**Observed boot pattern (user, real HW, repeated a few times):** FIRST boot with unix_boot040
→ **AmigaOS guru** (an AmigaOS-side alert, before the kernel installs trap handlers — so a
LOADER/handoff-level failure, NOT this kernel panic). SECOND boot → this p0init KERNEL PANIC,
immediately (screen goes black after unix_boot, nothing else, then the panic). Pattern repeats.
=> Treat as TWO separate phenomena: (a) the first-boot guru is a loader cold-start/handoff
robustness issue — **UPDATE 2026-07-09: almost certainly the cold-boot flakiness bug, since
ROOT-CAUSED AND FIXED (commit `a70e8df`): the loader's ELF buffer overlapped the copy
destination by ~25 KB and copyit's inverted copy-direction choice corrupted the copied kernel
head (incl. `_start`) → wild execution → guru; a 2nd boot's AmigaOS allocation residue shifted
the buffer past the overlap, which is why the second boot got further. Fixed loader
(overlap-safe copyit + MEMF_REVERSE buffer + permanent checksum verify; white/red screen flash
at handoff = corrupt copy) must be used on the next HW visit** — (b) the p0init panic below is
the kernel frontier and is fully root-caused (ISSUE-8 fix). Both fixes go to the same retest.

### What the screen shows
```
kstack 0x70DD178!
WARNING: DBG ufault VA=38A7000
TRAP  proc = 4007EC00 (pid 0, ) psw = 2700  pc = 7049130
PANIC: KERNEL FAULT psw=0x2700, pc=0x7049130, fmt=0x7, vector=0x2 (Bus Error)
DOUBLE PANIC: usrxmemflt: no as allocated.
```

### Decoded (every step verified against the binary)
- `pc=0x7049130` = kernel offset **0x49130 = inside `p0init`** (0x48fcc–0x49140), the loop
  tail. **`p0init` is called from `mlsetup` (0x48b8c), which runs in `pstart040`'s tail —
  BEFORE `main()` and long before the banner** (the banner's `utsname`+7×`printf` block is at
  0x59842, after `main`→`startup`→`vfs_mountroot`). `kstack 0x70DD178` = pstack (startup
  stack), proc 0, IPL7. **Real-HW timing CONFIRMS this (user, 2026-07-07): the panic appears
  immediately when the screen goes black after unix_boot, with NOTHING else on screen — i.e.
  pre-banner, pre-main, right after MMU bring-up = exactly where mlsetup→p0init sits.** The
  `DBG ufault VA=38A7000` line is **getfault040.s** printing the 040 format-7 frame's fault
  address: the faulting access hit phys **0x038A7000** (va<0x40000000 = DTT0 identity).
- p0init's loop (verbatim 030 code, unpatched) maps proc 0's u-area 4×2KB clicks with TWO
  stores per click: STORE A `0x490f6` into `p_ubptbl` (needed — resume040 path U reads it)
  and **STORE B `0x49120`** — an inline 030-tree walk
  `st_top1[(p0seguser>>17)&0x1fff].word2 + ((p0seguser>>11)&63)*4` and a PTE write through
  it. For p0seguser=0x48440000 (kvsegu slot 0): SDE index 0x422, PTE index 0 → the store
  target is **exactly `st_top1[0x422].word2`**.
- **Who filled word2: `kvm_init`.** Its kvsegu-window SDE build loop
  (0x48dc0–0x48e08) computes the leaf-table address as **`leafclick << 11`**
  (`0x48ddc: moveq #11,%d6; asll %d6,%d1`) and stores it to SDE word2 (0x48df2).
  Under Model B a click IS a 4KB pfn, so `<<11` HALVES the real address:
  leaf page at pfn 0x714E (first free pages right after the kernel image + early tables)
  → word2 = **0x038A7000** instead of 0x0714E000. `0x714E<<11 == 0x38A7000` exactly.
  The identical missed shift exists for the kvsegmap window (0x48d28/0x48d3e) and for the
  `ksegmappt`/`eksegmappt` globals (0x48d54).
- **Why the emulator never showed this:** the 030 st_top1 tree is INERT on 040 (all walkers
  ported to kptr040), so the halved word2 is never used for translation; p0init's STORE B
  posted-writes into unpopulated address space at 0x038A7000, and **fs-uae silently swallows
  accesses to unmapped space** — boots clean. The **real A3000 bus raises a bus error** on
  the posted write → fmt=7 vector=2 panic, pc advanced to the loop tail (040 writeback-fault
  imprecision). This CONFIRMS the phase-4 real-HW analysis prediction ("caches OFF → suspect
  = posted write to garbage phys") and its already-identified fix shape ("p0init STORE B now
  obsolete (prumap040) → 2-byte neuter") — same store, now with the full causal chain.
- **NOT a Mercury-memory-map issue**: the halved address is wrong on ANY memory map; an
  A3640 would hit the identical panic. The kernel's own base/console/MMU are fine.
- **The 07-05 vs current kernel age is irrelevant**: kvm_init/p0init/segu_get are stock text,
  byte-identical between that build and today's; this week's fixes are all post-login paths.
  Today's build panics identically on real HW.

### Predicted SECOND consumer (verified present): segu_get
`segu_get_orig` has the IDENTICAL inline st_top1 walk + store (0xaa6c4–0xaa6e6+), executed
for EVERY forked proc's u-area. Fixing p0init alone would move the real-HW panic to the
first fork. Any fix must cover both consumers — which the root fix does automatically.

### What the photo PROVES works on real 040 silicon (major milestone)
unix_boot040 handoff, pstart040 movec/TTR MMU enable, deep startup (mlsetup, page_init,
kmem_init, kvm_init all COMPLETED — p0init is far into main()), console output, trap
handling (a clean panic, not a guru), getfault040's 040 frame decode (correct FA printed),
and userspace040 routing (the double-panic message went through usrxmemflt). The port
fundamentally runs on real silicon; the blocker is one missed byte-patch site + its two
inert-store consumers.

### Fix plan (small; CODING GOES TO FABLE when approved)
1. **Root fix (preferred):** patch_modelb.py entries flipping `moveq #11→#12` at
   **0x48d28** (kvsegmap SDE fill) and **0x48ddc** (kvsegu SDE fill) — word2 then points at
   the REAL allocated leaf pages, so p0init's/segu_get's inert stores land in real dedicated
   RAM (their 030 purpose) on emulator AND real HW. Before including **0x48d54**
   (ksegmappt/eksegmappt) in the same change, scope-check who consumes those globals on the
   live path (segmap Tier-2 patches may already compensate; changing it blind risks the
   working emulator boot).
2. **Belt-and-braces (phase-4's original plan):** additionally neuter p0init STORE B
   (0x49120 `2080`→`4e71`) since prumap040 made it obsolete; consider the same for
   segu_get's store after RE-ing whether anything reads those inert PTEs.
3. Test order: rebuild → emulator boot MUST stay clean → real-HW retest (expect: past
   p0init, past early forks, next unknown real-HW frontier — likely SCSI/a3091 DMA or
   interrupts). Real-HW serial capture works (phase-4 note) and should be used for the
   next attempt.

---

## ISSUE-9: idle-time infinite Bus Error loop (OPEN, uncaptured — separate from ISSUE-7)

**Status: OPEN, deferred (2026-07-09).** After ISSUE-7 was fixed, the user left a successfully
booted 040 machine idle for a longer period and returned to find an **endless BUS ERROR loop on
screen**. Not yet captured to serial; not present in the 7-reboot ISSUE-7 verification log (that
run ended in a clean `haltsys`).

**Why it is NOT ISSUE-7:** the ISSUE-7 recursion signature (`kstack`/`KSTKCHAIN`/
`PREEMPT1 uprocp=0`, the wb040 write-back path) is completely absent from healthy runs now, and
this triggers on IDLE — a different code path. Most likely a **periodic/idle path**: `fsflush`,
`sched`/`pageout` daemon, or the clock/callout handler faulting after some time or on a periodic
wakeup. Could be a slow resource leak (page-table / kmem), a timer-driven fault, or a stale
mapping that only a long-lived idle process touches.

**Next step (do NOT chase blindly — capture first):** reproduce with SERIAL capture running
(see `SERIAL-DEBUG.md` / memory `amix-serial-debug-capture`) and let it sit idle until the loop
starts, to get the fault PC + type + faulting address. Then map the PC to the daemon/handler.
Only after that decide on a fix. Per the standing "pause elusive-bug hunting; record and redirect"
guidance, this is recorded and deferred — not the immediate frontier (real-HW retest + cold-boot
flakiness come first).

## ISSUE-10: `/bin/sh` heap contains a kvsegu-range pointer → SIGBUS fault-retry flood (amixadm repro)

**Status: OPEN (2026-07-10). Deterministic repro on the 68040** (reproduced at least twice;
first seen right after the 060 merge but confirmed on 040 → NOT an 060 regression).

**★ DATAPOINT + FAST REPRO 2026-07-15 (writeback conversion + schedpaging retirement):**
with the pageout daemon LIVE (schedpaging override retired, `pageoutd` sites converted),
sustained I/O pressure trips this class **within minutes**, escalating victim by victim:
console `-sh` (BUS ERROR at `4AFC0000`, the classic signature), then `in.telnetd` +
`inetd` (bus errors at `4AFC005F`/`C09EFBEC` — **the "network/telnet stall under load"
is at least partly THESE daemons dying, not a streams wedge**), finally `/sbin/init`
itself in a `sig=4` (ILLEGAL = 0x4AFC content) crash-loop. Repro recipe: emu-040 dbg
build ≥260715-12, tftp a 4 MiB file in, `cp` it 6× to `/` (one per telnet session),
run sums — corruption lands during/after the copy+reclaim burst. File-data writeback
stays byte-perfect throughout (`sum` 1570 8192 on all copies) → the corruption hits
USER anon/text pages via page REUSE, not the putpage data path. Mechanism already
diagnosed in `prototypes/hatalloc_dbg.s` (page_abort wrapper): **`page_abort` calls
`hat_pageunload` only when `p_mapping != 0`; a 040 PTE loaded without p_mapping
registration survives the free → freed page is re-used while still mapped → the old
owner reads the new owner's (often freshly disk-read) content.** Pageout multiplies
page-reuse rate, which is why the daemon makes it fire fast. **RESUME RECOMMENDATION:
the root fix is p_mapping registration coverage in the 040 HAT load paths (or an
unconditional-unload strategy that can find PTEs without p_mapping); the fast repro
above replaces the old slow amixadm-flood hunt.**

**★ SOURCE-FIRST NARROWING 2026-07-15 (evening) — leading hypothesis REFUTED.** Read the
SVR4 3b2 `vm_hat.c` p_mapping CONTRACT (the intended design) and verified the m68k port
against it, function by function. The contract: `hat_pteload` registers every new PTE
(`*(pte+NPGPT)=pp->p_mapping; pp->p_mapping=pte`); `hat_dup` splices the child PTE in
(both COW-copy and share paths); `hat_unload` walks the list and unlinks the specific
PTE; `hat_pageunload` walks + NULLs; `page_abort`/`hat_unload` free only when
`p_mapping==0`. **The m68k port implements ALL of these correctly** — hat040.s
`Lw_nolock` (fresh register), `Lreplace` (remap-diff-pfn unlink-old+register-new),
hat_dup040.s `Lhd_copy`/`Lhd_share` (both splice), hat_unload040 `Lhl_findmap`/`Lhl_unlink`
(with an `Lhl_findfail` diagnostic that fires iff a to-be-unloaded PTE is absent from the
list). And the ONE known violator — stock `hat_map`'s phantom vnode-preload that published
legacy pfn<<11 reverse-map entries — was already DISABLED (9b7f00c, 0xb58d2 beqw→braw).
**So "a PTE loaded without p_mapping registration" is NOT the surviving mechanism.** The
narrowed suspect set is now: (a) page-table **coherency/ordering** — the +256 reverse-map
link or PTE write not pushed to RAM (cpusha/pflusha) before a page-table is freed+reused
(hat040/hat_dup040 comments already obsess over this); (b) the **old-SDT teardown leak**
(HAT-MAP-AUDIT: hat_unload/hat_free don't retire leaked legacy SDT tables → a file-backed
page can retain a reverse-map pointer into a reused legacy table); (c) a page freed via a
path that **bypasses hat_pageunload entirely**. **DECISIVE NEXT STEP (empirical, not more
static reading): boot `unix-040-dbg` (has the `Lhl_findfail` probe + hatalloc_dbg
page_abort p_mapping logger), run the fast 6×4 MiB pressure repro, and read the serial log
— WHICH probe fires selects (a)/(b)/(c).** The source-first pass converted ISSUE-10 from
"mysterious stale-PTE, many hypotheses" to "core contract verified correct, 3 narrow
candidates, one instrumented experiment to disambiguate." Method win recorded in
[[amix-source-reconstruction-feasibility]].

**★ EMPIRICAL RUN 2026-07-15 (evening) — 2 of 3 candidates further narrowed; repro is
NON-DETERMINISTIC.** Booted `unix-040-dbg` (260715-12, has `Lhl_findfail` "pte not in
revmap" + hatalloc_dbg page_abort/memload/pageunload loggers), ran pressure workloads.
Session tally (whole boot): **0 corruption hits** (no `4AFC` BUS ERROR, no `SIG sig=4|11`,
no `SEGVDMP`) and **0 `pte not in revmap`** — plus benign churn: 40× `page_abort crash
p_mapping=0` (caller = **anon_decref+0x42**, the COW-anon refcount-drop free), 8× `hat_memload
crash` (p_mapping ALWAYS non-zero = registered), 2× `hat_pageunload CALLED`, 6× `page_free
SH DATA` (callers page_abort+0xDA, as_free+0x12 exit-teardown, hat_ptfree+0x70). All file
sums stayed `1570 8192`, guest alive. **Rules out two more mechanisms:** (1) load-registration
failure — hat_memload always registers; (2) hat_unload orphan — `Lhl_findfail` stayed SILENT,
so hat_unload never met a to-be-unloaded PTE missing from the revmap. **The corruption did
NOT reproduce in two deliberate pressure attempts** (both hampered by telnet tooling friction:
a heredoc'd and a nested-quote flood script both failed to run through emu.py). It fired
INCIDENTALLY earlier the same day but resists scripted on-demand repro — classic elusive
signature ([[feedback-pause-elusive-bug-hunting]]).

**Surviving candidates:** (a) page-table coherency/ordering (cpusha/pflusha), (b) old-SDT
teardown leak, (c) a free that bypasses hat_pageunload while a live PTE persists. The current
probes are PROXIES — none directly verifies the invariant at free time. **Two concrete
next-session moves:** (i) TOOLING — push the pressure workload as a FILE via tftp (not typed
through telnet) so it actually runs hard; (ii) INSTRUMENTATION (Fable) — a DIRECT invariant
probe: in page_free/page_abort, when `p_mapping==0`, do a bounded reverse scan for any live
PTE still mapping that pfn; a hit is the smoking gun and catches the bug WITHOUT needing the
userspace crash to manifest, sidestepping the repro nondeterminism entirely.

**★★★ RELIABLE REPRO + SMOKING-GUN CONTENT 2026-07-15 (night) — corrupting data is a
FRESHLY-DISK-READ ELF binary, so the reuse is via the segmap/exec disk-read path, NOT a HAT
p_mapping bug.** Move (i) landed: `test-tools/` (this session) proved the FILE-via-tftp
workload path, so `scratchpad/tftp/pressure.sh` (6× concurrent 4 MiB `cp` + `hat_dup_cow 64`,
run as a detached FILE not typed) now reproduces the corruption **within the FIRST burst
(~80 s)** on emu-040 dbg 260715-16 — the bug is no longer nondeterministic once you apply
*concurrent* copy pressure + fork churn from a real script. Escalation: first victim
`hat_dup_cow`/`cp` (BUS ERROR `4AFC005F`), then `/sbin/init` PID 1 in a permanent `PC:4`
crash-loop (control flow corrupted to addr 0x4). **Serial (30 MB, capture DID survive — the
earlier "frozen at 121430" was a stale read) gives the discriminator:**
- **`SEGVDMP p0=7F454C46 p4=1020100 …`** = `\x7fELF` + class32/big-endian ELF header, and the
  cm4/c0/c4/c8 fields decode to `.dynstr` symbol names — `open waitpid read exit _xmknod write
  close malloc …`. **The crash page holds an ELF binary's header + dynamic-symbol string table,
  read fresh from disk.** i.e. a user anon/heap page (sh malloc region va≈0x80010000) was handed
  to the segmap/exec demand-page path to hold a forked child's executable, WHILE the user PTE
  still mapped it. Concurrent `segmap-map … pfn=883F/863F/8E2C/8E2E/8E65` disk reads run right
  up to the first fault.
- **`Lhl_findfail` ("pte not in revmap") fired 0×** and `hat_pageunload` was called on the crash
  page with **non-zero p_mapping** immediately before the fault → **the HAT registration path is
  healthy**; this is NOT a missing-p_mapping bug (re-confirms the source-first finding, now under
  a real repro). Crash page structs cluster contiguously (stride 0x54 = sizeof(page)=84).
- **NARROWED to candidate (c), refined:** a *phys double-use* between user anon pages and the
  **buffer-cache/segmap/exec disk-read** reuse — the page reaches the free list / segmap fill
  while a user PTE still maps it, bypassing hat_pageunload of that mapping. This is the ISSUE-5/6
  "phys double-use" family, on the reclaim↔disk-read boundary — NOT the HAT p_mapping contract.
- **Best next probe (supersedes the generic free-time walker):** instrument the segmap/disk-read
  page-fill (or page_get/page reclaim into segmap) to assert the target pfn has no live USER PTE
  before filling it from disk — a hit names the exact reuse. Excerpt saved:
  `test-tools/issue10-smokinggun-260715.txt`. Spec: `ISSUE-10-FREETIME-PROBE-SPEC.md` (widen its scan target
  from free-time to the disk-read fill).

**★★ SOURCE-FIRST ANALYSIS 2026-07-15 (night) — the reclaim contract + a real unported HAT op
(`hat_pagesync`).** Read the 3b2 reference reclaim path that the now-live pageout exercises:
- `checkpage` (vm_pageout.c:351): DIRTY pages (`p_mod && p_vnode`, = sh's malloc heap) are NOT
  freed inline — they go `VOP_PUTPAGE(…, B_ASYNC|B_FREE)` and are freed later in **`pvn_done`
  B_FREE completion** (vm_pvn.c:365-394). That block is the reclaim's safety gate:
  `if (p_mod==0 && p_mapping) hat_pagesync(pp); if ((!p_ref && !p_mod)||p_gone||!p_vnode){ if
  (p_mapping) hat_pageunload(pp); page_free(pp);} else page_unlock(pp);`
  → **`hat_pagesync` is the linchpin: it reads the HW Used/Modified bits to decide whether the
  process still needs the page** (referenced ⇒ RECLAIM/keep, not free).
- **`hat_pagesync` is UNPORTED** — no override in prototypes/*.s or the relink scripts; stock
  030 body runs at 0xb4be8, calling `hat_pt2ptdat` (0xb5e0a, the retired 030 ptdat/secseg
  machinery) + `flushmmu`. The ref/mod BIT POSITIONS happen to align (immu.h `PG_REF`=bit3,
  `PG_M`=bit4 == 040 U/M), so the read isn't obviously wrong; the suspect part is the retired
  `hat_pt2ptdat`/`flushmmu` ATC handling on the 040 tree (Codex "hat_pagesync cpusha gap
  LATENT"). **LATENT until pageout went live** (schedpaging retirement 836cec7) — which is
  exactly why ISSUE-10's hit-rate jumped this same day.
- **HONEST confidence:** hat_pagesync-unported is a REAL gap in the reclaim safety path and the
  best structural lead, BUT the exact corruption chain is not yet closed: the B_FREE path DOES
  call `hat_pageunload` (which pflushas the single 040 ATC) before `page_free`, so a naive
  "freed while still mapped" story is incomplete. Two chains remain to disambiguate: (I)
  hat_pagesync mis-accounting frees an actively-used page whose content sh then re-faults into a
  reused frame; (II) page_get hands out a frame still mapped by a path that skipped the B_FREE
  hat_pageunload. **DECISIVE next step:** a probe at `page_get` (free-list reuse) asserting the
  returned page has `p_mapping==0` AND no live USER PTE — now runnable against the reliable
  repro. If it fires, dump the offending pfn + the surviving PTE's table → names chain (I) vs
  (II). Porting `hat_pagesync040` (read U/M from the +256 leaf PTE, global `pflusha`) is the
  candidate FIX to test once the probe confirms.

**★ hat_pagesync040 BUILT + TESTED 2026-07-15 night (build 260715-18, commit 4833ae6) — does
NOT fix ISSUE-10; rules out chain (I), points at chain (II).** Ported `hat_pagesync` to 040
(prototypes/hat_pagesync040.s: verbatim U/M gather+clear, retired flushmmu block replaced with
unconditional `cpusha bc`+`pflusha`). Boots clean to login (hat_pagesync is exercised by
fsflush during boot) — no regression. But the 4-burst concurrent-pressure repro STILL fires,
**identically**: first victim `cp /payload.bin/press6.bin` then `sh /tmp/pressure.sh`, BUS ERROR
`4AFC005F` PC:C1012100, `SEGVDMP p0=7F454C46`=`\x7fELF` + the same `.dynstr` symbols, `Lhl_findfail`
still 0. Fired one burst LATER than on 260715-16 (fix_p3 ~2 min clean, then flooded) — a slight
rate reduction, not a cure. **Conclusion:** the reclaim ref/mod SAMPLING (chain I) is not the
mechanism; the corrupting frame reaches page_get/exec-disk-read reuse while a USER PTE still maps
it via a path that never hat_pageunload'd THAT mapping (chain II — most likely a phys double-use /
alias whose PTE is absent from the freed page's `p_mapping` list, ISSUE-5/6 family). **hat_pagesync040
is KEPT** (a genuine correctness fix: the op was unported and its ATC flush broken, which degrades
pageout LRU ref-bit sampling regardless of ISSUE-10) but is NOT the ISSUE-10 fix. Evidence:
`test-tools/issue10-hatpagesync-negative-260718.txt`. **Next: the page_get free-list-reuse probe
(chain-II direct test) — still the decisive instrument.**

**★ hat_exec steal REFUTED 2026-07-15 (audit #1, commit 79c1faa, build 260715-20).** No-op
`hat_exec` (prototypes/hat_exec040.s, 6e56ee0 — removes the flag-0 steal path + NULL-panic) boots
clean but the 4-burst repro reproduces IDENTICALLY (same pp=400AA2C0, 4AFC005F, `\x7fELF`). hat_exec's
steal is NOT the producer. No-op KEPT as Codex `HAT-EXEC-POLICY` safety hardening, not the fix.
Evidence `test-tools/issue10-noexec-negative-260715.txt`.

**★★★ SEGVCHAIN PROBE + ROOT REFRAMED 2026-07-16 (commit 744cd65, build 260715-22) — chain-II
REFUTED; it is a DOUBLE-REGISTERED frame.** Added a victim-context reverse-map probe to
`prototypes/sigkill_dbg.s`: on a SIGSEGV whose saved-a0 URP walk reaches a resident leaf (the sh-heap
morphology), after SEGVDMP/SEGVPP it walks `pp->p_mapping` and prints `DBG SEGVCHAIN cnt in head vpte
hpte` — `in` = whether the victim's own leaf-PTE address is in the chain. Verified apples-to-apples
(chain stores PHYS `&leaf`, `hat040.s:461` links `%a4` from `%urp`); all derefs phys-gated + cap 16;
cap-split (Lsg_n=8 resident-leaf / Lsg_bn=4 bail) so an init crash-loop can't flood/drain. Two runs
first escalated to /sbin/init control-flow corruption (`C0800084 PC:E`, walk-bails → no data); a
grind run then landed the sh-heap morphology and the probe fired 8×:
- **`in=1` in ALL rows** (incl. `vpte!=head`, so the chain was genuinely walked) → **the victim's
  live-040 PTE IS in the freed page's chain. The "missing-live-entry" chain-II hypothesis is
  REFUTED; the reverse map is INTACT.**
- SEGVPP: the frame has **`p_vnode!=0 off=0`** (a file's first page = the ELF header behind
  `\x7fELF`) **and** the victim's user-anon heap PTE in its chain, `hpte=…00D` = live-040 PTE. Two
  page_ts (`400A8F88`/vn=`40121658`, `400A9FF0`/vn=`40120EE8`).

**⇒ ROOT: a DOUBLE-REGISTERED frame** — one physical frame is concurrently a **file vnode-cache
page** (`p_vnode`/`p_offset` set) and a **user-anon heap page** (live PTE, intact chain). It reached
page reuse / a vnode disk-read while a live user-anon mapping still owned it — a page-allocation /
vnode-cache-lifetime fault (ISSUE-5/6 phys double-use), **not** a `hat_pageunload`/`p_mapping` fault.
This retires the chain-II suspect list (hat_ptalloc alias, VA-vs-page GC, cpusha) as the primary
line. Evidence `test-tools/issue10-segvchain-260716.txt`, `issue10-initmorph-260716.txt`.

**NEXT (source-first, delegatable to Fable): page/vnode lifetime audit.** How does one page_t end up
both vnode-hashed and user-anon-mapped? (A) a vnode-cache page freed to the free list without
clearing `p_vnode`, then `page_get` hands it to anon; (B) a live user-anon page handed to
`page_get`/`vnode-getpage` for the disk read (sets `p_vnode`, reads the ELF over it). `page_free`/
`page_abort` panic on `p_mapping!=0` and the chain is intact here, so the frame reaches reuse by a
path bypassing that gate, or `hat_pteload` linked the victim PTE only after the vnode read. Audit
`page_get`/`page_free` free-list + `page_lookup`/vnode hash lifetime; Codex `PAGE-ABORT-FREE-CONTRACT`,
`VOP-GETPAGE-PAGEIN-CONTRACT`, `SEGMAP-HAT-STALE-WINDOW-AUDIT`, `ANON-SWAP-PAGEIN-CONTRACT`. The
SEGVCHAIN/SEGVPP probe stays as the live confirmator (grind full 6-cp pressure to land the sh-heap
morphology; ~1 in 3 runs, the rest hit the non-walkable init morphology).

**★ AMIXADM TRIGGER RETESTED 2026-07-15 (evening) — the 2026-07-10 deterministic trigger NO
LONGER FIRES on 260715-12.** Ran the original deterministic use case (`/usr/amiga/bin/amixadm`,
the interactive-menu sh script whose malloc free-list walk faulted) directly: bare run,
8× with `q` after priming with 128 forks (u-area churn), and a heavy menu-loop attempt — **all
exited CLEANLY, zero `4AFC`, zero `CMD:amixadm`/`CMD:-sh` fault lines across the whole boot,
data intact.** The bug is NOT fixed (it still crashed sh/telnetd/init under HEAVY sustained
pressure earlier the same day on 260715-10, task-5 evidence), but its trigger threshold has
clearly moved UP: amixadm's light forking is no longer enough to land sh's heap on a
stale/reused page. Likely causes of the reduced hit-rate since 2026-07-10: the completed
Model-B page-in/writeback conversion (fewer stale/half-read pages) and possibly the orderly
pageout reclaim from the schedpaging retirement (836cec7). **Practical consequence: amixadm is
retired as a reliable repro; ISSUE-10 is now a RARE, pressure-gated corruption, consistent with
the source-first finding that the core p_mapping machinery is correct. Recommended handling:
land the DIRECT free-time invariant probe (above) so the residual is caught opportunistically
in the background rather than chased with an increasingly-unreliable trigger.**

**Symptom:** running `/usr/amiga/bin/amixadm` floods the console with
`NOTICE: User BUS ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:<n> CMD:amixadm`, forever.

**Decoded facts (all from disassembly of vanilla `/sbin/sh` + the kernel):**
- `amixadm` is a plain `#!/bin/sh` script — the crasher is **sh itself** (CMD shows the
  script name).
- PC `0x800023FC` = sh's **own malloc free-list walk**: `moveal %a0@,%a1` then
  `btst #0,%a1@(3)`. Fault addr `4AFC0003` = a1+3 → **the free-list link read from sh's
  heap is 0x4AFC0000 — inside the kernel's kvsegu u-area region** (kvsegu = 0x48440000;
  offset 0x2B80000). A user anon/heap page contains kernel-u-area-flavored data where a
  malloc link should be.
- The endless flood is the historic Bourne-sh behavior: sh catches SIGSEGV/SIGBUS itself,
  sbrk()s more memory, and RETURNS to retry the faulting instruction — a kernel-range
  garbage pointer never heals → infinite fault/retry.
- `FAULT:6` = FLTBOUNDS from `hardbus` (u_trap print): the kernel correctly refuses the
  user access to a kernel VA; the loop is sh's retry, not a kernel fault loop.
- The malloc list head lives at `0x80010f08` in **sh's .bss page 0x80010000 — the very
  page investigated 2026-06-27 in the disk-DMA / phys double-use diagnostics**
  (vtop040.s header; assegat_dbg.s "sh's data page 0x80010000" probes). Suspect classes,
  in order: (1) phys double-use (a user page that is/was also a kernel u-page — the
  ISSUE-5/6 family), (2) ZFOD dirt (anon page not zeroed — one instance already fixed in
  44ebf05, `pagezero(pp,0,0x800)` half-zero), (3) buffer-cache/DMA into a user phys page.

**Next data (cheap, deterministic repro!):** boot `unix-040-dbg` (build ≥ 260710-13, the
hardbus probe now also prints `uva=` = curproc->u_va), run amixadm, capture serial. Read:
(a) `pte=` for 0x4AFC0000 (what the tables say about the bad target), (b) `uva=` — is
0x4AFC0000 sh's OWN u-area?, (c) the hat/as_fault/segu serial trace in the seconds before
the flood (which page got mapped where). Also worth one control: does plain interactive
`/sbin/sh` (typing a few commands) crash too, or only the amixadm script pattern
(fork-heavy menu loop)?

**ISSUE-10 progress log (2026-07-10):**
- Repro matrix so far: 040 fs-uae CRASH, 040 Amiberry CRASH (deterministic, same
  4AFC0003), 060 fs-uae NO crash (amixadm runs), 060 Amiberry UNTESTED. The earlier
  "fs-uae doesn't reproduce" was a mislabeled 060 run.
- sh eventually RECOVERS by itself: the catch-SIGSEGV/sbrk/retry loop finally
  exhausts and sh prints "/usr/amiga/bin/amixadm: no space"; the session stays alive.
- Serial capture (040 dbg): the fault takes the DEMAND path (as_fault fails on the
  wild kernel VA -> FLTBOUNDS -> SIGSEGV loop, `DBG SIG sig=11 stat=6` repeats);
  hardbus never runs. Kernel-side handling at fault time is CORRECT; the corruption
  happened earlier. pid's only trace before death = one successful segmap read fault.
- Emulator writeback facts (WinUAE/Amiberry source, newcpu.cpp fmt7 build +
  cpummu.cpp): **the emulator NEVER sets WB1S/WB2S valid** (wb1 fields don't exist;
  wb2 only for MOVE16 line writes) and always pushes WB3A == FA == EA, WB3D = plain
  register-style value. So wb040.s's WB1/WB2 replay paths have never executed on any
  emulator -> not the corruptor. SEGVCTX probe data (dbg 260710-14) still pending.

## ISSUE-11: wb040.s WB1 replay uses wrong data alignment — REAL-HW landmine (latent, emulator never triggers it)

**Status: OPEN (2026-07-10), latent — fix before the next real-HW visit.**
Found while investigating ISSUE-10 against reference implementations:
- **NetBSD** (`m68k_trap.c m68040_writeback`): WB1D is **memory/bus-lane aligned** —
  software must reposition it before writing: `off = (wb1a & 3) * 8`; LONG: rotate
  left by off; BYTE: `wb1d >>= (24 - off)`; WORD: rotate left by `(off+16) % 32`.
  WB2D/WB3D are plain right-justified values (written as-is).
- **Linux** (`traps.c do_040writebacks`): never replays WB1 at all (`#if 0 "cannot
  handle 1st writeback"`), and skips WB2 when its size is LINE (MOVE16 residue).
- **Our `wb040.s`** replays WB1 with WB2/WB3 semantics (right-justified) — on REAL
  68040 hardware a valid WB1 with (wb1a&3, size) != trivial would write the WRONG
  BYTES to the right address (e.g. an aligned WORD store's data sits in WB1D bits
  31-16; we'd write the low word = zeros). The emulator masks this completely
  (WB1S never valid — see ISSUE-10 notes), so all emulator testing passes.
**Fix plan:** add the NetBSD realignment to the WB1 dispatch in `wb040_replay`
(rotate/shift WB1D per size + wb1a&3 before `Lwb_do`), plus skip WB2 when
SIZE==LINE (0b11: currently mis-replayed as a word write). Both changes are
inert on emulators (paths never taken) — verify on real HW.

**ISSUE-10 ROOT CAUSE FOUND + FIXED (2026-07-10, builds 260710-16/-17/-18, boot test pending):**
SEGVCTX v2 pinned the corrupt cell: sh heap VA 0x80011CC0, phys 0x095AE000, live content
4AFC0000, and the very first fault followed a beyond-brk link -- the arena head was reading
STALE page content. Root cause: **`s5getapage` (x23 sites) and `spec_getapage` (x12 sites)
were never Model-B-converted** -- the Tier-2 pager pass covered ufs_getapage only, and the
root fs is s5. Full-page paths accidentally work with 2KB masks (4KB-aligned offsets round
to themselves), but every PARTIAL file page (file tails, incl. every exec'd binary's last
data page) was half-read/half-zeroed: pagezero(pp, off, 2048-off) leaves bytes 0x800-0xFFF
holding the phys page's previous content. /sbin/sh's last data page has file bytes only to
0x6E8 and its malloc arena head sits at page offset 0xF08 -> head read stale garbage ->
the walk followed the phys page's PREVIOUS content -> 4AFC0003 SIGSEGV flood. Explains all
observations: only some binaries affected (file-tail offset must land < 0x800 with .bss
vars in the stale half), late-boot onset (early pool pages are clean), and the apparent
040-vs-060 split (page-pool allocation order differs per CPU boot -> different previous
content; NOT a CPU mechanism). FIX: 35 new byte patches, groups s5gp+specgp in
patch_modelb_pager.py (all 2KB idioms: cmpil/addil #2047, andiw #-2048, movel #2048,
addil +/-2048, PAGESHIFT moveq #11->12; the mulsl %a1@ fs-bsize multiplies LEFT alone).
Also fixes silent file-data corruption for any mmap/exec of s5 files with tails in
(0x800,0x1000) -- a much broader latent bug than amixadm.

**ISSUE-10 correction (2026-07-10 evening): the s5gp/specgp fix did NOT cure the crash**
(build -17 reproduces with the identical signature; phys shifted 095AE000->095AC000 with
the new kernel layout = layout-deterministic, not fixed). The s5/spec Model-B patches stay
(genuine conversion gaps -- boot/login/bash all still work on -17), but they were not the
corruptor. KEY REALIZATION: the SAME sh binary ran dozens of rc scripts at boot cleanly --
the malloc-head page content DEGRADES at runtime between boot and the interactive amixadm
run. Suspicion back on page-cache / phys-reuse corruption (a dead proc's page left hashed
in the vnode cache, or phys double-use). SEGVCTX v3 (dbg 260710-19) dumps a 6-long content
signature of the corrupt phys page to identify its previous owner.

**ISSUE-10 FULL STATE DUMP + PAUSE (2026-07-10 night, user decision — same protocol as the
ISSUE-7 pause: record + redirect; may resolve via another route.)**

*Symptom & repro:* `/usr/amiga/bin/amixadm` (a plain `#!/bin/sh` script) → endless
`User BUS ERROR` flood (sh catches SIGSEGV, sbrk-retries forever; eventually self-recovers
with "no space"). Deterministic on the 68040 on BOTH emulators; 68060 clean on both
(believed layout luck, not a CPU mechanism). Reproduced ~8 times across builds -14..-23;
the corrupt phys shifts with kernel layout (095AE/095AC/095AF...) but the VICTIM is always
sh's first heap page (VA 0x80011000) + the arena head page (head @0x80010f08 reads a
beyond-brk garbage link 0x800120C0 every time).

*Evidence chain (probe by probe, all in serial logs /tmp/amix-issue10*.log):*
1. SEGVCTX v2: corrupt cell = VA 80011CC0, live content 4AFC0000, pte resident+valid.
2. SEGVDMP v3: foreign content is DISK-FLAVORED and varies per run: an s5 DIRECTORY
   dirent ("amixdate", /usr/amiga/bin) one run, the amixadm PATH string the next —
   1KB-buffer granularity at page offset 0xC00 (page start zeros).
3. SEGVPP v4: the page's page_t: flg=0x600 (mod+ref, NOT free), vn=400B6604,
   off VARIES per run (0x127000/0x2B0000/0x2D4000 — too large for the tiny dir file =>
   vn is most plausibly the swap/anon vnode and the page is sh's LEGIT anon page);
   p_mapping = 095A0044 = leaf entry 0x11*4 => VA 0x80011000 = sh's own mapping ✓.
   p_uown=0 (never a u-page).
4. PGALIAS (page_get wrapper): SILENT — page_get NEVER hands out a page with live
   p_mapping => free-list double-allocation RULED OUT.
5. VTOPALIAS (vtop DMA-target check, kernel buffers only): SILENT — no kernel-buffer
   DMA ever targets a mapped page (at/after mapping time) => the corrupting write
   happens BEFORE sh maps the page, or bypasses vtop.
6. Static audits during the hunt, all clean/ruled out: pagezero (lsll #12 ✓),
   page_numtouserpp/okpp ((pfn-base)*60 ✓), anon_zero (pea 0x1000 ✓), binit/getblk/
   geteblk/sptalloc (no 2KB idioms), wb040 WB1/WB2 replay (emulator never sets them),
   TAS/FSLW (fixed, was the 060 issue), kernel fault handling at crash time (correct:
   demand path → FLTBOUNDS → SIGSEGV; sh's own retry makes the flood).

*Fixes landed during the hunt (kept, genuine, but not the corruptor):*
- s5getapage ×23 + spec_getapage ×12 Model-B conversion (903210c) — real file-tail
  half-read/half-zero bugs on the s5 root fs.
- wb060_sswsynth + wb060_xpage (060 fixes, merged with 060-B).

*The surviving picture:* sh's anon heap page is legitimate in every VM structure, but its
CONTENT matches a recently-read disk block (dir block or file page) at 1KB granularity.
The write lands before/around sh's startup and evades the vtop and page_get chokepoints.
Remaining suspect classes, in order: (a) a pagein/buffer path whose IDENTITY-VA target
math is wrong for HIGH-BANK pfns only (0x08000000+ pool pages — would explain late-onset:
early-boot procs get low-bank pages; rc-time sh instances never crashed), checked pagezero
but NOT every pfntokv/pptonum INLINE copy in the pagein/buffer/segmap paths; (b) segmap
window PTE pointing at a stale/wrong phys during fbread of the script/dir; (c) something
entirely outside the audited set.

*Resume recipe (in order of decisiveness):*
1. **Amiberry write-watchpoint** — phys is deterministic per build: boot unix-040-dbg
   (-23), log pte from the SEGVCTX line of a crash run, then re-boot, BEFORE amixadm open
   the debugger and `w 1 <physpage+CC0> 4 w 4AFC0000` (or without the value filter), `g`,
   run amixadm → the breaking PC names the writer. If it never fires but the crash comes,
   the write predates login → set the watch progressively earlier.
2. Static hunt (a): disassemble every pagein/segmap/buffer path that computes an identity
   VA from a pfn/pp (INLINE copies of pfntokv/page_pptonum — search for `/60`(divsll #60)
   + shift patterns kernel-wide) and check the shift is 12 and the base handles the
   0x07000000/0x08000000 two-bank pool.
3. The probe arsenal stays in the dbg build (SEGVCTX/DMP/PP in sigkill_dbg.s, PGALIAS in
   hatalloc_dbg.s, VTOPALIAS in vtop040.s — all capped, near-zero noise). Any future
   corruption fault auto-documents itself in serial.

*Priority note:* amixadm itself is a sysadmin menu (workaroundable); the underlying
corruption class is the real concern — but it has ONLY ever manifested on this one
binary's heap geometry so far. Normal workloads (boot, login, NetHack, ls -alR, reboot
cycles) are unaffected. Severity: medium, deferred.

**ISSUE-11 FIXED (2026-07-10, builds 260710-24/-25/-26; emulator-inert, real-HW verify
pending):** wb040_replay now realigns WB1D per the NetBSD recipe (off=(wb1a&3)*8; LONG
rol off / WORD rol (off+16)%32 / BYTE >>(24-off)) before the byte-wise replay, and skips
SIZE=LINE WB2 writebacks (MOVE16 residue, Linux does the same). Both paths are unreachable
on the emulators (WB1S/WB2S never valid there), so emulator boots exercise nothing new;
first real-040 boot is the actual test.

## ISSUE-12: A2065 ethernet dead on real-HW 040 AMIX (ifconfig -a empty, no ping)

**Status: RESOLVED — FALSE ALARM (2026-07-11). A2065 networking WORKS on real-HW
040 AMIX (build 260711-02): remote telnet login to the real machine succeeded,
`ifconfig aen0` shows UP with the correct address, and interactive sessions work
over the wire. The "network access to the real machine" goal is ACHIEVED.**

Post-mortem — why the false diagnosis happened:
- **`ifconfig -a` is a silent no-op on AMIX SVR4** (unsupported option, prints
  nothing, exits 0). It prints nothing on a fully working system too — verified
  on the emulator. The original "ifconfig -a empty" observation carried zero
  information. The correct query is `ifconfig aen0` (interface name is aen0).
- The original "no ping" was most likely transient operator/test error during
  the first excited real-HW login session (user's own suspicion too).

Useful facts established while investigating (kept for reference):
- The aen driver (`amix-src/sys/amiga/driver/aen/aen.c`) does NO host-memory
  DMA: the Lance init block, rx/tx rings and all packet buffers live in the
  board's own RAM at `board_base+0x8000`, addressed by 16-bit board-relative
  offsets. No pfn/ctob/btoc math anywhere — the driver is inherently immune to
  Model-B pfn bugs.
- Boot-time bring-up chain is `/etc/inet/network-config`:
  `aen -S && slink addaen /dev/aen0 aen0 && ifconfig aen0 \`uname -n\` up
  -trailers` — fails silently if the board probe fails.
- Amiberry A2065 emulation (`a2065=slirp`) works with the 040 kernel: aen0
  configures, ping to the slirp gateway 10.0.2.2 works. Inbound host->guest
  needs `slirp_redir=tcp:<hostport>:<guestport>` and guest IP exactly
  10.0.2.15 (slirp's hardcoded redirect target).

**ISSUE-10 real-HW datapoint (2026-07-11):** the amixadm flood reproduces on the REAL
Amiga 3000 + Mercury 68040 (build 260711-02) with the IDENTICAL signature: `User BUS
ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:184 CMD:amixadm` — same beyond-brk garbage
link 4AFC0003, same faulting PC as both emulators. Consequences for the paused hunt:
(a) emulator-specific mechanisms are ruled out for good; (b) the corruption is fully
deterministic across three different machines given the same kernel layout, which
strengthens the "layout-deterministic wrong-phys write" picture; (c) the 68040-vs-68060
split remains a layout artifact, not a CPU mechanism. The resume recipe (write-watchpoint
+ pfntokv census) is unchanged and can now also be validated against real HW.

## ISSUE-13: kvseg fault robustness — NFS-copy panic + /dev/kmem fault recursion (real HW, 2026-07-12)

**Status (2026-07-12): CAPTURE 1 = FIXED + VERIFIED ON REAL HW (bp_map040, commit
4099f4e — see the "CAPTURE-1 FIXED" block at the end of this section). CAPTURE 2 =
OPEN, lower priority (crash(1M) /dev/kmem nested-fault storm: krnxmemflt_orig F_PWRITE
030-walk + k_trap landing-pad recursion window). Two captures, backtraces read from
photos (~/Lataukset/IMG_20260712_013119397.jpg = capture 1, IMG_20260712_103720403.jpg
= capture 2). Do NOT poke /dev/kmem on real HW until a serial cable is available (user
decision) — use Amiberry IPC READ_MEM on the emulator instead. Blocks below are in
investigation order; the last one is the resolution.**

**Capture 1 — the original panic (during user's NFS→local `cp`, concurrent
telnet load):** `DBG as_fault FAIL pid=384 addr=40326000 type=0 rw=1
ret=FFFFFFFF` → `PANIC: KERNEL FAULT psw=0x2000 pc=0x080002E8 fmt=0x7 vec=0x2`.
Full symbol-resolved chain (nm on build/unix-040-dbg, kernel = 260711-02):

```
read → rw → rdwr → nfs_read → nfs_rdwr → rwvp → uiomove → copyout
  → (fault on segkmap window = NORMAL) → k_trap → krnxmemflt → as_fault
    → segmap_fault → nfs_getpage → pvn_getpages → nfs_getapage
      → nfs_strategy → do_bio → nfsread → rfscall → clnt_clts_kcallit(_addr)
        → xdr_replymsg → xdr_union → xdr_rdresult → xdr_bytes → xdr_opaque
          → xdrmblk_getbytes (bcopy at 0x2E8, READ of mblk source)
            → kernel fault @0x40326000 (kvseg proper, < 0x40440000 segkmap
              base) → as_fault ret -1 → krnlflt → PANIC
```

I.e. while decoding an NFS READ RPC reply, the mblk data pointer aimed at an
UNMAPPED kvseg VA. Streams buffers arrive via the A2065 `aen` driver path.

**Capture 2 — crash(1M) probe fallout (fresh boot, machine otherwise idle):**
`echo 'vtop 40326000' | crash` → user-mode /dev/kmem read of the same VA →
`u_trap → usrxmemflt` then a ~25-deep `k_trap → usrxmemflt` nested-fault
recursion eating the kernel stack → wild jump → `PANIC ... pc=0xC6
(chk_fpu+0x6) vec=0x4 Illegal Instruction`. Two robustness gaps confirmed:
(a) mmread (/dev/kmem) has no nofault guard on the 040 port — unmapped kernel
VA ⇒ fault storm instead of EFAULT; (b) unresolvable kernel faults in the
fault-handler path recurse (ISSUE-7 class) instead of failing fast.

**Key deduction from capture 2:** 0x40326000 is unmapped on a HEALTHY fresh
boot too — kvseg is a sparse window region. So capture 1's question is not
"who tore down the mapping" but **"why did an mblk point there"**: stale
buffer pointer (use-after-free in the streams/NFS reply path) or
ISSUE-10-class pointer/PTE corruption are the leading theories.

**Leads (see Codex audits, amix-kernel-analysis/vm-map/):** segmap_fault is
NOT byte-verified for Model B; hat_pteload locked different-PFN replacement
misses pt_keepcnt (segmap softlock is a hat_memload(lock=1) caller); no audit
of segkmem/kvseg fault handling exists yet; NFS/RFS putpage + pvn_range_dirty
still carry 2 KiB geometry (write side; capture 1 is the READ side though).

**Next steps (emulator):** (1) try to reproduce with heavy streams+disk load
(big ftp/rcp into emulator AMIX + concurrent local writes; true NFS mount via
slirp would be ideal); (2) capped dbg probes on allocb/freeb/esballoc pointer
ranges and/or segkmem_mapin/mapout; (3) harden mmread with a nofault guard
(cheap, independent fix); (4) consider a fail-fast depth guard in the
usrxmemflt/k_trap nested-fault path.

**ISSUE-13/ISSUE-10 load-repro run 1 (2026-07-12, emulator 040, build 260711-02):**
tftp-fetch loop (4MB × N via slirp/aen) + local cp+sync loop. After ~40 min /
~3900 forks: **sac (pid 158) self-killed via the rtld convention** (`DBG SIG sig=9
fu=1 uret=800038B6` — same family as the ISSUE-10 amixadm/sh flood), after which
EVERY subsequent exec hung (telnet login prompt appears, login never completes;
console silent; loads stalled mid-transfer). Working hypothesis: the ISSUE-10
corruptor hit a SHARED libc.so.1 page-cache page → every new exec dies/hangs in
rtld. If the same corruptor can hit an mblk pointer field, ISSUE-13's real-HW
stale-mblk panic is the same root cause's third face. Serial log preserved
(issue13-serial-run1.log in the session scratchpad). **Run 2 prepared: dbg build
260712-01 adds a sigkill_dbg v5 probe — on every rtld self-kill it dumps the dying
process's libc GOT/data probe words (C102FDE4/C102FE68/C102E000/C102EC00/C102F000)
→ directly shows whether the shared page is corrupt at kill time and what the
content is.** Also queued for Codex: static census of bio/pfn conversion sites
(the 1KB-granularity signature smells like buffer-cache writes through wrong
Model-B phys math).

**ISSUE-13 load-repro run 2 (2026-07-12, emulator 040, build 260712-01 = sigkill_dbg
v5):** did NOT reproduce the shared-libc corruption. Under the same load, after ~9 min
the machine WEDGED into the idle loop instead. State read live via Amiberry IPC
(READ_MEM against emulator RAM — no /dev/kmem risk; kernel phys base 0x08000000,
data syms are runtime-absolute):
- CPU pinned at `stop #8192` in the idle dispatcher (Lidw/before resume), psw=0x2000
  (IPL 0, interrupts enabled) — scheduler found no runnable proc; NOT a spin, NOT a
  panic. All user work blocked; a fresh telnet gets the login banner but login never
  completes; the tftp load stalled mid-file at block 7122.
- **Streams pool HEALTHY** (rules out buffer exhaustion): `mdbfreelist` non-empty,
  `strst+0x30` use=79 total=393238 max=82 **fail=0**.
- **The one SIG9 that fired was benign** (`sac -t 300`, its normal inactivity
  timeout, not an rtld self-kill) and the v5 GOT dump proved the shared libc page was
  **intact**: fde4=C101116E, fe68=C102E050, e000=C10314EC, ec00=C102EB0A,
  f000=9E9FA0A1 — all match libc.so.1's file bytes.
Conclusion: run 2's failure is a **network/streams delivery stall under sustained UDP
load** (A2065 `aen` receive path the prime suspect), NOT the memory corruptor. So the
two runs show two distinct load-induced failures; run 1's "everything execs die" may
itself have been this stall (all I/O-bound work blocks) rather than proven libc
corruption. Method note: Amiberry IPC `READ_MEM 0x<addr> <width>` (0x prefix required;
tab or space separators) is a clean live-RAM window into the emulated machine while
running — far safer than crash(1M)/dev/kmem, use it for all future live inspection.
Next: (a) treat the aen/streams receive stall as its own investigation (does plain
sustained tftp WITHOUT the fork load also stall? isolate network from fork/COW); (b) to
still chase the corruptor, a longer soak or a tighter allocb/freeb pointer-range probe.

**ISSUE-13 FIX IMPLEMENTED (2026-07-12, awaiting boot test): `prototypes/bp_map040.s`**
rewrites bp_map + bp_mapout for the live 040 tree. Both were stock 030 bodies
(Codex PAGEIO-BPMAPIN audit): 2 KiB counts, retired st_top1 tree (zero for syssegs
on the 040 port -> derives a zero leaf base -> stores pfn<<11|1 into LOW MEMORY),
pfn<<11. The override: 4 KiB counts, kptr040 walk (same geometry as vatosde/vatopte),
and the proven live kvseg leaf-PTE format `phys|0x19` (resident, supervisor-writable,
cacheable-writethrough, U/M preset -- read directly from live kptr040 leaves via
Amiberry IPC READ_MEM), keeping the stock ghost-mapping contract (no p_mapping /
ref-mod / keep-count bookkeeping, unlike segkmem_mapin). cpusha bc + pflusha after
the map/clear loop. Wired into relink-040.sh (both GLOBAL T -> plain --weaken-symbol;
bp_mapin re-resolves to the strong def). Built: unix-040 + unix-040-dbg (260712-03),
single strong def each (0xd97f4/0xd98a0), 0 reloc complaints, text/data contiguous,
.data 4-aligned. Encodings verified (divsll 4c41 0800, oril #0x19, cpusha f4f8,
pflusha f518). **NOT YET BOOT-TESTED.** Test plan: (1) emulator 040+060 regression =
login + hat_dup_cow 1/32/256 still pass (bp_map is on the page-I/O path; confirm no
normal-boot regression); (2) THE test = real-HW NFS->local copy that previously
panicked (ISSUE-13 capture 1) now completes. If (2) passes, ISSUE-13 capture 1 is
fixed; the krnxmemflt F_PWRITE 030-walk (capture 2 / crash(1M) recursion amplifier)
remains a separate, lower-priority follow-up.

**ISSUE-13 CAPTURE-1 FIXED — VERIFIED ON REAL HW (2026-07-12): bp_map040 works.**
Full verification of build 260712-03 (bp_map040.s):
- emulator 68040: hat_dup_cow 1/32/256 ALL PASS (no regression);
- emulator 68060: hat_dup_cow 1/32/256 ALL PASS (no regression);
- REAL A3000 + Mercury 68040: the NFS->local copy that previously PANICKED
  (capture 1) now completes and the machine survives. 5 consecutive copies of a
  3102720-byte file from the NFS mount (/mnt/nasu = nasu:Public) to local SCSI /tmp,
  every one byte-perfect (`sum` = 11920 6060 identical on NFS source and every local
  copy), machine stable throughout (uname still 68040-260712-03 after).
This proves bp_map now maps NFS page-I/O buffers into the LIVE 040 tree with correct
PFNs. The capture-1 root cause (bp_map/bp_mapout on the retired st_top1 tree) is
resolved. Remaining ISSUE-13 follow-up (lower priority, separate): capture-2's
krnxmemflt_orig F_PWRITE 030-walk (the crash(1M) nested-fault amplifier) + the
k_trap landing-pad recursion window. bp_map040 is ready to COMMIT (awaiting user go).
(Committed 4099f4e, 2026-07-12.)

**CAPTURE-2 PLAN UPGRADED (2026-07-13, Codex `040-FAULT-RESOLVER-AUDIT.md`):** the
fix is NOT just "port the F_PWRITE walk to vatopte". `krnxmemflt_orig` is a COUPLED
4-defect unit that must be ported together as a native kernel-resolver core:
1. the shared `ptest` probes user FC 1 / URP even for kernel VAs — user roots are
   deliberately empty of kernel entries, so a kernel VA always reports I(nvalid)
   and resident write-protection is invisible;
2. the rw decode reads the 030 SSW field `frame+72` bit 6 (040: an EA bit; 060: a
   fault-address bit) — **rw can be wrong already on the ordinary I branch** and
   flows through as_fault → segmap_fault → VOP_GETPAGE;
3. the second write-protection gate `0x5b216` also reads `frame+72` (ignores the
   wrapper's corrected/synthesized `frame+76`);
4. the admitted leaf walk `0x5b22a..4a` is the stock 030 `*(sde+4)` + `>>11` walk.
Partial fixes are UNSAFE: fixing only the walk keeps wrong status+rw; fixing only
the status probe newly EXPOSES the broken walk. Do NOT make the global `ptest`
supervisor-FC (breaks the working user COW path) — a separate kernel probe is
needed. Full port spec + acceptance table: Codex `040-FAULT-RESOLVER-AUDIT.md`
("Required structural boundary" + "Port and test order"). Bonus finding fixed in
passing 2026-07-13: the base kernel previously lacked the crossing-page `hardbus`
(runtime040.s promotion, see RESUME-HERE.md).

**CAPTURE-2 FIXED — VERIFIED ON EMULATOR 040+060 (2026-07-13, commit cfa5e49):**
`prototypes/krnxmemflt040.s` implements the native resolver core per the spec above
(validated software walk of the live kernel tree instead of the URP-blind ptest;
rw + protection gate from the synthesized frame+76 SSW; every non-classifiable
case degrades to the stock-compatible F_INVAL attempt; depth-4 nested-fault
fail-fast). The wb040.s wrapper is unchanged — its `krnxmemflt_orig` call binds to
the new core; stock body kept as `krnxmemflt_stock`. Build line 260713-02/-03/-04.
Verified: emu-040 AND emu-060 boot→login, hat_dup_cow 1/32/256 ALL PASS on both,
and the capture-2 mechanism itself — `dd if=/dev/kmem` of the unmapped sparse
kvseg VA `0x40326000` (4 B and 16 KB) — now returns a clean "No such device or
address" with the machine alive on both CPUs (previously a ~25-deep nested-fault
storm → wild-jump panic); `echo 'vtop 40326000' | crash` also survives.
REMAINING: (a) real-HW re-run of the original crash(1M) repro on the next HW
visit; (b) the F_PROT branch (write to a write-protected resident kernel page)
is untestable from userland and remains exercised-by-inspection only.

## ISSUE-14: emulator root-fs s5 inconsistency — shutdown PANIC "free: freeing free frag" (datapoint 2026-07-13)

**OPEN — evidence datapoint, cause unattributed.** During a normal `shutdown` on the
emulator (dbg build 260712-03 line, after a long probe/load session), the final
unmount/sync phase printed three `NOTICE: mode = 0, ino = <129025/129026/126908>,
fs = /` lines and then **`PANIC: free: freeing free frag, dev = 0x480016, block = 47,
fs = /`** (**UFS** `free()` detected a double-free of a FRAGMENT — see the root-fs
geometry block below: the root is UFS, fragments are 1 KiB; screenshot
~/Kuvat/Kuvakaappaukset/Kuvakaappaus - 2026-07-13 00-06-51.png, backtrace on screen).
Notable: the sigkill_dbg v5 GOT dump fired during the same shutdown and showed the
shared libc page INTACT (fde4=C101116E, fe68=C102E050 = expected values).
Two candidate explanations, in Occam order: (a) **latent root-fs metadata damage** —
this disk has survived dozens of kernel panics; mode-0 inodes + a doubly-free frag
are classic residue that fsck's automatic pass may never have fully repaired;
(b) a live wrong-page/metadata write from the **unconverted pageout/writeback group**
or the ISSUE-10 corruptor family. Next cheap steps: run a MANUAL full `fsck` on the
emulator root (not just the boot-time auto pass) and note what it repairs; if the
panic recurs on a verified-clean fs, promote this to an active corruption lead.

**DATAPOINT 2026-07-15 (writeback conversion landed, `patch_writeback.py`):** with the
FULL pageout/writeback Model-B group converted, a clean `shutdown -y -g0 -i6` on
emu-060 (golden image; session load = hat_dup_cow 1/32 + 4 MiB cp/sync/sum) completed
with **NO freeing-free-frag panic**, and the reboot ran only `fsck -m` (fs clean — no
repairs). On emu-040 the same build survived an UNCLEAN kill (hard emulator restart
after a pressure-test wedge) → boot-time `fsck -y` repaired and both 4 MiB test files
read back byte-perfect (`sum` 1570 8192). Consistent with explanation (b) being the
unconverted writeback group; not yet proof — needs recurrence-watching across future
shutdown cycles.

## ROOT-FS GEOMETRY (measured 2026-07-15) — the writeback Phase-0 answer

**The root filesystem is UFS, NOT s5.** Measured directly from the golden emulator
image (`amix_hardfileX11R5-net.hdf`, RDB partition `UNIX_Root` @ byte 65536, UFS
superblock at +8192, magic `0x011954`) and confirmed on the running guest
(`df -n` → `/ : ufs`; `/etc/vfstab` → `/dev/dsk/c6d0s1 / ufs`):

```
fs_bsize = 8192      filesystem block size
fs_fsize = 1024      fragment size
fs_frag  = 8         frags per block (8192/1024, self-consistent)
partitions: UNIX_Root 850 MiB | UNIX_Swap 100 MiB | UNIX_Boot 2 MiB | Extra 48 MiB
```

**s5 is not mounted anywhere on this system** — the only real fs is the UFS root
(/proc and /dev/fd are pseudo-filesystems).

Consequences (these CORRECT several older working assumptions):
1. **Phase-0 for the writeback conversion is answered.** Codex's recommended policy
   ("keep the provider shape, require `fs_bsize >= 2048`") is satisfied with a wide
   margin by 8192. No provider rewrite is needed, and no 1 KiB-UFS support question
   arises. `fs_bsize 8192 > PAGESIZE 4096` means one VM page lies WITHIN a single fs
   block — the easiest case for the conversion.
2. **The s5 `S5MAXREQ=4` / 512-byte-block hazard is NOT on any live path.** s5putpage
   may be converted for completeness or simply guarded to reject 512 B; either way it
   does not block the group.
3. `fs_bsize 8192 == MAXBSIZE == the segmap slot size (0x2000)`: one UFS block = one
   segmap slot = two 4 KiB pages.
4. **ISSUE-10's "1 KiB granularity" signature is the UFS FRAGMENT size, not an s5 1 K
   block.** The corrupt anon page whose content matched a recently-read disk block at
   1 KiB granularity was matching exactly one UFS fragment → focus that hunt on the
   UFS read/write path.
5. **ISSUE-14's "freeing free frag" is UFS fragment accounting** (corrected above).

NOT yet verified: the REAL A3000's disk geometry (machine was powered off on
2026-07-15). It is very likely the same AMIX X11R5 install lineage, but confirm with
`df -n` + the UFS superblock on the next hardware visit BEFORE trusting the conversion
there.

## ISSUE-15: KMA pool builders double-map their backing — ✅ FIXED (2026-07-25, emu-040+060)

**RATKAISTU `prototypes/patch_kmapools.py` (26 sitea), buildit 260725-01/-02.**
`SMALLCLICKS = btoc(4096)` ja `BIGCLICKS = btoc(16384)` ovat compile-time-vakioita
(`svr4-src-3b2/.../os/kma.c:67-70`) → 030:llä 2/8, Model-B:ssä **1/4**. Muunnetut:
`kmem_allocspool` (8 sitea), `kmem_allocbpool` (9, ml. `kmem_alloc`-failure-polun
`sptfree`), `kmem_freepool` (8, molemmat haarat symmetrisesti) — ja **lisäksi
`kmem_avail` @0x42d7a**, jota Codexin KMA-taulukossa EI ollut: se laski
`ptob(availrmem - t_minarmem)` shiftillä 11 eli raportoi **puolet** todellisista
tavuista STREAMS `bufcall`-vastapaineelle.
EI muutettu (puskuri-/hash-vakioita): `SMALLBYTES` 4096, `BIGBYTES` 16384,
`MAXASMALL` 256, `MAXABIG` 4096, bitmapkoot, `HASH`-shift 14, kmeminfon
tavukirjanpito. `kmem_alloc`/`kmem_free` >4096-polut olivat jo muunnetut
(`patch_modelb.py:606-610`) eikä niihin koskettu.
Todistettu lähteestä että puolitus on turvallinen: molemmat bitmapit ovat tarkalleen
mitoitettuja (`BIGBYTES/MAXBIG` = 1 long = 4 B = varatut 4 B; `SMALLBYTES/MAXSMALL`
= 16 longia = 64 B) ja hallittu alue päättyy **tasan** mäppäyksen loppuun (pieni
1×4096, iso 4×4096) → tuplamäppäys poistuu ILMAN että käytettävissä oleva KMA-muisti
pienenee tavuakaan.
Emu-hyväksyntä (040 + 060): boot multiuseriin (~22 prosessia), telnet-login,
60× fork/exec-churn, ei panikkia. ⚠️ Kvantitatiivista sivumäärädeltaa EI mitattu
runtimessa (`sar`/`sadc` ei toimi relinkattua ET_REL-kerneliä vasten) — alloc/free-
symmetria on todistettu vain staattisesti. Evidenssi
`test-tools/modelb-tail-emu-verify-260725.txt`. Ks. myös **ISSUE-29**.

## ISSUE-16: RFS client cache 2 KiB page geometry — OPEN, ja se on 72 sitea, EI 5

**OPEN — aidot Model-B-bugit, dormantteja koska RFS:ää ei käytetä.**
Codexin `BIO-PFN-PHYS-KVA-CENSUS.md` listaa **5 PFN-konversiota** (`rfesb_fbread`
0x8f56c, `rfc_readend` 0xa102c, `rfc_plmove` 0xa11ba, `rfc_writefill` 0xa1322,
`rfc_readfill` 0xa1bd0): oikea sivudeskriptorijako mutta `PFN<<11`-tavuosoitteet →
luku/kirjoitus VÄÄRÄLLE fyysiselle sivulle kun RFS-client-cache on aktiivinen.
**KORJAUS TIIVISTELMÄÄN (census 2026-07-25, build/unix-040):** todellinen 2 KiB
-sivugeometria RFS/DUsys-alueella 0x8f4f0..0xa3900 on **72 sitea 27 funktiossa**
(kuvio `#2047`/`#2048`/`#-2048`/`moveq #11`) — täysi per-funktio-erittely
`test-tools/modelb-tail-emu-verify-260725.txt`:ssä. Mukana mm. `rfc_plmove` 7,
`rfcl_esbwrmsg` 6, `rfc_readend`/`rfc_writefill`/`rfc_readfill`/`rfcl_write_op` 5 kpl
kukin, sekä koko `rfsr_*`/`dusr_*`/`du_fcntl*`-perhe. Census on TARKOITUKSELLA
LUOKITTELEMATON: osa `#2048`-vakioista on varmasti viesti-/puskurikokoja eikä
sivugeometriaa, ja juuri se luokittelu on se työ jota ei saa ohittaa.
**EI muunneta sokkona:** RFS-polkua ei voi ajaa emussa eikä raudalla, joten 72 siten
muuntaminen olisi latentin bugin istuttamista ilman havaitsemiskeinoa.
**STATUS: RFS-testaus 040/060-portilla on EPÄTURVALLISTA.** Lykätty, ei korjattu.

## ISSUE-17: procfs prfastmapin/prfastmapout — ✅ FIXED (2026-07-25); oli KERNEL-PANIKKI

**RATKAISTU. Ja se oli PALJON pahempi kuin kirjattu "väärä page_t".**
Aiempi tiivistelmä sanoi "can hold/release/abort the wrong page_t". Todellisuudessa
**mikä tahansa /proc-prosessimuistin käyttö panikoi kernelin.** Todistettu
negatiivisella kontrollilla (`test-tools/proctest.c` korjaamattomalla 260724-04:llä):

```
PANIC: KERNEL FAULT psw=0x2400, pc=0x8063504, fmt=0x7, vector=0x2 (Bus Error)
```
`pc 0x8063504` = teksti 0x63504 = **stock `prfastmapin`in sisällä** (0x63484..0x63590),
kohdassa `btst #0,%a2@(3)` = PTE-dereferenssi kuolleen 030 SDE-kävelyn jälkeen;
`psw=0x2400` on tismalleen `prfastmapin`in oma `splhi` (0x63492). Ennen panikkia
/proc palautti **hiljaa väärää dataa** (4080/4096 tavua väärin).
**Juurisyy:** `hat_alloc` (hat040.s:1211) tallettaa **040-root-taulun VA:n** kohtaan
`as@(20)`, ja stock `prfastmapin` lukee sen 8-tavuisten 030-SDE:iden taulukkona
(0x634ba `moveal %a0@(4,%d0:l:8),%a0`) → villi pointteri. Immediate-patchaus ei
olisi auttanut: rakenne on väärä, ei vain shiftit.
**KORJAUS:** `prototypes/prfastmap040.s` = uusi `uvatopte040` (040 per-proc
root→ptr→leaf-kävely, UDT/PDT-tarkistus JOKA tasolla ennen seuraavaa dereferenssiä) +
`prfastmapin`-override (`--weaken-symbol`, siirtyi 0x63484 → 0xd97f0). Lisäksi
kovennus stockiin verrattuna: hallitsemattomalle PFN:lle stock teki `pp = NULL` ja
sitten silti `addqw #1,%a0@(2)` = kirjoitus osoitteeseen 2 → bus error; me
kieltäydymme nopeasta polusta ja `prusrio` ottaa `as_fault`+`prmapin`-reitin.
`prfastmapout` EI tarvinnut overridea — sen ainoa vika oli `phys>>PNUMSHFT`
(11 sitea) → `patch_procio.py`. Samassa yksikössä muunnettiin **`prusrio`
kokonaisena joukkona** (0x64580 PAGEMASK, 0x64586 nextpage, 0x645d8/0x6467a
`as_fault`-pituudet) — `patch_modelb.py:583-591` dokumentoi että VAIN pituuksien
flippaus jumitti bootin 2026-07-03 (overlapping softlocks).
**Hyväksyntä:** `proctest.c` T1–T7 + molemmat lapsen kirjoitustarkistukset PASS
emu-040 **ja** emu-060 (260725-04); korjaamattomalla panikki. Buildit 260725-03/-04.
Evidenssi `test-tools/modelb-tail-emu-verify-260725.txt`.

## ISSUE-18: vtop user-VA walker — ✅ (a) FIXED, (b) hardened + mitattu no-op (2026-07-25)

**(a) RATKAISTU.** `vtop_orig` 0xb7568:n proc-haara (stock 2 KiB indeksit/maskit,
`PFN<<11`, 0x7ff) ohitetaan nyt kokonaan käyttäjä-VA:lle: `vtop040.s` reitittää sen
uuteen `uvatopte040`-kävelijään. Tämä on `prmapin`in (0x63462 = `vtop(addr, p)`) polku
eli /proc:n hidas reitti — sama korjaus kattaa siis ISSUE-17:n fallbackin.
**(b) KOVENNETTU, ja mittaus sanoo että se on no-op.** Dispatch tehtiin
**proc-VIIMEISENÄ** tarkoituksella, jotta JOKAINEN `proc==0` -polku säilyy ennallaan.
Syy löytyi suunnittelussa: **`mmmmap` (0x2067e) kutsuu `vtop(addr, 0)`** /dev/memille,
ja Amigalla se osoite ulottuu laillisesti 0x80000000+ (Zorro III) — pelkkä
osoiteperustainen "user"-luokittelu olisi rikkonut /dev/memin korkealle fyysiselle
tilalle, koska stock `svirtophys` palauttaa ei-SCN1-osoitteen muuttumattomana
(0xb7744). Binääristä varmistettiin myös: **`startio` (0xc100) VÄLITTÄÄ `bp->b_proc`**
ja **`dma_pageio` (0x20c90) KOPIOI `b_proc`in** bounce-puskuriin
(`amiga_dma_pageio` 0xdbee sen sijaan nollaa sen) → proc-ENSIN-dispatch olisi
rikkonut levy-DMA:n. Nyt: `proc!=0` + SCN1 → pakotettu `proc=0` → `svirtophys`, ja
capattu diagnostiikka (`Lvt_viol`, cap 8) **ei laukennut kertaakaan** yhdessäkään
ajossa (boot/login/churn/proctest, molemmat CPU:t) → vanhentunut-`b_proc`-muoto ei
esiinny käytännössä tässä kokoonpanossa.
Yhä dormantit väärät apurit (ei sisääntulevia kutsuja, ÄLÄ käytä): `pptophys` 0xb1570
(`PFN<<11`), `phystopp` 0xb1532 (`>>11`), `uvirtophys` 0xb7860 (odottaa &SDE + 2 KiB).

## ISSUE-19: context-switch residual edges (szombflag overwrite; resume path-U partial p_ubptbl)

**OPEN — statically possible, never reproduced (Codex `PROCESS-MMU-CONTEXT-SWITCH-CONTRACT.md`).**
(a) `szombflag` is a SINGLE pointer and `swtch` is the only `segu_release` caller: if
a zombie switches directly to a never-dispatched child (which resumes via procdup's
context, skipping the zombie-cleanup block) and that child itself exits before any
normal `swtch` resume runs, the second zombie overwrites the pending pointer and the
first u-area LEAKS. TS-class `ts_forkret` (child-runs-first) closes this in practice;
RT/SYS fork policies do not. (b) native `resume` path U validates `p_ubptbl[0]` but
not `[2]` -> a half-built compat table would produce a second fixed-u PTE with frame
0; the `segu_ubptbl040` rebuild wrapper writes zeros on a missing PTE but does NOT
fail the segu_get/swapinub call. Both are hardening items on the (now base-linked)
runtime040.s resume + the segu wrappers; instrument only if a matching failure
signature ever appears.

**★★★ MEMWATCH-JAHTI 2026-07-18 (ba99d82+66c8cff) — CURRENT FRONTIER, supersedes the probe plans
above.** Added an IPC-driven silent memwatch to Amiberry (SET_MEMWATCH/GET_MEMWATCH_LOG; kernel-PC-only
ring, no halt; v2 also logs A1=dest / A0=src regs). Watching sh's data frame (phys 0x9E19000,
deterministic every boot; g_shdatabase runtime @ 0x08000000+.textsize+nm-offset): **timing NAILED,
reproduced 2x — zero kernel writes during the whole pressure run, then the write burst AND the crash in
the SAME 15 s window.** v2 flipped the picture: the writer is **COPYIN (user->kernel, PC 0x0800054A)
into a KERNEL kvseg buffer 0x404F2xxx** (content = sac/inetd config "inet/tcp/PM10/PM40") **whose
VA->phys translation resolves to sh's data frame** => a kvseg leaf PTE holds the WRONG PFN = KMA/STREAMS
buffer double-backing (ISSUE-5/6 family; Codex round-2 residual "KMA pool double-backing" now PRIME).
Evidence: test-tools/issue10-memwatch-{lcopyout,timing,copyin}-260718.txt. Also landed en route:
segvn fault-path Model-B conversion (11 sites, REAL bug, base 260717-05 — partial fix) and the
SEGVND/SEGVVN/PTLFILE0/HASHINMAP/LIVE-STALE probes (AT_PHDR page 0x80000000 + text base 0x80002000
identified as LEGIT off-0 homes). **NEXT: at hit time, walk the kvseg leaf for 0x404F2000 via IPC
READ_MEM (who mapped it, what pfn) + audit the kmem_alloc/sptalloc page-translation path.**

**★★★ ISSUE-10 PRODUCER FOUND AND FIXED 2026-07-18 EVE — hat_pageunload040 dropped the M bit:
dirty anon pages were freed WITHOUT their swap write (dirty-discard).** The kvseg-leaf walk
planned above was executed live (test-tools/kvwalk.py + IPC READ_MEM) and REFUTED the KMA
double-backing framing: VA 0x404F2000's leaf → pfn 0x9E19 was a LEGAL segmap window over a UFS
VREG page (p_vnode=ufs_vnodeops vnode, off 0x1E000, p_mapping = exactly the segmap leaf) — the
"copyin into a kernel buffer" was write(2) appending to a utmp/sac log file whose cache page had
LEGALLY been given sh's recycled data frame. The real question became: why was sh's DIRTY data
frame (GOT relocations written at exec) recycled with the swap partition BYTE-IDENTICAL to the
golden image (zero swap writes all boot)? Source proof (3b2 seg_vn.c segvn_swapout): pages reach
swapout ALREADY unloaded, hat_pagesync then finds an empty chain, and the decision is
`if (p_mod) VOP_PUTPAGE else page_free` — the whole dirty decision rests on the M bit harvested
AT UNLOAD TIME. Our hat_pageunload040 (hat040.s Lpu_loop) did a bare `clrl %a3@` with NO U/M
harvest into pp->p_ref/p_mod (hat_pagesync040 harvests correctly — its sticky p_mod explains the
few pages that DID reach swap). Dynamic confirmation on camera (mon8.py, pressure run 22:58):
memwatch caught PC 0x080D7C32 = Lpu_loop+0xe clearing the watched leaf during the steal; bus
errors 2→2723→6492→11568 while swap-diff-vs-golden PLATEAUED at 4 MB; serial showed the classic
`User BUS ERROR at 4AFC005F ... CMD:sh pressure.sh`; lcopyout (sigtoproc sigcontext push) was
observed writing to user stack VA 0xC011D03C whose translation hit the shared frame = live
double-use of a stack page and the utmp file page. Full chain + mechanism:
test-tools/issue10-dirtydiscard-260718.txt. FIX (build 260718-02 base / -03 dbg): U/M harvest
added to hat_pageunload040 before the invalidate (bit layout identical to hat_pagesync040).

Landed en route (same session): swapadd 2× slot over-allocation CONFIRMED LIVE (si_anon 51199
slots for a 25600-page 100 MiB partition; swapadd 0xb3242 `>>11` + 2K soff/eoff rounding
0xb3224/28 unconverted — xlate/anon already 4K ⇒ harmless below 25600 in-use slots, ani_max/
availsmem doubled, overflow past the partition if >100 MB ever swapped: patch as its own set).
hat_swapout audited statically: stock 030 body (030 PTE bit ops, >>11 leaf indices, 0x800 strides,
0x20000 table hops) running against the ptdat machinery — likely INERT on 040 (same class as
hat_pagesync's retired flush path) but MUST be audited: if it ever walks live 040 tables it
corrupts them. Golden image's swap area contains ARCHAEOLOGICAL 2K-placed page images (pre-xlate-
patch era) — do not mistake them for fresh evidence (bit us tonight; golden-vs-live diff settles it).

**★★ ISSUE-10 SWAP-IN-POLKU KORJATTU 2026-07-19 (Codex 7739bf6: SPEC-SWAPIN-HOT-PATH-AUDIT.md +
UM-BIT-LIFECYCLE-CENSUS.md).** The 260718-03 M-harvest made swap WRITES start; the avalanche then
moved to the first-ever-hot swap-IN path. Census of ALL klustsize readers (6 relocs: spec_getapage
×5 @0x66cc2/66e76/66e82/66eb8/66eca, spec_putpage ×1 @0x6733e; no writers): the decisive defect was
the compiled DATA initializer `int klustsize = 0x800` (.data+0x7c98) — spec_getapage read 2 KiB into
each freshly allocated 4 KiB page and EXPLICITLY ZEROED bytes 0x800..0xfff (destructive tail zero),
so every swapped-in anon page lost its upper half. FIX = `prototypes/patch_swapin.py` (in
relink-040.sh after the writeback group): klustsize data-init 0x800→0x1000 (resolved from the
symtab, old-byte-asserted) + the coordinated contract residuals from the same audit — spec_getpage
EOF allowance 0x6711a 0x7ff→0xfff, direct-provider gate 0x67186 0x800→0x1000, anon_getpage
VOP_GETPAGE len 0xad9a6 pea 0x800→0x1000, pvn_fail per-node step 0xb1a28 0x800→0x1000. With the
global at 0x1000 all six reader sites become source-correct (blkoff/blksz, read-ahead off2,
putpage offlo/offhi klustering); io_len&0xfff==0 skips the pagezero. **HYVÄKSYTTY EMULLA
2026-07-19 (build 260719-02): burst4 = 4×pressure ALLBURSTS-DONE, sum 1570 8192 ×6 joka
burstissa, 0 uutta bus-virhettä, swapdiff-vs-golden 0→5 MB, EI YHTÄKÄÄN 4AFC005F:ää —
vyöry kuollut; hat_dup_cow 64 RESULT PASS; implisiittiset anon-swap-roundtripit 4 kierrosta.
Matkalla 2 false alarmia = AMIX tftp:n NETASCII-oletusmoodi söi tavuja binääreistä (AINA
'binary' ennen get:iä!); burst-3:n näennäisjumi = laillista thrashia (live-diagnoosi:
practive/wchan-kävely + loaderin COMMON-allokoinnin simulaatio). Täysi kirjaus
test-tools/issue10-swapin-fix-260719.txt. JÄLJELLÄ: real-HW-verify.** Checked same pass:
swap_maxcontig (.data+0xb544 = 0x200) left alone — sole reader is swap_alloc's area-rotation
policy counter, a no-op with one swap area. ALSO FIXED (UM-census finding #2): hat_pteload::
Lreplace (hat040.s) now harvests the OLD PTE's U/M into old_pp before a different-PFN overwrite
(same block as the hat_pageunload harvest; done regardless of the reverse-map unlink outcome) —
was the one remaining unconditional HAT-side dirty-loss site.

**★ MODEL-B-JÄÄNNÖSRYHMÄT LANDATTU 2026-07-19-ilta (Codex-speksit, analyysirepo cbbf40f
vm-map/): kaikki 4 ryhmää emu-hyväksytty erikseen + yhdessä.** (1) swapadd-geometria
(1475e16, `patch_swapgeom.py`, 12 sitea / 5 funktiota — yllä oleva "patch as its own set"
-merkintä TEHTY; slottimäärä todistettu swapctl SC_LIST -probella `test-tools/swapls.c`:
PAGES 25600, ei 51199-tuplausta). (2) exec_initialstk+extractarg (7f8ac6e,
`patch_execstk.py`, 0x800→0x1000 symtab-resolvoitu + jaettu shift 11→12; hyväksyntä
`test-tools/bigargv.c` = 4500 B argv execin yli tavuntarkasti ×3). (3) pageout-oletukset
(7f36144, `patch_pageoutdefs.py`: lotsfree 128→64 / desfree 50→25 / minfree 16→8 =
dokumentoidut TAVUkynnykset 4K-sivuina + vmmeter UPIO-fold 2→1 nelänä nop:ina —
**burst4-thrash 8 min/bursti → 1,4 min/bursti**, freemem-129-jäätymä poissa). (4) mincore
(9c4139c, `patch_mincore.py`: btoc-vektori + PAGEOFFSET-portti @0x585e2, joka speksissä
jäi auki — varmistettu 3b2 grow.c:523:sta; hyväksyntä `test-tools/mincoretst.c`: tasan 8
vec-tavua + EINVAL 2K-kohdistuksesta). Buildit 260719-04…-15; joka ryhmällä hat_dup_cow
64 PASS, 0 bus-virhettä, 0 4AFC005F:ää. JÄLJELLÄ: real-HW-verify-delta (REALHW-VERIFY-tyyli).

## ISSUE-20: stock hat_swapout = MIINA jos prosessi-swapout koskaan palautetaan

**DEFERRED BY POLICY — do NOT fix, do NOT re-enable (Codex UM-BIT-LIFECYCLE-CENSUS.md +
HAT-SWAPOUT-AUDIT.md).** The linked `hat_swapout` 0xb4360 is the stock 030 body: 030 PTE bit
ops, >>11 leaf indices, 0x800 strides, 0x20000 table hops against the retired ptdat machinery,
and U/M-incorrect for the live 040 tree. It is currently UNREACHABLE: runtime040.s `sched` is a
deliberate swtch-only loop and never calls `swapout()` (the only static route is swapout →
as_swapout → hat_swapout). THE MINE: any future re-enabling of process swapout (restoring stock
sched or calling swapout directly) would run this body against live 040 tables — best case inert
030-tree reads, worst case corrupted live tables + silent dirty loss. Precondition for ever
re-enabling: a native hat_swapout040 (or an explicit no-op policy) + segu/u-area swap-out
validation. Until then sched STAYS overridden.

## ISSUE-21: satunnainen boot-musta-ruutu real-HW:llä (~1/4 booteista) — RATKAISTU (config-wrapper, IC-handoff)

**✅ RATKAISTU 2026-07-22 (config040.s cache-handoff-wrapper — self-contained, HW-verified 9/9):**
Juurisyy = 68040:n INSTRUCTION CACHE peritään AmigaOS/68040.library:ltä PÄÄLLÄ kernel-entryssä, ja
`config()`:n memcpy + pstart040:n bzero (ENNEN pstart040:n omaa 'D'-regiiminvaihtoa) ajavat likaisella/
periytyneellä IC:llä → satunnainen ILLEGAL@memcpy / ADDRERR@bzero. Loader-side copyit-CACR=0 EI jäänyt
voimaan (emu+HW: 'A':n CACR yhä 0x00008000). **FIX = kernel-side wrapper:** `patch_config_cachefix.py`
uudelleenkohdistaa `_start`:n ainoan `jsr config`-relokaation (.rela.text r_offset 0x26) →
`config_cachefix` (prototypes/config040.s), joka tekee `cinva ic` + `movec #0,cacr` (kaikki cachet pois)
ja tail-callaa oikean configin (`config_orig`=0x18f5c). Varhaiskoodi ajaa siis IC-off; pstart040 'D'
palauttaa IC:n (Step A / 2× nopeus säilyy). Loader-riippumaton (matkaa kernel-imagessa). **HW-VERIFIOINTI
(dbg -04 260722, evidenssi /tmp/amix-hw-cachetest4.log + reboot_loop.py 8 kierrosta):** 9/9 boottia
puhtaita — `K00000000` ×9 (wrapperin CACR-takaisinluku=0), `AC00000000` ×9 (pstart 'A' CACR=0 = nolla
säilyi wrapperista 'A':han), `FLT v00007008` ×9 (kaikki OK-init, 0× ILLEGAL/ADDRERR). Vrt. ilman
wrapperia IC-only (CACR=0x00008000) kaatui satunnaisesti parissa bootissa. **Ei enää tarvetta `cpu
nocache`-workaroundille.** Landattu commit 6c8a929; wrapper base+quiet+dbg (K-dumppi flag-gated dbg-only).
IMPLIKAATIO DC-tavoitteelle: ongelma oli nimenomaan IC-handoff, EI copyback-DC — B1/B2-kampanjan
varhaisbootin herkkyys poistui (peritty IC hoidettu). Alla oleva tutkimushistoria säilytetty.

---


**PÄIVITYS 2026-07-20 (btrace-lokalisointi + FLT-työkalu):** Lisättiin flag-gated
varhainen boot-trace (`prototypes/btrace.s`, vaihemerkit A–H/S/s/P; commit 235018a) ja
one-shot FIRST-FAULT-latch (`prototypes/ktrap_latch.s` FLT-lohko, commit 8d4e1ee).
Kaappaus dbg -11:llä (evidenssi /tmp/amix-hw-a3091-dbg*.log): epäonnistuva boot tulostaa
**`A`** (kernel entry) → heti fault → stock kstack-rekursio (`kstack 0x080DCxxx`, askel
0xBC=188 B). 'k'-virta = katkenneet kstack-rivit. **Fault on 'A':n ja 'B':n VÄLISSÄ =
varhaisin 030-taulunrakennus, MMU POIS PÄÄLTÄ, koodi IDENTTINEN -13:n kanssa** → EI CM-B1/
DMA-regressio (ne ajetaan vasta C:stä eteenpäin). Tilariippuvuus: jam säilyy lämminresetin
yli, ~2 min virrat pois palauttaa (→ marginaalinen rautatila -hypoteesi, EI deterministinen
ohjelmisto). Aiempi LATCH1 näytti fault-osoitteeksi pino-osoitteen (0x080DC830) → epäily:
ajoittainen bus-error fyysisellä RAMilla ~0x080DCxxx (proc-0 kernel-pino). **SEURAAVA
DATA: FLT-rivi epäonnistuvalta bootilta** (`FLT v<fmtvec> p<PC> a<fault-osoite>`): jos
a≈0x080DCxxx → varmistaa RAM/väylä tuolla alueella (rauta); onnistuvan bootin FLT =
normaali init-fault (v00007008 p080005C6 a80800000). Emu boottaa AINA puhtaasti (deterministinen
malli, ei marginaalia). Työkalut standardina dbg-buildissa.

**PÄIVITYS 2026-07-21 (FLT-ajo ~15 boottia dbg -11, evidenssi /tmp/amix-hw-a3091-dbg-latch.log):**
KOLME signatuuria (`_start` → `jsr config` → `jsr pstart040` (='A') → `jsr main`):
- **ILLEGAL @ memcpy 0x080002E4** (`v00000010`), EI 'A':ta edellä → fault `config()`:ssä ENNEN
  pstart040:ää.
- **ADDRERR @ bzero 0x0800033E** (`v0000200C`), 'A' AINA edellä → fault pstart040:n taulunrakennuksen
  bzero-kutsuissa (st_top1/u-area), 'A':n jälkeen ennen 'B':tä.
- **ACCESS-OK @ 0x080005C2 a=0x80800000** (`v00007008`) = NORMAALI init-text-demand-fault =
  onnistuva boot (koko `ABCDEFSsGH` + login).
Jakauma 15 bootilla: 5×ILLEGAL, 6×ADDRERR, 4×OK. Sekvenssi `IDIDODIOIDOIDDO` = ~50/50, EI tiukka
vuorottelu (vain ensimmäiset 4 alternoivat → sampling-harha). Kaksi moodia selittyvät kahdella
raskaalla varhaisella muistioperaatiolla (config-memcpy, pstart-bzero): marginaali pulpahtaa
kumpaan tahansa kuumaan sisäsilmukkaan osuu ensin. **fault-`a`-kenttä ILLEGAL/ADDRERR-kehyksissä on
roskaa (lyhyempi kehys, +84 kehyksen ohi); vain PC + vektori luotettavia.**

**LEVY/ZuluSCSI POISSULJETTU:** `image checksum = 30add799` IDENTTINEN kaikilla 15 bootilla →
ladattu kernel bitilleen sama joka kerta (levyluvun korruptio muuttaisi checksumia). Sama oikea
image RAMissa myös 11 kaatuneella → **ei-deterministinen fault latauksen JÄLKEEN.** Levy, ZuluSCSI,
image ja OHJELMISTO poissuljettu (fault stock-memcpy/bzero:ssa ennen mitään CM-B1/DMA-koodia,
todistetusti oikeassa imagessa). **Johtopäätös: rauta CPU↔RAM-polulla latauksen jälkeen** —
todennäköisin RAM-marginaali, mutta 040/Mercury-CPU, muistiväylä/RAMSEY tai PSU mahdollisia.

**JATKOTESTIT (rautapuoli, odottaa käyttäjää):** (1) vanha -14-kernel tiheystesti (erottaa
muutokset vs baseline; katso nouseeko rate session aikana = rauta oikuttelee ajallisesti);
(2) **stock-030 Mercury-030-fallbackilla** — Mercury-RAM SÄILYY käytössä 030-tilassa (käyttäjän
tieto), joten tämä ajaa SAMAA RAMia 030-nopeudella → puhdas CPU-vs-RAM-erottelu (RAM vakiona):
030 vakaa → 040-CPU/040-nopeus-marginaali; 030 myös oikuttelee → RAM/väylä. Varaus: 030 hitaampi/ei
burstia → ei täysin puhdista RAMia 040-nopeudella; (3) DiagROM / Mercuryn memtest Mercury PÄÄLLÄ =
suora RAM-testi 040-nopeudella 0x08000000+. mem-pankit: mem[0] 0x08000000-0x09000000 (kernel tänne),
mem[1] 0x07000000-0x08000000, mem[2] chip. FLT-tavudumppi-laajennus (RAM-sisältö vs CPU-glitch)
pidetään varalla jos tarvitaan vielä ohjelmistodatapiste.

**PÄIVITYS 2026-07-21 (muistitestit puhtaat → CACHE-HANDOFF-FIX-hypoteesi + korjausehdokas):**
Kolme muistitesteriä PUHTAAT, myös kernel-alue: AmigaTestKit ~9.5 kierrosta 0 virhettä (48 MB fast),
Mercuryn oma testeri kaikki 8 SIMMiä (U505–U512) vihreä Passed, DiagROM `$07000000–$09FFFFFF` 0 errors
(jäätyy loop-lopussa = tunnettu/vaaraton). RAM-piirit siis käytännössä poissuljettu → "marginaali-RAM"
heikkenee. **Painavin johtolanka nyt: emu ei kaadu KOSKAAN, ja Amiberry EI mallinna 040:n copyback-DC:tä**
(CACHES-ON-PLAYBOOK) → vika osoittaa perittyyn cache-tilaan. HYPOTEESI: kernel perii AmigaOS/68040.library:n
IC+copyback-DC:n entryssä; `unix_boot/copyit` disabloi vain MMU:n muttei CACR:ää, ja kernel asettaa oman
regiiminsä (pstart040 IC-on) vasta config()/pstart-bzeron JÄLKEEN → varhaiskoodi ajaa perityllä copyback-DC:llä
→ ajoitusriippuvainen koherenssifault (satunnainen ✓, emu-clean ✓, memtest-clean ✓, kuumissa memcpy/bzero-
silmukoissa ✓, myös -13:ssa = ei regressio ✓, Workbench-OK = handoff-ongelma ✓). **KORJAUSEHDOKAS (commit,
odottaa HW-testiä): `unix_boot/src/copyit.s` flush040 → `moveq #0,d0; movec d0,cacr` (CACR=0, kaikki cachet
pois) heti cpusha bc:n jälkeen ennen kerneliin hyppäämistä.** Kernel ajaa varhaiskoodin caches-off (kuten
stock-030-regiimi), pstart040 laittaa IC:n takaisin 'D':ssä. Emu-040 SANITY: uusi loader boottaa puhtaasti
(ABCDEFSsGH + normaali FLT v7008 + 197 WARNING-riviä), ei regressiota (emu ei voi validoida itse korjausta,
koska ei mallinna copyback-DC:tä). HW-testi: deployaa uusi `unix_boot040` (NAS modelb-b/), boottaa SAMA dbg -11
useita kertoja → jos ILLEGAL/ADDRERR-faultit katoavat = hypoteesi vahvistettu (mahdollinen KORJAUS); FLT jää
paikoilleen näyttämään jos vielä faulttaa. Loaderin toolchain: LOCAL-BUILD-NOTES §3 (amiga-gcc, make CC=m68k-amigaos-gcc).

**PÄIVITYS 2026-07-21 ilta (RATKAISEVA — cache/burst vahvistettu syyksi):** (1) copyit-CACR=0-fix
EI auttanut raudalla. (2) Käyttäjä lisäsi startup-sequenceen **`cpu nocache`** (AmigaOS-tason cache- JA
burst-disable ENNEN unix_boottia) → **automatisoitu reboot-survival-testi 15/15 selvisi** (evidenssi
test-tools/issue21-nocache-reboot15-260721.txt; ajuri durable-tools/reboot_loop.py `reboot`-komennolla,
EI init 6). Vrt. ilman nocachea FLT-ajossa ~4/15 OK. **Johtopäätös: intermittentti boot-fault johtuu
040:n CACHE/BURST-tilasta varhaisessa kernel-suorituksessa** (config()/pstart-bzero ennen pstart040:n
omaa regiimiä 'D'). Poissuljettu lopullisesti: RAM-piirit (3 testeriä puhtaat), levy (checksum vakio),
CM-B1/DMA-koodi (fault ennen sitä, stock-koodissa). **`cpu nocache` startup-sequencessa = validoitu
WORKAROUND** (kone bootaa+ajaa luotettavasti). AVOIN: miksi `cpu nocache` toimi mutta copyit-CACR=0 ei
(molempien pitäisi ajaa varhaiskoodi cache-off; ero todennäk. BURST — cpu nocache disabloi burstin, ja/tai
copyit-loaderia ei tosiasiassa käytetty). SELVITETTÄVÄ itsenäistä fixiä varten: dumppaa peritty CACR
(+RAMSEY burst) kernel-entryssä, vertaa nocache vs ei → replikoi cpu nocachen tekemä tarkasti (burst mukaan).
**IMPLIKAATIO DATA-CACHE-TAVOITTEELLE:** tämä on aito herkkyys 040-copyback-DC:lle/burstille varhaisbootissa
— B2 (copyback DC kaikkialla) osuisi samaan laajemmin; B1 (writethrough) ehkä turvallisempi. IC (Step A) on
päällä ja toimii bootin jälkeen, joten burst EI ole universaalisti rikki — ongelma on nimenomaan peritty
copyback-DC/varhaisikkuna. Selvitettävä ennen DC-käyttöönottoa.

**PÄIVITYS 2026-07-22 (RATKAISEVA: syyllinen on INSTRUCTION CACHE, EI data cache):** CACR/RAMSEY-dumppi
lisätty pstart040 'A':han (btrace_hex; commit 7139bdc). Ristiin-OS-tieto (käyttäjä): AmigaOS/Debian/OpenBSD/
RedHat ajavat tällä Mercuryllä datacache päällä ongelmitta → rautahypoteesi kumoutui, kyse OHJELMISTO. Kokeet
(dbg -02, cpu-output SER:iin, evidenssi /tmp/amix-hw-cachetest*.log):
- cpu nocache: CACR=0x00000000 (IC off, DC off) → 15/15 reboot OK.
- IC-only (`INST: Cache Burst / DATA: NoCache NoBurst`): CACR=0x00008000 → boot1 OK, **boot2 ILLEGAL@memcpy
  KAATUI**. RAMSEY vakio 0x38.
- IC+DC (0x80008000): kaatuu ~11/15 (FLT-ajo).
**Yhteinen tekijä KAIKISSA kaatumisissa = IC PÄÄLLÄ; DC epäolennainen. Ainoa luotettava = IC POIS.** Syy siis
instruction cache AmigaOS→kernel-handoffin varhaisikkunassa (config/pstart-bzero ENNEN pstart040:n 'D':tä joka
tekee cinva ic + IC-enable). Step A (IC päällä) toimii bootin JÄLKEEN → ongelma on nimenomaan peritty/likainen
IC handoffissa, todennäk. IC-koherenssi copyitissä (juuri kopioitu koodi; muiden OS:ien loaderit hoitavat, AMIX
ei). **FIX-SUUNTA:** copyit-CACR=0 disabloi myös IC:n varhaisikkunassa → pitäisi olla TÄYDELLINEN korjaus
(varhainen IC-off → ei faultia, pstart040 'D' laittaa IC:n takaisin → Step A säilyy). cpu nocache todistaa
periaatteen. Avoin: copyit-fix "ei auttanut" → todennäk. deployment (emu näytti CACR=0x80008000 vaikka build-
loaderissa on CACR=0 → korjattua loaderia ei ajettu). TESTI: boottaa korjatulla unix_boot040:llä (ilman cpu
nocachea, AmigaOS IC päällä), lue 'A':n CACR — 0x00000000 = fix toimi (self-contained), 0x00008000 = ei deployattu.

**OPEN — kirjattu 2026-07-19, EI blokkaa käyttöä (uusi yritys korjaa lähes aina).** A3000 +
Mercury 040, unix_boot → kernel jää heti bootissa mustaan ruutuun ~kerran neljästä.
ENSIMMÄINEN serial-evidenssi (260719-02, 9600 baud; rivien alut osin merkkikadon syömiä):

```
kstack 0x80DCFF4! / 0x80DCF38! / 0x80DCE7C! ... 0x80DC89C!   (askel -0xBC = 188 B)
WARNING: DBG LATCH1 f64=23004EAE f68=FF0A7008 f72=80DC830 f76=1E60005
```

Luenta: sisäkkäisiä kernel-trap-kehyksiä (188 B/kehys) proc-0:n kernel-pinossa
(0x080DCxxx), rekursio laskee kohti 0x80DC830:tä; ktrap_latch-proben LATCH1: f68:n
alaosa 0x7008 = FORMAT 7 / VEKTORI 8 = access error, f72 = 0x080DC830 = pinoalueen
osoite. Eli varhainen satunnainen access error jonka käsittely faultaa uudelleen →
kstack-rekursiovahti tulostaa tasot. AJOITUS satunnainen (kylmä/lämmin-tyyppinen?) —
sukua vanhalle cold-boot-perheelle mutta ERI mekanismi kuin a70e8df:n loader-overlap
(se on fiksattu) ja mahdollisesti sama juuri kuin ISSUE-8:n deferred idle-Bus-Error-
luuppi. SEURAAVA ASKEL kun tähän tartutaan: ktrap_latchin kenttien tarkka decode
(f64/f76-semantiikka krnxmemflt040-kehyksestä) + serial-merkkikadon fixi jotta koko
rekursioketju tallentuu; toistotilasto eri lämpötiloissa. Työkalu valmiina:
serial2usb-kaappaus toimii nyt (stty 9600 raw + while-cat-luuppi | tee).

## ISSUE-22: kertaluontoinen EFAULT (read: Bad address) paineessa bare basella (real-HW)

**OPEN (alennettu prioriteetti 2026-07-19 ilta): jahti ajettu — EI TOISTUNUT uusilla
Model-B-ryhmillä.** 5 validia kylmä-boot→välitön-pressure-sykliä bare basella 260719-13
(+1 lämmin): 0 EFAULTia, 0 Bad addressia, 0 bus-virhettä, 36/36 kopiosummaa tavuntarkkoja
(evidenssi test-tools/modelb-groups-realhw-260719.txt). Joko swapadd/exec-stack-ryhmät
poistivat tuottajan tai esiintymä on hyvin harvinainen — EFAULT-latch-instrumentointi
(alla) tehdään vain jos oire palaa. Alkuperäinen havainto:
1 tapaus / 48 rinnakkais-cp:tä (2026-07-19 real-HW-verify, base 260719-01).
Ensimmäisessä bootin jälkeisessä pressure-ajossa yksi kuudesta `cp /payload.bin`
-prosessista sai `read: Bad address` (EFAULT); /press6.bin jäi syntymättä. SIISTI
epäonnistuminen: ei korruptiota (5 muuta tiedostoa + kaikki myöhemmät 3 pressurea ja
burst4 24/24 summaa täydellisiä). dbg-kernelillä 0 tapausta koko sessiossa (6 kierrosta,
emu+HW). Epäily: fault-polun harvinainen kilpailutilanne (copyout-puskurin faultin
resoluutio rinnakkaisessa paineessa) jonka dbg-instrumentoinnin viive peittää; osui
kylmään page-cacheen. JAHTIRESEPTI: toista kylmä-boot→välitön pressure -sykliä basella;
jos toistuu, lisää minimaalinen EFAULT-latch (u_error==EFAULT && syscall==read →
latchaa faultannut VA+PC) baseen. Kirjattu test-tools/issue10-realhw-verify-260719.txt.

## ISSUE-23: serdbg serial-merkkikato 9600:lla — FIKSATTU + REAL-HW-VERIFIED
**FIXED-HW-VERIFIED (2026-07-19 myöhäisilta): 123 KB aitoa 9600-kaappausta
(boot+churn+pressure, dbg -16) → 74 interleave-tapahtumaa joissa keskeytys-token
laskeutui prosessirivin sisään KAIKKI ehjinä, 0 katkennutta tokenia, 0 silputtua
WARNING-riviä /795. Evidenssi test-tools/issue23-serialfix-260719.txt.**
**(alkup. FIXED-PENDING-HW-VERIFY (fiksi 2026-07-19 myöhäisilta, buildit dbg 260719-16 /
quiet -17; emu-regressio PASS: boot+login+serial-flood+hat_dup_cow 64).** Korjaus
kaikkiin KOLMEEN kirjoittajaan (serdbg.s serdbg_putc; serdbg_mark.s + mainmarks.s
serdbg_mark+serdbg_hex): SR talteen → IPL7-maski → bounded TBE-odotus ENNEN
kirjoitusta (btst #5,serdatr-ylätavu = word-bitti 13) → SERDAT-kirjoitus → SR-palautus.
Bounded-odotus säilyy fail-safena (puuttuva serial = pudotettu merkki, ei jumi).
Nopeus pidettiin 9600:ssa (SERPER-nosto edelleen optiona, arvot alla). Alkuperäinen
juurisyy: Real-HW:lla serial
pudottaa merkkejä dbg-floodissa (9584647:n sivulöydös). Juurisyy luettu `prototypes/serdbg.s`:stä:
`serdbg_putc` kirjoittaa `SERDAT ← merkki` ENSIN ja odottaa TBE:tä (SERDATR 0x2000) vasta
jälkeen, ILMAN keskeytyssuojaa. conputc-hookkia kutsutaan sekä prosessi- että
KESKEYTYSKONTEKSTISTA (dbg clock_sampler!) → TBE-odotusikkunaan (~1 ms/merkki @9600) osuva
keskeytyksen putc YLIKIRJOITTAA SERDAT-puskurin ennen siirtoa shift-rekisteriin = hiljainen
merkkikato. Emu ei näytä tätä koskaan: Amiberryn serial-TCP ei mallinna baud-ajoitusta (ikkuna=0).
FIKSI (kun tehdään): (1) odota TBE ENNEN kirjoitusta + lyhyt IPL7-maski odotus+kirjoituksen
ympärille (max 1 merkkiaika; @115200 vain 87 µs); (2) valinnainen SERPER-nosto — PAL-arvot:
19200=0xB8, 38400=0x5C, 57600=0x3D, 115200=0x1E (nyt 0x174=9600) — kapasiteetti 12× ja ikkuna
kapenee, mutta EI yksin poista racea. HUOM: unix_boot040:n loader-diagit jäävät 9600:aan ellei
nosteta molempia; vastaanottopää samaan nopeuteen. Verifiointi vain real-HW:lla.

## ISSUE-24: init 6 jää runlevel-6-limboon real-HW:lla — rc6-userland, EI kernel-bugi
**OPEN (kirjattu 2026-07-19 ilta, real-HW base 260719-13; sama havaittu ISSUE-22-jahdon
sykleissä).** `init 6` (telnetistä tai konsolilta) vie koneen runlevel 6:een (`who -r` = 6),
rc6 tappaa suurimman osan palveluista — mutta viimeinen uadmin-askel EI koskaan toteudu:
kone jää käyttökelpoiseen limboon (telnetd+smtpd elävät, konsolilla "init 6"). RAJAUS
(käyttäjän havainto): manuaalinen `reboot`-komento LIMBOSTA buuttaa koneen normaalisti →
kernelin uadmin/haltsys040-polku on real-HW:lla KUNNOSSA; vika on rc6-skriptisekvenssissä
(rc-taso, ei kernel-portti). Emulla shutdown -i6 toimii (writeback-hyväksyntä 060:lla) —
eroa emu vs. real ei ole vielä rajattu (rc6:n sisältö / konsoli-tty-tila?). KÄYTÄNNÖSSÄ:
käytä pehmoreboottiin `reboot`-komentoa, EI `init 6`:tta; kylmäboottiin reset (automaatti-
boot unix-040:lle konfiguroitu 2026-07-19). Selvitys: aja rc6 kädestä (`sh -x /sbin/rc6`)
ja katso mihin uadmin-haara kuolee.

## ISSUE-25: natiivi boot-osiopolku (boot1/boot2) on 030-only — 040-portti buutataan unix_boot040:llä
**DOCUMENTED-DEFERRED (koe 2026-07-20 yö, emu-040).** Kokeiltiin stock-asennuspolku:
/stand/Makefile newboot-target dd:llä (boot1.boot + makeiblk + boot2.boot + makeiblk +
kernel → /dev/dsk/c6d0s3; RDB: UNIX_Boot-osio bootable pri=2, boot1 = validi DOS\0-
bootblock). Layout-verifiointi hostilta: dd osui täsmälleen oikein (ero goldeniin alkaa
kernel-offsetista 0x260a). TULOKSET Amiberryssä (vain AMIX-hdf, KS 3.2.2):
- STOCK-kernel natiivisti → GURU 8000 000B (Line-F) = 030-MMU-käskyt (pmove-perhe)
  boot2:ssa/stock-pstartissa trappaavat 040:llä. Natiiviketju on 030-only.
- unix-040 (260719-13) natiivisti → EI gurua (pstart040:n 040-käskyt valideja): boot2
  latasi ja hyppäsi kerneliin, mutta MUSTA RUUTU ennen konsolialustusta — kernel-entry-
  kontrakti (bootinfo/parametrit/load-base) eroaa unix_boot040:n tarjoamasta; auditoitava
  JOS natiivibootti joskus halutaan (boot2:n 040-portti + kontraktivertailu unix_boot040
  vs boot2). Ei estä mitään nykyistä: AmigaOS→unix_boot040 on virallinen boottipolku.
(Alkup. sivulöydös shutdown -i0:sta eriytetty omaksi ISSUE-26:ksi alle — eristetty samana yönä.)

## ISSUE-26: shutdown -i0 (halt) → shutdown-prosessin deterministinen 4AFC0003-bus-error-silmukka
**OPEN, HYVÄ REPRO (eristetty 2026-07-20 yö, emu-040 dbg -16).** `shutdown -y -i0 -g0`
EI koskaan pääse halt-tilaan: shutdown-PROSESSI kaatuu silmukkaan `User BUS ERROR at
4AFC0003, PC:800023FC FAULT:6` (tuhansia toistoja kunnes prosessi kuolee; järjestelmä
jää elämään entiseen runleveliin). ERISTETTY: toistuu TUOREELTA golden-bootilta ILMAN
mitään edeltävää kuormaa (13651 osumaa <2 min) → laukaisin on -i0-polku itse, EI
raw-dd (alkup. epäily kumottu). Osoite 4AFC0003 = poison-kuvion deref = jokin -i0-
haaran lukema roskapointteri. Rajaukset: shutdown -i6 / `reboot` toimivat emulla;
real-HW:lla init 6 = ISSUE-24-limbo (eri mekanismi, rc6-userland). Halt-polkua (-i0 /
uadmin A_SHUTDOWN -haara) ei ole koskaan ajettu/validoitu 040-porteilla ennen tätä.
Deterministinen + halpa emu-repro = hyvä jahtikohde sopivassa välissä; ei blokkaa
mitään nykyistä (halttia ei käytetä työnkuluissa). Serial-evidenssi:
durable-tools/shutdown-i0-crash-serial.log (kopio myös scratchpadissa).

## ISSUE-27: segmap_pagecreate-perheen häntänollaus — ✅✅ TODISTETTU JA KORJATTU (2026-07-25, emu-040+060)

**VIKA TOISTETTU DETERMINISTISESTI JA KORJAUS TODISTETTU.**
| kerneli | mode E | tulos |
|---|---|---|
| 260725-06 (ei ISSUE-27) | 24/24 osumaa, offset **14336**, arvo **0xC5 = pool MARKER**, odotettu 0x2e | **DATA-DESTROYED** |
| 260725-10 (ISSUE-27), 040 ja 060 | 0/24 | **PRESERVED** |
**JA VIKA ON PAHEMPI KUIN "VUOTO": se YLIKIRJOITTAA voimassa olevaa tiedostodataa**
kierrätetyn fyysisen sivun sisällöllä. Laukaisin vaatii kolme ehtoa: (1) sivukohdistettu
kirjoitus, (2) pituus on 2048:n monikerta mutta EI 4096:n, (3) kokonaan jo allokoidun
tiedoston sisällä jonka sivut ovat KYLMIÄ. Mekanismi: `as_iolock`in
`if (uio_offset+n < to_filesize) n &= PAGEMASK` on juuri se suoja joka estää OSITTAISEN
pagecreaten — ja `PAGEMASK` oli 0xF800, joten 6144 ei typisty; `segmap_pagecreate` luo
KAKSI alustamatonta sivua, `uiomove` täyttää vain 8192..14335, ja häntänollauksen portti
`roundup(14336,2048) == 14336 == uio_offset` on epätosi → **nollausta ei ajeta lainkaan**.
Korjattuna 6144 typistyy 4096:een (yksi täysi sivu) ja loput 2048 tulee toisena
kierroksena jossa `2048 & ~4095 == 0` → pagecreate=0 → tavallinen read-modify-write.
Toistoprosessi ja kolmen aiemman epäonnistuneen koettimen analyysi:
`test-tools/pagecreate-issue27-COLD-PROOF-260725.txt`.
Muunnos: `patch_pagecreate.py`, 28 sitettä, buildit 260725-09/-10.
Codexin speksi + census (`vm-map/PAGECREATE-TAILZERO-{SPEC,CENSUS}.md`) toteutettiin
sellaisenaan: ryhmä `live` = `as_iolock` 12 + `rwip` 5 + `rwvp` 5 (atominen), `fbzero` 2,
`spec_write` 4. Tuottaja (`segmap_pagecreate` 0xa9742/0xa97a0/0xa9892/0xa9898) assertoidaan
**kanarioina jo-4-KiB:ksi** joka ajolla. EI mukana: S5 `writei` (AMIX-hybridi, ei tarkkaa
lähdettä, S5 ei mountattuna) eikä `ufs_bmap`in oma aritmetiikka (speksi: erillinen audit).
**Aiemmat epäonnistuneet koettimet (säilytetty, koska ne opettavat):** speksin oma
`pgcreatetest.c` luki hännän SAMASSA prosessissa heti kirjoituksen jälkeen → näki vain
residentin sivun; `pgcold` A/B jahtasi häntää EOF:n takaa → UFS-reikä jonka
`ufs_getapage` nollaa eksplisiittisesti; `pgcold` C oli oikea muoto mutta LÄMMIN cache →
`segmap_pagecreate`in `page_lookup` osui. Vasta D/E (oikea muoto + kylmä cache) toisti.
Ratkaiseva suunnittelumuutos: vikasignaali on "ALKUPERÄINEN kuvio hävisi", ei "häntä on
nollasta poikkeava" — se on provenienssiriippumaton, koska nollatkaan eivät ole
alkuperäistä dataa.
**Mitä ON verifioitu:** ei regressiota. `proctest` PASS, `mlocktest` PASS, ja
**levytotuus** `/big.dat` 2950288 t `sum = 8320 5763` identtinen `sync`+pehmeä `reboot`+
`fsck`:n yli — sekä emu-040 että emu-060, molemmat sekä pelkällä `live`-ryhmällä että
kaikilla kolmella. Serialit puhtaat.
**RISKI joka jää auki:** `rwip` välittää `pagecreate`in eteenpäin `ufs_bmap`ille
`alloc_only`-argumenttina, joten muutos koskee UFS:n **allokointia ja read-before-writea**,
ei vain nollausta — ja `ufs_bmap` (0x79d48) on itse yhä 2 KiB kahdeksassa kohdassa
(0x79d74, 0x79d7e, 0x79d96, 0x79da4, 0x79daa, 0x79ec0, 0x79ee2, 0x7a030). Speksi rajaa ne
tietoisesti ulos. Se on uusi tuottaja/kuluttaja-raja = sama vikaluokka joka puri kahdesti
samana päivänä → **`ufs_bmap`-audit on seuraava Codex-toimeksianto.**
Evidenssi: `test-tools/pagecreate-issue27-emu-verify-260725.txt`.

<details><summary>Alkuperäinen kirjaus (2026-07-25 aamu) — säilytetty, koska sen
vakavuusarvio ("ELÄVÄ hiljainen datavuoto") ei ole runtime-todistettu</summary>

**OPEN, KORKEA PRIORITEETTI (löytyi 2026-07-25 ISSUE-15/16/17/18 -diffauksen sivussa;
Codex-toimeksianto kirjoitettu → `PAGECREATE-TAILZERO-TASK.md`).**
`segmap_pagecreate` (0xa9722) on **jo muunnettu 4 KiB:iin** (`patch_modelb_pager.py:195-197`,
`patch_modelb.py:557`), mutta **jokainen sen kutsuja pyöristää häntänollauksen yhä
2048:aan**. Tuottaja on 4 KiB, kuluttajat 2 KiB — juuri se epäsymmetria on vika:

```
write(2) 2048-alignatulla offsetilla, ei-täysi sivu, EOF:ssa/sen jälkeen
  -> as_iolock (0xaee34, KAIKKI 12 sitea 2 KiB) -> *pagecreate_p = 1
  -> segmap_pagecreate luo KOKO 4 KiB sivun, tarkoituksella alustamatta
  -> uiomove kirjoittaa vain pyydetyt tavut
  -> kutsuja nollaa vain roundup(off+on+n, 2048):een
  => [roundup(end,2048), roundup(end,4096)) = KIERRÄTETYN fyysisen sivun vanhaa
     sisältöä; i_size:n kasvaessa se valuu tiedostoon ja levylle
```

Kutsujat ja niiden sitet (build/unix-040): `fbzero` 0x3fa8a (0x3fa90/0x3fa96),
`spec_write` 0x665f2 (4 sitea), `writei` 0x70cfa (s5, ei mountattu, 14 sitea),
**`rwip` 0x7f8ac = UFS = ELÄVÄ juuri-fs** (0x7f9b6/0x7f9bc/0x7f9d6/0x7f9e0/0x7f9e6),
`rwvp` 0x88f28 = NFS (5 sitea). `as_iolock`ia kutsuvat vain `rwip` (0x7f6b2) ja
`rwvp` (0x88edc), ja `rwip`in häntänollauksen portti on juuri se `pagecreate`-
out-param jonka `as_iolock` sille antaa (`pea %fp@(-28)` @0x7f69c) → sama yksikkö.
`as_iolock`in 12 siten lista on jo enumeroitu `patch_modelb.py:588-591`:ssä.
**VAROITUS:** juuri tämän luokan OSITTAINEN muunnos jumitti bootin 2026-07-03
(vain pituudet flipattu, step jäi 2 KB:iin = overlapping softlocks). Siksi Codexille
on pyydetty lukko-omistajuuskontrakti + `pl[]`-mitoitustodistus + minimaalinen atominen
yksikkö ENNEN toteutusta. `rwip`in MAXBSIZE-geometria (0x7f5d6 `&-8192`, 0x7f5e2
`&8191`, 0x7fb5c/0x7fbba `#8192`) on OIKEIN eikä siihen kosketa.
Codex on aiemmin auditoinut saman muodon erikseen `rwvp`:lle
(`NFS-FOREGROUND-WRITE-RWVP-AUDIT.md`) ja `fbzero`lle
(`MODEL-B-TEXT-RESIDUAL-CENSUS.md:63` "Definite active UFS helper defect") — mutta
UFS:n oma `rwip` ja `as_iolock`in rooli `pagecreate`-lipun TUOTTAJANA puuttuivat.
</details>

## ISSUE-28: memcntl / mem_unlock mlock-bittikartan geometria — ✅ FIXED (2026-07-25, emu-040+060)

**RATKAISTU `prototypes/patch_memcntl.py` (17 sitea + 5 kanariaa), buildit 260725-05/-06.**
**Sama tuottaja/kuluttaja-epäsymmetria kuin ISSUE-27:ssä:** `as_ctl` (0xaeafe) ja
`segvn_lockop` (0xad2f0) on JO muunnettu 4 KiB:iin (patch_modelb.py:333-337 ja
302-307) — ne TÄYTTÄVÄT ja indeksoivat mlock-bittikartan 4 KiB -sivuina. Mutta
`memcntl` (0x4319a) MITOITTI sen ja `mem_unlock` (0x434b6) KÄVELI sitä 2 KiB:llä.
Seuraukset: (a) `(int)addr & PAGEOFFSET` -portti päästi läpi 2048-alignatun mutta
ei-4096-alignatun osoitteen → `as_ctl` maskasi sen 4 KiB -rajalle ja operoi ERI
alueella kuin kutsuja pyysi; (b) `mlock_size` tuplasti tarpeellista (harmiton);
(c) **VIRHEPOLULLA** `mem_unlock` sai 2 KiB -bittiindeksit biteille jotka oli
asetettu 4 KiB -indekseillä, ja sen `ctob()` puolitti sekä osoitteen että pituuden
→ rollback vapautti VÄÄRÄN alueen: osa sivuista jäi pysyvästi lukituiksi
(`pages_pp_locked`/`availrmem` valuu) ja `MC_UNLOCK` osui alueille joita ei ollut
lukittu. Lähdekontrakti `svr4-src-3b2/.../os/lock.c:266-415`.
**LUOKITTELU: 21 raakaa osumaa, 17 aitoa sitea, 4 VALEOSUMAA** — `textlock` 0x42f58,
`datalock` 0x42fde, `ublock` 0x43080 (`moveq #11` = `return EAGAIN`) ja `memcntl`
0x43212 (`moveq #12` = `return ENOMEM`); lisäksi `segvn_lockop` 0xad54e (EAGAIN).
Patch-skripti assertoi kaikki viisi **kanarioina** joka ajolla. EI myöskään koskettu:
`ublock`/`ubunlock` `#4` = USIZE sivuina joka TÄSMÄÄ `segu_release` @0xaa78e:n kanssa;
`BT_BITOUL` (0x4339a/0x433a0); `segvn_lockop` 0xad482/0xad536 (`segvn_fault`-pituudet,
vedetty pois 2026-07-03 boot-jumin takia — pysyvät ennallaan).
**Hyväksyntä `test-tools/mlocktest.c`:** T1–T5 PASS emu-040 **ja** emu-060; erotteleva
T1 (`memcntl(base+2048)` → EINVAL) **FAIL korjaamattomalla 260725-04:llä** jossa se
palautti r=0 eli hyväksyi puolisivukohdistetun lukituksen.
⚠️ **VIRHEPOLKUA (c) EI ajettu suoraan** — sen deterministinen laukaisu vaatisi
lukittavan muistin loppumisen kesken operaation; konversio on perusteltu staattisesti
(täsmää nyt jo-4-KiB:n `as_ctl`/`segvn_lockop`-indekseihin). T2–T5 läpäisevät
MOLEMMILLA kerneleillä eli 16/17 siten runtime-näyttö on "ei regressiota", ei
"todistettu oikeaksi". Evidenssi `test-tools/memcntl-issue28-emu-verify-260725.txt`.

## ISSUE-29: kertaluontoinen KMA 128-tavuluokan vapaalista-hälytys (attribuutio TODISTAMATTA)

**OPEN, EI TOISTUNUT (havaittu 2026-07-25).** ISSUE-15-kernelin (260725-02) ENSIMMÄISESSÄ
ajossa dbg-overlayn `kmem_validate`-probe laukesi kahdesti, idlen JÄLKEEN:

```
DBG KMEMCORRUPT bin=80E3CB0 blk=4024E880 next=8 prev=6 caller=8042334 size=8C
DBG KMEMCORRUPT bin=80E3CB0 blk=4024C280 next=8 prev=6 caller=8042334 size=8C
```
Dekoodattu: `Km_FreeLists` runtime-base **0x080E3C60** (luettu relokoiduista operandeista
teksti 0x41c2a/0x41e16 Amiberry-IPC:llä) → bin-offset +0x50 = **vapaalista-indeksi 4 =
pienen poolin 128 TAVUN kokoluokka**. Ei MAX-lista, joten sen lohkot ovat tavallisia
buddyja joiden `fb_next`/`fb_prev` pitäisi olla oikeita osoitteita; 8 ja 6 eivät ole.
`caller 0x8042334` = `kmem_zalloc+0x18`, pyyntö 0x8C = 140 tavua.
**Attribuutioyritykset — KAIKKI NEGATIIVISIA:** korjaamaton 260724-04 (sama kuorma +
11 telnet-sessiota + sar/sadc/df + churn60) → 0; 260725-02 samalla kuormalla → 0;
260725-02 + 20 äkillistä connect/close → 0; yhdistetty 260725-04 emu-040 → 0;
emu-060 → 0. Eli 2 raporttia yhdessä bootissa viidestä, ei koskaan toistunut — myöskään
samalla kernelillä joka ne tuotti. **EI ole osoitettu että ISSUE-15 aiheuttaisi tämän.**
Rakenteellinen vasta-argumentti: puolitetut sivumäärät eivät muuta hallittua tavualuetta,
lohkojen osoitteita eikä listoja joille ne menevät — ainoa runtime-ero on että pooli
kuluttaa yhden sptmap-slotin kahden sijaan, mikä siirtää myöhempiä kvseg-osoitteita.
Aiempi latentti KMA-stomp (juuri se mitä `kmem_validate.s` kirjoitettiin jahtaamaan
ISSUE-5:lle, ei koskaan suljettu) on vähintään yhtä todennäköinen, nyt paljastuneena
siirtyneen layoutin takia. Jahti lopetettu projektin oman säännön mukaan; kirjattu
arvaamisen sijaan. Evidenssi `test-tools/modelb-tail-emu-verify-260725.txt`.

## ISSUE-30: pvn_vptrunc katkaisun häntänollaus oli 2 KiB — 🔶 MUUNNETTU, saavutettavuus TODISTAMATTA

**MUUNNETTU 2026-07-25 (`patch_pvntrunc.py`, 2 sitettä + 2 kanariaa, buildit
260725-11/-12), mutta vikaa EI saatu toistettua UFS:llä.** Codexin
`PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md` luokitteli tämän P1:ksi.
Lähdekontrakti `svr4-src-3b2/.../vm/vm_pvn.c` `pvn_vptrunc()`:
`kzero(addr + (vplen & MAXBOFFSET), MAX(zbytes, PAGESIZE - (vplen & PAGEOFFSET)))`.
Tarkoitus (ufs_inode.c): *"the contents of the pages following the end of the file must
be zero'ed in case it ever become accessable again because of subsequent file growth"*.
Vain `PAGESIZE`/`PAGEOFFSET`-termi on sivugeometriaa — **`MAXBMASK`/`MAXBOFFSET`
(0xb2474 `andiw #-8192`, 0xb24aa `andil #8191`) ovat 8 KiB segmap-slotti ja ne
assertoidaan KANARIOINA**, koska ne ovat naapuriosoitteissa ja näyttävät samanlaisilta.
Muunnetut: **0xb248c** `andil #2047`→`#4095`, **0xb2492** `subil #2048`→`#4096`
(niitä seuraa `negl` → `PAGESIZE - (vplen & PAGEOFFSET)`).
**Termi EI ole kuollut `MAX()`:n alla:** `ufs_itrunc` antaa `zbytes = bsize - offset`, ja
NDADDR-suorien lohkojen sisällä `bsize = fragroundup(fs, offset)`, joten 1 KiB
-fragmenteilla `zbytes <= 1023` → sivutermi dominoi. Katkaisu 4 KiB -sivun ALAPUOLISKOON
nollaa siis pre-fix vain seuraavaan 2 KiB -rajaan asti.
**⚠️ SAAVUTETTAVUUS TODISTAMATTA:** `test-tools/trunctest.c` (32 KiB P1 → truncate 8692
→ kasvata takaisin 12287:ään → lue [8692,12288)) antoi **0 osumaa 8/8 sekä ennen että
jälkeen** korjauksen. Syy on rakenteellinen: `truncate` **vapauttaa** lohkot yli
`fragroundup(uusi koko)`:n, joten se alue jota termi ei nollaa on deallokoitua, ja
takaisinkasvatus allokoi sen uudelleen nollattuna (`fbzero`). Sama peittomekanismi kuin
ISSUE-27:n A/B-koettimissa. Landattu siis **kontraktikorjauksena**, ei todistettuna
vikakorjauksena. NFS- (`nfs_vnops.c:842`, joka laskee `zbytes`:n ITSE `PAGESIZE`stä) ja
s5-kutsujat (`s5alloc.c:481`) eivät ole mountattuina eikä negatiivinen tulos kata niitä.
**Regressio OK:** `proctest`/`mlocktest`/`trunctest` PASS ja levytotuus `sum 8320 5763`
`reboot`+`fsck`:n yli, emu-040 **ja** emu-060; ISSUE-27 ei regressoinut (pgcold E
PRESERVED). Serialit puhtaat.
