# MMU translation format: 68030 (current AMIX) → 68040/060 (target)

The Phase 1.3 spec. Derived by disassembling `pstart` (`0xd44`–`0x1016`) and decoding
`tc_on`. This is the exact 68030 page-table format AMIX builds, and what it must become
on the 68040/060. Everything in the “current” column is verified from `stand/unix`.

---

## 1. Current 68030 setup (as built by `pstart`)

### 1.1 Translation Control register — `tc_on = 0x82B02D60`
```
E   = 1      MMU enabled
SRE = 1      separate supervisor root pointer (SRP) used
FCL = 0      no function-code lookup
PS  = 0xB    page size = 2^11 = 2 KB
IS  = 0      initial shift = 0 (full 32-bit VA used)
TIA = 2      level-A index = 2 bits  -> root table has 2^2 = 4 entries
TIB = 13     level-B index = 13 bits -> 8192 entries
TIC = 6      level-C index = 6 bits  -> 64 entries
TID = 0      level-D unused
            check: 0(IS)+2+13+6+0+11(PS) = 32 ✓   => THREE-level walk
```
VA breakdown (32 bits):  `[31:30]=A(2)  [29:17]=B(13)  [16:11]=C(6)  [10:0]=page(2 KB)`

### 1.2 Descriptors — **long format, 8 bytes each**
`pstart` builds every descriptor as 8 bytes (stride 8: offsets 0,8,16,24…) with bit-field
writes at byte +2/+3 of the first long, and the table/page address in the second long:
```
long 0:  [ limit (16b) | status bits | DT(2b) ]    DT at byte+3 bits6-7  (m68k bf numbering)
long 1:  [ table-or-page physical address ]        (e.g. movel #0x80000000, a0@(4))
```
`DT` (descriptor type, low 2 bits of long 0): `0`=invalid, `1`=page (early-terminating),
`2`=valid 4-byte table, `3`=valid 8-byte (long) table. Status field written via
`bfins #imm, a0@(2),6,8`: `0xC0` = normal memory, `0xD0` = **cache-inhibited** (the
0x80000000 / 0xC0000000 I/O regions). `limit` word `0x7FFF` = no limit.

### 1.3 The actual tree `pstart` constructs
* **Root pointers** `cpuroot` / `userroot` (8 B, identical): limit `0x7FFF`, DT=3 →
  point at the level-A table. Loaded via `pmove cpuroot,%srp`; the user root is the
  per-process A-table root.
* **Level-A table = 4 entries** (matches TIA=2), built at temp-table offsets 0/8/16/24:
  - entry 0: DT=1, status `0xC0` — early-terminating map of low space
  - entry 1: DT=3, addr = `st_top1` (the B/C page table), limit `0x04FF`, status `0xC0`
  - entry 2: DT=1, addr = `0x80000000`, status `0xD0` (CI) — I/O transparent region
  - entry 3: DT=1, addr = `0xC0000000`, status `0xD0` (CI) — I/O transparent region
* **Page table `st_top1`**: `bzero`’d, then a loop writes page descriptors
  `pte = (pageaddr rounded to 2 KB) | 1` (DT=1) — see the `kuptr` u-area mapping loop at
  `0xf62`.
* **u-area indexing**: `idx = (u >> 17) & 0x1FFF` (B-field of VA `u=0x40000000`),
  `entry = st_top1 + idx*8`, DT=2 (valid 4-byte sub-table), status `0x40`.

### 1.4 Instructions used (all illegal on 040/060)
`pmove %a0@,%srp` · `pmove tc_on,%tc` · `pflusha` (encoding `f000 2400`).

### 1.5 CONFIRMED: the binary-only HAT layer uses the identical format
Disassembly of `hat_pteload` (`0xb4d64`) and `hat_asload` (`0xb7444`) shows the runtime
page-table code extracts the VA fields and builds descriptors **exactly** as `pstart`:

```
hat_pteload VA decode:   A = va>>30 & 0x3      (2b, TIA=2)   -> *8  (8-byte table desc)
                         B = va>>17 & 0x1FFF   (13b, TIB=13) -> *8  (8-byte table desc)
                         C = va>>11 & 0x3F     (6b,  TIC=6)  -> *4  (4-byte LEAF PTE)
  leaf PTE:  bfextu @,0,21  -> 21-bit PFN (upper 21b; low 11b = status+DT, 2 KB page)
  DT field:  bfins/bfextu @(3),6,2            (same byte+3 bits6-7 as pstart)
  status:    bfins #0xC0, @(2),6,8            (same 0xC0 as pstart; 0x00 if CI requested)
  table limit: movew #63, @  (64 = 2^TIC entries)
hat_asload:  svirtophys(seg table top) -> userroot+4 ; pmove userroot,%crp ; pflusha
```
**Key nuance:** table descriptors (A,B levels) are **8-byte long format**; the **leaf
page descriptors (C level) are 4-byte short format** with a 21-bit PFN. On the 040/060
*all* descriptors are 4 bytes, so the table levels shrink 8→4 B and the leaf PFN widens
to fit 4 KB pages (20-bit PFN).

