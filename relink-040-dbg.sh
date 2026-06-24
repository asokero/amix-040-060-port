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

echo "[*] assembling ddopen_dbg.s + forkdbg.s + blkatoff_dbg.s (stock sdpartition retained)"
echo "    NOTE: swapconf override DROPPED 2026-06-22 -- the dir-read/namei path now works"
echo "    (gen_strategy PFN<<11->12 fix), so the REAL swapconf runs and configures swap"
echo "    (populates swapinfo) -- this clears the swap_xlate+0x26 NULL-swapinfo bus error."
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/ddopen_dbg.s"   -o "$HERE/build/ddopen_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/forkdbg.s"      -o "$HERE/build/forkdbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/blkatoff_dbg.s" -o "$HERE/build/blkatoff_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/mainmarks.s"    -o "$HERE/build/mainmarks.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/serdbg.s"       -o "$HERE/build/serdbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/getfault040.s"  -o "$HERE/build/getfault040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/assegat_dbg.s"  -o "$HERE/build/assegat_dbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/userspace040.s" -o "$HERE/build/userspace040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/vtop040.s"      -o "$HERE/build/vtop040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/execmark.s"     -o "$HERE/build/execmark.o"

echo "[*] weaken ddopen + hat_dup + schedpaging + idle + resume + sched + CONPUTC (serial hook); globalize+weaken blkatoff"
echo "    (anon_resv stub DROPPED 2026-06-23 -- swapconf configures swap now, real anon_resv balances)"
echo "    as_segat WRAPPED (--add-symbol as_segat_orig=0xadefc + --weaken as_segat) to trace the interp fault"
cp "$IN" "$HERE/build/unix-040-dbg-stage1"
m68k-linux-gnu-objcopy --weaken-symbol ddopen --weaken-symbol hat_dup --weaken-symbol schedpaging --weaken-symbol idle --weaken-symbol resume --weaken-symbol sched --weaken-symbol get_fault --weaken-symbol conputc --globalize-symbol blkatoff --weaken-symbol blkatoff --add-symbol as_segat_orig=.text:0xadefc,function,global --weaken-symbol as_segat --add-symbol execmap_orig=.text:0x57a4c,function,global --weaken-symbol execmap --add-symbol copyout_orig=.text:0x576,function,global --weaken-symbol copyout --add-symbol as_map_orig=.text:0xae4f8,function,global --weaken-symbol as_map --weaken-symbol userspace --add-symbol vtop_orig=.text:0xb7568,function,global --weaken-symbol vtop --add-symbol exece_orig=.text:0x56444,function,global --weaken-symbol exece --add-symbol gexec_orig=.text:0x576c0,function,global --weaken-symbol gexec --add-symbol elfexec_orig=.text:0xb80f2,function,global --weaken-symbol elfexec --add-symbol relvm_orig=.text:0x419b4,function,global --weaken-symbol relvm --add-symbol setregs_orig=.text:0x58b62,function,global --weaken-symbol setregs --add-symbol lookuppn_orig=.text:0x5c2ea,function,global --weaken-symbol lookuppn --add-symbol bread_orig=.text:0x3c154,function,global --weaken-symbol bread --add-symbol biodone_orig=.text:0x3ce3a,function,global --weaken-symbol biodone --add-symbol pn_getcomponent_orig=.text:0x5c952,function,global --weaken-symbol pn_getcomponent --add-symbol dnlc_lookup_orig=.text:0x5b89a,function,global --weaken-symbol dnlc_lookup --add-symbol dirlook_orig=.text:0x6dbe0,function,global --weaken-symbol dirlook --add-symbol iget_orig=.text:0x6f724,function,global --weaken-symbol iget --add-symbol copyinstr_orig=.text:0x43ef4,function,global --weaken-symbol copyinstr "$HERE/build/unix-040-dbg-stage1"

OUT="$HERE/build/unix-040-dbg"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-040-dbg-stage1" \
	"$HERE/build/ddopen_dbg.o" "$HERE/build/forkdbg.o" \
	"$HERE/build/blkatoff_dbg.o" "$HERE/build/mainmarks.o" "$HERE/build/serdbg.o" \
	"$HERE/build/getfault040.o" "$HERE/build/assegat_dbg.o" \
	"$HERE/build/userspace040.o" "$HERE/build/vtop040.o" \
	"$HERE/build/execmark.o"

echo "[*] overridden defs (single strong def each):"
for s in ddopen hat_dup; do
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

echo "[*] new UND refs introduced by ddopen_dbg (should be NONE -- all bound):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'sdopen|sdpartition|ddstrategy|cmn_err' \
	| sed 's/^/      LEAK: /' || true
echo "      (a LEAK line above = an unbound ref; none = good)"

echo "[*] sched is now a --weaken-symbol OVERRIDE (no detour patch -- detour-jmp entry"
echo "    into relinked code Line-F-crashes on this 040; jsr-override entry works)."

echo
echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040-dbg"
