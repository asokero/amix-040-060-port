#!/bin/sh
# relink-040-quiet.sh -- QUIET serial-capable twin of the dbg build (2026-07-06).
#
# Layers ONLY the load-bearing overrides on top of the fully-patched build/unix-040:
#   quiet040.s  = sched loop + schedpaging skip + idle + resume040 + hat_dup stub +
#                 hardbus page-crossing fix  (the dbg overlay's genuine parts, NO output)
#   serdbg.s    = conputc serial mirror (banner / cmn_err / panics -> serial @9600)
# All pure diagnostics (ddopen_dbg blkatoff_dbg assegat_dbg execmark hatalloc_dbg
# ktrap_latch kmem_validate segvn_softunlock_dbg preempt_dbg segu_swap_dbg + the
# sigkill_dbg probes) are OMITTED.  Functionally the build should match unix-040-dbg;
# the serial log carries only the real console stream.  Intended for real-HW testing;
# the MAIN debug line stays unix-040-dbg on the emulator.
#
# Input is the ALREADY-patched build/unix-040 (all Model B / PMMU patches baked in),
# so we do NOT re-run the byte patchers here (same contract as relink-040-dbg.sh).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
IN="$HERE/build/unix-040"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"

[ -f "$IN" ] || { echo "ERROR: $IN missing -- run sh relink-040.sh first"; exit 1; }

echo "[*] assembling quiet040.s + serdbg.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/quiet040.s" -o "$HERE/build/quiet040.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/serdbg.s"   -o "$HERE/build/serdbg.o"

echo "[*] weaken the overridden symbols (sched schedpaging idle resume hat_dup hardbus conputc)"
cp "$IN" "$HERE/build/unix-040-quiet-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol sched \
	--weaken-symbol schedpaging \
	--weaken-symbol idle \
	--weaken-symbol resume \
	--weaken-symbol hat_dup \
	--weaken-symbol conputc \
	--weaken-symbol hardbus \
	--add-symbol hardbus_orig=.text:0x5b3c2,function,global \
	"$HERE/build/unix-040-quiet-stage1"

OUT="$HERE/build/unix-040-quiet"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-040-quiet-stage1" \
	"$HERE/build/quiet040.o" "$HERE/build/serdbg.o"

echo "[*] overridden defs (each must be a single strong def):"
for s in sched schedpaging idle resume hat_dup conputc hardbus hardbus_orig; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done

echo "[*] UND leaks from the overlay (should print none):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'swtch|as_fault|hardbus_orig|curproc|kptr040|coputc|^0* U u$' \
	| sed 's/^/      LEAK: /' || echo "      (none)"

# text/data contiguity (loader copies them as one block)
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=strtonum("0x"$5); ts=strtonum("0x"$6)}
	$2==".data" {do_=strtonum("0x"$5)}
	END{printf("%d %d", to+ts, do_)}')
set -- $CONTIG
if [ "$1" = "$2" ]; then echo "[OK] text/data contiguous."
else echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"; exit 1; fi

echo
echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040-quiet"
