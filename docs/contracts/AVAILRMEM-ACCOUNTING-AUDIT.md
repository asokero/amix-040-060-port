# `availrmem` accounting audit (ISSUE-40)

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/AVAILRMEM-ACCOUNTING-AUDIT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Implementation follow-up (2026-08-01):** Real hardware confirmed this
> debit/credit signature. `ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md` now proves
> that the exact whole-object `hat_growsdt(hatp, 2/3, 0)` cleanup is safe in
> this pinned image when called before the native A/B/C walk. Its narrow
> acceptance supersedes this audit's earlier statement that no cleanup call
> was yet approved; nonzero partial legacy shrink remains unapproved.
>
> **Second hardware follow-up (2026-08-01):** The landed edge released 629
> legacy objects across boot plus 419 teardowns but returned zero physical
> pages. The final backing page had freed bits 0..17 and thirteen live one-unit
> `ptdat` allocations at bits 18..30. Thus the `ptdat` lifetime is not merely a
> lower-rate residual after the first edge: it is the measured pin that keeps
> the same one-page-per-exec slope. The exact inverse is now specified in
> `ISSUE40-PTDAT-TEARDOWN-CONTRACT.md`.

## Scope

This note pairs every `availrmem` debit and credit relevant to the measured
`fork` / `exec` workload. It identifies the deterministic one-page-per-`exec`
loss and separately records lower-rate accounting residuals that do not satisfy
that predicate.

This is static analysis and a runtime-verification prescription. It does not
patch the kernel.

## Pinned artifacts

| Artifact | Identity |
|---|---|
| Kernel | `build/unix-040`, build `68040-260801-04` |
| Kernel SHA-256 | `e956ea34dd83c77bb759151e957713b0a3d7e2148f4596126523d56f3739befb` |
| Kernel `.text` size | `0x000e4588` |
| AMIX libc | `vanilla/usr/lib/libc.so.1` |
| libc SHA-256 | `09d52bb3ff5a691c9ec4b057f3b3cad484ba98ce8d057a892082ca2010dda46c` |
| Reference contract | 3B2 `vm/vm_hat.c`, `vm/vm_as.c`, and `os/exec.c` |

All kernel addresses below are linked `.text` offsets unless explicitly
labelled as runtime addresses.

## Verdict

The deterministic loss is the retained legacy-SDT producer/consumer mismatch:

```text
dynamic exec
  -> segvn_create
  -> stock hat_map
  -> stock hat_growsdt(section 3, 130 entries)
  -> stock/byte-patched hat_sdtalloc(n = 17 units)
       -> forces a distinct retained 4 KiB backing page per exec AS
       -> allocator-family net: availrmem--, availsmem--,
          pages_pp_kernel++

old address-space death
  -> as_free
  -> port's hat_free040
       -> destroys only the live 040 A/B/C tree
       -> does not call hat_growsdt(..., 0) or hat_sdtfree
       -> frees the 040 root and loses the AS-side legacy-SDT reference
```

The debit is executed by a retained stock body at `hat_sdtalloc+0x136`
(`0x000b6464`). The missing ownership transition is in the port's active
`hat_free` override at `0x000d82bc`.

Therefore the ownership answer is deliberately two-sided:

- **producer/debit:** retained stock `hat_map -> hat_growsdt -> hat_sdtalloc`;
- **missing consumer/credit:** the port's own 040 `hat_free` replacement.

This is not safely repaired by incrementing `availrmem`. The backing page is
still held by the SDT allocator and still has allocated bitmap units. A naked
credit would make the counters claim that an unavailable page can be used.

Confidence is **high**. The control flow, allocation size, inability to share
the allocation, and absent teardown relocation are byte-proven. One counter
pair described below can close the remaining runtime attribution cheaply.

## Why the slope is exactly one page per `exec`

### The mandatory section-3 mapping

AMIX defines the shared-library base as:

```text
UVSHM = 0xc1000000
```

The installed `libc.so.1` first `PT_LOAD` has:

```text
p_vaddr = 0x00000094
p_memsz = 0x0002d7f4
```

Its last mapped byte is therefore:

```text
0xc1000000 + 0x94 + 0x2d7f4 - 1 = 0xc102d887
```

The retained 030 geometry used by `hat_map` divides a section into 128 KiB
segments (`SEGNUM(va) = (va >> 17) & 0x1fff`). Relative to section 3:

```text
(0xc102d887 - 0xc0000000) >> 17 = 0x81 = 129
newnseg + 1                            = 130 entries
nsize = ceil(130 / 8)                 = 17 SDT units
```

