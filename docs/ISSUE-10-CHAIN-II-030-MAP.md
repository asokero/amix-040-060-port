# ISSUE-10 chain (II): source-first PTE-registration audit + retained-030 code map

> **STATUS 2026-07-18: sections below are historical trail. Current frontier = the memwatch
> hunt in KNOWN-ISSUES.md (kvseg buffer PTE holds wrong PFN; KMA double-backing PRIME).**

**2026-07-15 night.** After the reliable repro + smoking gun (disk-read ELF reuse,
`6e4449b`) and the hat_pagesync040 test that ruled out chain (I) (`1ae680a`), this maps
where chain (II) lives, grounded in the Codex `amix-kernel-analysis/vm-map/` audits
(authoritative — they diff the exact AMIX objects, not just the 3b2 source).

## The invariant (Codex `P-MAPPING-MATRIX.md`)

```
valid managed PTE  <->  exactly one correct pp->p_mapping entry
```
Two failure modes flow from breaking it:
- a **stale phantom** entry prevents reclaim (page kept mapped-looking);
- a **missing live** entry permits free/reuse while a PTE is still resident. ← **chain (II)**.

## Why our corruption is a MISSING-live-entry (chain II), pinned to the observation

Repro serial (build 260715-16 and unchanged on the hat_pagesync040 build 260715-18):
- `hat_pageunload CALLED on crash page pp=400AA2C0 p_mapping=<non-zero>` fires immediately
  before the fault → the reclaim/free path DID walk a non-empty chain and clear its PTEs.
- Yet the victim (`cp`/`sh`) still **successfully reads** the reused frame (BUS ERROR on a
  garbage *pointer read from its heap*, `4AFC005F`, not a page fault) → the victim still had
  a **working live 040 PTE** to that physical frame.
- `Lhl_findfail` ("pte not in revmap") = 0 throughout.

Therefore the victim's live 040 PTE was **not in the freed page's `p_mapping` chain** — a
missing-live-entry. hat_pageunload cleared whatever WAS in the chain, but not the victim's
mapping, so free+reuse left the victim reading the disk-read ELF content.

## Retained STOCK-030 HAT/VM code that can touch this (ranked)

Overridden-to-040 (safe producers/removers): `hat_pteload`, `hat_dup040`, `hat_unload`,
`hat_free`, `hat_pageunload`, `hat_chgprot`, `hat_alloc`, `hat_ptfree`, `hat_unlock`,
`hat_pagesync` (ported this session, `f2767aa`).

Still **stock 030** and able to break the invariant (from `P-MAPPING-MATRIX.md` + the
per-op audits):

| Rank | Symbol | addr | 030 hazard for chain II | reachable in repro? |
|---|---|---|---|---|
| 1 | `hat_ptalloc_orig` / `hat_sdtalloc` | 0xb688e / 0xb632e | `p_mapping` **ALIAS** (`p_ptdats`/`p_sdtbits`) writes to the SAME offset-32 field. A physical page used as BOTH a data page AND a HAT table/SDT page has conflicting meanings → a data page's reverse-map head can be scribbled, or a table page can look like a mapped data page. The prime **phys-double-use** vector (ISSUE-5/6 family). `HAT-PTALLOC-AUDIT.md`, `HAT-SDT-ALLOC-FREE-POLICY.md`. | yes — every exec/fork grows page tables under pressure |
| 2 | `hat_exec` | 0xb6f20 | UNPORTED except an 8-byte root-load patch; "all section/segment/page/SDE/PTE/ptdat arithmetic is still 030" (`HAT-EXEC-AUDIT.md`). Zero-flag fallback "can copy/move old PTEs on old geometry" → can publish/leave a non-registered mapping (`HAT-EXEC-POLICY.md` recommends blocking/diagnosing it). | yes — exec on every cp/sh/expr |
| 3 | `hat_swapout` | stock | old SDT/PTE tree walk, "does not match live 040 mappings" — unlinks by the wrong tree. | maybe — process swapper `sched` is disabled, but verify no other caller |
| 4 | `relvm`/`as_free`/`as_exec`/`hat_asload`/`segvn_unmap` | stock 030 | AS teardown drivers; NOT overridden. They should route real PTE work through the ported `hat_unload`/`hat_free`, but the 030 driver arithmetic (SDE/ptdat) around those calls is unaudited for VA/range correctness on the 040 tree. | yes — relvm on every exec, as_free on every exit |
| — | `hat_map` | 0xb58d2 | phantom-preload producer — **VERIFIED STILL DISABLED** (braw at 0xb58d2, 317944f). Not a current producer. | no |

## Structural root (Codex, incompatibility #2)

