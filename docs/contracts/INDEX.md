# Implementation contracts

This directory closes the static evidence chain used by `src/`. It contains
the 38 analysis records that the implementation names as specifications,
contracts, or authoritative censuses. The larger private analysis repository
remains a research diary and is not required to build or review this port.

Each imported document names its original
`amix-kernel-analysis/vm-map/...` record in the header. Current implementation
and acceptance status comes from `STATUS.md`; pinned-image findings and
old-byte assertions in these documents remain the provenance of the relevant
unit.

## Import and merge policy

All 38 records were imported one-to-one. **No records were merged.** The
apparently paired documents have different normative jobs:

- the ISSUE-42 protection contract defines the architecture/VM rule, while
  its follow-up defines supervisor, signal-return, and landing-pad edges;
- the pagecreate census proves the sites and provenance, while its
  specification defines atomic landing units and acceptance;
- the FPU tier-1 specification and lazy-state audit govern different state
  transitions and are consumed by different source units.

Keeping those names stable makes every source citation unambiguous and lets a
reviewer distinguish a site census from the policy derived from it. References
inside these files to other private analysis notes are supporting research
history, not additional implementation specifications: the imported record
contains the addresses, offsets, ordering rules, alternatives, and acceptance
criteria needed by its listed consumer.

## Name map

### Faults, FPU and ISP

| Original private record | Local contract | Consumers under `src/` |
|---|---|---|
| `vm-map/XPAGE-COVERAGE-AUDIT.md` | [XPAGE-COVERAGE-AUDIT.md](XPAGE-COVERAGE-AUDIT.md) | `krnxmemflt040.s`, `pvn_probe.s`, `wb040.s` |
| `vm-map/ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md` | [ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md](ISSUE42-WBREPLAY-PROTECTION-CONTRACT.md) | `wb040.s` |
| `vm-map/ISSUE42-WBREPLAY-FOLLOWUP-AUDIT.md` | [ISSUE42-WBREPLAY-FOLLOWUP-AUDIT.md](ISSUE42-WBREPLAY-FOLLOWUP-AUDIT.md) | `wb040.s` |
| `vm-map/KRNXMEMFLT-PER-PROC-DEPTH-SPEC.md` | [KRNXMEMFLT-PER-PROC-DEPTH-SPEC.md](KRNXMEMFLT-PER-PROC-DEPTH-SPEC.md) | `krnxmemflt040.s` |
| `vm-map/FPSP-INTEGRATION-PLAN.md` | [FPSP-INTEGRATION-PLAN.md](FPSP-INTEGRATION-PLAN.md) | `fpsp_glue040.s` |
| `vm-map/FPU-TIER1-ENABLE-SPEC.md` | [FPU-TIER1-ENABLE-SPEC.md](FPU-TIER1-ENABLE-SPEC.md) | `fpu060.s` |
| `vm-map/FPU-LAZY-CONTRACT-AUDIT.md` | [FPU-LAZY-CONTRACT-AUDIT.md](FPU-LAZY-CONTRACT-AUDIT.md) | `fpsp060_glue.s`, `fpu060.s` |
| `vm-map/F3-FPSP060-CALLOUT-CONTRACT.md` | [F3-FPSP060-CALLOUT-CONTRACT.md](F3-FPSP060-CALLOUT-CONTRACT.md) | `fpsp060_glue.s` |
| `vm-map/ISP-VECTOR61-UNIT-SPEC.md` | [ISP-VECTOR61-UNIT-SPEC.md](ISP-VECTOR61-UNIT-SPEC.md) | `isp61_060.s` |

### HAT, VM and cache ownership

