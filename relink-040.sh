#!/bin/sh
# relink-040.sh -- build the page_init-milestone 68040 kernel: pstart040 (bootstrap
# paging + kvseg scaffold) + kvm040 (sysseginit pointer descs + segkmem_mapin leaf
# PTEs).  Combines the override mechanisms (see worklist):
#   * pstart        GLOBAL -> --weaken-symbol           (pstart040.o redefines it)
#   * segkmem_mapin GLOBAL -> --weaken-symbol           (kvm040.o redefines it)
#   * sysseginit    LOCAL  -> --globalize-symbol then --weaken-symbol (kvm040.o redefines)
# Then patch the remaining 030 PMMU instructions (patch_pflusha/patch_pmmu).
#
# Output: build/unix-040 -- a SELF-CONTAINED bootable 040/060 kernel since 2026-07-12:
# runtime040.s (native resume fixed-u remap + crossing-page hardbus + swap/pageout
# disables) is now part of THIS base link.  Before that date the bare artifact was a
# non-bootable intermediate (stock resume) and only the quiet/dbg overlays could boot;
# a post-link check below now rejects any image whose resume/hardbus are still stock.
# Overlays: unix-040-quiet = base + serial mirror; unix-040-dbg = base + probes.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
. "$(cd "$(dirname "$0")" && pwd)/tools/build-step.sh"
STOCK="${STOCK:-$AMIX_ROOT/stand/unix}"
. "$(cd "$(dirname "$0")" && pwd)/tools/verify-stock.sh"
verify_stock "$STOCK"
mkdir -p "$HERE/build"

echo "[*] assembling pstart040.s + kvm040.s + hat040.s + hat_chgprot040.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/pstart040.s"     -o "$HERE/build/pstart040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/kvm040.s"        -o "$HERE/build/kvm040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/hat040.s"        -o "$HERE/build/hat040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/hat_chgprot040.s" -o "$HERE/build/hat_chgprot040.o"
#     hat_pagesync040 = REAL 040 port of hat_pagesync (the pageout/pvn_done B_FREE reclaim
#                    sampling gate).  Stock's U/M gather is correct but its flushmmu via the
#                    retired 030 ptdat leaves the 040 ATC unflushed -> actively-used pages
#                    read p_ref==0 and get reclaimed+reused (ISSUE-10).  This flushes the
#                    ATC unconditionally after the walk.  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/hat_pagesync040.s" -o "$HERE/build/hat_pagesync040.o"
#     hat_exec040  = NO-OP override of the stock exec stack-page-table MOVE optimization.
#                    Stock passes flag 0 to hat_ptalloc (steal allowed) and its unpatched-030
#                    steal path, hit under memory pressure, orphans live 040 PTEs of a stolen
#                    table's pages (ISSUE-10 chain II).  as_exec moves the seg + faults rebuild
#                    the stack via hat_pteload, so the move is a pure (unsafe-on-040) optimization.
#                    Codex HAT-EXEC-POLICY.md-endorsed.  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/hat_exec040.s"    -o "$HERE/build/hat_exec040.o"
#     hat_dup040   = REAL 040 fork/COW port (ISSUE-4, boot-verified 2026-07-04 on branch
#                    040-hat-dup-port incl. the fork-without-exec COW subshell test) --
#                    replaces the old forkdbg.s no-op stub.  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/hat_dup040.s"     -o "$HERE/build/hat_dup040.o"

echo "[*] assembling genuine 68040 trap/fault runtime ports (moved out of the dbg overlay --"
echo "    these are REAL fixes, not diagnostics, so they belong in the base kernel):"
echo "      getfault040 = decode the 040 format-7 access-error frame (fault address)"
echo "      userspace040 = classify user-vs-kernel fault from the 040 SSW (route copyout)"
echo "      vtop040      = DTT0 identity phys for disk DMA (va < 0x40000000)"
echo "      wb040        = 040 access-error WRITE-BACK replay (the init copyout(icode) fix)"
echo "      ptest040     = real 040 ptestr -> 030-form PSR (the GOT-relocation COW-fault fix)"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/getfault040.s"  -o "$HERE/build/getfault040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/userspace040.s" -o "$HERE/build/userspace040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/vtop040.s"      -o "$HERE/build/vtop040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/wb040.s"        -o "$HERE/build/wb040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/segvn_prot040.s" -o "$HERE/build/segvn_prot040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ptest040.s"     -o "$HERE/build/ptest040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/uvatosde040.s"  -o "$HERE/build/uvatosde040.o"
# prfastmap040 (ISSUE-17/18): replaces prfastmapin's dead 030 SDE walk with a real
# 040 per-proc VA->PTE walker (uvatopte040), also consumed by vtop040.s for the
# user-VA branch of ISSUE-18a.  prfastmapout/prusrio keep their stock structure
# and are instead byte-patched (patch_procio.py, below) -- see prfastmap040.s's
# header comment for why the split is structure-vs-constant, not arbitrary.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/prfastmap040.s" -o "$HERE/build/prfastmap040.o"
#     prumap040    = lazy kvsegu slot-0 (proc 0 u-area) alias into kptr040 -- p0init's
#                    030 st_top1 writes are inert on 040; fixes the prgetpsinfo panic
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/prumap040.s"    -o "$HERE/build/prumap040.o"
#     haltsys040   = AttnFlags-guarded MMU disable for the reboot/halt path (ISSUE-5) --
#                    stock haltsys falls into unguarded 030 pmove tc/crp/srp, illegal on 040.
#                    Overrides rtnfirm TOO: mdboot calls rtnfirm (not haltsys) for fcn>=1,
#                    i.e. on every real reboot (ISSUE-5 fix v2)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/haltsys040.s"   -o "$HERE/build/haltsys040.o"
#     segu_lockfix = segu_get wrapper restoring SEGU_LOCKED in su_flags (ISSUE-7 root
#                    fix) -- the Model-B loop-bound patch (patch_modelb_pager.py:226)
#                    shared d5 as loop bound AND su_flags source, dropping the LOCKED
#                    bit, so segu_release never passed HAT_UNLOCK|HAT_RELEPP and the
#                    u-page keepcnt hold leaked -> page_abort freed live u-pages.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/segu_lockfix.s" -o "$HERE/build/segu_lockfix.o"
#     segu_ubptbl040 = post-fix wrappers rebuilding p_ubptbl from the live kptr040
#                    tree after stock segu_get/swapinub run (their inline st_top1
#                    walks are inert on 040 -> p_ubptbl was ZEROS; PREEMPT5).
#                    Chain: segu_get(ubptbl) -> segu_get_lockfix -> segu_get_orig
#                    (stock); the lockfix def is RENAMED below so each build keeps
#                    exactly one strong segu_get.  swapinub(ubptbl) -> swapinub_stock.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/segu_ubptbl040.s" -o "$HERE/build/segu_ubptbl040.o"
# inituname040 = wrapper appending " 68040-<buildid>" to utsname.machine (banner + uname -m)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/inituname040.s" -o "$HERE/build/inituname040.o"
# 060-B (2026-07-10): dual-CPU support objects (see docs/68060-prestudy.md).
#   cputype060 = the `cputype` global (40 default; unix_boot pokes 60 from AttnFlags)
#   lmul060    = portable lmul (stock's 64-bit muls.l forms trap on the 68060)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/cputype060.s" -o "$HERE/build/cputype060.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/lmul060.s"    -o "$HERE/build/lmul060.o"
#   isp61_060  = vector 61 (unimplemented integer): emulates the ONE form the installed
#                userland uses -- immediate-source 64-bit MULS.L/MULU.L, 103 measured sites,
#                zero elsewhere in libc/ld.so/as/ld.  Everything else declines, counted, to
#                nullvect.  cputype-gated, so the 040 never enters it.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/isp61_060.s"  -o "$HERE/build/isp61_060.o"
#   fpu060     = ISSUE-43 (2026-08-12): fpu_save / fpu_restore / fpu_setup for the 68060.
#                The inherited bodies decide "does this process have live FP state?" from
#                BYTE ZERO of the FSAVE frame.  That is the format byte on a 68881/040 and
#                the SOURCE OPERAND's exponent on a 68060, whose discriminator is at frame+2
#                -- so an enabled FP exception with a zero operand (i.e. divide-by-zero) read
#                as "no FP state" and lost fp0-7 across the signal, measured on silicon.
#                cputype-gated: the 040 tail-jumps to the untouched stock bodies, and every
#                fpc_* counter below must read 0 on an 040 boot.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/fpu060.s"     -o "$HERE/build/fpu060.o"
#   fpuinit060 = F1 (2026-08-24): the fourth strong symbol of that override surface, and the
#                one that decides what the other three may do.  The stock probe asks an 040
#                question (byte ZERO of the FSAVE frame) and FSAVEs into the inherited 8-byte
#                COMMON, four bytes short of a 68060 frame.  This one installs a temporary
#                vector-11 handler, clears PCR bit 1 (DFP -- settled from the manual and from
#                Motorola's own sample handler, docs/060-PCR-BIT1-VERDICT-260824.md), probes
#                with FRESTORE/FSAVE, and sets fpu_present only if nothing trapped AND the
#                frame is a valid 060 one.  It also carries fpu_setup_gated, the counted gate
#                at sendsig's call site.  Spec: FPU-TIER1-ENABLE-SPEC.md:212-243.
#                FPUINIT060=0 omits the unit, the weaken, the link and the sendsig retarget --
#                the spec's own rollback control (:460-462), and it must reproduce the
#                baseline image byte for byte apart from the build-id stamp.
FPUINIT060="${FPUINIT060:-1}"
FPUINIT_OBJ=""; FPUINIT_OC=""; FPUINIT_ASSERT=""; FPUINIT_BIND=""
if [ "$FPUINIT060" = "1" ]; then
	m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/fpuinit060.s" -o "$HERE/build/fpuinit060.o"
	FPUINIT_OBJ="$HERE/build/fpuinit060.o"
	FPUINIT_OC="--weaken-symbol fpuinit --add-symbol fpuinit_orig=.text:0x19bac,function,global"
	FPUINIT_ASSERT="fpuinit:0x19bac:4e5600004879000000004879"
	FPUINIT_BIND="fpuinit:00019bac"
else
	echo "[*] FPUINIT060=0 -- building WITHOUT the 060 FPU probe (rollback control)"
