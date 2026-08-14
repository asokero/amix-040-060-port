# `VOP_PUTPAGE` writeback conversion matrix

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/patch_writeback.py` implements the
> reachable specfs, common PVN, UFS, caller, and pageout groups described here.
> The accepted port also carries the separately specified NFS write repair.
> S5 and RFS remain outside the supported filesystem surface. References below
> to sites that are "still stale" describe the pinned pre-patch image and are
> retained as old-byte and grouping provenance.

## Scope

This note consolidates the writeback audits into one implementation-order
matrix. It does not introduce new binary findings; it orders the already
mapped findings from:

- `VOP-PUTPAGE-WRITEBACK-CONTRACT.md`
- `SEGMAP-WRITEBACK-CONTRACT.md`
- `S5-PUTPAGE-PVN-RANGE-DIRTY-CONTRACT.md`
- `UFS-PUTPAGE-WRITEBACK-CONTRACT.md`
- `SPEC-PUTPAGE-WRITEBACK-CONTRACT.md`
- `GENERIC-PUTPAGE-CALLERS-AUDIT.md`
- `NFS-RFS-PUTPAGE-WRITEBACK-CONTRACT.md`

The target question is practical: which sites belong in the same 4 KiB
writeback patch/test group, and which sites must not be patched even though
they look like size constants.

## Executive Summary

The current writeback state is mixed:

```text
already good:
  pvn_done completes page-I/O lists with a 0x1000 step
  segmap_release uses deliberate MAXBSIZE == 0x2000 slot writes
  segmap slot-internal pagecreate/unlock loops are already 0x1000

still stale:
  generic one-page VOP_PUTPAGE callers pass 0x800
  pvn_range_dirty rounds and scans as 0x800 pages
  spec_putpage writes dirty pages as 0x800
  s5putpage still computes page/block writeback from 0x800
  ufs_putpage still computes page/block writeback from 0x800

needs policy before patching:
  S5 512-byte block writeback and old S5MAXREQ stack layout
  UFS fs_bsize policy for 1K/2K filesystem blocks
```

Do not treat this as a global `0x800 -> 0x1000` replacement. The correct patch
unit is a coordinated writeback conversion: caller request sizes, PVN dirty
range geometry, and provider-local page-I/O sizing must agree.

## Dependency Graph

```text
foreground file write:
  segmap_release(..., len 0x2000)
    -> S5/UFS/specfs putpage
       -> pvn_range_dirty or pvn_vplist_dirty
       -> provider page-I/O length
       -> pvn_done

background/per-page writeback:
  checkpage / fsflush / segvn_swapout / segvn_sync
    -> VOP_PUTPAGE(..., len 0x800 today)
       -> S5/UFS/specfs putpage
       -> pvn_range_dirty or pvn_vplist_dirty
       -> provider page-I/O length
       -> pvn_done
