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
# The driver blob lives OUTSIDE the repo (user: not standard in vanilla):
#   EXP defaults to the durable scratch copy extracted from install.svga.
#
# Usage: sh relink-040-xsvga.sh [base-kernel] [exp-object]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
. "/home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh"

IN="${1:-$HERE/build/unix-040-dbg}"
EXP="${2:-/tmp/claude-12044/-home-asokero-kehitys-amix-playground-kernelsupport/durable-tftp-payloads/xsvga/svga/exp}"
OUT="$HERE/build/unix-040-xsvga-dbg"

[ -f "$IN" ]  || { echo "ERROR: base kernel missing: $IN"; exit 1; }
[ -f "$EXP" ] || { echo "ERROR: exp driver object missing: $EXP"; exit 1; }

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
python3 "$HERE/prototypes/patch_xsvga.py" "$OUT" | tail -8

echo "[*] reloc validation:"
( cd "$HERE" && python3 prototypes/check_relink_relocs.py "$OUT" 2>/dev/null | tail -1 ) || \
( cd "$HERE" && python3 prototypes/check_relink_relocs.py | tail -1 ) || true

echo "[*] stamping build id:"
python3 "$HERE/prototypes/stamp_buildid.py" "$OUT" || true

echo "[OK] built $OUT -- boot on 68040: unix_boot unix-040-xsvga-dbg"
