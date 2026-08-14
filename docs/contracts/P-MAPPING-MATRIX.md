# `page_t::p_mapping` writer/consumer matrix

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/P-MAPPING-MATRIX.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** This matrix records the mixed-tree risks
> that set the porting policy. In the current link, the retained `hat_map`
> preload producer is bypassed, `hat_pagesync` is a native 040 implementation,
> `hat_exec` is a no-op, and process swapout remains disabled, leaving retained
> `hat_swapout` unreachable. The unsafe rows below therefore describe pinned
> historical state or the consequences of re-enabling legacy paths, not a claim
> that each producer is live in the accepted kernel. The reverse-map layout and
> harvest-before-invalidate contract remain current.

## Scope

This memo collects every important current writer, remover, reader, and gate
user of `page_t::p_mapping` that matters to the 68040 HAT port. It is a
cross-cutting summary over the function-level HAT audits. It is documentation
and static analysis, not a patch.

The central question is:

```text
Can all current users of pp->p_mapping agree what each pointer in the chain is?
```

For the stock AMIX/030 HAT the answer was yes: the chain contained old-format
PTE addresses from the same old segment/page-table tree. In the current 040
port the answer is no: live 040 PTEs and retained 030 preload PTEs can both be
published into the same raw pointer chain.

## Field contract

The 3B2 SVR4 reference declares `p_mapping` as an address-sized field reserved
for machine-dependent HAT translation state (`vm/page.h:50`). The HAT header
also exposes that same storage under the names `p_ptdats` for page-table pages
and `p_sdtbits` for SDT allocation state (`vm/hat.h:95..96`).

So the field has two separate meanings:

| Page type | Meaning of `p_mapping` |
|---|---|
| Normal data page | head of reverse-map list of PTE addresses mapping this page |
| HAT page-table page | pointer to `ptdat` metadata, through `p_ptdats` |
| HAT SDT carve/page | SDT allocation bitmap, through `p_sdtbits` |

The reverse-map list node is not a separate structure. The PTE address itself is
the list node, and the next pointer is stored in software space after the PTE
array:

```text
pte->next == *(pte + NPGPT)
NPGPT == 64
next-pointer byte offset == 64 * 4 == 256
```

This offset survives the 040 port because a 040 leaf still has 64 four-byte PTE
slots. What changed is the meaning of the PTE word and the owner tree that can
reach that PTE.

## Provenance classes

Current matrix entries fall into three classes:

| Class | Examples | Provenance |
|---|---|---|
| Native 040 replacements | `hat_pteload`, `hat_unload`, `hat_pageunload`, `hat_free`, `hat_ptfree`, `hat_dup040` | project assembly replacements in `prototypes/hat040.s` / `hat_dup040.s` |
| Retained stock AMIX HAT | `hat_map`, `hat_pagesync`, `hat_swapout`, old `hat_ptalloc_orig` internals | byte-identical or lightly patched AMIX object body |
| Generic VM users | `page_abort`, `page_free`, `pvn_getdirty`, `segvn_fault`, pageout, `segu_softunload` | byte-identical AMIX object with 3B2 source as behavioral reference |

The field itself is global VM state, so all three classes must agree.

## PTE provenance types

For this audit, a `pp->p_mapping` entry can have at least these practical
provenance types:

| Type | Producer | PTE encoding | Hardware-reachable on 040? |
|---|---|---|---|
| Live 040 PTE | `hat_pteload`, `hat_dup040` | `(pfn << 12) | 040_status` | yes |
| Legacy phantom PTE | retained `hat_map` preload | `(pfn << 11) | old_status` | not for intended user VA |
| Retained stock old PTE | old `hat_swapout` / zero-flag `hat_exec` style paths | old 030 format | no, unless some old tree path is still used |
| Non-reverse-map alias | `hat_ptalloc`, `hat_sdtalloc` on HAT-owned pages | `ptdat` pointer or bitmap, not PTE list | not a mapping |

The raw `p_mapping` pointer does not encode which type it is. Every consumer
has to infer type from surrounding context, and many consumers do not have
enough context to do that safely.

