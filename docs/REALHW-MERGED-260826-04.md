# Hardware acceptance: `68060-260826-04` — 2026-08-26

The merged tree plus the A3091 `badhardware` interposer. Six of the seven steps are complete;
the burst is deliberately deferred and the graphics step belongs to a different artifact.

**Artifact** `build/unix-040`, sha256 `5cf0590a895f5f082dbb3e4dc2decd186d02f1eac6c6a1d2d54efea4e0845258`
**Loader identity** `image checksum = 9d569aa8 (277543 longs)` — printed on every boot, identical
on all three boots of this session, so every one of them loaded this image.

## Why the loader's checksum is the identity and the banner is not

The kernel is loaded from an AmigaOS partition AMIX does not mount, so the booted file's sha256
cannot be recomputed from inside the running system. The banner reports the **CPU**: two
different kernels both print `68060-260826-04`. The loader's checksum is computed over the image
it actually loaded and differs when the image does — and it reaches the serial log even from a
kernel that is otherwise silent there.

Reproducing it on the host was attempted and abandoned. The algorithm is in `unix_boot.c`
(wrapping 32-bit adds over `ci_size >> 2` longs) but it runs **after** relocation and after the
loader's own pokes; applying the relocations and `cputype = 60` matched the long count exactly
and the sum not at all. The half-finished tool was deleted rather than committed — a tool that
prints a loader-shaped number that is not the loader's number would eventually be compared
against one. Recording the value from an accepted boot and comparing later boots needs no
computation and works today.

## Results

| step | result |
|---|---|
| 1 host gates, second build, byte diff | ✅ `TOTAL complaints: 0`, `bindings failing: 0`, **one differing byte** (build-id) |
| 2 identity + magics | ✅ **31/31** — one more block than `-02`, because the interposer brought `a3d` |
| 3 battery | **11/12** — the miss is ISSUE-49, unchanged from `-02` and from `68060-260819-13` |
| 4 CPU-specific | ✅ (on `-02`, same code paths) `fp060probe bad=0`, `isp61ea bad=0`, `fputest060 fork`, Motorola `unimp` + `main` 4/4 |
| 5 device/graphics | **n/a** — this is the base kernel; the VA2000 variant is a separate artifact |
| 6 burst | ⏳ deferred to a supervised session |
| 7 **power cut** | ✅ **6/6 byte-exact** |

### The power cut

Written at `up 54 mins`, verified at `up 1 min`, same kernel both times — the script's own
precondition, checked before running rather than after.

    b2rt-f1 … f6   CLASS=V0_COMPLETE_MATCH   size=4194304   crc=50250
    B2RT-RESULT PASS (6 files, every byte intact)

`b2verify` was rebuilt from source in the booted system rather than reusing the copy an earlier
session left in `/b2dt` (dated three days earlier). `/tmp` is cleared at boot, which is the point
of keeping the evidence in `/b2dt` and the reason the binary had to be rebuilt.

### fsck, twice, and what it does and does not say

Two dirty boots this session: one after the wedge-and-power-off of 2026-08-25, one after this
deliberate cut. Both ran `fsck` and **neither asked anything**.

That means no inconsistency needed human judgement. It does **not** mean nothing was repaired:
the boot scripts run `fsck` in preen mode, which fixes benign cases silently and stops only for
the rest. Neither run's output was captured — the base kernel is silent on serial, so `fsck`
reaches the screen only, and both times it scrolled past before it could be photographed.

**That is a real gap in this procedure and it is not the operator's fault.** If `fsck`'s verdict
matters — and after a power cut it does — the run needs a kernel that mirrors console output to
serial, or a post-boot read of the filesystem's clean flag. Neither was arranged. Recorded here
rather than glossed, because "fsck passed" is exactly the sort of claim that hardens into fact.

## The interposer, on hardware

`a3d_magic` reads `41334421` and `a3d_ran` reads `00000000` after a full battery: the block is
where the tooling says it is, and the body has never run. That split exists because the first
draft had one magic written only when the body ran, which would have made an all-zero block
indistinguishable from a wrong address — for an instrument expected to read zero for its whole
life, the only distinction that matters.

It is now in place for the burst, which is the next thing to run and the best guess at what
provokes the wedge.
