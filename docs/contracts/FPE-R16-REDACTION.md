# FPE round 16 — the redaction pass: every third-party quotation replaced by a description

This round changes no code and no measurement. It rewrites the branch's own history so that no
blob and no commit message it carries reproduces text from a licensed third-party source. The
rule it implements is the one `AGENTS.md` already states for new work — *cite by file, line and
function; describe the algorithm; never paste the lines* — applied retroactively to everything
this branch had accumulated, because a fixing commit on top would leave the pasted text sitting
in the history underneath it.

> **PROVENANCE.** This document describes what was removed and what was deliberately kept. It
> quotes nothing. The licences of the packages this port builds against are reproduced in
> `THIRD_PARTY_NOTICES/`, which is where reproduction is both required and permitted.

The precedent is `4f15c81` on the `z3660` line, which replaced a decompiled `segmap_unlock`
guard with a description of the same three conditions. That commit is the model for the wording
used throughout this pass: keep every address, offset, field name and number; drop the borrowed
sentence.

---

## 1. What was scanned, and against what

Four passes, all mechanical, over **every blob version of every text path at every one of the 32
commits** in the range, plus **every commit message** — not just the tip.

| pass | what it matches | why it exists |
|---|---|---|
| exact line | a normalised source line appearing identically in a reference file | what `tools/check-verbatim.py` does, at a lower threshold |
| 8-token shingle, per line | an eight-word run shared with a reference line | catches a quote embedded mid-sentence |
| 8- and 6-token shingle, **joined stream** | the same, with line breaks removed on both sides | a quote that was re-wrapped across two lines is invisible to every line-based check, and this branch had three of those |
| code-span | every inline-code span and fenced block, as a contiguous token sequence | finds a pasted declaration or statement that is too short to trip a shingle |

Reference corpora: Motorola's M68040 FPSP and M68060 support package and the NetBSD/m68k FPE, all
three as `tools/netbsd-pin.sh` pins them; the historical System V trees and the reader's own AMIX
sources that `check-verbatim.py` already uses; and the emulator this lane benches on, because
these documents cite its CPU core as often as they cite the vendor packages.

**The joined-stream pass is the one that earned its keep.** `tools/check-verbatim.py` compares
line against line, so a sentence quoted across a line break matches nothing — and its
`BOILERPLATE` filter drops lines that still begin with `*` after one comment marker is stripped,
which is the exact shape of a support-package banner comment. Both blind spots were occupied.

---

## 2. What was rewritten

Every entry below is a passage that reproduced someone else's words. In each case the technical
content — the offsets, the field names, the numbers, the argument order — is unchanged; only the
borrowed sentence is gone.

| document | passages | source |
|---|---:|---|
| `FPE-R9-ADVMISS.md` | 6 comment quotations from the 68060 support package's unimplemented-`<ea>` handler (the immediate-length rule, the EA-calculator by-product, the frame-synthesis comment, the undefined `<ea>` slot, the Next-PC store, the exception-priority clause); 1 machine-ABI header comment; 1 emulator source line; 1 emulator call site and comment | 68060 SP, NetBSD FPE, emulator |
| `FPE-R10-VEC60.md` | 3 comment quotations from the 68060 support package; the `fpu_explode.c` 1.15→1.16 diff hunk, reproduced as a diff, now described; 2 inline source excerpts in the call-site table | 68060 SP, NetBSD FPE |
| `FPE-INTEGRATION-CONTRACT.md` | an FPSP instruction-plus-comment quotation and its neighbouring comment; a fenced format-4 code block; the "hack" comment; the PC-advance source line; a `static` declaration pair; 2 copies of an abort call | M68040 FPSP, NetBSD FPE |
| `FPE-GLUE-DESIGN.md` | the "hack" comment; 3 `static` declarations quoted as source | NetBSD FPE |
| `FPE-R4-DELTA.md` | 1 header comment describing a process flag | System V `<sys/proc.h>` |
| `src/fpe_glue.c` | 2 comment quotations, in the instruction-length block and the round-10 rewind block | NetBSD FPE |
| `src/fpe-compat/m68k/m68k.h` | 1 header comment describing the CPU-type variable | AMIX `<sys/systm.h>` |

**The six `HANDLING: … not for any push` banners are gone, and not merely deleted.** They were
false in two directions. Forwards, because the documents they guard no longer contain what they
warn about. Backwards, because the "same class" they each name — the ATT7 and ATT8 results — is
already in this branch's own merge-base, i.e. was published long before the banner was written.
Each is replaced by a **PROVENANCE** note that says what the sections are actually made of:
structural analysis of the stock kernel image this port patches, measured and cited by address,
with third-party code described rather than reproduced.

