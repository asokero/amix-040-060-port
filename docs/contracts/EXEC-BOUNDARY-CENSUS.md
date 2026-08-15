# Exec Boundary Census

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/EXEC-BOUNDARY-CENSUS.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** The live ELF units selected by this
> census are implemented by `src/patch_execboundary.py`; ISSUE-32 is fixed in
> the accepted port. The COFF core-file and shared-library candidates retained
> below are historical scope decisions, not part of the reconstructed critical
> surface described by `STATUS.md` section 9.

Status: static census complete for the pinned 040 image; no kernel patch is
proposed here.

Image: `build/unix-040`

Image SHA-256: `735353d215e6679e71233c480edbabd265ff4a8fa6d9e7a2fc5226cd81c62d1d`

Build label: `68040-260725-13`

This note answers `EXEC-BOUNDARY-TASK.md`. It separates the live ELF exec
boundary from the deferred COFF/core-format work, and records which remaining
030-era constants are actual 2 KiB logical-page operations rather than
8 KiB filesystem/segmap geometry.

## Executive Verdict

The current image is **not uniformly wrong across exec**. The earlier
initializer and argument-stack fixes are present: `exec_initialstk` is
`0x1000`, the `extractarg` page-count/stack-allocation group uses the 4 KiB
Model-B shift, and the `execmap` BSS-tail group already uses `+4095`, `>>12`,
and `<<12`.

There is nevertheless a live residual in the normal ELF path:

1. `exhd_getfbuf` and `exhd_nomap` still round file/header-cache ranges with
   2 KiB masks and `+2047`.
2. `execmap` still tests alignment, rounds offsets, and derives a page count
   with the 2 KiB geometry.
3. `elfexec` still has one live byte-count-to-page-count conversion using
   `+2047` and `>>11`.

These three groups are a real 4 KiB correctness boundary. They should be
treated as one **live ELF exec mapping unit** for implementation and testing,
with the header-cache helper as a subunit whose 8 KiB `MAXBSIZE` window must
remain unchanged.

The nine `coffcore` candidates are different. They affect the layout of a
COFF-format core file, not the normal ELF process address space. COFF exec and
COFF shared-library support remain deferred until a reachable-format inventory
or runtime test proves that AMIX needs them. `elfcore` has no candidate 2 KiB
rounding sites in this image.

`grow` is **in scope for the complete user-VM boundary, but not part of the
same atomic exec patch**. Its active conversion sites are already 4 KiB
based. It should retain its own acceptance test and be listed as a companion
unit.

## Evidence and Unit Model

The 3B2 reference makes the relevant units explicit:

- `exec.c:195-200` uses `MAXBMASK` for the 8 KiB buffer window, then
  `PAGEMASK`/`PAGESIZE` for the logical page range.
- `exec.c:285-287` defines `exhd_nomap`'s page range as
  `off & PAGEMASK` through `(off + size + PAGESIZE - 1) & PAGEMASK`.
- `exec.c:804-846` makes `execmap` choose the direct `VOP_MAP` path only when
  file offset and virtual address have the same page offset, then rounds both
  mapping inputs to the logical page boundary.
- `elf.c:198-204` publishes `AT_PAGESZ = PAGESIZE`; the current image emits
  `4096` there.
- `coff.c:550-597` stores core sizes in clicks and feeds the selected ranges to
  `core_seg`; its format-specific page-count fields are not a live ELF mapping
  contract.

The reference source itself is a 3B2/2 KiB implementation. The source names
are therefore used for control-flow and contract provenance; the required
constants below are judged against the current AMIX Model-B contract:

```text
PAGESIZE    = 0x1000
PAGESHIFT   = 12
PAGEOFFSET  = 0x0fff
PAGEMASK    = ~0x0fff
MAXBSIZE    = 0x2000   # retained filesystem/segmap header window
```

The distinction between `PAGEMASK` and `MAXBMASK` is the central guard
against over-converting this area.

