# TASK for Codex: exec boundary census and conversion spec

**Status: ✅ ANSWERED AND IMPLEMENTED (2026-07-25) → `vm-map/EXEC-BOUNDARY-CENSUS.md`.**
Implemented as ISSUE-32, `src/patch_execboundary.py` (21 sites in 3 atomic groups
+ 5 canaries), builds 68040-260725-15/-16.
**One correction to the census:** it lists only the CONSUMER of `*execsz`
(`elfexec` 0xb8440) and marks it "convert or prove byte-unit exception". Discharging that
proof showed the PRODUCER is also still 2 KiB — `mapelfexec` @0xb85f0, a LOCAL symbol
that fell outside the raw candidate scan in this brief. Both sides had to flip together;
converting only the consumer would have made the exec size limit twice as strict.
Deferred as the census recommends: `coffcore` (9 sites), the COFF-side `*execsz`
producers in `getcoffhead`, and `grow`/`brk`.

Requested deliverable: an analysis note in `amix-kernel-analysis/vm-map/`, suggested
name `EXEC-BOUNDARY-CENSUS.md`. Do not patch the kernel.

---

## Why this one, and why a census before any patch

`PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md` ranks the exec boundary P1 and says it is
"more important than its raw site count because every normal `exec` exercises some part
of this boundary". That is exactly why I am not touching it without a census: it is the
highest-reachability item left, it runs on every process creation, and a wrong immediate
here breaks the machine on the next boot rather than in some rare corner.

The three producer/consumer defects found so far were all the same shape — one side of a
shared page-granular contract converted, the other not — and in two of them my own
address list was wrong in a way that would have caused damage:

- ISSUE-28: a raw scan of `memcntl` returned 21 hits of which **4 were errno constants**
  (`moveq #11/#12` = `return EAGAIN`/`ENOMEM`).
- ISSUE-31: my task brief listed three `moveq #11` sites in `ufs_bmap` as conversion
  candidates. Your census showed they are **`NDADDR-1` direct-block thresholds**;
  converting them would have moved the UFS direct-block boundary and corrupted the
  allocator. It also found six real sites I had missed.

So the deliverable I need is a **classification**, not a list of matching immediates.
The raw scan below is supplied only as a candidate generator and should be treated as
untrusted.

## What is already done, and what that closes

Converted and verified (`patch_execstk.py`, `patch_modelb.py`):

```text
exec_initialstk  .data initializer 0x800 -> 0x1000
extractarg       shared shift feeding btoc/ctob and the 64-page group
execmap          (partially -- it appears in patch_modelb.py)
elfexec          (partially -- it appears in patch_modelb.py)
execstk_addr     (appears in patch_modelb.py)
```

Acceptance for the initial-stack part was `test-tools/bigargv.c`: 4500 bytes of argv
byte-exact across `exec`, three times. That closes the initial-stack producer and
nothing else. Your census agrees: "That does not close the entire exec contract."

## The question

For the exec path, enumerate every place where a page-granular value produced by one
function is consumed by another with a different page unit, and classify each. The
specific contracts I care about, in the census's own terms:

| Producer | Consumer | What to determine |
|---|---|---|
| exec header / file-size rounding | `execmap` -> `as_map` segment size | is the mapping end computed with the same unit `as_map`/`segvn` use? |
| `execmap` range | `segvn_create` / `segvn_fault` | does last-page coverage differ between the 2 KiB-derived range and the 4 KiB anon/vpage domain? |
| ELF/COFF page counts | limits and accounting | are `btoc`/byte policies mixed, and does that change an enforced limit or only a reported number? |
| `exhd_getfbuf` / `exhd_nomap` | segmap/fbuf and the page cache | these are the `fbread`-family helpers for header reads; `fbzero` in the same family was already found to be a live 2 KiB tail-zero defect (ISSUE-27 group) |
| `grow` | stack segment extension -> `as_map`/`segvn` | stack growth is page-granular and runs on every deep call chain, not only at exec |
| `setregs` / `copyarglist` | initial stack layout | already partly fixed via `extractarg`; is the rest consistent? |

Please also answer explicitly:

1. **Which parts are dead on this configuration?** `elfexec` is the live format on this
   installation; `coffexec`/`coffcore`/`elf_coffshlib` may be unreachable. If COFF is
   dead, say so and put it in a separate deferred unit rather than in the live one —
   the same treatment S5 `writei` and RFS got.
2. **Is `coffcore`/`elfcore` core-dump geometry a data-integrity concern or only a
   malformed-corefile concern?** Nine of the raw candidates are in `coffcore`, which
   would dominate a naive site count while possibly mattering least.
