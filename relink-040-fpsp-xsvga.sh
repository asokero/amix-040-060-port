#!/bin/sh
# relink-040-fpsp-xsvga.sh -- EXPERIMENTAL M5: ONE kernel carrying BOTH
#   (a) the Motorola 68040 FPSP + AMIX glue (M1/M2) -- so unimplemented FP
#       instructions (fmovecr/fintrz/transcendentals) are emulated, and
#   (b) the Klaus Burckert Xsvga graphics driver (Piccolo/Picasso II Zorro-II).
#
# Rationale: the Xsvga X SERVER crashed on an F-line transcendental (0xf200) --
# exactly the FPSP gap. With M2 proven (fmovecr/fintrz emulated, native cc works
# again) the graphical Piccolo goal should now be reachable.
#
# NOT the standard kernel. Requires the PC-relative-relocation loader fix
# (unix_boot rel.c, commit f0ed373) -- the FPSP body carries 330 PC-rel records.
#
# Usage: sh relink-040-fpsp-xsvga.sh [base-kernel]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"

IN="${1:-$HERE/build/unix-040-dbg.STD-backup}"
[ -f "$IN" ] || IN="$HERE/build/unix-040-dbg"
OUT="$HERE/build/unix-040-fpsp-xsvga-dbg"
FPWORK="$HERE/build/fpsp-work/usr/src/sys/arch/m68k/fpsp"
EXP="${EXP:-/tmp/claude-12044/-home-asokero-kehitys-amix-playground-kernelsupport/durable-tftp-payloads/xsvga/svga/exp}"

[ -f "$IN" ]  || { echo "ERROR: base kernel missing: $IN"; exit 1; }
[ -f "$EXP" ] || { echo "ERROR: xsvga exp driver missing: $EXP"; exit 1; }
echo "[*] base: $(basename "$IN")  (must be a STANDARD dbg kernel)"
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpsp_vec11$" && { echo "[FAIL] base already has FPSP linked -- use the standard kernel"; exit 1; }

echo "[*] M1: FPSP package body"
sh "$HERE/build-fpsp040.sh" >/dev/null
echo "[*] M2: assemble the AMIX FPSP glue"
m68k-linux-gnu-gcc -x assembler-with-cpp -m68040 -I"$FPWORK" \
	-c "$HERE/prototypes/fpsp_glue040.s" -o "$HERE/build/fpsp_glue040.o"
cp "$EXP" "$HERE/build/xsvga_exp.o"

echo "[*] ld -r: base + fpsp040.o + fpsp_glue040.o + xsvga_exp.o"
m68k-cbm-sysv4-ld -r -o "$OUT" "$IN" \
	"$HERE/build/fpsp040.o" "$HERE/build/fpsp_glue040.o" "$HERE/build/xsvga_exp.o"

echo "[*] symbols from both features must be defined:"
for s in fpsp_vec11 fpsp_done fpsp_fline fpsp_unimp svgaopen svgammap Piccolo_SwitchToSVGA; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " [Tt] $s\$" || { echo "[FAIL] $s missing"; exit 1; }
done
echo "      fpsp_vec11/done/fline/unimp + svgaopen/svgammap/Piccolo_SwitchToSVGA OK"
LEAK=$(m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'fpsp_|mem_read|mem_write|real_|svga' || true)
[ -z "$LEAK" ] && echo "      no unresolved FPSP/svga symbols" || { echo "[FAIL] unresolved:"; echo "$LEAK"; exit 1; }

echo "[*] patch 1/2: M68Kvec[11] -> fpsp_vec11"
python3 "$HERE/prototypes/patch_fpsp_vec11.py" "$OUT" | tail -2
echo "[*] M4: FP arithmetic vectors 48/51/52/53/54/55 -> FPSP"
python3 "$HERE/prototypes/patch_fpsp_vectors.py" "$OUT" | tail -8
echo "[*] patch 2/2: cdevsw[67] -> svga* + svgammap Model-B geometry"
python3 "$HERE/prototypes/patch_xsvga.py" "$OUT" | tail -3

echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py "$OUT" 2>/dev/null | tail -1 ) || true
DSZ=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print strtonum("0x"$6)}')
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data 4-aligned" || { echo "[FAIL] .data misaligned"; exit 1; }
echo "[*] PC-relative relocs present (loader MUST have the f0ed373 fix):"
m68k-linux-gnu-readelf -rW "$OUT" 2>/dev/null | awk '$3 ~ /^R_68K_PC/{n++} END{print "      "n" PC-relative records"}'

python3 "$HERE/prototypes/stamp_buildid.py" "$OUT" || true
echo "[OK] built $OUT"
