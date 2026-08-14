#!/bin/sh
# relink-040-xsvga.sh -- EXPERIMENTAL: build an 040 kernel with the Klaus
# Burckert Xsvga graphics driver (Piccolo/Picasso II Zorro-II) linked in.
#
# NOT part of the standard kernel (per the user: separate test build only).
# Layers on top of an already-built base (default build/unix-040-dbg):
#   1. ld -r the binary-only driver object (svga/exp, ET_REL m68k) into the
#      kernel -- its 10 imports (bzero/copyin/.../bootinfo/screengroups) bind to
#      our kernel; it defines svgaopen..svgammap + Piccolo/PicassoII routines.
#   2. patch_xsvga.py registers cdevsw[67] (nodev -> svga*) and fixes the
#      driver's own Model-B framebuffer geometry (svgammap phystopfn >>11->>12).
#   3. validate relocs + stamp a build id.
#
# The driver blob lives OUTSIDE the repo (third-party, not ours to redistribute).
# Its durable path and expected SHA-256 are in src/xsvga-provenance.sh --
# override with XSVGA_EXP=/your/path.  Until 2026-07-26 the default pointed into a
# session scratchpad under /tmp, which made rebuilds non-reproducible.
#
# FPSP note: since 2026-07-26 the Motorola FPSP is part of the BASE link
# (relink-040.sh), so this script no longer adds it -- it REQUIRES it in the base.
#
# For a kernel with BOTH RTG drivers (Xsvga + VA2000) use relink-040-rtg.sh.
#
# Usage: sh relink-040-xsvga.sh [base-kernel] [exp-object]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "$(cd "$(dirname "$0")" && pwd)/tools/config-load.sh"
. "$(cd "$(dirname "$0")" && pwd)/tools/build-step.sh"

. "$HERE/src/xsvga-provenance.sh"

IN="${1:-$HERE/build/unix-040-dbg}"
EXP="${2:-$XSVGA_EXP}"
XSVGA_EXP="$EXP"
OUT="$HERE/build/unix-040-xsvga-dbg"

[ -f "$IN" ]  || { echo "ERROR: base kernel missing: $IN"; exit 1; }
xsvga_check_exp || exit 1
m68k-linux-gnu-nm "$IN" | grep -qE " [Tt] fpsp_vec11$" || {
	echo "[FAIL] base does NOT carry FPSP -- since 2026-07-26 FPSP is part of"
	echo "       relink-040.sh.  Rebuild the base: sh relink-040.sh"
	exit 1
}

echo "[*] ld -r: $(basename "$IN") + svga/exp -> $(basename "$OUT")"
cp "$EXP" "$HERE/build/xsvga_exp.o"
m68k-cbm-sysv4-ld -r -o "$OUT" "$IN" "$HERE/build/xsvga_exp.o"

echo "[*] checking svga entry points are defined:"
for s in svgaopen svgaclose svgaread svgawrite svgaioctl svgammap Piccolo_SwitchToSVGA PicassoII_SwitchToSVGA; do
	a=$(m68k-linux-gnu-nm "$OUT" | awk -v s=$s '$3==s{print $1}')
	[ -n "$a" ] && echo "      $s = 0x$a" || { echo "[FAIL] $s undefined after ld -r"; exit 1; }
done

echo "[*] stray new UND refs from exp (should be none):"
m68k-linux-gnu-nm "$OUT" | grep ' U ' | grep -iE 'svga|screengroups|activescreen' | sed 's/^/      LEAK: /' || true

echo "[*] register cdevsw[67] + fix svgammap geometry:"
run_step 8 python3 "$HERE/src/patch_xsvga.py" "$OUT"

echo "[*] reloc validation:"
run_step 1 python3 "$HERE/src/check_relink_relocs.py" "$OUT"

echo "[*] stamping build id:"
run_step all python3 "$HERE/src/stamp_buildid.py" "$OUT"

echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040-xsvga-dbg"
