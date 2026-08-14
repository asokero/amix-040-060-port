# AMIX 68040 B2 Copyback Page-Lifecycle Closure

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/CB-PAGE-LIFECYCLE-CLOSURE.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** All three B2 boundaries specified here
> are implemented: both page-publication hooks call the physical release
> barrier, `hat_unload(HAT_RELEPP)` publishes before reuse, and A3091 uses the
> paired DMA protocol. Managed RAM ships as copyback. Real 68040 pressure and
> power-cut disk-truth acceptance recorded more than 555,000 release events,
> zero rejected pages, and zero completion-without-prepare events. Later dual-
> CPU baselines retain this policy.

## Scope and pinned target

This note closes the ownership transitions introduced when ordinary managed
RAM changes from writethrough to copyback. It builds on
`CM-PTE-WRITER-MATRIX.md`, `DMA-PREPARE-COMPLETE-CONTRACT.md`, and
`DTT0-PHYS-WINDOW-CENSUS.md`; it does not repeat those censuses and does not
modify the kernel.

Pinned target:

- kernel implementation commit: `bc27d81`
- `build/unix-040` SHA-256:
  `d3e1f80a65394f951ffe894eefe2efcfe7b862786937b0eaf0154440608e8404`
- `build/unix-040-dbg` SHA-256:
  `410a6143097ce4d2394f9555d3f2c55cddbdf1c9a991126f43bf05d8676df117`
- ELF `.text` file offset: text address `+ 0x34`
- 68040 data-cache line: 16 bytes; full cache: 4 KiB / 256 lines

## Verdict

**In the pinned pre-implementation image, B2 was blocked until three ownership
boundaries were implemented:**

1. clean and invalidate every managed physical page before either
   `page_free` or the `free_vp_pages` bypass publishes it to a free/cache list;
2. reorder `hat_unload(HAT_RELEPP)` so the leaf PTE is cleared and descriptor/
   ATC state is published before `page_free` can expose the physical page;
3. install direction-correct A3091 prepare/complete hooks as specified in
   `A3091-B2-PREPARE-PATCH-SPEC.md`.

The low D0-NC CPU copy/zero paths pass on 68040 without additional operations.
They are not the free/reuse barrier and are not evidence for real 68060.

## The B2 hazard

Under WT, a CPU store has already reached RAM when a page is freed. Under CB,
the newest bytes may exist only in a dirty cache line. Merely clearing a PTE,
`p_mapping`, or `p_mod` does not remove that physical cache line.

The unsafe sequence, if a later owner or device writes RAM through a path that
does not first touch/dislodge the old cached line, is:

```text
owner A writes CB alias             RAM is older; cache line is dirty
owner A unmaps/frees physical page  stale physical cache line survives
allocator gives page to owner B     owner B writes new RAM/content
old A line is evicted later         old bytes overwrite owner B in RAM
```

Because the 68040 cache is physically tagged, the hazard follows the physical
page across vnode, anon, table, KMA, and DMA uses. VM dirty state and cache
dirty state are related but not interchangeable: `p_mod == 0` is not proof
that no dirty CPU line exists. Some current reuse paths independently dislodge
the line (D0-NC CPU access) or prepare it (A3091 DMA); the release barrier is a
deliberately stronger invariant so correctness does not depend on every future
page consumer remembering the previous cache class.

## Required page-release primitive

Define one machine-dependent primitive with this semantic contract:

```c
void cb_page_release(page_t *pp);
```

For the 68040 B2 build it computes the page's physical base using the same
`pages/pages_base/sizeof(page_t)==60` conversion already used by HAT, then
executes one data-cache line push for every 16-byte line in the 4 KiB page:

```text
pfn = pages_base + (((uintptr_t)pp - (uintptr_t)pages) / 60)
pa = pfn << 12
end = pa + 0x1000

for (p = pa; p != end; p += 16)
        cpushl dc,(p)              /* opcode f4 68 with address in a0 */
```

On 68040, `CPUSHL` pushes a dirty matching line and invalidates it. The low
physical address is valid through retained DTT0 and names the same physical
cache tag as every high alias. The operation must complete before `p_free` or
free-list linkage becomes visible.

Implementation constraints:

- reject a `pp` outside `[pages, epages)` in a diagnostic build;
- use exactly 256 lines and reject physical-end overflow;
- preserve the caller's live registers and interrupt-level contract;
- do not skip the operation based on `p_mod`, vnode identity, `p_age`, or
  whether `p_mapping` was already cleared;
- require that no CPU alias or DMA engine can write the page after this
  transition; temporary ghost mappings must already be retired and the
  existing keep/intrans tests must exclude device-owned pages;
- count releases and rejected inputs in the debug build;
- on a future 68060 build, either assert CACR.DPI is zero or pair the push with
  explicit line invalidation. Real-060 B2 acceptance is outside this pilot.

