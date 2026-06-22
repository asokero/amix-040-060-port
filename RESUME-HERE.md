# RESUME HERE — AMIX 68040 port status (2026-06-22)

## >>> RESOLVED (2026-06-22 night): enqueue WORKS (maxrunpri=0x4F); bug = 040 ctx switch <<<
**MEASURED: `DBG sched ENTRY maxrunpri=4F` (=79, POSITIVE).**  Via a `--weaken-symbol sched`
override (mainmarks.s) that prints maxrunpri and spins, reached cleanly after all 4 daemon
u-areas map (8 ptload lines) and proc 0 ("sched") enters the swapper.  So the run queue is
NON-empty -- the children ARE enqueued and visible to the dispatcher.  This DEFINITIVELY kills
the "children invisible / maxrunpri==-1" theory (which was inferred, never measured) AND the
earlier "setrun never called" hunt (setrun is not on the fork path; the real enqueue is
newproc -> CL_FORKRET(cl_funcs@16) -> sys_forkret -> setbackdq, and newproc gives every child
SLOAD: child p_flag = (parent & 0x300000) | 0x10).

**=> The bug is the 040 CONTEXT SWITCH, not the enqueue.**  swtch idles only when
maxrunpri==-1; at sched entry it is 79.  So either (a) maxrunpri drops to -1 when proc 0
sleeps (if the pri-79 entry was proc 0 itself and the children sit at a level the scan
mishandles), or (b) swtch reaches the dispatch scan, picks the proc, calls resume -- and
resume/save (the 040 context switch) fails to transfer control (the "DBG resume" marker never
fired; hat_alloc ENTER never fired => no child ever runs its body).  The ml/ locore is the
suspect: save@0x84 (still 030 `pflusha f0002400`, tolerated only by the emulator), resume@0x9c,
idle@0x19c, + the child context set by setuctxt (procdup 0x418e8) + the 040 trap/exception
frames (memory's flagged biggest risk).

**NEXT: port/verify the 040 context switch.**  Concretely: (1) confirm whether swtch reaches
resume (override swtch or sleep, NOT a detour) or idles -- i.e. is maxrunpri still >=0 inside
swtch after proc 0 sleeps; (2) port save/resume/swtch dispatch + setuctxt child context for the
040 frame format; (3) the 040 trap/exception frames.

**INSTRUMENTATION RULE (learned this session, see memory [[040-detour-jmp-crashes]]):** byte-
patch jmp-DETOURS into relinked code Line-F-crash at the hook's first instruction on this 040
(setbackdq/sys_forkret/sched detours all failed identically); use `--weaken-symbol` OVERRIDES
(schedpaging/sched work).  Also use the C headers for struct offsets ([[kernel-source-vs-binary]]),
don't reverse-engineer them (that caused the setrun mis-diagnosis).

## >>> SOURCE MAP + BATCH PLAN (canonical; check source BEFORE reverse-engineering) <<<
Full map in memory `kernel-source-vs-binary.md`.  Summary:
- **HAS SOURCE (read/edit, don't RE):** trap/exception/vectors = `amix-src/sys/amiga/ml/
  ttrap.s`+`vec.s`+`syms.s` (ttrap.s `stkrestore:` = the 68020/030 frame-format/`framesz`
  handling = the 040 trap-frame edit point); all Amiga drivers/boot/console/SCSI under
  `amiga/`; ALL struct/flag/constant layouts in `include/sys/*.h` + `include/vm/*.h`
  (proc/class/disp/var/pcb/reg/trap/param/immu/vmparam/user/sysmacros, vm/pte, vm/seg).
- **BINARY-ONLY (RE/transcribe via --weaken override, see [[040-detour-jmp-crashes]]):**
  `os/exp` (newproc/sched/fork/procdup/main/p0init), `disp/exp` (swtch/setbackdq/ts_*/sys_*),
  `ml/exp` (save@0x84/resume@0x9c/idle@0x19c), `vm/exp` (hat_*/segu_*/seg*/as_*/page_*).

### Remaining 040 work as BATCHES (do related sites together):
1. **CONTEXT SWITCH (current blocker, BINARY/RE)** -- save@0x84, swtch dispatch@0xb902c,
   idle@0x19c.  resume@0x9c already transcribed (mainmarks.s, .word 0xf518 040 pflusha).
   save still has 030 `pflusha f0002400` (emulator-tolerated).  Verify swtch reaches resume
   (override probe) then transcribe save/swtch for the 040 register/frame save-restore.
2. **TRAP/EXCEPTION FRAMES (SOURCE)** -- edit ttrap.s `stkrestore`/`framesz` + vec.s for 040
   frame formats; use trap.h/reg.h/pcb.h.  Bites on first syscall/fault from init.
3. **child context (setuctxt, procdup 0x418e8, BINARY/RE)** -- sets the child's first-resume
   frame; must be 040-format for resume to transfer.  Pairs with #1/#2.
4. **per-proc HAT (BINARY/RE)** -- hat_alloc DONE; pending hat_growsdt@0xb6058 /
   hat_dup@0xb51xx (currently stubbed) = first user fork/exec.
5. **user SW page-table walkers (BINARY/RE)** -- uvirtophys/uvatosde/uvatopte (per-proc root);
   needed when the inert 030 st_top1 path is exercised for user procs.
6. **Model B 4KB sweep (byte-patch, 696 NEW sites kernel-wide; detect_pagesize.py)** --
   DONE groups (patch_modelb_pager.py): ufs,pvngp,segmap,buf,genst,bufbk,dmapio,segu.
   Needed-soon: **hat_chgprot** (×6, COW/protection on fork-exec).  DEAD on 040 (inert 030
   st_top1 builders, ignore): p0init/swapinub/segu_get-2nd-loop.  Rest: patch as each path
   is first exercised (the dispatch primitives setbackdq/dq_sruninc/swtch are already CLEAN).

## >>> (prior) REAL enqueue path found (setrun was WRONG target) <<<
**Methodology fix (user-flagged):** the kernel CORE (newproc/sched/swtch/ts_*/sys_* etc.)
ships ONLY as binary objects (`amix-src/sys/{disp,os,ml,vm}/exp` = ELF .o, NO C source) ->
function disasm is unavoidable.  BUT struct layouts/offsets/flags DO have C source:
`vanillarw/usr/include/sys/{proc.h,class.h,disp.h,var.h,ts.h}`.  STOP reverse-engineering
offsets -- read them.  Already corrected: p_stat@0 (SRUN=2), p_flag@4 (SSYS=0x1, SLOAD=0x10,
SPROCIO=0x400, SULOAD=0x2000), p_pri@24, p_cid@228, p_clproc@232, p_clfuncs@236.
classfuncs_t (class.h): cl_admin@0, cl_enterclass@4, cl_exitclass@8, cl_fork@12,
**cl_forkret@16**, cl_getclinfo@20, ... cl_setrun@52, ... cl_swapin@64, cl_swapout@68.

**Corrected diagnosis:** the earlier "setrun never called" hunt was a RED HERRING -- setrun
(0x489c2) is NOT on the fork path.  The real new-proc ENQUEUE is:
  newproc -> CL_FORKRET (cl_funcs@16 @0x41812) -> sys_forkret(0xba936) -> setbackdq(child).
(SYS class because main's 4 daemons are kernel procs; sys_fork sets clproc=the proc itself,
so sys_forkret(clproc)=setbackdq(proc).)  newproc's CL_ENTERCLASS error branch only LOGS,
it still falls through to CL_FORKRET, so the enqueue should happen.

**THE mechanism (read from setbackdq 0xb926e disasm + disp.h):** setbackdq always links pp
into dispq[p_pri], but only updates maxrunpri/dqactmap/dq_sruncnt -- i.e. makes pp VISIBLE
to the swtch dispatcher -- when `(p_flag & (SLOAD|SPROCIO)) == SLOAD`  OR  `SSYS(0x1)` set
(b92c0: andil #0x410 vs 16; b92d2: btst #0,@(7)=SSYS).  So if the children are enqueued with
BOTH SLOAD(0x10) and SSYS(0x1) CLEAR, they sit on the dispq INVISIBLE -> maxrunpri stays -1
-> swtch idles.  Exactly the observed symptom.  (On 030 the daemons must therefore have SSYS
and/or SLOAD set; if 040 fails to set the flag, that's the bug.)

**PROBE INSTALLED (boot build/unix-040-dbg):** setrun detour REMOVED; new setbackdq detour
(prototypes/patch_setbackdq_hook.py + mainmarks.s setbackdq_hook @0xd8128) prints
"DBG setbackdq pp=%x flag=%x pri=%x" for the first 6 calls.  Verdict table:
  - NO "DBG setbackdq" at all -> newproc->CL_FORKRET->sys_forkret->setbackdq broken on 040
    (next: detour sys_forkret 0xba936 + check the cl_funcs@16 indirect dispatch).
  - "DBG setbackdq" fires with flag having NEITHER 0x1 nor 0x10 -> THE BUG: child flag wrong
    on 040 (trace where SSYS/SLOAD is set for a new proc: newproc/procdup p_flag init).
  - fires with 0x1 or 0x10 set but resume STILL never fires -> bug is downstream in
    swtch/dispatcher maxrunpri scan (the 040 swtch port).
NEXT: boot unix-040-dbg, read the DBG setbackdq flag values.

## >>> (prior) hat_alloc + swtch DONE.  children not RUNNABLE <<<
The kernel now boots through swap config AND creates all 4 standard processes (proc 1
init + pageout + fsflush + aio -- confirmed via a kvsegu-VA ptload trace).  proc 0 then
runs sched() -> sleep(&runin) -> swtch, but **swtch idles** (jsr idle @0xb90fc, the
25-32% CPU spin) because **maxrunpri == -1 -- NO runnable procs**.  A verbatim resume()
override with a one-shot marker proved `DBG resume` NEVER prints (swtch never dispatches),
and the hat_alloc ENTER marker never prints (the children's child paths -- as_alloc ->
hat_alloc -> icode -- never run).  So: **the children are created but never put on the
run queue.**  newproc makes a child runnable via an INDIRECT scheduling-class op
(curproc@(228) -> class[cid] -> @(4) = CL_FORK/ts_fork @0x417b8) that should reach
setrun(0x489c2) (sets SRUN + dispq + maxrunpri).  That path is not completing on 040.
PROBED setrun with a detour (patch_setrun_hook.py + mainmarks.s setrun_hook overwrite
setrun's first 8 bytes with `jmp setrun_hook`): **`DBG setrun` NEVER fires -> setrun is
NEVER CALLED for any of the 4 children.**  So the bug is the fork->dispatch path, NOT
the dispq/maxrunpri update inside setrun.  newproc DOES mark the child SRUN directly
(`moveb #2,%a2@` @0x41742) and calls the scheduling-class ops (cl_funcs@(4) @0x417b8,
cl_funcs@(16) @0x41812, cl_funcs = class[cid] @a2@(236)), but the ts-class ops
(ts_fork @0xbaec2, ts_enterclass @0xbac36) do NOT call setrun.  setrun's real callers are
swapinub(0x4756c) + sched(0x47614) [swap-IN makes a proc dispatchable], the fork callers
(0x4fd4a/0x4fdf4/0x5fd48), wakeprocs(0x489ae), and 0x3dfaa.  So the child is SRUN but never
placed on the dispq (setrun) -> swtch dispatcher sees maxrunpri==-1 -> idle.
**NEXT: find WHO is supposed to call setrun(child) after newproc and why it doesn't on
040.  Two leads: (1) the children may be created !SLOAD (swapped-out) so sched->swapinub
(0x4756c) is meant to swap them in AND setrun them -- check if swapinub short-circuits/fails
on 040 (the u-areas ARE in core via segu_get, so the SLOAD flag may be the mismatch); (2)
the fork callers (cfork/fork1 @0x4fd4a etc.) call setrun after newproc -- check if main's
daemon-creation path reaches a setrun.  Mark swapinub / the 0x4fd4a-region setrun callers.**
(Also pending in this layer once children run: setuctxt's child stack copy + the 040 trap/
exception frames.)  Commits: f081e6d (hat_alloc+swtch), f2bad8c/eed4bdf/f55d48d (diag).
hat_alloc=040 root @as@(20); swtch pmove crp->movec urp (both correct, not the gate here).

## >>> (prior) READ-ZERO BUG FIXED + SWAP CONFIGURES + U-AREA FIXED <<<
The whole VM / page-cache / disk-I/O / swap-config / u-area path now WORKS on 040.  Boots
through swapconf, configures swap, creates proc 1, and goes IDLE at 0% CPU (a wait, NOT a
crash) in proc 1's setup because the per-proc hat + context switch are unported.  Three
root causes were found and fixed this session; the next blocker is the deferred fork/hat
layer (well-scoped below).

### FIX 1 — the read-zero / "swapconf namei" bug = gen_strategy PFN<<11 (DONE)
The "namei ENOENT" was NOT namei: directory page-reads returned an all-zero page
(blkatoff probe `PAGE phys=9D8B000 ram=[0 0 0 0]`).  ROOT CAUSE: **gen_strategy (0x3d988)**
converts a B_PAGEIO buf's page to a DMA-target PHYS = `PFN<<11` (0x3d9c0 single-page,
0x3dae6 breakup) and the device DMAs there; under Model B the page is at `PFN<<12`, so disk
data landed at HALF the address and the 4KB page stayed zero.  Found via a new whole-kernel
AUTO-DETECTOR `prototypes/detect_pagesize.py` (scans objdump for the 2KB idioms, attributes
to functions, excludes false-positives; reports **719** page-size sites kernel-wide, NOT
~150 -- the constant pervades the whole VM/FS/exec ABI; re-finds 85/94 known sites).  Fixed
with the targeted I/O-path groups in patch_modelb_pager.py: **genst** (gen_strategy 7),
**bufbk** (buf_breakup 3), **dmapio** (dma_pageio 7 -- its 512-byte sector >>9 logic left).
RESULT: dir reads return real data, ALL namei lookups resolve (`/dev/dsk/c6d0s2 -> r=0`).

### FIX 2 — swap now really configures (DONE)
relink-040-dbg.sh DROPPED the swapconf skip-stub (namei works now), so stock swapconf runs:
it opens `/dev/dsk/c6d0s2` (ddopen slice=2, r=0) and populates `swapinfo`.  This cleared the
`swap_xlate+0x26` NULL-swapinfo bus error (which was only ever a side effect of no-swap).

### FIX 3 — u-area maps as 2x4KB, not 4x2KB = segu_get/segu_softload (DONE)
First-fork u-area mapping hit `hat_pteload: pfn mismatch va=4844x800 *pte=...X newpfn=...X+1`
(a stock-030 FATAL check too, 0xb4eba -- NOT our over-strict assertion).  ROOT CAUSE:
**segu_get** allocates an 8KB u-area (anon_resv/page_get 0x2000) and maps it as a hardcoded
4 x 2KB pages (moveq #3 bound @0xaa6a2, #2048 va step @0xaa69c); under Model B page_get(8192)
returns 2 x 4KB pages -> consecutive pfns X,X+1 mapped 2KB apart -> same 4KB leaf -> mismatch.
Fixed with group **segu** (segu_get loop -> 2 iters/4KB step; segu_softload swap-in -> 4KB
step + >>11->>>12 index).  segu_get's SECOND loop (st_top1, the INERT 030 u-area page table)
is LEFT -- dead on 040 until uvirtophys is ported.  hat040.s's pfn-mismatch check is
temporarily WARN (prints va/*pte/newpfn) -- RESTORE to panic(3) once the u-area path is clean.

### >>> NEXT BLOCKER: the per-proc hat + context switch (the deferred fork/hat layer) <<<
After swap configures, main() does: schedpaging -> newproc(proc 1) -> as_alloc -> hat_alloc
-> segvn_create -> as_map -> copyout(icode).  The boot goes IDLE at 0-5% CPU here.
CONFIRMED (mainmarks.s schedpaging marker PRINTS -> swapconf returned; so the idle is in
proc-1 setup, not swapconf).  CONFIRMED in disasm (no boot needed) -- TWO unported pieces:
1. **swtch @0xb923c executes 030 `pmove %a1@,%crp`** (+ `pflusha` @0xb9240) to load the
   per-proc root -- an F-line on 040 (which uses `movec %dn,%urp`).  The scheduler therefore
   cannot switch to proc 1 -> proc 1 never runs -> proc 0 idles (idle, not crash = 0% CPU).
2. **hat_alloc @0xb4188** builds the per-proc root via `mem_align` -- the 4-entry 030 root;
   needs the 128-entry 040 root port (and to set the root so swtch's movec urp loads it).
Related unported (memory file): hat_growsdt/hat_dup (currently STUBBED in forkdbg.s),
uvirtophys/uvatosde (the per-proc 030 software walkers), and the **040 trap/exception
frames** (≠030 -- bites on proc 1's first fault/syscall; the memory's biggest-risk item).

**NEXT (recommended): port the per-proc hat + context switch as one coherent chunk:**
1. **hat_alloc** (0xb4188): build a 128-entry 040 root (like kroot040 but per-proc); zero it;
   store it where swtch reads the root from (hatp@? the as->hat).  Mirror the kroot040/
   sysseginit pointer-descriptor format.  hat_growsdt/hat_dup follow.
2. **swtch** (0xb923c): replace `pmove %a1@,%crp ; pflusha` with the 040 `movec %dn,%urp`
   (+ `pflusha` 040 form / cinv) -- a relink override (transcribe swtch tail) OR a byte
   patch (the pmove `f011 4c00` -> movec + the pflusha is already an F-line; patch_pmmu_040
   handles pflusha).  This is the same pmove-crp->movec-urp change needed in hat_map/exec/
   asload.
3. Build, boot: expect proc 1 to run the icode -> exec /sbin/init -> getty/login on console.
   The 040 trap-frame port likely bites here (proc 1's first user fault).

Build: `sh relink-040.sh` (-> build/unix-040) then `sh relink-040-dbg.sh` (-> build/
unix-040-dbg; ddopen + blkatoff + schedpaging-marker probes, hat_dup/anon_resv stubs).
Detector: `python3 prototypes/detect_pagesize.py` (719-site whole-kernel report; the full
Model B sweep is deferred -- patch path-by-path as each new code path is exercised).

### Diagnostics still in the tree (remove once past the fork/hat layer)
- hat040.s: DBG hat_unload/revmap-miss markers; pfn-mismatch lowered to WARN (restore to
  panic(3)).  ddopen_dbg.s, blkatoff_dbg.s, forkdbg.s (hat_dup/anon_resv stubs), mainmarks.s
  (schedpaging marker).  All layered ONLY in build/unix-040-dbg, not build/unix-040.
- **nomsg halt-path pmoves NOPed** (patch_pmmu_040.py 0x18ed8/ee2/ee6) -> clean panics.
  Context-switch pmoves (hat_map/exec/asload/swtch `pmove crp`) STILL unpatched -> item 2 above.


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
