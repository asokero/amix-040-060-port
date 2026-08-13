# TASK: pageout/writeback Model-B conversion group

**Status: ✅ DONE — EMULATOR-VERIFIED 040+060 (2026-07-15). All 20 sites converted in
`src/patch_writeback.py` (wired into `relink-040.sh` after
`patch_modelb_pager.py`; bisection via `WRITEBACK_GROUPS=spec,pvn,ufs,callers`).**

Verification (per-unit boot bisection spec → +pvn → +ufs → +callers, then exercises):
- 040 + 060: boot→login→telnet, `hat_dup_cow` 1/32/256 (040) / 1/32 (060) ALL PASS.
- **Disk truth:** 4 MiB stamped-pattern file, `cp` + `sync` → across BOTH an unclean
  kill+`fsck -y` (040) and a clean `shutdown -i6`+reboot (060), `sum` = `1570 8192`
  byte-perfect on re-read from disk.
- Clean 060 shutdown produced **no ISSUE-14 "freeing free frag" panic**; reboot fsck
  ran `-m` only (clean fs). Datapoint recorded in KNOWN-ISSUES.
- NOT converted (policy, per matrix): `s5putpage` (s5 not mounted anywhere; 512 B
  `S5MAXREQ` stack hazard), NFS/RFS putpage. `mountfs` now rejects `fs_bsize < 2048`.
- **FOLLOW-ON DONE (2026-07-15, same day):** the `schedpaging` rts-override was RETIRED
  (runtime040.s + mainmarks.s + relink weakens) and the newly-live daemon path converted
  (group `pageoutd`: setupclock `0x51eee` handspread ptob `<<11→<<12`, pageout
  `0x5204c/0x52052` btop(handspread) `+2047>>11 → +4095>>12`; stock schedpaging itself
  is page-count math, clean). Pressure re-test: the 6×4 MiB copy burst that previously
  FROZE userspace (page_get starvation, sac SIGKILL) now completes 6/6 with all sums
  byte-perfect — reclaim works. `sched` (process swapper) remains disabled.
- **✅ mmap/msync (`segvn_sync`) path VALIDATED emu-060 (2026-07-15):** `test-tools/msynctst.c`
  mmaps MAP_SHARED, dirties every page, `msync(MS_SYNC)` → `segvn_sync` → `ufs_putpage`.
  In-process read-back byte-perfect (MSYNC-OK, 64 KiB), and cold-cache disk-truth held
  across a clean `init 6` reboot (`sum` = `32895 128` pre == post), so the Model-B pfn
  conversion in the msync putpage path writes the CORRECT disk blocks (no wrong-block
  write masked by page cache). `segvn_sync` is MI C → 040 expected identical.
- **REMAINING:** (1) real-HW re-verify (root-disk geometry there still unmeasured);
  (2) with pageout live, sustained pressure now trips the **ISSUE-10 stale-PTE
  page-reuse corruption within minutes** (victims: sh → telnetd/inetd → init) — fast
  repro + mechanism + resume recommendation recorded under ISSUE-10 in KNOWN-ISSUES;
  that HAT p_mapping fix is the next frontier, not a writeback defect (file data
  stays byte-perfect throughout).

## Why this matters

The page-IN side is fully converted (123/123 sites byte-verified). The page-OUT /
writeback side is still largely 2 KiB in `build/unix-040`. Consequence class:
**only the lower 2 KiB of a dirty 4 KiB page gets written back while the dirty bit is
cleared — silent data loss.** The system survives day-to-day because bio/buffer-cache
writes dominate; putpage bites under memory pressure, `fsflush`, mmap-writes, and big
copies. It is also the gate for two other things: turning real paging/swap back on
(`sched`/`schedpaging` in `src/runtime040.s` are deliberate DISABLES until this
lands) and it is the smart precondition for the caches-on track.

## Phase-0 policy: ANSWERED — no decision left to make

Root fs measured directly (KNOWN-ISSUES.md → "ROOT-FS GEOMETRY"):

```
root = UFS (NOT s5).  fs_bsize = 8192   fs_fsize = 1024   fs_frag = 8
s5 is not mounted anywhere on this system.
```

- `fs_bsize 8192 >= 2048` → Codex's recommended UFS policy ("keep the provider shape,
  require fs_bsize >= 2048") holds with margin. **No provider rewrite needed.**
- `fs_bsize > PAGESIZE (4096)` → one VM page lies WITHIN a single fs block: the easiest
  conversion case.
