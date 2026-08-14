# `segmap_pagecreate` Tail-Zero Conversion Specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/PAGECREATE-TAILZERO-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The live, `fbzero`, and specfs units are
> implemented by `src/patch_pagecreate.py`. ISSUE-27 is hardware-accepted:
> the cold-cache control exposed marker data in 24/24 runs and the repaired
> kernel preserved it in 24/24. The S5 unit remains deferred exactly as this
> specification requires.

This is a static, old-byte-asserted specification. It does not implement the
kernel change.

## Root cause

`segmap_pagecreate` already creates complete 4 KiB pages, but the callers still
round their zero-fill bounds to 2 KiB. A page created for an EOF/partial write
is therefore only partly initialized. If a later write reaches the upper half
of that same cached page, the recycled physical-page contents become file
contents.

The minimal state transition is:

```text
page_get(4096) -> uiomove(short write) -> zero through roundup(..., 4096)
```

The 4 KiB zeroing is a data-integrity requirement, not a cache flush.

## Lock and page-list contract

`segmap_pagecreate(..., softlock=0)` is used by `spec_write`, `writei`, `rwip`,
and `rwvp`. Those calls do not create HAT softlocks. `fbzero` passes `1` and
does create a HAT lock plus a page hold; `fbrelse` releases it through the
already 4 KiB `as_fault(F_SOFTUNLOCK)` path.

`as_iolock` is a different contract. It calls `VOP_GETPAGE` with a page list
and holds returned pages with `PAGE_HOLD`; the callers release those holds by
the inline `PAGE_RELE` loops. The 2026-07-03 overlapping-softlock concern
belongs to the separate `prusrio`/`as_fault(F_SOFTLOCK)` group, not to
`segmap_pagecreate`.

The two callers that use `as_iolock` have six pointer slots at `fp-24` through
`fp-4`:

| Caller | Frame | `pl` | `pagecreate` | Max entries after 4 KiB conversion |
|---|---:|---:|---:|---:|
| `rwip` | `link #-120` | `fp-24` | `fp-28` | 3 pages + NULL |
| `rwvp` | `link #-48` | `fp-24` | `fp-28` | 3 pages + NULL |

The maximum is three pages, not two: an 8 KiB request whose user address is
not 4 KiB-aligned can span three pages. The existing six-slot frames are safe.
After conversion, `as_iolock` advances by 4 KiB and asks `VOP_GETPAGE` for one
aligned 4 KiB page per entry, so one `ppp++` per call remains correct.

Release coverage is complete in the current bodies:

- `as_iolock` initializes `pl[0]=NULL`; its `err` path walks every held entry,
  calls `PAGE_RELE`, and clears `pl[0]`.
- `rwip` releases the list after `uiomove`, and also releases it when
  `ufs_bmap` fails. There is no partial `bmapalloc` branch in UFS `rwip`.
- `rwvp` releases the list after `uiomove`; read paths initialize the list to
  NULL and do not call `as_iolock`.

Changing 2 KiB iteration to 4 KiB iteration reduces the number of entries and
does not alter the ownership rule.

## UFS allocation interaction

The live UFS caller is not `bmapalloc`; it calls:

```text
rwip -> ufs_bmap(..., size=on+n, S_WRITE, pagecreate)
```

Here `pagecreate` is passed as `alloc_only`. It tells `ufs_bmap` whether it may
allocate a new fragment/block without first doing `fbread`. Consequently,
changing the pagecreate decision changes allocation/read-before-write behavior,
not just the later zeroing.

For the measured root filesystem (`fs_bsize=8192 > 4096`), the UFS
`fs_bsize < PAGESIZE` sub-page-block branch is false. The remaining
`ufs_bmap` `PAGESIZE` arithmetic is a separate provider/allocation audit and
must not be converted by matching constants mechanically. The pagecreate
decision itself must nevertheless use the new 4 KiB contract.

The S5 task wording mentions `bmapalloc` and a `part_write` recomputation. The
current AMIX `writei` does call `bmapalloc`, but it is not the later source
implementation:

- it has no `as_iolock` call;
- it probes source pages with `fubyte` at `0x70c5c`/`0x70cc8`;
- it calls `segmap_pagecreate` at `0x70cfa` before `bmapalloc` at `0x70d46`;
- its ENOSPC partial branch starts at `0x70d80`, recomputes `n`, but does not
  recompute the pagecreate flag or undo the already-issued pagecreate call.

Therefore no missing `part_write` address can be byte-patched into the current
body. The later USL/v4 source branch is a different implementation. S5 must be
handled as a separate structural port and is safely deferred because S5 is not
mounted in the target installation.

## Atomic implementation units

Recommended landing boundaries:

1. **Live I/O unit:** convert all 12 `as_iolock` sites plus the five `rwip`
   tail sites and the five `rwvp` tail sites in one build. A mixed state is
   unsafe: converting `as_iolock` while its caller still rounds/zeros at 2 KiB
   leaves the producer/consumer contract split; converting only the tails
   leaves `as_iolock` making overlapping 2 KiB `VOP_GETPAGE` calls.
2. **`fbzero` unit:** convert its two sites. It is independent of the live
   `as_iolock` list contract, but should be included before claiming UFS
   allocation-hole safety.
3. **`spec_write` unit:** convert its four tail sites. It has no page-list
   ownership in the current body and can land independently, preferably with a
   scratch block-device test.
4. **S5 unit:** keep all `writei` geometry sites together, and do not claim the
   S5 path complete until the pre-`bmapalloc`/partial-ENOSPC design is either
   preserved deliberately or replaced by a verified structural override.

This is four logical units, with the first and second being the live UFS
acceptance gate. `prusrio`, `prfastmapin`, `prfastmapout`, and `vtop040` are
separable: they use different functions, owners, and HAT/softlock contracts.
The address-first `vtop` dispatch rule remains an independent requirement for
`startio`.

## Patch assertions

The implementation must assert the exact old bytes listed in
`PAGECREATE-TAILZERO-CENSUS.md` before writing replacements. It must also
assert that the four producer edits at `0xa9742`, `0xa97a0`, `0xa9892`, and
`0xa9898` are already present. The patch must reject a different image rather
than silently applying by symbol name alone.

No `MAXBSIZE`, `0x2000` segmap-slot, `vfs_bshift`, sector, fragment, or UFS
block-size instruction may be changed by this patch.

## Acceptance test

The original 4096/7000 example is useful for a generic `segmap_pagecreate`
demonstration, but it can be masked by UFS fragment growth and `fbread`. The
stronger live-UFS test is:

1. Create a file with a fully initialized first 8 KiB UFS block.
2. Dirty a large pool of anonymous pages with a recognizable nonzero pattern,
   then release the pool so `page_get` has recyclable pages. Repeat this before
   each batch; a fresh boot may otherwise hand out pages that happen to be zero.
3. Write 100 bytes at file offset `8192` (the start of a new UFS block).
4. Write 10 bytes at offset `11192` (`8192 + 3000`).
5. Read back `[8292, 11202)`, especially `[10240, 11192)`, and require every
   byte in the unwritten interval to be zero. Record the first nonzero byte and
   its marker pattern.
6. Repeat at least 256 times on both 68040 and 68060 images. A pre-fix hit is
   expected but not guaranteed; a no-hit pre-fix run is inconclusive. A
   post-fix run must have zero failures.
7. Force `sync`, close/unmount if possible, reboot or power-cycle, run `fsck`,
   and verify the same bytes from disk. This distinguishes page-cache success
   from writeback correctness.

The test must also cover a short `uiomove`/fault case and an exact 4 KiB write
boundary. NFS should use the analogous client-cache test when an NFS mount is
available. `writei` and raw `spec_write` require separate tests because S5 is
not mounted and block-device writes are not ordinary file semantics.

## Final verdict

The new defect is real and active in `rwip`/UFS, with the same tail-zero defect
also present in `rwvp`, `fbzero`, `spec_write`, and dormant `writei`. The safe
first implementation is the shared `as_iolock` + UFS/NFS tail group, followed
by `fbzero`. The S5 `part_write` request cannot be satisfied by locating a
hidden address in this image: that branch is absent in the AMIX hybrid and
must be treated as a separate design task.