> VA-based cleanup (`hat_unload`/`hat_free`, walk the live 040 A/B/C tree) and page-based
> cleanup (`hat_pageunload`, walk the raw `p_mapping` chain) "can disagree about whether a
> page is fully retired." Neither is a complete GC for the other's entries.

So a live 040 user PTE that was established/moved by a retained-030 path (or whose page
struct is aliased by hat_ptalloc/sdtalloc) can be **absent from the page's chain** yet
**present in the live 040 tree** — page-based free (pvn_done/page_abort → hat_pageunload)
misses it, and VA-based cleanup never ran for that page.

## Next step (Codex-recommended, richer than a bare p_mapping!=0 probe)

`P-MAPPING-MATRIX.md` practical conclusion: *"every crash involving unexpected page reuse,
page_free, page_abort, RSS drift, or pageout should log BOTH the PTE value and the provenance
of the p_mapping entry, not merely whether p_mapping is zero."* So the chain-II probe should,
at `page_get` free-list reuse (or page_free), **walk the live 040 tree for any PTE whose pfn
== the reused frame** (not just check the chain) and dump {pfn, VA, owning table, PTE value}.
A hit that is NOT in the page's `p_mapping` chain proves the missing-live-entry and names the
producer. Cheapest confirming source-first move first: audit #1 (hat_ptalloc/sdtalloc
alias-vs-data-page double-use) and #2 (hat_exec zero-flag fallback reachability) before
writing the probe.

## Audit #1 RESULT (2026-07-15 night) — concrete culprit: `hat_exec_orig` flag-0 steal path

Followed the hat_ptalloc/sdtalloc thread (Codex `HAT-PTALLOC-AUDIT.md` + binary). Findings:
- `hat_ptalloc` callers: `hat_pteload`/`hat_dup040` pass flag **2/3 = HAT_NOSTEAL** (no steal).
  **Only `hat_exec_orig` passes flag 0** (verified @0xb7232 `clrl %sp@-`) = steal ALLOWED
  (HAT_CANWAIT does not disable stealing; only HAT_NOSTEAL does).
- The `hat_ptalloc` **steal path is entirely UNPATCHED 030**: 8-byte SDE arithmetic
  (0xb6b52/72), 21-bit PFN extract (0xb6bb2), 2 KiB VA step (0xb6c62). On the 040 it walks the
  inert 030 tree and does NOT clear the live 040 PTEs of the stolen table's mapped pages.
- The steal victim is **any unlocked table in `active_pts`, not the exec'ing stack** — so it can
  steal `cp`/`sh`'s HEAP page-table, 030-unlink it (wrong), and leave that process's heap pages
  with **live 040 PTEs orphaned from `p_mapping`** → free/reuse → the observed corruption. This
  explains why a stack-transfer optimization corrupts heap pages, and why it needs BOTH heavy
  exec (steal trigger) AND memory pressure (normal alloc fails → steal fallback).
- **The steal cannot simply be blocked:** on `hat_ptalloc`==NULL, `hat_exec` calls
  `cmn_err(CE_PANIC)` (0xb7250, `pea 3`). So steal is how it dodges the panic under pressure;
  forcing NOSTEAL trades corruption for a panic.

**FIX (Codex `HAT-EXEC-POLICY`-endorsed): make `hat_exec` a no-op returning 0.** It is a pure
stack-page-table-move OPTIMIZATION; `as_exec` already moves the seg object (data ownership is on
the seg, not the PTEs), `relvm` tears down the old AS, and the moved stack's translations rebuild
via 040 faults through `hat_pteload`. A no-op never calls `hat_ptalloc` → no steal, no panic.
Strictly safer than today (removes both the corruption vector and the NULL-panic). Testable
against the reliable repro.

## Audit #1 FIX TESTED → REFUTED (2026-07-15 night, build 260715-20, commit e6b5e46)

Built the no-op `hat_exec` (`src/hat_exec040.s`, `--weaken-symbol hat_exec`), booted
emu-040 clean to login (exec exercised heavily by init/getty/login/print-services — no-op does
NOT break exec), then ran the reliable 4-burst `issue10-pressure.sh` repro (6×4 MiB cp +
`hat_dup_cow 64`, ×4).

**Result: corruption reproduced IDENTICALLY.** Same crash page `pp=400AA2C0`, same
`hat_pageunload CALLED … p_mapping=9CDC0C8`, same `User BUS ERROR at 4AFC005F`, same
`SEGVDMP p0=7F454C46` (`\x7fELF`) — the reused frame even shows a libc `.dynstr`
(`exit`/`_xmknod`/`write` symbol strings) from a concurrent segmap/exec disk-read. Then it
degrades into a tight respawn crash-loop (`BUS ERROR at 5C313595` ×6316, ~80 % host CPU).
Evidence: `test-tools/issue10-noexec-negative-260715.txt`.

