#!/bin/sh
# relink-040-rtg.sh -- ONE graphics kernel carrying BOTH RTG drivers (2026-07-26):
#   * Xsvga        Klaus Burckert, Piccolo / Picasso II Zorro-II -- binary `exp` object,
#                  registered on cdevsw[67] by relocation retarget (patch_xsvga.py)
#   * MNT VA2000   our own driver, cross-compiled from ~/kehitys/va2000-amix/src/va2000.c,
#                  registered on cdevsw[68] (patch_va2000_cdevsw.py)
#
# WHY ONE KERNEL
# The two integrations do not collide, which was checked rather than assumed:
#   - majors 67 vs 68, no clash;
#   - Xsvga weakens NOTHING (pure .rela.data retarget), VA2000 weakens only `parinit`
#     (wrapper -> va2000init() -> tail-jmp parinit_orig).  Independent mechanisms.
# So the hardware session can bring TWO artifacts (base+dbg and this) instead of four,
# and this one works with whichever board is physically in the machine.  Collapsing the
# variant matrix is the point: separate per-driver kernels with their own default bases
# are what produced the 2026-07-25 near-miss (graphics kernels silently built from a
# base that contained none of that day's VM fixes).
#
# The single-driver scripts stay available for bisecting a driver-specific failure --
# same reasoning as FPSP=0 in relink-040.sh:
#   sh relink-040-xsvga.sh    /  sh relink-040-va2000.sh
#
# FPSP comes from the BASE link (relink-040.sh) since 2026-07-26; this script requires
# it and does not add it.  The loader MUST be build/unix_boot040 (rel.c PC-rel reloc fix
# f0ed373) -- the FPSP body carries ~330 PC-relative records.
#
# NOT the standard kernel.  Usage: sh relink-040-rtg.sh [base-kernel] [output]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"
. "$HERE/prototypes/xsvga-provenance.sh"

IN="${1:-$HERE/build/unix-040-dbg}"
OUT="${2:-$HERE/build/unix-040-rtg-dbg}"

# parinit's address is baked into the objcopy --add-symbol below, so it is asserted, not
# assumed.  FPSP is appended AFTER the base .text, so base symbols do not move -- but
# that is exactly the kind of claim that has to be checked every build.
PARINIT_ADDR=0xfe6c

[ -f "$IN" ] || { echo "ERROR: base kernel missing: $IN"; exit 1; }
echo "[*] base: $(basename "$IN")"

m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpsp_vec11$" || {
	echo "[FAIL] base does NOT carry FPSP -- since 2026-07-26 FPSP is part of"
	echo "       relink-040.sh.  Rebuild the base: sh relink-040.sh"
	exit 1
}
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] va2000init$" && { echo "[FAIL] base already has va2000 linked -- pass a plain base"; exit 1; }
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] svgaopen$"   && { echo "[FAIL] base already has xsvga linked -- pass a plain base"; exit 1; }
echo "      FPSP present, no driver already linked"

echo "[*] Xsvga driver object provenance:"
xsvga_check_exp || exit 1

PARINIT_LINE=$(m68k-linux-gnu-nm "$IN" | grep -E " T parinit$") || { echo "ERROR: parinit not found in $IN"; exit 1; }
PARINIT_CUR=$(echo "$PARINIT_LINE" | awk '{print $1}')
PARINIT_EXPECT=$(printf '%08x' $PARINIT_ADDR)
[ "$PARINIT_CUR" = "$PARINIT_EXPECT" ] || {
	echo "ERROR: parinit @0x$PARINIT_CUR != expected 0x$PARINIT_EXPECT"
	echo "       The base layout drifted -- re-verify the address before building."
	exit 1
}
echo "      parinit @0x$PARINIT_CUR OK (matches expected 0x$PARINIT_EXPECT)"

# ---------------------------------------------------------------------------
# Driver objects
# ---------------------------------------------------------------------------
echo "[*] Xsvga: stage the binary driver object"
cp "$XSVGA_EXP" "$HERE/build/xsvga_exp.o"

echo "[*] VA2000: Model-B source copy (>>11 -> >>12, exactly one site)"
python3 "$HERE/prototypes/va2000_modelb.py"

echo "[*] VA2000: cross-compile build/va2000_040.c"
VA2000_CFLAGS=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
m68k-cbm-sysv4-gcc $VA2000_CFLAGS -I"$HERE/build" \
	-c "$HERE/build/va2000_040.c" -o "$HERE/build/va2000_040.o"

echo "[*] VA2000: assemble the parinit wrapper"
m68k-cbm-sysv4-gcc -m68040 -c "$HERE/prototypes/parinit_va2000.s" -o "$HERE/build/parinit_va2000.o"

