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
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/forkdbg.s"      -o "$HERE/build/forkdbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/mainmarks.s"    -o "$HERE/build/mainmarks.o"

echo "[*] VISIBILITY build: blkatoff_dbg + ddopen_dbg DROPPED (no dir-read / device-open spam);"
echo "    idle FREEZES at the first call so the full post-switch sequence stays on screen.  weaken"
echo "    hat_dup/anon_resv/schedpaging/resume/sched/idle; globalize dispq (sched diag reads dispq)."
cp "$IN" "$HERE/build/unix-040-dbg-stage1"
m68k-linux-gnu-objcopy --weaken-symbol hat_dup --weaken-symbol anon_resv --weaken-symbol schedpaging --weaken-symbol resume --weaken-symbol sched --weaken-symbol idle --globalize-symbol dispq "$HERE/build/unix-040-dbg-stage1"

OUT="$HERE/build/unix-040-dbg"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-040-dbg-stage1" \
	"$HERE/build/forkdbg.o" "$HERE/build/mainmarks.o"

echo "[*] overridden defs (single strong def each):"
for s in ddopen hat_dup anon_resv; do
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
