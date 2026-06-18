# Phase 3 — HAT / VM layer 68040 port: work list

Status: **NEXT BLOCKER, confirmed 2026-06-18.** Draft 2 (`pstart040.s`) got the
kernel past `pstart` through `vstart`/`mlsetup` into early init + display setup
(the u-area bus error is gone).  It then **hangs in `k_trap` (recursive trap)** —
the kernel's VM/HAT layer executes **68030 PMMU instructions that are illegal on
the 68040**, so the first VM op in early init traps, and the trap handler faults
again → infinite loop (PC stuck at `k_trap+2`, blitter left pending).

This is the design doc's predicted "page-size ripple / HAT" blocker
(`pstart-040-design.md` §5).  It is the **main body of the 040 port** — bigger
than pstart, because it's not only an instruction swap but a page-table FORMAT
change (030 3-level 2KB long-descriptors → 040 3-level 4KB 4-byte-descriptors).

## Inventory: every 030 PMMU instruction (18 sites, 10 functions)
(from `m68k-linux-gnu-objdump -d -m m68k:68030 build/unix-040`; excludes the dead
`pstart_030`.)

| Function    | off    | 030 instruction          | role |
|-------------|--------|--------------------------|------|
| `_start`    | 0x38   | `pflusha` (f000 2400)    | kernel entry TLB flush |
| `resume`    | 0xb2   | `pflusha`                | scheduler resume |
| `ptest`     | 0x3ac  | `ptestr #1,%a0@,7`       | page-table probe |
| `ptest`     | 0x3b0  | `pmove %psr,%sp@(4)`     | read MMU status |
| `ptest0`    | 0x3c4  | `ptestr #1,%a0@,0`       | page-table probe |
| `ptest0`    | 0x3c8  | `pmove %psr,%sp@(4)`     | read MMU status |
| `nomsg`     | 0x18ed8| `pmove %a0@,%tc`         | (alt MMU enable path) |
| `nomsg`     | 0x18ee2| `pmove %a0@,%crp`        | |
| `nomsg`     | 0x18ee6| `pmove %a0@,%srp`        | |
| `hat_map`   | 0xb58c6| `pmove %a1@,%crp`        | HAT: load addr-space root |
| `hat_map`   | 0xb58ca| `pflusha`                | |
| `hat_exec`  | 0xb70ea| `pmove %a1@,%crp`        | HAT exec |
| `hat_exec`  | 0xb70ee| `pflusha`                | |
| `hat_asload`| 0xb7472| `pmove %a1@,%crp`        | HAT address-space load |
| `hat_asload`| 0xb7476| `pflusha`                | |
| `flushmmu`  | 0xb78d0| `pflusha`                | TLB flush |
| `swtch`     | 0xb923c| `pmove %a1@,%crp`        | context switch: load root |
| `swtch`     | 0xb9240| `pflusha`                | |

## Per-instruction 040 translation
1. **`pflusha`** 030 `f000 2400` (4 B) → 040 `f518` + `nop`(`4e71`) (4 B).
   Clean same-size in-place swap.  (8 sites.)
2. **`pmove %psr,<ea>`** (ptest result) `f02f 6200 ...` → 040 reads MMU status
   differently; the 040 `ptestr`/`ptestw` set the SR CCR + write the result via
   the 040 MMUSR/`movec`.  Needs a small rewrite (ptest/ptest0).
3. **`ptestr #1,%a0@,N`** `f010 9e11` → 040 `ptestr (%a0)` (different encoding,
   uses current SFC/DFC) OR a software table walk.  (2 sites.)
4. **`pmove %a1@,%crp`** `f011 4c00` (load 8-byte CPU root) → 040 `movec Dn,%urp`
   (+`%srp`), 4-byte root.  Requires loading the 4-byte phys root from the
   descriptor first → NOT a same-size swap; needs extra instructions / a thunk.
   (4 sites: hat_map/hat_exec/hat_asload/swtch.)
5. **`pmove %a0@,%tc/%crp/%srp`** (nomsg) → same as pstart040's 040 enable.

## The harder half — page-table FORMAT
The instruction swap is necessary but NOT sufficient.  The descriptors these
instructions load/point at are **030 long-format 2KB-page tables**.  A 68040
table walker reads **4-byte descriptors / 4KB pages / fixed 7/7/6 split**.  So
everywhere the kernel BUILDS or WALKS page tables (the HAT layer, `ptest`, the
PTE macros — `>>11`, `& 2047`, segment/page table strides) must move to 4KB/040
format.  This is the "2KB→4KB ripple".  `pstart040` already builds an 040 tree
for the bootstrap u-area; the HAT must do the same for every mapping.

## Strategy options (to decide)
- **A. Relink-replace each HAT function** (like pstart040): transcribe verbatim,
  swap the MMU section + page-table math, relink.  Clean but ~10 functions.
- **B. In-place byte-patch** the same-size cases (pflusha) + relink-replace the
  format-sensitive ones (hat_map/swtch/ptest).
- ~~**C. Source-level**~~: NOT available — checked `amix-sources.tar` (157 .c/.s
  under sys/); it has NO hat.c / vm_machdep / mmu / locore.  The HAT/VM machdep
  layer is binary-only (like `pstart` was).  So we must transcribe+relink (A/B).

NOTE the kernel reached early init, so the FIRST offending call is likely
`flushmmu` or a `hat_*`/`swtch` from `mlsetup`.  Patching just `pflusha` won't
reach multiuser (the `pmove %crp` sites still trap) but may advance the hang
point and is a cheap probe.