fi
#   kvecprobe040 = F3 M0 (2026-08-07): wrap nullvect and count the vector of every exception
#                that reaches it.  The kernel names a vector only for SIGKILL kills, so a
#                SIGSYS ("bad system call") cannot currently be attributed -- which is what
#                blocks judging F3 and what leaves wolf3d/xv unexplained.  NOT cputype-gated:
#                it measures both CPUs, and the 040 numbers are the control.  Data flag
#                kvp_on = 0 takes it out of the path within one boot.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/kvecprobe040.s" -o "$HERE/build/kvecprobe040.o"
# ISSUE-13 (2026-07-12): bp_map/bp_mapout were left as stock 030 bodies (2 KiB, retired
# st_top1 tree) -> corrupt the NFS page-I/O temp mapping.  bp_map040 rewrites both for
# the live 040 kptr040 tree (4 KiB, phys|0x19).  Both GLOBAL T -> plain --weaken-symbol.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/bp_map040.s"  -o "$HERE/build/bp_map040.o"
# runtime040 (2026-07-12): the formerly-overlay-only LOAD-BEARING overrides promoted
# into the base link (Codex PROCESS-MMU-CONTEXT-SWITCH-CONTRACT.md packaging finding:
# bare unix-040 retained stock resume -> fixed-u never remapped -> not bootable).
#   resume   = native 040 fixed-u remap (ctx switch core)
#   hardbus  = page-crossing read fix (crossing ifetch/read refault loop)
#   sched/idle = sched still a deliberate process-swap disable (u-area swap-out
#                unvalidated); schedpaging override RETIRED 2026-07-15 -- writeback
#                group converted (patch_writeback.py), stock pageout daemon runs
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/runtime040.s" -o "$HERE/build/runtime040.o"
# segkmem040 (2026-07-20, CM-campaign B1): flushmmu = cpusha dc + pflusha (descriptor
# publication for every bare-flushmmu caller); segkmem_setprot Model-B port (2 KiB
# index/step was a live-PTE-corruption latent + stock cursor-advance defect) +
# publication; sptfree(flag=0) teardown publication.  Companion READER byte patches
# (checkprot/getprot) in patch_segkmem.py below.  Spec: CM-PTE-WRITER-MATRIX.md.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/segkmem040.s" -o "$HERE/build/segkmem040.o"
# dma_cache040 (2026-07-20, caches Step B / B1 DMA-coherency gate): shared
# FROM_DEVICE completion primitive (cinva dc) + A3091/SDMAC stopdma wrapper.
# A3000-first: only the A3000-internal SCSI controller (the sole host-RAM DMA
# initiator on this machine) is hooked; A2090/A2091/native-hd are documented in
# DMA-INITIATOR-CENSUS.md and DEFERRED (not in this HW).  Dormant no-op until
# the real-HW Step-B CACR DC-enable.  Wired by relocation retarget (three
# same-named local stopdma symbols block globalize+weaken) via patch_a3091_dma.py.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/dma_cache040.s" -o "$HERE/build/dma_cache040.o"
# a3091dbg040 (2026-08-26): capture the A3091 driver's state at the moment it shuts itself
# down.  badhardware() prints one line and returns DEAD, from which atab's all-ones DEAD row
# never lets it recover -- so on 2026-08-25 the machine wedged with `a3091: 0x16 0 0x8112B84`
# and nothing else survived.  This interposer prints and latches the surrounding state first,
# then tail-jumps to the stock body, so its line still appears and DEAD is still returned.
# Reached by retargeting ONE relocation (patch_a3091_badhardware.py): `badhardware` is a
# file-LOCAL static and the image holds two, so a global override would capture `service`'s
# call site too.  See docs/A3091-WEDGE-PRESTUDY-260826.md.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/a3091dbg040.s" -o "$HERE/build/a3091dbg040.o"
# segdevchk040 (2026-08-26, ISSUE-49): measure the assumption patch_segdev_bridge.py rests
# on.  The bridge steps segdev one 4 KiB page while the vpage array keeps two entries per
# page, which is correct only while both members of every pair are equal -- and they are
# equal only because the generic as_* boundaries round to 4 KiB before segdev is reached.
# Nothing links those two facts, so these two wrappers count any segdev operation arriving
# on a sub-page address or length: sdc_setprot_bad and sdc_unmap_bad must read 0 forever.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/segdevchk040.s" -o "$HERE/build/segdevchk040.o"
# cb_release040 (2026-07-23, caches Step B2): copyback page-lifecycle release
# barrier -- cpushl-per-line page push+invalidate (cb_page_release) + the two
# free-list choke-point islands (page_free @0xafb08 via bsr.l, free_vp_pages
# @0xafd98 via jsr/reloc-retarget; patch_cb_release.py installs both).  Spec:
# CB-PAGE-LIFECYCLE-CLOSURE.md.  In the WT baseline the loop only invalidates
# clean lines (harmless) -> hooks are regression-testable before the CM flip.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/cb_release040.s" -o "$HERE/build/cb_release040.o"
# cb_icode040 (2026-07-30, ISSUE-38 fix): main()'s copyout(icode) writes proc 1's
# bootstrap text with the CPU, and the 040 ifetch does not snoop the data cache --
# under copyback the icode stayed in dirty lines, proc 1 executed the still-zero RAM
# page as `ori.b #0,%d0` off the end into the unmapped 0x80801000 and died before
# exec.  Gated `cpusha bc` after the icode copyout only.  See the file header for
# the full evidence chain (incl. why assegat_dbg masked it: its copyout wrapper
# does the same push unconditionally).  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/cb_icode040.s" -o "$HERE/build/cb_icode040.o"
# kdbg040 (2026-07-31): the base kernel is SILENT.  One flag (kdbg_on, ships 0)
# gates the ~15 VM diagnostic cmn_err sites that fire on a HEALTHY boot inside the
# genuine-fix objects; the ~11 that never fire on a healthy boot stay ungated,
# because their silence is what makes them worth reading.  Two anomaly-shaped
# sites that DID fire every boot behind an 8-print cap now also carry uncapped
# counters (hat_pfnmiss_n, hat_badaslot_n) so their real rate becomes a number.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/kdbg040.s" -o "$HERE/build/kdbg040.o"
# dbgpublish040 (2026-07-31, DBG-TEXT-PUBLISH): the residual ISSUE-38 left open.
# The kernel CPU writes into another process's TEXT on exactly two debugger paths
# -- ptrace POKETEXT via suword, and /proc/<pid> writes via uiomove -- and under
# copyback those bytes sit in dirty lines the 040 ifetch never snoops, so a
# breakpoint or a patched instruction is invisible to the target.  Two wrappers
# reached by relocation retargeting (patch_dbgpublish.py, below), publishing with
# cpusha bc.  Spec: analyysirepo vm-map/DEBUGGER-TEXT-PUBLICATION-PATCH-SPEC.md.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/dbgpublish040.s" -o "$HERE/build/dbgpublish040.o"
# codepub040 (2026-08-01, USER-CODE-PUBLISH): the LAST ISSUE-38 residual -- user
# space generating its own code (runtime linker text relocation, a JIT, or a
# read(2) into a buffer that is then jumped to).  Defines the port ABI "a
# successful mprotect with PROT_EXEC publishes all completed stores", as a strong
# mprotect wrapping the stock body.  Today's kernel publishes W->X only
# INCIDENTALLY (hat_chgprot's PTE-coherency tail happens to be a whole-cache push)
# and a same-protection RWX call cannot publish at all, because segvn_setprot
# returns success before HAT is reached.  Spec: analyysirepo
# vm-map/USER-CODE-CACHE-ABI-SPEC.md.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/codepub040.s" -o "$HERE/build/codepub040.o"
# issue39_040 (2026-08-01): ISSUE-39 characterisation.  Two things no previous
# session could do: (1) freemem/availrmem/deficit/physmem/... are COMMON symbols
# placed in .bss by the LOADER, so they have no computable address -- a .data
# long initialised to the symbol turns each into a loader-resolved pointer that
# kpeek can follow; (2) hat_sdtfail_count now also latches the memory state at
# the first and last failure, so the warning stops being just a count.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/issue39_040.s" -o "$HERE/build/issue39_040.o"
# i10rev040 (2026-08-19): ISSUE-10 reverse-map instrumentation.  The three HAT
# routines that UNLINK a leaf PTE from a page's p_mapping chain all walk it with
# a 256-node safety bound, and all three give up quietly when the bound runs out
# -- hat_pteload's replacement path completely silently, hat_unload's and
# hat_free's behind a 4-print cap that goes dark for the rest of the uptime.  A
# give-up removes or overwrites the PTE without unlinking its chain node, which
# is the exact shape of the corruption ISSUE-10 keeps producing, so "how often"
# needs to be a number rather than a cap.  This is a data-only island: uncapped
# counters in the shape of kdbg040.s's hat_pfnmiss_n, incremented from the sites
# themselves, plus i10_deep_n -- the how-close-did-a-search-get reading that
# makes a zero fail count mean something.  hat_dup040 is counted too, as the
# chain-growth PRODUCER: it has no bound of its own because it never searches.
#   It is no longer data-only: the same file now carries i10p_probe, the one-shot
# capture that answers the question the counters raised but cannot settle -- WHAT
# the page holding the corrupt word is.  wb040.s's usrxmemflt tail calls it at the
# moment a user fault is known unresolved, and it walks the victim's own page tree
# looking for the value the fault died on, latching that page's whole identity
# (pfn, page_t, p_vnode, p_mapping and what the chain names, plus the frame's own
# first words) together with what the KERNEL'S map says about the value.  Gated on
# the fault address lying in the kernel VA band, so ordinary user faults pay one
# masked compare; see the header of the file for the register/safety contract.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/i10rev040.s" -o "$HERE/build/i10rev040.o"
# legacysdt040 (2026-08-01, ISSUE-40 fix): hat_free040 tore down only the native
# 040 A/B/C tree and never released the LEGACY SDT allocations that the retained
# stock hat_map -> hat_growsdt -> hat_sdtalloc path still makes on every exec --
# a 17-unit object for libc that cannot share a 32-unit p_sdtbits page, so every
# dynamic exec kept a 4 KiB page for good (availrmem -1/exec on hardware, with
# availrmem + pages_pp_kernel conserved => a real page, NOT lost accounting).
# Restores the 030 destructor's hat_growsdt(hatp, section, 0) edge for sections
# 2 and 3, before the native walk overwrites the descriptors that name them.
# Calls the RETAINED hat_growsdt body -- hence the globalize below, and hence
# this must never be weakened.  Contract: analyysirepo
# vm-map/ISSUE40-LEGACY-SDT-TEARDOWN-CONTRACT.md.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/legacysdt040.s" -o "$HERE/build/legacysdt040.o"
# ptdatfree040 (2026-08-02, ISSUE-40 part 2): the half that actually returns the
# page.  Part 1 released the legacy SDT and got ZERO pages back on hardware
# (i40_pgfreed_n = 0 over 3440 releases) because hat_sdtfree only credits when
# p_sdtbits reaches zero -- and our hat_ptfree discarded pp->p_ptdats without
# removing its four active_pts/free_pts records or returning their 64-byte
# hat_sdtalloc unit, so every table page ever allocated left a permanent crumb.
# hat_ptdat_retire() is the exact retained inverse behind a stronger ownership
# gate (p_keepcnt == 1, p_ptbits == 1, unlocked record, reciprocal links), called
# from hat_ptfree.  It CALLS retained hat_sdtfree -- hence the globalize below.
# Contract: analyysirepo vm-map/ISSUE40-PTDAT-TEARDOWN-CONTRACT.md.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/ptdatfree040.s" -o "$HERE/build/ptdatfree040.o"
# syncguard (2026-08-20): sync() walks vfssw[] through vsw_vfsops with no null
# check, and xpanic calls sync() -- so ANY panic before vfsinit() has filled the
# switch dereferences NULL, lands on low-memory vector 4 (the exec ROM trap stub
# AmigaOS left there), and turns into DOUBLE PANIC before the first panic can be
# read.  This override is the stock loop plus two null checks and a counter block.
# CPU-independent: it is a defect in generic vfs code, not in anything 040.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/syncguard.s" -o "$HERE/build/syncguard.o"
# pageinitzero (2026-08-20, ISSUE-102): the page-frame database is sptalloc'd with a
# non-zero base, which is segkmem_mapin -- it MAPS existing DRAM and clears nothing --
# and page_init only ORs p_lock into each struct.  Every other field arrives as
# whatever the DRAM held, so memialloc's page_free() walk panics on the first struct
# whose p_keepcnt/p_mapping/p_lckcnt/p_cowcnt garbage is non-zero.  Zero-filled
# emulator RAM hides this completely; AmigaOS-dirty Fast RAM on metal does not.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/pageinitzero.s" -o "$HERE/build/pageinitzero.o"
# segmapdbg (2026-08-20, ISSUE-103): segmap_unlock's three guards -- pp NULL,
# p_pagein, p_free -- all branch to ONE cmn_err, so the panic text cannot say which
# fired.  This island latches segmap_unlock's live registers plus a full-hash search
# for the page it could not find, then tail-jumps into cmn_err so the panic prints
# unchanged.  Only reachable from a path that was already panicking.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/segmapdbg.s" -o "$HERE/build/segmapdbg.o"
# btwalk (2026-08-21, ISSUE-104): backtrace accepted a frame pointer only inside a
# 64 KiB window at the u-block base, and that test was the walk's ONLY terminator --
# so the panic backtrace stopped at the first frame every time, twice costing this
# campaign a hand-walked stack dump.  The island widens the range to the whole
# u-block plus the kernel's own data+bss (where pstack lives) and adds the two
# bounds that make widening safe: strictly increasing frame pointers, and a hard
# 64-frame cap.
# Rule 4 (2026-08-25, first silicon): the walk dereferences the RETURN ADDRESS it
# reads out of each accepted frame, at [ret-6, ret), and nothing bounded that.  The
# last pid-0 frame is u+0x1FC0 whose slot reads 0, so the panic printer read
# 0xFFFFFFFA and double-faulted on real silicon.  The island now bounds the return
# address to [_start, etext) before anything reads through it.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/btwalk.s" -o "$HERE/build/btwalk.o"
# usptrap (2026-08-21, ISSUE-106): PID 1 dies at exec with a kernel-shaped user
# stack pointer (fa 0x40001FC0 == u+0x1FC0, the constant _start loads into %sp).
# The island latches the actual USP, u.u_ar0 and u_comm at the NOTICE, then
# tail-jumps into cmn_err so the message prints unchanged.  Only reachable from a
# path already reporting a fatal user fault.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/usptrap.s" -o "$HERE/build/usptrap.o"
# srgtrap (2026-08-21, ISSUE-106 round 2): round 1 latched u.u_ar0 inside u_trap,
# AFTER u_trap had already overwritten it -- the value was real, the moment was
# wrong.  This unit measures at the two moments that matter: the utraps push (the
# slot the trap exit pops USP from) and setregs (the pointer it writes the new SP
# through).  srg_match is the verdict word.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/srgtrap.s" -o "$HERE/build/srgtrap.o"
# inittrap (2026-08-21, ISSUE-106 round 3): round 2 proved exec never ran at all --
# u_trap has exactly one caller, so srg_ut_n=1 means ONE user trap in the whole
# boot, and it was the fault.  PID 1 died on its FIRST user instruction, so the
# question moved to what _start hands the initial rte.  This wraps `jsr main` and
# latches main's return value, the user PC.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/inittrap.s" -o "$HERE/build/inittrap.o"
# inituser (2026-08-21, ISSUE-106 round 4): round 3 proved exec never ran -- PID 1
# died on its FIRST user instruction (fault PC 0x80000012 = icode base 0x80800000
# with bit 23 dropped, +0x12).  main returns the right entry (ini_ret 0x80800000),
# but the user-transition RTE delivered the wrong PC.  This island IS that RTE:
# it rebuilds the exact frame from d0, latches d0 / SSP / USP / the frame words the
# RTE reads back, then RTEs -- so a good kernel still launches PID 1 identically.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/inituser.s" -o "$HERE/build/inituser.o"
# btrace (2026-07-20): early-boot serial phase trace, flag-gated.  Called from
# pstart040 (A-H), sysseginit (S/s), first hat_pteload (P).  btrace_on ships 0 =>
# base/quiet are behaviour-identical (silent no-op).  relink-040-dbg.sh flips
# btrace_on=1.  Diagnostic for the intermittent real-HW early-boot failure; kept
# as a standing feature (see src/btrace.s).
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/btrace.s" -o "$HERE/build/btrace.o"
# config040 (2026-07-22, ISSUE-21 fix candidate): config() cache-handoff wrapper.
# _start calls config() first (before pstart040); the intermittent early-boot fault
# happens when the IC is on in that window (inherited from AmigaOS; the loader's
# CACR=0 does not stick -- confirmed on emu too).  This kernel-side wrapper disables
# the caches at config entry (cinva ic + CACR=0); pstart040 re-enables IC at 'D'
# (Step A preserved).  Wired by retargeting _start's jsr-config reloc (patch below).
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/config040.s" -o "$HERE/build/config040.o"
# krnxmemflt040 (2026-07-13, ISSUE-13 capture 2): NATIVE kernel fault-resolver core.
# Stock krnxmemflt_orig was a coupled 4-defect 030 remnant (user-FC ptest, frame+72
# rw decode + prot gate, 030 leaf walk) + the k_trap landing-pad recursion window.
# The wb040.s public wrapper is UNCHANGED: its krnxmemflt_orig call now binds to this
# strong def (the stock body stays reachable as krnxmemflt_stock, reference only).
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/krnxmemflt040.s" -o "$HERE/build/krnxmemflt040.o"
# hgfault040 (2026-08-21, ISSUE-10 CURE): the USER-side counterpart of the line above,
# and the same idiom -- a strong usrxmemflt_orig here, the stock body retained as
# usrxmemflt_stock.  On the 68040 only, a USER-mode WRITE that the stock resolver has
# just refused, whose page is EXACTLY the page above the process break, grows the break
# by ONE page through brk's own as_map/segvn_create/zfod path and is handed back to the
# stock body, which then resolves it -- so wb040.s's replay gate sees a resolved fault
# and completes the pending write-back instead of discarding it.  Behind hg_on (one
# .data long, 0 = byte-exact stock).
#   WHY NOT as_fault, which is where the FC_NOMAP is returned: because for this fault
# as_fault is NEVER CALLED.  usrxmemflt tests coverage itself at 0x5afc2 and, finding
# no segment and no stack fault, takes the 0x5b02a shortcut straight to SIGSEGV.  That
# is measured, not deduced: the i10a as_fault audit was armed on the page and then on
# the exact address while the wall fired, and recorded i10a_vamatch_n = 0 against
# i10a_seen_n of 417 and 1024.  See src/hgfault040.s's header.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/hgfault040.s" -o "$HERE/build/hgfault040.o"
m68k-linux-gnu-objcopy --redefine-sym segu_get=segu_get_lockfix "$HERE/build/segu_lockfix.o"
# i10s (2026-08-20, ISSUE-10 resolution audit PART SEVEN): i10rev040.o carries an OUTER
# tail-call wrapper on segvn_faultpage that observes the per-page decision and then hands
# off to segvn_prot040's per-page restorer.  For the wrapper to take the segvn_faultpage
# symbol, segvn_prot040.o's own definition is renamed to segvn_faultpage_prot here -- a
# relink-time rename (the segu_get idiom above) so segvn_prot040.s stays untouched and
# standalone-upstreamable, knowing nothing about the audit.  The chain then binds as
# segvn_faultpage (i10rev040.o) -> segvn_faultpage_prot (segvn_prot040.o) ->
# segvn_faultpage_orig (0xac01a stock body).  The hard check after the link asserts it.
m68k-linux-gnu-objcopy --redefine-sym segvn_faultpage=segvn_faultpage_prot "$HERE/build/segvn_prot040.o"