A whole-cache `cpusha dc` at each release is correctness-preserving on the
68040 because it writes dirty data rather than discarding it, but it is a
high-cost fallback. The per-page loop is the production requirement. A bare
`cinva dc` is forbidden: it can discard unrelated dirty CB data.

## Free-list insertion census

The 3B2 `vm_page.c` source has two writers of `p_free=1`: the general
`page_free` routine and the independent `free_vp_pages` vnode-range shortcut.
The pinned AMIX binary has the same two list-publication families. A relocation
search over `page_free` callers alone therefore cannot close the lifecycle.

### Choke point 1: `page_free`

All early-return and invariant checks finish before `0xafb08`. The current six
bytes save SR and raise the interrupt level immediately before free-list state:

```text
0xafaf2  67 00 00 14             all keep/mapping/free/lock/COW checks passed
0xafb08  40 c3 46 fc 24 00       move.w sr,d3; move.w #0x2400,sr
0xafb34  52 b9 00 00 00 00       freemem++
0xafb3a  00 12 00 20             set p_free
```

Required patch shape:

```text
0xafb08: jsr cb_page_release_enter

cb_page_release_enter:
        move.w  sr,d3             /* displaced bytes */
        move.w  #0x2400,sr
        save scratch registers
        cb_page_release(a2)
        restore scratch registers
        rts
```

An in-place absolute `jsr` is six bytes, exactly matching the displaced SR
pair. Link the helper first, resolve its final ELF symbol value, then patch
`4e b9 <helper-address>` with the same final-image symbol-address mechanism as
the existing detour scripts. The patcher must assert current bytes
`40 c3 46 fc 24 00`. Cleanup occurs only after the function has decided that
the page will really be freed, and before `freemem`, `p_free`, or list links
are published. The existing epilogue still restores SR from `d3`.

### Choke point 2: `free_vp_pages`

`free_vp_pages 0xafc3e` does not call `page_free`. It skips modified, held,
mapped, already-free, locked, and COW pages, but that semantic filtering is not
a cache writeback barrier:

```text
0xafcf2  08 12 00 02 ...          skip if p_mod
0xafd02  4a aa 00 20 ...          skip if p_mapping
0xafd72  02 12 00 7f ...          final wake/flag cleanup
0xafd98  52 b9 00 00 00 00       freemem++
0xafe04  00 12 00 20             set p_free
```

SR is already raised at `0xafc88`. Replace the six bytes at `0xafd98` with an
absolute call to a helper that:

```text
        preserves loop state
        cb_page_release(a2)
        addq.l #1,freemem          /* displaced operation and relocation */
        rts
```

The patcher must assert `52 b9 00 00 00 00`, resolve the linked helper as
above, and preserve the helper's normal `freemem` symbol relocation in its
assembled object. Hooking only `page_free` is a failed B2 build.

### Why allocation-time cleanup is not the primary fix

Cleaning in `page_get` could remove a stale line before some reuses, but it
would leave direct free-list consumers and any future allocator path as hidden
exceptions. The ownership transition is the point at which the old owner is
known to be dead. Publish the page clean there; optional allocation assertions
may then verify the invariant.

## Free/reuse path matrix

| Producer/path | Current route to free state | Current ordering | Required B2 action | Verdict after action |
|---|---|---|---|---|
| `page_abort 0xaf8d6` | if mapped, `hat_pageunload 0xd7d5a`; then `page_free` at relocation `0xaf9ac` | U/M harvest, PTE clears, `cpusha bc; pflusha` at `0xd7da2`, then free | general `page_free` release hook | pass |
| `pvn_done 0xb1b00` | optional `hat_pageunload` at `0xb1cb0`, then `page_free` at `0xb1cc4` | unmap precedes free when mapped | general hook; DMA completion must already have run | pass |
| `pvn_getdirty` / `pvn_vplist_dirty` | page-free relocations `0xb1f20`, `0xb209e`, `0xb21f0` | generic VM release | general hook | pass |
| `checkpage` / pageout | `page_free` at `0x52288` | generic release after dirty decision/writeback | general hook plus A3091 TO_DEVICE prepare | pass |
| `segvn_swapout` | `page_free` at `0xacf68` | generic release | general hook plus writeback prepare if dirty | pass |
| `hat_ptfree 0xd852c` | `page_free` at `0xd8598` | parent descriptor is now detached first | general hook; closes table<->data class transition | pass |
| `hat_free 0xd8248` | mapped data is harvested/unlinked; leaf/pointer pages go through `hat_ptfree`; root through `kmem_free` | table parents are pushed before reclaim; mapped data is freed later by VM | general hook for page-backed objects; KMA remains WT in pilot | pass |
| `hat_unload(HAT_RELEPP)` | direct `page_free` at `0xd8100` | **free occurs before leaf clear at `0xd8106`** | reorder as specified below, then general hook | blocked until fixed |
| retained `hat_map` rollback | `page_free` at `0xb5a32`, `0xb5ae0`, `0xb5b5e`, `0xb5cec` | legacy path | general hook, plus retain `HAT-MAP-POLICY` guard | conditional |
| dormant old `hat_swapout` | `page_free` at `0xb4972` | 030 walker | keep unreachable; general hook is not a port | excluded |
| `free_vp_pages 0xafc3e` | direct cache-list insertion | bypasses `page_free` | dedicated `0xafd98` release hook | blocked until fixed |