**Conclusion:** `pstart`, `hat_pteload`, `hat_map`, `hat_exec`, `hat_asload`,
`hat_unload`, `hat_chgprot` all speak the same 030 format. The 040 rewrite
(4-byte descriptors, 7/7/6 tree, 4 KB) is therefore **uniform** across all of them —
one format change, applied consistently, not a per-function puzzle.

---

## 2. Target 68040 / 68060 format

The 040/060 MMU is **not configurable** the way the 030 is. Key differences:

| Property | 68030 (now) | 68040 / 68060 (target) |
|----------|-------------|------------------------|
| Page size | **2 KB** (PS=0xB) | **4 KB or 8 KB only** (TC bit P) — 2 KB impossible |
| Tree shape | configurable 2/13/6 (3-level) | **fixed** 7/7/6 (4 KB) or 7/7/5 (8 KB), 3-level |
| Descriptor size | 8 bytes (long format) | **4 bytes** |
| Levels | Root → A → (B/C) tables | Root → Pointer → Page tables (URP/SRP based) |
| Root load | `pmove desc,%srp` (8-byte desc) | `movec Aroot,%srp` / `%urp` (32-bit phys addr) |
| TC load | `pmove val,%tc` | `movec val,%tc` (different layout: only E + P bits) |
| Cache control | CI bit in descriptor status | **CM 2-bit field** per page (WT/CB/NC-ser/NC) |
| Prot/status bits | WP/U/M in long-format positions | U/M/W/S/CM/UR fields in 4-byte PTE layout |
| ATC flush | `pflusha` (`f000 2400`) | `pflusha` (different encoding) / `pflush` |
| Probe | `ptestr/ptestw` + `pmove %psr` | `ptestr/ptestw` (040) / **gone on 060** (SW walk) |

### 2.1 68040 TC register
Only two meaningful bits: `E` (enable, bit 15) and `P` (page size: 0=4 KB, 1=8 KB, bit 14).
No PS/TI/IS fields — the tree geometry is implied by `P`. So `tc_on` (0x82B02D60)
becomes `0x8000` (4 KB) or `0xC000` (8 KB).

### 2.2 68040 4 KB address breakdown (fixed)
`[31:25]=root idx(7)  [24:18]=pointer idx(7)  [17:12]=page idx(6)  [11:0]=offset(4 KB)`
Root table = 2^7 = 128 entries of 4 bytes = 512 B (must be 512-byte aligned).
(8 KB: page idx = 5 bits, offset 13 bits.)

### 2.3 68040 descriptor (4 bytes)
- Table descriptors (root/pointer): `[ table addr (upper bits) | U | W | UDT(2) ]`,
  UDT (bits 1-0): 0=invalid, 1=resident… ; tables must be 512/256-byte aligned.
- Page descriptor: `[ phys page addr | UR | G | U1U0 | S | CM(2) | M | U | W | PDT(2) ]`.
  **CM** (bits 6-5) selects cache mode: `00`=writethrough, `01`=copyback,
  `10`=noncacheable serialized, `11`=noncacheable — this replaces the 030 CI bit
  (the 0xD0 I/O regions become CM=`10`/`11`).

---

## 3. Translation work implied (Phase 1.3 + Phase 2.5)

1. **`tc_on`**: `0x82B02D60` → `0x8000` (4 KB) and switch `pmove %tc` → `movec %tc`.
2. **Root pointers**: build a 512-byte-aligned 128-entry root table; load its *physical
   address* via `movec …,%srp` and `%urp` (drop the 8-byte root *descriptor* entirely —
   040 roots are bare addresses, not descriptors).
3. **Descriptor builder rewrite**: every `bfins/bfclr` sequence in `pstart` (and in the
   binary-only `hat_pteload`/`hat_map`/`hat_exec`/`hat_asload`) must emit **4-byte 040
   descriptors** with the new field positions, not 8-byte long-format ones.
4. **Tree geometry**: 2/13/6 → fixed 7/7/6. The level-A “4 entries” logic and the
   `(u>>17)&0x1FFF` B-index math change to 040 shifts (`>>25`, `>>18 & 0x7F`, …).
5. **Page size everywhere**: `>>11`/`+2047` (2 KB) → `>>12`/`+4095` (4 KB) at the ~176/451
   sites; `hat_getkpfnum` `lsrl #11` → `lsrl #12`.
6. **Cache mode**: the `0xD0` (CI) I/O regions → CM field `10`/`11`; normal RAM → `01`
   (copyback) only *after* DMA coherency is in, else `00` (writethrough) for bring-up.
7. **Instructions**: `pflusha` re-encode; `pmove %psr`/`ptestr` fault path → 040 form
   (and a software table walk for 060).

### Decision locked in by this analysis
Go **4 KB** pages (not 8 KB): the existing tree is already 3-level and 4 KB maps cleanly
to the fixed 7/7/6 walk with the least wasted memory; 8 KB only helps if table memory
becomes a problem, which 32 MB makes unlikely.

### Reference
NetBSD `sys/arch/m68k/m68k/pmap_motorola.c` + `sys/arch/m68k/include/pte.h` implement
exactly this 030-long-format ↔ 040-4-byte split and are the cleanest model to follow.
