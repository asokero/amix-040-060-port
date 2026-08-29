# Predictions — ISSUE-54 classification build, written and committed before the run

Kernel `68040-260829-07` (`build/unix-040`; the banner will say `68060-` on the Mercury —
that prefix is the CPU readout, not the image). Instrument `src/a3091dbg040.s`, block `a3p`
@ `0810EA74`, magic `A3P!`, 21 longwords. Trigger:
`dd if=/dev/rdsk/c3d0s0 of=/dev/null bs=512 count=1` after two `sync`s.

Specified by `docs/contracts/A3091-PHASE-MISMATCH-RESUME-AUDIT.md`. **No behaviour change:**
the driver still dies, the machine still wedges, and `fsck` will still have work.

## Emulator, first

| # | prediction |
|---|---|
| E1 | boots to login; the addition is inert |
| E2 | `a3p_magic` reads `41335021` at `0810EA74` |
| E3 | `a3p_seen = 0`, `a3p_ran = 0` — Amiberry's SCSI produces no phase mismatch, so the gate must never fire |
| E4 | `a3d_n = 0` on a clean boot; `a3d_*` unchanged in character |
| E5 | no `a3p` line reaches the console |

## Hardware, on the trigger

| # | prediction | what a miss would mean |
|---|---|---|
| H1 | three `a3p` lines print, ahead of the stock `a3091: 0x49 1 ...` | gate or print placement wrong |
| H2 | `a3p_seen = 1`, `a3p_n49 = 1`, `a3p_n48 = a3p_n4a = 0` | decode wrong, or more than one status arrives |
| H3 | `a3p_rd = 1` — `dd` is a read | request identity is not what we think |
| H4 | `a3p_op` = `0x28` READ(10), or `0x08` READ(6) | the `cdb[0]` offset (+7) is wrong |
| H5 | `a3p_nbyte = 0x200` | `sdcom` offsets are wrong |
| H6 | `a3p_di` bit 6 (DPD) **set**, agreeing with `a3p_rd` | direction handling differs from the source |
| H7 | `a3p_retry = 0` on first arrival | recurrence detection broken |
| H8 | `a3p_verdict` ∈ {1, 2, 5} — **not 4** | a 4 means the chip's direction disagrees with the request, a different and worse defect than ISSUE-54 |
| H9 | `a3p_cp` neither `0` nor `0xff` | the register read is wrong |
| H10 | `a3p_sac` inside `[dma_seg_pa, dma_seg_pa + dma_seg_len]` | cursor outside the ownership envelope → the audit's stop/reconcile/re-arm design is required instead |

## What each verdict decides

| verdict | meaning | next build |
|---|---|---|
| 1 | `cp` 0x41/0x45 and `tc` non-zero | the audit's conditional one-shot resume is justified |
| 2 | `cp` 0x46, or `tc` zero | target overrun — do not resume data |
| 3 | `cp` below 0x40 | command sequencing — needs the CDB contract the audit defers |
| 4 | direction disagreement | stop; this is not the defect we think it is |
| 5 | some other command phase | report it and ask what it means |

## The cost, stated before asking

One power cycle and an `fsck`. The 2026-08-27 capture produced `INCORRECT BLOCK COUNT` on four
inodes and ten `UNREF FILE` reattachments, so this is not a free measurement — it buys the one
tuple that closes the largest remaining unknown.