- The s5 `S5MAXREQ=4` / 512-byte-block hazard is **not on any live path** → convert s5
  for completeness or just guard/reject 512 B; either way it does not block this group.

## Authoritative source

`~/kehitys/amix-playground/amix-kernel-analysis/vm-map/PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md`
is the ordering guide, the exact site list, and — importantly — the **do-not-patch
traps**. Supporting contracts: `UFS-PUTPAGE-WRITEBACK-CONTRACT.md`,
`SPEC-PUTPAGE-WRITEBACK-CONTRACT.md`, `GENERIC-PUTPAGE-CALLERS-AUDIT.md`.

**This is NOT a global `0x800 -> 0x1000` replacement.** The correct patch unit is a
coordinated writeback conversion: caller request sizes, PVN dirty ranges, provider
page-I/O length, and `pvn_done` must agree. Read the matrix before touching a byte.

## Suggested order (simplest provider first)

| # | Unit | Sites | Notes |
|---|------|-------|-------|
| 1 | `spec_putpage` | `0x67330`, `0x6741e`, `0x67424`, `0x67486` | simplest provider — patch and boot-test FIRST |
| 2 | `pvn_range_dirty` `0xb2242` | `0xb2266/6a/70` (masks+round), `0xb22b4/302/340` (steps) | shared by every provider |
| 3 | `ufs_putpage` | `0x82c56` (io_len), `0x82cac` (+growth), `0x82cd6` (`fs_bsize<PAGESIZE` gate `0x7ff`→`0xfff`), `0x82ce2` (p_nio), `0x82d2a` (2nd-write gate) | **THE live provider** (root is UFS) |
| 3b | `mountfs` gate `0x7e67e` | compare `0x3ff` (old PAGESIZE/2) | set policy: reject `fs_bsize < 2048` |
| 4 | generic callers (all pass `0x800`) | `checkpage 0x52238`, `fsflush 0x5c1e2`, `segvn_swapout 0xacf36`, `segvn_sync 0xad148` | |
| — | `s5putpage`, NFS/RFS putpage | see matrix | optional; not on the live path here |

## DO NOT PATCH (traps — from the matrix)

- segmap slot constants (`0x2000` / `0x1fff` / shift-13) = MAXBSIZE **design**, not page size
- page-hash `moveq #11`s = hash function, not PFN math
- sector `>>9` / `0x200` = 512-byte disk sectors
- UFS `0x1fff` / `0xffffe000` MAXBSIZE rounds
- `segvn_sync` large-range len-forward `0xad072`
- `pvn_done` is **already converted** — keep it

## Mechanics (repo conventions)

- Byte patches go in a `src/patch_*.py` script wired into `relink-040.sh`
  (see `patch_modelb.py` / `patch_modelb_pager.py` for the established pattern:
  every site asserts its expected OLD bytes before writing — never blind-poke).
- If a site needs a real code change rather than an immediate, write a
  `src/*.s` override + `--weaken-symbol` (see `bp_map040.s`, `krnxmemflt040.s`).
  **Every section of every override .s must end `.balign 4`** (else .bss misaligns →
  SDMAC DMA → root-mount ENXIO).
- Validate with `python3 src/check_relink_relocs.py` (must report 0 complaints).

## Test plan

Per unit (patch → build → boot), not big-bang:

1. `sh relink-040.sh && sh relink-040-dbg.sh`
2. `sh emu-reset-boot.sh 040` (golden-image reset; guest state is WIPED each run)
3. Prime the guest network once (console `ping 10.0.2.2` via `test-tools/sendkeys.py`),
   then drive it with `test-tools/emu.py`.
4. Regression: boot→login, `hat_dup_cow 1/32/256` (push via `test-tools/tftp_onesock.py`).
5. **The actual writeback exercise** (what this group is FOR): force dirty-page writeback
   and verify byte-perfect data — e.g. large file writes + `sync` + `sum` compare, an
   mmap-write workload, and memory pressure to make `fsflush`/pageout actually run.
   A pre/post `sum` mismatch on a big written file is the failure signature.
6. Repeat the whole thing on `emu-reset-boot.sh 060` before declaring the unit done.

## Watch out

- The real A3000's disk geometry is **not yet verified** (machine was off 2026-07-15).
  Confirm `df -n` + the UFS superblock there before trusting this conversion on real HW.
- ISSUE-14 (root-fs "freeing free frag" panic on shutdown) is an OPEN datapoint that may
  itself be caused by this unconverted group. Run a MANUAL full `fsck` on the emulator
  root first so you start from a verified-clean fs — otherwise you cannot tell inherited
  damage from damage you just caused.
