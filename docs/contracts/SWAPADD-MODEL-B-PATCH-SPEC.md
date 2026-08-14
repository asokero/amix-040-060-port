# Model B Swap Resource Geometry Patch Specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/SWAPADD-MODEL-B-PATCH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/patch_swapgeom.py` implements this
> complete constructor/destructor unit. It is part of the current Model-B
> build; the specification remains the source of its old-byte assertions and
> the rule that disk-sector conversions are not page-size conversions.

## Scope and target

This is a static implementation specification for Claude's later kernel-tree
patch. No kernel binary is modified by this analysis.

Target:

- kernel commit:
  `9c2ab666bd6eb9d43a3874d74aa7d5268997838a`
- `build/unix-040` SHA-256:
  `47d9bedc2ddce5e056f358058879914d4c8d634e5f2223bf1f89a82d530d99bd`
- ELF `.text` file offset: `0x34`
- Model B page size/shift/mask: `0x1000`, `12`, `0xfffff000`

The current `swap_xlate` at `0xb2aea` is already Model B:

```text
slot index = (swapent - si_swaptab) / 16
byte offset = si_soff + (slot index << 12)
```

The resource constructors and destructors still count and step 2 KiB slots.
That mismatch explains a roughly doubled `SC_LIST` page count and leaves the
slot table, byte offsets, and `kmem_free` size under different geometries.

## Required invariant

Inputs `lowblk` and `nblks` remain 512-byte disk blocks. Their `<<9` and `>>9`
conversions must not change.

For each swap resource:

```text
requested_start = lowblk << 9
requested_end   = min(requested_start + (nblks << 9), vnode_size)

si_soff  = roundup(requested_start, 0x1000)
si_eoff  = rounddown(requested_end, 0x1000)
si_npgs  = (si_eoff - si_soff) >> 12
table_sz = si_npgs * sizeof(struct swapent)   /* sizeof = 16 */

slot[k].offset = si_soff + k * 0x1000
```

`si_eoff <= si_soff` remains an invalid resource.

## Atomic text patch

All addresses below are `.text` section addresses. The file offset is
`address + 0x34`. Every replacement is length-preserving.

| Function and purpose | Text address | File offset | Current bytes | Replacement bytes |
|---|---:|---:|---|---|
| `swapdel_byname`: round `lowblk << 9` up | `0xb2d60` | `0xb2d94` | `06 82 00 00 07 ff` | `06 82 00 00 0f ff` |
| `swapdel_byname`: align start down after add | `0xb2d66` | `0xb2d9a` | `02 42 f8 00` | `02 42 f0 00` |
| `swapadd`: round start up | `0xb321e` | `0xb3252` | `06 83 00 00 07 ff` | `06 83 00 00 0f ff` |
| `swapadd`: align start | `0xb3224` | `0xb3258` | `02 43 f8 00` | `02 43 f0 00` |
| `swapadd`: align end | `0xb3228` | `0xb325c` | `02 44 f8 00` | `02 44 f0 00` |
| `swapadd`: round byte span before page count | `0xb323c` | `0xb3270` | `06 85 00 00 07 ff` | `06 85 00 00 0f ff` |
| `swapadd`: bytes to pages | `0xb3242` | `0xb3276` | `72 0b` | `72 0c` |
| `swapdel`: round `lowblk << 9` up | `0xb349c` | `0xb34d0` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
| `swapdel`: align start | `0xb34a2` | `0xb34d6` | `02 40 f8 00` | `02 40 f0 00` |
| `swapinfo_free`: recompute table page count | `0xb369c` | `0xb36d0` | `06 80 00 00 07 ff` | `06 80 00 00 0f ff` |
| `swapinfo_free`: bytes to pages before `*16` | `0xb36a2` | `0xb36d6` | `72 0b` | `72 0c` |
| `undelswap`: advance backing offset per slot | `0xb3d70` | `0xb3da4` | `06 82 00 00 08 00` | `06 82 00 00 10 00` |

This is one correctness patch. Reject a build in which only the five
`swapadd` sites changed.

### Why each mirror is required

