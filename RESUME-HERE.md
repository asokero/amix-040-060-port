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

**BUILD READY TO TEST (2026-06-18):** `sh relink-040.sh` -> `build/unix-040` combines
pstart040 (kvseg scaffold) + kvm040 (sysseginit + segkmem_mapin), patches PMMU, 0
reloc complaints.  This should advance past the page_init+0x4a bus error IF the kvseg
map is correct.  **Boot it on 040 and read the next panic pc.**  Key insight from the
trace: the milestone needs **sysseginit** (builds kvseg pointer descs into kptr040)
+ **segkmem_mapin** (leaf PTEs) -- NOT kvm_init (its loops feed segmap/segu, used
later, and write to the inert st_top1).  Both ported under Model A (2KB clicks paired
into 4KB pages); consistent (kptr040[(va>>18)-4096] -> kptbl+P*256; segkmem writes
kptbl[(va-0x40040000)>>12]).

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
