#!/bin/sh
# relink-040-dbg.sh -- layer the instrumented ddopen (prototypes/ddopen_dbg.s) on top
# of the fully-patched build/unix-040, producing build/unix-040-dbg.
#
# Purpose: localize "s5mountroot VOP_OPEN error 6".  The debug ddopen prints (CE_WARN)
# which sub-call fails:
#   "DBG ddopen: sdopen FAILED ..."       -> SCSI host registration (queue[ctrl]==0)
#   "DBG ddopen: sdpartition FAILED ..."  -> getrdb RDB disk read / 040 DMA
#   "DBG ddopen: both sub-calls OK"       -> open succeeded (failure is elsewhere)
#
# ddopen is GLOBAL T -> --weaken-symbol so our strong def wins and bdevsw re-resolves.
# Input is the ALREADY-patched build/unix-040 (all Model B / PMMU patches baked in), so
# we do NOT re-run the byte patchers here.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
IN="$HERE/build/unix-040"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"

[ -f "$IN" ] || { echo "ERROR: $IN missing -- run sh relink-040.sh first"; exit 1; }

echo "[*] assembling ddopen_dbg.s + blkatoff_dbg.s (stock sdpartition retained)"
echo "    NOTE: swapconf override DROPPED 2026-06-22 -- the dir-read/namei path now works"
echo "    (gen_strategy PFN<<11->12 fix), so the REAL swapconf runs and configures swap"
echo "    (populates swapinfo) -- this clears the swap_xlate+0x26 NULL-swapinfo bus error."
echo "    NOTE: forkdbg.s (hat_dup stub) DROPPED 2026-07-07 -- the real hat_dup040 port now"
echo "    lives in the BASE build (relink-040.sh), same as hat_chgprot040 -- it is a genuine"
echo "    fix, not a diagnostic.  hat_dup is already a finalized strong override in \$IN;"
echo "    this script does NOT re-weaken or re-link it."
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/ddopen_dbg.s"   -o "$HERE/build/ddopen_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/blkatoff_dbg.s" -o "$HERE/build/blkatoff_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/mainmarks.s"    -o "$HERE/build/mainmarks.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/serdbg.s"       -o "$HERE/build/serdbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/assegat_dbg.s"  -o "$HERE/build/assegat_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/execmark.s"     -o "$HERE/build/execmark.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/hatalloc_dbg.s" -o "$HERE/build/hatalloc_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/sigkill_dbg.s"  -o "$HERE/build/sigkill_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/ktrap_latch.s"  -o "$HERE/build/ktrap_latch.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/kmem_validate.s" -o "$HERE/build/kmem_validate.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/segvn_softunlock_dbg.s" -o "$HERE/build/segvn_softunlock_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/preempt_dbg.s" -o "$HERE/build/preempt_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/segu_swap_dbg.s" -o "$HERE/build/segu_swap_dbg.o"
# setuctxt_dbg = ISSUE-7 "Codex timing hypothesis #1" probe (2026-07-07): does u_procp
# survive setuctxt's OWN internal kmem_alloc(KM_SLEEP) loop?  Landed after the hat_unload
# cpusha fix (KNOWN-ISSUES.md #8) was boot-tested and did NOT clear ISSUE-7.
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/setuctxt_dbg.s" -o "$HERE/build/setuctxt_dbg.o"
# NOTE: getfault040 / userspace040 / vtop040 / wb040 are GENUINE 040 runtime fixes and now
# live in the BASE build (relink-040.sh); they are inherited via $IN (build/unix-040).  Only
# diagnostics (markers / wrappers) are layered here.

