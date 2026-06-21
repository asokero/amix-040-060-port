# RESUME HERE — AMIX 68040 port status (2026-06-19)

## >>> MILESTONE 2026-06-22: 040 VM/HAT PORT FUNCTIONALLY COMPLETE — boots to swap config <<<
The 040 kernel now boots through EVERY VM/MMU/HAT layer and runs init + prints the banner:
pstart040 -> mlsetup -> kvm_init -> page_init -> kmem -> segmap -> svirtophys/vatosde/
vatopte -> **hat_pteload / hat_unlock / hat_ptfree / hat_unload** -> root fs MOUNTS ->
"UNIX(R) System V Release 4.0 ... 2.1c" banner -> init -> **swapconf**.
This session cleared, in order: hat_unlock, hat_ptfree (pfn>>12), hat_unload (the core
unmap), each an inert-030-tree-walker re-ported to the live kptr040 tree.  hat_unload also
got a bounded reverse-map unlink (findmap skips if the pte isn't in pages[pfn]'s list --
correct for kvsegmap pages mapped by segmap setup, verified by a sane *pte).

### CURRENT BLOCKER (NEXT): swapconf can't resolve /dev/dsk/c6d0s2
`PANIC: swapconf lookupname /dev/dsk/c6d0s2 failed - error 2` (ENOENT, CE_PANIC at
swapconf 0xb401e -> lookupname 0x5c290).  The swap path is a HARDCODED kernel string;
swapconf is the SAME code the stock 030 kernel runs, so on the 030 disk the node resolves.
This is likely the FIRST path lookup (namei) of the boot (root mounts by device, not path),
so it exercises namei -> s5lookup -> fbread/segmap -> hat (the buffer-cache path) for the
first time.  TWO hypotheses: (1) CONFIG -- the WinUAE 040 disk lacks /dev/dsk/c6d0s2; or
(2) a 040 namei/buffer-read bug returning wrong directory data.  OPEN QUESTION to the user:
is the WinUAE-040 disk the same amix_hardfileX11R5.hdf that reaches login on fs-uae-030?
If same+030-logs-in => real namei/buffer bug to chase; else => config.
NOTE: debug markers still in hat040.s (DBG ddopen, DBG hat_unload, revmap-miss) -- remove
once swapconf is past.  Build: sh relink-040.sh (+ relink-040-dbg.sh for the probes).


## ★ MAJOR MILESTONE (2026-06-19): 040 CPU/MMU/VM/fork port COMPLETE.
The kernel now boots all the way through MMU-enable -> paging -> kmem -> mlsetup/
kvm_init -> svirtophys -> **fork1/procdup (first process, HAT page tables) -> main()
-> vfs_mountroot**.  The HAT first-fork port (hat_pteload linked + ptalloc/sdtalloc/
pt2ptdat byte-patches + kas@0x14=kroot040) WORKED -- procdup's child-u-area bcopy no
longer faults.  The hard part (the whole 040 virtual-memory bring-up) is DONE.

## TWO LINES (2026-06-19; EMULATOR line SUPERSEDED by the 06-22 top milestone):
- **REAL-HARDWARE line: STILL PAUSED** (resume later).  On real 040 the VM port + 040
  page-table walk are verified working; it hits ONE localized blocker -- a deferred bus
  error in p0init's u-area-PTE loop (a real-silicon write-buffer/cache effect the emulators
  don't model).  Full writeup + open hypotheses + how to resume:
  **`RESUME-HERE-040-HARDWARE.md`**.  (Emulators do NOT reproduce it -- they pass p0init.)
- **EMULATOR line: the SCSI / root-mount problem (below) is now SOLVED** (root mounts;
  see the 06-22 top milestone).  Current emulator blocker = swapconf (top of file).

## >>> MILESTONE 2026-06-21: ROOT FILESYSTEM MOUNTS on 040 <<<
The SCSI/root-mount problem is **SOLVED**.  All disk I/O works on 040 (getrdb/getpb read
RDSK/PART correctly; stock sdpartition returns 0 with dev=0x480016 ctrl=0 slice=1 ->
partab filled -> VOP_OPEN succeeds -> root mounts).  Test-1's transient "error 6" was
first-access SCSI nondeterminism; it read clean on every retry.  **The boot now sails PAST
vfs_mountroot into the post-mount VM path.**

