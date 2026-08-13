# Release plan — publishing the AMIX 68040/68060 port

**Decided 2026-08-13.** After the current hardware tests, publication becomes the main track ahead
of further feature work. Zorro III remains the one substantial development item worth doing; the
RAM-above-32 MB work is declined (`STATUS.md` §6).

This document is the plan, not the announcement. It exists because publishing this particular
project has three constraints that most releases do not, and getting them wrong is expensive in
ways that cannot be undone.

---

## 1. What is actually being published

**Not a kernel.** This repository is an override and patch layer applied to a proprietary AT&T /
Commodore binary: 69 override units, 43 patch scripts, and the tooling that links them. The
product of a build is a *derived work* of a kernel nobody here has the right to redistribute.

That single fact drives most of the plan:

* **no kernel binaries may be published** — not the vanilla one, not ours;
* every user must supply **their own licensed AMIX installation**;
* therefore the build must work on someone else's machine, or the release is decorative.

The reproducibility gate (§4) is not a quality nicety here. It is the whole delivery mechanism.

## 2. Two audiences, and they need different things

**The Amiga enthusiast who wants to run it.** Needs: prerequisites stated bluntly, a build that
works, `unix_boot040`, the hardware matrix (what is accepted on which silicon), and an honest list
of what is still open. This audience is small and will find the project by word of mouth.

**The reader interested in how it was done.** This is the larger audience and the rarer content.
The project has an unusual amount of it: pre-registered expectations, records of predictions that
turned out wrong, counter invariants that caught defects no passing test would have, three
external audits that overturned conclusions, and a measurement discipline that is legible in the
commit log. Most reverse-engineering write-ups do not survive that kind of scrutiny because the
record was never kept.

The second audience is served by *curation and a narrative*, not by more code.

## 3. Blocking gates — none of these are optional

### 3.1 Credentials are in the git history

`10.0.10.10` and the root password appear in tracked documents **and in the commit history**.
Editing the files does not remove them. Two options, and this is a decision to take deliberately
rather than by default:

| Option | Cost | Consequence |
|---|---|---|
| Rewrite history (`filter-repo`) | one careful pass, every hash changes | keeps the full record, including the failure log that makes the project interesting |
| Publish a fresh repository whose history starts at publication | trivial | loses the commit-by-commit record, which is a substantial part of the value |

**Recommendation: rewrite.** The history is the artifact most worth publishing. A scrub pass over
~40 commits touching five documents is a bounded job.

### 3.2 Hard-coded local paths

Measured: **59 occurrences of `/home/asokero` across 29 tracked files**, concentrated in
`LOCAL-BUILD-NOTES.md` (13), `emu-reset-boot.sh` (5), and the relink and tools scripts. Every one
of them is a place where someone else's build fails.

Work: introduce a single `env.sh`-style configuration point (toolchain prefix, vanilla kernel
path, emulator paths), and make the scripts read it. Bounded and mechanical, but it must be done
before anyone else tries the build, not after.

### 3.3 Third-party material

Already handled correctly by `.gitignore` — `amix-src/`, `svr4-src-3b2/`, `usl-svr42/`,
`ghindra-unix/`, kernel binaries and the original archives are all excluded, and 421 tracked files
contain no AT&T source. What remains:

* Motorola's 060SP/040SP and the NetBSD tree must be **fetched by script**, not vendored;
* their licence notices must be reproduced where the build uses them.

### 3.4 The README's first sentence

It must say what this is: a patch layer over a proprietary kernel, requiring the reader's own AMIX
installation. Without that, the repository reads as a bootable kernel, and the first issue filed
will be from someone who expected one.

## 4. The reproducibility gate

**`sh relink-040.sh` must run to completion on a machine that has only the documented toolchain**
— no scratchpad, no local paths, no artifacts from this working tree. Until that is demonstrated,
the release is a claim rather than a deliverable.

Test it the honest way: a clean container or a second machine, following only `LOCAL-BUILD-NOTES.md`
as written, with a vanilla kernel supplied from a licensed install. Anything the notes fail to
mention is a bug in the notes.

Acceptance: reloc `TOTAL complaints: 0`, and the produced image differs from the reference build
only in the build-id counter digit — which is already a verified property (`hw-68060-260812-02`).

## 5. What to publish, out of 220+ documents

`kernelsupport/` has 90 markdown files and the analysis repository 132. Publishing all of them
unedited would bury the reader; deleting them would destroy the record. Proposed split:

| Class | Treatment |
|---|---|
| `STATUS.md`, `KNOWN-ISSUES.md`, `LOCAL-BUILD-NOTES.md`, `RELEASE-PLAN.md` | front matter, curated |
| hardware acceptance records (`REALHW-*.md`) | publish as-is — they are the evidence |
| Codex audits and contracts (`vm-map/*.md`) | publish; they are the specification half of the work |
| session prompts, run-lists, `RESUME-HERE-*` | publish in an `archive/` subtree, clearly labelled as working notes |
| task briefs superseded by their answers | archive |

Rule: **nothing is deleted for looking untidy.** The refuted conclusions in `STATUS.md` §7 are part
of the evidence, and a reader who cannot see the wrong turns cannot judge the right ones.

## 6. The method piece

One document, written once, that the second audience actually reads. It should not be a victory
lap. The material that makes it worth reading is specific:

* an invariant counter that found a defect four of six tests were green through (ISSUE-44);
* a pre-registered prediction that was wrong and what that error exposed (ISSUE-42's `si_addr`,
  off by one, on the right page, where no test would ever have caught it);
* a fix that was reverted within an hour because the flag it set meant the opposite of what was
  assumed (ISSUE-43, 5-of-6 → 0-of-6);
* three external audits, two of which overturned a conclusion that had already been written down;
* the emulator/silicon divergences that only measurement could have separated.

**On the AI framing, stated honestly.** The repository's own commit log contradicts any claim that
this was done *by* an AI: the hardware, the priorities, the card swaps and several of the
corrections are the owner's, and two audits by a second model overturned conclusions this one had
committed. What the record does support is narrower and more interesting — that AI-assisted work
on a 34-year-old proprietary kernel is feasible **when it is held to a measurement discipline**,
and that most of the value came from the discipline rather than from the generation. Publishing
the failures is what makes that claim checkable.

## 7. Order

1. Finish the pending hardware tests (burst on the A3640, wolf3d/X11 on the RTG kernel).
2. Decide history rewrite vs fresh repository (§3.1) — everything else depends on it.
3. Path de-hardcoding (§3.2) and the fetch scripts (§3.3).
4. Prove the reproducibility gate on a clean machine (§4).
5. README + curation (§3.4, §5).
6. The method piece (§6).
7. Publish, then Zorro III as the first post-release development.

Nothing in steps 2–6 needs the Amiga powered on, which makes them the natural work for the periods
between hardware sessions.
