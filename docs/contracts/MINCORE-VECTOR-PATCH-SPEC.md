# `mincore` vector-length Model-B patch specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/MINCORE-VECTOR-PATCH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/patch_mincore.py` implements this
> syscall-boundary unit, including the public alignment gate omitted from the
> first draft. The current Model-B group passed its dedicated `mincore` vector
> test.

The `mincore` syscall's address quantum is already based on a 4 KiB chunk,
but its result-vector byte count and page advancement retain a 2 KiB
conversion. This must be changed as one syscall-boundary operation.

Target sites in `mincore`:

| Site | Old operation | Required operation |
|---|---|---|
| `0x58670` | round vector/page span with `+0x7ff` | use `+0xfff` |
| `0x58678` | derive result entries with `>>11` | use `>>12` |

The surrounding chunk quantum is already `128 * 4096 == 0x40000` and must
remain unchanged. Do not alter unrelated `0x800` values in the syscall
perimeter.

Acceptance: a one-page query returns one vector byte; a 4 KiB-aligned
multi-page query returns exactly one byte per Model-B page; an unaligned
range rounds according to the 4 KiB ABI; the kernel never copies or advances
past the caller's requested vector; and `mincore` agrees with the public
`mmap`/`munmap` alignment contract.
