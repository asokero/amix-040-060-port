#!/bin/sh
# test-isp060.sh -- self-test of the opt-in 68060 ISP pass (DRIVER-LINE-9).
#
#     sh tools/test-isp060.sh [patched-kernel [unpatched-base]]
#
# Always: build-isp060.sh, whose gates are the test of the package (pinned tarball, image size, zero
# unresolved, 128-byte table, all 32 call-out slots inside the glue, all 8 entry points `bra.l`
# into the image, the exact import set, the SysV4 linker accepting the object).
# With a kernel built by relink-040-isp060.sh: --check passes; a second patch is [skip] and leaves
# every byte as it was.  With an unpatched base as well: the patcher refuses it (no isp060_unimp).
# The behaviour itself -- every emulated form against a 68030 -- is the emulator probe set in
# KNOWN-ISSUES DRIVER-LINE-9; it needs a booted 68060 and is not hermetic.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
sh "$HERE/build-isp060.sh" > "$HERE/build/test-isp060-build.log" 2>&1 \
	|| { cat "$HERE/build/test-isp060-build.log"; echo "[FAIL] build-isp060.sh"; exit 1; }
grep '^\[OK\]' "$HERE/build/test-isp060-build.log"
[ -n "$1" ] || exit 0
echo "hook patcher against $(basename "$1"):"
python3 "$HERE/src/patch_isp060_hook.py" --check "$1"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cp "$1" "$W/k"
python3 "$HERE/src/patch_isp060_hook.py" "$W/k" | grep -q '\[skip\]' \
	|| { echo "  [FAIL] a second patch was not [skip]"; exit 1; }
cmp -s "$1" "$W/k" || { echo "  [FAIL] a second patch changed bytes"; exit 1; }
echo "  [ok]   idempotent: a second patch is [skip] and byte-identical"
[ -n "$2" ] || exit 0
cp "$2" "$W/b"
if python3 "$HERE/src/patch_isp060_hook.py" "$W/b" > "$W/out" 2>&1; then
	echo "  [FAIL] the patcher accepted a base without the ISP package"; exit 1
fi
grep -q 'isp060_unimp' "$W/out" || { cat "$W/out"; echo "  [FAIL] refused for the wrong reason"; exit 1; }
cmp -s "$2" "$W/b" || { echo "  [FAIL] the refused base was modified"; exit 1; }
echo "  [ok]   refuses a base without the package, and writes nothing: $(cat "$W/out")"
