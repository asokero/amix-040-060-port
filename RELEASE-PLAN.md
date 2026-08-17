# Release plan — publishing the AMIX 68040/68060 Port

**Decided 2026-08-13**, revised the same day after four checks that changed it. Publication is the
main track ahead of further feature work; Zorro III remains the one substantial development item;
the RAM-above-32 MB work is declined (`STATUS.md` §6).

---

## 0. Four findings, as they stood before the release work

> **Read this section as history.** It was written on 2026-08-13, before any of the release work,
> and it describes the repository as it was then. Everything in 0.1 and 0.3 has since been fixed;
> the finding is kept because *why* each mattered is the argument for the shape the repository now
> has. Where this section and `STATUS.md` disagree, `STATUS.md` is right. Each subsection ends with
> what actually happened.

### 0.1 The vanilla kernel must be **byte-exact**, and nothing checked it

The patch scripts work on hard-coded `.text` addresses (`0x132`, `0x158`, `0x19b50`, `0x5b3c2`, …),
byte-pattern assertions and relocation offsets. A different build of `/stand/unix` would not fail
cleanly — it would patch the wrong bytes.

```
reference:  AMIX SVR4 2.1c  /stand/unix
sha256      7d26cb6f04991be5776d9e5361259b20b413d97e3da33bf88e6f312e7be2ec23
```

`relink-040.sh` contained **zero** hash checks of its input. Adding one was small and it was the
single most important safety change for anyone else running this. Whether every 2.1c installation
carries this exact image is *unverified* — so the check had to print the expected hash and invite a
report, not merely refuse.

**Done** (phase 3): `tools/verify-stock.sh`, sourced by every script that patches the stock kernel,
tested in both directions, with `AMIX_ALLOW_UNKNOWN_STOCK=1` as the documented override. ISSUE-45
later closed the second half of the same problem: a failing patch assertion now stops the build
instead of scrolling past.

### 0.2 The loader sources are not ours to publish

> **Corrected 2026-08-15.** This section originally read "The loader sources are Commodore's, not
> ours". `unix_boot` is **Markus Wild's** program (Aminet `misc/unix/unix_boot`, v1.1c) — not a
> Commodore product. Its readme records that he took the boot sources from `/usr/sys/amiga/boot`,
> changed device I/O to DOS, and converted the assembler from SGS to MIT syntax for GCC, which is
> why the derived files still carry Commodore's 1991 header. No licence is stated for his own
> work. The conclusion below is unchanged and now rests on two grounds instead of a wrong one.

`unix_boot/` — **18 files, tracked at the time** — carried `Copyright (C) 1991, Commodore Business Machines`:
`unix_boot.c`, `bind.c`, `rel.c`, `streq.c`, `streqn.c`, the headers, `copyit.s`, `Supervisor.s`.
`src/copyit.s` is the same file with our 040/060 MMU-disable changes.

So the loader **cannot be published as sources either**, and the separate loader project the owner
proposed is the right shape but not for the reason assumed: its licence is not "determined by its
origin" in a way that allows redistribution — its origin is proprietary. The loader repository must
therefore be exactly the same kind of artifact as this one: **patches plus build scripts, applied
to sources the user already has.**

That is a coherent story rather than an awkward one: *two patch layers, one over the kernel and one
over the loader, both requiring your own AMIX media.*

### 0.3 The FPSP/ISP packages are already fetched, not vendored

`build-fpsp040.sh` and `build-fpsp060.sh` extract Motorola's packages from NetBSD's `syssrc.tgz`,
which is outside the repository. Only the path is hard-coded. Nothing to remove — just to
parameterise.

### 0.4 A byte-exact regression test for the whole build system already exists

Established when `hw-68060-260812-02` was tagged: rebuilding from a tree reproduces the accepted
binary **except for one byte**, the build-id counter digit at a known offset. That makes every
refactoring phase below verifiable without hardware and without judgement:

> after the change, rebuild and diff against the reference binary — exactly one byte may differ.

This is the acceptance criterion for phases 1–5.

---

## 1. What is actually being published

**Not a kernel, and not a loader.** Two override-and-patch layers over proprietary binaries. The
build produces derived works of material nobody here may redistribute, so:

* no kernel or loader binaries in the repositories;
* every user supplies their own licensed AMIX 2.1c installation;
* the build must therefore work on someone else's machine, or the release is decorative.

The owner may separately provide a prebuilt kernel to amigaunix.com, where the historical
distribution already lives. That is outside these repositories and outside this plan — but it means
the published build instructions must be good enough that the binary is a convenience, not the only
way in.

