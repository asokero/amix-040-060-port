# Zorro III works: a VA2000 driven at 7.66 MB/s in Amiga UNIX

**Machine:** Amiga 3000, Mercury 68060 @ 66 MHz. **MNT VA2000 with Zorro III firmware at
`0x42000000`, 32 MB**, alongside a Piccolo whose RAM board is in Zorro III at `0x40000000`.
**Image:** `68060-260819-13`
**Date:** 2026-08-19

Stock AMIX cannot reach a Zorro III board at all. Its drivers dereference the AutoConfig board
address directly as a kernel address — Commodore's own TIGA driver does it, so the pattern is
theirs — and a Zorro III address lands inside the kernel's own virtual range, where the access
does not fault but quietly hits kernel memory. This is the first time a Zorro III graphics card
has been driven under Amiga UNIX.

## The measurement the track existed for

`busbench`, same tool, same machine, same session, each run preceded by its own local-RAM
reference because absolute numbers do not compare across sessions.

| | write32 | write16 | read32 |
|---|---|---|---|
| local RAM (this session's reference) | 25.91 MB/s | 17.70 | 24.66 |
| **VA2000, Zorro III** | **7.66 MB/s** | **4.12** | **7.05** |
| VA2000, Zorro II (same day, its own reference 26.66) | 3.12 | 2.78 | 3.71 |
| **gain** | **2.45×** | 1.48× | 1.90× |

**It beat the number it had to beat by a factor of 2.45.**

### The width discriminator says *why*, and that matters more than the number

`busbench` states before any measurement exists how to tell a saturated bus from per-access
overhead: on a 16-bit port a 32-bit access costs two bus cycles but is one CPU access, so if
overhead dominated, `long` would move about twice the bytes of `word`; if bus cycles dominate they
come out equal.

* **Zorro II: `write32 / write16 = 1.12×`** — flat. The 16-bit bus was saturated, which is why the
  cache-class work bought nothing there and why that was recorded as measured rather than assumed.
* **Zorro III: `7850 / 4226 = 1.86×`** — a long now moves nearly twice the bytes of a word.

That is a 32-bit datapath being used, not merely a faster one. The aperture went from 8.5× below
local RAM to 3.4× below it.

## Everything else held, in the order it was run

**Boot, from the serial console** — the three lines that had to be right:

```
va2000: board found at 0x42000000, aperture 32768 KB
va2000: firmware version 90, ready
```

* **`0x42000000`** is a Zorro III address, and it is **not** the `0x40000000` already proven —
  the Piccolo holds the lowest 16 MB. The driver works at an address it has never seen, which is
  what changes A and B were for.
* **`aperture 32768 KB`** is the discrimination Zorro II could not give: there the AutoConfig size
  and the fallback constant were both 4 MB. 32 MB can only have come from `autocon()`. **Change C
  proven.**
* **`firmware version 90, ready`** was read through the kernel mapping, from a Zorro III address.
  `dev_kvmap` mapped it, the register answered. **Change A proven on Zorro III.**
* No `cannot map registers`, no `framebuffer cache class NOT registered`, zero panics.

**Device access:** `dd` of the register window returned `005a` throughout (firmware 90) with the
blitter-enable pair reading zero — the same content as Zorro II, through a kernel mapping at a
Zorro III address. That call also exercised the windowed `read`/`write` path.

**Cache-class census**, read out of the live page table:

```
CMF registered intervals: [42010,44000)
+00000000  DEV  pte 42000049  pfn 42000  NCS   register page
+00010000  FB   pte 42010069  pfn 42010  NC    first framebuffer page
+01000000  FB   pte 43000069  pfn 43000  NC    middle
+01fff000  FB   pte 43fff069  pfn 43fff  NC    last
```

The interval is exactly `base+0x10000 … base+size` in page frame numbers, and the classes are
right across a 32 MB aperture spanning about 128 leaf tables — considerably wider evidence than
the 4 MB Zorro II run. **Change D proven on Zorro III.**

## Two honest qualifications

**The Zorro II baseline was measured from offset 0, this one from `0x10000`.** `busbench` mapped
from the aperture base until today, so the 3.12 MB/s figure covered 4 KB of registers plus 60 KB of
undecoded gap plus 960 KB of framebuffer — about 94% framebuffer. This run is 100% framebuffer.
A 6% composition difference cannot account for a 2.45× gain, but the asymmetry is real and cannot
be removed now: the Zorro II firmware is no longer in the card. `busbench` grew an offset argument
today precisely so the question does not recur.

**The undecoded gap is not accessible in Zorro III, and it kills the process.** The firmware
decodes registers at `+0` to `+0x1000` and the framebuffer from `+0x10000`; nothing decodes what
is between. In Zorro II that region answered anyway. In Zorro III it does not, and an access to it
dies — which is ISSUE-47, an unresponsive access being retried rather than signalled. It cost two
tool runs today and is the reason `busbench` now takes an offset.

## The graphics stack, run on Zorro III the same evening

**X11 ran.** And the counters prove it used the new path rather than merely starting: `cmf_fb_n`
rose by **900 events — 450 pages, 1.8 MB of framebuffer, every one classified `NC`** — while
`cmf_ncs_n` rose by 2, one register page. Classification held across 450 consecutive pages, not
just the three that were probed.

**wolf3d ran, with no corruption.** `cmf_fb_n` rose by 38 events, 19 pages, 76 KiB — which is
exactly a 320×200 8-bit buffer plus change. That is the measure a structural census cannot give:
a cache-class mistake does not crash, it puts intermittent garbage on screen, and sustained
drawing is the only thing that shows it.

So changes A/B/C/D are now proven on Zorro III **both ways** — the bits read out of the live page
table, and the behaviour under a real client.

## One thing broke, and it is the driver, not the kernel

**`va2_restore_passthrough()` does not restore passthrough on the Zorro III firmware.** When X11
exited, the VA2000's output froze rather than returning to the Amiga's native picture. The card
was **not** crashed: `open()` still succeeded and the firmware register still read `0x005a` through
the Zorro III kernel mapping, and each subsequent open/close made the display flicker — so the
register writes reach the card and change its state. They simply do not land it in passthrough.

The routine writes a hardcoded 640×480 timing set and `CAPTURE_MODE = 1`, tuned against the
Zorro II firmware's state machine. Recovery is a full mode set: starting wolf3d woke the display
immediately. Recorded as **ISSUE-48**.

This is exactly the class of thing the firmware swap existed to find, and it is worth noting where
it is *not*: not the mapping, not the cache class, not the bus.

## What is still owed

No long pressure run. And two defects are now on the usability path rather than being curiosities:
ISSUE-47 (an access to an unbacked part of the aperture is killed with `SIGKILL` rather than
signalled with `SIGBUS`, or in another case retried forever) and ISSUE-48 above.