echo "[*] globalize local fns (so overrides + cross-refs bind); weaken the replaced ones"
cp "$STOCK" "$HERE/build/unix-stage1"
# sysseginit, hat_pteload are REPLACED (globalize+weaken).  hat_ptalloc, hat_pt2ptdat
# are file-LOCAL but CALLED by our hat040.o (and byte-patched in place by patch_modelb),
# so globalize them too -- else ld -r can't bind hat040.o's refs to the kernel's local
# defs (the crashsw/crash_sync RELA-guru lesson).
m68k-linux-gnu-objcopy \
	--globalize-symbol sysseginit \
	--globalize-symbol segkmem_setprot \
	--globalize-symbol hat_pteload \
	--globalize-symbol hat_ptalloc \
	--globalize-symbol hat_sdtalloc \
	--globalize-symbol hat_growsdt \
	--globalize-symbol hat_sdtfree \
	--globalize-symbol hat_pt2ptdat \
	--globalize-symbol hat_ptfree \
	--globalize-symbol free_pts \
	--globalize-symbol pt_waiting \
	--globalize-symbol usrxmemflt \
	--globalize-symbol segvn_faultpage \
	--globalize-symbol krnxmemflt \
	--globalize-symbol page_cachelist \
	--globalize-symbol page_cachelist_size \
	"$HERE/build/unix-stage1"

# HARD CHECK (2026-08-12, ISSUE-43): fpu060.o replaces the three FP-context routines and keeps
# the stock bodies reachable as *_orig at FIXED addresses.  A hard-coded address is only safe
# if the body at it is the one the override was written against, so assert the entry bytes and
# the symbol addresses BEFORE weakening anything.  Twelve bytes is past the first branch in all
# three, which is enough to identify the body.  .text file offset in this ET_REL image is 0x34.
echo "[*] ISSUE-43: asserting the stock FP-context bodies before weakening them"
for fpe in fpu_save:0x132:207900000000082800000003 \
           fpu_restore:0x158:2079000000004a2800706718 \
           fpu_setup:0x19b50:4e56000048e7003048780008 \
           $FPUINIT_ASSERT; do
	fpn=$(echo "$fpe" | cut -d: -f1)
	fpa=$(echo "$fpe" | cut -d: -f2)
	fpw=$(echo "$fpe" | cut -d: -f3)
	fpg=$(od -An -tx1 -j $((0x34 + fpa)) -N 12 "$HERE/build/unix-stage1" | tr -d ' \n')
	[ "$fpg" = "$fpw" ] || { echo "[FAIL] $fpn at $fpa: stock bytes $fpg, expected $fpw"; exit 1; }
	fps=$(m68k-linux-gnu-nm "$HERE/build/unix-stage1" | awk -v n="$fpn" '$3==n && $2=="T" {print $1}')
	[ "$fps" = "$(printf %08x $fpa)" ] || { echo "[FAIL] $fpn is not a global T at $fpa (nm: '$fps')"; exit 1; }
	echo "      $fpn @ $fpa: entry bytes and symbol match the pinned image"
done

m68k-linux-gnu-objcopy \
	--weaken-symbol pstart \
	--weaken-symbol sysseginit \
	--weaken-symbol segkmem_setprot \
	--weaken-symbol sptfree \
	--weaken-symbol flushmmu \
	--weaken-symbol vatosde \
	--weaken-symbol vatopte \
	--weaken-symbol uvatosde \
	--weaken-symbol hat_pteload \
	--weaken-symbol hat_unlock \
	--weaken-symbol hat_unload \
	--weaken-symbol hat_pageunload \
	--weaken-symbol hat_pagesync \
	--weaken-symbol hat_exec \
	--weaken-symbol hat_alloc \
	--weaken-symbol hat_free \
	--weaken-symbol hat_ptfree \
	--weaken-symbol hat_chgprot \
	--weaken-symbol hat_dup \
	--weaken-symbol ptest \
	--weaken-symbol prumap \
	--weaken-symbol prfastmapin \
	--weaken-symbol haltsys \
	--weaken-symbol rtnfirm \
	--weaken-symbol sync \
	"$HERE/build/unix-stage1"

# Genuine 040 trap/fault runtime overrides (getfault040/userspace040/vtop040/wb040).
# usrxmemflt is file-LOCAL ('t') -> globalized above so wb040's strong def binds and the
# original is reachable via the alias.  vtop040 tail-jmps the aliased original for the
# kvseg/user path.  get_fault and userspace are GLOBAL T -> plain weaken is enough.
#   2026-08-21 (ISSUE-10 cure): the retained user-side body is now aliased
# usrxmemflt_STOCK, not usrxmemflt_orig, because usrxmemflt_orig is a real routine in
# src/hgfault040.s that screens the fault and then tail-calls the stock body.  Exactly the
# krnxmemflt_orig / krnxmemflt_stock split three lines below, and for the same reason:
# wb040.s calls *_orig and must not know whether that is ours or the vendor's.
m68k-linux-gnu-objcopy \
	--weaken-symbol get_fault \
	--weaken-symbol userspace \
	--weaken-symbol vtop \
	--add-symbol vtop_orig=.text:0xb7568,function,global \
	--weaken-symbol usrxmemflt \
	--add-symbol usrxmemflt_stock=.text:0x5aede,function,global \
	--weaken-symbol segvn_faultpage \
	--add-symbol segvn_faultpage_orig=.text:0xac01a,function,global \
	--weaken-symbol as_fault \
	--add-symbol as_fault_orig=.text:0xae108,function,global \
	--weaken-symbol brk \
	--add-symbol brk_orig=.text:0x580e8,function,global \
	--weaken-symbol krnxmemflt \
	--add-symbol krnxmemflt_stock=.text:0x5b140,function,global \
	--weaken-symbol segu_get \
	--add-symbol segu_get_orig=.text:0x000aa466,function,global \
	--weaken-symbol swapinub \
	--add-symbol swapinub_stock=.text:0x000a9e5c,function,global \
	--weaken-symbol inituname \
	--add-symbol inituname_orig=.text:0x00049140,function,global \
	--weaken-symbol page_init \
	--add-symbol page_init_orig=.text:0xaf42a,function,global \
	--weaken-symbol setregs \
	--add-symbol setregs_orig=.text:0x58b62,function,global \
	--weaken-symbol nullvect \
	--add-symbol nullvect_orig=.text:0x11b4,function,global \
	--weaken-symbol lmul \
	--weaken-symbol bp_map \
	--weaken-symbol bp_mapout \
	--weaken-symbol sched \
	--weaken-symbol idle \
	--weaken-symbol resume \
	--weaken-symbol hardbus \
	--add-symbol hardbus_orig=.text:0x5b3c2,function,global \
	--add-symbol a3091_stopdma_orig=.text:0xd4cc,function,global \
	--add-symbol a3091_startdma_orig=.text:0xd40a,function,global \
	--add-symbol a3091_dma_on=.bss:0x3cc0,object,global \
	--add-symbol a3091_badhardware_orig=.text:0xd666,function,global \
	--add-symbol a3091_istate=.bss:0x3cc8,object,global \
	--add-symbol a3091_curunitp=.bss:0x3ce0,object,global \
	--add-symbol a3091_starthead=.bss:0x3cd8,object,global \
	--add-symbol segdev_setprot_orig=.text:0xa80de,function,global \
	--add-symbol segdev_unmap_orig=.text:0xa7c08,function,global \
	--add-symbol config_orig=.text:0x18f5c,function,global \
	--weaken-symbol copyout \
	--add-symbol copyout_orig=.text:0x576,function,global \
	--weaken-symbol mprotect \
	--add-symbol mprotect_orig=.text:0x58550,function,global \
	--weaken-symbol fpu_save \
	--add-symbol fpu_save_orig=.text:0x132,function,global \
	--weaken-symbol fpu_restore \
	--add-symbol fpu_restore_orig=.text:0x158,function,global \
	--weaken-symbol fpu_setup \
	--add-symbol fpu_setup_orig=.text:0x19b50,function,global \
	$FPUINIT_OC \
	"$HERE/build/unix-stage1"