echo "[*] weaken ddopen + idle + resume + sched + CONPUTC (serial hook); globalize+weaken blkatoff"
echo "    (schedpaging weaken RETIRED 2026-07-15: stock tuning + pageout daemon must run)"
echo "    (anon_resv stub DROPPED 2026-06-23 -- swapconf configures swap now, real anon_resv balances)"
echo "    as_segat WRAPPED (--add-symbol as_segat_orig=0xadefc + --weaken as_segat) to trace the interp fault"
echo "    NOTE 2026-07-12: sched/schedpaging/idle/resume/hardbus now have base defs in"
echo "    runtime040.s (relink-040.sh); the weakens below demote THOSE so the instrumented"
echo "    mainmarks/sigkill_dbg twins win.  hardbus_orig is INHERITED from the base image"
echo "    (no --add-symbol here -- a second copy would duplicate the symbol)."
cp "$IN" "$HERE/build/unix-040-dbg-stage1"
# hat_pageunload lives in our APPENDED 040 region (hat040.s); its address SHIFTS whenever
# hat040.s changes size.  Derive hat_pageunload_orig from $IN at build time so the dbg
# wrapper's _orig call always lands on the real fn -- a stale hardcode jumps into the
# middle of hat_unlock and faults (KERNEL FAULT pc=0xD7Bxx, fmt=7 Bus Error).
HPU_ORIG=$(m68k-linux-gnu-nm "$IN" | awk '$3=="hat_pageunload"{print "0x"$1}')
echo "    hat_pageunload_orig resolved to $HPU_ORIG (from $IN)"
# swapinub in $IN is now the segu_ubptbl040 p_ubptbl-rebuild wrapper (base build),
# itself calling swapinub_stock (stock 0xa9e5c).  The dbg probe (segu_swap_dbg.o)
# must chain THROUGH it, not around it, so swapinub_orig resolves to the wrapper's
# appended-region address at build time (HPU_ORIG-style; it shifts with .o sizes).
# Chain: segu_swap_dbg probe -> segu_ubptbl040 wrapper -> stock.
SIU_ORIG=$(m68k-linux-gnu-nm "$IN" | awk '$3=="swapinub"{print "0x"$1}')
echo "    swapinub_orig resolved to $SIU_ORIG (segu_ubptbl040 wrapper in $IN)"
# hat_exec in the base ($IN) is now the hat_exec040 NO-OP (ISSUE-10 chain-II fix), NOT the
# stock 0xb6f20 body.  Point the hatalloc_dbg hat_exec probe's hat_exec_orig at the base
# no-op (HPU_ORIG-style, shifts with .o sizes) so the dbg build LOGS exec then calls the
# no-op -- i.e. dbg carries the fix, not the stock stack-move.  (Was hardcoded 0xb6f20.)
HEXEC_ORIG=$(m68k-linux-gnu-nm "$IN" | awk '$3=="hat_exec"{print "0x"$1}')
echo "    hat_exec_orig resolved to $HEXEC_ORIG (hat_exec040 no-op in $IN)"
# hat_pteload lives in hat040.s (appended region, shifts with .o sizes) -- derive its
# _orig for the hatalloc_dbg PTLFILE0 producer-hunt wrapper (2026-07-17).
HPTL_ORIG=$(m68k-linux-gnu-nm "$IN" | awk '$3=="hat_pteload"{print "0x"$1}')
echo "    hat_pteload_orig resolved to $HPTL_ORIG (hat040.s native in $IN)"
m68k-linux-gnu-objcopy --weaken-symbol ddopen --weaken-symbol idle --weaken-symbol resume --weaken-symbol sched --weaken-symbol conputc --globalize-symbol blkatoff --weaken-symbol blkatoff --add-symbol as_segat_orig=.text:0xadefc,function,global --weaken-symbol as_segat --add-symbol execmap_orig=.text:0x57a4c,function,global --weaken-symbol execmap --add-symbol copyout_orig=.text:0x576,function,global --weaken-symbol copyout --add-symbol as_map_orig=.text:0xae4f8,function,global --weaken-symbol as_map --add-symbol exece_orig=.text:0x56444,function,global --weaken-symbol exece --add-symbol gexec_orig=.text:0x576c0,function,global --weaken-symbol gexec --add-symbol elfexec_orig=.text:0xb80f2,function,global --weaken-symbol elfexec --add-symbol relvm_orig=.text:0x419b4,function,global --weaken-symbol relvm --add-symbol setregs_orig=.text:0x58b62,function,global --weaken-symbol setregs --add-symbol lookuppn_orig=.text:0x5c2ea,function,global --weaken-symbol lookuppn --add-symbol bread_orig=.text:0x3c154,function,global --weaken-symbol bread --add-symbol biodone_orig=.text:0x3ce3a,function,global --weaken-symbol biodone --add-symbol pn_getcomponent_orig=.text:0x5c952,function,global --weaken-symbol pn_getcomponent --add-symbol dnlc_lookup_orig=.text:0x5b89a,function,global --weaken-symbol dnlc_lookup --add-symbol dirlook_orig=.text:0x6dbe0,function,global --weaken-symbol dirlook --add-symbol iget_orig=.text:0x6f724,function,global --weaken-symbol iget --add-symbol copyinstr_orig=.text:0x43ef4,function,global --weaken-symbol copyinstr --add-symbol u_trap_orig=.text:0x5a47e,function,global --weaken-symbol u_trap --add-symbol exhd_getmap_orig=.text:0x5704e,function,global --weaken-symbol exhd_getmap --add-symbol rexit_orig=.text:0x3f2c2,function,global --weaken-symbol rexit --add-symbol as_fault_orig=.text:0xae108,function,global --weaken-symbol as_fault --add-symbol hat_sdtalloc_orig=.text:0xb632e,function,global --weaken-symbol hat_sdtalloc --add-symbol hat_ptalloc_orig=.text:0xb688e,function,global --weaken-symbol hat_ptalloc --add-symbol page_get_orig=.text:0xaffa4,function,global --weaken-symbol page_get --add-symbol page_free_orig=.text:0xaf9ea,function,global --weaken-symbol page_free --add-symbol hat_pageunload_orig=.text:${HPU_ORIG},function,global --weaken-symbol hat_pageunload --add-symbol hat_memload_orig=.text:0xb4cb0,function,global --weaken-symbol hat_memload --add-symbol page_abort_orig=.text:0xaf8d6,function,global --weaken-symbol page_abort --add-symbol anon_decref_orig=.text:0xad798,function,global --weaken-symbol anon_decref --add-symbol hat_exec_orig=.text:${HEXEC_ORIG},function,global --weaken-symbol hat_exec --add-symbol hat_pteload_orig=.text:${HPTL_ORIG},function,global --weaken-symbol hat_pteload --add-symbol page_hashin_orig=.text:0xb02ac,function,global --weaken-symbol page_hashin --add-symbol grow_orig=.text:0x5820e,function,global --weaken-symbol grow --globalize-symbol segvn_unmap --add-symbol segvn_unmap_orig=.text:0xab63c,function,global --weaken-symbol segvn_unmap --add-symbol sigtoproc_orig=.text:0x4750e,function,global --weaken-symbol sigtoproc --add-symbol getdents_orig=.text:0x5e520,function,global --weaken-symbol getdents --weaken-symbol hardbus --add-symbol k_trap_orig=.text:0x0005a0e8,function,global --weaken-symbol k_trap --globalize-symbol Km_FreeLists --add-symbol kmem_alloc_orig=.text:0x00041fa8,function,global --weaken-symbol kmem_alloc --add-symbol preempt_orig=.text:0x000b9008,function,global --weaken-symbol preempt --add-symbol swapinub_orig=.text:${SIU_ORIG},function,global --weaken-symbol swapinub --add-symbol swapoutub_orig=.text:0x000a9f84,function,global --weaken-symbol swapoutub --globalize-symbol segu_softunload --add-symbol segu_softunload_orig=.text:0x000aa870,function,global --weaken-symbol segu_softunload --globalize-symbol segvn_softunlock --add-symbol segvn_softunlock_orig=.text:0x000abd00,function,global --weaken-symbol segvn_softunlock --globalize-symbol setuctxt --add-symbol setuctxt_orig=.text:0x00041918,function,global --weaken-symbol setuctxt "$HERE/build/unix-040-dbg-stage1"

