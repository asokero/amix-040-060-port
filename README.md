# AMIX 68040/68060 Port

*Amiga UNIX (AMIX) on the 68040 and 68060.*

**This is not a kernel. It is a patch and override layer for the one you already own.**

Amiga UNIX — Commodore's 1991 System V Release 4 for the Amiga 3000 — runs only on a 68030. This
project makes it run on a **68040** and a **68060**, from a single image, and it does so by
patching the stock kernel binary rather than by rebuilding it from sources nobody has.

You supply your own licensed AMIX 2.1c installation. Nothing here is redistributable Commodore or
AT&T material, and no kernel binary is published: what this repository holds is 69 override units,
43 byte-patch scripts, the build system that applies them, and the measurement record of what each
one fixed.

## Disclaimer

Hobbyist work on a 34-year-old proprietary operating system. Not affiliated with Commodore, AT&T,
Hyperion or anyone else. Not supported. **Not for production use** — this is a technical exercise
and a preservation project, and it can leave a machine unbootable. Keep your original kernel.

## Status

Both CPUs are hardware-accepted on the same image, on an Amiga 3000:

| | 68040 | 68060 |
|---|:--:|:--:|
| boot to multiuser, native userland | ✅ | ✅ |
| MMU / HAT, fork + COW, context switch | ✅ | ✅ |
| data cache in **copyback**, DMA coherence | ✅ | ✅ |
| swap, UFS, NFS, exec | ✅ | ✅ |
| per-page `mprotect` (XPAGE) | ✅ | ✅ |
| write-back fault propagation | ✅ | — (no write-backs on 060) |
| Motorola FPSP | ✅ 040 package | ✅ full 060 package, all six enabled IEEE classes bit-exact |
| 64-bit integer emulation (vector 61) | — (in hardware) | ✅ measured subset |
| RTG graphics + X11 + games | ✅ | ✅ |

Measured, not asserted: every claim above has an acceptance document in `docs/` naming the kernel
build, the instrument and the numbers.

### Three accelerator configurations, not two

The 68040 column is two physically different cards, which matters more than it sounds: they place
the kernel in different memory and were accepted at different times.

| Accelerator | CPU | Clock | Memory the kernel binds into | What it established |
|---|---|---|---|---|
| **Mercury** | 68040 | 35 MHz | its own RAM at `0x08000000` | every 68040 acceptance from 2026-07-27 to 2026-08-02 — the bulk of the 040 record |
| **Mercury** | 68060 | 66 MHz | its own RAM at `0x08000000` | every 68060 acceptance since 2026-08-05; same card, CPU swapped through an adapter |
| **A3640** | 68040 | 25 MHz | **A3000 motherboard fast RAM at `0x07000000`** — the card has no RAM of its own | 2026-08-13: ISSUE-42 closed on silicon, plus battery, burst suite, RTG/X11/wolf3d and Dhrystone |

The A3640 run was the first time this port had ever executed with the kernel bound outside
`0x08000000`, which moves every counter address by −16 MiB and is why `tools/status-facts.sh`
takes a load base. It is also the configuration in which the folklore "AMIX is limited to 16 MB"
is literally true *of the machine* — a property of a card with no local RAM, not of AMIX.

The Mercury's 68040 clock is **35 MHz**, from a 70 MHz oscillator at half clock. Every document in
this project written before 2026-08-13 says 33; those are wrong, and one performance conclusion
had to be withdrawn because of it (`STATUS.md` §7).

### Known issues

Two intermittent 68040 faults are captured but not attributed (`ISSUE-9`, `ISSUE-10`); neither
blocks normal use, both block a confident "finished". Three code paths have never executed
anywhere and are marked as such rather than assumed correct. Full list, with what is proven on
which silicon: **[`STATUS.md`](STATUS.md)**.

### Not supported

68LC060 (untested — the FPU-absent path was never implemented), memory above the region the kernel
is loaded into (analysed, declined), and the Zorro III device aperture (measured limitation).

## Hardware requirements

