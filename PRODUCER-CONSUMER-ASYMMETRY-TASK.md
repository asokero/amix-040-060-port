# TASK for Codex: census of remaining 4 KiB-producer / 2 KiB-consumer asymmetries

**Status: CENSUS REQUESTED (2026-07-25). No kernel changes by this document.**

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested
name `PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md`. Do not patch the kernel.

---

## Why this is being asked

Two separate issues investigated on 2026-07-25 turned out to be **the identical defect
class**, and neither was found by looking for it — both surfaced as a side effect of
working on something else:

| Issue | Producer (converted to 4 KiB) | Consumer (left at 2 KiB) |
|---|---|---|
| **ISSUE-27** | `segmap_pagecreate` `0xa9722` creates full 4 KiB pages | `rwip`, `rwvp`, `writei`, `spec_write`, `fbzero` all round their zero-fill to 2 KiB |
| **ISSUE-28** | `as_ctl` `0xaeafe` + `segvn_lockop` `0xad2f0` fill and index the mlock bitmap with 4 KiB page indices | `memcntl` `0x4319a` sized that bitmap and `mem_unlock` `0x434b6` walked it with 2 KiB arithmetic |

The Model-B conversion has proceeded function-by-function for months. That is the right
granularity for correctness *within* a function, but it is exactly the wrong granularity
for **contracts between** functions: whenever one side of a shared structure was
converted and the other was not, the result is a silent semantic split that no
individual function's own audit can see.

The two known instances are almost certainly not the only ones. The purpose of this
census is to find the rest **by construction rather than by accident**.

---

## The question

Enumerate every place in `build/unix-040` where two or more functions share a
**page-granular contract**, and one side has been converted to 4 KiB while the other has
not. "Shared page-granular contract" means any of:

- a **bitmap or page array** written by one function and indexed/walked by another
  (the ISSUE-28 shape);
- a **page-list** (`page_t **`) produced by one function and consumed/released by
  another (`as_iolock` / `rwip` / `rwvp`; `VOP_GETPAGE` `pl[]` users generally);
- a **byte offset/length pair** computed by one function against a page boundary and
  consumed by another (the ISSUE-27 tail-zero shape);
- a **flag derived from page geometry** passed as an argument that changes the callee's
  behaviour (`rwip` -> `ufs_bmap(..., alloc_only = pagecreate)` is the live example);
- a **page/click counter** maintained by one function and consumed by another
  (`availrmem`/`availsmem`/`pages_pp_kernel`/`pages_pp_locked`; note `ublock`'s USIZE
  `#4` must match `segu_release` `0xaa78e`, which it currently does);
- a **shift/mask pair** where the producing side rounds and the consuming side masks.

For each candidate, state: the shared object, both sides' current geometry, whether they
agree, and if not, what the observable consequence is (wrong data, wrong accounting,
wrong allocation, or none).

---

## Starting data: the "already converted" set

Extracting every byte-patched address from `prototypes/patch_*.py` and mapping it to its
containing function gives **130 functions** that have been touched by some conversion.
The list is reproducible with:

```sh
# addresses are the first element of each (vaddr, old, new, name) tuple
grep -hoE '\(0x[0-9a-f]{4,6}\s*,\s*b"' prototypes/patch_*.py
```

Caveat: that extraction misses `patch_pagecreate.py`, whose tuples are
`(group, vaddr, old, new, name)`. Add its functions manually: `as_iolock`, `rwip`,
`rwvp`, `fbzero`, `spec_write` (and `segmap_pagecreate`, already in the list).

Second caveat: `textlock`, `datalock` and `ublock` appear in the list only because
`patch_memcntl.py` records them as **canaries** (their `moveq #11` is `return EAGAIN`,
not a shift). They are NOT converted. That is itself a useful warning for this census:
a raw pattern scan over `memcntl` returned 21 hits of which **4 were errno constants**.
Context classification is the work; a list of matching immediates is not an answer.

