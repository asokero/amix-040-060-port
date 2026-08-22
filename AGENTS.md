# Working in this repository with an AI assistant

This file is for coding agents. It is not a description of the port — `BUILDING.md` §7 and
`src/README.md` do that — it is the set of rules an agent will otherwise break, and the reasons,
because each one here was learned by breaking it.

**Where this file and `STATUS.md` disagree, `STATUS.md` is right.** It is the canonical record;
this file is instructions.

## Read these first

| | |
|---|---|
| `STATUS.md` | what is proven, on which platform, with the evidence. Start here |
| `BUILDING.md` §7 | how the override mechanism works, in one page |
| `src/README.md` | the two ways this port changes the kernel, and the rules for each |
| `docs/METHOD.md` | why the discipline below exists |

Fetch these when the task needs them, not at the start — both are large:

| | |
|---|---|
| `KNOWN-ISSUES.md` | every defect found, including the ones that were not defects. Search it for the subsystem you are touching |
| `docs/contracts/` | the static contract a source unit was written against. `docs/contracts/INDEX.md` maps units to contracts |

**Do not add a parallel description of status, of the build, or of the override mechanism** —
those subjects are owned. New acceptance records and new contracts are a different matter: this
project runs on them, and a measurement without a document is a measurement that will be lost.

## The shape of the problem

There is no complete, buildable kernel source tree — but that is not the same as no sources, and
the difference decides how you should work. See "Look for the source before the disassembly"
below; getting this wrong is the most expensive mistake available here.

The port patches a binary you cannot recompile, addressing it by hard-coded offsets measured
against one exact image. Two consequences govern everything:

* **A wrong change usually does not fail. It succeeds and produces a plausibly wrong kernel.**
  That is why the build asserts before it writes, and why "it built" is not evidence.
* **Hardware time is rationed.** Decide on the emulator whatever the emulator can decide, and
  spend a boot only on what needs silicon. Know which is which before proposing a run.

## Look for the source before the disassembly

This is the working order the project actually uses, and it has a name in `KNOWN-ISSUES.md`:
**source-first**. It has refuted leading hypotheses that disassembly had made look obvious, so it
is not a preference.

1. **The reader's own AMIX installation carries a great deal of source.** `$AMIX_ROOT/usr/src`
   and `$AMIX_ROOT/usr/sys`
   hold thousands of C files and the kernel headers. Machine-specific Amiga code is there too.
   Look here first: it is the same lineage as the binary being patched.
2. **The historical System V sources are the reference for the generic half.** Where AMIX ships
   only a relocatable `exp` object, the corresponding SVR4 code is usually readable in the 3B2
   or USL trees. It is a *reference*, not a drop-in: read the contract there, then confirm it
   against the m68k binary, because the port diverges and the divergence is the interesting part.
3. **Where a source exists, disassemble to confirm rather than to discover.** For code that
   ships only as an object there is nothing to confirm against and the disassembly *is* the
   primary evidence. Otherwise, reading the compiled form is how you check that
   the contract you just read is the one this kernel implements, and how you find the addresses.
   Starting there means guessing at intent from instruction sequences, which is slower and wrong
   more often.
4. **What genuinely has no source** is the set of subsystems shipped only as `exp` objects. For
   those, the contract has to be reconstructed — and when it is, it belongs in `docs/contracts/`
   so the next reader does not repeat the work.

Neither reference tree is tracked or distributed here, and neither is redistributable; they are
the reader's own. Local copies sit gitignored in the working directory, which is exactly why the
next rule exists. Cite them by file, line and function — never paste their lines, see the rule below.

## Rules that are not style

* **Do not reorder the link and patch phases.** There are two `ld -r` runs, not one, and byte
  patches on both sides of the second. The order in `relink-040.sh` is: core override link →
  byte patches against stock offsets → the FPSP link → the FPSP and ISP vector retargets. Two
  rules follow, and the script says so at the site: never move the FPSP link ahead of the
  stock-offset patches, and never run another `ld -r` after the final vector retargets, because
  it would supersede them.
* **Every linked override section ends with `.balign 4`.** A misaligned `.data` total shifts the
  whole kernel `.bss` at runtime and the symptom is a root mount that fails, nowhere near the
  cause. One file is exempt and must stay so: `src/fpsp060_head.s` is concatenated rather than
  linked and has to be exactly 128 bytes.
