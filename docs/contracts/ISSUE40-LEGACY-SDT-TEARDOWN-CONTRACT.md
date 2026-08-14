# ISSUE-40 legacy-SDT teardown contract

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Hardware follow-up (2026-08-01):** This edge was implemented exactly as
> specified. Across boot plus 419 teardowns it released 629 legacy objects with
> zero shape or return errors and removed 629 stale-root skips, but returned no
> physical page because thirteen one-unit `ptdat` bits still pinned each
> backing page after the 18-unit SDT range was cleared. This contract remains
> accepted for its object lifetime. The required second edge is now specified
> in `ISSUE40-PTDAT-TEARDOWN-CONTRACT.md`.

## Scope

This note answers the implementation questions in
`kernelsupport/ISSUE40-CODEX-FOLLOWUP-QUESTIONS.md`. It narrows the broader
legacy-SDT warnings to one operation in the pinned image:

```text
hat_growsdt(hatp, section, 0)
```

The operation is the missing lifetime edge confirmed by the real-hardware
`availrmem` / `pages_pp_kernel` measurements. This is static analysis only. It
does not patch the kernel.

## Pinned artifacts

| Artifact | Identity |
|---|---|
| Kernel source tree | `kernelsupport` commit `0ebca71` |
| Kernel | `build/unix-040`, build `68040-260801-04` |
| Kernel SHA-256 | `e956ea34dd83c77bb759151e957713b0a3d7e2148f4596126523d56f3739befb` |
| Active destructor | `hat_free 0x000d82bc` |
| Retained helper | `hat_growsdt 0x000b6058`, local `t` |
| Retained free helper | `hat_sdtfree 0x000b65ca`, local `t` |
| Reference contract | 3B2 `vm/vm_hat.c:245..362`, `2037..2139`, `2294..2402` |

All addresses are linked `.text` offsets. The current kernel hash is unchanged
from `AVAILRMEM-ACCOUNTING-AUDIT.md`.

## Answers

| Question | Verdict |
|---|---|
| Q1: insertion point | Call the legacy teardown **before the first native A/B/C root read**, after the null-root guard. Calling it after the native walk is unsafe. |
| Q2: sections/helper | Call `hat_growsdt(hatp, 2, 0)` and then `hat_growsdt(hatp, 3, 0)`. The zero-length path is callable in this image; a direct `hat_sdtfree` reimplementation is not preferred. |
| Q3: direct-free fields | `hatp = as+0x14`; `root = *(as+0x14)`; section descriptor is `root + section*8`; base is descriptor `+4`; units are `((be16(descriptor)+1)+7)>>3` when UDT is valid. |
| Q4: copyback | No new whole-cache or ATC operation is needed. The legacy table uses the retained D0-NC physical alias, released pages cross the existing `cb_page_release` barrier, and the existing final `cpusha bc; pflusha` publishes/root-retires the live tree. |
| Q5: scope | Legacy SDT, `ptdat`, and `USIZE` can land separately. They share allocator capacity, so observed residual timing can change, but fixing SDT ownership neither frees `ptdat` records nor changes u-area accounting semantics. |

## Q1: teardown ordering

The active entry sequence is:

```text
0xd82c4  load as
0xd82c8  a5 = *(as+0x14)             root
0xd82ce  null-root guard
...
0xd8310  A = 0
0xd8314  native A loop
0xd8328  first root[A] read
```

The legacy descriptors occupy bytes in that same root page:

| Legacy object | Root bytes | Native interpretation |
|---|---:|---|
| section 2 descriptor word 1 | `root+0x10..0x13` | A4 |
| section 2 table base | `root+0x14..0x17` | A5 |
| section 3 descriptor word 1 | `root+0x18..0x1b` | A6 |
| section 3 table base | `root+0x1c..0x1f` | A7 |

The native walk may skip A4/A6 through `Lf_badA`, but that is not an ownership
contract. If a false legacy descriptor's masked base happens to pass the RAM
range check, the walk can traverse it and ultimately clear that root word at
`0xd8570`. The walk also destroys real native root entries and child tables as
it proceeds. `hat_growsdt` must not be asked to recover legacy state after any
of that mutation.

The correct source-level insertion is therefore the `Lhf_nodbg` join in
`prototypes/hat040.s`, immediately before the current `clrl fp@(-20)` that
starts the A loop. At this point all required state remains alive:

```text
fp@(8)       as
as+0x14      address of the HAT root-pointer field
*(as+0x14)   live 4 KiB root page
root+0x10    section-2 legacy descriptor
root+0x18    section-3 legacy descriptor
legacy SDT backing pages and sdtfreelist metadata
```

The calls may also be placed before the debug marker, but placing them at the
common `Lhf_nodbg` join preserves the current entry diagnostics. In either
case they must be after the null-root check and before `0xd8328`.

The first argument is an important ABI trap:

```text
correct:   hatp = &as->a_hat = as + 0x14
wrong:     hatp = root = *(as + 0x14)
```

