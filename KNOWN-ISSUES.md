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
**Status:** OPEN (2026-07-04).  Only `build/unix-040-dbg` stubs hat_dup (via relink-040-dbg.sh);
the BASE `build/unix-040` links the stock 030 hat_dup, whose 8-byte-descriptor tree walk is
garbage on 040.  Interactive login works on the *dbg* build because the stub avoids it, but any
real fork COW / user-fork path needs a proper `hat_dup040` (mirror hat_pteload/hat_free040: 4-byte
descs, va>>25/>>18/>>12 indices).  This is the main thing standing between "dbg build logs in" and
"clean base multi-user boot".  Related pending 040 ports: hat_chgprot ×6 (COW write-protect),
hat_exec (exec stack move — currently neutered by the hat_free040/hat_chgprot040 garbage-slot
guards), uvirtophys/uvatosde (user SW page-table walkers).  Full batch list: RESUME-HERE.md.

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

## ISSUE-7: u-area corruption at login-after-reboot — `u_procp=0` → wild jump / bus-error (OPEN, deeply characterized)
**Status: OPEN (2026-07-06), extensively narrowed but ROOT NOT YET FOUND. Documented for
resume; the system is USABLE (a clean boot + login + `ls -alR` + reboot succeeds; only a
SECOND boot from a kernel-contaminated disk crashes at the login prompt).**

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

### RESUME POINTS (next measurements to try)
- Instrument `setuctxt` EXIT + the kmem_alloc(KM_SLEEP) window (0x41978): read
  `*(cp->p_segu+0x730)` after the write and after the sleep — does the page/u_procp survive
  the sleep?  (Codex timing hypothesis #1.)
- Add a `segu_softload` marker (only softunload was instrumented) + a `segu_get` per-proc
  (cp→p_segu→page pfn) marker to trace the u-area PAGE lifecycle and catch when p_segu's
  backing page becomes a fresh-zero page.
- Codex to statically analyze the segu/u-area page lifecycle + a whole-kernel-vs-source
  audit (analysis/ dir) — likely the fastest path given how resistant this is to probing.