## 2. Two audiences

**Runs it:** prerequisites stated bluntly, a working build, the hardware matrix, an honest open-issue
list. Small audience.

**Wants to know how it was done:** pre-registered expectations, predictions recorded as wrong,
counter invariants that caught what no passing test would have, three external audits that
overturned conclusions. Larger audience, rarer content, and served by curation and a narrative
rather than by more code.

---

## 3. The phases

Each phase is independently completable and ends with the byte-exact rebuild check (§0.4). Nothing
before phase 6 needs the Amiga.

### Phase 0 — decisions (needs the owner, blocks everything)

| Decision | Options | Recommendation |
|---|---|---|
| Licence for our own work | MIT / BSD-2 / other | **MIT**, matching `va2000-amix` and `xrtg-amix` |
| Third-party attribution | — | a `NOTICE` file: NetBSD-derived algorithms (BSD-2), Motorola packages fetched under their own terms, AMIX/Commodore material never redistributed |
| Git history | rewrite vs fresh start | **rewrite** — the commit-by-commit record including the failures is a substantial part of the value |
| Credentials | where they live | a gitignored local file the tooling reads; never a tracked file |
| Repo split | one repo vs kernel + loader | **two**: `amix-040-060-port` and `amix-unix-boot` |

### Phase 1 — licence hygiene ✅ **DONE 2026-08-13**

Result, with the verifications that were actually run:

```
  credentials     local/secrets.env (gitignored) + a tracked .example; five documents
                  redacted; test-tools/hw.py committed for the first time, reading the
                  env file -- it was previously un-committable BECAUSE it held the password
  loader          unix_boot/ (18 files) and src/copyit.s moved out to the new
                  amix-unix-boot repository as FIVE PATCHES over unix_boot.lha
  self-test       apply.sh + patches reproduce the working tree BYTE FOR BYTE
  history         git filter-repo: password 0 occurrences in all 621 commits,
                  unix_boot/ and copyit gone from every commit, 5 tags preserved
  tag re-verified building from hw-68060-260812-02 in a clean worktree AFTER the rewrite
                  still reproduces the hardware-accepted binary: 2 bytes differ, both
                  inside the build-id stamp (date + per-day counter)
  backups         pre-rewrite bundle kept outside the repository, and on the NAS
```

Two corrections were needed along the way and are recorded in the commit: the patch baseline
is `unix_boot.lha`, **not** `vanilla/usr/sys/amiga/boot` (different lineage — patches against it
would have been wrong), and `src/copyit.s` was a stale duplicate that nothing built.

### Phase 1 — as originally planned

1. Move `unix_boot/` and `src/copyit.s` out of this repository into the loader project, and
   convert them there into **patches against Commodore's originals** plus build scripts.
2. Credentials: create `local/secrets.env` (gitignored), referenced by `test-tools/hw.py`-style
   tooling; remove the five documents' inline credentials.
3. Rewrite history to remove credentials (`git filter-repo`), once, carefully.

**Acceptance:** byte-exact rebuild; `git log -S` finds no credential; no tracked file carries a
third-party copyright except quoted console banners.

### Phase 2 — environment (the one that decides whether anyone else can build)

1. One configuration point: `config.sh` (gitignored) generated from a tracked `config.sh.example`,
   holding toolchain prefixes, the vanilla kernel path, the NetBSD tarball path, emulator paths.
2. De-hard-code the **59 `/home/asokero` occurrences across 29 tracked files**.
3. `tools/check-env.sh`: verifies every dependency, prints exactly what is missing and where to get
   it, and exits non-zero. This is the script a newcomer runs first.

**Acceptance:** byte-exact rebuild with `config.sh` pointing at the same paths; `check-env.sh`
passes on this machine and fails informatively when a tool is hidden.

### Phase 3 — input validation ✅ **DONE 2026-08-13**

```
  tools/verify-stock.sh   sourced by relink-040.sh, relink-030-dbg.sh, relink-hat.sh and
                          relink-pstart.sh -- every script that patches the stock kernel
  positive                correct kernel: "[*] stock kernel verified", build byte-exact
  negative                one byte changed in the input: refused, exit 1, both hashes and
                          the reason printed
  override                AMIX_ALLOW_UNKNOWN_STOCK=1 proceeds with a loud banner, for the
                          case where someone's 2.1c genuinely differs and wants to try
```