The complete relocation census also finds `page_free` at `0x5292c` and the
sites listed above. They all converge on the first choke point except
`free_vp_pages`, which is why two hooks are sufficient and necessary.

## `hat_unload(HAT_RELEPP)` ordering fix

The current releasable-page branch is:

```text
0xd80f6  00 14 ff 80             mark page gone
0xd80fa  42 a7 2f 0c             arguments
0xd80fe  4e b9 00 00 00 00       page_free
0xd8104  50 4f                   pop arguments
0xd8106  42 92                   clear leaf PTE
...
0xd81a8  f4 f8 f5 18             final cpusha bc; pflusha
```

U/M harvest and reverse-map unlink have already occurred, but the physical
page can enter a free list while its resident descriptor is still in memory.
The required order is:

```text
harvest PTE U/M into page_t
unlink p_mapping
mark page gone
clear leaf PTE
publish descriptor clear and invalidate ATC
page_free(pp, 0)                  /* central hook performs cb_page_release */
continue after the normal leaf-clear instruction
```

Use a final-image detour at `0xd80f6`. Replace exactly the first six bytes
`00 14 ff 80 42 a7` with `4e f9 <release-island-address>` after the island has
been linked. The island replays the displaced `mark gone`, then executes:

```text
        orib    #-128,a4@          /* displaced */
        clrl    a2@                /* retire leaf before allocator exposure */
        cpusha  dc
        pflusha
        clrl    sp@-
        movel   a4,sp@-
        jsr     page_free          /* central hook cleans page data */
        addqw   #8,sp
        jmp     0xd8108            /* skip old call and duplicate PTE clear */
```

The detour patcher must also assert the full surrounding window
`00 14 ff 80 42 a7 2f 0c 4e b9 00 00 00 00 50 4f 42 92`. Relying only on
the function-wide tail after `page_free` fails the ownership order. Do not add
a second data-page cleanup in the island; the mandatory central `page_free`
hook owns it.

This ordering correction is independently valuable even on a single CPU: it
removes a resident descriptor before allocator visibility instead of relying
on the absence of a context switch in the small interval.

## TO_DEVICE writeback closure

The B2 disk-write requirement is not another VM hook. Dirty pageout, swap,
filesystem putpage, raw disk, and buffer-cache writes eventually become A3091
hardware segments; the controller must push each segment before arm.

| Target-pilot writer | Last host-RAM observer | Does it pass A3091 `startdma`? | B2 closure |
|---|---|---:|---|
| UFS/S5/specfs pageout and putpage | local SCSI disk DMA reads host RAM | yes | A3091 TO_DEVICE prepare |
| anonymous swap write | specfs/block strategy to local SCSI | yes | same prepare |
| ordinary `bwrite`/`bdwrite` and buffer cache | local SCSI controller | yes | same prepare |
| raw disk / generic SCSI data | A3091 segment | yes | same prepare, including short/unaligned endpoints |
| disconnect/reconnect continuation | A3091 re-arm at `0xd21a` | yes, but without returning through generic BIO | prepare every re-arm |
| RAM disk | CPU `bcopy` through D0-NC physical alias | no external DMA | coherent CPU path; no DMA op |
| A2065 networking | CPU copies host mblks to/from board-local LANCE RAM through NCS aperture | no host-RAM bus-master transfer | board-local/PIO contract; no host-RAM prepare |
| Paula/floppy/display custom chips | chip RAM reached NC | no managed-RAM A3091 path | existing NC/chip ownership |
| A2090/A2091/native `hd` | other host-RAM controllers | no | explicitly deferred; must not be present in pilot hardware |

The A3091 source and relocation census prove that its initial arm at `0xd0b2`
and reconnect arm at `0xd21a` are the only two A3091 `startdma` calls. Retarget
both, and every target-pilot CPU-to-disk segment crosses the prepare boundary.
Generic `gen_strategy`, `bp_map`, `biodone`, or `pvn_done` must not duplicate
ownership.

## D0-NC page access closure