`hat_growsdt` computes that final value at `0x000b60d0..0x000b60d8` and calls
`hat_sdtalloc` at `0x000b6198` (relocation `0x000b619a`).

### Why two execs cannot share the backing page

The retained allocator still uses:

```text
64 bytes per SDT unit
32 allocator units per backing page
32-bit page_t::p_sdtbits bitmap
```

The Model-B patches changed physical backing to a 4 KiB page but deliberately
left the old 32-unit bitmap model. A 17-unit allocation leaves only 15 units.
No second 17-unit request can fit in that page:

```text
2 * 17 > 32
```

Consequently N leaked libc section-3 allocations require at least N charged
physical pages. The debit for a particular page can occur on an earlier small
SDT allocation that created the freelist page; the later 17-unit call can then
consume that page's free run. That changes which call executes `0xb6464`, but
not the net one-page-per-exec slope. Smaller allocations can consume the
remaining 15 slots but cannot put two 17-unit objects on one page.

### Why `fork` does not have the same mandatory debit

The linked image has only two direct `hat_map` callers:

| Caller | Call / relocation | Role |
|---|---:|---|
| `segdev_create` | `0x000a7a48 / 0x000a7a4a` | new device segment |
| `segvn_create` | `0x000aacc2 / 0x000aacc4` | new vnode/anon segment |

`as_dup` duplicates segment objects through their `dup` operations and then
calls the native `hat_dup` at relocation `0x000ae04c`. It does not call
`segvn_create` or `hat_map`. The native `hat_dup` builds the live 040 tree and
does not call `hat_growsdt`.

The public `hat_exec` at `0x000d8880` is also a two-instruction no-op:

```text
4280    clrl d0
4e75    rts
```

It is not the legacy-SDT producer in this image. The mandatory 17-unit request
comes from segment creation in the new exec address space.

This predicts the measured discriminator:

```text
fork + exit:        no deterministic 17-unit SDT allocation
fork + exec + exit: one unreclaimed 17-unit allocation
```

## Byte-level ownership chain

| Stage | Address | Pinned behavior |
|---|---:|---|
| `segvn_create` | `0x000aabfa` | invokes `hat_map` at `0x000aacc2` |
| `hat_map` | `0x000b57e0` | computes `newnseg` with `>>17` |
| legacy growth | `0x000b5882` | calls `hat_growsdt`; relocation at `0x000b5884` |
| vnode preload gate | `0x000b58d2` | current `60 00 00 12`: unconditional skip; phantom preload is disabled |
| `hat_growsdt` | `0x000b6058` | computes `nsize = ceil(nentries/8)` |
| SDT allocation | `0x000b6198` | calls `hat_sdtalloc`; relocation at `0x000b619a` |
| physical debit | `0x000b6464` | `availrmem -= i`; then `availsmem -= i`, `pages_pp_kernel += i` |
| stock SDT credit | `0x000b66e4`, `0x000b678c`, `0x000b6834` | each fully released backing page credits the three counters |
| `as_free` | `0x000adf9a` | calls public `hat_free` at relocation `0x000adfa8` before segment unmap |
| active `hat_free` | `0x000d82bc` | native live-040 A/B/C teardown; no relocation to `hat_growsdt` or `hat_sdtfree` |
| root retirement | `0x000d858a..0x000d85a2` | clears `as+20`, pushes/flushes, and `kmem_free(root, 0x1000)` |

The 3B2 lifetime contract supplies the missing edge. Stock `hat_free` calls:

```c
hat_growsdt(hatp, section, 0);
```

at `vm/vm_hat.c:356`. That reaches `hat_sdtfree`, whose complete-page exits
restore `availrmem`, `availsmem`, and `pages_pp_kernel`
(`vm_hat.c:2334..2339`, `2370..2376`, and `2393..2400`).

The port replaced the whole-AS destructor without carrying this parallel
legacy-object lifetime into the replacement.

## Debit/credit matrix for the measured path

