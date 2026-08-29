# Stage P — the PIO discard primitive works. My capture of it did not.

`68060-260830-02`, 2026-08-30. Six of eight predictions held, one was unmeasurable through my
own error, and the error is a documented property of the part that I read past.

## The capture

```
a3p ss=49 cp=46 tc=0 di=43 con=8C as=0
a3p req=8113A78 op=28 rd=1 addr=970B000 len=200
a3p sac=970B1F0 cntr=C verdict=2 retry=0
a3091dbg ss=49 istate=1 unit=8113FD8 head=0 dmaon=1
...
a3p P got=1 tc=FFFFFF as=21 ss=0 byte=50 polls=1
a3p P sac0=970B200 sac=970B200 cntr=C istr=1 dmaon=0
a3p P cp=FF di=FF con=FF
a3p ATN-FAILED stage=5 as=80 ss=89 polls=1
a3p RELEASE-FAILED try=1 as=0 ss=0 polls=0
a3091: 0x49 1 0x8113FD8
a3091dbg ss=19 istate=3 unit=8113FD8 head=0 dmaon=0
a3091: 0x19 3 0x8113FD8
a3091dbg ss=85 istate=3 unit=8113FD8 head=0 dmaon=0
a3091: 0x85 3 0x8113FD8
```

## The primitive is proven, by three facts that do not depend on the broken capture

- **`got=1`** — exactly one byte was taken from `DR`.
- **`byte=0x50`** — `'P'`, plausible CD content. Not `0x00`, not `0xFF`, so a real byte moved.
- **`ss=0x19`** on the next interrupt — `SBIC_CSR_XFERRED | DATA_IN_PHASE`. **The WD itself
  reported that the transfer completed.** That is the chip's own statement that `COM=0x20` with
  `TC=1` did what the documentation says, and it arrived after the quarantine had already taken
  the driver to `DEAD`, which is why it shows as `istate=3`.

| | | |
|---|---|---|
| P2 | `sac0 == sac == 970B200` — the SDMAC cursor did not move | ✓ |
| P3 | `dmaon=0` | ✓ |
| P4 | no `0x40`, no `LCI` | ✓ |
| P7 | `polls=1` | ✓ |
| P8 | quarantine held — both follow-ups are on the CD's own unit, no root command started | ✓ |

`sac` sat at `970B200`, which is `segpa 970B000 + 0x200`: the cursor was already at the end of
the 512-byte segment and stayed there. PIO moved nothing through the DMA path.

## What I got wrong

`tc=FFFFFF`, `cp=FF`, `di=FF`, `con=FF` — all four read as solid ones. That is not the chip
misbehaving. `sbicreg.h` states it plainly:

```
SBIC_ASR_BSY  0x20  /* Busy, only cmd/data/asr readable */
```

I captured those four registers while `BSY` was still set, and `BSY` means exactly that they are
not readable. `0xFF` is what an ungated read returns.

**The evidence was in my own capture the whole time**: `as=0x21` is `DBR | BSY`. I printed the
bit that invalidated the four numbers printed beside it, and did not look at it.

So **P1 is confirmed by other means and unconfirmed by the means chosen for it** — `got=1` and
the `0x19` completion prove a byte moved, but `TC` going 1 → 0 was never actually measured.
P5 and P6 are likewise unmeasured rather than failed.

## The fix, which is small

Wait for `BSY` to clear before reading `TC`, `CP`, `DI` and `CON`. Bounded like everything else
here. `DR` and `AS` stay readable throughout, so the byte and the status capture were never at
risk — only the four that are gated.

## What Stage D now rests on

The discard primitive is real: one PIO byte, no memory movement, no invalid command, and the
chip's own `XFERRED` to confirm it. The design's decision to prove this separately before
building the drain was correct, and it cost one controlled boot exactly as intended — no root
command was damaged, and the machine wedged where it was told to.