```

`segmap_release` is not the stale one-page caller. It hands off one 8 KiB
slot. The stale geometry is lower in the provider/PVN path, and in separate
background/per-page producers.

## Do-Not-Patch Table

These constants are intentional in the current 040 model:

| Area | Site | Keep | Reason |
|---|---:|---:|---|
| `segmap_getmap` | `0xa9908` | `0x1fff` | `MAXBOFFSET`, 8 KiB slot geometry |
| `segmap_getmap` | `0xa993e` | shift `13` | `MAXBSHIFT`, 8 KiB slot hash/index |
| `segmap_getmap` | `0xa9a14` | `0x2000` | unload whole 8 KiB slot on reuse |
| `segmap_release` | `0xa9aa8` | `0x1fff` | release alignment inside 8 KiB slot |
| `segmap_release` | `0xa9aca` | shift `13` | slot index calculation |
| `segmap_release` | `0xa9b60` | `0x2000` | `VOP_PUTPAGE(..., MAXBSIZE)` |
| `segmap_release` | `0xa9b9e` | `0x2000` | unload whole 8 KiB slot on invalidate |
| `pvn_done` | `0xb1d60` | `0x1000` | already converted completion step |
| block offset math | `>> 9` cases | sector shift | disk-sector conversion, not page size |

The segmap entries are the most important trap: an 8 KiB `MAXBSIZE` slot holds
two 4 KiB pages on 040/060. Converting those slot constants to 4 KiB would
damage the segmap design.

## Common Patch Matrix

These are the shared sites that must agree before writeback is 4 KiB-clean.

| Layer | Function | Site | Current | Target | Notes |
|---|---|---:|---:|---:|---|
| Caller | `checkpage` | `0x52238` | `0x800` | `0x1000` | pageout `B_ASYNC | B_FREE` one-page write |
| Caller | `fsflush` | `0x5c1e2` | `0x800` | `0x1000` | async clean, no `B_FREE` |
| Caller | `segvn_swapout` | `0xacf36` | `0x800` | `0x1000` | loop already indexes pages by 4 KiB |
| Caller | `segvn_sync` per-page | `0xad148` | `0x800` | `0x1000` | large-range path forwards caller `len`; do not patch that as a literal |
| PVN | `pvn_range_dirty` off mask | `0xb2266` | `0xfffff800` | `0xfffff000` | page-align start offset |
| PVN | `pvn_range_dirty` eoff round add | `0xb226a` | `+0x7ff` | `+0xfff` | round end offset |
| PVN | `pvn_range_dirty` eoff mask | `0xb2270` | `0xfffff800` | `0xfffff000` | page-align rounded end |
| PVN | `pvn_range_dirty` main step | `0xb22b4` | `+0x800` | `+0x1000` | main dirty range walk |
| PVN | `pvn_range_dirty` backward cluster | `0xb2302` | `-0x800` | `-0x1000` | pre-range cluster walk |
| PVN | `pvn_range_dirty` forward cluster | `0xb2340` | `+0x800` | `+0x1000` | post-range cluster walk |

`pvn_range_dirty` must be part of the same conversion family as the providers.
Otherwise a 4 KiB request can still be collected through a 2 KiB range scanner.

## Provider Patch Matrix

### specfs

Specfs is the cleanest provider. It has no filesystem sub-block policy to
decide: one dirty VM page should become one 4 KiB block-device page-I/O write.

| Function | Site | Current | Target | Notes |
|---|---:|---:|---:|---|
| `spec_putpage` | `0x67330` | `0x800` | `0x1000` | `UNKNOWN_SIZE` one-page cluster |
| `spec_putpage` | `0x6741e` | `+0x7ff` | `+0xfff` | bounded `fsize` rounding |
| `spec_putpage` | `0x67424` | `0xfffff800` | `0xfffff000` | bounded `fsize` mask |
| `spec_putpage` | `0x67486` | `0x800` | `0x1000` | dirty-page `io_len` |

Best first provider target: specfs plus common `pvn_range_dirty`, because this
validates the simplest provider-local page-I/O shape.

### UFS

UFS has two parts: literal page-size conversion, and an explicit block-size
policy. The source provider assumes one VM page spans at most two filesystem
blocks.

| Function | Site | Current | Target | Notes |
|---|---:|---:|---:|---|
| `ufs_putpage` | `0x82c56` | `0x800` | `0x1000` | initial `io_len` |
| `ufs_putpage` | `0x82cac` | `+0x800` | `+0x1000` | contiguous-page `io_len` growth |
| `ufs_putpage` | `0x82cd6` | compare `0x7ff` | compare `0xfff` | `fs_bsize < PAGESIZE` gate |
| `ufs_putpage` | `0x82ce2` | `0x800` | `0x1000` | `p_nio` numerator |
| `ufs_putpage` | `0x82d2a` | compare `0x7ff` | compare `0xfff` | optional second-write gate |
| `mountfs` | `0x7e67e` | compare `0x3ff` | policy | old `PAGESIZE/2` gate |

Recommended UFS policy for a binary patch: keep the existing provider shape
and require `fs_bsize >= 2048`. That preserves the "at most two blocks per VM
page" invariant. Supporting 1 KiB UFS blocks would require a provider rewrite
with a general sub-page block loop.

The existing `sizeof(struct fs)` mount check appears to reject normal 1 KiB
UFS geometry already, but the 4 KiB page-size policy should still be explicit
in the analysis and tests.

### S5

S5 is the riskiest provider because 512-byte filesystems need eight block
entries per 4 KiB page, while the old binary was compiled with `S5MAXREQ == 4`.

| Function | Site | Current | Target | Notes |
|---|---:|---:|---:|---|
| `s5putpage` | `0x74da2` | compare `0x7ff` | compare `0xfff` | `bsize < PAGESIZE` gate |
| `s5putpage` | `0x74dac` | `0x800` | `0x1000` | `multi_io` numerator |
| `s5putpage` | `0x7524c` | `0x800` | `0x1000` | initial `io_len` |
| `s5putpage` | `0x752a2` | `+0x800` | `+0x1000` | contiguous-page `io_len` growth |
| `s5putpage` | `0x752ca` | compare `0x7ff` | compare `0xfff` | `p_nio` / multi-I/O completion gate |

Policy decision required before enabling full S5 writeback conversion:

```text
512-byte S5:
  needs 8 block entries per 4 KiB page;
  old compiled local array likely has room for 4;
  blind multi_io=8 can overrun the stack frame.

1024-byte S5:
  needs 4 entries per 4 KiB page;
  old 4-entry array is likely sufficient, but p_nio and io_len must be fixed.

2048-byte S5:
  needs 2 entries per 4 KiB page;
  old 4-entry array is sufficient, but the old binary currently treats 2 KiB
  as a full page and can skip the upper half.
