# The 68060 boot precondition, caught on serial for the first time — 2026-08-29

That SetPatch is a boot precondition for the 68060 has been known here since the F0
measurement. What had never been captured is **what the failure looks like**, because it looks
like a black screen. The serial mirror caught it on its first real use, forty minutes after
being proven to work.

Two consecutive boot attempts of the same image, `build/unix-040-quiet` (`68060-260829-08`):

## The failed one

```
kernel cputype set to 40
  -> copyit will take the 68030 [path] ... [I]LLEGAL on a real 040/060!
image checksum = 3e35c5cf
  USP: 8172F8C  SSP: 80022EC  ...
AR: 080022E8 08000884 ...
SF: 2704 0000 E588 20E0 0000 E584 0010 00F8 0C8C
```

## The one that worked

```
68060 : Rev6 Superscalar Load/Store Bypass ...
kernel cputype set to 60
AttnFlags = 0x000080ff
060 (movec) path.
image checksum = 3e35c5e3
```

## What it says

The loader **misdetected the processor** on the first attempt — `cputype 40` rather than `60` —
and warned about the consequence in its own words before taking it: the 68030 copy path, which
is illegal on a real 040 or 060. Then it faulted, and the register dump is the last thing the
machine said.

On the second attempt `AttnFlags = 0x000080ff` and the loader took the `060 (movec)` path.

**The two image checksums differ — `3e35c5cf` against `3e35c5e3` — for the same kernel file.**
That is the independent confirmation: whatever the first attempt copied, it was not the same
bytes the second one copied. A misdetected CPU is not a cosmetic banner error.

## What it is not

Nothing to do with this port's changes. The identical kernel had, minutes earlier, run
`burst4.sh` to 24/24 checksums and 41738 DMA events with every must-stay-zero counter at zero,
and it booted cleanly on the retry. See `docs/REALHW-ISSUE54-REGRESSION-260829-08.md`.

## The loader's serial output is lossy, and this is the record of it

The capture interleaves and drops characters: `LLEGAL` for `ILLEGAL`, `ntinue in 10 s` for
`[RETURN to continue now; auto-continue in 10 s...]`, fragments of one line appearing inside
another. `src/serdbg.s`'s own header describes this exact failure — a character overwritten
inside the ~1 ms TBE window at 9600 — and says it was fixed there by masking to IPL7 for the
whole emit. The loader's mirror evidently did not get the same treatment.

It did not matter here: `cputype set to 40` against `set to 60`, and the two checksums, are
unambiguous. It would matter for a capture where the payload is a register value rather than a
word. Worth fixing before the loader's serial output is relied on for numbers.

## Why this is recorded at all

The instrument earned its keep on its first use. Before the cable, this boot would have been a
black screen and a shrug; the previous ISSUE-54 capture the same morning had to be photographed
off the monitor. The open question at the end of
`docs/REALHW-ISSUE54-REGRESSION-260829-08.md` — whether the serial mirror actually works — is
answered here twice over: by the halt message that arrived before the reboot, and by this.
