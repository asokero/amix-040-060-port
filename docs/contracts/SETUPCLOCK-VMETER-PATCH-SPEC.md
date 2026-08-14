# `setupclock` / `vmmeter` pageout-default patch specification

> **Imported normative contract.** Original analysis record:
> `amix-kernel-analysis/vm-map/SETUPCLOCK-VMETER-PATCH-SPEC.md` (private workspace,
> imported 2026-08-14). This copy is the implementation-facing reference used by `src/`.

> **Current implementation status.** This group is implemented by
> `src/patch_pageoutdefs.py` and is included in the current Model-B build.

This group preserves the historical byte thresholds while changing the
Model-B page interpretation. The pageout defaults are installed by
`setupclock`, not by their zero-valued `.data` initializers.

Required changes:

| Site/group | Required result |
|---|---|
| `setupclock` `lotsfree`, `desfree`, `minfree` defaults | Convert the old byte-derived constants to 4 KiB pages, preserving the documented byte thresholds before the memory-fraction cap. |
| `setupclock` `fastscan * PAGESIZE` | Replace the remaining `<<11` byte conversion at `0x51f6a` with the Model-B `<<12` conversion. |
| `vmmeter` useful-pages-per-I/O | Replace the constant-folded `MAXBSIZE / 2048 == 2` with the Model-B page count used by the source policy; keep `maxpgio` in I/O operations per second. |

Do not divide every page count mechanically. `minfree`, `desfree`, and
`lotsfree` are policy values and must be chosen together with the memory
fraction cap. `handspread` is a byte quantity and its byte initializer is
already correct; only its final page-size multiplication belongs in this
group.

Acceptance: on a fixed memory configuration, the resulting thresholds in
bytes match the documented source policy; `vmmeter` reports the intended
number of pages per I/O interval; pageout does not scan or wake at twice the
old byte thresholds; and the setup path remains stable with zero-valued
override globals.
