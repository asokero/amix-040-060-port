# A 68040 kernel carrying the two Z3660 drivers — audit, geometry fix, and the wiring map

2026-07-31. For a test bench where the Z3660's **68040 emulation** is being developed (WinUAE's
040+FPU+MMU core ported into the card), the drivers have to be in the kernel that runs there. This
records what was checked, what was fixed, and exactly where the remaining wiring goes.

Upstream repos are separate projects and are **never modified**: `~/kehitys/amix-z3660scsi`
(PISCSI mailbox SCSI, `z3660queue`) and `~/kehitys/amix-z3660net` (STREAMS/DLPI ethernet `zen0`,
`z3660ethinfo`). Both are proven on a real A4000 + Z3660 against a **68030** kernel.

## 1. They cross-compile for us as they stand

Both build clean with our AMIX SVR4 cross toolchain and the vanilla kernel headers — no source
changes, no missing headers:

```sh
m68k-cbm-sysv4-gcc $AMIX_KERNEL_CFLAGS(-m68040) -I vanilla/usr/sys/amiga/alien -c z3660.c
m68k-cbm-sysv4-gcc ... -c z3660eth.c
```

`rico.h`, `sd.h`, `sys/immu.h`, `sys/dlpi.h`, `sys/stream.h` are all present in the vanilla tree.

## 2. The page-geometry defect — found in the source, then confirmed in the object

Both drivers target a 2 KiB-page kernel, and they say so:

```c
z3660.c    #define BOUNCE_PAGES  32   /* 64KB bounce; Amix NBPP is 2KB, not 4KB! */
z3660eth.h #define ZZ_FRAME_PAGES 64  /* 64 * 2048 = 128 KB */
```

The dangerous one is not the constants but `phystopfn()`, which inlines from the vanilla
`<sys/immu.h>` as `paddr >> PNUMSHFT` with `PNUMSHFT = 11`. **Verified in the compiled object**, not
inferred:

```text
z3660.o    9e:  moveq #11,%d1 / lsrl %d1,%d0     <- sptalloc(regs)
           c6:  moveq #11,%d1 / lsrl %d1,%d0     <- sptalloc(bounce)
```

On a Model-B kernel a PFN is `paddr >> 12`, so an unconverted value maps the page at
`(pa>>11)<<12 = 2*pa` — **the wrong physical page**, silently. It is the same defect already fixed
kernel-side for `scrmmap`/`ammmap`/`timmap`/`svgammap` and for the VA2000 driver, and it is the
`amix-crosscompile-headers-2kib-trap` in its purest form: it compiles, links, boots, and then reads
someone else's memory.

**Fix: `prototypes/z3660_modelb.py`** — same idiom as `va2000_modelb.py`. It copies both sources
into `build/`, overrides `phystopfn` to the 4 KiB shift right after the `immu.h` include, halves the
two page counts so the mapped *byte* sizes stay exactly what the firmware windows are specified in
(64 KB bounce, 128 KB frame window), and asserts every replacement count so upstream drift fails the
build instead of producing a quietly wrong driver. Result, verified the same way:

```text
z3660_040.o     9e: moveq #12   c6: moveq #12        (both phystopfn sites converted)
z3660eth_040.o  78: moveq #12   c4: moveq #12
```

The two remaining `moveq #11` in the objects were checked and are not page math (a SCSI CDB length
compare; a DLPI constant written into a structure).

## 3. Wiring map — every address needed, none of it invented

Our kernel is a relinked binary, so their `amix-kerntools` build hub (which rebuilds a source kernel
and edits generated tables) cannot be used. The equivalents we already own:

**Ethernet — `cdevsw[48].d_str = &z3660ethinfo`.**

