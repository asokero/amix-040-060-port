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

---

## hat_pteload — worked port spec (2026-06-18)

Full disasm analysed (0xb4d64–0xb5028, 710 B). Calls: `cmn_err`, `hat_ptalloc`,
`hat_pt2ptdat`, `flushmmu`.  Frame `linkw -56`, saves d2-d3/a2-a4.
Args: fp@(8)=hat (→@(12)=seg, →@(20)=root table), fp@(12)=va→d2, fp@(16)=pp→a2,
fp@(20)=pfn, fp@(24)=prot, fp@(28)=lockflag.  Locals: fp@(-4)=ptdat,
fp@(-28)=Aidx, fp@(-36)=Bidx, fp@(-44)=leaf status, fp@(-52/-56)=A-desc longs.

### KEY DISCOVERY — leaf PTE low bits are format-compatible
030 leaf status values {0,1,5} = {invalid, page, page+WP} sit at PDT(1:0)+W(2) —
**identical bit positions on 040** (PDT=01 resident, W=bit2). M=bit4, U=bit3 on
BOTH.  So the C-level leaf needs only: page shift 11→12, PFN extract width 21→20.
The M/U-propagation bfextu sites (@(3){4:1},{3:1}) and status logic are VERBATIM.

### The three structural (length-changing) rewrites
1. **Root (A) desc read** (b4d94–b4dcc): 030 reads long0+long1 (8 B) + DT + limit
   check.  040: read ONE long → `UDT=desc&3`; if UDT not resident → cmn_err(panic);
   `Btable = desc & 0xFFFFFE00` (ptr table 512-aligned).  Drop the limit word/check.
2. **Pointer (B) desc walk** (b4de2–b4dee, b4eb4): stride Bidx*8→*4; base from the
   single long: `pagetable = Bdesc & 0xFFFFFF00` (page table 256-aligned), not @(4).
   The `bfextu a3@(3){6:2}` DT/UDT read is UNCHANGED (UDT also = low 2 bits).
3. **Pointer (B) desc build** (b4e66–b4e90): 030 wrote a4→@(4), bfins status@(2),
   bfins DT=2@(3), limit@.  040: `*a3 = a4 | 0x02` (UDT=2 resident; tables carry no
   cache/limit on 040). The ptdat bookkeeping writes (@(0)=seg,@(4),@(6),@(7)) are
   SOFTWARE state — KEEP verbatim.

### Same-size immediate changes
- A index: `>>30 &3` → `>>25 &0x7F`   (b4d76 moveq 30→25; b4d7a moveq 3→0x7f)
- B index: `>>17 &0x1FFF` → `>>18 &0x7F` (b4d84 17→18; b4d8a andil →0x7f)
- A,B table stride: asll #3 → #2 (b4da0, b4dea)
- C index: `>>11 &63` shift 11→12 (b4e96, b4ea8); stride asll #2 unchanged (4-B leaf)
- leaf pfn<<11 → <<12 (b4f66, b4fda); PFN extract {0:21}→{0:20} (b4ebe)

### Deferred (NOT in bring-up version, documented as TODO in hat040.s)
- **Device cache-mode**: 030 routed prot&8 to the (now-gone) B-table status byte.
  On 040 cache mode is per-LEAF (CM bits 6:5).  Deferred: pstart040's DTT0/DTT1
  cover the device identity regions, so early kernel maps are cacheable RAM only.
  When device page-table maps are needed: capture prot&8 before `prot&=7`, OR
  CM=10 (0x40) into the leaf.
- **ptdat@(4) packing**: kept at 030 `(va>>17)*2` (software free-path bookkeeping,
  read by hat_ptalloc/hat_ptfree — NOT the MMU, NOT boot-critical).  Re-pack to the
  040 layout when hat_ptalloc is ported so the two stay consistent.

### STATUS: hat_pteload DONE (ported + verified, not yet runtime-tested)
`prototypes/hat040.s` holds the 040 hat_pteload.  Verified: assembles clean
(660 B .text, mult-of-4); disassembly is byte-faithful to the original except the
documented sites; 4 relocs all resolve to real kernel symbols (cmn_err/flushmmu
global; hat_ptalloc/hat_pt2ptdat local -> see mechanism below); reloc validator
0 complaints.  Runtime test blocked on the coupled batch (below).

### KEY MECHANISM — overriding FILE-LOCAL functions (proven 2026-06-18)
The pstart `--weaken-symbol` trick only works on GLOBAL symbols.  Every boot-
critical HAT fn is file-LOCAL (`t`): hat_pteload, hat_ptalloc, hat_pt2ptdat,
hat_sdtalloc, hat_growsdt, hat_ptfree, hat_sdtfree.  To override a local AND
redirect its callers:
```
objcopy --globalize-symbol NAME ... unix-stage1   # local t -> global T (per fn)
objcopy --weaken-symbol   NAME      unix-stage1   # the one(s) we REPLACE -> weak W
m68k-cbm-sysv4-ld -r -o unix-040 unix-stage1 hat040.o   # strong def overrides
```
Globalize EVERY local HAT fn that hat040.o references or replaces; weaken only the
ones hat040.o actually redefines.  VERIFIED: after this, the kernel's internal
`jsr hat_pteload` relocs (b4ce2, b4d08) resolve to our appended def (0xd71a8), the
old body becomes dead weight, and check_relink_relocs.py = 0 complaints.  (Fns we
DON'T replace yet but DO call -- e.g. hat_pt2ptdat while only pteload is ported --
just get --globalize-symbol so our UND ref binds to the kernel's 030 version.)

### COUPLING — first testable increment is bigger than one function
hat_pteload calls hat_ptalloc to allocate page tables.  hat_ptalloc ALSO speaks the
030 format (asll #3 at b6b52/b6b70, DT bfclr @(3){6:2} at b6b84, page rounding
lsll #11 at b6a74/b68ec, 256-stride leaf walk b6c30, page-table backing `<<11`).
**So page_init won't advance until hat_pteload AND hat_ptalloc (+ hat_sdtalloc,
hat_growsdt for the 128-entry 512-aligned root) are all ported.**  hat040.s starts
with hat_pteload; the others follow in the same object before the first 040 test.