OUT="$HERE/build/unix-040"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage1" \
	"$HERE/build/pstart040.o" "$HERE/build/kvm040.o" "$HERE/build/hat040.o" \
	"$HERE/build/hat_chgprot040.o" "$HERE/build/hat_pagesync040.o" "$HERE/build/hat_exec040.o" "$HERE/build/hat_dup040.o" \
	"$HERE/build/getfault040.o" "$HERE/build/userspace040.o" \
	"$HERE/build/vtop040.o" "$HERE/build/wb040.o" "$HERE/build/ptest040.o" "$HERE/build/segvn_prot040.o" \
	"$HERE/build/uvatosde040.o" "$HERE/build/prfastmap040.o" "$HERE/build/prumap040.o" "$HERE/build/haltsys040.o" \
	"$HERE/build/segu_lockfix.o" "$HERE/build/segu_ubptbl040.o" \
	"$HERE/build/inituname040.o" \
	"$HERE/build/cputype060.o" "$HERE/build/lmul060.o" "$HERE/build/isp61_060.o" \
	"$HERE/build/fpu060.o" $FPUINIT_OBJ \
	"$HERE/build/kvecprobe040.o" \
	"$HERE/build/bp_map040.o" "$HERE/build/runtime040.o" "$HERE/build/krnxmemflt040.o" \
	"$HERE/build/segkmem040.o" "$HERE/build/dma_cache040.o" "$HERE/build/a3091dbg040.o" "$HERE/build/segdevchk040.o" "$HERE/build/cb_release040.o" "$HERE/build/btrace.o" \
	"$HERE/build/config040.o" "$HERE/build/cb_icode040.o" "$HERE/build/kdbg040.o" \
	"$HERE/build/dbgpublish040.o" "$HERE/build/codepub040.o" "$HERE/build/issue39_040.o" \
	"$HERE/build/legacysdt040.o" "$HERE/build/ptdatfree040.o" \
	"$HERE/build/syncguard.o" "$HERE/build/pageinitzero.o" "$HERE/build/segmapdbg.o" \
	"$HERE/build/btwalk.o" "$HERE/build/usptrap.o" "$HERE/build/srgtrap.o" "$HERE/build/inittrap.o" "$HERE/build/inituser.o" \
	"$HERE/build/hgfault040.o" \
	"$HERE/build/i10rev040.o"

echo
echo "[*] overridden symbols (each must be a single strong def):"
for s in pstart sysseginit vatosde vatopte uvatosde hat_pteload hat_unlock hat_unload hat_pageunload hat_pagesync hat_exec hat_alloc hat_free hat_ptfree hat_chgprot hat_dup get_fault userspace vtop usrxmemflt usrxmemflt_orig usrxmemflt_stock hg_magic hg_on hg_seen_n hg_cand_n hg_win_n hg_cover_n hg_lim_n hg_grow_n hg_landed_n hg_mapfail_n hg_unres_n hg_far_n segvn_faultpage segvn_faultpage_orig segvn_prot_magic segvn_prot_pp_n segvn_prot_n x60_far_addr x60_siginfo_n krnxmemflt krnxmemflt_orig krnxmemflt_stock vtop_orig ptest prumap prfastmapin uvatopte040 haltsys rtnfirm segu_get segu_get_lockfix segu_get_orig swapinub swapinub_stock lmul cputype bp_map bp_mapout sched idle resume hardbus hardbus_orig flushmmu segkmem_setprot sptfree hat_cm_ram dma_a3091_stopdma dma_a3091_startdma dma_a3091_startdma_reconn a3091_stopdma_orig a3091_startdma_orig a3091_dma_on a3091_badhardware_dbg a3091_badhardware_orig a3091_istate a3091_curunitp a3091_starthead segdev_setprot_chk segdev_unmap_chk segdev_setprot_orig segdev_unmap_orig sdc_magic sdc_setprot_n sdc_setprot_bad sdc_unmap_n sdc_unmap_bad a3d_magic a3d_ran a3d_n a3d_ss a3d_istate a3d_unit a3d_head a3d_segstate a3d_owned a3d_noprep dma_cmpl_count dma_seg_state cb_page_release cb_pgfree_enter cb_vpfree_enter cb_rel_count btrace_mark btrace_on config_cachefix config_orig copyout copyout_orig cb_icode_calls cb_icode_push kdbg_on hat_pfnmiss_n hat_badaslot_n hat_sdtfail_n dbg_publish_on dbg_ptrace_publish dbg_procfs_publish mprotect mprotect_orig codepub_on codepub_calls codepub_exec codepub_push hat_sdtfail_count i39_magic i39_freemem_p i39_availrmem_p i39_fail_n i39_fail_freemem \
         hat_growsdt hat_legacy_sdt_free i40_magic i40_on i40_calls i40_sec2_n i40_sec3_n i40_empty_n i40_bad_n i40_err_n i40_pgfreed_n i40_held_n i40_last_n i40_last_base i40_last_bits \
         i10_magic i10_rpfail_n i10_hlfail_n i10_hffail_n i10_dupreg_n i10_deep_n \
         i10p_probe i10p_magic i10p_gmask i10p_gwant i10p_vmask i10p_n i10p_done i10p_have \
         i10p_fa i10p_lastfa i10p_want i10p_maxtry i10p_tries i10p_busy i10p_why \
         i10p_as i10p_rootraw i10p_curproc i10p_uprocp i10p_comm0 i10p_comm1 i10p_comm2 i10p_comm3 \
         i10p_kdesca i10p_kdesc i10p_kpte i10p_root i10p_pgs i10p_hits i10p_chbad \
         i10p_uva i10p_pte i10p_ptea i10p_pfn i10p_pp i10p_pflags i10p_vnode i10p_off \
         i10p_hash i10p_map i10p_map0 i10p_mapn i10p_min i10p_hoff i10p_hitv \
         i10p_w0 i10p_w1 i10p_w2 i10p_w3 i10p_w4 i10p_w5 i10p_w6 i10p_w7 \
         i10p_p_kvseg i10p_p_segu i10p_p_segkmap i10p_p_pages i10p_p_pgbase i10p_p_pgend \
         i10g_hook i10g_magic i10g_on i10g_wantval i10g_lova i10g_hiva i10g_armed i10g_armproc \
         i10g_seq i10g_arena_n i10g_scan_hits i10g_wlatched i10g_wseq i10g_wctx i10g_wsr i10g_wpc \
         i10g_wfa i10g_wslot i10g_wb3a i10g_wb3d i10g_wtgt i10g_wtoff i10g_wmem \
         i10g_ilatched i10g_iseq i10g_ifa i10g_iuva i10g_iframe i10g_ipfn i10g_iproc i10g_ioff \
         i10g_iself i10g_ipp i10g_ipflags i10g_ivnode i10g_ioffp i10g_imap i10g_inzlo i10g_inzhi i10g_izrun \
         i10g_plo i10g_phi i10g_p_armed i10g_p_proc i10g_p_fault_n i10g_ipc i10g_isr i10g_iwb3a i10g_iwb3d i10g_wsrc i10g_wsrcr i10g_wsrcv i10g_wpv0 i10g_wpv1 i10g_wpv6 \
         hat_sdtfree hat_ptdat_retire ptd_magic ptd_on ptd_calls ptd_retired_n ptd_pgfreed_n \
         ptd_keep0_n ptd_keepn_n ptd_meta_n ptd_badlink_n ptd_wake_n ptd_tblfreed_n \
         nullvect nullvect_orig kvp_magic kvp_on kvp_n kvp_user_n kvp_super_n kvp_over_n \
         kvp_last_vec kvp_last_pc kvp_vec \
         sync syncg_magic syncg_calls syncg_skip_ops syncg_skip_fn syncg_last_i \
         page_init page_init_orig pgz_magic pgz_calls pgz_npages pgz_dirty_n pgz_held_n \
         smu_panic_latch smu_magic smu_n smu_why smu_scan smu_bucket smu_want smu_pp \
         bt_frame_ok bt_magic bt_walks bt_frames bt_stops bt_laststop bt_prev bt_budget \
         bt_badret bt_lastbadret \
         unt_latch unt_magic unt_n unt_magic2 unt_usp unt_uar0 unt_comm0 unt_comm1 unt_u0 unt_u1 \
         setregs setregs_orig srg_utraps srg_magic srg_match srg_ut_stamp srg_stamp1 srg_stamp2 \
         srg_ut_n srg_n srg_pushslot srg_slot_at srg_uar0_pre srg_uar0_post srg_ar0_0 srg_pcb0_post \
         ini_main ini_magic ini_stamp1 ini_stamp2 ini_n ini_ret ini_pcb0 ini_uar0 \
         ini_user_rte iur_magic iur_stamp1 iur_stamp2 iur_n iur_pc iur_a7 iur_usp \
         iur_f_sr iur_f_pc iur_f_fmt \
         smu_addr smu_off smu_addr0 smu_vp smu_smoff smu_hashsz smu_pflags \
         pgz_have pgz_first_i pgz_first_w0 pgz_first_map pgz_first_lc pgz_hash_n pgz_hashsz \
         fpsp060_top fpsp060_image fpsp060_vec11 f60_magic f60_entry_n f60_mem_n f60_real_n \
         f60_access_n f60_done_n f60_reserved_n f60_last_co f60_memfail_n f60_arith_n \
         f60_bsun_n f60_fline_n f60_trap_n f60_trace_n f60_fpudis_n f60_superdone_n \
         fpu_save fpu_save_orig fpu_restore fpu_restore_orig fpu_setup fpu_setup_orig \
         fpc_magic fpc_save_n fpc_save_wrt_n fpc_null_n fpc_idle_n fpc_excp_n fpc_odd_n \
         fpc_last_frame fpc_rest_n fpc_rest_live_n fpc_rest_null_n fpc_rest_wrt_n fpc_setup_n \
         fpc_save_nofpu_n fpc_rest_nofpu_n fpc_setup_nofpu_n \
         fpuinit fpuinit_orig fpu_setup_gated fpi_magic fpi_n fpi_trap_n fpi_nofpu_n \
         fpi_idle_n fpi_badfmt_n fpi_pcr_pre fpi_pcr_post fpi_savedvec fpi_ok \
         fpi_ss_skip_n fpi_ss_pass_n fpi_frame fpi_reset_frame f60_fpudis_nofpu_n \
         wbf_magic wbf_prop_on wbf_fail_n wbf_user_n wbf_sup_n wbf_signal_n wbf_nosig_n \
         wbf_krn_n wbf_swallow_n wbf_afb_n wbf_addr wbf_wbs wbf_fc wbf_sup_fatal \
         wbf_own_cookie wbf_own_sp wbf_alien_n wbf_alien_sp wbf_slot \
         wbf_last_signo wbf_last_code wbf_last_addr wbf_signo wbf_code wbf_fa; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done
