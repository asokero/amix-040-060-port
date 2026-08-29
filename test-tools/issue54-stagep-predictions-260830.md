# Predictions — Stage P, the PIO discard primitive, committed before the run

**Boot `build/unix-040-quiet`, `68040-260830-02`.** Block `a3p` @ `0810F244`;
`p_try` `0810F2E8`, `p_got` `+4`, `p_tc` `0810F300`, `p_sac0` `0810F310`, `p_sac` `+4`.

`docs/contracts/A3091-DATA-IN-DRAIN-DESIGN.md` Stage P. **This attempts no recovery.** It takes
one byte, captures, and quarantines: no callback, no `IDLE`, no root command. The machine wedges
by design, and that is the point — a failed primitive costs one controlled boot instead of
another damaged command.

## Predictions

| # | prediction | falsifies the primitive if |
|---|---|---|
| P1 | `a3p P got=1 tc=0 ...` — exactly one byte from `DR`, count 1 → 0 | `got=0`, or `tc` not 0 |
| P2 | `sac0 == sac` — the SDMAC cursor does not move | PIO moved memory it should not own |
| P3 | `dmaon=0` throughout | the driver's own DMA flag is not what we think |
| P4 | no invalid command: `ss` is not `0x40`, and `as` shows no `LCI` (bit 6) | the A revision rejects `COM=0x20` here too |
| P5 | `cp` still reads `0x46`, `di` still has bit 6 set | the probe disturbed direction or progress |
| P6 | `con` reads back `0x0c` — the PIO value took | the control write did not stick |
| P7 | `p_polls` small, 1 or 2 | the byte was not promptly available |
| P8 | the machine wedges with `a3091: 0x49` and does **not** start a root command | quarantine leaked |

## What each outcome decides

- **All eight hold** → the primitive is real, and Stage D (the bounded phase drain, message-out
  and status handling, bus-free proof) can be written on it.
- **P1 or P2 fails** → the drain must not be written. `COM=0x20` is not doing what the
  documentation says on this part, and that is the whole reason for proving it separately.
- **P4 fails** → the A revision has removed more than Transfer Pad and Abort, and the design
  needs to go back to the datasheet before anything else is attempted.

## A deviation from the spec, stated rather than buried

Stage P asks for **caller-buffer canaries** around the original 512-byte transfer. Not
implemented. The buffer address is the caller's, and dereferencing it from inside an interrupt
handler on a machine that has just done something unexplained is the exact hazard this file
refuses elsewhere — a diagnostic that can fault is not a diagnostic. The SDMAC cursor is captured
before and after instead: if PIO moved memory through the DMA path, `sac` would move. That is
weaker, and it is what is available without a new risk.

## Cost

One power cycle and an `fsck`. Unchanged from the last four runs.
