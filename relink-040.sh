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
STOCK="${STOCK:-/home/asokero/kehitys/amix-playground/vanilla/stand/unix}"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"
mkdir -p "$HERE/build"

echo "[*] assembling pstart040.s + kvm040.s + hat040.s + hat_chgprot040.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/pstart040.s"     -o "$HERE/build/pstart040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/kvm040.s"        -o "$HERE/build/kvm040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat040.s"        -o "$HERE/build/hat040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat_chgprot040.s" -o "$HERE/build/hat_chgprot040.o"
#     hat_pagesync040 = REAL 040 port of hat_pagesync (the pageout/pvn_done B_FREE reclaim
#                    sampling gate).  Stock's U/M gather is correct but its flushmmu via the
#                    retired 030 ptdat leaves the 040 ATC unflushed -> actively-used pages
#                    read p_ref==0 and get reclaimed+reused (ISSUE-10).  This flushes the
#                    ATC unconditionally after the walk.  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat_pagesync040.s" -o "$HERE/build/hat_pagesync040.o"
#     hat_exec040  = NO-OP override of the stock exec stack-page-table MOVE optimization.
#                    Stock passes flag 0 to hat_ptalloc (steal allowed) and its unpatched-030
#                    steal path, hit under memory pressure, orphans live 040 PTEs of a stolen
#                    table's pages (ISSUE-10 chain II).  as_exec moves the seg + faults rebuild
#                    the stack via hat_pteload, so the move is a pure (unsafe-on-040) optimization.
#                    Codex HAT-EXEC-POLICY.md-endorsed.  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat_exec040.s"    -o "$HERE/build/hat_exec040.o"
#     hat_dup040   = REAL 040 fork/COW port (ISSUE-4, boot-verified 2026-07-04 on branch
#                    040-hat-dup-port incl. the fork-without-exec COW subshell test) --
#                    replaces the old forkdbg.s no-op stub.  A genuine fix, belongs in base.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hat_dup040.s"     -o "$HERE/build/hat_dup040.o"

echo "[*] assembling genuine 68040 trap/fault runtime ports (moved out of the dbg overlay --"
echo "    these are REAL fixes, not diagnostics, so they belong in the base kernel):"
echo "      getfault040 = decode the 040 format-7 access-error frame (fault address)"
echo "      userspace040 = classify user-vs-kernel fault from the 040 SSW (route copyout)"
echo "      vtop040      = DTT0 identity phys for disk DMA (va < 0x40000000)"
echo "      wb040        = 040 access-error WRITE-BACK replay (the init copyout(icode) fix)"
echo "      ptest040     = real 040 ptestr -> 030-form PSR (the GOT-relocation COW-fault fix)"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/getfault040.s"  -o "$HERE/build/getfault040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/userspace040.s" -o "$HERE/build/userspace040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/vtop040.s"      -o "$HERE/build/vtop040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/wb040.s"        -o "$HERE/build/wb040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/ptest040.s"     -o "$HERE/build/ptest040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/uvatosde040.s"  -o "$HERE/build/uvatosde040.o"
#     prumap040    = lazy kvsegu slot-0 (proc 0 u-area) alias into kptr040 -- p0init's
#                    030 st_top1 writes are inert on 040; fixes the prgetpsinfo panic
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/prumap040.s"    -o "$HERE/build/prumap040.o"
#     haltsys040   = AttnFlags-guarded MMU disable for the reboot/halt path (ISSUE-5) --
#                    stock haltsys falls into unguarded 030 pmove tc/crp/srp, illegal on 040.
#                    Overrides rtnfirm TOO: mdboot calls rtnfirm (not haltsys) for fcn>=1,
#                    i.e. on every real reboot (ISSUE-5 fix v2)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/haltsys040.s"   -o "$HERE/build/haltsys040.o"
#     segu_lockfix = segu_get wrapper restoring SEGU_LOCKED in su_flags (ISSUE-7 root
#                    fix) -- the Model-B loop-bound patch (patch_modelb_pager.py:226)
#                    shared d5 as loop bound AND su_flags source, dropping the LOCKED
#                    bit, so segu_release never passed HAT_UNLOCK|HAT_RELEPP and the
#                    u-page keepcnt hold leaked -> page_abort freed live u-pages.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/segu_lockfix.s" -o "$HERE/build/segu_lockfix.o"
#     segu_ubptbl040 = post-fix wrappers rebuilding p_ubptbl from the live kptr040
#                    tree after stock segu_get/swapinub run (their inline st_top1
#                    walks are inert on 040 -> p_ubptbl was ZEROS; PREEMPT5).
#                    Chain: segu_get(ubptbl) -> segu_get_lockfix -> segu_get_orig
#                    (stock); the lockfix def is RENAMED below so each build keeps
#                    exactly one strong segu_get.  swapinub(ubptbl) -> swapinub_stock.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/segu_ubptbl040.s" -o "$HERE/build/segu_ubptbl040.o"
# inituname040 = wrapper appending " 68040-<buildid>" to utsname.machine (banner + uname -m)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/inituname040.s" -o "$HERE/build/inituname040.o"
# 060-B (2026-07-10): dual-CPU support objects (see 68060-prestudy.md).
#   cputype060 = the `cputype` global (40 default; unix_boot pokes 60 from AttnFlags)
#   lmul060    = portable lmul (stock's 64-bit muls.l forms trap on the 68060)
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/cputype060.s" -o "$HERE/build/cputype060.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/lmul060.s"    -o "$HERE/build/lmul060.o"
# ISSUE-13 (2026-07-12): bp_map/bp_mapout were left as stock 030 bodies (2 KiB, retired
# st_top1 tree) -> corrupt the NFS page-I/O temp mapping.  bp_map040 rewrites both for
# the live 040 kptr040 tree (4 KiB, phys|0x19).  Both GLOBAL T -> plain --weaken-symbol.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/bp_map040.s"  -o "$HERE/build/bp_map040.o"
# runtime040 (2026-07-12): the formerly-overlay-only LOAD-BEARING overrides promoted
# into the base link (Codex PROCESS-MMU-CONTEXT-SWITCH-CONTRACT.md packaging finding:
# bare unix-040 retained stock resume -> fixed-u never remapped -> not bootable).
#   resume   = native 040 fixed-u remap (ctx switch core)
#   hardbus  = page-crossing read fix (crossing ifetch/read refault loop)
#   sched/idle = sched still a deliberate process-swap disable (u-area swap-out
#                unvalidated); schedpaging override RETIRED 2026-07-15 -- writeback
#                group converted (patch_writeback.py), stock pageout daemon runs
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/runtime040.s" -o "$HERE/build/runtime040.o"
# krnxmemflt040 (2026-07-13, ISSUE-13 capture 2): NATIVE kernel fault-resolver core.
# Stock krnxmemflt_orig was a coupled 4-defect 030 remnant (user-FC ptest, frame+72
# rw decode + prot gate, 030 leaf walk) + the k_trap landing-pad recursion window.
# The wb040.s public wrapper is UNCHANGED: its krnxmemflt_orig call now binds to this
# strong def (the stock body stays reachable as krnxmemflt_stock, reference only).
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/krnxmemflt040.s" -o "$HERE/build/krnxmemflt040.o"
m68k-linux-gnu-objcopy --redefine-sym segu_get=segu_get_lockfix "$HERE/build/segu_lockfix.o"

