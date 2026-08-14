# 68040/68060 CM and PTE Writer Implementation Matrix

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/CM-PTE-WRITER-MATRIX.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Current implementation status

This is the pre-implementation writer census for the cache-mode campaign. The
statements below that describe B1 or B2 as pending are historical gates, not
the state of the current port. The current link ships managed RAM as copyback
(`hat_cm_ram = 0x20`), includes the A3091/SDMAC prepare/complete hooks, and has
passed the 68040 and 68060 hardware acceptance recorded in `STATUS.md` and the
local real-hardware reports.

The matrix remains normative for PTE classification, the old-byte anchors,
descriptor-publication order, and the distinction between managed RAM and
non-cacheable device or u-area mappings. Driver families outside the accepted
A3000/A3091 configuration remain outside that acceptance surface; their rows
are requirements if those paths are enabled later.

## Scope and target

This is the implementation basis for the data-cache CM campaign. It inventories
every identified writer of the live 68040 page-table tree, separates those
writers from retained 030 shadow-tree code, and assigns:

- the cache mode emitted by the current build;
- the B1 writethrough target;
- the B2 copyback target;
- the descriptor and mapped-data cache operations required by each path.

No kernel file or binary is modified by this analysis.

Target:

- kernel commit:
  `4aad0a95f409ebf98e8a0ff606b34cbba1693618`
- `build/unix-040` SHA-256:
  `bc5a43e6f8dc6ecd1854e11864e458eac2e473b40be08132a9096f2b6e2764ee`
- ELF `.text` address/file-offset relation: `file_offset = address + 0x34`

The evidence combines:

- the repository's relocation-enriched Ghidra symbol/call mapping;
- independent ELF relocation and GNU disassembly checks of the linked image;
- the relinked 040 assembly sources under `kernelsupport/prototypes`;
- the byte-identical AMIX `vm/exp` object where applicable;
- the 3B2 SVR4 source as semantic reference, not as AMIX byte provenance.

Addresses in this note are linked `.text` addresses in the target above.

## Verdict

B1 is not ready as only a `hat_pteload` change. Six coupled implementation
groups are required:

1. Apply one cache-class selector to all three `hat_pteload` leaf stores.
2. Keep both the fixed u-area and every `segu` window noncacheable.
3. Publish newly zeroed roots and reorder whole-AS teardown before table reuse.
4. Port the active direct-`kptbl` `segkmem` writers to 4 KiB geometry and add a
   descriptor-publication protocol.
5. Assign the same managed-RAM class to the native `hat_dup` and `bp_map`
   constructors.
6. Keep the retained 030 HAT tree writers unreachable instead of giving them
   040 CM bits.

The u-area point is easy to miss. `pstart` initially installs the fixed u-area
with `CM=11`. `resume` path U preserves the current fixed-PTE flags, but path V
overwrites the fixed PTEs by copying whole leaves from `kvsegu`. Those `kvsegu`
source mappings are normally writethrough today. Therefore changing only
`pstart` and `hat_pteload(pp != NULL)` does not preserve the intended u-area
policy.

One additional B1 blocker is independent of cache mode:
`segkmem_setprot` still computes a 2 KiB PTE index and advances by `0x800`.
It must be ported together with `segkmem_checkprot` and `segkmem_getprot`
before a data-cache build can claim complete protection/CM preservation.

## 68040 leaf format used here

Only the low byte is relevant to this campaign:

| Bit(s) | Mask | Meaning |
|---|---:|---|
| `S` | `0x80` | supervisor-only |
| `CM` | `0x60` | cache mode, bits 6:5 |
| `M` | `0x10` | modified |
| `U` | `0x08` | used |
| `W` | `0x04` | write-protect |
| `PDT` | `0x03` | descriptor type; resident page is `0x01` |

Cache-mode values:

| CM bits | Low-byte value | Class used in this note |
|---|---:|---|
| `00` | `0x00` | cacheable writethrough (`WT`) |
| `01` | `0x20` | cacheable copyback (`CB`) |
| `10` | `0x40` | noncacheable serialized (`NCS`) |
| `11` | `0x60` | noncacheable (`NC`) |