```text
cdevsw            @0x9dd4 (.data), entry = 52 bytes
  d_open +0  d_close +4  d_read +8  d_write +12  d_ioctl +16  d_mmap +20
  d_segmap +24  d_poll +28  d_xpoll +32  d_xhalt +36  d_ttys +40  d_str +44  d_flag +48
cdevsw[48]        @0xa794 -- free: +0..+36 all relocate to `nodev`, d_ttys and d_str are NULL
cdevsw[48].d_str  @0xa7c0 -- no relocation at all
```

Because `d_str` carries no relocation, the VA2000/Xsvga trick (retarget an existing one) does not
apply. Cleanest with our mechanisms: **store the pointer at runtime from an init hook** — exactly
what the VA2000 driver already does through its `parinit` wrapper. One store, no ELF surgery.

**SCSI — a fourth `scsicard[]` row.**

```text
scsicard          @0x395c (.data, local symbol), rows of 12 bytes {product, queue, name}
  [0] 0x0202f003  -> a3091queue (0xcf70)  name LC%0
  [1] 0x02020001  -> a2090queue (0xc200)  name LC%1
  [2] 0x02020003  -> a2091queue (0xc714)  name LC%2
consumer          `init` @0xd73a: `lea scsicard,%a3` (reloc @0xd74c), loop bound
                  `moveq #2,%d1; cmpl %a2,%d1` @0xd79e  -- three rows, hardcoded
```

So: build a **four-row table in our own object** (rows 0–2 re-declaring `a3091queue`/`a2090queue`/
`a2091queue` as externs, row 3 = `0x144B0001, z3660queue, "Z3660 SCSI"`), retarget the `lea`
relocation at `0xd74c` to it (the proven `patch_a3091_dma.py` mechanism), and patch the bound
immediate `0x7202 → 0x7203`. Two edits, both of a class this tree has done before.

**The `dd.c` ordering patch is not optional and is not ours yet.** Their repo carries
`src/kernel-patches/dd.c.patch`: in `amiga/alien/dd.c`'s completion path, `startio(FIRST, dp)` must
run **before** `iodone(bp)`, because `iodone`'s callback re-enters `ddstrategy` synchronously and
the old order double-issued the same `&dp->com`. We have `dd.c` only as a binary, so this becomes a
byte patch: locate the `jsr iodone` / `jsr startio` pair in the completion path and swap them.
Worth noting for our own sake — **our A3091 path runs through the same `dd.c` framework**, so this
race is arguably a latent defect in our kernel too, independent of the Z3660.

## 4. What is proven, what is not

Proven here: both drivers compile for our target; the geometry defect is real and now fixed at
source-copy level with object-level verification; every wiring point exists at a known address with
a known mechanism.

Not proven, and not provable on our machine: **anything about the datapath.** There is no Z3660 in
this A3000. What a local boot can show is compile/link/boot/registration and no regression — both
drivers already tolerate an absent board (`autocon()` misses → the queue is never called), so the
kernel is safe to boot here. The rest belongs on the friend's bench.

Also unresolved, and worth him knowing: `z3660.c` uses `BOUNCE_THRESH 0x08000000` — "buffers below
this are bounced by the ARM". That constant encodes where RAM sits. On an A4000 + Z3660 all RAM is
below it, so everything bounces; on a machine whose RAM starts at `0x08000000` (our Mercury A3000)
nothing would bounce, and the direct path would be taken. If his 040 emulation changes the memory
map, this threshold needs a second look.

## 5. Remaining work, in order

1. `relink-040-z3660.sh`: assemble the init hook (streamtab store), build the four-row `scsicard`
   table object, compile both Model-B driver copies, `ld -r` them in, retarget `0xd74c`, patch the
   bound at `0xd79e`, stamp.
2. The `dd.c` `startio`/`iodone` swap as a byte patch, with its own before/after disassembly in the
   commit — and a decision on whether it lands in the base kernel for our own SCSI path.
3. Boot it here with no board present: it must reach login and change nothing (`exectest`, counters).
4. Hand over the image plus a note on what the counters mean, so a failure on his bench can be read
   without our machine.