echo "[*] globalize local fns (so overrides + cross-refs bind); weaken the replaced ones"
cp "$STOCK" "$HERE/build/unix-stage1"
# sysseginit, hat_pteload are REPLACED (globalize+weaken).  hat_ptalloc, hat_pt2ptdat
# are file-LOCAL but CALLED by our hat040.o (and byte-patched in place by patch_modelb),
# so globalize them too -- else ld -r can't bind hat040.o's refs to the kernel's local
# defs (the crashsw/crash_sync RELA-guru lesson).
m68k-linux-gnu-objcopy \
	--globalize-symbol sysseginit \
	--globalize-symbol hat_pteload \
	--globalize-symbol hat_ptalloc \
	--globalize-symbol hat_sdtalloc \
	--globalize-symbol hat_pt2ptdat \
	--globalize-symbol hat_ptfree \
	--globalize-symbol free_pts \
	--globalize-symbol pt_waiting \
	--globalize-symbol usrxmemflt \
	--globalize-symbol krnxmemflt \
	"$HERE/build/unix-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol pstart \
	--weaken-symbol sysseginit \
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
	--weaken-symbol haltsys \
	--weaken-symbol rtnfirm \
	"$HERE/build/unix-stage1"

# Genuine 040 trap/fault runtime overrides (getfault040/userspace040/vtop040/wb040).
# usrxmemflt is file-LOCAL ('t') -> globalized above so wb040's strong def binds and the
# original is reachable via the alias.  vtop040 tail-jmps the aliased original for the
# kvseg/user path.  get_fault and userspace are GLOBAL T -> plain weaken is enough.
m68k-linux-gnu-objcopy \
	--weaken-symbol get_fault \
	--weaken-symbol userspace \
	--weaken-symbol vtop \
	--add-symbol vtop_orig=.text:0xb7568,function,global \
	--weaken-symbol usrxmemflt \
	--add-symbol usrxmemflt_orig=.text:0x5aede,function,global \
	--weaken-symbol krnxmemflt \
	--add-symbol krnxmemflt_stock=.text:0x5b140,function,global \
	--weaken-symbol segu_get \
	--add-symbol segu_get_orig=.text:0x000aa466,function,global \
	--weaken-symbol swapinub \
	--add-symbol swapinub_stock=.text:0x000a9e5c,function,global \
	--weaken-symbol inituname \
	--add-symbol inituname_orig=.text:0x00049140,function,global \
	--weaken-symbol lmul \
	--weaken-symbol bp_map \
	--weaken-symbol bp_mapout \
	--weaken-symbol sched \
	--weaken-symbol idle \
	--weaken-symbol resume \
	--weaken-symbol hardbus \
	--add-symbol hardbus_orig=.text:0x5b3c2,function,global \
	"$HERE/build/unix-stage1"

