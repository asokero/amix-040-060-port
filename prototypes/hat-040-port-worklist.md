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

### BATCH SCOPE (measured 2026-06-18)
`hat_init` (b4148, 64 B) needs NO port -- it only zeroes the free-list heads
(sdtfreelist/free_pts/active_pts), no table build, no format-critical code.  It is
global and stays as-is.

| fn | size | fmt sites | difficulty | notes |
|----|------|-----------|------------|-------|
| hat_pt2ptdat | 292 | 3 (1 page>>11, 2 pack>>17) | EASY | reverse lookup; mostly the SW ptdat@(4) packing (keep 030) -> verify, maybe 1 edit |
| hat_sdtalloc | 668 | ~6 (4x 11->12; 2x asll#2 keep) | MED | mostly SW bitmask free-list (setmask[], 32 seg/node -- NOT MMU fmt); page shifts |
| hat_ptalloc  | 1126 | ~10 (2x asll#3->x4, 1 DT bfclr, 3x PFN 21->20, 3x 11->12, 2048->4096) | MED-HARD | big but mechanical; page table stays 256 B; free-list carving stride/count per phys page needs rethink |
| hat_growsdt  | 726 | ~16 (11x asll#3->x4, 5 DT bfclr/bfins, entry counts) | HARDEST | the descriptor BUILDER; 8->4-byte multi-level descs; 8192->128-entry level change lives here |

Page-table size is UNCHANGED at 256 B (64 entries x 4) on both 030 and 040 -- the
`pea 0x100` allocations and the 256-stride leaf walk (addaw #256) stay.

### OPEN QUESTION (resolve BEFORE the batch) -- kernel ROOT table allocation
hat_pteload now indexes the root with `va>>25 & 0x7F` (128 entries) instead of
`va>>30 & 3` (4).  The kernel address-space root (`hat@(12)@(20)`) must therefore be
128-entry / 512-aligned.  WHO allocates it for the kernel is not yet traced -- it
may NOT be in this batch (could be hat_alloc, a static table, or vstart/mlsetup).
Must be resolved or the root walk corrupts.  [investigation below]

### Recommended order (risk-first)
1. trace the kernel root allocation (short but decisive)  2. hat_ptalloc (mechanical,
momentum, pteload's direct callee)  3. hat_pt2ptdat (easy)  4. hat_sdtalloc (med)
5. hat_growsdt (hardest last, once the pattern is routine).

### OPEN-QUESTION RESOLVED (2026-06-18) — kernel root is NOT hat_alloc
Traced the boot-critical kernel-VM chain.  Findings:
- **hat_alloc** (b4188, 88 B, GLOBAL): allocates a per-address-space root via
  `mem_align(&seg@(24),16)` -> `seg@(20)`, then zeroes 4 entries (`asll #3`,
  `bfclr @(3){6:2}`).  Needs the 4-entry/8-byte -> 128-entry/4-byte/512-align
  resize.  BUT only called from **as_alloc / as_dup** (user fork) -> a 7th batch
  function, NOT boot-critical for page_init.
- **The kernel root is STATIC, not hat_alloc.**  Boot path: `mlsetup -> kvm_init`
  (b48c2e) sets up `kas`/`kvseg` + static tables.  `ksegtbl` (BSS, 32 B) is a
  software seg#->pt# byte map (indexed `(va-syssegs)>>17 & 0x1FFF`), NOT the MMU
  root.  Kernel page mapping goes `sptalloc -> segkmem_mapin -> hat_vtokp_prot`.
- **hat_vtokp_prot** (b5fae, 134 B, GLOBAL): a protection-flag translator (jump
  table), NO page-table walk, format-agnostic -> NO PORT.  Same for **hat_init**.
- **hat_getkpfnum** (b5f2e, 28 B, GLOBAL): kernel pfn lookup, just `>>11` -> needs
  11->12.  Tiny, used widely.
- **kseg/unkseg** (a8d1a/a8e26, GLOBAL): encode 030 seg math (`>>17 &0x1FFF <<11`)
  but called only by RFS/IPC (rf_daemon/msginit/rfsr_*) -> NOT boot-critical, DEFER.

### NEXT TRACE (first task of implementation phase)
`segkmem_mapin` (a8904) calls only `hat_vtokp_prot` (a no-op for format) among HAT
fns -- so it installs the kernel PTE by some OTHER mechanism (direct write, or a
call not in my filter).  Pin down EXACTLY what builds the kvseg page tables the 040
MMU walks at page_init: re-disassemble segkmem_mapin + sptalloc fully, and check
whether kvm_init/mlsetup pre-build the kernel root the HAT then fills.  This tells
us whether the page_init milestone needs the full HAT batch or a smaller segkmem
path.  (hat_pteload is still needed -- hat_memload/hat_devload are its callers for
general kernel maps -- but the FIRST kvseg fault may go through segkmem directly.)

### Updated batch tally (for page_init milestone)
Likely: hat_pteload (DONE) + hat_ptalloc + hat_sdtalloc + hat_growsdt + the segkmem
kvseg-builder (TBD by the next trace) + hat_getkpfnum (tiny).  NO port: hat_init,
hat_vtokp_prot.  Deferred (not boot-critical): hat_alloc (user fork), kseg/unkseg
(RFS/IPC), hat_dup/hat_exec/hat_map/swtch/etc. (process mgmt, Phase 3 tail).

### *** MAJOR FINDING (2026-06-18) — page_init path is the STATIC map, NOT the HAT ***
Traced segkmem_mapin + kvm_init fully.  The kernel maps that the 040 MMU walks at
page_init are built by a STATIC path that DOES NOT touch hat_pteload/hat_ptalloc:

```
  mlsetup -> kvm_init (48c2e, LOCAL t, ~926 B)   builds the kvseg B-level descs
        -> sptalloc (a8bb6, GLOBAL) -> segkmem_mapin (a8904, GLOBAL)  writes leaves
```
- **kvm_init** sets `kas root = cpuroot+4` (pstart's 4-entry A-table) and builds the
  B-level (pointer) descriptors for **kvsegmap (0x40440000)** and **kvsegu
  (0x48440000)** DIRECTLY into `st_top1` (the SAME B-table pstart allocates), in 030
  8-byte format: `Bidx=va>>17 &0x1FFF` (48d12), `asll #3` stride (48d1c), template
  `limit=63 / status=0xC0 / DT=2` (48cf2/48cf8/48d06), two-long writes a0@ + a0@(4)
  (48d34/48d3e), page-table addr `d5<<11` (48d2a/48d56), B-desc step `addqw #8`
  (48d4c), `addil #512` per page table (48d42).  Repeats for kvsegu (48dc0+).
- **segkmem_mapin** writes the LEAF PTEs straight into `seg->s_ptbl` (seg@(28)):
  page index `(addr-seg@(4))>>11` (a892e, 2KB), PTE stride `asll #2` (a8932,
  already 4-byte -> KEEP), PTE = `pfn{0:21} | prot bfins{5:1}(W bit2) | DT orib#1`
  (a8976/a897c -- low-byte format = hat_pteload's leaf, COMPATIBLE), page step
  `addil #2048` (a8a4e, 2KB), page-base mask `andiw #-2047`=0xF801 (a89bc/a89c4).

### *** THE REAL page_init MILESTONE PATH (reprioritized) ***
To make the 040 MMU walk the kvseg maps, port the STATIC path -- a CLEANER, more
bounded route than the HAT batch (and it extends pstart040's proven approach):
1. **pstart040**: the 040 root must have pointer table(s) covering the kvseg VA
   range so kvm_init can fill them.  0x40000000>>25=32 (u-area, done), kvsegmap
   0x40440000>>25=34, kvsegu 0x48440000>>25=36.  Need 040 root entries 32..36+ ->
   pointer tables; make `st_top1` (or a fresh table) the 040 pointer table kvm_init
   writes into.
2. **kvm_init** (LOCAL t -> globalize+weaken): B-level build to 040 4-byte pointer
   descriptors: `>>17 &0x1FFF -> >>18 &0x7F`, `asll #3 -> #2`, single-long
   `*a0 = pagetable<<12 | UDT(2)`, drop limit/status template; `<<11 -> <<12`.
3. **segkmem_mapin** (GLOBAL -> just weaken): leaf edits `>>11->>>12`,
   `#2048->#4096`, `{0:21}->{0:20}`, `andiw #-2047 -> #-4095`(0xF001); PTE low-byte
   format unchanged.  (sptalloc: 2x `moveq #11` -> 12.)
4. **hat_getkpfnum** (28 B) if reached: `>>11 -> >>12`.

hat_pteload (DONE) + hat_ptalloc/sdtalloc/growsdt remain correct and necessary for
the LATER milestone (as_alloc / hat_memload / first user process), but are NOT the
page_init blocker.  hat_pteload's leaf-format analysis transfers directly to
segkmem_mapin (same low-byte PTE format).

### *** CENTRAL DESIGN DECISION (2026-06-18) — the CLICK (2KB) vs PAGE (4KB) duality ***
Traced the click model fully.  `mlsetup`: `maxclick = memsize >> 11` => the kernel's
**click/page = 2 KB**, baked as immediates (`#2048`, `<<11`/`>>11`) -- NOT a runtime
constant.  `sptalloc -> segkmem_mapin`: the pfn handed in is a **2 KB click number**;
the leaf PTE is `click << 11 | flags` (030: phys in bits 31:11).  The 040 MMU's min
page is **4 KB** (phys in bits 31:12).  These mismatch.  Three ways to reconcile:

  A. **Click stays 2 KB; pair 2 clicks per 4 KB MMU page** (recommended).  Change ONLY
     the leaf-build / table-walk sites: leaf index `va>>11 -> va>>12`, loop step
     `#2048 -> #4096`, pfn increment `+1 -> +2`, PTE base stays `click<<11` (a 4KB-
     aligned even click puts phys in bits 31:12 already -> a VALID 040 PTE, no shift
     change!).  Two adjacent clicks share one 4 KB page + protection.  Localizes the
     change to the MMU-facing code (kvm_init/segkmem_mapin/hat leaves); the kernel's
     2 KB click accounting (maxclick, pages[], btoc/ctob) is UNTOUCHED.  Caveat: a
     single 2 KB click can't be independently protected (fine for kernel maps; a
     Phase-4 / user-page concern).
  B. **Change click -> 4 KB everywhere** (NBPC/btoc/ctob/maxclick/pages[]): the
     pervasive ~176-site change the mmu-format doc warned of.  Cleanest model, most
     work + risk (touches the whole VM, not just the MMU-facing edges).
  C. **8 KB clicks/pages**: pairs cleanly with nothing; rejected earlier.

  => GO WITH (A).  Key simplification it buys: the leaf PTE construction `click<<11`
  needs NO shift change -- only the loop granularity (index >>12, step 4KB, pfn +=2)
  and that mapped regions start on an even (4KB-aligned) click.  This refines the
  earlier "segkmem_mapin leaf edits" spec: NOT `>>11->>>12` on the PTE value, but on
  the INDEX/STEP, keeping `click<<11`.

### REVISED segkmem_mapin / kvm_init port (under model A)
segkmem_mapin (a8904): page index `(addr-base)>>11 -> >>12` (a892e); loop step
`#2048 -> #4096` (a8a4e); pfn increment per page `+1 -> +2` (a8a42, the
bfextu/addql/bfins on fp@(-8)); the page-base compare mask `andiw #-2047 -> #-4095`
(a89bc/a89c4); PTE value `click<<11` UNCHANGED; PFN-extract widths stay (the click
field is still bits 31:11).  REQUIRES the mapped base click to be even (4KB-aligned)
-- verify sptalloc/segkmem_alloc hand even clicks (kernel allocs are contiguous from
an aligned base; check `v`/kptbl base alignment).
### segkmem_mapin — DONE (prototypes/kvm040.s, verified, committed)
Model A port done & mnemonic-diffed vs original (only intended edits + equivalent
restructures).  GLOBAL -> --weaken.

### kvm_init — DESIGN (worked out 2026-06-18; the geometry is the tricky bit)
Prep DONE: pstart040 now exports `kroot040` (0040 kernel root) AND `kptr040`.
kvm_init is LOCAL (t) -> globalize+weaken.  Port = transcribe VERBATIM except:
1. **48c3a** `kas@(0x14) = cpuroot+4` -> `kas@(0x14) = kroot040` (the 040 kernel root;
   used on context-switch movec ...,srp).  Not strictly the page_init blocker but
   correct.
2. **The two map loops** (kvsegmap 48d0c-48d60, kvsegu 48dc0-48e14): rebuild as 040
   pointer descriptors in kptr040.  GEOMETRY (the careful part):
   - 030: st_top1[va>>17 &0x1FFF] (8-byte B-desc, 128KB granularity) -> leaf table;
     loop `d0 += 64 clicks` until `smsegs*64`, leaf base `d1 = v<<11`, `d1 += 512`/seg.
   - 040 Model A: pointer entry = va>>18 = **256KB** = 64 x 4KB = 2 kernel-segments;
     leaf table = 64 PTEs = **256 B**.  Consistency with segkmem_mapin (which writes
     kptbl[(va-base)>>12]): `kptr040[(va>>18)-4096] -> kptbl + relptr*256` makes
     PTE(va) = kptbl + relptr*256 + ((va>>12)&0x3F)*4 = kptbl + ((va-base)>>12)*4. OK.
   - So 040 loop: `slot = kptr040 + ((kvsegmap>>18)-4096)*4`; `leaf = v<<11` (kptbl,
     2KB-aligned => fine for a 256-B/256-aligned page table, NO 4KB rounding needed --
     the even-click/4KB requirement is on the PHYS PAGES segkmem maps, not the leaf-
     TABLE addresses); `num = ceil(smsegs*128KB / 256KB) = ceil(smsegs/2)` (round UP;
     slight over-map is harmless -- extra pointer entries point at empty leaves and
     page_init only touches the pages[] range).  Per entry: `*slot = leaf | UDT(2)`;
     `slot += 4`; `leaf += 256`.  Set ksegmappt = v<<11, eksegmappt = leaf-end.
   - kptbl is allocated by **sysseginit** (ref 48c16) -- CONFIRM its size before
     writing (040 uses ~1/4 the 030 leaf space: 256-B vs 512-B leaves AND half the
     count, so it fits, but verify).  smsegs/susegs computations stay VERBATIM (they
     count 128KB segments from maxclick -- software, Model A leaves the click model
     intact).  All seg_attach/segkmem_create/sptalloc/hat_init/page_init/memialloc/
     kmem_init/seg_alloc/segmap_create/segu_create calls stay VERBATIM.
3. Build: add kvm_init to relink-kvm.sh GLOBALIZE+WEAKEN, segkmem_mapin to WEAKEN,
   link pstart040.o + kvm040.o, run patch_pflusha/patch_pmmu, test -> page_init.

OPEN before writing kvm_init: (a) sysseginit's kptbl size/layout; (b) confirm the
`v` arg (fp@8) and the v<<11 leaf base; (c) does kvsegu use a separate kptbl region
or continue in the same one (the 030 code continues d1/d5 from kvsegmap's end into
kvsegu -- mirror that).

### *** RESOLVED (2026-06-18) + the milestone key is sysseginit, NOT kvm_init ***
Confirmed the 3 items and found the real milestone-critical function:
- `mlsetup`: `v = sysseginit(); kvm_init(v)`.  **sysseginit** (48ba2, LOCAL t) sets
  `kptbl = v<<11` and builds the **kvseg/syssegs (0x40040000, 4MB)** pointer
  descriptors: 64-PTE (256 B) leaves, contiguous (`d0 += 256`), 32 segments
  (128KB each, loop `d1 += 64` while <=2047).
- **page_init's pages[]/page_hash are sptalloc'd from `sptmap`, which mlsetup inits
  to the 4MB syssegs region** -> they live in **kvseg (segkmem direct-map), built by
  sysseginit + filled by segkmem_mapin**, NOT in kvsegmap.
- **kvm_init's kvsegmap/kvsegu loops are for segmap/segu (page-cache/user windows,
  LATER)** and write to the now-INERT st_top1 (root040 -> kptr040, never st_top1).
  Harmless for page_init.  So **kvm_init needs NO change for the milestone** (nothing
  reloads SRP between kvm_init entry and page_init; kas@(0x14) fix can wait).

=> MILESTONE = **sysseginit + segkmem_mapin** (both ported), kvm_init UNCHANGED.

### sysseginit Model A port (the milestone key)
LOCAL t -> globalize+weaken.  Build 040 pointer descriptors into **kptr040** (not
st_top1), single long `*slot = leaf | UDT(2)`:
- slot = `&kptr040[(syssegs>>18) - 4096]` (= kptr040+4, flat index 1; u-area is flat 0)
- leaf base `d0 = v<<11` (=kptbl); leaf size 256 B (64 PTEs) UNCHANGED; `d0 += 256`/entry
- Model A granularity: a pointer entry now covers 256KB (64 x 4KB), so 16 entries for
  the 4MB region: loop `d1 += 128` (was 64) while `<= 2047` -> 16 iters (was 32).
- DROP the 8-byte template build (48bae-48bc4); descriptor is one long.
- tail: `kptbl = v<<11`; return `(leaf_end + 2047)>>11`.
Consistency with segkmem_mapin (Model A, writes kptbl[(va-0x40040000)>>12]*4):
kptr040[1+P] -> kptbl + P*256 ; PTE(va) = kptbl + P*256 + ((va>>12)&0x3F)*4 =
kptbl + ((va-base)>>12)*4.  OK.  (kvseg s_base = syssegs = 0x40040000; s_ptbl = kptbl.)
RISK to watch: the kptbl leaf memory (at v<<11) must be ZEROED before use (invalid
initial PTEs) -- the 030 path relies on it; verify if the test faults oddly.

### *** MILESTONE RESULT + MODEL A HIT ITS WALL (2026-06-18 eve) ***
Test of the sysseginit+segkmem_mapin build (after fixing a runaway-loop bug --
segkmem_mapin used `bne` on a 4KB `addil #-4096` step; odd-click len never hit 0 ->
infinite loop, Gary timeout; fixed with `bgt`):
**PAGE_INIT PASSED.**  Fault moved from page_init+0x4a (0xAF474) to
**kmem_allocspool+0x19c (0x41D1A)**, which runs AFTER page_init in kvm_init.  Visual
console restored.  So the kvseg map + sysseginit + segkmem_mapin (Model A) WORK end
to end for page_init.  Huge: validated pstart040 scaffold + override machinery +
the whole static kvseg path.

**But the new fault exposes Model A's fundamental limit:** kmem_allocspool ->
`sptalloc(...,phys=0,...)` -> **segkmem_alloc** (a86ba, the allocate-AND-map sibling
of segkmem_mapin, NOT ported).  segkmem_alloc maps pages from **page_get**, which
returns a **LINKED LIST of physically SCATTERED 2KB clicks** (page_sub follows the
page-struct links at off 16/20, not +1).  It maps each scattered click to a
**2KB-packed consecutive VA**.  On 040 this is IMPOSSIBLE under Model A:
  - a 4KB MMU page needs 4KB CONTIGUOUS phys -- two scattered 2KB clicks can't form one;
  - 040 forces 4KB VA granularity -- you can't map a 2KB-packed VA stream.
So the kernel's page ALLOCATOR (page_get/page_free/pages[]) being 2KB-granular is
irreconcilable with 4KB MMU pages.  Model A's "keep 2KB clicks" works for
pre-mapped/contiguous regions (pstart040 u-area, kvseg leaves) but NOT for the
scattered-click allocator path.  This is the "pikkuhattu" caveat materializing --
earlier than expected (kernel kmem allocator, not user pages).

=> DECISION NEEDED: the page frame must become 4KB-granular.  Either full **Model B**
(4KB clicks everywhere: NBPC/btoc/ctob/maxclick/pages[]/page_get + leaf PTE pfn<<12
& {0:20}; ~176 immediate sites, mechanical, the "correct" model real 040 ports use)
or a narrower "4KB allocator + keep 2KB accounting" hybrid (change only page_get/
page_free/page_init/pages[] to hand 4KB-aligned even-click pairs; then Model A's
segkmem `click<<11` still works since clicks are even -- fewer sites but mixes two
page sizes, fragile).  Model A infra (pstart040 scaffold, relink/override, kvseg
structure) carries over; segkmem leaf edits flip from "keep <<11" to "<<12 / {0:20}"
under B.

### MODEL B SCOPE (measured 2026-06-18) -- page-size sites on the boot-critical path
Counted page-size-context immediates (shift-by-11, #2048/#2047, 21-bit pfn bitfields)
across the whole kernel, attributed per function:
- **~892 total sites / 279 functions** -- but the MAJORITY are NOT boot-critical
  (filesystems ufs/s5/nfs getapage/bmap/putpage, /proc prfast*, mmrw, device DMA,
  memcntl, ...).  Those defer to "after single-user".
- **~186 sites / 45 functions on the boot-critical path** (VM/mem/proc/exec core).
Tiers within the 45:
- **Tier 0 (unblock the CURRENT fault, reach further than kmem):** segkmem_alloc(2),
  segkmem_free(5), segkmem_mapout(5), kmem_alloc(3), kmem_free(2), sptalloc(2),
  sptfree(3), page_get(2) + page allocator helpers.  ~6-10 functions, ~30 sites.
- **Tier 1 (first user process -> single-user shell):** the HAT process fns
  (hat_exec 8, hat_dup 7, hat_unload 6, hat_chgprot 6, hat_ptalloc 6, hat_load,
  hat_sdtalloc, hat_pteload...), segvn_fault(8)/create(6)/unmap(9), execmap(8),
  coffcore(9), as_fault/setprot, bp_map/bp_mapout(8 each).  ~30 functions, ~150 sites.
  MANY overlap the HAT batch already on the port list, so they aren't all "new".
- **Already ported under Model A (need a small re-touch under B):** hat_pteload,
  segkmem_mapin, sysseginit (leaf edits flip "keep <<11" -> "<<12 / {0:20}").

KEY CONSIDERATION -- Model B is LESS incrementally testable than Model A: the page
frame size is a global invariant (maxclick computed once in mlsetup, pages[] sized
once); ported (4KB) and un-ported (2KB) functions on the same path disagree, so the
core page-frame set must flip together-ish, then test.  Model A allowed per-function
test cadence; Model B is more big-batch.  (The hybrid "4KB allocator + 2KB
accounting" keeps maxclick/pages[]/btoc at 2KB -- fewer functions -- but mixes two
page sizes; the wart is variable-size sub-4KB allocations.)