| Writer family | Possible `exec` reachability | Intended credit | Predicate verdict |
|---|---|---|---|
| `exit` `+USIZE` | only the `SPROCIO` release branch | earlier process-I/O lock charge | positive-only here; cannot cause the loss |
| KMA pools / `kmem_alloc` | yes, including the 040 root | `kmem_free` / pool release | root has explicit `kmem_free(root, 0x1000)`; pool retention is amortized, not exactly one per exec |
| `ublock` / `ubunlock` | process-lock operations, not ordinary exec | paired `-4/+4` | fork-common or inactive in the test; wrong magnitude is symmetric |
| `kseg` / `unkseg` | temporary kernel mappings | paired by mapping lifetime | no mandatory unpaired exec-only edge |
| `segu_get` / `segu_release` | process/u-area lifecycle | paired `-4/+4` when charged | fork and exec share the u-area; does not satisfy exec-only discriminator |
| `segvn_faultpage` / `segvn_softunlock` | `F_SOFTLOCK` pages | one per locked page | ordinary exec mappings fault with normal page ownership; no fixed one-page unpairing found |
| `page_abort`, page lock/claim, addmem/delmem | generic page or topology transitions | matching page-state transition | event-dependent and not one per exec; no missing exec edge found |
| `hat_ptalloc` table page | live 040 table creation | normal custom `hat_ptfree` `0x000d860e` | direct physical-page debit is balanced on measured `keepcnt 1 -> 0`; `Lpf_n=0` excludes its guarded leak exit |
| `hat_ptalloc` one-unit `ptdat` metadata | every newly allocated table page | stock contract calls `hat_sdtfree(pp->p_ptdats, 1)` | **measured second pin after SDT cleanup**; pool-granular alone, but thirteen live bits keep each exec backing page charged in the observed layout |
| `hat_sdtalloc` 17-unit libc SDT | exactly once for each dynamic exec AS | stock `hat_free -> hat_growsdt(...,0) -> hat_sdtfree` | **root cause:** active 040 `hat_free` omits the credit/lifetime edge |

No other census family predicts both `-1` per dynamic exec and zero mandatory
loss per fork.

## `ptdat` metadata lifetime: measured second edge

The main verdict does not close the separate allocator mismatch documented in
`HAT-PTFREE-AUDIT.md` and `PAGE-TABLE-LIFETIME-CONTRACT.md`:

```text
hat_ptalloc@0xb69ae
  -> hat_sdtalloc(..., 1, ...)
  -> pp->p_ptdats and active_pts/free_pts records

custom hat_ptfree@0xd85ce
  -> clears pp+32
  -> releases the table page and its direct HAT accounting
  -> does not unlink ptdat records
  -> does not call hat_sdtfree(metadata, 1)
```

That leaks one 64-byte allocator unit per newly allocated table page. In the
original pre-cleanup image its physical effect was pool-granular and also
reachable from native `hat_dup`, so it did not independently identify the
first deterministic producer.

The post-cleanup hardware result changes the closure, not that original
attribution. After the section objects are freed, thirteen one-unit `ptdat`
bits remain immediately above the released 18-unit range. They keep the same
backing page charged, and the next exec cannot fit its 18-unit allocation in
the sole remaining bit. The complete current mechanism is therefore:

```text
legacy SDT lifetime omission creates the per-exec backing-page demand
+ ptdat lifetime omission pins that page after SDT cleanup
= one page remains lost per dynamic exec until both edges are restored
```

`Lpf_n=0` does not test this metadata lifetime. It only proves that the custom
physical table-page free did not take `Lpf_leak`.

## Runtime confirmation

### Cheapest counter invariant

For the pinned image, linked `.data` starts at:

```text
0x08000000 + 0x000e4588 = 0x080e4588
```

`pages_pp_kernel` is `.data+0x0000b528`, hence its direct runtime address is:

```text
0x080efab0
```

The existing ISSUE-39 pointer table remains usable for the other counters:

```text
i39_availrmem_p runtime slot = 0x080fcfa4
i39_availsmem_p runtime slot = 0x080fcfa8
```

Across 300 fork+exec operations, compared with a fork-only control, the primary
mechanism predicts approximately:

```text
availrmem       -300
availsmem       -300
pages_pp_kernel +300

availrmem + pages_pp_kernel ~= invariant
```

The approximation qualifier covers unrelated background transitions and the
secondary one-unit metadata pool. The three-way sign and near-equal magnitude
are the important discriminator.

The observation that `freemem` recovers after deleting test files does not
refute this physical leak. `freemem` includes reclaimable/cache-page traffic;
the workload can return more cached file pages than the SDT allocator holds.
`pages_pp_kernel` is the direct ownership counter.

### Exact allocation-site probe

For an exact ownership trace, record every `hat_sdtalloc` entry/return and every
new-page debit at `0x000b6464`. Capture:

```text
n
i at 0xb6464       expected 1
returned base/PFN
hat_sdtalloc RA    0x000b619e for hat_growsdt allocations
hat_growsdt caller 0x000b5888 for hat_map growth
```

Expected result:

```text
dynamic fork+exec: one n=17 allocation per exec
                     N such live allocations occupy N distinct backing PFNs
                     N + O(1) net legacy-SDT backing-page debits over N execs
fork-only:           no n=17 allocation
AS death:            no matching hat_sdtfree(base, 17)
```