The NetBSD side needed nothing: `build-fpsp060.sh` already validates the **content that
reaches the kernel** rather than the container — the assembled Motorola image's `.text` size
against an expected constant, and zero unresolved symbols. That is a better check than a
tarball hash, because it accepts any NetBSD release carrying the same Motorola drop and
rejects a different one.

⚠ Recorded because it happened: the override test built a kernel from the corrupted input
**into the normal output path**, so `build/unix-040` briefly held an untrustworthy artifact.
It was rebuilt and re-verified immediately. The banner says "do not trust any measurement
from it"; it does not stop the file from looking like every other build.

### Phase 3 — as originally planned

1. Hard sha256 check of the vanilla kernel in `relink-040.sh`, with the expected hash and a request
   to report mismatches.
2. Same for the NetBSD tarball used by the FPSP builds.

**Acceptance:** byte-exact rebuild; a deliberately corrupted input is refused with a message that
names the file and both hashes.

### Phase 4 — documentation ✅ **DONE 2026-08-13**

```
  README.md      the front door, va2000-amix structure: what this IS (a patch layer, not a
                 kernel), disclaimer, a both-CPU status table, known issues, quick start,
                 files, related projects, licence
  BUILDING.md    dependencies with sources and reasons, configure, build, verify, the
                 stock-hash rationale, booting, HOW THE PORT WORKS in one page, external
                 drivers, and the two things the emulator cannot decide
  LICENSE        MIT
  NOTICE         what is deliberately absent and why; Motorola and NetBSD attribution
  LOCAL-BUILD-NOTES.md  keeps only what is true of one laptop, with the split rule stated
```

Every file the README links to was checked to exist. `docs/` is referenced nowhere yet — the
layout move is phase 5, and the front door must not describe a structure that does not exist.

### Phase 4 — as originally planned

1. **`README.md`**, following the `va2000-amix` structure: Overview · Disclaimer · Status · Hardware
   requirements · Files · Quick start · Known issues · License. First sentence states that this is a
   patch layer requiring the reader's own AMIX.
2. **`BUILDING.md`** — generic build instructions: dependencies (cross toolchains, m68k binutils,
   Python 3), how to obtain each, how to configure, how to build, how to verify.
3. **External drivers** — how to build `va2000` / `xrtg` / other drivers into the kernel
   (`relink-040-rtg.sh` and friends), since that is the main extension point.
4. **`LOCAL-BUILD-NOTES.md`** — see the assessment in §4 below.

**Acceptance:** a reader following only `BUILDING.md` on a clean machine reaches a built kernel.
Tested for real in phase 6.

### Phase 5 — layout ✅ **DONE 2026-08-13**

```
  prototypes/ -> src/     495 references rewritten; the name was actively misleading, since
                          these are the shipping product rather than prototypes
  docs/                   51 acceptance records, contracts, audits and findings
  docs/archive/           41 session prompts, run-lists and task briefs -- working notes,
                          kept deliberately rather than deleted for looking untidy
  root                    6 documents: README, BUILDING, STATUS, KNOWN-ISSUES, RELEASE-PLAN
                          and the gitignored LOCAL-BUILD-NOTES
  75 files                had stale bare references to moved documents; all repointed
```

**One deviation from the plan, taken deliberately:** `prototypes/` was NOT split into `src/` and
`patches/`. Several byte-patchers belong to one specific override unit — `patch_isp_vec61.py`
with `isp61_060.s`, `patch_fpsp_vectors.py` with the FPSP glue — and separating them into two
directories would break that pairing for no reader benefit. One rename, not a four-way split.

The relink scripts also stay at the repository root: they are the documented entry points
(`sh relink-040.sh`), and burying them under `build-scripts/` would add a path for nobody's
benefit.

**Acceptance:** three full rebuilds during the move (after the rename, after the document move,
after the reference rewrite), each differing from its reference in exactly one byte — the
build-id counter. `check-env.sh` still exits 0. No dead links in any root document.

### Phase 5 — as originally planned

Proposed:

```
  README.md  BUILDING.md  STATUS.md  KNOWN-ISSUES.md  LICENSE  NOTICE
  config.sh.example
  src/          the override units (today: src/*.s)
  patches/      the byte-patch scripts (today: src/patch_*.py)
  tools/        status-facts.sh, check-env.sh, relink checkers
  build-scripts/ relink-040.sh and variants
  test-tools/   unchanged
  docs/         acceptance records, audits, contracts
  docs/archive/ session prompts, run-lists, RESUME-HERE-*
```

Nothing is deleted for looking untidy: the refuted conclusions and the working notes are part of the
evidence.

