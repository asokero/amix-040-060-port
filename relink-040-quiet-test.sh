#!/bin/sh
# relink-040-quiet-test.sh -- DIAGNOSTIC quiet variant (2026-07-09).
#
# unix-040-quiet fails root mount (s5mountroot VOP_OPEN error 6 -> PANIC
# vfs_mountroot errno 89) while unix-040-dbg boots fine on the SAME config.
# The two share the identical base (build/unix-040); the difference is the
# dbg build's ~40 wrapper objects.  This build = the QUIET overlay + ONLY the
# ddopen logger (ddopen_dbg.o, a faithful reimplementation of stock ddopen
# with cmn_err prints), so one boot tells us WHERE the open fails:
#   "DBG ddopen: sdopen FAILED r=%x"            -> SCSI host registration
#   "DBG ddopen: stock sdpartition returned r=%x" -> RDB/partition read (r=6=ENXIO)
#   both OK                                      -> failure is past ddopen
# It also tests whether ddopen itself being overridden is load-bearing.
#
# Output: build/unix-040-quiet-test
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
IN="$HERE/build/unix-040"
ENV="/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$ENV"

[ -f "$IN" ] || { echo "ERROR: $IN missing -- run sh relink-040.sh first"; exit 1; }

# NOTE 2026-07-12: quiet040.s was RETIRED -- its load-bearing overrides (sched,
# schedpaging, idle, resume, hardbus) now live in the BASE link (runtime040.s via
# relink-040.sh) and are inherited through $IN.  Only serdbg + ddopen_dbg layer here.
echo "[*] assembling serdbg.s + ddopen_dbg.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/serdbg.s"     -o "$HERE/build/serdbg.o"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/ddopen_dbg.s" -o "$HERE/build/ddopen_dbg.o"

echo "[*] weaken the overridden symbols (conputc + ddopen)"
cp "$IN" "$HERE/build/unix-040-quiet-test-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol conputc \
	--weaken-symbol ddopen \
	"$HERE/build/unix-040-quiet-test-stage1"

OUT="$HERE/build/unix-040-quiet-test"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-040-quiet-test-stage1" \
	"$HERE/build/serdbg.o" "$HERE/build/ddopen_dbg.o"

echo "[*] overridden defs (each must be a single strong def):"
for s in sched idle resume conputc hardbus hardbus_orig ddopen; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done

echo "[*] UND leaks (should print none):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'swtch|as_fault|hardbus_orig|sdopen|sdpartition|ddstrategy' \
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

echo "[*] stamping build id"
python3 "$HERE/prototypes/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT -- boot: unix_boot040 unix-040-quiet-test (capture serial!)"
