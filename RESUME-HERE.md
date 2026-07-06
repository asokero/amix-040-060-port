# RESUME HERE — AMIX 68040 port status (2026-07-06)

## ►►► UPDATE 2026-07-06: reboot + fsck FIXED; clean boot→login→ls -alR→reboot cycle works ◄◄◄
Since the 07-04 login milestone, driving real workloads surfaced and fixed a chain of bugs
(all on **master** now; patch_modelb.py = **235 sites**).  **Full detail: KNOWN-ISSUES.md.**
- **ISSUE-5 (reboot) FIXED:** `reboot` ran an illegal 030 `pmove` (haltsys, reached via `rtnfirm`
  for fcn>=1) → now an unconditional 040 `movec`/`pflusha` MMU-disable (this is an 040-only
  binary; the AttnFlags guard misfired under the live Unix MMU).  v1/v2/v3 = commits 16fb98d/
  23a3532/ded2e58.
- **ISSUE-6 (fsck) FIXED:** `fsck` on a dirty UFS panicked `segvn_softunlock`; two Model-B misses —
  `swap_xlate`/`swap_anon` still ×2048 (2KB) → non-4KB-aligned anon `p_offset`; and a MISLABELED
  byte-patch at 0xabdae had made segvn_softunlock's inlined PAGE_HASHFUNC `>>12` while the other 7
  hash sites stayed `>>11` (a hash needs only consistency).  Commits faa1ace + 61dd64e.
- **Also fixed:** `hat_unload040` V2.3 (its table-frame guard rejected the kernel-image static
  kptr040 tables → it was a SILENT NO-OP for ALL kernel VAs; lower bound now `_start>>12`,
  commit 49c9c23); `segu_get` SEGU_LOCKED (the Model-B loop-bound patch `moveq #3→#1` also dropped
  the flag stored from the same register → segu_release passed hat_unload flags=0, keepcnt never
  released; `segu_lockfix` wrapper, commit 6efba29).

**OPEN — ISSUE-7 (the current frontier, KNOWN-ISSUES.md):** a SECOND boot from a kernel-
contaminated disk panics at the login prompt; a process's u-area has **`u_procp=0`** (a fresh-zero
page, via a NON-swap mechanism — 7 hypotheses ruled out by runtime probes: kmem free-list,
interrupt tables, remap-read, u_procp-at-trap-entry, swap daemon, segu_softunload, segu slot
double-alloc).  Root NOT yet found.  Deterministic repro: contaminate image B (boot+reboot once),
its next boot crashes; restore pristine image A → clean.  System stays USABLE for clean cycles.
Rich dbg diagnostic infra in place (ktrap_latch / preempt_dbg+tourniquet / kmem_validate /
segvn_softunlock_dbg / segu_swap_dbg / hatalloc_dbg LIVEABORT / execmark UTRAP).

**NEXT options (pick per session):** (a) continue ISSUE-7 with the resume-point probes in
KNOWN-ISSUES; (b) get BASE `unix-040` bootable standalone — migrate the dbg-only genuine fixes
(resume040 in mainmarks.s + real hat_dup040 from branch `040-hat-dup-port` = ISSUE-4) and strip
diagnostics; a "quiet" serial-capable variant is planned for real-HW testing (MAIN debug line
stays the full dbg build on the emulator); (c) real-HW testing (USB-serial adapter incoming);
(d) let the parallel Codex `analysis/` project map the whole kernel vs the source tree first.

---
## (historical) MILESTONE 2026-07-04: INTERACTIVE 040 LOGIN WORKS — ls / ls -al / uname -a all run
Boot (`unix_boot unix-040-dbg`) runs with **0 panics / 0 BUS errors** to a `root` login on the
040 kernel; `ls`, `ls -al`, `uname -a` all work at the shell.  patch_modelb.py = **234 sites**.
This is the first genuinely usable interactive 040 boot.

**Fix chain that got here (all committed on branch 040-switch-trace, boot-verified):**
- **date/hardbus infinite-loop hang** (commit 70344f0): a `jsr abs.L` whose extension word
  straddles a 4KB page boundary; the 040 reports FA = the crossing access's START (mapped page),
  the 030-semantic usrxmemflt tail misroutes to hardbus, which resolves the already-OK page and
  retries forever.  Fix = hardbus wrapper (sigkill_dbg.s): for a user addr within 8 B of a page
  end, as_fault BOTH pages; either resolving → return 0.  DBG-only crutch; the proper fix (port
  usrxmemflt's tail to 040 SSW MA-bit semantics) is still open, low priority.
- **"Killed" / rtld self-SIGKILL** (commit 44ebf05): anon_zero HALF-zeroed every ZFOD page
  (`pagezero(pp,0,0x800)` — a `pea 0x800` invisible to detect_pagesize.py) → the exec arg-block's
  envp NULL terminator (which relies on ZFOD zero) held garbage → rtld ate the auxv as environ →
  no AT_BASE → silent `_kill(getpid(),9)`.  Fixed + a batch of pea-0x800 fault-len args.
- **segu u-area /proc window** (commit 04edaed): 3 VOP page lens 0x800→0x1000 + prumap040.s
  (proc-0 kvsegu slot-0 alias into kptr040; p0init wrote it into inert st_top1).  Cleared the
  scrmenu/prgetpsinfo KERNEL FAULT (pid 43).
- **sptmap arena free-side** (commit 0d85da7): the kvseg arena was 4KB on the ALLOC side only;
  sptfree's `va>>11` freed the wrong slot → overlapping sptalloc → kmem heap corruption (ttymon
  panic pc=0x704211C).  23 byte-patches completing the coupled set (kmem_alloc/free oversize,
  sptfree, segkmem_mapout/segkmem_free walkers, kseg/unkseg).

**NEXT — drive the system, don't audit blind.**  Every fix this session was found because a real
command crashed, not by guessing which 2KB site to flip next.  Fastest path to the next real bug:
run heavier workloads (`ps -ef`, a compile, `ls -R /`, multi-process scripts) and read the serial
log.  Known-pending 040 ports that only trigger on specific paths (see the batch list below):
**hat_dup** (fork — NOTE: BASE unix-040 still has STOCK-030 hat_dup, only the dbg build stubs it,
so BASE is NOT yet boot-safe for fork-heavy loads), **hat_chgprot ×6** (fork COW), **hat_exec**
(exec-time stack move, 030 garbage-write source, currently neutered-by-guards), **uvirtophys/
uvatosde** user walkers, **vm_swap 2KB units** (real swap-out would corrupt).

**Serial-log note:** the endless `C<pid>:<PC>:<SR>` and `W <pid>:...` lines are NOT a bug — they
are leftover debug probes in prototypes/sigkill_dbg.s (clock_sampler, cap 1024) and mainmarks.s
(idle W-dump, cap 8).  `pid=0 PC=0x070D8EC2 SR=0x2000` = proc 0 idling in the kernel (healthy).
A quiet-dbg variant (or a clean base boot once hat_dup lands) removes them.  The `XPAGE` lines
are the hardbus page-crossing wrapper firing normally.  ALWAYS `grep -a` (log has NUL bytes).