- `swapdel_byname` and `swapdel` must reconstruct exactly the same `si_soff`
  stored by `swapadd`, or an existing resource cannot be found reliably.
- `swapinfo_free` must pass the exact original allocation size
  `si_npgs * 16` to `kmem_free`. Keeping its 2 KiB count after shrinking the
  allocation to Model B can corrupt the kernel heap.
- `undelswap` walks the slot table while recreating vnode/page offsets. Its
  old `+0x800` would assign two entries to offsets within one Model B page and
  disagree with `swap_xlate`.
- `delswap` obtains offsets through the already-correct `swap_xlate`; it has no
  separate page-size immediate in this group.

## Optional policy patch

The private `.data` initializer `swap_maxcontig` is `0x200` pages at data
address `0xb544`. Source intent is one MiB:

```text
swap_maxcontig = 1024 * 1024 / PAGESIZE
```

Preserving that policy under Model B changes:

| Location | File offset | Current | Replacement |
|---|---:|---|---|
| `.data+0xb544` | `0xe52a4` | `00 00 02 00` | `00 00 01 00` |

This is not part of the geometry correctness patch. With one swap area the
rotation selects the same area, so its practical effect is visible only with
multiple active resources.

## Static acceptance

Before patching:

1. Verify the full target SHA-256 above.
2. Verify all 12 current byte sequences at their file offsets.
3. Abort on the first mismatch; do not search-and-replace generic byte
   patterns.

After patching:

1. Verify all 12 replacement sequences and their unchanged instruction
   lengths.
2. Disassemble and confirm:
   - every page mask is `0xf000`;
   - every page round-up addend is `0x0fff`;
   - both page-count shifts are 12;
   - the slot-offset step is `0x1000`;
   - all disk-block shifts remain 9.
3. Confirm that `swap_xlate` still uses `<<12`.
4. Run the whole-text residual scanner and require that the named active swap
   sites disappear; unrelated 030/dormant candidates may remain.

## Runtime acceptance

### Resource geometry

For every test input, compute expected values independently with the invariant
above and compare them with `swapctl(SC_LIST)`:

- `si_soff` equals the first 4 KiB-aligned usable byte;
- `si_eoff` equals the first excluded 4 KiB boundary;
- reported page count equals `(si_eoff - si_soff) / 4096`;
- no slot offset is below `si_soff` or at/above `si_eoff`;
- the final slot is exactly `si_eoff - 0x1000`.

Include:

- a partition whose low block is not 4 KiB aligned;
- a size that is not a multiple of 4 KiB;
- the normal full swap partition;
- one and, if possible, two swap resources.

### I/O identity

Force and verify swap traffic at:

- first slot;
- a middle slot;
- final slot.

For each, verify that the 4 KiB content written is read back from the same
vnode offset. Retain the golden-partition comparison so writes outside the
declared range are visible.

### Add/remove lifecycle

1. Add, list, pressure-test, remove, and re-add the resource.
2. Exercise deletion both by vnode and by name/low-block identity.
3. Require no KMA validation error, allocator panic, stale page lookup, or
   mismatch in `anoninfo` page totals.
4. Repeat remove/re-add enough times to expose an incorrect `kmem_free` size.

### Pressure regression

After geometry tests pass:

- run sustained anonymous allocation/fork pressure until swap-out and swap-in
  both occur;
- run the existing `hat_dup_cow` matrix;
- verify swap write/read offsets remain 4 KiB multiples;
- verify first/middle/last slot content after reuse;
- verify the system can still remove the swap resource cleanly.

## Expected count sanity check

A nominal 100 MiB resource has approximately 25,600 Model B pages, subject to
the rounded low block and actual vnode end. A result near 51,200 is the old
2 KiB count and must fail acceptance. The exact expected value must always be
computed from the advertised low block and end; the approximate number is not
an assertion.

## Bottom line

The `swapadd` patch changes five functions and must remain consistent with the
already-correct sixth participant, `swap_xlate`; it is not a five-instruction
local fix. The add-side geometry, lookup identity, free size, and restore-time
slot stepping must all cross from 2 KiB to 4 KiB in the same build.
