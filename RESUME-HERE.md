# RESUME HERE — AMIX 68040 port status (2026-06-18)

One-line: **68040 bootstrap paging works; kernel boots to `page_init` which
bus-errors writing the `pages[]` array (lives in unmapped kvseg).  pstart040 now
builds the kvseg-wide 040 scaffold (kptr040); NEXT = port kvm_init + segkmem_mapin
to FILL it so kvseg maps and page_init advances.**

## LAST TEST (2026-06-18, WinUAE on 040) — confirms the target
PANIC: KERNEL FAULT pc=0x70AF474 vector=0x2 (Bus Error).  Kernel loads at
0x07000000 -> fault = offset 0xAF474 = **page_init+0x4a** = `orib #0x80,%a0@`, the
loop initializing each `pages[]` struct (a0 = `pages`, stride 60, to `epages`).
`pages` is in kvsegmap (0x40440000+), unmapped because kvm_init hasn't filled
kptr040 yet.  EXACTLY the predicted blocker; pstart040 scaffold caused NO regression
(still reaches page_init cleanly).  (The DOUBLE PANIC pc=0xF80C34 is the panic
handler faulting again -- secondary, ignore.)

## Where we are (the journey)
```
pstart040 (040 MMU enable) ✓  ->  ptest (030 ptestr, stubbed) ✓
  ->  page_init BUS ERROR  <-- WE ARE HERE
        cause: HAT (hat_init/hat_pteload/...) builds 030 2KB-format page tables;
        the 040 MMU set up by pstart040 can't use them -> kvseg unmapped.
```
Achieved today: found & fixed the relink bug so pstart040 actually runs
(`--weaken-symbol`, not `--redefine-sym`); 040 paging up; clean-panic visibility;
mapped the blocker chain into the HAT.

## Build & test (the loop)
```
. /home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh   # cross toolchain
export PATH="/home/asokero/kehitys/amiga-gcc-bin/bin:$PATH"           # amiga gcc (loader)

# kernel (pstart040 + stubs):
m68k-cbm-sysv4-gcc -m68040 -c prototypes/pstart040.s -o build/pstart040.o
sh relink-pstart.sh build/pstart040.o          # -> build/unix-040  (uses --weaken-symbol)
python3 prototypes/patch_pflusha_040.py         # 030 pflusha -> 040 (re-run after each relink)
python3 prototypes/patch_pmmu_040.py            # ptest/ptest0 stubs (re-run after each relink)
python3 prototypes/check_relink_relocs.py       # MUST print "0 complaints"

# loader (only if changed): see LOCAL-BUILD-NOTES.md §3
# Test in fs-uae/WinUAE on 040:  command `unix_boot040 unix-040`
# Logs: ~/Asiakirjat/FS-UAE/Cache/Logs/fs-uae.log.txt  (logs the 040 MMU state!)
#       ~/.wine/.../WinUAE/winuaelog.txt  (needs the logging checkbox ON)
```
The kernel's console is hardcoded to the native Amiga display, so clean panics
render in the emulator — read the panic `pc=` to identify each blocker.

## NEXT TASK — port the HAT (Phase 3)  [hat_pteload DONE]
Full plan + inventory + the exact 030→040 format change + per-fn port spec:
**`prototypes/hat-040-port-worklist.md`**.

**DONE: `hat_pteload`** — `prototypes/hat040.s` (040 port, byte-faithful, relocs
clean, reloc-validator 0 complaints).  Two infrastructure results proven en route:
- **Local-symbol override mechanism** (`relink-hat.sh`): HAT fns are file-LOCAL,
  so `--weaken-symbol` alone can't override them.  Use `objcopy --globalize-symbol`
  (local→global) on every referenced/replaced HAT fn, THEN `--weaken-symbol` the
  replaced ones.  Verified: kernel callers redirect to our def, validator clean.
