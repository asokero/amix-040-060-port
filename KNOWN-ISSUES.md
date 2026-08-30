# Known issues — deferred, with enough context to resume

> **Canonical status: [`STATUS.md`](STATUS.md).** Where this file and STATUS.md disagree,
> STATUS.md is right and this file is history.
>
> **Do not mint a number by reading this file.** Issue numbers are allocated in per-machine
> blocks — run **`tools/next-issue.sh`**, which resolves yours from `git config user.email`.
> The registry and the reason are in [`CONTRACTS.md`](CONTRACTS.md). Taking "the highest
> number here, plus one" is how 46–49 came to mean two different things each.

## ISSUE-1: our rebuilt `unix_boot` causes a 68030 MMU Configuration Error at the kernel's `pstart` (clib2/bebbo build)

> **Ledger: DEFERRED** — unix_boot040 is the supported loader. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

> **Ledger: OPEN** — cosmetic, dbg build only. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
**Status:** OPEN (updated 2026-07-04), low priority — cleanup gated on hat_dup (see below).
The instrumented kernel `build/unix-040-dbg` (relink-040-dbg.sh) prints a lot of debug output;
all of it is HARMLESS but noisy.  Notable at the interactive-login stage:
- **`C<pid>:<PC>:<SR>` forever** — `src/sigkill_dbg.s` clock_sampler (every 16th tick,
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

> **Ledger: FIXED** — 68040 + 68060 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
**Status:** MERGED into master 2026-07-07, AWAITING BOOT TEST (was OPEN since 2026-07-04).
`hat_dup040.s` (branch `040-hat-dup-port`, already boot-verified there including the
fork-without-exec COW subshell test — see memory `amix-040-hat-dup-port`) is now merged into
`src/` and wired into `relink-040.sh` on top of ALL newer master fixes (haltsys/fsck/
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
Full batch list: docs/archive/RESUME-HERE-260727.md.

**Also flagged but NOT fixed this session** (deferred, needs more RE + can't be verified
without a boot): `hat_ptfree` frees the physical table page but never retires its `ptdat`
record from `active_pts`/`free_pts`, calls `hat_sdtfree`, or wakes `pt_waiting` — the stale
`active_pts` record can be reused by `hat_ptalloc_orig`'s (already-hardened-against, but not
eliminated for `hat_exec_orig`) steal path. Not an observed bug yet (steal path currently
unreachable from the CANWAIT sites above); full detail in `HAT-PTFREE-AUDIT.md`.

**hat_map phantom-preload — FIXED + boot-tested 2026-07-07 (commit 178364a).** Codex's
`P-MAPPING-MATRIX.md`/`HAT-MAP-AUDIT.md` found retained `hat_map` writes legacy `pfn<<11`
phantom PTEs into `pp->p_mapping` chains (mixing with live `pfn<<12` entries → breaks the
one-format invariant). Fixed with a 1-byte preload-disable (0xb58d2 beqw→braw); investigation
+ why-Option-A in `src/hat-map-040-fix-plan.md`. **User boot-tested (3 boots): login/
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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
**Status: RESOLVED (2026-07-05, fix v3, boot-confirmed).** Final fix = `haltsys040.s`
makes the reboot/halt MMU-disable UNCONDITIONALLY use the 040 `movec`+`pflusha` path
(commit 8c03c7c), after v1 (guarded `haltsys`) and v2 (`rtnfirm` override, commit 8dfc1d2)
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

**FIX v1 (superseded, retained below for the RE details):** `src/haltsys040.s` reimplements the
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
(`src/copyit.s`'s original unguarded `pmove tc/crp/srp` in the Amiga-side MMU-disable code,
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

> **Ledger: DEFERRED** — defensive; correct for the known callers. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
**Status: RESOLVED (2026-07-05, two commits).** Booting a corrupt/dirty filesystem ran
boot-`fsck` (`/sbin/fsck -F ufs -y /dev/rdsk/…`), which raw-reads the device into an anon
buffer; the kernel F_SOFTLOCKs the buffer pages for the physio transfer and `segvn_softunlock`
panicked. Root-caused with the `segvn_softunlock_dbg` diagnostic wrapper (dbg build) which
replicated the per-page page_hash find and dumped the failing page's state. TWO distinct
bugs, both leftover 2KB/4KB Model-B conversion errors in the VM layer:

1. **`swap_xlate`/`swap_anon` used a 2KB pagesize shift** (commit 8127111). They translate
   anon-slot-index ↔ swap-vnode byte-offset with `<<11`/`>>11` (×2048) — byte-identical to
   the 2KB vanilla, missed in the Model-B pass even though the anon/swap ACCOUNTING was
   already 4KB. Result: anon `p_offset` came out 2KB-aligned (e.g. 0x1F800 = 63×2048), not
   4KB-aligned — a swap-slot-overlap corruption and mishandled by 4KB-aligning code. Fix:
   `moveq #11→#12` at both sites (patch_modelb.py). This was real but NOT the panic trigger.

2. **`segvn_softunlock`'s inlined PAGE_HASHFUNC was patched to `>>12` while the other 7
   inlined hash sites stayed `>>11`** (commit 15e1251 — the actual fix). patch_modelb.py had
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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
**Status: RESOLVED (2026-07-09), commit `c0a3cd8`. Verified: fs-uae boots to login, runs
`ls -alR`, survives 7 reboot cycles with ZERO panics and ZERO recursion signatures
(`kstack`/`KSTKCHAIN`/`PREEMPT1 uprocp=0` all absent), clean `haltsys`.**

**ROOT CAUSE (finally): `wb040` write-back replay could not handle an UNALIGNED PAGE-CROSSING
store.** The 040 access-error handler re-issues the faulted store from the write-back frame with
one wide `moves`. Measured via the new KSTKWB probe (commit `3aeeb7c`): a supervisor long store
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
non-rootnull exit) alongside the ISSUE-4 hat_dup040 merge (commit 17b6081). **User boot-tested
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
entry probe in execmark.s. Serial capture via serdbg (docs/SERIAL-DEBUG.md).

### 9. setuctxt kmem_alloc(KM_SLEEP) window (2026-07-07, RULED OUT — probe never fired)
Codex timing hypothesis #1 (`src/setuctxt_dbg.s`, commit `d07552e`): does `u_procp`
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
`src/preempt_dbg.s`'s multi-proc watermark scan (commit `d618652`) fired on the
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
  NOTE (2026-07-07): the HAT-MAP phantom-PTE producer is now disabled (commit 178364a,
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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

> **✅ RESOLVED (2026-07-09), commit `ef3eb90`.** The `click<<11` intuition was RIGHT after all —
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
> `swapinub` ubptbl wrappers (commit `0cc9fb4`) rebuild `p_ubptbl` from the live kptr040 tree,
> closing the same halved-leaf exposure on the fork path. Emulators now behave identically.
>
> **Real-HW status: UNTESTED with this fix.** The real-A3000 p0init bus error was this halved
> address (segu_get read 0x038A7xxx in the RAM hole); the fix should clear it, but it has NOT been
> retested on silicon. That is next-session goal #1 — see `docs/archive/RESUME-HERE-040-HARDWARE.md`. The
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
ROOT-CAUSED AND FIXED (commit `55b211b`): the loader's ELF buffer overlapped the copy
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

## ISSUE-9: idle-time infinite Bus Error loop — ✅ **CAPTURED 2026-07-28** (still open)

> **Ledger: OPEN** — captured on 68040 hardware, not attributed. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**The capture ISSUE-9 has been waiting for since 2026-07-09 arrived on its own**, on real
hardware, kernel `68040-260728-12`, with serial running. Evidence:
`test-tools/issue9-capture-260728.txt`. It appeared during an ISSUE-36 acceptance session and the
first assumption -- that the acceptance tests caused it -- turned out to be wrong.

**It is a PERIODIC path, exactly as this entry predicted, and now it is named.** Not `fsflush`,
not `pageout`, not the callout handler -- **cron**:

```
uucp   254    97  0 23:45:00 ?  0:00 sh -c /usr/lib/uucp/uudemon.cleanu > /dev/null
uucp   256   254 15 23:45:00 ?  1:50 /usr/lib/uucp/uudemon.cleanu       <- 4328 faults
```

Parent 97 is cron; the machine's clock read 23:47 with 9 minutes of uptime, so the nightly uucp
cleanup fired on its own schedule. The loop:

```
NOTICE: User BUS ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:256 CMD:/usr/lib/uucp/uudemon.cleanu
DBG SIG sig=11 pid=256 stat=6 psargs=... uret=80011BF5 uarg2=80011A8C     (23x, probe-capped)
DBG SEGVCTX a0=400B5604 a1=1 pte=94C6019 cell=4AFC0000 uva=48478000       (8x)
DBG SEGVDMP p0=0 p4=0 cm4=74000000 c0=4AFC0000 c4=0 c8=0                  (8x)
DBG SEGVCTX a0=80012010 a1=80011C10 pte=0 cell=DEADDEAD uva=48478000      (1x)
```

**ISSUE-9 and ISSUE-10 are the same family.** `cell=4AFC0000` is the signature this project has
already documented as the corrupt-heap-link morphology: `src/sigkill_dbg.s` literally predicts it
("`a1` = the bad link value -- expect 0x4AFC0000, self-validating"), `hat040.s:730` calls it "the
4AFC005F bus-error avalanche", and `patch_swapin.py` ties it to a swapped-in anon page losing its
upper half. `uret`/`a0`/`a1` are all in sh's heap range (`0x8001xxxx`). One sample shows the
stronger form: **`pte=0`** with `cell=DEADDEAD`, i.e. the page is not merely wrong, it is gone.

**NOT deterministic.** The same script run by hand on the same kernel completed in 8 seconds with
zero bus errors. So the corruption is in the state at that moment, not in the script -- which is
why a plain A/B cannot attribute it and why a soak is the only honest test.

**RECOVERABLE, and that is a useful distinction:** `kill -9` on the looping process restored the
machine completely (`sync` clean afterwards). ISSUE-37's loop is inside the kernel and cannot be
killed. From the console the two are indistinguishable -- both are an endless error stream -- so
**try killing the faulting PID before reaching for the reset switch.**

**Attribution to the ISSUE-36 fix: not supported, but not excluded either.** All four changed sites
live inside `nfs_getpage`/`nfs_getapage`, which only execute for NFS-backed vnodes, while
`uudemon.cleanu` works on the local UFS spool -- so the changed code is not on its path. The `pl[]`
probe also reported no contract violations anywhere in that boot, which is the specific mechanism
that could have corrupted kernel state indirectly. What that does not exclude is some other
indirect effect of the same boot's NFS activity, and an intermittent fault cannot be cleared by a
single clean run.

**Next step, unchanged in kind but now much better targeted:** a soak with serial running, and
`uudemon.cleanu` (or any cron job that exercises sh's heap) as the trigger to watch. The open
question is which producer leaves `4AFC0000` in an anon page after ISSUE-10's fixes landed.

### (original entry, 2026-07-09)

**ISSUE-9 (as first recorded): idle-time infinite Bus Error loop, uncaptured — separate from ISSUE-7**

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
(see `docs/SERIAL-DEBUG.md` / memory `amix-serial-debug-capture`) and let it sit idle until the loop
starts, to get the fault PC + type + faulting address. Then map the PC to the daemon/handler.
Only after that decide on a fix. Per the standing "pause elusive-bug hunting; record and redirect"
guidance, this is recorded and deferred — not the immediate frontier (real-HW retest + cold-boot
flakiness come first).

## ISSUE-10: `/bin/sh` heap contains a kvsegu-range pointer → SIGBUS fault-retry flood (amixadm repro)

> **Ledger: OPEN** — 68040 hardware + emulator; INTERMITTENT, so a single-boot bisect is invalid. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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
diagnosed in `src/hatalloc_dbg.s` (page_abort wrapper): **`page_abort` calls
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
legacy pfn<<11 reverse-map entries — was already DISABLED (178364a, 0xb58d2 beqw→braw).
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
  `test-tools/issue10-smokinggun-260715.txt`. Spec: `docs/ISSUE-10-FREETIME-PROBE-SPEC.md` (widen its scan target
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
- **`hat_pagesync` is UNPORTED** — no override in src/*.s or the relink scripts; stock
  030 body runs at 0xb4be8, calling `hat_pt2ptdat` (0xb5e0a, the retired 030 ptdat/secseg
  machinery) + `flushmmu`. The ref/mod BIT POSITIONS happen to align (immu.h `PG_REF`=bit3,
  `PG_M`=bit4 == 040 U/M), so the read isn't obviously wrong; the suspect part is the retired
  `hat_pt2ptdat`/`flushmmu` ATC handling on the 040 tree (Codex "hat_pagesync cpusha gap
  LATENT"). **LATENT until pageout went live** (schedpaging retirement feacac3) — which is
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

**★ hat_pagesync040 BUILT + TESTED 2026-07-15 night (build 260715-18, commit d200778) — does
NOT fix ISSUE-10; rules out chain (I), points at chain (II).** Ported `hat_pagesync` to 040
(src/hat_pagesync040.s: verbatim U/M gather+clear, retired flushmmu block replaced with
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

**★ hat_exec steal REFUTED 2026-07-15 (audit #1, commit 1aef3e3, build 260715-20).** No-op
`hat_exec` (src/hat_exec040.s, be9a23f — removes the flag-0 steal path + NULL-panic) boots
clean but the 4-burst repro reproduces IDENTICALLY (same pp=400AA2C0, 4AFC005F, `\x7fELF`). hat_exec's
steal is NOT the producer. No-op KEPT as Codex `HAT-EXEC-POLICY` safety hardening, not the fix.
Evidence `test-tools/issue10-noexec-negative-260715.txt`.

**★★★ SEGVCHAIN PROBE + ROOT REFRAMED 2026-07-16 (commit f259347, build 260715-22) — chain-II
REFUTED; it is a DOUBLE-REGISTERED frame.** Added a victim-context reverse-map probe to
`src/sigkill_dbg.s`: on a SIGSEGV whose saved-a0 URP walk reaches a resident leaf (the sh-heap
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

**★★★ 2026-07-29: THE AMIXADM TRIGGER IS BACK, AND IT REPRODUCES IN THE EMULATOR.** The user
noticed it while checking the probe-less kernels: `amixadm` bus-errors on the base build but never
on a dbg build. It then reproduced on the FIRST try in Amiberry on `unix-040-quiet-260729-08`,
byte-identical to July:

```text
NOTICE: User BUS ERROR at 4AFC0003, PC:800023FC FAULT:6 PID:173 CMD:amixadm     (x16108)
```

Evidence: `test-tools/issue10-amixadm-emu-repro-260729.log`.

**Why it looked "retired" in July: the trigger is VARIANT-dependent, and every session since has run
dbg kernels.** The 2026-07-15 retest that declared it unreliable was run on a dbg image. It was never
the trigger that decayed; it was the instrument that hid it.

Three consequences, all of them useful:

1. **Not copyback** — `-08` is write-through, so this is independent of the B2 work.
2. **Not hardware-specific** — the emulator reproduces it, which substantially weakens a
   cache-coherency explanation for THIS symptom: Amiberry does not model the 040 data cache's
   coherency behaviour. That points back at the July suspect list, headed by **phys double-use**:
   the value read from sh's malloc free list is `0x4AFC0000`, which is kvsegu (u-area) flavoured,
   so a user heap page is carrying kernel u-area content.
3. **Iteration is now ~3 minutes locally instead of a hardware session.** The quiet kernel mirrors
   the console to serial, so the whole cycle is scriptable with `test-tools/sendkeys.py` and the
   serial log — no telnet, no hardware, no user at the keyboard.

**Open question worth testing first, because it is cheap:** ISSUE-38 (copyback hangs at init's exec
without probes) is ALSO masked by the dbg overlay. Two different symptoms, both hidden by the same
overlay, both involving page reuse. Whether they are one defect is unproven — but bisecting which
dbg component masks each of them is now an emulator-only experiment.

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
pageout reclaim from the schedpaging retirement (feacac3). **Practical consequence: amixadm is
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
  bc68e1b, `pagezero(pp,0,0x800)` half-zero), (3) buffer-cache/DMA into a user phys page.

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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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
- s5getapage ×23 + spec_getapage ×12 Model-B conversion (c4873ae) — real file-tail
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

> **Ledger: FIXED** — 68040 hardware -- it works; the interface is aen0. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**Status (2026-07-12): CAPTURE 1 = FIXED + VERIFIED ON REAL HW (bp_map040, commit
46b159c — see the "CAPTURE-1 FIXED" block at the end of this section). CAPTURE 2 =
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

**ISSUE-13 FIX IMPLEMENTED (2026-07-12, awaiting boot test): `src/bp_map040.s`**
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
(Committed 46b159c, 2026-07-12.)

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
(runtime040.s promotion, see docs/archive/RESUME-HERE-260727.md).

**CAPTURE-2 FIXED — VERIFIED ON EMULATOR 040+060 (2026-07-13, commit df7f879):**
`src/krnxmemflt040.s` implements the native resolver core per the spec above
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

> **Ledger: DEFERRED** — emulator environment, not the port. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

> **Ledger: FIXED** — emulator, both CPUs. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**RATKAISTU `src/patch_kmapools.py` (26 sitea), buildit 260725-01/-02.**
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

> **Ledger: DEFERRED** — 72 sites; RFS is broken upstream anyway. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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
**KORJAUS:** `src/prfastmap040.s` = uusi `uvatopte040` (040 per-proc
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

> **Ledger: FIXED** — emulator, both CPUs. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

> **Ledger: OPEN** — statically possible, never reproduced. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

**★★★ MEMWATCH-JAHTI 2026-07-18 (2ef58ef+0dea606) — CURRENT FRONTIER, supersedes the probe plans
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
so every swapped-in anon page lost its upper half. FIX = `src/patch_swapin.py` (in
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
(50abe53, `patch_swapgeom.py`, 12 sitea / 5 funktiota — yllä oleva "patch as its own set"
-merkintä TEHTY; slottimäärä todistettu swapctl SC_LIST -probella `test-tools/swapls.c`:
PAGES 25600, ei 51199-tuplausta). (2) exec_initialstk+extractarg (5637b04,
`patch_execstk.py`, 0x800→0x1000 symtab-resolvoitu + jaettu shift 11→12; hyväksyntä
`test-tools/bigargv.c` = 4500 B argv execin yli tavuntarkasti ×3). (3) pageout-oletukset
(3425d82, `patch_pageoutdefs.py`: lotsfree 128→64 / desfree 50→25 / minfree 16→8 =
dokumentoidut TAVUkynnykset 4K-sivuina + vmmeter UPIO-fold 2→1 nelänä nop:ina —
**burst4-thrash 8 min/bursti → 1,4 min/bursti**, freemem-129-jäätymä poissa). (4) mincore
(c79730a, `patch_mincore.py`: btoc-vektori + PAGEOFFSET-portti @0x585e2, joka speksissä
jäi auki — varmistettu 3b2 grow.c:523:sta; hyväksyntä `test-tools/mincoretst.c`: tasan 8
vec-tavua + EINVAL 2K-kohdistuksesta). Buildit 260719-04…-15; joka ryhmällä hat_dup_cow
64 PASS, 0 bus-virhettä, 0 4AFC005F:ää. JÄLJELLÄ: real-HW-verify-delta (REALHW-VERIFY-tyyli).

## ISSUE-20: stock hat_swapout = MIINA jos prosessi-swapout koskaan palautetaan

> **Ledger: DEFERRED** — process swapout is disabled. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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

> **Ledger: FIXED** — 68040 hardware, 9/9. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**✅ RATKAISTU 2026-07-22 (config040.s cache-handoff-wrapper — self-contained, HW-verified 9/9):**
Juurisyy = 68040:n INSTRUCTION CACHE peritään AmigaOS/68040.library:ltä PÄÄLLÄ kernel-entryssä, ja
`config()`:n memcpy + pstart040:n bzero (ENNEN pstart040:n omaa 'D'-regiiminvaihtoa) ajavat likaisella/
periytyneellä IC:llä → satunnainen ILLEGAL@memcpy / ADDRERR@bzero. Loader-side copyit-CACR=0 EI jäänyt
voimaan (emu+HW: 'A':n CACR yhä 0x00008000). **FIX = kernel-side wrapper:** `patch_config_cachefix.py`
uudelleenkohdistaa `_start`:n ainoan `jsr config`-relokaation (.rela.text r_offset 0x26) →
`config_cachefix` (src/config040.s), joka tekee `cinva ic` + `movec #0,cacr` (kaikki cachet pois)
ja tail-callaa oikean configin (`config_orig`=0x18f5c). Varhaiskoodi ajaa siis IC-off; pstart040 'D'
palauttaa IC:n (Step A / 2× nopeus säilyy). Loader-riippumaton (matkaa kernel-imagessa). **HW-VERIFIOINTI
(dbg -04 260722, evidenssi /tmp/amix-hw-cachetest4.log + reboot_loop.py 8 kierrosta):** 9/9 boottia
puhtaita — `K00000000` ×9 (wrapperin CACR-takaisinluku=0), `AC00000000` ×9 (pstart 'A' CACR=0 = nolla
säilyi wrapperista 'A':han), `FLT v00007008` ×9 (kaikki OK-init, 0× ILLEGAL/ADDRERR). Vrt. ilman
wrapperia IC-only (CACR=0x00008000) kaatui satunnaisesti parissa bootissa. **Ei enää tarvetta `cpu
nocache`-workaroundille.** Landattu commit 8d913b8; wrapper base+quiet+dbg (K-dumppi flag-gated dbg-only).
IMPLIKAATIO DC-tavoitteelle: ongelma oli nimenomaan IC-handoff, EI copyback-DC — B1/B2-kampanjan
varhaisbootin herkkyys poistui (peritty IC hoidettu). Alla oleva tutkimushistoria säilytetty.

---


**PÄIVITYS 2026-07-20 (btrace-lokalisointi + FLT-työkalu):** Lisättiin flag-gated
varhainen boot-trace (`src/btrace.s`, vaihemerkit A–H/S/s/P; commit a9ca934) ja
one-shot FIRST-FAULT-latch (`src/ktrap_latch.s` FLT-lohko, commit 9af33b9).
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
lisätty pstart040 'A':han (btrace_hex; commit a48b651). Ristiin-OS-tieto (käyttäjä): AmigaOS/Debian/OpenBSD/
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
sukua vanhalle cold-boot-perheelle mutta ERI mekanismi kuin 55b211b:n loader-overlap
(se on fiksattu) ja mahdollisesti sama juuri kuin ISSUE-8:n deferred idle-Bus-Error-
luuppi. SEURAAVA ASKEL kun tähän tartutaan: ktrap_latchin kenttien tarkka decode
(f64/f76-semantiikka krnxmemflt040-kehyksestä) + serial-merkkikadon fixi jotta koko
rekursioketju tallentuu; toistotilasto eri lämpötiloissa. Työkalu valmiina:
serial2usb-kaappaus toimii nyt (stty 9600 raw + while-cat-luuppi | tee).

## ✅ COPYBACK IS THE DEFAULT, AND FULLY ACCEPTED ON THE SHIPPING IMAGE (2026-07-30/31)

`hat_cm_ram` now ships `0x20` in the base link (`src/hat040.s`); the WRITE-THROUGH control is
the derived image (`patch_b2_flip.py --wt`). The flipped base differs from the hardware-accepted
`unix-040-b2-fix38-260730-03` by exactly one build-id byte, so the acceptance below covers what
ships. Everything here was run on a **probe-less** image — every earlier copyback result was taken
on a dbg overlay that carried an unconditional `cpusha bc` (see ISSUE-38).

```text
pressure suite      B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts), 96/96 V0_COMPLETE_MATCH
power-cut truth     B2RT-RESULT PASS (6 files, every byte intact) after a real power cut + fsck
Dhrystone           30037 /s  vs write-through 18292.7 /s  = +64 %
exec path           EXECTEST-RESULT PASS (data+bss verified across 20 generations)
```

Counters over the burst run (the content of the run, not bookkeeping): `wb_dfc_changed` +43 — the
ISSUE-22 DFC fix fired 43 times under load and the run produced zero EFAULTs; `dma_cmpl_noprep` 0
across +555 567 page releases — the B1 DMA-coherency hook never failed open; `cb_rel_reject` 0;
`us_odd_user` 0. Full records: `docs/REALHW-COPYBACK-ACCEPTANCE-260730.md`,
`docs/REALHW-COPYBACK-POWERCUT-260730.md`.

Known residual, deliberately not bundled: the base kernel still prints ~29 `cmn_err` diagnostics
from the genuine-fix objects (`hat040.s` 17, `vtop040` 3, `hat_dup040` 2, ...), gated only by
counters and not by a runtime flag. Quieting them is a separate unit with its own hardware
acceptance — ISSUE-38 is precisely the lesson that instrumentation changes behaviour.

## ISSUE-38 — ✅ CLOSED 2026-07-30: the boot icode was invisible to the 040 ifetch under copyback

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

Full record: `docs/ISSUE38-ICODE-CACHE-FINDING-260730.md`. Short form: `main+0x1e8`'s
`copyout(icode, 0x80800000, szicode)` leaves proc 1's bootstrap text in dirty copyback data-cache
lines; the 68040 instruction fetch does not snoop the data cache; proc 1 executes the still-zero RAM
page as `ori.b #0,%d0` off the end of the page into the unmapped `0x80801000` and dies of SIGSEGV
**before exec is entered**. The terminal `hat_unload va=48442000 size=2000 flags=A` is
`segu_release` reclaiming the resulting zombie's u-area, not an exec-header release. `assegat_dbg`
masks it because its `copyout` wrapper executes an unconditional `cpusha bc` — the masker is a cache
instruction, not chatter or timing. Discriminator: `ufault VA=80801000` appears twice in bisect D's
console and **zero** times in either booting capture, where `copyout dst=80800000 ret=0` shows the
bytes were copied. Fix: `src/cb_icode040.s` (gated `cpusha bc` after the icode copyout) in the
base link, guarded by a relink check that rejects a stock `copyout`. **HARDWARE-VERIFIED
2026-07-30:** `unix-040-b2-fix38-260730-03` (copyback, no probes) reaches telnet — `uname -m` =
` 68040-260730-03` — with `cb_icode_calls` = `cb_icode_push` = 1 and the anchor `hat_cm_ram` = `0x20`,
so the mechanism is measured and not inferred from the boot; `exectest 20` PASSes on it. The
copyback default flip is unblocked. The 2026-07-29 bisect record below stands as measured; only its
interpretation ("names the exec path") is superseded.

## ISSUE-38 — BISECTED 2026-07-29: `assegat_dbg` is what masks it, and that names the path

> **Ledger: FIXED** — earlier record of ISSUE-38; the first ISSUE-38 section above carries the current one.

Five hardware boots, deterministic verdict each time (reaches login, or spins in the scheduler with
no runnable process — `mainmarks` makes the latter visible as a repeating `W` proc-table dump):

```text
full dbg overlay (14 objects)                                     boots
A  = serdbg + ddopen,blkatoff,mainmarks,assegat,execmark,
              hatalloc,sigkill                                     boots   (telnet: -12, uptime 2 min)
B2 = serdbg + mainmarks,ddopen,blkatoff,execmark                   HANGS
D  = serdbg + mainmarks,hatalloc                                   HANGS
E  = D + assegat_dbg                                               boots   (telnet: -22)
quiet = serdbg only                                                hangs
```

**E − D is exactly `assegat_dbg`.** And the result is more informative than the name: `hatalloc_dbg`
(in D) prints heavily and wraps `page_get`/`page_free`/`hat_ptalloc`, yet does NOT mask. So the
masking is not chatter and not page-allocation instrumentation — it is specifically the wrapping of
**`as_fault`, `as_segat` and `execmap`**.

**The two paths differ structurally, not just in timing.** A booting kernel maps the 8 KiB
exec-header segmap slot and proceeds to fault in init's text; a hanging kernel *releases* it —
`DBG hat_unload va=48442000 size=2000 flags=A` — and stops. Exec is aborting, not stalling. `D`'s
log adds two lines immediately after the release that are worth following:

```text
DBG page_abort crash pp=400AD254 p_mapping=0 caller=80AD7DA (0=>SKIPs hat_pageunload, PTE stays)
DBG page_abort crash pp=400AD290 p_mapping=0 caller=80AD7DA (0=>SKIPs hat_pageunload, PTE stays)
```

A page released with its PTE left in place is the stale-PTE/page-recycling family — the same family
as ISSUE-10. Whether that is cause, consequence or coincidence here is **not established**.

⚠ **Provenance caveat on those two lines.** From 20:59 onward three processes were reading
`/dev/ttyUSB0` at once (two strays plus the session's capture), and serial readers SPLIT the byte
stream between them. The `-20` and `-22` captures are therefore incomplete. The lines quoted above
arrived intact and are real, but "immediately after the release, and nothing else" is NOT safe —
other lines may have gone to the other readers. Re-read them from a clean port before building on
the ordering. The bisect verdicts are unaffected: they rest on telnet/login, and the hang point
itself is established from the `-07` console photograph and the `-09` capture, both taken while the
port had a single reader.

The tell for a split stream is garbling, not absence: lines break mid-word and continue with another
line's content (`WARNING: DBG as_fault STREAM pi00011:00000001:...`). It reads like interleaved
output, which is how it was misread here for several messages.

**Next, and deliberately not another bisect:** the useful question is no longer *what hides it* but
*why exec aborts*. That wants a small probe on the exec header path (the `exhd_getmap`/`elfexec`
return codes) in an otherwise probe-less image, or a static read of that path under copyback. Both
are cheaper than narrowing further inside `assegat_dbg`, which is one large object with several
wrappers.

## ISSUE-38 — (CLOSED 2026-07-30, see above) it blocked the copyback flip: copyback hangs at init's exec WITHOUT the debug probes

> **Ledger: FIXED** — earlier record of ISSUE-38; the first ISSUE-38 section above carries the current one.

Found 2026-07-29 by booting the image that would actually ship — which, it turns out, no probe-less
kernel ever had been.

| image | cache | probes | result on the A3000 |
|---|---|---|---|
| `unix-040-260729-04` | write-through | no | **boots**, telnet, `uname -m` confirms |
| `unix-040-b2-260729-07` | **copyback** | no | **HANGS** at init's exec |
| `unix-040-b2-dbg-260729-06` | copyback | yes | boots; ran a 72-minute acceptance clean |

**`-04` and `-07` differ in exactly TWO bytes** — `hat_cm_ram` `0x00 → 0x20` at file offset 1033728,
and one build-id character. So the hang is attributable to copyback and to nothing else, and the
debug build masks it.

The console stops here (photographed; the DBG lines are pre-existing in every base image — 25 of
them in yesterday's `-24` — not new):

```text
WARNING: DBG hat_free ENTER as=4015F000 root=4015E000
WARNING: DBG hatfree BAD-Aslot A=4 Adesc=400003 table=400000 (skipped)
WARNING: DBG hatfree BAD-Aslot A=6 Adesc=3F0003 table=3F0000 (skipped)
WARNING: DBG hat_unload va=80800000 size=1000 flags=0
WARNING: DBG hat_unload va=C07FF000 size=1000 flags=0
WARNING: DBG hat_unload va=48442000 size=2000 flags=A        <- last line, then nothing
```

In a working boot (`-06` serial, `test-tools/issue22-serial-acceptance-260729.log`) the very next
line is `DBG execmap vaddr=80000034 filesz=66D4 off=34 prot=D` — **mapping init's ELF from disk.**
So it dies exactly where the exec path goes to the disk, and `0x48442000 size=2000` is the 8 KiB
exec-header segmap slot being released just before that.

**It boots in the emulator.** Amiberry does not model the 040's copyback data cache, which is
consistent with a cache-coherency mechanism and is why this could only be found on silicon.

**Working hypothesis, NOT yet measured:** a DMA/cache coherency window on the read path. With
copyback, a segmap slot reused for a DMA fill can still hold dirty or stale lines; the debug build's
constant `cmn_err` chatter creates cache pressure that would evict them, which is a plausible reason
the same code survives with probes and dies without. `dma_cache040`'s complete = per-range `cinvl`
is the first thing to re-read. Alternatives not excluded: a genuine timing race, or something
specific to the exec header slot's 8 KiB (two-page) size.

**Consequence: the copyback default flip is blocked.** Yesterday's acceptance stands — it was run on
`-06` and every number in it is real — but the artifact intended for use does not boot, so copyback
is not ready to become the default. The power-cut disk-truth test is postponed with it; there is no
point hardening a kernel we cannot ship.

Next: boot `unix-040-b2-quiet-260729-09` (base + serial mirror, no probes) to capture the hang's tail
verbatim instead of from a photograph, and to find whether the serial mirror alone is enough to mask
it — which would put a number on how narrow the window is.

## ISSUE-22 — ✅ ACCEPTED 2026-07-29: 16 bursts clean with 13 corruptions repaired under way

> **Ledger: FIXED** — 68040 hardware, 16/16. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

`68040-260729-06` (copyback + the DFC/SFC contract), fresh boot, `b2repro-copy.sh 16`, 72.6 min,
serial bracketed at both ends:

```text
B2REPRO-COPY CLEAN (0 non-V0 in 16 bursts)        96/96 verifications byte-exact
```

| counter | before | after | delta |
|---|---:|---:|---:|
| `wb_dfc_changed` corruptions caught and repaired | 220 | 233 | **+13** |
| `us_odd_user` misroutes | 0 | **0** | 0 |
| `Lkx_fn` resolver failure exits | 0 | **0** | 0 |
| `wb_replay_n` write-back replays | 7686 | 112558 | +104872 |
| `wb_dfc_lastold → lastnew` | 1 → 5 | 1 → 5 | unchanged signature |
| `wb_sfc_changed` | 0 | **0** | never differed |
| `wb_dfc_force*` | 0 | 0 | injection stayed inert |

**The +13 is what makes the clean run mean something.** A clean 16-burst run proves little by itself
— yesterday's control run was clean too, with the bug active. Thirteen corruptions occurring and
being repaired, with zero misroutes and zero failure exits, is the pair that says the hazard was
present and neutralised.

**Honest weight:** against a historical rate of ~1 EFAULT per 15 bursts, one clean 16-burst run is
about one expected event avoided. The case rests on the injection A/B and the mechanism counters;
this run is the confirmation Codex's acceptance list asked for, not the primary evidence.

`wb_sfc_changed = 0` across a boot and 112558 replays turns Codex's static "no victim path for the
SFC leak" into a measured statement.

### Side observation, NOT caused by this work: multi-minute stalls in the b2repro workload

Burst cost from the machine's own clock: bursts 1–6 took 120–125 s each, then +881, +118, +195,
+658 s. The same pattern predates all DFC work (`260728-36`: +539 and +352 in 15 bursts) and
appeared on a fresh boot, so yesterday's guess that it came from memory pressure left by earlier
cofault runs is weakened by this run. Baseline burst cost is unchanged, so it is stalls rather than
slowdown — a few candidates worth one cheap check later: root-fs free space and fragmentation after
~1 GB of burst writes, or paging pressure from 6 × 4 MiB copies plus a 4 MiB verify buffer on a
32 MB machine. Not investigated; recorded so it is not rediscovered as a new symptom.

## ISSUE-22 — the causal chain, closed 2026-07-29 by fault injection

> **Ledger: FIXED** — earlier record of ISSUE-22; the first ISSUE-22 section above carries the current one.

Root cause: **`wb040.s` leaked DFC into the interrupted copy** (section below for how it was found).
The natural event is far too rare to A/B — a 12-burst control run produced 25 DFC corruptions and
zero EFAULTs — so the corruption was injected instead, in the same place a leaking replay leaves it
and **before** the restore, which makes one test an A/B of the fix rather than of the mechanism
alone. Both halves ran in the same boot, one `.data` long apart, in two seconds (`68040-260729-03`):

```text
A  wb_dfc_on = 0   read_total=0        errno=14  injections=3    VERDICT EFAULT
B  wb_dfc_on = 1   read_total=1048576  errno=0   injections=40   VERDICT CLEAN
```

Serial during A reproduced the ISSUE-22 signature exactly — the same `w=2 ... rw=2 depth=1` that had
been captured by chance the previous day at a completely different address:

```text
WARNING: DBG userspace ODD fmt=7 fc=5 fa=80003228 ssw=85
WARNING: DBG krnxflt FAILEXIT w=2 va=80003228 rw=2 depth=1
```

With the fix on, the wrapper detected and repaired **40** corruptions during one 1 MiB read and the
read completed byte-complete; with it off, **3** were enough to abort it at zero bytes. Evidence:
`test-tools/issue22-misroute-260728.txt` and the injection logs beside it.

**Still open, and it is the last item:** a natural-rate A/B. What is proven is that a leaked DFC
produces this failure and that the fix neutralises it; what is not proven is that every historical
ISSUE-22 event was this leak. Supporting that: the identical signature, 218 natural leaks per boot
with the exact `1 → 5` pair, and Codex's census (`vm-map/ISSUE22-DFC-ARCH-STATE-AUDIT.md`, 7c314b2)
finding no other architectural state leaking out of the fault path — SFC excepted, which leaks the
same way from `ptest040.s:52` but has no victim path today and is deliberately left for its own
change.

## ISSUE-22 — how it was named on hardware, 2026-07-28: the fault is MISROUTED to the kernel resolver

> **Ledger: FIXED** — earlier record of ISSUE-22; the first ISSUE-22 section above carries the current one.

Full evidence: `test-tools/issue22-misroute-260728.txt` (+ the raw run and serial logs beside it).
Kernel `68040-260728-36`, copyback, six-way copy load, hit at burst 15 of 16:

```text
WARNING: DBG krnxflt FAILEXIT w=2 va=800C96B0 rw=2 depth=1
```

`va` is inside b2verify's own freshly `malloc`'d 4 MiB heap buffer and `rw=2` is a write — this is
`copyout` filling a user buffer during `read(2)`. The fault on that **user** page was handed to the
**kernel** resolver, whose stock `as_segat(&kas, userVA)` gate (verbatim at `0x5b19e`) cannot
succeed, so it returned unresolved **without calling `as_fault`** — which is exactly why the
`as_fault` FAIL logger stayed silent through every hit. `sf_fault` then delivered EFAULT.

**This refutes the depth-counter hypothesis by measurement.** `depth=1`, and `Lkx_depth` read live
through `/dev/mem` was 0 at rest both before the run and after the failure. The counter *is* global
and *is* held across a sleeping `as_fault` (Codex's static reading is right about that, and it stays
on the list as a latent defect), but it is not this bug.

**It also corrects an assumption written in the section below**: "a guarded MOVES fault has transfer
mode = user, so `k_trap` dispatches it to `usrxmemflt`". Usually true — the same run resolved on the
order of 90000 copyout page faults — but measurably not always, and one exception per run is enough
to abort an operation.

The routing has exactly one decision point, `k_trap 0x5a1ca: jsr userspace`, reached only when the
`u_nofault` pad is armed. `src/userspace040.s` reads the function code from the 040 SSW at
`frame+76`; what it reads in the failing case is the open question. `68040-260728-39` answers it: it
logs `fmt`/`fc`/`fa`/raw SSW for every non-user function code, counts the events in `.globl` longs
readable with `kpeek` (so the result does not depend on the serial capture), and carries the
candidate fix behind `us_reroute_on` — a one-`.data`-long A/B that runs inside a single boot.

The fix is safe by construction rather than by argument: with the pad armed, a "kernel" verdict on a
fault address ≥ `0x80000000` always ends in `as_segat(&kas, userVA) = NULL`, so the rerouted set is
exactly the set that fails today.

## ISSUE-22 — (SUPERSEDED 2026-07-29; kept as the record of what was true on 07-28) ⏳ was OPEN, and that day's clean runs were NOT attributable to the xpage fix

> **Ledger: FIXED** — earlier record of ISSUE-22; the first ISSUE-22 section above carries the current one.

> **Superseded.** ISSUE-22 was closed on 2026-07-29 by fault injection — the root cause was
> `wb040.s` not restoring DFC across the interrupted copy. See "ISSUE-22 — the causal chain, closed
> 2026-07-29 by fault injection" and "ISSUE-22 — ✅ ACCEPTED 2026-07-29" above. The section below is
> the honest state of knowledge on 07-28 and is kept because it is what made the injection test the
> obvious next step; do not read its OPEN marker as current.

**Codex's static verdict (XPAGE-COVERAGE-AUDIT.md, a61d2ac) refutes the equivalence hypothesis on
two independent grounds, and the hardware A/B agrees with it.**

1. **`u_nofault` does not turn a successful near-page resolve into EFAULT — it retries.** The armed
   sequence in `k_trap` is *resolve first, escape only on failure*: the resolver's zero reaches
   `0x5a20c`, the saved PC is **not** rewritten, and the instruction retries. Only a **nonzero**
   return installs the landing pad and reaches `sf_fault @0x5f2`, which is what becomes EFAULT.
2. **More decisively, `copyin`/`copyout` are not on the changed route at all.** A guarded MOVES
   fault has **transfer mode = user**, so `k_trap` dispatches it to **`usrxmemflt`**; today's block
   is inside `krnxmemflt_orig` and uses `&kas`. The relevant copyout crossing mechanisms were
   already the high-user `hardbus` helper and the 040 scalar write-back replay.

**The A/B confirmed it at runtime.** `xpage_on = 0` (`68040-260728-23`, two bytes from the shipping
image) ran the same 16-burst workload to completion: **`CLEAN (0 non-V0 in 16 bursts)`, 96/96
verifications**, exactly like the `xpage_on = 1` run, and both are far past the point where the
historical configuration failed twice. So **ISSUE-22 is simply not reproducing today**, on either
side of the flag, and neither clean run can be credited to the xpage fix.

**Both sides of the A/B: 96/96 V0.** That symmetry is the result — it is what turns "the fix worked"
into "the workload no longer triggers it, for a reason this flag does not control".

**What this changes:** ISSUE-22 keeps its own hunt. Codex specifies the latch fields — faulting PC
and FA, frame format, **original** SSW/FSLW, TM and the resolver actually selected, the `u_nofault`
landing pad, the primary `as_fault` return, and the next-page return if any. That last set is the
point: if the selected resolver returns nonzero, the nofault mechanism explains EFAULT, and the
current static evidence does not show crossing-page handling producing that nonzero.

**What it does not change:** ISSUE-22 was never a copyback blocker, and the two remaining copyback
items are recorded as ordinary acceptance (a longer all-V0 `b2verify` run + reboot disk-truth).
**Two independent 16-burst all-V0 runs now exist** (`xpage_on` on and off), which is most of the
first one.

### (superseded) NOT REPRODUCED on the xpage-fixed kernel; one-byte A/B built to attribute it

**2026-07-28, `68040-260728-18`:** `b2repro-copy.sh 16` -- the workload that reproduced ISSUE-22 on
23.7. -- ran **CLEAN: `0 non-V0 in 16 bursts`**, i.e. 96 verifications, every one
`V0_COMPLETE_MATCH` (full 4194304 bytes, identical CRC).

**The comparison is like-for-like, which is the part that matters.** The 23.7. runs that DID
reproduce it were both dbg builds -- `unix-040-dbg 68040-260723-07` (WT baseline, failed with
`cp: read: Bad address`) and `unix-040-b2-dbg 68040-260723-10` (copyback, `V1_EFAULT_TRANSIENT`) --
and both failed **inside the first two bursts**. So the older note that "the dbg kernel masks
ISSUE-22" is outdated for this workload: with burst4 pressure a dbg kernel reproduces it promptly.

That makes today's result strong evidence that the ISSUE-37 xpage fix also closed ISSUE-22, exactly
as the `u_nofault` reading predicts (no escape -> infinite loop; nofault escape -> EFAULT).

**What it is NOT yet: attributed.** `260723-07` and `260728-18` are five weeks of other fixes apart,
so something else in that delta could be responsible. Fixed the same way ISSUE-36's closure was made
defensible -- the xpage handling is now behind a runtime flag, so the A/B differs in **one flag byte**
in an otherwise identical image:

```text
build/unix-040-rtg-dbg          68040-260728-22   xpage_on = 1   (shipping)
build/unix-040-rtg-dbg-noxpage  68040-260728-23   xpage_on = 0   (control)
  the pair differs in exactly 2 bytes: the flag and one build-id character
```

`src/patch_xpage_flip.py` locates `xpage_on` through the symbol table, asserts the old value
and fails closed.

**The test:** boot `-23`, run `sh b2repro-copy.sh 16 noxpage`. If ISSUE-22's EFAULT returns at
~burst 2, the xpage fix is the cause of today's clean run and ISSUE-22 is closed with it. If `-23`
also runs clean, then something else in the five-week delta fixed it and this needs its own hunt
after all. Note the control run is **non-destructive if the hypothesis holds** -- `copyout` has
`u_nofault` set, so the defect surfaces as EFAULT rather than as ISSUE-37's unkillable loop.

This also matters for **B2/copyback**: ISSUE-22's transient EFAULT is the noise that made copyback
look guilty of disk corruption in July, and the two remaining copyback items are recorded as ordinary
acceptance (a longer all-V0 `b2verify` run + reboot disk-truth) rather than blockers. Today's 16-burst
all-V0 run is already most of the first one.

### (original entry) ISSUE-22: kertaluontoinen EFAULT (read: Bad address) paineessa bare basella

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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
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
pudottaa merkkejä dbg-floodissa (32b3296:n sivulöydös). Juurisyy luettu `src/serdbg.s`:stä:
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

> **Ledger: NOT A KERNEL BUG** — 68040 hardware -- rc6 userland. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
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

> **Ledger: DEFERRED** — documented: boot via unix_boot040. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
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

> **Ledger: OPEN** — good emulator repro; halt path only. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.
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

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

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
Codex-toimeksianto kirjoitettu → `docs/archive/PAGECREATE-TAILZERO-TASK.md`).**
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

> **Ledger: FIXED** — emulator, both CPUs. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**RATKAISTU `src/patch_memcntl.py` (17 sitea + 5 kanariaa), buildit 260725-05/-06.**
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

> **Ledger: OPEN** — single occurrence, attribution unproven. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**OPEN — OSUI RAUDALLA 27.7. (havainto #5) ja ei ole enää kohinaa.**
`DBG KMEMCORRUPT bin=80ED9F0 blk=40259300 next=8 prev=6 caller=8042334 size=1`, yksi osuma
332 kB lokissa, **funktionaalisen patterin aikana — EI paineen alla** (`pressure` 6/6 ja
`burst4` 24/24 ajoivat puhtaasti), mikä on itsessään tieto koska paine on se mistä sitä
odottaisi. Kolme uutta asiaa: (1) tapahtuu **piillä**, ei vain emussa; (2) **muoto täsmää
25.7. emu-havaintoihin** — sama caller, sama `next=8 prev=6` (26.7. 060-havainto oli eri
muotoinen, `next==prev`); (3) **caller 0x8042334 = `kmem_zalloc + 0x18`**, paluu
`kmem_alloc`-kutsusta → korruptoituneet blokit tulevat nimenomaan `kmem_zalloc`ista, ei
suoraan `kmem_alloc`ista eikä KMA-pooleista. Ja `next=8`/`prev=6` ovat **pieniä
kokonaislukuja siellä missä pitäisi olla pointtereita** — indeksi pointterin paikalla, ei
villi osoite eikä poison-kuvio. Viisi havaintoa samalla kutsujalla ja samalla muodolla.
Yhä **ei attribuoitu eikä jahdattu** (projektin oma sääntö), mutta seuraava askel on selvä:
kaikki `kmem_zalloc`-kutsujat joiden koko on 1 tai 0x8C.

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

> **Ledger: CONVERTED** — reachability unproven. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**MUUNNETTU 2026-07-25 (`patch_pvntrunc.py`, 2 sitettä + 2 kanariaa, buildit
260725-11/-12), mutta vikaa EI saatu toistettua UFS:llä.** Codexin
`PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md` luokitteli tämän P1:ksi.
Lähdekontrakti `svr4-src-3b2/.../vm/vm_pvn.c` `pvn_vptrunc()`:
`kzero(addr + (vplen & MAXBOFFSET), MAX(zbytes, PAGESIZE - (vplen & PAGEOFFSET)))`.
Tarkoitus, sellaisena kuin `ufs_inode.c`:n oma kommentti sen perustelee: viimeisen sivun
häntä nollataan, jotta tiedoston lopun jälkeen jäävää vanhaa sisältöä ei voi lukea uudelleen
siinä tapauksessa että tiedosto myöhemmin kasvaa ja tekee noista tavuista taas saavutettavia.
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

## ISSUE-31: ufs_bmap sivugeometria — ✅ MUUNNETTU (2026-07-25, emu-040+060)

> **Ledger: FIXED** — emulator, both CPUs. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**11 sitettä + 3 kanariaa (`patch_ufsbmap.py`), buildit 260725-13/-14.**
Tämä on ISSUE-27:n rajapinnan **UFS-provider-puolisko**: `rwip` syöttää `ufs_bmap`ille
4 KiB-johdetun `pagecreate`in `alloc_only`-argumenttina, mutta `ufs_bmap`in oma
`PAGESIZE`-aritmetiikka oli yhä 2 KiB. Lähdekontrakti
`svr4-v4/usr/src/uts/i386/fs/ufs/ufs_bmap.c`. Käyttäytymistä muuttava kohta on
rivit 398-399 ja 448: `} else if (!alloc_only || roundup(size, PAGESIZE) < bsize)`.
`fs_bsize` 8192:lla vanha 2 KiB -pyöristys vie koot **4097..6144** arvoon 6144 (< 8192 →
**LUE lohko**), uusi 4 KiB -pyöristys arvoon 8192 (→ **OHITA luku**). Ohitus on turvallinen
VAIN koska kutsuja täyttää nyt kokonaisia 4 KiB -sivuja — eli **ISSUE-27:n on pakko olla
landattuna ensin**, ja patch-skripti assertoi sen (`as_iolock` @0xaeeba = `andiw #-4096`)
ja kieltäytyy muuten ajamasta.
Muunnetut: 0x79d74, 0x79d7e (`blkpp`), 0x79d96, 0x79da4, 0x79daa (`nblks`), sekä
0x7a494/0x7a49e/0x7a4a4 (epäsuora allokointi) ja 0x7a520/0x7a52a/0x7a530 (synkroninen
kirjoitus) — kummassakin kaksi `addil` + `andiw` on YKSI `roundup`-lauseke
(etumerkkikorjausidiomi `+PAGEOFFSET / bpl / +PAGEOFFSET / &-PAGESIZE`).
**KANARIAT 0x79ec0, 0x79ee2, 0x7a030** (`moveq #11`) ovat **`NDADDR-1`
-suoralohkorajavertailuja**, EIVÄT `PAGESHIFT`iä — verifioitu disassemblysta muodossa
`moveq #11,%d7 ; cmpl <lbn>,%d7 ; blt`. Niiden muuntaminen siirtäisi UFS:n suoralohkorajaa
ja korruptoisi allokointialgoritmin. **Alkuperäinen toimeksiantoni listasi juuri nämä
kolme muunnettaviksi ja jätti kuusi oikeaa pois** — Codexin census korjasi sen.
**Hyväksyntä:** uusi `test-tools/bmaptest.c` ajaa Codexin listan (suora allokointi,
fragmenttikasvu, epäsuora allokointi, synkroninen kirjoitus, `fs_bsize` 8192) ja
tarkistaa KOKO tiedoston tavu tavulta: jokaisen tavun on oltava joko P1 (koskematon) tai
P2 (kirjoitettu). 11/11 OK sekä ENNEN (baseline 260725-12) että JÄLKEEN muunnoksen,
mukaan lukien erotteleva väli 4097..6144 jossa luku nyt ohitetaan. Lisäksi `proctest`,
`mlocktest`, `trunctest` PASS, ISSUE-27 ei regressoinut (pgcold E PRESERVED) ja
levytotuus `sum 8320 5763` `reboot`+`fsck`:n yli — **emu-040 ja emu-060**. Serialit puhtaat.
⚠️ EI testattu: `fs_bsize == PAGESIZE` tai pienempi (speksi: ei saa päätellä 8192-tuloksesta).
Ei rautaa.

## ISSUE-32: ELF-execin mäppäysrajapinta — ✅ MUUNNETTU (2026-07-25, emu-040+060)

> **Ledger: FIXED** — emulator, both CPUs. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**21 sitettä kolmessa atomisessa ryhmässä + 5 kanariaa (`patch_execboundary.py`),
buildit 260725-15/-16.** Codexin `EXEC-BOUNDARY-CENSUS.md` luokitteli tämän P1:ksi
("*more important than its raw site count because every normal `exec` exercises some
part of this boundary*").
- **`exhd`** (11): `exhd_getfbuf` + `exhd_nomap` ovat YKSI range-omistajuusyksikkö —
  molemmat operoivat samalla `exhdmap_t`-listalla, joten toisen muuntaminen yksin
  jättäisi listan ja sen vapautuspuolen eri sivugeometrioihin.
- **`execmap`** (6): tärkein on 0x57a68/0x57a72 = `(offset & PAGEOFFSET) == (addr &
  PAGEOFFSET)` -kelpoisuustesti. 2 KiB -maskilla loader voi pitää tiedosto-offsettia ja
  virtuaaliosoitetta samoin kohdistettuina vaikka ne EIVÄT ole samat modulo 4 KiB, ja
  valita suoran `VOP_MAP`-polun väärässä sivusuhteessa.
- **`elfsz`** (4) — **KORJAUS CENSUKSEEN.** Census listasi vain KULUTTAJAN (`elfexec`
  0xb8440/0xb8446, `if (*execsz > btopr(u+0x7d4)) ENOMEM`) ja merkitsi sen ehdolliseksi:
  *"convert or prove byte-unit exception"*. Todistus tehtiin ja se **muutti vastauksen**:
  `u+0x7d4` ON tavuarvo (`as_map` @0xae52a vertaa sitä suoraan tavumäärään), MUTTA
  **tuottaja on myös yhä 2 KiB** — `mapelfexec` @0xb85f0 kerryttää
  `*execsz += btoc(p_memsz)` kohdissa 0xb86fe/0xb8704. Nykyisin molemmat laskevat
  2 KiB -yksiköissä eli **rajatarkistus on oikein**; pelkän kuluttajan muuntaminen olisi
  tehnyt siitä kaksi kertaa tiukemman → turhia ENOMEM-execejä. Siksi ryhmä on 4 sitettä,
  ei 2. `mapelfexec` on LOKAALI symboli (`t`), minkä takia se jäi toimeksiannon
  raakahakulistalta pois ja census peri puutteen.
**KANARIAT:** 0x5677a (`exhd_getfbuf boff & MAXBMASK` = 8 KiB fbuf-ikkuna), 0x57c1c/
0x57c22 (`execmap` BSS-häntä, jo muunnettu), 0xb842c (`AT_PAGESZ = 4096`), 0xb8406
(`elfexec & MAXBMASK`). Näistä kaksi ensimmäistä ovat 8 KiB -ikkunoita jotka näyttävät
kuviohaussa täsmälleen sivumaskeilta.
**LYKÄTTY:** `coffcore` (9 sitettä, COFF-core-tiedostomuoto — vioittunut diagnostiikka-
artefakti, ei elävä osoiteavaruus), `getcoffhead`in COFF-puolen `*execsz`-tuottajat
(saavutettavissa vain `coffexec`in kautta; `getcoffshlibs`, joka ON saavutettavissa
ELF-execistä `PT_SHLIB`:n kautta, ei sisällä omaa `btoc`-sitettä, joten ELF-ryhmä ei
desynkronoidu), sekä `grow`/`brk` (jo 4 KiB, oma user-VM-yksikkönsä).
**Hyväksyntä:** uusi `test-tools/exectest.c` — ohjelma **tarkistaa oman alustetun
datansa ja BSS:nsä** joka käynnistyksessä ja **exec-ketjuttaa itsensä 20 sukupolvea**,
koska "binääri käynnistyy yhä" läpäisisi rikkinäiselläkin kernelillä. PASS sekä
kylmänä (rebootin jälkeen, binääri `/exectest.cold` jota ei ole luettu bootin jälkeen)
että residenttinä. Lisäksi `proctest`, `mlocktest`, `trunctest`, `bmaptest` PASS,
ISSUE-27 ei regressoinut (pgcold E PRESERVED), levytotuus `sum 8320 5763`
`reboot`+`fsck`:n yli — **emu-040 ja emu-060**. Serialit puhtaat.
⚠️ EI testattu: ELF-binäärit joiden `p_offset`/`p_vaddr` on tarkoituksella ristiriidassa
modulo 4 KiB (vaatisi käsin rakennetun ELF:n; natiivi `cc` ei anna kontrollia
segmenttikohdistukseen). Ei dynaamisesti linkitettyä `PT_INTERP`-polkua. Ei rautaa.

## ISSUE-33: /dev/mem-mmapin PFN oli 2 KiB — ✅ TODISTETTU JA KORJATTU (2026-07-25, emu-040+060)

> **Ledger: FIXED** — emulator, both CPUs. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**7 sitettä kahdessa ryhmässä + 7 kanariaa (`patch_devmmap2.py`), buildit 260725-17/-18.**
Kaventaa censuksen "P2: device mmap and PFN boundary" -kohdan niihin kahteen ylitykseen
jotka ovat oikeasti saavutettavissa. Lähdekontrakti `svr4-src-3b2/.../vm/seg_dev.c`.
**Ryhmä `pfn` (3 sitettä) — TODISTETTU ELÄVÄ VIKA.** `d_mmap` palauttaa PFN:n, ja
040-natiivi `hat_devload` (0xb4cec) mäppää sen `pfn << 12`. `mmmmap` (`/dev/mem`,
0x20688/0x2068e) ja `resmmap` (0xd7186) laskivat yhä `phys >> 11` = **kaksinkertainen
PFN** → mäppäys osui kaksinkertaiseen fyysiseen osoitteeseen. Sama vika jonka
`patch_devmmap_pfn.py` jo korjasi kolmelle sisarfunktiolle (`scrmmap`/`ammmap`/`timmap`,
fractal/julia-mustaruutu); ne assertoidaan nyt kanarioina.
**TODISTE (`test-tools/devmaptest.c` T1):** mmapataan `/dev/mem` fyysiseen 0x08000000
(kernelin latausosoite, siis varmasti nollasta poikkeavaa sisältöä).
`btop_2k(0x08000000) = 0x10000` → `hat_devload` mäppäisi `0x10000<<12` = 0x10000000 =
256 MB, RAM:n ulkopuolella → **nollia**. Mitattu: korjaamattomalla **0/4096** nollasta
poikkeavaa tavua, korjatulla **3186/4096**. Deterministinen, ja signaali on
provenienssiriippumaton.
**Ryhmä `incore` (4 sitettä).** `segdev_incore` (0xa838a/0xa8390/0xa839e/0xa83a4)
kirjoitti yhden tavun per **2048** tavua, mutta julkinen `mincore(2)` on jo 4 KiB
(`patch_mincore.py`), joten kutsuja mitoittaa vektorin `btopr_4k(len)`:iin →
kaksinkertainen kirjoitus. ⚠️ **Tätä EI saatu toistettua**: `devmaptest` T2 (kanaria
heti odotetun pituuden jälkeen) PASS sekä ennen että jälkeen. Staattinen argumentti on
aritmetiikkaa, mutta jokin estää ylivuodon — todennäköisesti `as_incore` rajaa. Landattu
kontraktikorjauksena, ei todistettuna vikakorjauksena.
**TARKOITUKSELLA MUUNTAMATTA JA ASSERTOITU ENNALLAAN:** loput segdev-perheestä
(`segdev_fault`/`dup`/`unmap`/`free`/`setprot`/`checkprot`/`getprot`, `spec_segmap`in
silmukka-askel 0x6766a). Se on **sisäisesti johdonmukainen** — vpage-taulukko mitoitetaan
ja indeksoidaan samalla `seg_page()`-shiftillä läpi perheen — ja sen kaksi ulkoista
ylitystä ovat harmittomia: (a) 2 KiB-askeleinen fault-silmukka kutsuu `hat_devload`ia
kahdesti per 4 KiB -sivu, mutta koska `d_mmap` palauttaa nyt 4 KiB PFN:n molemmat kutsut
kantavat SAMAA pfn:ää ja `hat_devload` pyöristää osoitteen sivulle → **idempotentti**
(tämä selittää miksi jo landattu scrmmap-korjaus toimi muuntamattoman segdevin kanssa);
(b) `segdev_getprot`in vektoritäyttö ajetaan vain kun `len > 0`, ja sen ainoa kutsuja
`as_getprot` (0xaecfc, vm_as.c:945) antaa `len = 0` ja osoittimen yhteen `int`:iin.
`spec_segmap` 0x67694 `moveq #12` on `return ENOMEM`, **neljäs errno-valeosuma** tässä
kampanjassa.
**Hyväksyntä:** `devmaptest` PASS, ja koko patteri (`exectest`, `proctest`, `mlocktest`,
`trunctest`, `bmaptest`) PASS + levytotuus `sum 8320 5763` — **emu-040 ja emu-060**.
Serialit puhtaat. ⚠️ Ei rautaa; VA2000/Piccolo-kortteja ei testattu tällä.

## ISSUE-34: JAKAUTUU KAHTEEN — 34a (todistettu) 68060 tappaa vakiojaon; 34b (auki) cc1:n SIGSYS ei ole tämä

> **Ledger: 34a FIXED / 34b SUPERSEDED** — 68060 hardware -- 34b was the missing FPSP after all. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

> **⚠⚠ KORJAUS 5.8.2026, RAUDALLA MITATTU — alla oleva "ketju on puhdas" ei pidä paikkaansa
> sillä koneella jolla ajamme.** Ks. `docs/060-F0-MEASUREMENT-260805.md`.
>
> Oikealla 68060:llä `cc` kuolee heti, ja konsoli nimeää syyn itse:
> `SIGKILL sent to pid 263 (.../2.7.2.3/cpp ...) because of vector 0xF4, pc=0x80006ED6`
> — 0xF4/4 = **vektori 61**, ja `0x80006ED6` on `mulsl #-2078209981,%d0,%d1` (ext 0x1c00,
> bit10 = 1 = 64-bittinen tulos). Enkooderipohjainen skannaus (`test-tools/scan060.py`):
> **cpp 2 osumaa, cc1 104 osumaa**; `libc.so.1`, `ld.so.1`, `as` ja `ld` = **0**.
>
> Kaksi syytä miksi alla oleva taulukko sanoi "clean", kumpikin todennettavissa:
> 1. **Se skannasi eri binäärit.** Vanillan `gcc-cc1` on 666 440 B ja `gcc-cpp` 46 468 B;
>    koneella `/usr/local/lib/gcc-lib/m68k-cbm-sysv4/2.7.2.3/` sisältää `cc1` 1 250 916 B ja
>    `cpp` 92 296 B. Dokumentin oma varaus ("nämä ovat VANILLA-asennuksen binäärit") oli
>    oikea ja se osui juuri tähän.
> 2. **Mittari itse.** Tämän puun 2.8.1-aikainen `objdump` tulostaa 64-bittisen muodon
>    pilkulla (`mulsl #imm,%d0,%d1`), EI Motorolan `Dh:Dl`-merkinnällä — grep joka etsii
>    `:%d`-parin raportoi puhtaaksi tiedoston joka on niitä täynnä. Toistin tämän virheen
>    itse tänään ennen kuin vaihdoin enkooderipohjaiseen tarkistukseen.
>
> **Luokkapäätelmä "käskykantaluokka on SULJETTU POIS" on siis kumottu** koneen omilla
> binääreillä.
>
> **`cc1` MITATTU SUORAAN — se on 34a, ei 34b.** Rikkinäisen gcc-cpp:n voi ohittaa
> esikäsittelemällä AT&T:n cpp:llä ja syöttämällä `.i`:n suoraan:
> `/usr/ccs/lib/cpp x.c > x.i` (rc=0), sitten `cc1 x.i -o x.s` → **`Killed`, rc=137 =
> 128+9 = SIGKILL**, konsoli: `vector 0xF4, pc=0x80021530` — ja `0x80021530` on skannauksen
> listassa `mulsl #-2115558717,%d1,%d0`. **Alkuperäinen 34b-havainto (cc1 = SIGSYS 12) ei
> toistu tällä raudalla**; se sopii siihen että se tehtiin vanillan cc1:llä (666 440 B,
> aidosti puhdas) tai emussa, ei asennetulla 1 250 916 B:n binäärillä.
>
> **SIGSYS on silti olemassa ja sillä on nyt pienempi koti:** AT&T:n `/usr/ccs/lib/acomp`
> kuolee **status 140 = 128+12 = SIGSYS** liukulukukoodissa (`test-tools/fpmin3.c`: double-
> palauttava silmukka), mutta kääntää kokonaislukukoodin ongelmitta (`fpmin1.c`, `fpmin2.c`).
> **Negatiivinen todiste raudalta:** kernelissä on täsmälleen yksi tällainen viesti
> (`u_trap WARNING: SIGKILL sent to pid %d (%s) because of vector 0x%x, pc=0x%x`), eli se
> ilmoittaa VAIN SIGKILL-tapot — ja koska jokainen vektori-61-tappo tulosti rivin mutta
> acompin kuolema ei tulostanut mitään, **acomp ei kuole vektoriin 61.** Vektorin numero
> vaatii `nullvect`-proben; vektori 11 (060-FPU) on yhä hypoteesi.
>
> Käyttökelpoinen kiertotie mittauksille: **`/usr/ccs/bin/cc`** (AT&T:n alkuperäinen ajuri,
> 1991) kääntää natiivisti 060:llä — se emittoi `divsll` (32-bit dividend) eikä magic
> multiplyä. `test-tools/mkall060.sh` kääntää patteriston sillä (13/14; `fputest` vaatii
> ristikäännöksen, ks. `fputest060.c`).

**⚠ KORJAUS 27.7. iltapäivä, samana päivänä kirjattu.** Kirjasin aamulla juurisyyn
"todistetuksi" koko ISSUE-34:lle. Se oli liian laaja. Se signaaliero jonka merkitsin
auki-jääväksi (`cc1` = 12/SIGSYS, eristetty repro = 9/SIGKILL) osoittautui ratkaisevaksi.

**Suora todiste:** purin guestin koko kääntäjäketjun READ-ONLY vanilla-puusta ja laskin
68060:lle toteuttamattomat käskyt:

```
gcc (driver)   72 896 B  clean      gcc-gnulib    36 354 B  clean
gcc-cc1       666 440 B  CLEAN      libc.so.1    206 876 B  clean
gcc-cpp        46 468 B  clean      libc.a       469 242 B  clean
                                    ld.so.1      111 104 B  clean
```

**`cc1` ei sisällä yhtäkään käskyä jota 68060 ei toteuta.** Eli `muls.l`/vektori-61-vika,
joka ON todellinen ja ON todistettu, **ei ole se joka rikkoo `cc1`:n.** Kaksi eri vikaa:

* **ISSUE-34a — TODISTETTU.** 64-bittinen `muls.l`/`divs.l` tappaa minkä tahansa
  käyttäjäprosessin 68060:llä koska `M68Kvec[61]` on `nullvect`. Yhden käskyn eristetty
  repro, 6/6 korrelaatio suiten yli. Seisoo täysin omilla ansioillaan. Yksityiskohdat alla.
* **ISSUE-34b — RATKAISTU MEKANISMILTAAN 7.8.2026, korjaus kesken (F3).** Juurisyy on
  mitattu eikä enää päätelty: 040:n FPSP on `cputype`-portitettu pois (`fpsp_glue040.s`),
  joten **060:llä ei ole mitään FP-tukipakettia** ja toteuttamaton FP-käsky putoaa
  `nullvect`iin = SIGSYS. Käyttäjätilan koe oikealla 060:llä (`test-tools/fp060probe.c`):
  `fsin/fetox/flogn/fmovecr` kuolevat signaaliin 12, `fadd/fsqrt/fintrz` eivät. Ja M0:n
  vektoriprobe mittasi vektorin suoraan: `kvp_vec[11]` 0 → **4** yhden `fp060probe`-ajon yli.
  **`fmovecr` on tavallinen tapaus, ei eksoottinen** — se lataa FPU:n ROM-vakiot (0.0, 1.0),
  gcc käyttää sitä liukulukuvakioihin, ja userland-skannaus laski 287 esiintymää. Siksi
  `x = 1.0;` riittää tappamaan prosessin. Kirjanpito `docs/060-FPU-STATE-260807.md`, korjaus
  `docs/060-F3-FPSP-PLAN-260807.md` (M0/M1 valmiit, M2a kytkentä todistettu, M2b kesken).
  ⚠ Alla oleva vanha analyysi on osin kumottu: `cc1` kuolee **vektoriin 61**, ei SIGSYS:iin
  (F0), joten alkuperäinen havainto lepää `acomp`in varassa. Historia säilytetty sellaisenaan.
* **ISSUE-34b — vanha analyysi (osin kumottu, ks. yllä).** `cc1` kuolee SIGSYS:iin (12) 060:llä ja toimii 040:llä. Koko
  kääntäjäketju on puhdas toteuttamattomista käskyistä, joten **käskykantaluokka on
  SULJETTU POIS suoralla todisteella.** SIGSYS on kirjaimellisesti "bad system call", mikä
  siirtää haun **syscall-/trap-polulle** eikä ISA:aan. Mikä 060:llä eroaa meidän
  kernelissä: `wb060.s`, `lmul060.s`, cputype-gatet ja neljä FPU Tier-1 -overridea — sekä
  060:n erilaiset exception-frame-formaatit.
  *Varaus skannauksesta:* nämä ovat VANILLA-asennuksen binäärit; emu boottaa X11R5-net-
  imagen jonka kääntäjä ei välttämättä ole tavuidenttinen. Luokkapäätelmä (ketju ei käytä
  näitä käskyjä) on kestävä, yksittäinen offset-väite ei olisi.
  **Seuraava askel on instrumentointi, ei päättely:** probe joka kirjaa vektorinumeron
  (exception-framen format-sana, `%sp@(66)` `nullvect`in `moveml`in jälkeen) ja faulttaavan
  PC:n — se vahvistaisi myös 34a:n vektorin suoraan eikä päättelemällä.

---

### ISSUE-34a: 68060 tappaa minkä tahansa käyttäjäohjelman joka jakaa vakiolla — vektori 61 ei ole kytketty

**OPEN, JUURISYY TODISTETTU 2026-07-27. Paljon isompi kuin alkuperäinen otsikko
"natiivi cc ei toimi".** Emu-040 + emu-060, dbg 260726-02. Ei rautaa — eikä tässä
projektissa OLE oikeaa 68060:tä, joten tätä ei voi vielä rautavarmistaa.

**Ketju:**
1. gcc emittoi vakiojaosta `muls.l <ea>,Dh:Dl` — **64-bittisen tuloksen** muodon
   (magic-number-käänteislukukertolasku). Tämä on tavallista optimoitua koodia, ei
   eksoottinen rakenne: `x / 100` tuottaa sen.
2. **68040 toteuttaa sen raudassa. 68060 EI** → Unimplemented Integer Instruction,
   **vektori 61**.
3. **`M68Kvec[61] → nullvect`** — verifioitu binäärista (samoin 60/62/63). Mikään ei
   käsittele sitä.
4. `nullvect` testaa talletetun SR:n S-bitin ja ohjaa user-moden `u_trap`iin, jossa ei
   ole tapausta vektorille 61. Prosessi kuolee.

**Eristetty repro — yksi käsky, ei muuta.** `test-tools/mul64test.c`, ristikäännettynä
tarkalleen YKSI epäilty käsky (ext=0x1c02: bit11 signed=1, **bit10 size=1 = 64-bit**):

```
8000042c   mulsl #1374389535,%d2,%d1
emu-040:  MUL64 before / MUL64 after q=12345 / MUL64-RESULT PASS   exit=0
emu-060:  MUL64 before / Killed                                    exit=137 (SIGKILL)
```

Sama binääri, sama golden image, vain CPU eroaa. Kuolee täsmälleen kertolaskuun.

**Korrelaatio koko testisuiteen yli — täydellinen 6/6:** 0 epäiltyä käskyä → toimii
060:llä (`proctest`, `exectest`, `msynctst`); ≥1 → tapetaan (`mul64test` 1,
`bmaptest` 3, `pgcold` 3); kaikki toimivat 040:llä. **Siksi 060-linja on näyttänyt
terveeltä: jokainen sillä koskaan ajettu testi sattui olemaan ilman näitä käskyjä.
Se oli onnea, ei kattavuutta.**

**Miksi tämä jäi huomaamatta — viikon toistuva kuvio jälleen.** Projekti TIESI
vektori-61-faktan. `src/lmul060.s`:n oma otsikko sanoo: *"The 64-bit mul/div forms
are UNIMPLEMENTED on the 68060 (vector 61 trap); these are the ONLY such sites in the
whole kernel (census 2026-07-09)."* Census oli oikea ja korjaus oikea — **kernelin omat**
kolme sitea `lmul`issa korvattiin 060-laillisella aritmetiikalla (validoitu muls.l-
referenssimallia vasten, 202500 tapausta, 0 eroa). Mutta census oli rajattu "koko
kerneliin", joten **user space ei ollut siinä koskaan** eikä vektoria 61 kytketty
mihinkään. Toinen puoli rajasta hoidettu, toinen jätetty — sama muoto kuin
ISSUE-27/28/31/32, paitsi että raja on tässä kernelin sisäinen vs. user mode.

**YKSI ASIA JOKA EI TÄSMÄÄ, JÄTETÄÄN AUKI:** alkuperäinen havainto oli
`cc1 got fatal signal 12` (SIGSYS), eristetty repro antaa **signaali 9** (SIGKILL). Sama
vektori tuottaisi saman signaalin, joten joko `cc1` osuu **eri** muotoon tai vektoriin
(60 = unimplemented effective address on ilmeinen toinen ehdokas), tai `u_trap`in
lopputulos riippuu prosessitilasta jota en tunnistanut. **EI RATKAISTU.** Seuraava askel
on trap-probe joka kirjaa vektorinumeron ja faulttaavan PC:n — ei enempää päättelyä.

**Korjausvaihtoehdot:**
1. **Motorolan 68060SP ISP** (Integer Support Package) kytkettynä vektoriin 61. Virallinen
   vastaus, ja tämä löydös on paljon vahvempi syy hankkia 060SP kuin kääntäjä oli: ilman
   sitä 68060-tuki ei ole vain epätäydellinen vaan **epäluotettava tavalliselle koodille.**
2. Kohdennettu vektori-61-käsittelijä joka emuloi vain 64-bittiset
   `muls.l`/`mulu.l`/`divs.l`/`divu.l`-muodot. **Kertolaskun aritmetiikka on jo puussa ja
   validoitu** (`lmul060.s`); puuttuu trap-framen käsittely, käskydekooderi ja tulosten
   takaisinkirjoitus. Se liima on työ, ei matematiikka.
3. Ei korjaus vaan kierto: vältä muotoja 060-user-koodia käännettäessä. gcc 2.8.1:ssä ei
   ole `-m68060`, joten tähän ei voi nojata.

**Toimenpiteet nyt:**
* Ristikäännöskierto 060-testaukseen (26.7.) on kapeampi kuin väitin: **3/8 testiä ei
  linkity ristiin lainkaan** (`plock`, `ftruncate`, `mincore` puuttuvat cross-sysrootin
  libc:stä), ja linkittyvistä ne joissa on 64-bittinen kertolasku eivät voi ajaa 060:llä.
  Nykyinen 060-kattavuus on: `proctest`, `exectest`, `msynctst`, `fputest`. Siinä kaikki.
* **Älä lue "emu-060 regression PASS" todisteeksi 060:stä yleisesti** ennen kuin vektori 61
  on käsitelty. Se tarkoittaa "nämä neljä testiä menevät läpi", ei enempää.

Evidenssi: `test-tools/issue34-060-unimpl-integer-260727.txt`.

## ISSUE-35: NFS-kirjoitus menetti PUOLET JOKAISESTA SIVUSTA — ✅ KORJATTU JA TODISTETTU 27.7.

> **Ledger: FIXED** — 68040 hardware, byte-verified from the server. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**✅ SULJETTU 2026-07-27 illalla.** Korjaus `src/patch_nfs_putpage.py` (2 atomista
sitea), buildit 68040-260727-07/-08. **Ennen/jälkeen todistettu oikealla raudalla
palvelimen puolelta.** Evidenssi `test-tools/issue35-nfs-putpage-fix-260727.txt`.

**⚠ ALKUPERÄINEN KARAKTERISOINTINI (alla) ALIARVIOI VIAN OLENNAISESTI.** Sanoin "8192:n
monikerta menettää viimeiset 2048 tavua". Tavutotuustesti palvelimen puolelta näyttää
todellisen kuvion:

```
kerneli 260727-01 (pre-fix), nfstruth + nfstruth-verify.py, palvelimelta luettuna:
  truth4096    size  2048/ 4096   hukatut (sivu,puolikas): —
  truth8192    size  6144/ 8192   (0,1)
  truth12288   size 10240/12288   (0,1) (1,1)
  truth16384   size 14336/16384   (0,1) (1,1) (2,1)
  truth24576   size 22528/24576   (0,1)…(4,1)
  truth32768   size 30720/32768   (0,1)…(6,1)
  -> NFSTRUTH-VERIFY-RESULT FAIL (6/6 tiedostoa rikki)
```

**JOKAISEN 4 KiB -sivun YLEMPI 2 KiB -puolikas jäi kirjoittamatta.** Se 2048 tavun
kokopuute on vain saman kuvion häntä. Myös `4096` ja `12288`, jotka kokosweepissäni olivat
"OK", ovat rikki.

**Miksi kokosweepini näytti paremmalta — testisuunnitteluvirhe, ISSUE-27:n oppi uudestaan:**
käytin `dd bs=1`, eli yksi tavu per `write()`. Silloin sivut likaantuvat yksitellen,
`nfs_putpage`in klusterointisilmukka ei kerää mitään ja 2 KiB:n `io_len` sattuu riittämään.
Realistisilla monen kilotavun kirjoituksilla klusterointi käynnistyy ja katkaisee joka sivun.
**Kokoa mittaava testi ei riitä; tavut on verrattava palvelimen puolelta.** (Codex varoitti
tästä ennen ajoa: *"12288 reporting the right size does not clear its first 8192 bytes"*.)

**Korjattu tulos samalla testillä, kerneli 260727-08:**
`NFSTRUTH-VERIFY-RESULT PASS (0/6 rikki)` — kaikki kuusi tiedostoa, jokainen tavu.
Kernelit eroavat **täsmälleen 4 tavussa**: kaksi ISSUE-35-immediatea, `sysconfig`in sivukoko,
buildid.

**Attribuutio: MEIDÄN.** Codex staattisesti (`vm-map/NFS-REALHW-ISSUE35-FOLLOWUP.md`):
stock-030:ssa sama koodi on oikein, koska `page_t`-offsetit ja `io_len` edistyvät 2048:lla
yhdessä. Model B siirsi sivupopulaation 4 KiB:iin ja jätti `io_len`in 2 KiB:iin.

**Korjaus (minimi atominen yksikkö, molemmat tai ei kumpaakaan):**
```
0x8b9de   263c00000800 -> 263c00001000    io_len = PAGESIZE
0x8ba2c   068300000800 -> 068300001000    io_len += PAGESIZE
```
Pelkkä `0x8ba2c` ei tee mitään; pelkkä `0x8b9de` kuvaisi kaksi 4 KiB -sivua 6144 tavuna.
`nfs_putpage`in neljä muuta sitea jäävät muuntamatta ja ovat kanarioina.
**Jäljellä:** lukupuoli (`nfs_getapage`/`nfs_getpage`, 13 sitea) — Codexin suositus on
`pl[]`-kapasiteettikoetin, `vm-map/RESIDUAL-PROBE-PRIORITY-260727.md`.

---

### (historia) alkuperäinen kirjaus: NFS-kirjoitus menettää 2048 tavua kun tiedoston pituus on 8192:n monikerta

**OPEN, TODISTETTU RAUDALLA 2026-07-27, attribuutio ei todistettu.** Löytyi rautasession
ENSIMMÄISESSÄ NFS-kirjoituksessa (A3000 + Mercury 68040, kerneli 68040-260727-01). **Ei osa
sitä deltaa jota sessio validoi** — ennestään olemassa ollut vika jota ei ollut koskaan ajettu.

**Vika:** tiedosto jonka pituus on **8192:n tarkka monikerta** menettää täsmälleen viimeiset
**2048 tavua** kirjoitettaessa NFS:lle.

```
pyydetty   talletettu  hukattu        pyydetty   talletettu  hukattu
   100        100         0             10240      10240        0
  2048       2048         0             12288      12288        0   <- 3x4096, EI 8192:n mon.
  3000       3000         0             16384      14336     2048   <- 2x8192
  4096       4096         0             24576      22528     2048   <- 3x8192
  6144       6144         0             32768      30720     2048   <- 4x8192
  8192       6144      2048  <- 2x8192  4194304   4192256    2048   <- 512x8192
```

**Kontrollit jotka tekevät tästä kernelivian:**
* **paikallinen kontrolli PUHDAS** — sama `dd bs=1 count=8192` paikalliselle UFS:lle 3/3 oikein
* **deterministinen** — 3/3 identtistä lyhyttä kirjoitusta
* **ei flush-viive** — `sync` + 5 s ei muuttanut kokoja
* **palvelimelta varmistettu ERI clientilla ja ERI protokollalla** — luettu Linuxista SMB:llä:
  4 192 256 tavua, **tiedosto loppuu sivun offsetiin 2048/4096** → viimeisen 4 KiB -sivun
  YLEMPÄÄ 2 KiB -puolikasta ei kirjoitettu koskaan

**Mekanismi:** 8192 = MAXBSIZE / segmap-slotti, 2048 = vanhentunut sivukoko. `nfs_putpage`
laskee write-out-laajuuden 2 KiB -aritmetiikalla 4 KiB -sivupopulaatiota vasten, ja tarkalla
lohkorajalla viimeinen puolisivu jää lasketun välin ulkopuolelle. **ISSUE-27:n luokka**
(tuottaja 4 KiB, kuluttaja 2 KiB).

**Korjaus on jo kartoitettu:** `nfs_putpage`, **6 muuntamatonta sitea**,
`amix-kernel-analysis/vm-map/NFS-PROVIDER-RESIDUAL-CLOSURE.md`. Codex asetti sen
toteutusjärjestyksen ykköseksi ja ennusti sille "palvelimelta tarkistettavan
datanmenetystestin" — **ennuste osui, eikä se edes tarvitse `mmap`ia.** Kolme NFS-ryhmää
voivat landata erikseen; `putpage` ensin.

**⚠ ATTRIBUUTIO EI TODISTETTU.** Yhdenmukainen Model-B-epäsymmetrian kanssa (2 KiB -kernelillä
tuo aritmetiikka olisi oikein → olisi meidän regressio), mutta **erotinta ei ole ajettu**:
boottaa stock 030-kerneli TAI 040-kerneli jossa `nfs_putpage` on muunnettu.

**Käytännön vaikutus:** jokainen 8 KiB:n tarkka monikerta joka kirjoitetaan NFS:lle tältä
koneelta katkeaa hiljaa 2 KiB lyhyemmäksi — tar-arkistot ja varmuuskopiot mukaan lukien.

Evidenssi `test-tools/realhw-verify-260727.txt` §5; testitiedostot NAS:issa
`amix/hwtest-260727/`.

## ISSUE-36: NFS-tiedoston mmap SIGBUSaa viimeisellä OSITTAISELLA sivulla

> **Ledger: FIXED** — 68040 hardware, A/B. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**OPEN, TODISTETTU RAUDALLA 2026-07-27**, kerneli 68040-260727-08 (ISSUE-35:n korjaus jo
paikallaan). Löytyi ajamalla Codexin määrittelemä lukupuolen testi — **mutta tämä ei ole se
vika jonka hän ennusti**, ks. alla.

**Vika:** tavun koskettaminen mmapatun NFS-tiedoston viimeisellä **osittaisella** sivulla
nostaa SIGBUSin. `read()` samasta tiedostosta toimii. Sama tiedosto paikallisella UFS:llä
toimii.

```
tiedosto  fs    pituus        mmap-hännän kosketus   exit
8192      NFS   2 x 4096      p[8191]   OK             0
12288     NFS   3 x 4096      p[12287]  OK             0
8315      NFS   8192 + 123    p[8314]   BUS ERROR    138
16507     NFS   16384 + 123   p[16506]  BUS ERROR    138
8315      UFS   8192 + 123    p[8314]   OK             0   <- paikallinen kontrolli
8315      NFS   read()/sum                             0   <- RPC-polku on kunnossa
```

Predikaatti on siis **"tiedoston pituus ei ole 4096:n monikerta"**, ja faulttaava osoite on
tiedoston sisällä (tavu `sz-1`).

**Isolointi korjasi ensilukemani:** kerneli sanoi
`as_fault FAIL addr=C103507A rw=1 ret=E05` + `User BUS ERROR at C103507A`. Luin ensin
`0xC1xxxxxx`:n libc:ksi ja `rw=1`:n kirjoitukseksi, eli oman testini bugiksi. Molemmat väärin:
minimirepro (`test-tools/rdmin.c`) näytti että `mmap` palautti `p=0xc1033000`, ja
`0xC103507A − 0xC1033000 = 0x207A = 8314 = p[sz-1]` **täsmälleen**. Ja `ret=0xE05` =
`FC_MAKE_ERR(14)` eli **fault-resolveri palautti EFAULT** — sivun tuonti epäonnistuu, pääsy ei
ole laiton.

**Missä se asuu:** Codexin dokumentoima lukupuolen ryhmä `nfs_getapage`/`nfs_getpage`,
**13 sitea**, joihin hän mainitsee kuuluvan "EOF allowance". Viimeisen sivun page-in on
sallittava vaikka tiedosto loppuu sivun keskelle; 2 KiB -geometrialla laskettu sallittavuus
hylkää 4 KiB -pyynnön. Yhdenmukainen sen kanssa että alempi `nfs_strategy → do_bio → nfsread
→ XDR` on tavupohjainen — juuri siksi `read()` toimii.

**ERI VIKA KUIN `pl[]`-invariantti.** Codexin vahvimmaksi arvioima lukupuolen vika on
kapasiteettirikko (`plsz = 4096` vs `sz -= 2048` per sivu, `nfs_getapage` @0x8b26c) ja se on
**yhä verifioimatta** — se vaatii kernelin puolen proben. Tämä löydös on musta laatikko ja
kova virhe samassa 13 sitteen ryhmässä, eli **parempi peruste ryhmän muuntamiselle** kuin
invarianttiprobe olisi ollut.

**Vakavuus:** lähes jokaisen tiedoston pituus ei ole sivun monikerta → käytännössä **NFS:n
mmap ei toimi tällä portilla**. Kova virhe eli turvallisempi kuin hiljainen korruptio, mutta
ei kulmatapaus. **Ei testattu:** osuuko binäärin `exec` NFS-mountilta samaan polkuun — exec
mappaa text/data ja jokaisen binäärin viimeinen sivu on osittainen.

**Ei korjausta, ei kernel-probea.** Korjausehdokas on se 13 sitteen yksikkö; EOF-allowance-
sitet ovat todennäköinen paikka, mutta **mikä site tuottaa tämän ei ole selvitetty** — ja se
on sama kysymys joka teki ISSUE-35:n korjauksesta pienen (2/6 sitea) eikä sokean kuuden
sitteen konversion.

Evidenssi `test-tools/issue36-nfs-mmap-tail-sigbus-260727.txt`, repro `test-tools/rdmin.c`.

## Käytännön sääntö (ei issue): `%` ja vakiojako ovat 68060-miinoja käyttäjätilan koodissa

Seuraa ISSUE-34a:sta, mutta on tarpeeksi tärkeä ja tarpeeksi helppo unohtaa että se ansaitsee
oman merkintänsä. Löytyi 27.7. kirjoittaessa `test-tools/busbench.c`:tä.

68060 ei toteuta **64-bittisiä** `muls.l`/`divs.l`-muotoja. m68k-gcc emittoi niitä KAHDESTA
tavallisesta C-rakenteesta:

1. **jako VAKIOLLA** → magic-number-käänteislukukertolasku → `muls.l <ea>,Dh:Dl` (64-bit)
2. **`%`-operaattori** → jakomuoto joka palauttaa sekä osamäärän että jakojäännöksen →
   `divs.l <ea>,Dr:Dq`. **objdump erottaa nämä:** `divsll` = 32-bittinen (060 OK),
   **`divsl` = 64-bittinen (060 tappaa prosessin)**.

`busbench.c`:n ensimmäinen versio sisälsi molemmat. Kierrot:

```c
static volatile long D100 = 100L;   /* volatile estää magic-multiplyn */
q = x / D100;
r = x - q * D100;                   /* EI `%` */
```

**Tarkista aina 060:lle tarkoitettu käyttäjätilan koodi:**
```sh
m68k-linux-gnu-objdump -d prog | grep -E '\b(mulsl|mulul|divsl|divul)\b'
# ja dekoodaa laajennussanan bitti 10: 1 = 64-bittinen = 060 tappaa
```

Tämä selittää osan siitä miksi `bmaptest` ja `pgcold` kuolivat emu-060:llä 27.7. — ne
sisältävät vakiojakoja. `proctest`/`exectest`/`msynctst` eivät, ja ne toimivat.
Ks. ISSUE-34a, `test-tools/issue34-060-unimpl-integer-260727.txt`.

## 060 XPAGE unit — LANDED 2026-07-28, static + both-CPU regression only

> **2026-08-01 correction:** the original heading said "no 060 hardware exists". That was wrong --
> a 66 MHz 68060 on a Mercury adapter has been available all along, so the runtime acceptance
> Codex asks for in `M68060-XPAGE-ACCEPTANCE.md` (does a hardware format-4 frame deliver FSLW.MA?)
> is schedulable, not blocked.

Codex's `XPAGE-COVERAGE-AUDIT.md` (a61d2ac) specified six items as **one frame-aware unit**, for the
stated reason that changing only the address threshold leaves the status loss and the nonconvergence
intact. All six are now in (`c8d2cc0`, `cfb6ef0`):

| # | item | where |
|---|---|---|
| 1 | preserve the original format-4 FSLW before `wb060_sswsynth` destroys its upper word | `wb040.s`: sswsynth returns it; the wrapper carries it in `d5` |
| 2 | use MA to select `round_page(FA)` instead of `FA&0xfff >= 0xff8` | `wb060_xpage` tier 1 |
| 3 | pass the real read/write/RMW classification, not `S_READ` | `wb060_xpage` tier 1 + the 040 native block |
| 4 | propagate a permanent far-page failure instead of restoring a saved zero | both wrappers honour `wb060_xpage`'s return; the 040 MA tier keeps its own |
| 5 | gate the native kernel helper so the 060 does not resolve twice | `krnxmemflt040`: format-7 test |
| 6 | prefer SSW MA over a raw address window on the 040 | `krnxmemflt040`: MA tier |

**Both the 040 and 060 keep a second tier**: MA set takes the new path and propagates; MA clear but
within the last eight bytes behaves exactly as the shipped code did, result discarded. So each change
is a **strict superset** of the behaviour that was actually proven on hardware. That matters most for
`d5`: `wb040_replay` runs between the synthesis and the crossing helper and clobbers `d0-d3`, which
is why the carried FSLW lives in a register the wrapper saves per invocation — nest-safe without a
static.

**040 REGRESSION CLEARED ON HARDWARE (`68040-260728-29`, cold boot).** The unit's new logic is
format-4 gated, but it changed the *shared wrapper prologue* on the 040 path too -- the `d5`
save/restore, the `moveml` set from five registers to six, and honouring `wb060_xpage`'s return --
and that runs on **every** 040 fault. wolf3d is the hardest exercise of that path available and it
came back clean:

```text
uptime 1 min (pre-flight) -> 5 min (after)   never reset, so no kernel loop
wolf3d exited on its own, no new core, load 0.00, shell responsive throughout
serial: 0 bytes during the run -- as_fault REPEAT 0, segat LOOP 0, BUS ERROR 0, SIG 0, FAIL 0
```

**And this time the silence is evidence, because the instrument was BRACKETED.** A deliberate
`kill -9` (which must print `DBG SIG sig=9`) was fired **before** the run (+1831 bytes) and **after**
it (+493 bytes), with the same capture process holding the port throughout. Earlier today the same
0-byte reading came from a capture that had died, and it was nearly recorded as the strongest
possible result. Verifying only beforehand is not enough either: a capture can die mid-run and
produce identical silence. **Bracket the instrument.**

**Verification is honest about its limit.** There is no 68060 in this project, so the MA tier is
verified statically and by boot regression on both CPUs (0 faults, idle reached, relocs 0, plus a
1.4 MB byte-verified copy round trip on the 060). Amiberry's 060 is not assumed to model MA
faithfully, so a green emulator run is not evidence that the MA path executes at all.

**Two of my own bugs were caught in review before building**, recorded because this file is delicate:
a first draft stashed the FSLW at frame+88 (that is `WB3A` in the 040 layout, and past the end of a
shorter format-4 frame), and a second returned `d1` after the RW test had masked it to bits 24-23.

**Left alone deliberately:** `hardbus` keeps its OR-of-results behaviour on the proven high-user path.
Fixing its negative-boundary flaw would change behaviour that cannot be tested here.

## Copyback (B2) — the last acceptance items are staged, 2026-07-28

`unix-040-b2-dbg` = **68040-260728-32** (`hat_cm_ram = 0x20`) differs from the write-through
`260728-28` in **three bytes**: the flip and two build-id characters.

⚠ **Correction to something claimed earlier today:** the two 16-burst all-V0 `b2repro` runs were on
**write-through** kernels. They are the pre-flip baseline, **not** copyback's acceptance — copyback has
to answer the same question itself.

### ✅ COPYBACK REBOOT DISK-TRUTH: PASS — the last recorded acceptance item is done

The item that had never been run for copyback is now run, on `68040-260728-32`, with both
preconditions verified **by the harness itself** rather than by a reader noticing two printed lines:

```text
B2RT VERIFY   kernel = 68040-260728-32
B2RT wrote-by kernel = 68040-260728-32   uptime = up 10 mins
B2RT now                                  uptime = up 7 mins
B2RT preconditions OK: same kernel, and uptime shows a real reboot
6 x 4194304 bytes -> all CLASS=V0_COMPLETE_MATCH
```

So 24 MiB written through a copyback data cache, synced, rebooted, and read back byte-exact by the
same kernel. **Copyback's write path lands its data.** That is the question copyback had never been
asked, and the July corruption scare -- since explained as ISSUE-22 -- was about this and nothing
else.

A **preliminary** read had already answered the same question a boot earlier and is worth keeping,
because it was free: the reboot came back on the default kernel (`-18`, write-through) instead of the
writer, and reading the copyback-written files there also gave 6/6 byte-exact. Caches are empty after
a boot, so the reader's cache mode cannot change what is on the platter -- but it is two variables, so
it stands as corroboration and not as the acceptance run.

**That mismatch produced the harness fix:** `verify` now **aborts** on a kernel mismatch or an uptime
that went up, instead of printing both identities and trusting the reader. A test that can detect its
own precondition must also refuse to run without it, or the check is a comment. This is the fifth
instrument failure of the same family today (dead serial capture read as kernel silence; a probe that
never fired read as a healthy kernel; a sample-capped `pl[]` probe read as "no violations"; a
no-reboot run read as reboot truth; the loader booting a different kernel than the test assumed) --
every one of which would have produced a green line.

### Dhrystone, three independent measurements on copyback

`30000.0`, `30037.5`, `29813.7` per second across three boots — within 0.7 % of each other, against
the write-through baseline of `18292.7`. Copyback is **+63 %**, and it is confirmed active on each
boot rather than assumed from the image.

### ⛔ COPYBACK AMPLIFIES ISSUE-22 — strict A/B, 3 bytes apart, 2026-07-28

| kernel | difference | `cp: /payload.bin: read: Bad address` |
|---|---|---|
| **copyback `68040-260728-32`** | — | burst **4** (confounded run) and burst **1** (clean run) |
| **write-through `68040-260728-28`** | **3 bytes** | **CLEAN 16/16 — 96 verifications** |

Same workload, same cold boot, same harness, same day, and the two images differ only in the
`hat_cm_ram` flip plus two build-id characters. Counting the earlier write-through runs on `-18` and
`-23`, write-through stands at **3 runs / 288 verifications with zero hits** while copyback failed in
**2 of 2 runs inside the first four bursts**.

**The verdict is sharper than July's "blocked but not proven guilty", and it is a different charge.**
Copyback is not a data-integrity problem here: in the run where `cp2` died, `cp1` verified as a
complete byte-exact match, so what copyback writes is intact. The charge is that it **amplifies a
transient read EFAULT that aborts operations** — ISSUE-22, which July established as
kernel-independent (their write-through baseline hit it too). Copyback does not appear to create the
defect; it makes it fire constantly. That is enough to keep the flip out of production, and it is a
precise reason rather than a suspicion.

**And it hands ISSUE-22 the thing it never had: a reproducer.** The defect was "1 case in 48 parallel
copies", and five cold-boot cycles in July failed to reproduce it at all. On the copyback kernel it
fires **in the first burst**. Combined with the kernel-side observation that holds across both
copyback hits — the `as_fault` FAIL logger (cap 64) printing **zero** lines, so the EFAULT is not a
failed page-in but a resolver-internal gate — this is the position Codex's latch spec was written
for, now with a workload that triggers on demand rather than by luck.

**Recommended order from here:** fix ISSUE-22 first, using copyback as its reproducer; then re-run
this A/B, where copyback's own acceptance should follow for free. The remaining copyback item
(`b2reboot-truth.sh`, does the data land across a reboot) is a *different* question and still unrun —
it is worth running even now, because it is unaffected by the EFAULT frequency.

### ✅ COPYBACK IS IN EFFECT, MEASURED: Dhrystone 30000/s on real hardware (+64% over B1)

Run on `68040-260728-32`, idle machine, 400000 runs (`dhry` prompts for the count on **stdin**; it
does not take it as argv, which is why two attempts hung first):

```text
Step A, no data cache      11538   /s
B1 write-through           18292.7 /s   +59 % over Step A
B2 COPYBACK                30000.0 /s   +64 % over B1, +160 % over Step A
```

Two things settle at once. **Copyback is genuinely in effect** -- measured, not inferred from the
image bytes -- which was the precondition for interpreting any copyback test result at all. And the
user's recollection of "~30000 from the copyback experiments" is **confirmed and now a recorded
hardware number** rather than a memory; copyback had never been benchmarked on hardware before.

### ⚠ The first copyback burst run is CONFOUNDED, not a result

`b2repro-copy 16` on the copyback kernel stopped at **burst 4** with
`CLASS=SOURCE_ERROR src=/payload.bin errno=14` (EFAULT reading the reference). But the user was
logged in searching the filesystem for `dhry` during that run, so it carried **uncontrolled extra
I/O that the write-through comparison runs did not have**. It is therefore uninterpretable as
copyback evidence -- not because the search caused it, but because we cannot tell. Repeating it
cleanly is exactly what this project's own rule from 23.7. demands: *a rare fault needs a controlled
repeat comparison; a single run would have been mistaken for ISSUE-22.*

**One genuine finding does survive from it, and it is new ISSUE-22 information.** The `as_fault`
FAIL logger has a cap of 64 and printed **zero** lines during that run, so the absence is meaningful
rather than exhausted: **the EFAULT that reached user space was not produced by `as_fault` failing.**
Per Codex's route analysis EFAULT comes from `sf_fault`, which is entered when the *resolver* returns
nonzero -- so the nonzero came from a resolver-internal decision (a `Lkx_fail`-class path: no `kas`
segment, walk validation, the recursion cap) and not from a failed page-in. That narrows ISSUE-22
away from the fault resolver's as_fault call and towards its own gates.

Remaining, both staged with a run sheet in `nasu:Public/amix/hwtest-260728/`:
1. `b2repro-copy.sh 16` on the copyback kernel — expect CLEAN; a `V1_*` class is ISSUE-22 and not
   copyback (it occurs on write-through too), `V3`–`V6` is a real disk-truth defect.
2. **`test-tools/b2reboot-truth.sh`** — the item that was actually missing. Two phases across a clean
   reboot: 6 × 4 MiB written and synced, then every byte compared after the boot, so the whole
   copyback chain is forced (dirty D-cache lines → push → buffer cache → disk → a fresh boot's
   reads). Files go in `/b2dt`, never `/tmp`, which every boot clears. Verification uses `b2verify`,
   not `sum` — `sum` prints a partial progress count after `ferror()`, which is exactly how a clean
   copyback run was misread as silent corruption in July.
3. Bonus: Dhrystone on copyback. The WT hardware baseline is **18292.7/s**; copyback has never been
   measured on hardware at all.

## Dokumentoitu rajoitus (ei regressio): Zorro III -laiteaukko ei ole ajurin tavoitettavissa

Selvitetty 2026-07-27 oikealla raudalla, Piccolo Zorro III -tilassa. **Ei meidän aiheuttama** —
stock-AMIX:ssa ei ole Zorro III -tukea lainkaan (MNT ZZ9000 -ajurin README sanoo sen suoraan ja
hylkää oman Z3-tuotteensa tarkoituksella). Kirjattu koska se rajoittaa kaikkea tulevaa
Z3-työtä ja koska mekanismi on nyt todistettu eikä arvattu.

**★ KONTROLLI 2026-07-28: sama kortti Zorro II -tilassa → X11 toimii ja on nopea.** Käyttäjä
palautti jumpperin ja ajoi saman ajurin samalla kernelillä: `svgaprobe` onnistuu, X11
käynnistyy. **Ainoa muuttunut asia koko järjestelmässä on kortin väylätila**, joten tämä on
yhden muuttujan A/B eikä pelkkä disassembly-päättely. Se sulkee samalla pois selitykset joita
ei ollut suljettu: kortti ei ole rikki, firmware ei ole väärä, ajurin sovitus ei ole väärä,
X-puoli ei ole väärä — vain osoite.

**⚠ Älä lue tuota "nopeaa" väyläväitteenä.** Nopeus tulee **CPU:sta** (Mercury 040 vs 030), ei
väylästä; **väylä on täsmälleen sama kuin 030-aikana.** Zorro III:n tuoma kaista on siis
kokonaan käyttämätöntä ja sen nopeusmotiivi on ennallaan — luultavasti vahvempi kuin 030:lla,
koska kertaluokkaa nopeampi CPU siirtää pullonkaulan väylälle (Z2 on 16-bittinen, Z3
32-bittinen). Mikä pätee: mikään ei ole rikki, joten Z3 ei **estä** mitään, eikä firmware-työtä
kannata tehdä diagnoosin takia. Nopeuden takia kannattaa.

**Palkinto on mitattavissa ennen kuin se ansaitaan:** aja `test-tools/busbench.c` **Z2-tilassa**
`-r`-referenssin rinnalla. Lähellä paikallisen RAMin kattoa → Z3 ostaa vähän; kertaluokan
alempana → Z3 ostaa paljon. Ei vaadi mitään Z3-työtä. **Ja jos Z3 tehdään, se on kaksi
muutosta:** kernel-mappaus antaisi aukolle `Lcm_sel`istä CM `0x40` NCS (serialisoitu), kun Z2
saa DTT0:sta `0x60` NC — serialisointi syö osan hyödystä, joten `Lcm_sel` tarvitsee myös
framebuffer-luokan.

**Todiste.** Piccolo Z3-tilassa autoconfig antaa:
```
board[2] mfg=0893 prod=05 addr=40000000 size=01000000   Piccolo RAM, 16 MB, ZORRO III
board[3] mfg=0893 prod=06 addr=00eb0000 size=00010000   Piccolo regs, Zorro II I/O
```
Tuotenumerot pysyvät 5+6, joten Xsvga-ajurin sovitus pätee — silti **`svgaprobe`:
`open /dev/svga0` → ENXIO**. Emulaattorissa jossa sama ajuri toimii:
`gfxcard_type=Piccolo_Z2`, eli **Zorro II**.

**Juurisyy.** Ajurit dereferoivat `cd_boardaddr`in **suoraan kernel-osoitteena**:
```
Xsvga exp @39f6:  moveal %a1@(0,%d2:l),%a0   | a0 = cd_boardaddr
              3a00:  moveb  #-61,%a0@(0,%d3:l)  | kirjoita sen läpi
```
Zorro II:lla se toimii koska **DTT0 = 0x003fc060 identity-mappaa 0x00000000–0x3FFFFFFF**.
**Zorro III osoitteessa 0x40000000 ei ole identity-mappausta** — se VA-alue on kernelin
**kvsegiä** ja aktiivisessa käytössä (havaitut VA:t 0x40440000–0x40449000).
**Ja pääsy Z3-osoitteeseen ei faulttaa** vaan osuu hiljaa
[REFUTED 2026-08-20: tämä sanoi "kvseg on fill-on-fault". Se on väärin -- `segkmem_fault`
palauttaa -1 tavalliselle F_INVAL/F_PROT-faultille. Oire on oikea, mekanismi oli väärä:
`0x40000000` on KIINTEÄ U-AREA, eli luku palveltiin elävästä kernel-mappauksesta.
Ks. `docs/AMIGA-PHYSICAL-MEMORY-MAP.md`.]
kernelin muistiin: luku palauttaa nollia (→ "ei lautaa"), kirjoitus menisi kernelin dataan.

**Mitä Z3-tuki siis vaatii:** kernelin on mapattava Z3-aukko kernel-VA:han ja ajurin on
käytettävä sitä mappausta raa'an fyysisen osoitteen sijaan. Ajurikohtainen muotoilu (pidä
fyysinen osoite `mmap`in `phystopfn`ille, lisää erillinen kernel-VA rekisteripääsyille
`segkmem_mapin`in kautta) on kirjattu muistiin `amix-zorro3-aperture-limitation`.
**Toteutus kuuluu ajuriprojekteihin, ei tähän repoon.**

**Ero ajurien välillä on korjattavuudessa, ei mekanismissa.** Xsvga on binääri (vain
patchattavissa) ja epäonnistuu hiljaa. VA2000 on oma lähdekoodi ja epäonnistuisi
**turvallisesti ja itsensä diagnosoiden** — init lukee firmware-rekisterin ja tulostaisi
`board found at 0x40000000` + `board not responding or firmware too old`, ja sen
rekisterikirjoitukset ovat `va2000ioctl`issa eli vaativat onnistuneen `open`in.

**Ja Z3 EI nopeuta korttia joka on Z2-tilassa** — väyläprotokollan määrää kortti.
Piccolo ja VA2000 ovat kumpikin kaksitoimisia (Piccolo: jumpperi; VA2000: firmware).
Mittaamiseen `test-tools/busbench.c`, jonka otsikossa on se ansa että DTT0 antaa Z2-aukolle
CM 0x60 (NC) kun `Lcm_sel` antaa Z3-mappaukselle 0x40 (NCS, serialisoitu) — naiivi vertailu
mittaisi serialisointia eikä väylää.

## ISSUE-36 — ✅ CLOSED: A/B CONFIRMED ON REAL HARDWARE 2026-07-28

> **Ledger: FIXED** — earlier record of ISSUE-36; the first ISSUE-36 section above carries the current one.

Both halves are now run, on two kernels that differ in **exactly five bytes** (the four immediates
plus one build-id byte), so the difference is attributable to nothing else.

| `r = size mod 4096` | OLD `68040-260728-13` | NEW `68040-260728-12` |
|---|---|---|
| 0 (full final page) | PASS | PASS |
| **1** | **SIGBUS** | PASS |
| **123** (the original field report) | **SIGBUS** | PASS |
| **2048** (last rejected) | **SIGBUS** | PASS |
| **2049** (first accepted) | **PASS** | PASS |
| 4095 | PASS | PASS |
| 123 in the 2nd page of a partial 8 KiB block | **SIGBUS** | PASS |

**Codex's static predicate is confirmed exactly, including the sharp part.** `2048` fails and
`2049` passes, which is the discriminator that separates this model from "any partial page fails" --
the characterisation we had originally recorded from the field and which was wrong. On the new
kernel all seven pass with all three checks (bytes match the host-written pattern, and the bytes
between EOF and the end of the tail page read as zero).

The kernel side closes the chain end to end, with the fault addresses being exactly `p[size-1]` of
each failing file:

```
DBG as_fault FAIL pid=199 addr=C1039000 type=0 rw=1 ret=E05        <- r=1     tail offset 0x000
DBG as_fault FAIL pid=199 addr=C103907A type=0 rw=1 ret=E05        <- r=123   tail offset 0x07A
DBG as_fault FAIL pid=199 addr=C10397FF type=0 rw=1 ret=E05        <- r=2048  tail offset 0x7FF
DBG as_fault FAIL pid=199 addr=C103A07A type=0 rw=1 ret=E05        <- 28795   tail offset 0x07A
NOTICE: User BUS ERROR at C1039000, PC:80000C22 FAULT:5 PID:199 CMD:./nfstail ...
```

`ret=E05` is `FC_MAKE_ERR(EFAULT)`, `type=0` is `F_INVAL`, `rw=1` is `S_READ`, and `FAULT:5` is the
`FC_OBJERR` low nibble -- the exact chain Codex derived from the binary.

Also verified on the new kernel: an NFS-resident **exposed** ELF (`uname`, one exposed PT_LOAD)
executes cold from the mount, a control ELF does too, the local control corpus passes 7/7, and the
ISSUE-35 server-side byte-truth regression still passes 6/6.

### The `pl[]` probe found no violation on EITHER body — and Codex predicted that

`DBG pvn` printed nothing on the old kernel or the new one. That is not a gap in the probe; it is
what Codex's own analysis says to expect for this workload: *"The reported +123 fault itself does
not exercise the return-list defect: raw `io_len=123`, so even the old countdown emits one
pointer."* The return-list defect needs **full 8 KiB clusters**, which a corpus of tail faults never
creates. So the four-site unit's countdown half remains justified by the source contract and by the
disassembly (a circular page list bounded only by a byte countdown), not by an observed violation.
**A future probe run aimed at it needs a different workload** -- large sequential reads of an
NFS-resident file, not tail faults.

### (build record and prior status)


`nfstail` over NFS: **7/7 PASS**, including the remainders that previously raised SIGBUS
(`r=1`, `r=123`, `r=2048`), and every file satisfied all three checks -- bytes match the
host-written pattern AND the bytes past EOF in the tail page read as zero, which is the
io_len half of the defect that a `p[size-1]` touch cannot see. An NFS-resident **exposed** ELF
(`uname`, one exposed PT_LOAD) executed cold from the mount and returned 0, as did a control
binary; the local control corpus passed 7/7; and the ISSUE-35 server-side byte-truth regression
still passes 6/6.

**Not yet done, and it is the half that CONFIRMS the model rather than the fix:** the A/B run on
`unix-040-dbg-pre36` (68040-260728-13, the same build with these four sites reverted -- the pair
differs in exactly five bytes). Expected there: `r=1,123,2048` SIGBUS and `r=0,2049,4095` pass.
Until that runs, the green result proves nothing is broken, not that the boundary model is right.
Also pending: the `pl[]` probe output, which goes to the console and the serial mirror only.

### (build record)


Four atomic sites, `src/patch_nfs_getpage.py`, wired into `relink-040.sh`. Codex's site
analysis is `amix-kernel-analysis/vm-map/NFS-READSIDE-ISSUE36-SITE.md` (c95fd8c); all thirteen
sites were re-verified byte-for-byte against our own image before anything was written, and the
image matched Codex's pin exactly (sha256 `5df4158b…`).

```
0x8b6ba  rp->r_size + 2047 -> + 4095    EOF allowance  <- the direct SIGBUS producer
0x8b26c  sz -= 2048 -> 4096             pl[] countdown
0x8b282  io_len + 2047 -> + 4095        full-page initialization
0x8b288  andiw #-2048 -> #-4096         full-page initialization
```

**The predicate is sharper than we recorded it.** With `r = size mod 4096` the old gate rejected
only `r` in 1..2048; `r == 0` and `r >= 2049` were always accepted. So our "NFS mmap does not work
for any non-multiple-of-4096 length" was wrong — upper-half remainders already worked. The
acceptance corpus therefore straddles the 2048/2049 boundary, because that boundary is what
distinguishes this model from "any partial page fails".

**Why the one-liner is unsafe alone** — verified independently in the disassembly, not taken on
trust: the loop that fills `pl[]` stores the pointer *before* following `p_next`, and SVR4 page
lists are CIRCULAR, so the byte countdown is the loop's only bound. At 2048 an 8 KiB cluster emits
`A, B, A, B, NULL` where the contract is `A, B, NULL`. And an EOF gate opened without the io_len
pair admits a page whose upper 2 KiB the I/O never initializes. Every half state is known-bad, so
the script verifies all four before writing any and refuses a partially applied image.

Artifacts, corpus, expectation tables and the A/B control kernel: `docs/REALHW-ISSUE36-260728.md`.
Emulator status: 040 and 060 boot clean, relocs 0, local control corpus 7/7 on both CPUs.
**ISSUE-36 itself cannot be verified in the emulator** — Amiberry's slirp does not forward RPC
outbound (`rpcinfo`: cannot contact the portmapper), so the guest cannot mount NFS at all.

### Intermittent, unattributed: scrmon bus error

One emulator boot in six produced `BUS ERROR at 4D455404 PC:C101D6C8 FAULT:6 PID:159
CMD:/usr/amiga/lib/scrmon`; the same kernel booted clean immediately after. The fault address is
ASCII (`MET\x04`), i.e. data dereferenced as a pointer. It does not correlate with that build's
only change (a debug threshold constant), but the cause is unknown and it is recorded rather than
explained away.

## ISSUE-37 — ✅✅ FIXED AND CONFIRMED; xpage v2 re-verified on hardware 2026-07-28

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**v2 acceptance (`68040-260728-26`, the audit-driven rewrite: format-7 gate, SSW MA tier with error
propagation, v1's window kept as a second tier with its result discarded).** wolf3d was run from a
COLD boot -- the machine had been up one minute, a stricter condition than the v1 run:

```text
uname -m   68040-260728-26
uptime     up 1 min  (pre-flight)  ->  up 5 mins  (after the run)   <- NEVER RESET, so no wedge
load avg   0.00 afterwards, wolf3d exited on its own, no new core file
user observation: the game worked
```

**The uptime continuity is the kernel-level proof here, and it is independent of serial**: a wedge on
this kernel is unrecoverable and forces the reset switch, which would have restarted the uptime
counter. It went 1 -> 5 minutes across the run.

⚠ **What this run does NOT have: serial evidence.** The capture (`cat /dev/ttyUSB0`) had died between
reboots, so the log recorded **0 bytes** during the run. That silence was nearly reported as "the
kernel had nothing to say" -- the strongest possible result -- and it would have been wrong. It was
caught by generating a known kernel message on purpose (`kill -9`, which prints `DBG SIG sig=9`) and
seeing that produce 0 bytes too. **A silent log and a dead instrument look identical**, exactly as a
wedged machine and a fault storm look identical from the console. Verify the instrument before
reading silence as success; capture with `cat /dev/ttyUSB0 | tee -a <file>` so it survives a
terminal.

## (v1 confirmation) FIXED AND CONFIRMED ON REAL HARDWARE 2026-07-28

`68040-260728-18`, wolf3d launched from the console:

```
before (3 runs, 3 kernels: 260727-02, 260728-12, 260728-15)
    machine wedged, 16 as_fault REPEAT lines to n=0x2000, telnet lost, reset switch required
after (260728-18, with the xpage fix)
    root  194  192  25  console  0:48 ./wolf3d      <- a normal process
    CPU time 0:14 -> 0:48 -> 0:57, machine answered telnet throughout
    serial: as_fault REPEAT 0   segat LOOP 0   User BUS ERROR 0   PANIC 0
```

The only as_fault traffic during the run is two routine `type=3` (`F_SOFTUNLOCK`) events. The
process consumes CPU and progresses instead of spinning in the kernel, and the system stayed
responsive to a shell the entire time -- which was impossible before, because the loop starved
every other process.

**One fix, one line of reasoning, confirmed by its prediction coming true.** The defect was that
the 68040 reports a misaligned access's START address while the missing page is the NEXT one, and
the resolver kept resolving the already-present near page.

### The wider consequence worth chasing next

This fix sits on **every kernel fault path**, and ISSUE-22 -- the transient `read: Bad address`
(EFAULT) under parallel pressure -- has as its recorded suspicion *"a rare race in the fault path
resolving a copyout buffer's fault under concurrent pressure"*: the same locus. The two symptoms
differ exactly as `u_nofault` predicts:

| path | `u_nofault` | outcome |
|---|---|---|
| segmap access inside `read()` | not set | no escape -> infinite loop = **ISSUE-37** |
| `copyout`/`uiomove` to a user buffer | **set** | the nofault escape returns **EFAULT** = **ISSUE-22** |

So the xpage fix may close ISSUE-22 too. That is a hypothesis, not a finding, and it is cheap to
test: ISSUE-22 already has a chase recipe (cold boot, then immediate pressure with six parallel
`cp`). It matters beyond ISSUE-22, because ISSUE-22's transient EFAULT is the noise that made
B2/copyback look guilty of disk corruption in July -- so clearing it also cleans the evidence base
for the copyback flip, whose remaining items are recorded as ordinary acceptance rather than
blockers.

## (root-cause record) ROOT CAUSE IDENTIFIED AND FIXED 2026-07-28

*(ISSUE-37 XPAGE root cause)*

**The 68040 reports the fault address of a MISALIGNED access as the address where the access
STARTS, even when the page actually missing is the NEXT one** (SSW `MA`). `krnxmemflt040` never
looked at that, so it handed as_fault the near page, as_fault resolved a page that was already
resident, returned 0, the instruction restarted and faulted identically -- an **unkillable** kernel
loop, since the fault is taken in kernel mode on the process's behalf.

**We had already found this exact defect on the 060 and explicitly excluded the 040.**
`src/wb040.s`'s `wb060_xpage` fixes it for the format-4 path, citing Linux/m68k's
`if (fslw & MA) addr = (addr + 7) & -8`, and its comment ends:

```
| Gated on fmt-4: on the 040 the byte-wise replay already covers this.
```

That sentence is the defect. The byte-wise replay covers **write-backs**; a **read** access error
never reaches the replay, so the 040's read side was uncovered. The 060 sighting even had the same
shape: `addr=40734FFE`, a kernel VA two bytes before a page end, `ret=0`, infinite loop.

### The measured invariant that identified it

| instance | addr | slot base | in-slot offset |
|---|---|---|---|
| 27.7. | `0x408F4FFF` | `0x408F4000` | **0xFFF** |
| 28.7. #1 | `0x40A80FFF` | `0x40A80000` | **0xFFF** |
| 28.7. #2 | `0x40946FFF` | `0x40946000` | **0xFFF** |

Three loops, three different slots, always the **last byte of an 8 KiB segmap slot's first page** --
exactly where a misaligned access straddles into the slot's second page. And `as_fault(len=1)`
rounds to a 4096-byte range covering only the first page, so `segmap_fault` maps that page and never
the second.

Supporting: the segment is `segmap` (`ops` resolved to `segmap_ops` from the loop itself on
hardware, window `0x40440000..0x422BFFFF`); the user PC is constant at `libc.so.1+0x13088` =
**`read`+4**, so the loop is inside a `read(2)`; `type=0` and `ret=0` every iteration.

### Why 76 synthetic cases missed it

Six sweeps varied offset, length, alignment, straddling, destination residency and the EOF tail on
both filesystems, and never produced a *misaligned kernel access starting at a page's last byte
whose successor page was absent*. The straddles they did produce had the second page already
resident, so each fault reported its own address and resolved normally. **The trigger is a
conjunction, and varying one property at a time cannot construct one.**

### The fix

`src/krnxmemflt040.s`, mirroring the proven 060 recipe rather than inventing one: after a
**successful** resolve, if the fault address lies in the last 8 bytes of its page, resolve the next
page too (`len=4`, `F_INVAL`, `S_READ`, `&kas`), preserving the original return value. The 8-byte
window is deliberately the sibling's: `move16` cannot trigger this (16-byte aligned by definition)
and 8 bytes covers every misalignable operand up to an FPU double.

Built `68040-260728-16` (base), `-17` (dbg), `-18` (rtg-dbg), `-19` (rtg). Verified: both CPUs boot
clean (0 faults, idle reached), relocs 0, and a 1.4 MB copy plus `cmp` byte-identical on the 060 --
this sits on every kernel fault path, so a functional check mattered more than usual.

**Not confirmed yet.** The acceptance test is one command: run wolf3d on `260728-18`. If it reaches
its menu, ISSUE-37 is closed. Until then: a root cause with a matching fix, not a proven repair.

## (original entry) ISSUE-37: wolf3d wedges the machine in an infinite as_fault loop

> **Ledger: FIXED** — earlier record of ISSUE-37; the first ISSUE-37 section above carries the current one.

Found 2026-07-28 on real hardware, VA2000 in Zorro II mode, kernel `68040-260727-02` (RTG dbg).
Wolf3D was ported to AMIX/030 by us earlier and worked there, so this is a **candidate Model-B
regression** rather than a program that never ran.

### Symptom, and why the symptom lied

Starting `/root/wolf3d`: the VA2000 screen goes black and the game never reaches its menu, the
network connection drops, virtual consoles still switch but accept no keystrokes. That reads like
a crash or a hang. **It is neither** -- the machine is running flat out inside the kernel:

```
DBG as_fault STREAM pid=184 addr=408E0000 upc=C101FFE0 type=3 ret=0
DBG as_fault STREAM pid=186 addr=408F4FFF upc=C1013088 type=0 ret=0     <- forever
DBG as_fault REPEAT pid=186 addr=408F4FFF upc=C1013088 type=0 ret=0 n=2000
```

That explains every part of the symptom at once: VT switching is interrupt-driven so it survives,
no process gets the CPU so nothing accepts input and the network stack starves, and the game is
stuck in a syscall so its screen never gets drawn. **A wedged AMIX and a fault storm look
identical from the console.** Capture serial before concluding anything about a hang.

### What the log establishes on its own

* **`ret=0` means the fault resolver reports SUCCESS** -- and the same address faults again.
  So nothing is denying the access; something claims to have fixed it and has not.
* **`type=0`** = `F_INVAL`, a not-present page, not a protection fault.
* **`addr=0x408F4FFF` is a KERNEL address.** kvseg heap is `[0x40040000,0x40440000)`
  (`src/kmem_validate.s`), kvsegmap starts at `0x40440000`, kvsegu is at `0x48440000`
  (`src/execmark.s`). So this is the kernel touching its own file window.
* **It ends in `FFF`** -- the last byte of a 4 KiB page.
* **`upc` is constant and in the shared-library range**: the process is parked in libc's `read()`.

### Which segment -- by elimination, not by guess

1. **`as_fault` (0xae108) is not the bug.** Its rounding is correct 4 KiB: `andiw #-4096` clears
   the low 12 bits of a 32-bit value. It passes the ROUNDED address to the segment's fault op and
   returns whatever that op returned, so `ret=0` is the segment driver's answer, not its own.
2. **It is not a segkmem-backed segment.** `segkmem_fault` (0xa83d6) returns 0 **only** for
   `F_SOFTLOCK`(2) and `F_SOFTUNLOCK`(3), and `-1` for everything else -- it is structurally
   incapable of returning 0 for `type=0`. That also rules out `sptmap`, whose allocator
   `sptalloc` (0xa8bb6) sits in the segkmem object immediately after `segkmem_faulta`.
3. The kernel has exactly five seg-ops vectors: `segdev_ops` `segkmem_ops` `segmap_ops`
   `segu_ops` `segvn_ops`. segdev/segvn are user segments, segu is kvsegu at 0x48440000.
   **Only `segmap` remains, and segmap can do exactly this.**

### The mechanism in segmap_fault (0xa9116)

It computes the faulting file offset `d4 = sm_off + (addr & 8191)` and `d7 = d4 + len`, calls
`VOP_GETPAGE(vp, d4, len, protp, pl, plsz=8192, seg, addr, rw, cred)`, then walks the returned
`pl[]` and maps **only pages whose `p_offset` lies in `[d4, d7)`**; every other returned page is
merely released. **If that set is empty it maps nothing, falls through to `clrl %d0` and returns
0.** So a provider whose page offsets are off by a page -- or that returns an empty list -- makes
as_fault report success forever while the faulting instruction never becomes executable.

This is ISSUE-27's family once more: **provider on one page grid, consumer on the other.**
wolf3d's files are on the root UFS, and Codex's residual census lists **UFS as 12 unconverted
sites**, including the note that `ufs_allocmap` rounds with `+0x0fff` rather than `+0x1000`.

Incidentally this clears segmap of Codex's `pl[]` capacity concern: its frame is `linkw #-56`
with `pl` at `fp@(-24)`, i.e. 6 pointers, and `plsz=8192` needs 3 on a 4 KiB grid or 5 on a
2 KiB one. Both fit. The capacity contract is a provider-side question, not segmap's.

### Why wolf3d finds it and a working system hides it

wolf3d is the only program here that reads at **arbitrary byte offsets**: `id_pm_amiga.c:25`
`PML_ReadFromFile(buf, offset, length)` seeks straight to a VSWAP chunk offset taken from the
file's own table, and `id_ca.c` does the same in a dozen places (lines 143, 664, 830, 871, 1100,
1157, 1237). `cc`, X and the shell read sequentially from zero -- and **a sequential reader
touches byte 0 of a slot first, which maps the page, so it never asks for the tail of an
unmapped page.** The bug needs a first touch at a page-tail offset, which only random access
produces.

### ⚠ FOUR SWEEPS RUN ON REAL HARDWARE — ALL NEGATIVE, AND THE PRIMARY HYPOTHESIS IS REFUTED

Run 2026-07-28 on the machine, kernel `68040-260727-02`, UFS root, files verified cold.

| sweep | what it varied | cases | result |
|---|---|---|---|
| `test-tools/segmaprep.c` | one single-byte read per fresh 8 KiB slot, within-slot offset 0…8191 | 12 | **all resolved** |
| `test-tools/segspan.c` | reads straddling page and slot boundaries, every misalignment, matched vs mismatched src/dst alignment, spans to 64 KB | 14 | **all resolved** |
| `test-tools/pmrep.c` | wolf3d's OWN `PM_Startup` loader: 663 seek+read pairs at the real VSWAP chunk offsets/lengths, no game attached | 663 | **all resolved** |
| `test-tools/segwrite.c` | the WRITE path: sparse offsets forcing UFS allocation, partial head+tail pages, byte-verified readback | 10 | **PASS, 69650 bytes verified** |

**The page-tail hypothesis above is REFUTED.** Sweep 1 includes within-slot offset **4095**, which
is exactly the offset of the hardware fault (`0x408F4FFF - 0x40440000 = 0x4B4FFF`; slot 602 base
`0x408F4000`; so the faulting byte sits at within-slot offset `0xFFF`). That byte is reachable.
Straddling accesses, alignment mismatch, the real loader's access pattern and the whole write path
are all reachable too. **`read()`/`write()` on UFS through segmap is not the trigger by itself.**

**One thing WAS confirmed rather than refuted:** `test-tools/` `vamap` (scratch program) mmapped
the VA2000 exactly as `id_vl_amix.c` does and got **`0xc1033000`**, mapping
`0xc1033000..0xc1432fff`. So user mappings live at `0xC1xxxxxx`, `0x408F4FFF` is **not** the
mapped device aperture, and the kernel-address reading — the assumption the elimination chain
rested on — holds.

**A correction to the entry above:** "the fault storm explains every part of the symptom" is too
strong. `id_in_amix.c`'s `IN_Startup` puts the console keyboard into raw mode, which is an
independent explanation for consoles that switch but accept no keystrokes. The fault storm is
real and the log proves it; that it accounts for the *input* symptom specifically is unproven.

Also corrected: the black screen does **not** show that the loader completed. `wl_main.c:1379`
calls `SignonScreen()`, which sets the video mode at line 951 — **before** `PM_Startup()` at 1399.
The mode set is the first thing the game does, so the hang can be anywhere from there onward.

### What remains, ranked by how badly the sweeps failed to model it

1. **Memory pressure and segmap slot RECYCLING.** Every sweep ran on an idle machine
   (`load average: 0.00`) against fresh slots — deliberately, to make each read a first touch.
   wolf3d holds a ~1.5 MB page-manager working set, a 4 MB device mapping and audio buffers at
   once. A slot being reused underneath a fault is exactly the shape none of these tests can
   produce. **This is the biggest systematic difference between the tests and the game.**
2. **The interaction, not either half.** File I/O while a 4 MB segdev mapping is live, i.e. two
   segment drivers in play at once, which no sweep did.
3. **The second process.** The log has two pids (184 doing an `F_SOFTUNLOCK` at a slot base, 186
   looping). Sweeps were single-process.

### ★★★ THE LOOP IS INSIDE A read(2) — the user PC resolves to a libc symbol (2026-07-28)

Second hardware reproduction, kernel `68040-260728-12`:

```
DBG as_fault REPEAT pid=438 addr=40A80FFF upc=C1013088 type=0 ret=0 n=2000
```

**A different slot from 27.7. (`0x408F4FFF`) but the identical shape** — segmap window, last byte
of a page, `type=0`, `ret=0` — and **exactly the same `upc`**. That constant is the lead we had
been walking past:

`libc.so.1` maps at `0xC1000000`, the vanilla copy is **not stripped**, and its text has
`vaddr == file offset`. So `0xC1013088` is `libc.so.1 + 0x13088`, and the nearest preceding
symbol is:

```
00013084 T _read      /  W read        <- upc is read + 4, i.e. the syscall stub
00013098 T _stime
```

**So ISSUE-37 is a `read(2)` that never returns**, while the kernel spins in `as_fault` on a
segmap address. That vindicates the original file-read model that four sweeps had seemed to
refute — the sweeps were wrong about *which* read, not about the subsystem.

### And the call site follows from wolf3d's own source

`wl_main.c:1379` runs `SignonScreen()` first, before `PM_Startup` — which is why the screen goes
black and the game never reaches its menu. It does this:

```c
VL_SetVGAPlaneMode();                  /* open /dev/va2000, mmap 4 MB, program the mode */
signon = (byte *) calloc(320*200, 1);  /* 64000 bytes of FRESH anon memory */
fread(signon, 320*200, 1, file);       /* ONE 64000-byte read into it */
```

That read has three properties **none of the 62 passing cases had**:

1. one large read into an **untouched destination** — every earlier sweep read into a `.bss`
   array or a block an earlier iteration had already faulted in, so `uiomove` never had to fault
   the destination while also faulting the segmap source;
2. a **live 4 MB segdev mapping** in the same address space (hypothesis 2 on the remaining list);
3. `stdio` `fread` rather than a bare `read(2)`.

`test-tools/readfresh.c` is sweep 5 and targets exactly this: fresh `/dev/zero`-mapped
destinations so "untouched" is guaranteed rather than hoped for, a pre-touched control to separate
destination-faulting from size, a case with `/dev/va2000` mapped, and a size bisect.

### Sweeps 5 and 6: also negative — 76 synthetic cases now, and that is itself the finding

Run on `68040-260728-13` (no reboot needed; both are user-space):

| sweep | hypothesis it tested | cases | result |
|---|---|---|---|
| `readfresh.c` | one large read into an **untouched** destination (the SignonScreen shape), pre-touched control, size bisect, mmap-anon vs brk-anon | 7 | all passed |
| `readtail.c` | one large read of a **whole UFS file, ending exactly at EOF** — the local analogue of ISSUE-36, motivated by UFS's 12 unconverted sites and `ufs_allocmap +0x0fff` | 7 | all passed, every byte correct |

Note one limitation honestly: `readfresh` case 2 was meant to have `/dev/va2000` mapped, but
`260728-13` is a dbg kernel **without** the RTG drivers (`va2000init` absent), so the map returned
0 and the case degenerated into a copy of case 1. That half of the hypothesis is untested.

**Six sweeps, 76 cases, no reproduction. The synthetic approach has failed decisively enough that
continuing it is the wrong move**, and by this project's own rule (record and redirect after a few
ruled-out hypotheses) the instrument has to change. What the failures collectively say is that the
trigger is not any single read shape — not offset, not length, not alignment, not straddling, not
destination residency, not the EOF tail, on either filesystem. It depends on something cumulative
in the game's state.

So the next step is **not a seventh synthetic case**. It is (a) the v2 probe on the real loop, which
names the segment from the loop itself rather than from a healthy emulator fault, and (b) bisecting
**the game**, using its own code paths — e.g. removing `signon.wl6` so `SignonScreen` returns before
its read (`if(!file) { free(signon); return; }`) and seeing whether the hang moves to a later phase.
After six failed models of the program, the program is the better instrument.

### ⚠ The v1 probe failed, and the reason is worth keeping

The segment-identity probe shipped in `260728-12` **stayed silent through a loop that reached
`n=0x2000`**. Not a build problem: it was gated on *consecutive* `as_segat` calls with the same
address, and **`as_segat` has twenty call sites**, so any other kernel-range lookup between two
loop iterations resets such a streak. *Never gate on a consecutive streak inside a function half
the VM calls.*

v2 (`260728-14`/`-15`) attaches the print to the `as_fault` REPEAT counter instead, and that
trigger is measured rather than assumed: **0 REPEAT lines across four healthy emulator boots (040
and 060), 38 on hardware, all inside the two wolf3d loops.** So 512 consecutive faults on one
address is already proof of a loop. Verified silent on a healthy boot after the change.

### On the `pl[]` probe during the loop — a correct reading, not the tempting one

`DBG pvn` produced **zero lines** during the loop. That does **not** show `pvn_getpages` was
uncalled: the probe's sample cap (6) is consumed during boot, so a clean call prints nothing
afterwards. Violations print independently up to 24, and none appeared. The honest statement is
therefore: **no page-list capacity violation occurred**, and whether the loop even reaches
`pvn_getpages` is still unknown.

### ✅ ANSWERED 2026-07-28: the segment IS segmap, measured rather than argued

The probe was built (`src/assegat_dbg.s`, repeat-gated, prints `seg->s_ops`) and it
answered the question on its first emulator boot -- as a FALSE POSITIVE, before the gate was
tuned:

```
DBG segat LOOP addr=40444000 seg=400B9800 base=40440000 size=1E80000 ops=80F2AB8
```

Resolving `0x080F2AB8` against the dbg kernel's runtime `.data` base (text base `0x08000000` plus
`.text` size `0xE76B0`) gives `.data` offset **`0xB408` = `segmap_ops`**, and the window
`0x40440000..0x422BFFFF` (30.5 MB) **contains `0x408F4FFF`**. So the elimination chain's conclusion
was right, and it is now a measurement.

**And the false positive taught something that bears on the remaining hypotheses:** at a threshold
of 64 the probe fired on a healthy idle boot, because **segmap recycles slots constantly and the
same kernel VA is re-faulted over and over as different files pass through it**. Long consecutive
streaks on one VA are normal. That weakens "slot recycling" as a sufficient explanation for
ISSUE-37 -- idle boot recycles continuously without wedging anything. The threshold is now 4096
(the loop exceeded 8192 within a second) and a healthy boot is verified silent.

### The remaining step is the loop's own segment state, not a fifth sweep

Stop inferring which segment owns `0x408F4FFF` and **measure it**. `src/assegat_dbg.s`
already wraps `as_segat` and prints the segment it finds plus `[base, base+size)`; it is gated to
`addr >= 0x80800000` and capped at 16. Re-gate it to `[0x40000000, 0x50000000)` and add
**`seg->s_ops`** to what it prints. One boot then names the driver outright, against:

    segdev_ops  0x0000b380      segkmem_ops 0x0000b3c4      segmap_ops  0x0000b408
    segu_ops    0x0000b450      segvn_ops   0x0000b494

If it is segmap, the follow-on probe is inside `segmap_fault`: print `d4` (the faulting file
offset) and each returned `p_offset`, which shows an empty set or an off-by-one page directly
instead of by argument.

### NOT yet established

* **Which provider site**, and now also **whether segmap is even the segment** -- the elimination
  argument stands, but it is an argument, and four sweeps failing to reproduce is reason to
  measure it rather than trust it.
* Whether the same defect reaches `mmap` of a UFS file, which would make it much broader than
  `read()`.
* Whether ISSUE-36 (NFS mmap tail SIGBUS) shares the root arithmetic. Probably not: ISSUE-36
  faults in the LOWER half of its page and returns `E05`, not 0.

### Repro

`test-tools/segmaprep.c` -- one 1-byte read per 8 KiB segmap slot so every read is the first
touch of its slot, sweeping the within-slot offset across the page and half-page boundaries.
It records progress to stdout AND to a synced state file **before** each attempt, so the offset
that wedges the machine survives the hard reset. Requires a COLD file (the loop needs a
not-present page), so run it on a fresh boot against something nothing has read yet.

    cc -o segmaprep segmaprep.c
    ./segmaprep /root/wolf3d/VSWAP.WL6
    # if it wedges: reset, then  cat /segmaprep.state

## ✅ THE BASE KERNEL IS SILENT (2026-07-31) — and the counter that replaced the print cap found something

`src/kdbg040.s` adds one flag, `kdbg_on` (ships 0; `patch_btrace_on.py` flips it to 1 in the
dbg build alongside `btrace_on`; pokeable live through `/dev/kmem`). 15 `cmn_err` sites inside the
genuine-fix objects are now gated by it — two instructions each (`tstl kdbg_on` + a branch to the
site's existing skip label, so no site's register discipline changes).

Classified by what a **healthy** boot actually does (`test-tools/issue22-serial45-260728.log`):

* **Gated** (fires on a healthy boot = narration): `hat_dup040 ENTER` (137×, and it never stopped —
  every 64th fork forever), `ufault` 48×, `GOTmap` 40×, `ptload` 40×, `segmap-map` 16×, `FREELEAF`
  12×, `ptload2` 12×, `Lballoc leaf` 8×, `hat_unload` 6×, `hat_alloc`/`hat_free`/`hat_chgprot040`
  ENTER, `first private-page copy`.
* **Not gated** (never fires on a healthy boot — their silence is what makes them worth reading):
  `hat_unlock invalid sde`, `pte not in revmap` ×2, `hatfree BAD-slot`, `hat_ptfree LEAK`,
  `vtop pool`, `VTOPALIAS`, `KERNVA-WITH-PROC`, `wb040 replay UNRESOLVED`, `krnxflt FAILEXIT`,
  `segkmem_setprot invalid segment`.

Verified in Amiberry, both directions: quiet image = **1 354 bytes of serial log, zero DBG lines**
(and `cb_icode_push` = 1 read over the Amiberry IPC, so the boot progressed — with a silent kernel,
absence of output is no longer evidence of progress); dbg image = **111 754 bytes**, every line back.

### The finding: `hat_badaslot_n` = 439 per boot, where the print cap only ever showed 8

Two anomaly-shaped sites fired on **every** healthy boot behind an 8-print cap, so their true rate
had never been visible. They now carry uncapped counters (`hat_pfnmiss_n`, `hat_badaslot_n`).
First reading, from one emulator boot:

```text
hat_pfnmiss_n     10     (cap showed 8 — the COW-replacement path, a small constant)
hat_badaslot_n   439     (cap showed 8 — 431 events were invisible)
```

`Lf_badA` fires when an address-space root's A-slot names a pointer table **outside managed RAM**
(`[pages_base, pages_end)`), and `hat_free` then skips that A region. The observed descriptors are
the same two on every teardown, on hardware and in the emulator: `A=4 Adesc=400003 table=400000` and
`A=6 Adesc=3F0003 table=3F0000` — addresses in the 0x200000–0x7000000 hole, which is not RAM on this
machine at all.

**So it is not a memory leak:** nothing reclaimable is being skipped, because those are not managed
pages. The skip is the correct action. What is now measured, and was not before, is that *every*
address-space root systematically carries two descriptors pointing outside RAM — most likely inert
stock-030 remnants written at address-space creation, which the 040 port never uses because kernel
VAs go through DTT0/`kptr040`. Worth its own look (who writes root[4] and root[6]?), but it is
noise, not damage, and it does not block anything.

## ⚠ ISSUE-10 / amixadm is INTERMITTENT — and that invalidates single-boot bisects (2026-07-31)

> **Ledger: OPEN** — earlier record of ISSUE-10; the first ISSUE-10 section above carries the current one.

Recorded so the next session does not repeat the afternoon: `amixadm` crashed at startup on
`unix-040-rtg-260731-05`, and on a **second boot of the same image** it started cleanly. The trigger
is therefore probabilistic per boot, not a property of a kernel that a single boot can decide.

Everything gathered today is a set of **samples, not verdicts**:

| kernel | terminal | result | what it is worth |
|---|---|---|---|
| `unix-040-quiet-base-260731-02` | telnet | clean | one sample |
| same | console | clean | one sample |
| `unix-040-va2000-only-260731-07` (+2.5 KB, the only variant that runs driver code at boot) | console | clean | one sample |
| `unix-040-rtg-260731-05` (+37 KB, both drivers) | console | **CRASH**, then clean on reboot | the intermittency itself |

The bisect ladder built for it was designed on the assumption of determinism, so its conclusions
("VA2000 ruled out", "base is clean") are **unproven**, not wrong. The images are kept because they
are still the right ladder — they just need a rate per image instead of a verdict per boot:

```text
unix-040-xsvga-only-260731-06   Xsvga only            (+34 KB)
unix-040-pad-260731-09          DEAD SPACE, no driver, byte-identical section geometry to the
                                Xsvga image (text 0xec9f4, .data off 0xeca28 size 0x18e00) --
                                separates "the driver" from "the size" once a rate exists
```

**Where to do this: the emulator, not the machine.** `test-tools/emu-amixadm-test.sh` runs one
unattended reproduction cycle in ~4 minutes, and ISSUE-10 reproduces there (2026-07-29, on
`unix-040-quiet-260729-08`). N cycles per image gives a crash rate; a hardware boot gives one
sample for the cost of a session. The kernel under test must carry `serdbg` (quiet or dbg), or the
console NOTICE lines never reach the serial mirror and a silent log is an instrument failure rather
than a clean run — the same rule that governed ISSUE-38.

Instrumentation is now in place for whenever it does fire: `hat_pfnmiss_n` is a **boot-time constant
of 10** on the base kernel (measured across 20 exec generations, a full `amixadm` session and a
compile — it does not move with runtime work), so any other reading taken after a crash is directly
interpretable, as are `us_odd_user` (0) and `wb_dfc_changed`.

**Not being hunted further right now**, deliberately: chasing an intermittent one hardware boot at a
time buys nothing until there is a rate ([[feedback-pause-elusive-bug-hunting]] applies).

## ⚠ ISSUE-39 (2026-07-31): `hat_sdtalloc` runs out of contiguous memory during the burst suite

> **Ledger: OPEN** — 68040 hardware; fragmentation, not pressure. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

Seen on the console during the 16-burst acceptance run on `68040-260731-10`, by a human watching the
screen. It is a kernel `cmn_err` warning, not a panic:

```text
hat_sdtalloc(0x40001A70,0x1,0x0) - not enough contiguous memory for segment tables; 1 pages.
 (called from 0x80B69B4, pid 1751, syscall 0x3(0x3,0x8037F6B0,0x2000))
```

`0x80B69B4` decodes to **`hat_ptalloc+0x126`**: a page-table allocation asked `hat_sdtalloc` for one
page of segment-table memory and did not get it, while the victim was inside `read(3, ..., 0x2000)`.

**Data integrity was unaffected in that run.** The suite finished its bursts with every verification
`V0_COMPLETE_MATCH` — a short or corrupted copy would have shown as `V4_INODE_SHORT` or
`V5_DATA_MISMATCH`. `cb_rel_reject` and `us_odd_user` both stayed 0.

**Whether this is new is UNKNOWN, and the reason matters.** Both this run and the 2026-07-30 run
that preceded it used *base* images, which have no `conputc` serial hook — so a console warning
leaves no trace anywhere. It has very possibly been happening in every burst run since the suite
existed. Do not record it as a regression of the quieting unit or of anything else landed on 07-31
without evidence; there is none either way.

**Why it is worth its own number rather than a footnote.** It is direct evidence for the memory
regime the two open intermittents live in: the `b2repro` stalls of 200-900 s (RESUME §8) and the
`amixadm` crash, both of which were guessed to be memory pressure and never measured. And
`hat_ptalloc`'s steal path under pressure is precisely the mechanism behind ISSUE-10 chain II, which
is why `hat_exec040` disables the exec-time table move.

**The cheap next step is a counter, not a hunt.** `hat_sdtalloc` failures should be counted in
`.data` the way `hat_badaslot_n` and `cb_icode_push` are, so the rate is readable with `kpeek`
afterwards instead of depending on someone watching a screen. Sampling `freemem`/`availrmem` across
a burst run would say how close the machine gets to the edge. Neither needs a hardware session of
its own — they ride along with the next boot.

---

## ✅ ISSUE-41 (2026-08-06): `segvn_faultpage` had no per-page permission check — partial `mprotect` + a denied write PANICKED the kernel

> **Ledger: FIXED** — 68040 + 68060 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**Status: FIXED** in `src/segvn_prot040.s`, kernel `260806-05` and later (commits
8787bfd finding, d93b04d fix, 88543b6 + 0ef9be2 regression). Record:
`docs/SEGVN-PAGEPROT-PANIC-260806.md`. Predicted statically by Codex
(`amix-kernel-analysis/vm-map/XPAGE-FPROT-CONTRACT.md`, 0a3aab3) before it was reproduced.

**Symptom.** Any program that `mprotect`s *part* of a mapping read-only and then writes it takes
the machine down:

```text
PANIC: KERNEL FAULT psw=0x2000, pc=0x80AE1D4 (as_fault+0xcc), fmt=0x7, vector=0x2
kernel stack full of ktraps -> k_trap -> usrxmemflt, ~90 frames
```

Reproduced on the emulated **68040** with an aligned write and **no page crossing**, on
`68040-260806-02` — the image accepted on real hardware that morning. Protecting a *whole*
segment behaves correctly, which is the diagnostic difference.

**Cause.** Linked AMIX `segvn_faultpage@0xac01a` loads `vpage->vp_prot` and jumps straight into
the fault body; the SVR4 rejection between them is absent:

```c
if ((vpage->vp_prot & protchk) == 0) return FC_PROT;   /* 3B2 seg_vn.c:1074-1095 */
```

The denied write therefore enters the COW/revalidation body, the mapping is reloaded
**read-only**, and `as_fault` returns 0. The instruction restarts, faults identically, and the
retry recurses until the kernel stack is gone. The compiler even emitted the `switch (rw)` whose
`protchk` result is never used — the rejection was dropped from the source, not optimised away.
`segvn_fault@0xac46a` still performs the equivalent check for the **segment-wide** case
(`moveq #4,%d0` = `FC_PROT`), which is why case A passes.

Codex reports the function's first `0x60` bytes are byte-identical to vanilla `stand/unix`, so
**this is a stock AMIX omission, not a 040/060 port regression.** It presumably breaks the 030
kernel too; untested there.

**Fix.** A tail-call wrapper (`--globalize-symbol` + `--weaken-symbol segvn_faultpage`,
`segvn_faultpage_orig` at `0xac01a`) performing the rejection. **Not CPU-gated** — the defect
breaks both CPUs identically. Counters `segvn_prot_pp_n` / `segvn_prot_n` / `segvn_prot_last_addr`.

**Verified.** `protfault` case B: PANIC → SIGSEGV on both emulated CPUs. Battery 11/11 on the
040 *and* the 060, burst 96/96 on the 040, `hat_pfnmiss_n` +2 exactly. The load-bearing pair is
`segvn_prot_pp_n` = 1687 with `segvn_prot_n` = 1: the restored check ran constantly and denied
only the one access that was meant to be denied.

**Not verified on hardware.** The Amiga is still on `68060-260806-02`.

**Worth checking:** anything in the installed system that uses partial-mapping protection — X11,
`ld.so`'s GOT handling, `malloc` guard pages — has been running on a kernel where that pattern
was fatal.

---

## ✅ ISSUE-42 (2026-08-06, CLOSED ON HARDWARE 2026-08-13): on the 68040, a denied write-back replay is swallowed — missing fault propagation, silent lost store

> **Ledger: FIXED — 68040 hardware (A3640), 2026-08-13.** `protfault` 3/3, and the defect itself
> reproduced on the same boot with `wbf_prop_on = 0`, which killed the emulator-artifact
> hypothesis. Record: `docs/REALHW-A3640-260813-ACCEPTANCE.md`. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

> **Retitled 2026-08-07.** This was filed as "completes a write into a protected page — protection
> bypass". That was an over-claim, and both the Codex audit and a direct measurement refute it:
> the replay store **does** fault, and the error is then discarded. See "Corrected mechanism" below.

**Status: OPEN**, and it is a *correctness* bug rather than a crash. Found once ISSUE-41's panic
stopped hiding it. Record: `docs/SIGINFO-TRANSLATION-260806.md` §"Still open".

**Symptom.** `protfault` case C on the emulated 68040 with kernel `260806-05`/`-06`: a misaligned
write starting at `page_end - 2`, crossing into an `mprotect(PROT_READ)` page, **succeeds**. The
child survives and exits with the protection-bypass status instead of dying of SIGSEGV.

```text
040   case a PASS   case b PASS   case c FAIL: the protected store SUCCEEDED
060   case a PASS   case b PASS   case c PASS  (fixed by the F4 siginfo translation)
```

**Corrected mechanism (2026-08-07): the store is denied, and the denial is thrown away.**
Codex's audit (`amix-kernel-analysis/vm-map/ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md`, 8fd31fd)
plus a counter measurement on the emulated 040 establish the real chain:

* the live PTE **is** write-protected — this is not an `mprotect`/hat accounting bug;
* the emulated write-back carries **FC = 1 (user data)**, so no supervisor privilege is involved;
  a supervisor FC would not have helped anyway — the W bit binds supervisor writes too, though FC
  does select a different translation;
* the far-page replay store **faults correctly**;
* `Lwb_fail` (`wb040.s:661`) restores `u_nofault`, counts, prints a capped `cmn_err`, and `rts` —
  the failure is not propagated, so the outer resolver's original success (`d4 = 0`) flows out and
  the process resumes with no signal.

Measured on the emulated 040, kernel `260806-06`, across a single `protfault c`:

```text
Lwbf_n          0 -> 1     exactly one replay store failed permanently
wb_replay_odd  82 -> 82    unchanged: the failing replay used FC = 1, not a supervisor code
wb_replay_n 10785 -> 11063 (background replay traffic)
```

**So what is proven is missing fault propagation and a silent lost/partial store — NOT that the
protected page's bytes changed.**

**Measured 2026-08-07** (`protfault` now snapshots the target bytes after `mprotect` and reads
them back if the child lives, instead of inferring the mechanism from survival):

```text
case c, emulated 040, 260806-06
  protected bytes:  01->01  00->00      page 2 is UNTOUCHED -- there is no protection bypass
  unprotected half: 00->5a  00->5a      page 1 DID take the store
  Lwbf_n            1 -> 2              one more permanently-denied replay, swallowed as before
```

**ISSUE-42 is therefore a silently TORN store.** The half of the misaligned write that lands on
the writable page is applied, the half that would land on the protected page is denied, the denial
is discarded, and the process continues with no signal and no error — holding half of a store it
believes completed. That is worse than a lost store and better than a bypass, and it is neither of
the two things this issue was originally filed as.

The 060 has no write-backs, which is consistent with C passing there.

**The contract question is ANSWERED (2026-08-07, Codex 8fd31fd):** validate WB1/WB2/WB3
**independently**. A write-back address differing from the original FA is *not* grounds to drop
it. The first permanently denied **user** write-back must stop the replay and become a protection
fault for *that* write-back's address. This matches the write-back ordering Motorola requires and
the fault-propagating implementations in NetBSD and Linux m68k; discarding is wrong, and so is
today's silent swallow. Implementation is not yet written.

**Not a regression.** The unfixed kernel panicked before ever reaching this state, so this
became *observable* only after ISSUE-41 was fixed — it was presumably always there.

**Task written 2026-08-07: `docs/archive/ISSUE42-WBREPLAY-CODEX-TASK.md`.** Two facts found while writing it
sharpen the question above. (1) The replay runs **only where the stock resolver returned 0**
(`wb040.s:83-87`), so it is not on a "fault is fatal" branch at all — the resolver resolved the
*near* page and a write-back may target the *far* page it never examined. (2) There is **no
real-68040 datapoint**: the machine is a 68060 now, and `wb040.s`'s own verified comment says the
emulator never sets WB1S valid, so an emulator artifact is a live hypothesis. The task also asks
where the permission is actually lost (PTE vs segment protection) and whether the replay's
`DFC = WBxS & 7` buys it a privilege it should not have — either would move the fix out of
`wb040.s` entirely.


### ✅ IMPLEMENTED 2026-08-12 — the denial is propagated, and the replay stops at it

`src/wb040.s`, per the contract's ten behavioural items. What changed:

* `Lwb_fail` no longer skips the failed write-back and continues. It classifies by the write-back's
  **own function code** — a user-FC denial is a user protection fault whichever wrapper is on the
  stack, a supervisor-FC one must never enter the user signal ABI (item 9) — then drops
  `Lwb_do`'s return address and returns straight to the wrapper. That is what stops the ordered
  replay mechanically: k_trap rte's into the landing pad with the trap-time stack, so `addql #4,%sp`
  leaves the remaining write-backs unprocessed (items 5 and 7).
* `usrxmemflt` turns that into complete `k_siginfo_t` state — `si_addr` is the **failing write-back
  byte**, not the near FA the CPU reported (item 6). `krnxmemflt` stops and counts without touching
  the signal ABI.
* The class is not guessed: the nested resolution that failed records its own verdict, and the
  address comes from the CPU's fault address in the format-7 frame.

```
  emulated 68040   case c FAIL (torn store)  ->  case c PASS (SIGSEGV), PROTFAULT fails=0
  same boot, A/B   wbf_prop_on 1 -> PASS, 0 -> FAIL with the old wording, 1 -> PASS
  attribution      wbf_user_n 1, wbf_signal_n 1, wbf_nosig_n 0, wbf_afb_n 0
                   si_signo 11 (SIGSEGV), si_code 2 (SEGV_ACCERR), si_addr = the page's first byte
  boot traffic     wbf_fail_n = 0 after a full boot: ordinary replays are never denied, so the
                   new signalling does not kill processes that used to survive
  emulated 68060   every wbf_* counter 0 -- the format-7 gate is this unit's CPU gate
```

Record: `test-tools/issue42-emu-verify-260812.txt`, including **two pre-registered predictions that
were wrong** and the defect each one exposed in the first build — an `si_addr` that was one byte
past the denial (the replay loop's post-increment), and a diagnostic block that cleared itself
before anyone could read it.

**WHY THIS IS STILL A BLOCKER.** No 68040 silicon has run it. `wb040.s`'s own verified comment
says the emulators never set WB1S valid, so everything measured is WB2/WB3 and the WB1 path with
its ISSUE-11 realignment is unexercised. Hardware acceptance needs the A3640 card swap and is
bundled into `docs/archive/NEXT-040-SESSION-RUNLIST.md`.

**Two things deliberately not done**, both stated in the source rather than hidden: write-back
state is not retained across a signal handler that repairs the mapping and returns (contract item
8 — no measured victim, and it needs somewhere to keep per-process WB state), and the
supervisor-FC branch is unexercised (`wbf_sup_n` = 0 in every run so far).

### Follow-up audit, same day: two of the above were defects, and both are fixed

`vm-map/ISSUE42-WBREPLAY-FOLLOWUP-AUDIT.md` answered the three questions raised by the
implementation. Two were defects in `-05`:

* **`WBS & 7` is a transfer MODIFIER, not a function code.** TM 1/2 user data/code, 5/6
  supervisor data/code, 3/4 MMU table search, **0 a data-cache push**, 7 reserved. The first
  classifier bucketed 0..2 as "user", so a failed cache push would have delivered SIGSEGV to a
  process for an access that was not even its own. Only TM 1 and 2 signal now.
* **"Stop and return success" was rejected for everything else.** Stopping only meant "attempt no
  further slots" while the interrupted kernel operation still returned success — a supervisor
  store, a table-search write or a dirty-line push would still vanish silently. The audit's safe
  pilot policy is *resolve or fail fast*; the fail-fast half is implemented, with the slot, WBxS,
  address and outer `u_nofault` value in the panic. `wbf_sup_fatal = 0` restores the old silence.
* **The landing pad had no owner.** `u_nofault` is one scalar that `k_trap` only tests for
  non-zero — not the faulting PC, not the SP — and interrupts are not masked while it is armed.
  An unrelated kernel fault landing there would have had a foreign `d2` written into `u_nofault`
  and then stack surgery performed on a stack we do not own. `Lwb_do` now records a cookie and
  the SP before arming; the pad refuses anything else and panics with both stacks. The outer
  owner rides in `a0`/`a1`, so a nested replay hands its parent's arm back intact.

Measured on `68040-260812-06`: `wbf_alien_n` 0 and `wbf_own_cookie` 0 at rest after a full boot
(the ownership check survived the boot's replay traffic without one false landing), `protfault`
3/3 with `wbf_fc` = 1, and every `wbf_*` counter 0 on the 68060.

**Still owed from the same audit:** the *resolve* half (retry a denied supervisor write-back in
the supervisor address space before failing), clearing completed WB valid bits in the frame, and
a sanitized `sigreturn` cleanup — for which AMIX already preserves the whole format-7 frame
through `ucontext.mc_state -> u+0x1e4 -> stkrestore`, so no new storage is needed, only a
`berr_040cleanup`-shaped handler that never replays supervisor authority arriving from user
context.
## ✅ ISSUE-43 (2026-08-11, CLOSED ON HARDWARE 2026-08-12): on the 68060, an enabled FP exception with a ZERO SOURCE OPERAND loses fp0-7 across a signal

> **Ledger: FIXED** — 68060 hardware, 6/6 bit-exact. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**Measured, real hardware, `68060-260810-03` and reproduced on `-05`.** Instrument:
`test-tools/fpenab060`, one child per IEEE class, Motorola's own fixture values from
`dist/ftest.s`. Five of the six enabled classes return Motorola's exact post-state bit for bit.
Divide-by-zero does not:

```
  DZ v50   FP0   got 7fff0000:ffffffff:ffffffff   want 40000000:80000000:00000000
           FPSR  got 00000000                     want 02000410
           FPIAR got 00000000                     want 80000752
```

i.e. the FPU **reset** state. The kernel counters rule out the M4 wiring immediately:
`f60_vec50_n` +1 and `f60_dz_n` +1, correctly paired, exactly like the five that pass.

### Root cause — a byte offset, in stock code

On a 68060 the fsave frame's discriminator is at **`frame + 2`**. Word zero belongs to the
extended **source operand** and carries its exponent. Stock `fpu_save` (`0x144`) and
`fpu_restore` (`0x15e`) test **byte zero**:

```
fpu_save    0x144: tstb %a0@(112) ; beq -> do NOT save fp0-7 / fpcr / fpsr / fpiar
fpu_restore 0x15e: tstb %a0@(112) ; beq -> null_state -> frestore = RESET, restore nothing
```

So an FP exception whose **source operand is zero** — which is precisely divide-by-zero — reads
as "this process has no live FP state", and the registers are dropped across the signal. The
five passing classes pass only because their operand's exponent happens to be non-zero. Nothing
about DZ is special except its operand.

Confirmed by Codex, `amix-kernel-analysis/vm-map/FPU-LAZY-CONTRACT-AUDIT.md` (`64b55cf`), which
also settles two things this port had wrong or unknown:

* bit 0 of `u.u_fpu.ustate` is **`UFPRWRT`** — "programmatically modified register image", not a
  lazy-FPU ownership flag. Only confirmed setter: `procxmt` / old ptrace at `0x47fac`.
* all 22 `_fpsp_done` exits were walked; **no genuine null-frame-with-live-registers state exists
  statically**, so this is not reachable from ordinary FP code — it needs an *enabled* exception.
  That bounds the severity: no silent data loss in normal programs.

### Two fix attempts that FAILED — do not repeat either

1. **`fpu_save` + `UFPRWRT`** (`f00a9d2`): saved the registers on a null frame and set bit 0 so
   `fpu_restore`'s `null_state` would restore them. Turned 5-of-6 into **0-of-6** on hardware.
   The bit was read backwards: in `fpu_save` "set" means *skip saving*.
2. **A word-zero null guard in the FPSP glue** (`9245d81`, removed): `tstw %sp@` classifies a
   zero source operand as a null frame and discards the state — the same offset error, in our
   own code. Motorola's original three-instruction prelude (FSAVE, `0x6000` at offset **two**,
   FRESTORE) is restored for all six exits.

### The corrective unit — WRITTEN AND EMULATOR-ACCEPTED, hardware verdict owed

1. ✅ Motorola's prelude for all six IEEE exits — `9245d81`.
2. ✅ 68060 `fpu_save` / `fpu_restore` test **`fp+0x72`**, `UFPRWRT` semantics and the inherited
   branch ordering unchanged — `src/fpu060.s`, `140e0c0`.
3. ✅ A complete 12-byte 68060 reset frame in the 68060 `fpu_setup` path — same unit.
4. ✅ **The 68040 path is byte-identical**: `0x132`/`0x158`/`0x19b50` compare equal to vanilla in
   the built image, and every `fpc_*` counter reads 0 on an emulator 040 boot.

Emulator acceptance, one image `68040/68060-260812-01`, both CPUs (2026-08-12):

```
  060  fpc_save_n 10080  fpc_rest_n 9386  fpc_setup_n 470   <- the new path really runs
       fpc_odd_n 0       every post-FSAVE format byte was 0x00, 0x60 or 0xe0
       fpc_null_n 9229   fpc_idle_n 855   fpc_excp_n 0
       fp060probe bad=0 (7/7, 0 ulp);  fputest060 fork correct in child and parent
       f60_fpudis_n 0;  f60 entry/mem/done 6/6/6, real 0
  040  every fpc_* counter 0;  fp060probe bad=0 through the 040 package
```

`fpc_null_n`/`fpc_idle_n` is the honest replacement for the retracted "7100 null saves": 92 % of
060 saves really are null frames, but now measured by byte two instead of by an operand exponent.

### ✅ CLOSED ON HARDWARE 2026-08-12 — `68060-260812-02`, six of six bit-exact

```
  OPERR v52  OK  fp0 ffff0000:00000000:00000000  fpsr 01002080  fpiar 80000628  sigs 1
  OVFL  v53  OK  fp0 7fff0000:00000000:00000000  fpsr 02001048  fpiar 8000068c  sigs 1
  UNFL  v51  OK  fp0 00000000:40000000:00000000  fpsr 00000800  fpiar 800006f0  sigs 1
  DZ    v50  OK  fp0 40000000:80000000:00000000  fpsr 02000410  fpiar 80000752  sigs 1
  INEX  v49  OK  fp0 50000000:80000000:00000000  fpsr 00000208  fpiar 800007b4  sigs 1
  SNAN  v54  OK  fp0 7fff0000:80000000:00000001  fpsr 01004080  fpiar 80000816  sigs 1
                                                              FPENAB060 bad=0
```

Regressions on the same boot: `fp060probe bad=0`, `ftest060 unimp` passed / `died=0`,
`ftest060 main` four sub-tests passed, `fputest060 fork` correct, `isp61ea bad=0`,
`f60_fpudis_n` 0. Counters: `f60_entry_n 6 = f60_real_n 6 = f60_arith_n 6`, `f60_bsun_n 0`;
`fpc_save_n` 8059, `fpc_setup_n` 256, `fpc_odd_n` 0, `fpc_save_wrt_n`/`fpc_rest_wrt_n` 0.
Full record: `docs/REALHW-ISSUE43-ACCEPTANCE-260812.md`.

**The first hardware build, `-01`, found a second defect one day old — see ISSUE-44 below.**
DZ passed on `-01` too, so the ISSUE-43 unit was proven before that defect was fixed.

⚠ **A pre-registered prediction that was wrong, recorded as wrong:** the run-list expected
`fpc_excp_n` non-zero on hardware. It stayed 0, because our own `Lco_fparith` writes the idle
status `0x6000` at offset two and FRESTOREs it before jumping to `nullvect` — so the OS can only
ever see an idle or null frame, never `0xe0`. The verdict did not depend on it; the mechanism
behind the prediction was still mine and still wrong.

⚠ Silicon's null/idle split is far sharper than the emulator's: 8048 null vs 17 idle on hardware
against 9229 vs 855 under Amiberry. The conclusion holds either way, but the emulator is not a
proxy for the rate.

Two branches of the new code are unexercised on both CPUs by construction: `fpu_save`'s `UFPRWRT`
early return and `fpu_restore`'s null-frame + `UFPRWRT` republish. Their only originating setter
is old ptrace, and no instrument in this repo writes FP registers through it (audit gate 6). The
instructions are the inherited ones, so this is a coverage gap, not a suspected defect.

Separate latent gap found by the same audit, not part of this issue: the `/proc` path
`prsetfpregs` does not set `UFPRWRT` where `procxmt` does.

## ✅ ISSUE-44 (2026-08-12, FIXED THE SAME DAY): the FPSP arithmetic exit fell through into the BSUN body

> **Ledger: FIXED** — 68060 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> The text below is the working record and may contain hypotheses later refuted;
> STATUS.md §7 lists which.

**Found on silicon by an invariant counter, on the first boot of the build that contained it.**

`9245d81` removed the null-frame guard from `Lco_fparith` in `src/fpsp060_glue.s`. That
removal was correct — the guard was itself a defect, built on the same byte-offset mistake as
ISSUE-43. But the guard block **ended in the exit's own `jmp nullvect`**, and removing the block
took the jump with it. Every arithmetic call-out then fell through into `Lco_bsun`.

Measured on `68060-260812-01`, per enabled exception:

```
  f60_entry_n +1     one package entry
  f60_arith_n +1     the class call-out ran
  f60_bsun_n  +1     ... and then the BSUN body ran too
  f60_real_n  +2     against entry +1 -- "entry == done + real_* exits" broken by exactly
                     the size of the fall-through
  kvp_vec[51] +1     only ONE arrival at nullvect, and it was the fall-through's
```

**User-visible damage:** `Lco_bsun` does `andib #0xfe,%sp@` on the saved FPSR, clearing the FPCC
NaN condition bit. Correct for a real BSUN, wrong for every other class. OPERR returned
`fpsr 00002080` where Motorola's fixture says `01002080`.

**Why nothing crashed and four classes still passed:** the BSUN prelude's stack arithmetic
happens to balance (FSAVE 12, push 4, pop 4, `addl #0xc`), and only NaN-valued results carry the
bit it clears.

**Why no test caught it before:** the emulator raises no enabled IEEE FP exceptions, so
`Lco_fparith` never executes there at all (`f60_arith_n` = 0 on both emulator CPUs). The body has
exactly one instrument in existence — `fpenab060` on hardware — and the previous hardware run
(2026-08-11) predates `9245d81`. The build's first boot anywhere was its first execution.

Fixed by restoring the one instruction (`8d4065b`); `68060-260812-02` measures `f60_bsun_n` 0 and
`entry == real == arith`.

**The lesson worth keeping is about instruments, not about assembly.** A passing test would not
have found this: four of six classes were green. What found it was an invariant that spans two
counters — one package entry must produce exactly one call-out exit — and the counter that made
the fall-through visible was the one nobody expected to move.

## ✅ ISSUE-40 (2026-08-01, CLOSED ON HARDWARE 2026-08-02): `availrmem` declined monotonically — page-table pages were never returned

> **Ledger: FIXED** — 68040 hardware. Canonical: [`STATUS.md`](STATUS.md) §4.
> ⚠ `ptd_wake_n` = 0: the `pt_waiting` branch of the fix has never been exercised.

This issue was worked entirely in its own documents and never had a section here, which made it
invisible to anyone reading the numbering. The record, in order:

| Document | What it holds |
|---|---|
| `docs/ISSUE40-AVAILRMEM-DECLINE-260801.md` | the measurement and the mechanism |
| `docs/archive/ISSUE40-AVAILRMEM-TASK.md`, `docs/archive/ISSUE40-PTDAT-CODEX-QUESTIONS.md`, `docs/archive/ISSUE40-CODEX-FOLLOWUP-QUESTIONS.md` | the static contract questions and their answers |
| `docs/ISSUE40-LEGACY-SDT-LANDED-260801.md` | the legacy-SDT teardown edge |
| `docs/REALHW-ISSUE40-PART1-260801.md`, `docs/REALHW-ISSUE40-ACCEPTANCE-260802.md`, `docs/REALHW-ISSUE40-CLOSED-260802.md` | hardware acceptance on `68040-260802-01` |

Kernel side: `src/legacysdt040.s` and `src/ptdatfree040.s`, with the `i40_*` and
`ptd_*` counter blocks (`tools/status-facts.sh` prints their current runtime addresses).

**The one thing left open** is the counter that says a branch never ran: `ptd_wake_n` is 0, so
the `pt_waiting` wake path in the teardown edge has never executed on either CPU. That is a
coverage gap, not a suspected defect — the same shape as ISSUE-43's two unexercised `UFPRWRT`
branches.

---

## ✅ ISSUE-45 (2026-08-14, FIXED THE SAME DAY): every byte-patch assertion in the build was disarmed by a shell pipe

> **Ledger: FIXED** — build tooling; no kernel change. Canonical: [`STATUS.md`](STATUS.md) §4.

**Not a kernel defect. A defect in the thing that checks the kernel** — which is worse, because
it is the layer that decides whether anything else gets believed.

42 of the 43 byte-patch scripts in `src/` assert the OLD bytes before writing the new ones, and
41 of them exit non-zero when the assertion fails. That assertion is the port's central safety
property: the patchers address the kernel by hard-coded offsets, so a patcher firing at a moved
target does not fail — it writes correct bytes to the wrong address. Every one of them was
invoked as

```sh
python3 "$HERE/src/patch_foo.py" "$OUT" | tail -3
```

and in POSIX sh the exit status of a pipeline is the status of its **last** command. `tail`
always succeeds. `set -e` — present since the first version of the script — never saw a thing:

```
$ sh -c 'set -e; (exit 3) | tail -1; echo "still here, status=$?"'
still here, status=0
```

### Measured, not argued

One expected opcode in `src/patch_config_cachefix.py` was changed from `4eb9` to `4eba`,
simulating a patch target that has moved, and the same build was run with the old script and
the new one:

| | old script | after the fix |
|---|---|---|
| exit status | **0** | 1 |
| `[OK] built` printed | **yes** | no |
| patch steps that ran after the failed one | **25** | 0 |
| build id stamped on the result | **yes** | no |

The old build produced a complete, named, plausible kernel image that was missing the ISSUE-21
cache-off handoff fix, and said `[OK] built`. Nothing downstream — not the relocation census,
not the build-id stamp, not the acceptance run-lists — would have distinguished it from a good
one, because all of them describe the image rather than the process that made it.

### Second defect found in the same place

`src/check_relink_relocs.py` **hard-coded** the image path `build/unix-040` and ignored `argv`.
Four variant scripts (`rtg`, `xsvga`, `va2000`, `z3660`) passed their own output as an argument
that was silently discarded, so each was shown the relocation census of a *different* kernel,
labelled as its own. The script also never exited non-zero — it printed `TOTAL complaints: N`
and returned success — so the callers that did check it could not have noticed. `relink-040-rtg.sh`
is the script that builds the kernel used for the RTG hardware sessions.

Re-measured after the fix: all eight existing images are genuinely at 0 complaints, so nothing
was actually wrong in the artifacts — only in the ability to tell.

### Fix

`tools/build-step.sh`, sourced by every relink script: `run_step <mode> cmd...` runs the step
with no pipe, captures its output, prints the requested tail on success, and on failure prints
everything and stops the build. 40 call sites converted; `|| true` removed from the reloc check
and the build-id stamp in three variant scripts (both were measured to succeed on every variant
before hardening). `check_relink_relocs.py` now honours `argv`, exits 1 on complaints and 2 on
an unreadable image, and names the image on its verdict line.

`relink-040-va2000.sh` was found to default to `build/unix-040-dbg.STD-backup`, a scratch image
from 2026-07-24 that predates FPSP being folded into the base — so the script's own FPSP guard
rejected its own default and it could not run without an explicit argument. Now defaults to
`build/unix-040-dbg` like every other variant.

### How it was found, and the one that got away

Found by a second model reviewing the repository for publication readiness — not by any test
here, because no test here tests the build system. Worth recording: while writing the fix, the
first version of `run_step` reported `exit status 0` in its own failure banner, because `$?`
after an `if` is the status of the `if`, not of the command. The unit test caught it only
because the banner prints the status at all. The same lesson as ISSUE-44: the instrument has to
say something falsifiable, or it is decoration.

**Byte-exact regression:** rebuilding the base after all of this yields an image differing from
the pre-change build in exactly **two bytes**, both inside the build-id string (`260813-09` →
`260814-01`). All six variant kernels build; all reloc checks pass against their own image.

---

## ⚠ ISSUE-46 (2026-08-19, OPEN): `/dev/mem` mmap lands one page high, and the test written to catch this class of bug cannot see it

> **Ledger: OPEN** — one 6-byte fix, not yet applied. Canonical: [`STATUS.md`](STATUS.md) §4.

Found by accident, while building a Zorro III probe that mapped `/dev/mem` and checked itself
against an independent path before trusting the result. The self-check failed:

```
Z3 selftest phys 08000000: lseek=46fc2700 mmap=2f004eb9  DISAGREE
```

`46fc 2700` is `movew #0x2700,%sr`, the kernel's first instruction, and it is what the image
holds at `.text+0`. So `lseek`+`read` is right and the **mapping is not where it was asked for**.
The value it did return, `2f00 4eb9`, is at `.text+0x1000` in the same image. The mapping is
**exactly one 4 KiB page high**.

### Mechanism

`mmmmap` (`0x2062c`) computes its page frame number with a **round-up**:

```
20688:  addil #4095,%d0
2068e:  moveq #12,%d1
20690:  lsrl  %d1,%d0            pfn = (offset + 0xfff) >> 12
```

and the retained 2 KiB `segdev` stepping calls `d_mmap` **twice per 4 KiB page**, at `X` and
`X+0x800`:

```
call 1:  (X + 0xfff) >> 12         = n      correct
call 2:  (X + 0x800 + 0xfff) >> 12 = n + 1  wrong
```

Both calls write the **same** 4 KiB leaf, so the second overwrites the first and the whole page
maps `n+1`. The double call is not speculation: the cache-class census measured exactly `+2`
classification events for every single-page probe (`docs/REALHW-Z3-CHANGE-D-260819.md`).

### It was introduced by the Model-B conversion, not inherited

With the stock 2 KiB geometry the round-up was harmless: each call covered its own 2 KiB page and
an aligned offset rounded to itself. `patch_devmmap2.py` converted the constant (`0x7ff` →
`0xfff`) and the shift (`11` → `12`), which makes the site 4 KiB-correct **in isolation** — but a
round-up is only correct when `d_mmap` is called once per page, and under Model B it is called
twice. Converting the constant preserved the bug instead of removing it.

### Scope: exactly one producer

Checked in the linked image, all of them: `scrmmap`, `ammmap`, `timmap`, `va2000mmap` and
`resmmap` contain **no** `addil #4095` — they truncate, which is the correct `btop` contract for
`d_mmap`. `mmmmap` is the only site with the round-up and therefore the only affected path.
Nothing in the kernel uses `/dev/mem`; the blast radius is userspace tools that map it.

### Why the existing test could not catch it

`test-tools/devmaptest.c` T1 exists to check exactly this — `/dev/mem` mmap PFN correctness — and
it passes. Its own header explains why it cannot help here: it is deliberately
*provenance-independent*, checking that offset `P` and `P+4096` differ and that `P` twice is
identical. **A uniform one-page offset satisfies both.** A self-consistency test cannot detect a
systematic displacement; only a comparison against an independent path can, which is what the
Zorro III probe happened to do.

That is the reusable lesson, and it is worth more than the bug: an instrument that only checks
itself will agree with itself while being wrong.

### Fix

Remove the round-up at `0x20688` so `mmmmap` truncates like every other producer. Six bytes, and
it belongs in `patch_devmmap2.py`, which already owns and asserts that site. Not applied yet: it
was found during a Zorro III hardware session and lands with its own before/after evidence rather
than being folded into unrelated work.

---

## ⚠ ISSUE-47 (2026-08-19, OPEN): a user-mode bus error is mishandled — two different ways

> **CORRECTED THE SAME DAY.** This entry first said "retried forever instead of signalling". That
> is one of the two behaviours, not the whole of it. With a Zorro III card present, the serial
> console showed the other:
>
> ```
> DBG as_fault FAIL pid=277 addr=4200F000 type=0 rw=1 ret=505
> Hardware Bus Error @ C1033000, (4200F000 physical)
> NOTICE: User BUS ERROR at C1033000, PC:8000095E FAULT:1 PID:277
> DBG SIG sig=9 pid=277
> ```
>
> The kernel **does** recognise the bus error and report it — and then kills the process with
> **`SIGKILL`**, not `SIGBUS`. Reproduced twice, on `cmfcensus` at `0x4200F000` and on `busbench`
> at `0x42001000`, both in the VA2000's undecoded gap.
>
> That explains a failure that looked like an instrument bug: `z3probe` had handlers armed for
> `SIGBUS` and `SIGSEGV` and neither fired. They were waiting for the wrong signal, and `SIGKILL`
> cannot be caught at all.
>
> **So there are two distinct faults, and they need separate fixes.** Which one occurs is not yet
> attributed — the retry-forever case was an uninitialised Piccolo aperture at `0x40000000`, the
> `SIGKILL` case an undecoded gap inside a live board's aperture. The original text follows.

## ⚠ ISSUE-47 (2026-08-19, OPEN): original text: a user-mode bus error is retried forever instead of signalling the process

> **Ledger: OPEN** — found while probing a Zorro III aperture; no fix attempted. Canonical:
> [`STATUS.md`](STATUS.md) §4.

A user process mapped physical `0x40000000` — a Zorro III aperture belonging to a card nothing had
initialised — and touched it. The debug kernel logged, repeatedly:

```
WARNING: DBG hardbus pid=283 addr=C1033000 pte=40000049 ret=0 upc=80000B74 uva=48478000 n=800
```

`n=0x800` is 2048 occurrences on one address. `ret=0` means `hardbus` reported the fault handled,
so the instruction was restarted, so it faulted again.

**Observed:** the process ran forever, consuming CPU (`18%`, `0:07` accumulated and rising). It
never returned and **never received a signal** — the probe had handlers armed for both `SIGBUS`
and `SIGSEGV` and neither fired. The machine stayed responsive and `kill -9` ended it, so this is
an ordinary fault-retry loop in user context, not a stalled bus cycle.

**Expected:** an unresolvable bus error on a user access delivers `SIGBUS` to that process. A
process that touches a non-responding physical address should die, not spin.

### Why it matters beyond this probe

Any user mapping of an address that does not answer — a device aperture that is powered down,
unconfigured, or simply absent — hangs the process indefinitely. It is recoverable (the machine is
fine, `kill -9` works), so it is a robustness defect rather than a stability one. But it also
**hides** the underlying condition: the probe was written specifically to turn "no response" into
a reported result, with both plausible signals handled, and it still could not report, because no
signal was ever sent.

### Not yet established

Whether `hardbus` is deciding to retry, or is falling through to a default that retries; and
whether the same happens for a supervisor-mode access, which would be considerably more serious.
Both are readable from the handler; neither was chased during a hardware session that was there
for something else.

Full context: `docs/REALHW-Z3-APERTURE-PROBE-260819.md`.


---

## ⚠ ISSUE-48 (2026-08-19, OPEN): `va2_restore_passthrough()` does not restore passthrough on Zorro III firmware

> **Ledger: OPEN** — driver defect in `va2000-amix`, found the evening the Zorro III firmware went
> in. Canonical: [`STATUS.md`](STATUS.md) §4.

When a client exits, the VA2000 driver's `close` path calls `va2_restore_passthrough()` to hand the
display back to the Amiga's native output. On the Zorro III firmware the display **freezes**
instead — it keeps showing a stale image rather than the passthrough picture.

**Reproducible and client-independent**: observed first when X11 exited, then again when wolf3d
exited. It is the routine, not something about one client's teardown.

### The card is not crashed, and that is the point

Measured immediately afterwards, without rebooting:

* `open("/dev/va2000")` still succeeds, which requires `va2000_present()` to read a sane firmware
  version **through the Zorro III kernel mapping**;
* the register window still reads `0x005a` — firmware 90 — the same as before;
* every subsequent open/close makes the display **flicker**, so the register writes are reaching
  the card and changing its state.

So the routine is not ineffective. It is doing the **wrong thing**: it writes a hardcoded 640×480
timing set (`H_SS 840`, `H_SE 968`, `H_MAX 1056`, `V_*`, `PIX_CLK 40 MHz`, `ROW_PITCH 320`) plus
`CAPTURE_MODE = 1`, all tuned against the Zorro II firmware's state machine.

**Recovery is a full mode set**: starting wolf3d, which issues `SVGAIOCSetScreenMode`, woke the
display immediately.

### Scope

Cosmetic-but-annoying rather than dangerous: nothing is corrupted, the machine is unaffected, and
any client that sets a mode restores the display. It matters because leaving X should not leave the
screen dead.

The fix belongs in the driver and needs the Zorro III firmware's own passthrough contract, which is
readable in `va2000.v` — not guessable from the Zorro II values that are there now.

---

## ⚠ ISSUE-49 (2026-08-21, OPEN): a 2048-aligned device mmap offset yields the NEXT page — and two bugs were cancelling to keep the test green

> **Ledger: OPEN** — found by the first run of the documented acceptance battery, on
> `68060-260819-13`. Canonical: [`STATUS.md`](STATUS.md) §4.
>
> **The fault-path half is hardware-accepted, 2026-08-27.** On `68060-260827-06` the battery
> ran **12/12** with `devmaptest` passing — the first 12/12 in this project, and the first time
> `devmaptest` has passed since it was written.
> [`docs/REALHW-ISSUE53-260827-06.md`](docs/REALHW-ISSUE53-260827-06.md). The **mmap** path
> (`spec_segmap`) and the `/dev/screen` extent work described below are separate and still open;
> the 12/12 must not be described as closing this issue.
>
> **Two reproducers, two symptoms, two sites (2026-08-26).** The title describes the
> first only. `devmaptest` T1 is the **fault path** (`segdev_fault`, `0xa7fe4`): a
> 2048-aligned offset yields the next page. The Deluxe Paint port then hit the **mmap
> path** (`spec_segmap`, `0x6766a`): ENXIO, or SIGBUS on the tail, for any mapping whose
> length is not a 4 KiB multiple. Same root cause — 2 KiB stepping retained under a
> 4 KiB MMU — reached two different ways, and they do **not** share a fix. See the
> 2026-08-26 section below before acting on the options list.

`devmaptest` T1 failed:

```
T1 FAIL: /dev/mem same-offset identical=1, base+2048 aliases correctly=0
DEVMAPTEST-RESULT FAIL
```

It has been passing since at least 2026-08-07 (`docs/REALHW-260807-11-ACCEPTANCE.md` §5 records
`DEVMAPTEST-RESULT PASS`). **It was passing for the wrong reason.**

### What the test asks

That a device mapping at offset `base+2048` be the **same 4 KiB page** as one at `base`. That is
correct 4 KiB semantics and the test says so at the site: "mmap maps WHOLE PAGES from the PFN
d_mmap returns, so the sub-page 2048 is dropped".

### Why it now fails, and why it did not before

The retained 2 KiB `segdev` stepping calls `d_mmap` **twice per 4 KiB page**, and both calls write
the same leaf, so **the second one wins**. That is not speculation — it is ISSUE-46's mechanism and
it was measured as `+2` classification events per page in
`docs/REALHW-Z3-CHANGE-D-260819.md`.

| | map at `base` | map at `base+2048` | T1 |
|---|---|---|---|
| **before the ISSUE-46 fix** (`d_mmap` rounded up) | steps give pfn `n`, `n+1` → leaf **`n+1`** | steps give `n+1`, `n+1` → leaf **`n+1`** | identical → **PASS** |
| **after the fix** (`d_mmap` truncates) | steps give `n`, `n` → leaf **`n`** | steps give `n`, `n+1` → leaf **`n+1`** | differ → **FAIL** |

So the round-up made *both* mappings wrong in the same direction, which made them equal, which the
test read as correct aliasing. **Two defects were cancelling into a green result.** Removing one
exposed the other.

### The remaining defect is the stepping, not the fix

`patch_devmmap2.py` records the `segdev` family as **deliberately not converted** and argues its
external crossings are benign, on the grounds that "because d_mmap now returns a 4 KiB PFN both
calls carry the SAME pfn". That holds when the mapping offset is 4 KiB-aligned. It does **not**
hold when the offset is 2048-aligned: the two steps then straddle a page boundary and the second
call legitimately returns `n+1`, which overwrites `n`.

The public mmap ABI admits 2048-aligned offsets (the five sites named in `devmaptest.c`'s header:
`sysconfig 0x44e7c`, `mmap 0x583a6`, `MAP_FIXED 0x5844c`, `munmap 0x584f2`, `mprotect 0x58572`), so
**a program can ask for one and will silently receive the following page.** Same family as
ISSUE-46, reached by a different route, and equally silent.

### Not the scenario the test's own header anticipated

`devmaptest.c` warns that T1 will fail if the public five-site ABI is ever moved to 4 KiB, and that
this would look like a regression without being one. That is a different case. This is a third one:
the ABI has not moved; a producer stopped being wrong and the consumer's 2 KiB stepping became
visible.

### What to do — not decided

Either convert the `segdev` family to 4 KiB as one unit (the `vpage` array size and every
`seg_page()` index together, which `patch_devmmap2.py` declines as unjustified risk without a
demonstrated defect — there is now a demonstrated defect), or reject non-page-aligned device mmap
offsets at the ABI, or accept and document the behaviour. `devmaptest` T1's expectation is correct
and should not be relaxed to make the red go away.

**Do not "fix" this by restoring the round-up.** That would re-mask it and reinstate ISSUE-46.

> **This list is incomplete as of 2026-08-26.** A fourth option exists for the second
> reproducer and is driver-side rather than kernel-side, and the second option — rejecting
> non-page-aligned offsets at the ABI — does not address it at all, since that offset is
> 0 and page-aligned and it is the *length* that is not a 4 KiB multiple. See below.

### 2026-08-26: a second, independent reproducer — and it is a DIFFERENT site

Reported from the Deluxe Paint port (`~/kehitys/amix-playground/dpaint-amix`), which hit
this while trying to use native 320x256 lores and spent a week routing around it.

**The reproducer.** `/dev/screen`, `SIOCALLOCBMAP` a 320x256x5 bitmap, `mmap` one
bitplane. The plane is `320*256/8` = **10240 bytes**. On `68060-260813-01`:

```
mmap(10240)                                   succeeds, reads fine, first STORE -> SIGBUS
mmap(12288)                                   ENXIO
mmap(8192)                                    fully writable   <- two whole 4 KiB pages
MAP_FIXED tail page at offset 8192, len 4096  ENXIO
```

On **stock AMIX 2.1p2a on a 68030**, measured 2026-08-26 in a dedicated Amiberry
instance, all of those work and `PAGESIZE` reads 2048:

```
>>> lores  non-lace   320x256 x5  10240   5.0 pages  YES
>>> lores  HAM        320x256 x6  10240   5.0 pages  YES
>>> lores  HalfBrite  320x256 x6  10240   5.0 pages  YES
```

So this is ours, not Commodore's: every geometry `scrdev.c` offers is an exact multiple
of 2048, which is its own kernel's page size. Write-up and probe:
`dpaint-amix/probe/results/2026-08-26-stock-030-emulator.md`.

**Why it is a different site from T1's.** The two symptoms come from two separate
2 KiB steppings, and conflating them would send the fix to the wrong place:

| | site | what it does | symptom |
|---|---|---|---|
| **T1 / devmaptest** | `segdev_fault` `seg_page()` `0xa7fe4` | fault-time PTE load, twice per 4 KiB page, second wins | 2048-aligned offset yields the NEXT page |
| **this reproducer** | `spec_segmap` loop step `0x6766a` | **mmap-time validation only** | ENXIO for any length that is not a 4 KiB multiple |

The `spec_segmap` loop (`svr4-src-3b2/.../fs/specfs/specvnops.c:1349`) is three lines: it
walks an index from zero to `len` in `PAGESIZE` steps, calls the driver's `d_mmap` at
`off` plus that index with `maxprot`, and returns `ENXIO` the first time one answers `-1`.

`len` arrives already rounded up by the public mmap ABI, which **is** at 4 KiB. With
`PAGESIZE` still 2048 here, a 10240-byte request becomes len 12288 and the loop's last
call lands at `off + 10240` — one 2 KiB step past the object. `scrmmap`'s bound is
`offset < bp->width*bp->height/8` (`scrdev.c:766`), so it returns -1 and the whole mmap
fails. **The producer/consumer split is between the 4 KiB ABI and this 2 KiB loop, not
inside segdev.**

**CORRECTED the same day — there is no cheap kernel-side subset.** The first version of
this entry claimed `0x6766a` could be converted alone, since `spec_segmap` is pure
validation and never touches the vpage array. That premise is true; the conclusion was
wrong, because it stopped reading before the fault path. **`segdev_fault` steps `d_mmap`
the same way and fails identically** (`seg_dev.c:370`) — it walks an address cursor
across the faulting extent in `PAGESIZE` steps and calls the
segment's map function at `sdp->offset` plus the cursor's distance from `seg->s_base`,
treating a returned `-1` as the failure.

Converting the validation loop alone would therefore turn the ENXIO back into a SIGBUS,
not into a working mapping. That the two observed symptoms differ by request length is
precisely this: `mmap(10240)` clears validation (last call 8192) and dies at fault time
(call at 10240); `mmap(12288)` dies in validation. Both need `d_mmap` never to be asked
past the object.

And `segdev_fault`'s loop carries `vpage++` per `PAGESIZE`, indexed from
`seg_page(seg, addr)` — so its step **is** tied to the vpage array geometry.
`patch_devmmap2.py`'s refusal covers this site fully and stands unchanged. The family
conversion is the expensive option and it is the only kernel-side one.

Caveat on all of the above: it is read from `svr4-src-3b2`, not from this image's
disassembly. Confirming that AMIX's specfs and seg_dev match that lineage here is the
first question in `dpaint-amix/docs/ISSUE-49-REVIEW-BRIEF.md`.

**The cheap fix is driver-side, and it is a fix rather than hardening.** Round the
bitplane allocation up to 4 KiB so `d_mmap` is never asked past the end:

- `allocbmap` (`scrdev.c:71`) — allocate the rounded size
- `freebmap` (`scrdev.c:110`) — free the same size, or the chip map corrupts silently
- `scrmmap` (`scrdev.c:766`) — the bound `offset < width*height/8` must round to match

all three from one shared macro. Cost: at most 4095 bytes per plane, 10 KB for
320x256x5. The rounded plane then genuinely owns its last page, which also closes the
half-owned tail a 4 KiB mapping of a 10240-byte object would otherwise expose —
`scrdev.c:71` allocates `width*height/8` exactly today, and `memory.c:67`'s `MEMF_PAGEB`
path explicitly frees the slack back to the chip pool. Correct on both kernels: at 2 KiB
a 12288-byte plane is simply 6 pages instead of 5.

`PAGESIZE` in `param.h` is still `0x800`, so this must round to a **literal 4096**.
Rounding to `PAGESIZE` compiles to a no-op, since 10240 is already a 2 KiB multiple —
an easy way to ship a patch that looks correct and changes nothing.

**Open before writing it:** whether `allocbmap`/`freebmap`/`scrmmap` are the only
consumers of `width*height/8` or of an assumed plane size — copper-list bitplane
pointers, display DMA, `screen_vbint`, `SIOCSELBMAP`, the console renderers in
`c0.c`/`c1.c`/`c3.c`. `sys/amiga/console/` ships as source in `amix-sources.tar`, so it
is answerable by reading. That is question 3 in the brief, and it is the one that
decides whether this is done driver-side at all.

This does **not** address T1, whose aliasing is a separate live defect on the fault path
and still wants the family conversion. That one reaches every device that maps memory,
VA2000 and ZZ9000 included.

### 2026-08-27: question 3 answered from the source, and a second driver-side defect

**Q3 — is the cheap fix available?** Yes. Every consumer of a *mappable* plane's size was
read out of `sys/amiga/console/` in `amix-sources.tar`:

| site | what it does | affected by rounding the allocation up? |
|---|---|---|
| `allocbmap` `scrdev.c:74` | `size = width*height/8`, one `AllocMem(MEMF_CHIP\|MEMF_PAGEB)` **per plane**, already `bzero`ed | must round |
| `freebmap` `scrdev.c:109` | frees the same `size` | must round, or the chip map corrupts |
| `scrmmap` `scrdev.c:788` | bound `offset < width*height/8` | must round to match |
| `c0.c:38` `PLANESIZE`, `c1.c:528/646-675/728-736`, `c3.c` `bmpos` | `width/8` as a **row stride**, `height*width/8` as a logical extent, for rendering and scrolling | no — they never index past the logical extent, so padding is simply untouched |
| `c0.c:281/286/347` | allocates the **console's own** bitmaps, plain `MEMF_CHIP`, no `PAGEB` | no — not `/dev/screen` planes and never mapped |

**No code assumes inter-plane contiguity.** Each plane is its own `AllocMem`, and `bmpos`
indexes `bpl[z]` individually; `c3.c:172`'s `+ width/8` is a second bitplane pointer *within*
plane 0, not a step across planes. So the three-site fix is available, which is what question 3
gated.

**And a second defect the brief did not name: the plane base is only 2 KiB aligned.**
`AllocMem`'s `MEMF_PAGEB` path (`memory.c:75`) aligns to `PAGESIZE`/`PAGEMASK` from `param.h`,
which is still `0x800`. `scrmmap` returns `phystopfn(bp->bpl[bpnum] + offset)`, and
`patch_devmmap_pfn.py` converted that `phystopfn` to `>>12` (site `0x8384`). So when a plane
base is not 4 KiB aligned, **the frame that comes back starts up to 2048 bytes before the
plane** and the whole mapping is displaced. That is independent of `segdev`'s stride and the
ISSUE-49 bridge does not touch it.

With `320x256x5` the per-plane size is 10240 = five 2 KiB units, so consecutive planes cannot
all land on 4 KiB boundaries.

The same `MEMF_PAGEB` path also does `mfree(chipmap, btoC(PAGESIZE-(p1-p0)), btoC(p1+nbytes))`
— it hands the slack **after** the plane back to the chip pool. So the tail of a 4 KiB mapping
of a 10240-byte plane is memory the plane genuinely does not own and the allocator may have
given to somebody else.

**Consequence for how the bridge is described.** The bridge makes the `mmap` *succeed*. On its
own it can therefore turn a loud `ENXIO` into a silent displaced or half-owned mapping. The
driver-side work is **correctness, not hardening**, and "`devmaptest` passes / battery 12/12"
must not be read as "DPaint works now".

### Prediction, written before the measurement

Run `dpaint-amix/probe/scrprobe pokeall` on a bridge kernel (`68060-260827-06` or later):

1. the `mmap` **succeeds** for the geometries that previously returned `ENXIO` — the bridge's
   `spec_segmap` stride fixes exactly that;
2. the writability matrix is **not** clean: at least one plane of `320x256x5` reads or writes
   displaced by 2048 bytes, because its base is not 4 KiB aligned;
3. `sdc_setprot_bad` and `sdc_unmap_bad` stay 0 — the pair-equality premise is unrelated to this.

If 2 is wrong and every plane is clean, the alignment argument above is wrong and must be
re-derived before any patch is written.

### Measured 2026-08-27 on `68060-260827-06` — prediction 1 ✅, prediction 2 ✅

**1. The mapping now succeeds, and is writable, for every geometry.** `scrprobe pokeall`:

```
mode                     geometry         plane  pages  writable?
lores  non-lace          320x256 x5       10240   2.50  YES
lores  interlaced        320x512 x5       20480   5.0   YES
hires  non-lace          640x256 x4       20480   5.0   YES
hires  interlaced        640x512 x4       40960  10.0   YES
lores  HAM               320x256 x6       10240   2.50  YES
lores  HalfBrite         320x256 x6       10240   2.50  YES
no constraints at all    320x256 x5       10240   2.50  YES
overscan lores           320x256 x5       10240   2.50  YES
overscan hires lace      640x512 x4       40960  10.0   YES
```

**Nine of nine, including all four 2.50-page geometries.** The three `NO`s the 2026-08-26
stock-030 reference recorded for exactly the fractional-page modes are gone, which is the
change the reproducer was written to detect. The `ENXIO`/`SIGBUS` blocker is genuinely closed
by the bridge.

**2. And the plane base really is 2 KiB aligned, so the mapping is displaced.** Both halves
were read out of the artifact and the running machine rather than inferred:

* **`AllocMem`'s `MEMF_PAGEB` path aligns to 2048 in this binary.** At `0x73d8`
  `addil #2079,%d0` (`nbytes + PAGESIZE` folded with the `btoC` rounding, 2048 + 31), at
  `0x73f2` `addil #2047,%d4` and at `0x73fc` `andiw #-2048,%fp@(-2)`. `PAGESIZE` is still
  `0x800` and this is where it reaches the allocation.
* **`scrmmap` really returns 4 KiB page frames.** Disassembled at `0x82f8`, which also
  confirms every struct offset used below: `mulsl #460` (`sizeof(struct scrdev)`),
  bitmap array at struct `+12` with `44`-byte entries, `flags` at `+0`, `width` `+2`,
  `height` `+4`, `depth` `+6`, `bpl[]` at `+12`, `oriw #2` setting `Bf_MAPPED`, and the
  final `lsrl #12`.
* **A plane that `scrmmap` actually mapped this boot sits at `0x00013800`.** Read from
  `scrdev[0].bitmap[0]` at runtime `0x08110A38` (`.bss` base `0x0810F58C`, validated first
  against `a3091_device`, which read `0x00dd0000` — the SDMAC). `flags = 0x0003`
  (`Bf_ACTIVE|Bf_MAPPED`), `640x512x1`, `bpl[0] = 0x00013800`.

`0x13800 mod 4096 = 2048`, so `phystopfn(0x13800) = 0x13` and that frame **starts at
`0x13000`, 2048 bytes before the plane**. Every byte the user sees through that mapping is
2048 bytes early.

**3. The pair-equality premise held, on the half that ran.** `sdc_unmap_n = 92` with
`sdc_unmap_bad = 0` — ninety-two segdev unmaps, none on a sub-page boundary. But
`sdc_setprot_n = 0`, so `sdc_setprot_bad = 0` says **nothing at all** on this run: it is the
denominator-of-zero case that `segdevprot` exists to drive. Prediction 3 is therefore half
measured and half unexercised, and the unexercised half must not be reported as clean.

**What is not established:** which client that `640x512x1` bitmap belongs to. It did not
change across two `pokeall` runs, so it is not the probe's, and `scrdev[1]`/`scrdev[2]` are
empty. It is mapped and it is misaligned, which is what the finding needs; whose it is, is
not known and is not claimed.

### The remaining unit, in this project's idiom

Four byte patches, all in the kernel this port already patches:

| site | change |
|---|---|
| `AllocMem` `0x73d8` | `#2079` → `#4127` (`nbytes + 4096`, same `+31` rounding) |
| `AllocMem` `0x73f2` | `#2047` → `#4095` |
| `AllocMem` `0x73fc` | `andiw #-2048` → `#-4096` (still a low-word mask; `0xf000` clears bits 11..0) |
| `allocbmap` / `freebmap` / `scrmmap` | round `width*height/8` up to a **literal 4096** — all three or none, or the chip map corrupts |

`allocbmap` already `bzero`s what it allocates, so the "zeroed" half of the requirement is
free. `MEMF_PAGEB` has exactly one caller, `allocbmap`, so widening the alignment reaches
nothing else.

### Written and emulator-verified 2026-08-27 — `68040/68060-260827-11`

`src/scrdevfix040.s` + `src/patch_scrdev_pageb.py`. Record:
[`test-tools/issue49-scrdev-emu-verify-260827.txt`](test-tools/issue49-scrdev-emu-verify-260827.txt).

**The table above was wrong in one place, and reading the whole path caught it.** There are
**four** `PAGESIZE` literals in the `MEMF_PAGEB` path, not three. The fourth is not in the
alignment arithmetic but in the **tail-slack free**, `btoC(PAGESIZE - (p1-p0))`, compiled at
`0x7438` as `movel #2079,%d0; subl %d2,%d0; lsrl #5`. Widening the first three and leaving that
one would have freed 2048 bytes that were never allocated — a silent chip-map corruption, and
the byte patch would have reported four green `[ok]` lines while doing it.

The rounding could **not** be done in place: the compiler left eight bytes where twelve are
needed, and the size is computed inside `allocbmap`, so a wrapper has nothing to intercept.
Both bodies are therefore reproduced in assembly with the rounding added and nothing else
changed, reached by retargeting their single call-site relocation each (`allocbmap` `0x7e74`
in `srvioc`, `freebmap` `0x7956` in `scrclose`) — the `patch_a3091_badhardware.py` mechanism,
no weakening.

`scrmmap`'s bound is deliberately untouched: segdev probes `d_mmap` on page-aligned offsets
only, and the last such offset for a mapping of `len` bytes is `roundup(len,4096)-4096`, which
is always below the unrounded size.

**The before/after is on one object.** The console's own 640x512x1 bitmap — the same one
measured at `0x00013800` on hardware under `-06` — now allocates at `0x00014000`. That also
settles whose bitmap it was: the console's, through the scrdev ioctl at boot, not the probe's.

**And the accounting closes.** After `pokeall` allocated and freed nine screens:
`scrfix_bytes_free` = **843 776**, which is the sum of `roundup(w*h/8,4096) * depth` over the
nine modes. Without the rounding it would be 788 480. So the measured total can only be
produced by the rounding running *and* by `allocbmap` and `freebmap` rounding identically —
`bytes_alloc - bytes_free` is exactly 40 960, the one console plane that is never freed.
`scrfix_misalign_n` and `scrfix_allocfail_n` are both 0.

### Silicon, 2026-08-27 — `68060-260827-11`

[`docs/REALHW-ISSUE49-260827-11.md`](docs/REALHW-ISSUE49-260827-11.md). 35/35 magics, battery
**12/12 `BATTERY-RESULT PASS`**, `pokeall` 9/9 unchanged, `scrfix_misalign_n = 0`, and the byte
accounting closes to exactly the one console plane — **the same figures the emulator produced**,
which is worth saying because so little here survives that comparison. The unit touches no
cache, no DMA and no FP, so for once the emulator was a fair test.

**The same object moved:** the console's own 640x512x1 bitmap was at `0x00013800` under `-06`
and allocates at `0x00014000` under `-11`, both read from `scrdev[0].bitmap[0]` on this machine.

**Still open:** whether Deluxe Paint draws where it means to. That needs the application driven
against a display; this shows the plane is aligned, page-rounded, zeroed and accounted, not that
the picture is right.

**Two things that looked like failures and were not**, both recorded in the acceptance document:
the battery's first run reported `FAIL (12 missing)` because its verdict greps a hardcoded
`/tmp/battery.log` while the run had been redirected elsewhere and the reboot had wiped `/tmp`
— every test had actually passed. The driver now takes the path as `$1` and **aborts if the file
does not exist**. And one `krnxflt FAILEXIT w=2 va=434D4642` console line, whose own counters
(`Lkx_fn = 1`, every must-stay-zero at 0) are clean; `434D4642` is ASCII `CMFB`, a magic word
used as an address. Which test produced it, and whether `-06` did too, is **not known** — the
`Lkx_*` counters are file-local with no magic word, so no battery dump has ever shown them.
Second block found invisible for that reason today, after `dma_*`.

### Handoff

Owned by this project, not by the Deluxe Paint port: the analysis below is read from
`svr4-src-3b2` and wants confirming against this image's disassembly, which is the skill
and the material that live here.

What the Deluxe Paint port supplies and will keep maintaining:

- **The reproducer.** `dpaint-amix/probe/scrprobe.c`, cross-compiled, self-terminating,
  subcommands `info` / `modes` / `pokeall` / `splitmap`. `pokeall` prints a writability
  matrix with a page count per mode, so a fix shows up as three `NO`s becoming `YES`.
- **A stock 68030 reference machine**, `dpaint-amix/tools/emu-dpaint.sh`, for diffing
  behaviour against a real 2 KiB kernel.
- **Verification on request** — measurements on either kernel, before and after any patch.

Open questions, with the one that decides the driver-side route marked:
`dpaint-amix/docs/ISSUE-49-REVIEW-BRIEF.md`. Question 3 — whether anything besides
`allocbmap`/`freebmap`/`scrmmap` derives plane size or inter-plane contiguity — gates
whether the cheap fix is available at all, and it is answerable by reading
`sys/amiga/console/` out of `amix-sources.tar`.

Note for whoever picks this up: the `STATUS.md` §4 ledger table stops at issue 45, so
ISSUE-46 and everything above it — this one included — has no row there, despite the
header above pointing at §4 as canonical. Not touched from here; flagged because a
handoff that relies on the ledger would miss this entirely.

**A clean 2 KiB reference platform now exists** for this class:
`dpaint-amix/tools/emu-dpaint.sh` boots stock AMIX on a stock 68030 (own image, own
config, serial 1236 / telnet 2325 / tftp 1072, contends with nothing here). Device-mmap
behaviour can be diffed against it, which `devmaptest` alone cannot do.

---

## ✅ ISSUE-100 (2026-08-20, FIXED THE SAME DAY): the panic path destroys its own diagnosis — `sync()` walks the vfs switch through a NULL pointer

> **Ledger: FIXED, and CONFIRMED ON HARDWARE 2026-08-20** (same day). Not yet reflected
> in [`STATUS.md`](STATUS.md). The hardware evidence is at the end of this entry; the
> static acceptance that preceded it is kept as written, because the prediction it made
> is what the run tested.

**Not a 68040 defect.** It is in generic vfs code and it is available to any AMIX kernel on
any CPU. It surfaced on the 040 line only because that is where a panic happened early enough
to hit it.

### Symptom

A 68040 kernel booting on an accelerator card with its own RAM at `0x08000000` reached VM
init and printed

```
PANIC: page_free
DOUBLE PANIC ... vector=0x3
```

The second panic replaced the first one's diagnosis. Every hour spent on the address error,
the Kickstart ROM and `ExecBase` was spent on the *second* panic; the bug is whatever caused
the first one, and the second one is what stopped anybody reading it.

### Mechanism, from this repository's own stock image

Every address is `.text`-relative in the 2.1c image this port patches, taken from its
disassembly or its relocation records.

1. `panic` (`0x3eb58`) is a two-line wrapper on `xcmn_err(CE_PANIC, ...)`; `xcmn_err` prints
   and calls `xpanic` (`0x3e668`, a file-local `t`).
2. `xpanic` runs `backtrace`, `clkreld`, stores `panicstr`, calls `sysdump` — and then, at
   relocation **`0x3e6a2 R_68K_32 sync`**, calls `sync()`, ahead of `mtcrchk`, `call_demon`
   and `rtnfirm` (the orderly return to firmware). So a filesystem flush sits in the middle
   of the panic path.
3. `sync` (`0x5d21a`) is `for (i = 1; i < nfstype; i++) (*vfssw[i].vsw_vfsops->vfs_sync)(0, 0,
   u.u_procp->p_cred);` — `moveal %a2@(8,%d0:l),%a0` (`vsw_vfsops`, +8 of a 16-byte
   `struct vfssw`) then `moveal %a0@(16),%a0` (`vfs_sync`, the fifth pointer of
   `struct vfsops`) then `jsr %a0@`. **Neither pointer is checked.** Offsets confirmed against
   `<sys/vfs.h>`.
4. `vsw_vfsops` is filled in at runtime. `vfsinit` (`0x5dab2`) sets row 0 to `vfs_strayops` and
   then calls each row's `vsw_init`. The `.data` relocations of `vfssw` (`.data+0x913c`, 12
   rows × 16 = `0xc0` bytes, `nfstype` = 12 at `.data+0x91fc`) show only row 0 with a link-time
   `vsw_vfsops` (`0x9144 R_68K_32 vfs_strayops`); rows 1–11 carry `vsw_name` and `vsw_init`
   relocations and nothing at +8. **`sync()`'s loop starts at row 1**, so before `vfsinit()`
   the very first iteration dereferences NULL.
5. `NULL+16` is absolute address `0x10` = **CPU exception vector 4** in the vector table
   AmigaOS leaves in low memory. The "`vfs_sync`" the kernel then calls is an exec ROM trap
   stub; it walks `ExecBase` (absolute 4, which AMIX repoints at its own pseudo-ExecBase) to
   `ThisTask->tc_TrapCode`, finds a sentinel, and returns to an odd address — address error,
   vector 3, into the kernel's own handler, which panics again.

Steps 2–5 are kernel code plus the Kickstart ROM. Nothing in them depends on the accelerator,
the emulator or the memory map, which is why a bench that never panics this early never sees
it: the divergence is entirely in *what panicked*, not in what the panic path then does.

### Fix

`src/syncguard.s` — a whole-routine override (`--weaken-symbol sync` in `relink-040.sh`)
carrying the stock loop instruction-for-instruction plus two null checks: skip the row if
`vsw_vfsops` is NULL, skip it if `vfs_sync` is NULL. Skipping is not a loss of function — a
filesystem whose switch row is empty has not been initialised and has nothing to flush.

One deliberate reordering: stock pushes the three arguments and *then* loads `vfs_sync`; the
override loads `vfs_sync` first, so a null one can be skipped without unwinding three pushes.
The loads and the pushes do not alias, so the order between them is not observable.

The unit carries a `syncg` counter block (`syncg_magic` = `"SYNG"`, `syncg_calls`,
`syncg_skip_ops`, `syncg_skip_fn`, `syncg_last_i`). It exists to make the *absence* of a
behaviour change measurable: on a kernel that reaches multiuser, `syncg_calls` climbs
(`fsflush` calls `sync(2)` continuously) while both skip counters stay at zero. A passing boot
would not demonstrate that; two counters that cannot both be true do.

### Acceptance — static and build-time only

* the override's assembled `.text` reproduces the stock routine's 23-instruction opcode sequence
  exactly; the guards, the counters and the reordered `vfs_sync` load are the only additions;
* exactly one strong `sync` in the linked image, off the stock address, with both call sites
  (`xpanic` `0x3e6a2` and `syssync` `0x5d272` — the only two `R_68K_32 sync` references in the
  whole image) rebinding to it. `relink-040.sh` asserts this; `tools/status-facts.sh` carries
  the row, because `ld -r` links a missing override cleanly and the failure would be a kernel
  that looks built and behaves like stock;
* `TOTAL complaints: 0`, `bindings failing: 0`;
* two builds of the tree differ in exactly **one byte**, inside the build-id string.

**Not measured (at the time of writing):** no boot, on any platform, had yet run this code.
`syncg_calls` had never been read. The claim was that the panic path can no longer fault on an
empty switch, argued from the instruction stream rather than from a run. It was tested the same
day — see below.

### Measured on hardware, 2026-08-20 (68040 on an accelerator card, kernel `68040-260820-18`)

The kernel panicked in early VM init exactly as before, and this time the console read:

```
PANIC: page_free
Backtrace: 80F4964:
```

**No `DOUBLE PANIC`, no trap, no vector-3 entry in the firmware exception trace.** The counter
block, read live at its build-specific address, says precisely what happened inside `sync()`:

| counter | value | meaning |
|---|---:|---|
| `syncg_magic` | `SYNG` | the block is the one this build published |
| `syncg_calls` | 1 | `sync()` was entered exactly once — from `xpanic` |
| `syncg_skip_ops` | **11** | **all eleven** rows 1–11 had a NULL `vsw_vfsops` and were skipped |
| `syncg_skip_fn` | 0 | no row had ops but a NULL `vfs_sync` |
| `syncg_last_i` | 11 | the last row skipped, i.e. the loop ran to `nfstype`-1 |

`syncg_skip_ops` = 11 with `nfstype` = 12 is the whole prediction, confirmed to the count: every
row the loop visits was empty, the guard skipped every one of them, and `sync()` returned instead
of calling through NULL. The static reading of the `vfssw` relocations — only row 0 populated at
link time — is now a measurement.

Two things that had never been observed before this boot: the panic path ran to completion, and
the panic message survived long enough to be read and acted on. The `page_free` panic it exposed
is ISSUE-102.

**One defect this uncovered, not fixed here:** the kernel's own backtrace printer emitted a single
frame address (`80F4964:`) and then stalled, so the `Backtrace:` line is a stub. The chain was
recovered by dumping the boot stack and walking the frame pointers by hand. That is a separate
(minor) defect of the panic printer, recorded here so it is not rediscovered as part of ISSUE-102.

### What this unblocks, and one static correction to go with it

With the panic path able to complete, an early panic keeps its own console output and reaches
`rtnfirm` instead of dying in an unrelated second fault.

Worth writing down while the addresses are fresh, because it narrows the *primary* bug and it
was read from the stock image rather than from the machine: **`PANIC: page_free` is not one of
`page_free`'s three assertions.** Those (`0xafa0a`, `0xafa2c`, `0xafa4e`) call `assfail`, which
formats `"assertion failed: %s, file: %s, line: %d"` — `pp >= pages && pp < epages`,
`pp->p_free == 0`, `pp->p_uown == NULL`, all in `vm_page.c` lines 622–624. The observed text is
the bare format string of a **fourth** site, `cmn_err(CE_PANIC, "page_free")` at `0xafb00`,
reached from four tests on the page being freed:

| test | insn | field | offset |
|---|---|---|---|
| `0xafad6` | `tstw %a2@(2)` | `p_keepcnt` | +2 |
| `0xafade` | `tstl %a2@(32)` | `p_mapping` | +32 |
| `0xafae6` | `tstw %a2@(36)` | `p_lckcnt` | +36 |
| `0xafaee` | `tstw %a2@(38)` | `p_cowcnt` | +38 |

i.e. *the page being freed is still held*. The offsets are the measured AMIX layout, confirmed
by three independently named asserts elsewhere in the same file (`pp->p_keepcnt == 0` →
`tstw %a2@(2)` at `0xafde2`; `pp->p_vnode == vp` → `cmpal %a2@(4)` at `0xafc96`;
`pp->p_mapping == NULL` → `tstl %a2@(32)` at `0xb01a2`) and consistent with `<vm/page.h>` once
the bitfield unit is read as two bytes rather than four. **Which of the four is non-zero is
still unmeasured** — that is a runtime fact, and it is exactly what the guard lets the next
boot print alongside the backtrace.

*(Resolved 2026-08-20, the same day, by the boot the guard made readable: the panic is reached
from `memialloc` during `kvm_init`, and the four fields are not state at all — see ISSUE-102.
The four branches converging on one `cmn_err` is why the panic text names no field, and is why
the fix had to bring its own counters.)*

## ⚠ ISSUE-101 (2026-08-20, RECORDED NOT FIXED): `config()`'s memory-sizing fallback is `0x07000000`-shaped and silently wrong at load base `0x08000000`

> **Ledger: OPEN, deliberately not fixed in this pass.** Latent: the path has not been
> observed to run. Recorded now because it is cheap to record and expensive to rediscover,
> and because it fails in a shape that would be mistaken for a different bug entirely.

### What it is

`config()` (`0x18f5c`) seeds `MAINSTORE = end` / `VSIZOFMEM = 0` and then runs a fixpoint over
`bootinfo.memory[]` (16 records of 32 bytes; `start` at +`0x14`, `end` at +`0x18`, base
`bootinfo+0x440`, loop `0x19174`–`0x191ce`): it lowers `MAINSTORE` through any record that
contains it, and extends `VSIZOFMEM` through any record that contains the current top,
repeating while anything changed. That part is base-agnostic and derives the right answer at
either `0x07000000` or `0x08000000`.

Immediately after it there is a fallback, taken **only if `VSIZOFMEM` is still zero** — i.e.
only if `bootinfo.memory[]` yielded nothing usable:

```
191d2:  tstl  VSIZOFMEM / bnew 19210   ; only when nothing was derived
191dc:  movel #0x07000000,%d5          ; hardcoded
191e2:  cmpil #end,%d5 / bccw 19210    ; only if 0x07000000 < end
191ec:  movel #end,%d5
191f2:  andil #0xF7C00000,%d5          ; round down -- this mask CLEARS bit 27
191f8:  movel %d5,MAINSTORE
191fe:  movel #0x08000000,%d5
19204:  subl  MAINSTORE,%d5
1920a:  movel %d5,VSIZOFMEM            ; VSIZOFMEM = 0x08000000 - MAINSTORE
```

It encodes one 1991 assumption: *the kernel lives in the A3000 motherboard-RAM window
`[0x07000000, 0x08000000)`*. The mask `0xF7C00000` keeps bits 31–28 and 26–22 and clears
**bit 27** — the `0x08000000` bit — and the terminus is the literal `0x08000000`.

| kernel load base | `end` | `MAINSTORE = end & 0xF7C00000` | `VSIZOFMEM = 0x08000000 - MAINSTORE` |
|---|---|---|---|
| `0x07000000` (A3000 motherboard RAM) | `0x0710B930` | `0x07000000` ✔ | 16 MiB ✔ |
| **`0x08000000` (an accelerator with its own RAM)** | `0x0810B930` | **`0x00000000`** | **`0x08000000` = 128 MiB** |

At `0x08000000` the fallback declares main memory to be 128 MiB starting at zero and sizes the
page-frame database for `[0, 0x08000000)` — which excludes **every byte of the machine's actual
RAM**. `maxclick = btopr(MAINSTORE) + physmem` then covers a range no real page is in, and the
first page handed to the allocator is outside `[pages, epages)`.

### Why it is worth recording rather than fixing today

The failure it produces is not obviously a memory-map failure. It is
`assertion failed: pp >= pages && pp < epages, file: vm_page.c, line: 622` — a page-allocator
assertion, in a subsystem that has nothing wrong with it. Anybody meeting that on a machine
whose `bootinfo.memory[]` happened to arrive empty would start in the page allocator and stay
there.

**Inference, not measurement:** the 68040 boots on an accelerator card at `0x08000000` did *not*
take this path, because the panic they produced is the held-page `cmn_err(CE_PANIC, "page_free")`
at `0xafb00` (ISSUE-100), not the line-622 assertion this would cause. That is an argument from
which panic fired, not a reading of `MAINSTORE`; the fallback's condition (`VSIZOFMEM` still zero
after the fixpoint) has not been observed either way, and `MAINSTORE`/`VSIZOFMEM` have not been
read out of a running kernel on that machine.

### What a fix would have to do

Both constants have to come from the memlist rather than from the 1991 assumption: the round-down
mask must not clear a bit that a legal load base uses, and the terminus must be the top of the
region the kernel was loaded into. The obvious minimal shape — mask with something that preserves
bit 27, and take the terminus from the record `end` already walked — is a `config040.s` job
(`config_orig` is already exposed at `0x18f5c` and the unit already wraps it for the ISSUE-21
cache handoff), so the wiring cost is near zero. It is left undone here deliberately: it changes
the memory sizing of every kernel this port builds, including the 030-based lines that boot from
motherboard RAM today, and that is a change that wants its own A/B rather than a ride-along.

## ✅ ISSUE-102 (2026-08-20): `PANIC: page_free` at boot — the page-frame database is mapped-in DRAM and **nothing zeroes it**

> **Ledger: FIXED in the port tree, NOT YET CONFIRMED ON HARDWARE.** The diagnosis is static
> and complete; the fix ships its own falsifier (`pgz_held_n`) and the next boot either proves
> or refutes it. Not yet reflected in [`STATUS.md`](STATUS.md).

**Not a 68040 defect either.** Like ISSUE-100 this is generic SVR4 VM code, and like ISSUE-100 the
040 lane is simply where it finally got hit.

### How it was found

The first 68040 boot on an accelerator card whose panic path survived (ISSUE-100) printed
`PANIC: page_free` and nothing else useful — the kernel's own backtrace printer stalls after one
frame. The boot stack was dumped live and the frame chain walked by hand; symbolised against the
booted image (`68040-260820-18`, load base `0x08000000`) it reads:

| frame | return address | symbol |
|---|---|---|
| `080F49A0` | `080AFB06` | `page_free+0x11c` — immediately after the `cmn_err` at `.text+0xafb00` |
| `080F49BC` | `08052930` | **`memialloc+0x94`** — the caller of `page_free` |
| `080F49D8` | `08048EBC` | `kvm_init+0x28e` |
| `080F4A30` | `08048B78` | `mlsetup+0xb0` |
| `080F4A60` | `080D75D8` | `Lps_nopcr+0x2a` (`pstart040`, just after the MMU is enabled) |
| `080F4AB0` | `08000030` | `stext+0x30` |

Three of the frame arguments pin the state exactly, and they agree with the code: `0x8198` (the
first free click), `0x9000` (`maxclick`) and `0x0E68` (`maxmem` = 3688 pages = `maxclick` − first
free click). So this is boot-time VM setup, handing the page allocator its initial free memory.

### The mechanism, from the stock image

```c
kvm_init():                                    /* .text+0x48c2e */
    va = sptalloc(npages, 1, first_free_click, 0);   /* .text+0xa8bb6 */
    page_hash = va + 60 * npages_estimate;
    hat_init();
    maxmem = maxclick - first_free_click;
    page_init(va, maxmem, first_free_click);         /* .text+0xaf42a */
    memialloc(first_free_click, maxclick);           /* .text+0x5289c */
```

* **`sptalloc` with a NON-ZERO third argument does not allocate.** It branches to
  `segkmem_mapin` (the zero case goes to `segkmem_alloc`), i.e. it maps the physical memory that
  is *already* at that click into kernel virtual space. Nothing is allocated and nothing is
  cleared. The page-frame database is a window onto raw DRAM.
* **`page_init` does not initialise the structs.** Its only write to the array is
  `orib #-128,%a0@` per 60-byte struct — it ORs `p_lock` into byte 0 and touches nothing else.
  It sets `pages`, `epages`, `pages_base`, `pages_end`, `max_page_get`, checks that
  `page_hash`/`page_hashsz` are non-zero, and returns. **It never zeroes the structs and never
  zeroes the hash buckets.** Both are *assumed* to arrive zero.
* **`memialloc` then frees every one of them**: `page_free(pp, 1)` in 60-byte steps across
  exactly the range `page_init` published.
* **`page_free` refuses to free a held page**: `p_keepcnt` (+2), `p_mapping` (+32),
  `p_lckcnt` (+36) and `p_cowcnt` (+38) must all be zero. All four branches converge on the same
  `cmn_err(CE_PANIC, "page_free")` at `.text+0xafb00`, which is why the panic text names no field.

At this point in boot **nothing has ever mapped, locked or held a managed page** — `hat_init()`
has only just returned and no page has been handed out. A non-zero value in those four fields
therefore cannot be state. It can only be what the DRAM already contained. The assertion is
correct and is doing its job; the missing precondition is what is wrong.

### Why the bench never sees it

The emulator hands out zero-filled RAM, so "sptalloc'd physical memory is zero" is always true
there. On metal the kernel is loaded by a program running under AmigaOS, out of the same Fast RAM
pool AmigaOS allocates from, and the database lands about 1.4 MB above the load base — in memory
AmigaOS was recently using. This is precisely the failure class `AGENTS.md` warns about: an
untested path in the emulator is indistinguishable from a passing one.

**Open question, deliberately not answered here:** the 68030 kernel runs on the same card, with
the same AmigaOS-dirty DRAM, through this same generic code, and does not panic. Whether it
escapes because its database lands somewhere AmigaOS happened to leave clean, or for some other
reason, is **not determined**. It matters only for understanding the history — the fix does not
depend on the answer, and zeroing memory that the code already requires to be zero cannot make
the 030 line worse. (Anyone re-opening the intermittent early-boot failures recorded under
ISSUE-21 may want this entry in view; that is a suggestion for a re-check, not a claim, and
ISSUE-21 has its own measured root cause.)

### Fix

`src/pageinitzero.s` — a wrapper on `page_init` (`--weaken-symbol page_init` plus
`--add-symbol page_init_orig=.text:0xaf42a`) that zeroes `60 * npages` bytes at the array and the
`page_hashsz` 4-byte buckets at `page_hash`, then tail-jumps to the stock body with the stack
untouched. **The bounds are `page_init`'s own arguments** — the same two values the stock body
turns into `pages` and `epages = pages + 60*npages` — so there is no second opinion about how big
the array is and no way for the two to drift apart. `page_init` has exactly one reference in the
whole image (`kvm_init` at `0x48eaa`), which is also the entire blast radius.

The hash is included because it is in the same `sptalloc`'d window and equally raw: a garbage
bucket is a wild pointer that `page_find` would follow later. That half is reasoning, not a
measured failure, and `pgz_hash_n` is there to turn it into one.

### The fix carries its own falsifier

`pageinitzero.s` reads every struct **before** it clears it:

| counter | what a boot proves with it |
|---|---|
| `pgz_dirty_n` | structs with any non-zero byte |
| `pgz_held_n` | structs `page_free` would have **refused** — i.e. the panic, counted |
| `pgz_first_i`, `pgz_first_w0`, `pgz_first_map`, `pgz_first_lc` | the first such struct and its three field words, exactly as the DRAM held them |
| `pgz_hash_n` | non-zero hash buckets, over `pgz_hashsz` of them |

**Written down before the run:** on the card `pgz_held_n` > 0 and `pgz_first_*` names a page; on
the bench every counter except `pgz_calls`, `pgz_npages` and `pgz_hashsz` reads 0. A boot that
comes up with `pgz_held_n == 0` **refutes this entry** — the boot would then have been fixed for
some other reason, and finding out which is worth more than the fix.

### Acceptance so far — static and build-time only

`TOTAL complaints: 0`; `bindings failing: 0` with the new row
`| page_init | af42a | 000db6ac | page_init_orig=000af42a | ok |`; `pgz_magic` reads `PGZ!` out of
the artifact. The zero loop and the scan loop cover the same 15 longs (60 bytes) per struct that
`memialloc` steps over. **No boot has run this code.**

## ✅ ISSUE-103 (2026-08-20, CLOSED 2026-08-21 — a symptom record, not a defect of this port): `PANIC: segmap_unlock` at first root-mount I/O

> **Ledger: CLOSED 2026-08-21 — symptom record, no kernel change.** The defect was in the
> accelerator card's 68040 emulation core, which ran bitfield operations through the 68030
> accessors, and it was fixed there; validated on metal the same day. The resolution is at the
> end of this entry, and the platform it belongs to is described in
> [`docs/PLATFORM-Z3660.md`](docs/PLATFORM-Z3660.md). The note below stood while the entry was
> open and is kept as it was written:
>
> > **Ledger: OPEN.** The statics below are settled and are not worth re-deriving; what remains
> > is runtime state, and the build carries an instrument that answers it in one boot. Not yet
> > reflected in [`STATUS.md`](STATUS.md).

### Symptom

With ISSUE-100 and ISSUE-102 in, the 68040 kernel on the accelerator card boots past console init
and dies ~10 s after MMU-on — where root-mount I/O begins. Recovered verbatim from the dead
kernel's `putbuf` ring through the firmware debug console:

```
PANIC: segmap_unlock
4.0 2.1c 0800430 Backtrace:
40001DF4: 803E66C->80595
```

The version banner is in the ring, so the console `printf` path is alive; `0x0803E66C` is
`xpanic`. The guest then warm-reboots cleanly — the ISSUE-100 guard doing its job — which is what
makes the ring readable in the reset window at all. (The truncated `Backtrace:` is ISSUE-104, not
this.)

### What segmap_unlock actually asserts

`segmap_unlock` (`.text+0xa8fec`) is the **F_SOFTUNLOCK** arm of `segmap_fault` — `type == 3`,
dispatched at `0xa9170` — i.e. the release half of a softlock/softunlock pair. For each 4 KiB
page in `[addr, addr+len)` it looks the page up in the page hash by `(vp, off)` and then panics —
`cmn_err(CE_PANIC, "segmap_unlock")` — when any one of three conditions holds: the page-hash lookup
returned no page (`pp` is `NULL`), or the page is still being paged in (`p_pagein` set), or the page
is on a free list (`p_free` set).

`btst #0` is `p_pagein`, `btst #5` is `p_free` — the byte-0 bitfield layout ISSUE-102 pinned. **All
three guards branch to the same `cmn_err` at `0xa907e`**, so the panic text cannot name the
condition. Exactly ISSUE-102's problem, and the reason this entry ships an instrument instead of
another reading of the disassembly.

### Settled statically — do not re-ask these

* **Not an ISSUE-102 repeat.** `segmap_create` (`0xa8ea8`) takes both the segmap data and the whole
  smap array from **`kmem_zalloc`**. segmap's own memory arrives zeroed; the dirty-DRAM story does
  not apply here.
* **The page-hash shift is uniform.** `page_find`, `page_exists`, `page_hashin`, `page_hashout`
  and `segmap_unlock`'s inlined copy all use `>>11`. Insert and lookup agree, so the hash is
  self-consistent; `>>11` under 4 KiB pages only halves the effective bucket count, which costs
  distribution, not correctness. `src/detect_pagesize.py` lists `segmap_unlock@a901e` among its
  deliberate exclusions for this reason, and that decision is **confirmed correct**. The
  `moveq #12` in `page_hashout` (`0xb043c`) is the `p_hash` **field offset**, not a shift — the
  "a page-size constant is not always a page size" trap, caught.
* **The geometry is converted.** `segmap_unlock` steps 4096 per page (`0xa90f4`), `as_fault`
  rounds to 4096 (`0xae156`, `0xae164`), slots are MAXBSIZE 8192 (`&0x1FFF`, `>>13`), and the two
  halves are symmetric about `p_keepcnt`: the F_SOFTLOCK arm keeps `getpage`'s hold, and
  `segmap_unlock`'s `subqw #1,%a2@(2)` releases it.

So the geometry is right and the memory is initialised. What is left is that **at softunlock time
the page is not where the softlock left it** — a fact about the running machine.

### Instrument

`src/segmapdbg.s` + `src/patch_segmapdbg.py` retarget the single `cmn_err` relocation at
`0xa9080` to `smu_panic_latch` — the one-relocation idiom `patch_sdtfail.py` already uses. The
island saves every register, latches, restores, and tail-jumps into the real `cmn_err`, so the
panic prints unchanged. **Blast radius on a healthy kernel is zero**: the only path that reaches
it was already calling `cmn_err(CE_PANIC)` on the next instruction. Verified surgical — exactly
one relocation moved, the other 531 `cmn_err` call sites untouched.

At the `jsr`, `segmap_unlock`'s registers are still live, so the state is read rather than
reconstructed: `a2` = pp (or NULL), `a3` = smp, `a4` = seg, `d2` = the failing page address,
`d3` = the offset looked up, `d4` = the `addr` argument, `d5` = rw, `d6` = len.

**The discriminator** is what the unit is for: after latching it walks the *whole* page hash for
`(vp, off)`.

| `smu_scan` | means |
|---|---|
| 1 | the page **is** in the cache, in bucket `smu_bucket`, while `segmap_unlock` looked in `smu_want`. Differ → the bucket arithmetic disagrees between insert and lookup. Equal → the chain was mutated concurrently, i.e. a locking defect |
| 0 | the page is genuinely **not** in the cache — freed, hashed out, or never entered; `smu_why` then separates the three guards |
| 2 | the scan hit its own safety budget and proves nothing |

The scan is bounded per-chain (1024) and in total (100000) because it runs inside a panic on a
machine whose page structures are already suspect, and an unbounded walk through a corrupt chain
is precisely how ISSUE-100 turned a panic into a dead machine.

### Predictions, registered before the run

* `smu_n == 1` and `smu_addr == smu_addr0` — it fails on the **first** page of the run. If
  `smu_addr > smu_addr0` the failure is position-dependent and the run length matters, which is a
  different bug.
* `smu_why == 4` (pp NULL) or `2` (p_free). A `1` (p_pagein) would mean a page still being read in
  under a softlock, which should be impossible.
* `smu_scan == 0`. **If it comes back 1, this entry is wrong about the cause** and the hash bucket
  arithmetic is where to look next.
* `smu_vp != 0` and `smu_smoff` a plausible file offset. A zero or wild `vp` means the smap slot
  itself was recycled under the softlock — a third story, which would move the investigation to
  `segmap_getmap`/`segmap_release`.

**Nothing here is measured yet.** The build has not been booted.

### MEASURED on hardware 2026-08-21 — the latch fired, and it refutes two of my four predictions

Kernel `68040-260821-02`, death ~22 s post-MMU, block read post-mortem from the reset window.

| | | |
|---|---|---|
| `smu_n` | 1 | ✓ predicted |
| `smu_addr` == `smu_addr0` | `0x40440000` | ✓ predicted — the **first** page of the run, and `0x40440000` is the base of `kvsegmap`, i.e. segmap slot 0 |
| `smu_off` == `smu_smoff` == `smu_poff` | 0 | offset 0 of the vnode |
| `smu_len` / `smu_rw` | `0x1000` / 0 | exactly one page |
| `smu_why` | **3** | ✗ **predicted 4 or 2** — got `1|2` = **p_pagein AND p_free together** |
| `smu_scan` | **1** | ✗ **predicted 0** — the page IS in the hash |
| `smu_bucket` == `smu_want` | 556 | same bucket |
| `smu_scanpp` == `smu_pp` | `0x40073E28` | the same page |
| `smu_vp` == `smu_pvnode` | `0x40078B04` | identity intact |
| `smu_hashsz` | 1024 | |
| `smu_pflags` | `0x33000002` | byte0 `0x33` = **p_free, p_intrans, p_ref, p_pagein**; `p_keepcnt = 2` |

`smu_pp - 0x40040000 = 0x33E28 = 212520`, and `212520 / 60 = 3542` **exactly** — so `pages[]` is at
`0x40040000` and this is page index 3542 of 3688, click `0x8F6E`. The array length `60 * 0xE68 =
0x36060` is the same `0x00036060` that appeared in ISSUE-102's stack frames. Three independent
numbers agreeing is what says the decode is right.

**Correction to this entry's own instrument.** The `smu_scan` interpretation table above was
written for the `pp == NULL` case and is wrong as stated for this one: with `pp != NULL` the scan
re-finding the same page in the same bucket proves nothing about locking — it simply confirms the
hash is healthy and the page is exactly where it should be. The table should have said so. What
the scan *did* establish is worth keeping: **the page hash is not the problem**, which was the
hypothesis most worth killing.

### The verdict

Not wrong-bucket, not concurrent mutation, not not-in-cache. The page is precisely where it
belongs, with the right identity, and **its flag state is the defect**: it is simultaneously
marked as on a free list (`p_free`) and as a pagein in flight (`p_intrans | p_pagein`), while held
twice (`p_keepcnt = 2`). `p_ref = 1` and `p_keepcnt` rising from 1 to 2 are exactly what
`page_get` + a softlock hold produce, so everything about this page is normal **except `p_free`**.

### What that single bit rules out, statically

* **`page_get` never ran on it.** Its per-frame re-init at `0xb023c`–`0xb0278` is the compiled
  form of `p_age = p_nc = p_mod = p_free = 0; p_pagein = p_intrans = p_lock = 0; p_ref = 1;
  p_keepcnt = 1` — a `bfextu`/`bfins` cascade that **clears `p_free` at `0xb025c`**. Any page
  through it is clean.
* **`page_unfree` never ran on it** — the reclaim path (`0xaff3c`–`0xaff4c`) clears `p_free` by
  the same idiom, and it is what `page_reclaim` (called from `page_lookup` at `0xaf85c`) uses.
* **`free_vp_pages` did not put it there.** Before setting `p_free` (`orib #32` at `0xafe04`) it
  asserts `p_free == 0` (line 753), `p_intrans == 0` (754) and `p_keepcnt == 0` (755). This page
  violates all three, so it would have `assfail`ed three times over first.
* **`page_abort` did not do it** — it asserts `p_free == 0` on entry (line 550) and returns early
  if `p_keepcnt != 0` or `p_intrans` is set.
* **The copyback release patch is not implicated.** `patch_cb_release.py` hook 2 rewrites
  `addql #1,freemem` → `jsr cb_vpfree_enter` at `0xafd98`; the next instruction is `btst #5,%a2@`,
  which sets its own condition codes, so the classic "a `jsr` where an `addql` set the CCR" trap
  does not apply here. Checked because it is exactly the trap this repository documents.

So `p_free` was set by `page_free` (`0xafb3a`, the only remaining setter, and its ISSUE-102 guard
means `p_keepcnt` was 0 at that moment), and then **the page was taken for a pagein without ever
being reclaimed** — neither `page_get`'s cascade nor `page_unfree` cleared the bit.

### Stage 2, and what it decides

The remaining question is which list the page is actually linked into, and it splits three ways.
The island now walks both (`p_next` +16 / `p_prev` +20, circular, both budgeted):

| outcome | meaning |
|---|---|
| `smu_oncache = 1` | it is on `page_cachelist` — a cache-list page taken for a pagein without `page_reclaim`. The acquirer is the bug |
| `smu_onfree = 1` | worse: a genuinely free page is being paged into, i.e. the free list handed out a page that is still linked |
| both 0 | **`p_free` is a stale bit** — the page was properly unlinked but the flag was never cleared, and the bug is one specific missing clear |

`smu_cachesz`/`smu_freemem` and the two walk counts are latched alongside so a truncated or
looping walk is visible rather than silently reported as "not found".

**Predicted before the run:** `smu_oncache = 1`, `smu_onfree = 0`. If both come back 0, the
"stale bit" reading is right and the search narrows to a single missing `page_unfree`.

### Second metal read 2026-08-21: stage 1 reproduced EXACTLY; stage 2 never ran (my bug)

Kernel `68040-260821-04`. Every stage-1 field latched **identically** to the first run — same
page `0x40073E28` (frame 3542), same `smu_why = 3`, same `addr == addr0 == 0x40440000`, same
`pflags 0x33000002`, same bucket 556. Nothing drifted.

**That reproducibility is itself a finding, and it is worth more than the run that produced it.**
Two boots, on different kernels, with different DRAM garbage underneath (see the `pgz` numbers
below), landed on the *same page frame* at the *same virtual address* with the *same flag word*.
Whatever corrupts this page is **deterministic in address**, not a race and not a function of what
was in memory beforehand. Any root-cause story that requires timing or luck is now excluded.

Stage 2, however, returned all zeros — including both walk counters and `freemem`, which cannot
be zero 22 s into a boot. The instrument did not walk and find nothing; **it never executed**, and
the reason was a defect in this unit, not in the kernel:

```
db75c:  braw db81e <Lsmu_go>      <- the "page found" exit
db81e:  Lsmu_lists == Lsmu_go     <- the same address
```

`Lsmu_lists:` had been written **after** the two list walks instead of before them, so it resolved
to the same address as the exit label. Every path that mattered — including the "found" path this
panic always takes — branched past the walks to the restore-and-tail-jump. Only the
budget-exhausted path fell through into them, and that path never runs. The assembler cannot
object: two labels on one address is legal, and the relink's hard check and the relocation
validator both passed, because symbol binding was never the problem.

Fixed by moving the label ahead of the walks, giving the freelist walk its own forward exit
(`Lsmu_done2` — with the label moved, its old backward branches would have become an infinite
loop inside a panic), and routing the two early exits through the walks as well.

**And the lesson is now built into the unit:** `smu_s2ran` is written `"RAN!"` as the *first*
instruction of the stage-2 block. An instrument whose silence is indistinguishable from a negative
result is decoration — the same lesson ISSUE-44 recorded, re-learned here at the cost of one
hardware run. A future all-zero stage-2 read now means "did not run" only if `smu_s2ran` is also
zero.

**ISSUE-102 confirmed a third time** in the same read: `pgz_held_n` = 1380, after 150 and 1225 on
the two previous boots, and `pgz_hash_n` = 71 after 2. Both counts vary run to run exactly as an
uninitialised-DRAM story predicts, and the boot gets past `kvm_init` every time.

### Third metal read 2026-08-21 — stage 2 answered, and it inverts the hypothesis

`s2ran = "RAN!"` ✓, `oncache = 0`, `onfree = 0`, cache list empty (`cachesz = 0`, walk 0),
freelist walk **3539** == `freemem` **3539** — the walk is internally consistent and the freelist
is coherent at 3539 of 3688 frames. **The page is on neither list**: properly unlinked, correctly
excluded from a healthy freelist, in the hash with the right identity, mid-pagein, held twice —
with `p_free` stale. The third pre-registered outcome, exactly.

That should have made this "find the acquisition path that forgot to clear `p_free`". It is not,
and the audit is what says so.

#### The 040 lane is exonerated for this, by a complete diff rather than by inspection

A byte-for-byte diff of the built kernel against the stock image across `vm_page.c`, `seg_map.c`
and `s5getapage` returns **44 changed runs, and every single one is a 2 KiB→4 KiB constant
conversion** (`07ff`→`0fff`, `0800`→`1000`, `f8`→`f0`, `moveq #11`→`#12`) plus the two documented
`cb_release` hooks (`page_free` `0xafb08`, `free_vp_pages` `0xafd98`). **Nothing in the port
touches the flag code.** `patch_cb_release.py`'s `free_vp_pages` hook was separately cleared last
round (the following instruction is a `btst`, which sets its own condition codes).

#### And the stock flag code is correct — checked structurally, not by reading

* **`page_get`'s cascade is unskippable.** The re-init at `0xb023c`–`0xb0278` (`p_age = p_nc =
  p_mod = p_free = 0; p_pagein = p_intrans = p_lock = 0; p_ref = 1; p_keepcnt = 1`) sits in the
  `dbf` loop, and the highest branch target anywhere in that loop body is `0xb022c` — **below the
  cascade**. Every iteration falls through it. No page leaves `page_get` with `p_free` set.
* **`page_unfree`** (`0xaff3c`) clears `p_free` by the same idiom, and it is what `page_reclaim`
  uses.
* **`page_enter`** (`0xaf87e`) is `page_exists` + `page_hashin` and touches no flags — correctly,
  since its callers acquire through `page_get`. Its twelve call sites include one in the port's
  own `hat_dup040.s`, which was checked: it takes its page from `page_get(4096,0)` first.

#### The reframe

There are exactly **two** instructions in the kernel that set `p_free`: `orib #32,%a2@` in
`page_free` (`0xafb3a`) and in `free_vp_pages` (`0xafe04`). Both are guarded by assertions that
this page violates — `page_free` by the four held-page tests (ISSUE-102), `free_vp_pages` by
`p_free == 0`, `p_intrans == 0`, `p_keepcnt == 0` (lines 753–755). **Had either run on this page
it would have produced a different panic, and it did not.**

So `p_free` was **not left set by a missing clear. It was SET, after the page was legitimately
acquired, by something that is not the page code.** Combined with stage 1 reproducing byte-identically
across four boots — same frame 3542, same VA `0x40440000`, same flag word `0x33000002` — this is a
**deterministic write to a fixed page-struct address** (`0x40073E28`), not a logic error and not a
race. That is a different class of bug from the one this entry started with, and it puts it in the
neighbourhood of the port's ISSUE-10 family (fixed-address poisoning) rather than the VM's.

#### Stage 3: how many pages are in the impossible state

One bounded pass over `pages..epages` counting flag bytes. `smu_freeset_n` should track
`freemem` + cache list; `smu_imposs_n` counts pages that are **both free and in transit**, with
the first one latched.

**Predicted:** `smu_imposs_n == 1` and `smu_imposs_pp == 0x40073E28` — exactly one page, ours,
i.e. a targeted write at a fixed address. `smu_freeset_n` ≈ 3540 (the coherent 3539 plus ours).
**If `smu_imposs_n` is large, the reframe is wrong** and the free-list accounting is systemically
broken, which would send this back to the VM after all.

### Fourth metal read 2026-08-21 — the census fires, and it RETRACTS the previous entry

`s3ran = "CEN!"`, `freeset_n = 3688`, `imposs_n = 2`, `imposs_i = 3541`,
`imposs_pp = 0x40073DEC`, and stage 1 unchanged except `pflags` = **`0xFF000002`** where four
earlier boots read `0x33000002`.

**Census mask audited first, and it is correct.** The shipped encoding is
`moveq #0,%d1 / moveb %a0@,%d1 / btst #5,%d1` — bit 5 of byte 0, the same bit `page_free`'s own
assert tests (`btst #5,%a2@` ↔ `pp->p_free == 0`). `p_lock` is bit **7** and the census does not
read it. So `freeset_n = 3688` is a real measurement, not a repeat of the stage-2 label bug.

#### The three facts reconciled

1. **The adjacency is not a corruption footprint.** A segmap slot is MAXBSIZE = 8192 = exactly
   **two** 4 KiB pages, so frames 3541 and 3542 *are* the 2-page cluster of one `getpage` for slot
   0. Nothing about that pairing needs a writer to explain it. (Correcting the premise as well:
   this island latches the **first** hit — `tstl smu_imposs_pp / bnew` skips once set — so
   `imposs_pp` is 3541, and 3542 is the second.)
2. **`freeset_n = 3688` is the one that matters.** Every struct has `p_free` set, while the
   freelist walk and `freemem` independently agree on 3539. **149 pages are off the free list with
   `p_free` still set.** This page is not special — it is one of 149, and merely the first whose
   `p_free` was ever checked in a fatal position.
3. **`0xFF` is not a page-code value.** `page_free` leaves `0x20`, `page_get`'s cascade leaves
   `0x02`. `0xFF` is every bit set. The address held across five boots; the value did not.

#### Retraction

**The previous section's conclusion — "a deterministic write to a fixed page-struct address" — is
withdrawn.** It was built on stage 1 reproducing at one address, and the census shows the anomaly
is population-wide. The address determinism is nothing more than boot determinism: segmap slot 0
is always the first slot faulted, so it is always the first page where a stale `p_free` can kill.

That reopens the question the previous section thought it had closed, and it reopens it against a
structural proof that `page_get`'s cascade cannot be skipped. Two possibilities remain, and they
are distinguished by measurement, not argument: either those 149 pages never went through
`page_get`, or the cascade's writes are not landing in the page array.

#### Stage 4: measure the population instead of reasoning about it

One counter per flag bit across every struct, plus counts of the two byte-0 values that mean
something — `0x20` (a clean free page, what `page_free` leaves) and `0xFF`.

The cascade clears bits 7, 5, 4, 2 and 0 on every page it hands out, so:

* `smu_bitpop[7]` (**p_lock**) large → the cascade did not take, and the defect is in the write
  path to the page array, not in the page logic;
* `smu_bitpop[7]` ≈ 0 with `bitpop[5]` = 3688 → the cascade ran and something set `p_free` back on
  149 pages afterwards;
* `smu_b0_20` ≈ 3539 with 149 others → the free population is clean and the allocated one is not;
* `smu_b0_ff` large → a fill, and the story is memory corruption after all.

**Deliberately not yet built: the standalone write-watch.** It was the agreed next step while the
target looked like one fixed address. A watch on one address is the wrong instrument for an
anomaly spanning 149 of them, and it would cost a boot to learn that. The histogram costs no new
machinery and narrows the target first; if it comes back "targeted after all", the watch follows
with a much better address to watch.

### Fifth metal read 2026-08-21 — the histogram names the instruction

`bitpop[0..7]` = 3, **149**, 1, 1, 3, **3688**, 1, 1 · `b0_ff` = 1 · `b0_20` = **3539** ·
`imposs_n` = 3 · stage 1 back to `0x33000002`.

**The population reconstructs exactly**, which is what says the reading is sound rather than
plausible:

| byte 0 | count | what it is |
|---|---:|---|
| `0x20` | 3539 | free pages — pristine `page_free` output, `p_free` and nothing else |
| `0x22` | ~146 | **allocated** pages: `p_free` **stale** + `p_ref` set |
| `0x33` | 2 | allocated + in transit (`p_intrans\|p_pagein`) — the segmap slot-0 cluster |
| `0xFF` | 1 | every bit set — the one outlier, unexplained |

3539 + 149 = 3688 exactly, and `bitpop[2]`/`[3]`/`[6]`/`[7]` all reading **1** is the single
`0xFF` struct contributing to each.

#### Only two operations in the cascade are observable, and they disagree

A page arriving from the free list has byte 0 = `0x20`. Against that input, of the six operations
`page_get`'s cascade performs on byte 0:

| bit | field | cascade op | input | observable? | result |
|---:|---|---|---:|---|---|
| 5 | `p_free` | **`bfins {2:1}`** — clear | **1** | **YES** | **landed on 0 of 149** |
| 1 | `p_ref` | **`orib #2`** — set | 0 | **YES** | **landed on 149 of 149** |
| 2 | `p_mod` | `bfins {5:1}` — clear | 0 | no | — |
| 4 | `p_intrans` | `bfins {3:1}` — clear | 0 | no | — |
| 7 | `p_lock` | `bfins {0:1}` — clear | 0 | no | — |
| 0 | `p_pagein` | `andib #-2` — clear | 0 | no | — |

The other four clears act on bits that are already zero, so they prove nothing either way.

#### Refinement: it is not "clears fail", it is "BFINS does not write"

The one failing operation is a **bitfield** instruction; the one succeeding operation is a
**byte** read-modify-write. "Clears vs sets" is not the axis the evidence supports — the only
clear that could be seen is also the only `bfins` that could be seen.

And the direction is pinned too: if `bfins` were writing **1**s (a `bfextu` returning garbage and
feeding the chain), then `p_mod`, `p_intrans` and `p_lock` would each read ≈149. **They read 1, 3,
1.** So `bfins` is not writing ones and not writing zeros — **its write is not landing at all**,
while `ori.b`/`andi.b` to the *same byte* do land.

That is not kernel logic. No sequencing of correct 68040 instructions produces it.

#### The exact sequence one struct's byte 0 undergoes at acquisition

`a2` = the page struct, reached through the **kernel's mapped window** — `pages` = `0x40040000`,
which `kvm_init` obtained via `sptalloc(..., first_free_click, 0)` → `segkmem_mapin`, i.e. physical
DRAM at click ≈`0x815C` mapped into `kvseg`. **MMU translation is active for this address and it is
not covered by any transparent-translation register.** Encodings are from the shipped image:

```
b0254:  efd2 0141   bfins  %d0,%a2@{5:1}     ; p_mod     <- d0   (d0 = 0)
b0258:  e9d2 0141   bfextu %a2@{5:1},%d0     ; d0 <- p_mod
b025c:  efd2 0081   bfins  %d0,%a2@{2:1}     ; p_free    <- d0   *** THE ONE THAT FAILS ***
b0260:  0212 00fe   andib  #-2,%a2@          ; p_pagein  <- 0
b0264:  e9d2 01c1   bfextu %a2@{7:1},%d0     ; d0 <- p_pagein
b0268:  efd2 00c1   bfins  %d0,%a2@{3:1}     ; p_intrans <- d0
b026c:  e9d2 00c1   bfextu %a2@{3:1},%d0     ; d0 <- p_intrans
b0270:  efd2 0001   bfins  %d0,%a2@{0:1}     ; p_lock    <- d0
b0274:  0012 0002   orib   #2,%a2@           ; p_ref     <- 1    *** THIS ONE LANDS ***
b0278:  357c 0001 0002  movew #1,%a2@(2)     ; p_keepcnt <- 1    (lands: keepcnt reads 1→2)
```

Every one of these is a read-modify-write of the **same byte**, at the same address, within nine
instructions of each other. The byte ops take effect and the bitfield ops do not.

### HANDOVER — minimal reproduction for the 68040 emulation core

For whoever owns the accelerator's 68040 core. This needs **no hardware boot**: it is a host-harness
test. AMIX is not required — the sequence is self-contained.

**Claim to test:** `BFINS <Dn>,<mem>{offset:1}` does not take effect when the effective address is
translated through the 68040 MMU (page-table translation, *not* transparent-translation), while
`ORI.B`/`ANDI.B` to the same byte do.

**Setup.** One 4 KiB page mapped through the page tables at a kernel-style address (the failing case
uses `0x40040000`+), MMU on, TC enabled, the mapping **not** covered by ITT0/ITT1/DTT0/DTT1 — the
distinction from a TTR-covered address is the thing most worth varying. Cache mode as the kernel's
`kvseg` uses (copyback) for the primary run.

**Body.** With `a2` pointing at a byte in that page:

```
    moveb  #0x20,%a2@          ; seed: bit 5 set, all others clear
    moveq  #0,%d0
    .word 0xefd2,0x0081        ; bfins %d0,%a2@{2:1}   -- clear bit 5
    ; EXPECT  %a2@ == 0x00
    ; PREDICT %a2@ == 0x20     (the write does not land)
    orib   #2,%a2@             ; control: byte RMW, set bit 1
    ; EXPECT  %a2@ == 0x02
    ; PREDICT %a2@ == 0x22     (matches every allocated page on the card)
```

**Variations that isolate it, in priority order.**

1. the same body at a **TTR-covered / untranslated** address — if it passes there and fails above,
   the defect is in the bitfield path's address translation, not the instruction decode;
2. **caches off** vs copyback — separates "write lost in the cache" from "write never issued";
3. `bfins` with **width > 1**, and a field **crossing a byte boundary** — does any bitfield write
   land?
4. `bfins` to a **data register** destination — expected to pass; if it fails too, the defect is
   decode-wide rather than memory-path;
5. `bfclr`/`bfset`/`bfextu` on memory — `bfextu` reads are believed to work (the cascade's chain
   would otherwise have propagated 1s, and the histogram says it did not), so a passing `bfextu`
   with a failing `bfins` localises it to the write half.

**Why this was never seen before.** The bench emulator implements these instructions; §9's firmware
audit covered MMU enable, the TT registers, `PFLUSH`/`PTEST` and the access-error frame, but the
bitfield-instruction path was never exercised, because nothing before this reached code that uses
`bfins` on MMU-translated memory in anger. It is the same family as the ISSUE-10 write
fabrication — a write that does not land where the instruction says it should.

**Report back:** the observed byte after each step, per variation. If step 1 passes and the primary
fails, that is the answer and the kernel needs no change at all.

**No new kernel build was produced for this round** — the bit map confirmed the reading rather than
refuting it, so `unix-040-minimal-i46-i48-i49e` (`68040-260821-10`) remains the current diagnostic
kernel and is still the right one to boot if another read is wanted.

**If the harness exonerates the core**, the fallback story is the mapped window itself — `p_free`
living in DRAM reached through `segkmem_mapin` — and the next kernel-side instrument is a
read-back-verify wrapper on the cascade rather than a write-watch.

### ✅ RESOLVED 2026-08-21 — it was not a kernel defect

The host-harness handover above was dispatched and the reproduction confirmed it: **the
accelerator's 68040 emulation core mishandled bitfield operations**, executing them through the
030 accessors, so `BFINS` to an MMU-translated address did not take effect while `ORI.B`/`ANDI.B`
to the same byte did. Fixed in the firmware (`6e8e33a`) and **validated on metal 2026-08-21
03:40**: the kernel boots, prints its banner and runs. `PANIC: segmap_unlock` is gone.

**The kernel needed no change.** ISSUE-103 is therefore a **symptom record**, not a defect of this
port — kept in full because the ladder that got here (which guard fired → which list → which
population → which instruction) is the reusable part, and because two of its rounds were wrong in
instructive ways: the "deterministic write to a fixed address" reading, retracted by the census,
and the stage-2 probe that never ran, caught only because the next instrument was made to say
whether it had.

The frontier moved to userland (init's exec fault), which is a different lane.

**Instrument retirement — candidates, not yet retired.** The ISSUE-100 (`syncg`) and ISSUE-102
(`pgz`) counter blocks have each done their job and been confirmed on metal (three times for
ISSUE-102). They are candidates for retirement once the userland case closes. **Do not retire them
yet**: the pinned diagnostic medium still carries them usefully, ISSUE-102's fix itself must stay
regardless (only its counters are optional), and `pgz_held_n` remains the cheapest live proof that
boot memory arrives dirty on this machine.

## ✅ ISSUE-104 (2026-08-20, FIXED 2026-08-21): the panic backtrace stopped after one frame because its frame-pointer window was 64 KiB wide

> **Ledger: FIXED in the port tree 2026-08-21, NOT YET EXERCISED ON HARDWARE** (no panic has
> occurred since it landed). Not yet reflected in [`STATUS.md`](STATUS.md). The diagnosis below is
> unchanged; the fix is at the end.

### It is not a stall

`backtrace` (`.text+0x595a4`) prints each frame **before** it validates it (`printf(LC%4, fp)` at
`0x595fa`–`0x59604`, validity test at `0x5960e`–`0x5962a`). The test is:

```
5960e:  cmpil #0x3FFFFFFF,%fp@(-4) / blsw  -> invalid
5961a:  cmpil #0x4000FFFF,%fp@(-4) / bhiw  -> invalid
59626:  moveq #1,%d0                       -> valid
5962a:  beqw 5979a                         -> stop the walk
```

i.e. a frame pointer is accepted only in **`[0x40000000, 0x4000FFFF]`** — a 64 KiB window at the
u-block base. So the printer emits the address, rejects it, and stops. That is the whole
behaviour, and it explains both observations exactly:

* ISSUE-102's boot printed `Backtrace: 80F4964:` and stopped — `0x080F4964` is the boot stack
  `pstack`, which lives in `.bss` and is nowhere near the window.
* ISSUE-103's boot printed `40001DF4: 803E66C->80595` — that frame **is** in the window, so it
  printed the frame and its return address; the next frame pointer left the window.

The window is too narrow for the kernel's real stacks: AMIX's u-block is `[0x40000000,
0x40040000)` (256 KiB, four times the window), and the boot and interrupt stacks are in the
kernel's own `.bss` entirely outside it.

### Why this is not a two-constant byte patch

**The window is the walk's only terminator.** The loop (`0x5978e`–`0x59796`) simply follows
`*fp` back to the top; there is no frame counter and no monotonicity check. Widening the window
without adding a bound would let a corrupt chain walk forever *inside a panic* — the exact
failure mode ISSUE-100 exists to prevent, reintroduced by the fix meant to help.

### The fix, when it is taken

A whole-routine override of `backtrace` that keeps the existing output format and adds all three
bounds at once: accept the full u-block **and** the kernel's own data/bss range; require the
frame pointer to **increase** each step (stacks grow down, so caller frames are at higher
addresses — this alone kills every cycle); and cap the frame count outright.

Not done in that pass on purpose: it would have put a second, unproven variable into a kernel
whose one job was to diagnose ISSUE-103.

### Fixed 2026-08-21, all three bounds together

`src/btwalk.s` + `src/patch_btwalk.py`. The 26 bytes of the old test (`0x5960e`–`0x59627`) are
replaced by `bsr.l bt_frame_ok` plus ten NOPs; the `tstl %d0 / beqw` at `0x59628` is untouched, so
the island's contract is the old code's exactly — `d0 = 1` continue, `d0 = 0` stop. PC-relative for
the same reason the `cb_release` hook is: a byte-patched absolute target would need loader
rebasing. Verified before writing that **no branch in `backtrace` targets an address inside the
replaced range**, and verified after linking that the displacement still resolves (`bsrl dba34
<bt_frame_ok>`) — the FPSP `ld -r` that follows appends to `$OUT` and leaves our `.text` in place.

| bound | test |
|---|---|
| RANGE | the whole u-block `[0x40000000, 0x40040000)` **or** `[edata, end)`, taken from the loader's own symbols so they cannot drift from the image |
| ORDER | each frame pointer strictly **greater** than the last — stacks grow down, so this alone kills every cycle |
| COUNT | hard cap of 64 frames per walk |

Plus a free one: an **odd** frame pointer is refused, because the next thing the walk does with it
is a longword read.

**Arming needs no second hook.** `backtrace` seeds its first candidate with its own frame pointer
(`0x595f2`), so the first call of every walk is the one where the candidate equals `%a6` — that is
where the counters re-arm, and rule 2 guarantees no later frame can alias it. The island reads
`%a6@(-4)` directly, since `bsr` builds no frame of its own.

Output format, symbol lookup and print order are deliberately unchanged: a frame is still printed
before it is judged, so the frame that *ended* the walk still appears. That address is itself
diagnostic — it is what made this defect findable at all — and `bt_laststop` now latches it.

## ✅ ISSUE-105 (2026-08-21, FIXED THE SAME DAY): `xpanic` decided whether to `sync()` from uninitialised bits

> **Ledger: FIXED in the port tree 2026-08-21, NOT YET EXERCISED ON HARDWARE.** Not yet reflected
> in [`STATUS.md`](STATUS.md). It mattered because it decided how much to trust a post-mortem
> counter, which became a working diagnostic channel for this port during the 040 campaign.

### The observation that forced it

Two panics on the same kernel family, both with ISSUE-100's guarded `sync()` linked in:

* ISSUE-100's boot (`PANIC: page_free`): `syncg_calls = 1`, `syncg_skip_ops = 11` — `sync()` ran
  and skipped all eleven unfilled `vfssw` rows.
* ISSUE-103's boot (`PANIC: segmap_unlock`): **`syncg_calls = 0`** — `sync()` was never entered,
  though the machine warm-rebooted cleanly and the `putbuf` ring was intact.

### Why

`xpanic` (`.text+0x3e668`) gates its `sync()` call like this:

```
3e688:  movew %sr,%d0            ; writes only the LOW word of d0
3e68a:  movew #9216,%sr
3e68e:  movel %d0,%fp@(-4)       ; stores the FULL LONG
3e692:  movew %sr,%d1
3e694:  movew %d0,%sr
3e696:  bftst %fp@(-4),5,3       ; e8ee 0143 fffc -> offset 5, width 3
3e69c:  bnew  3e6a6              ; non-zero -> SKIP sync
3e6a0:  jsr   sync
```

`bftst {5:3}` on a memory operand counts from the MSB of the addressed byte, so it tests bits
26–24 of the stored longword — i.e. bits 10–8 of **d0's high word**. `movew %sr,%d0` never writes
that half. What is in it is whatever the preceding `jsr sysdump` (`0x3e682`) left in `d0`.

**So the panic path's decision to flush filesystems is taken on uninitialised bits**, and the two
boots differ because `sysdump` returned different values.

### Consequences, which is the point of recording it

* **`syncg_calls` is not a reliable indicator that the panic path ran.** A zero means "`sync()`
  was not called this time", not "the panic path failed". For post-mortems the trustworthy signals
  are the `putbuf` ring contents and a clean warm reboot.
* **ISSUE-100's guard is not made redundant by this.** It was simply not exercised on the second
  boot. Had those bits fallen the other way — a coin toss on every early panic — the unguarded
  `sync()` would have walked the NULL `vfssw` and destroyed the ring that produced ISSUE-103's
  entire diagnosis. The guard remains load-bearing precisely because the gate is unpredictable.

### Fixed 2026-08-21 — one instruction, same length

`src/patch_xpanic_sync.py` rewrites the store at `0x3e68e` from `movel %d0,%fp@(-4)` (`2d40 fffc`)
to **`clrl %fp@(-4)`** (`42ae fffc`), so the field `bftst` reads is deterministically zero and the
panic path **always** reaches `sync()`.

Three things make that the safe direction rather than the clever one:

* `%fp@(-4)` is read by nothing else in `xpanic` — the SR restore at `0x3e694` comes from `%d0`,
  the register, which this does not touch;
* always-sync is the intended SVR4 panic semantic (flush filesystems on the way out); skipping
  would silently drop it;
* `sync()` on the panic path is safe at any point in boot **since ISSUE-100** — it skips vfs switch
  rows `vfsinit` has not filled instead of calling through NULL. Landing this without that guard
  would be reckless; with it, it is the behaviour the code always meant to have.

The ordering is worth keeping in view: ISSUE-100 made this fix safe, and this fix makes ISSUE-100's
guard reachable on every panic instead of on a coin toss.

## ✅ ISSUE-106 (2026-08-21, CLOSED 2026-08-21 — a symptom record, not a defect of this port): PID 1 dies at exec with a kernel-shaped user stack pointer

> **Ledger: CLOSED 2026-08-21 — symptom record, no kernel change.** Two defects in the
> accelerator card's 68040 emulation, both fixed there and validated on metal the same day: the
> access-error frame stacked the write-back status words without clearing them, so a stale
> write-back was replayed against the current fault's address; and `mmufixup[1]` was never
> cleared at reset, so the first bus fault of a session zeroed `copyout`'s source register. Both
> are described in [`docs/PLATFORM-Z3660.md`](docs/PLATFORM-Z3660.md) §2. The prediction ladder
> below is kept in full, including the rounds it got wrong — the note as it stood while the entry
> was open:
>
> > **Ledger: OPEN.** With ISSUE-103 closed (an emulation-core defect, not a kernel one) the kernel
> > boots and runs, and the frontier is userland. The statics below are settled; the build carries a
> > latch that decides the rest in one boot. Not yet reflected in [`STATUS.md`](STATUS.md).

### Symptom

```
NOTICE: User BUS ERROR at 40001FC0, PC:80000012 FAULT:6 PID:1 CMD:
```

The kernel survives and handles it correctly — this is a well-formed fault report, not a crash.

### Settled from the image, without a boot

* **`0x40001FC0` is `u + 0x1FC0`** — the exact constant `_start` loads into `%sp`
  (`0x3e R_68K_32 u+0x00001fc0`), i.e. the kernel stack top inside the u-area. Not a random
  address, and not one a user program can legitimately reach.
* **`PC 0x80000012` is init's own text**, so the icode's `trap #0` exec **succeeded** and
  `/bin/init` is mapped and running. The icode itself is intact: `icode+0` is
  `lea %pc@(L%stack),%sp` (`4FFB0170`), `+8` `moveq #11,%d0`, `+10` `trap #0` — the SYS_exec call,
  and `szicode` = 0x36.
* **The user stack lives at `userstack` = 0xC0800000** (`patch_execstk.py`,
  EXEC-INITIALSTK-PATCH-SPEC). A correct USP would be near there, not in the u-block.
* **FAULT:6 = FLTBOUNDS** per the port's own SIGINFO translation.

So init is running with a **kernel-shaped stack pointer** and dies on its first stack access,
which lands on the supervisor-only u-area.

### Thread 1 answered: the wb040 precedent is present, and this is not it

`wb040.s` — "THE init-hang fix, 2026-06-24" — describes this class in its own header: *"init's
`lea` never set USP → systrap read the syscall args from a stale kernel USP = garbage"*. That fix
**is in the lineage**: `wb040.o` is in the base `ld -r` list of both the shipped `260818-02`
kernel and this one, so the 68040 write-back replay is present on the bench and on the card alike.
The icode's `lea` is intact in the image and exec demonstrably worked. **This is a second instance
of the same class from a different cause**, not a missing fix.

### Thread 2: the static lead — a field consumed on the syscall path and written only on the fault path

The saved-register pointer `u.u_ar0` (absolute symbol `U_AR0` = `u + 0x864`) is written by exactly
one routine and merely read by the rest:

```
u_trap  0x5a490:  movel  %d4,u+0x864     ; d4 = %fp + 8   -- SETS it
systrap 0x5a940:  moveal u+0x864,%a5     --  only READS it
```

`setregs` (`0x58b62`), which exec calls to install the new user context, writes the new stack
pointer **through that pointer** (`u_ar0[60]` at `0x58c12`) and the new PC at `u_ar0+66`
(`0x58c22`). Meanwhile `utraps` saves and restores the user SP on the **kernel stack**
(`0x11ea` push / `0x11f6` pop), so the two only agree if `u_ar0` points at that saved slot.

**PID 1's first ever entry into the kernel is a syscall** — the icode's `trap #0`. If nothing
established `u_ar0` for PID 1 before it, `setregs` writes the new SP through an inherited or stale
pointer, the real saved-USP slot never receives it, and the trap exit restores the old value. That
is the ISSUE-102 shape exactly: a field consumed but not written, harmless where memory happens to
be favourable and fatal where it is not — which is also the shape of the bench/card divergence,
since the bench boots these same bits to the installer prompt.

**This is a lead, not a conclusion.** What is *not* established statically is whether some caller
of `systrap` sets `u_ar0` first, and what value PID 1 actually carries. Both are runtime facts.

### Instrument

`src/usptrap.s` + `src/patch_usptrap.py` retarget the single `cmn_err` relocation at `0x5a640` —
the NOTICE call itself — to `unt_latch`, which latches and tail-jumps into the real `cmn_err` so
the message prints unchanged. Verified surgical: one relocation moved, the other 531 `cmn_err`
sites untouched. Blast radius on a healthy kernel is zero — the only path here is one already
reporting a fatal user fault. `unt_magic2` is stamped `"USP!"` as the first act of the latch body,
so silence cannot be mistaken for a negative result (the ISSUE-103 stage-2 lesson).

| latched | what it decides |
|---|---|
| `unt_usp` | the **actual** user stack pointer at the fault. Equal to the reported fault address ⇒ init is dereferencing its own SP and the stale-USP reading is confirmed outright |
| `unt_uar0` | `u.u_ar0` as `setregs` saw it. Near `u+0x1FC0` ⇒ inherited from proc0; wild or zero ⇒ never established at all. **Different bugs, different fixes** |
| `unt_comm0/1` | the first eight bytes of `u_comm` (`u + 0x3b0`) — the very argument the NOTICE printed as an empty CMD |
| `unt_u0/u1` | the head of the u-area, as a cheap coherence check |

### Reconciling the empty CMD, which is the sharpest of the four

`u_comm` is `u + 0x3b0`, computed at `0x5a61a` and pushed as the `%s`. Its emptiness has two
readings and `unt_comm0` separates them:

* **zero** ⇒ `u_comm` was never written, and since `exec` sets it, that is independent evidence
  that exec wrote through the wrong pointer — the same failure that would misplace the stack
  pointer;
* **ASCII** (`"/bin"` = `0x2F62696E`) ⇒ exec *did* write it, the emptiness is a reporting artefact,
  and the `u_ar0` story is badly weakened.

### Predictions, registered before the run

* `unt_usp == 0x40001FC0`, matching the reported fault address exactly.
* `unt_comm0 == 0`.
* `unt_uar0` inside `0x4000xxxx`. A value outside the u-block **refutes** the inheritance reading.
* `unt_n == 1`.

**Nothing here is measured yet.** If the latch confirms the reading, the fix follows the ISSUE-102
pattern — establish the field explicitly on the path that consumes it, rather than zero-filling
every frame — and it will be a kernel-side fix in this port, unlike ISSUE-103.

### Latch read 2026-08-21 — the lead above is REFUTED, and two of the four fields say so

`magic=UNT! n=1 have=1 magic2=USP!` · `usp=0xCB7C0002` · `uar0=0x40001F44` · `comm0=comm1=0` ·
`u0=0xC0800000` · `u1=0`.

**Correction 1 — the static lead in this entry is wrong.** `systrap` has exactly **one** caller,
at `0x5a550`, which is `u_trap+0xd2`. Syscalls therefore arrive through `utraps` → `u_trap` →
`systrap`, and `u_trap` sets `u.u_ar0 = %fp + 8` as its **first action** (`0x5a490`). So `u_ar0`
*is* established on the syscall path. The "consumed but never written" reading was mistaken.

**Correction 2 — `unt_uar0` is not diagnostic, and it is my instrument's fault.** The latch runs
inside the NOTICE, which is inside `u_trap`, i.e. **after** `u_trap` has already overwritten
`u_ar0` with the *fault's* frame pointer. `0x40001F44` is that frame, not the value `setregs`
used at exec. Any reading built on it — including "the inheritance arm holds" — has to be
withdrawn. Latching a field that the measuring path itself rewrites is the same error class as the
stage-2 label bug in ISSUE-103, in a new disguise: **the value was real, the moment was wrong.**

#### What the read does establish

The pcb layout, read off the disassembly: 16 saved registers (USP, D0-D7, A0-A6) followed by the
psw and the two PC words — so **`regsave[0]` is the saved USP**, `psw` is at +64 and the PC at
+66, which is exactly what `setregs` writes (`u_ar0[0]` ← new SP at `0x58c16`, `u_ar0+66` ← PC
at `0x58c22`). The port's own `execmark.s` header states the same contract independently:
*"systrap reads each syscall arg with lfuword(usp+off) where usp = u.u_ar0[0]"*.

`struct user`'s first member is `pcb_t u_pcb`, so **`u0` is `u.u_pcb.regsave[0]` = `0xC0800000` =
exactly `userstack`.** The correct user stack pointer was computed and stored into the u-area's own
pcb. The value exists; what runs is `0xCB7C0002`.

**Reconciling the fault address with the USP.** `0xCB7C0002` is garbage **and odd**. An odd stack
pointer is fatal to any stack operation on the 68000 family and the reported fault address is
derived from it, not equal to it — so `fa = 0x40001FC0` from the earlier boot and
`usp = 0xCB7C0002` from this one are the *same* failure with different garbage, which is also why
it varies per boot. The u-area-shaped `fa` of the first report was a coincidence of that boot's
garbage, and reading meaning into it (as the first version of this entry did) was over-fitting.

`comm0 = 0` still stands on its own: `u_comm` was never written, so exec's u-area writes did not
all land where they were read from.

#### What the next measurement must do differently

The open question is unchanged but the moment is not: **does `setregs`' write and the trap exit's
USP restore address the same memory?** That must be measured **at `setregs`**, not at the fault:

* `u.u_ar0` as `setregs` sees it, and `u_ar0[0]` immediately after it writes;
* the address of the USP slot `utraps` pushed (`%sp` at `0x11ec`), to compare against `u_ar0`;
* `u.u_pcb.regsave[0]`, to see whether the surviving `0xC0800000` is the same word `setregs`
  wrote or a second copy.

If `u_ar0` and the pushed slot differ, the mismatch is named and the fix is to reconcile them. If
they agree, the write lands correctly and something *later* clobbers USP between `setregs` and the
`rte`, which is a different search.

**No fix is proposed here, and no kernel was built for this round.** The lead this entry was
built on is refuted, the field that appeared to confirm it was measured at the wrong moment, and
guessing at a kernel-side change on that basis would be worse than saying so.

### Round 2 instrument (2026-08-21): measure the handoff AT `setregs`, not at the fault

`src/srgtrap.s` + `src/patch_srgtrap.py`. Two hooks, because one moment cannot answer it:

1. **`srg_utraps`** — the `jsr u_trap` relocation at `0x11f0` is retargeted here. It records the
   address of the slot `utraps` just pushed (`%sp + 20`: its own four saved registers plus the
   `jsr` return address lands back on the pushed word) and tail-jumps into `u_trap` with the stack
   untouched, so `u_trap`'s `%fp + 8` is unchanged and its `rts` still returns to `0x11f4`. It
   fires on **every** user trap and is deliberately **not** once-only: it must track the *current*
   trap, because the exec syscall's own frame is the one `setregs` runs inside.
2. **`setregs`** — weakened, stock body retained as `setregs_orig` at `0x58b62`. The wrapper
   latches `u.u_ar0` **before** the stock body, calls it with the same argument, then latches
   `u_ar0[0]` (the word it just wrote), `u.u_ar0` again (to prove it did not move underneath), and
   `u + 0`. The stock return value is carried in `d2` across the post-latch and restored to both
   `d0` and `a0`.

**`srg_match` is the verdict**, computed in the kernel so the readout needs no arithmetic: 1 if
`u.u_ar0` equals the pushed-slot address, 0 if not.

Execution stamps on both capture points per the standing rule — `srg_ut_stamp` = `"UTR!"`,
`srg_stamp1` = `"PRE!"`, `srg_stamp2` = `"PST!"`. A missing stamp means the path was never taken,
which is a different fact from a zero value; this entry has already been burned twice by not being
able to tell those apart.

#### The fork, registered before the run

| outcome | meaning |
|---|---|
| **`srg_match == 0`** | `setregs`' write and the trap exit's USP restore address **different memory**. The mismatch is named; `srg_uar0_pre` vs `srg_slot_at` gives the size and direction, and the fix reconciles them |
| **`srg_match == 1`** | the handoff is sound — `setregs` wrote the new SP into the exact word the trap exit loads USP from. Then something **clobbers USP between `setregs` and the `rte`**, and the search moves there. `srg_ar0_0` should read `0xC0800000`; if it does not, the write itself did not land, which is a third story |

Also predicted: `srg_n` ≥ 1 with all three stamps set; `srg_uar0_pre` == `srg_uar0_post`;
`srg_pcb0_post` == the `0xC0800000` already seen.

Blast radius: the `utraps` hook is four stores on a path already entering the kernel; the
`setregs` wrapper is a call-through. Neither changes behaviour.

### Round 2 read (2026-08-21): BOTH registered forks die — exec never ran at all

`magic=SRG! MATCH=0 ut_stamp=UTR! stamp1=0 stamp2=0 ut_n=1 n=0 pushslot=0x40001F44`, everything
else zero.

`u_trap` has **exactly one reference** in the unpatched stock image — the `jsr` at `0x11f0` inside
`utraps`. Every user trap, syscall and fault alike, routes through it. So **`ut_n = 1` means one
user trap in the entire boot**, and since the NOTICE is printed from `u_trap`'s fault path, that
one trap *is* the fault.

**The icode's `trap #0` never executed. exec never ran. `setregs` never ran** (`n = 0`, no `PRE!`,
no `PST!`). `u_comm = 0` follows for free — exec is what would have written it. Both registered
forks are dead, and so is the "exec errored out pre-`setregs` and returned to the icode" reading:
that needs two traps and there was one.

`pushslot = 0x40001F44` is the fault's own frame slot — the same number round 1 misread as
`u_ar0`, now correctly identified.

#### PID 1 died on its FIRST user instruction

`main` maps and copies the icode to **`0x80800000`** (`as_map` `0x59972`, `copyout` `0x5998a`) and
returns that address in `d0` (`0x599d2`). The initial user stack is `as_map(0xC07FF800, 0x800)`,
top **`0xC0800000`** — exactly the `pcb0` already read. `_start` then builds the frame and returns
to user:

```
44:  jsr   main          ; d0 = the user PC
4e:  movew %d1,%sp@-     ; format word 0x0000 (4-word frame)
50:  movel %d0,%sp@-     ; PC        (sets N from d0)
52:  bmis  5c            ; 0x80800000 is negative -> the USER-mode arm
5c:  movew %d1,%sp@-     ; SR = 0x0000
5e:  rte
```

That is a correct format-0 frame and correct on the 68040. **But the fault was at PC
`0x80000012`, not `0x80800000`.** The `rte` did not deliver the entry `main` computed, so the
icode's first instruction — `lea %pc@(L%stack),%sp`, the one that establishes the user stack —
never ran.

**That inverts the last two rounds: the garbage USP is a *consequence*, not the cause.** `_start`
never loads USP and does not need to, precisely because the icode sets its own stack; with the
wrong PC that never happens, and USP keeps whatever it held (`0xCB7C0002`).

#### Round 3 instrument

`src/inittrap.s` + `src/patch_inittrap.py` retarget `_start`'s `jsr main` relocation at `0x46` to
`ini_main`, which calls the real `main`, latches its return value, and hands it back in `d0`
unchanged so the `bmis` and the frame build are bit-identical. Stamps `INI!` on entry and `RET!`
after `main` returns.

| outcome | meaning |
|---|---|
| `ini_ret == 0x80800000` | `main` is right; the corruption is in the `rte` or the frame it reads — a 68040 frame/format question |
| `ini_ret == 0x80000012` | `main` computed the wrong entry; the search moves into its icode setup |
| anything else | a third story, and the value names it |

**Noted, not acted on:** the initial stack mapping is 2 KiB-shaped — base `0xC07FF800` is not
4 KiB-aligned and the size is `0x800`. `as_map` rounds to page boundaries so it probably still
covers `[0xC07FF000, 0xC0800000)`, but nothing in the Model-B patch tables appears to own that
site. Worth a look once the entry-point question is settled.

### Round 4 (2026-08-21): the firmware RTE probe reframes it again — catch the ONE user transition

The Z3660 lane exonerated the RTE core on table-walked frames, and its metal probe (first 8
u-block-window RTEs after MMU-on) showed **every one returning to supervisor kernel text** — `pc
0x0800xxxx`/`0x080Dxxxx`, `SR` S-set, `fmt 0068`/`006C`, `usp 0x08003118` throughout. All eight
are interrupt/fault churn *inside* `main()`. None is the user drop (no `SR=0x0000`, no
`pc=0x80800000`, no `fmt=0`). Round 3 proved there is exactly one user trap in the whole boot (the
fault), so the user transition happened once, later than the 8-cap, and delivered the wrong PC.

**Where `_start`'s stack is, settled:** `0x3c` does `moveal #u+0x1FC0,%sp`, so the SSP is
`0x40001FC0` — in the u-block. The captured RTEs at `0x40001Dxx`–`0x1Exx` are `main()`'s nested
frames on that stack. So the firmware window is right; the user RTE is simply the 9th+.

**The arithmetic that names the bug:** icode is mapped at `0x80800000`; the fault PC is
`0x80000012` = `0x80800000` with **bit 23 (`0x00800000`) cleared**, plus `0x12`. PID 1 ran a
couple of instructions from the wrong page (`0x80000000`) and faulted. So `main` computes the
right entry (round 3's `ini_ret = 0x80800000`) but the user-transition RTE delivered it with bit
23 gone.

#### Instrument — the user RTE itself

`src/inituser.s` + `src/patch_inituser.py` replace `_start`'s frame-build + user RTE
(`0x4a`–`0x5f`, 22 bytes) with `bra.l ini_user_rte` + NOPs. The island **rebuilds the identical
frame** from `d0` (so a good kernel launches PID 1 unchanged) and, on the first firing, latches
`d0`, the SSP, USP, and the three frame words read straight back off the stack. `bra.l` not
`bsr.l`: it pushes no return address, so the reported SSP is the true one the RTE pops from.

**The decisive triple, in one boot** — `ini_ret` (round 3, what `main` returned), `iur_pc` (`d0`
at the frame build), `iur_f_pc` (the PC longword actually in the frame):

| reading | verdict |
|---|---|
| all three `0x80800000` | frame correct, **RTE delivered `0x80000000`** — back to the CPU core, but with the exact failing frame address (`iur_a7` ≈ `0x40001FB8`, u-block/table-walked) and the exact bit: the concrete case the "exact delivery on table-walked frames" exoneration did not cover |
| `iur_pc = 0x80000000`, `ini_ret = 0x80800000` | `d0` lost bit 23 between `ini_main`'s `rts` and here — an ISSUE-103-family data-path bit-drop, **kernel-side fix** |
| `iur_f_pc = 0x80000000`, `iur_pc = 0x80800000` | the `movel %d0,%sp@-` push truncated the store — a store bit-drop, the nearest cousin of ISSUE-103's BFINS finding |

#### Predictions, registered

`iur_stamp1 == "IUR!"`, `iur_stamp2 == "FRM!"`, `iur_n == 1`; `iur_f_sr == 0x0000` (user),
`iur_f_fmt == 0x0000`, `iur_a7` in `0x4000xxxx`. The fork itself is genuinely open — prior is
`iur_pc == iur_f_pc == 0x80800000` (frame correct, RTE delivers wrong) or a clean bit-23 drop at
exactly one of the three points. `iur_usp` is captured too: it becomes PID 1's `a7` at the drop,
before the icode's own `lea` would set it — which is why the earlier garbage-USP reads were a
consequence, not the cause.

### Round 4 read + round 5 fix (2026-08-21): the island caught the wrong RTE, and the miss named the mechanism

Round 4 latched `n=2`, `f_sr=0x00002000` (supervisor), `pc=f_pc=0x080DA84C`, `a7=0x40001FC0`.
`0x080DA84C` is **`sched`** (the scheduler, a port override); `a7` is exactly `_start`'s SSP. Not
the user drop.

**Why the island fired twice.** `main` has two return paths to its `rts`:
`0x599d2 movel #0x80800000,%d0` and `0x59c0e movel #sched,%d0`. That is the SVR4 boot fork —
`main` sets up proc 1 with `newproc` and "returns twice":

* **proc 0** returns `&sched` → falls through `ini_main` into `_start 0x4a` → this island → `d0`
  positive → supervisor arm → RTE into `sched`, which calls `swtch` (`0xda852`) and loops;
* **proc 1**, context-switched in by `swtch`, resumes in `main`, returns `0x80800000` → the same
  trampoline → `d0` negative → user arm → **the real user drop**.

So the island is the launch trampoline for *both* processes, round 4's `have`-gate latched
firing 1 (proc 0 → sched), and `ini_ret = 0x80800000` (round 3) is proc 1's return, written last.

**The fix (round 5):** latch only the **user arm** (the pushed SR has S clear), once. Every
non-user firing still builds its frame and RTEs, so proc 0 still reaches `sched` and proc 1 still
drops to user — the boot is unchanged. The user arm is entered only by proc 1's drop, so
"user arm + once" is unambiguous. One deliberate refinement over "S-clear **and** pc-in-range":
the S-clear arm alone isolates the drop, so the latch there is **unconditional** and captures the
drop even if the delivered PC is wildly corrupt — a pc-range *gate* could miss exactly the
failure being hunted. The pc-in-range test is kept as a recorded flag (`iur_pc_inrange`), not the
gate. `iur_first_pc`, `iur_super_n`, `iur_user_n` are added so the re-run confirms the
two-firing story.

Predictions unchanged from round 4 for the decisive triple (`ini_ret` / `iur_pc` / `iur_f_pc`),
plus: `iur_n ≥ 2`, `iur_super_n ≥ 1`, `iur_user_n == 1`, `iur_first_pc == 0x080DA84C`,
`iur_f_sr == 0x0000`, `iur_pc_inrange == 1`, `iur_a7 ~ 0x40001Fxx` (proc 1 kstack in the fixed u
VA, a page-table-translated address — so if all three PCs read `0x80800000`, the bit-23 drop is
in the RTE's read of the frame VALUE, not the address, and the exact translated frame address is
in `iur_a7` for the harness).

### Round 5 read + round 6 ring (2026-08-21): bit 23 FIXED (firmware) — the fault moved into user text

The Z3660 bus-misalign fix (BDBA0BDE) delivered bit 23 correctly: the fault PC moved
`0x80000012` → **`0x80800012`**, so PID 1 now launches at the right entry `0x80800000` and runs.
That confirms the round-4/5 fork's "RTE delivered the value with bit 23 dropped" arm — it was the
CPU core reading the frame, exactly as predicted, and it is now closed on the firmware side.

But PID 1 still `User BUS ERROR`s, now `PC:80800012 FAULT:6 fa=40001FC0` (the same u-block SSP
address). Disassembled, the icode is only 14 bytes of code:

```
icode+0x00  lea %pc@(L%stack),%sp   ; 8 bytes -> SP = icode+0x2A (the arg block)
icode+0x08  moveq #11,%d0           ; SYS_exece
icode+0x0a  trap #0
icode+0x0c  bras .                  ; loop forever if exece returns
icode+0x0e  "/sbin/init\0" ...      ; data
```

`icode+0x12` (`0x80800012`) is **inside the "/sbin/init" string**, four bytes past the `bras`
self-loop. So PID 1's PC ran off the end of the code into data, and `fa=0x40001FC0` (the SSP)
means the garbage it then executed touched the kernel stack — consistent with PID 1 running on
the wrong A7.

**The open questions, all runtime:** did the icode's `lea` set SP to `~0x8080002A`, or is PID 1 on
the un-switched SSP (`0x40001FC0`) / a stale USP (`0x08003118`, seen in round 4)? Did the icode's
`trap #0` execute at all, or did PID 1 fault before it? Did the syscall return advance the user PC
to `+0x12` instead of `+0xc`?

#### Round 6 instrument — the first four user traps, in order

Round 2 proved every user trap (syscall *and* fault) routes through the `utraps → u_trap` edge
(`srg_ut_n = 1` was the fault). Round 6 extends that existing hook into a **ring of the first four
user traps**, reading each from the exception frame on the SSP: `srt_vec[i]` (frame fmt+vec word —
`0x0080` for a `trap #0`, `0x7008` for an access error), `srt_pc[i]` (user PC), `srt_usp[i]`
(A7 at the trap = the SP the `lea` set), `srt_d0[i]` (user d0). `srt_stamp` = `"SRT!"`.

**Predictions, registered:**

* if the icode reaches its syscall: `srt_vec[0] = 0x0080`, `srt_pc[0] ≈ 0x8080000C` (return past
  `trap #0`), `srt_d0[0] = 0x0B` (exece), and `srt_usp[0] = 0x8080002A` **iff the `lea` ran and
  A7 is the arg block**. Then `srt_vec[1] = 0x7008`, `srt_pc[1] = 0x80800012` — the fault.
* if PID 1 faults before ever trapping: `srt_vec[0] = 0x7008`, `srt_pc[0] = 0x80800012`, and
  `srt_usp[0]` tells the SP it faulted on — `0x40001FC0` (un-switched SSP) or `0x08003118` (stale
  USP) names the mechanism directly.

The decisive cell is `srt_usp[0]`: `0x8080002A` clears the RTE/lea and moves the hunt to why the
syscall/return runs off into the string; `0x40001FC0`/`0x08003118` proves PID 1 is on the wrong
stack, which is a kernel USP-load (or emulator RTE USP-switch) defect.

**Emulator vs kernel, stated:** the bit-23 half was **emulator** (fixed). This half is undecided
and the ring decides it — a wrong `srt_usp` with a correct `srt_pc[0]=+0xc` return points at the
RTE-to-user USP switch (emulator) or the kernel never loading USP before `_start`'s user RTE
(kernel); a `srt_pc` that lands in the string with a *correct* `srt_usp` points at the syscall
return-PC advance. No fix is proposed until the ring says which.

### Round 6 read attempt (2026-08-21): all blocks zero = wrong address, and the analysis sharpens

The metal read of i52f showed `PC:80800012` on HDMI (confirming the run-off-into-the-string) but
**every counter block read `0x00000000`, including `pgz_magic`**. `pgz` populates at `kvm_init`
on every boot (proven four times), so a zero *magic* cannot mean the block failed — it means the
read address was wrong.

**The cause is a build-line address mismatch, and it is a standing trap worth recording.** The
main line carries the full instrument set (the ISSUE-10 `i10rev040` block and its neighbours);
the minimal-delta line does not. That extra `.data` on main pushes every counter block to a
higher runtime address. The addresses being read (`srg@0810DEF8`, `pgz@0810DDD4`, …) are the
**main-line** build's; the card runs the **minimal-line** i52f, whose blocks sit ~8 KB lower.
`tools/status-facts.sh` must be run on the *exact artifact booted* — the two lines are never
interchangeable for counter addresses, and the specific numbers change every build, so they are
not recorded here (per the repository's own rule against hand-carried volatile numbers).

**What the fault reboots into.** The counter blocks live in `.data` (magic word plus zeroed
counters), not `.bss`. `mlsetup`'s `bzero(edata, end)` clears `.bss` only, so it does **not** wipe
them; they are reset only when `boot2` reloads the kernel image on the next warm boot. PID 1's
fatal user fault → `SIGBUS` to init → init dies → the kernel panics ("init died") → `xpanic` →
(ISSUE-100 guard) `sync` → `rtnfirm` → warm reboot, on the observed ~90 s cycle. So within a
cycle, `pgz` is populated from `kvm_init` onward and `srt` from the init fault onward; both
persist until the reload. A correct-address read at almost any time after early boot shows `pgz`
non-zero.

**The analysis sharpens — it is the SECOND user RTE that is corrupt.** The fault is at
`PC=0x80800012` with `fa=0x40001FC0`. The icode's `lea` sets `SP=~0x8080002A`; for a string-byte
"instruction" at `0x80800012` to touch `0x40001FC0`, **A7 must be `0x40001FC0` (the SSP), not the
arg block** — so A7 was corrupted *after* the `lea`. The only thing between the `lea` and the
fault is the `trap #0` (exece) and its return. Therefore the **syscall-return RTE** (the second
kernel→user transition — the first being proc 1's launch) delivered **both** a wrong PC
(`0x80800012` instead of `0x8080000C`) **and** a wrong A7 (`0x40001FC0` = the SSP, i.e. USP was
left equal to the SSP). PID 1's launch RTE worked (it reached `0x80800000` and ran); the syscall
return did not. That relocates the bug to how the syscall/exece return builds the user context
(kernel) or how the RTE-from-syscall restores USP (emulator).

#### HANDOVER — firmware-side capture of the user-drop RTEs (no `.data` race)

For the accelerator's 68040 core. The kernel-side `srt` ring reads the same answer but is trapped
behind the `.data`/reboot timing; the emulator can print it to serial the instant it happens.

**Gate:** fire on any `RTE` whose popped frame drops the CPU to **user mode** — the SR word the
RTE is about to load has the **S-bit (bit 13, mask `0x2000`) CLEAR**. At the `RTE`, `a7` points at
the frame; read the SR word at `a7+0` and test `(sr & 0x2000) == 0`. Capture the first 4–8 such
RTEs (there are normally very few this early).

**Print, per firing, immediately to serial:**

| field | source | expected / tell |
|---|---|---|
| seq | a firing counter | RTE #1 vs #2 |
| `pc` | frame PC longword at `a7+2` | #1 = `0x80800000`; **#2 suspected `0x80800012`** (the wrong return) |
| `sr` | frame SR word at `a7+0` | bit 13 clear (user) |
| `ssp` | `a7` before the pop | the kernel stack |
| **`usp`** | the USP register value now | **the decisive field — becomes PID 1's A7.** valid user SP = RTE fine; `0x40001FC0` (SSP) or `0x08003118` (stale) = PID 1 dropped onto a bad stack |
| `fmt` | frame format/vector word at `a7+6` | format 0 (`0x0xxx`) |

**Interpretation:** the **second** S-clear RTE is the syscall return from the icode's `trap #0`.
If it shows `pc=0x80800012` and/or `usp=0x40001FC0`, the syscall-return context (PC + USP) is
corrupt — which is exactly the observed fault. The first RTE (proc 1 launch) is the control: it
should be clean (`pc=0x80800000`). This is emulator-side to *observe*; whether the *fix* is
emulator (RTE USP restore) or kernel (syscall-return frame build) is what the two RTEs'
`usp`/`pc` values decide.

### Firmware URTE read (2026-08-21): proc 1's launch is PERFECT — the icode derails on the CPU core

The firmware `[URTE]` probe fired **once**: `pc=0x80800000 sr=0x0000 ssp=0x40001FB8 usp=0x08003118
fmt=0x0000`. proc 1's launch RTE is flawless — correct entry, user mode (S clear), format 0, a
plausible kernel stack. `usp=0x08003118` is a don't-care placeholder (the icode sets its own SP).
**There is no second URTE** — PID 1 never returns from a syscall to user. So it faults *inside* the
icode, in user mode, between the clean launch and `PC=0x80800012 / fa=0x40001FC0`.

**Two facts settle where this lives.** First, the icode (`.text 0x36e..0x3a4`) is **byte-identical
between the stock kernel and the 040 build** — the port does not patch it. Second, the bench
(Amiberry's 040 core) boots this same miniroot to the installer prompt, so init runs there; and
the same full-format PC-relative addressing is a 68020+ mode the 030 executes too. **The bytes are
correct and run on two other cores. The divergence is the Z3660 card's 68040 execution of this
instruction stream** — the same shape as ISSUE-103 (bitfield ops) and the bit-23 bus-misalign, both
of which were advanced-040 gaps Amiberry handled and the Z3660 core did not, until fixed.

**Prime suspect — the icode's first instruction.** `lea %pc@(L%stack),%sp` = `4ffb 0170 0000
0028`, a **full-format** PC-relative EA (`ext 0x0170`: full format, base displacement long
`0x00000028`, index suppressed, no memory indirect). A correct 68040 computes
`A7 = 0x80800002 + 0x28 = 0x8080002A`. If the Z3660 core mis-decodes the full-format extension —
wrong EA, or the wrong instruction length so the stream misaligns and the `trap #0` at `+0x0a` is
never executed as a trap — PID 1 runs on into the icode data (`icode+0x12` is inside the
`"/sbin/init"` string) with a bad A7, and a stray stack access faults. That is exactly the
observed shape (no `trap #0` supervisor round-trip, no URTE2, a user fault at `+0x12`).

**This is not the icode build and not exece's return path.** The icode build is ruled out (bytes
identical to stock, runs on 030 + Amiberry). exece's return path is ruled out (no URTE2 means
exece never returned to user — the derail is *before* the syscall completes).

#### Cheapest confirmation, already aboard i52f — read the `srt` ring at the CORRECT addresses

i52f's round-6 ring captured the first user traps. Read (minimal-line i52f addresses):
`srt_vec[0]=0x0810C17C`, `srt_pc[0]=0x0810C18C`, `srt_usp[0]=0x0810C19C`, `srt_d0[0]=0x0810C1AC`
(stamp `0x0810C174`). **`srt_vec[0]=0x7008`** (an access-error frame) with `srt_pc[0]=0x80800012`
proves the icode faulted **before** ever trapping (derailed); **`srt_vec[0]=0x0080`** (a `trap #0`
frame) would mean it reached the syscall. `srt_usp[0]` is A7 at that first trap.

#### Decisive pinpoint — a firmware single-step probe (Z3660)

If the ring is not enough, single-step the first ~8 user instructions. After the user-drop RTE
that delivers `pc=0x80800000`, print per instruction: **PC, the opword at PC, A7, d0**.

**Predictions (correct-core baseline):**
* step 0: `PC=0x80800000 opword=0x4ffb A7=0x08003118` → **after: A7=0x8080002A** (the `lea`). If A7
  does not become `0x8080002A`, the full-format PC-relative EA is mis-computed — the bug.
* step 1: `PC=0x80800008 opword=0x700b` (moveq). **If PC is not `0x80800008`, the `lea` consumed
  the wrong number of bytes** — the stream is misaligned, and the `trap #0` at `+0x0a` will be
  skipped, which is what "no URTE2 + user fault at `+0x12`" means.
* step 2: `PC=0x8080000a opword=0x4e40` (trap #0) → leaves user; a correct core stops the trace
  here.

The two decisive cells are **A7 after step 0** (did the `lea` compute the right SP?) and **PC at
step 1** (did the `lea` consume the right length?). Either being wrong pins it to the Z3660 040
core's handling of the full-format PC-relative `lea`. No kernel change is proposed — if confirmed,
the fix is emulator-side.

---

## ⚠ ISSUE-50 (2026-08-25, OPEN): the burst step depends on a binary no clone can build, and nothing says so

> **Ledger: OPEN** — found while preparing the first acceptance run on merged `main`.

`test-tools/burstloop11.sh` runs `/tmp/hat_dup_cow`, and **there is no source for it anywhere in
this repository** — not in `test-tools/`, not under any other name, and no `.c` file mentions it.

> **Correction (2026-08-25, same day).** This entry first said nothing recorded the omission. That
> is wrong, and the way it was wrong is worth keeping. `test-tools/burst4.sh` documents it
> prominently, in a block headed **STILL MISSING**, naming every NAS path the binary survives at
> and stating what a run without it does and does not prove. I searched `ACCEPTANCE.md` and
> `test-tools/README.md` — the two files I expected it to be in — and concluded from their silence
> that the project was silent. The script that needs the binary was the obvious place to look and
> the one place I did not. Note also who wrote that block: I did, on 2026-08-19, when recovering
> `burst4.sh` from the NAS.

So step 6 of the acceptance procedure — burst and stress — cannot be run from a fresh clone. It
can only be run on a machine where some earlier session happened to leave the binary behind, and
whoever runs it there has no way to know what that binary was built from.

### Why this is the same defect twice

The 2026-08-19 run found `test-tools/burst4.sh` untracked but not ignored: present on the machine
that wrote it, absent from every clone. It was committed. This is the same shape one level down —
the script is now tracked, but the program it invokes is not, and the procedure that depends on
both says nothing about either.

The pattern worth naming: **a test tool is not delivered until a clone can build it.** A file that
exists only where it was first written is indistinguishable, to the person running the procedure,
from a file that was never needed.

### What it does not mean

`hat_dup_cow` is the fork/COW exerciser behind the burst suite's 24-sum rounds, and the suite has
been run and accepted repeatedly — most recently 96/96 on `68060-260819-13`. Those results stand;
they were produced by a real program doing real work. What is missing is the ability to reproduce
them somewhere else.

### Options

1. Recover or rewrite the source and track it. The behaviour is documented by `burstloop11.sh`'s
   expectations (24 good sums per round, `1570 8192` per file) well enough to re-derive.
2. Failing that, record in `ACCEPTANCE.md` that step 6 requires a pre-existing binary, name it, and
   say where the surviving copy lives — so that the limitation is visible rather than discovered by
   whoever next tries to run the procedure cleanly.

Option 2 is the honest minimum and costs nothing. Doing only option 2 leaves the procedure with a
step that a fresh clone cannot execute, which is worth knowing before the next person tries.

### Where the surviving copies are (checked 2026-08-25)

It is **not** on the machine: `/tmp/hat_dup_cow` is gone, because `/tmp` is where it lived and the
machine has rebooted since. For a while that looked like the program being lost outright.

It is not. `burstloop11.sh`'s own header names the location, and five copies survive on the NAS:

    amix/hwtest-260801/hat_dup_cow      8071 bytes, 2026-08-01   <- the one the header names
    amix/hwtest-260727/hat_dup_cow
    amix/hw260719/hat_dup_cow
    va2000dev/b1dc/hat_dup_cow
    va2000dev/modelb-b/hat_dup_cow

So the burst step runs, by copying the binary from the NAS first. What remains true is that
**nobody can rebuild it or say what it was built from** — five identical-looking binaries with no
source between them is provenance by folklore. The header naming the path is what saved this, and
is worth copying as a habit: when a tool cannot be built, the procedure that needs it should say
where it lives.

---

## ⚠ ISSUE-51 (2026-08-26, OPEN): a burst read returned wrong bytes, silently, and the file was fine

> **Ledger: OPEN** — found by the first burst run with the DMA counters read on both sides.
> Image `68060-260826-04`, 4 rounds, `hat_dup_cow` pressure present.

    rounds=4
    good_sums (expect 24 per round):
    95
    ---- wrong sums ----
    1522 8192 /press6.bin

**95 of 96.** One file summed to `1522` instead of `1570`, at the right length (8192 blocks).

### The file was never wrong

Re-read immediately afterwards, twice, it sums to `1570`. `b2verify` against `/payload.bin` says
`CLASS=V0_COMPLETE_MATCH size=4194304 crc=50250`, and so do the other five. **Nothing wrote
`/press6.bin` between the bad read and the good ones** — the burst's last round wrote it and
summed it immediately, and the run ended there.

So the write landed correctly and **a read returned different bytes than the same file yields
now**. Silently: no error, no short count, the full 8192 blocks.

### What is ruled out

* **A race in the test.** `burst4.sh` runs six `cp`s and `hat_dup_cow` in the background and then
  `wait`s before `sum`. The copies had completed.
* **`sum` misreporting a read error.** That is the 2026-07-23 lesson — AMIX's `sum` prints a
  partial block count after `ferror()`, so a read error looks like a short file. Here the block
  count is right and only the checksum differs, and `b2verify`, which reports the real errno,
  finds nothing wrong now.
* **A missing or unbalanced DMA prepare/complete.** The counters were read before and after, which
  had never been done. Across the burst's **155 788** transactions:

        dma_prep_from + dma_prep_to  =  42629 + 120975  =  163604
        dma_cmpl_count               =                     163604
        dma_prep_whole               =                     163604
        dma_seg_seq                  =                     163604
        dma_cmpl_from = dma_prep_from,  dma_cmpl_to = dma_prep_to

  and every must-stay-zero diagnostic stayed zero: `dma_prep_owned`, `dma_cmpl_noprep`,
  `dma_range_ovf`, `dma_zero_arm`, `dma_reconn_arm`.

**That last point is the useful one.** The B2 ownership protocol did exactly what it claims,
every prepare matched a complete in the right direction, and a read still came back wrong. So
this is not a dropped or mispaired cache operation — which is what the counters exist to rule
out, and the first time they have been in a position to rule anything out.

### What it is not (yet)

Not the A3091 wedge: `a3d_ran` stayed `0` and the machine survived the run. Not necessarily new
either — this is the first burst ever run with a wrong-sums check that could report cleanly (the
previous one matched its own header, see 2026-08-26's fix), so an earlier occurrence at this rate
would have been indistinguishable from the check's own noise.

Family resemblance to ISSUE-10 is obvious — a silent wrong value under concurrent
copy-plus-fork/COW pressure — but resemblance is not identity and nothing here has been tied to
a stale PTE.

### Next

1. **Rate.** One in 96 is a single event. Repeat the burst and count: two runs of 4 rounds each
   would say whether this is ~1 %, rarer, or a one-off.
2. **Catch it in the act.** The ISSUE-10 instruments (`i10w_*`, `i10g_*`) watch for a poisoned
   value at a watched address; this needs the analogous thing for a read that disagrees with the
   file. `b2verify` in a loop over freshly written files would at least turn "one wrong sum" into
   "the read that disagreed, with its errno and offsets".
3. **The `dma_*` block has no magic word**, which is why `status-facts.sh` never listed it and no
   battery driver ever dumped it. Giving it one costs nothing and makes it visible to every tool
   automatically.

### Rate, first additional datum: 2026-08-27, `68060-260827-06` — **96/96**

A four-round burst on the ISSUE-53 kernel ran clean: 96 good sums, all ten anomaly patterns zero,
and the wrong-sums check silent. The `dma_*` block balanced exactly across 162 485 transactions
with every must-stay-zero counter at zero.

**Two runs, one miss: that is a rate of 1 in 192 and nothing more.** It does not close this, and
nothing in the ISSUE-53 kernel was aimed at it.

Item 3 above stopped being a tidy-up on the same day. Reading the `dma_*` block for that record
was first attempted at a runtime address computed against the **`.text`** base instead of
`.data`, so it returned longwords out of the middle of the kernel's code — `207c00bf`,
`4e5e4e75` — which look exactly like counters until you disassemble them. Every other block in
the kernel would have failed its magic check instead. See
[`docs/REALHW-ISSUE53-260827-06.md`](docs/REALHW-ISSUE53-260827-06.md) §6.

---

## ⚠ ISSUE-52 (2026-08-26, OPEN): the load average freezes on garbage after FP-heavy graphics

> **Ledger: OPEN** — an observation, not yet attributed. Seen on `68060-260826-07`, the RTG
> variant built from the LC060 merge.

After X11, wolf3d and Quake had been run and stopped:

    9:12am  up 8 mins,  2 users,  load average: -2854062.34, 6910653.78, 1705065.05

Every earlier reading in that session, across several kernels and hours, was
`load average: 0.00, 0.00, 0.00`.

### Frozen, not merely wrong

Read three times at five-second intervals, the three numbers were **identical**. A real load
average decays; one that does not move means the accumulator has stopped being updated rather
than that it holds an unusual value. `w` prints the same figures, so both consumers read the same
place.

### What still works, which narrows it

**The clock is alive.** `up N mins` advances and timestamps update, so the clock interrupt is
running. It is the load-average computation specifically, not the tick.

Nothing in the day's acceptance depends on it: the power-cut test uses `uptime`'s **duration**
as its precondition, and that read correctly in both phases (`up 1:13` → `up 1 min`).

### The obvious hypothesis, and why it is only that

The load average is computed in floating point, and wolf3d and Quake are heavy FP users. Kernel
FP arithmetic landing in the wrong FPU state after a heavy FP process would produce exactly this:
garbage that then stops moving. And FPU changes landed the same day (the LC060 merge's
`fpu_present` gates in `fpu060.s`).

**That is a hypothesis and nothing more.** The gates were measured inert on this machine —
`fpc_save_nofpu_n`, `fpc_rest_nofpu_n` and `fpc_setup_nofpu_n` all read zero after a full
battery and a four-round burst — so the merge has no established connection to this.

### Whether it is new is unknown, and that matters

The 2026-08-19 acceptance ran the same three applications on the Zorro III branch. Nobody read
`uptime` afterwards. So this may have been happening for weeks; it may equally be new today. The
honest position is that there is no baseline.

### What would settle it, cheapest first

1. **Boot the base `-06` and run something FP-heavy.** If the load average rots there too, the
   RTG driver is not involved.
2. **Do the same on `-04`, which predates the LC060 merge.** If it rots there, the merge is not
   involved either, and this is older than today.
3. Only then look for the accumulator. `avenrun` is not a global symbol in this image, so
   locating it needs the disassembly of whatever `/usr/ucb/uptime` reads through `/dev/kmem`.

Step 2 is the one that matters, because it is the only one that can date the defect.

---

## ⚠ ISSUE-53 (2026-08-27, OPEN — fix built, not yet run): `a3091intr` reads WD status for interrupts the SCSI controller never raised

> **Ledger: OPEN.** The defect is established statically and by four runtime captures; the
> unit that addresses it is in `68040/68060-260827-05` and **has not been run on either
> platform.** Nothing below claims a measurement that has not happened.

The A3091 handler's entire admission test is SDMAC `ISTR` bit 4, and it then reads the
WD33C93A SCSI Status register unconditionally. Bit 4 is `INT_P`, an **aggregate**: the WD's
own request (`INTS`, bit 6), the SDMAC's end-of-process (`E_INT`, bit 5) and the FIFO
under/over-run errors all raise it. So an interrupt the SCSI controller never asked for is
dispatched as a WD event, on a register the data sheet defines only for a read that follows
an asserted WD interrupt. `atab[IDLE][8]` maps that to action 1, `badhardware()` returns
`DEAD`, the `DEAD` row absorbs every later input, and `startany()` refuses to run unless the
state is `IDLE`. There is no path back; the machine needs a power cycle.

Observed **four times on 2026-08-26** across three kernels, always `units[6]` (the root
disk) with `head=0 dmaon=0 segstate=0`: `docs/A3091-WEDGE-CAPTURED-260826.md`.

### Why this is the stock driver and not this port

Every variable the port controls was varied without changing the outcome — three kernels
with three different `.bss` layouts, both transfer directions, both transfer sizes, positions
from 7 300 to 168 807 in the DMA sequence, with and without a preceding burst. The port's own
DMA-ownership counters were all in their must-stay-zero state at each capture. The audit
adds the static half: `A2091` carries the same aggregate gate and the same permanent shutdown,
so the defect predates this work and is shared by a sibling driver.

NetBSD's `sys/arch/amiga/dev/ahsc.c` and Linux's `drivers/scsi/a3000.c` both put a boundary
between "which source interrupted" and "read WD status", and neither reads the WD unless
`ISTR.INTS` says the WD asked. Two independent implementations for the same gate array.

### The fix, and the three alternatives that were rejected

`src/a3091demux040.s`, reached by retargeting the one `int2_tbl` relocation
(`src/patch_a3091_intr.py`). One `ISTR` snapshot at entry, before anything else; a pure
`E_INT` is acknowledged with `CINT` and returns **without** reading `SS` or touching the DFA;
everything else, including every error and unclassifiable combination, reaches the stock body
exactly as before. `a3091intr` stays a strong global and is called by name, so nothing is
weakened. Contract and measurement contract:
[`docs/contracts/A3091-SPURIOUS-COMPLETION-AUDIT.md`](docs/contracts/A3091-SPURIOUS-COMPLETION-AUDIT.md).

Rejected, with reasons, so they are not re-proposed:

| Tempting change | Why not |
|---|---|
| `atab[IDLE][8]` → no-op | A target that disconnects leaves its request on the unit's `comhead` while `istate` returns to `IDLE`. A **genuine** `0x16` there would have action 0 dereference `curunitp->comhead` and complete the wrong request. Action 1 is a fail-stop guard, and ignoring it trades the wedge for a stranded request |
| `btst #4` → `btst #6` | Correctly stops the WD misread, and leaves a pure `E_INT` unacknowledged: interrupt storm |
| treat `srst` as a reset | It is the `SP_DMA` stop strobe, at offset `0x3e`. It cannot recover WD protocol state |
| a `DEAD` → `IDLE` recovery path | None exists. Building one means resetting and reprogramming the controller and settling every active, queued and disconnected request. Not a byte edit, and not needed if the harmless source is never admitted |

### What would close it

The block is `a3w` (magic `A3W!`). `a3w_calls` counts every level-2 interrupt, so it is the
denominator that proves the wrapper is in the table at all. Three invariants must reconcile:

    a3w_calls      = a3w_nodev + a3w_notours + a3w_own
    a3w_own        = a3w_ints_only + a3w_ints_eint + a3w_eint_only + a3w_other
    a3w_eint_acked = (a3w_eint_only - a3w_eint_deleg) + a3w_resid_eint

and then, over a workload that previously wedged: `a3w_eint_only > 0` (the mechanism exists),
`a3w_other = 0`, `a3w_nodev = 0`, `a3d_n = 0`, ordinary `a3w_ints_only` traffic nonzero, disk
truth byte-exact, and no new filesystem damage after a power cut.

**`a3w_eint_only = 0` would not be a pass.** It would mean the workload never produced the
event, and the reading would say nothing — the `sdc_setprot_bad` lesson from 2026-08-26.

If the machine wedges anyway, `a3w_dead_istr` holds the **entry** snapshot of the interrupt
that did it. That is the one datum the four captures could not produce, because `a3d_istr` is
sampled after `a3091intr` has already read `SS` and cleared WD `INTRQ`.

`a3w_consume` is a live A/B: `1` (shipped) consumes a pure `E_INT`; `kpoke`ing it to `0`
turns the unit into pure instrumentation with stock behaviour, which is the audit's
"classification build" without a second power cycle.

### Emulator, 2026-08-27 — `68040/68060-260827-06`, and what it did **not** decide

`test-tools/issue53-emu-verify-260827.txt`. The wrapper is in the table and its body runs;
**131 538** level-2 interrupts, **29 928** of them the A3091's, all classified `ints_only`;
all three invariants exact on the final read; `a3w_other`, `a3w_nodev`, `a3w_dead_n` and
`a3d_n` all zero; disk truth byte-exact against the host (`sum -s` 30951 3614 both sides).

**It decides nothing about the defect, and that was predicted before the run.**
`a3w_or_istr`, the OR of every entry snapshot over all 131 538 interrupts, is `0x00d1`:
bit 5 (`E_INT`) is **never set, in any combination**. Amiberry does not produce the SDMAC
event this unit exists to catch, so `a3w_eint_only = 0` here is an unexercised path and
nothing else. Add it to the list of things the emulator cannot decide.

What it does buy is that the hardware run starts from a wrapper known to be wired, known to
classify ordinary traffic correctly, and known not to break the disk.

### Silicon, 2026-08-27 — first reading, `68060-260827-06`, 2 minutes idle

Read from the running machine, not staged: `a3w_magic` ✓, `a3w_ran` ✓, 35 310 level-2
interrupts of which 7 538 the A3091's, **all** `ints_only`, every must-stay-zero counter
zero, `a3d_n = 0`. Nothing has been provoked yet; this is the idle baseline.

**`a3w_or_istr = 0xfed3` on silicon, against `0x00d1` in the emulator, and the difference is
not the one that was being looked for.** Decomposed:

| bits | meaning | silicon | emulator |
|---|---|---|---|
| 15–9 | not defined by NetBSD or Linux | **all 1** | all 0 |
| 8 | `INTX` | 0 | 0 |
| 7, 6, 4 | `INT_F`, `INTS`, `INT_P` | 1 | 1 |
| **5** | **`E_INT`** | **0** | **0** |
| 3, 2 | `UE_INT`, `OE_INT` | 0 | 0 |
| 1, 0 | `FF_FLG`, `FE_FLG` | 1 | bit 0 only |

Two things follow, and they pull in opposite directions.

**The undefined upper bits read as ones on real hardware.** The wrapper is unaffected because
its error test masks exactly the three named sources (`0x010c`) rather than whitelisting the
documented bits — `a3w_other` is 0 across 7 538 interrupts, which proves it. Anyone
"tightening" that mask into a whitelist would classify **every** interrupt on silicon as
unclassified, print four console lines and change nothing else, and would see none of it in
the emulator. Recorded so that does not happen.

**`E_INT` was not set at the entry of any of those 35 310 interrupts.** That is not the same
as "`E_INT` never asserts": `stopdma()` issues `CINT` on every stop, so the ordinary FLUSH
completion is cleared before it can be delivered. A pure `E_INT` would by construction be the
*late* one that escaped that `CINT` — rare, which is what the wedge is. So this reading
neither confirms nor refutes the candidate; it says the mechanism is not routine, which was
already implied by the wedge happening a few times a day rather than a few times a minute.

### Silicon, 2026-08-27 — battery **12/12** and burst **96/96**, and `E_INT` still not seen

Full record: [`docs/REALHW-ISSUE53-260827-06.md`](docs/REALHW-ISSUE53-260827-06.md).

34/34 magics, `BATTERY-RESULT PASS` 12/12 — the first 12/12 in this project, `devmaptest`
included — then `burstloop11.sh 4`: **96/96** good sums, all ten anomaly patterns zero, and
**no wedge**, on the workload after which two of the four wedges happened. The DMA
prepare/complete block balanced exactly across 162 485 transactions with every must-stay-zero
counter at zero.

`a3w` after the burst: `calls` 598 868, `notours` 436 659, `own` 162 217, `ints_only` 162 217
(= `own` exactly), and **every other counter zero**, `a3d_n` included.

**`a3w_eint_only = 0`, and that governs how this may be reported.** `a3w_or_istr` is `0xfed3`
over all 598 868 entries: bit 5 was never set at any of them. The wrapper only changes behaviour
for an event it counts, so a zero count means **it changed nothing** — surviving the burst is
therefore not evidence that the fix works, and cannot be cited as such. Closing ISSUE-53 requires
`a3w_eint_only > 0`.

What is established: the wrapper is wired, its buckets are mutually exclusive and reconcile, it
never takes its loud path, and it does not break the disk under the heaviest workload here. And
the bound: whatever raises `INT_P` without `INTS` does not happen once in 162 217 A3091
interrupts — consistent with a wedge rate of a few per day, and with the audit's candidate being
a FLUSH completion that escapes `stopdma`'s own `CINT`.

**The next wedge is now worth having.** `a3w_dead_istr` will hold the entry `ISTR` of the
interrupt that kills the driver, which is what the four August captures could not produce.

### The undefined `ISTR` bits float on silicon

`a3w_last_istr` read `0x00d0`, `0xfed2`, `0xfed0`, `0x00d0` on successive samples: **bits 15–9,
which neither NetBSD's `ahscreg.h` nor Linux's `a3000.h` defines, read back sometimes zero and
sometimes one.** Bit 8 (`INTX`) is always zero, so it is implemented and they are not. In
Amiberry the upper byte is always zero.

The wrapper survives this only because its error test masks the three named sources (`0x010c`)
rather than whitelisting the documented bits. **Rewriting that mask as a whitelist would classify
a varying subset of every interrupt on silicon as unclassified, and would look perfect in the
emulator.**

---

## ✅ ISSUE-54 (2026-08-27, CONTAINED 2026-08-30): reading a device whose block size is not 512 no longer kills the A3091 driver

> **CLASSIFIED ON SILICON 2026-08-29, `68060-260829-07`** —
> [`docs/REALHW-ISSUE54-CLASSIFY-260829-07.md`](docs/REALHW-ISSUE54-CLASSIFY-260829-07.md).
> Ten predictions written before the run, ten held. The tuple the external audit asked for:
> **`cp=46 tc=0 di=43 con=8C as=0`, `op=28 rd=1 len=200`, `sac=971C1F0` inside the 512-byte
> envelope at `971C000`, `verdict=2`, `retry=0`.**
>
> `cp=0x46` with `tc=0` means **the data phase had finished**, not that it was interrupted
> mid-way. That overturns the premise of this ledger's earlier reasoning — `0x49` was read as
> "mid-data-phase, more to transfer", and the measurement says the count was exhausted and the
> command phase already held the value action 9 writes to resume *past* the data. The cursor
> agrees: 496 of 512 bytes, one SDMAC FIFO short of the end.
>
> **STAGE D WORKS 2026-08-30, `68060-260830-06`** —
> [`docs/REALHW-ISSUE54-STAGED-260830-06.md`](docs/REALHW-ISSUE54-STAGED-260830-06.md).
>
> ```
> a3p D RETIRED busfree=1 sent=1 ss=41 bytes=1536
> ```
>
> **`bytes=1536`** is 2048 − 512, the CD block's exact residual, and it was written into the
> predictions before the run as the number that would confirm the root cause independently.
> **No `a3091:` line at all** — `badhardware()` never ran.
>
> Twice, which is the difference between luck and a mechanism: `d_try 2, d_sent 2, d_busfree 2,
> d_failed 2`, and `d_quar = d_badphase = d_badstat = d_notowner = 0`. The CD returns
> `dd: read error: I/O error`, `CD=2`; the root disk returns `8+0 records`, `ROOT=0`.
>
> All eight of the design's falsification conditions reported individually in the record.
>
> **Contained, not solved.** The CD is still unreadable — no block-size support is added. `0x48`
> `DATA_OUT` and `0x4A` `CMD` remain unobserved and unhandled, target 4 is a tape and has never
> been touched, and `a2091.c` has the identical tables and defect.
>
> Cost: six hardware runs and four designs. The first three were implemented to specification and
> failed on silicon for reasons the specification did not anticipate. What made the fourth
> different was proving its primitive in a separate build that attempted no recovery at all.

> **STAGE P ACCEPTED 2026-08-30, `68060-260830-04`: 8/8** —
> [`docs/REALHW-ISSUE54-STAGEP-ACCEPTED-260830-04.md`](docs/REALHW-ISSUE54-STAGEP-ACCEPTED-260830-04.md).
> `got=1 tc=0`, `sac0 == sac`, `cp=46 di=43 con=0C`, `as2=80` proving `BSY` was clear for the
> gated reads. `COM=0x20` with `TC=1` in PIO transfers exactly one byte, decrements the count,
> touches neither phase nor direction, moves nothing through the SDMAC, and reports
> `XFERRED | DATA_IN`. **Stage D can be written on it.**

> **STAGE P 2026-08-30, `68060-260830-02`: the PIO discard primitive works** —
> [`docs/REALHW-ISSUE54-STAGEP-260830-02.md`](docs/REALHW-ISSUE54-STAGEP-260830-02.md).
> `a3p P got=1 ... byte=50`, `sac0 == sac`, `dmaon=0`, and on the next interrupt **`ss=0x19` =
> `XFERRED | DATA_IN`** — the WD's own statement that `COM=0x20` with `TC=1` transferred exactly
> one byte. Six of eight predictions held and the quarantine did its job: no root command was
> started, and the machine wedged where it was told to.
>
> ⚠ **`tc`, `cp`, `di` and `con` printed `FF` and are unmeasured, not failed.** `sbicreg.h`:
> `SBIC_ASR_BSY 0x20 — "Busy, only cmd/data/asr readable"`. They were captured with `BSY` still
> set. The evidence was in the same line: `as=0x21` is `DBR | BSY`. Fixed by waiting for `BSY`
> before the gated reads.

> **ATN MEASURED 2026-08-29, `68060-260829-15`: the target answers `DATA_IN`, not `MESSAGE OUT`** —
> [`docs/REALHW-ISSUE54-ATN-260829-15.md`](docs/REALHW-ISSUE54-ATN-260829-15.md).
> `a3p ATN-FAILED stage=5 as=80 ss=89 polls=1`. `SET_ATN` was asserted and accepted — no `LCI`,
> `CLR_ACK` issued — and the target's immediate reply was `0x89`, `MIS_2 | DATA_IN_PHASE`. It
> still has 1536 bytes of its 2048-byte block to send and ATN did not make it stop and listen.
>
> **The bound was not the problem** (`polls = 1`), which is only sayable because that build
> changed instrumentation and nothing else.
>
> Next is a design step, not an edit: the WD's `XFER_PAD` (`0x19`) consumes a data phase with no
> buffer, so draining the target's remainder would let it reach a boundary where ATN can be
> honoured. NetBSD loops until message-out appears and handles the phases in between, but says
> that code does not work. **Third time on this issue that the obvious next move was wrong when
> measured — it belongs in a contract first.**
>
> Meanwhile the `0x49` handling that worked in `-09`/`-11` is traded away, because the ATN path
> fails closed.

> **DISCRIMINATED 2026-08-29, `68060-260829-11`: verdict 7** —
> [`docs/REALHW-ISSUE54-DISCRIMINATOR-260829-11.md`](docs/REALHW-ISSUE54-DISCRIMINATOR-260829-11.md).
> Six of six predictions held. `a3p ss=41 cp=3A tc=800 di=46 as=0`, `sac == segpa`.
> **`CP=0x3A` means a new selection completed and target 6 accepted CDB bytes before the bus went
> free** — so the `0x41` belonged to the root disk's command, not to a late event from the CD.
> `tc` full and the DMA cursor unmoved: nothing transferred.
>
> That makes the ATN + Message Out `ABORT` path **necessary**, not merely protocol-correct: the
> target must be told to release, since a WD `Disconnect` only drops the initiator's own signals.
> It also disposes of the cheaper options — not a late CD event (`CP` says otherwise), not a case
> for waiting longer (`rel_exp = 0`, `polls = 1`), and not a case for reclassifying `0x41`, which
> is telling the truth about a command that really died.

> **FIX LANDED AND HALF-PROVEN 2026-08-29, `68060-260829-09`** —
> [`docs/REALHW-ISSUE54-FIX-260829-09.md`](docs/REALHW-ISSUE54-FIX-260829-09.md). Seven of ten
> predictions held. `dd` on the CD now returns `RC=2` and an I/O error instead of killing the
> controller, **and no `a3091: 0x49` line appears** — the fatal cell was not taken.
> `rel_try 1, rel_ok 1, fail 0, exp 0, polls 1`.
>
> **But the next command dies.** A root-disk read afterwards wedged the machine, and not the way
> this line predicted: the second event is `0x41` — *unexpected target bus free* — at `STARTING`,
> on the **root disk's** unit, not `0x85` at `IDLE`. `startany()` correctly began the next
> queued request and that command terminated with an unexpected bus free.
>
> **Chip-level acceptance is not proof the SCSI bus is free.** `ASR.BSY` is the WD's own state,
> not whether the CD is still asserting BSY with 1536 bytes it never got to send. And `0x41` is
> one of the two statuses the bus-release contract accepts as proof of a free bus while the
> driver's own `itab` calls it illegal — that contradiction is the next thing to resolve, in a
> contract before code.

> **CONFIRMED the same day.** Target 3 is a ZuluSCSI-emulated **CD-ROM** — a Civilization II
> disc — and a CD-ROM data block is **2048 bytes**. The driver assumes 512. Every number in the
> capture follows: it asked for 512, `tc` reached 0 with the target still in `DATA_IN` holding
> 1536 more bytes, `cp` read `0x46` because the count it was given was complete, and the
> mismatch is exactly `MIS_1|DATA_IN`. The 16-byte gap between `sac` and the end of the segment
> is the SDMAC FIFO.
>
> **This is why the heading changed.** It is not "any target": the defect needs a device whose
> block size is not 512, which is why the root disk has been fine for months. **ID 4 is a tape
> drive**, so `/dev/rdsk/c4d0s0` is a second trigger and touching it is equally destructive.
>
> **And it settles the fix.** Resuming is wrong — the driver's LBA arithmetic is in 512-byte
> units, so for this target it does not merely transfer the wrong amount, it addresses the wrong
> place; a "successful" read would be wrong data reported as good. Completing the command and
> keeping the first 512 bytes is wrong for the same reason. The correct behaviour is to **fail
> the request** — `cp->okay` is already FALSE and action 5 leaves it so — **and release the
> bus**, which the audit establishes action 5 does not do after `MIS_1`. So the fix is action
> 5's body plus a WD bus-release, and neither the resume nor the table change this line proposed.

> **Ledger: OPEN.** Root-caused from the driver's own tables and a console capture. **This was
> triggered deliberately-by-accident from this side** — see "How it was found" — which makes it
> the first A3091 shutdown in this project that is reproducible rather than observed.

Reading `/dev/rdsk/c3d0s0` — a raw device node for a SCSI target that does not hold a normal
disk — takes the whole machine down. Not intermittently. The root disk shares the controller,
so the driver's shutdown ends every disk-backed operation on the system.

### The capture, and the decode

    a3091dbg ss=49 istate=1 unit=8113460 head=0 dmaon=1
    a3091dbg segstate=2 segseq=161454 segpa=96C1800 seglen=200 segdir=1
    a3091dbg dev=DD0000 istr=1
    a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=161454
    a3091: 0x49 1 0x8113460

`unit=0x8113460` resolves to **`units[3]`** on this image — `units` is `.bss+0x3ce8`, and the
loader's own line gives the bases (`tvaddr=08000000 tsize=000f58f8 dvaddr=080f58f8
dsize=00019e50`), so `.bss` is `0x0810F748` and `units` is `0x08113430`. Remainder 0. SCSI
target 3 is exactly what was being read.

`0x49` is **`SBIC_CSR_MIS_1 | phase`** — a phase mismatch — by NetBSD's `sbicreg.h`
(`SBIC_CSR_MIS_1 = 0x48`, low bits carry the phase). A phase mismatch is an ordinary SCSI
condition; NetBSD's `sbic.c` handles it as routine.

> **Decoded fully 2026-08-29** — see
> [`docs/contracts/A3091-PHASE-MISMATCH-DFA-CONTRACT.md`](docs/contracts/A3091-PHASE-MISMATCH-DFA-CONTRACT.md).
> The phase is **`DATA_IN`** (`DATA_IN_PHASE = 1` in `sbicvar.h`), which the capture's
> `segdir=1` agrees with independently. And the defect has a precise shape: `a3091.c` handles
> `MIS_1 | STATUS_PHASE` (`0x4B`, action 9) and `MIS_1 | MESG_IN_PHASE` (`0x4F`, action 8), and
> is fatal for `0x48` `DATA_OUT`, `0x49` `DATA_IN` and `0x4A` `CMD`. **It has handling for
> exactly the mismatches that need none** — the ones where the command is already over — and
> dies on the three that mean there is more transfer to do. Two of the three fatal cells have
> never been observed and must be fixed in the same change.
>
> NetBSD treats `MIS_1|DATA_IN_PHASE` in the same case arm as a *successful* transfer and
> continues the data phase, so no reset is needed: the target is still connected. And action 9
> is not a reset either — it is NetBSD's *"have the sbic complete on its own"* sequence
> register for register (`TC = 0`, `CMD_PHASE = 0x46`, `SEL_ATN_XFER`), which is why routing the
> fatal phases there, rather than to the `0x42` abort, is the candidate fix. It reaches action 0
> and a genuine status byte; the abort path writes no status at all.

a3091.c does not. `itab[0x49]` is **1**, "status is illegal or unsupported", and
`atab[STARTING][1]` is **1** — `badhardware()`, `DEAD`, no way back:

| status | at state | input | action | |
|---|---|---|---|---|
| `0x49` phase mismatch | `STARTING` | 1 illegal/unsupported | **1 → DEAD** | this issue |
| `0x42` no such target | `STARTING` | 0 | 5 abort, start next | **the driver handles this** |
| `0x85` disconnect | `DEAD` | 3 | 1 → DEAD | the second capture: the DEAD row absorbing a normal event |
| `0x16` completed | `IDLE` | 8 | 1 → DEAD | ISSUE-53's four captures |

**So the driver anticipated an absent target and handles it gracefully, and dies on a phase
mismatch from a target that answered.** The second capture is a consequence, not a second
fault — every later input maps back to `DEAD` by construction.

### Why this is a different defect from ISSUE-53

Same family — "any status I do not recognise becomes permanent death" — and a different
instance. ISSUE-53's signature is `ss=0x16 istate=IDLE head=0 dmaon=0 segstate=0`: a status the
driver **does** know, arriving in a state where it makes no sense, with nothing in flight. This
one is `ss=0x49 istate=STARTING dmaon=1 segstate=2`: a status the driver does **not** know,
arriving mid-transfer, with a transfer genuinely armed. Nothing here is evidence about
ISSUE-53 and it must not be cited as such.

Our own DMA counters at the capture are consistent and clean: `segstate=2` (prepared) because a
transfer really was armed, `whole == segseq`, and `owned`/`noprep`/`ovf` all zero.

### One thing the wrapper told us by staying silent

`src/a3091demux040.s` prints `a3091demux: unclassified istr=...` for any `INT_P` it cannot
classify, capped at four lines. **No such line appeared.** So the entry `ISTR` of the killing
interrupt was classifiable — `INTS` set, a genuine WD interrupt — and the wrapper delegated it
correctly. That is read from the *absence* of output, which is only evidence because the print
exists and is known to reach the console.

### How it was found, which is not to anybody's credit

While checking whether a collaborator's cross-unit `a2091` lead could apply here, this line ran
`dd` against each SCSI target in turn to see which respond. Targets 0 and 1 answered, target 2
returned zero records, and target 3 killed the machine. **A probe that was meant to establish
whether a hypothesis was testable destroyed the running system instead**, costing a power cycle
and an `fsck`. Probing SCSI targets on this controller is not a read-only operation and should
be treated as a destructive test.

### And a mistake in this project's own instrument, worth keeping visible

`a3091demux040.s` latches the entry `ISTR` of the killing interrupt in `a3w_dead_istr`,
specifically so it can be classified. It was written and then **could not be read**, because the
wedge takes the root disk down and nothing can reach kernel memory afterwards.

`a3091dbg040.s`'s own header says exactly why, in this project's words, and was written before
the wrapper: *"A latched block would be perfect and unreachable."* The wrapper's most valuable
datum went into a latch anyway. Fixed by printing the entry snapshot beside the post-`SS` one:

    a3091dbg dev=%x istr=%x entry=%x

### The fix to the instrument shifted every counter address, and the magic word caught it

Lengthening the format string grew `.data`, so **every block below it moved** — `a3d` `0810E760`
→ `0810E76C`, `a3w` `0810E7D8` → `0810E7E4`, `scrfix` `0810E850` → `0810E85C`. The first read on
`-13` used the `-11` addresses and returned `20697374`, `723d2578`, `0a000000`, which is the
format string itself (`" istr=%x\n"`) read as three longwords. Entirely plausible numbers.

The magic check rejected it in one line, which is the whole argument for magic words made
concretely for the third time in two days — after `dma_*` (no magic, read out of `.text`, looked
like counters) and `Lkx_*` (no magic, no baseline). `test-tools/batteryrun-260827-13.sh` was
regenerated from `tools/status-facts.sh` output and every one of its 35 address lines
machine-checked against it, rather than edited by hand.

### Provoked on demand with full instrumentation, 2026-08-27, `68060-260827-13`

Eight predictions written before the trigger (`scratchpad/PRED-ISSUE54.md`); **eight held.**
`dd if=/dev/rdsk/c3d0s0 of=/dev/null bs=512 count=1`, after two `sync`s:

    a3091dbg ss=49 istate=1 unit=811346C head=0 dmaon=1
    a3091dbg segstate=2 segseq=5924 segpa=973C000 seglen=200 segdir=1
    a3091dbg dev=DD0000 istr=0 entry=D0
    a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=5924
    a3091: 0x49 1 0x811346C
    a3091dbg ss=85 istate=3 unit=811346C head=0 dmaon=1
    a3091dbg segstate=2 segseq=5924 segpa=973C000 seglen=200 segdir=1
    a3091dbg dev=DD0000 istr=FE00 entry=FED0
    a3091dbg zarm=0 rarm=0 owned=0 noprep=0 ovf=0 whole=5924
    a3091: 0x85 3 0x811346C

`unit=0x811346C` is the address predicted for `units[3]` on **this** image before the run, from
the loader's own `tsize`/`dsize` (`.bss 0810F754` + `0x3ce8` + 3×16). Exact. And
`seglen=200 segdir=1` is 512 bytes from the device — the `bs=512 count=1` that was issued. The
capture matches the command that caused it, field by field.

**`entry=D0` settles what the driver was actually handed.** `0xD0` is `INT_F | INTS | INT_P`:
a genuine WD interrupt. Not `E_INT`, not an error source, not an unclassifiable aggregate. So
ISSUE-54 is entirely the DFA's: the controller correctly reported a phase mismatch through a
legitimate interrupt, and the driver had no table entry for the status it carried.

**And `istr=0` beside it is the audit's "sampled too late" made visible in one line.** The
post-`SS` read shows *no bits at all* — reading SCSI Status cleared WD `INTRQ`, which cleared
`INTS`, which cleared the aggregate `INT_P`. Every earlier capture's `a3d_istr` was measuring
that, which is exactly why it could never classify anything. The second capture shows the same
transition against the floating upper bits: `entry=FED0` → `istr=FE00`, low byte gone, bits
15–9 still floating.

**The demux wrapper is exonerated for this class**, and now by direct reading rather than by
the absence of a console line: it saw `INTS`, delegated, and that was correct.

The discriminator ISSUE-53 needs is therefore **live and proven end to end**. If the
spontaneous wedge recurs, `entry=` will say whether it carried `INTS` — a genuine WD event, as
here — or `E_INT`, the audit's candidate. That was the whole purpose of the wrapper and it can
now be read off the screen of a machine that is otherwise dead.

### The print change is regression-clean on silicon

`68060-260827-13`, the image the provoked capture above was taken on, was then given the full
battery: **35/35 magics, `BATTERY-RESULT PASS` 12/12**, `scrfix` unchanged from `-11` (one console
plane at `0x00014000`, `misalign_n` 0), and every A3091 must-stay-zero counter at 0 across 232 166
level-2 interrupts. So the added `printf` argument is inert to everything else, and `-13` is a
sound base for the FPE merge rather than an untested one carrying a debug edit.

Log archived to NAS `amix/issue49-260827/battery-260827-13.log`.

### Fix, not yet written

The driver needs a default that is not death. The minimum honest change is to give
`badhardware` a distinguishable outcome for *unknown status at a live state* — abort the current
request and return to `IDLE`, as `atab[STARTING][0]` already does for an absent target — rather
than shutting the controller down for the lifetime of the boot. That is a real DFA change and
wants the same treatment ISSUE-53's got: a contract first, then a counter with a denominator.

---

## ✅ ISSUE-55 (2026-08-28, CLOSED 2026-08-30): the cross compiler this port ships with existed only as an uncommitted working-tree change

> **Ledger: CLOSED 2026-08-30.** `isoriano1968/gcc-cross-amix` merged the PR as `048e85c`. The
> chain is verified rather than assumed: upstream `main`'s `amix-gcc-wrapper.sh`, with `@TARGET@`
> substituted, is now **byte-identical** to the compiler installed on this build host, and a
> rebuild against it changes exactly **one byte** of `build/unix-040` — the build-id stamp.
>
> So a fresh clone following `BUILDING.md` now produces the compiler every hardware acceptance in
> this project came from. That was the whole of the issue.
>
> ⚠ **The wrapper is not finished, and that is a different matter.** A collaborator exercising it
> as a general C toolchain — cross-building a libc shim and GNU patch as SVR4 packages, rather
> than compiling a kernel — found four more defects and raised them as PR #3: the `bfffo`
> bit-field operands (a fifth SGS spelling; all eight `bf*` mnemonics still fail), `-E`
> unimplemented so `gcc -E` **links** and autoconf silently falls back to the build host's
> `/lib/cpp`, a named archive placed before the objects, and an explicit `-l` suppressing the
> implicit libc. None touch `-march` or the kernel path, which is why neither line saw them.
> The `-E` one is this project's favourite shape of defect: it fails nothing and mis-sets
> `HAVE_*` quietly.

`BUILDING.md` told a reader to build the toolchain from `isoriano1968/gcc-cross-amix`. Doing so
produced a **different compiler** from the one every kernel in this project was built with, and
therefore from the one behind every hardware acceptance recorded here.

The difference was **sixty-six lines** of assembler-syntax repairs in `amix-gcc-wrapper.sh`,
present only as an uncommitted working-tree change in one clone plus the installed copy under
`~/opt`. One `git checkout` in that clone would have destroyed them, and nothing anywhere would
have said what was lost.

### What they repair, and why nobody else hit them

The SGS assembly gcc 2.7.2.3 emits is not what this GNU `as` accepts. Compiling a six-function
probe at `-m68040` through the upstream wrapper, with each half of the repair present and absent:

| wrapper | assembler errors | object produced |
|---|---|---|
| upstream, neither half | 23 | no |
| spelling rules only | 11 | no |
| `-march` only | 15 | no |
| both | **0** | **yes** |

**Both halves are required and neither alone is enough.** The 8 → 11 in the third row is the
interesting number: repairing the spellings *uncovers* architecture errors, because a corrected
`fmovem.l` is itself a 68040 opcode that an assembler pinned at `-m68020` then refuses. The two
repairs are not independent, which is why the gate below tests the outcome rather than grepping
for either rule.

> **Correction, 2026-08-28.** This entry previously said the assembler "does not stop... so the
> failure mode is an object with instructions missing, not a build error", and quoted 17 dropped
> instructions from a ten-function sample. Both are wrong. `gas` words each rejection *statement
> ignored*, which reads like it carries on, but it exits 1 and writes no object — the failure is
> a build that stops. The earlier count came from running `as` directly rather than through the
> wrapper, which skips the `-m68020` pinning and so cannot see the architecture half at all. The
> table above replaces it: same tool, same path a build actually takes.

**All four repairs target constructs gcc emits only at `-m68040`.** At `-m68020` every one has a
count of zero. The stock wrapper hardcoded the assembler to `-m68020`, so 040 code could not be
assembled at all and the four defects stayed invisible — which is why the collaborating line
never met them either, despite compiling its own lane at `-m68040`: its twenty-two emulator
objects contain **no FPU instruction at all**, a software float emulator being the last code that
would emit `fsmul.s`. Letting the assembler follow `-march` is what exposes the other four; they
are one change and its consequences rather than five independent repairs.

Two further repairs of the same family were already upstream, and both are the quiet kind:
`tdivs.l` assembles to the 64-bit-dividend `divsl` (`4c42 1c00`) where gcc means the 32-bit
`divsll` (`4c42 1800`) — one bit of the extension word, and every `%` on 32-bit ints is wrong
whenever the stale high-half register is non-zero — and `.swbeg &N` emits **zero** bytes where
gcc laid the jump table out assuming four.

### Status

Committed in the clone and offered upstream: `isoriano1968/gcc-cross-amix`, from
`asokero:fixes-2026-08-asokero`, rebased onto current `main` and reconciled so each defect has
exactly one rule. Where both sides had one, **upstream's was kept** — its `tdivs` lookahead
matches every size where ours matched only `.l`, its `.swbeg` preserves the case count where ours
wrote zero, and its `cmp.[bwl]` is more correct than our `f?cmp.[bwlsdxp]`.

**The reconciliation is measured, not assumed.** Compiling the same C at `-m68020`, `-m68030` and
`-m68040` before and after, the objects differ by four bytes at every architecture, all of them
the `.swbeg` filler — bytes between an unconditional `jmp` and the table that are never executed.
68020 and 68030 code generation is untouched. The kernel also builds byte-identical, but that is
the weaker result and worth saying: `relink-040.sh` assembles hand-written `.s` files and compiles
no C, so it never emits a `.swbeg` at all.

**The recurrence is gated now.** `tools/cross-cc-verify.sh` compiles the probe above and requires
an object; `tools/check-env.sh` runs it beside the presence checks. Presence was checked here for
the whole life of the port and fitness never was, which is exactly how this survived. The gate is
a behaviour test rather than a checksum of the wrapper on purpose: a pinned hash fails on harmless
reformatting and has to be re-pinned whenever upstream moves, which teaches people to re-pin
without looking.

### What closes it

The upstream PR merging, this project updating its clone to that commit, and one rebuild
confirming the artifact is unchanged. Until then `BUILDING.md` carries the warning.

## ✅ ISSUE-56 (2026-08-29, FIXED same day): `relink-040-dbg.sh` could not build at all — two symbols the base image had started defining

> **Ledger: FIXED.** `relink-040-dbg.sh` now builds; `68040-260829-06`, `check_relink_relocs.py`
> reports `TOTAL complaints: 0`. Not hardware-run, because the fix removes two duplicate symbol
> definitions and changes no code.

The debug overlay had been unbuildable. Every run ended:

```
build/unix-040-dbg-stage1: In function `setregs_orig':
build/unix-040-dbg-stage1(.text+0x58b62): multiple definition of `setregs_orig'
build/unix-040-dbg-stage1(.text+0xae108): multiple definition of `as_fault_orig'
```

`relink-040-dbg.sh` added `setregs_orig=.text:0x58b62` and `as_fault_orig=.text:0xae108` with
`--add-symbol`, and the base image had begun defining both — at exactly those addresses —
in `a2aef0a` (the ISSUE-52 USP-handoff instrumentation). Nobody updated the overlay.

The script already knew this failure mode and had a comment about it for a different symbol:
*"hardbus_orig is INHERITED from the base image (no `--add-symbol` here — a second copy would
duplicate the symbol)."* The same thing happened twice more and the comment did not generalise
into a check.

**Fix:** drop the two `--add-symbol` clauses, keeping their `--weaken-symbol` partners. The
addresses were identical, so nothing is lost — the overlay now inherits both the way it already
inherited `hardbus_orig`.

### How long it had been broken, and why nothing said so

Unknown, and that is the finding worth keeping. `relink-040-dbg.sh` is not run by any gate:
`tools/check-env.sh` does not build anything, and `src/check_relink_relocs.py` is invoked by
`relink-040.sh` only. The base kernel builds clean, so every green run this session was green
while the debug lane was dead. It surfaced only because a session needed a `-dbg` image to boot
and found it could not make one.

**A related gap, left open deliberately:** `relink-040-dbg.sh` still never runs
`check_relink_relocs.py`. Adding it would not have caught this — a duplicate symbol is a link
error, not a relocation defect — so it is recorded here rather than fixed as if it were the
remedy.

## ✅ ISSUE-57 (2026-08-30, FIXED same day): `devmaptest` printed PASS on an A3640 having measured nothing

> **Ledger: FIXED and hardware-run.** `68040-260830-06` on an A3640/68040, 2026-08-30. Before the
> fix: `T1 SKIP`, `T2 SKIP`, `DEVMAPTEST-RESULT PASS`. After: probe settles on `0x07000000`,
> `T1 PASS`, `T2 PASS`, `fails=0 skips=0`. Evidence: `docs/REALHW-BATTERY-68040-260830.md`.

`devmaptest` is the twelfth row of the battery and the acceptance test for ISSUE-33's device-mmap
page geometry and ISSUE-49's `/dev/screen` fault path. Both of its cases need a physical address
that `/dev/mem` will map and whose content is distinctive, and both used the kernel load base for
it — written into the source as a constant:

```c
/* Physical 0x08000000 is the kernel load base on this machine, so this window
 * has DISTINCTIVE, non-zero content. */
base = 0x08000000;
```

**The load base is a property of the accelerator, not of the machine.** Every card this project
had used until 2026-08-30 carried its own RAM at `0x08000000`. An A3640 has none and the kernel
runs from A3000 motherboard RAM at `0x07000000`, where `0x08000000` is not memory at all. Both
`mmap()`s returned `ENXIO`, both cases took their `SKIP` return, and neither `SKIP` incremented
`fails` — so the program printed:

```
  T1 SKIP: mmap /dev/mem failed errno=6
  T2 SKIP: mmap failed errno=6
DEVMAPTEST fails=0
DEVMAPTEST-RESULT PASS
```

The battery driver greps for `DEVMAPTEST-RESULT PASS` and scored the row `ok`. The run reported
**12/12 on a 68040 for the first time in this project** and one of the twelve had measured
nothing.

### What gave it away

Not the battery, which was green. The serial log, which carried four lines the battery never
prints:

```
WARNING: DBG krnxflt FAILEXIT w=2 va=8000000 rw=1 depth=1
WARNING: DBG krnxflt FAILEXIT w=2 va=8000000 rw=1 depth=1
WARNING: DBG krnxflt FAILEXIT w=2 va=8000800 rw=1 depth=1
WARNING: DBG krnxflt FAILEXIT w=2 va=8000000 rw=1 depth=1
```

Three reads at `0x08000000` and one at `0x08000000+2048` — exactly `a`, `b` and `c` of T1 — denied
by this port's own fault instrument. The same instrument had printed the same shape a day earlier
for two `kpeek` reads at stale counter addresses, which is why the shape was recognised.

### Fix

`test-tools/devmaptest.c`:

* the base is **probed** rather than assumed. Candidates `0x08000000` then `0x07000000`, and a
  candidate is accepted only if it both maps **and** reads back non-zero — mappable-but-zero is
  the exact signature T1 exists to detect, so a base chosen on mappability alone could hand T1 a
  window in which its own discriminator can never fire. `devmaptest <hex>` forces a base for a
  machine neither candidate fits;
* **a skip is no longer a pass.** `skips` is counted alongside `fails` and the verdict is
  `DEVMAPTEST-RESULT PASS` only when both are zero. A check that reads nothing must not be able
  to print a verdict — the same rule the battery driver already applies to its own verdict log.

### Which earlier results this does and does not invalidate

**No 68060 acceptance is affected.** The defect needs a card with no RAM at `0x08000000`, and
every Mercury run had RAM there — including `68060-260827-06`, whose row in `STATUS.md` §1 claims
the first 12/12 battery in this project. That run mapped real memory and measured what it says it
measured. The only readings this invalidates are `devmaptest`'s on an A3640, and the only A3640
session before this one is 2026-08-13, whose acceptance record does not list `devmaptest` among
what it ran.

### What it cost, and what it did not

Nothing was wrong with the kernel. The measurement the row was supposed to make had simply never
been made on this card; with the fix it was made, and it passes: `T1` confirms a `base+2048`
device offset aliases to the same 4 KiB page, `T2` confirms `mincore` over a four-page device
mapping writes four entries and no more. That is ISSUE-33 and ISSUE-49's fault path measured on
68040 silicon for the first time.

### The family this belongs to

This is the third time a hard-coded `0x08000000` has been wrong, and the second time it was wrong
*silently*:

* **ISSUE-101** is the same constant in the other direction — `config()`'s memory-sizing fallback
  is `0x07000000`-shaped and silently wrong at load base `0x08000000`;
* `tools/status-facts.sh` takes the base as an argument for this reason, and its header says so;
* now `devmaptest`.

Any test that names a physical address should be assumed to carry this defect until it is read.
The remaining candidates in `test-tools/` are `fpenab060.c`, `fpimm60.c`, `ftunimp0.c`,
`isp61ea.c`, `isp61test.c`, `kdepthmax.c`, `kpeek.c`, `memwatch.c` and `proctest.c`. Three were
read while writing this entry: `kpeek` takes its address from `argv[1]` and is correct on any
card, though its header comment asserted the `0x08000000` base as fact and has been corrected;
`proctest`'s hit is a comment about user VAs at `0x80000000` and is unrelated. **The other six
have not been read and are not claimed to be correct here.**