echo "[*] stray UND refs (should be NONE for our globals):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'kptr040|kroot040|sysseginit|segkmem_mapin|kptbl|syssegs|hardbus_orig|hat_growsdt|hat_sdtfree' \
	| sed 's/^/      /' || echo "      (none)"

# HARD CHECK (2026-08-01, ISSUE-40): legacysdt040.o CALLS the retained hat_growsdt,
# which is a file-LOCAL 't' in the stock image.  `ld -r` does NOT fail on an
# unresolved symbol, so a missing --globalize-symbol would produce a kernel whose
# teardown edge jumps to address 0 -- i.e. a silent, catastrophic regression that
# only shows up at the first process exit.  Shaped like the resume/hardbus guards.
GSADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hat_growsdt" && $2=="T" {print $1}')
LSADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hat_legacy_sdt_free" && $2=="T" {print $1}')
if [ -z "$GSADDR" ]; then
	echo "[FAIL] hat_growsdt is not a global T -> ISSUE-40 teardown edge is unbound"; exit 1
fi
if [ -z "$LSADDR" ]; then
	echo "[FAIL] hat_legacy_sdt_free missing -> ISSUE-40 fix not linked in"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U hat_growsdt$' >/dev/null 2>&1; then
	echo "[FAIL] hat_growsdt still UND after globalize -> the call would go to 0"; exit 1
fi
echo "[OK] ISSUE-40 edge bound: hat_legacy_sdt_free @0x$LSADDR -> retained hat_growsdt @0x$GSADDR."

# HARD CHECK (2026-08-02, ISSUE-40 part 2): same shape for the ptdat edge.  This
# one is worse if it slips: hat_ptfree runs on every table-page free, so an
# unbound hat_sdtfree would jump to 0 from the middle of address-space teardown.
SFADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hat_sdtfree" && $2=="T" {print $1}')
PRADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hat_ptdat_retire" && $2=="T" {print $1}')
if [ -z "$SFADDR" ]; then
	echo "[FAIL] hat_sdtfree is not a global T -> ISSUE-40 ptdat edge is unbound"; exit 1
fi
if [ -z "$PRADDR" ]; then
	echo "[FAIL] hat_ptdat_retire missing -> ISSUE-40 part 2 not linked in"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U hat_sdtfree$' >/dev/null 2>&1; then
	echo "[FAIL] hat_sdtfree still UND after globalize -> the call would go to 0"; exit 1
fi
echo "[OK] ISSUE-40 ptdat edge bound: hat_ptdat_retire @0x$PRADDR -> retained hat_sdtfree @0x$SFADDR."

# HARD CHECK (2026-08-20, ISSUE-100): syncguard.o replaces sync() so the panic path
# survives a vfs switch that vfsinit has not filled yet.  This one fails QUIETLY in
# the worst possible way: a missing --weaken-symbol, or the object dropped from the
# link list, leaves the stock body strong, `ld -r` succeeds, and the kernel is
# byte-plausible -- and then the next early panic destroys its own diagnosis exactly
# as before, with nothing in the build output to say the fix was not in it.  So
# assert both directions: our strong def must have MOVED OFF the stock address, and
# the counter block must be there to read it by.
SGADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="sync" && $2=="T" {print $1}')
if [ -z "$SGADDR" ]; then
	echo "[FAIL] sync is not a global T -> syncguard.o did not link"; exit 1
fi
if [ "$SGADDR" = "0005d21a" ]; then
	echo "[FAIL] sync is still the stock body at 0x5d21a -> the weaken/override did not take"; exit 1
fi
if [ -z "$(m68k-linux-gnu-nm "$OUT" | awk '$3=="syncg_magic" && $2=="D" {print $1}')" ]; then
	echo "[FAIL] syncg_magic missing -> syncguard.o's counter block is not in the image"; exit 1
fi
echo "[OK] ISSUE-100 panic-path guard bound: sync @0x$SGADDR (stock body was 0x5d21a)."

# HARD CHECK (2026-08-20, ISSUE-102): pageinitzero.o wraps page_init so the page-frame
# database is zeroed before it is published.  Both directions matter and each fails
# silently on its own: without the weaken, the stock body stays strong and the boot
# panics on metal exactly as before; without the retained alias the wrapper tail-jumps
# to address 0 and the machine dies in kvm_init with no message at all.  page_init has
# exactly ONE caller in the image (kvm_init @0x48eaa), so this is also the whole
# blast radius.
PZADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="page_init" && $2=="T" {print $1}')
PZORIG=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="page_init_orig" && $2=="T" {print $1}')
if [ -z "$PZADDR" ] || [ "$PZADDR" = "000af42a" ]; then
	echo "[FAIL] page_init did not move off the stock body 0xaf42a -> ISSUE-102 fix not in"; exit 1
fi
if [ "$PZORIG" != "000af42a" ]; then
	echo "[FAIL] page_init_orig is '$PZORIG', not 000af42a -> the wrapper would tail-jump wrong"; exit 1
fi
if [ -z "$(m68k-linux-gnu-nm "$OUT" | awk '$3=="pgz_magic" && $2=="D" {print $1}')" ]; then
	echo "[FAIL] pgz_magic missing -> pageinitzero.o's counter block is not in the image"; exit 1
fi
echo "[OK] ISSUE-102 page-database zero bound: page_init @0x$PZADDR -> page_init_orig @0x$PZORIG."

# HARD CHECK (2026-08-19, ISSUE-10): wb040.o's usrxmemflt tail now `jsr`s i10p_probe
# (i10rev040.o).  `ld -r` does not fail on an unresolved symbol, so dropping
# i10rev040.o from the link list -- or renaming the entry -- would leave a call to
# address 0 on the UNRESOLVED USER FAULT path: the kernel would survive until the
# first process took a fault it could not resolve, and then die somewhere that looks
# nothing like the cause.  Same shape as the two edges above, for the same reason.
IPADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="i10p_probe" && $2=="T" {print $1}')
if [ -z "$IPADDR" ]; then
	echo "[FAIL] i10p_probe is not a global T -> the usrxmemflt capture edge is unbound"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U i10p_probe$' >/dev/null 2>&1; then
	echo "[FAIL] i10p_probe still UND -> the unresolved-fault path would call address 0"; exit 1
fi
echo "[OK] ISSUE-10 capture edge bound: usrxmemflt -> i10p_probe @0x$IPADDR."

# HARD CHECK (2026-08-19, ISSUE-10 write-watch): both usrxmemflt and krnxmemflt now
# `jsr` i10w_hook (i10rev040.o) at their RESOLVED tails.  Same trap as the probe edge
# above: `ld -r` does not fail on an unresolved symbol, so a dropped object or a renamed
# entry would leave a call to address 0 on the resolved-fault path -- taken by every
# memory fault the moment the watch is armed.  Shaped like the i10p_probe guard.
IWADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="i10w_hook" && $2=="T" {print $1}')
if [ -z "$IWADDR" ]; then
	echo "[FAIL] i10w_hook is not a global T -> the write-watch capture edge is unbound"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U i10w_hook$' >/dev/null 2>&1; then
	echo "[FAIL] i10w_hook still UND -> the resolved-fault path would call address 0"; exit 1
fi
echo "[OK] ISSUE-10 write-watch edge bound: usrxmemflt/krnxmemflt -> i10w_hook @0x$IWADDR."

# HARD CHECK (2026-08-19, ISSUE-10 genesis watch): both usrxmemflt and krnxmemflt now
# also `jsr` i10g_hook (i10rev040.o) at their RESOLVED tails, right after i10w_hook.
# Same trap as the two edges above: a dropped object or renamed entry would leave a
# call to address 0 on the resolved-fault path, taken by every memory fault once the
# watch is armed.  Shaped like the i10w_hook guard.
IGADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="i10g_hook" && $2=="T" {print $1}')
if [ -z "$IGADDR" ]; then
	echo "[FAIL] i10g_hook is not a global T -> the genesis-watch capture edge is unbound"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U i10g_hook$' >/dev/null 2>&1; then
	echo "[FAIL] i10g_hook still UND -> the resolved-fault path would call address 0"; exit 1
fi
echo "[OK] ISSUE-10 genesis-watch edge bound: usrxmemflt/krnxmemflt -> i10g_hook @0x$IGADDR."

# HARD CHECK (2026-08-19, ISSUE-10 resolution audit): usrxmemflt now `jsr`s i10r_pre
# on ENTRY and i10r_post at its exit join (i10rev040.o).  Both edges are on the path
# EVERY user fault takes -- not just the resolved ones -- so an unbound entry here is
# a call to address 0 on the first user fault of the boot.  Shaped like the i10w/i10g
# guards, and checking both symbols because a half-linked pair is the shape that
# would survive a build and die at run time.
for h in i10r_pre i10r_post; do
	HADDR=$(m68k-linux-gnu-nm "$OUT" | awk -v h="$h" '$3==h && $2=="T" {print $1}')
	if [ -z "$HADDR" ]; then
		echo "[FAIL] $h is not a global T -> the resolution-audit edge is unbound"; exit 1
	fi
	if m68k-linux-gnu-nm "$OUT" | grep -E " U $h\$" >/dev/null 2>&1; then
		echo "[FAIL] $h still UND -> every user fault would call address 0"; exit 1
	fi
	echo "[OK] ISSUE-10 resolution-audit edge bound: usrxmemflt -> $h @0x$HADDR."
done

# HARD CHECK (2026-08-20, ISSUE-10 decision audit PART SEVEN): i10rev040.o's i10s outer
# wrapper now OWNS the strong segvn_faultpage and tail-jmps segvn_faultpage_prot -- the
# per-page restorer, renamed above from segvn_prot040.o.  Two ways this can silently
# break, both of which `ld -r` links cleanly through: the wrapper never took the symbol
# (segvn_faultpage still resolves to the stock body at 0xac01a, so the audit is dead and
# the per-page check runs unobserved), or the tail target is unbound (segvn_faultpage_prot
# left UND -> the jmp goes to address 0 on the FIRST VM fault of the boot).  Assert both,
# and that the per-page body is still reachable off its stock address, before trusting it.
SFPADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="segvn_faultpage" && $2=="T" {print $1}')
SFPPADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="segvn_faultpage_prot" && $2=="T" {print $1}')
if [ -z "$SFPADDR" ]; then
	echo "[FAIL] segvn_faultpage is not a global T -> the i10s wrapper is unbound"; exit 1
fi
if [ "$SFPADDR" = "000ac01a" ]; then
	echo "[FAIL] strong segvn_faultpage is still the stock body 0xac01a -> i10s wrapper did not take the symbol"; exit 1
fi
if [ -z "$SFPPADDR" ]; then
	echo "[FAIL] segvn_faultpage_prot is not a global T -> the per-page restorer rename did not take"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U segvn_faultpage_prot$' >/dev/null 2>&1; then
	echo "[FAIL] segvn_faultpage_prot still UND -> the i10s tail jmp would go to address 0"; exit 1
fi
echo "[OK] ISSUE-10 decision-audit edge bound: segvn_faultpage (i10s @0x$SFPADDR) -> segvn_faultpage_prot @0x$SFPPADDR -> segvn_faultpage_orig @0xac01a."