## Writer matrix

| Routine | Writes `pp->p_mapping`? | Entry type | Notes |
|---|---|---|---|
| `hat_pteload` | yes | live 040 PTE | Authoritative load path for real faults and `hat_memload`; writes `pfn << 12`, links `leaf+256`, and flushes the MMU. |
| `hat_pteload` replacement path | yes | live 040 PTE | Unlinks the same PTE from the old page's chain, rewrites it for the new page, then links it to the new page. RSS/table counts are not changed because the VA slot already existed. |
| `hat_dup040` COW-private path | yes | live 040 child PTE | Allocates/copies a new page and links the child's new PTE into the new page's chain. |
| `hat_dup040` share path | yes | live 040 child PTE | Copies the parent PTE and splices the child PTE after the parent PTE in the same page chain. |
| retained `hat_map` | yes | legacy phantom PTE | Preloads resident vnode pages with old SDE/PTE geometry and links them into the real page chain. This is the main mixed-provenance producer. |
| stock `hat_exec` zero-flag fallback | potentially yes | legacy PTE | Retained body can copy/move old PTEs and update chains on the old geometry. `HAT-EXEC-POLICY.md` recommends blocking or loudly diagnosing this fallback unless fully ported. |
| `hat_ptalloc_orig` | yes, but alias | `p_ptdats` metadata | On a HAT page-table page, stores the `ptdat` array through the same field. This is not a data-page reverse map. |
| `hat_sdtalloc` | yes, but alias | `p_sdtbits` metadata | On an SDT allocation page, stores allocation bitmap state through the same field. This is not a data-page reverse map. |

The important distinction is that `hat_pteload` and `hat_dup040` publish PTEs
that the 040 MMU can actually walk. `hat_map` publishes PTEs that look like
valid reverse-map entries to software but do not satisfy the live 040 hardware
path for the user VA.

## Remover matrix

| Routine | Removes or clears chain entries? | Tree walked | Mixed-chain behavior |
|---|---|---|---|
| `hat_unload` | unlinks live PTEs from the derived page's chain and clears the PTE | live 040 A/B/C range walk | Removes live entries in the requested VA range. It does not discover phantom entries sitting in the old SDT tree. See `HAT-UNLOAD-ACCEPTANCE.md`. |
| `hat_free` | unlinks live PTEs, clears them, then frees live 040 table pages | live 040 whole-AS walk | Removes live 040 entries during AS teardown. It does not walk old SDT tables created by `hat_map`/`hat_growsdt`. |
| `hat_pageunload` | clears every PTE pointer found in `pp->p_mapping`, then sets head to NULL | reverse-map chain only | Physical-page-safe for both live and phantom entries because it does not decode PFN. It does not repair RSS, `pt_inuse`, or old table ownership. |
| retained `hat_swapout` | unlinks PTEs and frees old tables | old SDT/PTE walk | Closest consumer for legacy phantom entries, but it does not walk the live 040 tree and remains 030-shaped. |
| `hat_ptalloc_orig` steal path | unlinks PTEs from pages while stealing a table | old SDT/PTE walk | Mostly avoided where current 040 callers pass `HAT_NOSTEAL`, but the retained logic assumes old tree geometry and old PFN decoding. |
| `hat_ptfree` | clears `pp->p_mapping/p_ptdats` on the table page being freed | HAT page-table page | This is alias cleanup, not data-page reverse-map removal. It prevents recycled table pages from looking mapped. |

The native 040 unload/free paths and retained old paths are complementary in a
bad way: each can clean the tree it understands, but neither is a complete
garbage collector for the other's entries.

## Non-ownership PTE mutator

`hat_chgprot()` changes permissions on existing live PTEs without changing
reverse-map membership:

| Routine | PTE effect | Required `p_mapping` effect | Current status |
|---|---|---|---|
| `hat_chgprot` | clears resident, clears write-protect, or sets write-protect | none; same PTE must remain in the same page's chain | Main user-COW path is 040-native and coherent. `HAT-CHGPROT-AUDIT.md` records remaining descriptor-residency and static-table-domain gaps; `HAT-CHGPROT-ACCEPTANCE.md` defines the full contract. |