| Original private record | Local contract | Consumers under `src/` |
|---|---|---|
| `vm-map/CM-PTE-WRITER-MATRIX.md` | [CM-PTE-WRITER-MATRIX.md](CM-PTE-WRITER-MATRIX.md) | `hat040.s`, `kvm040.s`, `patch_b2_flip.py`, `patch_segkmem.py`, `prumap040.s`, `segkmem040.s` |
| `vm-map/P-MAPPING-MATRIX.md` | [P-MAPPING-MATRIX.md](P-MAPPING-MATRIX.md) | `hat-map-040-fix-plan.md`, `patch_pmmu_040.py` |
| `vm-map/HAT-EXEC-AUDIT.md` | [HAT-EXEC-AUDIT.md](HAT-EXEC-AUDIT.md) | `hat-exec-040-fix-plan.md`, `hat_exec040.s` |
| `vm-map/SEGU-AUDIT.md` | [SEGU-AUDIT.md](SEGU-AUDIT.md) | `segu_lockfix.s` |
| `vm-map/AVAILRMEM-ACCOUNTING-AUDIT.md` | [AVAILRMEM-ACCOUNTING-AUDIT.md](AVAILRMEM-ACCOUNTING-AUDIT.md) | `legacysdt040.s` |
| `vm-map/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md` | [ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md](ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md) | `hat040.s`, `legacysdt040.s` |
| `vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md` | [ISSUE40-PTDAT-TEARDOWN-CONTRACT.md](ISSUE40-PTDAT-TEARDOWN-CONTRACT.md) | `hat040.s`, `ptdatfree040.s` |
| `vm-map/DTT0-NARROWING-SPEC.md` | [DTT0-NARROWING-SPEC.md](DTT0-NARROWING-SPEC.md) | `haltsys040.s`, `pstart040.s` |
| `vm-map/CB-PAGE-LIFECYCLE-CLOSURE.md` | [CB-PAGE-LIFECYCLE-CLOSURE.md](CB-PAGE-LIFECYCLE-CLOSURE.md) | `cb_release040.s`, `hat040.s`, `patch_b2_flip.py` |
| `vm-map/DMA-INITIATOR-CENSUS.md` | [DMA-INITIATOR-CENSUS.md](DMA-INITIATOR-CENSUS.md) | `patch_a3091_dma.py` |
| `vm-map/A3091-B2-PREPARE-PATCH-SPEC.md` | [A3091-B2-PREPARE-PATCH-SPEC.md](A3091-B2-PREPARE-PATCH-SPEC.md) | `dma_cache040.s`, `patch_a3091_dma.py` |
| `vm-map/A3091-SPURIOUS-COMPLETION-AUDIT.md` | [A3091-SPURIOUS-COMPLETION-AUDIT.md](A3091-SPURIOUS-COMPLETION-AUDIT.md) | `a3091demux040.s`, `patch_a3091_intr.py` |
| `vm-map/A3091-PHASE-MISMATCH-RESUME-AUDIT.md` | [A3091-PHASE-MISMATCH-RESUME-AUDIT.md](A3091-PHASE-MISMATCH-RESUME-AUDIT.md) | `a3091dbg040.s` (classification build, ISSUE-54) |
| `vm-map/A3091-BUS-RELEASE-CONTRACT.md` | [A3091-BUS-RELEASE-CONTRACT.md](A3091-BUS-RELEASE-CONTRACT.md) | `a3091dbg040.s` release path (partially superseded) |
| `vm-map/A3091-BUS-FREE-FOLLOWUP-AUDIT.md` | [A3091-BUS-FREE-FOLLOWUP-AUDIT.md](A3091-BUS-FREE-FOLLOWUP-AUDIT.md) | ISSUE-54 next build: the `0x41` discriminator |

### Model-B and filesystem boundaries

