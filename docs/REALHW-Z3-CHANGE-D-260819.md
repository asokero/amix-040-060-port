# Change D on silicon — the framebuffer really does get a different cache class

**Machine:** Amiga 3000, Mercury 68060 @ 66 MHz. **MNT VA2000 in Zorro II and a Piccolo in
Zorro III, both fitted at the same time** — the owner had the Piccolo jumpered for Zorro III for
AmigaOS use, which makes this the most useful bench configuration this track has had.
**Image:** `68060-260819-09` (`unix-040-va2000-dbg`, changes A/B/C/D plus the census instrument)
**Date:** 2026-08-19
**Under test:** that `Lcm_sel` gives a registered framebuffer page `CM=0x60` (noncacheable, not
serialised) and every other unmanaged page `CM=0x40` (noncacheable serialised) — read out of the
live page table, not out of the selector's intention.

## Boot facts, from the serial console

Captured over the USB-serial cable at 9600 baud. Two lines that had never been readable before,
because the driver's address line used `%lx` and this kernel's `printf` has no `l` modifier:

```
va2000: board found at 0x200000, aperture 4096 KB
va2000: firmware version 90, ready
```

No `cannot map registers`, no `framebuffer cache class NOT registered`, zero panics: both
`dev_kvmap` and `hat_cm_fb_add` succeeded.

**The VA2000 is at `0x200000`, not the `0x600000` older notes record — and the reason is the
argument for this whole track.** From the loader's board dump:

```
board[0] 0202:70 addr=00e90000 size=00010000   A2065 Ethernet
board[1] 4231:01 addr=00ea0000 size=00010000   Prelude audio
board[2] 0893:05 addr=40000000 size=01000000   Piccolo RAM   <- ZORRO III, 16 MB
board[3] 0893:06 addr=00eb0000 size=00010000   Piccolo registers
board[4] 6d6e:01 addr=00200000 size=00400000   VA2000        <- Zorro II, 4 MB
```

With the Piccolo's RAM board out of Zorro II space, AutoConfig gave the VA2000 a lower address.
**A card's address changed because a different card's jumper moved.** No driver should be pinned
to it, which is exactly what change B removed.

## The census

`test-tools/cmfcensus.c`, X stopped, one page faulted at a time.

```
CMF magic OK at 0810f2bc  fb_n=0 ncs_n=20
CMF registered intervals: [00210,00600) [00000,00000)
CMF +00000000  DEV  events +2  pte 00200049  pfn 00200  NCS noncacheable SERIALISED
CMF +00010000  FB   events +2  pte 00210069  pfn 00210  NC  noncacheable, not serialised
CMF +00200000  FB   events +2  pte 00400069  pfn 00400  NC  noncacheable, not serialised
CMF +003ff000  FB   events +2  pte 005ff069  pfn 005ff  NC  noncacheable, not serialised
CMF-DONE ok=4 bad=0
```

and on the boundary and the prefix:

```
CMF magic OK at 0810f2bc  fb_n=6 ncs_n=22
CMF +00008000  DEV  events +2  pte 00208049  pfn 00208  NCS
CMF +0000f000  DEV  events +2  pte 0020f049  pfn 0020f  NCS
CMF +00010000  FB   events +2  pte 00210069  pfn 00210  NC
```

Every expectation was registered before the run and every one held.

* **The registered interval is `[00210, 00600)`** — the framebuffer offset and the AutoConfig
  aperture size, converted to page frame numbers by the driver.
* **First, middle and last framebuffer pages are all `NC`** — the boundary coverage the acceptance
  list asked for.
* **The boundary is exact to the page**: `pfn 0020f` is `NCS` and `pfn 00210` is `NC`, adjacent
  frames either side of the interval's lower edge.
* **The register page keeps `NCS`**, which is what a control register needs.
* **`fb_n` was 0 before the first probe** — change D's branch had never executed until this run.
* **Every probe produced exactly `+2` events**, the retained 2 KiB `segdev` stepping classifying
  the same 4 KiB leaf twice. This was predicted; a test requiring exactly one event would have
  failed on correctly working code.
* **The counters are self-consistent**: `fb_n` 0 → 6 is three framebuffer probes at two events
  each, `ncs_n` 20 → 22 is one device probe. Nothing else touched the device during the run.

### The display flickered, and that is the driver working

The card blanked briefly. Expected: each probe opens and closes `/dev/va2000`, and
`va2000close()` on last close calls `va2_restore_passthrough()`, which rewrites the timing
registers and sets `VA2_CAPTURE_MODE = 1`. Eight probes, eight restores. It is also secondary
evidence that register writes through the `dev_kvmap` window reach the card, since they produced a
visible physical effect.

### One probe was mis-designed, recorded rather than quietly dropped

An extra probe at offset `0x10800` was intended as the "two 2 KiB halves resolve to one 4 KiB
frame" case. It is not that: the offset is not page-aligned, so the mapping spans two frames and
the latch holds the second (`pfn 00211`). The tool passed it correctly, because the class was
right. The genuine two-half evidence is the `+2 events on a single leaf with a single pfn` that
every page-aligned probe produced.

## What this does not establish

* **No performance claim.** On Zorro II the bus is saturated, measured (`1.12x` between long and
  word, `docs/Z3-BUSBENCH-VA2000-Z2-260819.md`), so removing serialisation cannot show up in a
  throughput number here and none was expected. The class matters once the bus stops being the
  bottleneck.
* ~~**No long-run corruption evidence.**~~ **Closed the same day**: X11, wolf3d and Quake were
  all run on **this** image, i.e. with the framebuffer mapped `NC`, and all three worked with no
  visible corruption. That is the functional evidence the structural census cannot give, and it is
  the only measure a cache-class mistake would show up in. It is still not a *measured* soak with
  a corruption metric — three graphics applications running correctly is strong, and it is not the
  same as a long pressure run with a byte-comparison at the end.
* **A page above the interval was not probed**, because the interval ends at the aperture end and
  `mmap` past it is refused. On a Zorro III aperture that probe becomes available.

## The bench this machine now is

A Zorro III aperture (`Piccolo RAM @ 0x40000000`, 16 MB) and a Zorro II one (the VA2000) are
present simultaneously. That makes a Zorro III test of the kernel mapping mechanism available
**without touching the VA2000's firmware**: a probe kernel can `dev_kvmap` the Piccolo's Zorro III
aperture and read through it. If that works, the only unknown left at the firmware swap is the
VA2000's own Zorro III firmware — instead of the mechanism, the address space and the firmware all
being open at once, where a failure could not be attributed to any one of them.
