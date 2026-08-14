# AMIX `segu` provenance and lifetime audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/SEGU-AUDIT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

## Result

The analyzed pre-fix 040 image contained a deterministic `segu_get` flag
corruption. It explained the observed `segu_release -> anon_free ->
anon_decref -> page_abort` path with `p_keepcnt == 1` without requiring a
primary defect in the 040 `hat_unload` release branch.

The Model B patch changes the loop terminal value in `d5` from 3 to 1:

```text
vanilla  0xaa6a2  moveq #3,d5       four 2 KB pages
040      0xaa6a2  moveq #1,d5       two 4 KB pages
both     0xaa6aa  movel d5,a3@(20)  sup->su_flags = d5
```

In the original binary, the same value 3 means both the final loop index and
`SEGU_ALLOCATED | SEGU_LOCKED`. In the patched binary the store consequently
writes 1, or `SEGU_ALLOCATED` only. `segu_release` then does not see
`SEGU_LOCKED` and calls `hat_unload` with zero flags instead of
`HAT_UNLOCK | HAT_RELEPP` (`0x2 | 0x8 == 0xa`). The page hold acquired by
`page_get` is therefore not released before `anon_free`.

Confidence is high. The instruction sequence, flag definitions, release
branch, and runtime symptom agree exactly.

Current-status update: master now wraps `segu_get_orig` with
`segu_get_lockfix`, which restores `SEGU_LOCKED`, and an outer
`segu_ubptbl040` wrapper rebuilds `p_ubptbl` from the live 040 tree. The root
cause and pre-fix byte analysis below remain provenance for those corrections;
they no longer describe the selected current `segu_get` entry by themselves.

## Binary provenance

The mounted read-only AMIX filesystem contains `usr/sys/vm/exp`. It is a
non-stripped ELF32/m68k relocatable object and is identical to the repository
copy:

```text
SHA-256 fdf33bc8e3dabcb16b0c1db22cb24954b3076dee83856e117a24206cfdb7cdf1
```

There is no `usr/sys/amiga/vm` object directory in the mounted distribution.
The machine-specific `segu` implementation is in this top-level `vm/exp`.

All entries below match the vanilla kernel by function/object bytes and
normalized ELF relocations:

| Symbol | `vm/exp` | Vanilla kernel | Size |
|---|---:|---:|---:|
| `segu_ops` | `.data+0xd0` | `0x0000b450` | `0x44` |
| `segu_create` | `0x2314` | `0x000a9d3c` | `0xd4` |
| `segu_fault` | `0x275e` | `0x000aa186` | `0x1b8` |
| `segu_get` | `0x2a3e` | `0x000aa466` | `0x2b2` |
| `segu_release` | `0x2cf0` | `0x000aa718` | `0xb4` |
| `segu_softunload` | `0x2e48` | `0x000aa870` | `0x170` |
| `segu_softload` | `0x2fb8` | `0x000aa9e0` | `0x1be` |

There is no AMIX symbol named `seguinit`. `kvm_init+0x374` calls
`segu_create` through the relocation at `0x48fa2`; `segu_create` installs
`segu_ops`. For this kernel, `segu_create` is the relevant initialization
entry.

The 17-entry operation vector at `.data+0xb450` is relocation-backed as
follows:

| Seg op | AMIX target |
|---|---|
| `dup`, `unmap`, `free` | `segu_badop` |
| `fault` | `segu_fault` |
| `faulta`, `unload`, `setprot` | `segu_badop` |
| `checkprot` | `segu_checkprot` |
| `kluster` | `segu_kluster` |
| `swapout`, `sync`, `incore`, `lockop` | `segu_badop` |
| `getprot` | `segu_getprot` |
| `getoffset` | `segu_getoffset` |
| `gettype` | `segu_gettype` |
| `getvp` | `segu_getvp` |

This vector is why a direct-call-only graph does not show every route into
`segu_fault`.

The 3B2 `seg_u.c` is behavioral source evidence, not AMIX source provenance.
Its statements map directly to the byte-identical AMIX implementation:

- `seg_u.c:610-774`: `segu_get`
- `seg_u.c:755-760`: final flags and owner
- `seg_u.c:792-855`: `segu_release`
- `seg_u.c:831-846`: unload flags before `anon_free`

## Call graph

The relevant direct and indirect paths are:

