# Producer-Consumer Asymmetry Census

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** This census is the pre-conversion map for
> the units it identified. The current port has landed the reachable
> `pvn_vptrunc`, UFS, NFS, ELF exec, public VM-vector, and device-PFN boundary
> repairs represented under `src/`; `STATUS.md` is authoritative for their
> acceptance. The S5 and RFS families remain deliberately deferred. The tables
> below remain normative for atomic grouping and for constants that must not be
> converted merely because they resemble 2 KiB page geometry.

## Scope

This note follows `PRODUCER-CONSUMER-ASYMMETRY-TASK.md`. It is a cross-function
audit of the current 040 image, not another list of every `#0x800` instruction.
The question is whether one function publishes a page-granular object or
argument in 4 KiB units while another function sizes, indexes, walks, or
consumes it in 2 KiB units.

Pinned image:

```text
build/unix-040
68040-260725-09
SHA-256 0bf2c5c075abe26eb5a4a9bfb43d616126792a4d6d09b23e6489c40066f08f07
```

The scan was repeated against this image with
`vm-map/scan_modelb_residuals.py`. The raw output is treated as a candidate
generator only. The final classification uses the patch scripts, current
symbols, 3B2/SVR4 source shape, and the existing function-level audits.

## Model boundaries

These units must not be conflated:

| Unit | Current meaning | Examples |
|---|---|---|
| VM page | 4096 bytes | `page_t`, HAT leaf, `PAGESIZE`, `PAGESHIFT=12` |
| Segmap slot | 8192 bytes | `MAXBSIZE`, `0x2000`, slot offset mask `0x1fff` |
| UFS block | 8192 bytes on the measured root filesystem | `fs_bsize` and UFS block allocation |
| UFS fragment | 1024 bytes on the measured root filesystem | on-disk allocation unit |
| Disk sector | 512 bytes | `btodb`, `<<9`, `>>9` |
| Page hash bucket | old `>>11` hash transform | valid when all hash users agree |

An old-looking constant in one of the last four domains is not an asymmetry
merely because it contains `0x800` or shift 11.

## Executive result

| Priority | Boundary | Current result | Reachability |
|---|---|---|---|
| P1 | `rwip -> ufs_bmap` | 4 KiB `alloc_only` caller meets mixed UFS internals | local UFS write path, high |
| P1 | `pvn_vptrunc` -> page/writeback lifetime | final-page tail remains 2 KiB-shaped | local truncate/write path, high |
| P1 | NFS get/putpage -> common PVN | common machinery is 4 KiB; NFS provider remains partly 2 KiB | NFS mount/read/write, medium |
| P1 | exec mapping -> 4 KiB VM | initial stack is fixed; live ELF header/map residuals remain mixed | every `exec`, high |
| P2 | public VM syscall/protection perimeter -> segment VM | some user-range and vector consumers remain old-shaped | user mmap/protection/proc paths |
| P2 | `d_mmap`/`segdev` -> `hat_devload` | old PFN/iteration domain crosses native 040 HAT | device mmap/Z3, optional |
| P2 | page counters -> byte consumers | current image's `kmem_avail`/pageout-default conversions are landed; runtime closure remains | active accounting |
| P2 | SysV SHM/Xenix -> `segvn` | old array/range units cross the 4 KiB segment VM | API-dependent |
| P3 | RFS/S5 -> common PVN | old providers meet 4 KiB common code | not mounted in pinned environment |

No new asymmetry was found in the already-fixed mlock bitmap, hot swap-in,
local UFS/specfs page-list core, local pagecreate live group, or local BIO/DMA
mapping group.

## P1: UFS allocation and pagecreate boundary

### `rwip -> ufs_bmap`

| Producer/consumer | Shared object or argument | Current producer | Current consumer | Consequence |
|---|---|---|---|---|
| `rwip` -> `ufs_bmap` | `alloc_only` | 4 KiB pagecreate decision | old and new UFS page-size branches are mixed | read-before-write decisions can differ |
| `segmap_pagecreate` -> `rwip` | created page and tail bound | complete 4 KiB page | `rwip` now zeros through 4 KiB | closed for the live UFS path |
| `ufs_putpage` -> disk BIO | dirty page and I/O length | 4 KiB page and length | `ufs_writelbn` accepts that range | full last page can be written past `i_size` |

The detailed result is in
`PAGECREATE-REACHABILITY-AND-UFSBMAP.md`. `ufs_bmap` has eleven VM-page
geometry sites, not merely the eight listed in the brief. Three other
`moveq #11` sites are `NDADDR-1` direct-block thresholds and must remain
unchanged.

The mixed state is not currently classified as an immediate misallocation on
the 8 KiB root filesystem. In the active indirect branch, old 2 KiB rounding
can select an extra `fbread` where 4 KiB rounding would skip it. That is a
real contract mismatch and can mask the pagecreate defect, but the static
evidence does not show a required read being skipped in that interval.

