# Z3660 driver patches for upstream — make the page counts follow the kernel's page size

Two small patches for the **separate upstream projects** `amix-z3660scsi` and `amix-z3660net`.
Neither repo is modified by anything in this tree; these are diffs to send, nothing more.

```text
0001-z3660-scsi-derive-BOUNCE_PAGES-from-NBPP.patch     src/z3660.c
0001-z3660-eth-derive-ZZ_FRAME_PAGES-from-NBPP.patch    src/z3660eth.h
```

Both apply with `patch -p1` from the repo root.

## What the defect is

`sptalloc()` takes a **page count**, and both drivers hardcode theirs for a 2 KiB-page kernel:

```c
z3660.c     #define BOUNCE_PAGES   32   /* 64KB bounce; Amix NBPP is 2KB, not 4KB! */
z3660eth.h  #define ZZ_FRAME_PAGES 64   /* 64 * 2048 = 128 KB */
```

The comments are honest and correct — the drivers know exactly what they assume. But the numbers
are counts, so on a 4 KiB-page kernel the same source maps **twice the intended window**: 32 pages
becomes 128 KB where the firmware map allocates 64 KB. Nothing warns; the driver just reaches past
its window.

The patches express the window in bytes (which is what the firmware actually fixes) and let the
page count follow `NBPP` from `<sys/immu.h>`:

```c
#define BOUNCE_BYTES  MAXXFER                            /* one max transfer, 64 KB */
#define BOUNCE_PAGES  ((BOUNCE_BYTES + NBPP - 1) / NBPP)

#define ZZ_FRAME_BYTES (ZZ_RX_MAX_SLOTS * ZZ_FRAME_SIZE) /* 128 KB overrun range */
#define ZZ_FRAME_PAGES ((ZZ_FRAME_BYTES + NBPP - 1) / NBPP)
```

Both byte constants are now tied to something that already exists in the driver and means what it
says — the max transfer size, and the ring's overrun range — rather than to a magic number.

## `phystopfn()` needs no patch at all

Worth saying explicitly, because it is the other half of the same trap and it is **not** the
drivers' bug. They call `phystopfn(pa)`, which is entirely page-size agnostic and correct. The
wrong shift is injected by the header:

```c
/usr/include/sys/immu.h:60    #define PNUMSHFT   11
/usr/include/sys/immu.h:353   #define phystopfn(paddr)  ((u_int)(paddr) >> PNUMSHFT)
```

Compile against headers whose `PNUMSHFT` is 12 and the same source emits the right shift. Nothing
to fix in the driver.

## Verified, both ways, in the compiled bytes

The point of this class of bug is that it is invisible in behaviour until it corrupts something, so
the check is on the emitted instructions, not on the source. Patched sources, cross-compiled twice:

| object | headers | shift | pages pushed to `sptalloc` | window mapped |
|---|---|---|---|---|
| `z3660.c` bounce | stock (`NBPP` 2048) | `moveq #11` | `pea 0x20` = 32 | 64 KB |
| `z3660.c` bounce | 4 KiB (`NBPP` 4096) | `moveq #12` | `pea 0x10` = 16 | 64 KB |
| `z3660eth.c` frame | stock | `moveq #11` | `pea 0x40` = 64 | 128 KB |
| `z3660eth.c` frame | 4 KiB | `moveq #12` | `pea 0x20` = 32 | 128 KB |

**The stock column is byte-identical to what the unpatched driver produces today**, so the 68030
kernel it currently runs on is unaffected. One source, two kernels, the same mapped window.

## What the patches deliberately do NOT touch

`ZZ_FRAME_SIZE 2048` in `z3660eth.h` is the ring's **per-slot stride** — a firmware protocol
constant that happens to equal the old page size. Scaling it with the page size would make the
driver read every slot from the wrong offset. It stays 2048, and that is why these patches change
named page *counts* only and never sweep for the literal `2048`.

`ZZ_REGS_PAGES 1` also stays 1: it is "at least one page", not a byte window, and dividing a
sub-page window by `NBPP` would yield zero.

## Two notes for whoever applies them

* The `#ifndef NBPP / #error` guard in the ethernet header exists because `z3660eth.h` uses `NBPP`
  while `z3660eth.c` is what includes `<sys/immu.h>` (line 54, before the header at line 68). If a
  toolchain dislikes `#error`, drop those three lines — the patch works without them.
* If upstream adopts these, this tree's `src/z3660_modelb.py` must be updated: it rewrites
  exactly these constants at build time and **asserts each replacement count**, so an upstream that
  no longer matches will fail the build loudly rather than silently doing nothing. That is the
  intended behaviour, not a bug to work around.