OUT="$HERE/build/unix-040"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-stage1" \
	"$HERE/build/pstart040.o" "$HERE/build/kvm040.o" "$HERE/build/hat040.o" \
	"$HERE/build/hat_chgprot040.o" "$HERE/build/hat_pagesync040.o" "$HERE/build/hat_exec040.o" "$HERE/build/hat_dup040.o" \
	"$HERE/build/getfault040.o" "$HERE/build/userspace040.o" \
	"$HERE/build/vtop040.o" "$HERE/build/wb040.o" "$HERE/build/ptest040.o" \
	"$HERE/build/uvatosde040.o" "$HERE/build/prumap040.o" "$HERE/build/haltsys040.o" \
	"$HERE/build/segu_lockfix.o" "$HERE/build/segu_ubptbl040.o" \
	"$HERE/build/inituname040.o" \
	"$HERE/build/cputype060.o" "$HERE/build/lmul060.o" \
	"$HERE/build/bp_map040.o" "$HERE/build/runtime040.o" "$HERE/build/krnxmemflt040.o"

echo
echo "[*] overridden symbols (each must be a single strong def):"
for s in pstart sysseginit vatosde vatopte uvatosde hat_pteload hat_unlock hat_unload hat_pageunload hat_pagesync hat_exec hat_alloc hat_free hat_ptfree hat_chgprot hat_dup get_fault userspace vtop usrxmemflt usrxmemflt_orig krnxmemflt krnxmemflt_orig krnxmemflt_stock vtop_orig ptest prumap haltsys rtnfirm segu_get segu_get_lockfix segu_get_orig swapinub swapinub_stock lmul cputype bp_map bp_mapout sched idle resume hardbus hardbus_orig; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done
echo "[*] stray UND refs (should be NONE for our globals):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'kptr040|kroot040|sysseginit|segkmem_mapin|kptbl|syssegs|hardbus_orig' \
	| sed 's/^/      /' || echo "      (none)"

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
echo
m68k-linux-gnu-size "$OUT" | sed 's/^/      /'

# text/data contiguity (loader copies them as one block)
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=strtonum("0x"$5); ts=strtonum("0x"$6)}
	$2==".data" {do_=strtonum("0x"$5)}
	END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
if [ "$1" = "$2" ]; then echo "[OK] text/data contiguous."
else echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"; exit 1; fi

# HARD CHECK (2026-07-09): final .data size MUST be a 4-byte multiple. The loader
# (rel.c bindsections) places .bss at data_addr+data_size with NO alignment, so a
# misaligned .data total shifts the ENTIRE kernel .bss -- CPU tolerates it (68020+)
# but the SDMAC 32-bit DMA engine has no A[1:0] bits: a misaligned DMA buffer (e.g.
# sdpart.c `block`) reads the RDB into the wrong offset -> 'RDSK' scan fails ->
# root mount ENXIO. This is exactly the quiet-on-Amiberry root-mount regression.
DSZ=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print strtonum("0x"$6)}')
if [ $((DSZ % 4)) -ne 0 ]; then
	echo "[FAIL] .data size 0x$(printf %x $DSZ) not a 4-byte multiple -> .bss misaligned at runtime (add .balign 4 to the offending .s)"; exit 1
fi
echo "[OK] .data size 0x$(printf %x $DSZ) is 4-aligned (bss placement safe)."

echo
echo "[*] patching remaining 030 PMMU instructions (pflusha, ptest stubs)"
python3 "$HERE/prototypes/patch_pflusha_040.py" "$OUT" | tail -2
python3 "$HERE/prototypes/patch_pmmu_040.py" "$OUT" | tail -2

echo "[*] Model B (4KB page frame) Tier-0 byte patches"
python3 "$HERE/prototypes/patch_modelb.py" "$OUT" | tail -3

echo "[*] Model B Tier-2 pager/fs page-I/O (dir-read chain) byte patches"
python3 "$HERE/prototypes/patch_modelb_pager.py" "$OUT" | tail -3

echo "[*] Model B writeback/putpage conversion (WRITEBACK-TASK.md; WRITEBACK_GROUPS=spec,pvn,ufs,callers)"
python3 "$HERE/prototypes/patch_writeback.py" "$OUT" | tail -3

echo "[*] 060-B: framesz[4] = 16 (68060 format-4 access-error frame; inert on 030/040)"
python3 "$HERE/prototypes/patch_framesz060.py" "$OUT"

echo
echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py | tail -1 )

echo
echo "[*] stamping build id -> utsname.machine tag (banner + uname -m)"
python3 "$HERE/prototypes/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040"