| Original private record | Local contract | Consumers under `src/` |
|---|---|---|
| `vm-map/PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md` | [PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md](PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md) | `patch_devmmap2.py`, `patch_pvntrunc.py` |
| `vm-map/PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` | [PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md](PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md) | `patch_writeback.py` |
| `vm-map/PAGECREATE-TAILZERO-CENSUS.md` | [PAGECREATE-TAILZERO-CENSUS.md](PAGECREATE-TAILZERO-CENSUS.md) | `patch_pagecreate.py` |
| `vm-map/PAGECREATE-TAILZERO-SPEC.md` | [PAGECREATE-TAILZERO-SPEC.md](PAGECREATE-TAILZERO-SPEC.md) | `patch_pagecreate.py` |
| `vm-map/PAGECREATE-REACHABILITY-AND-UFSBMAP.md` | [PAGECREATE-REACHABILITY-AND-UFSBMAP.md](PAGECREATE-REACHABILITY-AND-UFSBMAP.md) | `patch_ufsbmap.py` |
| `vm-map/NFS-REALHW-ISSUE35-FOLLOWUP.md` | [NFS-REALHW-ISSUE35-FOLLOWUP.md](NFS-REALHW-ISSUE35-FOLLOWUP.md) | `patch_nfs_putpage.py` |
| `vm-map/NFS-READSIDE-ISSUE36-SITE.md` | [NFS-READSIDE-ISSUE36-SITE.md](NFS-READSIDE-ISSUE36-SITE.md) | `patch_nfs_getpage.py`, `pvn_probe.s` |
| `vm-map/SWAPADD-MODEL-B-PATCH-SPEC.md` | [SWAPADD-MODEL-B-PATCH-SPEC.md](SWAPADD-MODEL-B-PATCH-SPEC.md) | `patch_swapgeom.py` |
| `vm-map/EXEC-BOUNDARY-CENSUS.md` | [EXEC-BOUNDARY-CENSUS.md](EXEC-BOUNDARY-CENSUS.md) | `patch_execboundary.py` |
| `vm-map/EXEC-INITIALSTK-PATCH-SPEC.md` | [EXEC-INITIALSTK-PATCH-SPEC.md](EXEC-INITIALSTK-PATCH-SPEC.md) | `patch_execstk.py` |
| `vm-map/SETUPCLOCK-VMETER-PATCH-SPEC.md` | [SETUPCLOCK-VMETER-PATCH-SPEC.md](SETUPCLOCK-VMETER-PATCH-SPEC.md) | `patch_pageoutdefs.py` |
| `vm-map/MINCORE-VECTOR-PATCH-SPEC.md` | [MINCORE-VECTOR-PATCH-SPEC.md](MINCORE-VECTOR-PATCH-SPEC.md) | `patch_mincore.py` |

### Executable-code publication

| Original private record | Local contract | Consumers under `src/` |
|---|---|---|
| `vm-map/DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md` | [DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md](DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md) | `dbgpublish040.s`, `patch_dbgpublish.py` |
| `vm-map/USER-CODE-CACHE-ABI-SPEC.md` | [USER-CODE-CACHE-ABI-SPEC.md](USER-CODE-CACHE-ABI-SPEC.md) | `codepub040.s` |

## Review gates

The import is valid only while all of these remain true:

1. `python3 tools/check-verbatim.py` exits zero.
2. Every specification citation under `src/` resolves to a file in this
   directory.
3. This map contains exactly the 34 original names listed by
   `docs/CONTRACTS-IMPORT-CODEX-TASK.md`.
4. A contract update preserves its addresses, field offsets, ordering
   constraints, refuted alternatives, and platform-attributed measurements.

There are no unresolved import questions. Future conclusions belong in
`STATUS.md` and a dated acceptance record; pinned contract evidence should not
be silently rewritten to match a newer image.

## Research notes referenced but not imported

Twenty-nine analysis records are named inside these contracts and are **deliberately not
here**.
They are supporting research history -- how a conclusion was reached -- not specifications the
implementation is written against, and they stay in the private analysis repository.

This list exists so that a dead reference inside a contract reads as a decision rather than as
an oversight. If one of them turns out to carry something an implementer needs, that is a bug in
this import and worth reporting.