Also relevant as .s-level overrides rather than byte patches (so they will not appear in
the grep above): `hat040.s`, `hat_dup040.s`, `hat_chgprot040.s`, `hat_pagesync040.s`,
`segkmem040.s`, `bp_map040.s`, `kvm040.s`, `prfastmap040.s`, `vtop040.s`,
`uvatosde040.s`, `segu_ubptbl040.s`, `runtime040.s`.

The interesting frontier is the **boundary** of that set: functions in it that exchange
page-granular data with functions outside it.

---

## Known-unconverted regions, as a starting worklist

These are already documented and can be used as one end of candidate pairs:

| Region | Addresses | Status |
|---|---|---|
| `ufs_bmap` | `0x79d48`; 2 KiB at `0x79d74`, `0x79d7e`, `0x79d96`, `0x79da4`, `0x79daa`, `0x79ec0`, `0x79ee2`, `0x7a030` | excluded by the ISSUE-27 spec; **now consumes a 4 KiB-derived `alloc_only`** — see `PAGECREATE-REPRO-UFSBMAP-TASK.md` |
| S5 `writei` | `0x70cfa` + its geometry group | deferred by the ISSUE-27 spec (AMIX hybrid, S5 unmounted) |
| RFS/DUsys client | `0x8f4f0`–`0xa3900`, 72 raw matches in 27 functions | ISSUE-16, unclassified, RFS unexercisable |
| `mmmmap` / `resmmap` | `0x20688`, `0x2068e` (`+2047`, `moveq #11`) | known `btopr` residual |
| `segvn_lockop` fault lengths | `0xad482`, `0xad536` (`pea 0x800`) | deliberately withdrawn 2026-07-03 after a boot hang; its loop step and bit indices ARE 4 KiB |
| dormant helpers | `pptophys` `0xb1570`, `phystopp` `0xb1532`, `uvirtophys` `0xb7860` | no inbound calls; wrong if ever called |

`vtop`'s dispatch is a solved instance of the same family and is documented in
ISSUE-18: it must stay **address-first, not proc-first**, because `startio` `0xc100`
passes `bp->b_proc` and `dma_pageio` `0x20c90` copies it into a bounce buffer whose
address is SCN0 identity RAM. Any candidate involving `b_proc`, `b_pages` or `b_addr`
should be checked against that constraint rather than "fixed" independently.

---

## What makes a good answer

1. **Ranked by live reachability**, not by site count. ISSUE-28 was 17 sites on a path
   nothing uses; ISSUE-27 is 28 sites on every `write(2)` but with unproven
   observability. Both matter less than a single-site asymmetry on the boot or disk
   path would.
2. **Classified, not matched.** For every candidate, say what the constant *is*, not
   just that it looks like a page size.
3. **Atomic units named.** For each real asymmetry, state which functions must flip in
   the same build, and whether a mixed state is worse than either extreme.
4. **An acceptance test per unit**, or an explicit statement that the asymmetry is not
   observable at runtime. The ISSUE-27 experience is the lesson here: a conversion whose
   defect cannot be demonstrated leaves you unable to prove the fix either, so it is
   worth knowing *before* implementation which units are testable.
5. **Say when there is nothing.** If the boundary is clean apart from the already-known
   items, that is a valuable result and should be stated as such.

---

## Provenance

```text
build/unix-040   68040-260725-09
SHA-256          0bf2c5c075abe26eb5a4a9bfb43d616126792a4d6d09b23e6489c40066f08f07
```

`.text` file offset `+0x34`. Model B: PAGESIZE 4096, PNUMSHFT 12. Root filesystem is
UFS with `fs_bsize` 8192, `fs_fsize` 1024, `fs_frag` 8; s5 and RFS are not mounted;
`MAXBSIZE` and the segmap slot are 8192 (`0x2000`) and are NOT page constants.
