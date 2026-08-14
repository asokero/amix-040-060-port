# `hat_exec` 68040 static audit

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/HAT-EXEC-AUDIT.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The retained 030 body audited here is no
> longer the live `hat_exec`: `src/hat_exec040.s` overrides it with a successful
> no-op. `as_exec` still transfers the segment object, old-AS teardown removes
> the old translations, and normal 040 faults rebuild them in the new address
> space. This audit is the provenance and safety argument for that policy; any
> wording below which calls the retained body "current" refers to the pinned
> pre-override image.

## Scope

This memo audits the exec-time HAT stack-transfer path in the current 68040
kernel. It is a static-analysis and documentation result, not a kernel patch.

The central question is whether `hat_exec` transfers mappings in the live 040
A/B/C tree, updates only legacy 030 metadata, or affects both representations.

## Provenance and active symbols

| Artifact | Symbol/address | Size | Role |
|---|---:|---:|---|
| vanilla AMIX kernel | `hat_exec` `0x000b6f20` | `0x524` | original implementation |
| Ghidra vanilla address | `0x000c6f20` | `0x524` | analyzed vanilla body |
| `amix-src/sys/vm/exp` | `hat_exec` `0x0000f4f8` | `0x524` | exact AMIX object reference |
| `build/unix-040` | `hat_exec` `0x000b6f20` | `0x524` | original body with 040 root-load patch |
| `build/unix-040-dbg` | `hat_exec_orig` `0x000b6f20` | `0x524` | same work body under an alias |
| `build/unix-040-dbg` | `hat_exec` `0x000da862` | wrapper | diagnostics, then calls `hat_exec_orig` |

The vanilla body is byte-for-byte identical to the `vm/exp` body and has the
same relocation signature. It is therefore an AMIX-provenanced implementation,
not merely a source analogy.

Comparing the complete vanilla body with current `hat_exec_orig` finds only
eight changed bytes at `0x000b70ea..0x000b70f1`:

```text
vanilla: pmove old-root,%crp ; 030 pflusha
current: movec root-phys,%urp ; 040 pflusha ; nop
```

All section, segment, page, SDE, PTE, and `ptdat` arithmetic around that patch
is still the original 030 code. Current relocations do, however, resolve to the
current `hat_ptalloc`, `hat_ptfree`, `hat_pt2ptdat`, and `flushmmu` symbols, so
the unchanged body now calls helpers with mixed 030/040 contracts.

The 3B2 source at `vm_hat.c:2723` is a useful semantic reference. The exact
AMIX object remains authoritative where the source listing is inconsistent,
notably around the slow-path `hat_ptalloc` call and destination table address.

## Exec call chain

The active path is:

```text
exec argument construction
  -> execstk_addr(size, &hatflag)
  -> remove_proc
     -> as_alloc()                         new address space
     -> as_exec(oas, ostka, stksz,
                nas, nstka, hatflag)
        -> detach the existing stack seg from oas
        -> attach the same seg to nas at nstka
        -> hat_exec(...)
     -> relvm(p)                           destroy old address space
     -> p->p_as = nas
     -> hat_asload()                       load nas->root into URP
```

Current binary addresses include:

| Function/site | Address |
|---|---:|
| `remove_proc` | `0x00057e78` |
| `remove_proc -> as_exec` | `0x00057f1a` |
| `remove_proc -> relvm` | `0x00057f20` |
| `remove_proc -> hat_asload` | `0x00057f2e` |
| `as_exec` | `0x000aed8a` |
| `as_exec -> hat_exec` | `0x000aee22` |
| `execstk_addr` | `0x000af2b8` |

`as_exec` moves the segment object before it calls HAT. The segment's anon/file
backing therefore belongs to `nas` even if no hardware mapping is transferred.
Afterward `remove_proc` ignores the return value from `as_exec`, frees `oas`,
installs `nas`, and loads its 040 root.

This establishes an important lifecycle fact: the stack data is owned by the
moved segment and its backing pages, not by the old PTEs. HAT mappings are a
reconstructable cache. Missing mappings in `nas` can normally be rebuilt by
faulting the moved segment after exec.

## `hatflag` meaning

