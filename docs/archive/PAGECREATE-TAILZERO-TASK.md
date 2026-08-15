# TASK for Codex: `segmap_pagecreate` family — Model-B tail-zero / `as_iolock` contract

**Status: ✅ ANSWERED AND IMPLEMENTED (2026-07-25). Tracked as ISSUE-27.**
Codex delivered `vm-map/PAGECREATE-TAILZERO-{CENSUS,SPEC}.md`; implemented as
`src/patch_pagecreate.py` (28 sites, 3 atomic groups, 4 producer canaries),
builds 68040-260725-09/-10.

⚠️ **ONE SEVERITY CLAIM BELOW IS WRONG AND IS LEFT ONLY AS THE RECORD OF WHAT I THOUGHT
AT THE TIME.** This brief calls ISSUE-27 a "silent data leak / stale-data exposure".
It is worse than that: the defect **OVERWRITES VALID EXISTING FILE DATA** with the
contents of a recycled page. Trigger: a page-aligned write whose length is a multiple of
2048 but NOT of 4096, entirely inside an already-allocated file whose pages are cold —
`as_iolock`'s `n &= PAGEMASK` is the guard against a PARTIAL pagecreate, and at 2 KiB it
does not fire. Proven 24/24 vs 0/24, marker-verified.
The proof, and the three probe designs that could NOT see it, are in
`test-tools/pagecreate-issue27-COLD-PROOF-260725.txt`. Follow-up brief:
`docs/archive/PAGECREATE-REPRO-UFSBMAP-TASK.md`.**

Requested deliverable: a census + conversion spec in the analysis repo
(`amix-kernel-analysis/vm-map/`), suggested name
`PAGECREATE-TAILZERO-CENSUS.md` (+ `PAGECREATE-TAILZERO-SPEC.md` if you prefer the
census/spec split used by `DTT0-*` and `B2-*`). Implementation will follow in
`amix-040-060-port` from your spec; do not patch the kernel yourself.

---

## Why this is being escalated now