## Live ELF Residual Matrix

### Header-cache helpers

| Function | Text offsets | Current operation | Verdict | Reason |
|---|---|---|---|---|
| `exhd_getfbuf` | `0x56786` | `off & 0xf800` | convert | `bpoff = off & PAGEMASK`; this selects a logical page start. |
| `exhd_getfbuf` | `0x567b4` | `eoff + 0x7ff` | convert | `epoff = (eoff + PAGESIZE - 1) & PAGEMASK` in the partial 8 KiB-window case. |
| `exhd_getfbuf` | `0x567bc` | `& 0xf800` | convert | same `epoff` page-end normalization. |
| `exhd_getfbuf` | `0x5677a` | `off & 0xe000` | retain | `boff = off & MAXBMASK`; this is the 8 KiB header/fbuf window, not a page. |
| `exhd_nomap` | `0x569d6`, `0x569e2`, `0x569ea` | start/end rounding | convert | initial `poff`/`epoff` range uses `PAGEMASK` and `PAGESIZE`. |
| `exhd_nomap` | `0x56e26`, `0x56e42`, `0x56e48` | split-range rounding | convert | same range contract when a cached map is partially consumed. |
| `exhd_nomap` | `0x56f64`, `0x56f6a` | tail `epoff` rounding | convert | final no-map tail uses the same logical page-end operation. |

The `exhd_nomap` addresses are one ownership unit, not eight independent
patches. `exhd_getfbuf` and `exhd_nomap` both operate on `exhdmap_t` ranges;
changing only one side would make the hidden header-cache list use one page
geometry while its release/trim side uses another.

`exhd_getmap` and `exhd_release` contain no remaining 2 KiB page candidates.
Their `0xe000` masks are the 8 KiB map-window traversal and are intentionally
retained. Their role in the acceptance test is contract coverage, not a
constant conversion.

### `execmap`

| Text offset | Current operation | Verdict | Interpretation |
|---|---|---|---|
| `0x57a68` | `& 0x7ff` | convert | `offset & PAGEOFFSET` in the direct-map eligibility test. |
| `0x57a72` | `& 0x7ff` | convert | `addr & PAGEOFFSET` in the same test. |
| `0x57a9a` | `& 0xf800` | convert | `offset = offset & PAGEMASK`. |
| `0x57ac0` | `& 0xf800` | convert | second mapping-input page normalization. |
| `0x57b24` | `+0x7ff` | convert | `len` to logical page count before the address-limit check. |
| `0x57b2a` | `moveq #11` / `lsr` | convert | paired with the preceding rounding operation. |
| `0x57c1c`, `0x57c22`, `0x57c28` | `+0xfff`, `>>12`, `<<12` | closed | existing BSS-tail conversion; do not re-patch. |

The first pair is semantically important even though it is only an alignment
test. With a 2 KiB mask, the loader can classify a file offset and virtual
address as equally aligned when they are not equal modulo 4 KiB, selecting the
`VOP_MAP` path under the wrong page relationship.

### `elfexec`

| Text offsets | Current operation | Verdict | Interpretation |
|---|---|---|---|
| `0xb8440`, `0xb8446` | `+0x7ff`, `>>11` | convert or prove byte-unit exception before implementation | live ELF exec boundary check converts a byte-sized value to the legacy 2 KiB page count. |
| `0xb842c` | literal `0x1000` for `AT_PAGESZ` | closed | current image already advertises the Model-B page size. |
| `0xb8406` | `& 0xe000` | retain | auxiliary-vector/base alignment is an 8 KiB compatibility/window operation, not a page-count conversion. |

The `0xb8440` pair is the only residual in the live ELF loader whose exact
source-level field identity is not recoverable from the 3B2 text alone: the
relocation is against `u + 0x7d4`, and the result is compared with `*execsz`.
The dataflow is nevertheless unambiguous: a value is rounded and shifted as a
2 KiB page count. Before changing it, verify the `u+0x7d4` field's unit in the
current AMIX `user` layout. If it is a byte length, the required replacement
is `+0xfff`/`>>12`; if it is already a click/page count, the site is a false
positive and must be retained. This is a targeted proof obligation, not a
reason to leave the whole ELF group unclassified.

