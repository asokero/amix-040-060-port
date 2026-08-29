# Predictions — the `0x41` discriminator, written and committed before the run

**Boot `build/unix-040-quiet`, `68040-260829-11`** — the serial-mirror twin. The whole point of
this build is one console line, and it should not depend on a photograph. The base twin is
`68040-260829-10` if the quiet one cannot be used.

Block `a3p` @ `0810ED8C` (quiet). `a3p_n41` `0810EDA4`, `a3p_verdict` `0810EDE0`,
`a3p_rel_try` `0810EDE4`, `a3p_rel_ok` `0810EDE8`, `a3p_rel_exp` `0810EDF4`.

**No behaviour change from `-09`.** The `0x41` is captured and printed and then still falls
through to the stock fail-stop, exactly as before. The machine is still expected to wedge.

Trigger: `sync; sync; dd if=/dev/rdsk/c3d0s0 of=/dev/null bs=512 count=1`, then a root-disk read.

## The question this run exists to answer

Whose event was the `0x41`? `docs/contracts/A3091-BUS-FREE-FOLLOWUP-AUDIT.md` §Q1: `CP` is the
only field that records how far a command actually got, because `startany()` writes `DI`, the
CDB, the DMA arm, `curunitp` and `STARTING` **before** it writes the command.

| verdict | `CP` | meaning |
|---|---|---|
| **6** | `0x00` | **no new selection completed** — the strong result for a late event belonging to the CD's cleanup |
| **7** | `>= 0x10` | a new selection really progressed, so the event is the root disk's |

## Predictions

| # | prediction | a miss means |
|---|---|---|
| H1 | the `0x49` behaviour is unchanged: `dd` returns an error, `rel_try = 1`, `rel_ok = 1`, `rel_exp = 0`, no `a3091: 0x49` line | the discriminator disturbed the fix |
| H2 | an `a3p ss=41 ...` line appears, before the `a3091dbg` group and the `a3091: 0x41` line | the widened gate does not fire |
| H3 | `a3p_n41 = 1` | |
| H4 | `a3p_verdict` on that line is **6 or 7**, never 1–5 | the 0x41 branch fell into the phase-mismatch verdict |
| H5 | the whole capture reaches the **serial log**, not just the screen | the mirror does not cover this path |
| H6 | the machine still wedges, exactly as on `-09` | something changed that should not have |

## What each verdict decides

- **6** — the `0x41` was the CD letting go late, and the root-disk request had not begun. The
  defect is the cleanup race at its producer: the release must own the target until bus free is
  consumed, and `startany()` must not run before that. This is the audit's corrected design.
- **7** — the root disk really was selected and its command died. Then the release genuinely left
  the bus unusable for a *new* command, and the ATN/Message-Out `ABORT` path is required rather
  than merely protocol-correct.

Either way the answer changes what is built next, which is why this build changes nothing.

## Cost

One power cycle and an `fsck`, same as `-09`. Nothing here can make the wedge worse: every new
path is a read and a print.
