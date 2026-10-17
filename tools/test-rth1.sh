#!/bin/sh
# test-rth1.sh -- run the kernel half of the RTH1 root hint (src/rth1.c) on qemu-m68k against
# every rule of docs/contracts/RTH1-ROOT-HINT.md (tools/test-rth1.c).  The object under test is
# compiled exactly as relink-040-rth1.sh compiles it.
#
#     sh tools/test-rth1.sh          # exits 0 if every case passes
#
# Needs the AMIX cross compiler (config.sh), m68k-linux-gnu-gcc and qemu-m68k.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"
for t in m68k-cbm-sysv4-gcc m68k-linux-gnu-gcc qemu-m68k; do
	command -v "$t" >/dev/null 2>&1 || { echo "[FAIL] $t not found"; exit 2; }
done
mkdir -p "$HERE/build"
CF=$(echo "$AMIX_KERNEL_CFLAGS" | sed 's/-m68020/-m68040/')
m68k-cbm-sysv4-gcc $CF -c "$HERE/src/rth1.c" -o "$HERE/build/rth1-host.o"
m68k-linux-gnu-gcc -static -O1 -Wall -Werror "$HERE/tools/test-rth1.c" "$HERE/build/rth1-host.o" \
	-o "$HERE/build/test-rth1"
qemu-m68k "$HERE/build/test-rth1"