While diffing ISSUE-15/16/17/18 against the binary (2026-07-24/25 session) a
**previously unlisted, live, silent data-integrity defect** surfaced on the UFS
root-filesystem `write(2)` path. It is not in KNOWN-ISSUES. It has the exact
signature that ISSUE-10 was hunted by ("file/disk-block-shaped garbage appearing in
memory or files at sub-page granularity"), and it is *adjacent* to two residuals you
have already audited separately but never as one unit:

- `NFS-FOREGROUND-WRITE-RWVP-AUDIT.md` — `rwvp` pagecreate tail-zeroing still 2 KiB.
- `MODEL-B-TEXT-RESIDUAL-CENSUS.md:63` — `fbzero` pagecreate zeroing still 2 KiB
  ("**Definite active UFS helper defect**").
- `MODEL-B-TEXT-RESIDUAL-CENSUS.md:83` — `prfastmapin/out`, `prusrio`, `as_iolock`
  grouped as a "known atomic soft-lock group", deferral retained.

What was missing is that **UFS's own `rwip` has the same defect**, that
`as_iolock` *feeds* it the `pagecreate` decision, and that `segmap_pagecreate` itself
was **already converted to 4 KiB** in 2026-07 (`patch_modelb_pager.py:195-197`,
`patch_modelb.py:557`). The producer is 4 KiB while every consumer's zero-fill bound
is still 2 KiB. That asymmetry is the defect.

### The mechanism (my reading — please confirm or refute)

```
user write(2), uio_offset 2048-aligned, partial page, at/after EOF
  -> as_iolock  (0xaee34, ALL 2 KiB)        -> *pagecreate_p = 1
  -> segmap_pagecreate (0xa9722, ALREADY 4 KiB) creates a FULL 4 KiB page,
     deliberately uninitialised
  -> uiomove writes only the requested bytes
  -> caller tail-zero rounds to roundup(off+on+n, PAGESIZE) with PAGESIZE = 2048
  => bytes in [roundup(end,2048), roundup(end,4096)) of a freshly created page are
     NEVER zeroed = residual contents of whatever physical page was recycled
  => once i_size grows past them (a later non-page-aligned write into the same cached
     page takes pagecreate = 0 and does not re-zero), they become file content and are
     flushed to disk.
```

Worked example I derived from `usl-svr42/common/uts/fs/s5fs/s5rdwri.c` (the closest
available analogue — see "Open question 1"):

```
write 100 B at offset 4096 to a 4096-byte file
  off = uio_offset & MAXBMASK = 0 ;  on = 4096 ;  n = 100
  as_iolock: offset & 2047 == 0 -> not rejected; offset+n >= i_size -> no PAGEMASK trim
             sz == n == 100 -> pagecreate = 1
  segmap_pagecreate creates page covering file offsets 4096..8191, uninitialised
  rwip tail-zero: roundup(0 + 4096 + 100, 2048) = 6144
                  zeroes 4196..6143   (1948 bytes)
  page bytes 6144..8191  = STALE
then lseek(7000); write(10)
  7000 & 2047 != 0 -> pagecreate = 0 -> no zero-fill, page already cached
  i_size becomes 7010 -> stale bytes 6144..7000 are now file content
```

Under a correct 4 KiB port the first tail-zero would have covered 4196..8191 and the
exposure would not exist.

**This is a data-disclosure/corruption path on the root filesystem.** I rate it above
the remaining ISSUE-16/17/18 tail in value, which is why it is being specced rather
than patched opportunistically.

---

## Why I am asking you rather than just converting it

Four reasons, in order of weight:

1. **`rwip`/`rwvp`/`writei`/`spec_write`/`fbzero` are binary-only in this tree.** I
   reasoned from `usl-svr42/common/uts/fs/s5fs/s5rdwri.c`, which is a *different
   filesystem* and a *different SVR4 revision* from AMIX's UFS. Your
   relocation-aware Ghidra pipeline can prove body provenance; I cannot. Porting a
   zero-fill bound from an analogous-but-not-identical source is precisely how a
   latent bug gets planted.

2. **This exact class of partial conversion already hung the kernel.**
   `src/patch_modelb.py:583-591` records the 2026-07-03 revert:

   > "REVERTED 2026-07-03 EVE (boot-5 hang suspect): the as_iolock and prusrio pea-len
   > flips are WITHDRAWN. Both functions' INTERNALS are still 2KB … flipping only their
   > lock/fault LENGTHS made lock-len 4KB vs step 2KB = OVERLAPPING SOFTLOCKS = p_lck
   > imbalance = hang risk. The partial-conversion hazard, self-inflicted."

   The site lists are now complete, so that specific trap is avoidable — but the
   underlying question is a *lock-ownership contract*, which is what your audits are
   for. I want the contract stated before anyone writes a patch script.

3. **`pl[]` array dimensioning must be proven in the AMIX frames, not inferred.** I
   inferred `page_t *iolpl[MAXBSIZE/PAGESIZE + 2]` = 6 entries from the usl source
   (MAXBSIZE 8192 confirmed = segmap slot 0x2000 = UFS `fs_bsize`). Converting
   `as_iolock`'s step 2048→4096 should *halve* the entries written (≤2 + NULL), i.e.
   strictly safer — but that must be read out of each caller's actual stack frame.

4. **The group needs a runtime acceptance test that demonstrates the defect**, not just
   a boot. Without a before/after byte-level demonstration no correctness claim is
   honest.

---

## Binary provenance for this request

```
kernel   build/unix-040
SHA-256  5bd37386d9c5a0f89be451b187fa5dfe9e4f05bcf2f1c37accdc22177a225b38
```

ELF text offsets as used by `nm` / project docs (add `0x10000` for Ghidra text).
Root fs measured: **UFS, `fs_bsize` 8192, `fs_fsize` 1024, `fs_frag` 8**; s5 is not
mounted anywhere (KNOWN-ISSUES "ROOT-FS GEOMETRY"). PAGESIZE 4096, PNUMSHFT 12.

### Producer — already 4 KiB (do not re-touch, but the asymmetry starts here)

| Function | Addr | State |
|---|---:|---|
| `segmap_pagecreate` | `0x000a9722` | **converted**: `0xa9742` `&-4096`, `0xa9892`/`0xa9898` `+4096`, `0xa97a0` `page_get` size `0x1000` |

### `as_iolock` — complete 2 KiB set, all 12 sites verified present in the current binary

`as_iolock` `0x000aee34`. Matches the enumeration left in
`src/patch_modelb.py:588-591` exactly:

| Addr | Instruction | Role (per usl `vm_as.c:1081`) |
|---:|---|---|
| `0xaee6a` | `andil #2047,%d0` | `uio_offset & PAGEOFFSET` early-reject |
| `0xaeeba` | `andiw #-2048,%d6` | `n &= PAGEMASK` (below-EOF trim) |
| `0xaeece` | `andiw #-2048,%d2` | `raddr = addr & PAGEMASK` |
| `0xaeed6` | `andil #2047,%d0` | `addr & PAGEOFFSET` for `cpsz` |
| `0xaeedc` | `movel #2048,%d3` | `cpsz = PAGESIZE - (addr & PAGEOFFSET)` |
| `0xaef02` | `addil #2048,%d0` | `raddr + PAGESIZE > eaddr` test |
| `0xaef10` | `addil #-2048,%d0` | `cpsz -= raddr + PAGESIZE - eaddr` |
| `0xaefdc` | `pea 0x800` | `VOP_GETPAGE` arg (plsz) |
| `0xaefe4` | `pea 0x800` | `VOP_GETPAGE` arg (len) |
| `0xaf000` | `movel #2048,%d3` | loop `cpsz = PAGESIZE` |
| `0xaf006` | `addil #2048,%d2` | loop `raddr += PAGESIZE` |
| `0xaf01c` | `andil #2047,%d0` | `*pagecreate_p = ((sz & PAGEOFFSET) == 0 || …)` |

No `as_iounlock` symbol exists in this link — the release is the callers' inline
`for (ppp = pl; *ppp; ppp++) PAGE_RELE(*ppp)` loops. Please confirm and enumerate
those loops (including error paths).

### Consumers — all five `segmap_pagecreate` callers, all still 2 KiB

| Caller | Call site | Subsystem | Uses `as_iolock`? | 2 KiB tail-zero sites found |
|---|---:|---|---|---|
| `fbzero` | `0x3fa8a` | UFS helper | no | `0x3fa90` `+2047`, `0x3fa96` `&-2048` |
| `spec_write` | `0x665f2` | specfs | no | `0x6666c` `+2047`, `0x66672` `&-2048`, `0x66688` `+2047`, `0x6668e` `&-2048` |
| `writei` | `0x70cfa` | s5 (**not mounted**) | no | `0x70bd6`/`0x70bee`/`0x70bfa`/`0x70c24`/`0x70c84`/`0x70c90` `&2047`, `0x70c5c`/`0x70cc8` `moveq #11`, `0x70c70`/`0x70cdc` `+2048`, `0x70df4`/`0x70dfa`/`0x70e10`/`0x70e16` round/mask |
| **`rwip`** | `0x7f8ac` | **UFS — LIVE root fs** | **yes** (`0x7f6b2`) | `0x7f9b6` `+2047`, `0x7f9bc` `&-2048`, `0x7f9d6` `+2047`, `0x7f9e0` `+2047`, `0x7f9e6` `&-2048` |
| `rwvp` | `0x88f28` | NFS | **yes** (`0x88edc`) | `0x88fba` `+2047`, `0x88fc0` `&-2048`, `0x88fd4` `+2047`, `0x88fde` `+2047`, `0x88fe4` `&-2048` |

`rwip`'s tail-zero block reads (0x7f9a2 onward): `tstl %fp@(-28)` = the `pagecreate`
out-param `as_iolock` was given at `0x7f69c` (`pea %fp@(-28)`) → so the gate and the
bound are the same unit. `as_iolock`'s `pl[]` is `%fp@(-24)` in `rwip`.

`rwip`'s MAXBSIZE geometry (`0x7f5d6` `&-8192`, `0x7f5e2` `&8191`, `0x7fb5c`/`0x7fbba`
`cmpil #8192`) is **correct** and must not be touched.