This corrects one earlier wording error: `0xe1` is
`S | NC | resident`. It does **not** have `U` or `M` set.

The current `bp_map` value `0x19` is `resident | U | M`, with `CM=00` and no
`S` bit. Its kernel-only accessibility follows from the active root and VA,
not from a supervisor bit in that leaf.

## Campaign stages

The stage definitions are taken from the current kernel roadmap:

| Mapping class | Current | B1 | B2 |
|---|---|---|---|
| managed ordinary RAM | mostly `WT` | `WT` | `CB` |
| unmanaged PFN / MMIO registers | mostly `WT` | `NCS` | `NCS` |
| `segu` and fixed u-area | mixed: fixed `NC`, windows usually `WT` | `NC` | `NC` |
| framebuffer or coherent aperture | no explicit class | `NCS` default | explicit later policy; never infer from `PROT_USER` |
| page-table descriptors | no leaf CM semantics | accessed through current DTT0 NC alias | retain a defined uncached descriptor alias or implement the protocol below |

B1 keeps `DTT0` unchanged and enables writethrough data caching for ordinary
RAM. It still requires completion-side invalidation for DMA reads.

B2 changes ordinary RAM to copyback and additionally requires complete DMA
prepare/complete hooks and coherent handling of low-physical aliases.

## Required cache-class selector

`hat_pteload` already has the managed-versus-unmanaged discriminator:

```text
hat_memload -> pp != NULL
hat_devload -> pp == NULL
```

That discriminator needs one higher-priority exception:

```text
if mapping belongs to the segu segment:
        CM = 0x60                    /* NC in B1 and B2 */
else if pp == NULL:
        CM = 0x40                    /* NCS in B1 and B2 */
else if stage == B1:
        CM = 0x00                    /* WT */
else:
        CM = 0x20                    /* CB */
```

The implementation can identify `segu` by exact segment identity
(`seg == segu`). Checking `seg->s_ops == &segu_ops` is a useful defensive
assertion, but should not silently classify an unrelated segment.

Before composing a complete PTE:

```text
status = (status & ~0x60) | selected_cm
pte = (pfn << 12) | status
```

Do not OR a new CM value into an unmasked template. Do not use `prot & 8`;
`0x8` is `PROT_USER`, and `hat_pteload` reduces protection to `prot & 7`
before each current constructor.

## Census closure

The inventory was closed with four independent searches:

1. Relocation-backed call/reference walks for `hat_memload`, `hat_devload`,
   `hat_pteload`, `vatosde`, `vatopte`, `kptbl`, `kptr040`, and `kroot040`.
2. Complete-store and bitfield-store review in every native 040 HAT routine.
3. Direct linear-`kptbl` review of the retained `segkmem` and `sptfree`
   routines.
4. A whole-image `cpusha bc` census.

The current image has exactly these table-publication `cpusha bc` sites:

```text
pstart, hat_pteload, hat_pageunload, hat_unload, hat_free,
hat_chgprot, hat_pagesync, hat_dup, prumap, bp_map, bp_mapout, resume
```

The identified live writers without one are exactly the important gaps in this
matrix:

```text
sysseginit
hat_alloc root initialization
hat_ptalloc table initialization (publication is caller-owned)
segkmem_setprot/alloc/free/mapin/mapout (only bare flushmmu where present)
sptfree(flag=0)
```

The `kptr040` references not represented as writers here resolve to walkers or
readers such as `vatosde`, `vtop`, `ptest`, and `krnxmemflt040`. The only
retained old-tree writers are listed separately under Legacy/shadow writers.

## Full live-writer matrix

The cache-operation column distinguishes:

```text
DATA     cache operation for bytes in the mapped physical page
DESC     publication/invalidation for page-table descriptor memory
ATC      translation-cache invalidation
```

`PUB` below means: make the descriptor store visible to the table walker, then
invalidate any translation that may contain the old value. The conservative
pilot implementation is `cpusha bc; pflusha`; the ordering rules are specified
later.

