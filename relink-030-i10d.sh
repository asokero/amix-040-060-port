#!/bin/sh
# relink-030-i10d.sh -- the 68030 half of the CPU-independent brk ring tracer (i10d).
#
# The 040/060 tracer lives in src/i10rev040.s (PART ELEVEN) and rides that build.  The
# stock 030 kernel has none of that infrastructure, so this overlays the standalone,
# generic-68k src/i10dtrace030.s onto the SAME base kernel the 040 build starts from
# ($AMIX_ROOT/stand/unix, run 030-native and UNPATCHED), by exactly the mechanism
# relink-030-dbg.sh uses: weaken the sysent brk, add a brk_orig alias at its stock
# address, and `ld -r` the overlay in.  brk has a single sysent reference in this ET_REL
# image, so the weaken re-binds 100% of brk syscalls -- the same guarantee the 040 build
# asserts.  The result runs on a 68030 and publishes the SAME I1D! block layout as the
# 040 build, so test-tools/i10d.sh reads both and the granted break can be compared for
# the identical sh sbrk sequence.
#
# Run with the same env the 040 relink needs:  AMIX_ALLOW_UNKNOWN_STOCK=1 sh relink-030-i10d.sh
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
IN="${STOCK:-$AMIX_ROOT/stand/unix}"
. "$(cd "$(dirname "$0")" && pwd)/tools/verify-stock.sh"
verify_stock "$IN"
[ -f "$IN" ] || { echo "ERROR: stock kernel $IN missing"; exit 1; }
mkdir -p "$HERE/build"

echo "[*] assembling the standalone 030 brk ring tracer (generic 68k, -m68040 driver)"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/i10dtrace030.s" -o "$HERE/build/i10dtrace030.o"

echo "[*] weaken sysent brk; add brk_orig alias at the stock 0x580e8"
cp "$IN" "$HERE/build/unix-030-i10d-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol brk \
	--add-symbol brk_orig=.text:0x580e8,function,global \
	"$HERE/build/unix-030-i10d-stage1"

OUT="$HERE/build/unix-030-i10d"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-030-i10d-stage1" \
	"$HERE/build/i10dtrace030.o"

# text/data contiguity (loader copies them as one block) -- same check as the other relinks
CONTIG=$(m68k-linux-gnu-readelf -SW "$OUT" 2>/dev/null | awk '
	{gsub(/[][]/,"")}
	$2==".text" {to=$5; ts=$6}
	$2==".data" {do_=$5}
	END{print to, ts, do_}')
set -- $CONTIG
set -- $(( 0x$1 + 0x$2 )) $(( 0x$3 ))
if [ "$1" = "$2" ]; then echo "[OK] text/data contiguous."
else echo "[FAIL] text/data NOT contiguous: text_end=0x$(printf %x $1) data_off=0x$(printf %x $2)"; exit 1; fi

# HARD CHECK: the tracer must have TAKEN the brk symbol (moved off 0x580e8) and brk_orig
# must still point at the stock body.  Same shape as the 040 grow-probe check.
BKADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="brk" && $2=="T" {print $1}')
BKOADDR=$(m68k-linux-gnu-nm "$OUT" | awk '$3=="brk_orig" && $2=="T" {print $1}')
if [ -z "$BKADDR" ] || [ "$BKADDR" = "000580e8" ]; then
	echo "[FAIL] strong brk is missing or still the stock body 0x580e8 -> the 030 tracer did not take the symbol (nm: '$BKADDR')"; exit 1
fi
if [ -z "$BKOADDR" ] || [ "$BKOADDR" != "000580e8" ]; then
	echo "[FAIL] brk_orig missing or not at 0x580e8 (nm: '$BKOADDR')"; exit 1
fi
if m68k-linux-gnu-nm "$OUT" | grep -E ' U brk_orig$' >/dev/null 2>&1; then
	echo "[FAIL] brk_orig still UND -> the 030 tracer jmp would go to address 0"; exit 1
fi
echo "[OK] 030 grow-tracer edge bound: brk (i10dtrace030 @0x$BKADDR) -> brk_orig @0x$BKOADDR."
echo "[*] I1D! block on the 030 image:"
m68k-linux-gnu-nm "$OUT" | grep -wE 'i10d_magic|i10d_ring|i10d_on' | sed 's/^/      /'
echo
echo "[OK] built $OUT -- boot it with the STOCK 030 loader on a 68030; read the ring with"
echo "     test-tools/i10d.sh (refresh the addresses from tools/status-facts.sh $OUT)."
