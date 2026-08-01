# Model-B headers — correct-by-default page geometry for compiled-in C (2026-08-01)

Makes correct-by-default what has been correct-by-patcher: everything compiled into this 68040
kernel now sees a 4 KiB page. Files: `include-modelb/sys/{immu.h,param.h}`,
`prototypes/mk_modelb_sysroot.sh`, `prototypes/modelb_geom_probe.c`,
`prototypes/check_page_geometry.sh`.

## The trap, and why a plain `-I` never fixed it

The toolchain's gcc wrapper (`~/opt/amix-cross/bin/m68k-cbm-sysv4-gcc`, line 13) prepends

```sh
common_cflags=(-I"$sysroot/usr/include")
```

to **every** compile, *before* any user `-I`. So the
`-I.../vanilla/usr/include` that has been sitting in `AMIX_KERNEL_CFLAGS` all along has never
supplied `<sys/immu.h>` or `<sys/param.h>` — the sysroot copies win, and both say the page is
2 KiB. That is the trap recorded as `amix-crosscompile-headers-2kib-trap`, now located exactly.

The wrapper *does* honour `AMIX_SYSROOT`, so the override is a **mirror sysroot**:
`prototypes/mk_modelb_sysroot.sh` builds `build/sysroot-modelb` as a symlink mirror of the real
one, with `sys/immu.h` and `sys/param.h` replaced by the Model-B versions and the originals kept
reachable as `sys/immu_stock.h` / `sys/param_stock.h`. Nothing in the real sysroot is touched.

## What changed, and what is deliberately poisoned

`immu.h`: `NBPP` 4096, `PNUMSHFT` 12, `POFFMASK` 0xFFF, `PG_ADDR` 0xFFFFF000, and the
`phystopfn`/`pfntophys`/`kvtopfn`/`pfntokv` family.

`param.h` — **the half the Z3660 analysis missed, and arguably the more dangerous one**:
`PAGESIZE`/`PAGESHIFT`/`PAGEOFFSET`/`PAGEMASK`, the `MMU_PAGE*` set, and `ptob`/`btop`/`btopr`.
A buffer sized with the stock `btopr()` is *half* the pages the kernel will touch, and `btopr` is
far easier to reach for than `phystopfn`.

The 68030 three-level table macros — `PNUMMASK`, `PNDXMASK`, `PGFNMASK`, `pgndx`, `PAGNUM`,
`mkpte`, `svtop`, `ptosv` — are **poisoned**: each expands to `sizeof()` an undeclared struct, so
any use is a compile error naming the macro. Their Model-B values depend on the 040 table shape
that `hat040.s` implements in assembler, they have no audited C consumer today, and a
plausible-looking wrong constant would be far worse than a build failure.

## The instrument is verified, not assumed

`mk_modelb_sysroot.sh` compiles `modelb_geom_probe.c` **twice**: it must compile through the
mirror and must **fail** against the stock sysroot. A probe that passes either way tests nothing.
Every assertion is a negative array size, which this gcc reports as
`size of array '...' is negative` with a line number.

## Proof on the driver that motivated the work

The **same unmodified upstream** `~/kehitys/amix-z3660scsi/src/z3660.c`:

```text
stock sysroot :   9e: 720b  moveq #11,%d1     c6: 720b  moveq #11,%d1
                  a0: e2a8  lsrl  %d1,%d0     c8: e2a8  lsrl  %d1,%d0
mirror sysroot:   9e: 720c  moveq #12,%d1     c6: 720c  moveq #12,%d1
                  a0: e2a8  lsrl  %d1,%d0     c8: e2a8  lsrl  %d1,%d0
```

## What headers cannot do — and the check that covers it anyway

`va2000.c` computes its PFN with a **hardcoded** `(base + offset) >> 11`, not with `phystopfn`.
No header reaches a literal, so `va2000_modelb.py` stays load-bearing. Verified: the va2000
object is **byte-identical** with and without the header set, so this change is inert for the
shipped drivers and only guards new ones.

That split is why the object-level check matters more than either fix:
`prototypes/check_page_geometry.sh` asserts in the **compiled bytes** that no object shifts by 11.

**It found a bug in the existing check while being written.** The version inside
`relink-040-z3660.sh` only matched `lsrl` — but a *signed* `>> 11` compiles to `asrl`, which is
exactly what `va2000.c` emits. The old check reported that object clean. The shared checker
matches both, and `relink-040-z3660.sh` now calls it.

## Wiring

`AMIX_SYSROOT` is exported by `relink-040-va2000.sh`, `relink-040-rtg.sh` and
`relink-040-z3660.sh` before any C compile, each followed by `check_page_geometry.sh` on the
object. Rebuilt `unix-040-rtg` end to end through the new path: clean, `[OK] va2000_040.o:
1 page shift(s), all by 12 (4 KiB)`, reloc validation 0 complaints.

## Staged for hardware exposure

`build/unix-040-rtg-260801` (build id **68040-260801-05**) is the RTG kernel — both graphics
drivers — built on the accepted base **through the mirror sysroot**, reloc validation 0
complaints, `[OK] va2000_040.o: 1 page shift(s), all by 12 (4 KiB)`. It is on the NAS as
`amix/hwtest-260801/unix-040-rtg-260801-05` with `unix_boot040` and `SHA256SUMS-260801.txt`.

Booting it is the one thing this header set still owes: it is *inert* for the shipped drivers
(the va2000 object is byte-identical with and without the override, verified), so the boot is a
no-regression check rather than a test of the geometry — but "inert by construction" and "boots"
are different claims and only one of them has been made.

**Its counter addresses are NOT the base's** — textsize `0xed5b4`, so
`hat_cm_ram` = `0x081058B4`, `codepub_on` = `0x08105FB8`, `i39_magic` = `0x08105FC8`.
Recompute before reading anything, as always.

This is also the precondition recorded for compiling any reconstructed kernel source later:
whatever gets compiled next inherits the right geometry without anyone remembering to ask.
