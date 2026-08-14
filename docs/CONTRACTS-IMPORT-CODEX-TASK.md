# Task — close the evidence chain: import the normative contracts into this repository

**For Codex. Documentation work, no kernel change, no hardware, no emulator.** Written
2026-08-14. This is the last item blocking publication that is not simply "push it".

## The situation in one paragraph

Thirty-six files under `src/` — the override units and byte-patchers that *are* the port — cite
their specification as `amix-kernel-analysis/vm-map/SOMETHING.md`, a sibling repository the reader
will not have. `docs/METHOD.md` rests its whole claim on those specifications being inspectable.
Published as it stands, the most load-bearing citations in the project end at a path on one
laptop. The fix is not to publish the analysis repository — most of it is a research diary, and it
would need its own hygiene pass over 132 documents — but to bring across the part that is
*normative*: the contracts an implementation was written against.

## What is already measured — do not re-derive these

```text
tracked files citing vm-map/            123
  ...of which under src/                 36
distinct vm-map documents cited from src/   34      <- the normative set, listed below
distinct cited from anywhere                50
documents in the analysis repository       132
size of the 34                          11 903 lines / ~76 000 words
```

All 34 exist; none is missing. The analysis repository is at
`~/kehitys/amix-playground/amix-kernel-analysis`, and it stays private after this work.

**The provenance gate already exists and passes.** `python3 tools/check-verbatim.py` normalises
every tracked line and compares it against the local reference source trees — 34 818 distinct
lines against 23 743 files, ~25 s — and currently reports **0 unexplained, 11 known**. The 11 are
`include-modelb/sys/{param,immu}.h`, argued in `tools/check-verbatim.allow`. It exits 0 today, and
it must exit 0 when you are finished. It was built before this task on purpose: a manual pass over
five pasted fragments missed two more that the checker found immediately.

## What "done" means

Four conditions, three of them mechanical.

1. **`python3 tools/check-verbatim.py` exits 0.** Anything it reports as unexplained is either a
   line to rewrite or, very rarely, an interface-dictated form to argue for in
   `check-verbatim.allow` — with the argument written out, not asserted.
2. **Every `SPECIFICATION` / `Authoritative …` / `Source contract` citation under `src/` resolves
   to a file that exists in this repository.** Change the citing lines in `src/` to point at
   `docs/contracts/…`; keep the original `vm-map/…` name in the new document's header so the two
   records can still be joined.
3. **`docs/contracts/INDEX.md` maps every old name to its new one**, including any you merge, and
   says explicitly which of the 34 were merged into what.
4. **Nothing the implementation depends on is lost.** For each document, the test is: could
   someone re-derive the unit that cites it — the same addresses, the same field offsets, the same
   ordering constraints, the same refuted alternatives — from your version alone? If not, you
   removed something load-bearing.

## The rule that governs the rewriting

Citing a source is not copying. Pasting its lines is.

Keep, always: file names, line numbers, function names, struct field offsets, register and vector
numbers, addresses, hashes, commit ids, counter names, measured numbers, and the names of the
tests that produced them. These are facts and they are the reason the documents are worth having.

Rewrite, always: any passage that reproduces the reference source's own text. Say what the code
does, in your words — a table, a numbered sequence, pseudocode, an inequality — rather than
showing its lines. The existing repository has worked examples of the target style; compare the
headers of `src/patch_pvntrunc.py`, `src/patch_ufsbmap.py` and `src/patch_kmapools.py` against
their state before commit `c011275`, which is exactly this transformation done by hand.

Do not bring across: whole decompilations, long disassembly listings, long excerpts of any
reference source. Short disassembly of *the specific instructions this port patches* is fine and
necessary — that is a measurement of the binary the reader owns, and it is what makes a byte
patch checkable.

## Style

Match the repository, not the analysis diary. The documents you are producing are reference
material for someone reading the code, so:

* state the contract first and the investigation second, or not at all;
* keep the tables, keep the counter names, keep the numbers with their platform attached
  ("measured on 68060 silicon, `68060-260812-06`") — an unattributed PASS is the thing this
  project has been burned by most often;
* keep refuted hypotheses where the analysis document kept them, and keep them labelled as
  refuted. `STATUS.md` §7 exists because the record of why something failed has repeatedly been
  worth more than the hypothesis;
* British-neutral technical English, no marketing, no "comprehensive" or "robust".

## Merging is allowed, and expected

Several of the 34 are two halves of one subject — the two `ISSUE42-WBREPLAY-*`, the two
`PAGECREATE-TAILZERO-*`, the `FPU-*` pair. Merge where a reader is better served by one document,
split nothing, and record every merge in `INDEX.md`. Aim for a set that reads as a reference
section, not for a fixed number of files.

## The set, largest first, with the units that depend on each