Retained DTT0 makes low logical addresses identity-mapped and NC. On 68040, an
NC access to a physical line dislodges any matching cached line, pushing dirty
data first. The following are therefore coherent without an added cache op:

| Path | Pinned operation | Alias interaction | 68040 B2 requirement | 68060 note |
|---|---|---|---|---|
| `ppcopy 0xaf200` | source and destination PFNs become low addresses; `bcopy(0x1000)` | D0-NC read/write versus possible high CB aliases | none; NC access resolves each touched physical line | re-verify before real-060 B2 |
| `pagecopy 0xaf24e` | `copyin` writes destination physical page through D0 | destination may formerly/currently have high alias | none for touched lines | separate 060 gate |
| `pagezero 0xaf282` | `bzero` of low physical range | partial or full page versus high CB alias | none for touched lines; free/reuse hook still covers untouched lines | separate 060 gate |
| `ramstrategy 0x10436` | CPU `bcopy` in 512-byte chunks through `vtop` low address | RAM-disk KVA versus physical data alias | none; this is CPU copy, not DMA | separate 060 gate |
| HAT table walks by software | descriptor bases are low physical addresses | table memory is D0-NC | covered by `PT-MEMORY-B2-POLICY.md` | separate table policy for 060 |

These operations cannot replace the release hook. A partial `pagezero`, for
example, touches only its requested lines, while an unrelated dirty line in
the same physical page could otherwise survive into the next owner.

## Cache-operation census

The pinned image contains whole-cache operations (`cpusha dc/bc`, `cinva dc`,
and `cinva ic`) but no line/page cache-maintenance opcode. Relevant current
sites include:

```text
0xd7da2  hat_pageunload publication     cpusha bc
0xd81a8  hat_unload publication         cpusha bc
0xd84c6  hat_free leaf-parent publish   cpusha dc
0xd84e6  hat_free pointer-parent publish cpusha dc
0xd8504  hat_free root publish          cpusha bc
0xd9fc4  B1 A3091 completion            cinva dc
```

The HAT pushes publish descriptor memory. They are not proof that mapped page
**data** is clean. The absence of `cpushl` confirms that no existing per-page
release primitive already closes B2.

## Implementation order

1. Add the physical-range cache helper and test its opcode/line count in an
   isolated object.
2. Install `page_free` and `free_vp_pages` hooks with old-byte assertions.
3. Reorder the `hat_unload(HAT_RELEPP)` release island.
4. Install the A3091 B2 prepare/complete patch.
5. Re-run the page-free relocation census and require exactly two free-list
   publication families, both covered.
6. Only then change `hat_cm_ram` from `0x00` to `0x20`.

## Static acceptance

Reject the B2 build unless all of these hold:

- `page_free` hook executes after all non-free early returns and before
  `0xafb34/0xafb3a`;
- `free_vp_pages` hook executes before `0xafd98/0xafe04` publication;
- both hooks clean and invalidate all 256 physical lines independent of
  `p_mod`;
- `hat_unload` clears/publishes the leaf before calling `page_free`;
- `hat_pageunload` still harvests U/M before clear and publishes at `0xd7da2`;
- `hat_free` still detaches/publishes parent descriptors before `hat_ptfree`;
- every A3091 nonzero initial and reconnect arm has prepare metadata;
- no whole-cache `cinva dc` remains reachable while CB mappings can be dirty;
- DTT0 stays enabled and kvseg stays WT for this pilot.

## Runtime acceptance

The emulator cannot accept cache correctness. Use it only for control-flow and
regression smoke tests. Real A3000/Mercury 68040 acceptance should include:

1. counters proving both release hooks and both A3091 arm sites execute;
2. forced free/reuse pressure across anon, file cache, and page-table pages;
3. swap-out and swap-in with byte-verified 4 KiB slots;
4. local-disk and NFS-to-local copies followed by power-cut disk truth;
5. `hat_dup_cow` 1/32/256 and table-boundary probes;
6. `burst4` and the existing B1 workload matrix;
7. no release-state assertion, arm/complete imbalance, stale page content, or
   filesystem mismatch.

## Closure-search record

The verdict is supported by three independent searches:

1. source-level `p_free` writer search in 3B2 `vm_page.c` and binary matching
   of the two current insertion families;
2. relocation enumeration of every current `page_free`, `hat_pageunload`, and
   A3091 `startdma` caller;
3. mechanical cache-op census plus byte-level disassembly of HAT teardown,
   free-list publication, and D0 physical-copy paths.

## Bottom line

B2 needs a physical ownership barrier, not another dirty-bit heuristic. Clean
and invalidate every page before either free-list publication path, retire the
last leaf mapping before `hat_unload` exposes the page, and push every A3091
TO_DEVICE segment before hardware arm. With those changes, the remaining
68040 D0-NC copy/zero paths are coherent by architecture and require no extra
patch in this pilot.
