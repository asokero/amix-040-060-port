#!/bin/sh
# mk_modelb_sysroot.sh -- build build/sysroot-modelb, the header set every C
# file compiled INTO this 68040 kernel must see (2026-08-01).
#
# THE PROBLEM THIS SOLVES.  The cross toolchain's gcc wrapper
# (~/opt/amix-cross/bin/m68k-cbm-sysv4-gcc, line 13) prepends
#     -I"$sysroot/usr/include"
# to every compile, BEFORE any -I on the command line.  So a user -I can never
# override a header the sysroot also provides -- which means the
# -I.../vanilla/usr/include in AMIX_KERNEL_CFLAGS has in fact never been
# consulted for <sys/immu.h> or <sys/param.h>, and both sysroot copies say the
# page is 2 KiB.  That is the trap recorded as amix-crosscompile-headers-2kib.
#
# The wrapper does honour AMIX_SYSROOT, so the override is a MIRROR sysroot:
# every entry symlinked to the real one, except <sys/immu.h> and <sys/param.h>,
# which become the Model-B files from include-modelb/, with the originals still
# reachable as <sys/immu_stock.h> / <sys/param_stock.h>.  Nothing in the real
# sysroot is modified, and a build that forgets AMIX_SYSROOT fails the probe
# below rather than producing a quietly 2 KiB object.
#
# Usage:  sh prototypes/mk_modelb_sysroot.sh
#         export AMIX_SYSROOT=<printed path>
set -e

HERE=$(cd "$(dirname "$0")/.." && pwd)
. /home/asokero/kehitys/amix-playground/gcc-cross-amix/build/env.sh
REAL="${AMIX_REAL_SYSROOT:-/home/asokero/opt/amix-cross/m68k-cbm-sysv4/sysroot}"
OUT="$HERE/build/sysroot-modelb"

[ -d "$REAL/usr/include/sys" ] || { echo "ERROR: real sysroot not found: $REAL"; exit 1; }

echo "[*] mirroring $REAL -> $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/usr/include/sys"

# usr/: everything except include/ is a plain symlink (lib, ccs, sys, ...).
for e in "$REAL"/usr/*; do
	b=$(basename "$e")
	[ "$b" = "include" ] && continue
	ln -s "$e" "$OUT/usr/$b"
done

# usr/include/: everything except sys/ is a plain symlink.
for e in "$REAL"/usr/include/*; do
	b=$(basename "$e")
	[ "$b" = "sys" ] && continue
	ln -s "$e" "$OUT/usr/include/$b"
done

# usr/include/sys/: symlink everything, then substitute the two geometry headers
# and keep the originals reachable under *_stock.h.
for e in "$REAL"/usr/include/sys/*; do
	ln -s "$e" "$OUT/usr/include/sys/$(basename "$e")"
done
for h in immu param; do
	rm -f "$OUT/usr/include/sys/$h.h"
	ln -s "$REAL/usr/include/sys/$h.h" "$OUT/usr/include/sys/${h}_stock.h"
	cp "$HERE/include-modelb/sys/$h.h" "$OUT/usr/include/sys/$h.h"
	echo "      sys/$h.h  = Model B   (stock kept as sys/${h}_stock.h)"
done

# ---------------------------------------------------------------- the probe
# A build that silently missed the override must FAIL HERE, not months later in
# a driver.  Every constant is asserted by a negative array size, which this gcc
# reports as "size of array `...' is negative" with a line number.
echo "[*] compiling the geometry probe through the mirror sysroot"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
AMIX_SYSROOT="$OUT" m68k-cbm-sysv4-gcc $CF \
	-c "$HERE/prototypes/modelb_geom_probe.c" -o "$HERE/build/modelb_geom_probe.o"

# And the same probe MUST fail against the real sysroot -- otherwise the probe
# is not testing anything (the instrument gets verified, not assumed).
if AMIX_SYSROOT="$REAL" m68k-cbm-sysv4-gcc $CF \
	-c "$HERE/prototypes/modelb_geom_probe.c" -o /dev/null 2>/dev/null; then
	echo "[FAIL] the probe compiles against the STOCK sysroot too -- it proves nothing"; exit 1
fi
echo "[OK] probe passes through the mirror and fails against the stock sysroot."

echo
echo "[OK] $OUT"
echo "     export AMIX_SYSROOT=$OUT"