- Leaf PTEs are format-compatible (030 status {0,1,5} == 040 PDT/W bits); only the
  page shift 11→12 + PFN width 21→20 change.  Structural rewrites are confined to
  the root/pointer descriptor read+build (8-byte→4-byte).  (Details in worklist.)

**REPRIORITIZED (trace 2026-06-18): page_init is reached via the STATIC kernel-map
path, NOT the HAT batch.**  Full trace in the worklist ("MAJOR FINDING"/"THE REAL
page_init MILESTONE PATH").  The kvseg maps the 040 MMU walks at page_init are built
by `kvm_init` (writes kvseg pointer descriptors into `st_top1`, pstart's B-table) +
`segkmem_mapin` (writes leaf PTEs into `seg->s_ptbl`) — neither calls hat_pteload.

**TIER-1 STATUS (2026-06-18): "No space for mapping files" PERSISTS after adding the
Tier-1 sites (seg_alloc rounding + kvsegmap/kvsegu <<18).**  So those weren't the
cause.  REFINED DIAGNOSIS: the panic is kvm_init LC%2 = `seg_alloc(kas, kvsegmap)`
returns 0.  Static analysis CANNOT explain a real seg-list overlap (MAINSTORE/
VSIZOFMEM set at 0x191xx, untouched by Model B; kvsegmap 0x40440000 is adjacent to
kvseg [..0x40440000), no overlap; page_init passing proves v/kptbl/smsegs are
consistent).  BUT seg_alloc calls `kmem_fast_alloc` for the seg struct and does NOT
check its return -- if kmem_fast_alloc returns 0 (pool EMPTY), the struct ptr is
null, seg_attach->as_addseg reads garbage and returns -1 -> seg_alloc returns 0 ->
"No space".  So the LIKELY root cause is **kmem_fast_alloc returning 0 = kmem's pool
is empty/undersized under Model B** (we passed the BUS ERROR in kmem_allocspool, but
kmem may not be functionally initialized -- e.g. its pool size depends on a halved
maxclick, or kmem_allocbpool/the free-list count is wrong).
**NEXT: investigate kmem.** Check kmem_allocspool/kmem_allocbpool pool SIZING (does it
derive from maxclick/page count?  it had no page-size *shift* sites, but the byte
size it sptallocs may be maxclick-derived -> halved -> too small/zero).  Trace
kmem_fast_alloc and confirm it returns 0 here (runtime: a debug cmn_err in a kvm_init
override dumping smsegs / the kmem free-list head, OR the emulator debugger).  Then
fix the kmem pool sizing for Model B.

**MODEL B Tier-0 PASSED (2026-06-18 earlier test):** got PAST kmem_allocspool -- the bus
error is gone, now a CLEAN panic "No space for mapping files" at the kvsegmap/segmap
setup (kvm_init 48ef8 `seg_alloc(kas, kvsegmap, smsegs<<17)` returns 0).  Model B
4KB page frame WORKS for the allocator.  NEXT FRONTIER (Tier-1 segmap) -- add to
patch_modelb.py:
- **seg_alloc** (b2820) page-size rounding: b2832 #-2048->#-4096, b283e #2047->#4095,
  b2844 #-2048->#-4096.
- **kvm_init segmap size** 48ee6 `moveq #17`->`#18` (segment 128KB->256KB; smsegs is
  halved under B so <<18 restores the 030-equiv byte size).  Same for kvsegu (48f58).
- **seg_attach** (b28f0): check its page-size sites (seg_alloc fails via valid_va_range
  OR seg_attach<0 -- pin down which; seg_attach actually checks the VA/seg list).
- The kvm_init kvsegmap/kvsegu LOOPS (48d0c/48dc0) were left inert (write to st_top1);
  once segmap actually maps kvsegmap they likely need the kptr040 + Model B treatment
  too (like sysseginit) -- but seg_alloc/seg_attach (struct setup) fails BEFORE any
  mapping, so fix those first.
Then rebuild + retest.

**MODEL B Tier-0 BUILD (2026-06-18):** `sh relink-040.sh` ->
`build/unix-040`.  Model A got PAST page_init but hit its wall at the kmem allocator
(page_get returns physically scattered 2KB clicks -> can't be paired into 4KB pages).
Switched to **Model B (4KB page frame)**: each click IS a 4KB page, so scattered
clicks map 1:1.  Tier-0 = 21 SAME-SIZE byte patches (patch_modelb.py: mlsetup
maxclick+sptmap, kvm_init page_hash size, segkmem_alloc + segkmem_mapin leaf builders,
sptalloc) + 1 structural override (sysseginit -> kptr040, re-touched to Model B in
kvm040.s).  Build: 0 reloc complaints, contiguous.  **Boot on 040, read next panic
pc.**  Expect to advance past kmem_allocspool+0x19c (0x41D1A).  If a new page-size
fault appears, add its site to patch_modelb.py (Tier-1 fns: hat_*, segvn_*, execmap,
coffcore -- see worklist Model B scope).

**NEXT (page_init milestone), in order:**
1. **pstart040 — DONE.**  Extended to build the 040 root with entries 32..63 ->
   `kptr040` (a flat 16 KB region of 32 pointer tables for the kvseg 1GB), u-area
   mapped via `kptr040[0]` -> `uarea_pt`.  `kptr040` is EXPORTED (global, in the
   kernel now) so kvm_init writes 040 pointer descriptors at
   `kptr040 + ((va>>18)-4096)*4`.  st_top1 left untouched (still 030, read by
   sysseginit/p0init/bp_map/swapinub/segu_get).  Assembles/relinks/patches/
   reloc-validates clean, text/data contiguous.  (Boot behaviour unchanged until
   kvm_init fills kptr040 -- entries are invalid/zeroed for now.)
2. **kvm_init** (LOCAL → globalize+weaken): B-level build → 040 4-byte pointer descs
   written into **kptr040** (not st_top1): index `(va>>18)-4096` *4, single-long
   `*slot = leaftable<<12 | UDT(2)`; `>>17&0x1FFF→>>18`, `asll#3→#2`, `<<11→<<12`,
   drop the 030 limit/status template.  (Build it like hat040.s: a new object,
   globalize+weaken kvm_init.)
3. **segkmem_mapin** (GLOBAL → weaken): leaf edits (`>>11→>>12`, `#2048→#4096`,
   `{0:21}→{0:20}`, `andiw#-2047→#-4095`); PTE low-byte format unchanged.  +sptalloc.
Build alongside pstart040, run `patch_pflusha_040.py`/`patch_pmmu_040.py`, test → page_init.

**LATER (next milestone — first user process):** the HAT batch.  `hat_pteload` is
DONE (`hat040.s`); add `hat_ptalloc`/`hat_sdtalloc`/`hat_growsdt`/`hat_pt2ptdat`
(+ `hat_alloc` 4→128 root) to `hat040.s` & `relink-hat.sh`.  hat_pteload's leaf
analysis transfers directly to segkmem_mapin (same PTE low-byte format).

## Map of the docs
- `hat-040-port-worklist.md` — the HAT-port plan (NEXT work).
- `mmu-format-030-to-040.md` — the exact 030/040 page-table format (the spec).
- `prototypes/pstart-040-design.md` — pstart040 design (done).
- `KNOWN-ISSUES.md` — ISSUE-1: clib2-built loader's 68030 MMU-config bug (deferred;
  use the UPSTREAM `unix_boot/bin/unix_boot` for any 030 baseline; OUR
  `build/unix_boot040` for 040).
- `LOCAL-BUILD-NOTES.md` — toolchains, paths, how to (re)build the loader.
- `boot-path-map.md`, `68040-68060-support-analysis.md` — background.

## Progress estimate: ~33% (high confidence now)
Foundation (RE, toolchain, loader, pstart) done; the HAT/VM format port is the
main remaining body, then reach single-user, then 68060, then HW stability.