### Phase 6a — clone test on this machine ✅ **DONE 2026-08-14**

`git clone` into an empty directory, then `BUILDING.md` followed literally.

**It found three things the working tree was hiding**, which is exactly what it was for:

* `LOCAL-BUILD-NOTES.md` was **still tracked**. It went into `.gitignore` in phase 1, but an
  ignore entry does not untrack a file already in the index — so the laptop-specific notes, 13
  hard-coded paths and all, would have been published.
* `muistiinpanot.txt` — a fragment of an assistant conversation, in Finnish, about a component
  that has since moved to its own repository.
* `z3660-upstream-patches/` had no `NOTICE` entry, being our diffs against someone else's project.

After fixing those, a second clone:

```
  420 files, no local-only leftovers
  check-env.sh          exit 0
  relink-040.sh         exit 0, TOTAL complaints: 0, bindings failing: 0
  resulting kernel      2 bytes from the reference -- the build-id date and counter
```

**What this proves and what it does not.** It proves nothing the build needs is untracked, no
relative path is wrong, and the documented steps work in order from a clean checkout. It does
**not** prove that `BUILDING.md`'s dependency instructions are sufficient: `config.sh` was copied
rather than filled in from scratch, and the toolchains already existed on this machine. That is
what phase 6b is for, and it cannot be faked here.

### Phase 6b — the real test, on another machine

Clone to a different machine, run `check-env.sh`, follow `BUILDING.md` **only**, build the
toolchain from its own upstream, supply a vanilla kernel, build. **Every step the notes fail to
mention is a bug in the notes.** Then boot the clone-built kernel on the Amiga.

### Phase 6 — as originally planned

Clone to another machine, run `check-env.sh`, follow `BUILDING.md` only, supply a vanilla kernel,
build. **Every step the notes fail to mention is a bug in the notes.** Then boot the result on the
Amiga to confirm the clone-built kernel is byte-identical to the reference.

### Phase 7 — publish

`LICENSE` (MIT), `NOTICE`, the method piece (§5), then push. Zorro III becomes the first
post-release development.

---

## 4. Assessment: what to do with `LOCAL-BUILD-NOTES.md`

It currently mixes two things, and the mix is why it cannot be published as-is (13 of the 59
hard-coded paths are in it).

**Split it.**

* The **generic half** — three toolchains and what each is for, the `ld -r` override mechanism, the
  `--weaken-symbol` / `--add-symbol` pattern, the relink hazards (`ld -r` links cleanly when an
  override definition is missing), the reloc validator, the link/patch phase ordering — is
  genuinely valuable and belongs
  in `BUILDING.md`. This is knowledge nobody can rediscover cheaply.
* The **machine-specific half** — where the toolchains live on this laptop, NAS mounts, emulator
  paths — stays as `LOCAL-BUILD-NOTES.md`, **gitignored**, as the owner's own working tool.

That split is also the honest test of every other document: if it only makes sense on one laptop,
it is a local note; if it would help a stranger, it is documentation.

## 5. The method piece ✅ **WRITTEN 2026-08-14** — `docs/METHOD.md`

Nine practices, each with the incident that produced it; four cases with the actual numbers
(ISSUE-43's byte offset and two reverted fixes, ISSUE-44's invariant against four green tests,
ISSUE-42's wrong pre-registration and the off-by-one it exposed, the clock correction that deleted
one finding and improved another); an explicit account of who did what, including the two
conclusions a second model overturned; and a transferable checklist.

The AI framing is stated so a reader can check it against the commit log rather than take it on
trust.

## 5b. The method piece — as originally planned

One document, written once. Not a victory lap — the material that earns attention is specific:

* an invariant counter that found a defect four of six tests were green through (ISSUE-44);
* a pre-registered prediction that was wrong, and the defect its wrongness exposed (ISSUE-42's
  `si_addr`, off by one, on the right page, where no test would have caught it);
* a fix reverted within an hour because a flag meant the opposite of what was assumed (ISSUE-43);
* a clock figure that was wrong for months and deleted one finding while creating a better one;
* emulator-versus-silicon divergences that only measurement could separate.

**On the AI framing, stated plainly.** The commit log contradicts any claim that this was done *by*
an AI: the hardware, the priorities, the card swaps and several of the corrections are the owner's,
and audits by a second model overturned conclusions this one had committed. What the record does
support is narrower and more interesting — that AI-assisted work on a 34-year-old proprietary
kernel is feasible **when it is held to a measurement discipline**, and that the value came from the
discipline rather than the generation. Publishing the failures is what makes that claim checkable.