The `O(1)` term is initial freelist state: the call that first charges a page
may be an earlier small section-table request, while the 17-unit libc request
later makes that page permanently unique to one exec AS. Caller and `n`
together distinguish this path from `hat_ptalloc`'s `n=1` metadata requests.

A useful negative control is an executable that does not load libc at
`UVSHM`. It should have no `n=17` call and no deterministic one-full-page
slope; any small legacy SDT objects can share the 32-unit pool. This also
makes explicit that the proof applies to the measured dynamically linked exec
target, not to every theoretically possible static/legacy executable format.

## `USIZE = 4` verdict

The installed AMIX header defines:

```c
#define USIZE 4    /* size of user block (*2048 bytes) */
```

So `USIZE` is historically not a count of arbitrary current VM pages. It is a
legacy 2 KiB-click quantity and denotes an 8 KiB u-area.

The current binary confirms that the byte size remains correct:

- `segu_get_orig` reserves and `page_get`s `0x2000` at `0x000aa4aa` and
  `0x000aa522`;
- its physical-page loop runs twice and advances by `0x1000` at
  `0x000aa69c`;
- `segu_release` unloads and releases `0x2000` at `0x000aa76e` and below;
- `segu_ubptbl040` represents the two 4 KiB pages as four legacy 2 KiB
  `p_ubptbl` entries.

The same literal is wrong when used as a **4 KiB resident-page count**:

| Site | Current accounting | Physical Model-B ownership |
|---|---:|---:|
| `segu_get_orig` | `availrmem -= 4`, `pages_pp_kernel += 4` | two 4 KiB pages |
| failure unwind / `segu_release` | corresponding `+4/-4` | releases two 4 KiB pages |
| `ublock` / `ubunlock` | `-4/+4` locked pages | an 8 KiB u-area is two pages |
| `exit` `SPROCIO` release | `+4` | same two-page u-area ownership class |

Therefore:

```text
USIZE = 4 is correct as the legacy 8 KiB ABI/structure quantity.
USIZE = 4 is a Model-B residual when interpreted as 4 KiB page accounting.
The correct resident-page count is 2.
```

Changing the global definition to 2 would break byte lengths and the four
entry `p_ubptbl` ABI. A future implementation should separate byte size / old
click count from current physical-page accounting, for example:

```text
USIZE_BYTES = 0x2000
USIZE_PAGES = 2
```

The stale magnitude is symmetric on normal get/release and lock/unlock paths,
so it over-reserves memory but cannot produce the measured `-1/exec` leak.

## Current `hat_sdtfree` caveat

Older analysis notes correctly recorded that an earlier image left
`hat_sdtfree` at `base >> 11`. The pinned ISSUE-40 image has the two PFN
conversions patched to `>>12` at `0x000b65e4` and `0x000b6610`.

That removes the former doubled-PFN failure for a single lower-half bitmap
allocation such as this 17-unit object. It does **not** by itself approve
adding a cleanup call to `hat_free`:

- `hat_growsdt` still overlays 8-byte legacy descriptors on the live 040 root;
- `hat_free040` may inspect/skip those words as 040 A descriptors before root
  retirement;
- allocations larger than 32 units still have unresolved packed-byte versus
  per-`page_t` geometry;
- ordering and ownership must be proven before any legacy free is enabled.

The safest implementation direction remains the one already recorded in
`HAT-MAP-POLICY.md`: stop `hat_map` from creating redundant legacy SDT state
on 040/060. The vnode preload body is already disabled in this image, so the
remaining growth has no live-040 mapping benefit. A full symmetric cleanup is
the alternative, but it is a larger unit.

Neither direction is implemented by this audit.

## Closure statement

ISSUE-40's complete measured ownership chain is now closed as:

```text
first missing lifetime edge:
  hat_sdtalloc(n=17) debit
    --X--> hat_sdtfree(n=17) credit at AS death

owner of first missing edge:
  port's native hat_free replacement

second missing lifetime edge:
  hat_ptalloc -> hat_sdtalloc(n=1)
    --X--> four-node unlink + hat_sdtfree(n=1) at table death

owner of second missing edge:
  port's native hat_ptfree replacement

reason for one page/exec:
  libc section-3 mapping requires 17 of 32 bitmap units

reason the first SDT edge has no mandatory page/fork:
  fork duplicates through hat_dup and does not call hat_map/hat_growsdt

reason the first landed edge credited zero physical pages:
  thirteen leaked ptdat bits remained in the same p_sdtbits bitmap
```

The `ptdat` metadata lifetime is now the measured second half of ISSUE-40 and
is specified separately so each ownership edge remains reviewable. `USIZE`
page-count accounting remains an independent symmetric residual. None of the
three may be hidden by a compensating counter increment.