This distinction matters for `PROT_NONE`: stock-compatible behavior can leave a
nonzero but non-resident PTE in `pp->p_mapping`. Destructive consumers must use
the full PTE word or chain ownership, not assume that resident bit zero means
the slot is empty.

## Reader matrix

| Routine | Reads chain entries? | Assumption |
|---|---|---|
| current `hat_pagesync040` | yes | Every entry is assumed to be a sampleable PTE; current code does not validate resident/PFN/class or bound traversal. |
| `hat_pageunload` | yes | Every entry is assumed to be a PTE address whose U/M can be harvested, whose longword can be cleared, and whose next pointer is at `+256`. |
| `hat_unload` / `hat_free` | indirectly | For a live PTE found through the 040 tree, the exact PTE should appear in the PFN-derived page's chain. |
| `hat_pt2ptdat` consumers | indirectly | A PTE address can be mapped to its table metadata through `pp->p_ptdats`; this assumes the PTE belongs to a HAT-managed table page. |
| retained `hat_swapout` | yes | Old table walk plus old PTE/PFN decoding. |

`hat_pageunload` has the most type-agnostic behavior: it clears pointed-to PTE
longwords without needing to reconstruct VA or PFN. That makes it the most
tolerant consumer of a mixed chain, but only at the physical-page safety level.
It does not make the rest of the accounting correct.

`hat_pagesync040` is the opposite. It is a chain reader whose job is to decode
status bits and reconstruct flush addresses. A mixed chain gives it entries
with incompatible encodings.

`REFMOD-PAGEOUT-CONTRACT.md` follows the consequence upward into pageout, PVN,
fsflush, and segvn: those generic VM paths consume `p_ref`/`p_mod`, not raw PTE
state, so `hat_pagesync` is the critical bridge.

## Gate-only consumers

Several VM routines do not inspect chain nodes. They only treat
`pp->p_mapping != NULL` as "this page is still mapped":

| Routine/path | Use of `p_mapping` |
|---|---|
| `page_abort` | if non-NULL, calls `hat_pageunload(pp)` before `page_free` |
| `page_free` | panics if `p_mapping != NULL` at final free point |
| `pvn_getdirty` / `pvn_done` | decides whether to call `hat_pagesync` or `hat_pageunload` before invalidation/free |
| pageout `checkpage` | calls `hat_pagesync`, then later `hat_pageunload` before freeing |
| `segvn_faultpage` | uses `p_mapping == NULL` as one condition for stealing a clean resident page |
| `segvn` toss/free logic | skips pages that still appear mapped |
| `segu_softunload` | uses `p_mapping == NULL && keepcnt == 0` as part of async writeback decision |

These users are format-agnostic but lifetime-sensitive. A phantom mapping can
keep a page out of reclaim paths even though it provides no usable 040
translation. Conversely, a missing reverse-map entry can let `page_abort` skip
`hat_pageunload`, leaving a live PTE to a freed page.

## Main incompatibilities

### 1. One chain can contain two PTE formats

After a file-backed vnode segment is created with preload, retained `hat_map`
can install:

```text
legacy phantom PTE: (pfn << 11) | old_status
```

The first actual access still faults, because the 040 tree was not populated.
Current `hat_pteload` can then install:

```text
live 040 PTE: (pfn << 12) | 040_status
```

The resulting chain can look like:

```text
pp->p_mapping
  -> live 040 PTE    # actual translation
  -> legacy PTE      # software-visible phantom
```

No chain node tells later consumers which decode rule to use.

### 2. Unload by VA and unload by page see different worlds

`hat_unload` and `hat_free` walk the live 040 tree. They are correct for live
040 translations but blind to old SDT/PTE tables not reachable from that tree.

`hat_pageunload` walks the page's raw chain. It sees both live and phantom
entries, but it does not know how to retire the owning table metadata for every
entry type.

Thus VA-based cleanup and page-based cleanup can disagree about whether a page
or table is fully retired.

### 3. `p_mapping` aliasing makes bad PFN math dangerous

