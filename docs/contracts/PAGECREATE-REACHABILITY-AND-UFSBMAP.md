# PAGECREATE Reachability and UFS `ufs_bmap` Audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/PAGECREATE-REACHABILITY-AND-UFSBMAP.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The eleven-site UFS provider unit derived
> here is implemented by `src/patch_ufsbmap.py`; ISSUE-31 is fixed in the
> current port and was accepted on both emulator CPU modes. The earlier
> `as_iolock` and live pagecreate group remains coupled to it as described
> below. S5 remains a separate deferred structural port.

## Scope and provenance

This note answers `PAGECREATE-REPRO-UFSBMAP-TASK.md` without changing the
kernel. The primary image is `build/unix-040`, build
`68040-260725-09`, SHA-256:

```text
0bf2c5c075abe26eb5a4a9bfb43d616126792a4d6d09b23e6489c40066f08f07
```

The pre-fix comparison image is
`build/unix-040-dbg.ISSUE28-260725-06`, SHA-256
`e6847d3dcd97360657391c4e0f2b04cfbfb2395d1ef106485e85f1cc9a604351`.
The `ufs_bmap` body is byte-identical in shape to the stripped AMIX
`usr/sys/fs/ufs/exp` object (`exp` address `0x2ef4`, size `2398`) and is
linked at `0x79d48` in the current image. The source comparison is the SVR4
3B2 UFS implementation in
`svr4-v4/usr/src/uts/i386/fs/ufs/ufs_bmap.c`.

This is a static reachability and contract result. The existing acceptance run
has no pre-fix hits, so it is not evidence that the tail-zero defect is
unreachable.

## Executive verdict

1. The current same-process test is weak against the suspected `fbread` path.
   `fbread` enters through `as_fault(..., F_SOFTLOCK, ...)`; if the page is
   still resident in the page cache, the fault path can retain that page and
   does not imply a disk refill. Therefore the second write can leave the
   un-zeroed tail in the same resident page while the subsequent read sees
   the same page, with no observable stale-disk content.
2. The writeback route is reachable. Current `ufs_putpage` is already 4 KiB
   converted, but its per-page I/O length is 4096 and its upper bound is the
   UFS block boundary, not the raw `i_size`. A dirty last page can therefore
   write a full 4 KiB containing the un-zeroed tail. A cold-cache or reboot
   between the first and second write is the useful exposure mechanism.
3. `ufs_bmap` is not a uniform collection of 2 KiB constants. The brief lists
   eight sites, but the current body contains fourteen relevant literals:
   eleven page-geometry sites and three `NDADDR-1` direct/indirect threshold
   constants. Only the eleven page-geometry sites are candidates for a 4 KiB
   conversion.
4. Leaving all `ufs_bmap` page geometry old is compatible with the measured
   8 KiB root filesystem in the first direct-fragment branch, because several
   page-size branches are dead when `fs_bsize > PAGESIZE`. It is not a valid
   general 4 KiB contract, however. The six indirect-path rounding sites are
   active with an 8 KiB block size and can disagree with the new 4 KiB
   `alloc_only` decision.
5. The landed `as_iolock + rwip + rwvp` group should not be reverted solely
   because `ufs_bmap` remains old. The mixed state is conservative in the
   important indirect allocation case: it can perform an extra `fbread` for
   some sizes, rather than skip a required read. `ufs_bmap` should be treated
   as a separate, atomic UFS provider/allocation conversion unit, with its
   full eleven-site audit applied together.

## Why the existing probe does not fire

The implemented probe does this on an 8 KiB UFS filesystem:

```text
fully write the first 8 KiB
write 100 bytes at 8192       new UFS block, pagecreate = 1
write 10 bytes at 11192       same 4 KiB VM page, pagecreate = 0
read the never-written tail
```

The expected defect is that `segmap_pagecreate` zeroes only through the old
2 KiB boundary. That is a valid static defect: the producer creates/fetches a
4 KiB page, while the caller-side zeroing can leave the upper part unchanged.
`page_get` and `page_free` contain no zeroing call that would invalidate this
argument.

The missing observation is page provenance. The second write reaches

```text
rwip -> ufs_bmap(..., S_WRITE, alloc_only = 0) -> possible fbread
```

but `fbread` is a buffered fault path, not an unconditional disk read. Its
relevant shape is:

```text
segmap_getmap
as_fault(kas, addr + offset, len, F_SOFTLOCK, rw)
...
segmap_release / fbrelse
```

If the page is already resident, the normal segmap fault path can use that
page. It need not call the provider's `VOP_GETPAGE` path and need not replace
the page with the disk image. Thus a same-process read immediately after the
second write can simply inspect the page that the second write already
modified. This masks a disk-side stale tail and explains why larger windows
and file-cache poisoning alone did not produce a hit.

This does not prove that `fbread` is never an exposure route. It means that the
route needs page-cache eviction or a reboot before it is informative.

## Stronger reproducer

The useful experiment is a two-boot or otherwise cold-cache sequence:

### Phase A: create and write back