## COFF and Core-Format Verdicts

### `coffcore`

All nine supplied candidates are in the format-specific `coffcore` body:

```text
0xb7f96  0xb7f9c  0xb7fb0  0xb7fc0
0xb8040  0xb8046  0xb8062  0xb8068  0xb8088
```

They form three related calculations:

1. header page counts from text/data sizes;
2. a core segment start adjusted by the low 2 KiB offset;
3. segment length/end rounding before `core_seg`.

This is a **COFF core-file layout** unit. A wrong conversion can omit,
duplicate, or misplace bytes in a COFF core dump, but it does not itself write
the live process's text/data pages or alter the ELF page tables. It is
therefore a data-integrity issue for a deferred diagnostic artifact, not a
normal exec boundary defect.

Recommended status: **defer as one COFF-core unit**, unless a reachable COFF
format is demonstrated. Do not mix these nine sites into the live ELF exec
patch.

### `elfcore`

`elfcore` is reachable for the current ELF format and should remain in the
reachability inventory. Its current body walks `as` segments and emits ELF
program headers; the scan found no old 2 KiB rounding literal in the pinned
candidate set. That is a positive result, not proof that every `core_seg`
consumer is 4 KiB-clean. The core writer should get a later behavioral test,
but it is not a pending exec-page conversion group from this census.

### COFF exec and `elf_coffshlib`

`coffexec` is registered in the generic `gexec` dispatch model, so it cannot
be called “dead” from the symbol table alone. It is **unvalidated/deferred**:
the current AMIX workload and acceptance evidence are ELF-only, and no COFF
binary/shared-library reachability proof was found in this static pass.

`elf_coffshlib` is a narrower mixed-format path: the ELF loader calls it only
when an ELF program carries `PT_SHLIB` metadata. It is therefore potentially
reachable from an ELF exec, but not part of the ordinary `PT_LOAD` plus
`PT_INTERP` path. Treat it as its own deferred mixed-format unit, not as proof
that all COFF code is live.

## `grow`, `brk`, and Stack Helpers

`grow` is not an exec-loader operation. It is the fault-time heap/stack address
growth contract, with its own callers and lifetime rules. The current image's
active sites already use the Model-B 4 KiB form, including the `brk`/growth
rounding group around `0x58222`, `0x58228`, `0x58234`, `0x58270`, `0x582ba`,
`0x5830c`, and `0x58328`.

Decision:

- keep `grow` and `brk` as a companion **user-VM-range unit**;
- do not combine them atomically with the ELF header/execmap patch;
- require a separate boundary test for heap growth and stack fault growth;
- do not convert policy-sized `0x20000` stack-placement/alignment values merely
  because they are larger than 4 KiB. The no-op 040 `hat_exec` policy means
  those values are not evidence of a live 030 page-table transfer.

`setregs`, `copyarglist`, and the already-converted `extractarg` group are
consumers of the final stack image. They have to be exercised by the test, but
they are not additional raw 2 KiB writer sites in this image.

## `hat_exec` Compatibility Check

The current linked 040 symbol at `0xd87f0` is the native no-op override:

```asm
clr.l  d0
rts
```

The old 030 stack-table transfer body is retained only as provenance/fallback
material (`hat_exec_orig` in the relink design); it is not called by the live
040 `hat_exec` symbol. `as_exec` still moves the stack segment object and the
subsequent native 040 fault path rebuilds user mappings through
`hat_pteload`. This is compatible with the recommended `execmap` unit: the
loader's page geometry must be fixed independently, and the old HAT transfer
body must not be re-enabled as part of that fix.

## Minimal Atomic Units

