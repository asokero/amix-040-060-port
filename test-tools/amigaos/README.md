# AmigaOS-side measurement tools

Everything else in `test-tools/` is built for AMIX. This directory is the exception, and
it exists for one reason.

## Why an AmigaOS tool at all

On 2026-08-19 we measured the VA2000's Zorro III aperture under AMIX:

| | write32 | write16 | read32 |
|---|---|---|---|
| local RAM reference | 25.91 MB/s | 17.70 | 24.66 |
| VA2000 Z3 aperture | **7.66 MB/s** | 4.12 | 7.05 |

and attributed the 7.66 MB/s ceiling to the **card** — a 16-bit SDRAM path, an arbiter
round-trip per transaction, display scanout priority, and no MTC burst support. That
attribution was read out of the card's Verilog. It is an inference, and it has one
control we had never run: **the same card, in the same machine, driven by an operating
system we did not write.**

- If AmigaOS also lands near 7.7 MB/s → the card is the ceiling and our side is clean.
- If AmigaOS reaches materially more → the cost is ours, and it is findable.

Neither answer is obtainable any other way, and one of them is a bug report.

## Build

    sh test-tools/amigaos/mkbusbench_os.sh

Needs `~/kehitys/amiga-gcc-bin/bin/m68k-amigaos-gcc`. The build refuses to finish unless
the emitted instructions still match the AMIX build's loops — see the codegen check in the
script, and the note there on exactly what that check has and has not demonstrated.

## Run

Copy `busbench_os` to the Amiga, boot AmigaOS with the VA2000's normal driver, and:

    busbench_os -l                      # what is on the bus, and at what address
    busbench_os 6d6e:1 1048576 10000    # VA2000 framebuffer

The reference run is not optional here and happens automatically before the board run —
absolute MB/s numbers do not compare across sessions, only the ratio does. That rule was
learned the hard way when a morning and an evening reference differed by 7–20 %.

`10000` is the framebuffer's offset in the aperture. Offset 0 is the **register window**,
and the tool refuses it without `-f`: under AMIX the kernel answered a write there with
SIGKILL (ISSUE-47), but AmigaOS has no such backstop and the writes would land in the
display controller.

## Reading the result — the one trap

**This program does not know the aperture's cache mode.** Under AMIX we know it exactly
(the leaf PTE: `0x40` NCS, or `0x60` NC for the framebuffer class since change D). Under
AmigaOS it is whatever `mntgfx.card`, Picasso96, or an MMU tool left in the tables.

So a raw MB/s gap between the two systems may be a **cache-class difference and nothing
more**. What compares soundly is the *shape*: the write32/write16 ratio, and whether a
ceiling exists at all. The tool prints a `*** SUSPECT` block if the aperture comes back
above half the local-RAM reference, because on a Zorro bus that is not plausible and the
usual cause is a cacheable mapping — i.e. a run that measured the cache and not the bus.

A flagged run is not a fast bus. It is a void measurement.
