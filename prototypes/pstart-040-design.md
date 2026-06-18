# Draft 2 — real 040 bootstrap paging in `pstart`: design

Goal: replace `pstart`'s 68030 MMU setup so the 68040 MMU is enabled with a
bootstrap mapping equivalent to the 030 one — specifically so the kernel's
`u`-area (virtual `0x40000000`) is backed by physical RAM and the recursive
bus-error fault (Draft 1's limit) goes away.

## 1. What the 030 `pstart` maps (decoded from disassembly)

030 TC = `0x82B02D60` → E=1, **2 KB pages**, 3-level tree TIA/TIB/TIC = 2/13/6.
VA split: `[31:30]`=root(4), `[29:17]`=B(8192), `[16:11]`=C(64), `[10:0]`=offset.

`pstart` builds (root table `tbl`, 4 × 8-byte long descriptors):

| Root slot | VA range              | 030 descriptor                          | Meaning |
|-----------|-----------------------|-----------------------------------------|---------|
| `[0]`     | `0x00000000-0x3FFFFFFF`| DT=1 early-term, status `0xC0`, addr=0  | **identity, cacheable** (kernel @0x07000000, chip RAM, low I/O) |
| `[1]`     | `0x40000000-0x7FFFFFFF`| DT=3, status `0xC0`, addr=`st_top1`     | **paged** (segment table) — holds the u-area |
| `[2]`     | `0x80000000-0xBFFFFFFF`| DT=1 early-term, status `0xD0`, addr=0x80000000 | **identity, cache-inhibited** (I/O) |
| `[3]`     | `0xC0000000-0xFFFFFFFF`| DT=1 early-term, status `0xD0`, addr=0xC0000000 | **identity, cache-inhibited** (I/O) |

Inside the paged slot `[1]`, only the **u-area** is mapped at bootstrap:
`u = 0x40000000`, 8 KB = 4 × 2 KB pages. `st_top1[0]` (DT=2) → `kuptr`
(4 × 4-byte page descriptors) → 4 physical 2 KB pages at `d3` (allocated just
past the kernel). `cpuroot`==`userroot` (SRP==URP). Globals set:
`cpuroot`(8B SRP desc), `userroot`(8B URP), `st_top1`, `kuptr`, `ublksde`.

`status 0xC0` = bits 7,6 (U + ?) cacheable; `0xD0` = +bit4 cache-inhibit.

## 2. The 040 MMU (target format)

Fixed 3-level tree, **no early termination**, all descriptors **4 bytes**:

    root  : 128 entries (VA[31:25]), 512 B, 512-aligned   -> URP/SRP
    ptr   : 128 entries (VA[24:18]), 512 B, 512-aligned
    page  : 64 entries  (VA[17:12]), 256 B, 256-aligned   (4 KB pages)
    offset: VA[11:0]                                       (4 KB)

TC = **`0x00008000`** (bit15 E=1, bit14 P=0 → 4 KB).  Root pointers loaded with
`movec Dn,%srp` / `movec Dn,%urp` (control regs 0x807 / 0x806), flush `pflusha`
(`0xf518`).  Large 1:1 regions use **Transparent Translation Registers** instead
of page tables.

### Descriptor bit values (authoritative — Linux `motorola_pgtable.h`, MC68040 UM)

Low byte common: bit0 PRESENT(0x01), bit1 = table type(0x02) → UDT/PDT.
- **Table/pointer descriptor** = `next_table_phys & 0xFFFFFF00` `| 0x02` (UDT=resident).
- **Page (leaf) descriptor** = `phys & 0xFFFFF000` `| CM | S | 0x01`(PDT=resident).
  - S (supervisor-only) = `0x080`.
  - W (write-protect)   = `0x004`;  Used `0x008`;  Modified `0x010`.
  - CM (bits 6-5): writethrough `0x00`, copyback `0x20`,
    noncacheable-serialized `0x40`, **noncacheable `0x60`**.

### TTR (ITTx/DTTx) layout
`[31:24]`=addr base, `[23:16]`=addr mask (1=ignore), bit15 E, `[14:13]` S
(`1x`=match both user+super → `0x4000`), bits `[6:5]` CM, bit2 W.

## 3. The 040 bootstrap mapping (Draft 2)

Replicate §1 with TTRs for the identity/I/O regions and a real 040 tree for the
u-area:

| Region | 040 mechanism | Value |
|--------|---------------|-------|
| `0x00000000-0x3FFFFFFF` identity, **code** | `ITT0` cacheable WT | base 0x00, mask 0x3F → `0x003FC000` |
| `0x00000000-0x3FFFFFFF` identity, **data** | `DTT0` **cache-inhibited** (bring-up safe: chip regs/DMA) | `0x003FC060` |
| `0x80000000-0xFFFFFFFF` identity I/O | `DTT1` cache-inhibited | base 0x80, mask 0x7F → `0x807FC060` |
| `ITT1` | unused | `0` |
| `0x40000000` u-area (8 KB = 2×4 KB) | **paged** root→ptr→page | see below |

TTR derivation (E=1=`0x8000`, S=both=`0x4000`):
- ITT0 = `0x003F0000|0x8000|0x4000|0x00` = `0x003FC000`
- DTT0 = `0x003F0000|0x8000|0x4000|0x60` = `0x003FC060`
- DTT1 = `0x807F0000|0x8000|0x4000|0x60` = `0x807FC060`

**Cache decision:** code cached write-through (safe, fast-ish), all data + I/O
**cache-inhibited** for Draft 2 — eliminates every cache-coherency surprise
(volatile chip registers at 0xBFxxxx/0xDFxxxx, SCSI DMA) during bring-up. The
030 used cacheable for the low region; we are deliberately more conservative and
will relax DTT0 to write-through/copyback once DMA coherency (Phase 3.11) is in.

### u-area page tree (maps VA 0x40000000, 8 KB)
Reuse the physical pages the 030 code already allocated: after `pstart`'s body
runs, `kuptr[0]` = `(u_phys_page0 | 1)`, so `u_phys = kuptr[0] & 0xFFFFF800`.
The 030 u-area is 4×2 KB contiguous = 8 KB → two 4 KB 040 pages at `u_phys`,
`u_phys+0x1000`.

    root[VA>>25 & 0x7F] = root[32] = ptr_tbl_phys | 0x02
    ptr [VA>>18 & 0x7F] = ptr[0]   = page_tbl_phys | 0x02
    page[VA>>12 & 0x3F] = page[0]  = (u_phys        ) | S | CM | 0x01
                          page[1]  = (u_phys+0x1000  ) | S | CM | 0x01
    (CM here = write-through 0x00 or copyback 0x20; u-area is RAM, cacheable OK.)

Storage for the three 040 tables: continue `pstart`'s bootstrap allocator (the
running "next free, page-rounded" pointer it keeps just past the kernel), or a
zero-init static buffer in the replacement object. Tables live in the
identity-mapped low region, so their kernel address == physical address (what
the root pointer needs).