| Referenced record (not imported) | Named by |
|---|---|
| `DMA-PREPARE-COMPLETE-CONTRACT.md` | `CB-PAGE-LIFECYCLE-CLOSURE.md`, `CM-PTE-WRITER-MATRIX.md`, `DMA-INITIATOR-CENSUS.md` |
| `DTT0-PHYS-WINDOW-CENSUS.md` | `CB-PAGE-LIFECYCLE-CLOSURE.md`, `DTT0-NARROWING-SPEC.md` |
| `HAT-MAP-POLICY.md` | `AVAILRMEM-ACCOUNTING-AUDIT.md`, `P-MAPPING-MATRIX.md` |
| `UFS-PUTPAGE-WRITEBACK-CONTRACT.md` | `PAGECREATE-REACHABILITY-AND-UFSBMAP.md`, `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `USER-EXECUTABLE-CACHE-PUBLICATION-CENSUS.md` | `DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md`, `USER-CODE-CACHE-ABI-SPEC.md` |
| `040-FAULT-RESOLVER-AUDIT.md` | `XPAGE-COVERAGE-AUDIT.md` |
| `FPU-STATE-CENSUS.md` | `FPU-LAZY-CONTRACT-AUDIT.md` |
| `GENERIC-PUTPAGE-CALLERS-AUDIT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `HARDBUS-XPAGE-RETRY-AUDIT.md` | `XPAGE-COVERAGE-AUDIT.md` |
| `HAT-CHGPROT-ACCEPTANCE.md` | `P-MAPPING-MATRIX.md` |
| `HAT-CHGPROT-AUDIT.md` | `P-MAPPING-MATRIX.md` |
| `HAT-EXEC-POLICY.md` | `P-MAPPING-MATRIX.md` |
| `HAT-GROWSDT-AUDIT.md` | `HAT-EXEC-AUDIT.md` |
| `HAT-PAGESYNC040-ACCEPTANCE.md` | `P-MAPPING-MATRIX.md` |
| `HAT-PAGESYNC040-DESIGN.md` | `P-MAPPING-MATRIX.md` |
| `HAT-PAGEUNLOAD-ACCEPTANCE.md` | `P-MAPPING-MATRIX.md` |
| `HAT-PTFREE-AUDIT.md` | `AVAILRMEM-ACCOUNTING-AUDIT.md` |
| `HAT-SDT-ALLOC-FREE-POLICY.md` | `CM-PTE-WRITER-MATRIX.md` |
| `HAT-UNLOAD-ACCEPTANCE.md` | `P-MAPPING-MATRIX.md` |
| `NFS-RFS-PUTPAGE-WRITEBACK-CONTRACT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `PAGE-TABLE-LIFETIME-CONTRACT.md` | `AVAILRMEM-ACCOUNTING-AUDIT.md` |
| `PT-MEMORY-B2-POLICY.md` | `CB-PAGE-LIFECYCLE-CLOSURE.md` |
| `REFMOD-PAGEOUT-CONTRACT.md` | `P-MAPPING-MATRIX.md` |
| `S5-PUTPAGE-PVN-RANGE-DIRTY-CONTRACT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `SEGKMEM-KVSEG-MMREAD-FAULT-AUDIT.md` | `XPAGE-COVERAGE-AUDIT.md` |
| `SEGMAP-FAULTA-PAGEIN-AUDIT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `SEGMAP-WRITEBACK-CONTRACT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `SPEC-PUTPAGE-WRITEBACK-CONTRACT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |
| `VOP-PUTPAGE-WRITEBACK-CONTRACT.md` | `PUTPAGE-WRITEBACK-CONVERSION-MATRIX.md` |

## Contracts written in this repository

The count above is about the **import** from the analysis repository and does not change. These
were written here, are not in that repository, and have no `vm-map/...` origin line:

| document | subject | status |
|---|---|---|
| [A3091-PHASE-MISMATCH-DFA-CONTRACT.md](A3091-PHASE-MISMATCH-DFA-CONTRACT.md) | ISSUE-54: an unrecognised WD status must not be permanent death | measurement done, **fix blocked on four stated unknowns** |
| [FPE-INTEGRATION-CONTRACT.md](FPE-INTEGRATION-CONTRACT.md) | NetBSD m68k FP emulator: what the lane owes the kernel | implemented, `relink-040-fpe.sh` |
| [FPE-GLUE-DESIGN.md](FPE-GLUE-DESIGN.md) | the `src/fpe040.s` trap glue | implemented |
| [FPE-R4-DELTA.md](FPE-R4-DELTA.md) | what differs between NetBSD releases in the extracted set | measured |
| [FPE-R7-METAL.md](FPE-R7-METAL.md) | bare-metal assumptions the emulator makes | measured |
| [FPE-R9-ADVMISS.md](FPE-R9-ADVMISS.md) | advance/miss accounting | measured |
| [FPE-R10-VEC60.md](FPE-R10-VEC60.md) | vector 60 and the counter-block address incident in §10.4 | measured |
| [FPE-R16-REDACTION.md](FPE-R16-REDACTION.md) | redaction method for vendor-derived prose | applied |

The FPE documents arrived with the `fpe` branch and are a collaborator's work; the A3091 one is
this line's.
