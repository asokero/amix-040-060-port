# Predictions — the ATN path with stage tracing, committed before the run

**Boot `build/unix-040-quiet`, `68040-260829-15`.** Block `a3p` @ `0810EFE0`;
`atn_try` `0810F060`, `atn_mout` `+8`, `atn_sent` `+0xc`, `atn_free` `+0x10`,
`atn_stage` `0810F07C`, `rel_try` `0810F038`.

**One variable changed from `-13`: instrumentation.** The bound is still 16 × `delayus(8)`. If
the bound is what failed, this run says so; widening it at the same time would have made a
success unattributable.

## Why this build exists

`-13` failed and printed `a3p RELEASE-FAILED try=1 as=0 ss=0 polls=0`, which could not
distinguish an ignored `SET_ATN` from a wrong phase from a timeout. That print carried only the
`a3p_rel_*` fields because it was written before the ATN path and never extended — my omission,
and the counters that would have answered it went with the wedge.

Now the failure prints two lines, and `stage` says how far the path got:

| stage | reached |
|---|---|
| 2 | about to `SET_ATN` |
| 4 | ATN taken without `LCI`, about to `CLR_ACK` |
| 5 | a status arrived in the message-out wait and is being classified |
| 6 | the target asked for MESSAGE OUT |
| 7 | `XFER_INFO` issued, waiting for `DBR` |
| 8 | the ABORT byte went out |
| 9 | waiting for bus free |

`ATN-EXPIRED` and `ATN-FAILED` are now separate messages, which `-13` could not tell apart.

## Predictions

| # | prediction | reads as |
|---|---|---|
| H1 | one `a3p ATN-FAILED` **or** `ATN-EXPIRED` line appears with a non-zero `stage` | the tracing works |
| H2 | `stage >= 4` — `SET_ATN` was not ignored | a stage of 2 means `LCI`, and the 7 µs guard is too short for this command too |
| H3 | if `stage = 5`, the printed `ss` is the status that was rejected — **that number decides the next build** | |
| H4 | `stage = 7` or `9` with `ATN-EXPIRED` would mean the bound is too tight, and the fix is to widen it | |
| H5 | the second event is again `ss=85` on the CD's own unit, as on `-13` | |
| H6 | the machine wedges, as on `-13` | it did not, and something else changed |

## The `-13` observation this is chasing

On `-13` the follow-up was `0x85` — bus free — **on the CD's own unit**, where `-09` and `-11`
had `0x41` on the root disk's. The target let go. Whether that was because the ABORT reached it,
or would have happened anyway, is exactly what `stage` and `atn_sent` will settle.

## Cost

One power cycle and an `fsck`, as before. Nothing here changes behaviour; every addition is a
store to a counter and two printf calls on paths that already ended in the stock fail-stop.