## 4. Implementation strategy

Full-function replacement (`pstart040.s`, linked via `relink-pstart.sh`):
1. **Transcribe** `pstart`'s body verbatim (crash-dump prologue + 030 table/glob
   build) so every global (`cpuroot`/`userroot`/`st_top1`/`kuptr`/`ublksde`)
   keeps the exact value downstream expects. The 030 tables become inert data.
2. At the MMU-enable point, instead of `pmove`s: build the 040 u-area tree
   (reusing `kuptr[0]`'s physical page), `movec` SRP/URP/ITT0/DTT0/DTT1, `pflusha`,
   `movec #0x8000,%tc`.
3. Fall through to the original `jsr vstart; jsr mlsetup; …` tail.

Validation before boot: assemble, disassemble, diff the *transcribed* region
against the original `pstart` (must match) — only the MMU section differs. Then
`relink-pstart.sh build/pstart040.o` (auto-checks text/data contiguity).

## 5. Expected result & known limits
- Past the u-area bus error → kernel continues into early init / toward
  single-user.
- **Page-size ripple still looms:** the binary-only HAT/VM layer computes PTE
  indices with 2 KB math (`>>11`, `+2047`) and walks tables in 030 format. With
  the hardware now at 4 KB / 040 format, the first HAT operation (≈ first process
  fork / kvseg map) will misbehave — the next blocker, and the start of the
  VM-wide 2 KB→4 KB conversion. Draft 2 is expected to reach early init, not
  multiuser.

Sources: Linux `arch/m68k/include/asm/motorola_pgtable.h`; MC68040 User's Manual
(NXP MC68040UMAD) ch.3 (MMU); decoded AMIX `pstart`/`tc_on`.