### NEW BLOCKER -> FIXED (needs boot test): hat_unlock: invalid sde
After mount, s5mountroot -> fbrelsei (s5 buffer release) -> **hat_unlock** (0xb5d1e)
PANIC "invalid sde".  Same inert-030-tree problem as vatosde: hat_unlock walked the 030
segment tree (root[region*8+4] -> 8-byte SDE) but the live root is kroot040 (040 4-byte
descriptors) -> garbage SDE -> DT==0 -> panic.  **PORTED**: prototypes/hat040.s now has a
hat_unlock 040 replacement (standard 040 walk A=va>>25&7f, B=va>>18&7f, leaf=Bdesc&
0xffffff00+(va>>12&3f)*4 -- same as vatopte; hat_pt2ptdat + lock-count + free_pts/wakeprocs
tail kept verbatim).  relink-040.sh: --weaken-symbol hat_unlock, --globalize-symbol
free_pts/pt_waiting.  Built clean (0 reloc complaints).  **NEXT: boot unix-040-dbg, expect
past hat_unlock -> next post-mount blocker (likely sibling HAT fns hat_unload/hat_chgprot/
hat_pagesync per the worklist, or 040 syscall/trap frames as init starts).**

## (historical) ACTIVE: root filesystem mount (DEVICE/FS domain, not MMU) -- the SCSI problem
`s5mountroot VOP_OPEN error 6` (ENXIO) -> `nfs_mountroot` fallback -> PANIC
`vfs_mountroot: cannot mount root: errno 89`.  `rootdev` = 0x00480016 = major 18 / minor 22.

### FULL OPEN-PATH TRACE (2026-06-21, disassembled from vanilla/stand/unix)
- bdevsw[18].d_open = **ddopen** (0xbcb8).  major 18 = the **dd** SCSI-disk driver.
- `ddopen(devp)`: ctrl = (*devp>>3)&1 = (22>>3)&1 = **0**.  Calls, in order:
    1. **`sdopen(ctrl)`** (0xd6ba): calls SCSI `init()` then returns ENXIO(6) unless
       `queue[ctrl][0] != 0` -- i.e. the host adapter for ctrl 0 is REGISTERED.
    2. **`sdpartition(*devp, ddstrategy)`** (0xd848): slice = (22>>4)&7 = **1** (nonzero)
       -> calls **`getrdb()`** = physically **READS the RigidDiskBlock off the disk via
       SCSI DMA**, parses partitions.  Returns ENXIO(6) on read/parse failure.
  Error 6 can come from EITHER call.  (If slice were 0 it'd skip getrdb -- but it's 1.)
