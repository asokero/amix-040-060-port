# ISSUE-10 chain (II): source-first PTE-registration audit + retained-030 code map

**2026-07-15 night.** After the reliable repro + smoking gun (disk-read ELF reuse,
`b5e856a`) and the hat_pagesync040 test that ruled out chain (I) (`81779a3`), this maps
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
`hat_pagesync` (ported this session, `4833ae6`).

Still **stock 030** and able to break the invariant (from `P-MAPPING-MATRIX.md` + the
per-op audits):

| Rank | Symbol | addr | 030 hazard for chain II | reachable in repro? |
|---|---|---|---|---|
| 1 | `hat_ptalloc_orig` / `hat_sdtalloc` | 0xb688e / 0xb632e | `p_mapping` **ALIAS** (`p_ptdats`/`p_sdtbits`) writes to the SAME offset-32 field. A physical page used as BOTH a data page AND a HAT table/SDT page has conflicting meanings → a data page's reverse-map head can be scribbled, or a table page can look like a mapped data page. The prime **phys-double-use** vector (ISSUE-5/6 family). `HAT-PTALLOC-AUDIT.md`, `HAT-SDT-ALLOC-FREE-POLICY.md`. | yes — every exec/fork grows page tables under pressure |
| 2 | `hat_exec` | 0xb6f20 | UNPORTED except an 8-byte root-load patch; "all section/segment/page/SDE/PTE/ptdat arithmetic is still 030" (`HAT-EXEC-AUDIT.md`). Zero-flag fallback "can copy/move old PTEs on old geometry" → can publish/leave a non-registered mapping (`HAT-EXEC-POLICY.md` recommends blocking/diagnosing it). | yes — exec on every cp/sh/expr |
| 3 | `hat_swapout` | stock | old SDT/PTE tree walk, "does not match live 040 mappings" — unlinks by the wrong tree. | maybe — process swapper `sched` is disabled, but verify no other caller |
| 4 | `relvm`/`as_free`/`as_exec`/`hat_asload`/`segvn_unmap` | stock 030 | AS teardown drivers; NOT overridden. They should route real PTE work through the ported `hat_unload`/`hat_free`, but the 030 driver arithmetic (SDE/ptdat) around those calls is unaudited for VA/range correctness on the 040 tree. | yes — relvm on every exec, as_free on every exit |
| — | `hat_map` | 0xb58d2 | phantom-preload producer — **VERIFIED STILL DISABLED** (braw at 0xb58d2, 9b7f00c). Not a current producer. | no |

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

Cross-refs: `P-MAPPING-MATRIX.md`, `HAT-EXEC-AUDIT.md`/`HAT-EXEC-POLICY.md`,
`HAT-PTALLOC-AUDIT.md`, `HAT-MAP-AUDIT.md`/`HAT-MAP-POLICY.md`, `PAGE-ABORT-FREE-CONTRACT.md`,
`REFMOD-PAGEOUT-CONTRACT.md`, `HAT-UNLOAD-COHERENCY-AUDIT.md` (all in
`amix-kernel-analysis/vm-map/`).