# HARD CHECK (2026-08-20, ISSUE-10 as_fault audit PART EIGHT): i10rev040.o's i10a
# wrapper now OWNS the strong as_fault and CALLS as_fault_orig (the stock body, kept
# at 0xae108).  Same silent-break shapes `ld -r` links through: the wrapper never took
# the symbol (as_fault still resolves to 0xae108, audit dead and the fault path
# unobserved), or as_fault_orig is unbound (the wrapper's jsr goes to address 0 on the
# first matched fault).  Assert both.  as_segat is a pre-existing global the wrapper
# also calls; a stray UND on it would be caught by the reloc census, but check it here
# too since the audit's whole result is that call.
AFADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="as_fault" && $2=="T" {print $1}')
AFOADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="as_fault_orig" && $2=="T" {print $1}')
if [ -z "$AFADDR" ]; then
	echo "[FAIL] as_fault is not a global T -> the i10a wrapper is unbound"; exit 1
fi
if [ "$AFADDR" = "000ae108" ]; then
	echo "[FAIL] strong as_fault is still the stock body 0xae108 -> i10a wrapper did not take the symbol"; exit 1
fi
if [ -z "$AFOADDR" ] || [ "$AFOADDR" != "000ae108" ]; then
	echo "[FAIL] as_fault_orig missing or not at 0xae108 (nm: '$AFOADDR') -> the i10a call target is wrong"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U as_fault_orig$' >/dev/null 2>&1; then
	echo "[FAIL] as_fault_orig still UND -> the i10a jsr would go to address 0"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U as_segat$' >/dev/null 2>&1; then
	echo "[FAIL] as_segat still UND -> the i10a lookup would call address 0"; exit 1
fi
echo "[OK] ISSUE-10 as_fault-audit edge bound: as_fault (i10a @0x$AFADDR) -> as_fault_orig @0x$AFOADDR, as_segat resolved."

# HARD CHECK (2026-08-20, ISSUE-10 grow-failure probe PART NINE): i10rev040.o's i10b
# wrapper OWNS the strong brk and CALLS brk_orig (the stock body at 0x580e8).  brk has a
# SINGLE reference in the whole ET_REL image -- the sysent dispatch slot -- so taking the
# symbol is what puts the probe on the live syscall path; if the wrapper did not take it
# (brk still 0x580e8) the probe is dead, and if brk_orig is unbound the wrapper's jsr goes
# to address 0 on the first brk of the boot.  Assert both.
BKADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="brk" && $2=="T" {print $1}')
BKOADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="brk_orig" && $2=="T" {print $1}')
if [ -z "$BKADDR" ]; then
	echo "[FAIL] brk is not a global T -> the i10b wrapper is unbound"; exit 1
fi
if [ "$BKADDR" = "000580e8" ]; then
	echo "[FAIL] strong brk is still the stock body 0x580e8 -> i10b wrapper did not take the symbol"; exit 1
fi
if [ -z "$BKOADDR" ] || [ "$BKOADDR" != "000580e8" ]; then
	echo "[FAIL] brk_orig missing or not at 0x580e8 (nm: '$BKOADDR') -> the i10b call target is wrong"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U brk_orig$' >/dev/null 2>&1; then
	echo "[FAIL] brk_orig still UND -> the i10b jsr would go to address 0"; exit 1
fi
echo "[OK] ISSUE-10 grow-probe edge bound: brk (i10b @0x$BKADDR) -> brk_orig @0x$BKOADDR."

# HARD CHECK (2026-08-21, ISSUE-10 CURE): hgfault040.o owns the strong usrxmemflt_orig --
# the routine src/wb040.s calls -- and tail-calls the retained stock body as
# usrxmemflt_stock.  Four ways this breaks silently, all of which `ld -r` links through:
# the object is dropped from the link (usrxmemflt_orig falls back to the 0x5aede alias,
# the cure is absent and NOTHING says so); the alias was left named usrxmemflt_orig (two
# definitions, or ours never taking the name); usrxmemflt_stock is unbound (our tail jmp
# goes to address 0 on the FIRST user memory fault of the boot -- i.e. instant death); or
# one of the three grow edges is unbound (as_map / segvn_create / zfod_argsp), which would
# call or push address 0 the first time a heap page is grown on a fault.  Assert all of it.
UXOADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="usrxmemflt_orig" && $2=="T" {print $1}')
UXSADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="usrxmemflt_stock" && $2=="T" {print $1}')
if [ -z "$UXOADDR" ]; then
	echo "[FAIL] usrxmemflt_orig is not a global T -> wb040's jsr is unbound"; exit 1
fi
if [ "$UXOADDR" = "0005aede" ]; then
	echo "[FAIL] usrxmemflt_orig is still the stock body 0x5aede -> hgfault040.o is NOT in the kernel"; exit 1
fi
if [ -z "$UXSADDR" ] || [ "$UXSADDR" != "0005aede" ]; then
	echo "[FAIL] usrxmemflt_stock missing or not at 0x5aede (nm: '$UXSADDR') -> the tail call is wrong"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U usrxmemflt_stock$' >/dev/null 2>&1; then
	echo "[FAIL] usrxmemflt_stock still UND -> every user memory fault would jmp to address 0"; exit 1
fi
if [ -z "$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hg_magic" && $2=="D" {print $1}')" ]; then
	echo "[FAIL] hg_magic missing -> hgfault040.o's counter block is not in the image"; exit 1
fi
for hgs in as_map segvn_create zfod_argsp as_segat; do
	if m68k-linux-gnu-nm "$OUT" | grep -E " U $hgs\$" >/dev/null 2>&1; then
		echo "[FAIL] $hgs still UND -> the ISSUE-10 grow edge would use address 0"; exit 1
	fi
done
echo "[OK] ISSUE-10 cure bound: usrxmemflt_orig (hgfault040 @0x$UXOADDR) -> usrxmemflt_stock @0x$UXSADDR; as_map/segvn_create/zfod_argsp/as_segat resolved."

# HARD CHECK (2026-08-20, ISSUE-10 genesis introspection PART TEN): wb040.o's usrxmemflt
# and krnxmemflt now `jsr` i10c_hook (i10rev040.o) right after wbf_dropwarn -- the site
# that fires exactly once for a dropped pending write-back.  `ld -r` does not fail on an
# unresolved symbol, so a dropped object or renamed entry would leave a call to address 0
# on the first such drop.  Shaped like the i10w/i10g hook guards.
ICADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="i10c_hook" && $2=="T" {print $1}')
if [ -z "$ICADDR" ]; then
	echo "[FAIL] i10c_hook is not a global T -> the genesis-introspection edge is unbound"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U i10c_hook$' >/dev/null 2>&1; then
	echo "[FAIL] i10c_hook still UND -> the drop-warning path would call address 0"; exit 1
fi
echo "[OK] ISSUE-10 genesis-introspection edge bound: usrxmemflt/krnxmemflt -> i10c_hook @0x$ICADDR."

# HARD CHECK (2026-07-12): the RUNTIME kernel must carry the NATIVE resume (fixed-u
# remap) and the crossing-page hardbus -- stock resume (.text 0x9c) writes the retired
# 030 ublksde and never updates the live uarea_pt, so a kernel whose strong `resume`
# still resolves to 0x9c cannot context-switch (Codex PROCESS-MMU-CONTEXT-SWITCH-
# CONTRACT.md).  Same guard for hardbus (stock 0x5b3c2 loops on crossing reads).
RESADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="resume" && $2=="T" {print $1}')
HBADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="hardbus" && $2=="T" {print $1}')
if [ "$RESADDR" = "0000009c" ] || [ -z "$RESADDR" ]; then
	echo "[FAIL] strong resume is stock/missing (addr='$RESADDR') -> kernel cannot context-switch"; exit 1
fi
if [ "$HBADDR" = "0005b3c2" ] || [ -z "$HBADDR" ]; then
	echo "[FAIL] strong hardbus is stock/missing (addr='$HBADDR') -> crossing reads loop forever"; exit 1
fi
echo "[OK] native resume @0x$RESADDR + crossing-page hardbus @0x$HBADDR are the strong defs."

# HARD CHECK (2026-07-30, ISSUE-38): the strong `copyout` must be the cb_icode040
# wrapper, not the stock body at 0x576 -- a kernel whose copyout is stock leaves
# main()'s icode in dirty copyback lines and proc 1 dies before exec (the whole of
# ISSUE-38).  Guard shaped exactly like the resume/hardbus ones above.
COADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="copyout" && $2=="T" {print $1}')
if [ "$COADDR" = "00000576" ] || [ -z "$COADDR" ]; then
	echo "[FAIL] strong copyout is stock/missing (addr='$COADDR') -> icode never published to RAM (ISSUE-38)"; exit 1
fi
echo "[OK] cb_icode040 copyout wrapper @0x$COADDR is the strong def (stock body kept as copyout_orig)."

# HARD CHECK (2026-08-12, ISSUE-43): the FP context path.  Two ways this unit can be present
# in the tree and absent from the kernel, both of which have happened to other units here:
# an assembler error (relink does NOT abort on one -- it links the stock body instead), and a
# missing weaken (ld -r keeps the stock strong def and our object's def is dropped).  Either
# would produce a kernel that looks built and still reads byte zero of a 68060 frame.  So
# assert BOTH directions: the strong symbol moved off the stock address, and the stock body is
# still reachable at it as *_orig -- the 040 path is a tail jump to exactly that address.
for fpe in fpu_save:00000132 fpu_restore:00000158 fpu_setup:00019b50 $FPUINIT_BIND; do
	fpn=$(echo "$fpe" | cut -d: -f1)
	fpo=$(echo "$fpe" | cut -d: -f2)
	fpnew=$(m68k-linux-gnu-nm "$OUT" | awk -v n="$fpn" '$3==n && $2=="T" {print $1}')
	fporig=$(m68k-linux-gnu-nm "$OUT" | awk -v n="${fpn}_orig" '$3==n {print $1}')
	if [ -z "$fpnew" ] || [ "$fpnew" = "$fpo" ]; then
		echo "[FAIL] strong $fpn is stock/missing (addr='$fpnew') -> the 68060 still tests byte zero (ISSUE-43)"; exit 1
	fi
	if [ "$fporig" != "$fpo" ]; then
		echo "[FAIL] ${fpn}_orig is '$fporig', expected $fpo -> the 68040 tail jump has no target"; exit 1
	fi
	if [ "$(m68k-linux-gnu-nm "$OUT" | grep -cE " T $fpn\$")" != "1" ]; then
		echo "[FAIL] $fpn does not have exactly one strong definition"; exit 1
	fi
done
FPCMAG=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="fpc_magic" {print $1}')
[ -n "$FPCMAG" ] || { echo "[FAIL] fpc_magic missing -> fpu060.o is not in the link"; exit 1; }
echo "[OK] ISSUE-43 FP context override bound on all three routines; stock bodies kept as *_orig."

# HARD CHECK (2026-08-24, F1): the same two directions for the fourth routine.  fpuinit is the
# one the others depend on -- if it silently stays stock, fpu_present is decided by a probe that
# FSAVEs a 68060 frame into an 8-byte buffer, and every gate below it is gating on that answer.
if [ "$FPUINIT060" = "1" ]; then
	FPIMAG=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="fpi_magic" {print $1}')
	[ -n "$FPIMAG" ] || { echo "[FAIL] fpi_magic missing -> fpuinit060.o is not in the link"; exit 1; }
	FPGATE=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="fpu_setup_gated" && $2=="T" {print $1}')
	[ -n "$FPGATE" ] || { echo "[FAIL] fpu_setup_gated missing -> the sendsig gate has no target"; exit 1; }
	echo "[OK] F1 060 FPU probe bound; stock fpuinit kept as fpuinit_orig @0x19bac."
fi

# HARD CHECK (2026-08-01, USER-CODE-PUBLISH): the strong `mprotect` must be the
# codepub040 wrapper, not the stock body at 0x58550.  A kernel whose mprotect is
# stock still publishes W->X by accident (via hat_chgprot) but cannot publish a
# same-protection RWX call at all -- i.e. it silently does NOT implement the ABI,
# and the difference is invisible until a JIT executes stale bytes.
MPADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="mprotect" && $2=="T" {print $1}')
if [ "$MPADDR" = "00058550" ] || [ -z "$MPADDR" ]; then
	echo "[FAIL] strong mprotect is stock/missing (addr='$MPADDR') -> no user-code publication ABI"; exit 1
fi
echo "[OK] codepub040 mprotect wrapper @0x$MPADDR is the strong def (stock body kept as mprotect_orig)."

# The shipped cache stage (2026-07-30): the base image is COPYBACK by default now
# that ISSUE-38 is closed.  Printed, and asserted to be one of the two legal
# values by the script itself; the write-through control is the derived image
# (patch_b2_flip.py --wt).
run_step indent python3 "$HERE/src/patch_b2_flip.py" "$OUT" --check
echo
m68k-linux-gnu-size "$OUT" | sed 's/^/      /'

# text/data contiguity (loader copies them as one block)
# Hex -> decimal is done by the shell, not by awk: strtonum() is a GNU extension and the
# default awk on Debian/Ubuntu is mawk, where it is a hard error.  2026-08-14.
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))   # $1 = text end, $2 = data offset, decimal
if [ "$1" = "$2" ]; then echo "[OK] text/data contiguous."
else echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"; exit 1; fi

