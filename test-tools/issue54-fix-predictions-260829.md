# Predictions — ISSUE-54 fix, written and committed before the run

Kernel `68040-260829-09` (`build/unix-040`; the Mercury banner will read `68060-`, which is the
CPU readout rather than the image). Implements
`docs/contracts/A3091-BUS-RELEASE-CONTRACT.md` in `src/a3091dbg040.s`.

Block `a3p` @ `0810ECEC`, magic `A3P!`. Release counters: `try` `0810ED40`, `ok` `+4`,
`raced` `+8`, `fail` `+0xc`, `exp` `+0x10`, `polls` `+0x14`, `maxpoll` `+0x18`.

Trigger `sync; sync; dd if=/dev/rdsk/c3d0s0 of=/dev/null bs=512 count=1`.

## Emulator

| # | prediction |
|---|---|
| E1 | boots; `a3p_magic` = `41335021` |
| E2 | `a3p_rel_try = 0` — the tuple never occurs on Amiberry's SCSI |
| E3 | `a3d_n = 0`, `a3p_seen = 0` |
| E4 | DMA counters self-consistent with a real denominator |

## Hardware, on the trigger

| # | prediction | a miss means |
|---|---|---|
| H1 | **`dd` returns an error and the shell comes back.** The machine stays up | the release did not work, or ownership changed too early |
| H2 | `a3p_rel_try = 1` | the tuple test rejected the very state it was written from |
| H3 | `a3p_rel_ok = 1` **or** `a3p_rel_raced = 1`, and the other 0 | |
| H4 | `a3p_rel_fail = 0` and **`a3p_rel_exp = 0`** | expiry means the WD did not take the Disconnect within ~2 ms |
| H5 | `a3p_rel_maxpoll` small — 0, 1 or 2 | a large value means the conservative pre-command delay is not doing its job |
| H6 | the console shows `a3p RELEASED req=... polls=...` | |
| H7 | **no `a3091: 0x49 1 ...` line.** Its absence is the direct evidence the fatal cell was not taken | |
| H8 | `a3d_n = 0` — `badhardware()` never ran | |
| H9 | a second `dd` against the **root** disk succeeds afterwards, and `dma_prep_to + prep_from == cmpl_to + cmpl_from` still holds | the bus was not usable again, which is what the whole release is for |
| H10 | repeating the CD read gives `a3p_rel_try = 2` and the machine still lives | one release is luck; two is a mechanism |

## What would make me stop and not ship

`a3p_rel_exp > 0`, or `dd` reporting **success**. A short read reported as good is the one
outcome worse than the present wedge, and `cp->okay` staying FALSE is the whole reason it
should not happen.

## Cost

If the release fails, the machine wedges exactly as before: one power cycle and an `fsck`. The
fix cannot make that worse — the fail-closed path ends at the same stock `badhardware()`.