Stock `execstk_addr` prefers a temporary stack hole aligned to a complete 030
page-table coverage boundary:

```text
030 page size       = 2 KiB
030 PTEs per table  = 64
030 table coverage  = 128 KiB
```

It returns `hatflag = 1` when that aligned hole is available. This allows stock
`hat_exec` to move whole page tables. If no aligned hole exists it returns
`hatflag = 0`, requiring individual PTE copies.

The current `execstk_addr` has 4 KiB free-page and section-end constants, but
it still rounds stack holes to `0x20000` (128 KiB). A 040 leaf covers:

```text
64 PTEs * 4 KiB = 256 KiB
```

Therefore current `hatflag = 1` does not prove that a whole 040 leaf contains
only stack mappings. A future native 040 whole-leaf move cannot reuse this flag
without changing its alignment/exclusivity contract.

Project runtime notes report that the observed exec path uses `hatflag = 1`.
The diagnostic bracket did not show the suspected data-page corruption during
that path. This is useful runtime evidence, but it does not change the static
geometry result.

## Geometry comparison

| Concept | `hat_exec_orig` | Live 040 HAT |
|---|---|---|
| top selector | `(va >> 30) & 3` section | `A = (va >> 25) & 0x7f` |
| middle selector | `(va >> 17) & 0x1fff` segment | `B = (va >> 18) & 0x7f` |
| page selector | `(va >> 11) & 0x3f` | `C = (va >> 12) & 0x3f` |
| parent descriptor | 8-byte SDE | 4-byte A/B descriptor |
| VM page step | `0x800` | `0x1000` |
| leaf coverage | `0x20000` | `0x40000` |
| managed PFN extraction | 21 bits | 20 bits |

The 256-byte PTE payload happens to remain 64 four-byte entries in both
models. That superficial similarity does not make the containing tree or VA
indexing compatible.

## Legacy tree embedded in the live root

Current `hat_alloc` allocates a zeroed 4 KiB 040 root and stores its address in
`as+20`. The live 040 walker interprets it as 128 four-byte A descriptors.

Stock `hat_growsdt`, called by `hat_exec`, interprets the same pointer as the
base of four 8-byte 030 section descriptors:

```text
old section descriptor = root + section * 8
```

This aliases 030 fields onto these 040 root slots:

| Old section | Byte range | 040 root entries | 040 VA ranges represented |
|---:|---:|---:|---|
| 2 | `root+0x10..0x17` | A4/A5 | `0x08000000..0x0bffffff` |
| 3 | `root+0x18..0x1f` | A6/A7 | `0x0c000000..0x0fffffff` |

Actual section-2 and section-3 user addresses use 040 A indices 64..127, not
4..7. Thus `hat_growsdt` does not build the intended high-user 040 tree.

The alias is not completely inert. In an old 8-byte section descriptor:

- the first long contains limit/protection/UDT state;
- the second long contains the old segment-table address.

The 040 MMU sees those two longs as two independent A descriptors. For the
common stack region around `0xc07ff000`:

```text
old SEGNUM = 0x3f
new A/B/C  = 0x60 / 0x1f / 0x3f
```

Growing the old section-3 table to 64 entries stores old limit `0x3f` and UDT
bits in root A6. In 040 interpretation this produces the `0x003f0002/3` family
of false root descriptors whose apparent pointer-table base is `0x003f0000`.
This statically explains the relic addresses described in the project notes.

Root A7 receives the aligned old SDT address in its second long. Its low UDT
bits are normally zero, so it usually appears invalid to the 040 walker. The
old SDT allocation is nevertheless real memory and remains reachable to the
030 software through that second long.

## Common `hatflag != 0` path

The fast path is `0x000b700a..0x000b70f4`.

Its stock intent is to move complete page tables:

1. Grow the destination's old section table with `hat_growsdt`.
2. Derive source and destination SDE arrays from the old section descriptors.
3. For each covered old segment:
   - skip an invalid source SDE;
   - obtain the table's `ptdat`;
   - change `ptdat->pt_as` to `nas`;
   - rewrite `ptdat->pt_secseg` with old packing;
   - copy both longs of the source SDE to the destination SDE;
   - clear source SDE validity;
   - transfer `pt_inuse` from old RSS to new RSS.