* **`objcopy --weaken-symbol`, never `--redefine-sym`**, to replace a routine. Expose the original
  with `--add-symbol NAME_orig=.text:0xADDR` when the override needs to tail-jump to it.
* **`ld -r` does not fail when an override definition is missing.** It leaves the stock body
  strong and links cleanly, so the exit status proves nothing. `tools/status-facts.sh` checks the
  bindings in both directions for the units that matter most; that table is the evidence, and it
  is a named subset rather than every override.
* **The immediate prefix depends on which assembler compiles the file, not on taste.** The AMIX
  cross assembler takes `&` (`cmpil &60,cputype`); the GNU path, used for the concatenated
  support-package units, takes `#`. Match the file you are editing.
* **Never edit a build artefact.** Everything under `build/` is regenerated on the next run, so
  a fix applied there disappears without a trace. The change belongs in `src/`, in `tools/`, or
  in the relink script. (The companion loader repository has its own version of this rule, about
  its generated patches; the lesson was learned there.)
* **Do not put a build step behind a pipe.** `cmd | tail -3` discards the exit status in POSIX sh,
  which is how a failing byte-patch assertion went unnoticed for weeks (ISSUE-45). Use
  `run_step` from `tools/build-step.sh`.
* **Do not paste lines from a reference source tree.** Cite file, line and function; describe the
  algorithm. `tools/check-verbatim.py` is the gate and it must report 0 unexplained.

## Code that runs on AMIX itself

Everything under `test-tools/` is compiled by the **native SVR4 `cc` on the guest**, not by the
cross toolchain, and that compiler is from 1991. This is the one place in the repository where
modern C is wrong rather than merely unidiomatic, and the error surfaces on the Amiga — a long way
from where it was written.

* **K&R C.** Parameter types on separate lines after the signature, not in the parameter list. No
  ANSI prototypes. Variables declared at the top of a block. Cast to `(char *)` where you would
  reach for `void *`.
* **Do not redeclare with `extern` anything the system headers already declare** — `<fcntl.h>`
  declares `open()` and friends, and a helpful redeclaration produces "conflicting types".
* **Shell scripts that run on the guest are Bourne sh:** backticks, not `$(...)`; no `[[ ]]`, no
  arrays. Note that this is a *different* rule from the host build scripts, which are POSIX sh —
  two dialects live in this repository and mixing them up is easy. Every guest script here uses
  backticks and none uses `$(...)`; follow the file you are in.
* **`grep -q` does not work on AMIX.** Redirect to `/dev/null 2>&1` instead.
* The 68030/68040/68060 are **big-endian**, so multi-byte values read from `/dev/mem` or
  `/dev/kmem` need no swapping. The host-side Python patchers read the kernel image big-endian for
  the same reason.

`test-tools/README.md` documents what each program measures. Build on the guest with
`cc -o NAME NAME.c`.

## Things that look mechanical and are not

* **A page-size constant is not always a page size.** The 2 KiB → 4 KiB conversion is the largest
  single body of work here, and it is not a sweep of `0x800` → `0x1000`. The same constant may be
  a page, a disk block, a sector, or a buffer geometry that must not move. Establish what a
  literal *means* before changing it; the byte-patchers are grouped by meaning for this reason.
* **Six different kinds of address appear in this project and they are easy to confuse:** the
  `.text`-relative address in the stock kernel, the raw file offset of the same byte (`.text`
  starts at `0x34` in that ET_REL image, and the patchers keep the two apart deliberately), the
  symbol address after linking, the runtime virtual address, the load base the loader chose, and
  the physical address or PFN. A number is meaningless without saying which it is — the load
  base alone differs by 16 MiB between two accelerators.
* **A different stock kernel SHA-256 is a new porting target, not a reason to touch the check.**
  If a reader's `stand/unix` does not match, the offsets this port uses were never measured
  against their image. Record the hash, report it, and do not relax `tools/verify-stock.sh` to proceed.

## How claims are made here

* **Read the magic word before believing a counter.** Every counter block starts with one
  (`fpc_`, `wbf_`, `f60_`, …). A stale address does not fail — it returns a plausible number from
  whatever now lives there. `tools/status-facts.sh` prints the current addresses and the magic
  read out of the artifact.