### ►► SUPERSEDED (2026-07-03): the "commands get Killed" frontier ◄◄
Solved — see the "Killed / rtld self-SIGKILL" bullet above (anon_zero ZFOD half-zero, commit
44ebf05).  The earlier execstk_addr / setregs-copyin-EFAULT theory was a mis-diagnosis; the real
cause was the half-zeroed ZFOD page corrupting the exec arg block.  Banner "8 MB" was cosmetic
(main printed physmem/freemem `<<11`, counters were always right) — fixed.

## ►► PREVIOUS STATUS (2026-07-02) ◄◄
**2026-07-02: THE CHILD CRASH IS SOLVED (root cause proven, fix built, AWAITING BOOT TEST).**
The deterministic `User BUS ERROR FFFFFFFF PC:800024FE` in every fork+exec'd child was **NOT**
kernel page corruption, NOT a lazy-PLT/GOT[2] bug, NOT free-while-mapped (all those framings are
RETIRED): the fs-uae `AMIXE48` watch caught the write **`addr=80010e48 val=ffffffff s=0
PC=80002494` = USER-MODE, sh ITSELF** storing sbrk()'s return value.  Chain (disasm-verified in
/sbin/sh): malloc calls sbrk(0x600) -> kernel **brk() rounds nva/ova to 2KB** (`+2047 >>11 <<11`
@0x58130/0x58136/0x58144 — an unpatched Model-B straggler) -> ova=0x80011800 lands INSIDE the
4KB-rounded exec data/bss segment (ends 0x80012000) -> as_map overlap -> ENOMEM -> sbrk returns
-1 -> malloc stores -1 in its arena head (0x80010e48) and writes through it (`movel %a0,%a1@`,
a1=-1) -> BUS ERROR at FFFFFFFF, PC = next insn 0x800024FE.  init survives because its break
rounds identically at 2KB and 4KB.  **FIX: 8 byte-patches in patch_modelb.py (brk 3 + grow 5,
2KB->4KB roundups/shifts), built into unix-040 + unix-040-dbg.**  Also this session:
hat_chgprot040 boot-tested (fires, kept — real fork-COW bug, but wasn't the crash);
hat_exec probe added (clean brackets = hat_exec NOT the corruptor; still unported, flag=1 path);
anon_decref dbg wrapper found DEAD (symbol is file-local `t` — weaken can't bind it).
**BOOT-VERIFIED (2026-07-02 eve): 0 BUS ERRORs — children run past malloc, rc scripts exec real
programs.  NEW FRONTIER hit next: `PANIC: swap_xlate`** (user fault -> segvn_fault ->
segvn_faultpage -> anon_getpage got a garbage anon ptr) once fork/exec/unmap churn started.
ROOT CAUSE: the seg_vn/as user-VM family was only PARTIALLY 4KB-converted (fault path 4KB, the
create/dup/unmap/free/setprot/... family still 2KB) = the exact mixed-granularity hazard the old
as_setprot post-mortem warned about (e.g. segvn_unmap's split path computes anon_index with 2KB
math against 4KB-indexed anon arrays).  **FIX: +99 byte-patches (detect_pagesize.py-classified,
gen_uservm_patches.py-verified) completing the whole coupled set** — segvn_create/extend_prev/
extend_next/anonmap_alloc/dup/unmap/free/softunlock/non_anon/faulta/unload/setprot/checkprot/
getprot/kluster/swapout/sync/incore/lockop/vpage/isanon + as_faulta/setprot/checkprot/unmap/map/
incore/ctl + map_addr.  patch_modelb.py now 176 sites; both kernels rebuilt, relocs clean.
DEFERRED (noted in patch_modelb.py): as_iolock, execstk_addr, phystopp, vm_swap internals.
**BOOT-VERIFIED (2026-07-02 night): no swap_xlate panic, 0 BUS ERRORs — the system is ALIVE and
responds to Enter on the console.  NEW FRONTIER: `ldterm/console_get_buffer: out of blocks` =
allocb's kmem_alloc(KM_NOSLEEP) returns NULL = kernel heap genuinely exhausted after ~36 execs
(~150-200KB lost per process; allocb has NO strthresh check on this path, so it IS memory).
Suspects: exit teardown not returning pages (as_free/segvn_free/anon chain) vs processes never
exiting vs (small, known) hat PT leaks.  MEASURE FIRST: the hat_exec dbg probe now logs
freemem/availrmem/availsmem per exec (cap 64).  NEXT: boot unix-040-dbg, then
`grep -a "hat_exec ENTER" /tmp/amix-boot.log` -> read the freemem trajectory: never recovers
after exits = teardown leak; stable = STREAMS-pool-specific.
(NOTE: the serial log contains NUL bytes — plain grep silently matches nothing, ALWAYS -a).**

## ►► PREVIOUS STATUS (2026-06-26, superseded) ◄◄
The 040 kernel now boots with **0 kernel panics** all the way to **/sbin/init running its rc scripts
(/etc/sysinit, /etc/brc, /etc/rc2) and spawning the multi-user/login entries (/etc/getty,
/usr/lib/saf/sac) from /etc/inittab** -- i.e. the THRESHOLD of a console login.  THREE bugs solved
this session (branch 040-switch-trace, all committed, boot-verified): (1) **gen_strategy d3 #4->#8**
(disk sectors-per-page; the multi-page B_PAGEIO 2KB straggler) -> the GOT/dynamic-linker bug is GONE
(libc.so.1 relocates, 872 GOT writes, init's _start runs).  (2) **uvatosde040** (per-proc user
page-table walker 040 port) + usrxmemflt inline-leaf patches -> COW/F_PROT faults resolve (init's
write-protect faults work).  (3) **hat_free040 garbage-slot skip** -> no KERNEL FAULT on child-exit
teardown.  **CURRENT FRONTIER (next task): every exec'd CHILD wild-jumps (`User BUS ERROR FFFFFFFF
PC:800024FE`) -- a lazy-PLT/GOT[2] (=_rt_bind) base bug, CONFIRMED SYSTEMATIC on a clean FS.  See the
section immediately below.**  Build: `sh relink-040.sh` (base) + `sh relink-040-dbg.sh` (dbg).

## ★★★★★ 2026-06-26 CONFIRMED SYSTEMATIC (clean FS): children wild-jump via PLT[0] -> GOT[2] wrong
Re-booted on a KNOWN-CLEAN (fsck'd) FS: the child fault `User BUS ERROR FFFFFFFF PC:800024FE` is
DETERMINISTIC (18x, every exec'd child: getty/sac/autopush/rc2/sysinit) -- NOT FS corruption.  0
kernel panics (hat_free040 robust).  MECHANISM (static, from autopush): the program's lazy PLT --
`PLT[n]: jmp *JMP_SLOT` -> push index -> `PLT[0](0x5d0): push GOT[1]; jmp *GOT[2]`.  In the FILE
autopush's GOT[1]=0 (link map) and **GOT[2]=0 (the lazy resolver _rt_bind)**; the rtld sets them at
runtime.  The wild jump to 0x800024FE = program_base(0x80000000) + 0x24FE means **GOT[2] was set to
0x800024FE** (program base + 0x24FE) instead of libc's _rt_bind (0xC10xxxxx) -> `jmp *GOT[2]` lands
in autopush's unmapped TEXT-DATA GAP -> executes garbage -> derefs FFFFFFFF.  So _rt_setup computed
the child's lazy resolver with the WRONG base.  KEY DIFFERENCE: init is exec'd by the KERNEL (works,
GOT resolved -- rexit dump shows C101116E) but the children are exec'd by a USER process (the init
shell) -> suspect the kernel's USER-initiated exec path (elfexec auxv AT_BASE for the interp, or how
the interp/_rt_setup runs for a user-exec) sets up the child's interp base wrong.  Children's auxv
AT_BASE was NOT yet captured (the rexit dump with AT_BASE=C1000000 was INIT's, not a child's).
**NEXT: capture the CHILD's runtime GOT[2] + auxv AT_BASE -- via the instrumented fs-uae (trace the
child's PLT[0]@0x800005d0 + the value read from GOT[2]@0x80003e40) OR a kernel probe in elfexec's
auxv build.  Then fix the base used for the child interp/_rt_bind.**  Source refs: SVR4-3b2
lib/rtld/m32/reloc.c + rtld.c (GOT[1]/GOT[2]/_rt_bind setup), the AMIX elfexec (0xb80f2) auxv build.

## (DONE, VERIFIED) hat_free040 robust -> NO KERNEL PANIC, init runs rc + spawns getty/sac
The hat_free040 garbage-slot skip (commit 689db7d) WORKS: boot shows **0 kernel panics**.  hat_free
was bus-erroring on a pointer-table at region A=6 filled with the 030-invalid pattern 0xFFFFFFFF
(Bdesc=FFFFFFFF, UDT=3 looked "valid"); now it validates leaf base in [pages_base,pages_end) and
SKIPS bad slots (12 logged, A=6 B=0..11, bounded leak).  Source of the FFFFFFFF table = stock-030
hat_growsdt/hat_dup region fill (not yet ported; skip is the robust fix).  **init now runs its rc
scripts (/etc/sysinit, /etc/brc, /etc/rc2) and spawns the multi-user/login entries (/etc/getty,
/usr/lib/saf/sac, /sbin/autopush) from /etc/inittab.**  We are at the threshold of a console login.
**NEW BLOCKER: every exec'd CHILD takes `User BUS ERROR at FFFFFFFF PC:800024FE` and respawns in a
loop.**  PC 800024FE is in autopush's TEXT-DATA GAP (text ends 0x8000139C, data starts 0x8000339C) =
a WILD JUMP into unmapped space.  autopush's relocations are **R_68K_JMP_SLOT (LAZY PLT** for
exit/open/printf/ioctl/getopt...): the program calls a libc fn via the PLT, and if the lazy resolver
(GOT[2]=_rt_bind) / PLT stub isn't set up, the jump lands in garbage.  init (kernel-exec'd) + the
init shell got far enough, but these children wild-jump.  **CAVEAT (user, 2026-06-26): the disk image
FS corrupts intermittently from our boots -> some boots fsck, some don't, and a corrupted autopush
file would ALSO produce a garbage GOT/PLT -> the SAME wild jump.  So CONFIRM this reproduces on a
known-clean FS before investing in a lazy-PLT-resolver fix.**  NEXT: verify determinism (clean FS),
then if systematic, investigate the lazy PLT/_rt_bind setup for child execs (cf. SVR4-3b2 rtld
rtbind.c).  Also still open (deferred, robust skip in place): the region-A=6 FFFFFFFF table source
(hat_growsdt 040 zero-fill).

## (DONE, VERIFIED) uvatosde040 -> COW WORKS, init runs rc scripts
The uvatosde 040 port (commit, uvatosde040.s + usrxmemflt inline-leaf patches) is BOOT-VERIFIED:
the F_PROT/COW path now resolves -- serial shows `as_fault addr=C102F11C type=1 rw=2 ret=0` (a
genuine F_PROT/COW write fault, ret=0) and `GOTmap C102F000 prot=F` (the GOT page COW'd to a
writable private copy).  The 0x5B088 bus error is GONE.  **init now runs its rc scripts** -- it
forks a shell and execs `/sbin/autopush -f /etc/amiga.ap` from /etc/inittab.  uvatosde040 does the
full per-proc 040 walk (curproc->p_as@(124)->root040@(20) -> A=va>>25&7f / B=va>>18&7f / C=va>>12&3f)
and returns &PTE; usrxmemflt's two inline 030 leaf walks (0x5b072 F_PROT, 0x5b0fc hardbus) are
byte-patched to `moveal %a0,%a2` to consume it.
**NEW BLOCKER: KERNEL bus error pc=0x5B088->now 0xD8064 (hat040.s `Lf_PTE`) during a CHILD's exit.**
Backtrace: exit -> relvm -> as_free -> **hat_free** -> Lf_PTE `tstl %a3@` where a3 = leaf base
(Bdesc & 0xffffff00) is INVALID.  The child (autopush) first took a `User BUS ERROR at FFFFFFFF
PC:800024FE` (reason TBD -- maybe a real missing feature, maybe a bad page) -> exit -> teardown.
ROOT (likely): **hat_dup (0xb502a, fork's page-table copy) is NOT 040-ported** -- STUBBED in the dbg
build (forkdbg.s), STOCK 030 in the base build -> fork builds the child a malformed 040 tree (a
pointer-table slot with UDT set but a garbage leaf base) -> hat_free040 walks it and bus-errors.
**NEXT SUB-PROJECT = the user-VM fork/teardown HAT family: port hat_dup (+ likely hat_growsdt) to
040 (copy the per-proc root040->ptr->leaf tree), and/or make hat_free040 robust to a stale slot.**
Also open: WHY autopush user-faults at FFFFFFFF (investigate after the kernel teardown is clean).

## (DONE, VERIFIED) usrxmemflt F_PROT/COW path -- uvatosde040 + inline-leaf patches
The gen_strategy d3 #4->#8 fix (commit a3668a8) is BOOT-VERIFIED on the instrumented fs-uae:
c100f348=204f, c100f364=61ff (correct _rt_boot), **c10127b4=4e56 (_rt_setup RUNS)**, reloc loop
iterates, **872 GOT writes relocate the whole GOT**, then c100f370 `jmp %a0@` -> init's relocated
_start.  The whole GOT/linker sub-project (C1012088 bus error) is SOLVED; init runs (serial: pid 5).
**NEW BLOCKER (serial): KERNEL bus error pc=0x5B088 fmt=7 in usrxmemflt+0x1aa while pid 5 init runs.**
Backtrace u_trap->k_trap->usrxmemflt.  It's the **F_PROT/COW path** (5b040: SSW bit 0x800) -- so
**ptest040 (526b708) is now PAYING OFF** (init's write-protect fault is correctly classified F_PROT,
not F_INVAL).  The handler crashes at 5b068-88: `jsr uvatosde` (per-proc SW page-table walker) then
leaf PTE addr = SDE@(4) + `((VA>>11)&0x3f)*4` (0x5b078) -> `bfextu a2@(3)` @0x5b088 bus-errors (a2
invalid).  TWO causes: (1) **uvatosde(0xb74f8)/uvatopte/uvirtophys(0xb7860) are STOCK 030 walkers,
UNPORTED** (no override exists) -> walk the INERT 030 tree -> garbage SDE; need an 040 per-proc-root
port (like kernel vatosde040 in kvm040.s).  (2) usrxmemflt leaf `(VA>>11)&0x3f` is a 2KB straggler at
**0x5b078 + 0x5b102** (check siblings 0x5afa0/0x5b02e) -> >>12.  **NEXT SUB-PROJECT = uvatosde/
uvatopte/uvirtophys 040 port + usrxmemflt leaf >>11->>>12 (+ likely hat_chgprot x6 COW).**  This is
the user-VM SW-walker + COW frontier, now live because init runs COW faults.

## (DONE, VERIFIED) gen_strategy disk SECTORS-PER-PAGE d3 #4->#8
The 2KB straggler is `gen_strategy` **0x3d9e6 `moveq #4,%d3`** (disk sectors per page = 2048/512 = 4).
Pinned by static analysis in source order (Amiga image -> root=ufs; SVR4 ufs_vnops.c; gen_strategy
binary).  init's libc.so.1 text fault (off=0xF000) -> ufs_getapage; root fs_bsize=8KB (>4KB page) ->
lbnoff=0xE000 -> pvn_kluster builds a **2-page cluster** (0xE000+0xF000, io_len=8KB).  gen_strategy's
**multi-page breakup loop** (0x3da20, b_pages!=NULL, bcount>4096) deposits it: `b_blkno = base +
d3*page_index` (0x3daa2).  The per-page DMA byte count d1 (0x3da40) was ALREADY patched to 4096, but
**d3 stayed 4** -> page[1] reads 4096 bytes from disk base+4sec (=2KB=file 0xE800) not base+8sec
(=file 0xF000) -> C100F000 = file[0xE800..] -> C100F348 = file[0xEB48], EXACTLY the observed bug.
Single-page reads (the dir-read validation) never enter this loop -> never exercised.  FIX in
`patch_modelb_pager.py` group genst: 0x3d9e6 `7604`->`7608`.  BUILT (relink-040.sh + -dbg.sh, 88
pager patches, 0 complaints, byte-verified).  ALL the offset-arithmetic suspects (as_fault/segvn_
fault/ufs_getpage/ufs_getapage/pvn_kluster) were proven 4KB-CORRECT in the live build -- the bug was
the DISK-SECTOR STRIDE, not an offset.  (buf_breakup 0x3d21e `pea 0x800` = a separate latent 2KB site
in the LINEAR-buffer path, NOT on init's path; convert later if it bites.)  **VERIFY: boot
build/unix-040 on the instrumented fs-uae -> AMIXPC f348=204f, f364=61ff, C10127B4(_rt_setup) fetched
-> GOT relocated -> init past C1012088.**

## OVERALL STATUS (2026-06-26 -- ROOT CAUSE pinned by an INSTRUMENTED fs-uae; FIX above)
68040 port boots to **/sbin/init running its DYNAMIC LINKER** (libc.so.1 interp @C1000000); the
0x66000030 bus error is GONE.  **DEFINITIVE ROOT CAUSE (PC-accurate, via an instrumented fs-uae):
the demand-paged TEXT page C100F000 is loaded from FILE offset 0xE800 instead of 0xF000 -- exactly
0x800 (2KB) TOO LOW -- a Model B 2KB file-offset straggler in the text-segment demand-paging path.**
Proof: a patched fs-uae `mmu_get_iword` logged the actual WORDS fetched while executing `_rt_boot`
at C100F348+; every word was WRONG (got 0000/0016/0002/f9fe... = an Elf32_Rela table, r_info type
0x16=R_68K_RELATIVE) where `_rt_boot` code (204f/2f3b...) was expected.  A file search placed the
runtime bytes at C100F348 at file 0xEB48 = 0xF348 - 0x800.  So `_rt_boot`'s `bsrl _rt_setup`
(file 0xf364, should be `0x61ff`, reads `0x0002`) is GARBAGE -> **`_rt_setup`(0x127b4) NEVER runs**
(AMIXPC trace confirms C10127B4/C10128DE are never fetched) -> the GOT is never relocated -> init
bus-errors (PC C1012088, /sbin/init).  This RETIRES all earlier symptom-theories (COW/ptest
classification, aliasing, the -0x800 .rela DATA read, "loop runs but stores vanish") -- they were
ALL downstream of running CORRUPTED libc code.  **NEXT (the fix):** find the getpage/kluster site
that computes the text page's file-offset ONE 2KB-click too few (page C100F000 = seg-offset 0xF000
= click 0x1E, loads from 0xE800 = click 0x1D); fix in `prototypes/patch_modelb_pager.py`
(ufs_getapage/pvn_getpages/pvn_kluster/segmap family).  Prime suspect: pvn_kluster read-behind
start-offset, OR ufs_getapage file-offset->block.  Same family as the already-fixed
gen_strategy/pvn_*/segmap stragglers -- this one just never ran before init exercised it.

### TOOL: instrumented fs-uae (THE breakthrough enabler -- PC-accurate ground truth)
Source `kernelsupport/fs-uae` (git, **checkout v3.2.35** = SDL2, matches the user's binary; master
needs SDL3 -- GITIGNORED, do NOT commit).  Patches (AMIX-DBG comments): `src/include/cpummu.h`
(mmu_get/put_long/word/byte + mmu_get_iword PC+word trace), `src/cpummu.cpp` (mmu_*_slow = the
faulting/ATC-miss path), `src/rpc.cpp` (debuggable()->1).  Build: `cd kernelsupport/fs-uae &&
make -j8` (deps: libtool libsdl2-dev libopenal-dev libmpeg2-4-dev libflac-dev).  User runs it by
full path from `kernelsupport/fs-uae` with `flush_log = 1` in the config (else the log buffers at
~57KB); log = `~/Asiakirjat/FS-UAE/Cache/Logs/fs-uae.log.txt`.  Use a CLEAN disk image (torn-file
boots corrupt it).  Success criterion for the fix: AMIXPC shows the CORRECT `_rt_boot` words
(f348=204f, f364=61ff) and C10127B4 (_rt_setup) IS fetched.

## SOURCE-CONSULTATION ORDER (user rule -- ALWAYS follow before digging into binaries)
When you need to understand a function or layout, check sources in THIS order:
1. **Amiga Unix disk-image tree FIRST** -- `~/kehitys/amix-playground/vanilla/usr/sys/` and
   `vanilla/usr/src/` (the image is ALWAYS mounted there) + extracted `kernelsupport/amix-src/sys/`.
   129 C files exist, but `vm/` is binary-only (just `exp`+Makefile).  Always check here first for
   headers/struct layouts and the fs/exec/os modules that DO ship C.
2. **Related System V sources SECOND** (full C for VM/pager): `kernelsupport/usl-svr42/common/uts/
   mem/{vm_pvn.c,seg_vn.c,seg_map.c}` (SVR4.2, closest), `kernelsupport/svr4-src-3b2/`,
   `kernelsupport/svr4-v4/`.  Not Amiga, but the SVR4 logic is stable.  (gitignored -- copyright.)
3. **Ghidra decompilation of the unix kernel THIRD** -- `sh tools/ghidra-decomp.sh func1,func2`
   (headless, MC68030, decompiles named fns of `vanilla/stand/unix`; calls show as `func_0x0` --
   resolve with `m68k-linux-gnu-objdump -d -r`).  GUI project at `ghindra-unix/amix.rep` (gitignored).
   Use this for the binary-only core (vm/os/disp/ml `exp`) BEFORE hand-disassembling.
4. **Raw binary disasm LAST** -- `m68k-linux-gnu-objdump -d -r --start-address/--stop-address`.

## (SUPERSEDED 2026-06-25 -- refined by the 06-26 text-page finding above) SMOKING GUN
68040 port boots to **/sbin/init running its DYNAMIC LINKER** (libc.so.1 interp @C1000000).  The
0x66000030 bus error is GONE.  init jumps to the interp entry C100F348; the linker runs but
**libc.so.1's GOT is never RELOCATED -> the linker reads its own _rt_warn/_rt_tracing through the
raw GOT, gets garbage, and `_exit(0)`s cleanly before init's _start runs.**  THREE theories were
chased and KILLED this session: (1) ptest/F_PROT misclassification; (2) RMW-write-drop (the GOT
relocs are ALL R_68K_RELATIVE PLAIN stores -- via the SVR4-3b2 rtld source); (3) "fs-uae drops user
stores to COW'd pages" (REFUTED by reading fs-uae cpummu.cpp -- user write-protect WRITES fault
correctly).  The 3 fixes built for those (eager-COW segvn_cow040.s, pflusha, usrxmemflt-trace) were
WRONG-MODEL and were **REVERTED (commit a429df1)**.  **CORRECTED ROOT (SMOKING GUN): the interp's
`.rela.data` file page maps 0x800 (2KB) TOO LOW -- a Model B 2KB file-offset straggler in the
demand-paging path.**  Proof: SVR4-3b2 `rtld/m32/rtsetup.c` shows `_rt_setup`(0x127b4) self-relocates
ld.so via `*(ld_base + r_offset) = ld_base + r_addend` over DT_RELA..DT_RELA+DT_RELASZ.  At runtime
AT_BASE=C1000000 and `.dynamic`(DT_RELA=0xd0f8, DT_RELASZ=0x2250) are BOTH correct, so reladdr=
C100D0F8.  But a rexit probe reading C100D0F8 (should be .rela.data[0] = `0002E014 00000016
00011080`) got the ASCII strings `_devzero_fd\0ungetc\0sigs` = FILE offset **0xc8f8** -> 0xd0f8 -
0xc8f8 = **0x800**.  So _rt_setup reads .strtab strings where its relocations should be -> the GOT is
never relocated (a RAM scan for the relocated _rtmalloc C101116E found it NOWHERE).  OPEN LINK
(don't over-claim): if the loop read this -0x800 garbage during the NORMAL run the bad type byte
0x72 != RELATIVE(22) would SIGKILL, but we see a clean _exit -- so first CONFIRM the -0x800 is a
normal demand-fault bug (dump C100D0F8 via an EARLIER hook, not rexit) and not a teardown artifact.
Then FIND+FIX the 2KB straggler in segvn_fault/ufs_getpage's page file-offset (= svd->offset +
(page_va - seg_base); a remaining >>11/0x800 round) -- same family as gen_strategy/pvn_*/segmap.
Diags live: assegat_dbg.s rexit probes 'L'(rela)/'D'(.dynamic)/'Z'(RAM scan)/'P'(phys PTE)/auxv
stack dump.  REFERENCE SOURCES (gitignored, do NOT commit -- copyright): `svr4-src-3b2/` (SVR4 VM +
rtld C source) and `fs-uae/` (68040 MMU emulation cpummu.cpp).  Real 040 HW (a3640/Mercury) =
separate later track (no serial cable now).  See [[amix-040-init-userpage-pfn]] (newest section).

## >>> ★ USER-PT FRONTIER (2026-06-24): hat_pt2ptdat invalid pte ptr -> port the user page-table builder <<<
exec maps init's ELF segments (`execmap vaddr=80000034 filesz=66D4` / `vaddr=80008708 prot=F`),
then demand-faults va=80009000: segvn_faultpage -> hat_memload -> hat_pteload(040, 0xd7604) ->
hat_pt2ptdat -> PANIC "invalid pte ptr".  hat_pteload Lbhave reads the pointer-table slot
(`slot=7D20200`), `Bdesc=0x003F0002` -> leaf base 0x3F0000 = an UNBACKED memory hole (RAM is at
phys 0x07000000+, chip RAM ends at 2MB), so `*a4=0xFFFFFFFF` and hat_pt2ptdat(a4>>12) sees a bogus
pfn -> panic.  **NARROWED to the exec VM teardown/rebuild (diagnostics, two boots):** hat_ptalloc
is FINE -- the Lballoc print showed `Lballoc leaf va=8001F800 leafpt=7D3A400` (a valid RAM
0x07D3A400), and hat_sdtalloc's PFN<<11 sites are already <<12.  The CRUCIAL log sequence: the
first user faults (va=8001F800, same Bidx=0 -> same slot[0]) get a GOOD leaf 0x07D3A402; THEN exec
runs `V`(relvm) -> `hat_free ENTER as=401AA400` (tears down the old AS) -> `execmap` (new binary)
-> the va=80009000 fault reads slot[0] = 0x003F0002 (CHANGED).  So the bad descriptor appears ONLY
AFTER teardown+rebuild.  ROOT: stock 030 `hat_free`/hat_dup/hat_growsdt walk the INERT 030 st_top
tree, NOT the live 040 pointer tables hat_pteload built, so they free the underlying pages but
leave a stale/garbage 040 pointer-table slot.  NEXT: trace ptr-table 7D20200 slot[0] across
hat_free (what writes 0x3F0002 -- hat_free's leaf-free, or a fresh-but-unzeroed pointer table on
rebuild); port hat_free + the user-VM HAT family to maintain the 040 tables.  Diagnostics in
place: hat040.s Lpemsg1 (leaf/slot/Bdesc dump) + Lbamsg (Lballoc result).  Memory
[[amix-040-init-userpage-pfn]].

## >>> ★★ EXEC-HEADER FRONTIER SOLVED (2026-06-24, commits c8be89f/4b18053, boot-verified) <<<
The coupled 4KB page-cache conversion (patch_modelb_pager.py, groups pgget+pvnk + pvn_done): (1)
**pgget** page_get-internal `(size+2047)>>11 -> (size+4095)>>12` (0xaffb8 #2047->#4095; 0xaffbe
moveq #11->#12 = shift count in d1, NOT the lsrl at 0xaffc0) -- the missing keystone (patch_modelb.py
had already converted the variable-size callers segkmem_alloc/hat_sdtalloc/segu to expect size/4096
frames, leaving page_get at 2x).  (2) **pvnk** pvn_kluster rounds the cluster to 4KB + steps the
file offset 4KB/page (0xb19b2 #2048->#4096 + rounding consts) -- pvnk ALONE broke mount because
page_get returned 2x the frames the 4KB loop expected; pgget fixes that.  (3) **pvn_done** page-walk
step `addil #2048,d4 -> #4096` (0xb1d60): pvn_done loops `while d4 < b_bcount` pulling one page/iter
off b_pages -> a 2KB step over 4KB pages overran the list -> `pp >= pages && pp < epages` PANIC
(vm_page.c:1192).  VERIFIED: banner survives (mount dir-read OK), `segmap-map va=40448000 poff=0
pfn=7D24` + `va=40449000 poff=1000 pfn=7D25` (4KB VA AND poff stride, no collision), exhd_getmap 'H'
magic=7F454C46.  Diagnostics still in: hat040.s `DBG segmap-map` (gated 16) + execmark.s 'H' dump.


## >>> ★★★ FIXED (2026-06-24 night): 68040 access-error WRITE-BACK replay -> init now reaches exec ELF-load <<<
The init-bootstrap blocker is FIXED.  `prototypes/wb040.s` (commit 32a105c) ports the 68040
access-error WRITE-BACK replay as a `usrxmemflt` wrapper: after as_fault resolves the demand-fault
(ret==0) on a format-7 frame, re-issue every valid write-back (WB1/2/3; valid = WBxS bit7) via
`moves.<size> WBxD -> (WBxA)` under `DFC = WBxS & 7`.  This completes copyout(icode)'s lost first
store.  **VERIFIED in the serial log:** icode page offset 0 = 0x4FFB0170 (was 0), saved usp =
0x8080002A (was the stale 0x070DB958), copyinstr path = "/sbin/init" (2F736269), and init now runs
lookuppn -> gexec -> elfexec(F) -> relvm(V) -> setregs(X) -- it LOADS the init ELF binary.
Wiring: usrxmemflt is file-local -> `--globalize-symbol usrxmemflt --weaken-symbol usrxmemflt
--add-symbol usrxmemflt_orig=.text:0x5aede` + link build/wb040.o (relink-040-dbg.sh).  Frame WB
offsets confirmed empirically (get_fault040 'W' dump): WB3S@+78 WB3A@+88 WB3D@+92, WB2 @+80/+96/+100,
WB1 @+82/+104/+108; WBxS bit7=valid, &7=FC, >>5&3=SIZE(0=long,1=byte,2=word).
**NEW FRONTIER (not yet login):** exec's ELF loading loops/retries with `hat_pteload pfn mismatch
va=40448800 *pte=7A50001 newpfn=7A51 (overwriting)` (kvseg leaf-PTE remap) + `blkatoff page_find ->
NULL` -- the user-VM / file-mapping hat family (hat_dup/hat_chgprot/segvn page cache).
**TODO:** (1) DONE (commit 0ffdac8) -- wb040 + getfault040/userspace040/vtop040 moved to the BASE
build; (2) DONE (commit 88e4339) -- krnxmemflt wrapped; (3) the exec frontier = the 4KB page-cache
conversion (see the EXEC FRONTIER section above).  Memory [[amix-040-init-userpage-pfn]].

## >>> (superseded by FIXED above) TRUE ROOT CAUSE (2026-06-24 night): 68040 access-error WRITE-BACK not replayed <<<
The init hang is the **68040 access-error WRITE-BACK** not being replayed.  main()'s
`copyout(icode, 0x80800000, szicode)` -- the FIRST `movesl` to the ZFOD page demand-faults; the
68040 access-error frame carries the pending store (WB1/2/3), but the bus-error handler demand-pages
the page and NEVER re-issues the store, so **icode offset 0 stays 0** while offsets 4+ land.
PROVEN with caches OFF (CACR=0, so lfuword = literal RAM): icode page =
`0 / 00000028 / 700B4E40 / 60FE2F73` -- only the first long (the lea word 0x4FFB0170) missing.
The zeroed first word decodes as `ori.b` and falls THROUGH to `moveq #11,d0; trap#0` (so E/exece
still fires) but **the lea never runs -> USP stays stale 0x070DB958** -> systrap copies syscall args
from kernel memory = garbage -> empty exec path -> lookuppn busy-loops -> init never starts.  So the
wrong-usp + garbage-args + lookuppn-loop are ALL this one bug.
**ALL earlier theories were WRONG (don't re-chase):** pfn factor-of-2 / phys-beyond-RAM (phys
0x07A5D000 IS backed RAM, DEADBEEF write/readback OK); page-table cache coherency (CACR=0, caches
OFF); the loader (copies the real memory list); FS/lookuppn (030 baseline boots fine).  8MB-vs-16MB
is a separate Model-B accounting artifact.
**FIX (next):** port 68040 access-error WRITE-BACK replay into the bus-error path (k_trap/u_trap /
the nullvect/ktraps/utraps glue).  The 040 access-error frame (format 7) has WB1D/WB1S/WB1A (+WB2/3)
status/addr/data for pending stores; after as_fault resolves the page, re-issue any write-back whose
valid bit is set (check WBV/SIZE/TT/TM).  get_fault already reads FA at frame+84 from this frame, so
some offsets are known.  Motorola 68040 UM: "Access Error Stack Frame" / "Returning from an Access
Error".  Diagnostics: assegat_dbg.s copyout wrapper (icode-byte dump), execmark.s (usp/PC trace),
relink-030-dbg.sh (030 golden ref -- boot UPSTREAM unix_boot, not unix_boot040).  Memory
[[amix-040-init-userpage-pfn]].

## >>> SUPERSEDED (2026-06-24 eve): "user-page PTE points to phys BEYOND RAM (Model B factor-of-2)" -- WRONG, see above <<<
Branch `040-switch-trace`. The init-startup hang was traced END TO END with direct serial markers
(execmark.s) on the 040 dbg build + a HEALTHY 030 baseline (relink-030-dbg.sh, golden reference).
**The chain of symptoms (each proven, then superseded by the next):**
- init never starts; boot hangs after `copyout(icode,0x80800000) ret=0` (markers `M`,`E`).
- proc 1 DOES reach user mode + execs: `E`(exece) fires; the syscall path arg (the `/sbin/init`
  path pointer) is GARBAGE on 040 (`copyinstr from=0x3C66..`) vs `0x8080000E` on 030.
- The garbage arg comes from a WRONG saved usp: `u.u_ar0[0] = 0x070DB958` (a kernel addr) on 040
  vs `0x8080002A` (icode's `lea L%stack,sp`) on 030.  Both trap from USER mode (SR=0, PC=8080000C)
  -> icode ran -- but USP was never the value its `lea` set.
- ROOT: the **icode page itself is incoherent**.  `lfuword(user 0x80800000)` = `0x00000000` on 040
  (4FFB0170 on 030) -- EVEN right after copyout (`f` marker) and even after `cpusha`+`pflusha`.
  The instruction FETCH runs the real icode (so it reaches a phys with icode); user-FC DATA reads
  see zeros.  So the syscall arg copy (lfuword from the user stack) reads zeros/garbage.
- URP walk (exece AND post-copyout, IDENTICAL): URP=07A6C000 (== copyout's, unchanged), leaf PTE
  `0x07A5D019` -> phys **0x07A5D000**, which reads ZEROS.  copyout uses **DFC=1 (user data)** (movec
  #1,%dfc; movesl) -- the SAME FC as lfuword -- so both resolve via URP to phys 0x07A5D000.  No
  DTT/ITT split (ITT0=0-1GB only, ITT1 disabled, DTT1 supervisor-only).
- **THE BUG: phys 0x07A5D000 is BEYOND the kernel's managed RAM.**  The 040 detects only 8MB
  (`Total Unix memory = 8386560` = 0x7FF800; base 0x07000000 -> top ~0x077FF800) where the SAME
  fs-uae config on 030 detects 16MB (16775168).  0x07A5D000 > 0x077FF800 by ~2.4MB.  The user-page
  PTE points OUTSIDE RAM -> reads zeros.  This is a residual **Model B 2KB-click -> 4KB-page
  factor-of-2 error in the USER-fault pfn/phys path** (a 2KB-click number used as a 4KB page-frame
  number -> phys ~2x too big), which ALSO explains the 8MB-vs-16MB halving (same root).
**NEXT (the fix): audit the user-fault pfn path** segvn_fault -> anon/page_get -> hat_memload ->
hat_pteload(pfn) for a click(2KB)-vs-page(4KB) mismatch (`pfn<<12` in hat_pteload @Lwleaf expects a
4KB page-frame number; if `page_get`/segvn hands it a 2KB click, the phys doubles).  Cross-check
with the memory-sizing halving (maxclick/physmem).  Compare the GOOD kernel-region mappings (which
work) vs the user ZFOD page.  Tools: the dbg markers are all in `prototypes/execmark.s` (040 build)
+ `relink-030-dbg.sh` (030 golden baseline); commits ae5f942..46a78aa on `040-switch-trace`.
NOTE: a `cpusha+pflusha` was added to hat_pteload's exit (prototypes/hat040.s) as a coherency
guard -- it did NOT fix this (the bug is the wrong phys, not cache), but it is correct for 040 and
can stay (or be reverted if the per-fault cost matters).

## >>> LATEST (2026-06-24): init/copyout blocker SOLVED; now blocked on SCSI-DMA root-mount <<<
Branch `040-switch-trace`. See memory [[amix-040-ctx-switch-working]] (updated) + commits
`ae5f942` (init/copyout fixes), `fc01890` (SCSI localization).

**init/copyout blocker SOLVED (2 fixes).** The "icode page @0x80800000 is ZEROS → init SIGSEGV"
blocker was NOT a write-back-replay issue (that earlier guess was wrong). Two real causes, fixed:
1. **DTT1 user-leak** — `prototypes/pstart040.s` DTT1 `0x807fc060 → 0x807fa060` (S=10 both →
   S=01 supervisor-only). The old DTT1 transparently translated USER accesses to 0x80000000+ to
   nonexistent phys, so copyout's user-FC `moves` to the icode VA wrote to the VOID (no fault,
   readback 0). With S=supervisor-only, user VAs ≥0x80000000 (init lives at 0x80800000) fault +
   demand-page via the URP page tables. (BASE build / relink-040.sh.)
2. **userspace() 040 port** — `prototypes/userspace040.s` (--weaken userspace @0x5b5f0). Stock
   userspace() decides user-vs-kernel faults from the 030 SSW and knows only 030 formats 0xA/0xB;
   a 040 format-7 access-error frame fell through to "non-bus error exception" → returned 0
   (kernel) → k_trap routed copyout's fault to **krnxmemflt(&kas)** instead of
   **usrxmemflt(curproc->p_as)** → as_segat(&kas, 0x80800000)=NULL → copyout EFAULT → PANIC
   "main: copyout of icode failed". Fix: format 7 reads FC = (SSW & 7), 040 **SSW @ frame+76**.
   EMPIRICAL 040 access-error frame (ktrap_dbg.s raw dump): SR@+64 PC@+66 fmt/vec@+70 (0x7008)
   **SSW@+76** (0x0401 = ATC,write,TM=user) **FA@+84** (= get_fault). +4 shift from textbook.

**SCSI root-mount FIXED (vtop040, commit 5b6f68b).** The r=6 was NOT cache — it was the disk
DMA physical address. `alien/dd.c:240  dp->com.addr = vtop(b_un.b_addr, b_proc)`; sdpart read()
leaves b_proc=0 → `vtop(&block,0)` → svirtophys(&block), which WALKS kptr040 page tables that may
not cover the DTT0-transparent kernel region → wrong/0 phys for some `block` addresses (layout-
sensitive) → disk DMA misses block. **A3000 uses a3091 (32-bit direct DMA, device@0xDD0000); NOT
the a2091 24-bit+chip-bounce path.** FIX: `prototypes/vtop040.s` (--weaken vtop + --add-symbol
vtop_orig=0xb7568): for va<0x40000000 (DTT0 identity region, phys==va by construction) return va
directly, else stock vtop. Benefits ALL disk DMA (dd/scsi/ram/hd/flop). **CONFIRMED** (serial,
deterministic): the build that failed root-mount 4× now mounts (sdpartition r=0 ×3). NO source
for vtop/svirtophys (binary-only). SCSI source: `alien/{sdpart,dd,scsi,a2090,a2091,a3091}.c`.

**WHOLE CHAIN VERIFIED**: DTT1 + userspace040 + vtop040 → root mounts → banner → swapconf → sched
→ proc-1 setup → **copyout(icode,0x80800000) ret=0** (was EFAULT). The copyout's own `moves`
write demand-faults the icode page (ufault 80800000), resolves in proc1's p_as=401AA400 (was
&kas), ptloads it, writes icode. NO SIGSEGV, NO "ufault 80801000", NO panic. healthy.

**>>> NEW BLOCKER (2026-06-24): init startup HANGS after the icode copyout. <<<**
After main's `copyout(icode) ret=0 caller=0x59994`, the boot HANGS deterministically (no crash,
no login). main continues: `as_map(stack@0xC07FF800)` → branch `0x59c18` (return-to-user / launch
proc 1 to run icode → trap#0 → exec /sbin/init). LAYOUT-SENSITIVE: one build reached a 2nd copyout
(proc-1 exec running); the current build hangs earlier. NEXT: add a marker after main's icode
copyout (disasm `0x59c18`+ = the proc-1 launch / return-to-user path) to localize the hang —
likely the context-switch to proc 1 to RUN init, or exec of /sbin/init. Reaching exec needs more
user-VM hat (hat_dup/fork, COW), uvirtophys/uvatosde, and 040 signal frames may follow.
Addrs: main=0x597ac (icode copyout @0x5998e, ret addr 0x59994; stack as_map @0x599cc; branch
@0x599d8 → 0x59c18). git checkpoints: `5b6f68b` (root+copyout work), `ae5f942` (pre-SCSI).

---

## >>> SUPERSEDED (2026-06-23): 040 ctx switch WORKS; init runs in USER MODE + EXECs <<<
(The hat_free / write-back-replay theory below is SUPERSEDED by the 2026-06-24 section above —
the real init blocker was DTT1 + userspace(), not write-back replay.)
Verified in the SERIAL log (branch `040-switch-trace`, see memory [[amix-040-ctx-switch-working]]
+ [[amix-serial-debug-capture]]).  The whole chain now runs:
- **040 context switch** (resume040 in `prototypes/mainmarks.s`, --weaken resume/sched/idle):
  swtch calls `resume(arg1=u+0x318 FIXED VA 0x40000318, arg2=childphys)`; the 040 remap writes
  the new proc's 2 u-area leaf PTEs into `uarea_pt` (kptr040[0]&~0xFF), `cpusha bc`+`pflusha`,
  then restores context from the FIXED VA.  **DUAL SOURCE**: path U = proc 0 / static u-area via
  `p_ubptbl` (proc+80, 2KB-click→4KB PTE, keep live flags); path V = forked procs via a kptr040
  walk of u_va (kvsegu, already 040 4KB PTEs).  Earlier bugs fixed: read context from FIXED VA
  not kvsegu (kvsegu DATA bus-errors early); 2KB→4KB stride (uarea_pt[k]=p_ubptbl[2k]).
- All 4 daemons + proc 1 run; banner, swapconf, sched (maxrunpri=0x4F) all pass.
- **Last 030 `pmove %a1@,%crp` sites patched** → `movec %a0,%urp` (hat_map/hat_exec/hat_asload,
  patch_pmmu_040.py).  A full kernel PMMU scan (`objdump|grep pmove/pflush/ptest`) = COMPLETE
  for every reachable site (only the DEAD original-pstart tail remains).
- **get_fault override** (`prototypes/getfault040.s`, --weaken): decodes the 040 format-7
  access-error frame (Fault Address at frame+84).  Stock only knew 030 formats 0xA/0xB → it
  returned -1 → "User BUS ERROR" on init's first user fault.  With this, init runs in USER mode,
  demand-pages its text (0x80800000), and **execs** the init binary.
- **hat_pteload lazy pointer-table alloc** (`prototypes/hat040.s`): a fresh user as has an EMPTY
  040 root slot (measured Adesc4=0 AND desc8=0) because the 030 hat_growsdt writes the root with
  the 030 VA split + 8-byte descs that our 040 walk never reads.  Worked around by allocating the
  pointer table on the fault path (hat_sdtalloc count=8 = 512B = 128×4, root[Aidx]=ptable|UDT2).

## >>> NEXT BLOCKER (2026-06-23): user-VM hat family is still 030 (8-byte descriptors) <<<
init execs → teardown `relvm → as_free → hat_free → hat_ptfree` BUS-ERRORs: **hat_free walks the
page-table tree with `asll #3` (030 8-byte stride)** over our 4-byte 040 tables → garbage ptdat
list pointers → crash.  So the REMAINING CHUNK = the **user-VM hat family 040 port**: hat_growsdt
(build, 0xb6058), **hat_free (0xb41e0) / hat_ptfree (0xb6cf4) / hat_sdtfree** (teardown),
hat_chgprot ×6 (COW), hat_swapout/swapin.  All 030 8-byte-desc, NO source (triple-confirmed) →
binary RE/override like hat_pteload.  **Recommended order: hat_free + hat_ptfree first** (the
teardown that crashes now) → init's exec-teardown passes → see if init reaches a shell; then
hat_growsdt (then the lazy hat_pteload hack can be removed).  Descriptor formats ARE source:
`include/sys/immu.h` sde_t/pte_t, `include/vm/vm_hat.h` hat_t — read them for the port.
~80% to single-user 040.

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
1. **CONTEXT SWITCH -- DONE (2026-06-23).** resume040 (mainmarks.s) dual-path remap; swtch
   pmove→movec patched; save@0x84 unchanged (works).  See the top section.
2. **TRAP/EXCEPTION FRAMES -- PARTLY DONE.** get_fault 040 format-7 access-error frame =
   DONE (getfault040.s).  Still SOURCE-editable if more frame issues surface: ttrap.s
   `stkrestore`/`framesz` + vec.s (signal return / sigreturn frame sizes), use trap.h/reg.h/pcb.h.
3. **child context (setuctxt/procdup) -- DONE in effect** (children resume + run; resume040
   transfers correctly).  Revisit only if a child's first-resume frame misbehaves.
4. **user-VM hat family 040 port (BINARY/RE) -- MOSTLY DONE.** DONE + boot-verified in the BASE
   build (hat040.s): hat_pteload (fault-fill), hat_alloc, hat_free040/hat_ptfree (teardown, with
   [pages_base,pages_end) garbage-slot guards), hat_chgprot040 (fires), hat_unload040.  Still
   PENDING: **hat_dup** (fork -- BASE unix-040 has STOCK-030 hat_dup; only the dbg build stubs it,
   so the base is not fork-safe = ISSUE-4), **hat_exec@0xb6f20** (exec stack move -- 030 garbage-
   write source, currently neutered by the garbage-slot guards; port to per-4KB-page move via our
   hat040 primitives), **hat_growsdt@0xb6058** (build -- lazy-patched in hat_pteload for now).
   Port like hat_pteload: 4-byte descs, va>>25/>>18/>>12 indices, immu.h sde_t/pte_t + vm_hat.h
   hat_t.  Start with hat_dup (biggest exposure).
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