**Conclusion: hat_exec's flag-0 steal is NOT the producer of the missing-live-entry.** The
no-op removes the steal path (and the NULL→CE_PANIC branch) entirely, yet the identical
chain-II corruption persists. Audit #1's hypothesis is refuted.

The no-op hat_exec is **KEPT** anyway — a Codex `HAT-EXEC-POLICY`-endorsed safety hardening
(removes an unported-030 stack-PT-move optimization and its NULL-panic branch, boots clean) —
but **relabelled: safety hardening, NOT the ISSUE-10 fix.**

**Surviving chain-II suspects (re-ranked after refutation):**
1. `hat_ptalloc_orig` / `hat_sdtalloc` **p_mapping ALIAS** phys-double-use (still reachable on
   every exec/fork table-grow, independent of the removed steal path).
2. Structural VA-vs-page GC mismatch (Codex incompatibility #2): a live 040 PTE established/moved
   by a retained-030 driver (`relvm`/`as_free`/`as_exec`/`hat_asload`/`segvn_unmap`) absent from
   the page's `p_mapping` chain → page-based free (pvn_done/page_abort→hat_pageunload) misses it.
3. Coherency/ordering (cpusha/pflusha) leaving a stale TLB/cache copy of a freed frame.

**Recommended next move (per KNOWN-ISSUES strategy — stop patch-guessing):** the DIRECT
free-time invariant probe (`ISSUE-10-FREETIME-PROBE-SPEC.md`) — at `page_free`/`page_get`
free-list reuse, walk the live 040 tree for ANY PTE whose pfn == the reused frame and dump
{pfn, VA, owning table, PTE value, in-chain?}. A hit NOT in the chain proves the
missing-live-entry and *names the producer* — cheaper and more conclusive than testing
suspects 1–3 one patch at a time.

## Chain-II SEGVCHAIN probe DEPLOYED — correct + safe, but repro morphology blocks capture (2026-07-16)

Built the victim-context reverse-map probe (`src/sigkill_dbg.s`, commit `cc21ff7`,
builds 260715-21/-22). On a SIGSEGV whose saved-`a0` URP walk reaches a **resident leaf**
(the sh-heap double-use morphology), after the existing SEGVDMP/SEGVPP dump it walks
`pp->p_mapping` and reports:

```
DBG SEGVCHAIN cnt=<nodes> in=<1=found|0=MISSING> head=<p_mapping> vpte=<victim &leaf> hpte=<*head>
```

`in=0` with a valid `vpte` = the missing-live-entry proof. Verified: the chain stores the
**physical** `&leaf` (`hat040.s:461` links `%a4`, derived from `%urp`), and the crash walk
computes the victim `&leaf` from the same `%urp` phys-identity space → address compare is
exact. All chain derefs are phys-range gated (top nibble 0, 4-byte aligned) + capped 16 nodes.
Cap split (Lsg_n=8 diagnostic, consumed only on resident-leaf; Lsg_bn=4 for walk-bail) so an
init crash-loop can't drain the budget or flood serial. Boots clean; reloc check 0.

**Blocker — repro morphology.** Three emu-040 runs:
- full 6×4 MiB `issue10-pressure.sh` ×2 (builds -21, -22): both escalated to **/sbin/init
  PID 1 control-flow corruption** — `BUS ERROR at C0800084, PC:E, a0=FFFFFFFF, pte=0,
  cell=DEADDEAD` in a tight 80 000× kernel-NOTICE loop. init's corrupted datum is a *code
  pointer / return address*, not a walkable heap cell, so the URP walk bails → **no SEGVDMP /
  SEGVPP / SEGVCHAIN**. The cap split worked (only 4 bail SEGVCTX; no probe flood).
- fork-heavy / light-cp `forkpress.sh` ×1 (build -22): **no corruption at all** — 4 bursts
  `ALLBURSTS-OK`, forks to pid 3372 clean. ⇒ the double-use needs the heavy 6-cp reclaim
  pressure; lighter pressure doesn't fire it.

So the classic sh-heap `4AFC005F` morphology (reliable on the pre-probe build 260715-20) did
**not** recur on the probe builds — the heavy-pressure victim keeps landing on init. The probe
is correct and staged; it will answer IN-vs-MISSING the moment a resident-leaf user-heap fault
occurs. Two ways forward:

1. **Grind full-pressure runs** for the sh-heap morphology (variance; it was the norm
   pre-probe). Cheapest, no new code, but each run = reset-boot (~3 min) + tftp (~70 s).
2. **Morphology-independent producer-side probe** — catch the double-use at page reuse
   regardless of how it later crashes. Robust but heavier: needs either an all-AS reverse
   scan at `page_free`/`page_get` (expensive per free) or a pfn→pte side-table shadow of
   `hat_pteload`/`hat_unload`. This is the durable instrument if grinding doesn't land it.

Evidence: `test-tools/issue10-initmorph-260716.txt`.

## ★★★ SEGVCHAIN HIT — chain-II REFUTED, it's a DOUBLE-REGISTERED frame (2026-07-16)

A grind run (build 260715-22) finally landed the **sh-heap morphology** (4× `4AFC005F`
cp victims + sh `5C313595`; **zero** init-`C0800084` this run) and the probe fired 8×.
Result (`test-tools/issue10-segvchain-260716.txt`):

```
DBG SEGVPP  pp=400A8F88 flg=200 vn=40121658 off=0 map=8E49000 uown=0
DBG SEGVCHAIN cnt=6 in=1 head=8E49000 vpte=8D56000 hpte=9DC700D
DBG SEGVCHAIN cnt=5 in=1 head=8E49000 vpte=8C16000 hpte=9DC700D   <- vpte != head, in=1
...
DBG SEGVPP  pp=400A9FF0 flg=200 vn=40120EE8 off=0 map=8AB3000 uown=0
DBG SEGVCHAIN cnt=4 in=1 head=8AB3000 vpte=8AB3000 hpte=9E0D00D
```

**`in=1` in ALL 8** — including rows where `vpte != head` (the probe walked the chain and
found the victim mid-list, so the compare is genuinely working). **The victim's live-040
PTE IS in the freed page's `p_mapping` chain.** ⇒ **chain-II "missing-live-entry" is
REFUTED.** The reverse map is intact.

What the crash actually is (from SEGVPP): the frame has **`p_vnode != 0, off=0`** (a file's
first page — the ELF header, matching the `\x7fELF` SEGVDMP) **and simultaneously** the
victim's user-anon heap PTE in its chain. `hpte=…00D` decodes to a **live-040** PTE
(`pfn<<12`, status W|U), not a legacy phantom. Two distinct page_ts showed it
(`400A8F88`/vn=`40121658`, `400A9FF0`/vn=`40120EE8`).

**So the bug is a DOUBLE-REGISTERED frame, not a reverse-map leak:** one physical frame is
concurrently a **file vnode-cache page** (`p_vnode`/`p_offset` set) and a **user-anon heap
page** (live PTE, intact chain). The frame reached page reuse / a vnode disk-read **while a
live user-anon mapping still owned it** — exactly the original ISSUE-10 sentence, now proven
to be a page-allocation / vnode-cache-lifetime fault, **not** a `hat_pageunload`/`p_mapping`
fault. This retires the whole chain-II suspect list (hat_ptalloc alias, VA-vs-page GC,
cpusha) as the *primary* line.

**New direction — page/vnode lifetime (ISSUE-5/6 phys double-use):** how does one page_t end
up both vnode-hashed (`p_vnode` set) and user-anon-mapped? Two orderings:
(A) a vnode-cache page is freed to the free list without clearing `p_vnode`, then `page_get`
hands it to anon; (B) a live user-anon page is handed to `page_get`/`vnode-getpage` for the
disk read (which sets `p_vnode` and reads the ELF over it) — the victim then reads the ELF.
`page_free`/`page_abort` panic on `p_mapping != 0`, and the chain is intact here, so the
frame must reach reuse by a path that **bypasses that gate** (or `hat_pteload` linked the
victim PTE only after the vnode read). Audit targets: `page_get`/`page_free` free-list +
`page_lookup`/vnode hash lifetime, `PAGE-ABORT-FREE-CONTRACT.md`,
`VOP-GETPAGE-PAGEIN-CONTRACT.md`, `SEGMAP-HAT-STALE-WINDOW-AUDIT.md`,
`ANON-SWAP-PAGEIN-CONTRACT.md`. The SEGVCHAIN/SEGVPP probe stays in `sigkill_dbg.s` as the
live confirmator.

Cross-refs: `P-MAPPING-MATRIX.md`, `HAT-EXEC-AUDIT.md`/`HAT-EXEC-POLICY.md`,
`HAT-PTALLOC-AUDIT.md`, `HAT-MAP-AUDIT.md`/`HAT-MAP-POLICY.md`, `PAGE-ABORT-FREE-CONTRACT.md`,
`REFMOD-PAGEOUT-CONTRACT.md`, `HAT-UNLOAD-COHERENCY-AUDIT.md` (all in
`amix-kernel-analysis/vm-map/`).