| Writer/path | Live effect | Current CM | B1 target | B2 target | Required cache operation / verdict |
|---|---|---|---|---|---|
| `pstart`, fixed u-area leaves `0xd743e`, `0xd744e` | installs two live leaves | `NC` via `0xe1` | `NC` | `NC` | Existing final `cpusha bc; pflusha`; keep |
| `pstart`, root/pointer descriptors `0xd7462`, `0xd7474` | builds initial live kernel tree | N/A | N/A | N/A | Existing final `PUB`; child tables are initialized before parents |
| `sysseginit` loop `0xd759a` | installs live `kptr040` pointer descriptors | N/A | N/A | N/A | No current `PUB`; add publication before any first walk |
| `hat_alloc` `0xd80d8..0xd80e6` | zeroes a new 4 KiB user root, then exposes it through `as->hat_root` | N/A | N/A | N/A | B1 WT makes zero stores visible, but add explicit root publication; B2 requires a push before storing/exposing the root pointer |
| `hat_pteload`, root descriptor `0xd7802` | invalid-to-valid root pointer | N/A | N/A | N/A | Common final `PUB`; retain |
| `hat_pteload`, B descriptor `0xd78ce` | invalid-to-valid leaf-table pointer | N/A | N/A | N/A | Common final `PUB`; retain |
| `hat_pteload`, same-PFN store `0xd79de` | rewrites complete leaf | `WT` | classifier | classifier | If CM changes, purge DATA under old class first; then complete store and `PUB` |
| `hat_pteload`, fresh store `0xd7a4e` | installs complete leaf | `WT` | classifier | classifier | Complete store and existing `PUB`; DMA/page-ownership maintenance is caller/domain work |
| `hat_pteload`, replacement store `0xd7b46` | replaces mapped PFN | `WT` | classifier | classifier | Harvest old U/M and clean old DATA before replacement/release; complete store and `PUB` |
| `hat_pageunload` `0xd7c70` | harvests U/M and clears all reverse-mapped leaves | preserved until clear | preserve, then invalid | preserve, then invalid | Drain old translation; harvest; B2 clean DATA before page reuse; clear; existing final `PUB` |
| `hat_unload` `0xd7fe0` | harvests U/M, clears range leaves | preserved until clear | preserve, then invalid | preserve, then invalid | Same ordering; final `PUB` must occur before any mapped page/table can be recycled |
| `hat_free`, leaf clears `0xd8388`, `0xd8392` | tears down address-space leaves/tables | preserved until clear | preserve, then invalid | preserve, then invalid | B2 DATA cleanup and descriptor publication must precede `hat_ptfree`/reuse; final-only push is not a sufficient ownership proof |
| `hat_free`, root clear `0xd83c2` | detaches pointer table | N/A | N/A | N/A | Clear and `PUB` before freeing child table |
| `hat_chgprot` `0xd860a`, `0xd861c`, `0xd8624` | changes W/V, preserves other bits | preserved | preserve | preserve | No DATA purge for protection-only change; existing final `PUB` |
| `hat_pagesync` `0xd86a0` | harvests then clears U/M only | preserved | preserve | preserve | Read current U/M before store; store with CM unchanged; existing final `PUB` |
| `hat_exec` `0xd86b8` | native live entry is a no-op | none | none | none | No writer; keep the retained 030 body unreachable |
| `hat_dup`, root descriptor `0xd87d8` | installs child pointer table | N/A | N/A | N/A | Existing final `PUB` |
| `hat_dup`, B descriptor `0xd8a60` | installs child leaf table | N/A | N/A | N/A | Existing final `PUB` |
| `hat_dup`, private child leaf `0xd8d46` | constructs new managed mapping | `WT`, status `1` | `WT` | `CB` | Add stage CM to constructor; existing final `PUB` |
| `hat_dup`, parent W change `0xd8e72` | clears W bit only | preserves CM | preserve | preserve | Existing final `PUB` |
| `hat_dup`, shared child leaf `0xd8e80` | copies parent PTE wholesale | copies CM | copy parent | copy parent | Assert parent class matches stage; existing final `PUB` |
| `prumap` `0xd95f0`, `0xd95fe` | writes `kvsegu` slot-0 u-area leaves | inherits low 12 bits, normally `WT` | `NC` | `NC` | Force `CM=0x60`, do not inherit CM; current `cpusha` is enough only for invalid slots, conservative `PUB` preferred |
| `bp_map` `0xd9932` | temporary managed page alias | `WT` via `0x19` | `WT` | `CB` | Constructor must select RAM class; existing `PUB`; DMA prepare/complete remains at controller ownership boundary |
| `bp_mapout` `0xd99d2` | clears temporary aliases | invalid | invalid | invalid | Existing `PUB`; purge DATA only when ownership/direction requires it, not merely because a same-class alias disappears |
| `resume`, path U `0xd9b58`, `0xd9b66` | rebuilds PFNs from `p_ubptbl` while preserving current fixed-leaf flags | normally `NC` | `NC` | `NC` | Normalize/assert `CM=0x60` defensively; existing `PUB` |
| `resume`, path V `0xd9b9e`, `0xd9bd8` | copies `kvsegu` leaves wholesale | copies source CM | `NC` | `NC` | Source should already be NC, but normalize/assert anyway; existing `PUB` |
| `segkmem_setprot` clear `0xa84a6` / bit store `0xa84ac` | direct linear `kptbl` writer | preserves CM on nonzero path | preserve | preserve | **Blocker:** port 2 KiB index/step first; add `PUB`; clear path also needs teardown ordering |
| `segkmem_alloc` `0xa8754` | constructs managed kernel leaves | `WT` | `WT` | `CB` | Add explicit class, descriptor push before current `flushmmu`; B2 page initialization/alias contract |
| `segkmem_free` `0xa8812` | clears leaves and frees backing pages | invalid | invalid | invalid | B2 clean DATA before free; clear and push descriptors before page reuse; current bare `flushmmu` is insufficient |
| `segkmem_mapin` `0xa8a2c` | installs caller-template leaf | inherits template, normally `WT` | managed `WT`, unmanaged `NCS` | managed `CB`, unmanaged `NCS` | Resolve `page_t`; mask old CM and assign class; descriptor push before current `flushmmu` |
| `segkmem_mapout` `0xa8b24` | clears V but leaves stale PFN/CM in invalid word | stale, invalid | invalid | invalid | Ownership-dependent DATA cleanup; descriptor push before current `flushmmu` |
| `sptfree(flag=0)` `0xa8cd0` | directly clears linear `kptbl` entries | invalid | invalid | invalid | No current cache/ATC operation; add full teardown publication or reject/guard this ABI path |

