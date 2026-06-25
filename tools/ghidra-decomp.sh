#!/bin/sh
# Headless Ghidra decompiler for the AMIX m68k kernel.
# Usage:  sh tools/ghidra-decomp.sh segvn_fault,segvn_faultpage,anon_private
# First run imports + analyzes build/unix-040 (or $TARGET) with the MC68030 language and saves
# a Ghidra project under /tmp/ghproj-amix; later runs reuse it (fast, -process -noanalysis).
# Output: decompiled C per named function (calls show as func_0x0 -- ET_REL relocs are not yet
# resolved; map them with `m68k-linux-gnu-objdump -d -r` when a call target matters).
set -e
GH="${GHIDRA:-/home/asokero/kehitys/amix-playground/ghidra_12.1.2_PUBLIC}"
TARGET="${TARGET:-/home/asokero/kehitys/amix-playground/vanilla/stand/unix}"
PROJ=/tmp/ghproj-amix
NAME=amixk
SCRIPTS="$(cd "$(dirname "$0")" && pwd)/ghidra-scripts"
mkdir -p "$SCRIPTS"
# (the DecompFns.java script is kept alongside this driver)
export GH_FNS="$1"
PROG=$(basename "$TARGET")
if [ ! -d "$PROJ/$NAME.rep" ]; then
  echo "[*] first run: importing + analyzing $TARGET (MC68030) -- a couple minutes"
  mkdir -p "$PROJ"
  "$GH/support/analyzeHeadless" "$PROJ" "$NAME" -import "$TARGET" \
     -processor 68000:BE:32:MC68030 -scriptPath "$SCRIPTS" -postScript DecompFns.java 2>/dev/null \
     | sed -n '/@@@@/,$p' | sed 's/^INFO  DecompFns.java> //; s/ (GhidraScript)  $//'
else
  "$GH/support/analyzeHeadless" "$PROJ" "$NAME" -process "$PROG" -noanalysis \
     -scriptPath "$SCRIPTS" -postScript DecompFns.java 2>/dev/null \
     | sed -n '/@@@@/,$p' | sed 's/^INFO  DecompFns.java> //; s/ (GhidraScript)  $//'
fi