OUT="$HERE/build/unix-040-dbg"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-040-dbg-stage1" \
	"$HERE/build/ddopen_dbg.o" \
	"$HERE/build/blkatoff_dbg.o" "$HERE/build/mainmarks.o" "$HERE/build/serdbg.o" \
	"$HERE/build/assegat_dbg.o" "$HERE/build/execmark.o" "$HERE/build/hatalloc_dbg.o" \
	"$HERE/build/sigkill_dbg.o" "$HERE/build/ktrap_latch.o" "$HERE/build/kmem_validate.o" \
	"$HERE/build/segvn_softunlock_dbg.o" "$HERE/build/preempt_dbg.o" "$HERE/build/segu_swap_dbg.o" \
	"$HERE/build/setuctxt_dbg.o"

echo "[*] overridden defs (single strong def each; hat_dup is inherited from \$IN, shown for confirmation only):"
for s in ddopen hat_dup k_trap kmem_alloc segvn_softunlock preempt setuctxt swapinub swapinub_orig swapinub_stock segu_get; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done

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

echo "[*] new UND refs introduced by ddopen_dbg (should be NONE -- all bound):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'sdopen|sdpartition|ddstrategy|cmn_err' \
	| sed 's/^/      LEAK: /' || true
echo "      (a LEAK line above = an unbound ref; none = good)"

echo "[*] sched is now a --weaken-symbol OVERRIDE (no detour patch -- detour-jmp entry"
echo "    into relinked code Line-F-crashes on this 040; jsr-override entry works)."

echo
echo "[*] enabling early-boot serial phase trace (btrace_on=1; base/quiet stay silent)"
python3 "$HERE/prototypes/patch_btrace_on.py" "$OUT"

echo
echo "[*] stamping build id -> utsname.machine tag (inherits inituname040 from unix-040)"
python3 "$HERE/prototypes/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040-dbg"
