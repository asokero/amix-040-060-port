# ISSUE NUMBERS 46–49 WERE MINTED TWICE — and how that was resolved

**Resolved 2026-08-25.** This branch's seven issues moved to **100–106**. The other line's
46–49 did not move. If you are reading a `z3660` commit older than that date, or a document
that predates it, its issue numbers in the 46–52 range mean the numbers in the left
column below. (Written without the `ISSUE-` prefix on purpose: a literal token here reads as a
live reference to `tools/check-blocks.sh` and to anyone who greps for one.)

## The mapping

| was, on this branch | is now | one line |
|---|---|---|
| 46 | **100** | `sync()` on the panic path walks the vfs switch through NULL, so any pre-`vfsinit()` panic double-faults and destroys its own message |
| 47 | **101** | `config()`'s memory-sizing fallback assumes load base `0x07000000` and is silently wrong at `0x08000000` |
| 48 | **102** | the page-frame database is mapped-in DRAM and nothing zeroes it — invisible on zero-filled emulator RAM, fatal on a card whose DRAM is dirty |
| 49 | **103** | `PANIC: segmap_unlock` at first root-mount I/O — a symptom record; the defect was in the emulated CPU, not the kernel |
| 50 | **104** | the panic backtrace stopped after one frame: its frame-pointer window was 64 KiB wide and that test was the walk's only terminator |
| 51 | **105** | `xpanic` decided whether to call `sync()` from uninitialised bits |
| 52 | **106** | PID 1 dies at exec with a kernel-shaped user stack pointer — two emulated-CPU defects, an unconsumed write-back slot and an uncleared `mmufixup` slot |

**50, 51 and 52 collided with nothing, and moved anyway.** Leaving them behind would have left
this line straddling two namespaces permanently, and the next collision would have been
resolved by renumbering a second time. Thirty-eight extra references bought the whole line
sitting inside one block.

## What collided

Both lines branched from a `main` whose ledger ended at **ISSUE-45**, started work on
2026-08-19 five hours apart, and both took the next free number — four times.

| № | on `wip/zorro3` (kept these) | on this branch (moved to 100+) |
|---|---|---|
| 46 | `/dev/mem` mmap lands one page high, and the test written to catch this class of bug cannot see it | the panic path destroys its own diagnosis |
| 47 | a user-mode bus error is mishandled — two different ways | `config()`'s memory sizing is wrong at load base `0x08000000` |
| 48 | `va2_restore_passthrough()` does not restore passthrough on Zorro III firmware | `PANIC: page_free` at boot |
| 49 | a 2048-aligned device mmap offset yields the NEXT page — and two bugs were cancelling to keep the test green | `PANIC: segmap_unlock` at first root-mount I/O |

## Why this line moved and the other did not

Not because `main` owned the namespace. That was the first answer and it does not survive
contact with the facts: `main`'s ledger stopped at 45, so **neither** line's 46–49 was in it,
and the rule pointed at an empty space.

The reason is that `wip/zorro3`'s numbers are cited in a **hardware acceptance record**
(`docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md`), and an acceptance record is evidence tied to
one image on one date. Rewriting it retroactively makes the record less trustworthy, which
costs more than it saves. On this branch the numbers were still labels on unmerged work.

The cost argument pointed the **other** way — 28 references against 126 — and was overruled
for that reason. Worth stating plainly, because "cheaper" was the obvious answer and it was
the wrong one.

The renumbering was done by the other line rather than this one, so that work in progress
(LC060) was not interrupted for 126 mechanical edits.

## Why it happened, and what now prevents it

Nothing here was careless. Both lines followed the same rule — take the next free number in
`KNOWN-ISSUES.md` — and the rule has no defence against two people applying it at once. It was
also **never written down**: not in `AGENTS.md`, not at the top of the ledger. It was an
inference, and it was the correct inference from what both readers had in front of them.

What did *not* collide is the instructive part. This branch minted 709 new symbols and the
other minted 9, with **zero** overlap, because symbols already carry a per-line prefix. The
discipline was never the difference between the two outcomes. The namespace was.

So issue numbers now carry the same property: per-machine blocks, registered in
[`../CONTRACTS.md`](../CONTRACTS.md), resolved from `git config user.email`, handed out by
`tools/next-issue.sh` and verified by `tools/check-blocks.sh`. The same partition covers
build-id sequences, where a second and entirely silent collision was found while fixing this
one — `stamp_buildid.py`'s counter is per build *directory*, and there are two.
