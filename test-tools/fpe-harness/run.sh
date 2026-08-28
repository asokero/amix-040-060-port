#!/bin/sh
# run.sh -- build and run the FPE frame harness on a big-endian m68k host under qemu-m68k.
#
# The harness links the EXTRACTED NetBSD emulator (build/fpe-src/) unmodified, exactly as
# relink-040-fpe.sh does, and supplies the same four kernel primitives the glue supplies.  It
# answers "what does the emulator do with a vector-60 frame" by running it, on the right
# endianness and the right pointer width, without an Amiga anywhere in the loop.
#
# It is NOT a substitute for the metal rows: it says nothing about src/fpe040.s, the vector
# table, or the frame the 68060 actually stacks.  docs/contracts/FPE-R10-VEC60.md 8 and 9
# carry that split.
#
# Needs: m68k-linux-gnu-gcc, qemu-m68k, and build/fpe-src/ (src/extract_fpe.sh puts it there).
#
#   sh test-tools/fpe-harness/run.sh

set -e
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SRC="$HERE/build/fpe-src"
OUT="$HERE/build/fpe-harness"

command -v m68k-linux-gnu-gcc >/dev/null || { echo "ERROR: m68k-linux-gnu-gcc not on PATH"; exit 1; }
command -v qemu-m68k          >/dev/null || { echo "ERROR: qemu-m68k not on PATH"; exit 1; }

# The extracted tree, and the freshness gate that proves it is the pinned tarball's bytes.
# Same gate the kernel build runs; a harness compiled against an edited emulator would be
# measuring something this lane does not ship.
echo "[*] FPE sources from the pinned tarball"
sh "$HERE/src/extract_fpe.sh" | sed 's/^/      /'

# THE INCLUDE ORDER IS THE KERNEL BUILD'S, one substitution.  There the AMIX sysroot comes
# first and supplies <sys/*>; here test-tools/fpe-harness/include does, with the same six
# headers stubbed to what the emulator actually takes from them.  src/fpe-compat and the
# extracted include/ follow in the same order, so m68k/m68k.h still shadows NetBSD's and
# machine/frame.h still forwards to cpuframe.h.
INC="-I$HERE/test-tools/fpe-harness/include -I$HERE/src/fpe-compat -I$SRC/include -I$SRC"

# -nostdinc keeps glibc's headers away from the emulator entirely, so the stubs above are the
# whole environment; the compiler's own directory is added back for stddef/stdarg/float.
GCCINC=$(m68k-linux-gnu-gcc -print-file-name=include)
CF="-std=gnu89 -O1 -g -fno-strict-aliasing -nostdinc -isystem $GCCINC -Wno-implicit"

rm -rf "$OUT"; mkdir -p "$OUT"
echo "[*] cross-compiling the emulator + the harness for m68k (big-endian, ILP32)"
OBJS=
for f in "$SRC"/*.c; do
	b=$(basename "$f" .c)
	m68k-linux-gnu-gcc $CF $INC -c "$f" -o "$OUT/$b.o"
	OBJS="$OBJS $OUT/$b.o"
done
N=$(echo $OBJS | wc -w)
[ "$N" = 20 ] || { echo "[FAIL] $N emulator objects, expected 20"; exit 1; }
m68k-linux-gnu-gcc $CF $INC -c "$HERE/test-tools/fpe-harness/fpe_frame_probe.c" \
	-o "$OUT/fpe_frame_probe.o"

# -static so qemu-m68k needs no m68k dynamic loader on this host.
m68k-linux-gnu-gcc -static -o "$OUT/fpe_frame_probe" "$OUT/fpe_frame_probe.o" $OBJS
echo "      $OUT/fpe_frame_probe  $(sha256sum "$OUT/fpe_frame_probe" | cut -c1-16)..."

echo "[*] running under qemu-m68k"
echo
qemu-m68k "$OUT/fpe_frame_probe"
