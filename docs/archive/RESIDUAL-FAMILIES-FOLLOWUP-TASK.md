# TASK for Codex: three proof obligations from the six-family residual closure

Requested deliverable: analysis notes in `amix-kernel-analysis/vm-map/`. Do not patch the
kernel. Three questions, in priority order — Q1 is the one that changes what we do next.

**Your pin was verified exactly on our side before this brief was written:**

```text
kernel HEAD      272153158cc88d4413159743fbb227c109df4984      MATCH
build/unix-040   767ea9a0b904752701f3d49d8df9bba55fe46bbadbc70da95c8001b0e22540fb   MATCH
.text            9b49c77a59d3b77effab6c1847a0f6633200f7ce0f0600d3f696e6ce41ac4111   MATCH
buildid          68040-260726-01
```

All three hashes match byte for byte, so we are reasoning about the same image. That is worth
stating because it is rare and it means none of what follows needs re-derivation.

The six-family closure is good work and two of its findings are the kind that only come from
classification rather than matching: the `ufs_allocmap` round-up target being `+0x0fff` and not
`+0x1000` (the free side and the intended semantics use `PAGEOFFSET`, the source text uses
`PAGESIZE`), and the S5 structural blocker — `page_t` carries `p_dblist[4]` and `S5MAXREQ`
arrays are four entries, so a 4 KiB page cannot describe a 512-byte-block S5 filesystem at all
and constants alone can never fix it. Also valuable: the five retained false positives
(`IINACTIVE`, `STYP_LIB`, 26× `IMODTIME`, `VSUID`, 2× `NBPS`), each of which a mechanical
constant sweep would have converted.

Please also commit the analysis-repo changes — the report says they are still uncommitted, and
these six documents are the cartography we will be implementing from.

---

## Q1 (primary): segdev — what is the concrete failure scenario?

`SEGDEV-4K-REPRESENTATION-SPEC.md` explicitly revises the earlier "retained paired-2K
compatibility domain" verdict and states the current mix is not self-contained: PFN producers,
`segdev_incore` and the live HAT are 4 KiB while vpage allocation, fault, split, protection and
free remain 2 KiB.