1. **Header-cache range unit:** `exhd_getfbuf` + `exhd_nomap`; retain the 8 KiB
   `MAXBSIZE` window and convert only logical-page range operations.
2. **Live ELF mapping unit:** six `execmap` residuals, with the existing BSS
   tail conversion included in the byte assertions.
3. **ELF boundary-check proof:** `elfexec@0xb8440`; patch only after resolving
   the unit of `u+0x7d4`.
4. **Deferred COFF core unit:** all nine `coffcore` sites together, only after
   COFF core reachability is established.
5. **Companion user-VM unit:** `grow`/`brk`, already converted, tested
   separately.

The first three are the implementation-relevant closure for normal ELF
execution. A mixed partial conversion is unsafe because `exhd_*` shares range
metadata, while `execmap` shares the same page-offset contract across text,
data, BSS, interpreter, and any ELF `PT_SHLIB` mapping.

## Acceptance Plan

The test must expose both cold and resident paths; a boot-only `exec /bin/sh`
test is insufficient.

1. **ELF header boundary:** execute a valid ELF binary whose ELF header,
   program-header table, and interpreter path cross 2 KiB boundaries at
   offsets that are not 4 KiB-equivalent. Check successful exec and exact
   `AT_PAGESZ == 4096`.
2. **ELF segment alignment matrix:** use binaries with `p_offset`/`p_vaddr`
   pairs aligned at 0, 0x800, 0x1000, and deliberately mismatched modulo
   0x1000. Verify text/data bytes, BSS zeroing, and relocations after a cold
   page-cache run and after a second resident run.
3. **Interpreter path:** repeat with a dynamically linked ELF, because the
   loader invokes `exhd_getmap`/`exhd_release` for `PT_INTERP` and may traverse
   the same header-cache list multiple times.
4. **Large argument environment:** retain the existing 4500-byte big-argv
   test as the stack-image regression; it validates `exec_initialstk`,
   `extractarg`, `copyarglist`, and `setregs`, not the remaining `execmap`
   sites by itself.
5. **Growth companion:** run independent heap `brk` growth and downward stack
   growth tests; do not use their pass as proof of ELF mapping correctness.
6. **COFF deferred test:** if COFF is later enabled, generate a COFF core with
   non-page-aligned text/data/stack boundaries and validate segment lengths and
   offsets with a format-aware parser. Until then, record it as untested, not
   fixed.

The strongest provenance-independent signal is the executed program's own
bytes and control flow after a cold-cache exec. A malformed core file is a
separate signal and must not be used to infer a live exec fault.

## Correction to Earlier Census Notes

This document supersedes any older statement that still lists
`exec_initialstk = 0x800`, `klustsize = 0x800`, or the pre-existing
`kmem_avail`/`vmmeter` conversions as open in the current image. For this
image, `exec_initialstk` is `0x1000`; `klustsize` is already `0x1000`; the
`kmem_avail` and pageout-default corrections are landed. The remaining exec
items above are the ones still visible in the pinned binary.

## Provenance Index

- Current binary: `amix-040-060-port/build/unix-040`, SHA-256 above.
- Task pin and raw candidate list: `amix-040-060-port/EXEC-BOUNDARY-TASK.md`.
- 3B2 control flow: `svr4-src-3b2/usr/src/uts/3b2/os/exec.c`.
- 3B2 ELF path: `svr4-src-3b2/usr/src/uts/3b2/exec/elf/elf.c`.
- 3B2 COFF path: `svr4-src-3b2/usr/src/uts/3b2/exec/coff/coff.c`.
- Current 040 HAT policy: `prototypes/hat_exec040.s` and the linked
  `hat_exec` bytes at `0xd87f0`.

Confidence is high for the `exhd_*`, `execmap`, `coffcore`, and `hat_exec`
classifications. Confidence is conditional for `elfexec@0xb8440`: the
machine-level operation is clear, but the unit of relocated field `u+0x7d4`
must be confirmed before a patch specification is written.
