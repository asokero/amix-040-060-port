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