* **Every claim names the platform it was measured on.** `EMU` and `HW` are not
  interchangeable, and an untested path in the emulator looks exactly like a passing one.
  **Amiberry is not evidence for any of these**, and the list is not closed:
  * it raises no enabled IEEE floating-point exceptions, so those handlers never execute there;
  * it never marks the first 68040 write-back slot valid;
  * **it does not model the 68040's copyback data cache** — a cache or DMA-coherency change that
    passes in the emulator has not been tested at all. ISSUE-38 could only be found on silicon
    for exactly this reason;
  * it is not proof for FSLW.MA behaviour, or for which instructions the CPU traps as
    unimplemented — a UAE core may execute what real silicon refuses.

  Before accepting an emulator result, ask whether the thing you changed is on that list.
* **A branch that never ran is not a branch that works.** Where coverage is missing, say so; do
  not upgrade "not exercised" to "correct".
* **Write down what you expect before you measure.** A prediction that fails is the useful
  result; a prediction made afterwards is not a prediction.
* **Prefer an invariant over a passing test.** Two counters that cannot both be true have caught
  defects here that green test suites did not.
* **Refuted conclusions stay in the record**, labelled as refuted (`STATUS.md` §7). Do not tidy
  them away; the reason a hypothesis failed has repeatedly outlived the hypothesis.
* **When the code or a fresh measurement contradicts `STATUS.md`, that is a defect in the
  documentation** — say so and get it resolved. Do not silently follow either one. `STATUS.md`
  wins when they merely disagree in wording; a measurement that genuinely conflicts with it means
  one of them is wrong and somebody needs to know which.

## Before you claim you are finished

```sh
git ls-files --others --exclude-standard   # must print nothing -- see below
sh tools/check-env.sh                     # exit 0
sh tools/test-build-step.sh               # exit 0
python3 tools/check-verbatim.py           # exit 0 = 0 unexplained.  Exit 2 means it could NOT check
sh relink-040.sh                          # exit 0, and TOTAL complaints: 0 in the output
sh tools/status-facts.sh                  # exit 0, and bindings failing: 0
```

Three of those need care rather than a glance:

* **A file that is untracked but not ignored is the dangerous state**, and it does not look
  dangerous. `git status` mentions it in passing, no check that reads the index sees it, and then
  `git add -A` sweeps it in. That is how a reference source tree, a kernel binary, or a copy of
  the reader's AMIX installation gets published — none of which can be recalled once someone has
  cloned it. `git ls-files --others --exclude-standard` must print nothing before you stage.
* **`tools/check-verbatim.py` only sees files git tracks.** A new file you have not added is not
  checked, so `git add` it before you trust the result. And **exit 2 is not a pass** — it means
  the reference trees are not on this machine and nothing was compared. Note how this rule and the
  previous one pull in opposite directions: an untracked file is invisible to the verbatim gate
  *and* liable to be staged wholesale. Neither is safe. Decide, per file, whether it belongs in
  the repository or in `.gitignore`, and leave nothing in between.
* **`relink-040.sh` prints `TOTAL complaints` from the relocation validator.** A non-zero count
  means the kernel would be rejected at boot. The validator exits non-zero and runs through
  `run_step`, so the build should already have stopped — if you ever see `[OK] built` together
  with complaints, the build gate itself has regressed and that is the bug to fix first.

**Then rebuild and diff.** Two builds of the same tree differ only in the build-id stamp; after
any infrastructural change, that byte-for-byte comparison is the regression test for the build
system itself. A change that alters other bytes has done something you did not intend, and you
should find out what before going further.

## Working with the person who owns this

* **Check `git status` and the existing diff before you touch anything.** There is very often
  uncommitted work in this tree, and it is not yours to reorganise or revert.
* **Do not commit, do not push, do not start a hardware run, and do not reset the emulator's disk
  image unless you were asked to.** Hardware time is booked, an emulator image can hold state
  somebody is mid-way through using, and a commit written for the wrong reason is hard to unpick
  from a history this project treats as evidence.

## What not to do

* Do not add a fourth description of the override mechanism.
* Do not hand-maintain, in prose, the numbers that change on every build: linked symbol
  addresses, counter-block locations, and summary counts of files or units. Generate those.
  Fixed stock offsets, field offsets and measured counter *values* are different — they are the
  substance of a contract or an acceptance record, and they belong in one, pinned to the image
  they were read from.
* Do not weaken a check to make a build pass. The check is the product.
* Do not commit a kernel binary, a reference source tree, or anything from the reader's own AMIX
  installation. `.gitignore` and `NOTICE` define the boundary; `tools/check-verbatim.py` enforces
  part of it.
* Do not describe hardware results you did not see. If a run has not happened, the honest text is
  that it has not happened.
