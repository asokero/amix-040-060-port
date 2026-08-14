# hat_map 040 fix — approach investigation (2026-07-07)

> **STATUS: Option A IMPLEMENTED (commit 9b7f00c), awaiting boot test.** Patch added to
> `patch_pmmu_040.py` at 0xb58d2 (`67`→`60`, beqw→braw); byte-verified present in all three
> kernels; 0 reloc complaints. The rest of this doc is the original decision record.

Investigation of how to fix the `hat_map` phantom-PTE bug that Codex's
`docs/contracts/P-MAPPING-MATRIX.md` documented. **This is a
decision/plan doc, not yet implemented.** All addresses/bytes below independently verified
against `build/unix-040-dbg` disassembly (not taken from the audit on trust).

## The bug (one line)

Retained stock `hat_map` (0xb57e0, only 8 bytes ported so far = the fork URP load) writes
**legacy `pfn<<11` "phantom" PTEs** into `pp->p_mapping` reverse-map chains during
file-backed segment preload, while `hat_pteload`/`hat_dup040` write **live `pfn<<12`** PTEs
into the *same* chains. No consumer can tell the two formats apart → the mixed chain breaks
the invariant "every live managed PTE ⇔ exactly one same-format p_mapping entry."

## hat_map structure (verified)

Two phases, split at the preload gate 0xb58ce:

1. **Growth + URP phase (0xb57e0–0xb58cc) — MUST KEEP.** Computes section/newnseg, calls
   `hat_growsdt` if the legacy SDT limit grew, then at **0xb58c6 does `movec %a0,%urp`** —
   this is the fork-path address-space root load, "reached for the FIRST time" per
   patch_pmmu_040.py:58, i.e. **load-bearing for fork**. Followed by pflusha (0xb58ca).
   This phase does NOT touch p_mapping.
2. **Preload phase (0xb58ce–0xb5cf2) — the phantom producer.** Gate at 0xb58ce:
   `tstl fp@(12)` (ppl==NULL?) / `tstl fp@(24)&0x10` (preload flag?). If either fails →
   0xb58e6 (`clrl %d0; braw 0xb5cf8` = return success). Otherwise the vnode-page loop writes
   `(pfn<<11)|status` PTEs (shift built at 0xb5c10 `moveq #11 / lsll`) and links them into
   `pp->p_mapping` at 0xb5c3e (`movel %a4,%a3@(32)`). Tail at 0xb5cf8.

## Callers (verified via reloc scan)

Only two: `segdev_create` (0xa7a48) and `segvn_create` (0xaacc2).
- `segdev_create` pushes **ppl=NULL AND flags=0** (0xa7a44/0xa7a38) → it ALREADY takes the
  no-preload path today. **Unaffected by disabling preload.**
- `segvn_create` is the only caller that can enter preload, and only for a file-backed
  segment whose pages are already resident + the 0x10 preload flag. This is the sole site
  the fix touches.

## Option A — disable the preload loop (RECOMMENDED)

**One-byte patch.** At 0xb58d2 (file offset 0xb5906) the gate is `6700 0012` (`beqw
0xb58e6`). Change the first byte `0x67`→`0x60` → `6000 0012` (`braw 0xb58e6`): unconditionally
skip preload and return success. The preceding `tstl fp@(12)` at 0xb58ce becomes dead but
harmless.

Why this is correct and safe:
- **Preserves the load-bearing URP reload** (0xb58c6, before the gate) and the whole growth
  phase — fork is unaffected.
- **Functionally equivalent on 040.** Preload is a stock-030 optimization: pre-map
  already-resident file pages so the first access doesn't fault. On 040 the preload produces
  NO usable hardware translation anyway (audit: it never builds the A/B/C path), so the
  access faults regardless and `hat_pteload` builds the identical live mapping on demand.
  Disabling preload just goes straight to the demand-fault path the kernel already relies on
  (anonymous segments — the majority — already have no page list and always demand-fault).
- **Removes, not just hides, three audit findings at once:** the phantom-PTE chain
  contamination (restores the one-format invariant, which also de-fangs the
  hat_pagesync/hat_swapout mixed-chain misdecode — they'd then only ever see live entries),
  the RSS/pt_inuse double-count (preload increments once, the later real fault again), and
  the "phantom preload pulls cache pages off the free list without avoiding a fault."
- **Risk: very low.** Does not touch the live 040 tree code, the URP reload, or any
  allocator. Same byte-patch mechanism already used on hat_map (patch_pmmu_040.py).

Cost: a one-time first-access fault for file pages that were already cache-resident — minor,
per-page, and already the behavior for nearly everything else.

Does NOT address: the growth phase's separate "false root descriptors in section-2/3 slots"
concern (HAT-GROWSDT-AUDIT) — that is a different, non-p_mapping issue and must be evaluated
on its own (and is riskier, since the growth phase carries the fork URP load). Out of scope
for the p_mapping-matrix fix.

## Option B — port the preload loop to real 040 PTEs (NOT recommended)

Rewrite the ~0x406-byte preload loop (0xb58ec–0xb5cf2) to, per resident page: walk/allocate
the A/B/C tree for the real VA (root[va>>25]→ptr→leaf, allocating pointer+leaf tables if
absent), write `(pfn<<12)|status`, link with the +256 convention, and cpusha/pflusha at the
end. This is essentially calling `hat_pteload`/`hat_memload` per page — i.e. a
full-function override on the scale of the `hat_dup040` port, not a byte patch.

Why not:
- **No functional benefit over Option A on 040:** the mapping it would build is byte-for-byte
  the one demand-faulting already builds via hat_pteload. It only re-adds a stock 030
  latency optimization, at the cost of a large new hand-written asm surface to get right.
- **Higher risk:** new tree-walk/alloc code in a hot path, more to test, for zero
  correctness gain the demand-fault path doesn't already provide.

Option B would only make sense if profiling later showed first-access fault storms on
file-backed segments were a real performance problem — no evidence of that today.

## Recommendation

**Option A** (1-byte preload-disable at 0xb58d2), added to the byte-patch set the same way
hat_map's URP patch is applied. Verify after build: 0xb58d2 reads `60 00 00 12`, and a boot
still reaches login + runs a fork/exec workload (the demand-fault path is exercised
constantly, so any regression would surface immediately). The `hat_pteload`/`hat_dup040`
side is unchanged, so p_mapping chains become single-format (live 040 only) from every
producer.

Not yet implemented — awaiting go-ahead.