### Requested non-writer row: `krnxmemflt040`

The current native `krnxmemflt_orig` at `0xd9bec` validates the live
`vatosde`/`vatopte` walk and reads a leaf. It does not write a PTE or a
descriptor. On an invalid/protection fault it delegates through `as_fault`;
the eventual leaf writer is `hat_pteload`.

Therefore its CM entry is:

```text
current CM: N/A
B1/B2:      no local PTE change
cache op:   none locally; requires all producer descriptors to have been
            published before this reader walks them
```

The previously documented stock `F_PWRITE` direct 030 walk is not the current
implementation and must not be patched a second time.

## Table initialization and descriptor writers

The valid-descriptor stores above are not the only writes to table memory.
Initialization and retirement have their own ordering:

| Path | What it initializes | Current behavior | Contract |
|---|---|---|---|
| `hat_ptalloc` reuse path `0xb6904` | reused table page | `bzero(..., 0x1000)` | Caller must publish before installing/using a parent |
| `hat_ptalloc` new-page path `0xb6a7a` | PTE half of first leaf fragment | `bzero(..., 0x100)` | Sufficient for 64 leaves; callers using it as a 128-entry pointer table explicitly zero 512 bytes |
| `hat_alloc` `0xd80d8` | complete 4 KiB user root | `kmem_zalloc(0x1000)`, immediately stores pointer at `0xd80e6` | Push the zeroed root before it can be selected by URP; expose `as->hat_root` only after publication |
| `hat_pteload` root-table allocation | 128 pointer descriptors | explicit 128-long clear, then root store | Push initialized child before publishing parent |
| `hat_dup` root-table allocation | 128 pointer descriptors | explicit 128-long clear, then root store | Same |
| `hat_ptfree` `0xd83fe` | software/page allocator teardown | does not itself detach a hardware parent | Caller must clear and publish parent before calling it |
| `hat_sdtalloc` / `hat_sdtfree` | retained AMIX software/legacy SDT allocator | not a native live-040 descriptor constructor | Do not add CM logic; keep live-tree callers bounded as documented in `HAT-SDT-ALLOC-FREE-POLICY.md` |

