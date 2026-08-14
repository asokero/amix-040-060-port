# `exec_initialstk` / `extractarg` Model-B patch specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/EXEC-INITIALSTK-PATCH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** `src/patch_execstk.py` implements this
> atomic initializer-and-rounding group. Ordinary exec and large-argument tests
> are part of the accepted Model-B regression surface.

Target: `build/unix-040`, Model B page size 4096 bytes.

The initializer and its rounding consumers are one atomic group. Changing
only the data word leaves `extractarg` aligned to 2 KiB; changing only the
instructions leaves a one-page stack allocation at the old size.

| Site | Old bytes/operation | Required operation |
|---|---|---|
| `.data` `exec_initialstk` (`0x72c8`) | `00 00 08 00` | `00 00 10 00` |
| `extractarg` (`0x587d0`) | round with `+0x7ff` | round with `+0xfff` |
| `extractarg` (`0x587d6`) | page index `>> 11` | page index `>> 12` |
| `extractarg` (`0x587dc`) | page byte offset `<< 11` | page byte offset `<< 12` |

Use old-byte assertions and resolve the data word by symbol/relocation rather
than assuming a file offset. Preserve instruction length and register use.

Acceptance: a one-page initial stack is `0x1000` bytes; argument extraction
rounds at 4 KiB boundaries; a boundary-crossing argument neither aliases the
preceding page nor skips the following page; ordinary exec and a large argv
both complete without an alignment fault.
