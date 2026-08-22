# ⚠ ISSUE NUMBERS 46–49 WERE MINTED TWICE, IN PARALLEL

**Read this before reading any `ISSUE-46`, `ISSUE-47`, `ISSUE-48` or `ISSUE-49` reference on this
branch.** Four numbers mean two different things depending on which line wrote them.

Both lines branched from a `main` whose ledger ended at **ISSUE-45**, worked for two days without
seeing each other, and both took the next free number — four times.

**`KNOWN-ISSUES.md` on `main` owns the namespace.** These numbers are this branch's, not the
project's. **Whatever numbers are assigned there are the real ones, and this side renumbers** —
in the ledger entries, in the source comments, in the relink-script comments, and in the document
filenames that carry them. We are not proposing a scheme; we are asking which numbers to use.

## The collision

| № | on `wip/zorro3` (the ledger's line) | on this branch |
|---|---|---|
| **46** | `/dev/mem` mmap lands one page high, and the test written to catch this class of bug cannot see it | the panic path destroys its own diagnosis — `sync()` walks the vfs switch through a NULL pointer |
| **47** | a user-mode bus error is mishandled — two different ways | `config()`'s memory-sizing fallback is `0x07000000`-shaped and silently wrong at load base `0x08000000` |
| **48** | `va2_restore_passthrough()` does not restore passthrough on Zorro III firmware | `PANIC: page_free` at boot — the page-frame database is mapped-in DRAM and nothing zeroes it |
| **49** | a 2048-aligned device mmap offset yields the NEXT page — and two bugs were cancelling to keep the test green | `PANIC: segmap_unlock` at first root-mount I/O — closed as a symptom record; the defect was in the emulated CPU, not the kernel |

## What this branch minted, in full

Seven numbers, all on real findings, all cross-referenced from source and scripts:

| ours | one line | state |
|---|---|---|
| 46 | `sync()` on the panic path walks the vfs switch through NULL, so any pre-`vfsinit()` panic double-faults and destroys its own message | fixed |
| 47 | `config()`'s memory-sizing fallback assumes load base `0x07000000` and is silently wrong at `0x08000000` | recorded, deliberately not fixed |
| 48 | the page-frame database is mapped-in DRAM and nothing zeroes it — invisible on zero-filled emulator RAM, fatal on a card whose DRAM is dirty | fixed |
| 49 | `PANIC: segmap_unlock` at first root-mount I/O; the kernel needed no change — bitfield writes were not landing because the emulated CPU used the wrong accessors | symptom record |
| 50 | the panic backtrace stopped after one frame: its frame-pointer window was 64 KiB wide and that test was the walk's only terminator | fixed |
| 51 | `xpanic` decided whether to call `sync()` from uninitialised bits | fixed |
| 52 | PID 1 dies at exec with a kernel-shaped user stack pointer — resolved to two emulated-CPU defects, an unconsumed write-back slot and an uncleared `mmufixup` slot | resolved |

**50, 51 and 52 do not collide** with anything currently on `wip/zorro3`. They are still this
branch's numbers rather than the project's, and they move too if the ledger says so.

## Why it happened, so it does not happen again

Nothing here was careless: both lines followed the same rule — take the next free number in
`KNOWN-ISSUES.md` — and the rule has no defence against two people applying it at once. The
cheapest fix is a claim before the work rather than a merge after it: whoever is about to open an
issue takes the number in the ledger on `main` first, even if the entry is a placeholder line.
That is a decision for the ledger's owner, and this document is not it.

## Also worth knowing when reading across the two lines

`docs/ACCEPTANCE.md` §8 cites `ISSUE-47` for the undecoded aperture gap that kills a process. On
`wip/zorro3` that entry's title reads "a user-mode bus error is mishandled — two different ways";
on this branch `ISSUE-47` is a memory-sizing fallback and nothing to do with apertures. The
citation in `ACCEPTANCE.md` is correct for the ledger's line — it simply cannot be read from this
branch without this table.
