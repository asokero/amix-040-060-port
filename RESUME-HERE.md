# RESUME HERE — AMIX 68040 port status (2026-06-18)

One-line: **68040 bootstrap paging WORKS; the kernel boots past pstart and prints
clean panics. Next = port the binary-only HAT/VM layer from 030 2KB page tables
to 040 4KB tables (the big phase).**

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

## NEXT TASK — port the HAT (Phase 3)
Full plan + inventory + the exact 030→040 format change: **`prototypes/hat-040-port-worklist.md`**.
Start with **`hat_pteload`** (the central PTE loader, 0xb4d64, ~710 B): relink-replace
it via `--weaken-symbol hat_pteload` (a new `hat040.s`), transcribe verbatim, then:
- (a) same-size immediate patches: VA decode `>>30/&3 -> >>25/&0x7F`, `>>17/&0x1FFF ->
  >>18/&0x7F`, page `>>11/+2047 -> >>12/+4095`, table stride `*8 -> *4`;
- (b) structural: 030 8-byte long descriptors -> 040 4-byte descriptors.
Then hat_ptalloc/hat_sdtalloc/hat_growsdt/hat_init -> kvseg maps -> page_init works.

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