* Amiga 3000 (or A2500/A4000-class hardware AMIX supports) with a 68040 or 68060 accelerator
* **SetPatch before booting on a 68060** — a precondition, not an optimisation
* the patched loader, `unix_boot040`, from the companion project **`amix-unix-boot`** (tag
  `v1.0-040-060`) — which patches Markus Wild's `unix_boot`, Aminet `misc/unix/unix_boot`
* your own AMIX SVR4 2.1c installation

Tested accelerators: **Mercury with a 68040 (35 MHz)**, **Mercury with a 68060 (66 MHz)** and
**A3640 (68040, 25 MHz, no local RAM — the kernel binds into motherboard memory)**. See the table
above for what each one established.

## Quick start

```sh
cp config.sh.example config.sh    # point it at your toolchains and your AMIX install
$EDITOR config.sh
sh tools/check-env.sh             # verifies every dependency, and your kernel's sha256
sh relink-040.sh                  # -> build/unix-040
```

Then on the Amiga, having copied the image to your AmigaOS volume:

```
unix_boot040 unix-040
```

Full instructions, including the toolchains and how the override mechanism works:
**[`BUILDING.md`](BUILDING.md)**.

## Files

| path | what |
|---|---|
| `relink-040.sh` | the build — assembles the override units, rebinds symbols, byte-patches, validates |
| `relink-040-*.sh` | variants: debug probes, serial mirror, and the RTG graphics kernels |
| `src/*.s` | the override units: MMU/HAT, fault resolvers, cache and DMA, FPSP/ISP glue, FP context — [`src/README.md`](src/README.md) explains the two mechanisms and the rules |
| `src/patch_*.py` | byte-patchers for what a symbol override cannot express |
| `tools/` | `check-env.sh`, `status-facts.sh` (generates counter addresses), `verify-stock.sh`, `config-load.sh` |
| `test-tools/` | the instruments — `protfault`, `fpenab060`, `fp060probe`, `isp61ea`, `kpeek`, the battery |
| `docs/` | acceptance records, contracts, audits and findings — the evidence behind the table above; [`docs/contracts/INDEX.md`](docs/contracts/INDEX.md) maps source units to their normative contracts |
| `docs/archive/` | session prompts, run-lists and task briefs: working notes, kept deliberately |
| `STATUS.md` | canonical status: what is proven, on which platform, with links to the evidence |
| `KNOWN-ISSUES.md` | 45 issues, chronological, corrections in place |

## Documentation

* **[`STATUS.md`](STATUS.md)** — the canonical picture. When any other document disagrees with it,
  it is right and the other one is history.
* **[`BUILDING.md`](BUILDING.md)** — dependencies, build, verification, and how the port works.
* **[`KNOWN-ISSUES.md`](KNOWN-ISSUES.md)** — every defect found, including the ones that turned out
  not to be defects, and the reasoning that was wrong.
* **[`docs/METHOD.md`](docs/METHOD.md)** — how the work was done: instruments before fixes,
  pre-registered expectations, the invariants that caught what passing tests could not, and an
  honest account of what the AI assistance did and did not do.
* **[`docs/contracts/INDEX.md`](docs/contracts/INDEX.md)** — the 34 static contracts cited by the
  implementation, with their original analysis names and source consumers.

The record deliberately keeps the failures: pre-registered expectations that did not happen, fixes
reverted within the hour, a clock figure that was wrong for months and deleted one finding while
creating a better one. A reader who cannot see the wrong turns cannot judge the right ones.

## Related projects

| Repository | What |
|---|---|
| `amix-unix-boot` | the patched AmigaOS bootstrap — **required** to boot any kernel built here |
| `va2000-amix` | MNT VA2000 RTG driver |
| `xrtg-amix` | Xsvga / X11 for Piccolo and Picasso II |
| [`gcc-cross-amix`](https://github.com/isoriano1968/gcc-cross-amix) | the `m68k-cbm-sysv4` cross toolchain this build needs |

## License

New code and modifications: **MIT** — see `LICENSE`.

No Commodore or AT&T material is distributed here. The Motorola 68040/68060 support packages are
fetched from a NetBSD source tarball at build time and retain their own terms; some algorithms are
derived from NetBSD's m68k support, which is BSD-licensed. See `NOTICE`.

-Antti Sokero 2026
