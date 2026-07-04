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