Atomic unit:

```text
all eleven ufs_bmap VM-page sites
  + rwip alloc_only/pagecreate review
  + direct, fragment-growth, indirect, and synchronous-write tests
```

Acceptance must cross a writeback/reboot or cache-eviction boundary. A
same-process read is not enough because `fbread` can retain the resident page.

## P1: `pvn_vptrunc` tail producer

`pvn_vptrunc` at `0xb2370` still computes the final page tail with the old
2 KiB boundary (`+0x7ff`, `&-0x800`, and the associated subtraction). The
shared object is the final partial page in the vnode page cache:

```text
pvn_vptrunc -> page contents after new EOF
             -> VOP_PUTPAGE / page_abort / page_free consumers
```

The page allocation and provider writeback units are 4 KiB. If truncation
leaves bytes in the upper half of the final 4 KiB page, a later extension or
writeback can expose them.

Verdict: **active correctness asymmetry**.

Atomic unit:

```text
pvn_vptrunc tail rounding + page-cache re-extension/writeback test
```

Acceptance: write a recognizable pattern across a 4 KiB page, truncate at
offsets in both halves, force sync/cache eviction, extend or read the affected
range, and compare the never-written interval with zero. The test must
distinguish page-cache reuse from persistent disk contents.

## P1: NFS provider versus common PVN

The common page-list machinery is 4 KiB-shaped:

```text
page_get -> pvn_kluster -> pvn_getpages -> pageio_setup -> pvn_done
```

The current NFS provider is not. Relevant functions are:

```text
nfs_getpage  0x8b5d4
nfs_getapage 0x8b14c
nfs_putpage  0x8b7e8
rwvp         0x88d4c
```

| Boundary | 4 KiB side | 2 KiB side | Consequence |
|---|---|---|---|
| `as_iolock/rwvp` -> `nfs_getpage` | caller length/plsz and `rwvp` tail zero | provider threshold/EOF math | wrong one-page/multi-page routing |
| `nfs_getapage` -> PVN/pageio | common page list and page identity step | provider `io_len`, countdown, read-ahead rounding | page can be allocated while only half is described |
| `pvn_range_dirty` -> `nfs_putpage` | common dirty range | NFS provider writeback | dirty remote pages can be under-described |

The local `rwvp` tail-zero sites are already converted. That closes the
foreground producer but not NFS page-in or remote writeback.

Verdict: **real provider boundary asymmetry, environment-dependent**.

Atomic read unit:

```text
segmap_faulta request length
  + nfs_getpage wrapper
  + nfs_getapage page-list/io_len/read-ahead sites
```

Atomic writeback unit:

```text
pvn_range_dirty/common callers + nfs_putpage + NFS strategy/pageio tests
```

Acceptance: NFS read and read-only mmap across 4 KiB boundaries, then dirty
remote pages followed by sync/reboot and byte comparison. No runtime closure
claim should be made while NFS is unavailable.

## P1: exec boundary

The one-page initial-stack producer has already been fixed:

```text
exec_initialstk = 0x1000
extractarg initial-stack arithmetic = 4 KiB
```

That does not close the entire exec contract. The remaining `execmap`, live ELF
header-cache (`exhd_getfbuf`/`exhd_nomap`), and one `elfexec` boundary check
still contain old page rounding or byte/page conversions. The detailed current
classification, including deferred COFF/core work and the `hat_exec` no-op
compatibility result, is in `EXEC-BOUNDARY-CENSUS.md`.

| Producer | Consumer | Current split | Consequence |
|---|---|---|---|
| exec header/file-size rounding | `execmap`/`as_map` segment size | old boundary/accounting in parts of exec | wrong mapping end or accidental policy preservation |
| `execmap` range | `segvn_create`/`segvn_fault` | 2 KiB-derived range meets 4 KiB anon/vpage | last-page coverage can differ |
| ELF page counts | limits/accounting | one residual conversion is still unit-conditional | wrong limit or accounting |

Verdict: **active high-reachability asymmetry**. It is more important than its
raw site count because every normal `exec` exercises some part of this
boundary.

Atomic unit: the executable format path being enabled, starting with ELF,
including header read, map range, initial stack, and accounting. Acceptance is
repeated `exec` of binaries whose last text/data page ends at offsets 1, 2047,
2048, 4095, and 4096, plus process map/protection checks.

## P2: public VM and protection-vector perimeter

The public syscall layer is another producer-consumer boundary. The live
segment/HAT machinery operates on 4 KiB pages, but retained `mmap`, `munmap`,
and `mprotect` validation/range sites still accept or round some addresses and
lengths using the old 2 KiB boundary. This allows a caller to present a
2 KiB-aligned range which the segment layer later normalizes to a different
4 KiB leaf range.

