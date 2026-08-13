# Measuring the Zorro III prize before earning it — busbench on the Z2 aperture

**Machine:** Amiga 3000, 68060 @ 66 MHz, `68060-260809-03` (`unix-040-rtg-isp`), solon
**Date:** 2026-08-10
**Why:** [[amix-zorro3-aperture-limitation]] proposed this as the cheap step that decides whether
the Zorro III work is worth doing — *before* any Z3 work, firmware change or jumper move.

## What was run

`svgaprobe` first, because it identifies the card and the bus mode:

```
SVGAPROBE open /dev/svga0 OK fd=3
SVGAPROBE CardID=3 (Piccolo) FrameBufSize=2097152 MaxPixClk=85 Blitter=1 Panning=1
```

It **opens**, so the Piccolo is in **Zorro II** mode — in Z3 mode this same probe returns ENXIO,
which is the whole reason Z3 is unusable today.

Then `busbench -r` (the reference — the tool refuses to be read without it) and the aperture:

| | write32 | write16 | read32 |
|---|---|---|---|
| local RAM (reference ceiling) | **28.66 MB/s** | 21.59 MB/s | 31.33 MB/s |
| Piccolo aperture, Zorro II | **3.09 MB/s** | 2.95 MB/s | 3.08 MB/s |
| ratio | **9.3×** | 7.3× | 10.2× |

## Reading it — using the tool's own pre-stated discriminator

`busbench.c` states, before any number exists, how to tell a saturated bus from per-access
overhead: *"on a 16-bit Zorro II port a 32-bit access costs two bus cycles but is one CPU
access, so if serialisation overhead dominates you get long ≈ 2× word on BOTH buses, and only
if bus cycles dominate does the ratio separate them."*

Measured: **write32 3170 KB/s vs write16 3021 KB/s — 1.05×, not 2×.**

So byte throughput is flat across access width. The limit is **bytes on the wire, not accesses
per second**: the Zorro II bus is saturated. 3.09 MB/s is essentially the practical ceiling of
a 7 MHz 16-bit Zorro II port, so **the Z2 aperture has nothing left to give.**

## The correction this forced, from source rather than from the plan

`busbench.c`'s header assumes the Z2 target gets the friendlier cache class: DTT0 =
`0x003fc060` covers `0x00000000-0x3FFFFFFF` with CM `0x60` = noncacheable, **not** serialised,
and the VA2000 at `0x00200000` is inside it.

**That holds for a KERNEL dereference of `cd_boardaddr`, not for this measurement.** busbench
uses `mmap`, and the mapping landed at `c1033000` — far outside DTT0's transparent range, so
the cache mode comes from the leaf PTE. `src/hat040.s`, `Lcm_sel`:

```
	tstl	%a2			| pp == NULL -> device/unmanaged
	beq	Lcm_dev
...
Lcm_dev:
	oril	&0x40,%fp@(-44)		| unmanaged PFN -> NCS
```

Every `pp == NULL` device mapping gets `0x40` = **noncacheable-SERIALISED**, Zorro II or III
alike. So the 3.09 MB/s above is the *serialised* path, measured on a Z2 card.

**And that makes the width result more interesting, not less:** even handicapped by
serialisation, the numbers say the limit is the bus and not the serialisation. Serialisation is
not what is costing us on Zorro II today.

## What this decides

1. **Zorro III is worth doing.** The aperture is an order of magnitude below the CPU's local
   ceiling and it is bus-bandwidth-limited, not overhead-limited. Doubling the bus to 32 bits
   addresses exactly the thing that is saturated.
2. **The motive is stronger than on the 030, as [[amix-zorro3-aperture-limitation]] argued.**
   The bus is unchanged since the 030 era; the CPU is now roughly an order of magnitude faster.
   That is the Amdahl shift that turns a bus which was not a bottleneck into one.
3. **It confirms "Z3 is two changes, not one" — from data this time.** The `Lcm_sel` framebuffer
   class is *not* what is limiting Zorro II today, so it buys nothing on its own right now. But
   once the bus stops being the bottleneck, serialisation is the next thing in line, and it
   would eat the gain the wider bus is supposed to deliver. So it belongs to the Z3 work, and
   the earlier guess that it might be a free standing win on Z2 is **wrong** — measured.

## Order of work, unchanged by this but now evidence-backed

1. VA2000 driver source fix (`va2000-amix` repo): keep `va2000_boards[]` physical for `mmap`'s
   `phystopfn`, add `va2000_kva[]` from the kernel mapping; registers use `_kva`.
2. Test it **in Z2 mode** — it must behave identically, because there the mapped VA happens to
   equal the physical address. A failure there is the fix's fault, not Zorro III's.
3. `Lcm_sel` framebuffer class (this repo): a memory-like aperture does not need serialisation,
   and the selector already has three branches.
4. Only then the firmware/jumper move to Z3, and re-run **this same busbench** — the number
   above is the baseline it must beat.

## Caveats kept rather than dropped

* Only the Piccolo was measured. A VA2000 comparison would add a second Z2 data point but not
  change the conclusion, since both would take the same NCS class through `mmap`.
* `busbench` writes garbage to the framebuffer by design. X11 was not running.
* The local-RAM reference is a 1 MB buffer, far larger than the 060's caches, so it measures
  main memory rather than cache — which is the right comparison for a framebuffer copy.
