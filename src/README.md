# Prototypes

First actual code changes for the 68040/060 port. Each is validated as far as it can be
without running the kernel; real testing is on fs-uae / the A3000.

## `copyit.s` — CPU-class-aware MMU disable (Phase 1.1)

Drop-in replacement for `unix_boot/src/copyit.s` (and the model for the in-kernel
`sys/amiga/kernel/servant.s` reboot path). Fixes the **first 040/060 bring-up blocker**:
the stock `copyit.s` disables the MMU with unguarded 68030 `pmove tc/crp/srp`, which is
illegal on the 040/060 and traps before the kernel runs (see `../boot-path-map.md` 0c).

### What it does
- Branches on `SysBase->AttnFlags`: AFB_68040 (bit 3) / AFB_68060 (bit 7) → `movec` path;
  otherwise the original 68030 `pmove` path (unchanged, still default/safe on 030).
- 040/060 MMU-off: `movec #0,%tc` (clears TCR.E) + clear `ITT0/1`,`DTT0/1` + `pflusha`.
- After the copy, 040/060 do `cpusha bc` so the freshly copied kernel text is coherent
  before the `jmp` (split copyback caches, no auto coherency).

### Validation done
- Opcodes for `movec %d0,%tc/itt0/itt1/dtt0/dtt1`, `pflusha`, `cpusha bc` verified by
  assembling with `m68k-linux-gnu-as -m68040` **and** `-m68060` (identical encodings).
- Whole file assembles clean; disassembly confirms the dispatch + all ops decode right.
- The cleaner `movel ABSEXECBASE,a1 ; btst #n,a1@(0x129)` idiom is *more* portable than
  the stock `btst #2,(ABSEXECBASE)@(0x129)` (which even fails on modern gas).

### Build
MIT-syntax assembly (bare register names), like the original. Use whichever assembler
builds `unix_boot`:
```sh
# AMIX cross-toolchain (binutils 2.8.1, MIT syntax native):
m68k-cbm-sysv4-as -m68030 -o copyit.o copyit.s
# or modern binutils (needs the MIT-compat flag):
m68k-linux-gnu-as -m68030 --register-prefix-optional -o copyit.o copyit.s
```
Assemble with `-m68030` (the `pmove` ops are valid there; the 040/060 ops are emitted as
`.word`, so one object serves all three CPUs).

### Test (on fs-uae, then A3000)
1. Build `unix_boot` with this `copyit.s` in place of the stock one.
2. Run it under **68040** emulation booting the **unmodified** `unix`.
3. **Expected result:** the machine now gets *past* the copyit MMU-disable and reaches
   the kernel entry `_start`, then crashes deeper — at the next 030-only instruction
   (`_start`'s `pflusha` @0x38, or `pstart`'s `pmove`). That is success for this step:
   blocker #1 cleared, blocker #2 exposed. Capture where it dies (PC / on-screen alert).

### Known risk to confirm on hardware
Cache coherency around the MMU-off window: the kernel image was loaded under AmigaOS
copyback caching. The 040 cache is physically tagged so reads should still hit dirty
lines after MMU-off, and `cpusha bc` before `jmp` pushes/invalidates — but this is the
kind of thing that behaves subtly differently on real silicon than in emulation. If the
copied kernel looks corrupt on real hardware, add a `cpusha bc` at routine entry too.