`mincore` is now fixed in the current image at its public alignment and vector
length sites. It is therefore not an open generic `mincore` producer. However,
the `as_incore -> segdev_incore` device path still crosses into a retained
2 KiB segdev vector walk and is covered by the device-mmap unit below.

The protection-vector family is more mixed:

```text
as_getprot / segmap_getprot / segdev_getprot
  -> procxmt / ptrace / procfs reporting consumers
```

Several of these sides still use old page-entry counts and old range rounding,
while the ordinary `segvn` protection state is a 4 KiB per-page domain. The
old values inside the generic/proc family are often mutually consistent, so
this is not always a memory corruption bug. It is still a contract mismatch at
the public range and vector boundary, with possible overlong vectors,
misreported protections, or half-page operations.

Verdict: **reachable API asymmetry, lower priority than the data-integrity
units**.

Atomic unit:

```text
mmap/munmap/mprotect alignment and range math
  + as_getprot/segmap_getprot/segvn_getprot/segdev_getprot
  + ptrace/procfs vector consumers
```

Acceptance: use 2 KiB-aligned but 4 KiB-misaligned addresses and lengths at
both sides of a page boundary; verify the exact accepted/rejected range,
protection vector length, and no operation on an adjacent leaf.

## P2: device mmap and PFN boundary

The retained `segdev` family is internally still old-shaped: fault, unmap,
protection, incore, and fork loops use 2 KiB steps. The live HAT consumer is
040-native and expects a 4 KiB PFN:

```text
d_mmap -> spec_segmap/segdev_fault -> hat_devload -> hat_pteload040
```

Device PFN producers (`scrmmap`, `ammmap`, `timmap`, `mmmmap`, and `resmmap`)
still include old `phys >> 11` helpers or old range policy.

| Part | Current state |
|---|---|
| `hat_pteload040` PFN consumption | 4 KiB (`pfn << 12`) |
| `d_mmap` PFN production | several old 2 KiB helpers |
| `segdev_fault` iteration | old 2 KiB loop |
| `segdev` lifecycle methods | largely mutually consistent old family |

This is an old-domain-to-native-HAT boundary. The first mapping can appear to
work while a multipage map, `mprotect`, `mincore`, or unmap crosses the contract
incorrectly.

Verdict: **critical for Z3/device mmap, optional for the current boot path**.

Atomic unit:

```text
public mmap alignment + spec map accounting + all d_mmap PFN producers
  + segdev fault/unmap/protection/incore/dup + 040 HAT device-load contract
```

Acceptance: a minimal device whose `d_mmap` returns a known physical window,
with one- and multi-page read/write, `mprotect`, `mincore`, fork/dup, and
unmap tests. Both halves of a 4 KiB page must return the same 4 KiB PFN.

## P2: page counters and byte consumers

### `kmem_avail` (conversion landed)

The earlier census identified an old `<<11` conversion. The current pinned
image has the corresponding conversion corrected by the landed ISSUE-15
change. The remaining work here is runtime/accounting verification, not a new
static patch candidate.

Verdict: **static conversion closed; runtime closure pending**.

Acceptance: compare the reported byte value against
`(availrmem - t_minarmem) << 12` while creating/destroying STREAMS buffers and
under low-memory pressure.

### `vmmeter` and `maxpgio` (conversion landed)

The earlier census also identified the stale `MAXBSIZE / 2048` page-rate
conversion. The current image has the pageout-default conversion corrected by
the landed `patch_pageoutdefs.py` change. `maxpgio` remains a page-rate
policy value, not a physical-page address.

Verdict: **static conversion closed; deterministic policy acceptance remains**.

The `minfree/desfree/lotsfree` values are different: they are page-count
policy values consumed as page counts. Their byte interpretation changed, so
they need policy review, not a mechanical producer-consumer patch.

## P2: SysV shared memory and Xenix shared data

`shmget`, `shmat`, `shm_lock`, `shm_unlock`, and `shm_rm_amp` retain old
page-count, anon-array, or range arithmetic. Their shared-memory object is
then attached to the 4 KiB `segvn`/anon/HAT machinery.

| Shared object | Producer side | Consumer side | Consequence |
|---|---|---|---|
| anon pointer array/size | `shmget`/`shmat` old allocation and rounding | `segvn_create`, `segvn_fault`, `anon_dup/free` | wrong slot count or tail coverage |
| lock range | `shm_lock`/`shm_unlock` old iteration | segvn/HAT soft-lock and page counters | wrong pages locked/unlocked |
| attach/detach range | old attach/remove arithmetic | `as_map`/`as_unmap` and native HAT | partial-range mismatch |