3. **What is the minimal atomic unit?** The census suggests "the executable format path
   being enabled, starting with ELF, including header read, map range, initial stack,
   and accounting". I need that as a concrete list of functions that must flip in the
   same build, plus a statement of whether a mixed state is worse than either extreme.
4. **Is `grow` in or out?** It appears in `patch_modelb.py` already but stack extension
   is arguably a different contract from exec; if it is a separate unit, say so.

## Acceptance test design

The census proposes: "repeated `exec` of binaries whose last text/data page ends at
offsets 1, 2047, 2048, 4095, and 4096, plus process map/protection checks."

I can build that, but please sharpen two things, because this session has produced three
probes that could not see a real defect:

- **What is the observable?** For ISSUE-27 the winning signal turned out to be "the
  ORIGINAL data is gone", which is provenance-independent. For exec, is the analogous
  observable a wrong `/proc` map extent, a byte difference in the last text/data page, a
  SIGSEGV one page early or late, or an accounting number? A test that only checks "the
  binary still runs" will pass on a broken kernel.
- **Does anything mask it?** Three probes failed this session because UFS holes are
  zero-filled, because `segmap_pagecreate` reuses resident pages, and because a
  same-process read never leaves the page cache. If exec has an analogous masking
  mechanism — for example the last page always being zero-filled by the provider — the
  test has to defeat it deliberately.

`test-tools/proctest.c` already reads and writes another process's memory through
`/proc`, so process map inspection is available and known to work on both CPUs.

## Raw candidate scan — UNTRUSTED, classification is the deliverable

Pattern `#2047 / #2048 / #-2048 / moveq #11` over the exec-path functions of the pinned
image. 28 hits. On past form, roughly a fifth of these will not be page geometry:

```text
exhd_getfbuf   3   0x56786 0x567b4 0x567bc
exhd_nomap     8   0x569d6 0x569e2 0x569ea 0x56e26 0x56e42 0x56e48 0x56f64 0x56f6a
execmap        6   0x57a68 0x57a72 0x57a9a 0x57ac0 0x57b24 0x57b2a
coffcore       9   0xb7f96 0xb7f9c 0xb7fb0 0xb7fc0 0xb8040 0xb8046 0xb8062 0xb8068 0xb8088
elfexec        2   0xb8440 0xb8446
```

Functions with no hits from this pattern but which are part of the contract and should
still be examined: `exece` `0x56444`, `exec` `0x5674a`, `exhd_getmap` `0x5704e`,
`exhd_release` `0x573b0`, `execpermissions` `0x57426`, `execsetid` `0x575ae`,
`execopen` `0x57f44`, `execclose` `0x58052`, `grow` `0x5820e`, `extractarg` `0x58734`,
`setregs` `0x58b62`, `as_exec` `0xaed8a`, `execstk_addr` `0xaf2b8`, `coffexec` `0xb78dc`,
`elfexec` `0xb80f2`, `elf_coffshlib` `0xb8758`, `elfnote` `0xb884e`, `elfcore` `0xb8910`,
`hat_exec` `0xd87f0` (a 040 override), `copyarglist` `0x7d8`.

Note `hat_exec` is deliberately a NO-OP 040 override (the stock exec stack page-table
move was unsafe on 040, ISSUE-10 chain II) — please confirm that does not interact with
whatever `execmap`/`as_exec` conversion you recommend.

## Provenance

```text
build/unix-040   68040-260725-13
SHA-256          735353d215e6679e71233c480edbabd265ff4a8fa6d9e7a2fc5226cd81c62d1d
```

`.text` file offset `+0x34`. Model B: PAGESIZE 4096, PNUMSHFT 12. Root filesystem UFS,
`fs_bsize` 8192, `fs_fsize` 1024, `fs_frag` 8. `MAXBSIZE` and the segmap slot are 8192
(`0x2000`) and are NOT page constants.

Landed since the census was written, in case it affects the analysis:
ISSUE-27 (`patch_pagecreate.py`, 28 sites — as_iolock/rwip/rwvp/fbzero/spec_write),
ISSUE-30 (`patch_pvntrunc.py`, 2 sites), ISSUE-31 (`patch_ufsbmap.py`, 11 sites +
3 NDADDR canaries). ISSUE-27 is now PROVEN: a page-aligned write whose length is a
multiple of 2048 but not 4096, into an already-allocated cold file, was deterministically
overwriting valid file data (24/24, marker-verified); fixed on both CPUs.

Two corrections to the census's own P2 section, verified against the pinned image:
`kmem_avail` @0x42d7a is **already** `moveq #12` (fixed in ISSUE-15 the same day), and
the `vmmeter`/`maxpgio` `MAXBSIZE/2048` fold was already handled by
`patch_pageoutdefs.py`. Those two P2 entries appear to be stale.
