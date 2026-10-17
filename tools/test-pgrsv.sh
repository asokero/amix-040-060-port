#!/bin/sh
# test-pgrsv.sh -- run the page-out reserve (src/pgrsv.c) on qemu-m68k against its rules
# (tools/test-pgrsv.c), then the call-site patcher (src/patch_pgrsv_sites.py) against a kernel.
# The object under test is compiled as relink-040-pgrsv.sh compiles it, plus -DPGRSV_HOSTTEST (the
# two SR helpers come from the harness; see tools/test-pgrsv.c).
#
#     sh tools/test-pgrsv.sh [patched-kernel [unpatched-base]]   # exits 0 if every case passes
#
# With a kernel built by relink-040-pgrsv.sh, also: --check passes, a second patch is [skip].
# With an unpatched base as well: the patcher refuses it (no pgrsv_get) and writes nothing.
# Needs the AMIX cross compiler (config.sh), m68k-linux-gnu-gcc and qemu-m68k.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
for t in m68k-cbm-sysv4-gcc m68k-linux-gnu-gcc qemu-m68k; do
	command -v "$t" >/dev/null 2>&1 || { echo "[FAIL] $t not found"; exit 2; }
done
mkdir -p "$HERE/build"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
m68k-cbm-sysv4-gcc $CF -DPGRSV_HOSTTEST -c "$HERE/src/pgrsv.c" -o "$HERE/build/pgrsv-host.o"
m68k-linux-gnu-gcc -static -O1 -Wall -Werror "$HERE/tools/test-pgrsv.c" "$HERE/build/pgrsv-host.o" \
	-o "$HERE/build/test-pgrsv"
qemu-m68k "$HERE/build/test-pgrsv"

[ -n "$1" ] || exit 0
echo "patcher against $(basename "$1"):"
python3 "$HERE/src/patch_pgrsv_sites.py" --check "$1"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$1" "$W/k"
python3 "$HERE/src/patch_pgrsv_sites.py" "$W/k" | grep -q '\[skip\]' \
	|| { echo "  [FAIL] a second patch was not [skip]"; exit 1; }
cmp -s "$1" "$W/k" || { echo "  [FAIL] a second patch changed bytes"; exit 1; }
echo "  [ok]   idempotent: a second patch is [skip] and byte-identical"
[ -n "$2" ] || exit 0
cp "$2" "$W/b"
if python3 "$HERE/src/patch_pgrsv_sites.py" "$W/b" > "$W/out" 2>&1; then
	echo "  [FAIL] the patcher accepted a base without pgrsv_get"; exit 1
fi
grep -q 'pgrsv_get' "$W/out" || { cat "$W/out"; echo "  [FAIL] refused for the wrong reason"; exit 1; }
cmp -s "$2" "$W/b" || { echo "  [FAIL] the refused base was modified"; exit 1; }
echo "  [ok]   refuses a base without the reserve, and writes nothing: $(cat "$W/out")"