`hat_growsdt+0x26` dereferences its first argument to obtain `root`. Passing
the root value would therefore treat `root[0]` as another pointer.

## Q2: sections and helper safety

### Both sections are required

The stock destructor processes section 2 and then section 3. The current
runtime evidence independently shows both legacy descriptors in real address
spaces:

```text
A4 Adesc=0x00400003 / 0x00020003    section 2
A6 Adesc=0x003f0003 / 0x00810003    section 3
```

The `0x00810003` section-3 value is the 130-entry libc object (`n=17` units),
but the main executable and stack also create section-2/other section-3
objects. Freeing only section 3 is not a complete AS lifetime edge. It can
also fail to return a physical page when a section-2 allocation occupies bits
in the same `p_sdtbits` backing page.

The bounded legal section set is exactly `{2, 3}`. Do not scan all 128 native
root entries and do not call the legacy helper for sections 0/1.

### Why the zero-length helper is accepted

For `nentries=0`, current `hat_growsdt` does the following:

```text
root  = *hatp
rdesc = root + section*8
osize = UDT_valid ? ceil((be16(rdesc)+1)/8) : 0
nsize = 0
nlastseg = 0

no old-SDE invalidation iterations
hat_sdtfree(*(rdesc+4), osize)
clear UDT in rdesc
return 0
```

The no-iteration point is byte-visible at `0xb60e4..0xb610c`: with
`nentries=0`, both the loop cursor and `nlastseg` are zero, so execution goes
directly to the free call at `0xb611e`.

This is narrower than approving the whole retained subsystem. It is safe in
the pinned image because:

1. `hat_sdtfree` has the required PFN shifts `moveq #12` at `0xb65e4` and
   `0xb6610`.
2. The call frees the **entire original allocation** from its original base.
   It does not perform the unsafe partial multi-group shrink
   `obase + nsize*64` with nonzero `nsize`.
3. For a sub-32-unit freelist allocation, the allocator guaranteed
   `index + osize <= 32`; the free computes the same PFN and 64-byte index.
4. For a 32-or-more-unit new allocation, the original base is 4 KiB aligned;
   the free consumes the same `ceil(osize/32)` consecutive `page_t` groups.
   The retained packed-byte geometry remains wasteful, but it does not make a
   whole-object bitmap release asymmetric. The allocation used
   `P_PHYSCONTIG` (`flag|2` at `0xb6476..0xb648c`), matching the free-side
   `page_t` increment.
5. `hat_map` vnode preload is disabled by the unconditional branch at
   `0xb58d2`, public `hat_exec` is the native no-op, public `hat_dup` is native,
   and stock `hat_swapout` is unreachable. The legacy object therefore holds
   coverage allocation, not live old PTE children or phantom reverse maps that
   would need an old-tree walk before freeing the SDT itself.
6. Clearing section UDT makes A4/A6 invalid to the following native walk. The
   retained physical base in A5/A7 is at least 64-byte aligned, so its low UDT
   bits are zero and it is skipped as well.

This acceptance does **not** approve nonzero partial shrink, re-enabled vnode
preload, old `hat_exec`, or old `hat_swapout`.

### Recommended call mechanism

`hat_growsdt` is a local `t` symbol in the current ELF. A new reference from
`hat040.o` therefore requires the relink stage to globalize that retained
symbol. It should be globalized but not weakened or replaced:

```text
--globalize-symbol hat_growsdt
```

Then call it twice, in stock order, with independently reconstructed
`hatp=as+0x14`. Both zero-length calls are non-allocating and should return
zero. No direct reference to local `hat_sdtfree` is needed.

## Q3: direct-free fallback layout

Direct free is not recommended for the current patch, but the exact recovery
formula is:

```text
as             = hat_free argument
hatp           = as + 0x14
root           = *(uint32_t *)(as + 0x14)
rdesc(section) = root + section*8

section 2:
    descriptor first long = root+0x10
    physical base         = root+0x14

section 3:
    descriptor first long = root+0x18
    physical base         = root+0x1c
```

The first long's low two UDT bits are extracted by the binary as
`bfextu rdesc@(3){6:2}`. When they are zero, the object has no allocation and
`n=0`. When nonzero:

```text
entries = be16(rdesc+0) + 1
n       = ceil(entries * 8 / 64)
        = ceil(entries / 8)
        = (entries + 7) >> 3
base    = be32(rdesc+4)
```

There is no separate stored unit count. The 16-bit section limit stores
`entries-1`; `n` must be recomputed.

If a future direct implementation is used, it must snapshot both descriptors
before clearing either and prove one of these allocator shapes before calling
`hat_sdtfree(base,n)`:

```text
n < 32:   ((base & 0x7ff) >> 6) + n <= 32
n >= 32:  (base & 0xfff) == 0
all n:    base>>12 is in [pages_base,pages_end)
```

It must then clear the legacy descriptor before the native A walk. Recreating
this parsing and validation in assembly adds more failure surface than using
the retained zero-length helper.

## Q4: copyback and ATC ordering

No additional whole-cache operation is required for this edge in the pinned
B2 configuration.