```text
kvm_init
  -> segu_create
       -> seg->s_ops = &segu_ops

procdup
  -> segu_get
       -> anon_resv
       -> page_get
       -> [per page] anon_alloc -> swap_xlate -> page_enter -> hat_memload
       -> su_flags = ALLOCATED | LOCKED
       -> cp->p_segu returned

swapinub
  -> segu_fault(F_SOFTLOCK)
       -> segu_softload -> hat_memload

swapoutub
  -> segu_fault(F_SOFTUNLOCK)
       -> segu_softunload -> hat_unload(HAT_UNLOCK | HAT_RELEPP)

swtch zombie path
  -> segu_release
       -> hat_unload
       -> anon_free -> anon_decref -> page_abort
       -> anon_unresv
       -> slot returned to usd_free

segment fault dispatch
  -> segu_ops.fault -> segu_fault
```

The kernel relocations identify the direct edges at `0x418a4` (`procdup`),
`0x48fa2` (`kvm_init`), `0xa9eae` (`swapinub`), `0xa9fca`
(`swapoutub`), and `0xb9076` (`swtch`).

## Intended keep-count contract

The intended page lifetime is:

```text
page_get(0x2000, P_CANWAIT)
  -> each returned page has p_keepcnt = 1
  -> page_enter gives the page its anon vnode/offset identity
  -> hat_memload(..., lock=1) installs and locks the translation
  -> slot flags become SEGU_ALLOCATED | SEGU_LOCKED (3)

segu_release
  -> sees SEGU_LOCKED
  -> hat_unload(..., HAT_UNLOCK | HAT_RELEPP)
  -> removes the mapping and performs PAGE_RELE(pp)
  -> p_keepcnt changes 1 -> 0
  -> anon_free drops the anon reference
  -> slot flags become 0 and the slot returns to usd_free
```

`page_get` assigning `p_keepcnt = 1` is explicit in
`vm_page.c:910-914`. `HAT_RELEPP` is documented as "PAGE_RELE() pp after
mapping is unloaded" in `vm/hat.h:129-139`. The 3B2 `hat_unload` implements
this at `vm_hat.c:786-788`.

The current 040 `hat_unload` also has the required flag-8 behavior:
`prototypes/hat040.s:888-915` decrements `p_keepcnt` and handles the resulting
zero count. That code cannot run when `segu_release` passes flags 0.

## Historical failing 040 lifetime

`prototypes/patch_modelb_pager.py:226` changes `0xaa6a2` from `moveq #3,d5`
to `moveq #1,d5`. The unchanged store at `0xaa6aa` writes that 1 to
`su_flags`:

```text
segu_get
  -> page_get leaves p_keepcnt = 1
  -> mapping is installed
  -> su_flags = SEGU_ALLOCATED (1), missing SEGU_LOCKED

segu_release at 0xaa754
  -> bit 1 test fails
  -> pushes HAT_NOFLAGS (0) at 0xaa76c
  -> hat_unload removes the mapping but does not PAGE_RELE the page
  -> p_keepcnt remains 1
  -> anon_free -> anon_decref -> page_abort
```

When `page_abort` sees a nonzero keep count, it marks the page gone and returns
without immediately freeing it (`vm_page.c:507-515`). Thus the precise static
failure is a leaked hold plus a premature anon teardown. This is consistent
with the observed kept u-page and subsequent stale/reused u-area state.

The repeated anon offsets have a more exact explanation. In `anon_decref`, the
last reference path does this in order (`vm_anon.c:202-231`):

```text
swap_xlate(ap) -> page_find(vp, off) -> swap_free(ap) -> page_abort(pp)
```

`swap_free` therefore makes the anon/swap slot reusable before `page_abort`
discovers `p_keepcnt == 1`. The old physical page remains kept and marked gone,
but its anon offset can already be handed to another process. If a later
`segu_get` tries to enter the same `<vp,off>`, the retained page identity can
also make `page_enter` find the old page repeatedly. This directly connects
the missing `HAT_RELEPP` to both the kept-page trace and cross-process anon
offset reuse.

## `u_procp` write path

The AMIX binary confirms `u.u_procp` at offset `0x730`:

```text
newproc
  -> procdup (0x41840)
  -> segu_get(cp)                         relocation at 0x418a4
  -> cp->p_segu = returned window VA     0x418a8, proc offset 0xfc
  -> setuctxt(cp, cp->p_segu)            relocation at 0x418ea
       -> bcopy(&u, cp->p_segu, 0x2000)  0x41942..0x41950
       -> [cp->p_segu + 0x730] = cp      0x41954
  -> save(cp->p_segu + 0x318)            0x418ee..0x418f4
```

The creation path writes `u_procp` through the per-process `kvsegu` window,
not through fixed VA `u == 0x40000000`. Later scheduler/trap code reads it
through fixed `u+0x730`. Those addresses must alias the same physical u-area
page after context switching.

This makes the observed state significant:

- live data at `u+0x318` proves that the fixed u mapping is not simply wholly
  absent;
- zero at `u+0x730` proves the fixed view no longer contains the complete
  image written by `setuctxt`, or that the page contents were subsequently
  altered;
- the broken release/reuse lifetime provides a direct mechanism for a stale
  fixed-u view, so the current evidence does not yet require a second
  independent `setuctxt` bug.

Offsets `0x318` and `0x730` are both in the first 4 KB page. Their differing
contents are therefore not evidence for a boundary error between the two u-area
pages. A stale first-page mapping can contain a plausible old save area at
`0x318` while still having zero at `0x730`; this observation should be repeated
after restoring the release contract.

The relevant 3B2 source reference is `os/fork.c:416-488`. AMIX
`KUSER(cp->p_segu)` is an identity at offset zero because `struct seguser`
starts with `struct user` (`usr/include/sys/user.h:308-312`).

## Slot allocator

`segu_create` creates a LIFO free list. On this 32-bit ABI:

| `struct segu_data` field | Offset | Size |
|---|---:|---:|
| `su_next` | `0x00` | 4 |
| `su_swaddr[4]` | `0x04` | 16 |
| `su_flags` | `0x14` | 4 |
| `su_proc` | `0x18` | 4 |
| total | | 28 |

The array remains four anon pointers wide even when the active Model B page
loops use two 4 KB pages. Therefore `su_flags` remains at offset 20; the
failure is not a shifted structure layout.

Allocation and release are symmetrical:

```text
segu_get:     sup = usd_free; usd_free = sup->su_next
              slot = sup - usd_slots
              VA = segu->s_base + slot * 0x2000

segu_release: slot = (VA - segu->s_base) / 0x2000
              sup->su_next = usd_free; usd_free = sup
```

No independent duplicate-slot arithmetic error is apparent. Reuse of a slot
and its anon offsets after a valid release is expected. It becomes unsafe here
because the slot is returned after teardown that omitted the page release.

`su_flags == 1` is valid after an intentional soft-unload: that path already
uses `HAT_RELEPP` before clearing `SEGU_LOCKED`. It is invalid immediately after
the resident-page allocation in `segu_get`, where the page_get holds are still
owned by the slot. This distinction is why `segu_release` trusts the flag bit.

## Correction boundary

The semantic correction is to keep the 4 KB loop bound independent from the
slot-state constant:

The corrected sequence iterates twice to allocate and map the two 4 KiB u-area
pages, then writes the independent slot-state value
`SEGU_ALLOCATED | SEGU_LOCKED` (`3`) to `su_flags`. The loop bound must never
double as the source of that state value.

No project patch is made by this audit. At binary level, the existing
four-byte `movel d5,a3@(20)` could be replaced by a four-byte operation that
sets 3 independently of `d5`; for example, `addq.l #3,a3@(20)` encodes as
`56 ab 00 14`. That particular encoding relies on the documented invariant
that a free slot has zero flags. A source/trampoline correction that explicitly
stores 3 is easier to audit and does not rely on that precondition.

## Runtime assertions for the implementation owner

These checks distinguish this finding from any remaining HAT defect:

1. Immediately after `segu_get`, the selected slot has `su_flags == 3`.
2. `segu_release` calls `hat_unload` with flags `0xa` for a resident u-area.
3. For each page, `p_keepcnt` changes from 1 to 0 during `hat_unload`.
4. The reverse mapping and 040 PTE are gone before `anon_free`.
5. Only after those conditions does the slot return to `usd_free`.

If assertions 1 and 2 pass but 3 or 4 fails, the remaining defect is in the
040 HAT path. In the historical pre-fix image assertion 1 failed statically;
the current wrapper is intended to make it pass.