```

Recommended S5 policy for a first binary-patch pass:

```text
support 1024-byte and 2048-byte S5 writeback;
guard, reject, or leave disabled 512-byte S5 writeback until s5putpage is
rewritten or safely split into bounded subpasses.
```

If AMIX root filesystems are known to be 1024 or 2048 byte S5, that policy
keeps the first patch tractable while avoiding the `S5MAXREQ` stack hazard.

## Recommended Implementation Order

### Phase 0: freeze invariants

Before patching, document the active filesystem geometry used by the test
images and real machines:

```text
root filesystem type and block size
local test filesystem type and block size
swap/spec device paths used by normal boot and stress tests
whether any 512-byte S5 filesystem must be supported
whether any 1 KiB UFS filesystem must be supported
```

No binary patch should be treated as complete until those policy questions are
answered.

### Phase 1: provider/PVN core

Patch and test the provider/PVN core as one group:

```text
pvn_range_dirty 4 KiB range geometry
spec_putpage 4 KiB page-I/O length and range rounding
UFS provider literals, with fs_bsize >= 2048 policy
S5 provider literals for supported block sizes, with 512-byte policy guarded
```

This phase fixes foreground file writes through `segmap_release`, because
`segmap_release` already sends a correct 8 KiB slot request into the provider
layer.

### Phase 2: generic one-page callers

After providers can consume a 4 KiB dirty page correctly, patch the generic
one-page request producers:

```text
checkpage
fsflush
segvn_swapout
segvn_sync per-page path
```

This phase turns background pageout, fsflush, segment swapout, and per-page
`msync` into 4 KiB request producers. Doing it after the provider/PVN core
avoids creating new 4 KiB requests for providers that still write only 2 KiB.

### Phase 3: pressure tests

Run tests that force each producer class:

```text
foreground segmap write:
  write patterns spanning both halves of many 4 KiB pages;
  sync, reread, and verify after cache-disrupting activity or reboot.

fsflush:
  dirty many files, wait for fsflush, verify upper-half data persists.

pageout:
  dirty files while applying memory pressure; verify checksums after pressure.

segvn_sync:
  mmap a file, dirty upper halves, msync or equivalent, verify after remap.

swapout/specfs:
  only on scratch media or with controlled swap pressure; avoid destructive
  raw-device tests on production media.
```

The recent reported NFS-to-local copy panic with a segmap-region address is a
useful stress candidate after the static writeback group is patched. It should
be treated as a regression test candidate, not as proof of this exact bug
class yet.

## Minimum Coherent Patch Set

For a broad "writeback is 4 KiB-clean" claim, the minimum coherent set is:

```text
common:
  pvn_range_dirty

callers:
  checkpage
  fsflush
  segvn_swapout
  segvn_sync per-page path

providers:
  spec_putpage
  s5putpage for supported S5 block sizes
  ufs_putpage plus UFS block-size policy

already converted:
  pvn_done

unchanged by design:
  segmap MAXBSIZE slot constants
```

If S5 is the normal AMIX root filesystem, do not call the writeback conversion
complete until the S5 provider policy has been resolved and tested with the
actual root/local filesystem block sizes.

## Optional Network-FS Extension

`NFS-RFS-PUTPAGE-WRITEBACK-CONTRACT.md` shows that NFS and RFS writeback also
retain 2 KiB provider-local geometry. They are not part of the minimum
local-disk milestone, but they should be added if AMIX is expected to write
dirty pages back to NFS/RFS mounts or support mapped writes to remote files.

| Provider | Required if in scope | Notes |
|---|---|---|
| NFS | `nfs_putpage` local `PAGESIZE` sites plus common `pvn_range_dirty` | Clear UFS-like loop; best first network-FS target. |
| RFS | `rf_pushpages` `io_len` sites plus common `pvn_range_dirty` | Needs a separate EOF/tail pass if RFS writeback is actively supported. |

The reported NFS-to-local copy panic is not direct evidence of NFS `putpage`.
That workload more directly combines NFS read/page-in with local filesystem
foreground writeback and segmap/HAT cleanup.

## Deferred Or Separate Targets

These are adjacent but not part of the first writeback conversion group:

| Area | Reason |
|---|---|
| `segmap_faulta` `VOP_GETPAGE` length `0x800` | Page-in/fault-ahead boundary, not putpage writeback. Mapped in `SEGMAP-FAULTA-PAGEIN-AUDIT.md`. |
| HAT `hat_pagesync040` implementation | Still critical for dirty detection, but it is a ref/mod sampler problem, not a byte-length conversion site. |
| Zorro III mmap/MMIO work | Separate device-mapping track. |

## Working Conclusion

The writeback conversion should be treated as one coordinated VM milestone, not
as isolated literal patches. The highest-value next implementation package is:

```text
1. decide S5/UFS supported block-size policy;
2. patch common pvn_range_dirty and provider-local specfs/S5/UFS writeback;
3. patch generic one-page VOP_PUTPAGE callers;
4. run foreground-write, fsflush, pageout, and mmap/msync persistence tests;
5. repeat on 040 and 060 emulation, then real hardware.
```

This matrix gives the implementation side a bounded target: it separates the
mechanical page-size sites from the filesystem policy decisions and keeps the
known-good `segmap` and `pvn_done` constants out of the patch blast radius.