---

## What I need from you

### 1. Provenance (blocking)
For each of `as_iolock`, `rwip`, `rwvp`, `writei`, `spec_write`, `fbzero`: which
available source is byte/structurally equivalent to the AMIX body
(`svr4-src-3b2`, `usl-svr42`, `svr4-v4`, `amix-src`), and where they diverge. I used
`usl-svr42/common/uts/mem/vm_as.c:1081` and `.../fs/s5fs/s5rdwri.c:150-290` as
analogues; say plainly if that is the wrong reference for AMIX's UFS.

### 2. Complete site enumeration as ONE set
Every site in the family, with **old bytes**, classified as: *page geometry (convert)*
/ *fs-block or sector geometry (do not convert)* / *deliberately deferred*. Specifically
call out constants that merely *look* like page math: `MAXBSIZE` 8192/`0xe000`/`0x1fff`,
`>>9`/`0x200` sectors, `vfs_bshift`/`fs_fsize` 1024 fragments, segmap slot `0x2000`.
Include the `part_write` ENOSPC branch, which recomputes
`pagecreate = ((n & PAGEOFFSET) == 0 || uio_offset + n >= osize)` — I have not located
its address and it must not be missed.

### 3. The lock-ownership contract (the reason for this brief)
- What exactly diverged in the 2026-07-03 hang: is `segmap_pagecreate`'s `softlock`
  argument 0 in all five callers (i.e. no softlock accounting here at all), and if so
  where did the `p_lck` imbalance actually come from — `as_iolock`'s `VOP_GETPAGE`
  `PAGE_HOLD`s, or `prusrio`'s `as_fault(F_SOFTLOCK)`?
