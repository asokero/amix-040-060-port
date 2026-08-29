# Stage P accepted — 8/8, `68060-260830-04`, 2026-08-30

The PIO discard primitive is proven, including the number the previous run could not measure.

```
a3p P got=1 tc=0 as=21 ss=0 byte=50 polls=1
a3p P sac0=9715A00 sac=9715A00 cntr=C istr=D1 dmaon=0
a3p P cp=46 di=43 con=C as2=80 bsyw=1
a3091: 0x49 1 0x811402C
a3091: 0x19 3 0x811402C
a3091: 0x85 3 0x811402C
```

| # | | |
|---|---|---|
| P1 | `got=1` and **`tc=0`** — one byte from `DR`, transfer count 1 → 0 | ✓ |
| P2 | `sac0 == sac == 9715A00` — the SDMAC cursor did not move | ✓ |
| P3 | `dmaon=0` | ✓ |
| P4 | no invalid command, no `LCI` | ✓ |
| P5 | `cp=46` unchanged, `di=43` — `DPD` still set, target 3 | ✓ |
| P6 | `con=0C` — the PIO control value took | ✓ |
| P7 | `polls=1` | ✓ |
| P8 | `0x19` then `0x85`, both on the CD's own unit; no root command started | ✓ |

`as2=80` is the point of the fix: `BSY` clear, so the four gated registers were readable when
they were finally read. `bsyw=1` says one delay was needed to get there — the previous run's
`FF FF FF FFFFFF` was one `delayus(8)` away from being correct, and printed the `BSY` that
explained it on the same line.

`byte=0x50` again, the same `'P'` as the previous run: the same disc position, read the same way.

## What is now established about the primitive

`COM=0x20` with `TC=1`, in PIO mode with `CON=0x0C`, on a WD33C93A in `DATA IN` with the
initiator's own count already exhausted:

- transfers exactly one byte to `DR` and decrements `TC` to zero;
- leaves the command phase and the direction register untouched;
- moves nothing through the SDMAC — cursor identical before and after, `dma_on` still 0;
- is not rejected as an invalid command, unlike Transfer Pad and initiator Abort, which
  Western Digital removed from the A revision; and
- reports `XFERRED | DATA_IN` when it completes.

That is the whole contract Stage D needs from it.

## What Stage P deliberately did not do

No recovery. No callback, no `IDLE`, no `startany()`. The machine wedged where it was told to,
and both follow-up events landed on the CD's own unit, so no root-disk command was damaged by
the experiment. Two runs, two controlled boots, and the design's insistence on proving the
primitive separately is why the second one only cost a re-read rather than a re-design.