For a newly allocated hierarchy:

```text
zero child table
push child-table initialization if that alias can be cached
store valid parent descriptor
push parent descriptor
invalidate ATC before first possible walk
```

For replacement or teardown:

```text
stop new users of the mapping
complete required DATA clean/invalidate
make the old U/M state observable
harvest U/M
clear or replace leaf/parent
push descriptor store
invalidate ATC
only then release/reuse the mapped page or table page
```

With the current unchanged DTT0, the low-physical aliases used by these HAT
walkers are noncacheable, so a descriptor push is often redundant in B1.
The explicit protocol is still required as an implementation invariant: it
prevents B1 from silently depending on DTT0 and is mandatory if descriptor
memory later becomes cacheable or DTT0 is narrowed.

### Whole-AS allocation/free ordering

`hat_alloc` obtains its root through the normal kernel mapping returned by
`kmem_zalloc`, not through the HAT's low-physical descriptor alias. In B2,
zeroing can therefore remain dirty in copyback cache while a context switch
loads the new root into URP. Publish the zeroed root before writing
`as->hat_root`.

The current `hat_free` order is also not a B2 teardown contract:

```text
0xd839c  hat_ptfree(leaf)
0xd83b4  hat_ptfree(pointer_table)
0xd83c2  clear root[A]
0xd83d4  kmem_free(root)
0xd83e4  cpusha bc
0xd83e6  pflusha
```

The final push occurs after child and root memory may already have entered an
allocator. A data-cache build must detach and publish leaves/parents before
their table pages are reusable, and publish/retire the root before
`kmem_free(root)`. A final whole-cache operation after the frees is too late
to prove that dirty descriptor lines cannot overwrite newly allocated data.

## Direct `segkmem` blocker

`segkmem_setprot` is not merely missing a CM choice. The target bytes prove it
still has Model-A geometry:

```text
0xa8474  72 0b                  moveq #11,d1
0xa84a6  42 9a                  clrl (a2)+
0xa84ac  ef ea 41 41 00 03      bfins d4,a2@(3){5:1}
0xa84b2  06 82 00 00 08 00      addil #0x800,d2
```

The direct `kptbl` family should be ported as one unit:

```text
segkmem_setprot
segkmem_checkprot
segkmem_getprot
```

The port needs 4 KiB indexing/stepping, live-range bounds, CM preservation,
descriptor publication, and tests across a leaf-table boundary. A local
`moveq #11 -> #12` edit without auditing the index formula and the companion
readers is not an acceptable CM-campaign patch.

## Legacy/shadow writers

These routines can write memory shaped like the old 030 HAT, but they do not
construct accepted live 040 mappings:

| Path | Current status | CM-campaign policy |
|---|---|---|
| early old `pstart` SDE/kuptr setup | retained bootstrap shadow before native tree | Do not translate its CI bits into 040 leaf CM |
| `kvm_init` old `st_top1` SDE setup | shadow bookkeeping | Do not use as live CM authority |
| `p0init` old PTE setup | shadow/`p_ubptbl` producer | Only its software physical values may be consumed; normalize CM at live writer |
| `segu_get` / `swapinub` `p_ubptbl` rebuild | software shadow for context switch | Physical identity only; never inherit 030 low flag bits as policy |
| `hat_map` `0xb57e0` and `hat_growsdt` | old SDE geometry; preload branch is skipped by `0xb58d2: 60 00 00 12` | Retire/bypass; no 040 CM patch |
| `hat_swapout` `0xb4360` | stock 030 walker and 030-format bit operations | Must remain unreachable under the replacement scheduler |
| retained stock `hat_exec` body | old SDE/PTE mover | Live `hat_exec` is the native no-op; keep old body unreachable |