4. Reload the old/current root and flush the ATC.

On the current 040 build, every tree location in steps 1-3 is in the legacy
section/SDE representation. The function does not calculate A96/B31/C63 for a
stack around `0xc07ff000`, and it does not copy or relink a live 040 B or leaf
descriptor.

`hat_map` also calls the stock `hat_growsdt` when segments are created. It can
populate legacy tables through its own old vnode-preload body, while normal
fault mappings use current `hat_pteload` and the separate A/B/C walk. The exec
stack is normally anonymous and has no vnode page list to preload, so its old
SDT can exist with invalid SDEs while its real mappings live only in A/B/C. If
a source SDE is invalid, the fast loop simply skips it.

The likely common effect is therefore:

- allocate or grow legacy destination SDT storage;
- leave the live stack mappings in `oas`;
- move no live mapping to `nas`;
- flush the old/current URP;
- let `relvm` tear down the old A/B/C mappings;
- rebuild the new stack mappings on demand from the moved segment.

This interpretation agrees with the reported clean `hatflag = 1` runtime
bracket. It is an inference from the static split-tree model plus that runtime
observation, not proof that every exec has invalid old SDEs.

## Fallback `hatflag == 0` path

The slow path is `0x000b70f8..0x000b7434`. It is substantially more dangerous
if it processes a valid legacy source SDE.

Observed behavior:

1. Walk the range in `0x800` increments.
2. Skip to the next `0x20000` boundary when an old source SDE is invalid.
3. Select `opte` with `(ostka >> 11) & 0x3f`.
4. Extract a 21-bit PFN and find `page_t`.
5. If the destination old SDE is invalid:
   - hold the data page and source `ptdat`;
   - call current `hat_ptalloc` with flag `0`;
   - initialize the returned `ptdat` with old `pt_secseg` packing;
   - install the returned table in an old 8-byte SDE.
6. Select `npte` with `(nstka >> 11) & 0x3f`.
7. Copy a PTE, move the reverse-map link, clear `opte`, and call `flushmmu`.
8. Decrement the old `pt_inuse`; if it reaches zero, call current
   `hat_ptfree` and then clear old SDE validity.
9. Increment destination `pt_inuse` and RSS.

The exact AMIX object copies the first PTE long at the source table base into
`npte`, not the selected `opte` long. That is what the disassembly at
`0x000b7324..0x000b732e` does and what the 3B2 text also appears to express.
For a nonzero old page index this is not a normal per-PTE move.

Even without that anomaly, the fallback is not 040-safe:

- it runs twice per current 4 KiB VM page;
- old page indices select 2 KiB halves, not 040 C entries;
- old segment transitions occur every 128 KiB, half a 040 leaf;
- PFN width is stale;
- old SDE validity is cleared only after `hat_ptfree`;
- `flushmmu` receives `nstka` after clearing the source PTE, although current
  global `pflusha` makes the passed VA irrelevant;
- no data-cache push makes table writes visible to a 040 hardware walk;
- allocation flag `0` permits the already unsafe legacy steal path;
- current `hat_ptfree` assumes whole-page ownership and leaves stale `ptdat`
  list state.

This path must not be interpreted as a partial 040 mapping move. It is a stock
030 PTE migration routine calling mixed-contract helpers.

## Helper-contract interactions

| Helper | Current interaction from `hat_exec_orig` |
|---|---|
| `hat_growsdt` | builds old 8-byte section/SDE state inside A4..A7 and separate SDT storage |
| `hat_pt2ptdat` | has patched 4 KiB page lookup but retains four-fragment `ptdat` selection |
| `hat_ptalloc` | normally returns a whole 4 KiB page; flag `0` allows stealing and no wait |
| `hat_ptfree` | frees a whole page but does not retire old `active_pts/free_pts` records |
| `flushmmu` | ignores VA/count and performs global `pflusha`; no `cpusha` |
| `hat_asload` | correctly loads `p->p_as+20` as the final 040 URP root after exec |

The function therefore crosses nearly every unresolved compatibility boundary
in the allocator. Its common fast path may avoid most of them by finding no
valid old SDE. The slow path exercises them directly.

