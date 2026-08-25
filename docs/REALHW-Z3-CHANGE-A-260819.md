# Zorro III change A on silicon — the kernel MMIO mapping works, measured on the 68060

**Machine:** Amiga 3000, Mercury 68060 @ 66 MHz, MNT VA2000 with Zorro II firmware 1.9.0
**Image:** `68060-260819-02` (`unix-040-va2000-dbg`, base `unix-040-dbg` + VA2000 driver +
`dev_kvmap`)
**Date:** 2026-08-19
**What is under test:** changes A, B, C and the `read`/`write` windowing — the driver no longer
dereferences `cd_BoardAddr`; register access goes through a kernel mapping made by `dev_kvmap`
with an explicit noncacheable-serialised class.

This is the Zorro II half of the plan: it must behave *identically* to before, because in Zorro II
the mapped VA merely happens to address the same board the physical dereference did. A failure
here would be the fix's fault, not Zorro III's.

## What ran, and what each result proves

Expectations were registered before each command.

**1. The image is the one under test.**

```
uname -m  ->  Amiga (Unlimited) 68060-260819-02
```

**2. Opening the device exercises the whole new path.** `open()` reaches `va2000_map_regs()` ->
`dev_kvmap(0x600000, 0x1000, NCS, NOSLEEP)`, and only then `va2000_present()`, which reads the
firmware version *through the returned KVA*. In this build there is no physical fallback:
`va2000_regs[]` is set by `dev_kvmap` or not at all. So a successful open is the proof.

```
dd if=/dev/va2000 of=/tmp/va2reg.bin bs=512 count=1
1+0 records in
1+0 records out
```

That single command also exercised the second new path: under `VA2000_KVA` the character
`read`/`write` route maps a bounded temporary window per chunk and releases it again.

**3. The bytes are right, and they are not a coincidence.** Predicted: the first 16-bit word is
the firmware version, 90 = `0x005a` for 1.9.0.

```
0000000 005a 005a 005a 005a 005a 005a 005a 005a
*
0000040 005a 005a 005a 005a 0000 0000 005a 005a
0000060 005a 005a 005a 005a 00f8 0000 005a 005a
```

Most offsets return the firmware byte, which is what the board does for register reads. Two do
not, and both are meaningful:

| offset | value | meaning |
|---|---|---|
| `0x28`, `0x2a` | `0000` | `VA2_BLIT_RGB16`, `VA2_BLIT_ENABLE` — the blitter is idle |
| `0x38` | `00f8` | `VA2_PAN_HI` — exactly what `va2_restore_passthrough()` writes on last close |

So a value the driver itself wrote through the kernel mapping is read back through it. That is a
round trip, not a bus that happens to answer.

**4. The teardown works, stressed 64 times.** Reading the whole aperture forces 64 consecutive
`dev_kvmap`/`dev_kvunmap` cycles at 64 KiB each. If `sptfree` were not returning the slots, 1024
pages would consume the entire 4 MiB `kvseg` arena.

```
dd if=/dev/va2000 of=/dev/null bs=4096 count=1024
1024+0 records in
1024+0 records out
```

**5. The aperture bound is applied.** Predicted: a request past the aperture stops at 4 MiB.

```
dd if=/dev/va2000 of=/dev/null bs=4096 count=1030
dd: read error: No such device or address
1024+0 records in
```

`No such device or address` is `ENXIO`, from `va2000rdwr`'s offset check against
`va2000_size[dev]`.

**6. The machine is healthy afterwards.** `uptime`: 32 minutes, load average 0.00.

## What this does NOT establish — kept deliberately

* **AutoConfig size versus the fallback constant is not discriminated here.** `va2000_size[0]` is
  demonstrably `0x400000`, but in Zorro II the AutoConfig size and the fallback `VA2000_HWLEN` are
  the *same number*, so this run cannot say which produced it. Zorro III discriminates it for
  free: AutoConfig will say 32 MB and the fallback would say 4 MB.
* **"The processor honours the NCS class" is not proven, only supported.** The class was verified
  structurally on the emulator (leaf PTE `0x00EB0041` for a probe mapping: PFN, `CM` bits 6:5 =
  `10`, V set). Here the register values are correct and self-consistent, which is what a genuinely
  uncached MMIO mapping should give — but reading correct values does not by itself exclude a
  cached mapping that happened to be coherent.
* **X11 on the VA2000 has not been run on this image**, and neither has `busbench`. Both belong to
  the same session and need the display; `busbench` writes garbage to the framebuffer by design, so
  it must not run while X is up. The Zorro II baseline it has to match is 3.09 / 2.95 / 3.08 MB/s
  (`docs/Z3-BUSBENCH-Z2-MEASUREMENT-260810.md`).
* **`/lszorro` was tried and rejected as an instrument**, not used as evidence: it looks for
  `bootinfo.autocon[]` at an address pinned against a different kernel image, and against this one
  it returned 18 mostly-nonsense entries. A stale address does not fail, it returns something
  plausible — the reason this project reads the magic word first.

## Bearing on Zorro III

Every mechanism the Zorro III work depends on has now run on silicon **except** the one that
cannot be tested without the firmware change: that `sptalloc` + a CM-only fixup produces a working
kernel window for a board the CPU cannot reach transparently. In Zorro II the board *is* reachable
transparently, so this run proves the machinery rather than the necessity. The necessity was
already established by the 2026-07-28 single-variable A/B on the Piccolo.

Still ahead, in order: the framebuffer cache class in `Lcm_sel` (change D), a user-root leaf walker
so that change can be verified structurally at all, the NC-to-NCS ordering question, and only then
the firmware move.