The relevant cache classes are:

| Object | Current CPU alias/policy | Teardown owner |
|---|---|---|
| Legacy SDT bytes | returned physical address through retained D0-NC window | `hat_sdtfree`; no CB data alias while owned as SDT |
| User root page | high KMA/kvseg mapping, retained WT in the B2 scope | existing `hat_free` final publication and `kmem_free` |
| Released managed page | may later become CB data | central `page_free -> cb_page_release` physical-line barrier |

When the last `p_sdtbits` allocation in a backing page is removed,
`hat_sdtfree` drops its hold and reaches `page_abort -> page_free`. The current
`page_free` hook calls `cb_pgfree_enter -> cb_page_release` at `0xafb08`, before
free-list publication, and performs 256 `cpushl dc` operations over that
physical page. If other SDT or `ptdat` bits remain, there is no physical owner
transition and therefore no release operation to perform.

The native destructor still ends with:

```text
0xd858e  clear as+0x14
0xd8592  cpusha bc
0xd8594  pflusha
0xd859c  kmem_free(root, 0x1000)
```

That remains the correct root/native-tree publication point. The legacy SDT
is not a live 040 translation parent, and no user execution occurs during AS
death, so no per-section `pflusha` is needed. Do not add `cpusha`/`cinva`
around each helper call; it would duplicate the line release barrier and the
final root publication without closing a new ownership transition.

This verdict depends on the current B2 scope: DTT0 remains enabled for D0-NC
physical accesses, kvseg/KMA roots remain WT, and the central page-release
hook remains installed. Narrowing DTT0 or making the root/legacy allocator
alias CB requires a new audit.

## Q5: independent landing units

The legacy SDT and `ptdat` records share `hat_sdtalloc`, `sdtfreelist`, and the
32-bit `page_t::p_sdtbits` capacity. Therefore the fixes are not
measurement-independent:

- freeing section-2/3 bits can expose slots that later `ptdat` allocations
  reuse;
- a leaked `ptdat` bit can keep a backing page charged after both legacy SDTs
  have been freed;
- the lower-rate `pages_pp_kernel` debit cadence can consequently move.

They are nevertheless ownership-independent and do not need an atomic patch:

- the two `hat_growsdt(...,0)` calls clear only the section allocations' exact
  bitmap ranges;
- they do not unlink `pp->p_ptdats`, `active_pts`, or `free_pts` records;
- custom `hat_ptfree` still owns the unresolved one-unit metadata lifetime.

Acceptance should therefore require removal of the deterministic approximately
one-page-per-dynamic-exec slope, not demand perfectly zero drift while the
`ptdat` unit remains open.

`USIZE` is completely separate. Keep `USIZE=4` for the 8 KiB legacy ABI and
four-entry `p_ubptbl`; convert only the resident-page accounting sites from
four old 2 KiB clicks to two current 4 KiB pages in its own unit.

## Static acceptance checklist

1. Pin the input image to the SHA above or rederive all addresses.
2. Globalize retained `hat_growsdt`; do not weaken or override it.
3. Preserve the null-root guard.
4. Pass `as+0x14`, not `*(as+0x14)`, as argument 1.
5. Call sections 2 and 3 with `nentries=0`, in that order.
6. Place both calls before `Lf_A` and before any read of `root[A]`.
7. Retain `0xb65e4 == 72 0c` and `0xb6610 == 72 0c`.
8. Retain the disabled `hat_map` preload, native no-op `hat_exec`, native
   `hat_dup`, and unreachable old `hat_swapout` assumptions.
9. Retain the central `cb_page_release` hooks and final
   `cpusha bc; pflusha` before root `kmem_free`.
10. Add no compensating `availrmem`, `availsmem`, or `pages_pp_kernel` write.

## Runtime acceptance

Use the already measured test; no allocation-site probe is a prerequisite:

```text
300 x fork + exit
300 x fork + exec + exit
```

Require:

- `availrmem + pages_pp_kernel` remains conserved;
- fork remains flat apart from background/`ptdat` pool granularity;
- dynamic exec no longer loses approximately one physical page per iteration;
- A4/A6 legacy false-descriptor skips disappear for address spaces cleaned by
  the new edge;
- `cb_rel_reject` remains zero;
- normal copyback, `hat_dup_cow`, exec, and power-cut disk-truth suites remain
  clean.

If a smaller residual remains, classify it against the one-unit `ptdat` pool
before changing this edge. The exact `hat_sdtalloc` probe remains a diagnostic,
not a precondition.

## Closure

For the pinned current image, the missing destructor edge can be restored
without porting the entire old HAT:

```text
hat_free040, after root-null check and before A/B/C walk:
    hat_growsdt(as+0x14, 2, 0)
    hat_growsdt(as+0x14, 3, 0)
```

This is a narrowly accepted whole-object legacy cleanup. It does not reverse
the broader policy that nonzero partial legacy resize, vnode preload, old
`hat_exec`, and old `hat_swapout` remain unported and unsafe.