## Error handling

`hat_exec_orig` returns an error if the initial `hat_growsdt` fails. A slow-path
`hat_ptalloc` failure is treated as a panic.

Current `remove_proc` does not inspect the `as_exec` return value. It proceeds
to free `oas`, install `nas`, and load the new root. Because the segment has
already moved, a no-mapping result can still recover by faulting. Ignoring an
allocation error nevertheless means the caller does not distinguish the
intended HAT optimization from a failed legacy metadata operation.

## Effect classification

### Proven live and useful

- `as_exec` moves the real stack segment object and changes its base/owner.
- `relvm` destroys old mappings after the segment move.
- `hat_asload` installs the actual new 040 root.
- the fast-path 040 URP load and global ATC flush are valid 040 instructions.

### Legacy but often operationally inert

- old SDT allocation and old SDE scans;
- `pt_secseg` rewrites for old page tables;
- whole-table copy when source old SDEs are invalid and therefore skipped.

These still consume memory and leave metadata that teardown must tolerate.

### Visible to the 040 tree despite legacy intent

- 030 section descriptors stored in root A4..A7;
- false A descriptors such as the `0x003f0002/3` family;
- root-scan and teardown encounters with bogus pointer-table bases.

Normal AMIX user mappings start in the high section-2/3 ranges, so A4..A7 are
not their intended locations. They remain real root entries, not private
side-band metadata.

### Unsafe if exercised

- the entire `hatflag == 0` PTE move;
- any fast-path valid old SDE that is assumed to represent a live 040 leaf;
- current `hat_ptfree` calls reached through old table ownership;
- allocator fallback to steal from the stale `active_pts` model.

## Findings

### High: `hat_exec_orig` is not a 040 mapping-transfer implementation

Except for the final URP instruction sequence, the body remains stock 030. It
does not locate or transfer the live stack A/B/C mappings.

### High: legacy section descriptors pollute the live 040 root

`hat_growsdt` overlays 8-byte section descriptors on A4..A7. The old segment
limit and UDT fields form false 040 pointer descriptors. This explains the
observed `0x003f0002/3` root relic without requiring random memory corruption.

### High: the fallback PTE-copy path is structurally unsafe

It uses 2 KiB stepping, 128 KiB segments, 21-bit PFNs, old SDEs, permissive
table allocation, and the mixed-contract free path. The exact object also
copies the source table's first PTE rather than the selected source PTE.

### Medium: `hatflag = 1` no longer proves whole-leaf exclusivity

`execstk_addr` still aligns to 128 KiB while a 040 leaf covers 256 KiB. The flag
cannot authorize a native 040 whole-table move as currently defined.

### Medium: the common fast path is probably redundant legacy work

The real segment survives and new mappings can fault in. When old SDEs are
invalid, the fast path moves no mapping but still grows old SDT state and
flushes the root. This can add allocation and teardown pressure without
providing the intended optimization.

### Medium: the HAT error result is ignored

`remove_proc` continues after `as_exec` regardless of return value. The current
fault-rebuild lifecycle can mask this, but it weakens the function's stated
allocation/error contract.

## Practical conclusion

The current `hat_exec_orig` should be understood as a legacy 030 stack-mapping
optimization running alongside the real 040 HAT, not as part of the native
A/B/C mapping path.

For the commonly observed `hatflag = 1` case, the actual successful 040
lifecycle is likely segment transfer followed by old-AS teardown and demand
fault reconstruction in the new AS. The old HAT work mainly creates and scans
compatibility metadata. Its writes are not fully inert because they occupy
real A4..A7 root slots and interact badly with 040 root scanners.

Follow-up: `HAT-GROWSDT-AUDIT.md` proves the false-root overlay and identifies
a more serious alloc/free mismatch: current `hat_sdtalloc` uses 4 KiB physical
shifts, while byte-identical `hat_sdtfree` still derives `page_t` with 2 KiB
geometry. The next producer-level target is `hat_map`.

The resulting operating policy is that retained `hat_exec_orig` remains
diagnostic-only and bypassed unless it is fully ported to the live 040 mapping
tree. The current no-op implements that policy.
