# Predictions — the ATN / Message Out ABORT path, committed before the run

**Boot `build/unix-040-quiet`, `68040-260829-13`.** Block `a3p` @ `0810EEFC`.
`atn_try` `0810EF7C`, `atn_lci` `+4`, `atn_mout` `+8`, `atn_sent` `+0xc`, `atn_free` `+0x10`,
`rel_try` `0810EF54`, `rel_ok` `+4`, `rel_exp` `0810EF64`.

Implements `docs/contracts/A3091-BUS-FREE-FOLLOWUP-AUDIT.md` Q4, which verdict 7 made necessary
rather than optional.

## What changed from `-11`

The release no longer commands the chip; it addresses the target. `SET_ATN` (0x02), `CLR_ACK`
(0x03), bounded wait for a Message Out phase status, then one PIO byte — SCSI `ABORT` 0x06 —
and then a bounded wait for **bus free**.

And the acceptance test that passed while the bus stayed busy is **gone**: "CIP clear, BSY and
DBR clear" is no longer success anywhere. Only `0x41` or `0x85` is.

Fail-closed everywhere, which gives up `-09`'s partial behaviour on the failure branch. That
branch wedged one command later anyway, so it costs nothing real.

## Predictions

| # | prediction | a miss means |
|---|---|---|
| H1 | `dd` on the CD returns an error and the shell comes back, as on `-09` and `-11` | the ATN path broke the part that worked |
| H2 | `rel_try = 1`, `atn_try = 1` | the gate or the splice is wrong |
| H3 | `atn_lci = 0` — `SET_ATN` was not ignored | the 7 µs guard is insufficient for this command too |
| H4 | **`atn_mout = 1`** — the target asked for Message Out | the CD does not honour ATN mid-cleanup, and the whole approach needs rethinking |
| H5 | `atn_sent = 1` | the data buffer never became ready |
| H6 | `rel_ok = 1` with a `0x41`/`0x85`, `rel_exp = 0` | ABORT did not make the target let go |
| H7 | **the root disk works afterwards** — a second `dd` succeeds and the machine stays up | this is the whole point of the change; a miss means the target still holds the bus |
| H8 | `a3p_n41 = 0` — no `0x41` at all this time | the follow-on failure is unchanged |
| H9 | a second CD read repeats it: `atn_try = 2`, machine still alive | one is luck, two is a mechanism |

`atn_free = 1` instead of `atn_mout`/`atn_sent` is an acceptable pass for H4–H6: it means the
target let go before we could speak, which is the outcome we wanted by a shorter road. It must
not be read as the message having worked.

## What would stop me shipping this

`dd` reporting success, or the machine surviving with `atn_sent = 1` but the root disk quietly
returning wrong data. The request is failed with `okay == FALSE` and nothing on this path sets
it, but that is the invariant worth checking rather than assuming.

## Cost

If it fails, the same wedge as before: one power cycle and an `fsck`. If it works, none — the
machine stays up and every counter is readable over telnet.
