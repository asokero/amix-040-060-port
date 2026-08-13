# Release plan — publishing the AMIX 68040/68060 port

**Decided 2026-08-13**, revised the same day after four checks that changed it. Publication is the
main track ahead of further feature work; Zorro III remains the one substantial development item;
the RAM-above-32 MB work is declined (`STATUS.md` §6).

---

## 0. Four findings that shape everything below

### 0.1 The vanilla kernel must be **byte-exact**, and nothing checks it today

The patch scripts work on hard-coded `.text` addresses (`0x132`, `0x158`, `0x19b50`, `0x5b3c2`, …),
byte-pattern assertions and relocation offsets. A different build of `/stand/unix` would not fail
cleanly — it would patch the wrong bytes.

```
reference:  AMIX SVR4 2.1c  /stand/unix
sha256      7d26cb6f04991be5776d9e5361259b20b413d97e3da33bf88e6f312e7be2ec23
```

`relink-040.sh` currently contains **zero** hash checks of its input. Adding one is small and it is
the single most important safety change for anyone else running this. Whether every 2.1c
installation carries this exact image is *unverified* — so the check must print the expected hash
and invite a report, not merely refuse.

### 0.2 The loader sources are Commodore's, not ours

`unix_boot/` — **18 tracked files** — carries `Copyright (C) 1991, Commodore Business Machines`:
`unix_boot.c`, `bind.c`, `rel.c`, `streq.c`, `streqn.c`, the headers, `copyit.s`, `Supervisor.s`.
`prototypes/copyit.s` is the same file with our 040/060 MMU-disable changes.

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
| Repo split | one repo vs kernel + loader | **two**: `amix-040-port` and `amix-unix-boot` |

### Phase 1 — licence hygiene (blocking, no functional change)

1. Move `unix_boot/` and `prototypes/copyit.s` out of this repository into the loader project, and
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

### Phase 3 — input validation

1. Hard sha256 check of the vanilla kernel in `relink-040.sh`, with the expected hash and a request
   to report mismatches.
2. Same for the NetBSD tarball used by the FPSP builds.

**Acceptance:** byte-exact rebuild; a deliberately corrupted input is refused with a message that
names the file and both hashes.

### Phase 4 — documentation

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

### Phase 5 — layout

Proposed:

```
  README.md  BUILDING.md  STATUS.md  KNOWN-ISSUES.md  LICENSE  NOTICE
  config.sh.example
  src/          the override units (today: prototypes/*.s)
  patches/      the byte-patch scripts (today: prototypes/patch_*.py)
  tools/        status-facts.sh, check-env.sh, relink checkers
  build-scripts/ relink-040.sh and variants
  test-tools/   unchanged
  docs/         acceptance records, audits, contracts
  docs/archive/ session prompts, run-lists, RESUME-HERE-*
```

Nothing is deleted for looking untidy: the refuted conclusions and the working notes are part of the
evidence.

### Phase 6 — the real test

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
  `--weaken-symbol` / `--add-symbol` pattern, the relink hazards (it does not abort on an assembler
  error), the reloc validator, the "`ld -r` last" ordering rule — is genuinely valuable and belongs
  in `BUILDING.md`. This is knowledge nobody can rediscover cheaply.
* The **machine-specific half** — where the toolchains live on this laptop, NAS mounts, emulator
  paths — stays as `LOCAL-BUILD-NOTES.md`, **gitignored**, as the owner's own working tool.

That split is also the honest test of every other document: if it only makes sense on one laptop,
it is a local note; if it would help a stranger, it is documentation.

## 5. The method piece

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