- Is every `pl[]` `PAGE_HOLD` released on **every** exit path, including
  `as_iolock`'s own `err:` label and the caller's `bmapalloc` ENOSPC partial-write
  branch? A conversion that changes the entry count must not change the release count.
- Prove `pl[]` cannot overflow after conversion, from each caller's actual frame.

### 4. UFS interaction with `pagecheate` as an input
`bmapalloc(ip, firstlbn, lastlbn, pagecreate, &dblist[0])` takes `pagecreate` as an
argument, so changing when it is set changes **block allocation** behaviour, not just
zeroing. With `fs_bsize 8192 > PAGESIZE 4096` I expect the `bsize < PAGESIZE`
hole-marking branch to be dead — please confirm from the binary rather than the source.

### 5. Minimal atomic unit + ordering
State what must flip in the **same build**. My hypothesis, to be confirmed or
corrected: `as_iolock` + `rwip` + `rwvp` form one atomic unit (shared `pagecreate`
contract), while `fbzero`, `spec_write` and `writei` are independent and can each land
separately. If any mixed state is *worse* than fully-unconverted, say so explicitly —
that determines whether this is one commit or four.

### 6. Acceptance criteria that demonstrate the defect
A runtime test that shows the stale tail **before** and zeros **after**, plus the
regression list. My starting proposal, please harden it:
- `write(100 B @ 4096)` then `write(10 B @ 7000)` on a fresh UFS file, then read back
  and dump `[4196, 7010)`: expect non-zero garbage pre-fix, zeros post-fix.
- Since the exposed bytes are recycled page contents, pre-dirty the page pool with a
  recognisable pattern first so "garbage" is *identifiable* rather than incidentally
  zero (a fresh boot's free pages may already be zero and hide the defect).
- Disk truth across a power-cut/`fsck` cycle, per the `b1-dcwt` / writeback precedent.
- 040 **and** 060 (one dual-CPU binary — both must regress clean).

### 7. Scope boundary
Please state explicitly whether `prusrio`/`prfastmapin`/`prfastmapout` (ISSUE-17/18)
must be in this unit. I am implementing those **now**, separately, in this session as:
`prfastmapin` → full 040 per-proc walker override (its 030 SDE walk reads our
`root040` table as 8-byte SDEs — `as@(20)` is the 040 root VA per `hat040.s:1211`);
`prfastmapout` → 11 × `moveq #11`→`#12`; `prusrio` → the complete 4-site set
(`0x64580`, `0x64586`, `0x645d8`, `0x6467a`); `vtop040` → user-VA branch routed to the
same walker. **`vtop` dispatch must stay address-first, not proc-first** — `startio`
`0xc100` passes `bp->b_proc` with a kernel bounce address, so a proc-first dispatch
would break disk DMA. If you believe that group and this one cannot be separated, say
so and I will hold the ISSUE-17/18 landing until your spec arrives.

---

## Adjacent findings from the same diff (for your census, not necessarily this spec)

Recording these so they are not lost; they are being handled separately:

- **`kmem_avail` `0x42d68`** — `(availrmem - tune.t_minarmem) << 11` at `0x42d7a`
  (`moveq #11,%d2`). Reports **half** the true available bytes to STREAMS `bufcall`
  back-pressure. This is an ISSUE-15-family site that
  `STREAMS-MBLK-LIFETIME-AUDIT.md`'s KMA table does not list (it covers
  `kmem_allocspool`/`allocbpool`/`alloc`/`free`/`freepool` only). Being fixed in this
  session with the rest of ISSUE-15.
- **`memcntl` / `lock_mem` / `mem_unlock`, `0x4319a`–`0x434b6`** — unconverted 2 KiB
  page rounding (`0x4331c`, `0x43328`, `0x4332e`, `0x43348`, `0x43352`, `0x43358`,
  `0x4338e`, `0x43394`). `memcntl(2)`/`plock(2)` page locking. Not on the boot path;
  proposed as a new ISSUE-28, unowned.
- **`mmmmap` `0x2067e`** — calls `vtop(addr, 0)` then `addil #2047` / `moveq #11`
  (`0x20688`/`0x2068e`). Consistent with the already-recorded `mmmmap`/`resmmap`
  `btopr` residual from the device-mmap work.
- **ISSUE-16 (RFS) is ~40 sites, not 5.** `BIO-PFN-PHYS-KVA-CENSUS.md` lists the 5 PFN
  conversions; the `rfc_*`/`rfcl_*` range `0xa0ab4`–`0xa3874` contains 40 matches for
  `#2047`/`#2048`/`#-2048`/`moveq #11`. Being re-documented in KNOWN-ISSUES with the
  true count; no blind conversion of an unexercisable path.