echo "[*] checking va2000_040.o has no surprise unresolved refs:"
LEAK0=$(m68k-linux-gnu-nm "$HERE/build/va2000_040.o" | grep ' U ' | grep -vE '^\s*U (autocon|printf|uiomove|copyin|copyout)$' || true)
[ -z "$LEAK0" ] && echo "      only expected kernel imports (autocon/printf/uiomove/copyin/copyout)" \
	|| { echo "[FAIL] unexpected unresolved refs in va2000_040.o:"; echo "$LEAK0"; exit 1; }

# ---------------------------------------------------------------------------
# Link.  VA2000 needs the base's strong `parinit` weakened first; Xsvga needs nothing
# done to the base, so it just rides along in the same ld -r.
# ---------------------------------------------------------------------------
echo "[*] weaken base parinit + expose parinit_orig -> build/unix-stage-rtg"
STAGE="$HERE/build/unix-stage-rtg"
cp "$IN" "$STAGE"
m68k-linux-gnu-objcopy \
	--weaken-symbol parinit \
	--add-symbol parinit_orig=.text:$PARINIT_ADDR,function,global \
	"$STAGE"

echo "[*] ld -r: base(weakened, FPSP in it) + xsvga_exp.o + va2000_040.o + parinit_va2000.o"
m68k-cbm-sysv4-ld -r -o "$OUT" "$STAGE" \
	"$HERE/build/xsvga_exp.o" \
	"$HERE/build/va2000_040.o" "$HERE/build/parinit_va2000.o"

echo "[*] symbols from all three features must be defined:"
for s in fpsp_vec11 fpsp_done fpsp_fline fpsp_unimp \
	svgaopen svgaclose svgaread svgawrite svgaioctl svgammap \
	Piccolo_SwitchToSVGA PicassoII_SwitchToSVGA \
	va2000init va2000open va2000close va2000read va2000write va2000ioctl va2000mmap va2000_boards \
	parinit parinit_orig; do
	m68k-linux-gnu-nm "$OUT" | grep -qE " [A-Za-z] $s$" || { echo "[FAIL] $s missing"; exit 1; }
done
echo "      FPSP + svga* + va2000* + parinit/parinit_orig all defined"

LEAK=$(m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'fpsp_|mem_read|mem_write|real_|svga|va2000|screengroups|activescreen' || true)
[ -z "$LEAK" ] && echo "      no unresolved FPSP/svga/va2000 symbols" || { echo "[FAIL] unresolved:"; echo "$LEAK"; exit 1; }

# parinit must be a SINGLE strong def (our override), not still resolving to the stock body.
PCOUNT=$(m68k-linux-gnu-nm "$OUT" | grep -cE " T parinit$")
[ "$PCOUNT" -eq 1 ] || { echo "[FAIL] expected exactly 1 strong 'parinit' def, found $PCOUNT"; exit 1; }

# ---------------------------------------------------------------------------
# Register both drivers.  Distinct majors, distinct relocation sets -- but run them in
# a fixed order and let each assert its own preconditions.
# ---------------------------------------------------------------------------
echo "[*] register 1/2: cdevsw[67] -> svga* + svgammap Model-B geometry"
python3 "$HERE/prototypes/patch_xsvga.py" "$OUT" | tail -3

echo "[*] register 2/2: cdevsw[68] -> va2000* (major 68 = /dev/va2000)"
python3 "$HERE/prototypes/patch_va2000_cdevsw.py" "$OUT" | tail -8

echo
echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py "$OUT" 2>/dev/null | tail -1 ) || true
DSZ=$(m68k-linux-gnu-readelf -SW "$OUT" | awk '{gsub(/[][]/,"")} $2==".data"{print strtonum("0x"$6)}')
[ $((DSZ % 4)) -eq 0 ] && echo "[OK] .data 4-aligned ($DSZ)" || { echo "[FAIL] .data misaligned ($DSZ)"; exit 1; }
echo "[*] PC-relative relocs present (loader MUST have the f0ed373 fix):"
m68k-linux-gnu-readelf -rW "$OUT" 2>/dev/null | awk '$3 ~ /^R_68K_PC/{n++} END{print "      "n" PC-relative records"}'

python3 "$HERE/prototypes/stamp_buildid.py" "$OUT" || true
rm -f "$STAGE"
echo "[OK] built $OUT"
echo "     boot: unix_boot040 $(basename "$OUT")   <- unix_boot040 is MANDATORY"
echo "     nodes: mknod /dev/svga    c 67 0"
echo "            mknod /dev/va2000  c 68 0"
