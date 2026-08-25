# Contracts — what the parallel lines have agreed between themselves

`AGENTS.md` says how to work **in** this repository. This file records what has been agreed
**between** the people and assistants working on it in parallel, and it is the canonical
source for those agreements. Where a rule here and a rule elsewhere disagree, this file is
right and the other place is a stale copy that should be reduced to a pointer.

It exists because this project is now developed on more than one machine, by more than one
person, each with their own assistant, working days apart without seeing each other's
branches. Everything below is a defence against that specific situation — not bureaucracy,
but the small number of places where two people following the *same* rule correctly still
produce a collision.

---

## 1. Allocation blocks

Numbers that come from a single shared counter collide when two lines mint from it at once.
Numbers that carry a per-line block never do. This table is the registry, and
`tools/blocks.py` is its only reader.

| git identity | issues | build-id seq |
|---|---|---|
| antti.sokero@gmail.com | 1-99 | 1-49 |
| jussi@alanara.fi | 100-199 | 50-99 |

**Identity comes from `git config user.email`.** It is already on every machine, git already
uses it for authorship, and it survives a fresh clone and a lost session — which is what a
rule needs if nobody is going to be told it. One person may hold several rows (work machine
and home machine); the blocks may be the same on each.

**If your address is not in the table, claim a block before you open your first issue or
build your first image:** take the next free hundred and the next free fifty, add a row, and
carry on. This is self-service on purpose. You do not need anyone's permission — the row
needs to exist so the next person can see the block is taken.

### How to actually take a number

    tools/next-issue.sh          # the next free issue number IN YOUR BLOCK

Do not take one by hand. Scanning `KNOWN-ISSUES.md` for the highest number and adding one is
exactly the reasoning that produced the collision below, and it is the reasoning a fresh
assistant session will arrive at unaided if the easy path does not already give the right
answer.

Build-id sequences need no discipline at all: `src/stamp_buildid.py` performs the same
lookup itself, so an image cannot be stamped outside its block. That is deliberate. A rule
that can be skipped eventually is; a mechanism cannot be.

### Checking

    tools/check-blocks.sh <base>..<tip>

Every `ISSUE-N` introduced in that range must lie inside its author's block. Run it before
merging a branch from another line. A rule with no instrument is a wish, and this one is
cheap: the partition does not merely prevent collisions, it makes violations **visible** —
`ISSUE-53` authored from `jussi@alanara.fi` is wrong at a glance, where `ISSUE-46` against
`ISSUE-46` was indistinguishable.

---

## 2. The collision this is a response to (2026-08-19 → 2026-08-25)

Both lines started work on 2026-08-19, five hours apart. Both read a `KNOWN-ISSUES.md` whose
ledger ended at **45**. Both took the next free number. Both did it four times.

| № | on the `wip/zorro3` line | on the `z3660` line |
|---|---|---|
| 46 | `/dev/mem` mmap lands one page high | `sync()` on the panic path walks the vfs switch through NULL |
| 47 | a user-mode bus error is mishandled | `config()`'s memory sizing is wrong at load base `0x08000000` |
| 48 | `va2_restore_passthrough` fails on Zorro III | the page-frame database is never zeroed |
| 49 | a 2048-aligned device mmap yields the next page | `PANIC: segmap_unlock` at first root-mount I/O |

**Nothing here was careless.** Both lines followed the same rule, correctly, and the rule has
no defence against two people applying it at once. Note also what did *not* collide: 709 new
symbols on one line and 9 on the other, with zero overlap, because symbols already carry a
per-line prefix. The mechanism was never the discipline. It was the namespace.

**Resolution:** the `z3660` line's seven issues moved into its block as 100–106, done by the
other line so as not to interrupt work in progress. The mapping is in
`docs/ISSUE-NUMBERING-COLLISION.md`, which is kept rather than deleted: it is why 100–106 are
topically older than they look.

`wip/zorro3`'s 46–49 did not move. They are cited in a hardware acceptance record
(`docs/REALHW-Z3-VA2000-ACCEPTANCE-260819.md`), and an acceptance record is evidence tied to
one image on one date. Renumbering it retroactively would cost more than it saved — the cost
argument pointed the other way (28 references against 126) and was overruled for that reason.

### A second shared counter, found while fixing the first

`src/stamp_buildid.py`'s own docstring promised that *"any two kernels built the same day are
distinguishable"*. The counter is per **build directory**, and there are now two, so
`68060-260825-03` from one machine and `68060-260825-03` from the other were different
kernels with the same name — and the build id is the identity every acceptance record uses.

That is the same defect as the issue numbers and worse in one respect: it produces no
conflict, no build error, and nothing that would ever draw attention to itself. The partition
in the table above restores the promise.

**The general form, for the next shared counter somebody invents: partition it at birth.**

---

## 3. Requests between lines

The channel below is for asking the other line for something and recording that it was done.
It exists because the numbering question above travelled by chat and through a third party,
which worked once and does not scale.

Append at the bottom. Keep entries short, say who is asking, and mark them done rather than
deleting them — the record of what was agreed is the point.

### Open

*(none)*

### Done

- **2026-08-25 — antti → jussi.** Issue numbers 46–52 on the `z3660` line renumbered to
  100–106 by this side, so work in progress was not interrupted. Rebase onto `main` before
  continuing, and branch new work (LC060) from `main` rather than from `z3660`.
  **Done by the asking side; nothing required from the other beyond the rebase.**