# HARD CHECK (2026-07-09): final .data size MUST be a 4-byte multiple. The loader
# (rel.c bindsections) places .bss at data_addr+data_size with NO alignment, so a
# misaligned .data total shifts the ENTIRE kernel .bss -- CPU tolerates it (68020+)
# but the SDMAC 32-bit DMA engine has no A[1:0] bits: a misaligned DMA buffer (e.g.
# sdpart.c `block`) reads the RDB into the wrong offset -> 'RDSK' scan fails ->
# root mount ENXIO. This is exactly the quiet-on-Amiberry root-mount regression.
DSZ=$(( 0x$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print $6}') ))
if [ $((DSZ % 4)) -ne 0 ]; then
	echo "[FAIL] .data size 0x$(printf %x $DSZ) not a 4-byte multiple -> .bss misaligned at runtime (add .balign 4 to the offending .s)"; exit 1
fi
echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned (bss placement safe)."

echo
echo "[*] patching remaining 030 PMMU instructions (pflusha, ptest stubs)"
run_step 2 python3 "$HERE/src/patch_pflusha_040.py" "$OUT"
run_step 2 python3 "$HERE/src/patch_pmmu_040.py" "$OUT"

echo "[*] Model B (4KB page frame) Tier-0 byte patches"
run_step 3 python3 "$HERE/src/patch_modelb.py" "$OUT"

echo "[*] Model B Tier-2 pager/fs page-I/O (dir-read chain) byte patches"
run_step 3 python3 "$HERE/src/patch_modelb_pager.py" "$OUT"

echo "[*] Model B writeback/putpage conversion (docs/archive/WRITEBACK-TASK.md; WRITEBACK_GROUPS=spec,pvn,ufs,callers)"
run_step 3 python3 "$HERE/src/patch_writeback.py" "$OUT"

echo "[*] Model B block-swap page-IN conversion (ISSUE-10: klustsize 0x800 data init + residuals)"
run_step 6 python3 "$HERE/src/patch_swapin.py" "$OUT"

echo "[*] Model B swap resource geometry (SWAPADD-MODEL-B-PATCH-SPEC.md: swapadd/swapdel/swapinfo_free/undelswap)"
run_step 3 python3 "$HERE/src/patch_swapgeom.py" "$OUT"

echo "[*] Model B exec initial-stack group (EXEC-INITIALSTK-PATCH-SPEC.md: extractarg + exec_initialstk data init)"
run_step 2 python3 "$HERE/src/patch_execstk.py" "$OUT"

echo "[*] Model B pageout-policy defaults (SETUPCLOCK-VMETER-PATCH-SPEC.md: lotsfree/desfree/minfree + vmmeter UPIO fold)"
run_step 2 python3 "$HERE/src/patch_pageoutdefs.py" "$OUT"

echo "[*] Model B mincore vector (MINCORE-VECTOR-PATCH-SPEC.md: btoc + alignment gate; 0x40000 chunk unchanged)"
run_step 2 python3 "$HERE/src/patch_mincore.py" "$OUT"

echo "[*] Model B device-mmap PFN geometry (scrmmap/ammmap/timmap phystopfn >>11 -> >>12; fractal/julia + /dev/amiga + TIGA)"
run_step 2 python3 "$HERE/src/patch_devmmap_pfn.py" "$OUT"

echo "[*] CM-B1 segkmem reader geometry (CM-PTE-WRITER-MATRIX.md: checkprot/getprot 2K->4K + stock-body canaries)"
run_step 3 python3 "$HERE/src/patch_segkmem.py" "$OUT"

echo "[*] B1 DMA hook: retarget A3091/SDMAC stopdma calls -> dma_a3091_stopdma (DMA-INITIATOR-CENSUS.md)"
run_step 6 python3 "$HERE/src/patch_a3091_dma.py" "$OUT"
run_step 6 python3 "$HERE/src/patch_a3091_badhardware.py" "$OUT"
run_step 3 python3 "$HERE/src/patch_segdev_bridge.py" "$OUT"
run_step 2 python3 "$HERE/src/patch_segdev_ops.py" "$OUT"

echo "[*] ISSUE-21 fix: retarget _start jsr config -> config_cachefix (cache-off handoff)"
run_step 3 python3 "$HERE/src/patch_config_cachefix.py" "$OUT"

echo "[*] ISSUE-39: count hat_sdtalloc out-of-contiguous-memory warnings"
python3 "$HERE/src/patch_sdtfail.py" "$OUT"

echo "[*] ISSUE-103: latch which of segmap_unlock's three guards panics"
run_step 2 python3 "$HERE/src/patch_segmapdbg.py" "$OUT"

echo "[*] per-process fault-depth gate: assert v.v_proc matches the table size"
python3 "$HERE/src/check_vproc.py" "$OUT"

echo "[*] DBG-TEXT-PUBLISH: publish debugger writes to user text (3 relocation retargets)"
run_step 4 python3 "$HERE/src/patch_dbgpublish.py" "$OUT"

echo "[*] B2 page-release barrier: page_free + free_vp_pages choke-point hooks (CB-PAGE-LIFECYCLE-CLOSURE.md)"
run_step 3 python3 "$HERE/src/patch_cb_release.py" "$OUT"

# ISSUE-104 (2026-08-21): PC-relative like the cb_release hook above and for the same
# reason -- an absolute byte-patched target would need loader rebasing.  Must run
# after the core ld -r; the FPSP link that follows appends to $OUT and leaves our
# .text where it is, so the displacement stays valid.
echo "[*] ISSUE-104: backtrace frame test -> bt_frame_ok (range + order + cap)"
run_step 1 python3 "$HERE/src/patch_btwalk.py" "$OUT"

echo "[*] ISSUE-105: xpanic's sync gate reads uninitialised bits -- make it deterministic"
run_step 1 python3 "$HERE/src/patch_xpanic_sync.py" "$OUT"

echo "[*] ISSUE-106: latch USP/u_ar0/u_comm at the fatal user-fault NOTICE"
run_step 2 python3 "$HERE/src/patch_usptrap.py" "$OUT"

echo "[*] ISSUE-106 round 2: retarget the utraps -> u_trap edge (pushed-USP slot)"
run_step 2 python3 "$HERE/src/patch_srgtrap.py" "$OUT"

echo "[*] ISSUE-106 round 3: latch the user PC _start hands to the initial rte"
run_step 2 python3 "$HERE/src/patch_inittrap.py" "$OUT"

echo "[*] ISSUE-106 round 4: capture the user-transition RTE (frame + SSP + USP)"
run_step 1 python3 "$HERE/src/patch_inituser.py" "$OUT"

echo "[*] 060-B: framesz[4] = 16 (68060 format-4 access-error frame; inert on 030/040)"
python3 "$HERE/src/patch_framesz060.py" "$OUT"

# F1-M2 (2026-08-24): sendsig calls fpu_setup with no fpu_present gate, so on a 68LC060 the
# first delivered signal executes FRESTORE in supervisor mode.  Relocation retarget, the same
# mechanism as patch_dbgpublish.py above; the wrapper's 040 arm is a plain tail jump.  Runs
# with the byte patches rather than after the FPSP link, because the target comes from the core
# ld -r and the FPSP link only appends -- and the assertion after it re-reads the finished
# image, so a superseded retarget would not survive to the artifact unnoticed.
if [ "$FPUINIT060" = "1" ]; then
	echo "[*] F1-M2: sendsig -> fpu_setup only when fpu_present != 0"
	run_step 2 python3 "$HERE/src/patch_sendsig_fpu.py" "$OUT"
fi

echo "[*] ISSUE-15: KMA pool page counts (SMALLCLICKS/BIGCLICKS 2K->4K clicks) + kmem_avail ptob"
run_step 3 python3 "$HERE/src/patch_kmapools.py" "$OUT"

echo "[*] ISSUE-17/18: procfs user-memory I/O geometry (prfastmapout shift + prusrio page loop)"
run_step 3 python3 "$HERE/src/patch_procio.py" "$OUT"

echo "[*] ISSUE-28: memcntl/mem_unlock mlock-bitmap geometry (as_ctl + segvn_lockop are ALREADY 4K)"
run_step 3 python3 "$HERE/src/patch_memcntl.py" "$OUT"

# ISSUE-27 (PAGECREATE-TAILZERO-SPEC.md).  segmap_pagecreate is ALREADY a 4 KiB producer;
# its consumers still rounded their zero-fill to 2 KiB, leaving
# [roundup(end,2048), roundup(end,4096)) of a freshly created page holding the recycled
# physical page's contents -- a live silent data leak on the UFS root write path.
# Groups: PAGECREATE_GROUPS=live,fbzero,spec (default all).  'live' (as_iolock+rwip+rwvp)
# is ATOMIC.  S5 writei and ufs_bmap's own arithmetic are deliberately NOT in this patch.
echo "[*] ISSUE-27: segmap_pagecreate consumer tail-zero + as_iolock geometry (PAGECREATE_GROUPS=live,fbzero,spec)"
run_step 3 python3 "$HERE/src/patch_pagecreate.py" "$OUT"

# pvn_vptrunc final-page tail zeroing (Codex P1, PRODUCER-CONSUMER-ASYMMETRY-CENSUS.md).
# MAX(zbytes, PAGESIZE - (vplen & PAGEOFFSET)) still used 2 KiB while clearing a 4 KiB
# page.  The 8 KiB segmap-slot constants next to it are asserted as canaries.
echo "[*] pvn_vptrunc: final-page tail zeroing PAGESIZE term (2 sites + 2 segmap-slot canaries)"
run_step 3 python3 "$HERE/src/patch_pvntrunc.py" "$OUT"

# ISSUE-31: ufs_bmap VM-page geometry -- the UFS provider half of the ISSUE-27 boundary.
# rwip now feeds it a 4 KiB-derived alloc_only; its own PAGESIZE arithmetic must match.
# 11 sites; the three moveq #11 NDADDR-1 direct-block thresholds are asserted UNCHANGED,
# and the patch refuses to run unless ISSUE-27 (as_iolock) is already 4 KiB.
echo "[*] ISSUE-31: ufs_bmap page geometry (11 sites + 3 NDADDR canaries + ISSUE-27 precondition)"
run_step 3 python3 "$HERE/src/patch_ufsbmap.py" "$OUT"

# ISSUE-32: live ELF exec mapping boundary (EXEC-BOUNDARY-CENSUS.md).  Three atomic
# groups: exhd (header-cache ranges), execmap (VOP_MAP eligibility + mapping inputs),
# elfsz (*execsz producer AND consumer -- the census listed only the consumer; the
# producer in the LOCAL symbol mapelfexec was found while discharging its proof
# obligation).  COFF core/exec and grow/brk stay deferred.
echo "[*] ISSUE-32: ELF exec mapping boundary (EXECBOUNDARY_GROUPS=exhd,execmap,elfsz)"
run_step 3 python3 "$HERE/src/patch_execboundary.py" "$OUT"

# ISSUE-33: remaining device-mmap crossings.  d_mmap must return a 4 KiB PFN because
# hat_devload maps it as pfn<<12; mmmmap//dev/mem and resmmap still produced phys>>11.
# Plus segdev_incore's vector stride, which crosses into the already-4-KiB mincore.
# The rest of the segdev family stays 2 KiB on purpose and is asserted unchanged.
echo "[*] ISSUE-33: device-mmap PFN + segdev_incore vector (DEVMMAP2_GROUPS=pfn,incore)"
run_step 3 python3 "$HERE/src/patch_devmmap2.py" "$OUT"

# sysconfig(_CONFIG_PAGESIZE) reported 2048 on a 4 KiB kernel -- the kernel misreporting
# ITSELF to user space, which is also how a program computes an alignment that lands at
# page+0x800 and then meets the genuinely ABI-shaped mmap/munmap/mprotect defects.  Fixing
# this REDUCES exposure to those; it is not part of the same compatibility decision and it
# lands alone.  Two canaries next door: the POSIX_VER 198808 and the case VALUE 6.
# ISSUE-35, PROVEN ON REAL HARDWARE 2026-07-27 and attributed to us: a file whose length is
# an exact multiple of 8192 lost exactly its last 2048 bytes on NFS write.  nfs_putpage's
# io_len advanced in 2 KiB steps against a 4 KiB page population.  Codex settled attribution
# statically -- on stock 030 the same code is correct because page_t offsets and io_len
# advance together -- so this is a Model-B mixed-geometry regression.  MINIMUM ATOMIC UNIT IS
# TWO INSTRUCTIONS and a half-applied pair is worse than either endpoint; the script refuses.
# The other four sites of the six-site group stay unconverted and are asserted as canaries.
echo "[*] ISSUE-35: nfs_putpage io_len in 4 KiB pages (2 ATOMIC sites + 4 canaries)"
run_step 3 python3 "$HERE/src/patch_nfs_putpage.py" "$OUT"

# ISSUE-36 (NFS read side): the minimum SAFE repair is four sites, not the one that produces the
# SIGBUS.  nfs_getpage's EOF allowance (0x8b6ba) is the direct producer -- it rejects the final
# partial page for remainders 1..2048 with EFAULT, which segvn turns into 0xE05 and the user sees
# SIGBUS.  But relaxing that gate alone admits a page whose upper 2 KiB the I/O never initializes,
# and can newly expose a malformed pl[] return list, because the loop that fills it is bounded only
# by a byte countdown over a CIRCULAR page list.  So the io_len round-up pair and the countdown
# land together or not at all.  Codex: vm-map/NFS-READSIDE-ISSUE36-SITE.md (c95fd8c).
# The other nine sites of the thirteen stay unconverted and are asserted as canaries -- notably
# 0x8b72c, which must never be converted without the countdown.
echo "[*] ISSUE-36: nfs_getpage EOF + pl[] countdown + io_len (4 ATOMIC sites + 9 canaries)"
run_step 6 python3 "$HERE/src/patch_nfs_getpage.py" "$OUT"

echo "[*] sysconfig: _CONFIG_PAGESIZE reports 4096, not 2048 (1 site + 2 canaries)"
run_step 2 python3 "$HERE/src/patch_sysconfig_pagesize.py" "$OUT"

# ---------------------------------------------------------------------------
# Motorola 68040 FPSP (Floating-Point Support Package) + AMIX glue.
#
# PROMOTED INTO THE BASE LINK 2026-07-26 (was relink-040-fpsp.sh, an add-on layer).
# Rationale: the 68040 implements only a SUBSET of the FP instruction set in
# hardware and traps the rest (transcendentals, denormalized/packed operands).
# Motorola ships FPSP because completing the ISA is the OS's job -- so a 68040
# kernel without it is an INCOMPLETE 68040, not a kernel missing an extra.  Our own
# evidence: with vector 55 on nullvect, X died of SIGILL
# (`DBG SIG sig=4 pid=208 psargs=/usr/X/bin/Xsvga`) and that was mistaken for a
# graphics problem.  Keeping FPSP as a separate variant also doubled the kernel
# matrix and directly caused the 2026-07-25 near-miss where the graphics kernels
# were silently built from a stale base.
#
# Placement: LAST, after every byte patch.  `ld -r` puts $OUT's .text first, so all
# patch addresses survive -- but only in this order.  Do not move it earlier.
#
# 68060 safety: fpsp_glue040.s gates every entry on `cmpl #40,cputype` (see its
# comment "a 68060 boot of this dual-CPU binary must never enter the 040 path").
# The 060 keeps the stock nullvect path; its own SP package is separate work.
#
# Requires build/unix_boot040 (rel.c PC-rel reloc fix, amix-unix-boot v1.0-040-060) -- the FPSP body
# carries ~330 PC-relative relocations that the stock loader mis-applies.
#
# FPSP=0 builds the pre-2026-07-26 kernel WITHOUT FPSP.  Keep that escape hatch:
# it is how you A/B a suspected FPSP regression, and the image grows ~250 KB with
# FPSP in, which is exactly what the loader's copyit buffer path is sensitive to.
FPSP="${FPSP:-1}"
if [ "$FPSP" = "1" ]; then
	FPWORK="$HERE/build/fpsp-work/usr/src/sys/arch/m68k/fpsp"

	echo
	echo "[*] FPSP 1/4: package body build/fpsp040.o"
	sh "$HERE/build-fpsp040.sh" >/dev/null
	[ -f "$HERE/build/fpsp040.o" ] || { echo "[FAIL] fpsp040.o not built"; exit 1; }
	[ -f "$FPWORK/fpsp.defs" ]     || { echo "[FAIL] fpsp.defs missing at $FPWORK"; exit 1; }

	# The 060 branch in fpsp_vec11 exists only when its target is actually linked -- see the
	# comment at Lv11_stock for why an unresolved jmp there is worse than no branch at all.
	FPSP060="${FPSP060:-1}"
	[ "$FPSP060" = "1" ] && GLUE060="-DHAVE_FPSP060" || GLUE060=""

	echo "[*] FPSP 2/4: assemble AMIX glue src/fpsp_glue040.s${GLUE060:+ (with 060 branch)}"
	m68k-linux-gnu-gcc -x assembler-with-cpp -m68040 -I"$FPWORK" $GLUE060 \
		-c "$HERE/src/fpsp_glue040.s" -o "$HERE/build/fpsp_glue040.o"

	# F3 (2026-08-07/08): Motorola's M68060 FPSP, packaged as ONE unit (128-byte call-out
	# table + image + AMIX call-outs).  fpsp_vec11 sends cputype == 60 into it instead of
	# dropping to nullvect.  Without it a 68060 kills any process that executes an FP
	# instruction it does not retire in hardware -- and `fmovecr`, which is how compilers load
	# the constants 0.0 and 1.0, is one of them, so `x = 1.0;` was enough.
	#
	# DEFAULT IS ON since M2b (2026-08-08).  M2a's default-off was because its call-outs all
	# declined and the first trapping instruction panicked the kernel; M2b implements them.
	# Emulator acceptance, both CPU configs, one image (68040/68060-260807-09):
	#     060  fp060probe 7/7 bit-exact (0 ulp), f60 entry 4 / mem 4 / done 4, real 0
	#          fputest060 fork completes -- it used to die before its first printf
	#          battery 11/11
	#     040  fp060probe 7/7 bit-exact via the 040 package, every f60 counter still 0
	#          battery 11/11
	# HARDWARE ACCEPTANCE (M5) IS STILL OWED.  Escape hatch, one variable:
	#     FPSP060=0 sh relink-040.sh              <- 060 back on the old SIGSYS path
	#     FPSP060_VARIANT=pfpsp sh ...            <- D2 control: partial package, measured to
	#                                                fail all four (real_fline x4, done 0)
	FPSP060_OBJ=""
	if [ "$FPSP060" = "1" ]; then
		echo "[*] FPSP 2b/4: 68060 package build/fpsp060_pkg.o"
		sh "$HERE/build-fpsp060.sh" >/dev/null
		[ -f "$HERE/build/fpsp060_pkg.o" ] || { echo "[FAIL] fpsp060_pkg.o not built"; exit 1; }
		FPSP060_OBJ="$HERE/build/fpsp060_pkg.o"
	fi

	echo "[*] FPSP 3/4: ld -r  base + fpsp040.o + fpsp_glue040.o${FPSP060_OBJ:+ + fpsp060_pkg.o}"
	m68k-cbm-sysv4-ld -r -o "$OUT.fpsp" "$OUT" \
		"$HERE/build/fpsp040.o" "$HERE/build/fpsp_glue040.o" $FPSP060_OBJ
	mv "$OUT.fpsp" "$OUT"

	for s in fpsp_vec11 fpsp_done fpsp_fline fpsp_unimp fpsp_unsupp \
	         fpsp_operr fpsp_ovfl fpsp_unfl fpsp_snan fpsp_bsun; do
		m68k-linux-gnu-nm "$OUT" | grep -qE " [Tt] $s\$" \
			|| { echo "[FAIL] FPSP symbol $s not defined"; exit 1; }
	done
	LEAKFP=$(m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'fpsp_|mem_read|mem_write|real_' || true)
	[ -z "$LEAKFP" ] || { echo "[FAIL] unresolved FPSP symbols:"; echo "$LEAKFP"; exit 1; }
	echo "      all FPSP entry points defined, no unresolved FPSP refs"

	echo "[*] FPSP 4/4: retarget M68Kvec[11] and FP arith vectors 48/51/52/53/54/55"
	run_step 2 python3 "$HERE/src/patch_fpsp_vec11.py"   "$OUT"
	run_step 3 python3 "$HERE/src/patch_fpsp_vectors.py" "$OUT"
else
	echo
	echo "[*] FPSP=0 -- building WITHOUT the Motorola FPSP (A/B / bisect build)"
fi

# F2 (2026-08-06): retarget M68Kvec[61] -> isp61_vec.  AFTER the FPSP block on purpose:
# an FPSP `ld -r` would otherwise supersede the retarget, and running it here means FPSP=0
# and FPSP=1 images get identical vector-61 behaviour.  No FPSP script touches slot 61.
echo
echo "[*] ISP: retarget M68Kvec[61] (unimplemented integer) -> isp61_vec"
run_step 2 python3 "$HERE/src/patch_isp_vec61.py" "$OUT"

echo
echo "[*] FPU relink assertions (FPU-TIER1-ENABLE-SPEC.md:205-210), on the finished image:"
if [ "$FPUINIT060" = "1" ]; then
	run_step indent python3 "$HERE/src/check_fpu_relocs.py" "$OUT" --gated
else
	run_step indent python3 "$HERE/src/check_fpu_relocs.py" "$OUT"
fi

echo
echo "[*] reloc validation:"
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"

echo
echo "[*] stamping build id -> utsname.machine tag (banner + uname -m)"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

# 2026-08-14: the FPSP=0 branch used to say "boot: unix_boot", i.e. the STOCK loader, on the
# grounds that only the FPSP body carries PC-relative relocations and it is those that the stock
# rel.c mis-applies.  Measured, and that much is true:
#
#     FPSP=1   29857 relocations, 330 PC-relative (PC32 106, PC16 223, PC8 1)
#     FPSP=0   28734 relocations,   0 PC-relative
#
# But it is not the only reason the patched loader is required, and the other two apply to every
# build this script can produce:
#
#   * the stock copyit.s disables the MMU with unguarded 68030 `pmove tc/crp/srp`, which is
#     illegal on a 68040/68060 -- it traps before the kernel gets control.  This is the first
#     bring-up blocker of the whole port;
#   * `cputype` is poked into the kernel BY THE LOADER (unix_boot.c, pokesymlong).  The stock
#     loader does not do it, so on a 68060 the kernel keeps its built-in default of 40 and every
#     cputype-gated path -- fpu_save/fpu_restore/fpu_setup, isp61_vec, the FPSP 060 call-outs --
#     silently takes the 68040 branch on 68060 silicon.
#
# So there is no image here that the stock loader should be pointed at, and one message saying
# otherwise is worth more damage than the bisect convenience it was offering.
if [ "$FPSP" = "1" ]; then
	echo "[OK] built $OUT (WITH FPSP) -- boot: unix_boot040 unix-040   <- unix_boot040 is MANDATORY"
else
	echo "[OK] built $OUT (NO FPSP -- bisect build) -- boot: unix_boot040 unix-040   <- unix_boot040 is MANDATORY"
fi