Verdict: **reachable API asymmetry**, but not normal boot. Treat the whole SHM
family as one unit. Acceptance uses sizes 1, 2047, 2048, 4095, 4096, and 8193
bytes with attach, fork, lock/unlock, detach, and removal.

`sdatt_common` has the same shape for Xenix shared data: old `btopr`/`ptob`
and anon-pointer array geometry crosses into current segment VM. It is a
separate lower-priority unit. `sdget`/`creatsem` `0x800` mode constants are
not page geometry.

## P3: RFS and S5 provider boundaries

The common PVN/page-list side is 4 KiB, while retained RFS and S5 providers
still contain old page rounding:

```text
common pvn_kluster/pvn_getpages/pvn_done or pvn_range_dirty: 4 KiB
RFS/S5 getpage/putpage/writei providers: old or mixed geometry
```

For S5, `writei` remains a direct `segmap_pagecreate` consumer with old
tail-zeroing arithmetic. For RFS, page-list and network transfer helpers retain
old units. Neither filesystem is mounted in the pinned environment.

Atomic units:

```text
S5: writei + pagecreate tail + s5getpage/s5putpage + block-size policy
RFS: rf_getpage/rf_getapage + rf_putpage + common PVN + network transport
```

These are static findings until the corresponding filesystem is mounted and
tested. A local UFS test cannot close either unit.

## Closed boundaries

| Boundary | Result |
|---|---|
| mlock bitmap: `as_ctl`/`segvn_lockop` -> `memcntl`/`mem_unlock` | **Closed.** Producer, sizing, rollback, and unlock walk use 4 KiB. `textlock`/`datalock`/`ublock` `moveq #11` values are errno constants. |
| hot swap-in: `segvn_faultpage` -> `anon_getpage` -> spec provider | **Closed in current image.** `plsz`, VOP length, `klustsize`, provider gate, and `pvn_fail` are 4 KiB. Older notes saying `klustsize=0x800` are stale for this image. |
| local page list: `page_get` -> `pvn_kluster`/`pvn_getpages`/`pvn_done` | **Closed.** Allocation count, offset stride, and completion walk agree. |
| local pagecreate: producer -> `as_iolock`/`rwip`/`rwvp`/`fbzero`/`spec_write` | **Closed for landed groups.** Deferred S5 `writei` remains separate. |
| local BIO/DMA: `gen_strategy`/`bp_map040` -> pageio/DMA | **Closed for verified local disk path.** Real-HW NFS-to-local copies passed after `bp_map040`. |
| `segvn` anon/vpage lifecycle | **Internally closed as a 4 KiB family.** Device `segdev` is a separate old family. |
| native `segkmem040` tables -> `krnxmemflt_orig` | **Inactive fallback residual.** The native kvseg fault path is 040-shaped; the retained old resolver is reached only by the `/dev/kmem` crash/probe path and is not a normal producer of live mappings. |
| `startio`/`vtop` address dispatch -> DMA bounce buffer | **Closed.** Dispatch remains address-first; `b_proc` is not used as a replacement discriminator. |
| page hash helpers | **Not an asymmetry.** Hash producers and consumers use the same transform; do not change shift 11 locally. |
| segmap slots | **Not an asymmetry.** `0x2000`, `0x1fff`, and shift 13 describe the 8 KiB slot. |
| sectors/filesystem blocks | **Not an asymmetry.** `>>9` and UFS block/fragment values have independent contracts. |
| retained old HAT/SDT code | **Inactive mixed-domain risk.** `hat_map`/`hat_swapout` and old allocation fallbacks are covered by HAT retirement audits, not mechanical page patches. |

## Ranking and implementation order

1. Close `pvn_vptrunc` and complete the UFS `ufs_bmap`/cold-cache proof.
2. Execute the live ELF exec acceptance matrix from `EXEC-BOUNDARY-CENSUS.md`.
3. Resolve the remaining conditional `elfexec` field-unit proof, then decide
   whether NFS is a supported 040 target; if yes, convert/test its
   getpage and putpage units.
4. Complete the `kmem_avail`/`vmmeter` runtime accounting checks.
5. Port the device mmap/segdev family for Z3 and framebuffer work.
6. Port SysV SHM and Xenix shared-data families according to feature scope.
7. Leave RFS/S5 deferred until their filesystems are mounted and testable.

## Bottom line

The producer-consumer method finds real remaining work, but also prevents false
positives. The two accidental discoveries were not isolated anomalies: the
same boundary failure remains in UFS allocation, NFS providers, exec
accounting, device mmap, and a few page-counter consumers. Meanwhile the
earlier mlock-bitmap and hot swap-in asymmetries are closed in the current
image. The remaining work is now feature- and filesystem-scoped atomic units,
not an unbounded search for isolated `0x800` literals.