- **SCSI host registration** (`init` 0xd736 -> `autocon` 0x19222 -> `insert` -> queue[]):
  the A3000 ONBOARD SCSI is NOT a Zorro autoconfig board; `autocon` has a hardcoded
  **special case**: if scsicard[0].field0==0x0202f003 && ctrl==0 && `0x07000000 < end`,
  it returns DMAC address **0xDD0000** and queue[0] gets set.  `end` = loader-resolved
  top-of-kernel (base+size, e.g. 0x07100000) so the gate `0x07000000<end` holds -> queue[0]
  SHOULD be set.  (Confirmed in fs-uae.log: "Initializing A3000 mainboard SCSI / Adding ...
  HD unit 6" / "00DD0000 64K A3000 DMAC" -- the emulator presents exactly this.)
- **DMA address translation**: SCSI uses `vtop`(0xb7568); for KERNEL buffers (arg2==0)
  it delegates to **`svirtophys`** (which we PORTED).  svirtophys returns `va` unchanged
  for region!=1 (identity: regions 0/2/3) and walks the 040 tree (vatosde/vatopte) for
  region 1.  So kernel-buffer phys is correct on 040 in BOTH regions.  => statically,
  BOTH sdopen and sdpartition should succeed; need RUNTIME data to see which fails.

### TEST RESULTS (2026-06-21, WinUAE 040, kernel @ 0x08000000)
1. ddopen probe -> **"sdpartition FAILED (getrdb RDB disk read / DMA)"**.  So sdopen
   (host registration) is FINE; the failure is in sdpartition.
2. sdpartition probe (calls real getrdb, prints block[0]) -> **"getrdb returned 0,
   block[0]=5244534B"** (== "RDSK") and "ddopen: both sub-calls OK".  **=> THE SCSI DMA
   READ WORKS on 040.  getrdb reads the RigidDiskBlock CORRECTLY.**  Not a DMA/cache bug!
   (With getpb/partab skipped, VOP_OPEN now succeeds but the mount still errno-89's
   because partab is left empty -- expected for the debug shortcut.)
**CONCLUSION:** the original "error 6" is NOT disk I/O -- it's in sdpartition's
**partition-block walk** (getpb 0xda22 / the rdb_PartitionList traversal / partab fill,
0xd876-0xd8ee), which the stock code runs AFTER getrdb.  getpb uses the SAME working
read()/block, so suspect: rdb_PartitionList (block@0x1c) value, or a PARTIAL block DMA
(block[0] ok but later longs stale), or the partab geometry math.  NEXT probe (built):
prints rdb_PartitionList + getpb result -> boot unix-040-dbg, read the two new DBG lines.

### DECISIVE DEBUG BUILD (ready): build/unix-040-dbg
`sh relink-040-dbg.sh` layers an instrumented **ddopen** (prototypes/ddopen_dbg.s,
GLOBAL-weaken override) onto the patched build/unix-040.  It prints (CE_WARN) exactly
which sub-call fails:
- `DBG ddopen: sdopen FAILED ...`      -> host registration (queue[0]==0): autocon/end/onboard
- `DBG ddopen: sdpartition FAILED ...` -> getrdb RDB read / **040 DMA** (the user's suspicion)
- `DBG ddopen: both sub-calls OK`      -> open succeeded; failure is upstream (rootdev/vfs)
**Boot it: `unix_boot040 unix-040-dbg`** and report which line prints -- that bifurcates
all further work (detection vs DMA).

### Emulator facts (fs-uae a3000ux config + log, this laptop)
- Working 030 config: `~/Asiakirjat/FS-UAE/Configurations/a3000ux.fs-uae` (cpu=68030,
  hard_drive_0=amix_hardfileX11R5.hdf, hard_drive_0_controller=**scsi6** = A3000 onboard
  SCSI unit 6).  Kernel files exposed to Amiga via hard_drive_2 = the kernelsupport dir.
- For 040 testing: switch cpu to 68040 (the WinUAE screenshots are the 040 runs).
- Aside (likely unrelated): fs-uae.log shows a `bzero` loop (PC=0x...032c) hitting "Gary
  timeout" writes to unmapped Zorro-III 0x2006xxxx -- some board-struct init, not SCSI.

SUSPECTS if it's **sdpartition** (DMA): (1) 040 copyback cache coherency on DMA-in (real
HW only -- emulator wouldn't show it); (2) the A3091 startdma (0xd40a) writes only a
24-bit DMA addr from iopb@12..14 -- verify the high byte / region is set for a buffer
above 16MB.  SUSPECTS if **sdopen**: autocon `end` gate or scsicard[0].field0 mismatch.
This is a NEW phase (device drivers on 040); the VM port this file documents is finished.

---
# (historical) RESUME HERE — AMIX 68040 port status (2026-06-18)

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

## (historical / DONE) NEXT TASK — port the HAT (Phase 3)  [ALL CORE HAT FNS NOW DONE — see top]
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

**CORRECTED DIAGNOSIS + FIX (2026-06-18 later): the kmem/seg_alloc/valid_usr_range
theory above was WRONG -- it misidentified the panic's LC label.**  Disassembly of
kvm_init's .data string pool (0x6700..) shows the six messages in order:
LC%0="No space for mapping files", LC%1="...u areas", LC%2="cannot allocate segkmap",
LC%3="segmap_create segkmap", LC%4="cannot allocate segu", LC%5="segu_create segu".
So the reported **"No space for mapping files" = LC%0**, used at **0x48cc0 -- the
`smsegs <= 0` check**, NOT the kvsegmap seg_alloc (that would print "cannot allocate
segkmap").  `smsegs = maxclick>>6 - (v+63)>>6` (0x48ca4..0x48cb4).
ROOT CAUSE: **pstart040 passed `v` (d2) to mlsetup as a 2KB-click high-water mark**
(its 030 table build computes d2 = (st_top1+12287)>>11, i.e. `lsrl #11`).  Under Model
B every downstream click consumer is 4KB: maxclick = memsize>>12 (halved, patched),
mlsetup's bzero does v<<12, sysseginit does v<<12, kvm_init's smsegs uses maxclick &
v together.  With v in 2KB clicks but maxclick in 4KB clicks, v is ~2x too big ->
smsegs collapses to <=0 -> panic.
**FIX APPLIED (prototypes/pstart040.s, tail before `jsr mlsetup`):** `addql &1,%d2 ;
lsrl &1,%d2` -- convert v to 4KB clicks (round up) so it matches maxclick.  d2 is dead
after mlsetup (Lpepi restores it from the saved-reg frame).  +4 bytes, .text stays
4-aligned, relink clean (0 complaints).  This also makes smsegs ~= half the 030 value,
which is exactly why the Tier-1 `<<18` kvsegmap/kvsegu window patches are correct
(half the segments x double the per-seg bytes = same window).  Built: `sh relink-040.sh`.
**TEST RESULT (smsegs fix): PASSED -- boot went through ALL of mlsetup+kvm_init**
(smsegs, susegs, kvsegmap/kvsegu seg_alloc, segmap/segu_create, p0init's own
svirtophys(u-area)) and hit the NEXT panic at pstart040's tail: **"PANIC: Svirtophys:
SDE_invalid"** (fs-uae + WinUAE identical).

**svirtophys FIX (2026-06-18, applied):** pstart040's tail calls
`svirtophys((*proc_sched + 95) & ~15)`.  `*proc_sched = &proc[0]` (a kmem_zalloc'd proc
struct in **kvseg**, region 1 ~0x40040000+).  `svirtophys` walks the **inert 030 tree**
via `vatosde` (`kas@(0x14)` -> tbl[1].addr=st_top1 -> st_top1[(va>>17)&0x1fff]); but the
kvseg mappings now live ONLY in the live **040 kptr040 tree** (sysseginit/segkmem write
there, not st_top1), so st_top1[kvseg_idx]=DT0 -> SDE_invalid.  (p0init's own
svirtophys(u=0x40000000) worked because pstart040 DOES populate st_top1[0]=the u-area.)
KEY: svirtophys's DT switch + cmn_err + phys assembly are FORMAT-AGNOSTIC -- it reads
the descriptor type via `bfextu @(3){6:2}` = byte-3 low 2 bits, which is the 030 DT AND
the 040 UDT (same bits).  So only the WALKERS change:
- **vatosde/vatopte ported to 040** (kvm040.s, GLOBAL T -> --weaken-symbol): vatosde
  returns `&kptr040[((va>>18)-4096)*4]` (the flat 040 pointer descriptor, exactly how
  sysseginit/kvm_init address it); vatopte returns `(*sde & 0xffffff00) +
  ((va>>12)&0x3f)*4` (040 leaf PTE).  No kas@(0x14) change needed -- vatosde reads
  kptr040 directly.  Also fixes krnxmemflt (the only other vatosde caller).
- **svirtophys phys assembly 4KB-patched** (patch_modelb.py: 0xb77c0 `&-2048->-4096`,
  0xb77c8 `&2047->4095`).
Built clean (`sh relink-040.sh`: vatosde/vatopte single strong defs, contiguous, 0
reloc complaints, 28 Model B patches).
**TEST RESULT (svirtophys fix): PASSED.**  Boot went svirtophys -> pstart returns ->
main() -> vfs_mountroot -> **fork1 -> newproc -> procdup** (creating proc 1) and hit a
**BUS ERROR pc=0x70002E6 = mcpy** (memcpy/bcopy worker; bcopy `bral`s to mcpy).
proc=0x4007EC00 (proc[0] now in kvseg -- proc_sched resolved correctly).

**THE HAT / fork MILESTONE (2026-06-18, Phase 4 -- the big remaining chunk):**
procdup does `bcopy(u=0x40000000, child_uarea, 0x2000)` to copy the u-area into the
child.  The child u-area comes from `segu_get` (segu = kvsegu 0x48440000, region 1),
which maps it via `hat_memload` (0xb4cb0, a tiny wrapper: pfn=(pp-pages)/60+pages_base,
then `hat_pteload`).  **hat_pteload writes the page-table entry the MMU walks -- but it
is (a) not linked into this build and (b) the kernel hat's root isn't the 040 root**, so
the child u-area VA is unmapped on 040 -> bcopy faults.  First PER-PROCESS mapping path.

ARCHITECTURE (verified): `hat_pteload` roots its walk at `arg@(12)@(20)` = the hat's
ROOT table, walking `root[va>>25&0x7F] -> ptr[va>>18&0x7F] -> leaf[va>>12&0x3F]`.  For a
region-1 kernel VA this standard 040 walk lands on the SAME `kptr040` entry as
sysseginit/vatosde's flat `(va>>18)-4096` indexing (root040[32+k]->kptr040+k*512, and
(kptr040+k*512)[Bidx] == kptr040[(va>>18)-4096]).  So IF the kernel hat's root = kroot040,
hat_pteload writes into root040->kptr040->leaf and the 040 MMU (SRP=root040) sees it.
`kroot040` is already exported by pstart040 for exactly this.

HAT PORT WORKLIST (the Phase-4 sub-project; full per-fn specs in
`prototypes/hat-040-port-worklist.md`):
- **hat_pteload** -- DONE (`prototypes/hat040.s`, 040 walk).  NOT YET in the build -- add
  hat040.o to relink-040.sh (it's `t` LOCAL -> globalize+weaken hat_pteload).
- **hat_memload** -- no port needed (page-struct arithmetic; calls hat_pteload).
- **hat_ptalloc** (0xb688e) -- allocate a leaf page table (4KB/64-entry on 040); port.
- **hat_pt2ptdat** (0xb5e0a) -- page-table addr -> ptdat; check page-size sites.
- **hat_growsdt** (0xb6058) / **hat_sdtalloc** (0xb632e) -- segment-descriptor-table
  alloc/grow (pointer-table level); port to 040 4-byte descs.
- **hat_alloc** (0xb4188) -- allocates the hat root via mem_align (4-entry 030 -> 128-entry
  040); AND the KERNEL hat's root must be set to kroot040 (hat_init only sets free-lists,
  so the root install is hat_alloc or the kas/segu setup -- find it).
- **flushmmu** -- called by hat_pteload; verify pflusha (already patched) or its own edit.

**HAT FIRST-FORK PORT DONE (2026-06-19) -- ready to boot-test.**  Scoping showed the
procdup-bcopy fault needs FAR less than the full HAT port: the child u-area uses the
KERNEL hat (already kptr040-rooted via kas@0x14=kroot040), and on first fork memory is
plentiful so the allocators take their SUCCESS paths -- which skip the structural
8->4-byte descriptor code (the page-table STEAL path) and never call hat_growsdt.  So:
- hat_pteload (040 walk, hat040.s) LINKED (relink-040.sh: globalize+weaken hat_pteload;
  globalize hat_ptalloc/hat_pt2ptdat so hat040.o's calls bind to the kernel LOCAL defs).
- hat_ptalloc/hat_sdtalloc/hat_pt2ptdat success-path click->byte shifts byte-patched
  (patch_modelb.py: b6a74, b63d6/b6484/b6524, b5e1c -- all `moveq #11->#12`).  Carve
  keeps 4 tables/page in the low 2KB of the 4KB click; >>11 page-frame index -> >>12.
- kas@0x14=kroot040 (pstart040 tail).  flushmmu pflusha already in patch_pflusha_040.
Build clean: hat_pteload single strong def, 33 Model B patches, 0 reloc complaints,
UND==stock.  **NEXT: BOOT build/unix-040 -- expect past procdup's bcopy (child u-area
now mapped on 040).**
DEFERRED (next blockers, when proc 1 faults in USER pages via its OWN hat): hat_growsdt
(8192->128 descriptor builder), hat_alloc (4->128 child-hat root), the hat_ptalloc STEAL
path (structural 8->4-byte descs + PFN 21->20 + asll#3->#2), uvirtophys/uvatosde/uvatopte
(user v->p walkers), and trap/exception-frame 040 work (bites on first syscall/fault).

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

## Progress estimate (2026-06-22): VM/HAT port DONE; boots to swapconf
Foundation + the entire HAT/VM format port are DONE (boots through init + banner to
swapconf).  Remaining to single-user: swapconf (current blocker), then first user
fork/exec (deferred per-proc hat fns: hat_alloc/dup/exec/asload/swtch), then **040
trap/exception frames** (biggest risk).  Then 68060, then real-HW p0init blocker.
(Old "~33%" estimate superseded.)
