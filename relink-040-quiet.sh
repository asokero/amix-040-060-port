#!/bin/sh
# relink-040-quiet.sh -- QUIET serial-capable twin of the dbg build (2026-07-06).
#
# SLIMMED 2026-07-12: the former quiet040.s load-bearing overrides (sched,
# schedpaging, idle, resume040, hardbus page-crossing fix) were PROMOTED into the
# base link (src/runtime040.s via relink-040.sh) after the Codex
# PROCESS-MMU-CONTEXT-SWITCH-CONTRACT.md packaging finding.  This overlay now layers
# ONLY the serial mirror on top of the already-bootable build/unix-040:
#   serdbg.s = conputc serial mirror (banner / cmn_err / panics -> serial @9600)
# Functionally the build should match unix-040-dbg minus all probes; the serial log
# carries only the real console stream.  Intended for real-HW testing; the MAIN
# debug line stays unix-040-dbg on the emulator.
#
# Input is the ALREADY-patched build/unix-040 (all Model B / PMMU patches baked in),
# so we do NOT re-run the byte patchers here (same contract as relink-040-dbg.sh).
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
. "$(cd "$(dirname "$0")" && pwd)/tools/build-step.sh"
IN="$HERE/build/unix-040"

[ -f "$IN" ] || { echo "ERROR: $IN missing -- run sh relink-040.sh first"; exit 1; }

echo "[*] assembling serdbg.s"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/src/serdbg.s"   -o "$HERE/build/serdbg.o"

echo "[*] weaken the overridden symbol (conputc)"
cp "$IN" "$HERE/build/unix-040-quiet-stage1"
m68k-linux-gnu-objcopy \
	--weaken-symbol conputc \
	"$HERE/build/unix-040-quiet-stage1"

OUT="$HERE/build/unix-040-quiet"
echo "[*] relinking -> $OUT"
m68k-cbm-sysv4-ld -r -o "$OUT" "$HERE/build/unix-040-quiet-stage1" \
	"$HERE/build/serdbg.o"

echo "[*] overridden defs (each must be a single strong def; all but conputc are inherited from \$IN, shown for confirmation only):"
for s in sched idle resume hat_dup conputc hardbus hardbus_orig; do
	m68k-linux-gnu-nm "$OUT" | grep -E " $s\$" | sed "s/^/      $s: /"
done

echo "[*] UND leaks from the overlay (should print none):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'swtch|as_fault|hardbus_orig|curproc|kptr040|coputc|^0* U u$' \
	| sed 's/^/      LEAK: /' || echo "      (none)"

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
echo "[*] B2 page-release hooks: re-verify/re-fix the page_free bsr.l displacement for this link"
run_step 3 python3 "$HERE/src/patch_cb_release.py" "$OUT"

echo
echo "[*] stamping build id -> utsname.machine tag (inherits inituname040 from unix-040)"
python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT -- boot: unix_boot040 $(basename "$OUT")   <- unix_boot040 is MANDATORY"