---

## 3. What was deliberately kept, and why

A scan tuned to find seven-word overlaps finds a great many things that are not authorship.
Recording the verdicts is the point of the exercise; a class silently dropped is a class nobody
can re-check.

* **Licence text.** `NOTICE` and everything under `THIRD_PARTY_NOTICES/` reproduce notices whose
  licences require reproduction without alteration. `check-verbatim.py` already skips that tree.
* **Interface-dictated declarations.** `src/fpe-compat/sys/cdefs.h`'s short-name typedefs match
  the System V `<sys/types.h>` spellings because a typedef of one of those short BSD names onto
  its standard type has exactly one form that interoperates. This is the same argument the
  `include-modelb/` allowlist entry already makes, and it is the whole of that allowlist: the
  11 reported matches are all in those two headers, both unchanged by this pass and both already
  published.
* **Function signatures.** The emulator's entry point and its per-instruction operator are quoted
  as prototypes because the prototype *is* the contract a caller writes against. Replacing them
  with prose would remove the thing the section exists to state.
* **Identifiers, constants and data tables.** Field names, configuration-flag expressions,
  exception and instruction mnemonics, vector numbers, and the operand-size table the emulator
  indexes with a source specifier. These are facts about an instruction set, not sentences.
* **Strings that locate code in the binary.** A driver's error string is how a reader finds the
  address the surrounding paragraph disassembles. The document is analysis of a shipped image,
  and the string is data in that image.
* **This project's own words.** Several passages quote earlier documents in this repository, this
  port's own assembly comments, and a comment this project contributed to the emulator it benches
  on. Those are self-citations and stay as they are.

Two items are recorded as **judgments rather than certainties**, and both were left in place:

1. `test-tools/fpe-harness/include/sys/systm.h` carried unnamed `panic`/`printf` prototypes
   between the commit that created it and the commit that named the parameters. The line matches
   every System V `<stdio.h>` because a variadic prototype has one spelling. It was already cured
   forward *inside this range*, by a commit whose entire content and whose message are that fix —
   redacting it at the introducing commit would empty that commit and make its message false.
   A two-line standard-library prototype in one intermediate blob is the smaller cost.
2. The typedef block above. There is no alternative spelling to move to, so the verdict is
   "interface, not expression" or nothing.

---

## 4. What the rewrite is proved to have done

* **Nothing outside the redactions moved.** For each of the 32 commit pairs, the tree diff
  restricted to every path *not* in the redaction spec is empty, and the set of paths is identical
  on both sides — no file added, removed, renamed or re-moded. Eight paths changed anywhere in the
  range: the six documents and two source files listed in §2.
* **Both source-file edits are comment-only and line-count-neutral**, so the compiler sees the
  same input. `build/fpe-obj/fpe_glue.o` and `build/fpe-obj/fpe040.o` are **byte-identical** to
  the objects built before the pass, and so is the base image `build/unix-040`.
* **Author and committer are `Jusii <jussi@alanara.fi>` on all 32 commits**, and every message,
  author date and committer date is byte-identical to the original — the messages are copied from
  the raw commit objects rather than through a pretty-printer, which would silently append a
  newline to all of them.
* **The gates pass at the new tip.** `tools/check-verbatim.py` exits 0 (0 unexplained, 11 known,
  all in `include-modelb/`); `tools/check-blocks.sh` reports PASS over the range;
  `relink-040-fpe.sh` completes with 0 complaints and every assertion green; the four vendor
  extractions — 040 FPSP, 060 SP, `ftest060` and the FPE — each verify the pinned tarball and
  build clean.
* **The linked kernel differs only by its stamp.** Two consecutive builds at the same tree differ
  in exactly one byte, inside the 16-byte `buildid` field, which is what
  `FPE-INTEGRATION-CONTRACT.md` §1 says about this artifact not being sha-reproducible. That is
  the reason the object shas above are the evidence and the kernel sha is not.

The scans of §1 were re-run over the rewritten range and report **no third-party prose, comment
or statement text in any blob or any commit message**. What they still report is the §3 set:
licence text, typedefs, signatures, identifiers, numeric tables and self-citation.

---

## 5. The commit map

The rewrite is `4f15c81..` — everything above the merge-base with the published branches. The
first commit maps to itself because it touches none of the redacted paths, so its tree and its
parent are unchanged and it hashes to the same object.

