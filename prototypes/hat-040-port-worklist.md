# Phase 3 — HAT / VM layer 68040 port: PLAN

Status: IN PROGRESS (2026-06-18).  pstart040 works (040 bootstrap paging);
visibility achieved (clean kernel panics).  Stub-&-map confirmed the chain:
pstart040 ✓ → ptest (stubbed) → **page_init bus-errors** because the kernel's
HAT builds 030 2KB-format page tables that the 040 MMU (set up by pstart040)
cannot use → kvseg unmapped.  This is the core 2KB→4KB page-table-format rework.

## The exact format change (from mmu-format-030-to-040.md, verified)
| | 030 (now) | 040 (target) |
|-|-----------|--------------|
| Page size | 2 KB (>>11, +2047) | 4 KB (>>12, +4095) |
| VA split | A=va>>30&3, B=va>>17&0x1FFF, C=va>>11&0x3F | A=va>>25&0x7F, B=va>>18&0x7F, C=va>>12&0x3F |
| Table desc | 8 bytes (stride ×8) | 4 bytes (stride ×4) |
| Leaf PTE | 4 bytes, 21-bit PFN | 4 bytes, 20-bit PFN |
| Root | 4-entry A-table, pmove desc | 128-entry root, movec phys addr (done in pstart040) |

## The functions to port (~26, ~15 KB, BINARY-ONLY — no source in the tar)
Boot-critical FIRST (what kvm_init/page_init/early VM need), then process mgmt:
| Function | size | role | priority |
|----------|------|------|----------|
| `hat_pteload` | 710 | **the central PTE loader** — builds one mapping | 1 (core) |
| `hat_ptalloc` | 1126 | allocate a page table | 1 |
| `hat_sdtalloc`/`hat_sdtfree` | 668/696 | segment-descriptor-table alloc/free | 1 |
| `hat_growsdt` | 562 | grow the SDT | 1 |
| `hat_init` | 64 | HAT init (builds kernel tables) | 1 |
| `hat_pt2ptdat`, `hat_getkpfnum`, `hat_vtokp_prot` | 292/28/134 | walk/lookup helpers | 1 |
| `hat_map` | 1316 | map a VA range (+ pmove crp) | 2 |
| `hat_memload`/`hat_devload`/`hat_pteload` callers | | | 2 |
| `hat_unload`/`hat_pageunload`/`hat_chgprot`/`hat_pagesync` | 820/318/478/200 | unmap/protect | 2 |
| `hat_asload` (+pmove crp), `swtch` (+pmove crp), `hat_exec`, `hat_dup` | 64/578/1316/1974 | address-space load / context switch / fork | 3 |
| `hat_swapin`/`hat_swapout`/`hat_alloc`/`hat_free`/`hat_unlock`/`hat_newseg` | | | 3 |

## KEY INSIGHT — the change splits into two kinds of edit
**(a) Same-size byte-patches** (~171 sites total across the HAT — most of the work):
the index/stride/page-size math is immediate-only tweaks, same instruction size:
- `moveq #30,Dn` (A: va>>30) → `moveq #25,Dn`   (7?1e → 7?19)
- `moveq #17,Dn` (B: va>>17) → `moveq #18,Dn`   (7?11 → 7?12)
- `andil #8191,Dn` (B mask 0x1FFF) → `andil #0x7F,Dn`
- `moveq #11,Dn` / `lsrl #11` / `#2047` (2KB) → `#12`/`#12`/`#4095`
- `asll #3,Dn` (×8 table stride) → `asll #2,Dn`   (e?80 → e?80 w/ count 2)
- leaf PFN field widths (bfextu/bfins widths 21→20, etc.)
A context-checked patch script (like patch_pmmu_040.py) can do these in place.
CAUTION: these immediates also occur OUTSIDE the MMU context (loop counts, etc.)
— each site MUST be verified in its descriptor/VA-decode context, never blind-patched.

**(b) Structural descriptor changes** (per-function, harder): the 030 reads/writes
table descriptors as **8 bytes** (long0 = limit/status/DT, long1 = addr at +4) e.g.
in hat_pteload:
```
  b4de2: a3 = desc.addr (long1)
  b4dea: asll #3,d0 ; a3 += Bidx*8        <- ×8 stride
  b4dee: bfextu a3@(3),6,2 -> DT           <- DT at byte+3
  b4e50: movew d3,a0@(4)  ; limit at +4    <- 8-byte layout
  b4e58: moveb #1,a0@(6) ; b4e62: clrb a0@(7) ; b4e66: movel a4,a3@(4) ; addr at +4
```
On 040 every descriptor is **4 bytes**: `[phys/table addr (upper) | flags | UDT/PDT(2)]`.
So the dual-long read/write collapses to a single 4-byte access, the +4/+6/+7 field
offsets vanish, and the bitfield builds move to the 040 4-byte field layout
(table: addr&~0xFF | UDT; page: phys&~0xFFF | CM | M | U | W | S | PDT).
These sequences need transcription/rewrite, not just an immediate swap.

## Approach (incremental, validated by the clean-panic visibility)
1. Port `hat_pteload` first (the core).  Relink-replace it (a `hat040.s` linked via
   `--weaken-symbol hat_pteload`, same mechanism that finally worked for pstart).
   Transcribe verbatim, then apply (a)+(b) to its descriptor/VA-decode sites.
2. Port the allocators it calls (`hat_ptalloc`, `hat_sdtalloc`, `hat_growsdt`) and
   `hat_init` → kvseg maps → `page_init` works → advance.
3. Continue function-by-function as each surfaces as a clean panic.

## HONEST SCOPE
This is the biggest single piece of the project: ~15 KB of intricate binary MMU
code, ~171 same-size sites + structural descriptor rewrites across ~26 functions,
no source, each error = silent table corruption.  Multi-session.  pstart040 (one
700 B function) is the proof the method works; the HAT is ~20× that.  NetBSD
`pmap_motorola.c` / `pte.h` are the cleanest reference for the 030-long ↔ 040-4-byte
split (mmu-format doc §ref).

Tooling ready: relink via `--weaken-symbol` (relink-pstart.sh pattern),
`check_relink_relocs.py` (validate relocs), clean panics for per-function verify.
