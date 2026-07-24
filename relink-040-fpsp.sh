#!/bin/sh
# relink-040-fpsp.sh -- EXPERIMENTAL: build an 040 kernel with the Motorola FPSP
# (M1 package body build/fpsp040.o) + AMIX glue (M2 fpsp_glue040.s) linked in and
# vector 11 retargeted to it.  NOT the standard kernel (separate test build).
#
# Goal (M2 milestone): a previously-crashing unimplemented FP instruction
# (fmovecr / fintrz / transcendental) is emulated instead of SIGSYS.
#
# Layers on build/unix-040-dbg.  Spec: analyysirepo vm-map/FPSP-INTEGRATION-PLAN.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"

# Base must be a STANDARD dbg kernel.  Prefer the STD-backup: the live
# build/unix-040-dbg boot slot is frequently swapped to an FPSP/Xsvga kernel,
# and linking the package on top of a base that already has it yields
# "multiple definition of fpsp_*".
IN="${1:-$HERE/build/unix-040-dbg.STD-backup}"
[ -f "$IN" ] || IN="$HERE/build/unix-040-dbg"
OUT="$HERE/build/unix-040-fpsp-dbg"
FPWORK="$HERE/build/fpsp-work/usr/src/sys/arch/m68k/fpsp"   # fpsp.defs lives here

[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpsp_vec11$" && { echo "[FAIL] base already has FPSP linked -- pass a STANDARD dbg kernel as \$1"; exit 1; }

echo "[*] M1: (re)build the FPSP package body build/fpsp040.o"
sh "$HERE/build-fpsp040.sh" >/dev/null
[ -f "$HERE/build/fpsp040.o" ] || { echo "ERROR: fpsp040.o not built"; exit 1; }
[ -f "$FPWORK/fpsp.defs" ] || { echo "ERROR: fpsp.defs missing at $FPWORK"; exit 1; }

echo "[*] M2: assemble AMIX glue prototypes/fpsp_glue040.s (-I $FPWORK for fpsp.defs)"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68040 -I"$FPWORK" \
	-c "$HERE/prototypes/fpsp_glue040.s" -o "$HERE/build/fpsp_glue040.o"

echo "[*] ld -r: $(basename "$IN") + fpsp040.o + fpsp_glue040.o -> $(basename "$OUT")"
m68k-cbm-sysv4-ld -r -o "$OUT" "$IN" "$HERE/build/fpsp040.o" "$HERE/build/fpsp_glue040.o"

echo "[*] checking all FPSP symbols resolved (no lingering U from the package):"
LEAK=$(m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'fpsp_|mem_read|mem_write|real_' || true)
[ -z "$LEAK" ] && echo "      (none -- glue satisfies the package)" || { echo "[FAIL] unresolved:"; echo "$LEAK"; exit 1; }
for s in fpsp_vec11 fpsp_done mem_read mem_write fpsp_fline fpsp_unimp; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " [Tt] $s\$" || { echo "[FAIL] $s not defined"; exit 1; }
done
echo "      fpsp_vec11 / fpsp_done / mem_read / mem_write / fpsp_fline / fpsp_unimp defined"

echo "[*] retarget M68Kvec[11] -> fpsp_vec11"
python3 "$HERE/prototypes/patch_fpsp_vec11.py" "$OUT" | tail -2
echo "[*] M4: FP arithmetic vectors 48/51/52/53/54/55 -> FPSP"
python3 "$HERE/prototypes/patch_fpsp_vectors.py" "$OUT" | tail -8

echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py "$OUT" 2>/dev/null | tail -1 ) || true

echo "[*] .data 4-byte alignment (bss placement safety):"
DSZ=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print strtonum("0x"$6)}')
[ $((DSZ % 4)) -eq 0 ] && echo "      .data 0x$(printf %x $DSZ) 4-aligned" || { echo "[FAIL] .data not 4-aligned"; exit 1; }

echo "[*] stamping build id:"
python3 "$HERE/prototypes/stamp_buildid.py" "$OUT" || true

echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040-fpsp-dbg"