1. Create a file on the target UFS filesystem.
2. Make the first 8 KiB fully known, then write 100 bytes at offset 8192.
3. Dirty a recognizable file-cache page pool before or around this operation;
   do not assume a fresh free page is non-zero.
4. Force `fsync`/sync and wait for writeback. Record the file size and a disk
   image or raw-block checksum if available.
5. Reboot, or otherwise force the page out of the page cache. A process-local
   read without this step is not a cold-cache test.

### Phase B: page-in after the short file size

1. Open the file again and write 10 bytes at offset 11192.
2. This should make `ufs_bmap(..., alloc_only = 0)` eligible to use `fbread`.
3. Read the interval from the first write's end through the end of the 4 KiB
   VM page. Compare it against the known marker pattern and against zero.
4. Repeat enough times to obtain a page reuse event. A zero result is only
   conclusive if instrumentation proves that a non-zero page entered
   `segmap_pagecreate` or that the page-in read the disk bytes written by
   `ufs_putpage`.

### What to instrument if it still stays quiet

The smallest useful trace points are:

| Point | Evidence needed |
|---|---|
| `segmap_pagecreate` return/page list | PFN and first bytes of each newly attached 4 KiB page |
| `ufs_putpage` before `ufs_writelbn` | vnode offset, `i_size`, `d2` I/O length, and page bytes at the tail |
| `ufs_writelbn`/pageio setup | physical/file offset and submitted byte length |
| `ufs_bmap` `alloc_only=0` branch | whether `fbread` was actually selected |
| `segmap_fault`/provider GETPAGE boundary | resident-page hit versus provider page-in |

This distinguishes three otherwise identical-looking outcomes: a zero page
was supplied, the page stayed resident, or disk writeback/page-in replaced the
page. The existing 0/64 result does not distinguish them.

## Writeback finding

The current `ufs_putpage` is at `0x828da`, size 1432, and is already 4 KiB
converted in the pinned image. Relevant current instructions are:

| Address | Current behavior | Contract consequence |
|---|---|---|
| `0x8299c` | rounds the dirty range using `i_size + 8191`, mask `-8192` | UFS block-boundary bookkeeping |
| `0x82c56` | initial per-page I/O length `4096` | a page can be submitted as a full 4 KiB |
| `0x82cac` | grows contiguous I/O by `4096` | same full-page unit for adjacent pages |
| `0x82cc4..0x82cd2` | clamps against `lbn_off + bsize` | block boundary, not raw `i_size` |
| `0x82cd6` | compares `fs_bsize` with `4095` | 4 KiB page/block gate |
| `0x82ce2` | uses `4096` in `p_nio` arithmetic | page-count/byte-count conversion |
| `0x82d1e` | calls `ufs_writelbn` with the computed `d2` | full page can reach disk |
| `0x82d2a` | compares against `4095` | second-write/page-size gate |

There is no final clamp of a last page's write length to
`i_size - page_offset`. Therefore, for `i_size` ending at 8292 inside an 8 KiB
UFS block, the dirty page beginning at 8192 can be written with a 4096-byte
length. Whether its upper bytes are non-zero depends on the pagecreate and
page provenance, but the writeback path itself does not protect the file from
that content.

This corrects the older wording in `UFS-PUTPAGE-WRITEBACK-CONTRACT.md`, which
described the pre-conversion 2 KiB literals. The old document remains useful
for the provider call graph, but its current-image literal claims must not be
used as the current status.

## `ufs_bmap` full census

The source structure separates two kinds of constants:

```c
/* VM page geometry */
PAGESIZE, PAGEOFFSET, PAGESHIFT

/* UFS direct/indirect geometry */
NDADDR, NIADDR, bsize, fs_bsize, dbsize
```

The binary has eleven page-geometry sites and three direct-block threshold
sites. The following table gives the old-byte-asserted targets. The text
offset convention remains the repository's `+0x34` convention when converting
ELF text addresses to file offsets.

### Page-geometry sites: convert as one unit

| ELF address | Current instruction | Role | 4 KiB target |
|---|---|---|---|
| `0x79d74` | `cmpil #2048,%d3` | `PAGESIZE >= bsize` / page-size numerator | `cmpil #4096,%d3` |
| `0x79d7e` | `movel #2048,%d2` | `PAGESIZE / bsize` branch value | `movel #4096,%d2` |
| `0x79d96` | `cmpil #2047,%d3` | `PAGESIZE > bsize` rounding | `cmpil #4095,%d3` |
| `0x79da4` | `addil #2047,%d0` | `roundup(..., PAGESIZE)` | `addil #4095,%d0` |
| `0x79daa` | `moveq #11,%d7` | `PAGESHIFT` | `moveq #12,%d7` |
| `0x7a494` | `addil #2047,%d0` | indirect allocation roundup | `addil #4095,%d0` |
| `0x7a49e` | `addil #2047,%d0` | overflow compensation for roundup | `addil #4095,%d0` |
| `0x7a4a4` | `andiw #-2048,%d0` | rounded-size mask | `andiw #-4096,%d0` |
| `0x7a520` | `addil #2047,%d0` | indirect synchronous-write roundup | `addil #4095,%d0` |
| `0x7a52a` | `addil #2047,%d0` | overflow compensation for roundup | `addil #4095,%d0` |
| `0x7a530` | `andiw #-2048,%d0` | rounded-size mask | `andiw #-4096,%d0` |