| # | before | after | subject |
|---:|---|---|---|
| 1 | `ac63f6cebf95` | `ac63f6cebf95` | fpe: the NetBSD/m68k FPE is extracted from the pinned tarball, never vendored |
| 2 | `0aa87fcacf22` | `372d9531a24a` | fpe: the AMIX side of the seam, measured |
| 3 | `eb8f7871e0e8` | `ea78287131dc` | fpe: the glue design, pre-registered |
| 4 | `799fbc3d0923` | `e46902f2662b` | fpe: the glue |
| 5 | `2c90b5451271` | `23c5e3c7e7c3` | fpe: the relink |
| 6 | `70b04ba5692b` | `7203c8fcfbc8` | fpe: the round-4 delta, pre-registered |
| 7 | `e6fcbc7b58b0` | `e1370c725917` | fpe: deliver signals from the success path |
| 8 | `13e68e404d63` | `b633022c68df` | fpe: exec and sendsig get a reset FP model |
| 9 | `b7c5d9eb0fe4` | `4c758eb12c11` | fpe: read cputype as the long it is |
| 10 | `566f888e90d5` | `3f5e2992aad3` | fpe: advmiss counts straight-line advances only |
| 11 | `4becdb42e2c8` | `fb0fa306bba5` | fpe: census the frame format before the decline |
| 12 | `7cd59b1a0ad2` | `1243217eeb1d` | fpe: latch the faulting PC beside the delivered si_addr |
| 13 | `d064d97738f2` | `83cbfdf8d97d` | fpe: the header caught up |
| 14 | `03b4cf0f4819` | `f38b00523eca` | fpe: the format-2 frame's +8 longword is the operand address |
| 15 | `98991071275e` | `7cb10575c4dd` | fpe: si_addr's "next FP instruction" rule is refuted |
| 16 | `39d6d53d147d` | `32db6f93e7db` | fpe: the buildid offset moves when .data grows |
| 17 | `72440559a4b2` | `c2feca89a706` | fpe: round 5's number against each row of the glue design's registration |
| 18 | `c1318f0e8554` | `f5928d3edf60` | fpe: the metal NO-GO is a root-storage family, not the FPE lane |
| 19 | `21e96cd061c1` | `9b7fc7fc29a6` | fpe: the relink asserted fifteen things about the glue and nothing about the base |
| 20 | `5f54bf5062a1` | `0a3c1a7608dc` | fpe: the round-7 artifact is the metal known-good minus the ucontext arm, plus the lane |
| 21 | `e26f1c88826c` | `426c6e577bb7` | fpe: advmiss-201 is the frame telling the truth |
| 22 | `3d871192ab2d` | `8c0ca2c01744` | fpe: the vector-60 SIGSYS is Lco_fpudis_nofpu declining, not a handler failing |
| 23 | `31a92e0d7103` | `a06860be454e` | fpe: vector 60 gets the arm vector 11 has |
| 24 | `4e92c5904c61` | `1675685b8cf8` | fpe: the vector-60 artifact, its lineage and the metal plan |
| 25 | `322f45bf65a0` | `2f63807d53bf` | fpe: the abort latches get a magic and a section it can gate |
| 26 | `43572663b490` | `ee0090f90885` | status-facts: a .bss symbol is not at textsize + nm offset |
| 27 | `a5aae1c0e8cf` | `72714fcaf466` | fpe: round 11's metal answers and the round-12 artifact |
| 28 | `5aa8f41b1e7c` | `a38d6d02a902` | fpe-harness: name the variadic parameters so the stub header is its own text |
| 29 | `c2ff9c05c9ab` | `ce5ebe0bcfd9` | fpe: the vendor tarball is pinned to NetBSD 10.1, and the move is measured rather than assumed |
| 30 | `5556248967c3` | `60c5e0305529` | fpe: three of the four vendor-source extractions never looked at the tarball |
| 31 | `03ab7e281437` | `af8426320428` | fpe: three documents still described the pin as it was two rounds ago |
| 32 | `58871d8cf1f3` | `a5b1955e4ba2` | BUILDING: the checksum gate outgrew extract_fpe.sh |

This document is the commit above `a5b1955e4ba2` and therefore cannot name its own hash. Any
reference to a pre-rewrite hash — in a results file, a build log, or another document — refers to
the left-hand column; the right-hand commit has the same tree apart from the redactions and the
same message, author and date.