**That contradicts a conclusion recorded on our side**, so it needs settling rather than
asserting. After ISSUE-33 landed (2026-07-26, `patch_devmmap2.py`: `mmmmap`/`resmmap` PFN plus
`segdev_incore`'s vector stride, with three sibling sites asserted UNCHANGED on purpose) we
recorded that the remainder of the segdev family was internally consistent and that
`hat_devload`'s duplicate loads are idempotent — which is also the explanation we accepted for
why the earlier `scrmmap` fix worked against an unconverted segdev.

The evidence against a live defect: `test-tools/devmaptest.c` PASSES on 68040-260726-02 and
on 260727-02, including T2, which walks `mincore` over a **4-page device mapping** and checks
that exactly 4 entries are written and that canary bytes beyond them are untouched — i.e. the
vpage/incore boundary you describe as split is directly exercised and comes out clean.

So: **name a concrete failure scenario.** Specifically —

1. Which entry point, with which arguments and which mapping length, produces an observable
   wrong result today? A `mmap` length that is a multiple of 2048 but not 4096 is the obvious
   candidate given the ISSUE-27 precedent; is that it, or is the split invisible unless
   `mprotect`/`munmap` splits an existing segdev mapping?
2. What is the observable — a wrong `mincore` vector, a protection applied to the wrong extent,
   a leaked or double-freed vpage, or only an accounting number?
3. If the answer is that it is **latent** — structurally wrong but not reachable through any
   current entry point — say that plainly. That is a perfectly good answer and it changes the
   priority from "convert now" to "convert when the public ABI moves", which matters because…
4. …the spec makes segdev depend on landing "the public mmap/munmap/mprotect 4 KiB ABI" first.
   Please state explicitly **what user-visible behaviour changes** when that lands. If existing
   AMIX binaries can observe a different granularity from `mincore`, `mprotect` extents or
   `munmap` partial-unmap semantics, that is an ABI change rather than a bug fix and it needs a
   separate decision, not a place in an implementation queue. Which of the five public sites
   are observable from user space and which are internal?

## Q2: is COFF actually reachable, or only its magic compare?

`COFF-EXEC-CORE-RESIDUAL-CLOSURE.md` says COFF is reachable because `execsw` contains the MC68
COFF entry (magic 0x0150) and because ELF `PT_SHLIB` compatibility can also reach
`getcoffhead`.

We verified the first half: `execsw @0xac10` begins `coffmagic` / `coffexec` / `coffcore`,
**ahead of** the ELF entry, so the COFF admission path is consulted on every `exec`. But
`coffmagic` is a magic-number comparison and carries no page geometry. `coffexec` and
`coffcore` need an actual COFF object, and we found **zero** COFF binaries among the first 400
files of the vanilla `/usr/bin` + `/bin`.

So the operative question is narrower than the document states:

1. Can `coffexec`'s or `coffcore`'s **page-geometry sites** be reached on an installation with
   no COFF executables? Please answer per site group (your four exec/admission sites vs the
   nine `coffcore` layout/limit sites).
2. **The `PT_SHLIB` route is the interesting claim and needs its own proof.** Show the call
   chain from `elfexec` to `getcoffhead`, and state what an ELF binary must contain to take it.
   If a normal ELF binary produced by the AMIX toolchain can reach it, COFF stops being
   deferred and becomes live — that flips its priority entirely.
3. `coffcore` runs when a process dumps core. Which core routine is selected — by the process's
   exec format, or by something else? If an ELF process always gets `elfcore`, the nine
   `coffcore` sites are unreachable without a COFF process and should be labelled as such.

## Q3: NFS acceptance test — and note that NFS IS testable here

`NFS-PROVIDER-RESIDUAL-CLOSURE.md` reports 21 of 21 candidates genuine, split
setattr/truncation 2 / getpage-getapage 13 / putpage 6, all four bodies byte-identical to the
mounted AMIX NFS `exp`, no structural blocker, three reviewable commits but acceptance requires
all three.

**Correction to an assumption we recorded, in your favour:** an earlier note of ours said "no
NFS mount available". That was about the emulator. On the real machine NFS is mounted routinely
(`mount -F nfs nasu:Public /mnt/nasu`) and it is where ISSUE-13 was found and fixed — the
NFS→local copy path panicked via stock `bp_map` walking the retired `st_top1` tree, and the
`bp_map040` fix was accepted there with **five consecutive 3 MB copies byte-perfect, `sum`
11920 6060 identical NFS↔local**.

So NFS is the one remaining family that is both live and hardware-testable today, which makes
it the best first implementation target rather than the fourth. What we need from you:

1. **An acceptance test that discriminates**, in the ISSUE-27 sense. "The copy still works"
   would pass on a broken kernel; ISSUE-27 needed the signal to be "the ORIGINAL data is gone"
   before it could be seen at all, and three earlier probe designs failed first. What is the
   analogous provenance-independent observable for each of your three groups — truncation,
   page-in, writeback?
2. **What masks each group?** The ISSUE-27 experience was that UFS holes are zero-filled,
   `segmap_pagecreate` reuses resident pages, and a same-process read never leaves the page
   cache. For NFS, does the client cache, the readahead path, or the server's own page
   granularity hide a wrong page number? If a group is not observable, say so before we build
   a probe for it.
3. **Is the existing `11920 6060` reference usable as the regression baseline**, or does the
   conversion change what that number should be? If it stays valid, it is a free before/after
   check on hardware we have already used once.
4. **Can any of the three groups land alone?** You say acceptance requires all three, but
   landing order still matters for bisecting. If a mixed state is worse than either extreme —
   the shape that bit us in ISSUE-27/28/31/32 — say so and we will treat the three as one
   atomic commit.

---

## Context you may not have

* Our implementation order will not follow the report's. The report puts the public VM ABI
  first; we intend to do the testable, live, low-risk items first (UFS `addmap`/`delmap`, then
  NFS) and treat the public ABI as a separate decision rather than a queue item. Q1.4 and Q3
  are what that ordering depends on.
* **RFS stays disabled, and your finding strengthens that.** We had recorded RFS as
  "unconverted and therefore internally consistent". `rfc_writefill` differing by exactly one
  byte from the mounted `rfs/exp` because `page_get` was already moved to 0x1000 means it is not
  consistent, it is broken. That is a better reason than the one we had.
* Nothing in these six families is affected by a separate hazard we found on 2026-07-27: the
  headers we cross-compile C against are the vanilla 2 KiB ones (`PNUMSHFT 11`), so anything
  compiled into the kernel silently gets 2 KiB geometry. That applies to compiled drivers and
  to any future source reconstruction, **not** to byte patches against this image. The two
  should not be conflated even though both are "Model-B residuals".
* Live-image state as of this pin: FPSP is part of the base link, both RTG drivers (Xsvga
  cdevsw[67], VA2000 cdevsw[68]) live in one kernel, and the dbg overlay's `sigtoproc` wrapper
  now logs signals 4..12. None of that touches the families above.