The last six sites are the important omission from the brief's eight-site
list. They implement the source condition equivalent to:

```c
roundup(size, PAGESIZE) < bsize
```

inside the indirect allocation and synchronous write decisions. They are not
safe to dismiss as fragment constants merely because they occur in UFS code.

### UFS direct/indirect threshold sites: keep unchanged

| ELF address | Current instruction | Meaning | Verdict |
|---|---|---|---|
| `0x79ec0` | `moveq #11,%d7` | direct-block/indirect threshold (`NDADDR - 1`) | keep |
| `0x79ee2` | `moveq #11,%d7` | direct-block/indirect threshold | keep |
| `0x7a030` | `moveq #11,%d7` | direct-block/indirect threshold | keep |

These are not `PAGESHIFT` uses. Changing them to 12 would move the UFS
direct-block boundary and corrupt the allocation algorithm. This is the exact
kind of context classification that a whole-text `moveq #11` scan must apply.

## Interaction with the converted callers

`rwip` now supplies its 4 KiB-derived pagecreate value as `ufs_bmap`'s
`alloc_only` argument. That is a meaningful caller contract change, but it does
not automatically convert every internal `PAGESIZE` use in `ufs_bmap`.

For the measured root filesystem (`fs_bsize = 8192`):

1. The entry branch based on `PAGESIZE >= bsize` is false for both 2 KiB and
   4 KiB builds. Its old literals are therefore inert on the root filesystem.
2. The adjacent `PAGESIZE > bsize` branch is also false. The first five old
   page-geometry sites do not control the normal root path.
3. The indirect `roundup(size, PAGESIZE) < bsize` tests are active. With the old
   2 KiB rounding, sizes from 4097 through 6144 round to 6144 and satisfy the
   `< 8192` condition. With correct 4 KiB rounding, those sizes round to 8192
   and do not satisfy it.

In the old/current mixed state, the result for that interval is an extra
`fbread`/read-before-use in the indirect path where the 4 KiB contract would
allow skipping it. That is a performance and exposure difference, and it can
mask the pagecreate defect by restoring data before the caller reads it. The
static result is not a skip of a required read for the measured UFS geometry.
It is nevertheless a contract mismatch and should not be accepted as a final
generic 4 KiB UFS implementation.

For `fs_bsize == PAGESIZE` or smaller, the first five sites become reachable,
and the old branch geometry can change page/block counts and page-in behavior.
That configuration is not exercised by the AMIX root filesystem, but it is
enough to reject the claim that leaving `ufs_bmap` wholly unconverted is safe.

## Conversion and integration decision

The safe unit is:

```text
ufs_bmap page-geometry sites (all 11)
    + caller contract review for rwip/rwvp
    + direct/indirect allocation regression tests
```

It does not need to be atomically linked with the already landed
`as_iolock + rwip + rwvp` pagecreate group. The live group can remain in place
while the UFS provider is audited and patched as its own unit. Do not patch
only the first five obvious literals: that would leave the active indirect
rounding decisions old and make the result harder to reason about.

The current mixed state is not worse than both extremes for the observed
8 KiB root path: it is conservative in the identified 4097..6144 indirect
interval. It is worse than a coherent 4 KiB state in performance and in
reachability predictability, so it should be closed before claiming complete
UFS 4 KiB provenance.

No recommendation is made here to revert the live caller group. A revert would
discard a verified producer-side correction while leaving the provider's
independent page-size debt unresolved.

## Acceptance criteria for the next implementation pass

Before any UFS `ufs_bmap` patch is accepted:

1. All eleven page-geometry old bytes are asserted; all three `NDADDR-1`
   sites are asserted unchanged.
2. Direct allocation, fragment growth, indirect allocation, and synchronous
   write branches are exercised with `fs_bsize = 8192`.
3. The cold-cache pagecreate reproducer is run across a writeback/reboot
   boundary, not only as a same-process read.
4. The test records whether the observed page was resident, page-created,
   or supplied by provider page-in. A clean result without that provenance is
   not a closure result.
5. Disk truth is checked after sync, reboot, and filesystem check. The test
   must distinguish a clean page-cache read from a clean on-disk tail.
6. `fs_bsize == 4096` is either tested or explicitly declared out of scope;
   it must not be silently inferred from the 8192-byte root result.

## Bottom line

The 0/64 result is most plausibly a cache-lifetime artifact, not evidence that
`segmap_pagecreate` is harmless. The strongest static exposure is a full-page
UFS writeback followed by a cold page-in. The `ufs_bmap` conversion is needed
for a coherent generic 4 KiB contract, but it is a separate eleven-site UFS
unit; the three `moveq #11` direct-block constants must remain unchanged.