`hat_map` deserves a precise warning: the current unconditional branch skips
its vnode preload body, but the earlier `hat_growsdt` call can still update
legacy state. It is a shadow writer, not evidence that a live 040 PTE has the
right CM.

## Byte assertions for the current target

These assertions identify the present implementation before any CM patch.
They are not generic search-and-replace patterns. Abort if the target hash or
any asserted site differs.

| Purpose | Text address | Current bytes |
|---|---:|---|
| fixed u-area page 0 class | `0xd743e` | `00 81 00 00 00 e1` |
| fixed u-area page 1 class | `0xd744e` | `00 81 00 00 00 e1` |
| `sysseginit` pointer store | `0xd759a` | `20 83` |
| `hat_pteload` root store | `0xd7802` | `21 81 08 00` |
| `hat_pteload` B store | `0xd78ce` | `26 80` |
| `hat_pteload` same-PFN leaf store | `0xd79de` | `28 83` |
| `hat_pteload` fresh leaf store | `0xd7a4e` | `28 83` |
| `hat_pteload` replacement leaf store | `0xd7b46` | `28 83` |
| `hat_pageunload` clear | `0xd7c70` | `42 93` |
| `hat_unload` clear | `0xd7fe0` | `42 92` |
| `hat_alloc` publishes root pointer | `0xd80e6` | `25 48 00 14` |
| `hat_free` root clear | `0xd83c2` | `42 b5 08 00` |
| `hat_pagesync` complete store | `0xd86a0` | `22 80` |
| live `hat_exec` no-op | `0xd86b8` | `42 80 4e 75` |
| `hat_dup` private leaf store | `0xd8d46` | `20 84` |
| `hat_dup` shared leaf copy | `0xd8e80` | `20 91` |
| `prumap` inherited-flag mask | `0xd95e2` | `02 85 00 00 0f ff` |
| `bp_map` current status literal | `0xd992c` | `00 80 00 00 00 19` |
| `bp_map` leaf store | `0xd9932` | `22 80` |
| `resume` path-U stores | `0xd9b58`, `0xd9b66` | `24 84`; `25 44 00 04` |
| `resume` path-V stores | `0xd9b9e`, `0xd9bd8` | `24 93`; `25 53 00 04` |
| `segkmem_alloc` leaf store | `0xa8754` | `24 ee ff f8` |
| `segkmem_free` clear | `0xa8812` | `42 9b` |
| `segkmem_mapin` leaf store | `0xa8a2c` | `26 ae ff f8` |
| `segkmem_mapout` valid-bit clear | `0xa8b22` | `72 fe c3 93` |
| `sptfree(flag=0)` direct clear | `0xa8cd0` | `42 b0 0c 00` |
| global `flushmmu` operation | `0xb78d0` | `f5 18` (`pflusha` only) |

The native source routines should be changed in source and relinked. The
generic binary `segkmem` group is too large for blind length-preserving byte
edits; use an override or an old-byte-asserted patch/trampoline specification
after its full 4 KiB implementation is written.

## B1 implementation group

Treat the following as one B1 atomic group:

1. Add the shared classifier to all three `hat_pteload` constructors.
2. Force `segu` mappings, `prumap`, and both `resume` source paths to `NC`.
3. Publish `hat_alloc`'s zeroed root and reorder `hat_free` so descriptors are
   detached/published before table/root memory is freed.
4. Add explicit `WT` construction to `hat_dup` private leaves and `bp_map`.
5. Port the direct `segkmem` family and classify:
   - managed page-backed mappings as `WT`;
   - unmanaged/MMIO mappings as `NCS`.
6. Add descriptor publication to `sysseginit`, `segkmem`, and
   `sptfree(flag=0)`, or make the last path fail loudly if unsupported.