| contract | lines | cited by |
|---|---:|---|
| `XPAGE-COVERAGE-AUDIT` | 631 | krnxmemflt040.s pvn_probe.s wb040.s  |
| `FPSP-INTEGRATION-PLAN` | 585 | fpsp_glue040.s  |
| `ISP-VECTOR61-UNIT-SPEC` | 580 | isp61_060.s  |
| `FPU-LAZY-CONTRACT-AUDIT` | 533 | fpsp060_glue.s fpu060.s  |
| `CM-PTE-WRITER-MATRIX` | 528 | hat040.s kvm040.s patch_b2_flip.py patch_segkmem.py prumap040.s segkmem040.s  |
| `ISSUE40-PTDAT-TEARDOWN-CONTRACT` | 520 | hat040.s ptdatfree040.s  |
| `ISSUE42-WBREPLAY-PROTECTION-CONTRACT` | 498 | wb040.s  |
| `A3091-B2-PREPARE-PATCH-SPEC` | 480 | dma_cache040.s patch_a3091_dma.py  |
| `FPU-TIER1-ENABLE-SPEC` | 473 | fpu060.s  |
| `ISSUE42-WBREPLAY-FOLLOWUP-AUDIT` | 469 | wb040.s  |
| `F3-FPSP060-CALLOUT-CONTRACT` | 459 | fpsp060_glue.s  |
| `AVAILRMEM-ACCOUNTING-AUDIT` | 440 | legacysdt040.s  |
| `NFS-READSIDE-ISSUE36-SITE` | 387 | patch_nfs_getpage.py pvn_probe.s  |
| `PRODUCER-CONSUMER-ASYMMETRY-CENSUS` | 385 | patch_devmmap2.py patch_pvntrunc.py  |
| `HAT-EXEC-AUDIT` | 379 | hat-exec-040-fix-plan.md hat_exec040.s  |
| `DMA-INITIATOR-CENSUS` | 378 | patch_a3091_dma.py  |
| `CB-PAGE-LIFECYCLE-CLOSURE` | 375 | cb_release040.s hat040.s patch_b2_flip.py  |
| `ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT` | 360 | hat040.s legacysdt040.s  |
| `PUTPAGE-WRITEBACK-CONVERSION-MATRIX` | 341 | patch_writeback.py  |
| `DTT0-NARROWING-SPEC` | 340 | haltsys040.s pstart040.s  |
| `SEGU-AUDIT` | 308 | segu_lockfix.s  |
| `PAGECREATE-REACHABILITY-AND-UFSBMAP` | 305 | patch_ufsbmap.py  |
| `EXEC-BOUNDARY-CENSUS` | 299 | patch_execboundary.py  |
| `P-MAPPING-MATRIX` | 287 | hat-map-040-fix-plan.md patch_pmmu_040.py  |
| `KRNXMEMFLT-PER-PROC-DEPTH-SPEC` | 265 | krnxmemflt040.s  |
| `DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC` | 255 | dbgpublish040.s patch_dbgpublish.py  |
| `USER-CODE-CACHE-ABI-SPEC` | 249 | codepub040.s  |
| `NFS-REALHW-ISSUE35-FOLLOWUP` | 215 | patch_nfs_putpage.py  |
| `SWAPADD-MODEL-B-PATCH-SPEC` | 191 | patch_swapgeom.py  |
| `PAGECREATE-TAILZERO-SPEC` | 164 | patch_pagecreate.py  |
| `PAGECREATE-TAILZERO-CENSUS` | 155 | patch_pagecreate.py  |
| `SETUPCLOCK-VMETER-PATCH-SPEC` | 25 | patch_pageoutdefs.py  |
| `MINCORE-VECTOR-PATCH-SPEC` | 22 | patch_mincore.py  |
| `EXEC-INITIALSTK-PATCH-SPEC` | 22 | patch_execstk.py  |

## Suggested order

Do them in dependency order rather than size order, so that the hardest judgement calls come when
you already know the vocabulary:

1. **The FP group** — `FPU-LAZY-CONTRACT-AUDIT`, `FPU-TIER1-ENABLE-SPEC`,
   `F3-FPSP060-CALLOUT-CONTRACT`, `FPSP-INTEGRATION-PLAN`, `ISP-VECTOR61-UNIT-SPEC`. These carry
   ISSUE-43 and ISSUE-44, the two most recent hardware results, and their contracts are the ones
   most likely to be re-read by anyone extending the port.
2. **The HAT/VM group** — `CM-PTE-WRITER-MATRIX`, `ISSUE40-PTDAT-TEARDOWN-CONTRACT`,
   `ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT`, `HAT-EXEC-AUDIT`, `P-MAPPING-MATRIX`,
   `AVAILRMEM-ACCOUNTING-AUDIT`, `SEGU-AUDIT`, `XPAGE-COVERAGE-AUDIT`.
3. **The write-back group** — the two `ISSUE42-WBREPLAY-*`, `KRNXMEMFLT-PER-PROC-DEPTH-SPEC`.
4. **The Model-B conversion specs** — everything ending in `-PATCH-SPEC` or `-CENSUS`.
5. **The rest.**

Run `check-verbatim.py` after each group rather than at the end. It takes 25 seconds and it is
much cheaper to fix one group's habits than five groups' output.

## Where judgement is genuinely required

Some of the analysis documents establish a contract *by* showing what the reference source does.
When you cannot state the contract without the passage, the answer is not to paste it and not to
drop the contract: describe the algorithm precisely enough that an implementer gets the same
answer, and cite the file and line so a reader with their own copy can check you. If a specific
passage seems to resist that, say so in `INDEX.md` under the document's entry rather than
deciding silently — that is a question for the repository owner, not a blocker for the rest.

## What this task is not

Not a rewrite of the port. Not a re-analysis — if a contract in the analysis repository is wrong,
note it, do not fix it here. Not an import of the other 98 documents. And not a place to improve
the conclusions: where an analysis document and `STATUS.md` disagree, `STATUS.md` is right and
your job is to bring the contract across, not to relitigate it.
