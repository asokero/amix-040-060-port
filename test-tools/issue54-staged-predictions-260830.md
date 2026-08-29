# Predictions — Stage D, the bounded drain, committed before the run

**Boot `build/unix-040-quiet`, `68040-260830-06`.** Block `a3p` @ `0810F6E4`; `d_try` `0810F7CC`,
`d_bytes` `0810F7E0`, `d_sent` `+4`, `d_busfree` `0810F7F0`, `d_failed` `0810F7F8`,
`d_quar` `+4`, `d_notowner` `0810F808`.

**This one attempts recovery.** Unlike Stage P it may retire the request and restart the queue —
but only after a bus-free status has been consumed.

## Reported against the design's eight falsification conditions, not summarised

| # | the design's condition | prediction |
|---|---|---|
| F1 | `COM=0x20` rejected, or TC/DBR accounting inexact | does not happen — Stage P measured it |
| F2 | target still in DATA IN after `0x800` discarded | `d_exp_bytes = 0`; the residual should be 1536 |
| F3 | no recognised phase or bus-free event within bounds | `d_exp_poll = d_exp_dbr = d_exp_ss = d_exp_phase = 0` |
| F4 | SDMAC state or the host buffer changes during discard | `dma_on` stays 0; the cursor is not re-read here, which is a gap |
| F5 | action 9, action 0, or a success callback is reached | **`a3091: 0x19` and `0x4B` must not appear**, and `okay` must stay FALSE |
| F6 | `startany()` runs before bus free is consumed | `d_busfree >= 1` before any root command; `d_notowner = 0` |
| F7 | the CD produces another late `0x85` after a root command starts | no `a3091:` line after the retirement |
| F8 | the root request fails after cleanup | **a root read succeeds afterwards** |

## The line I want to see

```
a3p D RETIRED busfree=1 sent=1 ss=41|85 bytes=600
```

`bytes = 0x600` is 1536, the exact residual of a 2048-byte block after 512 were taken. A
different number is informative rather than wrong — it would mean the target's block is not what
we think.

## What the machine should do

`dd` on the CD returns an error, the shell comes back, **and a root-disk read afterwards works**.
That last clause is the whole of Stage D; `-09` and `-11` managed the first two and lost the
controller on the next command.

## The failure that would stop everything

`d_failed = 1` with `dd` reporting **success**. `cp->okay` is cleared by `a3091queue()` and
nothing in Stage D sets it, and stock action 0 is never re-entered — but the whole design turns
on that, so it is the invariant to check rather than assume.

## Cost

If Stage D quarantines, the same wedge as the last five runs: one power cycle and an `fsck`. The
quarantine prints which of the five bounds fired, so a failure is worth one boot rather than a
guess.
