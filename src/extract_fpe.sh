#!/bin/sh
# extract_fpe.sh -- put the NetBSD/m68k FPE sources where the build can compile them, and keep
# proving they are the tarball's own bytes (2026-08-27).
#
# The emulator is third-party code and this repository does not carry it.  It comes out of the
# SAME pinned NetBSD source tarball Motorola's FPSP and 060SP already come out of
# (build-fpsp040.sh), under the same rule this project uses everywhere: you supply the tarball,
# the build extracts what it needs, and no third-party source file is checked in.  What IS
# checked in is the first-party glue -- src/fpe_glue.c, src/fpe040.s, src/fpe-compat/ -- and the
# licence texts the attribution requires, in THIRD_PARTY_NOTICES/NETBSD-M68K-FPE.txt.  Those
# licences are five families with materially different conditions, one of them a live
# advertising clause; NOTICE maps them.
#
# The extracted tree, gitignored with the rest of build/:
#
#   build/fpe-src/                25 files from usr/src/sys/arch/m68k/fpe/
#   build/fpe-src/include/m68k/   cpuframe.h, fpreg.h, ieee.h
#   build/fpe-src/include/sys/    ieee754.h
#
# THREE QUESTIONS, and the third is not licence hygiene:
#
#   1. is the tarball the pinned one?  A different tarball is a different emulator, and the
#      comparison below would be against something the build was never measured on.
#   2. is every extracted file still the tarball's bytes, and is there nothing beside them?
#      The tree lives under build/, which is where this project puts things it is free to
#      delete -- so an edit there is invisible to git and would reach the kernel unremarked.
#      An extraction that is only believed is not an extraction.
#   3. does the emulator still touch only the four TAIL members of struct fpframe?
#
# Question 3 is a correctness gate.  src/fpe_glue.c hands the emulator a `struct fpframe *`
# computed as a fixed bias off fpu_ptr, so that fpf_regs lands on AMIX's own fpu_info.regs with
# no copy and no transposition (contract 3.1).  The 216-byte FSAVE union IN FRONT of that tail
# therefore addresses memory before the u-area's FP block, and nothing may dereference it.
# Today nothing does -- measured over the whole tree -- and this is what keeps that true across
# a future tarball pin.
#
# Usage:  sh src/extract_fpe.sh                 extract if absent, verify, refuse a stale tree
#         FPE_REEXTRACT=1 sh src/extract_fpe.sh discard what is there and extract again

set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
. "$HERE/tools/config-load.sh"

# The pinned tarball -- NetBSD 10.1 syssrc.tgz -- as config.sh records it.  Repeated here
# because config.sh is local-only and this check must not depend on a file the repository does
# not carry.  Rounds <=12 of this lane pinned NetBSD 9.4 instead, sha256 5e1f1017...3120b.
WANT=76a600e703d2e964753323e264d3ec07d0c6cbe134648fc8f0f13ed9faaa1be4

DEST="$HERE/build/fpe-src"
TMP="$HERE/build/fpe-extract-check"
SUB=usr/src/sys/arch/m68k/fpe
MD=usr/src/sys/arch/m68k/include
MI=usr/src/sys

[ -f "$NETBSD_SYSSRC" ] || { echo "[FAIL] NETBSD_SYSSRC not found: $NETBSD_SYSSRC"; exit 1; }
GOT=$(sha256sum "$NETBSD_SYSSRC" | cut -d' ' -f1)
[ "$GOT" = "$WANT" ] || {
	echo "[FAIL] $NETBSD_SYSSRC sha256 $GOT, expected $WANT"
	echo "       A different tarball is a different emulator; everything this lane measured"
	echo "       was measured on the pinned one."
	exit 1
}
echo "      tarball sha256 $WANT"

# unpack <root> -- lay the four extraction roots out the way the -I lines want them.
unpack() {
	d=$1
	rm -rf "$d" "$d.raw"; mkdir -p "$d.raw"
	tar -xzf "$NETBSD_SYSSRC" -C "$d.raw" --exclude=CVS \
		"$SUB" "$MD/cpuframe.h" "$MD/fpreg.h" "$MD/ieee.h" "$MI/sys/ieee754.h"
	mkdir -p "$d/include/m68k" "$d/include/sys"
	cp -p "$d.raw/$SUB"/* "$d/"
	cp -p "$d.raw/$MD/cpuframe.h" "$d.raw/$MD/fpreg.h" "$d.raw/$MD/ieee.h" "$d/include/m68k/"
	cp -p "$d.raw/$MI/sys/ieee754.h" "$d/include/sys/"
	rm -rf "$d.raw"
}

[ -n "$FPE_REEXTRACT" ] && rm -rf "$DEST"

if [ ! -d "$DEST" ]; then
	echo "      extracting $SUB + 4 machine-ABI headers -> build/fpe-src/"
	unpack "$DEST"
fi

# The freshness gate.  A fresh extraction beside the one the build is about to compile, and
# `diff -r` both ways: a file present on only one side fails exactly like an edited one, so an
# addition to the extracted space is caught as loudly as a modification.
unpack "$TMP"
if diff -r "$TMP" "$DEST" >/dev/null 2>&1; then
	n=$(ls -1 "$DEST" | grep -v '^include$' | wc -l)
	h=$(find "$DEST/include" -type f | wc -l)
	echo "      build/fpe-src/      $n files + $h machine-ABI headers, byte-identical to the tarball"
else
	echo "[FAIL] build/fpe-src/ is not what the pinned tarball says it should be:"
	diff -r "$TMP" "$DEST" | sed 's/^/    /'
	echo "       Left is the tarball, right is what the build would have compiled.  This tree"
	echo "       is extracted output, not source: nothing should ever edit it, and a kernel"
	echo "       built from an edited copy is not the emulator this lane measured."
	echo "       Re-extract:  FPE_REEXTRACT=1 sh src/extract_fpe.sh   (or rm -rf build/fpe-src)"
	rm -rf "$TMP"
	exit 1
fi
rm -rf "$TMP"

# The four tail members, and nothing else from struct fpframe.
BAD=$(grep -ohE "fpf_[a-z0-9_]+" "$DEST"/*.c "$DEST"/*.h \
	| sort -u | grep -vE '^fpf_(regs|fpcr|fpsr|fpiar)$' || true)
[ -z "$BAD" ] || {
	echo "[FAIL] the emulator now references struct fpframe members outside the tail:"
	echo "$BAD" | sed 's/^/    /'
	echo "       src/fpe_glue.c's fixed-bias fpframe pointer does not address those."
	exit 1
}
echo "      fpframe use         fpf_regs / fpf_fpcr / fpf_fpsr / fpf_fpiar only"

echo "[OK] FPE sources are the pinned tarball's, and still tail-only"
