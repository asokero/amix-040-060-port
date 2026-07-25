# TASK for Codex: why doesn't the ISSUE-27 probe fire, and is `ufs_bmap` safe?

**Status: FOLLOW-UP REQUESTED (2026-07-25). Follows
`vm-map/PAGECREATE-TAILZERO-{SPEC,CENSUS}.md`, which were implemented in full.
Tracked against ISSUE-27 in `KNOWN-ISSUES.md`.**

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested
name `PAGECREATE-REACHABILITY-AND-UFSBMAP.md`. Two questions, in priority order.
Do not patch the kernel.

---

## What happened

Your spec was implemented exactly as written: `prototypes/patch_pagecreate.py`,
28 sites in your three atomic groups (`live` = `as_iolock` 12 + `rwip` 5 + `rwvp` 5,
`fbzero` 2, `spec_write` 4), with the four producer edits asserted as canaries on every
run. All 32 addresses were re-verified byte-identical against the current image before
patching (your stale-pin warning was correct and harmless). Builds 68040-260725-07/-08
(live only) and -09/-10 (all groups); relocs 0; `.data` 4-aligned.

**Your acceptance test was also implemented exactly as written — and it finds nothing
on the PRE-FIX kernel.**

`test-tools/pgcreatetest.c`:

```text
file with a fully written first 8 KiB UFS block (fs_bsize 8192)
write 100 B at offset 8192    page-aligned, start of a new block  -> pagecreate=1
write  10 B at offset 11192   8192+3000, not page-aligned         -> pagecreate=0
read back; every never-written byte must be zero
pre-fix zero-fill stops at roundup(8292,2048) = 10240
```

Result on pre-fix kernel 68040-260725-06: **0 hits in 64 iterations.**

Two independent strengthenings changed nothing:

1. **Wider window.** Your window `[8292,11192)` is 952 bytes. Adding a third write of
   1 byte at 12287 — still inside the SAME 4 KiB page `[8192,12288)` and not page
   aligned, so it takes no pagecreate and no zero-fill — makes the rest of the page
   file contents and widens the observable window to `[10240,12288)`. Still 0 hits.
2. **Better-targeted poisoning.** The first version dirtied anonymous memory in a
   forked child (slow under emulation, and the wrong page population). Replaced by
   churning 32 marker (`0xC5`) pages through a scratch file that is then unlinked —
   file cache pages, which is what the probe's `page_get` should recycle. Still 0 hits.

The mechanism is not defeated by zeroing elsewhere. Verified from the binary:
**`page_get` (`0xaffa4`) and `page_free` (`0xaf9ea`) contain no `pagezero`/`bzero`/
`kzero` call.** The only `pagezero` callers are `spec_getapage`, `s5getapage`,
`ufs_getapage` (hole filling) and `anon_zero`. So a page recycled into
`segmap_pagecreate` genuinely carries its previous contents.

Consequence, and the reason for this brief: the post-fix "CLEAN" result proves nothing,
because both kernels behave identically on the probe. ISSUE-27 has been re-recorded as
a **proven-by-construction correctness defect of unknown live reachability**, not as an
observed leak. That correction has been made in `KNOWN-ISSUES.md` and `RESUME-HERE.md`.

---

## Question 1 (primary): what masks it, and what probe would expose it?

You already anticipated masking of this general kind — the spec says the 4096/7000
example "can be masked by UFS fragment growth and `fbread`", and offers 8192/11192 as
the stronger test. That stronger test does not fire either. So the masking is either
broader than expected or the exposure needs a different reader.

My leading hypothesis, which I could not confirm without kernel instrumentation:

```text
second write (11192, not page aligned)
  -> pagecreate = 0
  -> rwip -> ufs_bmap(..., size = on+n, S_WRITE, alloc_only = 0)
  -> with alloc_only = 0, ufs_bmap may fbread the block
  -> the read refills the segmap page from disk, overwriting the un-zeroed tail
```

Please confirm or refute that from the binary, and then answer the operative question:

**Is the un-zeroed tail observable at all on this configuration, and by what?**
Candidate exposure routes worth checking explicitly:

- a reader that faults the page in *before* the second write (so no `fbread` refill);
- `mmap` of the file, where `segmap`/`segvn` hand out the page directly;
- `ufs_putpage` writing the FULL page to disk while `i_size` still stops mid-page —
  i.e. is the leak on the *writeback* side rather than the read-back side, which a
  read-through-the-page-cache probe can never see?
- a second process reading the file while the first still holds the page;
- `fs_bsize == PAGESIZE` or `fs_bsize < PAGESIZE` filesystems, which this installation
  does not have but which would change the fragment/`fbread` interaction.

If your conclusion is that the tail is **not** reachable on a `fs_bsize 8192` UFS root,
say so plainly. That is a perfectly good answer and it would downgrade ISSUE-27 from
"data-integrity defect" to "latent correctness defect", which materially changes how
the remaining units (`rwvp`, `spec_write`, S5 `writei`) should be prioritised.

---

## Question 2: is leaving `ufs_bmap` unconverted safe?

The spec deliberately excludes `ufs_bmap`'s own PAGESIZE arithmetic ("separate
provider/allocation audit... must not be converted by matching constants mechanically")
while still requiring the pagecreate decision to move to the 4 KiB contract. That is
defensible, but it creates a **new producer/consumer boundary** — and that is exactly
the defect class that bit twice in one day (ISSUE-27 itself, and ISSUE-28 where
`as_ctl`/`segvn_lockop` filled a bitmap at 4 KiB while `memcntl`/`mem_unlock` sized and
walked it at 2 KiB).

`ufs_bmap` is at `0x00079d48`. Its 2 KiB sites in the current image:

```text
0x79d74  cmpil #2048,%d3          0x79d7e  movel #2048,%d2
0x79d96  cmpil #2047,%d3          0x79da4  addil #2047,%d0
0x79daa  moveq #11,%d7            0x79ec0  moveq #11,%d7
0x79ee2  moveq #11,%d7            0x7a030  moveq #11,%d7
```

Please answer:

1. Which of those are VM-page geometry and which are UFS fragment/block geometry?
   (The ISSUE-28 work is a warning here: a naive scan of `memcntl` returned 21 hits of
   which 4 were `moveq #11/#12` = `return EAGAIN`/`ENOMEM`. Context classification is
   the work.)
2. Now that `rwip` passes a 4 KiB-based `pagecreate` as `ufs_bmap`'s `alloc_only`, does
   any of that internal 2 KiB arithmetic disagree with the caller in a way that can
   misallocate, skip a needed `fbread`, or fail to skip an unneeded one?
3. If a conversion is needed, is it atomic with the `live` group already landed, or can
   it land separately? If the current mixed state is *worse* than either extreme, say
   so — I will revert `live` rather than leave a half-converted allocator.

---

## Provenance

```text
build/unix-040   68040-260725-09  (live + fbzero + spec)
SHA-256          0bf2c5c075abe26eb5a4a9bfb43d616126792a4d6d09b23e6489c40066f08f07
```

The pre-fix image used for the baseline is 68040-260725-06 (kept as
`build/unix-040-dbg.ISSUE28-260725-06`); the live-only image is
`...ISSUE27live-260725-08`; the all-groups image is `...ISSUE27all-260725-10`.
`.text` file offset convention `+0x34` as usual.

What IS verified about the landed change (no-regression only): `proctest` PASS,
`mlocktest` PASS, and disk truth `/big.dat` 2950288 bytes `sum = 8320 5763` identical
across `sync` + soft `reboot` + `fsck -F ufs -m`, on emu-040 AND emu-060, with the
`live` group alone and with all three. Serials clean. Full record:
`test-tools/pagecreate-issue27-emu-verify-260725.txt`.

Not exercised at all: NFS `rwvp` (no NFS mount available) and `spec_write` (no scratch
block-device test). No real hardware.