7. Keep `hat_swapout`, old `hat_exec`, and live-tree use of
   `hat_growsdt` unreachable.
8. Add DMA-read completion invalidation before enabling the data cache. The
   complete initiator and insertion-site specification is now in
   `DMA-INITIATOR-CENSUS.md` and `DMA-PREPARE-COMPLETE-CONTRACT.md`.

Do not enable the data cache in a build where the classifier landed but the
u-area normalization or direct-`kptbl` group did not.

## B2 delta

B2 changes only managed ordinary RAM from `WT` to `CB`; it does not change the
special classes:

```text
ordinary managed RAM: WT -> CB
segu/fixed u-area:     NC -> NC
unmanaged MMIO:        NCS -> NCS
```

Before B2:

- every DMA initiator needs direction-correct prepare and complete hooks;
- every low-physical CPU alias (`ppcopy`, `pagecopy`, `pagezero`,
  `gen_strategy`, HAT table access, and any driver direct-physical access)
  needs an ownership/coherency decision;
- every teardown path must clean dirty DATA before the physical page can be
  reassigned;
- no VA may retain a stale WT/NC mapping to a physical page also mapped CB,
  unless an explicit alias protocol proves it safe.

For a same-PFN PTE rewrite, compare old and target CM. If they differ, clean
and invalidate the mapped data under the old translation before publishing
the new descriptor. Merely changing bits and issuing `pflusha` does not remove
old data-cache lines.

## Static acceptance

For each linked candidate:

1. Verify the kernel commit and full image SHA-256.
2. Verify all applicable old-byte assertions above.
3. Enumerate every `movel`/bitfield store reached from:
   `hat_pteload`, `hat_dup`, `hat_pageunload`, `hat_unload`, `hat_free`,
   `hat_chgprot`, `hat_pagesync`, `segkmem_*`, `sptfree`, `bp_map*`,
   `prumap`, and `resume`.
4. Prove every complete leaf constructor masks and assigns CM.
5. Prove every protection/ref-mod modifier preserves CM.
6. Prove every parent descriptor is published after child initialization and
   before the first hardware walk.
7. Prove every parent clear is published before child-table reuse.
8. Prove `hat_alloc` publishes its zeroed root before `as->hat_root` can reach
   URP and `hat_free` publishes all detachments before allocator reuse.
9. Require the old `hat_swapout` and `hat_exec` bodies to have zero live call
   paths.
10. Disassemble `krnxmemflt040` and confirm it remains a reader/delegator.
11. Confirm fixed-u and `kvsegu` leaves all decode as `CM=11`.

## Runtime acceptance

Before enabling DC, add a page-table census probe that samples representative
live mappings:

| Mapping | B1 expected | B2 expected |
|---|---|---|
| user text/data/anon | `WT` | `CB` |
| kernel `segkmem` RAM | `WT` | `CB` |
| `bp_map` managed alias | `WT` | `CB` |
| `segdev`/MMIO register page | `NCS` | `NCS` |
| `kvsegu` and fixed u-area | `NC` | `NC` |

Then run, on both 040 and 060 emulation for structural regressions:

- boot/login/exec;
- the full `hat_dup_cow` 1/32/256 matrix;
- swap-out/swap-in pressure;
- NFS/local-copy and page-I/O paths;
- protection and `mincore` boundary tests.

B1 and especially B2 correctness require real hardware:

- disk and network DMA in both directions with byte comparisons;
- direct and bounce-buffer SCSI cases;
- sustained fork, swap, filesystem, and network pressure;
- u-area context switching while the pressure run is active;
- table-boundary tests for `segkmem_setprot`;
- a high-PFN `segdev` mapping with register access kept NCS.

## Bottom line

The correct CM campaign boundary is:

```text
leaf class + descriptor publication + data ownership + legacy-tree reachability
```

`hat_pteload` is the central class selector, but it is not the only complete
PTE constructor. The two highest-risk omissions in a partial implementation
would be cacheable `segu` aliases overwriting the fixed NC u-area and the
still-2-KiB `segkmem_setprot` writer modifying the wrong live PTE.
