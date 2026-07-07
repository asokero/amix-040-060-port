# hat_exec 040 — RE findings + fix plan (2026-07-07)

RE/scoping of the `hat_exec` port (the last major unported HAT function), prompted by
Codex's `analysis/vm-map/HAT-EXEC-AUDIT.md`. **This is a plan + finding doc, not implemented.**
All claims below independently verified against `build/unix-040-dbg` disassembly.

## Headline finding: hat_exec is currently INERT + DEFANGED, not an active bug — DEPRIORITIZE

Contrary to the earlier "still runs stock-030 code on every exec, needs porting" framing,
`hat_exec` is not causing an observed problem in the current build:

1. **Fast path (hatflag=1, the OBSERVED case) moves no live 040 mapping.** The exec stack is
   anonymous → no vnode preload → its legacy source SDEs are invalid → the fast loop skips
   them all. It only grows legacy SDT storage and writes false section descriptors into root
   slots A4..A7. The real stack mapping stays in oas, is torn down by `relvm`, and is rebuilt
   in nas by demand fault. (Audit + runtime bracket agree; the bracket showed no corruption.)
2. **The false root descriptors (`0x003f0002/3` family, apparent base `0x003f0000`) are
   ALREADY DEFANGED.** Verified: `0x003f0000>>12 = 1008`, far below the kernel-base guard
   bound `_start>>12 = 0x7000 (28672)` that every ported 040 walker (hat_free040 /
   hat_unload040 / hat_chgprot040 / hat_dup040 V2.2/V2.3 guards) uses to reject a descriptor
   whose pointer-table base lies below the kernel image. So a root scan hitting A4..A7 treats
   them as ABSENT — no bogus deref.
3. **The slow path (hatflag=0) is not currently hit** (execstk_addr returns hatflag=1 for the
   observed stack holes).

So `hat_exec`'s only current cost is wasted per-exec legacy SDT allocation/scan + a redundant
URP reload — memory/cycles, not correctness. **It is lower priority than hat_dup/hat_map were.**

## Why it's still worth doing eventually (just not urgently)

- Removes per-exec legacy `hat_growsdt` allocation + SDT scan (pure waste on 040).
- Removes the hatflag=0 slow-path landmine (structurally unsafe: 2KB stepping, 21-bit PFN,
  old SDEs, `hat_ptalloc` flag 0 = steal-permitted, `hat_ptfree` whole-page assumption, AND a
  confirmed bug — it copies the source table's FIRST PTE not the selected one, 0xb7324). If
  `execstk_addr`'s alignment ever yields hatflag=0, this path executes.
- Cleanliness: stops polluting A4..A7 even if the guards currently absorb it.

## Structure (verified)

- `0xb6f20` entry; computes section indices from args (oas=fp@8, nas/stka args, hatflag=fp@28).
- `0xb6fb0` calls `hat_growsdt` (grows nas legacy SDT — the false-descriptor source).
- `0xb6fc2` error check on hat_growsdt return.
- `0xb700a` `tstl fp@(28)` = hatflag → fast path (!=0, 0xb700a..0xb70f4) vs slow (==0,
  0xb70f8..0xb7434).
- `0xb70ea` the patched `movec %a0,%urp` + `pflusha` (the only already-040 part).

## Fix options (for when prioritized — CODING GOES TO FABLE)

**Option N1 — neuter to a near-no-op (recommended shape):** skip `hat_growsdt` + both path
bodies; do only what's provably needed and return 0. OPEN QUESTION to resolve first: is the
URP reload at 0xb70ea actually needed? Analysis so far suggests NOT — `relvm` walks oas via
`oas->root` (as+20), not URP, and `hat_asload` loads nas->root at the end of `remove_proc`, so
hat_exec's reload of the *old/current* root looks redundant. But this must be confirmed by
RE'ing relvm + the remove_proc sequence before dropping it. Safest interim neuter: keep the
URP load + flush, skip only growsdt + the SDE-move loops.

**Option N2 — full `return 0` at entry:** simplest, but drops the URP load on the unproven
assumption it's redundant. Do NOT do this until the URP-load question above is settled.

**Not recommended:** a real 040 mapping-transfer port (walk/move live A/B/C leaves). Same
reasoning as hat_map Option B — demand-fault already rebuilds the identical mapping, so a
native port re-adds a stock-030 latency optimization for zero correctness gain, at high cost.

## Recommendation

Deprioritize. `hat_dup_cow` acceptance test + workload-driven bug-finding are higher value
right now. When hat_exec IS picked up: first RE relvm/remove_proc to settle the URP-load
question, then hand Fable a concrete N1 neuter spec. Small job once that one question is
answered.