For normal data pages, offset 32 means reverse-map head. For HAT-owned table or
SDT pages, the same offset means `p_ptdats` or `p_sdtbits`.

If old PFN math identifies the wrong `page_t`, a table-management operation can
clear or overwrite what is actually a data page's reverse-map head. This is the
same failure class documented in the `hat_sdtfree` and `hat_ptfree` audits.

### 4. Gate-only VM code amplifies stale state

Generic VM code correctly treats `p_mapping != NULL` as proof that HAT cleanup
is required. That contract only works if the chain is complete and meaningful.

A stale phantom entry can prevent reclaim. A missing live entry can permit
free/reuse while a PTE is still resident. Both errors flow from the same
invariant failure:

```text
valid managed PTE <-> exactly one correct pp->p_mapping entry
```

## Function-level status

| Area | Status |
|---|---|
| `hat_pteload` | Good native 040 reverse-map producer for live PTEs; same-VA replacement moves the chain entry between pages. Different-PFN replacement still lacks old-page U/M harvest. |
| `hat_dup040` | Good intended native producer for fork/share/COW child PTEs; depends on the same `+256` link convention. |
| `hat_chgprot` | Native permission-only mutator; preserves chain ownership. The normal user-COW path is structurally sound, but the shared A/B walk still has descriptor and static-table-domain hardening gaps. |
| `hat_unload` | Good native VA-range remover for live 040 PTEs; cannot remove phantom old-tree entries. `HAT-UNLOAD-ACCEPTANCE.md` defines the accepted narrow contract. |
| `hat_free` | Good native AS teardown remover for live 040 tree; cannot retire old SDT/PTE tables. |
| `hat_pageunload` | Best emergency physical-page cleanup; harvests U/M and clears all listed PTE words and head pointer, but leaves accounting/table ownership drift. `HAT-PAGEUNLOAD-ACCEPTANCE.md` defines the accepted narrow contract. |
| `hat_map` | Bad active producer for 040 semantics; publishes old-format phantom mappings into real page chains. `HAT-MAP-POLICY.md` recommends no new phantom production unless fully ported. |
| `hat_pagesync` | Bad mixed-chain reader; stock VA/PTE decode does not match live 040 entries. `HAT-PAGESYNC040-DESIGN.md` defines a live-only classifier and `HAT-PAGESYNC040-ACCEPTANCE.md` defines acceptance criteria for a future replacement. |
| `hat_swapout` | Bad mixed-tree cleanup; old tree walk does not match live 040 mappings. |
| `hat_ptalloc_orig` / `hat_ptfree` | Mixed allocator/free contract; uses `p_mapping` aliases and still carries old metadata/list assumptions. |

## Practical conclusion

`pp->p_mapping` should be treated as the highest-value cross-check for this
port. The field is where hardware mappings, page lifetime, page reclaim, and HAT
table ownership meet.

The current safe subset is:

```text
hat_pteload / hat_dup040 produce live 040 PTE entries
hat_unload / hat_free remove live 040 PTE entries by VA or AS
hat_pageunload can clear any listed PTE before physical page reuse
```

The unsafe subset in the pinned mixed-tree image, or if the corresponding
legacy paths are reinstated, is:

```text
hat_map can add legacy phantom PTEs to the same chain
hat_pagesync and hat_swapout still interpret entries through old geometry
hat_ptalloc/hat_sdtalloc aliases mean wrong-page metadata writes hit the same field
```

For future development, the clean architectural target would be one of these:

1. Stop `hat_map` from publishing preload PTEs unless it creates real 040
   translations.
2. Add explicit provenance to reverse-map entries, so consumers know whether an
   entry is live 040, legacy, or metadata.
3. Retire all old-tree producers and consumers from active paths, leaving
   `p_mapping` as a pure live-040 reverse map.

Option 3 is the simplest invariant. Until then, every crash involving
unexpected page reuse, `page_free`, `page_abort`, RSS drift, or pageout should
log both the PTE value and the provenance of the `p_mapping` entry, not merely
whether `p_mapping` is zero.
